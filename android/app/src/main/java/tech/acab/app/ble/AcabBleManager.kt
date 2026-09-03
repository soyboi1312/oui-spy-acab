package tech.acab.app.ble

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.ParcelUuid
import android.os.Looper
import android.os.SystemClock
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.sample
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.roundToInt
import org.json.JSONArray
import org.json.JSONObject
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.companyIdHex
import tech.acab.app.model.validCoord
import tech.acab.app.model.displayName
import tech.acab.app.model.historyBeginFromOrAbsent
import tech.acab.app.model.historyBeginGenerationOrAbsent
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import tech.acab.app.net.FirmwareBuild
import tech.acab.app.net.FirmwareManifest
import tech.acab.app.net.firmwareArtifactResponseAllowed
import tech.acab.app.net.trustedFirmwareArtifactUrl
import tech.acab.app.widget.BeaconsWidgetProvider
import java.time.LocalDate
import java.time.ZoneId
import java.io.File
import java.net.HttpURLConnection
import java.security.KeyStore
import java.security.MessageDigest
import java.time.Instant
import java.util.ArrayDeque
import java.util.zip.CRC32
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import tech.acab.app.model.maker

enum class ConnState { DISCONNECTED, SCANNING, CONNECTING, BONDING, READY, POWERED_OFF }

/** Outcome for one replay end sentinel. A bounded retry stops radio churn for this connection,
 * but DEFER_INCOMPLETE deliberately does not authorize advancing past a sequence gap. */
internal enum class HistoryEndDisposition { COMPLETE, RETRY_NOW, DEFER_INCOMPLETE }

internal fun historyEndDisposition(
    received: Int,
    expected: Int,
    resyncAttempts: Int,
    resyncCap: Int,
    beginSeen: Boolean = true,
): HistoryEndDisposition = when {
    // Counts alone cannot authenticate a drain: if the begin notify was lost, an empty end (or
    // an equal number of records + end) would otherwise checkpoint the previous generation under
    // a board that may already have wiped/rotated its ring. Re-request the whole envelope, then
    // defer to a reconnect when this connection's bounded retry budget is exhausted.
    !beginSeen && resyncAttempts < resyncCap -> HistoryEndDisposition.RETRY_NOW
    !beginSeen -> HistoryEndDisposition.DEFER_INCOMPLETE
    received == expected -> HistoryEndDisposition.COMPLETE
    resyncAttempts < resyncCap -> HistoryEndDisposition.RETRY_NOW
    else -> HistoryEndDisposition.DEFER_INCOMPLETE
}

internal fun historyEnvelopeAuthorizesCheckpoint(beginSeen: Boolean): Boolean = beginSeen

internal const val DURABLE_BUFFER_KEY_BYTES = 32

internal fun durableBufferKeyIsUsable(raw: ByteArray?): Boolean =
    raw != null && raw.size == DURABLE_BUFFER_KEY_BYTES && raw.any { it.toInt() != 0 }

/** Resolve one long-lived buffer key without ever returning an uncommitted replacement.
 *
 * A present blob is authoritative: if it cannot be unwrapped, fail closed and preserve it. It may
 * still be the only key capable of decrypting evidence after a transient Keystore failure, so
 * silently rotating it is data loss. A new key becomes visible only after [persist] confirms its
 * synchronous durable write. Kept platform-free so the crash/failure boundaries stay unit-tested.
 */
internal fun resolveDurableBufferKey(
    stored: String?,
    unwrap: (String) -> ByteArray?,
    generate: () -> ByteArray?,
    wrap: (ByteArray) -> String?,
    persist: (String) -> Boolean,
): ByteArray? {
    if (stored != null) {
        val existing = runCatching { unwrap(stored) }.getOrNull()
        return existing?.takeIf(::durableBufferKeyIsUsable)
    }
    val candidate = runCatching(generate).getOrNull()
        ?.takeIf(::durableBufferKeyIsUsable) ?: return null
    val sealed = runCatching { wrap(candidate) }.getOrNull() ?: return null
    return if (runCatching { persist(sealed) }.getOrDefault(false)) candidate else null
}

internal enum class BufferHandshakeWrite { KEY, EPOCH, SYNC }
internal data class BufferHandshakeTransition(
    val next: BufferHandshakeWrite? = null,
    val complete: Boolean = false,
    val failed: Boolean = false,
)

/** The key write is a security barrier: epoch and sync do not exist until its ACK succeeds. */
internal fun bufferHandshakeTransition(
    completed: BufferHandshakeWrite,
    success: Boolean,
): BufferHandshakeTransition {
    if (!success) return BufferHandshakeTransition(failed = true)
    return when (completed) {
        BufferHandshakeWrite.KEY -> BufferHandshakeTransition(next = BufferHandshakeWrite.EPOCH)
        BufferHandshakeWrite.EPOCH -> BufferHandshakeTransition(next = BufferHandshakeWrite.SYNC)
        BufferHandshakeWrite.SYNC -> BufferHandshakeTransition(complete = true)
    }
}

internal fun <T> enqueueBufferControlWrite(
    queue: java.util.ArrayDeque<T>,
    value: T,
    handshakeSuccessor: Boolean,
) {
    // A clear requested while KEY is in flight stays behind EPOCH and SYNC. The same rule makes a
    // second clear wait until the first clear's full rekey completes, so one transaction can never
    // overwrite another transaction's completion owner.
    if (handshakeSuccessor) queue.addFirst(value) else queue.addLast(value)
}

internal enum class MtuDiscoveryAction { WAIT_FOR_CALLBACK, CONTINUE_AT_DEFAULT, DISCONNECT }
internal fun mtuDiscoveryAction(serviceDiscoverySucceeded: Boolean,
                                mtuRequestAccepted: Boolean): MtuDiscoveryAction = when {
    !serviceDiscoverySucceeded -> MtuDiscoveryAction.DISCONNECT
    mtuRequestAccepted -> MtuDiscoveryAction.WAIT_FOR_CALLBACK
    else -> MtuDiscoveryAction.CONTINUE_AT_DEFAULT
}

/** Best available count of rows not delivered in this attempt. A duplicate-only mismatch cannot
 * identify the missing sequence, so report at least one rather than presenting the drain as clean. */
internal fun replayUnreplayedCount(
    promised: Int,
    sent: Int,
    received: Int,
    transportComplete: Boolean,
): Int {
    val safePromised = promised.coerceAtLeast(0)
    val safeSent = sent.coerceAtLeast(0)
    val safeReceived = received.coerceAtLeast(0)
    val missing = if (safePromised > 0) {
        (safePromised - minOf(safeSent, safeReceived)).coerceAtLeast(0)
    } else {
        (safeSent - safeReceived).coerceAtLeast(0)
    }
    return if (transportComplete) missing else maxOf(1, missing)
}

internal data class ReplayCursorTuple(val sequence: Long, val generation: Long)

/** A reconnect can advertise only the durable tuple. The volatile cursor may be ahead while the
 * detection-store checkpoint is still in flight; trusting it would let firmware omit RAM-only
 * rows permanently. The otherwise-unused argument makes that rejected choice explicit and keeps
 * the crash-window policy directly testable. */
internal fun replayCursorForReconnect(
    @Suppress("UNUSED_PARAMETER") volatileCursor: ReplayCursorTuple,
    durableCursor: ReplayCursorTuple,
): ReplayCursorTuple = durableCursor

internal enum class PairingFailure {
    START_REJECTED,
    CANCELED_OR_FAILED,
    TIMED_OUT,
    SECURE_LINK_NOT_READY,
}

internal fun pairingFailureHint(failure: PairingFailure): String = when (failure) {
    PairingFailure.START_REJECTED ->
        "Android could not start pairing. Keep the beacon powered and nearby, then try again."
    PairingFailure.CANCELED_OR_FAILED ->
        "Pairing was canceled or failed. Keep the beacon powered and nearby, approve Android's pairing request if it appears, then try again."
    PairingFailure.TIMED_OUT ->
        "Pairing took too long. Keep the beacon powered and nearby, approve Android's pairing request if it appears, then try again."
    PairingFailure.SECURE_LINK_NOT_READY ->
        "Android connected, but the beacon's secure link did not become ready. Keep it powered and nearby, then try again."
}

/** A same-address BOND_NONE is terminal only after this attempt observed a real BONDING state. */
internal fun shouldAcceptCurrentBondNone(
    state: ConnState,
    userInitiatedDisconnect: Boolean,
    activeAttemptGeneration: Long,
    observedBondingGeneration: Long,
    previousStateWasBonding: Boolean,
    platformStateIsNone: Boolean,
): Boolean = state == ConnState.BONDING && !userInitiatedDisconnect &&
    activeAttemptGeneration > 0L && observedBondingGeneration == activeAttemptGeneration &&
    previousStateWasBonding && platformStateIsNone

internal fun shouldHandleCurrentBonded(
    state: ConnState,
    userInitiatedDisconnect: Boolean,
    activeAttemptGeneration: Long,
    handledBondedGeneration: Long,
    platformStateIsBonded: Boolean,
): Boolean = state == ConnState.BONDING && !userInitiatedDisconnect &&
    activeAttemptGeneration > 0L && handledBondedGeneration != activeAttemptGeneration &&
    platformStateIsBonded

internal fun shouldStopScanBeforeDemo(state: ConnState): Boolean = state == ConnState.SCANNING

internal fun awaitingSecureReadiness(state: ConnState): Boolean =
    state == ConnState.CONNECTING || state == ConnState.BONDING

internal fun scanStartFailureHint(featureUnsupported: Boolean): String =
    if (featureUnsupported) {
        "This phone does not support the Bluetooth scan needed to find your beacon."
    } else {
        "Android could not start Bluetooth scanning. Make sure Bluetooth is on, then try again."
    }

/** How sightings are announced.
 *  BUZZER  = board buzzes, phone stays quiet (the normal case).
 *  VIBRATE = board muted, phone buzzes on each first sighting.
 *  SILENT  = board muted, no phone feedback either. */
enum class AlertMode { BUZZER, VIBRATE, SILENT }

/** How long a scanned board stays in the picker after its last advert. See FoundBoard.seenAt.
 *
 *  A board advertises many times a second, so a few seconds of silence means gone, not quiet. */
private const val FOUND_STALE_MS = 6_000L

/** Bench tooling, OFF in every shipped build. Flip true to log each scanned board's advertised
 *  address and its type. Exists because Android is the ONLY platform that exposes a peer's real
 *  MAC (iOS and macOS substitute a per-host UUID), which makes it the only way to confirm the
 *  firmware's BLE address privacy is actually rotating rather than silently compiled out. */
private const val SCAN_ADDR_DEBUG = false

/** One board seen while scanning. [seenAt] exists because the board now advertises a ROTATING
 *  Resolvable Private Address (ACAB_BLE_PRIVACY): the list is keyed on device.address, so when an
 *  address rotates mid-scan the old entry would otherwise linger as a phantom second board.
 *
 *  THIS IS NOT AN ANDROID-ONLY PROBLEM, and the prune below must not be deleted as Android-specific
 *  complexity. It was reviewed as one, on the reading that iOS keys its discovered list on
 *  CBPeripheral.identifier, which is a per-host UUID rather than a MAC, and therefore already
 *  collapses a rotating peripheral to one row. The evidence says otherwise:
 *
 *   1. Per-host is a property of the VALUE, not a promise about rotation. CoreBluetooth can only
 *      keep issuing one UUID for one peer while it can tie successive advertisements to a stable
 *      identity, and for an LE peer that means resolving the RPA against an IRK it holds.
 *   2. The board hands its IRK over at BONDING and nowhere else: acab_ble_service.cpp sets
 *      BLE_SM_PAIR_KEY_DIST_ID explicitly on both key-distribution masks precisely so a bonded
 *      phone can follow the rotation, and states in the same comment that a stranger cannot.
 *   3. The picker IS the unbonded case. It exists to choose a board that has not been paired yet
 *      (first run, or after the user forgets the device), so at the moment this list is being built
 *      neither platform holds the key. An unresolvable rotated address is a new peer to
 *      CoreBluetooth exactly as it is a new BluetoothDevice here, and it gets a fresh identifier.
 *
 *  So both platforms need this and the correct action was to KEEP it. iOS reached the same verdict
 *  independently and now carries the matching prune (BLEManager.pruneStaleDiscovered, same 6 s
 *  window, same absent-is-fresh guard, same advert-driven timing); it stores the stamp in a side map
 *  instead of on the row only because its list is @Published and stamping the row per advert would
 *  republish the picker 10 to 20 times a second, which this file avoids for free by rebuilding
 *  _found per scan result. Recorded here rather than left implicit because "iOS uses a UUID, so iOS
 *  is fine" is a reasonable-sounding argument that will be made again.
 *
 *  Exposure is the same size on both, and it is small: the rotation period is
 *  CONFIG_BT_NIMBLE_RPA_TIMEOUT (900 s, see the advCompleteCb comment in acab_ble_service.cpp) and
 *  both platforms cap one picker scan at 45 s and clear the list when a scan starts. A phantom
 *  needs a rotation to land inside a single 45 s window. Small is not zero, and the failure is
 *  user-visible in the worst possible place: two rows for one board on the screen where a user
 *  who owns exactly one board decides which one to trust. */
data class FoundBoard(val device: BluetoothDevice, val name: String, val rssi: Int,
                      val firmware: String? = null, val seenAt: Long = 0L)

/** The most recent LIVE sighting (category + wall-clock last-seen), for the Drive-mode
 *  notification's "last <KIND> <ago>" line. One immutable object per update so a reader
 *  never sees a torn category/timestamp pair. */
data class NewestLive(val category: String, val at: Long)

/** A location fix keeps its uncertainty alongside its coordinate. Observer geotagging may use a
 * coarse but current fix, while a binary HERE rule must additionally prove that the uncertainty is
 * no wider than its own radius. */
internal data class MutePosition(
    val coord: Pair<Double, Double>,
    val horizontalAccuracyMeters: Double?,
)

private data class TimedCoord(
    val coord: Pair<Double, Double>,
    val elapsedRealtimeNanos: Long,
    val horizontalAccuracyMeters: Double?,
) {
    fun asMutePosition() = MutePosition(coord, horizontalAccuracyMeters)
}

/** One lock-consistent Live Mode projection. The newest row per category is derived during the
 * same pass that enforces mute and freshness policy, so the service never rescans or performs a
 * lock acquisition per displayed row. */
internal data class NearbySnapshot(
    val detections: List<Detection>,
    val newestByCategory: Map<String, NewestLive>,
)

/** One indivisible Stop result for the contribution composer. [capturedAtById] and [csv]
 *  are derived while holding the same store snapshot, so a live update or eviction cannot land
 *  between the membership decision and the row serialization. The CSV is deliberately
 *  unredacted; review-time policy switches redact this frozen text without touching the store. */
data class ContributionWindowSnapshot(
    val capturedAtById: Map<String, Long>,
    val csv: String,
)

/** Immutable input for a normal Log CSV/GPX export. Membership, visible row values, time basis,
 * and observer coordinate are all frozen before IO, so a scope change, resume, or live publish
 * cannot alter the file after the user taps Export. */
internal data class DetectionExportRowSnapshot(
    val detection: Detection,
    val firstSeenMs: Long?,
    val timeBasis: TimeBasis,
    val observerCoord: Pair<Double, Double>?,
)

internal data class DetectionExportSnapshot(val rows: List<DetectionExportRowSnapshot>)

/** Process-level location ownership rule. A visible READY link may use the Activity's
 * while-in-use grant; background Drive mode may use it only after its foreground service is
 * actually active. Keeping this pure pins the lifecycle matrix without an Android runtime. */
internal fun shouldOwnLocation(
    locationGranted: Boolean,
    state: ConnState,
    appForegrounded: Boolean,
    driveMode: Boolean,
    driveServiceActive: Boolean,
): Boolean = locationGranted && state == ConnState.READY &&
    (appForegrounded || (driveMode && driveServiceActive))

internal fun liveModeWanted(storedChoice: Boolean?): Boolean = storedChoice ?: true

/** Automatic service/link teardown suspends the surface without rewriting the user's preference.
 * Only an explicit off action turns the persisted intent off. */
internal fun liveModeWantedAfterStop(currentWanted: Boolean, userRequestedStop: Boolean): Boolean =
    if (userRequestedStop) false else currentWanted

/** A default Live Mode request is consumable only while its real link is usable and the activity
 * is resumed. Kept pure so the permission-dialog lifecycle regression stays pinned in JVM tests. */
internal fun defaultLiveModeStartReady(
    pending: Boolean,
    activityResumed: Boolean,
    linkReady: Boolean,
    demoMode: Boolean,
    wanted: Boolean,
): Boolean = pending && activityResumed && linkReady && !demoMode && wanted

/** startForegroundService accepting an Intent is not confirmation; only the service callback
 * proves foreground promotion succeeded. */
internal fun defaultLiveModeStartConfirmed(driveModeOn: Boolean, driveServiceReady: Boolean): Boolean =
    driveModeOn && driveServiceReady

/** Sample-data managed-list edits are session previews and must never reach disk or a board. */
internal fun managedListPersistenceAllowed(demoMode: Boolean): Boolean = !demoMode

/** NEW-lens membership from frozen first-seen values, never from manager side maps that may have
 * evicted these ids after Pause. The two watermark axes intentionally match [newIdSet]. */
internal fun frozenNewIdSet(
    rows: List<DetectionExportRowSnapshot>,
    seenWatermark: Long,
    approxWatermark: Long,
): Set<String> = buildSet {
    for (row in rows) {
        val fs = row.firstSeenMs
        val isNew = fs == null || if (fs <= AcabBleManager.HIST_PSEUDO_BASE) {
            fs < approxWatermark
        } else {
            fs > seenWatermark
        }
        if (isNew) add(row.detection.id)
    }
}

/** What the app knows about a buffered row's time: how the stamp was arrived at, and the key
 *  the log orders it by. The two are deliberately separate. A bracketed or unbounded record
 *  carries the seq-derived pseudo stamp, which sits near 2001, so sorting on the stamp buries
 *  every one of them under the real history they actually belong beside. The sort key is an
 *  ordering device only and is never printed. */
internal class HistTime(val basis: TimeBasis, val sortKey: Long)

/** One unanchored record held back until the drain closes and the boot bounds are known. */
private class PendingBracket(val id: String, val boot: Long, val ms: Long, val seq: Long)

/** Where an in-app firmware update is in its run. Drives the FirmwareCard's button copy. */
enum class OtaPhase {
    IDLE,        // nothing running
    CHECKING,    // opening the session on the board (begin sent, waiting for "ready")
    DOWNLOADING, // pulling the .bin over HTTPS
    VERIFYING,   // checking size + SHA-256 before we touch the board
    SENDING,     // streaming the image to the board (pct is meaningful here)
    REBOOTING,   // image accepted; board is rebooting into it, we wait for it to come back
    CONFIRMING,  // reconnected on the new version; disarming rollback
    DONE,        // confirmed on the new firmware
    FAILED,      // stopped with a reason (see OtaProgress.message); ROLLED-BACK lands here too
}

/** A snapshot of the running (or last) OTA, collected by the UI. */
data class OtaProgress(
    val phase: OtaPhase = OtaPhase.IDLE,
    val pct: Int = 0,            // 0..100, meaningful during DOWNLOADING and SENDING
    val message: String = "",    // human copy for FAILED, else a short status line
    val targetVersion: String = "",
)

/** Foreground-service Intent acceptance is only the request boundary. Board mutation is allowed
 * only after [AcabBleManager.onLinkServiceStarted] confirms promotion; a bounded wait fails closed
 * when Android accepts the Intent but later rejects startForeground(). */
internal enum class ForegroundServiceHoldDecision { READY, WAIT, FAILED }

internal fun foregroundServiceHoldDecision(
    requestAccepted: Boolean,
    serviceActive: Boolean,
    elapsedMs: Long,
    timeoutMs: Long,
): ForegroundServiceHoldDecision = when {
    !requestAccepted -> ForegroundServiceHoldDecision.FAILED
    serviceActive -> ForegroundServiceHoldDecision.READY
    elapsedMs >= timeoutMs -> ForegroundServiceHoldDecision.FAILED
    else -> ForegroundServiceHoldDecision.WAIT
}

/** A rejected duplicate start must not erase a same-reason hold owned by the live service. */
internal fun rejectedForegroundRequestRemovesHolder(
    holderInsertedByThisRequest: Boolean,
    requestAccepted: Boolean,
): Boolean = holderInsertedByThisRequest && !requestAccepted

/** A combined S3 leg starts after the original foreground tap and reuses that run's confirmed
 * hold. Direct S3 must invoke [requestOwnHold] instead. */
internal fun acquireOtaHoldBoundary(
    reuseConfirmedHold: Boolean,
    serviceActive: Boolean,
    requestOwnHold: () -> Boolean,
): Boolean = if (reuseConfirmedHold) serviceActive else requestOwnHold()

/** A lost keep-alive may stop S3 work only before the image-commit boundary. */
internal fun otaUserCancellationAllowed(phase: OtaPhase, imageEnded: Boolean): Boolean =
    !imageEnded && when (phase) {
        OtaPhase.CHECKING, OtaPhase.DOWNLOADING, OtaPhase.VERIFYING, OtaPhase.SENDING -> true
        OtaPhase.IDLE, OtaPhase.REBOOTING, OtaPhase.CONFIRMING,
        OtaPhase.DONE, OtaPhase.FAILED -> false
    }

internal const val OTA_HOLD_PROMOTION_TIMEOUT_MS = 5_000L

/** Current firmware replies carry no wire session token. This is the minimum ownership gate every
 * S3 OTA reply must pass before its phase-specific checks run. */
internal fun otaReplyBelongsToArmedSession(
    armed: Boolean,
    ownerConnectGen: Int,
    currentConnectGen: Int,
): Boolean = armed && ownerConnectGen >= 0 && ownerConnectGen == currentConnectGen

/** An abort is itself a board mutation and belongs only to the exact armed GATT generation. */
internal fun otaAbortAllowed(
    boardSessionArmed: Boolean,
    ownerConnectGen: Int,
    currentConnectGen: Int,
    phase: OtaPhase,
    imageEnded: Boolean,
    awaitingConfirm: Boolean,
): Boolean = otaReplyBelongsToArmedSession(
    armed = boardSessionArmed,
    ownerConnectGen = ownerConnectGen,
    currentConnectGen = currentConnectGen,
) && !imageEnded && !awaitingConfirm &&
    (phase == OtaPhase.CHECKING || phase == OtaPhase.SENDING)

internal enum class OtaPostRebootDecision { CONFIRM, LABEL_MISMATCH, ROLLED_BACK, UNKNOWN }

internal fun isNumericFirmwareVersion(value: String): Boolean {
    // Exact twin of release_tools.require_ota_packable_version. esp_app_desc.version has 32 bytes
    // including its NUL; the board packs one to three 10-bit fields, reserves packed zero as
    // malformed, and ignores one optional dash suffix. Keeping this gate looser than staging lets
    // an attacker-influenced Status label reach CONFIRM with a spelling no published image can
    // carry, disarming rollback on a value the board and app interpret differently.
    if (value.isEmpty() || value.length > 31 || value.any { it.code > 0x7f }) return false

    val dash = value.indexOf('-')
    val core = if (dash < 0) value else value.substring(0, dash)
    if (dash >= 0) {
        val suffix = value.substring(dash + 1)
        if (suffix.isEmpty() || suffix.first() !in ASCII_FIRMWARE_SUFFIX_ALNUM) return false
        if (suffix.any { it !in ASCII_FIRMWARE_SUFFIX_ALNUM && it != '.' && it != '-' }) return false
    }

    val fields = core.split('.')
    if (fields.size !in 1..3) return false
    var packedNonzero = false
    for (field in fields) {
        val numeric = packableFirmwareFieldValueOrNull(field) ?: return false
        if (numeric != 0) packedNonzero = true
    }
    return packedNonzero
}

private val ASCII_FIRMWARE_SUFFIX_ALNUM =
    ('0'..'9').toSet() + ('A'..'Z') + ('a'..'z')

/** Parse without Int.toInt(): the release grammar permits a 31-byte field of leading zeroes whose
 * value is still <=1023. Accumulating only until the packer's bound is crossed accepts that legal
 * spelling without letting an attacker-influenced long field overflow the post-reboot compare. */
private fun packableFirmwareFieldValueOrNull(field: String): Int? {
    if (field.isEmpty()) return null
    var numeric = 0
    for (char in field) {
        if (char !in '0'..'9') return null
        numeric = numeric * 10 + (char - '0')
        if (numeric > 1023) return null
    }
    return numeric
}

internal fun isFirmwareVersionAtLeast(have: String, want: String): Boolean {
    if (!isNumericFirmwareVersion(have) || !isNumericFirmwareVersion(want)) return false
    val a = have.substringBefore("-").split(".").map {
        packableFirmwareFieldValueOrNull(it) ?: return false
    }
    val b = want.substringBefore("-").split(".").map {
        packableFirmwareFieldValueOrNull(it) ?: return false
    }
    for (i in 0 until maxOf(a.size, b.size)) {
        val x = a.getOrElse(i) { 0 }
        val y = b.getOrElse(i) { 0 }
        if (x != y) return x > y
    }
    return true
}

/** Strict update gate shared by the OTA engine, combined flow, and Device screen. Both inputs use
 * the release grammar; comparison ignores the optional build/prerelease suffix consistently. */
internal fun isFirmwareVersionOlder(installed: String, latest: String): Boolean =
    isNumericFirmwareVersion(installed) && isNumericFirmwareVersion(latest) &&
        !isFirmwareVersionAtLeast(installed, latest)

internal fun decideOtaPostReboot(
    runningVersion: String,
    runningLabel: String,
    targetVersion: String,
    targetLabel: String,
): OtaPostRebootDecision = when {
    !isNumericFirmwareVersion(runningVersion) || !isNumericFirmwareVersion(targetVersion) ->
        OtaPostRebootDecision.UNKNOWN
    runningLabel != targetLabel -> OtaPostRebootDecision.LABEL_MISMATCH
    isFirmwareVersionAtLeast(runningVersion, targetVersion) -> OtaPostRebootDecision.CONFIRM
    else -> OtaPostRebootDecision.ROLLED_BACK
}

internal fun otaDoneCanAdvance(phase: OtaPhase, imageEnded: Boolean): Boolean =
    phase == OtaPhase.SENDING && imageEnded

enum class MuteScope { PERMANENT, ONE_HOUR, ONE_DAY, HERE }

/** Whether a configured mute is suppressing the device right now. A place rule remains
 * configured when the phone is outside its radius or has no current fix, but neither state is an
 * active mute. Keeping those states distinct prevents the dossier from claiming "MUTED" while
 * the active feed is correctly showing the device. */
enum class MuteRuleStatus {
    ACTIVE,
    EXPIRED,
    CURRENT_LOCATION_REQUIRED,
    OUTSIDE_RADIUS,
    INVALID_PLACE,
}

/** Status and Live Mode use one definition of "nearby now". Kept pure for policy tests. */
internal const val ACTIVE_NEARBY_WINDOW_MS = 45_000L
internal const val DEFAULT_HERE_RADIUS_METERS = 50.0

internal fun lastSeenIsNearby(
    lastSeenAt: Long?,
    now: Long,
    windowMs: Long = ACTIVE_NEARBY_WINDOW_MS,
): Boolean {
    if (lastSeenAt == null) return false
    val age = now - lastSeenAt
    return age in 0..windowMs
}

/** UI staleness, deliberately ONE-sided: a stamp a few milliseconds ahead of a view's captured
 *  `now` is fresh, not stale, so a backward wall-clock step (an NTP correction) cannot flip live
 *  rows to stale until they are re-heard. Live Mode keeps the stricter two-sided [lastSeenIsNearby]
 *  to reject genuinely future/corrupt data. Top-level so the per-row and whole-feed readers cannot
 *  drift apart, and named the same as iOS's lastSeenIsStale. */
internal fun lastSeenIsStale(
    lastSeenAt: Long?,
    now: Long,
    olderThanMs: Long = ACTIVE_NEARBY_WINDOW_MS,
): Boolean {
    if (lastSeenAt == null) return true
    return now - lastSeenAt > olderThanMs
}

/** A device the user has chosen to silence. Optional fields keep old permanent rows compatible. */
data class IgnoredDevice(
    val mac: String,
    val label: String,
    val expiresAt: Long? = null,
    val latitude: Double? = null,
    val longitude: Double? = null,
    val radiusMeters: Double = DEFAULT_HERE_RADIUS_METERS,
) {
    val isPlaceRule: Boolean get() = latitude != null || longitude != null

    val scopeLabel: String get() = when {
        latitude != null && longitude != null -> "within ${radiusMeters.toInt()} m"
        // Half-anchored (one coordinate, not both) is what evaluateMuteRule reads as INVALID_PLACE:
        // the rule silences nothing. The managed-list row prints this label with no MuteRuleStatus
        // beside it, so "place" read as an active geofenced mute and the user would leave a rule in
        // place that was never going to fire. On this threat model a false "you are covered" is the
        // wrong way to fail; say plainly that the rule cannot be used.
        // iOS twin: IgnoredDevice.scopeLabel in BLEManager.swift, same string.
        isPlaceRule -> "place rule unusable"
        expiresAt != null -> {
            val left = (expiresAt - System.currentTimeMillis()).coerceAtLeast(0L)
            if (left >= 3_600_000L) "${(left + 3_599_999L) / 3_600_000L}h remaining"
            else "${(left + 59_999L) / 60_000L}m remaining"
        }
        else -> "permanent"
    }
}

/** Immutable exact-MAC index used by the BLE ingest path. Building it only when the managed list
 * changes keeps each incoming record O(1), while the selected rule still evaluates its time/place
 * scope at the moment of the lookup. */
internal fun indexIgnoredDevices(items: List<IgnoredDevice>): Map<String, IgnoredDevice> =
    items.associateBy { it.mac.lowercase() }

/** One immutable generation for every hot-path exact-MAC decision. Publishing one volatile
 * reference prevents BLE ingest from observing a new ignore index with an old watch index (or
 * vice versa) while a paired durable edit is being installed. */
internal data class ManagedListIndexes(
    val ignoredByMac: Map<String, IgnoredDevice>,
    val watchedMacs: Set<String>,
)

internal fun buildManagedListIndexes(
    ignored: List<IgnoredDevice>,
    watched: List<WatchedDevice>,
): ManagedListIndexes = ManagedListIndexes(
    ignoredByMac = indexIgnoredDevices(ignored),
    watchedMacs = watched.mapTo(HashSet(watched.size)) { it.mac.lowercase() },
)

internal fun managedIndexSaysMuted(
    indexes: ManagedListIndexes,
    mac: String,
    ignoredRuleIsActive: (IgnoredDevice) -> Boolean,
): Boolean {
    val key = mac.lowercase()
    if (key in indexes.watchedMacs) return false
    return indexes.ignoredByMac[key]?.let(ignoredRuleIsActive) == true
}

/** A wire row typed WATCHED records how the board classified it when captured; only membership in
 * the phone's current watchlist may outrank a current mute. */
internal fun activeProjectionIncludes(
    mac: String,
    isCurrentlyWatched: Boolean,
    activeIgnoredMacs: Set<String>,
): Boolean = isCurrentlyWatched || mac.lowercase() !in activeIgnoredMacs

/** The board protocol reports only a count for rules created by another phone. Disclose the
 * unrepresented remainder without inventing MAC addresses or editable rows. */
internal fun unrepresentedBoardRuleCount(
    boardCount: Int,
    localBoardBackedCount: Int,
): Int = (boardCount - localBoardBackedCount).coerceAtLeast(0)

/** Sample detections temporarily replace the in-memory store, but must never mutate the retained
 * real log or its New watermark on disk. */
internal fun persistedLogMutationAllowed(demoMode: Boolean): Boolean = !demoMode

internal enum class ManagedListEditMode { PREVIEW_ONLY, LOADING_FAIL_CLOSED, DURABLE }

/** A real edit is not allowed to snapshot either list until the paired encrypted load completed. */
internal fun managedListEditMode(demoMode: Boolean, listsReady: Boolean): ManagedListEditMode = when {
    demoMode -> ManagedListEditMode.PREVIEW_ONLY
    !listsReady -> ManagedListEditMode.LOADING_FAIL_CLOSED
    else -> ManagedListEditMode.DURABLE
}

/** A truly absent list is a valid empty list; present bytes are authoritative only if they open
 * and parse. A present-but-unreadable encrypted blob must be preserved for a later recovery. */
internal fun storedManagedListIsAuthoritative(
    storedPresent: Boolean,
    decodedSuccessfully: Boolean,
): Boolean = !storedPresent || decodedSuccessfully

/** One process-wide ordering boundary for managed-list edits. The persistence operation itself is
 * synchronous, so keeping build -> durable write -> install -> board reconciliation under this
 * monitor means a later tap can never overtake an older one or push a generation that is not the
 * exact generation on disk. Kept platform-free so the race is deterministic in local JVM tests. */
internal class ManagedListEditSerializer {
    private val monitor = Any()
    private var generation = 0L

    fun <T> serialized(block: (generation: Long) -> T): T = synchronized(monitor) {
        generation += 1L
        block(generation)
    }

    fun currentGeneration(): Long = synchronized(monitor) { generation }
    fun isCurrent(expected: Long): Boolean = synchronized(monitor) { generation == expected }

    /** Serialize board acknowledgements with edits without manufacturing a new edit generation.
     * In particular, an ACK for an older empty list must not retire the write-ahead clear intent
     * while a newer empty generation is committing on another thread. */
    fun <T> withLock(block: () -> T): T = synchronized(monitor) { block() }
}

/** Retires an older startup/exit-demo decode before it can install over a newer reload or edit. */
internal class ManagedListLoadGate {
    private val generation = AtomicLong(0L)
    fun beginLoad(): Long = generation.incrementAndGet()
    fun accepts(token: Long): Boolean = generation.get() == token
}

/** Durable write-ahead clear intent. A failed retirement remains pending in this process even
 * though SharedPreferences.commit() may already have changed its in-memory map; later STATUS
 * acknowledgements retry until commit + exact readback confirm the disk transition. */
internal class ManagedListClearIntent(
    private val readStored: () -> Boolean,
    private val writeStored: (Boolean) -> Boolean,
) {
    private fun readStoredSafely(): Boolean = runCatching(readStored).getOrDefault(true)

    private val pendingInProcess = AtomicBoolean(readStoredSafely())

    val isPending: Boolean get() = pendingInProcess.get() || readStoredSafely()

    fun adoptDurableState(pending: Boolean) {
        pendingInProcess.set(pending)
    }

    fun retire(): Boolean {
        val retired = runCatching { writeStored(false) }.getOrDefault(false) &&
            !readStoredSafely()
        if (retired) {
            pendingInProcess.set(false)
            return true
        }
        pendingInProcess.set(true)
        return false
    }
}

/** Apply a managed-list generation only after its persistence callback confirms durability.
 * Returning false deliberately performs neither the visible install nor board reconciliation. */
internal fun <T> applyDurableManagedListEdit(
    candidate: T,
    persist: (T) -> Boolean,
    isStillCurrent: () -> Boolean = { true },
    install: (T) -> Unit,
    reconcileBoard: (T) -> Unit,
): Boolean {
    if (!runCatching { persist(candidate) }.getOrDefault(false)) return false
    // A synchronous preference listener can re-enter the edit API on this same thread. Java
    // monitors are reentrant, so the serializer's generation check is what prevents the older
    // outer callback from installing/pushing after the nested newer generation has committed.
    if (!isStillCurrent()) return false
    install(candidate)
    reconcileBoard(candidate)
    return true
}

internal fun performConfirmedPersistedDetectionDeletion(
    fileExists: () -> Boolean,
    remove: () -> Unit,
): Boolean {
    if (!fileExists()) return true
    return try {
        remove()
        !fileExists()
    } catch (_: Throwable) {
        !fileExists()
    }
}

internal enum class PersistedDetectionClearCommit {
    DURABLE_TOMBSTONE, CONFIRMED_DELETION, UNAVAILABLE,
}

/** A visible Clear needs either a synchronously committed recovery intent or confirmed absence. */
internal fun preparePersistedDetectionClear(
    armTombstone: () -> Boolean,
    deleteSynchronously: () -> Boolean,
): PersistedDetectionClearCommit = when {
    armTombstone() -> PersistedDetectionClearCommit.DURABLE_TOMBSTONE
    deleteSynchronously() -> PersistedDetectionClearCommit.CONFIRMED_DELETION
    else -> PersistedDetectionClearCommit.UNAVAILABLE
}

internal fun persistedDetectionClearMayResetMemory(
    commit: PersistedDetectionClearCommit,
): Boolean = commit != PersistedDetectionClearCommit.UNAVAILABLE

/** Retirement is the write-unblock boundary. Confirmed deletion is insufficient while an older
 * visible store still needs its generation-paired reset. */
internal fun persistedDetectionClearMayRetire(
    deletionConfirmed: Boolean,
    visibleResetPending: Boolean,
    initiatingResetInProgress: Boolean = false,
): Boolean = deletionConfirmed && !visibleResetPending && !initiatingResetInProgress

internal fun persistedDetectionClearRetryMayOwnCompletion(
    initiatingResetInProgress: Boolean,
): Boolean = !initiatingResetInProgress

/** Establish the in-memory half of Clear before publishing its tombstone. A retry may observe the
 * tombstone as soon as [armTombstone] returns, so reset-pending must already be true at that point. */
internal fun beginPersistedDetectionClearBoundary(
    markVisibleResetPending: () -> Unit,
    invalidateDecodedLoads: () -> Unit,
    advanceWriteGeneration: () -> Unit,
    armTombstone: () -> Boolean,
): Boolean {
    markVisibleResetPending()
    invalidateDecodedLoads()
    advanceWriteGeneration()
    return armTombstone()
}

/** Process-death-safe Clear intent with an in-process fail-closed mirror for failed commits. */
internal class PersistedDetectionClearTombstone(
    private val readStored: () -> Boolean,
    private val storePending: () -> Boolean,
    private val removeStored: () -> Boolean,
) {
    private val pendingInProcess = AtomicBoolean(runCatching(readStored).getOrDefault(true))

    val isPending: Boolean
        get() = pendingInProcess.get() || runCatching(readStored).getOrDefault(true)

    fun arm(): Boolean {
        pendingInProcess.set(true)
        return runCatching { storePending() && readStored() }.getOrDefault(false)
    }

    /** A failed retirement is re-armed and remains an in-process write/load barrier. */
    fun retire(): Boolean {
        val retired = runCatching { removeStored() && !readStored() }.getOrDefault(false)
        if (retired) {
            pendingInProcess.set(false)
            return true
        }
        pendingInProcess.set(true)
        runCatching { storePending() }
        return false
    }
}

internal class PersistedDetectionLoadGate {
    private val generation = AtomicLong(0L)
    fun beginLoad(): Long = generation.incrementAndGet()
    fun invalidate() { generation.incrementAndGet() }
    fun accepts(token: Long): Boolean = generation.get() == token
}

internal fun persistedDetectionSnapshotMayWrite(
    snapshotGeneration: Long,
    currentGeneration: Long,
    clearPending: Boolean,
): Boolean = !clearPending && snapshotGeneration == currentGeneration

private const val DETECTION_CLEAR_PENDING_KEY = "detectionClearPending"

private data class PersistedDetectionClearCompletion(
    val resetCompleted: Boolean,
    val tombstoneRetired: Boolean,
)

/** Accuracy policy for a binary HERE decision. Missing, negative, non-finite, or wider-than-rule
 * uncertainty fails closed even when the fix is recent. */
internal fun positionSupportsHere(position: MutePosition?, radiusMeters: Double): Boolean {
    val accuracy = position?.horizontalAccuracyMeters ?: return false
    return radiusMeters.isFinite() && radiusMeters > 0.0 &&
        validCoord(position.coord.first, position.coord.second) &&
        accuracy.isFinite() && accuracy >= 0.0 && accuracy <= radiusMeters
}

/** Only rules with no time or place boundary are safe to persist on the board. */
internal fun isBoardBackedMute(item: IgnoredDevice): Boolean =
    item.expiresAt == null && item.latitude == null && item.longitude == null

private val BOARD_MAC_SHAPE = Regex("^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")

/** The one MAC shape a managed-list entry may take: six lowercase hex octets, colon separated.
 * That is exactly what the firmware emits (acabFormatMac in detection.h) and what its parseMac6
 * accepts on the way back in. `mac` is decoded off the wire as free text (see the
 * spreadsheetSafeText note in the CSV export), so anything else is a rule the phone would show as
 * applied while the BOARD silently dropped it: the device keeps buzzing, the two sides can never
 * agree on a count again, and that is exactly the divergence MAX_LIST_PUSH_ATTEMPTS then has to
 * give up on. Callers must lowercase first.
 *
 * iOS twin: isBoardPushableMac in BLEManager.swift, same rule and the same three call sites
 * (ignoreDevice, ignoreDevices, watchDevice). */
internal fun isBoardPushableMac(mac: String): Boolean = BOARD_MAC_SHAPE.matches(mac)

/** Pure mute policy. Android's platform distance calculation is injected so JVM tests can pin
 * the fail-closed states without calling an android.jar stub. */
internal fun evaluateMuteRule(
    item: IgnoredDevice,
    now: Long,
    currentPosition: MutePosition?,
    distanceMeters: (Pair<Double, Double>, Pair<Double, Double>) -> Double,
): MuteRuleStatus {
    if (item.expiresAt?.let { it <= now } == true) return MuteRuleStatus.EXPIRED
    if (!item.isPlaceRule) return MuteRuleStatus.ACTIVE
    val lat = item.latitude
    val lon = item.longitude
    if (!validCoord(lat, lon) || !item.radiusMeters.isFinite() || item.radiusMeters <= 0.0) {
        return MuteRuleStatus.INVALID_PLACE
    }
    val here = currentPosition
    if (!positionSupportsHere(here, item.radiusMeters)) {
        return MuteRuleStatus.CURRENT_LOCATION_REQUIRED
    }
    val distance = distanceMeters(here!!.coord, lat!! to lon!!)
    if (!distance.isFinite() || distance < 0.0) return MuteRuleStatus.INVALID_PLACE
    return if (distance <= item.radiusMeters) MuteRuleStatus.ACTIVE
    else MuteRuleStatus.OUTSIDE_RADIUS
}

/** Reconciliation action for the board-backed permanent-mute list. In particular, a phone with
 * no permanent rows is not authoritative over a nonempty board unless this phone remembers an
 * explicit user deletion. */
internal enum class BoardIgnoreSyncAction { NONE, PUSH_LIST, PUSH_CLEAR, ACK_CLEAR }

internal fun boardIgnoreSyncAction(
    localPermanentCount: Int,
    boardReportedCount: Int?,
    intentionalClearPending: Boolean,
): BoardIgnoreSyncAction = when {
    localPermanentCount > 0 &&
        (boardReportedCount == null || boardReportedCount != localPermanentCount) ->
        BoardIgnoreSyncAction.PUSH_LIST
    localPermanentCount > 0 -> BoardIgnoreSyncAction.NONE
    intentionalClearPending && boardReportedCount == 0 -> BoardIgnoreSyncAction.ACK_CLEAR
    intentionalClearPending -> BoardIgnoreSyncAction.PUSH_CLEAR
    else -> BoardIgnoreSyncAction.NONE
}

/** A device the user has starred to watch: the board alerts on this exact MAC every time it's
 *  seen, even with no built-in signature match. The inverse of an IgnoredDevice. */
data class WatchedDevice(val mac: String, val label: String)

/** The detection CSV's columns, in order. Byte-identical to iOS's header, which is why it moves in
 *  the same commit or not at all.
 *
 *  Top-level rather than inline in [AcabBleManager.detectionsCsv] because the redaction policy in
 *  ContributionCsv.kt names these columns as STRINGS: OBSERVER/DRONE/OPERATOR_LOCATION_COLS have to
 *  match the emitter exactly or a coordinate the disclosure says was removed ships under its new
 *  name. With one shared list, ContributionCsvTest pins the two against each other instead of
 *  against a hand-copied fixture that a rename would leave green.
 *
 *  iOS twin: ContributionCsv.detectionColumns, which BLEManager.buildCSV joins for its header the
 *  same way detectionsCsv does here.
 *
 *  `maker` is appended LAST so an existing parser keyed on column order still reads every field it
 *  knew about. */
internal val DETECTION_CSV_COLUMNS: List<String> = listOf(
    "detected_at", "time_basis", "time_precision_s", "type", "mac", "rssi",
    "source", "matched_on", "confidence", "sightings", "approx_lat", "approx_lon",
    "company_id", "uas_id", "drone_lat", "drone_lon", "altitude_m", "speed_ms",
    "heading_deg", "height_agl_m", "operator_lat", "operator_lon", "operator_alt_m",
    "rid_status", "maker",
)

/** The aircraft and operator coordinates a CSV row may export, after the type gate. Null means the
 *  column is blank. */
internal data class DroneExportCoords(
    val droneLat: Double?,
    val droneLon: Double?,
    val operatorLat: Double?,
    val operatorLon: Double?,
)

/** THE TYPE GATE, and it is LOAD-BEARING (added 2026-08-05, fixing a real export defect).
 *
 *  `lat`/`lon` on the wire is OVERLOADED: the `lat`,`lon` row of ble-protocol.md's detection-frame
 *  table defines it as "drones = the aircraft's own broadcast position; everything else = the
 *  DETECTOR's GPS". Cited by FIELD, not by line number: the "line 88" pointer this replaces had
 *  drifted off the row it named, which is what every line-number citation eventually does to the
 *  one warning this whole gate depends on. Without this gate every non-drone row copied the
 *  PHONE's own position into drone_lat/drone_lon. Measured on a real 2747-row export: 2746 of 2746
 *  non-drone rows carried a bogus drone position, 555 of them byte-identical to that row's own
 *  approx_lat/lon. Anything reading the drone columns (a GPX/KML export, a map layer) would plot
 *  thousands of phantom aircraft.
 *
 *  Operator coords ride the same gate. Per ble-protocol.md's `plat`,`plon` row they are drone-only
 *  anyway, so that half is belt-and-braces rather than a second bug fixed, but the two column pairs
 *  must stand or fall together or a row could export an operator position with no aircraft. Coords
 *  go through validCoord so a 0,0 blanks. Kept byte-identical to iOS's CSV writer; extracted here
 *  so both platforms' suites can pin it (AcabBleManagerExportTest, ExportTests.swift). */
internal fun droneExportCoords(d: Detection): DroneExportCoords {
    if (d.type != DeviceType.DRONE) return DroneExportCoords(null, null, null, null)
    val aircraft = d.lat != null && d.lon != null && validCoord(d.lat, d.lon)
    val operator = d.pilotLat != null && d.pilotLon != null && validCoord(d.pilotLat, d.pilotLon)
    return DroneExportCoords(
        droneLat = if (aircraft) d.lat else null,
        droneLon = if (aircraft) d.lon else null,
        operatorLat = if (operator) d.pilotLat else null,
        operatorLon = if (operator) d.pilotLon else null,
    )
}

/**
 * Drives the link to an OUI-Spy board: scan by service UUID, connect, bond (the GATT
 * service is encrypted), subscribe to the detection + status notifies, parse, and
 * write config. Android's BLE stack only does one op at a time, so the connect steps
 * are chained through the callbacks. Permissions are the caller's job - the UI asks
 * for SCAN/CONNECT before any of this runs.
 */
@SuppressLint("MissingPermission")
class AcabBleManager(private val context: Context) {

    private val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE)
            as BluetoothManager).adapter
    private val scanner get() = adapter?.bluetoothLeScanner

    private val _state = MutableStateFlow(ConnState.DISCONNECTED)
    val state: StateFlow<ConnState> = _state.asStateFlow()

    private val _found = MutableStateFlow<List<FoundBoard>>(emptyList())
    val found: StateFlow<List<FoundBoard>> = _found.asStateFlow()

    private val _scanHint = MutableStateFlow<String?>(null)
    val scanHint: StateFlow<String?> = _scanHint.asStateFlow()

    private val _detections = MutableStateFlow<List<Detection>>(emptyList())
    val detections: StateFlow<List<Detection>> = _detections.asStateFlow()
    /** Evidence/log projection. Unlike [detections], active mute rules do not remove prior rows. */
    private val _logDetections = MutableStateFlow<List<Detection>>(emptyList())
    val logDetections: StateFlow<List<Detection>> = _logDetections.asStateFlow()

    private val _status = MutableStateFlow<DeviceStatus?>(null)
    val status: StateFlow<DeviceStatus?> = _status.asStateFlow()

    private val _deviceName = MutableStateFlow<String?>(null)
    val deviceName: StateFlow<String?> = _deviceName.asStateFlow()

    private val _demoMode = MutableStateFlow(false)
    val demoMode: StateFlow<Boolean> = _demoMode.asStateFlow()

    // True once we've confirmed the connected board exposes the acab0104 OTA characteristic.
    // Released 1.7 boards do NOT have it, so in-app OTA is gated on this runtime check.
    private val _otaCapable = MutableStateFlow(false)
    val otaCapable: StateFlow<Boolean> = _otaCapable.asStateFlow()

    // The live OTA state machine, collected by the FirmwareCard.
    private val _otaProgress = MutableStateFlow(OtaProgress())
    val otaProgress: StateFlow<OtaProgress> = _otaProgress.asStateFlow()

    // nRF co-processor DFU: a self-contained coordinator (its own scan + the Nordic DFU library).
    // It reaches back for two things only: the trigger write, and the live status for the post-
    // flash version confirm. The S3 link stays up the whole time; the DFU library talks to AdaDFU
    // on a separate connection.
    private val nrfDfu by lazy {
        NrfDfuCoordinator(
            context = context,
            adapter = adapter,
            scope = scope,
            sendTrigger = { writeConfig(JSONObject().put("nrfdfu", true)) },
            requestStatus = { readStatus() },
            statusProvider = { _status.value },
            // Never let a co-processor DFU start on top of a live S3 OTA (both drive the radio).
            otaInProgress = {
                val p = _otaProgress.value.phase
                p != OtaPhase.IDLE && p != OtaPhase.DONE && p != OtaPhase.FAILED
            },
            linkSessionProvider = { connectGen.toLong() },
            linkReady = { gatt != null && _state.value == ConnState.READY },
            statusRevisionProvider = { statusRevision.get() },
            protectedHoldReady = { driveServiceActive },
        )
    }

    // One-click combined update: a single "Update" flow that runs the nRF leg first while the
    // physical-start authorization is live, then S3, merging both progress streams onto one bar. It
    // COMPOSES the two engines above (it re-implements no transfer) and holds the foreground service
    // across BOTH legs (HOLD_COMBINED), since the S3 OTA releases its own hold on its DONE.
    @Volatile private var combinedHoldingService = false
    private val combinedDelegate = lazy {
        CombinedUpdateCoordinator(
            otaProgress = _otaProgress.asStateFlow(),
            nrfProgress = nrfDfu.progress,
            status = _status.asStateFlow(),
            otaCapable = _otaCapable.asStateFlow(),
            startS3 = { startOta(it, reuseConfirmedCombinedHold = true) },
            cancelS3 = { cancelOta() },
            canCancelS3 = { otaCancellableNow() },
            dismissS3 = { clearOtaResult() },
            startNrf = { nrfDfu.startUpdate(it) },
            cancelNrf = { nrfDfu.cancel() },
            dismissNrf = { nrfDfu.dismiss() },
            nrfUpdateAvailable = { nrfDfu.updateAvailable(it) },
            rereadStatus = { refreshStatus() },
            acquireHold = {
                val accepted = runCatching {
                    AcabLinkService.start(context, AcabLinkService.HOLD_COMBINED)
                }.getOrDefault(false)
                if (accepted) combinedHoldingService = true
                accepted
            },
            holdReady = { driveServiceActive },
            releaseHold = {
                combinedHoldingService = false
                runCatching { AcabLinkService.stop(context, AcabLinkService.HOLD_COMBINED) }
                Unit
            },
        )
    }
    private val combined by combinedDelegate
    val combinedProgress: StateFlow<CombinedUpdateProgress> get() = combined.progress
    /** Either radio is behind: drives whether the single "Update" button is offered. */
    fun combinedUpdateStale(build: FirmwareBuild): Boolean = combined.updateStale(build)
    /** The BOARD firmware specifically is behind. The card needs this separately from
     *  [combinedUpdateStale] so it can name what is actually stale: an offer driven only by the
     *  co-processor used to read "Update available: v2.0.4" while the board already ran 2.0.4. */
    fun s3UpdateStale(build: FirmwareBuild): Boolean = combined.s3UpdateStale(build)
    fun startCombinedUpdate(build: FirmwareBuild) = combined.start(build)
    fun cancelCombinedUpdate() = combined.cancel()
    fun dismissCombinedUpdate() = combined.dismiss()

    private val _ignored = MutableStateFlow<List<IgnoredDevice>>(emptyList())
    val ignored: StateFlow<List<IgnoredDevice>> = _ignored.asStateFlow()
    private val managedListEdits = ManagedListEditSerializer()
    // False until BOTH encrypted lists have been decoded and atomically installed. Also lowered
    // before exitDemo exposes real-mode APIs while its IO reload is pending. A Settings action is
    // independent of the detection feed, so relying on that feed's load join did not gate edits.
    @Volatile private var managedListsReady = false
    private val managedListLoadGate = ManagedListLoadGate()
    @Volatile private var managedListIndexes = ManagedListIndexes(emptyMap(), emptySet())
    // Location.distanceBetween writes into its result array. Keep one scratch per callback thread
    // instead of allocating an array for every record or serializing unrelated BLE/UI callers.
    private val muteDistanceScratch = ThreadLocal.withInitial { FloatArray(1) }
    private val muteDistanceMeters:
        (Pair<Double, Double>, Pair<Double, Double>) -> Double = { here, center ->
            val result = muteDistanceScratch.get() ?: FloatArray(1).also(muteDistanceScratch::set)
            Location.distanceBetween(here.first, here.second, center.first, center.second, result)
            result[0].toDouble()
        }

    private val _watched = MutableStateFlow<List<WatchedDevice>>(emptyList())
    val watched: StateFlow<List<WatchedDevice>> = _watched.asStateFlow()

    // "Mark all seen" baseline: the firstSeen timestamp at the moment the user tapped it.
    // The Log's "New only" view shows detections first heard after this point. Persisted so
    // the watermark survives an app restart.
    private val _seenWatermark = MutableStateFlow(0L)
    val seenWatermark: StateFlow<Long> = _seenWatermark.asStateFlow()
    // Buffered records the board had no clock for are stamped on their own descending axis
    // (see fileHistory), which sits permanently below any wall clock. They need their own
    // baseline: compared against the live watermark, one live sighting marks every buffered
    // row seen at once and no buffered row can ever read as new again.
    //
    // The axis runs BACKWARDS: the stamp is HIST_PSEUDO_BASE - seq*1000 and seq ascends with
    // recording order, so a MORE RECENT record has a SMALLER stamp. Newer means less-than here,
    // and the baseline is the smallest stamp seen, not the largest. Starts at the base (nothing
    // marked seen yet) so a first drain reads as new rather than as already-read.
    private var approxWatermark = HIST_PSEUDO_BASE

    // ---- offline-log replay UX ----
    // True from the moment a reconnect requests the buffer replay (sendHandshake) until the
    // board's end sentinel lands (onHistEnd). Drives the subtle "syncing offline log…" pill.
    private val _syncingOfflineLog = MutableStateFlow(false)
    val syncingOfflineLog: StateFlow<Boolean> = _syncingOfflineLog.asStateFlow()

    // Running count of records filed during the current drain, so the pill can climb live.
    private val _offlineSyncCount = MutableStateFlow(0)
    val offlineSyncCount: StateFlow<Int> = _offlineSyncCount.asStateFlow()

    // Total for the current drain, from {"hist":"begin","n":N} (0 = unknown). Lets the pill show
    // a determinate "X of N" instead of just a climbing count.
    private val _offlineSyncTotal = MutableStateFlow(0)
    val offlineSyncTotal: StateFlow<Int> = _offlineSyncTotal.asStateFlow()

    // One-shot: the total the board reported at replay-complete, but ONLY when it was > 0.
    // Non-null raises the transient "N detections recorded while you were away" banner; the UI
    // clears it back to null on view/dismiss/navigate. In-memory only, so it never survives a
    // relaunch.
    private val _offlineSyncBanner = MutableStateFlow<Int?>(null)
    val offlineSyncBanner: StateFlow<Int?> = _offlineSyncBanner.asStateFlow()

    // One-shot beside the banner: records the board PROMISED ({"hist":"begin","n"}) but did not
    // SEND in this attempt ({"hist":"end","n"}). A record past notifyCap() now blocks the drain
    // without committing that row, so it remains in the ring for a later sync from a larger-MTU
    // peer or corrected schema. This is an attempt-level disclosure, surfaced in the banner and
    // cleared with it. ble-protocol.md, "Why the replay check needs all three numbers".
    private val _offlineSyncUnreplayed = MutableStateFlow(0)
    val offlineSyncUnreplayed: StateFlow<Int> = _offlineSyncUnreplayed.asStateFlow()

    // Bumped whenever histTime changes for rows already on screen, which is the end of a drain,
    // where bracketing turns a pile of "time unknown" rows into bounded ones. timeBasis() is a
    // plain map read, so a screen holding one has no way to learn it went stale; this gives it a
    // key to recompose on. The detection feed alone won't do: those rows were published minutes
    // earlier and their content doesn't change when the basis is resolved.
    private val _timeBasisRev = MutableStateFlow(0)
    val timeBasisRev: StateFlow<Int> = _timeBasisRev.asStateFlow()

    private val _alertMode = MutableStateFlow(AlertMode.BUZZER)
    val alertMode: StateFlow<AlertMode> = _alertMode.asStateFlow()

    private val _driveMode = MutableStateFlow(false)
    val driveMode: StateFlow<Boolean> = _driveMode.asStateFlow()
    val driveModeOn: Boolean get() = _driveMode.value
    private val _driveModeWanted = MutableStateFlow(true)
    val driveModeWanted: StateFlow<Boolean> = _driveModeWanted.asStateFlow()

    /** Per-category phone notifications (see DetectionNotifier). Independent of alertMode. */
    val notifier = DetectionNotifier(context)

    // Hide detection counts on the lock screen (user setting, default OFF: counts are visible
    // unless the user turns redaction on; a stored choice always wins over the default). The app
    // always shows the full breakdown. Loaded from prefs in init.
    //
    // SCOPE. On Android this switch reaches THREE surfaces: the Live Mode notification
    // (AcabLinkService.build -> VISIBILITY_PRIVATE + buildPublic), the Android 16 promoted chip
    // (AcabLinkService.shortCriticalText, which drops the count locked OR not, because the chip
    // sits in the status bar either way), and per-detection alerts (DetectionNotifier's own public
    // version, which replaces the category with "Something was detected nearby."). Erring private
    // is the deliberate direction for this product, so the copy widened to name all three rather
    // than the behaviour narrowing: DeviceScreen's toggle subtitle now says so. iOS scopes its
    // same-named toggle to the Live Activity only, which is why the iOS subtitle reads narrower -
    // that is a real behaviour difference, deliberately left as the quieter platform winning.
    //
    // Four places point HERE for that scope, so keep this block on the declaration when editing:
    // setRedactLockScreen's KDoc and the fileLive notify block in this file, DeviceScreen's toggle
    // subtitle comment, and SettingsView.swift's Live Activity note.
    private val _redactLockScreen = MutableStateFlow(false)
    val redactLockScreen: StateFlow<Boolean> = _redactLockScreen.asStateFlow()

    private val prefs = context.getSharedPreferences("acab", Context.MODE_PRIVATE)
    private fun newManagedListClearIntent(key: String) = ManagedListClearIntent(
        readStored = { prefs.getBoolean("${key}_clear_pending", false) },
        writeStored = { pending ->
            prefs.edit().putBoolean("${key}_clear_pending", pending).commit() &&
                prefs.getBoolean("${key}_clear_pending", !pending) == pending
        },
    )
    private val ignoreClearIntent = newManagedListClearIntent("ignore")
    private val watchClearIntent = newManagedListClearIntent("watch")

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION") context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    private val notificationManager: NotificationManager? by lazy {
        context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
    }

    private val locationManager: LocationManager? by lazy {
        context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
    }

    /** Location is process-owned because Drive mode deliberately outlives MainActivity. The old
     * Activity ViewModel listener was removed with its task, leaving the foreground service alive
     * but every fix after two minutes rejected as stale. Registration is now need-gated: a visible
     * live link, or a Drive service that has actually entered the foreground. */
    @Volatile private var locationPermissionGranted = hasLocationPermission()
    @Volatile private var locationUpdatesRegistered = false
    /** Serializes register/unregister so the pair can never interleave. Private, so it does not
     *  share a monitor with the GATT op queue; see syncLocationOwnership. */
    private val locationLock = Any()
    /** Bumped under [locationLock] on every ownership transition, in both directions. The seed
     *  replay that runs after the lock is dropped carries the value it registered under, so a
     *  release that landed in the gap retires the seeds instead of being undone by them.
     *  Guarded by [locationLock] alone, so it needs no volatility of its own. */
    private var locationOwnershipGeneration = 0L
    @Volatile private var driveServiceActive = false
    val driveServiceReady: Boolean get() = driveServiceActive
    private val ownedLocationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val nowNanos = SystemClock.elapsedRealtimeNanos()
            val age = nowNanos - location.elapsedRealtimeNanos
            if (age in 0..FIX_MAX_AGE_NANOS && validCoord(location.latitude, location.longitude)) {
                val fix = TimedCoord(
                    location.latitude to location.longitude,
                    location.elapsedRealtimeNanos,
                    if (location.hasAccuracy()) location.accuracy.toDouble() else null,
                )
                lastMuteFix = fix
                fixCacheAt = nowNanos
                fixCache = fix
                setLocation(location.latitude, location.longitude)
            }
        }
        override fun onProviderEnabled(provider: String) { syncLocationOwnership() }
        override fun onProviderDisabled(provider: String) {}
        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
    }

    // Short-lived cache of the platform's last known fix (see freshSelfCoord).
    @Volatile private var fixCacheAt = 0L
    @Volatile private var fixCache: TimedCoord? = null
    @Volatile private var lastMuteFix: TimedCoord? = null

    /** True when a Focus or Do Not Disturb is on, so vibrate alerts stay quiet.
     *  Reading the filter needs no permission; if we can't read it, just alert. */
    private fun focusSuppressed(): Boolean = when (notificationManager?.currentInterruptionFilter) {
        NotificationManager.INTERRUPTION_FILTER_PRIORITY,
        NotificationManager.INTERRUPTION_FILTER_NONE,
        NotificationManager.INTERRUPTION_FILTER_ALARMS -> true
        else -> false   // ALL, UNKNOWN, or null: alert as usual
    }

    // ---- phone Bluetooth radio (adapter) tracking ----
    // Android watched only bond state before, so toggling the radio stranded the connect screen
    // (a dead Scan button) with no recovery short of a cold launch. Mirror iOS: fall to
    // POWERED_OFF when the radio dies, auto-recover (with an opportunistic rescan) when it returns.
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)) {
                BluetoothAdapter.STATE_OFF -> onRadioOff()
                BluetoothAdapter.STATE_ON -> onRadioOn()
            }
        }
    }

    // A reconnect intent carried across a phone-radio cycle. The pending autoConnect client
    // itself cannot survive the radio dying (nothing completes on a dead adapter, so onRadioOff
    // must close it), but iOS preserves reconnectTarget across .poweredOff and re-arms the
    // pending connect on .poweredOn - while a plain teardown here left the same board stranded
    // at DISCONNECTED, no scan and no pending connect, until the user reopened the app and
    // re-tapped it. Captured in onRadioOff before cleanup() nulls target; consumed in onRadioOn.
    @Volatile private var radioRestoreTarget: BluetoothDevice? = null
    @Volatile private var radioRestoreName: String? = null

    private fun onRadioOff() {
        // The radio is gone: the GATT link is dead and the scanner is unusable. Tear down like a
        // disconnect, then force POWERED_OFF so a race with the GATT-disconnect callback can't
        // leave us stranded on the plain scan screen.
        scanGen++   // invalidate any pending scan timeout/retry from the dead radio's session
        scanPausedInBackground = false
        // A pending auto-reconnect was chasing the board when the radio died: remember the
        // intent (the iOS reconnectTarget analog) so onRadioOn can re-arm it. Only the
        // auto-reconnect's own client qualifies - a fresh scan-connect falls back to the scan
        // screen like iOS, and the OTA reconnect loop paces itself through the radio cycle.
        radioRestoreTarget = if (reconnectClientArmed) target else null
        radioRestoreName = if (radioRestoreTarget != null) _deviceName.value else null
        cleanup()
        _state.value = ConnState.POWERED_OFF
    }

    private fun onRadioOn() {
        if (!hasScanPermission() || !hasConnectPermission()) {
            teardownForBluetoothPermissionRevocation()
            return
        }
        // Radio's back. A reconnect that was pending when it died is re-armed first, mirroring
        // iOS centralManagerDidUpdateState's .poweredOn reconnectTarget branch; without this a
        // Bluetooth toggle or airplane-mode hop mid-chase left the app at DISCONNECTED until a
        // manual re-tap. Deliberately NOT foreground-gated: the reconnect it restores runs
        // backgrounded too, exactly like the one the radio killed.
        val restore = radioRestoreTarget
        val restoreName = radioRestoreName
        radioRestoreTarget = null; radioRestoreName = null
        if (restore != null && _state.value == ConnState.POWERED_OFF) {
            autoReconnect(restore, restoreName)
            return
        }
        // Otherwise leave a live session alone; land on the scan screen and, when we're allowed
        // to scan, kick one off so the board reappears without a manual tap.
        if (_state.value == ConnState.CONNECTING && gatt == null) {
            // Stranded connect with no client that can ever call back (the OTA reconnect loop
            // gave up while the radio was off, or connectGatt returned null on a dead adapter):
            // no callback will ever fire, so recover to the scan screen here.
            _state.value = ConnState.DISCONNECTED
            if (appForegrounded && hasScanPermission() && hasConnectPermission()) startScan()
            return
        }
        if (_state.value != ConnState.POWERED_OFF) return
        _state.value = ConnState.DISCONNECTED
        // Foreground only, and debounced: a background radio flap must not light up a
        // LOW_LATENCY scan nobody is looking at, and rapid toggles must not burn the
        // platform's 5-scan-starts-per-30s budget.
        if (appForegrounded && hasScanPermission() && hasConnectPermission() &&
            SystemClock.elapsedRealtime() - lastScanStartAt > SCAN_RESTART_DEBOUNCE_MS) startScan()
    }

    /** Resting (not-connected) state for the current radio: the scan screen when it's on, the
     *  "Bluetooth is off" screen when it isn't. */
    private fun restingState(): ConnState =
        if (!hasScanPermission() || !hasConnectPermission()) ConnState.DISCONNECTED
        else if (runCatching { adapter?.isEnabled == true }.getOrDefault(false)) {
            ConnState.DISCONNECTED
        } else ConnState.POWERED_OFF

    /** Whether we hold the permission a scan needs (SCAN on 12+, else fine location), so an
     *  auto-rescan on radio-recovery never trips a SecurityException. */
    private fun hasScanPermission(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_SCAN) ==
                PackageManager.PERMISSION_GRANTED
        else
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED

    private fun hasConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.BLUETOOTH_CONNECT) ==
                PackageManager.PERMISSION_GRANTED

    /** BluetoothDevice getters became permission-gated on Android 12. They are best-effort display
     * metadata, so a revocation race must not crash a scan or reconnect callback. */
    private fun safeDeviceName(device: BluetoothDevice): String? =
        runCatching { device.name }.getOrNull()

    private fun safeDeviceAddress(device: BluetoothDevice): String? =
        runCatching { device.address }.getOrNull()

    init {
        // The ignore/watch lists are deliberately NOT loaded here. They are sealed with the same
        // Keystore key as the detection log, so opening one is binder IPC into keystore2 plus an
        // AES-GCM decrypt, and this constructor runs on the main thread (AcabViewModel's
        // `val ble = getInstance(app)` is a property initializer, and AcabLinkService resolves the
        // same lazy from a main-thread service callback). They ride persistLoadJob instead, ahead
        // of the detections; see its declaration below. Everything from here down is plain
        // SharedPreferences reads.
        _alertMode.value = runCatching {
            AlertMode.valueOf(prefs.getString("alertMode", null) ?: "BUZZER")
        }.getOrDefault(AlertMode.BUZZER)
        // Default false = counts visible; getBoolean's default only applies when the user never
        // set the toggle, so an explicit stored choice (either way) is preserved.
        _redactLockScreen.value = prefs.getBoolean("redactLock", false)
        // The lock-screen Live Mode surface is opt-out. A stored false is still respected.
        _driveModeWanted.value = liveModeWanted(
            if (prefs.contains("liveModeWanted")) prefs.getBoolean("liveModeWanted", true) else null
        )
        _seenWatermark.value = prefs.getLong("seenWatermark", 0L)
        approxWatermark = prefs.getLong("approxWatermark", HIST_PSEUDO_BASE)
        // Track the phone's Bluetooth radio for the process lifetime so the connect screen can say
        // "Bluetooth is off" and auto-recover when it returns.
        // EXPORTED, not NOT_EXPORTED: ACTION_STATE_CHANGED is a system <protected-broadcast> only
        // the OS can send, and on API < 33 ContextCompat emulates NOT_EXPORTED by gating the
        // receiver behind our app-private DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION - which the
        // system Bluetooth process does not hold, so the broadcast is silently DENIED and the
        // radio-off/on screen never updates. Same root cause as the bond receiver below.
        ContextCompat.registerReceiver(
            context, adapterReceiver,
            IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED,
        )
        if (hasConnectPermission() &&
            !runCatching { adapter?.isEnabled == true }.getOrDefault(false)) {
            _state.value = ConnState.POWERED_OFF
        }
    }

    // Background scope for the coalesced detection-feed publisher. Survives the link's
    // lifecycle (it's a singleton); never torn down.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    init {
        // Keep the shared name registry in step with BOTH lists, reactively. Doing it here rather
        // than at each mutation site is deliberate: watched/ignored are assigned in ~10 places
        // (star, unstar, mute, unmute, bulk ignore, rename, disk load), and any one missed would
        // silently leave a stale or missing custom name in the log.
        combine(_watched, _ignored) { w, i ->
            w.map { it.mac to it.label } to i.map { it.mac to it.label }
        }.onEach { (w, i) ->
            tech.acab.app.model.DeviceNames.rebuild(w, i)
        }.launchIn(scope)
        // Expired mutes must reveal preserved evidence even if no new detection arrives. Timed
        // and place rules are phone-only; maintenance never makes their expiry authoritative over
        // an unknown board list.
        scope.launch {
            while (true) {
                delay(60_000L)
                val hasPlaceRule = _ignored.value.any { it.isPlaceRule }
                val pruned = pruneExpiredMutes()
                // A HERE rule can become inactive solely because its fix aged out, with no new
                // detection or location callback to trigger a projection. Re-evaluate it on the
                // same bounded maintenance cadence that already handles timed rules.
                if (hasPlaceRule && !pruned) publishNow()
            }
        }
    }

    // ---- app foreground tracking ----
    // A LOW_LATENCY scan must not keep running while the app is backgrounded ("tap Scan,
    // pocket the phone"): pause the radio scan on background, resume it on return. Tracked at
    // the PROCESS level (this manager is a singleton) rather than per-activity, so a rotation
    // doesn't kill the scan: the old activity stops around the new one starting, and the
    // debounce below rides across that gap (same idea as ProcessLifecycleOwner's ~700 ms).
    @Volatile private var appForegrounded = false
    @Volatile private var startedActivities = 0
    private var backgroundDebounceJob: Job? = null

    private val appLifecycle = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            startedActivities++
            backgroundDebounceJob?.cancel(); backgroundDebounceJob = null
            if (!appForegrounded) {
                appForegrounded = true
                onAppForeground()
            }
        }
        override fun onActivityStopped(activity: Activity) {
            startedActivities--
            if (startedActivities > 0) return
            backgroundDebounceJob?.cancel()
            backgroundDebounceJob = scope.launch {
                delay(BACKGROUND_DEBOUNCE_MS)
                if (startedActivities == 0) {
                    appForegrounded = false
                    onAppBackground()
                }
            }
        }
        override fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
        override fun onActivityResumed(activity: Activity) {}
        override fun onActivityPaused(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    /** Backgrounded with a scan running: stop the radio but keep _state at SCANNING and flag
     *  the pause, so the return to foreground restarts it seamlessly. The scan timeout keeps
     *  ticking; if it elapses while backgrounded, stopScan() clears the flag and nothing
     *  resumes - the window is spent either way. */
    private fun onAppBackground() {
        if (_state.value == ConnState.SCANNING && !scanPausedInBackground) {
            scanPausedInBackground = true
            runCatching { scanner?.stopScan(scanCb) }
        }
        syncLocationOwnership()
    }

    private fun onAppForeground() {
        scope.launch(Dispatchers.IO) {
            retryPendingDetectionClear(checkpointCurrentStoreOnSuccess = true)
        }
        if (scanPausedInBackground && _state.value == ConnState.SCANNING) beginScan()
        syncLocationOwnership()
    }

    // Coalesced detection-feed emission. A Desert-mode firehose can file hundreds of records
    // a second; pushing each one to the StateFlow would thrash Compose. Instead a dirty flag
    // is set on each file, and a single coroutine drains it at ~3 Hz (PUBLISH_INTERVAL_MS).
    private val publishDirty = AtomicBoolean(false)
    @Volatile private var publishPumpRunning = false

    private var gatt: BluetoothGatt? = null
    private var target: BluetoothDevice? = null
    private val store = LinkedHashMap<String, Detection>()
    private val firstSeenAt = HashMap<String, Long>()
    private val lastSeenAt = HashMap<String, Long>()
    private val rssiHistory = HashMap<String, MutableList<Int>>()
    private val capturedLoc = HashMap<String, Pair<Double, Double>>()
    private val contributionCapture = ContributionCaptureLedger()
    // Best (strongest) RSSI seen for each capturedLoc pin. RSSI is a distance proxy, so a
    // stronger later sighting is a better position estimate than the first: the pin migrates to
    // closest approach and this is the bar it has to beat (with hysteresis). Keyed/locked like
    // capturedLoc, and torn down wherever capturedLoc is.
    private val bestRssi = HashMap<String, Int>()
    private val trackHistory = HashMap<String, MutableList<Pair<Double, Double>>>()   // drone flight paths
    // Per-tracker breadcrumb of the PHONE's own path while a tracker stayed with us ("it followed
    // me across all these places"). Same shape as trackHistory, drawn as a DASHED trail. Throttled
    // by lastCrumbAt (time) AND distance so a stakeout doesn't pile crumbs on one spot.
    private val crumbHistory = HashMap<String, MutableList<Pair<Double, Double>>>()
    // The two ENDS of the crumb window, which is what the follow-evidence scorer measures its
    // duration across. firstCrumbAt is NOT firstSeenAt: firstSeenAt is when the device was first
    // HEARD and it survives an app restart in the persisted store, while crumbs start later (a
    // crumb needs a fresh fix, 60 s and 25 m) and die with the session. Scoring first-HEARD to
    // last-crumb narrated a duration the trail did not cover and let the band time floors be
    // satisfied by minutes with no crumbs in them at all. Written together, torn down together
    // (both are in perDeviceMaps below), read together by FollowEvidence.evaluate.
    private val firstCrumbAt = HashMap<String, Long>()
    private val lastCrumbAt = HashMap<String, Long>()
    // Time quality for rows whose FIRST sighting came off the offline buffer. A row absent here
    // was first heard live, so its stamp is this phone's own clock reading (TimeBasis.Exact) and
    // there is nothing to qualify. Keyed like the maps above and guarded by the same lock.
    private val histTime = HashMap<String, HistTime>()
    // Every map keyed by detection id, in one place. A device has to leave ALL of them together
    // or the leftovers leak and, worse, desync if the same id comes back (a stale bestRssi would
    // hold the pin at an old closest approach, a stale crumbHistory would draw a trail from a
    // previous session). Listing them once means a NEW side map can't be added to the class and
    // then missed at one of the teardown sites: eviction (evictKey) and the wholesale clears
    // (resetInMemoryLog, placeDemoDetections). The ignore paths are NOT teardown sites: muted
    // evidence stays sealed in the store and is suppressed at projection time.
    // Declared after the maps it names so they're all initialized by the time it builds.
    private val perDeviceMaps: List<MutableMap<String, *>> = listOf(
        store, firstSeenAt, lastSeenAt, histTime, rssiHistory,
        capturedLoc, bestRssi, trackHistory, crumbHistory, firstCrumbAt, lastCrumbAt,
    )
    // Per-boot bounds over the buffered records the board WAS able to date, in unix seconds.
    // Boot counters are monotonic (the firmware persists and increments gBoot every power-up), so
    // a boot the app never anchored can still be bounded by the anchored boots either side of it.
    // Rebuilt from the persisted log on reload and extended by every drain; guarded by storeLock
    // because the drain writes it from the BLE callback thread.
    private val bootMinAt = HashMap<Long, Long>()
    private val bootMaxAt = HashMap<Long, Long>()
    // Unanchored records filed during the CURRENT drain, resolved in one pass when the drain
    // closes (see resolveBrackets). Bracketing a record needs the whole batch, not just the
    // record, so it cannot be done on the filing path.
    // GUARDED BY storeLock, every access. This said "BLE-callback thread only", which was the
    // assumption that made an unguarded ArrayList look safe: the adds do come from the BLE
    // callback, but the clears run from the disconnect, clear-log and hist-resync paths, which
    // do not. There are five access sites; keep them all inside the monitor.
    private val pendingBracket = ArrayList<PendingBracket>()
    // Guards every mutation of the store and its side maps above. Ingest runs on the BLE
    // callback thread, but Clear-log and the ignore paths mutate the same maps from main, and
    // a HashMap being cleared while another thread puts into it corrupts its internals rather
    // than merely losing a row. The monitor is uncontended in practice (main touches these
    // maps only on a user action), so the Desert-mode firehose pays nothing for it. Reentrant,
    // so a guarded caller may call another guarded helper.
    private val storeLock = Any()
    private var lastLat: Double? = null
    private var lastLon: Double? = null
    private var demoNeedsRelocate = false   // demo seeded before a GPS fix -> re-place around the user when one arrives

    // ---- live-session checkpointing ----
    // Wall-clock of the last store->disk write, for checkpointDetections' throttle.
    @Volatile private var lastCheckpointAt = 0L
    // Serializes the seal+write half of persistDetections. Two snapshots taken close together
    // (a checkpoint racing an end-of-drain persist) must not interleave into one file.
    private val persistMutex = Mutex()
    // Real Clear Log is a write-ahead transaction. The durable SharedPreferences bit survives a
    // kill between the tap and file deletion; the in-process mirror remains armed even when commit
    // reports failure, because that failure cannot prove bytes did not reach disk.
    private val persistedDetectionClearTombstone = PersistedDetectionClearTombstone(
        readStored = { prefs.getBoolean(DETECTION_CLEAR_PENDING_KEY, false) },
        storePending = {
            prefs.edit().putBoolean(DETECTION_CLEAR_PENDING_KEY, true).commit() &&
                prefs.getBoolean(DETECTION_CLEAR_PENDING_KEY, false)
        },
        removeStored = {
            prefs.edit().remove(DETECTION_CLEAR_PENDING_KEY).commit() &&
                !prefs.getBoolean(DETECTION_CLEAR_PENDING_KEY, false)
        },
    )
    // Invalidates snapshots captured before a Clear even when their IO coroutine reaches
    // persistMutex after deletion. A separate token gates decoded startup/exit-demo loads.
    private val persistedDetectionWriteGeneration = AtomicLong(0L)
    private val persistedDetectionLoadGate = PersistedDetectionLoadGate()
    // The final generation/tombstone check and atomic file replacement share this short lock
    // with Clear's write-ahead transition. A writer already inside may finish first, after which
    // Clear deletes it; a writer arriving after Clear arms can never create a new checkpoint.
    private val persistedDetectionClearStateLock = Any()
    // Guarded by persistedDetectionClearStateLock. A generic foreground/startup retry must not
    // complete or retire the transaction while the clearLog call that created it still owns the
    // visible reset; doing so opens a write window before that initiator's later second reset.
    private var persistedDetectionClearInitiatorInProgress = false
    // If both the write-ahead commit and synchronous deletion initially fail, rows stay visible.
    // A later successful retry must then honor the original Clear before persistence resumes.
    private val pendingClearNeedsMemoryReset = AtomicBoolean(false)

    // ---- offline buffer replay state ----
    // lastSeq is the highest contiguous seq we've filed; it survives a disconnect (so a
    // reconnect only re-pulls what we missed) and is persisted across app restarts - but only
    // through persistCursor/checkpointHistory, which advance the on-disk copy strictly BEHIND
    // the store write that holds the acknowledged records (write-ahead; mirrors iOS).
    private var lastSeq: Long = prefs.getLong("lastSeq", 0L)
    // Generation paired with the in-memory cursor. Firmware changes it on every durable ring wipe;
    // a mismatched/unknown value makes sync replay the full retained window instead of trusting a
    // numerically overlapping cursor from an older generation.
    private var activeLogGeneration: Long = prefs.getLong("logGeneration", 0L)
    private var histReceived = 0            // records filed during the current drain
    private var histHighestContiguous = 0L  // highest contiguous seq seen this drain
    // n == 0 is a valid begin, so the total cannot stand in for this per-attempt envelope bit.
    // An end without it has no authority to finalize the previous generation/cursor.
    private var histBeginSeen = false
    // Re-drain requests issued this connection (see onHistEnd's bounded resync). Reset on a
    // clean/accepted end and in the disconnect cleanup.
    private var histResyncAttempts = 0
    // Wall clock at the moment we pushed {"epoch"} in sendHandshake, i.e. the anchor the board is
    // about to date this drain's records against. It is the only handle the app has on how far a
    // reconstructed stamp had to be carried, which is what its precision is made of.
    @Volatile private var anchorPushedAt = 0L

    // ---- serialized GATT op queue ----
    // Android allows one outstanding GATT op per connection, so every writeCharacteristic
    // / writeDescriptor goes through this single-in-flight queue. The callbacks
    // (onCharacteristicWrite / onDescriptorWrite) dequeue the next op. Inbound notifies
    // (onCharacteristicChanged) do NOT consume the slot.
    private val gattQueue = ArrayDeque<(BluetoothGatt) -> Unit>()
    private var gattBusy = false
    private enum class ConfigWritePurpose {
        NORMAL, HANDSHAKE_KEY, HANDSHAKE_EPOCH, HANDSHAKE_SYNC, CLEAR_LOG,
    }
    private enum class BufferHandshakeCompletion { STARTUP, REKEY_AFTER_CLEAR }
    // Exactly one with-response operation is in flight, so this tag attributes the callback to
    // the payload which actually reached the controller (CoreBluetooth has an analogous queue).
    private var configWriteInFlight: ConfigWritePurpose? = null
    private var bufferHandshakeCompletion: BufferHandshakeCompletion? = null

    // ---- OTA engine state ----
    // The ATT MTU the board negotiated (onMtuChanged). Streaming chunks are (mtu - 3) bytes;
    // 20 is the safe floor if the 512 request was refused (default ATT MTU 23). We request 512
    // so the board's fuller status JSON (all detector toggles + diagnostics) fits one notify.
    @Volatile private var negotiatedMtu = 23
    // The running update coroutine (download -> verify -> stream -> finish), null when idle.
    private var otaJob: Job? = null
    // The image being sent, split into (mtu-3) chunks the moment "ready" lands; streamed one
    // chunk per onCharacteristicWrite callback so the platform's back-pressure paces us.
    private var otaChunks: List<ByteArray> = emptyList()
    private var otaChunkIdx = 0
    private var otaTotalBytes = 0
    // The version we're flashing, held across the reboot so the reconnect can confirm it.
    private var otaTargetVersion: String = ""
    // Exact firmware/product label that selected the manifest entry. Rev-A and rev-B use distinct
    // images, so version alone must never disarm rollback after a wrong-target image boots.
    private var otaTargetFwLabel: String = ""
    // Set once the board reboots after a good "done"; the next READY checks the fw version and
    // sends confirm (or reports a rollback). Cleared when consumed.
    @Volatile private var otaAwaitingConfirm = false
    // The connection generation the confirm was armed ON. "done" arms otaAwaitingConfirm while the
    // OLD link is still up (the board reboots ~250 ms later, and Android's disconnect callback lags
    // that by seconds), and the same handler clears otaStreaming, which re-opens the 5 s status
    // poll. So a Status frame carrying the PRE-reboot version can reach checkPostRebootConfirm
    // before the board has even rebooted, and it reads a successful update as "came back on its
    // previous firmware" - failing the run, and in the combined flow aborting before the nRF leg
    // ever starts (observed on hardware 2026-08-06: board booted 2.0.4, app said rollback).
    // Only a frame from a LATER generation may decide. iOS carries the same guard as
    // otaSawFreshStatus (BLEManager+OTA.swift otaHandleReconnected/decideRebootOutcome).
    @Volatile private var otaRebootGen = -1
    // Bumps whenever the OTA session changes; a stale stall-watchdog checks this to bail out.
    @Volatile private var otaSessionId = 0
    // The exact encrypted GATT generation that owns the current board OTA controls. OTA replies do
    // not carry a wire session id, so accepting them across a reconnect would let an old board
    // session drive a new app attempt.
    @Volatile private var otaOwnerConnectGen = -1
    @Volatile private var otaBoardSessionArmed = false
    // A cancelled/failed board-touched session can still have ready/prog/err notifies queued on the
    // same link. Retry only after reconnecting, which flushes the controller and changes connectGen.
    @Volatile private var otaQuarantinedConnectGen = -1
    // Wall-clock of the last progress signal from the board ("ready"/"prog"), for the stall watchdog.
    @Volatile private var otaLastProgressAt = 0L
    // True while we're actively pushing chunks, so a mid-stream disconnect can offer a retry.
    @Volatile private var otaStreaming = false
    // True once we've written {ota:{end:true}} to commit the image, before the board's "done"
    // notify arrives. That single notify can be lost or the reboot can race ahead of it, so a
    // disconnect after this is a PROBABLE SUCCESS, not a failure: we enter the reboot/confirm path
    // and let the post-reboot version read decide. Mirrors iOS OTASession.ended. Cleared on reset.
    @Volatile private var otaEnded = false
    // True while the post-reboot reconnect loop is running, so a stale-client disconnect can't
    // spawn a second, concurrent reconnect loop (the confirmed OTA reconnect blocker).
    @Volatile private var otaReconnecting = false

    // ---- unexpected-drop auto-reconnect ----
    // True while an unexpected-drop auto-reconnect is armed, so a flurry of DISCONNECTED callbacks
    // can't stack multiple pending clients into a GATT_ERROR-133 storm (mirrors otaReconnecting for
    // the OTA path). Cleared on a successful STATE_CONNECTED, a user disconnect, or the give-up
    // watchdog.
    @Volatile private var autoReconnecting = false
    // Set by disconnect() so the very next STATE_DISCONNECTED is treated as a deliberate teardown
    // and never auto-reconnected. Consumed (reset) once read in onConnectionStateChange.
    @Volatile private var userInitiatedDisconnect = false
    // Bumped on each auto-reconnect arm so a stale give-up watchdog from a prior arm can't tear
    // down a newer one (same idea as otaSessionId).
    @Volatile private var autoReconnectGen = 0
    // True while a pending autoConnect=true client from autoReconnect() exists, INCLUDING after
    // the 120 s window clears `autoReconnecting` (the client is deliberately left armed then).
    // The Android shape of iOS's `reconnectTarget != nil`: it lets onRadioOff tell a killed
    // pending RECONNECT (preserve the intent across the radio cycle) from a killed fresh
    // connect (fall back to the scan screen, like iOS). Set in autoReconnect(); cleared on
    // STATE_CONNECTED and in cleanup().
    @Volatile private var reconnectClientArmed = false
    // Gen guard for the fresh-connect watchdog in connect(): bumped by STATE_CONNECTED and by
    // cleanup() so a stale 15 s timeout can't tear down a later session (same idea as scanGen).
    @Volatile private var connectGen = 0
    // The OS bond and the secure GATT readiness chain are separate phases with separate bounds.
    // Generations make delayed same-MAC broadcasts and watchdogs inert after a retry or teardown.
    // Atomic, not @Volatile ++: the main thread (cleanup) and the GATT binder thread both bump
    // these, and a lost increment leaves a retired 30/45 s watchdog generation-matched, free to
    // tear down the NEXT healthy attempt. The Jobs are @Volatile for the same cross-thread
    // handoff (armed on the binder thread, cancelled on main); a cancel that loses the
    // assignment race is harmless because the generation check makes the stray job inert.
    private val bondAttemptGeneration = AtomicLong(0L)
    @Volatile private var observedBondingGeneration = -1L
    @Volatile private var handledBondedGeneration = -1L
    @Volatile private var bondTimeoutJob: Job? = null
    @Volatile private var secureReadyTimeoutJob: Job? = null
    private val secureReadyGeneration = AtomicLong(0L)
    @Volatile private var secureReadyArmed = false
    private val statusRevision = AtomicLong(0L)
    // True once THIS session reached READY (set in finishReady, cleared in cleanup). The
    // unexpected-drop auto-reconnect requires it: a connect that NEVER succeeded (a stale scan
    // row for a powered-off board, ~30 s status-133) must fail to the resting screen, not arm a
    // perpetual no-cancel "Connecting…".
    @Volatile private var sessionWasReady = false

    // CCCD writes we've already retried once this session (see onDescriptorWrite). Per-session so a
    // reconnect gets a clean shot at every subscription, and bounded to one retry apiece so a board
    // that keeps rejecting can't spin the GATT queue forever.
    private val cccdRetried = java.util.Collections.synchronizedSet(mutableSetOf<java.util.UUID>())

    // The startup reload of everything held at rest. loadPersistedDetections() does AndroidKeyStore
    // IPC + an AES-GCM decrypt of the whole sealed blob + a JSONArray parse + sort (+ a re-seal on
    // legacy migration); doing that on the main thread at cold start stutters launch / risks an ANR
    // on slower devices. So it runs off the main thread here, and connect()/seedDemoData() join this
    // job before they touch the store. The same non-synchronized store/firstSeenAt/lastSeenAt/
    // rssiHistory maps are also mutated by the BLE binder-callback ingest path, so letting an
    // ingest or a persist write interleave with the load populating them could corrupt the maps or
    // lose/duplicate records; the join serializes the load strictly before any of that.
    //
    // loadManagedLists() rides the same job for the same reason: both lists are sealed with the
    // same Keystore key, so the constructor used to pay two more wrappingKey() lookups before the
    // first frame - four on the one legacy-migration launch, which also re-seals and rewrites both
    // prefs entries.
    @Volatile private var persistLoadJob: Job? = null

    init {
        // Runs after the store/maps above are constructed, so the reload can populate them. Off the
        // main thread now (IO: Keystore + file read + decrypt + parse + the migration re-seal); the
        // connect and demo paths await persistLoadJob before they mutate the same maps.
        // Lists FIRST, detections second. That ordering is the whole guarantee: the mute/watch
        // projection is an input to the publish the detection reload ends with, so no row can
        // reach the feed - and therefore no row can be muted, starred or renamed by the user -
        // before both lists are back in memory. A muted device cannot flash onto the feed for one
        // publish while its rule is still being decrypted, and an edit cannot be overwritten by a
        // load that lands after it.
        val managedListLoadToken = managedListLoadGate.beginLoad()
        persistLoadJob = scope.launch(Dispatchers.IO) {
            if (loadManagedLists(managedListLoadToken)) pruneExpiredMutes(publish = false)
            loadPersistedDetections()   // replayed history survives an app restart
        }
        startWidgetFeed()   // keep the home-screen widget summary current for the process lifetime
        // Foreground/background edges for the scan pause/resume above (process lifetime, like
        // the adapter receiver).
        (context.applicationContext as? Application)?.registerActivityLifecycleCallbacks(appLifecycle)
    }

    @Synchronized
    private fun enqueueGatt(prioritize: Boolean = false, op: (BluetoothGatt) -> Unit) {
        enqueueBufferControlWrite(gattQueue, op, handshakeSuccessor = prioritize)
        if (!gattBusy) dispatchGatt()
    }

    @Synchronized
    private fun dispatchGatt() {
        val g = gatt
        if (g == null) { gattQueue.clear(); gattBusy = false; return }
        val op = gattQueue.poll()
        if (op == null) { gattBusy = false; return }
        gattBusy = true
        runCatching { op(g) }.onFailure { gattBusy = false; dispatchGatt() }
    }

    /** A write finished (or failed) - free the slot and run the next queued op. */
    @Synchronized
    private fun onGattOpComplete() {
        gattBusy = false
        dispatchGatt()
    }

    // ---- scanning ----

    // Explicitly typed: onScanFailed's retry references scanCb from inside the initializer.
    private val scanCb: ScanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            if (!hasScanPermission() || !hasConnectPermission()) {
                teardownForBluetoothPermissionRevocation()
                return
            }
            val dev = result.device
            val address = safeDeviceAddress(dev) ?: run {
                teardownForBluetoothPermissionRevocation()
                return
            }
            val name = result.scanRecord?.deviceName ?: safeDeviceName(dev) ?: "ACAB"
            // Firmware version rides our 0xACAB scan-response manufacturer data (matches the iOS
            // parse). It arrives a callback or two after the first advert, so keep the last-seen
            // value if this frame doesn't carry it.
            val fw = result.scanRecord?.getManufacturerSpecificData(0xACAB)
                ?.toString(Charsets.UTF_8)?.takeIf { it.isNotBlank() }
            val now = android.os.SystemClock.elapsedRealtime()
            // DEBUG-ONLY address log. Android is the ONLY platform that hands an app a peer's real
            // MAC: iOS and macOS substitute a per-host UUID, so neither can tell a rotating address
            // from a fixed one. That made the firmware's BLE privacy change effectively unverifiable
            // until this line existed. Top two bits of the first octet say which kind it is:
            // These bits classify the address ONLY IF it is random. Android hands us the advertised
            // address with no type attached, so a fixed public factory MAC is indistinguishable by
            // bits alone and lands in whichever bucket its first octet happens to select: an
            // Espressif e8:3d:c1 reads as 11, exactly like a static-random address. The real proof
            // that privacy is live is the address CHANGING across boots and across the rotation,
            // not the bucket this prints. 01 = resolvable private, 11 = static random or public,
            // 00 = non-resolvable or public.
            if (SCAN_ADDR_DEBUG) {
                val b0 = address.substringBefore(':').toIntOrNull(16) ?: 0
                val kind = when (b0 shr 6) {
                    0b01 -> "RESOLVABLE-PRIVATE (rotates)"
                    0b11 -> "static-random"
                    0b00 -> "non-resolvable-private"
                    else -> "PUBLIC (not private)"
                }
                android.util.Log.d("ACAB-scan", "board $name addr=$address type=$kind rssi=${result.rssi}")
            }
            val prev = _found.value.firstOrNull { safeDeviceAddress(it.device) == address }
            val board = FoundBoard(dev, name, result.rssi, fw ?: prev?.firmware, now)
            // Drop entries not heard from recently. Keying on address is still right (it is what
            // distinguishes two real boards from each other), but with address privacy on, an
            // address the board has rotated away from would sit in the picker forever as a
            // duplicate of the same physical unit. A board advertises many times a second, so a
            // few seconds of silence means gone, not quiet.
            _found.value = (_found.value
                .filterNot { safeDeviceAddress(it.device) == address }
                .filter { it.seenAt == 0L || now - it.seenAt < FOUND_STALE_MS } + board)
                .sortedByDescending { it.rssi }
        }

        override fun onScanFailed(errorCode: Int) {
            if (!hasScanPermission() || !hasConnectPermission()) {
                teardownForBluetoothPermissionRevocation()
                return
            }
            // Registration failures arrive ONLY here; without this override every one is
            // silent and the UI sits on a "scanning" that isn't. ALREADY_STARTED means a live
            // registration still delivers results - tearing down would kill a working scan.
            if (errorCode == ScanCallback.SCAN_FAILED_ALREADY_STARTED) return
            if (errorCode == ScanCallback.SCAN_FAILED_SCANNING_TOO_FREQUENTLY) {
                // The platform denies a 6th scan start per app within 30 s (radio flapping).
                // Retry once past the penalty window; the gen guard is invalidated by
                // stopScan()/connect()/radio-off so a stale retry can't fire into a new session.
                val gen = scanGen
                scope.launch {
                    delay(SCAN_RETRY_MS)
                    // appForegrounded is part of the guard because this is the ONLY scan start
                    // that isn't already behind it, and it fires ~30 s late: background the app
                    // inside that window and this would light a LOW_LATENCY scan back up behind
                    // the user's back. _state stays SCANNING across a background pause (that's
                    // how the resume works), so state alone can't tell the two apart.
                    if (gen == scanGen && _state.value == ConnState.SCANNING && appForegrounded &&
                        hasScanPermission() && hasConnectPermission() &&
                        runCatching { adapter?.isEnabled == true }.getOrDefault(false)) {
                        runCatching { scanner?.stopScan(scanCb) }
                        beginScan()
                    }
                }
                return
            }
            // Anything else (registration failed, unsupported, internal error): the scan is
            // dead. Retain the terminal cause so UI does not misreport it as an empty scan.
            _scanHint.value = scanStartFailureHint(
                featureUnsupported = errorCode == ScanCallback.SCAN_FAILED_FEATURE_UNSUPPORTED,
            )
            _state.value = restingState()
        }
    }

    // Generation guard for the scan-lifecycle jobs (timeout, too-frequent retry): bumped by
    // beginScan()/stopScan()/onRadioOff so a stale job can't flip a later session's state.
    @Volatile private var scanGen = 0
    private var scanTimeoutJob: Job? = null
    // When the last real scanner start happened (elapsedRealtime), so radio flapping can't
    // burn the platform's 5-scan-starts-per-30s budget with back-to-back auto-rescans.
    @Volatile private var lastScanStartAt = 0L
    // Set when backgrounding stopped an active scan without changing _state, so the return to
    // foreground knows to restart it (see appLifecycle).
    @Volatile private var scanPausedInBackground = false

    fun startScan() {
        if (!hasScanPermission() || !hasConnectPermission()) {
            _state.value = ConnState.DISCONNECTED
            return
        }
        // Already scanning: a re-tap must not clear the board list or double-register the
        // callback (the platform rejects the second registration with ALREADY_STARTED anyway).
        if (_state.value == ConnState.SCANNING) return
        _scanHint.value = null
        _found.value = emptyList()
        beginScan()
    }

    /** Register (or re-register) the platform scan. Split from startScan so the background
     *  pause/resume and the too-frequent retry can restart the radio without clearing _found. */
    private fun beginScan() {
        if (!hasScanPermission() || !hasConnectPermission()) {
            scanPausedInBackground = false
            _state.value = ConnState.DISCONNECTED
            return
        }
        val s = runCatching { scanner }.getOrNull() ?: run {
            if (runCatching { adapter?.isEnabled == true }.getOrDefault(false)) {
                _scanHint.value = scanStartFailureHint(featureUnsupported = false)
            }
            _state.value = restingState()
            return
        }
        val gen = ++scanGen
        scanPausedInBackground = false
        lastScanStartAt = SystemClock.elapsedRealtime()
        _state.value = ConnState.SCANNING
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(AcabProfile.SERVICE))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val started = runCatching { s.startScan(listOf(filter), settings, scanCb) }.isSuccess
        if (!started) {
            _scanHint.value = scanStartFailureHint(featureUnsupported = false)
            _state.value = ConnState.DISCONNECTED
            return
        }
        // A LOW_LATENCY scan left running is a multi-percent-per-hour battery cost, and until
        // now nothing but connect() ever stopped it. Bound the window: past it, fall back to
        // the resting screen ( _found keeps any boards already seen, still tappable).
        scanTimeoutJob?.cancel()
        scanTimeoutJob = scope.launch {
            delay(SCAN_TIMEOUT_MS)
            if (gen == scanGen && _state.value == ConnState.SCANNING) stopScan()
        }
    }

    fun stopScan() {
        scanGen++
        scanTimeoutJob?.cancel(); scanTimeoutJob = null
        scanPausedInBackground = false
        runCatching { scanner?.stopScan(scanCb) }
        if (_state.value == ConnState.SCANNING) _state.value = ConnState.DISCONNECTED
    }

    // ---- connection ----

    /** Recovery hint shown when a connect attempt ends before the link is usable. On a board that is
     *  present and advertising, the overwhelmingly likely cause is the PAIRING WINDOW: a phone that
     *  has never bonded may only pair in the two minutes after power-on, and outside that the board
     *  refuses at connect (see ACAB_PAIR_WINDOW_MS in the firmware). The board cannot tell us why,
     *  because it hangs up before any characteristic exists to be read, so the app offers the one
     *  recovery that covers this and most other stuck states. Mirrors iOS BLEManager.connectHint. */
    private val _connectHint = MutableStateFlow<String?>(null)
    val connectHint: StateFlow<String?> = _connectHint.asStateFlow()

    fun connect(board: FoundBoard) {
        if (!hasConnectPermission() || !hasScanPermission()) {
            _state.value = ConnState.DISCONNECTED
            return
        }
        _connectHint.value = null   // fresh attempt: drop any stale hint from the last one
        _scanHint.value = null
        // In-flight guard: two fast taps on the same board row (the recomposition to
        // ConnectingRow lags a frame) must not open two parallel clients feeding one callback
        // machine - the first would leak toward the ~30-client ceiling and callbacks from
        // either would drive ops onto the other.
        if (_state.value == ConnState.CONNECTING || _state.value == ConnState.BONDING) return
        stopScan()
        // A fresh, user-initiated connect starts from a clean slate: clear any leftover
        // auto-reconnect intent/guard from a previous session so a stale flag can't block the
        // NEXT unexpected-drop reconnect (or a stale watchdog tear down this new link).
        userInitiatedDisconnect = false
        autoReconnecting = false
        // Close any leftover client (a pending auto-reconnect the watchdog abandoned, say)
        // before opening a new one - same discipline as reconnectAfterOta.
        runCatching { gatt?.close() }
        gatt = null
        _state.value = ConnState.CONNECTING
        target = board.device
        _deviceName.value = board.name
        // (bondReceiver is registered for the process lifetime next to its declaration: every
        // path that can land STATE_CONNECTED on an unbonded board needs it, not just this one.)
        //
        // Fresh-connect watchdog (iOS's 15 s connectTimeoutTimer + auto-rescan). A tap on a
        // stale row for a board that just powered off used to sit at CONNECTING until the
        // platform's ~30 s status-133, then land on a static resting screen; iOS cancels at
        // 15 s and restarts the scan, so the stale row only re-lists if the board is really
        // advertising. Gen-guarded like scanTimeoutJob: STATE_CONNECTED and every cleanup()
        // bump connectGen, and the flag checks keep it clear of the auto-/OTA-reconnect
        // paths, which pace themselves.
        val cGen = ++connectGen
        scope.launch {
            delay(CONNECT_TIMEOUT_MS)
            if (cGen != connectGen) return@launch
            withContext(Dispatchers.Main) {
                if (cGen == connectGen && _state.value == ConnState.CONNECTING &&
                    !autoReconnecting && !otaReconnecting && !otaAwaitingConfirm) {
                    runCatching { gatt?.close() }
                    gatt = null
                    target = null
                    _deviceName.value = null
                    _state.value = ConnState.DISCONNECTED
                    if (!sessionWasReady) _connectHint.value = PAIR_WINDOW_HINT
                    if (appForegrounded && hasScanPermission() && hasConnectPermission() &&
                        runCatching { adapter?.isEnabled == true }.getOrDefault(false)) startScan()
                }
            }
        }
        // Hold the GATT open until the startup reload has finished populating the store: the connect
        // chain files (and, on a clean drain, persists) detections into the same non-synchronized
        // maps loadPersistedDetections is filling, so opening the link first could let a binder-thread
        // ingest race the load. In practice persistLoadJob is long done by the time a user taps
        // connect, so this join returns at once; it only guards the pathological instant-connect.
        // Join off the main thread, then open the link back on it.
        val dev = board.device
        scope.launch {
            persistLoadJob?.join()
            withContext(Dispatchers.Main) {
                if (target !== dev) return@withContext   // a teardown or a newer connect() superseded this one
                if (!hasConnectPermission()) {
                    teardownForBluetoothPermissionRevocation()
                    return@withContext
                }
                gatt = runCatching {
                    dev.connectGatt(context, false, gattCb, BluetoothDevice.TRANSPORT_LE)
                }.getOrNull()
                if (gatt == null) {
                    target = null
                    _deviceName.value = null
                    _state.value = ConnState.DISCONNECTED
                }
            }
        }
    }

    fun disconnect() {
        // A user-initiated disconnect must NOT trigger the unexpected-drop auto-reconnect: flag it
        // so onConnectionStateChange treats the coming STATE_DISCONNECTED as deliberate, and cancel
        // any auto-reconnect already armed.
        userInitiatedDisconnect = true
        autoReconnecting = false
        // A client with no established link fires NO STATE_DISCONNECTED callback when cancelled,
        // so its cleanup would never run: the UI would hang on "Connecting…"/"Pairing…" and the
        // stale userInitiatedDisconnect=true would silently eat the NEXT unexpected-drop
        // reconnect. That covers a first connect still in flight, a pending autoConnect=true
        // reconnect (CONNECTING), and the whole BONDING stretch: inside the bond-settle window
        // gatt is null outright (the settled handler closed it), and the 600 ms relaunch is a
        // not-yet-connected client that cancels silently. Relying on the callback there
        // SWALLOWED a Cancel tapped on the Pairing screen - cleanup() never ran, target
        // survived, the delayed relaunch's `target === d` guard passed and re-paired against
        // the user's intent - or, after the relaunch, wedged the UI on "Pairing…" for good.
        // A live createBond client (BONDING with an established ACL) still gets the disconnect()
        // below; the inline cleanup is idempotent with any callback, which can no longer fire
        // once cleanup() closes the client. READY keeps the callback-driven teardown as before.
        // Gate on the STATE, not the autoReconnecting flag: after the 120 s watchdog gives up
        // the flag is already false while the pending client stays armed.
        val neverLinked = _state.value == ConnState.CONNECTING || _state.value == ConnState.BONDING
        runCatching { gatt?.disconnect() }
        if (neverLinked) { cleanup(); userInitiatedDisconnect = false }
    }

    /** Cancel the in-flight connection and immediately return to a fresh beacon scan. */
    fun stopConnectionAndScan() {
        disconnect()
        if (hasScanPermission() && hasConnectPermission() &&
            runCatching { adapter?.isEnabled == true }.getOrDefault(false)) {
            startScan()
        }
    }

    // ---- drive mode (foreground-service glanceable counter notification) ----

    /** Start the Drive-mode foreground service: an ongoing detection-counter notification
     *  (lock screen + shade; an Android 16 Live Update chip where supported), and the link
     *  stays alive in the background while it runs. The iOS Live Activity analog. */
    fun startDriveMode(): Boolean {
        _driveModeWanted.value = true
        prefs.edit().putBoolean("liveModeWanted", true).apply()
        if (_driveMode.value) return true
        _driveMode.value = true
        val accepted = AcabLinkService.start(context)
        if (!accepted) {
            _driveMode.value = false
            syncLocationOwnership()
        }
        return accepted
    }

    fun endDriveMode() {
        stopDriveMode(userRequestedStop = true)
    }

    /** Stop the foreground surface for an automatic lifecycle reason while retaining the user's
     * Live Mode preference. The root orchestration can restore it when a real link is READY again. */
    fun suspendDriveMode() {
        stopDriveMode(userRequestedStop = false)
    }

    private fun stopDriveMode(userRequestedStop: Boolean) {
        val wanted = liveModeWantedAfterStop(_driveModeWanted.value, userRequestedStop)
        if (wanted != _driveModeWanted.value) {
            _driveModeWanted.value = wanted
            prefs.edit().putBoolean("liveModeWanted", wanted).apply()
        }
        if (!_driveMode.value) return
        _driveMode.value = false
        syncLocationOwnership()
        AcabLinkService.stop(context)
    }

    /** Hide/show detection counts on the lock screen: the Live Mode notification and its Android 16
     *  chip, plus the category on a per-detection alert (the service re-renders). All three are
     *  named in the toggle's own subtitle; see the _redactLockScreen declaration for the full
     *  scope and for why iOS's same-named toggle covers less. */
    fun setRedactLockScreen(on: Boolean) {
        _redactLockScreen.value = on
        prefs.edit().putBoolean("redactLock", on).apply()
    }

    // ---- home-screen widget summary ----
    // The widget runs in the launcher's process and can't read this singleton's memory, so it
    // polls a tiny summary out of its own shared-prefs file. The file name and key strings are
    // the cross-process CONTRACT with BeaconsWidgetProvider - keep them identical on both sides.
    private val widgetPrefs = context.getSharedPreferences(BeaconsWidgetProvider.PREFS, Context.MODE_PRIVATE)

    /** One store row, flattened for the widget summary pass: seen stamps, the display category
     *  and the strip token it feeds (null for rows that feed no cell). */
    private data class WidgetRow(val first: Long?, val last: Long?, val cat: String, val wkey: String?)

    /** Seed the summary prefs for a widget that was JUST placed. updateWidget() skips its work
     *  entirely while nothing is placed, so without this the first render reads whatever the prefs
     *  held when the last widget was removed - and if the board is disconnected or idle, no publish
     *  ever arrives to correct it. One bounded store pass, on the placement edge only.
     *  Called from BeaconsWidgetProvider.onEnabled, which fires for the first instance. */
    fun seedWidgetSummary() = updateWidget()

    /** Recompute the widget summary from the store and hand it to the provider. Idempotent, but
     *  not cheap once a widget IS placed: it takes storeLock and walks up to STORE_CAP rows. That
     *  is why it returns on the isPlaced gate below, and why the only repeating caller is the
     *  sampled collector in startWidgetFeed rather than every publish - a Desert-mode firehose must
     *  not thrash cross-process updates. */
    private fun updateWidget() {
        // Nothing placed, nothing to feed. This is the gate BeaconsWidgetProvider.isPlaced asks
        // callers to apply: the pass below takes storeLock - the monitor the BLE ingest thread
        // holds for every arriving detection, and that main-thread readers stall behind - snapshots
        // up to STORE_CAP rows, and writes the summary prefs file, every WIDGET_SAMPLE_MS for the
        // whole of a drive. Gating only the re-render left all of that running on exactly the
        // installs the gate exists to spare. The answer is cached and invalidated on the provider's
        // enable/disable edges, so placing the first widget starts the feed within one sample
        // window.
        if (!BeaconsWidgetProvider.isPlaced(context)) return
        // Today's window is computed ONCE out here: the per-row Instant->ZonedDateTime->
        // LocalDate conversion this replaces was ~STORE_CAP temporal allocations under
        // storeLock every sample, exactly the hold the main-thread readers stall behind.
        val zone = ZoneId.systemDefault()
        val todayDate = LocalDate.now(zone)
        val today = todayDate.toEpochDay()
        val todayStartMs = todayDate.atStartOfDay(zone).toInstant().toEpochMilli()
        val todayEndMs = todayDate.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli()
        var countToday = 0
        var lastType = ""
        var lastAt = 0L
        // Cheap reference snapshot under the lock; the counting runs outside it. Muted evidence
        // remains sealed in store but must not leak back onto this glanceable visible surface.
        val indexes = managedListIndexes
        val muted = activeIgnoredMacs(indexes = indexes)
        val watched = indexes.watchedMacs
        val rows = synchronized(storeLock) {
            store.values.asSequence()
                .filter { d -> activeProjectionIncludes(d.mac, d.mac.lowercase() in watched, muted) }
                .map { d ->
                WidgetRow(firstSeenAt[d.id], lastSeenAt[d.id], d.type.category, d.type.widgetCategoryKey)
                }.toList()
        }
        var newestSeen = Long.MIN_VALUE
        var newestType: String? = null
        // Today's breakdown, one bucket per strip cell. It shares the headline's DAY rule (same
        // isApproxTime + local-day window below), so a row can never be in one and not the other
        // for a reason about time. It does NOT share the headline's TYPE rule, and that asymmetry
        // is deliberate:
        //
        // widgetCategoryKey belongs on the buckets alone. The day gate drops a row from both sides
        // because we cannot place it in TODAY at all; a NEARBY_DEVICE (Desert's firehose), WATCHED
        // or UNKNOWN row is dated perfectly well, it just has no strip glyph to draw it with.
        // Gating the headline on it too made the glance contradict itself in the mode that
        // produces the most hits: Desert files nearly everything as NEARBY_DEVICE, so the face
        // rendered "0 TODAY" directly above a live "NEARBY 12s ago", and a starred device firing
        // read "0 TODAY" beside "WATCHED 1m ago". A muted row is one the user asked
        // us to drop; a watched row is one the user asked us to shout about, and neither it nor an
        // ambient row may be quietly subtracted from the only running total this product puts on a
        // home screen.
        //
        // So: the headline counts EVERY projected row first heard today whose instant we measured,
        // whatever its type, and the six buckets are a named breakdown of the part of that total
        // the widget has a glyph for. The strip can sum to LESS than the number above it (never
        // more), which reads as "412 today, 3 of them ALPR" rather than as a lost count.
        // iOS twin: the same loop in BLEManager.writeWidgetSummary.
        val catToday = HashMap<String, Int>(8)
        for ((fs, ls, cat, wkey) in rows) {
            // "Today" counts only rows with a REAL wall-clock first-sighting on the local day.
            // isApproxTime screens out the offline-buffer pseudo-time axis, so a replayed
            // black-box record with no clock can never inflate today's number.
            if (fs != null && !isApproxTime(fs) && fs >= todayStartMs && fs < todayEndMs) {
                countToday++
                if (wkey != null) catToday[wkey] = (catToday[wkey] ?: 0) + 1
            }
            // Last sighting is the freshest row by last-seen (same pick as the notification).
            if (ls == null) continue
            if (ls > newestSeen) { newestSeen = ls; newestType = cat }
        }
        newestType?.let { cat ->
            lastType = cat
            // A pseudo-stamped newest (offline-only, no real clock) gets no honest "ago": leave
            // lastAt at 0 so the widget falls back to its empty state ("no detections") rather
            // than a fabricated age.
            if (!isApproxTime(newestSeen)) lastAt = newestSeen
        }
        val ed = widgetPrefs.edit()
            .putInt(BeaconsWidgetProvider.KEY_COUNT, countToday)
            .putString(BeaconsWidgetProvider.KEY_LAST_TYPE, lastType)
            .putLong(BeaconsWidgetProvider.KEY_LAST_AT, lastAt)
            .putBoolean(BeaconsWidgetProvider.KEY_CONNECTED, _state.value == ConnState.READY)
            .putInt(BeaconsWidgetProvider.KEY_DAY, today.toInt())
            .putString(
                BeaconsWidgetProvider.KEY_PROCESS_GENERATION,
                BeaconsWidgetProvider.currentProcessGeneration(),
            )
        // Every token is written every time, including the zeroes: a bucket that empties has to
        // clear its cell, and a key left behind would keep a stale count on the strip.
        for (t in BeaconsWidgetProvider.CAT_TOKENS) {
            ed.putInt(BeaconsWidgetProvider.KEY_CAT_PREFIX + t, catToday[t] ?: 0)
        }
        ed.apply()
        BeaconsWidgetProvider.markCurrentSummaryPublished(context)
        BeaconsWidgetProvider.refresh(context)
    }

    /** Keep the home-screen widget summary current: recompute + re-render whenever the feed or the
     *  link state changes. Sampled so a firehose of detections can't hammer cross-process updates;
     *  a connect/disconnect still lands within one sample window. The store already accumulates
     *  every hit regardless, so a dropped sample only delays the widget, never loses a detection. */
    @OptIn(FlowPreview::class)
    private fun startWidgetFeed() {
        scope.launch {
            combine(_detections, _state) { _, _ -> }
                .sample(WIDGET_SAMPLE_MS)
                .collect { updateWidget() }
        }
    }

    private fun cleanup(forAutoReconnect: Boolean = false) {
        val endedConnectGen = connectGen
        bondTimeoutJob?.cancel()
        bondTimeoutJob = null
        secureReadyTimeoutJob?.cancel()
        secureReadyTimeoutJob = null
        secureReadyGeneration.incrementAndGet()
        secureReadyArmed = false
        bondAttemptGeneration.incrementAndGet()
        observedBondingGeneration = -1L
        handledBondedGeneration = -1L
        nrfDfu.onLinkTeardown(endedConnectGen.toLong())
        otaBoardSessionArmed = false
        otaOwnerConnectGen = -1
        connectGen++   // retire any pending fresh-connect watchdog; this session is over
        stopStatusPolling()   // no live link -> stop the ~5 s status-read fallback
        runCatching { gatt?.close() }
        gatt = null
        target = null
        // Drop any in-flight GATT ops; the slot is meaningless without a connection.
        synchronized(this) {
            gattQueue.clear()
            gattBusy = false
            configWriteInFlight = null
            bufferHandshakeCompletion = null
        }
        sessionWasReady = false
        cccdRetried.clear()            // fresh session gets a fresh retry per subscription
        reconnectClientArmed = false   // the pending client (if any) was just closed
        histReceived = 0
        histHighestContiguous = 0L
        histBeginSeen = false
        histResyncAttempts = 0
        // A per-record advance is only volatile until its matching store checkpoint completes.
        // Reconnect from the durable tuple, never from RAM that a process kill could still lose.
        val resumeCursor = synchronized(cursorLock) {
            replayCursorForReconnect(
                ReplayCursorTuple(lastSeq, activeLogGeneration),
                ReplayCursorTuple(lastSeqPersisted, lastLogGenerationPersisted),
            )
        }
        lastSeq = resumeCursor.sequence
        activeLogGeneration = resumeCursor.generation
        // A drain cut short never reaches resolveBrackets, and the cursor didn't advance, so the
        // next session replays these same records. Drop the half-batch rather than bracketing
        // those rows twice over; they stay unknown until a replay closes cleanly.
        // Under storeLock: noteHistTime ADDS to this list while holding the lock, and cleanup can
        // run from a different thread than the BLE callback that fills it, so an unguarded clear
        // races an in-flight add. ArrayList is not thread-safe and the failure mode is not a lost
        // row, it is a corrupted list or an out-of-bounds on the next read. The declaration's
        // "BLE-callback thread only" note is what made this look safe; it is not accurate.
        synchronized(storeLock) { pendingBracket.clear() }
        // A drop mid-drain: leave the "syncing" pill off (the banner one-shot is untouched, so a
        // completed drain that raised it before the drop still shows).
        _syncingOfflineLog.value = false
        _offlineSyncCount.value = 0
        _offlineSyncTotal.value = 0
        _status.value = null
        // No link means no OTA channel: a capability left true from the previous session let
        // startOta run against a dead link (see its fail-fast). onDescriptorWrite re-derives it
        // on the next connect; iOS clears otaCapable on every teardown the same way.
        _otaCapable.value = false
        _deviceName.value = null
        // The store and its side maps are deliberately NOT cleared here. A live session exists
        // nowhere but this store (the board only buffers while the app is away), so wiping it on
        // a routine drop - a board reboot, a walk out of range, the radio toggling - threw away
        // the whole log with no way back. Only the confirmed clearLog() empties it. Re-filing
        // after a reconnect is dedup-by-id and idempotent, so a replay can't double up.
        // A drop is also when a session ends, so force the checkpoint the throttle may still owe
        // us before anything else can end the process.
        checkpointDetections(force = true)
        // An auto-reconnect is about to be armed for this drop: leave the link state and Drive mode
        // ALONE. autoReconnect() sets CONNECTING itself (the service + widget read that as
        // "Reconnecting…"), and Drive mode must stay up so its notification and the home-screen
        // widget resync to connected the moment the board comes back. The two branches below are
        // the ordinary end-of-session teardown.
        if (forAutoReconnect) {
            // No live detections can arrive while the link is being chased. Move the state before
            // re-evaluating process location ownership so Drive mode does not keep GPS running
            // through the reconnect window.
            _state.value = ConnState.CONNECTING
            syncLocationOwnership()
            return
        }
        // A plain teardown (user disconnect, radio off, or give-up): any armed auto-reconnect is
        // being torn down with it, so clear the guard or a stale 'true' would block the next arm.
        autoReconnecting = false
        // Land on the scan screen, or the "Bluetooth is off" screen when the radio is what dropped.
        _state.value = restingState()
        // Don't hold the connectedDevice foreground service open with no live link (battery
        // drain + Android 14's FGS-without-device policy): if the board drops for good, end Drive
        // mode so the counter stops cleanly instead of a perpetual, non-reconnecting "Reconnecting…".
        if (_driveMode.value) suspendDriveMode()
        syncLocationOwnership()
    }

    private fun armBondTimeout(device: BluetoothDevice, attemptGeneration: Long) {
        bondTimeoutJob?.cancel()
        val expectedAddress = safeDeviceAddress(device) ?: return
        bondTimeoutJob = scope.launch {
            delay(PAIRING_TIMEOUT_MS)
            withContext(Dispatchers.Main) {
                val targetAddress = target?.let(::safeDeviceAddress)
                if (attemptGeneration == bondAttemptGeneration.get() &&
                    _state.value == ConnState.BONDING && targetAddress == expectedAddress &&
                    !userInitiatedDisconnect) {
                    _connectHint.value = pairingFailureHint(PairingFailure.TIMED_OUT)
                    disconnect()
                }
            }
        }
    }

    private fun armSecureReadyTimeout(device: BluetoothDevice) {
        secureReadyTimeoutJob?.cancel()
        secureReadyTimeoutJob = null
        secureReadyArmed = false
        val expectedAddress = safeDeviceAddress(device) ?: return
        val generation = secureReadyGeneration.incrementAndGet()
        secureReadyArmed = true
        secureReadyTimeoutJob = scope.launch {
            delay(SECURE_READY_TIMEOUT_MS)
            withContext(Dispatchers.Main) {
                val targetAddress = target?.let(::safeDeviceAddress)
                val awaitingReady = awaitingSecureReadiness(_state.value)
                if (generation == secureReadyGeneration.get() && awaitingReady &&
                    targetAddress == expectedAddress &&
                    !userInitiatedDisconnect) {
                    _connectHint.value = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)
                    disconnect()
                }
            }
        }
    }

    // Bond before discovering services - the board insists on an encrypted link.
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (!hasConnectPermission()) {
                teardownForBluetoothPermissionRevocation()
                return
            }
            val dev = intent.getParcelableExtraCompat(BluetoothDevice.EXTRA_DEVICE)
            val devAddress = dev?.let(::safeDeviceAddress) ?: return
            val targetAddress = target?.let(::safeDeviceAddress) ?: return
            if (devAddress != targetAddress) return
            when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, -1)) {
                BluetoothDevice.BOND_BONDING -> {
                    val platformBonding = runCatching {
                        dev.bondState == BluetoothDevice.BOND_BONDING
                    }.getOrDefault(false)
                    val attemptGeneration = bondAttemptGeneration.get()
                    if (_state.value == ConnState.BONDING && !userInitiatedDisconnect &&
                        attemptGeneration > 0L && platformBonding) {
                        observedBondingGeneration = attemptGeneration
                    }
                }
                BluetoothDevice.BOND_BONDED -> {
                    val platformBonded = runCatching {
                        dev.bondState == BluetoothDevice.BOND_BONDED
                    }.getOrDefault(false)
                    val attemptGeneration = bondAttemptGeneration.get()
                    if (!shouldHandleCurrentBonded(
                            state = _state.value,
                            userInitiatedDisconnect = userInitiatedDisconnect,
                            activeAttemptGeneration = attemptGeneration,
                            handledBondedGeneration = handledBondedGeneration,
                            platformStateIsBonded = platformBonded,
                        )) return
                    handledBondedGeneration = attemptGeneration
                    // The OS bond is complete. Retire its deadline immediately and give the fresh
                    // encrypted reconnect plus service/CCCD readiness chain its own bounded window.
                    bondTimeoutJob?.cancel()
                    bondTimeoutJob = null
                    armSecureReadyTimeout(dev)
                    // Bonding just upgraded the link to encrypted. On Android 11 the freshly-bonded
                    // GATT routinely can't discover services right after BOND_BONDED (the encryption
                    // isn't settled, and the ACL is frequently torn down mid-bond), which stranded the
                    // FIRST connect on the pairing screen even though the bond DID persist - which is
                    // exactly why a manual cancel + retry worked: that retry connects to an ALREADY
                    // bonded device and goes straight to discovery. So reproduce the retry: close the
                    // just-bonded link and reconnect. Now bonded, the fresh link comes up encrypted and
                    // onConnectionStateChange takes the same straight-to-discovery path.
                    val d = target ?: return
                    runCatching { gatt?.close() }
                    gatt = null
                    scope.launch(Dispatchers.Main) {
                        delay(600)                       // let the stack release the closed link
                        if (target === d && _state.value == ConnState.BONDING &&
                            attemptGeneration == bondAttemptGeneration.get()) {
                            if (!hasConnectPermission()) {
                                teardownForBluetoothPermissionRevocation()
                                return@launch
                            }
                            gatt = runCatching {
                                d.connectGatt(context, false, gattCb, BluetoothDevice.TRANSPORT_LE)
                            }.getOrNull()
                            if (gatt == null) {
                                _connectHint.value = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)
                                disconnect()
                            }
                        }
                    }
                }
                BluetoothDevice.BOND_NONE -> {
                    // A stale same-MAC NONE from the prior attempt can arrive during a retry. Accept
                    // it only after this generation observed the platform in BONDING, and recheck
                    // both the broadcast transition and the platform's current state.
                    val platformStateIsNone = runCatching {
                        dev.bondState == BluetoothDevice.BOND_NONE
                    }
                        .getOrDefault(false)
                    val previousStateWasBonding = intent.getIntExtra(
                        BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE,
                        -1,
                    ) == BluetoothDevice.BOND_BONDING
                    if (shouldAcceptCurrentBondNone(
                            state = _state.value,
                            userInitiatedDisconnect = userInitiatedDisconnect,
                            activeAttemptGeneration = bondAttemptGeneration.get(),
                            observedBondingGeneration = observedBondingGeneration,
                            previousStateWasBonding = previousStateWasBonding,
                            platformStateIsNone = platformStateIsNone,
                        )) {
                        _connectHint.value = pairingFailureHint(PairingFailure.CANCELED_OR_FAILED)
                        disconnect()
                    }
                }
            }
        }
    }

    init {
        // Registered for the PROCESS lifetime, like adapterReceiver (this block sits after the
        // receiver's declaration so it is initialized). It used to be registered in connect()
        // and unregistered in cleanup(), but createBond() runs on EVERY path that lands
        // STATE_CONNECTED on an unbonded board - the fresh connect, the unexpected-drop
        // auto-reconnect, and the post-OTA reconnect (the user can remove the pairing in system
        // Bluetooth settings while either is pending) - and the per-connect dance left those
        // reconnect paths sitting in BONDING with nobody listening for BOND_BONDED: the OS
        // finished pairing while the app hung on the pairing screen forever. The receiver
        // self-gates on `target`, so it is inert with no session.
        //
        // EXPORTED, not NOT_EXPORTED. ACTION_BOND_STATE_CHANGED is a system <protected-broadcast>
        // (only the OS can send it), so exporting the receiver is not an attack surface - it can't
        // be spoofed. It MUST be exported: on API < 33 ContextCompat backports NOT_EXPORTED by
        // registering the receiver with our app-private DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION,
        // and the system Bluetooth process (uid bluetooth) does not hold that permission, so the
        // bond-state broadcast is DENIED at the BroadcastQueue and never reaches us. The bond still
        // completes at the OS level, but the app never hears BOND_BONDED, so the first connect (the
        // one that actually bonds) hangs on the pairing screen forever; a retry only works because
        // the device is already bonded by then and takes the straight-to-discovery path in
        // onConnectionStateChange. Verified on a Pixel 2 / Android 11 via the "Permission Denial"
        // BroadcastQueue log for exactly this receiver.
        ContextCompat.registerReceiver(
            context, bondReceiver,
            IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED),
            ContextCompat.RECEIVER_EXPORTED,
        )
    }

    private fun rejectGattCallbackWithoutPermission(): Boolean {
        if (hasConnectPermission()) return false
        teardownForBluetoothPermissionRevocation()
        return true
    }

    private val gattCb = object : android.bluetooth.BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            // A closed client can deliver its final callback after a reconnect has installed a new
            // BluetoothGatt. It must not clean up or advance the replacement session.
            if (g !== gatt) return
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                // A pending auto-reconnect (or OTA reconnect) just landed: disarm the guard so its
                // stall watchdog no-ops and a later drop can arm a fresh attempt. The pending
                // client is now a live one, and the fresh-connect watchdog is retired by its gen.
                autoReconnecting = false
                reconnectClientArmed = false
                connectGen++
                // Already bonded? Go straight to discovery. Otherwise bond first.
                if (runCatching { g.device.bondState == BluetoothDevice.BOND_BONDED }.getOrDefault(false)) {
                    armSecureReadyTimeout(g.device)
                    val discoveryStarted = runCatching { g.discoverServices() }.getOrDefault(false)
                    if (!discoveryStarted) {
                        _connectHint.value = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)
                        disconnect()
                    }
                } else {
                    _state.value = ConnState.BONDING
                    val attemptGeneration = bondAttemptGeneration.incrementAndGet()
                    observedBondingGeneration = -1L
                    handledBondedGeneration = -1L
                    val started = runCatching { g.device.createBond() }.getOrDefault(false)
                    if (started) {
                        armBondTimeout(g.device, attemptGeneration)
                    } else {
                        _connectHint.value = pairingFailureHint(PairingFailure.START_REJECTED)
                        disconnect()
                    }
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                // Hold the target/name across cleanup so an OTA reboot OR an unexpected drop can
                // reconnect to the same board (cleanup nulls both).
                val wasTarget = target
                val wasName = _deviceName.value
                val reconnectForOta = otaAwaitingConfirm
                // A user tap (disconnect()) sets this so a deliberate teardown is never chased.
                val userDisconnect = userInitiatedDisconnect
                userInitiatedDisconnect = false
                val awaitingSecureReady = awaitingSecureReadiness(_state.value)
                val secureReadyDropped = awaitingSecureReady && !userDisconnect &&
                    secureReadyArmed
                val pairingDropped = _state.value == ConnState.BONDING && !userDisconnect &&
                    !secureReadyDropped
                val midOta = otaStreaming || _otaProgress.value.phase == OtaPhase.SENDING ||
                    _otaProgress.value.phase == OtaPhase.CHECKING
                // Did we already write the end control to commit the image? A drop after that is a
                // probable success, not a failure (cleanup() below doesn't touch this flag).
                val endedOta = otaEnded
                // Auto-reconnect only on an UNEXPECTED drop: not a user disconnect, not the OTA
                // reboot-confirm path, not mid-flash, the radio is still on (a radio-off drop is
                // onRadioOff/onRadioOn's job, and re-arming a GATT connect with a dead radio is
                // pointless), and we still know which board to chase. Decide BEFORE cleanup().
                // !autoReconnecting too: if one is already armed (pending client), a second
                // DISCONNECTED must fall through to a plain teardown rather than close that pending
                // client via cleanup() and then hit autoReconnect()'s guard and NOT re-arm (which
                // would strand us). A healthy pending autoConnect doesn't re-fire DISCONNECTED
                // without a connect in between anyway; on that connect the guard is already cleared.
                // sessionWasReady: only chase a board we actually had; see its declaration.
                val doAutoReconnect = !reconnectForOta && !userDisconnect && !midOta &&
                    !autoReconnecting && sessionWasReady && wasTarget != null &&
                    hasConnectPermission() &&
                    runCatching { adapter?.isEnabled == true }.getOrDefault(false)
                // Treat the OTA reboot-reconnect like an auto-reconnect for teardown: skip the
                // scan-screen state reset + Drive-mode end, since reconnectAfterOta is about to chase
                // the same board (else Drive mode dies and the UI flashes the scan screen mid-reboot).
                cleanup(forAutoReconnect = doAutoReconnect || (reconnectForOta && wasTarget != null))
                if (secureReadyDropped && !doAutoReconnect && !reconnectForOta) {
                    _connectHint.value = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)
                } else if (pairingDropped && !doAutoReconnect && !reconnectForOta) {
                    _connectHint.value = pairingFailureHint(PairingFailure.CANCELED_OR_FAILED)
                }
                when {
                    reconnectForOta && wasTarget != null -> reconnectAfterOta(wasTarget)
                    // doAutoReconnect already implies wasTarget != null; ?.let smart-casts it.
                    doAutoReconnect -> wasTarget?.let { autoReconnect(it, wasName) }
                    midOta && endedOta && wasTarget != null -> {
                        // We already committed the image (end control written) but never saw the
                        // "done" notify: it can be lost, or the board's reboot can race ahead of
                        // it. The image most likely took, so treat this as a PROBABLE SUCCESS.
                        // Arm the same reboot/confirm path reconnectForOta uses and let the
                        // post-reboot version read confirm success (or report a rollback), rather
                        // than falsely failing an update that actually applied. Mirrors iOS
                        // otaHandleDisconnect's ended-session branch. otaAwaitingConfirm must be
                        // set before reconnectAfterOta, whose loop gates on it.
                        otaAwaitingConfirm = true
                        otaRebootGen = connectGen   // this link is gone; only a later one decides
                        // And the phase must leave SENDING: the stall watchdog gates on phase, so
                        // without this transition a reboot+reconnect slower than the 20 s stall
                        // budget was failed as "went quiet ... not applied" on an update that
                        // most likely applied - and the session bump in that failOta silently
                        // killed the reconnect loop, stranding CONNECTING. Same transition the
                        // "done" handler makes (iOS sets .confirming on this exact path).
                        setOtaPhase(OtaPhase.REBOOTING, pct = 100,
                            message = "Board is rebooting into the new firmware.")
                        reconnectAfterOta(wasTarget)
                    }
                    midOta -> {
                        // Dropped mid-transfer, before the end control: nothing was committed.
                        // Surface a retryable failure rather than a silent hang.
                        failOta("Lost the connection to the board during the update. It's still on the firmware it had, so it's safe. Reconnect and try again.")
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            val discovered = status == BluetoothGatt.GATT_SUCCESS
            val mtuAccepted = discovered && runCatching { g.requestMtu(512) }.getOrDefault(false)
            when (mtuDiscoveryAction(discovered, mtuAccepted)) {
                MtuDiscoveryAction.WAIT_FOR_CALLBACK -> Unit
                // requestMtu(false) produces no callback. Continue at ATT MTU 23; the ACK-gated
                // key write now either succeeds as a long write or fails with the replay-specific
                // recovery instead of hanging forever before the handshake.
                MtuDiscoveryAction.CONTINUE_AT_DEFAULT -> subscribe(g, AcabProfile.DETECTIONS)
                MtuDiscoveryAction.DISCONNECT -> runCatching { g.disconnect() }
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            // Remember the negotiated ATT MTU so the OTA stream can use (mtu - 3)-byte chunks.
            // If the request was refused we keep the 23-byte default (20-byte chunks, slower).
            if (status == BluetoothGatt.GATT_SUCCESS && mtu >= 23) negotiatedMtu = mtu
            subscribe(g, AcabProfile.DETECTIONS)   // chain picks up in onDescriptorWrite
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            onGattOpComplete()   // CCCD write done - free the slot before queuing the next ops
            val cccdFor = d.characteristic.uuid
            if (status != BluetoothGatt.GATT_SUCCESS) {
                // The subscription did NOT take, so the board will never notify on this
                // characteristic. Retry once, since a lone transient rejection is the usual cause.
                if (cccdRetried.add(cccdFor)) {
                    android.util.Log.w("ACAB-ble", "CCCD write failed for $cccdFor (status=$status), retrying once")
                    subscribe(g, cccdFor)
                    return
                }
                // Retry exhausted. The three characteristics are NOT interchangeable, so hand this
                // to the policy rather than "continue degraded" for all of them - continuing on a
                // dead DETECTIONS stream is how a link reaches READY showing a connected board that
                // will never report anything.
                onSubscribeFailed(g, cccdFor, "status=$status after retry")
                return
            }
            when (cccdFor) {
                AcabProfile.DETECTIONS -> {
                    // The Detections subscription is live, so the board can now NOTIFY the
                    // replay. Hand it our key + clock, then ask for everything past lastSeq.
                    if (!startBufferHandshake(BufferHandshakeCompletion.STARTUP)) {
                        // A generated key is useful only if it survives this process. Never hand
                        // the board an ephemeral replacement: it would encrypt buffered evidence
                        // that this phone cannot decrypt after a restart. Keep an unreadable blob
                        // intact too; a transient Keystore failure is not authority to rotate it.
                        _connectHint.value = BUFFER_KEY_UNAVAILABLE_HINT
                        secureReadyTimeoutJob?.cancel()
                        secureReadyTimeoutJob = null
                        secureReadyArmed = false
                        // Keep the teardown out of the pairing-failure branch, which would replace
                        // the storage-specific recovery hint when STATE_DISCONNECTED arrives.
                        _state.value = ConnState.CONNECTING
                        runCatching { g.disconnect() }
                        return
                    }
                    // STATUS subscription is deliberately deferred until key, epoch and sync have
                    // each received a successful Config write response. Its eventual completion is
                    // what can call finishReady(); a failed replay handshake never reaches READY.
                }
                AcabProfile.STATUS -> {
                    // Newer boards expose the OTA characteristic; subscribe to its progress
                    // notifies before we call the link ready. Older 1.7 boards don't have it,
                    // so finishReady() runs straight away when the char is absent.
                    // NOTE: the direct Status read is deferred to finishReady() so it can't
                    // race the OTA CCCD write here (only one GATT op may be in flight; a direct
                    // read alongside the queued descriptor write would drop one of them, and a
                    // dropped OTA CCCD write would leave the board's progress notifies off).
                    if (charOf(g, AcabProfile.OTA) != null) {
                        subscribe(g, AcabProfile.OTA)
                    } else {
                        _otaCapable.value = false
                        finishReady()
                    }
                }
                AcabProfile.OTA -> {
                    _otaCapable.value = true
                    finishReady()
                }
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            if (c.uuid == AcabProfile.CONFIG) {
                val purpose = configWriteInFlight
                configWriteInFlight = null
                if (purpose != null) {
                    handleConfigWriteResult(g, purpose, status == BluetoothGatt.GATT_SUCCESS)
                }
            }
            // A finished OTA-image chunk is our back-pressure signal: the controller accepted
            // the last packet, so queue the next one. A non-success status means the buffer
            // rejected it; abort the run rather than silently dropping bytes.
            if (c.uuid == AcabProfile.OTA) {
                if (status != BluetoothGatt.GATT_SUCCESS) {
                    failOta("The board stopped accepting data. The update was not applied.")
                } else {
                    // Each accepted chunk is real byte progress; advance the stall clock here so
                    // the watchdog tracks bytes, not the board's ~64KB-spaced "prog" notifies (on a
                    // 20-byte-MTU link, one prog interval can otherwise outrun the stall timeout).
                    otaLastProgressAt = System.currentTimeMillis()
                    sendNextOtaChunk()
                }
            }
            // Handle the result first: a successful handshake step enqueues exactly its successor
            // while the slot is still held; releasing it here dispatches that successor next.
            onGattOpComplete()
        }

        // API 33+ passes the value in; older versions read it off characteristic.value.
        override fun onCharacteristicChanged(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray,
        ) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            ingest(c.uuid, value)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            @Suppress("DEPRECATION") ingest(c.uuid, c.value ?: ByteArray(0))
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int,
        ) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            onGattOpComplete()   // a queued read finished - free the slot before parsing
            if (status == BluetoothGatt.GATT_SUCCESS) ingest(c.uuid, value)
        }

        @Suppress("DEPRECATION", "OVERRIDE_DEPRECATION")
        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            if (rejectGattCallbackWithoutPermission()) return
            if (g !== gatt) return
            onGattOpComplete()   // a queued read finished - free the slot before parsing
            if (status == BluetoothGatt.GATT_SUCCESS) {
                @Suppress("DEPRECATION") ingest(c.uuid, c.value ?: ByteArray(0))
            }
        }
    }

    /** A CCCD subscription did not take. Applies the per-characteristic policy.
     *
     *  The three characteristics are NOT equivalent and must not be treated as one "degrade"
     *  case, which is what the previous version did:
     *    DETECTIONS - FATAL. It is the entire product. A link that reaches READY with this dead
     *                 shows a connected board that will never report anything, which is the one
     *                 lie this app must never tell. Tear the link down and say why.
     *    STATUS     - degrade. The app already polls status every ~5 s as a fallback, so losing
     *                 the notify costs freshness, not function. Continue the chain.
     *    OTA        - disable the feature. Progress notifies are dead, so an update would crawl to
     *                 the stall watchdog and blame the board. Continue the chain without it.
     *
     *  Reached from BOTH failure shapes: an asynchronous non-SUCCESS status in onDescriptorWrite,
     *  and a SYNCHRONOUS rejection inside subscribe() (missing characteristic, missing CCCD, or
     *  writeDescriptor refusing outright). The synchronous ones used to just free the queue slot
     *  and return, firing no callback at all - so the startup chain stalled forever with the
     *  connect watchdog already cancelled, leaving the UI stuck mid-connect with no way out. */
    private fun onSubscribeFailed(g: BluetoothGatt?, charUuid: java.util.UUID, why: String) {
        android.util.Log.w("ACAB-ble", "subscribe FAILED for $charUuid ($why)")
        when (charUuid) {
            AcabProfile.DETECTIONS -> {
                _connectHint.value =
                    "This board connected but will not send detections. Turn it off and on, then try again."
                userInitiatedDisconnect = true   // a deliberate teardown: do NOT auto-reconnect into it
                runCatching { g?.disconnect() }
                _state.value = ConnState.DISCONNECTED
            }
            AcabProfile.STATUS -> {
                // Status polling covers it. Keep walking the chain so the link still becomes usable.
                if (g != null && charOf(g, AcabProfile.OTA) != null) subscribe(g, AcabProfile.OTA)
                else { _otaCapable.value = false; finishReady() }
            }
            AcabProfile.OTA -> { _otaCapable.value = false; finishReady() }
            else -> { }
        }
    }

    private fun subscribe(g: BluetoothGatt, charUuid: java.util.UUID) {
        enqueueGatt { gg ->
            val c = charOf(gg, charUuid)
            if (c == null) {
                onGattOpComplete(); onSubscribeFailed(gg, charUuid, "characteristic absent"); return@enqueueGatt
            }
            gg.setCharacteristicNotification(c, true)
            val cccd = c.getDescriptor(AcabProfile.CCCD)
            if (cccd == null) {
                onGattOpComplete(); onSubscribeFailed(gg, charUuid, "CCCD absent"); return@enqueueGatt
            }
            val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                gg.writeDescriptor(cccd, enable) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION") cccd.value = enable
                @Suppress("DEPRECATION") gg.writeDescriptor(cccd)
            }
            // A synchronous rejection (stack busy, e.g. mid-bond/encryption work) fires NO
            // descriptor callback, so the op slot would never free and every later queued op
            // would silently pile up for the rest of the session. Free it ourselves (same
            // guard as readStatus/sendNextOtaChunk).
            if (!queued) { onGattOpComplete(); onSubscribeFailed(gg, charUuid, "writeDescriptor rejected") }
        }
    }

    private fun charOf(g: BluetoothGatt, uuid: java.util.UUID): BluetoothGattCharacteristic? =
        g.getService(AcabProfile.SERVICE)?.getCharacteristic(uuid)

    /** Queue a direct READ of the Status characteristic. Goes through the single-in-flight GATT
     *  queue like every other op (onCharacteristicRead frees the slot); a synchronous rejection
     *  (stack busy) fires no callback, so free the slot ourselves to keep the queue from wedging. */
    private fun readStatus() {
        enqueueGatt { g ->
            val c = charOf(g, AcabProfile.STATUS)
            if (c == null) { onGattOpComplete(); return@enqueueGatt }
            if (!g.readCharacteristic(c)) onGattOpComplete()
        }
    }

    // ---- periodic status read (notify fallback) ----
    // A full status frame can exceed a small negotiated MTU (e.g. iPhone 185, and Android may
    // settle low too) and get skipped as a notify while a READ stays fresh. Poll Status every
    // ~5 s while connected so the detector toggles + counts converge even when the notify is
    // dropped. Complements the firmware live-MTU clamp; mirrors the iOS fallback read.
    private var statusPollJob: Job? = null

    private fun startStatusPolling() {
        statusPollJob?.cancel()
        statusPollJob = scope.launch {
            while (true) {
                delay(STATUS_POLL_MS)
                // Only while READY, and not mid-OTA (don't inject reads into the tight chunk
                // stream); the notify fallback isn't needed during a flash.
                if (_state.value == ConnState.READY && !otaStreaming) readStatus()
            }
        }
    }

    private fun stopStatusPolling() {
        statusPollJob?.cancel()
        statusPollJob = null
    }

    /** Ask the board for a fresh Status frame right now instead of waiting for the next
     *  periodic poll/notify. Backs the Device header's refresh control (mirrors iOS
     *  otaRereadStatus). Only meaningful on a live link and not mid-flash; a no-op otherwise. */
    fun refreshStatus() {
        if (_state.value == ConnState.READY && !otaStreaming) readStatus()
    }

    /** The last step of the connect chain: mark READY and re-push per-session state. Split out
     *  so it runs whether or not the board has the OTA characteristic. Also drives the
     *  post-reboot OTA confirm: if we came back after a flash, check the version and confirm. */
    private fun finishReady() {
        bondTimeoutJob?.cancel()
        bondTimeoutJob = null
        secureReadyTimeoutJob?.cancel()
        secureReadyTimeoutJob = null
        secureReadyGeneration.incrementAndGet()
        secureReadyArmed = false
        observedBondingGeneration = -1L
        handledBondedGeneration = -1L
        sessionWasReady = true   // this session earned an unexpected-drop auto-reconnect
        _connectHint.value = null   // link is usable; the hint no longer applies
        _state.value = ConnState.READY
        syncLocationOwnership()
        // Prime the Status characteristic once the CCCD chain is fully written (all queued
        // descriptor writes have drained by now), so this read can't collide with an in-flight
        // OTA CCCD write. A Status notify also arrives on connect, so this is just a fast first
        // fill; the post-reboot confirm below leans on whichever lands first. Queued (not direct)
        // so its onCharacteristicRead slot-free stays balanced with the GATT queue.
        readStatus()
        // Keep Status fresh even when a large frame is skipped as a notify: poll it every ~5 s.
        startStatusPolling()
        resyncListsOnConnect()   // re-state ignore then watch, skipping a list we never emptied
        buzzerReassertAttempts = 0                       // fresh link: first status frame is pre-write
        lastBuzzerMuteWrite = 0L                         // and the slow mute retry starts over with it
        ignorePushAttempts = 0; watchPushAttempts = 0    // and a fresh board gets a fresh convergence budget
        setBuzzer(_alertMode.value == AlertMode.BUZZER)   // a fresh board boots with the buzzer on; sync it to the phone's mode
        // Board just connected: make sure the firmware manifest is current so the update nudge
        // and OTA gate reflect the latest published build. Non-blocking; no-ops if cache is fresh.
        runCatching { FirmwareManifest.getInstance(context).refresh() }
        // If this READY is the board coming back from an OTA reboot, verify + confirm. The
        // Status read we just queued lands async, so run the check off the status frame in
        // handleOtaNotify's sibling path (checkPostRebootConfirm), triggered on the next status.
        if (otaAwaitingConfirm) {
            checkPostRebootConfirm()
            armPostRebootStatusCap()
        }
    }

    /** Bound the post-reboot wait for the first status frame. checkPostRebootConfirm can only
     *  decide once a status lands, and a board that reconnects but never sends one left the run
     *  waiting on REBOOTING forever. 30 s cap on both platforms (iOS widens its quick recheck to
     *  the same cap): past it, report the indeterminate outcome and leave rollback armed - the
     *  same copy the unparseable-version path uses, because the situation is the same, the board
     *  is back but its new version was never seen. */
    private fun armPostRebootStatusCap() {
        val session = otaSessionId
        scope.launch {
            delay(POST_REBOOT_STATUS_CAP_MS)
            if (session != otaSessionId || !otaAwaitingConfirm) return@launch
            otaAwaitingConfirm = false
            setOtaPhase(OtaPhase.FAILED,
                message = "The board came back but didn't report the new version, so rollback was left armed for safety. Reconnect to check its firmware.")
            clearOtaStreamState()
        }
    }

    // ---- OTA engine ------------------------------------------------------------------------
    // State machine (OtaProgress.phase):
    //   IDLE -> DOWNLOADING -> VERIFYING -> CHECKING -> SENDING -> REBOOTING -> CONFIRMING -> DONE
    //   any step -> FAILED (with a reason). A rollback (board came back on the OLD version)
    //   also lands in FAILED, worded as "safe: rolled back".
    //
    // Flow:
    //   startOta() downloads the .bin off the main thread, checks size + SHA-256, computes the
    //   zlib CRC-32, then writes the begin control to the Config char. The board replies "ready"
    //   on the OTA char; we stream the image as WRITE_NO_RESPONSE chunks of (mtu - 3) bytes,
    //   one per onCharacteristicWrite callback (the platform's back-pressure paces us). "prog"
    //   notifies move the bar; "done" means the board took the image and is rebooting. The
    //   existing reconnect logic re-establishes the link; finishReady() then confirms the new
    //   version (disarming rollback) or reports that the board rolled back and is safe.

    /** Kick off an in-app update to [build]. No-op if one is already running or the board isn't
     *  OTA-capable. Downloads + hashing happen off the main thread. */
    fun startOta(build: FirmwareBuild) =
        startOta(build, reuseConfirmedCombinedHold = false)

    private fun startOta(build: FirmwareBuild, reuseConfirmedCombinedHold: Boolean) {
        val currentPhase = _otaProgress.value.phase
        if (currentPhase != OtaPhase.IDLE && currentPhase != OtaPhase.DONE &&
            currentPhase != OtaPhase.FAILED) return
        if (otaJob?.isActive == true) return
        if (!_otaCapable.value) {
            setOtaPhase(OtaPhase.FAILED, message = "This board can't update over Bluetooth. Reflash it in your browser.")
            return
        }
        if (!build.ota || !build.hasVerifiableImage) {
            setOtaPhase(OtaPhase.FAILED, message = "No verified image is published for this board yet.")
            return
        }
        if (!isNumericFirmwareVersion(build.version)) {
            setOtaPhase(OtaPhase.FAILED,
                message = "The published update has an invalid version, so it was not installed.")
            return
        }
        // Fail fast with no live link (iOS startFirmwareUpdate's otaLink guard). Without it a
        // tap that raced a disconnect burned a full download and then sat in CHECKING - the
        // begin write silently no-ops on a null gatt - until the 20 s stall watchdog blamed
        // the board ("went quiet") for an update that never reached it.
        if (gatt == null) {
            setOtaPhase(OtaPhase.FAILED, message = "The board isn't connected. Reconnect and try again.")
            return
        }
        if (otaQuarantinedConnectGen == connectGen) {
            setOtaPhase(OtaPhase.FAILED,
                message = "Reconnect to the beacon before retrying the board update. This clears any delayed update replies from the previous attempt.")
            return
        }
        // Request the keep-alive while this user action is unquestionably foreground. Download
        // and verification may outlive the Activity; accepting the Intent is necessary but not
        // sufficient, so the coroutine rechecks confirmed promotion before touching the board.
        if (!acquireOtaHold(reuseConfirmedCombinedHold)) {
            setOtaPhase(OtaPhase.FAILED,
                message = "Android could not start the protected update session. Nothing was sent to the board; keep the app open and try again.")
            return
        }
        val ownerConnectGen = connectGen
        val liveStatus = _status.value
        if (liveStatus?.needsNewerApp != false) {
            setOtaPhase(OtaPhase.FAILED,
                message = "This board needs a newer version of the app before it can be updated safely.")
            return
        }
        val liveFwLabel = liveStatus.firmwareLabel
        if (liveFwLabel.isNullOrBlank()) {
            setOtaPhase(OtaPhase.FAILED,
                message = "The board didn't report which firmware image it uses. Refresh its status and try again.")
            return
        }
        if (build.manifestLabel.isBlank() || build.manifestLabel != liveFwLabel) {
            setOtaPhase(OtaPhase.FAILED,
                message = "This update image does not match the connected board. Refresh its status and try again.")
            return
        }
        otaTargetVersion = build.version
        otaTargetFwLabel = build.manifestLabel
        otaAwaitingConfirm = false
        otaRebootGen = -1        // fresh run: no generation pinned until "done" arms one
        otaStreaming = false
        otaEnded = false
        otaBoardSessionArmed = false
        otaOwnerConnectGen = ownerConnectGen
        val session = ++otaSessionId
        setOtaPhase(OtaPhase.DOWNLOADING, pct = 0, message = "Downloading firmware…")
        otaJob = scope.launch {
            // 1) download off the main thread
            val bytes = withContext(Dispatchers.IO) {
                runCatching { downloadFirmwareArtifact(build.appUrl, build.size) }.getOrNull()
            }
            if (session != otaSessionId) return@launch   // cancelled mid-download
            if (bytes == null) {
                failOta("Could not download the firmware. Check your connection and try again.")
                return@launch
            }
            // 2) verify size + SHA-256 before we touch the board
            setOtaPhase(OtaPhase.VERIFYING, pct = 100, message = "Verifying download…")
            if (bytes.size.toLong() != build.size) {
                failOta("The download was the wrong size. Nothing was sent to the board. Try again.")
                return@launch
            }
            val sha = sha256Hex(bytes)
            if (!sha.equals(build.sha256, ignoreCase = true)) {
                failOta("The download failed its checksum. Nothing was sent to the board. Try again.")
                return@launch
            }
            if (session != otaSessionId) return@launch
            // The download/verify window is seconds long, and a disconnect during it skips the
            // midOta teardown (the phase is DOWNLOADING/VERIFYING, not CHECKING/SENDING), which
            // used to leave this job arming a null gatt. Re-check the link before touching the
            // board, like iOS beginTransfer.
            if (gatt == null || connectGen != ownerConnectGen || _state.value != ConnState.READY) {
                failOta("The board isn't connected. Reconnect and try again.")
                return@launch
            }
            if (!awaitOtaHoldReady(session)) {
                if (session != otaSessionId) return@launch
                failOta("Android could not keep the protected update session active. Nothing was sent to the board; keep the app open and try again.")
                return@launch
            }
            // 3) compute the zlib CRC-32 the firmware will match, and stage the image
            val crc = zlibCrc32(bytes)
            prepareChunks(bytes)
            // 4) Re-prove the protected hold at the exact mutation boundary. The download work
            // runs on Default while AcabLinkService.onDestroy is delivered on Main; moving the
            // proof and both serialized-queue inserts onto Main makes service loss unable to land
            // between them. The signature goes first, then begin.
            withContext(Dispatchers.Main.immediate) {
                if (session != otaSessionId) return@withContext
                if (gatt == null || connectGen != ownerConnectGen ||
                    _state.value != ConnState.READY) {
                    failOta("The board isn't connected. Reconnect and try again.")
                    return@withContext
                }
                if (!otaProtectedHoldReady()) {
                    failOta("Android could not keep the protected update session active. Nothing was sent to the board; keep the app open and try again.")
                    return@withContext
                }
                otaOwnerConnectGen = ownerConnectGen
                otaBoardSessionArmed = true
                setOtaPhase(OtaPhase.CHECKING, pct = 0, message = "Preparing the board…")
                otaLastProgressAt = System.currentTimeMillis()
                sendSig(build.sig)
                sendBegin(size = bytes.size, crc = crc, version = build.version)
                // 5) hand off to the notify-driven state machine; arm the stall watchdog
                watchForStall(session)
            }
        }
    }

    /** Cancel a running update: tell the board to abort and reset our state. Refused past the
     *  point of no return (the image is committed and the board is rebooting into it), like
     *  iOS's OTAState.isCancellable: a cancel there can't stop the flash - it could only orphan
     *  the confirm handshake (otaAwaitingConfirm outliving its session) and then contradict
     *  itself when the reconnect landed "Updated" over "Update cancelled." */
    fun cancelOta() {
        if (!otaCancellableNow()) return
        val touchedBoard = otaBoardSessionArmed
        val ownerGen = otaOwnerConnectGen
        otaSessionId++            // invalidate the running job + watchdog
        otaJob?.cancel(); otaJob = null
        otaStreaming = false
        // A "done" notify racing this cancel can have armed the confirm just after the phase
        // read above: drop it, or the flag outlives its session (the bump killed the loop that
        // would have consumed it) and the NEXT disconnect of any later session is misrouted
        // into the OTA reboot-confirm path, chasing a confirm that is not happening.
        otaAwaitingConfirm = false
        // Best-effort only on the exact GATT generation this run actually armed. A cancellation
        // during download/verify, or one racing a replacement link, must never manufacture an OTA
        // command on a board/session this run did not touch.
        if (gatt != null && otaAbortAllowed(
                boardSessionArmed = touchedBoard,
                ownerConnectGen = ownerGen,
                currentConnectGen = connectGen,
                phase = _otaProgress.value.phase,
                imageEnded = otaEnded,
                awaitingConfirm = otaAwaitingConfirm,
            )) {
            writeConfig(JSONObject().put("ota", JSONObject().put("abort", true)))
        }
        if (touchedBoard && ownerGen >= 0) otaQuarantinedConnectGen = ownerGen
        clearOtaStreamState()
        setOtaPhase(OtaPhase.FAILED, message = "Update cancelled.")
    }

    /** Once the end control is queued, the image may already be committing even before the board's
     * done reply changes phase. Keep that narrow interval non-cancellable too. */
    private fun otaCancellableNow(): Boolean =
        otaUserCancellationAllowed(_otaProgress.value.phase, otaEnded)

    /** After a good "done", the board reboots and the link drops. Wait for it to come back up,
     *  then reconnect to the same device so finishReady() can confirm the new version. Retries
     *  inside a 90 s window (iOS otaRebootTimeout parity); if the board never returns, report it
     *  (a dead board is the worst case, but the rollback arming means it should always come
     *  back on at least the previous firmware). */
    private fun reconnectAfterOta(device: BluetoothDevice) {
        // Re-entrancy guard: a failed attempt's DISCONNECTED runs cleanup() which (with
        // otaAwaitingConfirm still set) re-invokes this. Without the guard, two loops with the
        // same session would race, each opening its own connectGatt -> GATT_ERROR 133 and a
        // stranded confirm. One loop only.
        if (otaReconnecting) return
        otaReconnecting = true
        val session = otaSessionId
        scope.launch {
            try {
                delay(REBOOT_WAIT_MS)   // give the board time to reboot and re-advertise
                // Wall-clock bound, not an attempt count: iOS allows otaRebootTimeout (90 s)
                // before declaring the board missing, and a first boot of new firmware plus
                // re-advertise can legitimately take 40-80 s (flash validation, RF congestion).
                // The old 8 x 4 s loop gave up at ~35 s and reported "didn't come back" on
                // boards that were seconds from confirming.
                val deadline = SystemClock.elapsedRealtime() + REBOOT_GIVE_UP_MS
                while (session == otaSessionId && otaAwaitingConfirm &&
                       SystemClock.elapsedRealtime() < deadline) {
                    withContext(Dispatchers.Main) {
                        if (!hasConnectPermission()) {
                            teardownForBluetoothPermissionRevocation()
                            return@withContext
                        }
                        // The board is already bonded, so onConnectionStateChange goes straight to
                        // discovery -> the confirm check in finishReady(); if the user removed the
                        // pairing mid-wait, createBond runs and the process-lifetime bondReceiver
                        // picks the flow up. Close any prior (possibly still-pending, ~30s-timeout)
                        // client BEFORE opening a new one, or every 4s attempt leaks a GATT
                        // interface until the app hits the ~30-client ceiling and every connect
                        // fails with 133.
                        runCatching { gatt?.close() }
                        gatt = null
                        target = device
                        _deviceName.value = _deviceName.value ?: safeDeviceName(device)
                        _state.value = ConnState.CONNECTING
                        gatt = runCatching {
                            device.connectGatt(context, false, gattCb, BluetoothDevice.TRANSPORT_LE)
                        }.getOrNull()
                    }
                    delay(RECONNECT_ATTEMPT_MS)
                    // If we reached READY (state left CONNECTING), the confirm path has it now.
                    if (_state.value == ConnState.READY || !otaAwaitingConfirm) return@launch
                }
                if (session == otaSessionId && otaAwaitingConfirm) {
                    // Never came back inside the window. The board arms rollback on flash, so it
                    // should usually boot the previous firmware; tell the user it didn't reconnect.
                    otaAwaitingConfirm = false
                    setOtaPhase(OtaPhase.FAILED,
                        message = "The board didn't come back after the update. Power-cycle it and check its firmware; if the new image won't boot it usually recovers to the previous version, and if not you can re-flash it over USB.")
                    clearOtaStreamState()
                    // The last attempt left _state at CONNECTING with a dead (or null, on a
                    // toggled-off radio) client that may never fire a callback; once FAILED
                    // releases the OtaWaitScreen gate that renders as an endless no-cancel
                    // spinner. Land back on a recoverable resting state. CONNECTING-guarded so
                    // a connection that landed inside the last 4 s window (mid-bond/discovery,
                    // otaAwaitingConfirm still true) isn't killed; main thread to match every
                    // other gatt mutation.
                    withContext(Dispatchers.Main) {
                        if (_state.value == ConnState.CONNECTING) {
                            runCatching { gatt?.close() }
                            gatt = null
                            target = null
                            _state.value = restingState()
                        }
                    }
                }
            } finally {
                otaReconnecting = false
            }
        }
    }

    /** Arm an automatic reconnect after an UNEXPECTED drop (board power-cycle: unplugged/replugged
     *  or an ignition cut on the USB SKU; a walk out of and back into range). Without this the app
     *  strands on a dead "Reconnecting…" and the user has to reconnect by hand, so the background
     *  widget + Drive-mode notification never resync, the reported bug.
     *
     *  Mirrors iOS's pending CoreBluetooth connect: connectGatt(autoConnect = true) hands the
     *  platform a single connect with NO timeout that completes the moment the bonded board
     *  re-advertises, even while backgrounded (we hold the bluetooth foreground service + bonded
     *  link). autoConnect = true (not the connect-then-retry loop the OTA path uses) means ONE
     *  pending client, so repeated DISCONNECTED callbacks can't spawn the classic GATT_ERROR-133
     *  storm. On success onConnectionStateChange -> STATE_CONNECTED re-runs discovery -> handshake
     *  -> finishReady, which re-reads status, resubscribes, and flips _state to READY; the widget
     *  feed (samples _state) and the Drive-mode service (collects ble.state) then resync to
     *  connected on their own, no explicit widget poke needed here. */
    private fun autoReconnect(device: BluetoothDevice, name: String?) {
        // Re-entrancy guard: a pending client that briefly connects and drops again, or a burst of
        // DISCONNECTED callbacks, must not each open their own connectGatt. One armed attempt only.
        if (autoReconnecting) return
        if (!hasConnectPermission()) {
            teardownForBluetoothPermissionRevocation()
            return
        }
        autoReconnecting = true
        val gen = ++autoReconnectGen
        target = device
        reconnectClientArmed = true   // the iOS reconnectTarget analog; onRadioOff reads this
        _deviceName.value = name ?: safeDeviceName(device)
        _state.value = ConnState.CONNECTING   // the service + widget read this as "Reconnecting…"
        // Close any prior client before arming a new pending one, or we leak a GATT interface toward
        // the ~30-client ceiling that ends in 133s (same discipline as reconnectAfterOta). The board
        // is already bonded, so STATE_CONNECTED goes straight to discovery; bondReceiver is
        // process-lifetime, so a bond the user removed mid-wait still lands its BOND_BONDED here.
        runCatching { gatt?.close() }
        gatt = runCatching {
            device.connectGatt(context, /* autoConnect = */ true, gattCb, BluetoothDevice.TRANSPORT_LE)
        }.getOrNull()
        if (gatt == null) {
            autoReconnecting = false
            reconnectClientArmed = false
            cleanup()
            return
        }
        // Bound the "Reconnecting…" window like the iOS Live Activity's ~120s auto-end, so a board
        // that never returns (powered off and pocketed while Drive mode is on) doesn't hold a
        // device-less connectedDevice foreground service open forever. A successful reconnect clears
        // autoReconnecting in onConnectionStateChange, so this fires only if we're still stranded;
        // the gen check keeps a stale watchdog from a prior arm from tearing down a newer one.
        scope.launch {
            delay(AUTO_RECONNECT_WINDOW_MS)
            if (gen == autoReconnectGen && autoReconnecting && _state.value != ConnState.READY) {
                // Window elapsed with no reconnect. Clear the guard either way so a later drop or
                // radio toggle can re-arm cleanly.
                autoReconnecting = false
                // The pending client stays ARMED in BOTH branches. iOS's driveModeGraceExpired
                // ends only the Live Activity and leaves reconnectTarget chasing, so a board
                // that returns at minute 3 (long tunnel, gas stop, board on ignition power)
                // relinks by itself and the drive keeps logging; closing the client here ended
                // the drive's logging silently while claiming parity with an iOS auto-end that
                // never touched the reconnect. What DOES have to end at the window is Drive
                // mode's device-less connectedDevice foreground service (battery + Android 14's
                // FGS-without-device policy forbid holding it with no live link) - the service,
                // and only the service, matching iOS ending only the Activity. The widget-only
                // path has no service to protect and keeps its pending client as before.
                // onRadioOff/connect()/disconnect() still tear this client down.
                if (_driveMode.value) suspendDriveMode()
            }
        }
    }

    /** Dismiss a finished/failed banner back to idle (the button returns to its default copy). */
    fun clearOtaResult() {
        if (_otaProgress.value.phase == OtaPhase.DONE || _otaProgress.value.phase == OtaPhase.FAILED) {
            _otaProgress.value = OtaProgress()
        }
    }

    /** Hand the board the image signature before begin: {"ota":{"sig":"<hex DER>"}} on the
     *  Config char (same serialized path config uses). The board stages it and, in otaFinish,
     *  verifies the ECDSA P-256 signature over the streamed image's SHA-256 against its baked-in
     *  public key before committing. Kept as its own small message so each JSON stays compact. */
    private fun sendSig(sig: String) {
        writeConfig(JSONObject().put("ota", JSONObject().put("sig", sig)))
    }

    /** Write the OTA begin control object to the Config char (same path config uses). crc is the
     *  standard zlib CRC-32 as lowercase hex; the firmware parses it with strtoul base 16. */
    private fun sendBegin(size: Int, crc: Long, version: String) {
        val ota = JSONObject()
            .put("begin", true)
            .put("size", size)
            .put("crc", "%08x".format(crc))
            .put("ver", version)
            .put("force", false)
        writeConfig(JSONObject().put("ota", ota))
    }

    /** After a good "ready": start pushing the first chunk. The rest chain off the write
     *  callbacks in onCharacteristicWrite. */
    private fun beginStreaming() {
        otaChunkIdx = 0
        otaStreaming = true
        sendNextOtaChunk()
    }

    /** Queue the next image chunk as a WRITE_NO_RESPONSE op, or, once the last chunk is out,
     *  write the end control to commit the image. Paced one chunk per write callback. */
    private fun sendNextOtaChunk() {
        if (!otaStreaming) return
        if (otaChunkIdx >= otaChunks.size) {
            // Whole image handed off. Commit it; the board validates + reboots on a good end.
            otaStreaming = false
            // Mark the image committed so a disconnect after this reads as a probable success
            // (done notify lost / reboot raced ahead) rather than a false failure.
            otaEnded = true
            writeConfig(JSONObject().put("ota", JSONObject().put("end", true)))
            return
        }
        val chunk = otaChunks[otaChunkIdx++]
        enqueueGatt { g ->
            val c = charOf(g, AcabProfile.OTA)
            if (c == null) { onGattOpComplete(); failOta("Lost the update channel. Nothing was applied."); return@enqueueGatt }
            val queued = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(c, chunk, BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE) ==
                    BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION") c.value = chunk
                @Suppress("DEPRECATION") c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                @Suppress("DEPRECATION") g.writeCharacteristic(c)
            }
            // A synchronous rejection (stack busy) fires NO write callback, so the op slot would
            // never free and the whole GATT queue would wedge. Complete it ourselves and fail.
            if (!queued) { onGattOpComplete(); failOta("The board stopped accepting data. The update was not applied.") }
        }
    }

    /** Split the verified image into (negotiatedMtu - 3)-byte chunks up front. */
    private fun prepareChunks(bytes: ByteArray) {
        val chunkSize = (negotiatedMtu - 3).coerceAtLeast(20)
        val out = ArrayList<ByteArray>((bytes.size / chunkSize) + 1)
        var off = 0
        while (off < bytes.size) {
            val end = minOf(off + chunkSize, bytes.size)
            out.add(bytes.copyOfRange(off, end))
            off = end
        }
        otaChunks = out
        otaChunkIdx = 0
        otaTotalBytes = bytes.size
    }

    /** Watchdog: if the board goes quiet for too long during CHECKING/SENDING (no "ready"/"prog"
     *  and no "done"), the transfer has stalled. Bail with a clear message rather than hang. */
    private fun watchForStall(session: Int) {
        scope.launch {
            while (session == otaSessionId) {
                delay(STALL_CHECK_MS)
                if (session != otaSessionId) return@launch
                val phase = _otaProgress.value.phase
                if (phase != OtaPhase.CHECKING && phase != OtaPhase.SENDING) return@launch
                if (System.currentTimeMillis() - otaLastProgressAt > STALL_TIMEOUT_MS) {
                    failOta("The update stalled with no progress from the board. Keep the phone next to it and try again.")
                    return@launch
                }
            }
        }
    }

    /** Board rebooted after a flash and we've reconnected. If it now reports the target version,
     *  send confirm to disarm rollback; if it came back on a PARSEABLE older version, it rolled
     *  back and is safe; if the version string is garbage, say so without claiming either
     *  outcome. Runs off whichever status frame arrives first after READY (bounded by
     *  armPostRebootStatusCap). */
    private fun checkPostRebootConfirm() {
        if (!otaAwaitingConfirm) return
        // Not on the pre-reboot link: see otaRebootGen. Return WITHOUT consuming the flag, so the
        // real post-reconnect frame still gets to decide.
        if (connectGen == otaRebootGen) return
        val s = _status.value ?: return          // wait for a status frame to land (30 s cap)
        otaAwaitingConfirm = false
        val have = s.version
        val haveLabel = s.firmwareLabel
        // Confirm only on a PARSEABLE a.b[.c] version that is at least the target. A non-numeric
        // string (e.g. a fallback "ESP32") zeroed through isVersionAtLeast and landed in the
        // rollback branch, reporting a confident "rolled back ... running as before" for a board
        // that may well be RUNNING the new firmware with an unreadable version string. Neither
        // confirming nor claiming a rollback is honest there; iOS decideRebootOutcome draws the
        // same three-way line.
        when (decideOtaPostReboot(have, haveLabel, otaTargetVersion, otaTargetFwLabel)) {
            OtaPostRebootDecision.CONFIRM -> {
                otaOwnerConnectGen = connectGen
                otaBoardSessionArmed = true
                setOtaPhase(OtaPhase.CONFIRMING, pct = 100, message = "Confirming the update…")
                writeConfig(JSONObject().put("ota", JSONObject().put("confirm", true)))
                awaitDurableOtaConfirmation(otaSessionId)
            }
            OtaPostRebootDecision.LABEL_MISMATCH -> {
                setOtaPhase(OtaPhase.FAILED,
                    message = "The board came back identifying as $haveLabel instead of $otaTargetFwLabel, so rollback was left armed for safety. Reconnect and install the correct firmware for this board.")
                clearOtaStreamState()
            }
            OtaPostRebootDecision.ROLLED_BACK -> {
                // Came back on the previous firmware: the board's boot-attempt rollback reverted it.
                setOtaPhase(OtaPhase.FAILED,
                    message = "The board came back on its previous firmware, so it stayed safe. The update didn't take; try again.")
                clearOtaStreamState()
            }
            OtaPostRebootDecision.UNKNOWN -> {
                // Came back but didn't report a version we can trust; leave rollback armed.
                setOtaPhase(OtaPhase.FAILED,
                    message = "The board came back but didn't report the new version, so rollback was left armed for safety. Reconnect to check its firmware.")
                clearOtaStreamState()
            }
        }
    }

    /** Retry confirm until the firmware says its product-health gate was durably committed. A
     *  provisional health-wait is not success: rollback remains armed until an actual ok. */
    private fun awaitDurableOtaConfirmation(session: Int) {
        scope.launch {
            val deadline = System.currentTimeMillis() + CONFIRM_TIMEOUT_MS
            while (session == otaSessionId && _otaProgress.value.phase == OtaPhase.CONFIRMING) {
                delay(CONFIRM_RETRY_MS)
                if (session != otaSessionId || _otaProgress.value.phase != OtaPhase.CONFIRMING) return@launch
                if (System.currentTimeMillis() >= deadline) {
                    failOta("The new firmware is running, but the board did not confirm that rollback was disarmed. Keep it powered for a moment, then reconnect and check its firmware.")
                    return@launch
                }
                writeConfig(JSONObject().put("ota", JSONObject().put("confirm", true)))
            }
        }
    }

    /** Fail the current run with a reason and drop stream state. Board-side is left to its own
     *  abort/rollback (we don't force-write if the reason is a lost link). */
    private fun failOta(reason: String) {
        val touchedBoard = otaBoardSessionArmed
        val ownerGen = otaOwnerConnectGen
        otaSessionId++
        otaStreaming = false
        otaJob?.cancel(); otaJob = null
        // If the exact armed link is still live and was mid-transfer, tell that board to tear down
        // cleanly. A stale failure after reconnect must not enqueue abort on the replacement link.
        if (gatt != null && otaAbortAllowed(
                boardSessionArmed = touchedBoard,
                ownerConnectGen = ownerGen,
                currentConnectGen = connectGen,
                phase = _otaProgress.value.phase,
                imageEnded = otaEnded,
                awaitingConfirm = otaAwaitingConfirm,
            )) {
            writeConfig(JSONObject().put("ota", JSONObject().put("abort", true)))
        }
        if (touchedBoard && ownerGen >= 0) otaQuarantinedConnectGen = ownerGen
        clearOtaStreamState()
        setOtaPhase(OtaPhase.FAILED, message = reason)
    }

    private fun clearOtaStreamState() {
        otaChunks = emptyList()
        otaChunkIdx = 0
        otaTotalBytes = 0
        otaStreaming = false
        otaEnded = false
        otaBoardSessionArmed = false
        otaOwnerConnectGen = -1
    }

    // ---- OTA foreground-service hold ----
    // The chunk stream is paced by binder callbacks into THIS process; a backgrounded app can
    // be frozen (Android 12+ cached-app freezer, OEM battery managers), halting the stream
    // until both stall watchdogs abort the update. Hold the foreground service - shared with
    // Drive mode via start reasons, so neither lifecycle can kill the other's hold - from the
    // foreground user tap, before the download can outlive the Activity, through
    // REBOOTING/CONFIRMING (the reconnect loop needs the process alive too). Actual board writes
    // additionally wait for confirmed promotion; terminal phases release through setOtaPhase.
    @Volatile private var otaHoldingService = false
    @Volatile private var otaUsingCombinedServiceHold = false
    @Volatile private var otaHoldRequestedAt = 0L

    @Synchronized
    private fun acquireOtaHold(reuseConfirmedCombinedHold: Boolean): Boolean {
        if (otaHoldingService || otaUsingCombinedServiceHold) return true
        val accepted = acquireOtaHoldBoundary(
            reuseConfirmedHold = reuseConfirmedCombinedHold,
            serviceActive = driveServiceActive,
            requestOwnHold = {
                runCatching {
                    AcabLinkService.start(context, AcabLinkService.HOLD_OTA)
                }.getOrDefault(false)
            },
        )
        if (!accepted) return false
        // Do not claim the hold before the framework accepts its Intent. Promotion itself is
        // asynchronous and is proved separately by driveServiceActive. A combined leg already
        // passed that proof and must not request a new FGS start minutes after the foreground tap.
        if (reuseConfirmedCombinedHold) otaUsingCombinedServiceHold = true
        else otaHoldingService = true
        otaHoldRequestedAt = SystemClock.elapsedRealtime()
        return true
    }

    @Synchronized
    private fun releaseOtaHold() {
        val owned = otaHoldingService
        if (!owned && !otaUsingCombinedServiceHold) return
        otaHoldingService = false
        otaUsingCombinedServiceHold = false
        otaHoldRequestedAt = 0L
        if (owned) runCatching { AcabLinkService.stop(context, AcabLinkService.HOLD_OTA) }
    }

    private suspend fun awaitOtaHoldReady(session: Int): Boolean {
        while (session == otaSessionId) {
            val decision = foregroundServiceHoldDecision(
                requestAccepted = otaHoldingService || otaUsingCombinedServiceHold,
                serviceActive = driveServiceActive,
                elapsedMs = (SystemClock.elapsedRealtime() - otaHoldRequestedAt).coerceAtLeast(0L),
                timeoutMs = OTA_HOLD_PROMOTION_TIMEOUT_MS,
            )
            when (decision) {
                ForegroundServiceHoldDecision.READY -> return true
                ForegroundServiceHoldDecision.FAILED -> return false
                ForegroundServiceHoldDecision.WAIT -> delay(OTA_HOLD_POLL_MS)
            }
        }
        return false
    }

    private fun otaProtectedHoldReady(): Boolean =
        (otaHoldingService || otaUsingCombinedServiceHold) && driveServiceActive

    private fun setOtaPhase(phase: OtaPhase, pct: Int = _otaProgress.value.pct, message: String = _otaProgress.value.message) {
        when (phase) {
            OtaPhase.DONE, OtaPhase.FAILED -> releaseOtaHold()
            else -> {}
        }
        _otaProgress.value = OtaProgress(phase = phase, pct = pct.coerceIn(0, 100),
            message = message, targetVersion = otaTargetVersion)
    }

    /** Download the whole firmware artifact into memory (~1 MB) on the caller's (IO) thread. Capped at the
     *  manifest's declared size so a misconfigured/compromised server can't OOM the app before
     *  the size + SHA gate runs. */
    private fun downloadFirmwareArtifact(url: String, expectedSize: Long): ByteArray {
        val parsed = trustedFirmwareArtifactUrl(url)
            ?: throw java.io.IOException("firmware URL is not on the trusted host")
        val conn = (parsed.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15_000
            readTimeout = 20_000
            instanceFollowRedirects = false
        }
        try {
            val responseCode = conn.responseCode
            if (!firmwareArtifactResponseAllowed(parsed, conn.url, responseCode))
                throw java.io.IOException("HTTP $responseCode or redirect refused")
            // Read at most the declared size (+ a hard 8 MB ceiling); a longer stream is rejected
            // before it can exhaust memory. The exact size is re-checked against the manifest after.
            val cap = expectedSize.coerceIn(1L, 8L * 1024 * 1024)
            val out = java.io.ByteArrayOutputStream(cap.toInt())
            conn.inputStream.use { input ->
                val tmp = ByteArray(16 * 1024)
                var total = 0L
                while (true) {
                    val r = input.read(tmp)
                    if (r < 0) break
                    total += r
                    if (total > cap) throw java.io.IOException("firmware exceeds declared size")
                    out.write(tmp, 0, r)
                }
            }
            return out.toByteArray()
        } finally {
            conn.disconnect()
        }
    }

    private fun sha256Hex(bytes: ByteArray): String =
        MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /** Standard zlib/PKZIP CRC-32 over the whole image, matching the firmware's crc32_update. */
    private fun zlibCrc32(bytes: ByteArray): Long =
        CRC32().apply { update(bytes) }.value   // already the reflected poly 0xEDB88420

    private fun ingest(uuid: java.util.UUID, bytes: ByteArray) {
        val rawJson = String(bytes, Charsets.UTF_8)
        val json = runCatching { JSONObject(rawJson) }.getOrNull() ?: return
        when (uuid) {
            AcabProfile.DETECTIONS -> {
                // The drain's sentinels carry hist as a STRING (live and per-record frames use a
                // bool): "begin" gives the total up front for a determinate pill, "end" closes it.
                if (json.optString("hist") == "begin") {
                    histBeginSeen = true
                    val total = json.optInt("n", 0)
                    _offlineSyncTotal.value = total
                    // Newer firmware stamps "from" = the first seq this drain will send. After a
                    // board-side buffer wipe or key-change the seq generation resets low, so our
                    // persisted cursor can sit ABOVE every seq the board is about to send: the
                    // contiguous-advance in fileHistory then never matches (from != lastSeq+1) and
                    // the whole buffer re-replays on every reconnect. Rebase the cursor DOWN to
                    // from-1 so the next in-order seq == from advances it again. Only when it's
                    // actually lower (an ordinary reconnect has from > lastSeq and must be left
                    // alone); absent "from" (older firmware) keeps the current cursor untouched.
                    // Only an exact uint32 real-record seq (>= 1) may rebase, matching iOS's
                    // `from >= 1` + UInt32(exactly:) gate. Read the raw lexeme: Android's
                    // JSONTokener rounds decimal/exponent tokens to Double, so optLong would turn
                    // `1.0000000000000000001` into cursor 1. Zero/malformed/fractional/out-of-range
                    // all mean "do not rebase"; subtraction below is therefore uint32-safe.
                    val from = historyBeginFromOrAbsent(rawJson)
                    val generation = historyBeginGenerationOrAbsent(rawJson)
                    if (json.has("gen") && generation == 0L) {
                        // A present-but-invalid generation is not legacy firmware. Forget numeric
                        // cursor authority for this attempt and refuse to persist generation 0;
                        // the next sync advertises unknown and firmware offers the full window.
                        activeLogGeneration = 0L
                        invalidateCursorCheckpoints()
                        val rebase = if (from >= 1L) from - 1L else 0L
                        lastSeq = rebase
                        histHighestContiguous = rebase
                    } else if (generation > 0L && generation != activeLogGeneration) {
                        // A new ring generation invalidates the numeric meaning of every old
                        // cursor, even when the fresh log has already grown past it. Keep this
                        // rebase in memory until a store checkpoint lands; after a crash the old
                        // persisted generation mismatches again and firmware safely replays all.
                        activeLogGeneration = generation
                        invalidateCursorCheckpoints()
                        val rebase = if (from >= 1L) from - 1L else 0L
                        lastSeq = rebase
                        histHighestContiguous = rebase
                    } else if (from >= 1L) {
                        val rebase = from - 1L
                        if (rebase < lastSeq) {
                            lastSeq = rebase
                            histHighestContiguous = rebase
                            persistCursor(
                                rebase,
                                logGeneration = activeLogGeneration,
                                forward = false,
                            )
                        }
                    }
                    if (total > 0) _syncingOfflineLog.value = true   // a real replay is starting
                    return
                }
                if (json.optString("hist") == "end") { onHistEnd(json.optInt("n", 0)); return }
                // Keep the original numeric lexemes through the model boundary. Android's
                // JSONTokener rounds decimal/exponent values to Double, so the parsed object alone
                // cannot tell an integer 1 from a wire token such as 1.0000000000000000001.
                val d = Detection.fromWireJson(rawJson, json)
                // History records bypass the ignore drop: fileHistory must run its drain
                // bookkeeping (seq cursor, histReceived, pill) for EVERY replayed record or
                // the drain never closes - it skips the FILING of ignored records itself.
                // Dropping them here froze the cursor below their seq and re-drained the whole
                // buffer forever (the offline-replay livelock).
                if (d.hist) { fileHistory(d); return }
                // Only the CURRENT watchlist beats a current mute. WATCHED on the wire is capture-
                // time history; after an unstar + mute it must not remain a permanent bypass.
                if (isMutedForProjection(d.mac)) return
                fileLive(d)
            }
            AcabProfile.STATUS -> {
                val s = DeviceStatus.fromJson(json)
                _status.value = s
                val revision = statusRevision.incrementAndGet()
                nrfDfu.handleStatusUpdate(s, connectGen.toLong(), revision)
                reconcileBuzzer(s)
                reconcileDesert(s)   // rare since firmware persists Desert; still needed for older boards / NVS wipe
                if (!managedListsReady) {
                    // A present-but-unreadable encrypted list is not an authoritative empty list.
                    // Keep unrelated status/OTA handling alive, but do not push or acknowledge
                    // either managed list until a later process load can open the preserved bytes.
                    if (otaAwaitingConfirm) checkPostRebootConfirm()
                    return
                }
                managedListEdits.withLock {
                // Read counts, decide, push, and durably retire a matching clear ACK under the
                // same boundary as paired list edits. Otherwise an ACK calculated for generation
                // N can clear the pending bit while generation N+1 is concurrently committing a
                // fresh empty list, losing the only crash-safe instruction to clear the board.
                if (!managedListsReady) return@withLock
                // Reconcile the board-backed whitelist without treating an empty phone as
                // authoritative. A fresh install or second phone knows only the board's count,
                // not its MACs, so sending [] for a larger board list would destroy settings it
                // cannot reconstruct. Empty is sent only for a persisted explicit user clear.
                // Reconcile against what the board CAN hold, never against our raw size: the
                // board keeps at most IGNORE_CAP and reports that truncated count, so a longer
                // list here can never converge. The cap in ignoreDevice keeps us from getting
                // there; MAX_LIST_PUSH_ATTEMPTS below catches every OTHER divergence.
                val expectedBoardIgnores = minOf(boardIgnoredMacs().size, IGNORE_CAP)
                val ignoreAction = boardIgnoreSyncAction(
                    localPermanentCount = expectedBoardIgnores,
                    boardReportedCount = s.ignoreCount,
                    intentionalClearPending = listClearPending("ignore"),
                )
                if (ignoreAction == BoardIgnoreSyncAction.PUSH_LIST ||
                    ignoreAction == BoardIgnoreSyncAction.PUSH_CLEAR) {
                    // BOUNDED, like every other convergence loop in this file (reconcileBuzzer's
                    // MAX_BUZZER_REASSERTS, onHistEnd's HIST_RESYNC_MAX). A count the board can
                    // never match - a MAC its parseMac6 rejects, a list saved by an older build,
                    // or a v1.7 board with no "watch" handler that never reports "wat" (optInt
                    // reads the missing key as 0) - leaves the two sides permanently unequal, and
                    // the commit chunk of every push we make sets the firmware's statusDirty, so
                    // the status notify that comes back asks for the next push. Unbounded that
                    // ran for the whole session: one full-list re-push (13 chunk writes at
                    // IGNORE_CAP) per status frame on the SERIALIZED GATT queue, ahead of every
                    // buzzer/toggle/GPS write behind it, and acabScannerSetIgnoreList rewrites
                    // the board's NVS on each committed round. Past the cap, stop asking: the
                    // phone-side mute still holds (ingest drops muted MACs itself) and the next
                    // connection or user edit re-arms the attempts.
                    if (ignorePushAttempts < MAX_LIST_PUSH_ATTEMPTS) {
                        ignorePushAttempts++
                        sendIgnoreList(
                            intentionalClear = ignoreAction == BoardIgnoreSyncAction.PUSH_CLEAR,
                            userEdit = false,
                        )
                    }
                } else {
                    // The board agrees, or has just proved it took the clear: the next divergence
                    // starts from a full budget.
                    ignorePushAttempts = 0
                    if (ignoreAction == BoardIgnoreSyncAction.ACK_CLEAR) retireListClearPending("ignore")
                }
                // The watchlist uses the same authority rule, and the same bound. In particular,
                // an empty-list clear stays pending until a STATUS frame proves the board accepted
                // it; retiring that intent when the write was merely queued loses the clear if the
                // link drops first.
                val watchAction = boardIgnoreSyncAction(
                    localPermanentCount = minOf(_watched.value.size, IGNORE_CAP),
                    boardReportedCount = s.watchCount,
                    intentionalClearPending = listClearPending("watch"),
                )
                if (watchAction == BoardIgnoreSyncAction.PUSH_LIST ||
                    watchAction == BoardIgnoreSyncAction.PUSH_CLEAR) {
                    if (watchPushAttempts < MAX_LIST_PUSH_ATTEMPTS) {
                        watchPushAttempts++
                        sendWatchList(userEdit = false)
                    }
                } else {
                    watchPushAttempts = 0
                    if (watchAction == BoardIgnoreSyncAction.ACK_CLEAR) retireListClearPending("watch")
                }
                }
                // If we're mid-OTA and this is the first status after the reboot, the version
                // is now known: confirm the flash (or report the rollback).
                if (otaAwaitingConfirm) checkPostRebootConfirm()
            }
            AcabProfile.OTA -> handleOtaNotify(json)
        }
    }

    // ---- OTA progress notifies from the board (on the acab0104 char) ----

    /** Route a `{"ota":...}` frame from the board through the update state machine. See
     *  otaResultStr() in firmware ota_update.cpp for the exact "err" code strings.
     *
     *  Every arm is gated on the phase, which is Android's shape of iOS's live-uncancelled-
     *  session guards in otaHandleNotify. A cancel bumps the session but notifies already in
     *  flight (and the board's own abort echo) still land here, and ungated they reanimated a
     *  cancelled run (a late "ready" streamed the chunk list cancelOta had just cleared) or
     *  clobbered its "Update cancelled." terminal copy. */
    private fun handleOtaNotify(json: JSONObject) {
        val kind = json.optString("ota")
        if (kind == "nrf-ready") { nrfDfu.handleArmReply(true, connectGen.toLong()); return }
        if (kind == "nrf-denied") { nrfDfu.handleArmReply(false, connectGen.toLong()); return }
        if (json.optString("pwr") == "off") {
            // The board is deep-sleeping on purpose (a physical button-hold or an app power-off). Flag
            // the coming STATE_DISCONNECTED as a deliberate teardown so onConnectionStateChange runs
            // cleanup(forAutoReconnect=false) with no error banner and no reconnect loop. Arming HERE,
            // on the board's own confirmation rather than in powerOff(), means a board that never
            // actually powers off never sends this and so never mis-flags a later unrelated drop.
            userInitiatedDisconnect = true
            autoReconnecting = false
            return
        }
        // The current protocol has no S3 OTA session id on replies. Bind every reply to the exact
        // encrypted GATT generation that sent begin/confirm, and require an armed app-side session.
        // Failed/cancelled board-touched runs are additionally quarantined until reconnect.
        if (!otaReplyBelongsToArmedSession(
                otaBoardSessionArmed, otaOwnerConnectGen, connectGen)) return
        val phase = _otaProgress.value.phase
        when (kind) {
            "ready" -> {
                // begin accepted: the board opened its OTA slot. Start streaming the image.
                // Only meaningful while THIS run is waiting on it.
                if (phase != OtaPhase.CHECKING) return
                otaLastProgressAt = System.currentTimeMillis()
                setOtaPhase(OtaPhase.SENDING, pct = 0)
                beginStreaming()
            }
            "prog" -> {
                // ~every 64 KB. Trust the board's own pct so the bar tracks flash, not just
                // packets the controller buffered. Ignored unless we're actually streaming: a
                // late prog after a FAILED run flipped the card back to SENDING with the
                // watchdog already dead (session bumped), wedging it there for good.
                if (phase != OtaPhase.SENDING) return
                otaLastProgressAt = System.currentTimeMillis()
                val pct = json.optInt("pct", _otaProgress.value.pct)
                setOtaPhase(OtaPhase.SENDING, pct = pct)
            }
            "done" -> {
                // Image validated and set as the boot slot; the board reboots ~250 ms later.
                // Arm the post-reboot confirm and let the existing reconnect logic take over.
                // Require this run to have handed its complete image to the board. A delayed done
                // from an earlier same-board session must not reboot-confirm a new partial run.
                if (!otaDoneCanAdvance(phase, otaEnded)) return
                otaStreaming = false
                otaBoardSessionArmed = false
                otaAwaitingConfirm = true
                // The board has NOT rebooted yet (~250 ms away) and this link is still up, so pin
                // the generation: no frame from it may decide the outcome. See otaRebootGen.
                otaRebootGen = connectGen
                setOtaPhase(OtaPhase.REBOOTING, pct = 100,
                    message = "Board is rebooting into the new firmware.")
            }
            "ok" -> {
                // Reply to our confirm: rollback disarmed, we're settled on the new version.
                if (phase == OtaPhase.CONFIRMING) {
                    setOtaPhase(OtaPhase.DONE, pct = 100,
                        message = "Updated to v$otaTargetVersion.")
                    clearOtaStreamState()
                }
            }
            "health-wait" -> {
                // Provisional reply. The bounded confirmation loop keeps asking until the board
                // has durably disarmed rollback and answers ok.
                if (phase != OtaPhase.CONFIRMING) return
            }
            "abort" -> {
                // The board tore its session down. Only report it while a run is still LIVE:
                // cancelOta writes {abort} and the board echoes it back, and that echo used to
                // overwrite "Update cancelled." on every single cancel. iOS ignores the echo
                // the same way once its state is terminal.
                if (phase != OtaPhase.IDLE && phase != OtaPhase.DONE && phase != OtaPhase.FAILED) {
                    failOta("The update was stopped on the board.")
                }
            }
            "err" -> {
                // Same terminal-state guard as abort: chunks already queued when a cancel lands
                // keep flowing and draw per-chunk err:state replies that must not clobber the
                // cancel copy.
                if (phase != OtaPhase.IDLE && phase != OtaPhase.DONE && phase != OtaPhase.FAILED) {
                    failOta(otaErrorMessage(json.optString("e").ifEmpty { "unknown" }))
                }
            }
        }
    }

    /** Map a firmware OtaResult code (otaResultStr) to plain user copy. Mirrored VERBATIM from
     *  iOS OTAText.forBoardError - the two platforms explain the same board event with the same
     *  words, so keep them in lockstep when either changes. */
    private fun otaErrorMessage(code: String): String = when (code) {
        "busy"      -> "The board is already in the middle of an update. Disconnect, wait a moment, and try again."
        "not-newer" -> "The board is already on this version or newer, so there's nothing to install."
        "size"      -> "The update didn't transfer completely. Check your connection and try again."
        "begin"     -> "The board doesn't have room for the update. This build may be too large for it."
        "write"     -> "The board couldn't write the update to flash. Try again."
        "crc"       -> "The update failed its integrity check. The download may be corrupt; try again."
        "image"     -> "The board rejected the update as invalid. Make sure this build is for your board."
        "sig"       -> "The board couldn't verify this update was signed by the beacon maker, so it refused to install it. Only official signed firmware can be installed over the air."
        "stall"     -> "The update stalled and the board cancelled it. Stay close to the beacon with the app open, and try again."
        "state"     -> "The update fell out of step with the board. Try again."
        else        -> "The board reported an error ($code). Try again."
    }

    /** A live detection: timestamp is now, and a fresh sighting may buzz the phone. */
    private fun fileLive(d: Detection) {
        synchronized(storeLock) {
            // Read the clock only after acquiring the same lock Stop freezes under. Whichever
            // operation wins the lock defines the boundary, so a callback cannot carry a
            // pre-Stop timestamp while filing after the frozen snapshot.
            val observedAt = System.currentTimeMillis()
            // One observer read and one wall-clock instant describe this exact sighting. The
            // capture-local sample is independent of capturedLoc's session-global closest pin.
            val observer = freshSelfCoord()
            val first = !firstSeenAt.containsKey(d.id)
            if (first) {
                firstSeenAt[d.id] = observedAt
                // Stamp the hit with the phone's position only when the phone's fix is actually
                // fresh. lastLat/lastLon are a LAST-SEEN value with no expiry: once the platform
                // stops delivering (activity gone, permission revoked mid-drive) they hold their
                // final value forever, and a frozen coordinate is not a missing coordinate - it
                // pins the rest of the drive on the driveway, in the map and in the CSV both.
                // validCoord can't catch this: a two-hour-old coordinate is a valid coordinate.
                val self = observer
                if (self != null) {
                    // capturedLoc is always the OBSERVER PHONE's position. A drone's d.lat/d.lon
                    // is its aircraft position, but the contribution export has independent
                    // approx_lat/lon and drone_lat/lon columns and must be able to populate both.
                    capturedLoc[d.id] = self
                    if (d.lat == null) {
                        bestRssi[d.id] = d.rssi   // the bar a later, closer sighting has to beat
                    }
                }
            }
            lastSeenAt[d.id] = observedAt
            file(d, observedAt)   // appends this sample to rssiHistory, so smoothing sees it
            // Record only after the live row is filed. History uses fileHistory and can never
            // enter this ledger, so a replay-only bracketed row cannot be relabeled `exact` by a
            // capture merely because it arrived between Start and Stop.
            contributionCapture.record(d, observedAt, observer)
            // Seed a missing observer fix on any later sighting, INCLUDING a drone: its own
            // aircraft coordinate does not fill the separate observer columns. For devices
            // without an authoritative broadcast coordinate, later sightings also migrate the
            // phone pin at a >= 4 dB stronger closest approach (hysteresis vs RSSI wobble).
            if (!first) {
                val smoothed = rssiHistory[d.id]?.takeLast(3)?.average()?.roundToInt() ?: d.rssi
                if (capturedLoc[d.id] == null) {
                    observer?.let { self ->
                        capturedLoc[d.id] = self
                        if (d.lat == null) bestRssi[d.id] = smoothed
                    }
                } else if (d.lat == null) {
                    val prevBest = bestRssi[d.id]
                    if (prevBest == null || smoothed - prevBest >= 4) {
                        observer?.let { self ->
                            capturedLoc[d.id] = self
                            bestRssi[d.id] = smoothed
                        }
                    }
                }
            }
            // Tracker breadcrumb trail: while a TRACKER stays with us, drop a crumb of the PHONE's
            // position, gated by time AND distance so a stationary stakeout doesn't stack crumbs
            // on one spot. Session-scoped, in-memory (like drone tracks).
            if (d.type == DeviceType.TRACKER) {
                val self = observer
                if (self != null) {
                    val crumbs = crumbHistory.getOrPut(d.id) { mutableListOf() }
                    val last = crumbs.lastOrNull()
                    val moved = last == null || run {
                        val out = FloatArray(1)
                        Location.distanceBetween(last.first, last.second, self.first, self.second, out)
                        out[0] >= 25f
                    }
                    if (last == null || (observedAt - (lastCrumbAt[d.id] ?: 0L) >= 60_000L && moved)) {
                        crumbs.add(self)
                        // Only when absent: this is the START of the crumb window and must never
                        // advance. putIfAbsent semantics spelled out rather than assumed, because
                        // a stray unconditional write here would silently collapse every scored
                        // duration to zero and refuse every tag on the clock-sanity test.
                        if (!firstCrumbAt.containsKey(d.id)) firstCrumbAt[d.id] = observedAt
                        lastCrumbAt[d.id] = observedAt
                        if (crumbs.size > 120) crumbs.subList(0, crumbs.size - 120).clear()
                    }
                }
            }
        }
        // The only thing that puts a live session on disk. See checkpointDetections.
        checkpointDetections()
        // hapticDue RECORDS, so it stays LAST: the cheap gates short-circuit ahead of it, and a
        // buzz suppressed by DND must not start the cooldown that suppressed it.
        if (_alertMode.value == AlertMode.VIBRATE && !focusSuppressed() && hapticDue(d.mac)) alertHaptic(d.type)   // buzz past the per-device cooldown, unless DND/Focus is on
        // Phone notification, per category, opt-in. INDEPENDENT of alertMode: that governs the
        // board buzzer, and a silent board is not a silent phone. Ignored devices are dropped
        // before this point so they can never notify.
        //
        // The lock-screen redaction toggle rides along here as well as on Live Mode: with it on,
        // a locked screen shows "Something was detected nearby." instead of naming the category.
        // That is a surface iOS's same-named toggle does not cover, and it is kept on purpose: on
        // this product, quieter is the safe side of a mismatch. The toggle's subtitle names it.
        // See the _redactLockScreen declaration for the full scope.
        //
        // NOT gated on `firstTime`, deliberately: that is `store[d.id] == null` and the store is
        // PERSISTED across launches, so a device seen in any earlier session was never first again
        // and could never notify. The notifier owns the dedup via its per-device cooldown.
        if (!d.hist && DetectionNotifier.anyEnabled(context)) {
            notifier.notifyIfNeeded(d, _redactLockScreen.value)
        }
    }

    /** A replayed history record. Use the board's recorded timestamp when it has one;
     *  otherwise fall back to a monotonically-DECREASING pseudo-time derived from seq, so
     *  the newest-first display never pulls old history up to "now". Never buzzes. */
    private fun fileHistory(src: Detection) {
        // Tag it as an offline-buffer record so the log row can show the "OFFLINE" chip; this
        // is the ONLY place the flag is set true (the live path leaves it false).
        val d = src.copy(offline = true)
        val ts = when {
            d.at > 0L -> d.at * 1000L                       // absolute: exact moment it was seen
            else -> HIST_PSEUDO_BASE - d.seq * 1000L        // approx: order-only, strictly before now
        }
        synchronized(storeLock) {
            // Two axes live in these maps: real clock stamps and the seq pseudo-time above.
            // isApproxTime is the only thing that tells them apart, and EVERY pseudo stamp
            // sorts before EVERY real one, so a bare "earlier wins" hands the pseudo stamp the
            // win every time and a replay overwrites the real moment we heard the device live.
            // The board re-sends approx records after any reboot (an ignition cut on the USB
            // SKU is a reboot), and the store now survives a disconnect, so that replay lands
            // on retained live rows as a matter of course. Rule: only compare stamps on the
            // same axis, so a genuinely-earlier record of the same kind still wins and a real
            // stamp, once known, is never traded for a pseudo one.
            val prevFirst = firstSeenAt[d.id]
            if (prevFirst == null || (isApproxTime(prevFirst) == isApproxTime(ts) && ts < prevFirst)) {
                firstSeenAt[d.id] = ts
            }
            // Last-seen ADVANCES across a replay (iOS ingestHistory keeps the newer stamp): a
            // device with several buffered sightings must report its latest, not whichever
            // record happened to replay first - the dossier's last-seen, isStale's verdict and
            // the widget's "last sighting" pick all read this. A raw max() is sound across the
            // two axes too, because every pseudo stamp sits strictly below every real one: a
            // pseudo stamp can never displace a real clock reading, while a real reconstructed
            // stamp may upgrade a pseudo one, exactly as on iOS.
            val prevLast = lastSeenAt[d.id]
            if (prevLast == null || ts > prevLast) lastSeenAt[d.id] = ts
            // Same downgrade, one layer down: detectionsCsv blanks detected_at for any row
            // whose approx flag is set, so re-filing an approx record over a row we heard live
            // erases the real capture time from the file people hand over as evidence. The
            // stamp guard above cannot prevent that, because the CSV tests the STORE ROW, not
            // the stamp. Keep the live row and drop the replayed one, but still count it below
            // so the replay cursor and the syncing pill advance. Skipping file() also skips
            // this record's RSSI append and republish, which is what we want: the live row we
            // are keeping is the fresher truth.
            val prev = store[d.id]
            val downgradesLiveRow = d.approx && prev != null && !prev.approx && !prev.offline
            // An ignored MAC's buffered records still reach here (ingest routes ALL hist
            // frames in) so the bookkeeping below always runs; only the FILING is skipped,
            // mirroring downgradesLiveRow. The record then advances the cursor contiguously,
            // the drain closes clean, and it is never replayed.
            val dropIgnored = isMutedForProjection(d.mac)
            // Anchor evidence is drain-level knowledge about the BOOT, not about this row's
            // basis: an anchored record proves its boot's span whether or not its stamp sticks
            // as the row's firstSeen below, and gating the widening on that guard threw away
            // bounds that would have bracketed the neighbouring unanchored boots. iOS widens
            // histAnchoredBoots for every anchored record before any filing guard; ignored MACs
            // feed anchors on neither platform.
            if (!dropIgnored && d.at > 0L && d.boot > 0L) {
                bootMinAt[d.boot] = minOf(bootMinAt[d.boot] ?: d.at, d.at)
                bootMaxAt[d.boot] = maxOf(bootMaxAt[d.boot] ?: d.at, d.at)
            }
            if (!downgradesLiveRow && !dropIgnored) {
                file(d, ts)
                // Only claim the time quality when this record's stamp is the one that stuck.
                // A row whose firstSeen came from a live sighting keeps an Exact basis, and a
                // replayed record that lost the guard above must not relabel it.
                if (firstSeenAt[d.id] == ts) noteHistTime(d, ts)
            }
        }
        // Advance the in-memory contiguous cursor, but DON'T rewrite the whole detections file
        // per record - onHistEnd checkpoints once the drain ends. If a drain is interrupted, we
        // just re-drain from the last checkpoint; filing is idempotent by id, so nothing is lost
        // or duplicated (vs. a full write per record).
        // Records whose begin notify was lost are still retained as evidence, but cannot move a
        // cursor whose generation was never established. The fresh-envelope retry re-files them
        // idempotently after it sees begin.
        if (historyEnvelopeAuthorizesCheckpoint(histBeginSeen) && d.seq == lastSeq + 1) {
            lastSeq = d.seq
            // Checkpoint every ~200 contiguous records so an app restart mid-drain resumes from
            // near here instead of re-pulling everything since the last clean end. The store
            // write and the cursor ride the SAME checkpoint (write-ahead; see checkpointHistory):
            // the bare prefs write that used to sit here covered process death for the CURSOR
            // while the records it acknowledged were still RAM-only - a kill at record 900 of a
            // 1000-record drain left prefs claiming ~800 filed, the sealed store never written,
            // and the board never re-sends an acked seq, so rows 1..800 were gone from both
            // ends. Skip while one is in flight (each checkpoint re-seals the whole store);
            // onHistEnd's final checkpoint is the one that has to be complete.
            if (lastSeq % 200L == 0L && !checkpointInFlight) checkpointHistory()
        }
        if (historyEnvelopeAuthorizesCheckpoint(histBeginSeen) &&
            d.seq > histHighestContiguous) histHighestContiguous = d.seq
        histReceived++
        _offlineSyncCount.value = histReceived   // let the "syncing" pill climb live
    }

    /** Record how a just-filed buffered record's stamp was arrived at. Called under storeLock,
     *  and only when this record's stamp is the one that stuck as the row's firstSeen. (The
     *  per-boot anchor bounds are widened in fileHistory for EVERY anchored record, stuck or
     *  not: they are evidence about the boot, not about this row's basis.) */
    private fun noteHistTime(d: Detection, ts: Long) {
        if (d.at > 0L) {
            // The board held an anchor for this record's boot and dated it against that.
            histTime[d.id] = HistTime(TimeBasis.Reconstructed(ts, precisionFor(ts)), ts)
        } else {
            // The app never connected during the boot that captured this, so the board has no
            // anchor to date it against. Worst case for now; resolveBrackets upgrades it when the
            // drain closes and the boots either side of it are known.
            histTime[d.id] = HistTime(TimeBasis.Unknown, HIST_PSEUDO_BASE + d.seq)
            // Under storeLock. noteHistTime is called OUTSIDE file()'s own lock, so this add ran
            // unguarded against resolveBrackets' take-and-clear and against the clears on the
            // disconnect and clear-log paths. ArrayList is not thread-safe; the failure is a
            // corrupted list, not a lost row. synchronized is reentrant, so nesting is harmless.
            synchronized(storeLock) { pendingBracket.add(PendingBracket(d.id, d.boot, d.ms, d.seq)) }
        }
    }

    /** How wide a reconstructed stamp could be off, in whole seconds.
     *
     *  Two error sources stack. The board's crystal is specified to roughly +/-20 ppm, so a stamp
     *  carried back across E seconds of uptime can have drifted E * 0.00002. Under that sits the
     *  anchor itself: the epoch we pushed crossed a BLE round trip before the board stored it, and
     *  no amount of short elapsed time removes that couple of seconds. So it is the drift, floored.
     *
     *  The elapsed span is an APPROXIMATION and worth being plain about. The exact figure is
     *  (anchor.atMs - record.whenMs) on the board's own uptime clock, and the board never sends
     *  anchor.atMs. What the app has is the reconstructed stamp and the instant it pushed the
     *  anchor, so it measures the same span on the phone's clock instead of the board's. The two
     *  disagree by exactly the drift being measured, which is parts per million of it, so it
     *  cannot move the answer by a second. */
    private fun precisionFor(atMs: Long): Int {
        // anchorPushedAt is 0 until this process first pushes an epoch in sendHandshake, and
        // the startup reload runs before any connection: measured against 0 the elapsed span
        // went hugely negative, coerced to zero, and every legacy row reloaded claiming the
        // 2 s floor however old it was - the exact opposite of the deliberately wide bar the
        // reload asks for. No anchor yet means measure the age against now, matching iOS's
        // `syncStartedAt ?? Date()`.
        val anchorMoment = if (anchorPushedAt > 0L) anchorPushedAt else System.currentTimeMillis()
        val elapsedSec = ((anchorMoment - atMs) / 1000L).coerceAtLeast(0L)
        return maxOf(TIME_ANCHOR_FLOOR_SEC, Math.round(elapsedSec * CRYSTAL_DRIFT).toInt())
    }

    /** Bound this drain's unanchored records against the anchored boots either side of them.
     *
     *  The board can only date a record when the app connected during the boot that captured it.
     *  For every other record all it can say is which boot session it came from. Boot counters are
     *  monotonic, so an unanchored boot B still falls strictly after every anchored boot below it
     *  and strictly before every anchored boot above it, and the spans of those two bound it. That
     *  is a real bound rather than a guess, which is the only reason it is allowed on screen.
     *
     *  Rows left over from an EARLIER drain are re-checked too, mirroring iOS
     *  resolveBracketedHistory: a boot number orders against this drain's anchors just as
     *  soundly as against its own, so a later sync tightens rows that were undateable when they
     *  were filed (a drain cut short, a first-ever sync of unanchored boots) instead of leaving
     *  them "time unknown" forever.
     *
     *  Runs once per drain rather than once per record, and does its work on snapshots, so
     *  storeLock is only held for the copy in and the apply out. */
    private fun resolveBrackets() {
        // Take the batch and the boot bounds in ONE locked section. Two reasons it has to be one:
        // the take-and-clear was racing noteHistTime's add (ArrayList, not thread-safe), and
        // snapshotting the bounds separately let a record file in between, so it would be dropped
        // from this batch while its boot's bounds were already folded in. The heavy work below
        // stays OUTSIDE the lock; only the snapshot is guarded.
        val rows: List<PendingBracket>
        val minAt: Map<Long, Long>
        val maxAt: Map<Long, Long>
        synchronized(storeLock) {
            // Every store row still Unknown (earlier drains, the disk reload) plus the current
            // drain's batch. The store row carries the boot/ms the re-check needs (seq is not
            // persisted; ms carries the within-boot order for reloaded rows). Membership in the
            // STORE is required on both sources: pendingBracket is not one of perDeviceMaps, so
            // a row evicted at STORE_CAP mid-drain used to linger in the batch and putAll below
            // resurrected a histTime entry for it - a later LIVE sighting of that device then
            // inherited a Bracketed basis for a detection heard on the phone's own clock.
            val pending = LinkedHashMap<String, PendingBracket>()
            for ((id, h) in histTime) {
                if (h.basis !is TimeBasis.Unknown) continue
                val d = store[id] ?: continue
                if (d.boot <= 0L) continue
                pending[id] = PendingBracket(id, d.boot, d.ms, d.seq)
            }
            // The in-flight batch last, so a record's own fresher seq/ms wins for the same id.
            for (p in pendingBracket) if (store.containsKey(p.id)) pending[p.id] = p
            pendingBracket.clear()
            if (pending.isEmpty()) return
            rows = pending.values.toList()
            minAt = HashMap(bootMinAt); maxAt = HashMap(bootMaxAt)
        }
        val anchoredBoots = minAt.keys.sorted()
        val resolved = HashMap<String, HistTime>()
        for ((boot, group) in rows.groupBy { it.boot }) {
            // boot 0 means the record didn't carry one at all (firmware older than the ms/boot
            // fields). Without a boot there is nothing to order it against, so it stays unknown.
            if (boot <= 0L) continue
            val after = anchoredBoots.filter { it < boot }.mapNotNull { maxAt[it] }.maxOrNull()?.times(1000L)
            // The HIGHEST unanchored boot has no anchored boot above it, but a buffered record
            // was necessarily captured BEFORE the sync that collected it, and anchorPushedAt is
            // exactly that moment - so the sync itself is a sound upper bound. It turns the
            // weakest, most recent, most-likely-to-matter bracket from "time unknown" into
            // "between X and <sync>" (iOS uses syncStartedAt the same way); not using a bound we
            // hold understates what is actually known, a real loss in an evidence log.
            val before = anchoredBoots.filter { it > boot }.mapNotNull { minAt[it] }.minOrNull()?.times(1000L)
                ?: anchorPushedAt.takeIf { it > 0L }
            if (after == null && before == null) continue   // unbounded on both sides: still unknown
            val basis = TimeBasis.Bracketed(after, before)
            // Uptime orders the records within a boot directly, which is what the field is for;
            // seq breaks the tie for a board that sent no uptime.
            val ordered = group.sortedWith(compareBy({ it.ms }, { it.seq }))
            ordered.forEachIndexed { i, r ->
                resolved[r.id] = HistTime(basis, bracketSortKey(after, before, i, ordered.size))
            }
        }
        if (resolved.isEmpty()) return
        synchronized(storeLock) {
            // Re-check membership at apply time too: a clear on the main thread can
            // evict a row between the snapshot above and here, and a basis must never outlive
            // its row (see evictKey).
            for ((id, ht) in resolved) if (store.containsKey(id)) histTime[id] = ht
        }
        _timeBasisRev.value = _timeBasisRev.value + 1
    }

    /** An ordering slot for a bracketed row: spread inside the bracket when both ends are known,
     *  just past the single known end otherwise. Keeps the boot's rows a contiguous block sitting
     *  where the bracket says it belongs. An ordering device only, never printed as a time. */
    private fun bracketSortKey(after: Long?, before: Long?, index: Int, size: Int): Long = when {
        after != null && before != null -> after + (before - after) * (index + 1L) / (size + 1L)
        after != null -> after + 1L + index
        else -> before!! - (size - index)
    }

    /** How this row's first-seen stamp was arrived at. A row first heard live is [TimeBasis.Exact]
     *  and has no entry; everything else was replayed off the board's buffer and says so. */
    fun timeBasis(id: String): TimeBasis =
        synchronized(storeLock) { histTime[id]?.basis } ?: TimeBasis.Exact

    /** The same for a whole feed in ONE locked pass, the way newIdSet does it. A list screen
     *  asking per row would take storeLock once per visible row on every recomposition. Rows
     *  absent from the result are [TimeBasis.Exact], which is most of them. */
    fun timeBasisMap(list: List<Detection>): Map<String, TimeBasis> = synchronized(storeLock) {
        val out = HashMap<String, TimeBasis>()
        for (d in list) histTime[d.id]?.let { out[d.id] = it.basis }
        out
    }

    /** Forget one device everywhere: the store row and every per-device side map. The teardown
     *  for STORE_CAP eviction (its only caller today), so eviction can never drop a row from the
     *  store and leave its pin, closest-approach RSSI or breadcrumb trail behind. The ignore
     *  paths deliberately do NOT evict: muted evidence stays sealed in the store and is
     *  suppressed at projection time (see ignoreDevice).
     *  CALL UNDER storeLock (the monitor is reentrant, so a guarded caller is fine). */
    private fun evictKey(k: String) = synchronized(storeLock) {
        for (m in perDeviceMaps) m.remove(k)
    }

    /** Shared filing path: dedup-by-id into the store, keep the RSSI trend and (for drones)
     *  the flight path, and republish. Does not vibrate. */
    private fun file(d: Detection, ts: Long) = synchronized(storeLock) {
        val hist = rssiHistory.getOrPut(d.id) { mutableListOf() }
        hist.add(d.rssi)
        if (hist.size > 48) hist.subList(0, hist.size - 48).clear()
        store.remove(d.id)            // re-add so it sorts as the most recent
        store[d.id] = d
        // Bound memory over a long drive. Priority-aware: an airport-density flood of
        // confidence-0 "nearby device" rows must never push a real flag (tracker, body cam,
        // drone, glasses, or a starred/watched device) out of the store. Evict the oldest
        // ambient row first (store is insertion-ordered, so the first NEARBY_DEVICE match is
        // the oldest); only if the store is somehow all flags past the cap do we fall back to
        // evicting the oldest row outright.
        while (store.size > STORE_CAP) {
            val victim = store.entries.firstOrNull { it.value.type == DeviceType.NEARBY_DEVICE }?.key
                ?: store.keys.firstOrNull() ?: break
            evictKey(victim)
        }
        val dla = d.lat; val dlo = d.lon
        if (d.type == DeviceType.DRONE && dla != null && dlo != null && validCoord(dla, dlo)) {   // valid coords only
            val path = trackHistory.getOrPut(d.id) { mutableListOf() }
            if (path.lastOrNull() != (dla to dlo)) {
                path.add(dla to dlo)
                if (path.size > 60) path.subList(0, path.size - 60).clear()
            }
        }
        schedulePublish()
    }

    private data class FeedSnapshots(val active: List<Detection>, val log: List<Detection>)

    /** Build the active and evidence projections from one store snapshot. Both are newest-first
     * and capped; only the active projection applies current mute rules. */
    private fun feedSnapshots(): FeedSnapshots {
        // Copy the store's values under storeLock so we don't iterate the shared LinkedHashMap
        // while the BLE callback thread mutates it (ConcurrentModificationException). Keep the
        // critical section to the copy; do the reverse + cap outside the lock.
        val now = System.currentTimeMillis()
        val indexes = managedListIndexes
        val muted = activeIgnoredMacs(now, indexes)
        val watched = indexes.watchedMacs
        val all = synchronized(storeLock) { store.values.toList() }.asReversed()
        val log = if (all.size > FEED_CAP) all.take(FEED_CAP) else all
        val active = all.asSequence()
            .filter { d -> activeProjectionIncludes(d.mac, d.mac.lowercase() in watched, muted) }
            .take(FEED_CAP)
            .toList()
        return FeedSnapshots(active = active, log = log)
    }

    /** Publish both projections from the same immutable snapshot. StateFlow assignments are
     * sequential, but no store mutation or second policy evaluation can land between them. */
    private fun publishFeeds(snapshot: FeedSnapshots = feedSnapshots()) {
        _logDetections.value = snapshot.log
        _detections.value = snapshot.active
    }

    /** Full-store Live Mode snapshot, restricted to live rows heard in the Status freshness
     * window. The service collects [_detections] only as an invalidation signal; reading here
     * avoids counting the entire persisted log or truncating a dense nearby set at FEED_CAP. */
    internal fun nearbySnapshot(now: Long = System.currentTimeMillis()): NearbySnapshot {
        val indexes = managedListIndexes
        val muted = activeIgnoredMacs(now, indexes)
        val watched = indexes.watchedMacs
        return synchronized(storeLock) {
            val rows = ArrayList<Detection>()
            val newest = HashMap<String, NewestLive>(8)
            for (d in store.values) {
                if (d.hist || !activeProjectionIncludes(
                        d.mac, d.mac.lowercase() in watched, muted,
                    )) continue
                val seenAt = lastSeenAt[d.id]
                if (!lastSeenIsNearby(seenAt, now)) continue
                rows.add(d)
                if (d.type.onDriveSurface && seenAt != null) {
                    val category = d.type.category
                    if (seenAt > (newest[category]?.at ?: Long.MIN_VALUE)) {
                        newest[category] = NewestLive(category, seenAt)
                    }
                }
            }
            NearbySnapshot(rows, newest)
        }
    }

    /** Coalesced publish: mark the feed dirty and make sure the ~3 Hz pump is running.
     *  Used on the hot live/history filing path so a firehose can't thrash Compose. */
    private fun schedulePublish() {
        publishDirty.set(true)
        if (!publishPumpRunning) {
            publishPumpRunning = true
            scope.launch {
                while (publishDirty.getAndSet(false)) {
                    publishFeeds()
                    delay(PUBLISH_INTERVAL_MS)
                }
                publishPumpRunning = false
                // A file() that raced in after the last drain but before the flag cleared:
                // re-arm so its update isn't stranded.
                if (publishDirty.get() && !publishPumpRunning) schedulePublish()
            }
        }
    }

    /** Immediate publish for low-frequency UI actions (clear, ignore, demo seed, reload)
     *  where the latency of the coalescing pump would feel laggy. */
    private fun publishNow() {
        publishDirty.set(false)
        publishFeeds()
    }

    /** The board finished replaying. Verify we filed exactly N records; on a mismatch
     *  (a dropped or duplicated notify) re-issue {sync} from the last good seq - at most
     *  HIST_RESYNC_MAX times per connection. At the cap, stop this connection's retry loop but
     *  retain the contiguous cursor so the missing sequence remains eligible on reconnect. */
    private fun onHistEnd(n: Int) {
        val received = histReceived
        val beginSeen = histBeginSeen
        val disposition = historyEndDisposition(
            received = received,
            expected = n,
            resyncAttempts = histResyncAttempts,
            resyncCap = HIST_RESYNC_MAX,
            beginSeen = beginSeen,
        )
        if (disposition == HistoryEndDisposition.RETRY_NOW) {
            // Something slipped, ask the board to replay again from where we're solid. Stay in
            // the "syncing" state (and don't raise the banner) while the re-drain runs; the next
            // clean onHistEnd settles it. Bounded: a record this app can never count would
            // otherwise re-drain the entire buffer forever (permanent pill, continuous BLE
            // traffic, battery burn on both ends). Past the cap, settle this attempt as incomplete
            // without moving the cursor across the gap; a reconnect gets a fresh retry budget.
            histResyncAttempts++
            histReceived = 0
            histHighestContiguous = 0L
            histBeginSeen = false
            // The re-drain re-sends every record, so drop what this attempt queued rather than
            // bracketing the same rows twice over. Guarded like every other access, see the
            // declaration: noteHistTime adds to this from the filing path.
            synchronized(storeLock) { pendingBracket.clear() }
            _offlineSyncCount.value = 0
            _offlineSyncTotal.value = 0
            writeConfig(replaySyncConfig(lastSeq))
            return
        }
        if (beginSeen && disposition == HistoryEndDisposition.COMPLETE &&
            histHighestContiguous > lastSeq) {
            lastSeq = histHighestContiguous
        }
        if (disposition == HistoryEndDisposition.COMPLETE) histResyncAttempts = 0
        histReceived = 0
        histHighestContiguous = 0L
        histBeginSeen = false
        if (historyEnvelopeAuthorizesCheckpoint(beginSeen)) {
            // Bound the unanchored records now the whole batch is in and every anchored boot in it
            // is known. Before the checkpoint, so the resolved basis is what lands on disk.
            resolveBrackets()
            // Persist the store, THEN the cursor, and the cursor only if the write landed (see
            // checkpointHistory). No begin means no generation authority: at the retry cap leave
            // both durable tuple fields untouched so reconnect requests the envelope again.
            checkpointHistory(finalizeGeneration = disposition == HistoryEndDisposition.COMPLETE)
        }
        // Drain finished cleanly. Drop the "syncing" pill, and, only when the board actually
        // buffered records while we were away, raise the one-shot count banner. n == 0 (an
        // ordinary reconnect with nothing buffered, or a first connect) raises nothing.
        // Third number: begin.n promised vs end.n sent. A shortfall means this attempt stopped
        // before every promised row was queued (for example, an over-MTU row blocked the drain).
        // The board leaves that row uncommitted in the ring for a later sync; disclose this
        // attempt as incomplete instead of passing a received==end.n check off as complete.
        // promised == 0 means the begin sentinel never landed, so no judgement.
        val promised = _offlineSyncTotal.value
        val unreplayed = replayUnreplayedCount(
            promised = promised,
            sent = n,
            received = received,
            transportComplete = disposition == HistoryEndDisposition.COMPLETE,
        )
        _syncingOfflineLog.value = false
        _offlineSyncCount.value = 0
        _offlineSyncTotal.value = 0
        _offlineSyncUnreplayed.value = unreplayed
        if (n > 0 || unreplayed > 0) _offlineSyncBanner.value = n
    }

    // ---- config writes ----

    fun writeConfig(obj: JSONObject) {
        enqueueConfigWrite(obj, ConfigWritePurpose.NORMAL)
    }

    /** Enqueue one attributed write-with-response. Handshake successors are created only from the
     * successful callback (or never, on a synchronous rejection), rather than preloaded behind it. */
    private fun enqueueConfigWrite(
        obj: JSONObject,
        purpose: ConfigWritePurpose,
        prioritize: Boolean = false,
    ): Boolean {
        if (gatt == null) return false
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        enqueueGatt(prioritize = prioritize) { g ->
            val c = charOf(g, AcabProfile.CONFIG)
            if (c == null) {
                handleConfigWriteResult(g, purpose, false)
                onGattOpComplete()
                return@enqueueGatt
            }
            configWriteInFlight = purpose
            val queued = runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    g.writeCharacteristic(c, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) ==
                        BluetoothStatusCodes.SUCCESS
                } else {
                    @Suppress("DEPRECATION") c.value = bytes
                    @Suppress("DEPRECATION") c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                    @Suppress("DEPRECATION") g.writeCharacteristic(c)
                }
            }.getOrDefault(false)
            // A synchronous rejection fires NO write callback; free the slot ourselves so one
            // refused config write can't wedge the whole serialized queue for the session
            // (same guard as readStatus/sendNextOtaChunk). Handshake and clear writes are not
            // ordinary settings: attribute and fail them before anything later can dispatch.
            if (!queued) {
                configWriteInFlight = null
                handleConfigWriteResult(g, purpose, false)
                onGattOpComplete()
            }
        }
        return true
    }

    private fun handshakeWriteFor(purpose: ConfigWritePurpose): BufferHandshakeWrite? = when (purpose) {
        ConfigWritePurpose.HANDSHAKE_KEY -> BufferHandshakeWrite.KEY
        ConfigWritePurpose.HANDSHAKE_EPOCH -> BufferHandshakeWrite.EPOCH
        ConfigWritePurpose.HANDSHAKE_SYNC -> BufferHandshakeWrite.SYNC
        else -> null
    }

    private fun handleConfigWriteResult(
        g: BluetoothGatt,
        purpose: ConfigWritePurpose,
        success: Boolean,
    ) {
        val completed = handshakeWriteFor(purpose)
        if (completed != null) {
            val transition = bufferHandshakeTransition(completed, success)
            if (transition.failed) {
                failBufferHandshake(g, completed)
                return
            }
            transition.next?.let { next ->
                if (!enqueueBufferHandshakeWrite(next)) {
                    failBufferHandshake(g, next)
                    return
                }
            }
            if (transition.complete) {
                val completion = bufferHandshakeCompletion
                bufferHandshakeCompletion = null
                when (completion) {
                    BufferHandshakeCompletion.STARTUP -> subscribe(g, AcabProfile.STATUS)
                    BufferHandshakeCompletion.REKEY_AFTER_CLEAR -> readStatus()
                    null -> failBufferHandshake(g, completed)
                }
            }
            return
        }
        if (purpose == ConfigWritePurpose.CLEAR_LOG) {
            if (!success) {
                android.util.Log.w("ACAB-ble", "offline-history clear write was rejected")
                synchronized(this) { gattQueue.clear() }
                _connectHint.value = "Offline history was not cleared. Reconnect and try again."
                userInitiatedDisconnect = true
                runCatching { g.disconnect() }
                return
            }
            resetReplayCursorAfterClearAck()
            if (!startBufferHandshake(BufferHandshakeCompletion.REKEY_AFTER_CLEAR)) {
                failBufferHandshake(g, BufferHandshakeWrite.KEY)
            }
        } else if (!success) {
            // Ordinary settings converge against Status and can be retried there. They do not
            // relax the startup barrier above.
            android.util.Log.w("ACAB-ble", "config write was rejected")
        }
    }

    private fun failBufferHandshake(g: BluetoothGatt, failedAt: BufferHandshakeWrite) {
        android.util.Log.w("ACAB-ble", "buffer handshake failed at $failedAt")
        bufferHandshakeCompletion = null
        synchronized(this) { gattQueue.clear() }
        _connectHint.value =
            "Secure offline-history setup failed. Reconnect and try again before relying on replay."
        secureReadyTimeoutJob?.cancel()
        secureReadyTimeoutJob = null
        secureReadyArmed = false
        userInitiatedDisconnect = true
        _state.value = ConnState.CONNECTING
        runCatching { g.disconnect() }
    }

    fun setFlock(on: Boolean) = writeConfig(JSONObject().put("flock", on))
    fun setDrone(on: Boolean) = writeConfig(JSONObject().put("drone", on))
    /** Drone vendor-OUI fallback (flag a known DJI/Parrot OUI with no Remote ID). Opt-in and
     *  default off on the board, because it can't distinguish a flying drone from a stationary
     *  Parrot gadget. The Remote ID path stays always on under setDrone. */
    fun setDroneOuiEnabled(on: Boolean) = writeConfig(JSONObject().put("droneoui", on))
    fun setBodyCam(on: Boolean) = writeConfig(JSONObject().put("bodycam", on))
    /** The broad Motorola Solutions OUI proxy, a sub-toggle under setBodyCam: a device is only
     *  classified when BOTH are on. Turning this off quiets the noisy vendor-wide match (those
     *  blocks also carry radios, docks, and infrastructure) while the field-validated Axon
     *  "BWCDEVICE" payload match and Utility BodyWorn keep running. Pre-split firmware ignores
     *  the key, which is why the UI only offers it when status.motoSupported. */
    fun setMotorolaOui(on: Boolean) = writeConfig(JSONObject().put("motorola", on))
    fun setTracker(on: Boolean) = writeConfig(JSONObject().put("tracker", on))
    fun setGlasses(on: Boolean) = writeConfig(JSONObject().put("glasses", on))
    /** Network-camera detector (branded IP-camera OUI on the host WiFi: Hikvision/Dahua/Amcrest/
     *  Axis/Reolink). Opt-in and default off on the board, because it enables 802.11 DATA-frame
     *  source-MAC inspection (off by default). Mirrors setDroneOuiEnabled. */
    fun setNetcamEnabled(on: Boolean) = writeConfig(JSONObject().put("netcam", on))
    fun setBuzzer(on: Boolean) = writeConfig(JSONObject().put("buzzer", on))
    /** Onboard LED master. off = "lights out" (fully dark), for covert/stationary deploys.
     *  Firmware default on; the board persists this across reboots. */
    fun setLed(on: Boolean) = writeConfig(JSONObject().put("led", on))
    fun setVolume(v: Int, preview: Boolean = false) {
        val cfg = JSONObject().put("volume", v.coerceIn(0, 100))
        if (preview) cfg.put("beep", true)   // chirp once at the new level on release
        writeConfig(cfg)
    }
    fun setBleScan(on: Boolean) = writeConfig(JSONObject().put("ble", on))
    fun setWifiScan(on: Boolean) = writeConfig(JSONObject().put("wifi", on))
    // WiFi eco: 0/3/7/15 s of RX sleep between channel sweeps (battery SKU). Firmware snaps to the ladder.
    fun setWifiEco(sec: Int) = writeConfig(JSONObject().put("wifiEco", sec))

    /** Turn the board's offline detection buffer on or off (firmware default off). */
    fun setBuffer(on: Boolean) = writeConfig(JSONObject().put("buffer", on))

    /** Ask the beacon to power off (rev-B). The board deep-sleeps and drops the link ITSELF. We do
     *  NOT arm the expected-teardown flags here: the board confirms with a {"pwr":"off"} notify only
     *  when it is really about to drop, and handleOtaNotify arms userInitiatedDisconnect / stops
     *  autoReconnecting on THAT. Arming on the confirmation, not on this request, keeps a board that
     *  ignores the key (older firmware still reporting rev "B", or a write lost on the wire) from
     *  leaving a stale flag that would silently eat the next genuine unexpected drop. Once off, only a
     *  physical ~2 s button hold wakes it; the UI confirm says so and only offers this on rev-B. */
    fun powerOff() {
        if (gatt == null) return
        writeConfig(JSONObject().put("poweroff", true))
    }

    // The alert mode that was active before Desert mode muted the board, so disabling Desert
    // can restore it instead of leaving the board permanently silent. Null when Desert isn't
    // holding a prior mode (never enabled, or already SILENT when enabled).
    /** Alert mode to restore when Desert mode turns off.
     *
     *  PERSISTED. This used to be plain in-memory state, and Desert mode force-writes Silent to
     *  BOTH prefs and the board's NVS (buzz=false). So relaunching the app while Desert was on
     *  lost the restore target, and turning Desert off afterwards left the board permanently mute
     *  with no way back except hand-picking the mode again. A user in that state reports "my
     *  starred device never beeps", which reads as a detection bug and is not one. Mirrors iOS. */
    private var alertModeBeforeDesert: AlertMode?
        get() = prefs.getString("alert_mode_before_desert", null)
            ?.let { v -> AlertMode.entries.firstOrNull { it.name == v } }
        set(value) {
            prefs.edit().apply {
                if (value == null) remove("alert_mode_before_desert")
                else putString("alert_mode_before_desert", value.name)
            }.apply()
        }

    /** Desert mode: the board reports EVERY device in range (not just signatures).
     *  Enabling it drops alerts to SILENT; with everything reporting in, the buzzer and
     *  haptics would otherwise never stop. Disabling it restores the mode it muted, so the
     *  board doesn't stay silent forever. The user can also switch sound back on by hand. */
    fun setDesert(on: Boolean) {
        writeConfig(JSONObject().put("desert", on))
        if (on) {
            // Remember the mode we're muting so it can come back, then drop to SILENT.
            if (_alertMode.value != AlertMode.SILENT) {
                alertModeBeforeDesert = _alertMode.value
                setAlertMode(AlertMode.SILENT)
            } else {
                // Already Silent, so there is nothing to restore. CLEAR the token rather than
                // leaving it: now that it is persisted it would otherwise be an arbitrarily old
                // mode, and a later Desert-off would un-mute a user who deliberately chose Silent.
                alertModeBeforeDesert = null
            }
            desertSeenOn = false   // wait for the board to confirm before arming the reconciler
        } else {
            // Restore the pre-Desert mode, but only if the user hasn't already picked one by
            // hand while Desert ran (in which case we're no longer SILENT and leave it alone).
            alertModeBeforeDesert?.let { prior ->
                if (_alertMode.value == AlertMode.SILENT) setAlertMode(prior)
            }
            alertModeBeforeDesert = null
        }
    }

    // ---- offline-buffer handshake (key + clock + sync request) ----

    private fun replaySyncConfig(cursor: Long): JSONObject =
        JSONObject().put("sync", cursor).put("syncgen", activeLogGeneration)

    /** Start an ACK-gated key -> epoch -> sync transaction. Only the key exists in the queue now;
     * each successful Config response creates its successor, and sync success alone may advance
     * the startup subscription chain toward READY. */
    private fun startBufferHandshake(completion: BufferHandshakeCompletion): Boolean {
        // Successors are priority-queued, so a clear cannot normally reach its ACK until the
        // active chain settles. Keep the invariant explicit as a final guard against duplicate
        // callbacks or a future caller bypassing that queue policy.
        if (bufferHandshakeCompletion != null) return false
        // Resolve and durably commit the key before queuing ANY handshake write. If storage or
        // Keystore access fails, the caller tears down this not-yet-ready session.
        val key = keyHex() ?: return false
        // Reload again at the point of use: an auto-reconnect may race an async checkpoint that
        // completed after cleanup. Either durable position is safe; an ahead volatile one is not.
        val resumeCursor = synchronized(cursorLock) {
            replayCursorForReconnect(
                ReplayCursorTuple(lastSeq, activeLogGeneration),
                ReplayCursorTuple(lastSeqPersisted, lastLogGenerationPersisted),
            )
        }
        lastSeq = resumeCursor.sequence
        activeLogGeneration = resumeCursor.generation
        // We've asked the board to replay everything past lastSeq. The pill is driven by the
        // board's {"hist":"begin"} lead-in, NOT this handshake: the board streams sentinels only
        // when it actually buffered records, so a buffer-off/empty connect shows no pill (and can't
        // stick waiting for an end that never comes). onHistEnd clears it when a real drain closes.
        _offlineSyncCount.value = 0
        _offlineSyncTotal.value = 0
        histBeginSeen = false
        _syncingOfflineLog.value = false
        bufferHandshakeCompletion = completion
        val queued = enqueueBufferHandshakeWrite(BufferHandshakeWrite.KEY, key)
        if (!queued) bufferHandshakeCompletion = null
        return queued
    }

    private fun enqueueBufferHandshakeWrite(step: BufferHandshakeWrite, key: String? = null): Boolean {
        val (payload, purpose) = when (step) {
            BufferHandshakeWrite.KEY -> {
                val durableKey = key ?: return false
                JSONObject().put("key", durableKey) to ConfigWritePurpose.HANDSHAKE_KEY
            }
            BufferHandshakeWrite.EPOCH -> {
                // This is the actual epoch-write attempt, not the earlier key-generation moment;
                // its timestamp is therefore the tightest available reconstruction anchor.
                anchorPushedAt = System.currentTimeMillis()
                JSONObject().put("epoch", anchorPushedAt / 1000L) to
                    ConfigWritePurpose.HANDSHAKE_EPOCH
            }
            BufferHandshakeWrite.SYNC -> replaySyncConfig(lastSeq) to
                ConfigWritePurpose.HANDSHAKE_SYNC
        }
        return enqueueConfigWrite(payload, purpose, prioritize = true)
    }

    /** Dismiss the offline-sync count banner (view tapped, dismissed, or the user navigated). */
    fun clearOfflineSyncBanner() { _offlineSyncBanner.value = null; _offlineSyncUnreplayed.value = 0 }

    /** Re-assert attempts since the app and board last agreed on the buzzer. Reset on every fresh
     *  connection so a stale value cannot skip the grace period. */
    private var buzzerReassertAttempts = 0

    /** When the last MUTE write went out. After the fast burst above, an AUDIBLE board the user
     *  asked to keep quiet keeps getting the write every [BUZZER_MUTE_RETRY_MS] for as long as the
     *  two disagree. See [reconcileBuzzer] for why that one direction never gives up. iOS twin:
     *  BLEManager.lastBuzzerMuteWrite / buzzerMuteRetryInterval, same 30 s cadence. */
    private var lastBuzzerMuteWrite = 0L

    /** Reconcile the alert mode against what the board actually reports.
     *
     *  THE BUG (reported 2026-07-31): Desert mode on then off left the app showing sound ON while
     *  the board stayed silent. The alert mode was optimistic local state, asserted once on connect
     *  but never reconciled against the per-status `buzzer` the board already reports, so any lost
     *  config write left the two diverged with nothing to heal it. setDesertMode is the only path
     *  firing TWO config writes back to back, which is where a drop shows up.
     *
     *  THREE THINGS THE FIRST VERSION GOT WRONG, found in re-review:
     *   1. Mesh-Detect has NO buzzer hardware (weak `alertsBuzzerEnabled()` stub returns false
     *      forever, buzzer writes discarded), so want(true) != report(false) never converged and
     *      this wrote SILENT into the SHARED prefs file, muting the user's real beacon board on its
     *      next connect. Hence the isMeshDetect bail.
     *   2. It collapsed three modes onto a Bool and could only write back BUZZER or SILENT, so a
     *      VIBRATE user could be silently promoted to BUZZER: an audible board for someone who
     *      chose a quiet one. When the board is audible and the user wanted quiet, keep trying to
     *      MUTE. Erring quiet is the only safe direction on this product.
     *   3. The correction was persisted, so one transient fault could rewrite a stored preference.
     *      It is now in-memory for the session.
     *
     *  THE TWO DIRECTIONS ARE NOT SYMMETRIC, which is the whole shape of this function. Wanting
     *  sound and getting silence is an inconvenience the UI can just tell the truth about. Wanting
     *  silence and getting sound is a beacon making noise for someone who asked for none, so the
     *  mute write is re-sent for as long as the two disagree - see the terminal branch.
     *  Mirrors iOS reconcileBuzzer() branch for branch, including that retry and its cadence. */
    private fun reconcileBuzzer(s: DeviceStatus) {
        if (s.isMeshDetect) { buzzerReassertAttempts = 0; return }   // no buzzer to reconcile

        val wantBuzzer = _alertMode.value == AlertMode.BUZZER
        if (wantBuzzer == s.buzzer) {
            buzzerReassertAttempts = 0
            lastBuzzerMuteWrite = 0L
            return
        }

        if (buzzerReassertAttempts < MAX_BUZZER_REASSERTS) {
            buzzerReassertAttempts++
            lastBuzzerMuteWrite = System.currentTimeMillis()
            setBuzzer(wantBuzzer)          // most likely a dropped write; say it again
            return
        }
        if (wantBuzzer) {
            // Re-asserting did not take, and this is the direction where the mapping is LOSSLESS:
            // we claim sound, the board is muted. Tell the truth for this session, in memory only,
            // so a transient fault cannot rewrite the stored preference.
            _alertMode.value = AlertMode.SILENT
            return
        }
        // The other direction is the one we must never give up on: the board is AUDIBLE while the
        // user chose VIBRATE or SILENT. Leaving the mode alone is still right (both are honest
        // about what the PHONE does), but going quiet about it was not. Nothing else in the app
        // re-sends the mute, and no surface reports the disagreement, so running the burst out
        // meant "beeping for the rest of the session" unless the user happened to re-pick a mode
        // or reconnect - the covert-use promise breaking. Keep sending it. A buzzer:false frame is
        // one small idempotent config write, so a slow cadence costs almost nothing and heals the
        // moment the board starts listening again.
        val now = System.currentTimeMillis()
        if (now - lastBuzzerMuteWrite < BUZZER_MUTE_RETRY_MS) return
        lastBuzzerMuteWrite = now
        setBuzzer(false)
    }

    /** Pick how sightings get announced. VIBRATE and SILENT both mute the board's buzzer, for when
     *  a chirp would give you away; VIBRATE buzzes this phone instead. */
    fun setAlertMode(mode: AlertMode) {
        _alertMode.value = mode
        prefs.edit().putString("alertMode", mode.name).apply()
        // A mode picked while Desert is running is an explicit choice and outranks whatever we
        // captured on the way in, so drop the token. Mirrors iOS.
        if (mode != AlertMode.SILENT) alertModeBeforeDesert = null
        setBuzzer(mode == AlertMode.BUZZER)
    }

    /** Latched view of the board's Desert state, so a `desert:false` frame can be told apart from
     *  "our enable write has not landed yet". Only flips true once the BOARD confirms Desert on. */
    private var desertSeenOn = false

    /** Restore the pre-Desert alert mode when Desert ends WITHOUT going through setDesert(false).
     *
     *  HISTORY, because the rationale changed under this code. Desert USED TO BE the one toggle
     *  with no NVS backing (desert_detect.cpp held a plain `static bool`), so any board reboot came
     *  back with it off. The Device screen's toggle only follows the status frame (DeviceScreen.kt:
     *  `desertOn = s.desertMode`), so the restore branch in setDesert never ran for the single most
     *  common way Desert ended, and because the board's Silent IS persisted (buzz=false in its NVS)
     *  the board was left permanently mute after a power cycle. That reads as "my starred device
     *  stopped beeping" and is not a detection fault.
     *
     *  Firmware from 2026-08-08 PERSISTS Desert (desertRestoreEnabled), so a reboot no longer ends
     *  it behind our back and that specific bug cannot recur on current firmware. Kept deliberately
     *  and NOT to be deleted as dead code: boards already in the field still run the non-persisting
     *  build and this app pairs with them, a factory reset still clears it, and Desert can still end
     *  without passing through setDesert(false) from another client. The condition it guards,
     *  "Desert stopped and we are not the ones who stopped it", is unchanged; only how often it
     *  fires changed. Mirrors iOS reconcileDesert(). */
    private fun reconcileDesert(s: DeviceStatus) {
        if (s.desertMode) { desertSeenOn = true; return }
        if (!desertSeenOn) return              // never saw it on: nothing to restore
        desertSeenOn = false
        // Same conditions as the manual path: only un-mute if we are still on the Silent that
        // Desert forced, so a mode the user hand-picked while Desert ran survives.
        alertModeBeforeDesert?.let { prior ->
            if (_alertMode.value == AlertMode.SILENT) setAlertMode(prior)
        }
        alertModeBeforeDesert = null
    }

    /**
     * Per-device haptic cooldown. THE COOLDOWN IS THE EDGE, NOT `firstTime`.
     *
     * Same defect DetectionNotifier already fixed for notifications, left behind on the haptic
     * line: `firstTime` is `store[d.id] == null`, and the store is PERSISTED across launches
     * (loadPersistedDetections), so a device seen in ANY earlier session was never first again and
     * could never buzz. On a commute past the same hardware that is every device. The comment two
     * lines under the haptic call already spelled this out for the notifier; it never reached the
     * haptic itself. Parity with iOS BLEManager.lastHapticByMac.
     */
    private val lastHapticByMac = HashMap<String, Long>()
    private val hapticCooldownMs = 600_000L   // 10 min, matches DetectionNotifier

    /**
     * May this MAC buzz now? True when never seen or past the cooldown, and it RECORDS the buzz,
     * so only call it once everything else has passed. Bounded like the notifier's map, which
     * matters in Desert mode where one drive sees thousands of MACs.
     */
    private fun hapticDue(mac: String, now: Long = System.currentTimeMillis()): Boolean {
        val last = lastHapticByMac[mac]
        if (last != null && now - last < hapticCooldownMs) return false
        lastHapticByMac[mac] = now
        if (lastHapticByMac.size > 256) {
            lastHapticByMac.entries.removeAll { now - it.value >= hapticCooldownMs }
        }
        return true
    }

    /** Category-shaped tactile cue: glasses double-tap, body cameras repeat, priority gear snaps. */
    private fun alertHaptic(type: DeviceType) {
        val vib = vibrator ?: return
        val effect = when (type) {
            DeviceType.GLASSES -> VibrationEffect.createWaveform(longArrayOf(0, 45, 100, 45), -1)
            DeviceType.BODY_CAM ->
                VibrationEffect.createWaveform(longArrayOf(0, 90, 75, 90, 75, 90), -1)
            // Watched devices ride the priority double-pulse too: the user asked to be told.
            DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN, DeviceType.DRONE, DeviceType.WATCHED ->
                VibrationEffect.createWaveform(longArrayOf(0, 70, 90, 70), -1)
            else -> VibrationEffect.createOneShot(50, VibrationEffect.DEFAULT_AMPLITUDE)
        }
        vib.vibrate(effect)
    }

    // ---- per-detection timing, RSSI trend, and map location ----

    // side-map reads take storeLock: the BLE thread writes these under it (see file()/fileLive)
    fun firstSeen(id: String): Long? = synchronized(storeLock) { firstSeenAt[id] }
    fun lastSeen(id: String): Long? = synchronized(storeLock) { lastSeenAt[id] }
    fun rssiTrend(id: String): List<Int> = synchronized(storeLock) { rssiHistory[id]?.toList() } ?: emptyList()

    /** True when [stamp] is fileHistory's seq-derived ordering key rather than a clock reading.
     *  The board buffers records it has no time for, so those stamps mean "before that one" and
     *  nothing more. Anything that renders one as an age has to ask this first, or it reports the
     *  pseudo-base as a confident "24 years ago". Asked per stamp, not per detection: a device
     *  first replayed from the buffer and then heard live keeps its approx firstSeen while its
     *  lastSeen is a real time, and the approx flag alone can't tell those apart. */
    fun isApproxTime(stamp: Long?): Boolean = stamp != null && stamp <= HIST_PSEUDO_BASE

    /** True when we haven't heard from this id lately (probably gone). One row's worth: fine for a
     *  dossier, wrong for a feed - see [freshIdSet]. The one-sided comparison lives in the
     *  top-level [lastSeenIsStale] so both readers answer identically. */
    fun isStale(id: String, olderThanMs: Long = ACTIVE_NEARBY_WINDOW_MS): Boolean {
        val ls = synchronized(storeLock) { lastSeenAt[id] }
        return lastSeenIsStale(ls, System.currentTimeMillis(), olderThanMs)
    }

    /** Which of [dets] were heard inside the staleness window, in ONE storeLock take and against
     *  ONE clock reading, the way newIdSet and timeBasisMap do it. Status filters its whole active
     *  feed through this on every publish and on a 1 Hz tick; asking isStale per row took the
     *  monitor the BLE thread holds for every arriving advert up to FEED_CAP times per pass, on the
     *  main thread, during exactly the dense traffic the radar exists to display. Same one-sided
     *  rule as [isStale], so a backward clock step cannot empty the radar. */
    fun freshIdSet(dets: List<Detection>, olderThanMs: Long = ACTIVE_NEARBY_WINDOW_MS): Set<String> {
        val now = System.currentTimeMillis()
        return synchronized(storeLock) {
            val out = HashSet<String>(dets.size)
            for (d in dets) if (!lastSeenIsStale(lastSeenAt[d.id], now, olderThanMs)) out.add(d.id)
            out
        }
    }

    /** Where to drop the map pin: the detection's own coords (drones), or the phone's
     *  position from when we first heard it. */
    fun mapCoord(d: Detection): Pair<Double, Double>? {
        val la = d.lat; val lo = d.lon
        // Only trust the detection's own coords when finite + in range + not null-island: a garbled
        // drone Remote ID decodes to ~214 deg, and a bad GeoPoint wedges the osmdroid map thread.
        return if (validCoord(la, lo)) la!! to lo!! else synchronized(storeLock) { capturedLoc[d.id] }
    }

    /** Where the PHONE was when it heard [d], or null when that is genuinely unknown.
     *
     *  Deliberately NOT mapCoord(): that prefers the detection's own wire lat/lon, which for a
     *  DRONE is the aircraft's Remote ID broadcast rather than the observer. mapCoord is right for
     *  the map (a drone pin belongs at the aircraft); it is wrong for approx_lat/lon and for the
     *  GPX "Heard:" waypoint, both of which promise an observer position. A replayed drone has no
     *  known observer position, and null is the honest answer. Mirrors iOS, where capturedLoc is
     *  left nil for drones on history ingest. */
    private fun mapCoordForExport(d: Detection): Pair<Double, Double>? =
        if (d.type == DeviceType.DRONE) synchronized(storeLock) { capturedLoc[d.id] } else mapCoord(d)

    /** A drone's accumulated flight path (empty for anything else). */
    fun track(id: String): List<Pair<Double, Double>> = synchronized(storeLock) { trackHistory[id]?.toList() } ?: emptyList()

    /** A tracker's breadcrumb trail of the PHONE's path while it stayed with us (empty otherwise). */
    fun crumbs(id: String): List<Pair<Double, Double>> = synchronized(storeLock) { crumbHistory[id]?.toList() } ?: emptyList()

    /** When the FIRST crumb for [id] was dropped, or null if it has none. The START of the crumb
     *  window, and deliberately not [firstSeen]: first-seen is when the device was first HEARD, it
     *  is restored from the persisted store on launch, and the crumbs are not. Scoring from it
     *  narrated a duration the trail did not cover. READ ONLY; takes storeLock like its siblings,
     *  because the BLE thread writes the map under it. */
    fun firstCrumbAt(id: String): Long? = synchronized(storeLock) { firstCrumbAt[id] }

    /** When the most recent crumb for [id] was dropped, or null if it has none. READ ONLY, and with
     *  [firstCrumbAt] and [crumbs] the whole of what the follow-evidence scorer needs from this
     *  class. It is the END of the crumb window: [lastSeen] would keep advancing on adverts heard
     *  while the phone sat still, which would stretch the run without a single new crumb behind it.
     *  Takes storeLock like its siblings, because the BLE thread writes the map under it. */
    fun lastCrumbAt(id: String): Long? = synchronized(storeLock) { lastCrumbAt[id] }

    /** The phone's last known coordinate (centers a no-GPS RSSI ring). */
    fun selfCoord(): Pair<Double, Double>? = lastLat?.let { la -> lastLon?.let { lo -> la to lo } }

    /** A freshness- and accuracy-checked coordinate for the 50 m HERE action. A current but coarse
     * fix can still geotag evidence honestly; it cannot make a binary inside/outside claim. */
    fun currentSelfCoord(): Pair<Double, Double>? = freshSelfFix()?.asMutePosition()
        ?.takeIf { positionSupportsHere(it, DEFAULT_HERE_RADIUS_METERS) }
        ?.coord

    /** HERE-rule evaluation may outlive the visible Activity for the short period in which Android
     * keeps the BLE process/link around without Live Mode. Do not start background location for
     * that case, but do accept the platform's still-fresh last fix; tying evaluation to listener
     * ownership made every HERE mute turn off the instant the app backgrounded. */
    private fun freshMuteCoord(): MutePosition? {
        if (locationOwnershipNeeded()) return freshSelfFix()?.asMutePosition()
        if (!hasLocationPermission()) return null
        val nowNanos = SystemClock.elapsedRealtimeNanos()
        if (nowNanos - fixCacheAt < FIX_CACHE_NANOS) return fixCache?.asMutePosition()
        // Listener ownership is intentionally gone, but the fix that was current at that edge is
        // still current until the same strict 2-minute age limit expires. Keep that provenance
        // separately from fixCache, which syncLocationOwnership clears to protect other callers.
        lastMuteFix?.let { fix ->
            if (nowNanos - fix.elapsedRealtimeNanos in 0..FIX_MAX_AGE_NANOS) {
                return fix.asMutePosition()
            }
        }
        fixCacheAt = nowNanos
        fixCache = readFreshFix(nowNanos)
        return fixCache?.asMutePosition()
    }

    /** The phone's position, but only when the underlying FIX is recent enough to stamp onto a
     *  detection we're hearing right now.
     *
     *  Do NOT re-express this as "time since the last locListener callback". requestLocationUpdates
     *  runs with a 10 m displacement filter, so a phone parked at a stakeout gets no callbacks for
     *  an hour while its coordinate stays exactly right; callback age would call that stale and
     *  throw away good coordinates. Ask the platform for its last known fix and read the fix's own
     *  elapsedRealtimeNanos, which is the age of the position itself. elapsedRealtime (not wall
     *  clock) so a time-zone hop or an NTP correction can't make a fresh fix look ancient.
     *
     *  Cached briefly: this runs on the BLE callback thread once per new device, and a Desert-mode
     *  flood would otherwise fire a binder call per record. A second of lag is centimetres. */
    private fun freshSelfCoord(): Pair<Double, Double>? = freshSelfFix()?.coord

    private fun freshSelfFix(): TimedCoord? {
        if (!locationOwnershipNeeded()) {
            fixCacheAt = 0L
            fixCache = null
            return null
        }
        val nowNanos = SystemClock.elapsedRealtimeNanos()
        if (nowNanos - fixCacheAt < FIX_CACHE_NANOS) return fixCache
        fixCacheAt = nowNanos
        fixCache = readFreshFix(nowNanos)
        return fixCache
    }

    @SuppressLint("MissingPermission")
    private fun readFreshFix(nowNanos: Long): TimedCoord? {
        val lm = locationManager ?: return null
        if (!hasLocationPermission()) return null
        // Newest of the two providers the ViewModel subscribes to; network usually wins indoors,
        // GPS on the road.
        var best: Location? = null
        for (p in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            val l = runCatching { lm.getLastKnownLocation(p) }.getOrNull() ?: continue
            if (best == null || l.elapsedRealtimeNanos > best.elapsedRealtimeNanos) best = l
        }
        val fix = best ?: return null
        if (nowNanos - fix.elapsedRealtimeNanos !in 0..FIX_MAX_AGE_NANOS) return null
        if (!validCoord(fix.latitude, fix.longitude)) return null
        return TimedCoord(
            coord = fix.latitude to fix.longitude,
            elapsedRealtimeNanos = fix.elapsedRealtimeNanos,
            horizontalAccuracyMeters = if (fix.hasAccuracy()) fix.accuracy.toDouble() else null,
        ).also {
            lastMuteFix = it
        }
    }

    /** Whether we may read location at all. Location is optional in this app (MainActivity only
     *  starts it once granted), so every location read has to tolerate a flat "no". */
    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(context, android.Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    /** MainActivity reports every resume/result edge. A revoked Bluetooth grant must retire a
     * retained READY shell immediately instead of leaving dead GATT controls that fail silently or
     * throw on a later direct disconnect. Location is independent and merely re-evaluates the
     * process-owned listener. */
    fun onPermissionsChanged(bluetoothGranted: Boolean, locationGranted: Boolean) {
        locationPermissionGranted = locationGranted && hasLocationPermission()
        if (!bluetoothGranted && !_demoMode.value) teardownForBluetoothPermissionRevocation()
        syncLocationOwnership()
    }

    /** Called only after AcabLinkService successfully enters the foreground. Merely setting the
     * Drive toggle is not enough: requesting background fixes before the foreground promotion can
     * itself violate Android's while-in-use location rules. */
    fun onLinkServiceStarted() {
        driveServiceActive = true
        syncLocationOwnership()
    }

    /** The service can be stopped by the system as well as by endDriveMode. Never let a stale
     * in-memory Drive flag keep the process location listener registered without its FGS owner. */
    fun onLinkServiceStopped() {
        driveServiceActive = false
        // onDestroy is delivered on Main. Retire only work that is still before its destructive
        // boundary; a Nordic FLASHING transfer may already have erased the application, and an S3
        // image at/after end may already be committing. Those critical legs must finish rather
        // than being aborted into a board/radio that needs physical recovery.
        if (combinedHoldingService && combinedDelegate.isInitialized()) {
            combined.onProtectedHoldLost()
        }
        // A direct S3 run has no combined coordinator to observe the teardown. The combined
        // callback above cancels its own cancellable S3 leg and clears the inherited marker before
        // this check, so the same run cannot be failed twice.
        if ((otaHoldingService || otaUsingCombinedServiceHold) && otaCancellableNow()) {
            failOta(
                "Android could not keep the protected update session active. " +
                    "The update stopped before it committed; keep the app open and try again.",
            )
        }
        if (_driveMode.value) _driveMode.value = false
        syncLocationOwnership()
    }

    private fun locationOwnershipNeeded(): Boolean = shouldOwnLocation(
        locationPermissionGranted,
        _state.value,
        appForegrounded,
        _driveMode.value,
        driveServiceActive,
    )

    /** Register GPS and network on the main looper so this is safe when a GATT binder callback is
     * the transition that made the link READY. One listener owns both providers; removeUpdates
     * retires both atomically.
     *
     * Its OWN lock, deliberately, like every other subsystem here (storeLock, managedListEdits,
     * cursorLock, persistMutex). This was @Synchronized, i.e. on the instance monitor, which is
     * also the lock for the serialized GATT queue (enqueueGatt/dispatchGatt/onGattOpComplete). The
     * two have nothing to do with each other, and sharing a monitor made every main-thread caller
     * (onPermissionsChanged, onAppForeground/Background, startDriveMode) contend with the BLE
     * binder thread's write completions, while dispatchGatt held it across a Bluetooth binder call.
     *
     * Only the registration bookkeeping belongs inside the lock. The seed fixes and the republish
     * run after it: onLocationChanged reaches setLocation -> writeConfig -> enqueueGatt, and
     * publishNow rebuilds the whole feed under storeLock, neither of which should be holding a lock
     * this path owns.
     *
     * Dropping the lock before the seeds is what [locationOwnershipGeneration] exists for. This runs
     * on the BLE binder thread (finishReady) as well as on main (onAppBackground), so a release can
     * land in that gap; replaying a seed after it would repopulate the fix cache and push the
     * phone's coordinate to the board through setLocation, silently undoing ownership the process
     * had just given up. Each seed re-proves under the lock that the registration it came from is
     * still the live one. */
    @SuppressLint("MissingPermission")
    private fun syncLocationOwnership() {
        val seeds = ArrayList<Location>(2)
        var republish = false
        var seedGeneration = -1L
        synchronized(locationLock) {
            val lm = locationManager ?: return
            if (!locationOwnershipNeeded()) {
                if (locationUpdatesRegistered) runCatching { lm.removeUpdates(ownedLocationListener) }
                locationUpdatesRegistered = false
                locationOwnershipGeneration++
                fixCacheAt = 0L
                fixCache = null
                // selfCoord intentionally survives for map centering. Evaluation-only HERE rules may
                // keep using lastMuteFix while it remains fresh and accurate; new HERE rules still
                // require foreground ownership. Republish because the applicable fix source changed.
                republish = _ignored.value.any { it.isPlaceRule }
            } else if (!locationUpdatesRegistered) {
                var registered = false
                for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
                    runCatching {
                        lm.getLastKnownLocation(provider)?.let(seeds::add)
                        lm.requestLocationUpdates(
                            provider, LOCATION_INTERVAL_MS, LOCATION_MIN_DISTANCE_M,
                            ownedLocationListener, Looper.getMainLooper(),
                        )
                        registered = true
                    }
                }
                locationUpdatesRegistered = registered
                locationOwnershipGeneration++
                // Both providers refused, so nothing is owned: a last-known fix collected on the
                // way through must not be replayed into setLocation, which would push a
                // coordinate to the board off a registration that does not exist.
                if (registered) seedGeneration = locationOwnershipGeneration else seeds.clear()
            }
        }
        // Outside the lock: same seeding as before, same order (GPS then network), just not while
        // holding it. The listener itself is what decides whether a last-known fix is fresh enough.
        // Per seed, not once for the batch, so a release landing between two of them stops the
        // second as well: the generation check is what proves this registration is still ours.
        for (seed in seeds) {
            val stillOurs = synchronized(locationLock) {
                locationUpdatesRegistered && locationOwnershipGeneration == seedGeneration
            }
            if (!stillOurs) break
            ownedLocationListener.onLocationChanged(seed)
        }
        if (republish) publishNow()
    }

    /** Permission loss can happen while Settings covers a retained READY Activity. All platform
     * calls are best-effort because the grant is already gone; the important guarantee is that
     * internal state, reconnect intent, service ownership, and the UI all leave the live session. */
    private fun teardownForBluetoothPermissionRevocation() {
        val liveState = _state.value == ConnState.SCANNING ||
            _state.value == ConnState.CONNECTING || _state.value == ConnState.BONDING ||
            _state.value == ConnState.READY || gatt != null
        scanGen++
        scanTimeoutJob?.cancel(); scanTimeoutJob = null
        scanPausedInBackground = false
        runCatching { scanner?.stopScan(scanCb) }
        if (!liveState) {
            _state.value = ConnState.DISCONNECTED
            return
        }
        userInitiatedDisconnect = true
        autoReconnecting = false
        otaReconnecting = false
        runCatching { gatt?.disconnect() }
        cleanup()
        userInitiatedDisconnect = false
        _state.value = ConnState.DISCONNECTED
    }

    private var lastGpsSent = 0L
    /** Feed in the phone's location: geotag non-drone detections locally, and push it
     *  to a connected board so a Mesh-Detect uplink can carry where we are (throttled). */
    fun setLocation(lat: Double, lon: Double) {
        if (!validCoord(lat, lon)) return
        lastLat = lat; lastLon = lon
        // The listener primes fixCache before calling here, retaining the source fix's timestamp
        // and horizontal accuracy instead of collapsing it to a coordinate-only value.
        if (_demoMode.value && demoNeedsRelocate) {   // snap the demo hits onto the user once a fix arrives
            demoNeedsRelocate = false
            placeDemoDetections(lat, lon)
        }
        val now = System.currentTimeMillis()
        if (_state.value == ConnState.READY && now - lastGpsSent > 15_000) {
            lastGpsSent = now
            writeConfig(JSONObject().put("lat", lat).put("lon", lon))
        }
        // HERE rules are phone-side only. Crossing their boundary hides/reveals the retained
        // evidence locally; it must never rewrite the board's persistent ignore list.
        if (_ignored.value.any { it.isPlaceRule }) publishNow()
    }

    // ---- log clear + CSV export ----

    /** Clear the on-phone detection log, but stay connected. Local only, this does NOT touch
     *  the board's offline buffer (use [clearBufferLog] for that), and it deliberately keeps the
     *  replay cursor so records the board already sent don't refill the log on the next reconnect. */
    fun clearLog(): Boolean {
        val deletePersistedStore = persistedLogMutationAllowed(_demoMode.value)
        // Demo rows replace memory only. Clearing them must never delete the real sealed log that
        // exitDemo is about to restore from disk.
        if (!deletePersistedStore) {
            resetInMemoryLog()
            return true
        }

        // Invalidate already-decoded loads and every snapshot captured before this tap. This is
        // deliberately before the synchronous fallback waits on persistMutex: an older coroutine
        // that runs after deletion must observe a stale generation and may never recreate the file.
        val boundaryResult: Boolean? = synchronized(persistedDetectionClearStateLock) {
            if (persistedDetectionClearInitiatorInProgress) null
            else {
                persistedDetectionClearInitiatorInProgress = true
                beginPersistedDetectionClearBoundary(
                    markVisibleResetPending = { pendingClearNeedsMemoryReset.set(true) },
                    invalidateDecodedLoads = { persistedDetectionLoadGate.invalidate() },
                    advanceWriteGeneration = { persistedDetectionWriteGeneration.incrementAndGet() },
                    armTombstone = { persistedDetectionClearTombstone.arm() },
                )
            }
        }
        // A second tap cannot become a second owner of the same visible reset.
        val tombstoneArmed = boundaryResult ?: return false

        // Do not change the visible store until the action has a process-death-safe boundary.
        // SharedPreferences.commit() is the write-ahead path; confirmed synchronous absence is the
        // fallback when preferences storage is unavailable. If both fail, rows remain visible.
        val commit = preparePersistedDetectionClear(
            armTombstone = { tombstoneArmed },
            deleteSynchronously = { deletePersistedDetectionsSynchronously() },
        )
        if (!persistedDetectionClearMayResetMemory(commit)) {
            synchronized(persistedDetectionClearStateLock) {
                persistedDetectionClearInitiatorInProgress = false
            }
            scope.launch(Dispatchers.IO) {
                retryPendingDetectionClear(checkpointCurrentStoreOnSuccess = true)
            }
            return false
        }

        val completion = completeInitiatingPersistedDetectionClear(
            retireTombstone = commit == PersistedDetectionClearCommit.CONFIRMED_DELETION,
        )
        if (!completion.resetCompleted) {
            scope.launch(Dispatchers.IO) {
                retryPendingDetectionClear(checkpointCurrentStoreOnSuccess = true)
            }
            return false
        }
        when (commit) {
            PersistedDetectionClearCommit.DURABLE_TOMBSTONE ->
                scope.launch(Dispatchers.IO) {
                    retryPendingDetectionClear(checkpointCurrentStoreOnSuccess = true)
                }
            PersistedDetectionClearCommit.CONFIRMED_DELETION -> {
                // Keep writes blocked until removal of a possibly half-committed tombstone is
                // itself durably confirmed. A failed retirement remains pending and is retried.
                if (!completion.tombstoneRetired) {
                    scope.launch(Dispatchers.IO) {
                        retryPendingDetectionClear(checkpointCurrentStoreOnSuccess = true)
                    }
                }
            }
            PersistedDetectionClearCommit.UNAVAILABLE -> Unit
        }
        return true
    }

    /** Drop every filed detection from memory and republish. Does NOT touch the on-disk log. */
    private fun resetInMemoryLog(invalidatePersistedSnapshots: Boolean = false) {
        notifier.reset()   // a new session may alert on the same devices again (iOS parity)
        // Called from main, unlike the rest of the store's mutations. See storeLock.
        synchronized(storeLock) {
            // Clear bumps once before its durable boundary and again with the visible reset. The
            // second bump invalidates a snapshot captured from the old rows while that boundary
            // was being established; a post-reset snapshot receives the new generation.
            if (invalidatePersistedSnapshots) persistedDetectionWriteGeneration.incrementAndGet()
            // The store and every per-device side map, off the one list, so a map added later
            // is cleared here too (see perDeviceMaps).
            for (m in perDeviceMaps) m.clear()
            // The boot bounds go with the rows they were derived from: keeping them would let a
            // cleared log's anchors bracket records the user can no longer see the basis for.
            // Keyed by boot counter, not detection id, so they're not in perDeviceMaps.
            bootMinAt.clear(); bootMaxAt.clear()
            // pendingBracket too. Both the mid-drain drop (cleanup) and the hist-end resync clear
            // it precisely so one batch cannot be bracketed twice, and the clear-log path was the
            // one route that missed it: a half-drained batch left here would be resolved against
            // the NEXT drain's boot bounds, bracketing rows the user just erased against anchors
            // from a different session.
            pendingBracket.clear()
        }
        publishDirty.set(false)
        _logDetections.value = emptyList()
        _detections.value = emptyList()
    }

    /** Erase the board's offline buffer (the detections it recorded while the phone was away),
     *  leaving the on-phone log intact. The board restarts its record sequence from 1 after a
     *  wipe, so reset the replay cursor to 0, a stale-high cursor would skip every post-erase
     *  record on the next reconnect and the fresh buffer would be lost. */
    fun clearBufferLog() {
        // Do not reset the local cursor until the board ACKs the destructive write. The callback
        // then re-sends this phone's durable key through the same ACK-gated handshake, so a cleared
        // multi-bond board is never left with a keyless fresh ring.
        enqueueConfigWrite(JSONObject().put("clearlog", true), ConfigWritePurpose.CLEAR_LOG)
    }

    private fun resetReplayCursorAfterClearAck() {
        lastSeq = 0L
        activeLogGeneration = 0L
        histReceived = 0
        histHighestContiguous = 0L
        histBeginSeen = false
        persistCursor(0L, logGeneration = 0L, forward = false)
        // a deliberate rewind, like the hist-begin rebase
    }

    // detected_at instants render with EXACTLY three fractional digits, always - iOS formats
    // with ISO8601DateFormatter's .withFractionalSeconds, and the two exports are meant to be
    // byte-identical so a file from either app reads the same. Instant.toString() emitted the
    // fraction only when the millis were non-zero, so nearly every live row differed between
    // the platforms.
    private val csvInstantFmt = java.time.format.DateTimeFormatterBuilder().appendInstant(3).toFormatter()

    private fun csvInstant(ms: Long): String = csvInstantFmt.format(Instant.ofEpochMilli(ms))

    /** CSV of the current log: when, what, and where for each detection. Location is
     *  the phone's rough position from when we first heard it (the board has no GPS),
     *  or blank if we didn't have one.
     *
     *  [category] is a DeviceType.category key (ALPR / DRONE / BODY CAM / TRACKER), or null for
     *  everything. Callers pass the filter the user is already looking at in the log, so export
     *  means "give me what is on screen" rather than silently handing over the whole history.
     *  Mirrors iOS writeDetections(_:category:). */
    /** A contribution CSV: the detection log with location redacted per the three policy switches.
     *  Redacts the EXPORTED copy only (redactCsvColumns is pure over its input); the app's own log
     *  is never mutated. Defaults match the composer: observer location OUT, drone aircraft
     *  broadcast IN, operator broadcast OUT (it can point at a person on the ground). */
    fun contributionCsv(includeObserverLocation: Boolean = false,
                        includeDroneLocation: Boolean = true,
                        includeOperatorLocation: Boolean = false): String =
        redactCsvColumns(detectionsCsv(null),
            contributionBlankColumns(includeObserverLocation, includeDroneLocation, includeOperatorLocation))

    /** A BOUNDED contribution CSV from the immutable ID -> in-window timestamp map frozen when
     *  Stop was tapped, with location redacted per policy. This preserves membership but does not
     *  atomically freeze changing row fields; UI Stop paths must use [freezeContributionWindow]. */
    @Deprecated("Use freezeContributionWindow at Stop so membership and row content are atomic")
    fun windowedContributionCsv(capturedAtById: Map<String, Long>,
                                includeObserverLocation: Boolean = false,
                                includeDroneLocation: Boolean = true,
                                includeOperatorLocation: Boolean = false): String =
        redactCsvColumns(detectionsCsv(detectedAtOverrides = capturedAtById),
            contributionBlankColumns(includeObserverLocation, includeDroneLocation, includeOperatorLocation))

    /** Freeze the capture-local live ledger and render it in one critical section. History replay
     *  never enters this ledger, and each row carries one latest Detection, phone-clock instant,
     *  and optional observer fix from the same live callback. */
    fun freezeContributionWindow(startMs: Long, stopMs: Long): ContributionWindowSnapshot =
        synchronized(storeLock) {
            val live = contributionCapture.finish(startMs, stopMs)
            val times = live.associate { it.detection.id to it.observedAtMs.coerceIn(startMs, stopMs) }
            val observerSamples = live.associate { it.detection.id to it.observer }
            ContributionWindowSnapshot(
                times,
                detectionsCsv(
                    detectedAtOverrides = times,
                    observerCoordOverrides = observerSamples,
                    // The ledger iterates oldest latest-sighting first; explicit renderer inputs
                    // are already in output order, so reverse once here to keep newest first.
                    detectionOverrides = live.asReversed().map { it.detection },
                ),
            )
        }

    /** Arm capture-local sampling and return its exact Start instant without an unarmed gap. */
    fun beginContributionCapture(): Long = synchronized(storeLock) {
        val startedAt = System.currentTimeMillis()
        contributionCapture.begin(startedAt)
        startedAt
    }

    /** Drop capture-local samples when a capture is discarded before Stop. */
    fun cancelContributionCapture() = synchronized(storeLock) {
        contributionCapture.cancel()
    }

    /** Device ID -> last in-window sighting, snapshotted exactly once at Stop. Frozen keys prevent
     *  post-Stop membership changes; frozen values keep detected_at inside the capture instead of
     *  printing a first-ever session sighting. This does not freeze row content by itself. */
    @Deprecated("Use freezeContributionWindow at Stop so membership and row content are atomic")
    fun windowObservationTimes(startMs: Long, stopMs: Long): Map<String, Long> = synchronized(storeLock) {
        buildMap {
            for (d in store.values) {
                val first = firstSeenAt[d.id]
                val last = lastSeenAt[d.id]
                if (inCaptureWindow(first, last, startMs, stopMs)) {
                    captureTimestamp(last, startMs, stopMs)?.let { put(d.id, it) }
                }
            }
        }
    }

    /** Live count while capturing. Review uses the frozen timestamp map captured at Stop. */
    fun windowObservationCount(startMs: Long, stopMs: Long): Int = synchronized(storeLock) {
        contributionCapture.count(startMs, stopMs)
    }

    private fun freezeDetectionExportLocked(rows: List<Detection>): DetectionExportSnapshot =
        DetectionExportSnapshot(rows.map { d ->
            DetectionExportRowSnapshot(
                detection = d,
                firstSeenMs = firstSeenAt[d.id],
                timeBasis = histTime[d.id]?.basis ?: TimeBasis.Exact,
                observerCoord = mapCoordForExport(d),
            )
        })

    /** Freeze exactly the rows currently visible in the Log lens, in their current order. */
    internal fun freezeLogExport(rows: List<Detection>): DetectionExportSnapshot =
        synchronized(storeLock) { freezeDetectionExportLocked(rows.toList()) }

    /** Freeze the manager's current Compose-sized feed and every evictable side field in one
     * store critical section. Pause uses this rather than the last coalesced StateFlow emission:
     * at STORE_CAP a UI row can be evicted between that emission and the tap, taking firstSeen,
     * time basis and captured location with it. Tap-time current data is the honest pause point. */
    internal fun freezeFeedExport(): DetectionExportSnapshot = synchronized(storeLock) {
        val rows = store.values.toList().asReversed().let { newestFirst ->
            if (newestFirst.size > FEED_CAP) newestFirst.take(FEED_CAP) else newestFirst
        }
        freezeDetectionExportLocked(rows)
    }

    /** The destructive Clear sheet's escape hatch intentionally snapshots the complete store. */
    internal fun freezeWholeLogExport(category: String? = null): DetectionExportSnapshot =
        synchronized(storeLock) {
            val rows = store.values.asSequence()
                .filter { category == null || it.type.category == category }
                .toList()
                .asReversed()
            freezeDetectionExportLocked(rows)
        }

    internal fun renderDetectionsCsv(snapshot: DetectionExportSnapshot): String =
        detectionsCsv(
            detectionOverrides = snapshot.rows.map { it.detection },
            firstSeenOverrides = snapshot.rows.associate { it.detection.id to it.firstSeenMs },
            timeBasisOverrides = snapshot.rows.associate { it.detection.id to it.timeBasis },
            observerCoordOverrides = snapshot.rows.associate { it.detection.id to it.observerCoord },
        )

    /** [detectedAtOverrides], when set, restricts export to its frozen keys and writes its in-window
     *  phone-clock values as detected_at. Null (the default) preserves full-history semantics. */
    fun detectionsCsv(
        category: String? = null,
        detectedAtOverrides: Map<String, Long>? = null,
        observerCoordOverrides: Map<String, Pair<Double, Double>?>? = null,
        detectionOverrides: List<Detection>? = null,
        firstSeenOverrides: Map<String, Long?>? = null,
        timeBasisOverrides: Map<String, TimeBasis>? = null,
    ): String {
        // The header is DETECTION_CSV_COLUMNS, shared with the contribution redactor so a rename
        // can never leave a location column unblanked. The UI names a manufacturer, and the
        // evidence file has to be able to say the same thing.
        val rows = StringBuilder(detectionCsvRow(DETECTION_CSV_COLUMNS, ::csvSafe))
        fun iStr(v: Int?): String = v?.toString() ?: ""
        // Export the full store (newest first), not the bounded live feed, so nothing is lost.
        // Snapshot the values under storeLock so the export can't collide with the BLE callback
        // thread mutating the shared map mid-iteration; build the CSV rows outside the lock.
        // The category and frozen-time filters only read immutable Detection fields but run inside
        // the lock with the store snapshot so there is one atomic membership decision. Null
        // detectedAtOverrides (the default) exports the full store, unchanged.
        val selectedRows = synchronized(storeLock) {
            (detectionOverrides ?: store.values).filter { d ->
                (category == null || d.type.category == category) &&
                    (detectedAtOverrides == null || d.id in detectedAtOverrides)
            }.toList()
        }
        // Store values are oldest-first; explicit snapshots already carry the exact UI order.
        val snapshot = if (detectionOverrides == null) selectedRows.asReversed() else selectedRows
        for (d in snapshot) {
            // Approx records (buffered before the board had a clock) carry only a synthetic
            // sort-time near epoch, not a real capture time. Leave the column blank rather than
            // exporting a bogus 1969/1970 date.
            // Test the STAMP as well as the row, because the two can disagree: a device replayed
            // from the buffer and THEN heard live keeps its pseudo firstSeenAt (the live path only
            // stamps a FIRST sighting) while its store row is replaced by a live, non-approx one.
            // Going on the row alone there exports the pseudo stamp as a real 2001 date, in the
            // one file that gets handed over as evidence. isApproxTime is the arbiter for every
            // other printed stamp, so it has to be for this one too.
            val capturedAt = detectedAtOverrides?.get(d.id)
            val fs = capturedAt ?: if (firstSeenOverrides != null && d.id in firstSeenOverrides) {
                firstSeenOverrides[d.id]
            } else firstSeen(d.id)
            // A reader of this file has to be able to tell a clock reading from a reconstruction,
            // so detected_at never travels alone: time_basis says how it was arrived at and
            // time_precision_s how wide it could be. A bracketed row has no single time at all,
            // so it exports the ISO 8601 interval instead of a point, and the unbounded end of a
            // one-sided bracket is ".." (the open-interval form).
            val basis = when {
                capturedAt != null -> TimeBasis.Exact
                timeBasisOverrides != null && d.id in timeBasisOverrides ->
                    timeBasisOverrides.getValue(d.id)
                else -> timeBasis(d.id)
            }
            val whenAt: String
            val basisName: String
            var precision = ""
            when {
                capturedAt != null -> {
                    whenAt = csvInstant(capturedAt)
                    basisName = TimeBasis.Exact.csvName
                }
                basis is TimeBasis.Reconstructed -> {
                    whenAt = csvInstant(basis.atMs)
                    basisName = basis.csvName
                    precision = basis.precisionSec.toString()
                }
                basis is TimeBasis.Bracketed -> {
                    val a = basis.afterMs?.let { csvInstant(it) } ?: ".."
                    val z = basis.beforeMs?.let { csvInstant(it) } ?: ".."
                    whenAt = "$a/$z"
                    basisName = basis.csvName
                }
                // Unknown by the model, or a row from a build that predates it whose stamp is the
                // seq pseudo-time. Test the STAMP as well as the row, because the two can disagree:
                // a device replayed from the buffer and THEN heard live keeps its pseudo
                // firstSeenAt (the live path only stamps a FIRST sighting) while its store row is
                // replaced by a live, non-approx one. Going on the row alone there exports the
                // pseudo stamp as a real 2001 date, in the one file that gets handed over as
                // evidence. Blank beats a bogus date either way.
                basis is TimeBasis.Unknown || d.approx || isApproxTime(fs) || fs == null -> {
                    whenAt = ""
                    basisName = TimeBasis.Unknown.csvName
                }
                else -> {
                    whenAt = fs?.let { csvInstant(it) } ?: ""
                    basisName = TimeBasis.Exact.csvName
                }
            }
            // approx_lat/lon is the PHONE's position, so this is NOT mapCoord(): that falls back
            // to the detection's own wire lat/lon, which on a drone row is the AIRCRAFT's Remote ID
            // broadcast (the OVERLOADED `lat`,`lon` row in ble-protocol.md; see
            // droneExportCoords). Ungated it exported the aircraft as the observer
            // and made approx_lat identical to drone_lat. Matches iOS buildCSV.
            val coord = if (observerCoordOverrides != null && d.id in observerCoordOverrides) {
                observerCoordOverrides[d.id]
            } else {
                mapCoordForExport(d)
            }
            val lat = coord?.let { f6(it.first) } ?: ""
            val lon = coord?.let { f6(it.second) } ?: ""
            // Drone Remote ID telemetry, blank for a non-drone row. approx_lat/lon is the PHONE's
            // position when it heard the device; a drone also broadcasts its OWN position and the
            // OPERATOR (pilot) position, the single most valuable field in a drone capture, so it
            // must survive into the evidence export. The type gate that keeps the two apart is
            // droneExportCoords, extracted so a test can pin it; read its comment before touching
            // either column pair.
            val air = droneExportCoords(d)
            val dLat = air.droneLat?.let { f6(it) } ?: ""
            val dLon = air.droneLon?.let { f6(it) } ?: ""
            val opLat = air.operatorLat?.let { f6(it) } ?: ""
            val opLon = air.operatorLon?.let { f6(it) } ?: ""
            val externalText = detectionCsvExternalText(d.rid, d.maker)
            rows.append('\n').append(detectionCsvRow(
                // spreadsheetSafeText on mac: it is decoded off the wire as a free string, so an
                // impostor board can put "=cmd(...)" in it. A real MAC ("aa:bb:...") is untouched.
                listOf(whenAt, basisName, precision, d.type.label, spreadsheetSafeText(d.mac), d.rssi.toString(),
                    d.sourceLabel, d.methodLabel, d.confidence.toString(),
                    d.count.toString(), lat, lon, d.companyIdHex ?: "",
                    externalText.uasId, dLat, dLon,
                    iStr(d.altitude), iStr(d.speedH), iStr(d.heading), iStr(d.heightAGL),
                    opLat, opLon, iStr(d.pilotAlt), d.ridStatusLabel ?: "",
                    externalText.maker),
                ::csvSafe,
            ))
        }
        return rows.toString()
    }

    /** Six-decimal coordinate, ALWAYS with a dot.
     *
     *  Locale.US is not cosmetic here. Kotlin's String.format uses the DEFAULT locale, so on a
     *  German/French/Spanish phone "%.6f".format(32.763243) yields "32,763243" - a comma INSIDE a
     *  CSV field, which shifts every column after it and silently corrupts the one file that gets
     *  handed over as evidence. It also emits invalid GPX (lat="32,763243"), which mapping apps
     *  reject outright. iOS never had this: Swift's String(format:) is POSIX unless handed a
     *  locale, so this was a live iOS/Android parity break on any non-dot-decimal device. */
    private fun f6(v: Double): String = String.format(java.util.Locale.US, "%.6f", v)

    /** XML text escape. Ampersand FIRST or it double-escapes the entities added after it. */
    private fun xmlSafe(s: String): String =
        s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    /** GPX 1.1 for import into a mapping app (Gaia GPS, Caltopo, OsmAnd).
     *
     *  THE ONE THING A READER MUST NOT MISUNDERSTAND: for everything except a drone, the pin is
     *  where the PHONE was standing, NOT where the device is. A passive radio cannot tell you
     *  where a transmitter is, only that it was audible from here, which at BLE range could be
     *  most of a block in any direction. GPX has no way to express that uncertainty, so every
     *  such waypoint is NAMED "Heard:" and its description says so in words. Do not "clean that
     *  up": the whole file is misread the moment it looks like a map of camera positions.
     *
     *  A drone is the exception and gets up to three waypoints, because Remote ID broadcasts real
     *  positions: where it was heard from, where the AIRCRAFT said it was, and where the OPERATOR
     *  said they were. Those last two are the only true device positions this product can export.
     *
     *  NOT YET UNDER TEST, stated honestly. iOS's twin is covered by BeaconsTests/ExportTests.swift
     *  (the drone gate, waypoint counts, escaping, the bracketed-row time omission); this side's
     *  AcabBleManagerExportTest.kt covers only the CSV drone gate and wire clamps, zero GPX.
     *  renderDetectionsGpx already takes a pure snapshot (DetectionExportSnapshot), so the
     *  remaining blocker is only that it lives on the Context-requiring manager class and cannot
     *  run under plain JUnit; make it callable without a manager and reuse the ExportTests.swift
     *  JSON fixtures verbatim. Treat any change on this side as unguarded until a Kotlin test
     *  runs renderDetectionsGpx on those shared fixtures. */
    fun detectionsGpx(category: String? = null): String =
        renderDetectionsGpx(freezeWholeLogExport(category))

    internal fun renderDetectionsGpx(snapshot: DetectionExportSnapshot): String {
        val out = StringBuilder(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
            "<gpx version=\"1.1\" creator=\"beacons\" xmlns=\"http://www.topografix.com/GPX/1/1\">")

        // One waypoint. `time` is omitted rather than faked when the row has no single instant:
        // a bracketed row's honest answer is a RANGE, and GPX <time> can only hold a point, so
        // writing either end of the bracket would state a precision the data does not have. The
        // basis always rides in <desc> instead.
        fun wpt(lat: Double, lon: Double, name: String, desc: String, time: String?) {
            out.append("\n  <wpt lat=\"").append(f6(lat))
               .append("\" lon=\"").append(f6(lon)).append("\">")
            if (!time.isNullOrEmpty()) out.append("\n    <time>").append(xmlSafe(time)).append("</time>")
            out.append("\n    <name>").append(xmlSafe(name)).append("</name>")
            out.append("\n    <desc>").append(xmlSafe(desc)).append("</desc>")
            out.append("\n  </wpt>")
        }

        for (row in snapshot.rows) {
            val d = row.detection
            val fs = row.firstSeenMs
            val basis = row.timeBasis
            // A single instant, or null when the row is bracketed/unknown (see wpt above).
            var stamp: String? = null
            val basisNote: String
            when {
                basis is TimeBasis.Reconstructed -> {
                    stamp = fs?.let { csvInstant(it) }
                    basisNote = "reconstructed, +/-${basis.precisionSec}s"
                }
                basis is TimeBasis.Bracketed -> {
                    val a = basis.afterMs?.let { csvInstant(it) } ?: ".."
                    val z = basis.beforeMs?.let { csvInstant(it) } ?: ".."
                    basisNote = "bracketed $a/$z"
                }
                // SAME GUARD AS detectionsCsv above, and it must not drift from it. A row buffered
                // before the board had a clock carries a synthetic near-epoch sort key, not a
                // capture time. Testing `fs == null` alone lets a NON-NULL pseudo stamp through and
                // prints it as a real 2001 date inside a <time> element, i.e. a fabricated
                // timestamp in a file handed over as evidence. d.approx AND isApproxTime(fs) are
                // both needed: the row and its stamp disagree when a buffered device is later
                // heard live.
                basis is TimeBasis.Unknown || d.approx || isApproxTime(fs) || fs == null ->
                    basisNote = "time unknown"
                else -> { stamp = csvInstant(fs); basisNote = "exact" }
            }
            val label = d.maker?.let { "${d.type.label} ($it)" } ?: d.type.label
            val facts = mutableListOf(d.mac, "${d.rssi} dBm", "conf ${d.confidence}",
                "matched on ${d.methodLabel}", "${d.count}x", "time: $basisNote")
            d.detail?.takeIf { it.isNotEmpty() }?.let { facts.add(it) }
            val isDrone = d.type == DeviceType.DRONE

            // Where we heard it FROM. mapCoord falls back to the detection's own wire lat/lon,
            // which for a DRONE is the aircraft's Remote ID position, not the phone - the same
            // overload that produced the CSV bug. Using it here would label the aircraft's
            // position "Position is where the PHONE was", the exact inversion of the honesty rule
            // this writer exists to enforce. A drone's real position gets its own waypoint below.
            val heard = row.observerCoord
            if (heard != null) {
                wpt(heard.first, heard.second, "Heard: $label",
                    "Position is where the PHONE was, not the device. Audible from here only. " +
                        facts.joinToString(" | "), stamp)
            }
            // Real broadcast positions. Drone-only, matching the CSV's type gate.
            if (isDrone) {
                val dla = d.lat; val dlo = d.lon
                if (dla != null && dlo != null && validCoord(dla, dlo)) {
                    wpt(dla, dlo, "Drone (broadcast position): $label",
                        "Aircraft position from its own Remote ID broadcast. " +
                            facts.joinToString(" | "), stamp)
                }
                val pla = d.pilotLat; val plo = d.pilotLon
                if (pla != null && plo != null && validCoord(pla, plo)) {
                    wpt(pla, plo, "Drone OPERATOR: $label",
                        "Operator position from the aircraft's Remote ID broadcast. " +
                            facts.joinToString(" | "), stamp)
                }
            }
        }
        out.append("\n</gpx>")
        return out.toString()
    }

    // NOT composed with spreadsheetSafeText: this transform runs on EVERY cell of a row, and the
    // neutralizer prefixes a leading '-', which would corrupt every negative numeric cell (rssi
    // "-58", altitudes, vertical speed). Formula neutralization is applied at the source to the
    // cells that carry radio-sourced TEXT: rid/maker via detectionCsvExternalText, and mac at the
    // row emitter.
    private fun csvSafe(s: String): String = csvField(s)

    // ---- whitelist (ignored devices) ----

    /** The exact state used by both feed filtering and the dossier label. */
    fun muteRuleStatus(item: IgnoredDevice, now: Long = System.currentTimeMillis()): MuteRuleStatus =
        evaluateMuteRule(
            item,
            now,
            if (item.isPlaceRule) freshMuteCoord() else null,
            muteDistanceMeters,
        )

    private fun muteActive(item: IgnoredDevice, now: Long = System.currentTimeMillis()): Boolean =
        muteRuleStatus(item, now) == MuteRuleStatus.ACTIVE

    private fun activeIgnoredMacs(
        now: Long = System.currentTimeMillis(),
        indexes: ManagedListIndexes = managedListIndexes,
    ): Set<String> {
        val rules = indexes.ignoredByMac.values
        // Snapshot location once for the entire projection. Calling muteRuleStatus per row used
        // to repeat the freshness/provider path up to IGNORE_CAP times on every 300 ms publish.
        val currentCoord = if (rules.any { it.isPlaceRule }) freshMuteCoord() else null
        return buildSet(rules.size) {
            for (item in rules) {
                if (evaluateMuteRule(item, now, currentCoord, muteDistanceMeters) ==
                    MuteRuleStatus.ACTIVE) add(item.mac)
            }
        }
    }

    /** The board has no clock or geofence evaluator, so it receives permanent rules only. */
    private fun boardIgnoredMacs(items: List<IgnoredDevice> = _ignored.value): List<String> =
        items.filter(::isBoardBackedMute).map { it.mac }

    fun isIgnored(mac: String): Boolean {
        val item = managedListIndexes.ignoredByMac[mac.lowercase()] ?: return false
        return muteActive(item)
    }

    /** Current policy for ingest and per-row UI checks. A historical WATCHED wire type is not an
     * input: only the current exact-MAC watchlist may outrank the current mute rule. */
    fun isMutedForProjection(mac: String): Boolean {
        val indexes = managedListIndexes
        return managedIndexSaysMuted(indexes, mac, ::muteActive)
    }

    /** Publish both visible lists and their hot-path indexes as one logical generation. The single
     * volatile index assignment is the BLE ingest boundary; StateFlows follow for UI consumers. */
    private fun installManagedLists(
        ignored: List<IgnoredDevice>,
        watched: List<WatchedDevice>,
    ) {
        val normalizedIgnored = ignored.map { item ->
            val mac = item.mac.lowercase()
            if (item.mac == mac) item else item.copy(mac = mac)
        }
        val normalizedWatched = watched.map { item ->
            val mac = item.mac.lowercase()
            if (item.mac == mac) item else item.copy(mac = mac)
        }
        managedListIndexes = buildManagedListIndexes(normalizedIgnored, normalizedWatched)
        _ignored.value = normalizedIgnored
        _watched.value = normalizedWatched
    }

    /** Silence a device locally; permanent scope is also persisted on the board. Ignore and
     *  watch are mutually exclusive, so ignoring a starred device un-stars it first.
     *
     *  Returns false for THREE reasons, and the caller can only tell two of them apart: the list
     *  is already full and the device was NOT ignored (the board holds IGNORE_CAP entries and
     *  silently drops the rest); a HERE scope with no fix good enough to anchor it; or a MAC the
     *  board could never store (see isBoardPushableMac, widened from "blank" to "full shape").
     *  DetailScreen's mute sheet has a two-branch else, so that third case shows the "the
     *  muted-device list is full" copy and an instruction that can never help. Unreachable from
     *  genuine hardware - only a spoofed or non-conforming peer advertises a MAC of that shape -
     *  and fixing it properly means a third message in that sheet, not a change here. */
    fun ignoreDevice(d: Detection, scope: MuteScope = MuteScope.PERMANENT): Boolean =
        managedListEdits.serialized { _ ->
        val mac = d.mac.lowercase()
        // Same guard the batch path applies, on the shape the board can actually store. A blank or
        // malformed MAC would become a rule the app shows as muted while parseMac6 drops it, so the
        // board keeps alerting on the device and its count can never match ours again.
        if (!isBoardPushableMac(mac)) return@serialized false
        val now = System.currentTimeMillis()
        val here = if (scope == MuteScope.HERE) freshSelfFix()?.asMutePosition() else null
        if (scope == MuteScope.HERE &&
            !positionSupportsHere(here, DEFAULT_HERE_RADIUS_METERS)) return@serialized false
        val previous = _ignored.value.firstOrNull { it.mac == mac }
        // Replacing a scoped rule is allowed at capacity; only a genuinely new row consumes one.
        if (previous == null && _ignored.value.size >= IGNORE_CAP) return@serialized false
        val replacement = IgnoredDevice(
            mac = mac,
            label = previous?.label?.takeIf { it.isNotBlank() } ?: d.displayName,
            expiresAt = when (scope) {
                MuteScope.ONE_HOUR -> now + 3_600_000L
                MuteScope.ONE_DAY -> now + 86_400_000L
                else -> null
            },
            latitude = if (scope == MuteScope.HERE) here?.coord?.first else null,
            longitude = if (scope == MuteScope.HERE) here?.coord?.second else null,
        )
        val wasWatched = isWatched(mac)
        if (previous == replacement && !wasWatched) return@serialized true
        val proposedIgnored = if (previous == null) {
            _ignored.value + replacement
        } else {
            _ignored.value.map { if (it.mac == mac) replacement else it }
        }
        val proposedWatched = _watched.value.filterNot { it.mac == mac }
        if (!commitManagedLists(proposedIgnored, proposedWatched)) return@serialized false
        // Keep the row in the sealed evidence store. feedSnapshot() suppresses active rules and
        // reveals the same record again when a timed/HERE rule expires or leaves its boundary.
        publishNow()
        true
    }

    /** Silence a batch of devices at once (Log select-mode): one merged ignore-list push to the
     *  board (chunked per MAC_CHUNK by sendMacList) and one republish, instead of one push per
     *  row. Caps at the firmware's 256-entry ignore list.
     *  Returns the number of devices the CAP turned away (0 when all of them landed), so a
     *  caller can tell the user the list is full instead of truncating in silence.
     *
     *  A MAC the board could never store (isBoardPushableMac) IS counted here, because such a row
     *  ends up muted NOWHERE - the board cannot parse it, and a rule the board never took is not a
     *  mute. That shares this return's wording with the list-full case, which stays a known gap:
     *  today every unit of this return is worded as "the muted-device list is full", and the honest
     *  repair is a second reason in the caller's toast rather than a bigger number out of here.
     *  iOS twin: BLEManager.ignoreDevices, same rule and same wording gap. */
    fun ignoreDevices(detections: List<Detection>): Int = managedListEdits.serialized { _ ->
        if (detections.isEmpty()) return@serialized 0
        val existing = _ignored.value.associateBy { it.mac }.toMutableMap()
        var refused = 0
        var changed = false
        val selected = HashSet<String>()
        val attempted = HashSet<String>()
        for (d in detections) {
            val mac = d.mac.lowercase()
            // Dedupe FIRST so one device listed twice cannot be refused twice, then count a shape
            // refusal. Dropping it silently made LogScreen's `requested - refused` tally report a
            // device as muted that is muted NOWHERE. iOS twin: the same two lines in
            // BLEManager.ignoreDevices.
            if (!attempted.add(mac)) continue
            if (!isBoardPushableMac(mac)) { refused++; continue }
            val prior = existing[mac]
            if (prior != null) {
                selected.add(mac)
                if (!isBoardBackedMute(prior)) {
                    existing[mac] = prior.copy(expiresAt = null, latitude = null, longitude = null)
                    changed = true
                }
                continue
            }
            if (existing.size >= IGNORE_CAP) { refused++; continue }
            selected.add(mac)
            existing[mac] = IgnoredDevice(mac, d.displayName)
            changed = true
        }
        // exclusivity: pull any newly-ignored MACs off the watchlist so the two never overlap
        val unstarred = _watched.value.any { it.mac in selected }
        if (changed || unstarred) {
            val proposedIgnored = if (changed) existing.values.toList() else _ignored.value
            val proposedWatched = if (unstarred) {
                _watched.value.filterNot { it.mac in selected }
            } else _watched.value
            if (!commitManagedLists(proposedIgnored, proposedWatched)) {
                // Nothing became visible or reached the board. Report every attempted MAC as not
                // added so the caller never claims success for an edit that is absent on disk.
                return@serialized attempted.size
            }
            publishNow()
        }
        refused
    }

    /** Un-silence a device. */
    fun unignore(mac: String) {
        managedListEdits.serialized { _ ->
            val kept = _ignored.value.filterNot { it.mac == mac.lowercase() }
            if (kept.size == _ignored.value.size) return@serialized
            if (!commitManagedLists(kept, _watched.value)) return@serialized
            publishNow()
        }
    }

    private fun pruneExpiredMutes(publish: Boolean = true): Boolean =
        managedListEdits.serialized { _ ->
        val now = System.currentTimeMillis()
        val kept = _ignored.value.filterNot { it.expiresAt?.let { end -> end <= now } == true }
        if (kept.size == _ignored.value.size) return@serialized false
        if (!commitManagedLists(kept, _watched.value)) return@serialized false
        if (publish) publishNow()
        true
    }

    // ---- watchlist (starred devices) ----

    fun isWatched(mac: String): Boolean = mac.lowercase() in managedListIndexes.watchedMacs

    /** Star a device: the board alerts on this exact MAC every time it's seen, even without a
     *  signature match. Watch and ignore are mutually exclusive, so starring an ignored device
     *  un-ignores it first (the scanning path can filter ignored MACs before classification). */
    fun watchDevice(d: Detection) {
        managedListEdits.serialized { _ ->
            val mac = d.mac.lowercase()
            // Same shape guard as the ignore paths: a star the board's parser drops leaves the app
            // claiming a watch the board never took, and "wat" diverged for the session.
            if (!isBoardPushableMac(mac) || isWatched(mac)) return@serialized
            if (_watched.value.size >= WATCH_CAP) return@serialized
            val proposedIgnored = _ignored.value.filterNot { it.mac == mac }
            val proposedWatched = _watched.value + WatchedDevice(mac, d.displayName)
            if (!commitManagedLists(proposedIgnored, proposedWatched)) return@serialized
            publishNow()
        }
    }

    /** Un-star a device. */
    fun unwatch(mac: String) {
        managedListEdits.serialized { _ ->
            val kept = _watched.value.filterNot { it.mac == mac.lowercase() }
            if (kept.size == _watched.value.size) return@serialized
            commitManagedLists(_ignored.value, kept)
        }
    }

    /** Rename a starred device's label (management UI); no board write, the label is app-only. */
    fun renameWatched(mac: String, label: String) {
        managedListEdits.serialized { _ ->
            val t = label.trim()
            if (t.isEmpty()) return@serialized
            val m = mac.lowercase()
            val proposed = _watched.value.map { if (it.mac == m) it.copy(label = t) else it }
            if (proposed == _watched.value) return@serialized
            commitManagedLists(_ignored.value, proposed)
        }
    }

    /** Rename an ignored device. Same contract as [renameWatched]: an empty string is rejected so
     *  a cleared field cannot blank the label and leave an unidentifiable row. */
    fun renameIgnored(mac: String, label: String) {
        managedListEdits.serialized { _ ->
            val t = label.trim()
            if (t.isEmpty()) return@serialized
            val m = mac.lowercase()
            val proposed = _ignored.value.map { if (it.mac == m) it.copy(label = t) else it }
            if (proposed == _ignored.value) return@serialized
            commitManagedLists(proposed, _watched.value)
        }
    }

    /** Decode both encrypted lists before publishing either one, then install the pair under the
     * same edit-generation boundary used by taps. Settings can be opened without a detection feed;
     * exposing ignored rows while watched was still its construction-time empty value allowed a
     * fast rename/unignore to commit that temporary empty sibling over a real watchlist. */
    private fun loadManagedLists(loadToken: Long): Boolean {
        val storedIgnored = prefs.getString("ignored", null)
        val rawIgnored = storedIgnored?.let(::openManagedList)
        val loadedIgnored: List<IgnoredDevice>? = when {
            storedIgnored == null -> emptyList()
            rawIgnored == null -> null
            else -> runCatching {
                val arr = JSONArray(rawIgnored)
                (0 until arr.length()).map {
                    val o = arr.getJSONObject(it)
                    IgnoredDevice(
                        mac = o.optString("mac"),
                        label = o.optString("label"),
                        expiresAt = o.optLong("expiresAt").takeIf { o.has("expiresAt") },
                        latitude = o.optDouble("latitude").takeIf { o.has("latitude") },
                        longitude = o.optDouble("longitude").takeIf { o.has("longitude") },
                        radiusMeters = o.optDouble("radiusMeters", 50.0),
                    )
                }
            }.getOrNull()
        }

        val storedWatched = prefs.getString("watched", null)
        val rawWatched = storedWatched?.let(::openManagedList)
        val loadedWatched: List<WatchedDevice>? = when {
            storedWatched == null -> emptyList()
            rawWatched == null -> null
            else -> runCatching {
                val arr = JSONArray(rawWatched)
                (0 until arr.length()).map {
                    val o = arr.getJSONObject(it)
                    WatchedDevice(o.optString("mac"), o.optString("label"))
                }
            }.getOrNull()
        }

        return managedListEdits.serialized { _ ->
            if (!managedListLoadGate.accepts(loadToken)) return@serialized false
            val ignoredAuthoritative = storedManagedListIsAuthoritative(
                storedPresent = storedIgnored != null,
                decodedSuccessfully = loadedIgnored != null,
            )
            val watchedAuthoritative = storedManagedListIsAuthoritative(
                storedPresent = storedWatched != null,
                decodedSuccessfully = loadedWatched != null,
            )
            if (!ignoredAuthoritative || !watchedAuthoritative) {
                // Do not leave demo rows masquerading as real managed settings after exitDemo.
                // These empty flows are explicitly NON-authoritative: ready stays false, so they
                // can neither overwrite the preserved bytes nor reconcile an empty board list.
                installManagedLists(emptyList(), emptyList())
                managedListsReady = false
                android.util.Log.e(
                    "AcabBleManager",
                    "managed-list storage could not be opened; preserving bytes and disabling edits/sync",
                )
                return@serialized false
            }
            val ignored = loadedIgnored!!
            val watched = loadedWatched!!
            installManagedLists(ignored, watched)
            // Migrations remain single-key but stay under the SAME generation boundary as the
            // paired install. Otherwise a fast edit can durably commit a newer pair between the
            // install and this migration, after which the stale migration reverses one key.
            if (ignored.isNotEmpty() && storedIgnored != null && isLegacyManagedList(storedIgnored)) {
                migrateManagedList("ignored", ignoredJson(ignored), storedIgnored)
            }
            if (watched.isNotEmpty() && storedWatched != null && isLegacyManagedList(storedWatched)) {
                migrateManagedList("watched", watchedJson(watched), storedWatched)
            }
            managedListsReady = true
            true
        }
    }

    /** Push the watchlist to the board so it alerts on those MACs at the source. Same MAC
     *  string format and cap as the ignore list; the board keys reconciliation on "wat".
     *
     *  USER-EDIT path. An edit that leaves the list EMPTY is a real clear, so it is remembered
     *  until a board has taken it; the connect-time re-statement goes through resyncListsOnConnect.
     *
     *  [userEdit] false is the STATUS reconciler re-stating a list the board has not matched: it
     *  is spending a bounded budget, so it must not refill the budget on its way through. */
    private fun sendWatchList(userEdit: Boolean = true) {
        if (!managedListPersistenceAllowed(_demoMode.value)) return
        if (!managedListsReady) return
        if (userEdit) watchPushAttempts = 0
        // The destructive empty intent was committed atomically with the exact list snapshot in
        // commitManagedLists. Never manufacture one here: this method is also used by STATUS
        // reconciliation, and a board push may only follow a durable phone generation.
        if (_watched.value.isEmpty() && !listClearPending("watch")) return
        sendMacList("watch", _watched.value.map { it.mac })
    }

    /** Re-push attempts spent on each board-backed MAC list since the board last agreed with this
     *  phone. Reset on a fresh link and on any user edit, so only a divergence the board can never
     *  resolve runs the budget out. See the STATUS reconciler in [ingest]. */
    private var ignorePushAttempts = 0
    private var watchPushAttempts = 0

    /** Whether the last user edit on [key] emptied the list and we have not yet delivered that
     *  clear to a board. Persisted, because the edit can happen while disconnected. Mirrors iOS. */
    private fun listClearIntent(key: String): ManagedListClearIntent = when (key) {
        "ignore" -> ignoreClearIntent
        "watch" -> watchClearIntent
        else -> error("unknown managed-list key: $key")
    }
    private fun listClearPending(key: String): Boolean = listClearIntent(key).isPending
    private fun retireListClearPending(key: String) {
        if (!listClearIntent(key).retire()) {
            android.util.Log.w(
                "AcabBleManager",
                "$key clear acknowledgement was not durably retired; retaining it for retry",
            )
        }
    }

    /** Re-state both lists to a freshly connected board.
     *
     *  Skips a list we have nothing to say about. Pushing an EMPTY list unconditionally is how a
     *  fresh install (or any second phone that had never starred anything) silently wiped every
     *  star on a board the instant it connected: the push committed an empty list and the board
     *  rewrote its NVS. An empty list is only worth sending when the user actually emptied it,
     *  which is what the persisted clear-pending flag records. The firmware refuses a bare empty
     *  commit as well (it requires "clr"), so this is belt and braces, not the only guard. */
    private fun resyncListsOnConnect() {
        if (!managedListsReady) return
        val permanent = boardIgnoredMacs()
        when (boardIgnoreSyncAction(
            localPermanentCount = permanent.size,
            boardReportedCount = null,
            intentionalClearPending = listClearPending("ignore"),
        )) {
            BoardIgnoreSyncAction.PUSH_LIST -> sendIgnoreList()
            BoardIgnoreSyncAction.PUSH_CLEAR -> sendIgnoreList(intentionalClear = true)
            BoardIgnoreSyncAction.ACK_CLEAR,
            BoardIgnoreSyncAction.NONE -> Unit
        }
        if (_watched.value.isNotEmpty() || listClearPending("watch")) sendMacList("watch", _watched.value.map { it.mac })
    }

    // ---- "mark all seen" baseline watermark ----

    /** Drop a baseline at the newest detection's first-seen time. The Log's "New only" view
     *  then shows only detections first heard after this point (and not on the ignore list). */
    fun markAllSeen() {
        // Demo first-seen stamps belong to a disposable sample store. Letting them move either
        // persisted axis would mark genuine retained detections seen after exitDemo reloads them.
        if (!persistedLogMutationAllowed(_demoMode.value)) return
        // Two axes, two baselines. The buffered rows carry seq-derived ordering keys, not times,
        // so they only compare meaningfully against each other. Fall back to now on the live axis
        // when nothing live is in the store, or a store of buffered rows alone would drag the live
        // watermark down to 2001 and every real sighting since would still read as new.
        // Snapshot the store's values under storeLock so this main-thread read can't collide with
        // the BLE callback thread mutating the shared map; do the stamp mapping outside the lock.
        // snapshot store AND read firstSeenAt in ONE locked section (both are BLE-thread-mutated).
        val stamps = synchronized(storeLock) { store.values.mapNotNull { firstSeenAt[it.id] } }
        _seenWatermark.value = stamps.filter { it > HIST_PSEUDO_BASE }.maxOrNull()
            ?: System.currentTimeMillis()
        // min, not max: the pseudo axis descends with seq, so the smallest stamp in the store is
        // the most recent buffered record. Taking the max would baseline on the OLDEST one and
        // leave every later drain reading as already-seen.
        approxWatermark = stamps.filter { it <= HIST_PSEUDO_BASE }.minOrNull() ?: approxWatermark
        prefs.edit()
            .putLong("seenWatermark", _seenWatermark.value)
            .putLong("approxWatermark", approxWatermark)
            .apply()
    }

    /** First-run baseline for the "new" dots. The first time the log is ever opened normally,
     *  treat whatever is already stored as seen, so a fresh install (or a first offline backlog)
     *  does not paint a red dot on every row. Once-only, guarded by a persisted flag; from then on
     *  the watermark advances each time the user leaves the Log tab (see MainScreen's Tab.LOG
     *  onDispose), so a dot always means "arrived since you last looked". Mirrors iOS. */
    fun seedSeenWatermarkOnce() {
        if (!persistedLogMutationAllowed(_demoMode.value)) return
        if (prefs.getBoolean("seenWatermarkSeeded", false)) return
        markAllSeen()
        prefs.edit().putBoolean("seenWatermarkSeeded", true).apply()
    }

    /** True when this detection was first heard after the "mark all seen" watermark. */
    fun isNewSinceWatermark(d: Detection): Boolean {
        val fs = synchronized(storeLock) { firstSeenAt[d.id] } ?: return true
        // Two axes, two directions: the live one ascends with the wall clock, the pseudo one
        // descends with seq (see approxWatermark).
        return if (fs <= HIST_PSEUDO_BASE) fs < approxWatermark else fs > _seenWatermark.value
    }

    /** Which of [dets] were first heard after the "mark all seen" watermark, in ONE storeLock
     *  take. The per-row isNewSinceWatermark is fine for the visible viewport, but calling it
     *  for a whole feed (the Log's tallies + NewOnly filter) is thousands of main-thread lock
     *  acquisitions per publish, each able to stall behind a long BLE-thread hold. */
    fun newIdSet(dets: List<Detection>): Set<String> {
        val firstSeen = synchronized(storeLock) { HashMap(firstSeenAt) }
        val seenWm = _seenWatermark.value
        val approxWm = approxWatermark
        val out = HashSet<String>()
        for (d in dets) {
            val fs = firstSeen[d.id]
            val isNew = fs == null || if (fs <= HIST_PSEUDO_BASE) fs < approxWm else fs > seenWm
            if (isNew) out.add(d.id)
        }
        return out
    }

    /** Paused equivalent: current watermarks applied to first-seen values frozen at Pause. */
    internal fun newIdSet(snapshot: DetectionExportSnapshot): Set<String> =
        frozenNewIdSet(snapshot.rows, _seenWatermark.value, approxWatermark)

    // ---- managed lists at rest ----
    //
    // A HERE mute stores the exact coordinate the user was standing on when they made it, which
    // is almost always home or somewhere they return to, and both lists carry MACs plus the
    // advertised names of the gear around them. That is the same class of data as the detection
    // log, so it gets the log's at-rest posture (AND-SEC-1): sealed with the non-exportable
    // AndroidKeyStore key rather than left as cleartext JSON in the app's shared-prefs XML, where
    // a raw sandbox dump off a seized or rooted phone reads it straight out. allowBackup="false"
    // plus the sharedpref exclusions already keep this file out of cloud backup and device
    // transfer, so the dump is the exposure this closes. iOS holds the same two lists in
    // completeFileProtection files in Application Support (BLEManager.writeProtectedList).

    /** True for the pre-seal form: a bare JSON array. A sealed payload is "ivHex:ctHex". */
    private fun isLegacyManagedList(stored: String): Boolean = stored.trimStart().startsWith("[")

    /** Read a managed list back, tolerating the legacy plaintext an older build wrote. A blob that
     *  will not open (a foreign or wiped Keystore key) reads as absent, exactly like the detection
     *  log's reload: best-effort, never a crash. The board keeps its own copy of the permanent
     *  ignore list, and an empty phone is deliberately not authoritative over it. */
    private fun openManagedList(stored: String): String? =
        if (isLegacyManagedList(stored)) stored
        else runCatching { gcmOpen(stored).decodeToString() }.getOrNull()

    private data class ManagedListsSnapshot(
        val ignored: List<IgnoredDevice>,
        val watched: List<WatchedDevice>,
    )

    private fun ignoredJson(items: List<IgnoredDevice>): String {
        val arr = JSONArray()
        items.forEach { item ->
            val o = JSONObject().put("mac", item.mac).put("label", item.label)
                .put("radiusMeters", item.radiusMeters)
            item.expiresAt?.let { o.put("expiresAt", it) }
            item.latitude?.let { o.put("latitude", it) }
            item.longitude?.let { o.put("longitude", it) }
            arr.put(o)
        }
        return arr.toString()
    }

    private fun watchedJson(items: List<WatchedDevice>): String {
        val arr = JSONArray()
        items.forEach { arr.put(JSONObject().put("mac", it.mac).put("label", it.label)) }
        return arr.toString()
    }

    /** Legacy migration is intentionally single-key. A combined migration before both lists were
     * decoded would durably replace the sibling with its temporary empty startup value. No UI or
     * board action depends on migration succeeding. */
    private fun migrateManagedList(key: String, json: String, expectedLegacy: String) {
        // CAS the source as well as holding managedListEdits. This protects against a synchronous
        // SharedPreferences listener re-entering the edit API on this reentrant JVM monitor.
        if (prefs.getString(key, null) != expectedLegacy) return
        val sealed = runCatching { gcmSeal(json.encodeToByteArray()) }.getOrNull() ?: return
        val ok = runCatching {
            prefs.edit().putString(key, sealed).commit() && prefs.getString(key, null) == sealed
        }.getOrDefault(false)
        if (!ok) android.util.Log.w("AcabBleManager", "could not durably migrate $key")
    }

    /** Durably store BOTH proposed lists and any destructive-clear intents in one preferences
     * transaction. The two encrypted blobs must move together: watch/ignore exclusivity crosses
     * both keys, and a process death between independent writes could otherwise restore a MAC in
     * both lists. `commit` plus exact readback is the boundary before the StateFlows or board see
     * this generation. */
    private fun persistManagedLists(
        snapshot: ManagedListsSnapshot,
        ignoreMacsChanged: Boolean,
        watchMacsChanged: Boolean,
    ): Boolean {
        val sealedIgnored = runCatching { gcmSeal(ignoredJson(snapshot.ignored).encodeToByteArray()) }
            .getOrNull() ?: return false
        val sealedWatched = runCatching { gcmSeal(watchedJson(snapshot.watched).encodeToByteArray()) }
            .getOrNull() ?: return false
        val ignoredClear = boardIgnoredMacs(snapshot.ignored).isEmpty()
        val watchedClear = snapshot.watched.isEmpty()
        val committed = runCatching {
            val editor = prefs.edit()
                .putString("ignored", sealedIgnored)
                .putString("watched", sealedWatched)
            if (ignoreMacsChanged) editor.putBoolean("ignore_clear_pending", ignoredClear)
            if (watchMacsChanged) editor.putBoolean("watch_clear_pending", watchedClear)
            editor.commit()
        }.getOrDefault(false)
        val readBack = committed &&
            prefs.getString("ignored", null) == sealedIgnored &&
            prefs.getString("watched", null) == sealedWatched &&
            (!ignoreMacsChanged ||
                prefs.getBoolean("ignore_clear_pending", !ignoredClear) == ignoredClear) &&
            (!watchMacsChanged ||
                prefs.getBoolean("watch_clear_pending", !watchedClear) == watchedClear)
        if (readBack) {
            if (ignoreMacsChanged) ignoreClearIntent.adoptDurableState(ignoredClear)
            if (watchMacsChanged) watchClearIntent.adoptDurableState(watchedClear)
        }
        if (!readBack) {
            android.util.Log.w(
                "AcabBleManager",
                "managed-list commit was not confirmed; keeping the visible and board state unchanged",
            )
        }
        return readBack
    }

    /** Commit an exact combined generation, then install and reconcile that same generation.
     * Demo edits stay preview-only and intentionally skip both persistence and board callbacks. */
    private fun commitManagedLists(
        proposedIgnored: List<IgnoredDevice>,
        proposedWatched: List<WatchedDevice>,
    ): Boolean {
        val generation = managedListEdits.currentGeneration()
        val snapshot = ManagedListsSnapshot(
            ignored = proposedIgnored.map { it.copy(mac = it.mac.lowercase()) },
            watched = proposedWatched.map { it.copy(mac = it.mac.lowercase()) },
        )
        val beforeIgnore = boardIgnoredMacs().toSet()
        val afterIgnore = boardIgnoredMacs(snapshot.ignored).toSet()
        val beforeWatch = _watched.value.mapTo(HashSet()) { it.mac }
        val afterWatch = snapshot.watched.mapTo(HashSet()) { it.mac }
        val ignoreMacsChanged = beforeIgnore != afterIgnore
        val watchMacsChanged = beforeWatch != afterWatch

        when (managedListEditMode(_demoMode.value, managedListsReady)) {
            ManagedListEditMode.PREVIEW_ONLY -> {
                installManagedLists(snapshot.ignored, snapshot.watched)
                return true
            }
            ManagedListEditMode.LOADING_FAIL_CLOSED -> return false
            ManagedListEditMode.DURABLE -> Unit
        }
        // Startup and exit-demo loads decode on IO. Until their paired install lands, the mode
        // above leaves UI and board unchanged instead of committing a temporary/preview sibling.
        return applyDurableManagedListEdit(
            candidate = snapshot,
            persist = { persistManagedLists(it, ignoreMacsChanged, watchMacsChanged) },
            isStillCurrent = { managedListEdits.isCurrent(generation) },
            install = {
                installManagedLists(it.ignored, it.watched)
            },
            reconcileBoard = {
                if (ignoreMacsChanged) {
                    sendIgnoreList(intentionalClear = afterIgnore.isEmpty())
                }
                if (watchMacsChanged) sendWatchList()
            },
        )
    }

    /** Push permanent ignored MACs to the board. Empty is destructive and therefore allowed only
     * for an explicit local deletion (or its persisted retry), never merely because this phone has
     * no permanent rows.
     *
     * [userEdit] false is the STATUS reconciler spending its bounded re-push budget; see
     * [sendWatchList]. */
    private fun sendIgnoreList(intentionalClear: Boolean = false, userEdit: Boolean = true) {
        if (!managedListPersistenceAllowed(_demoMode.value)) return
        if (!managedListsReady) return
        if (userEdit) ignorePushAttempts = 0
        val permanent = boardIgnoredMacs()
        if (permanent.isEmpty()) {
            if (!intentionalClear && !listClearPending("ignore")) return
        }
        sendMacList("ignore", permanent)
    }

    /** Push a MAC list ("ignore" or "watch") to the board, split into <=MAC_CHUNK-per-write
     *  chunks so a long list stays well under the 512 B ATT write cap. A single write of a full
     *  >24-entry list is one frame over the cap, rejected before the firmware sees it, so the
     *  board's count never converges and every status notify re-pushes it - an endless failed
     *  loop. Chunking fixes that.
     *
     *  Protocol (backward compatible): every chunk but the last carries "more":true and the board
     *  STAGES it (appends without committing); the final chunk omits "more" and the board commits
     *  the whole staged list to the scanner. A list of <=MAC_CHUNK is a single write with no
     *  "more", byte-for-byte what we sent before. An empty list is one committing write carrying
     *  "clr":true, which is what marks it a DELIBERATE clear. The firmware refuses an empty
     *  commit only when it is the peer's FIRST list commit of the connection and carries no
     *  "clr" (a later empty commit from a peer that already pushed a non-empty list is accepted;
     *  see the empty-commit rule in acab_ble_service.cpp). The flag is what lets a clear made
     *  while DISCONNECTED survive to the next connect, where resyncListsOnConnect's empty push
     *  IS the first commit.
     *  Each writeConfig enqueues on the serialized GATT queue, so the chunks land in order. */
    private fun sendMacList(key: String, macs: List<String>) {
        // Not merely a live client: the CONFIG characteristic must be DISCOVERED. `gatt` is
        // non-null throughout CONNECTING and BONDING, and for the entire indefinite autoConnect
        // pending-client window, and in all of those charOf() returns null and writeConfig
        // silently DISCARDS the write. Retiring the persisted clear flag off a write no board ever
        // took loses the user's unstar for good: resyncListsOnConnect then sees an empty list with
        // no pending clear and pushes nothing, and the status reconciler only fires when the board
        // is BEHIND us, never ahead. Matches iOS canWriteConfig.
        val g = gatt ?: return
        if (charOf(g, AcabProfile.CONFIG) == null) return
        if (macs.size <= MAC_CHUNK) {
            val arr = JSONArray(); macs.forEach { arr.put(it) }
            val obj = JSONObject().put(key, arr)
            if (macs.isEmpty()) obj.put("clr", true)
            // Keep an empty-list intent pending until a later STATUS count reports zero. A GATT
            // enqueue is not delivery: the link can disappear before this write gets a response.
            writeConfig(obj)   // single write, no "more" (commits)
            return
        }
        val chunks = macs.chunked(MAC_CHUNK)
        chunks.forEachIndexed { i, chunk ->
            val arr = JSONArray(); chunk.forEach { arr.put(it) }
            val obj = JSONObject().put(key, arr)
            if (i < chunks.lastIndex) obj.put("more", true)   // stage; the final chunk (no "more") commits
            writeConfig(obj)
        }
    }

    // ---- demo mode (explore the UI with sample data, no board) ----

    /** Seed sample detections so the whole UI works without a board.
     *  Behind the connect screen's "Continue without pairing" button. */
    fun seedDemoData() {
        // Demo replaces the scan screen with a synthetic READY session. Retire the scanner first,
        // including its timeout and delayed retry generation, so LOW_LATENCY work cannot leak.
        if (shouldStopScanBeforeDemo(_state.value)) stopScan()
        _demoMode.value = true
        _deviceName.value = "beacon"
        // Mirror the iOS sample payload: the real board emits body-cam state under "axon" (the
        // key both apps read), and total matches the 6 sample detections placeDemoDetections seeds
        // (one per category the Status strip shows), so iOS and Android report the same demo total.
        _status.value = DeviceStatus.fromJson(JSONObject(
            // "moto" is present so the tour shows the Motorola sub-toggle. Omitting it would make
            // the demo board look like pre-split firmware and hide the control the tour exists to
            // introduce. "axon":true so the parent category is on and the sub-row is not dimmed.
            """{"fw":"beacon board 2.0.7","up":4920,"total":6,"ble":true,"wifi":true,"axon":true,"moto":true,"tracker":true,"glasses":true,"ncam":true,"buzzer":true,"vol":70,"gps":true,"bat":82}"""))
        _state.value = ConnState.READY
        syncLocationOwnership()
        // placeDemoDetections clears + repopulates the same maps the async startup reload fills, so
        // wait for that reload before seeding, to avoid a concurrent mutation of the non-synchronized
        // maps. The join is instant in practice; the READY flip stays synchronous above so the UI
        // still lands on the dashboard immediately.
        scope.launch {
            persistLoadJob?.join()
            withContext(Dispatchers.Main) {
                if (!_demoMode.value) return@withContext   // user left demo while we waited
                placeDemoDetections(lastLat, lastLon)      // cluster the sample hits around the user
                demoNeedsRelocate = (lastLat == null)      // no fix yet? re-place once one arrives
            }
        }
    }

    /** Place (or re-place) the demo detections around (baseLat,baseLon) = the user, keeping
     *  their relative spread. Falls back to the canned San Francisco coords when there's no fix. */
    private fun placeDemoDetections(baseLat: Double?, baseLon: Double?) {
        val sfLat = 37.7799; val sfLon = -122.4188    // coords the samples were authored at
        // One sample per category the Status strip, Log tiles, and Map chips all show: ALPR,
        // DRONE, BODY CAM, TRACKER, GLASSES, and Network camera. Exactly six, so the demo status
        // "total" matches the seed count and lines up with the iOS tour's seed set.
        val samples = listOf(
            """{"t":1,"s":1,"meth":1,"c":95,"mac":"AC:AB:00:7F:2A:10","rssi":-54,"name":"FlockSafety","lat":37.7799,"lon":-122.4202,"n":12,"new":true}""",
            """{"t":4,"s":2,"meth":7,"c":99,"mac":"DA:7E:E0:44:21:09","rssi":-61,"id":"1581F4FED0A2B7","lat":37.7816,"lon":-122.4169,"plat":37.7821,"plon":-122.4151,"alt":84,"n":1,"new":true}""",
            """{"t":3,"s":0,"meth":3,"c":45,"mac":"A0:0F:11:BA:7C:33","rssi":-88,"n":1}""",
            """{"t":5,"s":0,"meth":3,"c":85,"mac":"4C:00:12:19:AA:BB","rssi":-72,"det":"Apple Find My (offline)","cid":76,"lat":37.7791,"lon":-122.4196,"n":3}""",
            // VERBATIM from glasses_signatures.h. These seeds must carry the firmware's real
            // strings, not a prettified paraphrase: `maker` parses them, so a paraphrase would
            // demo the OLD behaviour (a row reading "Recording glasses") while real hardware
            // shows the new one. This one resolves to "Meta".
            """{"t":9,"s":0,"meth":3,"c":60,"mac":"5A:2E:7C:41:08:D3","rssi":-69,"det":"Meta: possible recording glasses or Quest","cid":1422,"lat":37.7804,"lon":-122.4181,"n":2,"new":true}""",
            // Branded IP-camera OUI seen on the host WiFi (matched by source MAC), so the NETCAM
            // tile and NETWORK CAM map chip both show up on the tour. The MAC is a real Hikvision
            // block, so this row demonstrates the maker-led title end to end. Wire values are the
            // firmware's own: s=1 is SRC_WIFI (netcamClassifyWiFi never emits a BLE source) and
            // c=65 is NETCAM_OUI_CONFIDENCE, the registry tier a validated=0 block lands on; the
            // twin row in iOS BLEManager.seedDemoData carries the same values.
            """{"t":10,"s":1,"meth":1,"c":65,"mac":"44:19:B6:22:0A:5C","rssi":-70,"det":"Hikvision on wifi","lat":37.7788,"lon":-122.4183,"n":2,"new":true}""",
        )
        val now = System.currentTimeMillis()
        val wobble = listOf(-6, -3, -7, -1, -4, 2, -2, 1, -3, 0, -1, 1, -2, 0)
        // Guard the store + side-map mutations with storeLock (matches resetInMemoryLog): the widget
        // feed and publish pump iterate these under the lock on other threads.
        synchronized(storeLock) {
            // Same one list as resetInMemoryLog: the demo replaces the whole store, so any real
            // row's pin, closest-approach RSSI or breadcrumbs left in a side map would outlive
            // the row it belonged to.
            for (m in perDeviceMaps) m.clear()
            for (s in samples) {
                val o = JSONObject(s)
                if (baseLat != null && baseLon != null && o.has("lat") && o.has("lon")) {
                    o.put("lat", baseLat + (o.getDouble("lat") - sfLat))   // keep the hit's relative offset, re-based on the user
                    o.put("lon", baseLon + (o.getDouble("lon") - sfLon))
                    if (o.has("plat")) o.put("plat", baseLat + (o.getDouble("plat") - sfLat))
                    if (o.has("plon")) o.put("plon", baseLon + (o.getDouble("plon") - sfLon))
                }
                val d = Detection.fromJson(o)
                store[d.id] = d
                firstSeenAt[d.id] = now; lastSeenAt[d.id] = now
                rssiHistory[d.id] = wobble.map { (d.rssi + it).coerceIn(-99, -30) }.toMutableList()
            }
        }
        publishNow()
    }

    /** Drop out of demo mode, back to the connect screen. */
    fun exitDemo() {
        // Close the real persistence boundary before lowering demoMode. A preview edit that wins
        // before this edge stays nonpersistent; one after it fails closed until loadManagedLists
        // installs the real pair and marks it ready.
        val managedListLoadToken = managedListEdits.serialized { _ ->
            managedListsReady = false
            managedListLoadGate.beginLoad()
        }
        _demoMode.value = false
        // Memory only. The board being off is what puts a user on the connect screen, which is
        // where "Take the tour" is offered, so tapping the tour and leaving it used to delete a
        // real drive's log with no prompt and no undo. Demo rows do have to LEAVE the store here
        // though, or the next checkpoint seals fabricated detections into the evidence file.
        resetInMemoryLog()
        _status.value = null
        _deviceName.value = null
        _state.value = ConnState.DISCONNECTED
        syncLocationOwnership()
        // Re-read the real lists and the real log the demo was covering up. Published as
        // persistLoadJob, exactly like the startup load, so a re-entered demo or an instant connect
        // joins it instead of racing the reload as it repopulates the non-synchronized maps.
        //
        // Managed-list edits in sample data are previews. Their persistence and board-sync paths
        // are gated while demoMode is true, so the real lists have to come back off disk before
        // canned sample MACs or preview renames can survive this session or reach the next
        // connected board. Lists before detections, same as the startup load, and off the main
        // thread for the same reason (each open is Keystore IPC plus an AES-GCM decrypt). That
        // leaves a brief window where preview lists remain visible with demoMode already false;
        // managedListsReady is deliberately false across that window, so any Settings action
        // fails closed and connect() joins this job before a board hears anything.
        persistLoadJob = scope.launch(Dispatchers.IO) {
            if (loadManagedLists(managedListLoadToken)) pruneExpiredMutes(publish = false)
            loadPersistedDetections()
        }
    }

    // ---- the long-lived buffer key (32 random bytes, generated once) ----
    //
    // The board needs the raw 32 bytes as hex to decrypt the records it buffered while we
    // were away, so we can't hand it an AndroidKeyStore handle directly - those don't
    // export their key material. Instead we generate 32 random bytes once, wrap them with
    // a non-exportable AES-GCM key held in the AndroidKeyStore, and persist only the
    // wrapped blob. The plaintext key never sits in SharedPreferences.

    private fun keyHex(): String? =
        loadOrCreateKey()?.joinToString("") { "%02x".format(it) }

    /** Serializes the read/create transaction. `SharedPreferences.apply()` is intentionally not
     * used: returning before its async disk write lets the board receive a key which disappears on
     * process death. A failed unwrap also aborts rather than rotating the only key for old rows. */
    private val bufferKeyLock = Any()
    private fun loadOrCreateKey(): ByteArray? = synchronized(bufferKeyLock) {
        resolveDurableBufferKey(
            stored = prefs.getString("bufKey", null),
            unwrap = { runCatching { unwrapKey(it) }.getOrNull() },
            generate = {
                runCatching {
                    ByteArray(DURABLE_BUFFER_KEY_BYTES).also {
                        java.security.SecureRandom().nextBytes(it)
                    }
                }.getOrNull()
            },
            wrap = { runCatching { wrapKey(it) }.getOrNull() },
            persist = { sealed ->
                // commit() is synchronous and reports the disk result. Read back the exact blob
                // before exposing its plaintext counterpart to the BLE handshake.
                prefs.edit().putString("bufKey", sealed).commit() &&
                    prefs.getString("bufKey", null) == sealed
            },
        )
    }

    /** AES-GCM-encrypt the raw key with the Keystore wrapping key; store iv:ciphertext hex. */
    private fun wrapKey(raw: ByteArray): String {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, wrappingKey())
        val ct = cipher.doFinal(raw)
        return cipher.iv.joinToString("") { "%02x".format(it) } + ":" +
            ct.joinToString("") { "%02x".format(it) }
    }

    private fun unwrapKey(stored: String): ByteArray {
        val (ivHex, ctHex) = stored.split(":", limit = 2)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE, wrappingKey(),
            javax.crypto.spec.GCMParameterSpec(128, ivHex.hexToBytes()),
        )
        return cipher.doFinal(ctHex.hexToBytes())
    }

    /** AES-GCM-seal arbitrary bytes with the Keystore wrapping key; returns iv:ciphertext hex.
     *  Same construction as wrapKey, exposed for the at-rest detection log. */
    private fun gcmSeal(plain: ByteArray): String {
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(javax.crypto.Cipher.ENCRYPT_MODE, wrappingKey())
        val ct = cipher.doFinal(plain)
        return cipher.iv.joinToString("") { "%02x".format(it) } + ":" +
            ct.joinToString("") { "%02x".format(it) }
    }

    /** Reverse of gcmSeal; throws on a tampered/foreign blob (callers treat that as "start fresh"). */
    private fun gcmOpen(sealed: String): ByteArray {
        val (ivHex, ctHex) = sealed.split(":", limit = 2)
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            javax.crypto.Cipher.DECRYPT_MODE, wrappingKey(),
            javax.crypto.spec.GCMParameterSpec(128, ivHex.hexToBytes()),
        )
        return cipher.doFinal(ctHex.hexToBytes())
    }

    /** The non-exportable AES key in the AndroidKeyStore that wraps the buffer key. */
    private fun wrappingKey(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getEntry(KEY_ALIAS, null) as? KeyStore.SecretKeyEntry)?.let { return it.secretKey }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    // ---- local persistence of filed detections (survives an app restart) ----

    private fun detectionStore(): File = File(context.filesDir, "detections.json")
    private fun detectionTempStore(): File = File(context.filesDir, "detections.json.tmp")

    /** Delete both the live atomic target and a staging file left by an interrupted checkpoint.
     *  Caller holds [persistMutex], so no rename can cross the confirmed-absence check. */
    private fun deletePersistedDetectionFilesLocked(): Boolean =
        performConfirmedPersistedDetectionDeletion(
            fileExists = { detectionStore().exists() || detectionTempStore().exists() },
            remove = {
                for (file in listOf(detectionStore(), detectionTempStore())) {
                    if (file.exists() && !file.delete()) error("persisted detection delete failed")
                }
            },
        )

    /** Fallback boundary when SharedPreferences cannot durably arm the write-ahead tombstone. */
    private fun deletePersistedDetectionsSynchronously(): Boolean = runCatching {
        runBlocking(Dispatchers.IO) {
            persistMutex.withLock { deletePersistedDetectionFilesLocked() }
        }
    }.getOrDefault(false)

    /** The initiating clear owns exactly one visible reset. Serialize it with file writers and
     * background retries; for the synchronous-deletion fallback, retire before releasing these
     * locks. The durable-tombstone path leaves retirement to the subsequent delete retry. */
    private fun completeInitiatingPersistedDetectionClear(
        retireTombstone: Boolean,
    ): PersistedDetectionClearCompletion = runCatching {
        // clearLog is a Main-thread UI action. Keep the visible StateFlow/notifier reset on that
        // caller while runBlocking only waits for an older IO checkpoint to release the mutex.
        runBlocking {
            persistMutex.withLock {
                synchronized(persistedDetectionClearStateLock) {
                    if (!persistedDetectionClearInitiatorInProgress) {
                        return@synchronized PersistedDetectionClearCompletion(false, false)
                    }
                    resetInMemoryLog(invalidatePersistedSnapshots = true)
                    pendingClearNeedsMemoryReset.set(false)
                    persistedDetectionClearInitiatorInProgress = false
                    val retired = if (!retireTombstone) {
                        false
                    } else if (persistedDetectionClearMayRetire(
                            deletionConfirmed = true,
                            visibleResetPending = pendingClearNeedsMemoryReset.get(),
                            initiatingResetInProgress = persistedDetectionClearInitiatorInProgress,
                        )) {
                        persistedDetectionClearTombstone.retire()
                    } else {
                        false
                    }
                    PersistedDetectionClearCompletion(true, retired)
                }
            }
        }
    }.getOrElse {
        // Preserve the reset-pending barrier for a generic retry. If the tombstone was durable it
        // survives process death; if only the in-process mirror exists, no visible reset was
        // reported as successful and the retained file remains authoritative.
        synchronized(persistedDetectionClearStateLock) {
            persistedDetectionClearInitiatorInProgress = false
        }
        PersistedDetectionClearCompletion(false, false)
    }

    /** Finish a pending Clear before any load or checkpoint may resume. Tombstone retirement is
     *  allowed only after absence was checked while holding the same mutex as atomic writes. */
    private suspend fun retryPendingDetectionClear(
        checkpointCurrentStoreOnSuccess: Boolean = false,
    ): Boolean {
        var completedClear = false
        val resolved = persistMutex.withLock {
            // Claim this transaction under the same flag as the tap-side initiator. That keeps a
            // new tap/second retry from becoming an owner while this coroutine briefly dispatches
            // the visible reset to Main. persistMutex remains held, so no file writer can cross
            // delete -> reset -> retirement either.
            val pendingAtClaim = synchronized(persistedDetectionClearStateLock) {
                if (!persistedDetectionClearRetryMayOwnCompletion(
                        persistedDetectionClearInitiatorInProgress,
                    )) return@withLock false
                val pending = persistedDetectionClearTombstone.isPending
                if (!pending && !pendingClearNeedsMemoryReset.get()) return@withLock true
                persistedDetectionClearInitiatorInProgress = true
                pending
            }
            try {
                if (pendingAtClaim && !deletePersistedDetectionFilesLocked()) return@withLock false

                if (pendingClearNeedsMemoryReset.get()) {
                    // Demo rows are memory-only and must not disappear underneath the tour. Keep
                    // the tombstone/owner armed; exitDemo retries after it has reset the demo.
                    if (_demoMode.value) return@withLock false
                    withContext(Dispatchers.Main.immediate) {
                        if (_demoMode.value) return@withContext
                        synchronized(persistedDetectionClearStateLock) {
                            if (pendingClearNeedsMemoryReset.get()) {
                                resetInMemoryLog(invalidatePersistedSnapshots = true)
                                pendingClearNeedsMemoryReset.set(false)
                                completedClear = true
                            }
                        }
                    }
                    if (pendingClearNeedsMemoryReset.get()) return@withLock false
                }

                synchronized(persistedDetectionClearStateLock) {
                    // Lower the ownership bit only at the retirement decision. The mutex is still
                    // held, so a new clear can arm immediately afterward but no checkpoint can
                    // write between this transaction's reset and confirmed retirement.
                    persistedDetectionClearInitiatorInProgress = false
                    if (!pendingAtClaim) return@synchronized true
                    val retired = if (persistedDetectionClearMayRetire(
                            deletionConfirmed = true,
                            visibleResetPending = pendingClearNeedsMemoryReset.get(),
                            initiatingResetInProgress = persistedDetectionClearInitiatorInProgress,
                        )) persistedDetectionClearTombstone.retire()
                    else false
                    if (retired) completedClear = true
                    retired
                }
            } finally {
                synchronized(persistedDetectionClearStateLock) {
                    persistedDetectionClearInitiatorInProgress = false
                }
            }
        }
        if (!resolved) return false

        // Rows received after the visible clear were intentionally blocked while the tombstone
        // was live. Once deletion and retirement are both confirmed, checkpoint those new rows.
        if (completedClear && checkpointCurrentStoreOnSuccess && !_demoMode.value &&
            synchronized(storeLock) { store.isNotEmpty() }) {
            persistDetections()
        }
        return true
    }

    // ---- replay-cursor persistence (write-ahead; mirrors iOS checkpointHistory) ----
    // The prefs mirror of the persisted "lastSeq". The in-memory lastSeq advances per record
    // (the contiguity test needs it), but the PERSISTED cursor may only advance once the store
    // write holding those records has landed: a cursor written ahead of the store told the
    // board the records were safe while they existed nowhere but this process's RAM, so a kill
    // mid-drain lost them from both ends - the board never re-sends an acked seq. Guarded by
    // cursorLock; the two deliberate rewinds (hist-begin rebase, buffer wipe) go DOWN through
    // the same helper so the mirror can't drift from prefs.
    private val cursorLock = Any()
    private var lastSeqPersisted: Long = prefs.getLong("lastSeq", 0L)
    private var lastLogGenerationPersisted: Long = prefs.getLong("logGeneration", 0L)
    // Bumped (under cursorLock) by every deliberate rewind, so a write-ahead completion whose
    // checkpoint predates the rewind can't push the cursor back UP past it - a stale-high
    // cursor would skip every post-wipe record, the exact bug clearBufferLog exists to prevent.
    // Same idea as scanGen/otaSessionId.
    private var cursorGen = 0
    // True while a replay checkpoint's seal + write is still in flight, so the every-200
    // mid-drain checkpoints skip rather than queue a pile of whole-store re-seals (each launch
    // holds its own snapshot). onHistEnd's final checkpoint is the one that has to be complete.
    @Volatile private var checkpointInFlight = false

    /** Persist the replay generation+cursor tuple. Forward advances (the default) never move it
     *  down within one generation and a completion carrying an obsolete [cursorEpoch] is dropped
     *  once a rewind supersedes it. [forward] = false is reserved for deliberate rewinds. */
    private fun invalidateCursorCheckpoints() {
        synchronized(cursorLock) { cursorGen++ }
    }

    private fun persistCursor(
        cursor: Long,
        logGeneration: Long = activeLogGeneration,
        forward: Boolean = true,
        cursorEpoch: Int = -1,
        finalizeGeneration: Boolean = false,
    ) {
        synchronized(cursorLock) {
            if (cursorEpoch >= 0 && cursorEpoch != cursorGen) return
            val generationChanged = logGeneration != lastLogGenerationPersisted
            if (generationChanged && forward && (!finalizeGeneration || logGeneration == 0L)) return
            if (forward) {
                if (!generationChanged && cursor <= lastSeqPersisted) return
            } else if (!generationChanged) {
                cursorGen++
            }
            if (generationChanged) cursorGen++
            lastSeqPersisted = cursor
            lastLogGenerationPersisted = logGeneration
            prefs.edit()
                .putLong("lastSeq", cursor)
                .putLong("logGeneration", logGeneration)
                .apply()
        }
    }

    /** Write-ahead checkpoint for the replay path: persist the store, THEN advance the
     *  persisted resume cursor, and only if the write actually landed. The cursor (and the
     *  rewind gen) are captured before the snapshot, so the advance can never run ahead of the
     *  rows the write covers nor undo a wipe that landed while the write was in flight; on
     *  failure the cursor stays put, the board re-sends, and filing is idempotent by id, so a
     *  re-drain costs a little radio and nothing else. */
    private fun checkpointHistory(finalizeGeneration: Boolean = false) {
        val cursor = lastSeq
        val logGeneration = activeLogGeneration
        val cursorEpoch = synchronized(cursorLock) { cursorGen }
        checkpointInFlight = true
        persistDetections { saved ->
            checkpointInFlight = false
            if (saved) persistCursor(
                cursor,
                logGeneration = logGeneration,
                cursorEpoch = cursorEpoch,
                finalizeGeneration = finalizeGeneration,
            )
        }
    }

    /** Throttled checkpoint of the live session to disk.
     *
     *  Detections filed while we're connected live in RAM and nowhere else: the board only
     *  buffers while the app is AWAY (det_log.cpp early-returns on a connected client), so a
     *  process death mid-drive used to take the entire session with it. Write the store out as
     *  we go, but not per record - persistDetections re-serializes and re-seals all ~5000 rows,
     *  which an airport-density Desert-mode flood would turn into a continuous re-encrypt of the
     *  whole log. Throttling on TIME rather than on a record count is what keeps both ends
     *  honest: a flood costs at most one write per interval, and a quiet drive with four hits an
     *  hour still lands on disk within the interval instead of waiting for a 200th record that
     *  never comes. The exposure is the last CHECKPOINT_MIN_MS of a session, and only if the
     *  process dies without ever reaching cleanup().
     *
     *  [force] is for the end of a session (drop, radio off), where the throttle doesn't apply. */
    private fun checkpointDetections(force: Boolean = false) {
        // Demo rows are fabricated. They must never reach the evidence file, and cleanup() can
        // fire during the tour (radio off), so the guard lives here rather than at the call sites.
        if (_demoMode.value) return
        val now = System.currentTimeMillis()
        if (!force && now - lastCheckpointAt < CHECKPOINT_MIN_MS) return
        lastCheckpointAt = now
        persistDetections()
    }

    // Orders persistDetections snapshots: taken (with the snapshot) under storeLock, checked
    // under persistMutex, so an older snapshot that lost the dispatch race can never clobber a
    // newer write. The old build-under-storeLock version got this ordering from the lock itself.
    private val persistSnapSeq = AtomicLong(0L)
    private var persistSeqWritten = 0L   // guarded by persistMutex

    /** Snapshot the current store to disk as the same compact JSON the wire uses, tagged
     *  with the firstSeen pseudo/real timestamp so the order is restored on reload. The log
     *  carries MACs + capture GPS + RID, so it is sealed at rest with the Keystore key (AND-SEC-1).
     *
     *  Only a cheap reference snapshot is taken on the CALLING thread under storeLock
     *  (Detection is immutable); the JSON build and its toString() - tens of milliseconds at
     *  STORE_CAP rows, and the radio-off caller is the MAIN thread - run with the seal + file
     *  write on IO. Iterating the maps from the IO thread instead would race the next ingest,
     *  which the lock cannot help with once the caller has returned.
     *
     *  [completion] runs (on the IO worker) with whether the sealed write actually LANDED;
     *  anything that commits state the file is supposed to back - the replay cursor - must wait
     *  for it rather than assume success (see checkpointHistory). Mirrors iOS. */
    private fun persistDetections(completion: ((Boolean) -> Unit)? = null) {
        // Demo rows are fabricated and must never reach the evidence file. checkpointDetections
        // already guards its own callers; this covers the direct replay-path calls too, and a
        // refusal is not a landed write.
        if (_demoMode.value) { completion?.invoke(false); return }
        val snapshot: List<Triple<Detection, Long?, HistTime?>>
        val seq: Long
        val snapshotGeneration: Long
        synchronized(storeLock) {
            snapshot = store.values.map { Triple(it, firstSeenAt[it.id], histTime[it.id]) }
            seq = persistSnapSeq.incrementAndGet()
            snapshotGeneration = persistedDetectionWriteGeneration.get()
        }
        scope.launch(Dispatchers.IO) {
            val ok = persistMutex.withLock {
                if (!persistedDetectionSnapshotMayWrite(
                        snapshotGeneration,
                        persistedDetectionWriteGeneration.get(),
                        persistedDetectionClearTombstone.isPending,
                    )) return@withLock false
                // Never trade a real log for an empty one. A checkpoint that lands while the store
                // is legitimately empty (before startup reload, just after ignore-all) would
                // otherwise destroy the retained file. Only confirmed Clear empties it.
                if (snapshot.isEmpty()) {
                    return@withLock !detectionStore().exists() && !detectionTempStore().exists()
                }
                // A newer snapshot already wrote: its rows are a superset of this one's (the
                // store only sheds rows by STORE_CAP eviction or a deliberate clear), so this
                // one's records ARE on disk. Superseded counts as saved.
                if (seq < persistSeqWritten) return@withLock true
                val text = runCatching {
                    val arr = JSONArray()
                    for ((d, fs, ht) in snapshot) {
                        val o = detectionToJson(d)
                        fs?.let { o.put("_fs", it) }
                        // Time quality is derived from the whole batch a record arrived in, and
                        // that batch is gone by the next launch, so it has to ride along with the
                        // row. Without it a bracketed record reloads as "time unknown" and the
                        // work of bounding it is quietly lost.
                        ht?.let { o.put("_sk", it.sortKey); basisToJson(it.basis)?.let { b -> o.put("_tq", b) } }
                        arr.put(o)
                    }
                    arr.toString()
                }.getOrNull() ?: return@withLock false
                // The high-water mark advances only when the write LANDS, so a failed newer
                // write can't make an older queued snapshot skip itself and leave the file stale.
                val wrote = synchronized(persistedDetectionClearStateLock) {
                    // Re-prove the authorization at the actual file boundary. Clear changes the
                    // generation and arms its tombstone under this same lock, so a checkpoint is
                    // wholly before that transaction (and will be deleted) or wholly after it.
                    if (!persistedDetectionSnapshotMayWrite(
                            snapshotGeneration,
                            persistedDetectionWriteGeneration.get(),
                            persistedDetectionClearTombstone.isPending,
                        )) {
                        false
                    } else runCatching {
                        // Stage a sibling, then rename it in. writeText() TRUNCATES the live file
                        // and then streams into it, so a kill mid-write must not truncate the only
                        // retained copy. rename(2) within one directory is atomic.
                        val f = detectionStore()
                        val tmp = detectionTempStore()
                        tmp.writeText(gcmSeal(text.encodeToByteArray()))
                        if (!tmp.renameTo(f)) { tmp.delete(); error("detections rename failed") }
                    }.isSuccess
                }
                if (wrote) persistSeqWritten = seq
                wrote
            }
            completion?.invoke(ok)
        }
    }

    /** Reload persisted detections on startup so replayed history isn't lost on a restart. */
    private suspend fun loadPersistedDetections() {
        // A process may have died after the Clear intent committed but before deletion. Delete and
        // durably retire that intent first; if either step fails, preserve the file and load none
        // of it. Foreground/exit-demo/next launch retry the same idempotent transaction.
        if (!retryPendingDetectionClear() || persistedDetectionClearTombstone.isPending) return
        val loadToken = persistedDetectionLoadGate.beginLoad()
        val stored = runCatching { detectionStore().readText() }.getOrNull()?.trim() ?: return
        // sealed blobs are "ivHex:ctHex"; an old build wrote a plaintext JSON array (starts with '[').
        // decrypt the sealed form, tolerate the legacy plaintext, and on any decrypt failure just
        // start fresh (best-effort, never crash).
        val legacyPlaintext = stored.startsWith("[")
        val raw = if (legacyPlaintext) stored
                  else runCatching { gcmOpen(stored).decodeToString() }.getOrNull() ?: return
        runCatching {
            val arr = JSONArray(raw)
            // PER-ROW tolerant, matching iOS. One malformed row must never cost the user their
            // whole history: parse each entry independently and keep every row that survives.
            // The outer runCatching only guards the top-level JSONArray parse now.
            // Order on the SORT KEY, not the stamp. A bracketed or unbounded record carries the
            // seq pseudo-stamp, which sits near 2001, so sorting on "_fs" buries every buffered
            // row the board couldn't date under the whole real log, however recently it was
            // captured. "_sk" is where the row actually belongs; rows written before it existed
            // fall back to the stamp and reload exactly as they used to.
            val entries = (0 until arr.length())
                .mapNotNull { runCatching { arr.getJSONObject(it) }.getOrNull() }
                .sortedBy { it.optLong("_sk", it.optLong("_fs", 0L)) }   // oldest first, so asReversed() puts newest on top
            var skipped = 0
            var accepted = false
            synchronized(storeLock) {
                // Clear invalidates the token before establishing its durable boundary. If this
                // decode raced that tap, applying even one row would resurrect the cleared view.
                if (persistedDetectionLoadGate.accepts(loadToken) &&
                    !persistedDetectionClearTombstone.isPending) {
                    accepted = true
                }
                if (accepted) for (o in entries) {
                    // fromStoredJson, not fromJson: a log written by v1.7 can still hold the
                    // retired t=6 type, which migrates to BODY_CAM on the way in.
                    val d = runCatching { Detection.fromStoredJson(o) }.getOrNull()
                    if (d == null) { skipped++; continue }
                    val fs = o.optLong("_fs", System.currentTimeMillis())
                    firstSeenAt[d.id] = fs
                    lastSeenAt[d.id] = fs
                    rssiHistory.getOrPut(d.id) { mutableListOf() }.add(d.rssi)
                    store[d.id] = d
                    // A row written before "_tq" existed has no recorded basis, and falling through
                    // to timeBasis()'s Exact default would label a buffered record as a live clock
                    // reading, which is the one claim this whole model exists to prevent. But only
                    // a row holding a REAL reconstructed instant may be called Reconstructed: the
                    // approx rows of the same era carry nothing but the seq-derived pseudo stamp
                    // (the ~2001 band isApproxTime screens for), and labelling THAT Reconstructed
                    // exported a confident fabricated 2001 date - the Reconstructed CSV branch
                    // runs before the approx blanking one - into the file people hand over as
                    // evidence. Those degrade to Unknown, which every renderer and the CSV
                    // already blank correctly. For the real instants, precisionFor widens the
                    // error bar by age: an old row gets a deliberately wide bar rather than a
                    // fabricated tight one. Live rows are unaffected, they are not offline.
                    val basis = basisFromJson(o) ?: when {
                        d.offline && !isApproxTime(fs) -> TimeBasis.Reconstructed(fs, precisionFor(fs))
                        d.offline -> TimeBasis.Unknown
                        else -> null
                    }
                    basis?.let { basis ->
                        histTime[d.id] = HistTime(basis, o.optLong("_sk", fs))
                        // Rebuild the boot bounds off the reloaded log as well, so a drain in THIS
                        // session can bracket against boots anchored in an earlier one.
                        if (basis is TimeBasis.Reconstructed && d.boot > 0L) {
                            val sec = basis.atMs / 1000L
                            bootMinAt[d.boot] = minOf(bootMinAt[d.boot] ?: sec, sec)
                            bootMaxAt[d.boot] = maxOf(bootMaxAt[d.boot] ?: sec, sec)
                        }
                    }
                }
            }
            // Count only, never row contents: this is a detection log and the app is the only
            // place live detections are ever recorded. Fully-qualified to match the one other
            // log call in the module (AcabLinkService); this codebase deliberately barely logs.
            if (!accepted) return@runCatching
            if (skipped > 0) android.util.Log.w(
                "AcabBleManager", "persisted log: skipped $skipped unreadable row(s), kept ${entries.size - skipped}")
            publishNow()
            // migrate a legacy plaintext file to the sealed form so the cleartext copy is overwritten.
            if (legacyPlaintext) runCatching { persistDetections() }
        }
    }

    /** Rebuild the compact wire JSON for a filed detection (enough to reload it). */
    private fun detectionToJson(d: Detection): JSONObject = JSONObject().apply {
        put("t", d.type.raw); put("s", d.source); put("meth", d.method); put("c", d.confidence)
        put("mac", d.mac); put("rssi", d.rssi); put("n", d.count)
        d.name?.let { put("name", it) }
        d.rid?.let { put("id", it) }
        d.detail?.let { put("det", it) }
        d.companyId?.let { put("cid", it) }
        d.lat?.let { put("lat", it) }
        d.lon?.let { put("lon", it) }
        d.pilotLat?.let { put("plat", it) }
        d.pilotLon?.let { put("plon", it) }
        d.altitude?.let { put("alt", it) }
        // The rest of the drone telemetry the board delivered. Dropping these left a reloaded
        // drone dossier with speed/heading/AGL/pilot-alt/status blank for data we already had.
        d.speedH?.let { put("spd", it) }
        d.speedV?.let { put("vspd", it) }
        d.heading?.let { put("hdg", it) }
        d.heightAGL?.let { put("hgt", it) }
        d.pilotAlt?.let { put("palt", it) }
        d.ridStatus?.let { put("sta", it) }
        // Fix age, or a coordinate the board stamped from a two-hour-old fix reloads with no "as
        // of" qualifier at all (locationAgeText needs gage) and reads as a fix taken on the spot.
        d.gpsAgeSec?.let { put("gage", it) }
        // approx says the record has no real capture time, only the synthetic seq-derived sort key
        // in _fs. Without the flag the CSV stops blanking the column and exports every buffered
        // record as detected_at 2001-09-09, a confident fabricated timestamp in a file people hand
        // to other people as evidence. _fs round-trips the ordering key, so seq/at stay unpersisted.
        if (d.approx) put("approx", true)
        // Persist the offline-record flag so a reloaded black-box record keeps its "OFFLINE" chip.
        if (d.offline) put("offline", true)
        // Which boot session captured the record, and how far into it. boot is what the reloaded
        // log rebuilds its per-boot anchor bounds from, so a later drain can still bracket against
        // boots this session anchored; ms is the capture's place within its own boot.
        if (d.boot > 0L) put("boot", d.boot)
        if (d.ms > 0L) put("ms", d.ms)
    }

    /** Serialize a [TimeBasis] for the persisted log. Exact returns null: a live row has nothing
     *  to qualify, and an absent tag is what every previously written row already means. */
    private fun basisToJson(b: TimeBasis): JSONObject? = when (b) {
        is TimeBasis.Exact -> null
        is TimeBasis.Reconstructed -> JSONObject().put("k", "r").put("at", b.atMs).put("p", b.precisionSec)
        is TimeBasis.Bracketed -> JSONObject().put("k", "b").apply {
            b.afterMs?.let { put("a", it) }
            b.beforeMs?.let { put("z", it) }
        }
        is TimeBasis.Unknown -> JSONObject().put("k", "u")
    }

    /** Read back [basisToJson]. Null for a row with no tag, which is every row an older build
     *  wrote and every live row: the caller leaves those as Exact. */
    private fun basisFromJson(o: JSONObject): TimeBasis? {
        val t = o.optJSONObject("_tq") ?: return null
        return when (t.optString("k")) {
            "r" -> TimeBasis.Reconstructed(t.optLong("at"), t.optInt("p", TIME_ANCHOR_FLOOR_SEC))
            // A bracket that lost both ends is no bracket at all, so it degrades to unknown
            // rather than reloading as a range with nothing in it.
            "b" -> {
                val a = if (t.has("a")) t.optLong("a") else null
                val z = if (t.has("z")) t.optLong("z") else null
                if (a == null && z == null) TimeBasis.Unknown else TimeBasis.Bracketed(a, z)
            }
            "u" -> TimeBasis.Unknown
            else -> null
        }
    }

    companion object {
        /** The one sentence a user needs when a connect will not take. Kept byte-identical to iOS
         *  BLEManager.pairWindowHint: this is user-facing copy and the two apps must not diverge. */
        const val PAIR_WINDOW_HINT = "turn the beacon off and on, then connect within two minutes."
        const val BUFFER_KEY_UNAVAILABLE_HINT =
            "Secure buffer key storage is unavailable. Unlock your phone and reconnect."

        @Volatile private var INSTANCE: AcabBleManager? = null

        /** Process-wide singleton so the foreground service and the ViewModel share ONE
         *  link. The service owns the connect/disconnect lifecycle while Drive mode is on,
         *  so the ViewModel's onCleared() must not tear it down then. */
        fun getInstance(context: Context): AcabBleManager =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AcabBleManager(context.applicationContext).also { INSTANCE = it }
            }

        /** The live manager, or null. Deliberately does NOT construct one: a widget being placed
         *  must never be the thing that spins up a BLE manager in a process that has none. */
        fun peekInstance(): AcabBleManager? = INSTANCE

        private const val KEY_ALIAS = "acab.buf.wrap"
        // A fixed point safely in the past that approx-time history counts down from, so a
        // seq-ordered replay lands strictly before "now" and keeps its relative order.
        internal const val HIST_PSEUDO_BASE = 1_000_000_000_000L   // ~2001-09, far below any real wall clock
        // The board's crystal is specified to roughly +/-20 ppm, so a reconstructed stamp carried
        // back across E seconds of uptime can be off by E * this. See precisionFor.
        private const val CRYSTAL_DRIFT = 0.00002
        // Floor under any reconstructed stamp's precision. The anchor itself crossed a BLE round
        // trip before the board stored it, so even a record captured seconds after the push is
        // only good to a couple of seconds, and claiming better would be claiming more than we know.
        private const val TIME_ANCHOR_FLOOR_SEC = 2
        // Cap on distinct devices held in memory / persisted, so a long drive can't grow the
        // store without bound. Evicts oldest-first. 5000 is high enough to just keep logging
        // through any realistic session (~5MB) while still guarding against a runaway firehose;
        // the board's offline black box is the uncapped record.
        private const val STORE_CAP = 5000
        // Cap on rows handed to the live feed (newest-first). A Desert-mode firehose stays
        // responsive; the full store still backs the map, CSV, and counts.
        private const val FEED_CAP = 5000
        // Coalesce feed emissions to this cadence (~3 Hz) so the firehose can't thrash Compose.
        private const val PUBLISH_INTERVAL_MS = 300L

        // How often the home-screen widget summary is recomputed + re-rendered at most. A home
        // widget updates far less often than the in-app feed, so this coarse sample keeps a
        // Desert-mode firehose from thrashing cross-process AppWidget updates; a connect or
        // disconnect still lands within one window.
        private const val WIDGET_SAMPLE_MS = 2_000L
        // Floor on the gap between live-session checkpoints (see checkpointDetections). 30 s bounds
        // a Desert-mode flood to two whole-log re-seals a minute while keeping the most a crash can
        // cost to half a minute of driving.
        private const val CHECKPOINT_MIN_MS = 30_000L
        // How stale the phone's own fix may be before we stop stamping detections with it. 2 min is
        // ~1 mile at freeway speed: past that the coordinate is not "roughly where you were", it is
        // a specific wrong place, and a blank cell beats a confident lie in an evidence export.
        private const val FIX_MAX_AGE_NANOS = 120_000L * 1_000_000L
        // How long a last-known-fix read is reused (see freshSelfCoord).
        private const val FIX_CACHE_NANOS = 1_000L * 1_000_000L
        // Process-owned location cadence. Same values the old Activity listener used.
        private const val LOCATION_INTERVAL_MS = 5_000L
        private const val LOCATION_MIN_DISTANCE_M = 10f
        // The firmware accepts up to 256 ignore-list entries.
        private const val IGNORE_CAP = 256
        // The firmware accepts up to 256 watchlist entries, same as the ignore list.
        private const val WATCH_CAP = 256
        // How often to READ the Status characteristic as a notify fallback while connected. A big
        // status frame skipped as a notify under a small MTU stays fresh via this read.
        private const val STATUS_POLL_MS = 5_000L
        /** Buzzer re-assert attempts in the fast burst (see reconcileBuzzer). Matches iOS
         *  BLEManager.maxBuzzerReasserts. Only the "board wants to be audible" direction stops
         *  here; the MUTE direction falls through to the slow retry below. */
        private const val MAX_BUZZER_REASSERTS = 3
        /** How often the reconciler re-sends a MUTE the board has not taken, after the burst is
         *  spent. A board left audible against the user's choice is a covert-use failure, so that
         *  direction never gives up; 30 s is slow enough that one idempotent config frame costs
         *  nothing on the serialized GATT queue. Matches iOS BLEManager.buzzerMuteRetryInterval. */
        private const val BUZZER_MUTE_RETRY_MS = 30_000L
        /** Full-list re-pushes the STATUS reconciler may spend on ONE divergence before it gives
         *  up on this connection. Three rounds cover the ordinary causes (a dropped chunk write,
         *  a board still committing a staged list when its status frame went out) and stop the
         *  session-long re-push loop a count the board can never match used to produce. iOS twin:
         *  BLEManager.maxListPushAttempts, spent per key in reconcileBoardList and re-armed on the
         *  same events - a fresh link, a user edit that really changes the list, and the board
         *  agreeing. Its 1 Hz scheduleListPush debounce only PACES that loop; this bound ends it. */
        private const val MAX_LIST_PUSH_ATTEMPTS = 3
        // Max MACs per ignore/watch config write. 20 MACs (~17 chars each) plus the JSON envelope
        // and the "more" flag stays well under the 512 B ATT write cap; a >24-entry single write
        // would exceed it and be rejected. Apps split into these chunks; the board stages each
        // "more":true chunk and commits on the final one.
        private const val MAC_CHUNK = 20

        // ---- OTA timings ----
        // How often the stall watchdog wakes, and how long a silence from the board (no "ready",
        // "prog", or "done") means the transfer has stalled. ~64 KB between prog notifies is a few
        // seconds of writes even at the 20-byte floor, so 20 s is comfortably past a healthy gap.
        private const val STALL_CHECK_MS = 4_000L
        private const val STALL_TIMEOUT_MS = 20_000L
        private const val OTA_HOLD_POLL_MS = 100L
        // How long to wait after "done" before trying to reconnect (board reboots ~250 ms after
        // the end, then re-advertises), the gap between attempts, and the wall-clock window
        // before declaring the board missing. 90 s on both platforms (iOS otaRebootTimeout): a
        // first boot of new firmware plus re-advertise can take 40-80 s, and the old ~35 s
        // attempt-counted loop reported "didn't come back" on boards seconds from confirming.
        private const val REBOOT_WAIT_MS = 3_000L
        private const val REBOOT_GIVE_UP_MS = 90_000L
        private const val RECONNECT_ATTEMPT_MS = 4_000L
        // After the post-reboot reconnect lands, how long to wait for the first status frame
        // (the version report checkPostRebootConfirm needs) before reporting the indeterminate
        // outcome. 30 s on both platforms; see armPostRebootStatusCap.
        private const val POST_REBOOT_STATUS_CAP_MS = 30_000L
        // Fresh firmware normally satisfies its product-health gate at 20 s. Keep retrying long
        // enough for that durable acknowledgement, but never synthesize success without "ok".
        private const val CONFIRM_RETRY_MS = 2_000L
        private const val CONFIRM_TIMEOUT_MS = 35_000L

        // How long the unexpected-drop auto-reconnect shows "Reconnecting…" before Drive mode's
        // foreground service is released. Matches the iOS "Reconnecting…" Live Activity's ~120 s
        // auto-end so a powered-off board doesn't hold a device-less foreground service open
        // forever. Only the SERVICE ends at the window: the pending autoConnect client stays
        // armed on every path, like iOS's reconnectTarget, so the board still relinks whenever
        // it returns (see autoReconnect's watchdog).
        private const val AUTO_RECONNECT_WINDOW_MS = 120_000L
        // Fresh scan-connect watchdog: how long a tapped row may sit at CONNECTING before the
        // pending client is cancelled and the scan restarted. Matches iOS's 15 s
        // connectTimeoutTimer; the platform's own failure (status 133) takes ~30 s and lands on
        // a static resting screen instead of a live rescan.
        private const val CONNECT_TIMEOUT_MS = 15_000L
        // The user may have to approve Android's system pairing sheet. Give that interaction room,
        // but never leave the app's Pairing screen unbounded if no terminal broadcast arrives.
        private const val PAIRING_TIMEOUT_MS = 45_000L
        // Once transport connects, bound the encrypted service/CCCD readiness chain separately.
        // The initial connect watchdog has already retired at STATE_CONNECTED. Re-arming after a
        // fresh bond also covers its settle/reconnect window.
        private const val SECURE_READY_TIMEOUT_MS = 30_000L

        // ---- scan lifecycle ----
        // How long a LOW_LATENCY scan may run before falling back to the resting screen. Long
        // enough to power a board on and watch it appear; a fraction of the ~30 min the OS
        // would otherwise let the highest duty cycle burn.
        private const val SCAN_TIMEOUT_MS = 45_000L
        // Retry delay after SCAN_FAILED_SCANNING_TOO_FREQUENTLY: the platform's penalty window
        // is 30 s of accepted starts, so one retry past it succeeds.
        private const val SCAN_RETRY_MS = 30_000L
        // Skip onRadioOn's auto-rescan when a scan started this recently, so radio flapping
        // can't burn the 5-starts-per-30s budget.
        private const val SCAN_RESTART_DEBOUNCE_MS = 10_000L
        // How long the app must have zero started activities before it counts as backgrounded.
        // Rides across the stop->start gap of a rotation (ProcessLifecycleOwner uses ~700 ms).
        private const val BACKGROUND_DEBOUNCE_MS = 700L

        // Re-drain requests allowed per connection before onHistEnd accepts a short drain
        // as-is (cross-platform contract with iOS: cap of 2, accept-at-cap advances the
        // cursor to the highest seq actually received).
        private const val HIST_RESYNC_MAX = 2
    }
}

private fun String.hexToBytes(): ByteArray =
    ByteArray(length / 2) { ((this[it * 2].digitToInt(16) shl 4) or this[it * 2 + 1].digitToInt(16)).toByte() }

@Suppress("DEPRECATION")
private fun Intent.getParcelableExtraCompat(key: String): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
        getParcelableExtra(key, BluetoothDevice::class.java)
    else getParcelableExtra(key)
