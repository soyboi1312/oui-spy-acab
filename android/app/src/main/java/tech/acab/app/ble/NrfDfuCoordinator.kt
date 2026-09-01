package tech.acab.app.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Handler
import android.os.Looper
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import no.nordicsemi.android.dfu.DfuProgressListenerAdapter
import no.nordicsemi.android.dfu.DfuServiceInitiator
import no.nordicsemi.android.dfu.DfuServiceListenerHelper
import tech.acab.app.model.DeviceStatus
import tech.acab.app.net.FirmwareBuild
import tech.acab.app.net.NrfBuild
import tech.acab.app.net.firmwareArtifactResponseAllowed
import tech.acab.app.net.trustedFirmwareArtifactUrl
import java.io.ByteArrayInputStream
import java.io.File
import java.net.HttpURLConnection
import java.security.MessageDigest
import java.util.UUID
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream

enum class NrfDfuPhase { IDLE, PREPARING, TRIGGERING, SCANNING, FLASHING, CONFIRMING, DONE, FAILED }

/** Start DFU may erase the application before upload progress appears. Once FLASHING is entered,
 * neither a user cancel nor loss of the separate S3 control link may abort the selected AdaDFU
 * transfer; doing so can strand the radio in its bootloader and require physical USB recovery. */
internal fun nrfUserCancellationAllowed(phase: NrfDfuPhase): Boolean = when (phase) {
    NrfDfuPhase.PREPARING, NrfDfuPhase.TRIGGERING, NrfDfuPhase.SCANNING -> true
    NrfDfuPhase.IDLE, NrfDfuPhase.FLASHING, NrfDfuPhase.CONFIRMING,
    NrfDfuPhase.DONE, NrfDfuPhase.FAILED -> false
}

internal fun nrfArmMutationAllowed(
    ownsLiveSession: Boolean,
    phase: NrfDfuPhase,
    protectedHoldReady: Boolean,
): Boolean = ownsLiveSession && phase == NrfDfuPhase.PREPARING && protectedHoldReady

internal enum class NrfStartStallAction { KEEP_WAITING, IGNORE }

/** Once the Nordic service starts, a silent START/erase window is never safe to abort. */
internal fun nrfStartStallAction(
    phase: NrfDfuPhase,
    uploadProgressSeen: Boolean,
): NrfStartStallAction = if (phase == NrfDfuPhase.FLASHING && !uploadProgressSeen) {
    NrfStartStallAction.KEEP_WAITING
} else {
    NrfStartStallAction.IGNORE
}

data class NrfDfuProgress(
    val phase: NrfDfuPhase = NrfDfuPhase.IDLE,
    val pct: Int = 0,
    val message: String = "",
) {
    val isRunning: Boolean get() = phase != NrfDfuPhase.IDLE && phase != NrfDfuPhase.DONE && phase != NrfDfuPhase.FAILED
}

/**
 * Drives one nRF co-processor DFU over BLE, self-contained so AcabBleManager only wires it in.
 *
 * Flow: download + verify the package (sha256 AND the app-side ECDSA signature, since the nRF's
 * stock bootloader can't verify our sig), tell the S3 to relay the DFU trigger, scan for the
 * bootloader's "AdaDFU" advertiser, hand it to Nordic's DfuServiceInitiator (legacy DFU), then
 * watch the S3's reported nrfv for the new version. The S3 link (AcabBleManager's own GATT) stays
 * up the whole time; the DFU library talks to AdaDFU over a separate connection.
 */
class NrfDfuCoordinator(
    private val context: Context,
    private val adapter: BluetoothAdapter?,
    private val scope: CoroutineScope,
    private val sendTrigger: () -> Unit,           // writeConfig {"nrfdfu": true}
    private val requestStatus: () -> Unit,
    private val statusProvider: () -> DeviceStatus?, // for the post-flash version confirm
    private val otaInProgress: () -> Boolean,      // true while an S3 OTA is live (never overlap)
    /** Monotonic identity of the encrypted S3 GATT session that owns this attempt. */
    private val linkSessionProvider: () -> Long,
    private val linkReady: () -> Boolean,
    /** Increments for every status frame, including identical values. */
    private val statusRevisionProvider: () -> Long,
    /** Confirmed foreground-service promotion, rechecked on Main at the trigger write. */
    private val protectedHoldReady: () -> Boolean,
) {
    private val _progress = MutableStateFlow(NrfDfuProgress())
    val progress: StateFlow<NrfDfuProgress> = _progress.asStateFlow()

    private var job: Job? = null
    private var scanCb: ScanCallback? = null
    private var preflightScanCb: ScanCallback? = null
    private var confirmTarget: Int = 0
    private var ownerSession: Long? = null
    private var triggerStatusRevision = 0L
    private var triggerSent = false
    /** A board-touched failed run may still have replies in this GATT's queues. Never reuse it. */
    private var quarantinedSession: Long? = null
    private val main = Handler(Looper.getMainLooper())

    // START-phase notice watchdog. The Adafruit bootloader can erase the application before the
    // first upload-progress callback. A timeout in that silent window may update the copy, but it
    // must never abort the Nordic service: interruption can leave a bootloader-only radio that
    // requires USB recovery. Nordic's own terminal callback remains authoritative.
    private var pendingZip: File? = null
    private var pastStart = false          // true once upload progress begins (watchdog disarm)
    private var listenerRegistered = false
    private var settleRunnable: Runnable? = null
    private var watchdogRunnable: Runnable? = null
    private var scanTimeoutRunnable: Runnable? = null
    private var armReplyTimeoutRunnable: Runnable? = null
    private var candidateWindowRunnable: Runnable? = null
    private var preflightWindowRunnable: Runnable? = null
    private val closeCandidates = LinkedHashMap<String, Int>()

    companion object {
        // Legacy Nordic DFU service, advertised by the Adafruit/Seeed bootloader in OTA mode.
        private val DFU_SERVICE = UUID.fromString("00001530-1212-EFDE-1523-785FEABCD123")
        private const val SCAN_TIMEOUT_MS = 40_000L
        // Let the Adafruit HCI queue drain after AdaDFU appears, before we open the transfer.
        private const val SETTLE_MS = 3_000L
        // connect + service discovery + START + the bootloader's erase-before-response all fit well
        // inside this; the first upload-progress callback disarms it.
        private const val START_WATCHDOG_MS = 25_000L
        private const val ARM_REPLY_TIMEOUT_MS = 10_000L
        // A qualifying advertiser is not selected immediately. Give the scanner a short window to
        // reveal a second nearby AdaDFU and refuse ambiguity rather than flash whichever callback won.
        private const val PREFLIGHT_WINDOW_MS = 2_000L
        private const val CANDIDATE_WINDOW_MS = 2_000L
        // Proximity gate: the UI tells the user to hold the phone next to the beacon, so a real
        // target is loud. Reject weaker advertisers so a wildcard-signed zip can't flash a
        // neighbor board that happens to be in bootloader mode. 127 = RSSI unavailable.
        private const val MIN_RSSI = -55
        // The stock Adafruit/Seeed bootloader HARD-FAILS the transfer (Response op=3 status=6
        // "Operation failed" + disconnect, seen on hardware 2026-07-23) when data packets outrun
        // its shallow HCI RX queue. Adafruit's guidance: OTA needs PRN <= 8; the library default is
        // 12. 6 gives headroom - each PRN is a flow-control stop that lets it drain to flash.
        private const val PRN = 6

        /**
         * RELEASE GATE for the co-processor DFU on Android. FALSE ships the app S3-only: the nRF
         * leg is never offered and never runs, by any route.
         *
         * WHY IT IS OFF. The failure mode this guards is not a failed update, it is a DEAD RADIO:
         * when the bootloader accepts Start DFU and the size array and the transfer then dies, it
         * has already erased the application, so the nRF re-parks in its bootloader on every boot
         * with BLE detection offline. A power cycle does NOT recover it - it took a USB UF2
         * reflash (observed 2026-08-06). Nothing in the app can fix that, because the co-processor
         * offer is gated on reading a version FROM the co-processor. An update path that can
         * silently kill the product's main function is worse than no update path.
         *
         * WHAT FLIPPING IT TO TRUE REQUIRES (all of it, on hardware, not reasoning):
         *   1. a run from a power-cycled nRF in its normal application,
         *   2. a log with NO MTU negotiation on the DFU link,
         *   3. Start DFU accepted (no status 2),
         *   4. TWO complete passes: co-processor-only, and combined S3+nRF,
         *   5. the board back on the new nrfv with detections resumed after each.
         *
         * STATUS: ALL FIVE PASSED on 2026-08-06 (Pixel 2, rev-A) once disableMtuRequest() was
         * added - see the A/B recorded at that call.
         *   pass 1, co-processor only: nRF v1 -> v2, 123120 bytes in 96.1 s, Validate status 1,
         *     board reported "[nrf] co-processor app version 2", scanning + forwarding resumed.
         *   pass 2, combined S3+nRF: board 2.0.3 -> 2.0.4, rebooted, reconnected, confirmed, then
         *     nRF v1 -> v2 in the same flow (93.0 s), ending DONE / "You're on the latest
         *     firmware" - not PARTIAL - with detections resumed.
         * Neither log contained an MTU negotiation and neither Start DFU was refused.
         *
         * If this ever regresses, set it back to false FIRST and diagnose second: the failure
         * costs a radio, not an update.
         *
         * The two functions below are the ONLY ways into the DFU - the combined coordinator reaches
         * it through these same two, and nothing outside this file touches DfuServiceInitiator - so
         * guarding both is a complete gate over every entry point (combined, co-processor-only,
         * notification/deep link, and any automatic coordinator invocation).
         */
        const val NRF_DFU_ENABLED = true
    }

    /** True when a co-processor update is available for this build vs the running version.
     *  Gated: with [NRF_DFU_ENABLED] false this is always false, so the update is never OFFERED -
     *  the combined flow's staleness check ORs this in, so it simply plans an S3-only run. */
    fun updateAvailable(build: FirmwareBuild): Boolean {
        val status = statusProvider()
        return nrfUpdateOfferAllowed(
            releaseEnabled = NRF_DFU_ENABLED,
            nrf = build.nrf,
            buildLabel = build.manifestLabel,
            liveLabel = status?.firmwareLabel,
            runningVersion = status?.nrfVersion,
            protocolVersion = status?.protoVersion,
        )
    }

    fun startUpdate(build: FirmwareBuild) {
        if (_progress.value.isRunning) return
        // Defence in depth behind the offer gate above: nothing should reach here with the flag
        // off, and if some future path does, it must not put the co-processor into its bootloader.
        if (!NRF_DFU_ENABLED) {
            set(NrfDfuPhase.FAILED, 0,
                "Second-radio updates aren't available in this version of the app. Your beacon keeps working as it is.")
            return
        }
        // Never overlap an S3 OTA: both flows drive the same radio, and a co-processor DFU started
        // mid-OTA would fight the S3 image stream. Parity with the otaState.isRunning guard at the
        // top of BLEManager.startNrfUpdate (BLEManager+NrfDFU.swift), which fails with this same
        // string. Named, not line-cited: that file has already shifted this guard once.
        if (otaInProgress()) {
            set(NrfDfuPhase.FAILED, 0, "Finish the board update first, then update the co-processor.")
            return
        }
        if (!linkReady()) {
            set(NrfDfuPhase.FAILED, 0, "The board isn't connected. Reconnect and try again.")
            return
        }
        val session = linkSessionProvider()
        if (quarantinedSession == session) {
            set(NrfDfuPhase.FAILED, 0,
                "Reconnect to the beacon before retrying the co-processor update. This clears any delayed update replies from the previous attempt.")
            return
        }
        val liveStatus = statusProvider()
        if (liveStatus?.needsNewerApp != false) {
            set(NrfDfuPhase.FAILED, 0,
                "This board needs a newer version of the app before it can be updated safely.")
            return
        }
        if (liveStatus.protoVersion != DeviceStatus.SUPPORTED_PROTO_VERSION) {
            set(NrfDfuPhase.FAILED, 0,
                "Update the board firmware first, then power-cycle and reconnect before updating the co-processor.")
            return
        }
        if (liveStatus.nrfUpdating) {
            set(NrfDfuPhase.FAILED, 0,
                "The co-processor is already in update mode. Wait for it to finish, then reconnect before trying again.")
            return
        }
        val runningNrfVersion = liveStatus.nrfVersion
        if (runningNrfVersion == null) {
            set(NrfDfuPhase.FAILED, 0,
                "The beacon did not report its co-processor version. Refresh its status and try again.")
            return
        }
        val liveLabel = liveStatus.firmwareLabel
        if (build.manifestLabel.isBlank() || build.manifestLabel != liveLabel) {
            set(NrfDfuPhase.FAILED, 0,
                "This update package does not match the connected board. Refresh its status and try again.")
            return
        }
        val nrf = build.nrf
        if (nrf == null || !nrf.ota || !nrf.hasVerifiableImage) {
            set(NrfDfuPhase.FAILED, 0, "No verified co-processor update is published for this board yet.")
            return
        }
        if (nrf.version <= runningNrfVersion) {
            set(NrfDfuPhase.FAILED, 0, "The co-processor is already on this version or newer.")
            return
        }
        confirmTarget = nrf.version
        ownerSession = session
        triggerStatusRevision = 0L
        triggerSent = false
        pastStart = false
        DfuServiceInitiator.createDfuNotificationChannel(context)

        // All state-machine transitions and scanner ownership are main-thread serialized. Only the
        // bounded download/verification body leaves Main below.
        job = scope.launch(Dispatchers.Main.immediate) {
            set(NrfDfuPhase.PREPARING, 0, "Preparing update…")
            val zipFile = try {
                withContext(Dispatchers.IO) {
                    downloadAndVerify(
                        nrf.zipUrl, nrf.size, nrf.sha256, nrf.sig, nrf.version,
                    )
                }
            } catch (e: CancellationException) {
                // cancel() already owns the state ("Co-processor update cancelled."). The blocking
                // HTTP read isn't interruptible, so this zombie resume can land seconds later; it
                // must not clobber the cancelled copy - or a restarted run's fresh state. Parity
                // with iOS BLEManager+NrfDFU's dedicated CancellationError catch.
                throw e
            } catch (e: Exception) {
                set(NrfDfuPhase.FAILED, 0, (e as? PrepError)?.msg
                    ?: "Couldn't download the co-processor update. Check your connection and try again.")
                return@launch
            }
            if (!ownsLiveSession()) {
                set(NrfDfuPhase.FAILED, 0,
                    "The board changed before the co-processor update could start. Reconnect and try again.")
                return@launch
            }
            // First prove no generic AdaDFU target was already nearby. The bootloader has no board
            // identity, so a pre-existing candidate cannot be associated with this trigger.
            set(NrfDfuPhase.PREPARING, 0, "Checking for other devices already in update mode…")
            pendingZip = zipFile
            main.post {
                if (!ownsLiveSession() || _progress.value.phase != NrfDfuPhase.PREPARING) {
                    set(NrfDfuPhase.FAILED, 0,
                        "The board changed before the co-processor update could start. Reconnect and try again.")
                    return@post
                }
                verifyNoPreexistingDfuTarget { armDfuHandoff(zipFile) }
            }
        }
    }

    private fun armDfuHandoff(zipFile: File) {
        val ownsSession = ownsLiveSession()
        val holdReady = protectedHoldReady()
        if (!nrfArmMutationAllowed(
                ownsLiveSession = ownsSession,
                phase = _progress.value.phase,
                protectedHoldReady = holdReady,
            )) {
            val message = if (!holdReady) {
                "Android could not keep the protected update session active. Nothing was sent to the co-processor; keep the app open and try again."
            } else {
                "The board changed before the co-processor update could start. Reconnect and try again."
            }
            set(NrfDfuPhase.FAILED, 0,
                message)
            return
        }
        // Protocol v2 explicitly accepts or denies the physical-start gate. Do not scan until this
        // encrypted session then reports a fresh nrfup handoff.
        set(NrfDfuPhase.TRIGGERING, 0, "Starting co-processor update mode…")
        triggerStatusRevision = statusRevisionProvider()
        triggerSent = true
        sendTrigger()
        val timeout = Runnable {
            if (_progress.value.phase == NrfDfuPhase.TRIGGERING) {
                set(NrfDfuPhase.FAILED, 0,
                    "The beacon did not acknowledge co-processor update mode. Power-cycle it, reconnect, and retry within two minutes.")
            }
        }
        armReplyTimeoutRunnable = timeout
        main.postDelayed(timeout, ARM_REPLY_TIMEOUT_MS)
    }

    /** Protocol-v2 reply from the initiating board's authenticated OTA notification channel. */
    fun handleArmReply(allowed: Boolean, sourceSession: Long) {
        main.post {
            if (_progress.value.phase != NrfDfuPhase.TRIGGERING ||
                ownerSession != sourceSession || !ownsLiveSession()) return@post
            val zip = pendingZip
            if (!allowed) {
                armReplyTimeoutRunnable?.let { main.removeCallbacks(it) }
                armReplyTimeoutRunnable = null
                set(NrfDfuPhase.FAILED, 0,
                    "For safety, co-processor updates require a recent physical start. Power-cycle the beacon, reconnect, and retry within two minutes.")
            } else if (zip == null) {
                armReplyTimeoutRunnable?.let { main.removeCallbacks(it) }
                armReplyTimeoutRunnable = null
                set(NrfDfuPhase.FAILED, 0,
                    "The co-processor update package was no longer available. Retry the update.")
            } else {
                // Acceptance precedes the loop-task drain's final secure-window recheck. Wait for
                // status.nrfup, which proves this S3 actually forwarded the command. Keep the
                // original timeout armed: nrf-ready alone is not the handoff.
                requestStatus()
            }
        }
    }

    /** Status-side proof of the actual S3-to-nRF handoff, and fallback for a lost optional ack. */
    fun handleStatusUpdate(status: DeviceStatus, sourceSession: Long, revision: Long) {
        main.post {
            if (!nrfHandoffStatusIsFresh(
                    protoVersion = status.protoVersion,
                    nrfUpdating = status.nrfUpdating,
                    statusRevision = revision,
                    triggerRevision = triggerStatusRevision,
                    ownerSession = ownerSession,
                    sourceSession = sourceSession,
                ) || !ownsLiveSession() ||
                _progress.value.phase != NrfDfuPhase.TRIGGERING) return@post
            val zip = pendingZip ?: run {
                set(NrfDfuPhase.FAILED, 0,
                    "The co-processor update package was no longer available. Retry the update.")
                return@post
            }
            armReplyTimeoutRunnable?.let { main.removeCallbacks(it) }
            armReplyTimeoutRunnable = null
            scanForDfuTarget(zip)
        }
    }

    fun cancel() {
        if (!nrfUserCancellationAllowed(_progress.value.phase)) return
        job?.cancel(); job = null
        stopScan()
        clearPendingCallbacks()
        unregisterDfuListener()
        if (_progress.value.isRunning) set(NrfDfuPhase.FAILED, 0, "Co-processor update cancelled.")
    }

    /** Before transfer, the generic AdaDFU link still depends on its owning S3 identity and a link
     * loss ends the attempt. Once FLASHING, the uniquely selected target must finish safely. */
    fun onLinkTeardown(endedSession: Long) {
        main.post {
            if (ownerSession != endedSession || !_progress.value.isRunning) return@post
            // The AdaDFU address was uniquely selected before FLASHING. Its transfer no longer
            // depends on the S3 control link, and aborting after Start DFU can strand an erased
            // radio. Keep listeners/controller alive; startConfirm will report that the finished
            // transfer could not be confirmed if the S3 has not reconnected.
            if (_progress.value.phase == NrfDfuPhase.FLASHING) return@post
            job?.cancel(); job = null
            stopScan()
            clearPendingCallbacks()
            unregisterDfuListener()
            set(NrfDfuPhase.FAILED, 0,
                "The beacon connection ended during the co-processor update. Reconnect and try again.")
        }
    }

    fun dismiss() {
        if (!_progress.value.isRunning) set(NrfDfuPhase.IDLE, 0, "")
    }

    // ---- steps ----

    private class PrepError(val msg: String) : Exception(msg)

    /** Observe the generic bootloader namespace before triggering this board. Any already-close
     * AdaDFU makes identity unknowable, so fail before changing hardware state. */
    @SuppressLint("MissingPermission")
    private fun verifyNoPreexistingDfuTarget(onClear: () -> Unit) {
        val scanner = runCatching { adapter?.bluetoothLeScanner }.getOrNull()
        if (scanner == null) {
            set(NrfDfuPhase.FAILED, 0, "Bluetooth is off.")
            return
        }
        val found = LinkedHashSet<String>()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                if (preflightScanCb !== this) return
                val address = matchingCloseDfuAddress(result) ?: return
                found += address
            }

            override fun onScanFailed(errorCode: Int) {
                if (preflightScanCb !== this) return
                stopPreflightScan()
                set(NrfDfuPhase.FAILED, 0,
                    "Couldn't check for other update-mode devices. Reconnect and try again.")
            }
        }
        preflightScanCb = cb
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { scanner.startScan(null, settings, cb) }
            .onFailure {
                stopPreflightScan()
                set(NrfDfuPhase.FAILED, 0,
                    "Couldn't check for other update-mode devices. Reconnect and try again.")
                return
            }
        val finish = Runnable {
            if (preflightScanCb !== cb) return@Runnable
            stopPreflightScan()
            preflightWindowRunnable = null
            if (_progress.value.phase != NrfDfuPhase.PREPARING || !ownsLiveSession()) {
                if (_progress.value.phase == NrfDfuPhase.PREPARING) {
                    set(NrfDfuPhase.FAILED, 0,
                        "The board connection changed during the safety check. Reconnect and try again.")
                }
            } else if (!preflightDfuClear(found)) {
                set(NrfDfuPhase.FAILED, 0,
                    "A nearby co-processor was already in update mode, so it cannot be tied safely to this beacon. Move it away or recover it, then reconnect and try again.")
            } else {
                onClear()
            }
        }
        preflightWindowRunnable = finish
        main.postDelayed(finish, PREFLIGHT_WINDOW_MS)
    }

    @SuppressLint("MissingPermission")
    private fun stopPreflightScan() {
        val cb = preflightScanCb ?: return
        preflightScanCb = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(cb) }
    }

    private fun downloadAndVerify(
        url: String,
        expectedSize: Long,
        expectedSha: String,
        sigHex: String,
        expectedVersion: Int,
    ): File {
        val parsed = trustedFirmwareArtifactUrl(url)
            ?: throw PrepError("The co-processor update URL was not from the trusted firmware host.")
        val conn = (parsed.openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"; connectTimeout = 15_000; readTimeout = 20_000
            instanceFollowRedirects = false
        }
        val bytes = try {
            val responseCode = conn.responseCode
            if (!firmwareArtifactResponseAllowed(parsed, conn.url, responseCode))
                throw PrepError("Couldn't download the co-processor update. Check your connection and try again.")
            val cap = expectedSize.coerceIn(1L, 4L * 1024 * 1024) + 4096
            val out = java.io.ByteArrayOutputStream(cap.toInt())
            conn.inputStream.use { input ->
                val tmp = ByteArray(16 * 1024); var total = 0L
                while (true) {
                    val r = input.read(tmp); if (r < 0) break
                    total += r
                    if (total > cap) throw PrepError("The co-processor update was the wrong size, so it wasn't installed.")
                    out.write(tmp, 0, r)
                }
            }
            out.toByteArray()
        } finally { conn.disconnect() }

        if (bytes.size.toLong() != expectedSize)
            throw PrepError("The co-processor update was the wrong size, so it wasn't installed.")
        val sha = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
        if (!sha.equals(expectedSha, ignoreCase = true))
            throw PrepError("The co-processor update failed its integrity check, so it wasn't installed.")
        // App-side signature gate: the ONLY gate for the nRF (its bootloader can't verify our sig).
        if (!NrfDfuSignature.isValid(bytes, sigHex))
            throw PrepError("The co-processor update couldn't be verified as signed by the beacon maker, so it wasn't installed.")
        val embeddedVersion = nrfPackageApplicationVersion(bytes)
            ?: throw PrepError("The signed co-processor package did not contain a valid embedded application version, so it wasn't installed.")
        if (embeddedVersion != expectedVersion.toLong()) {
            throw PrepError(
                "The signed co-processor package identifies as version $embeddedVersion instead of $expectedVersion, so it wasn't installed.",
            )
        }

        val f = File(context.cacheDir, "beacon-nrf-dfu.zip")
        f.writeBytes(bytes)
        return f
    }

    @SuppressLint("MissingPermission")
    private fun scanForDfuTarget(zipFile: File) {
        if (!ownsLiveSession()) {
            set(NrfDfuPhase.FAILED, 0,
                "The board connection changed before the co-processor appeared. Reconnect and try again.")
            return
        }
        pendingZip = zipFile
        closeCandidates.clear()
        candidateWindowRunnable?.let { main.removeCallbacks(it) }
        candidateWindowRunnable = null
        val scanner = runCatching { adapter?.bluetoothLeScanner }.getOrNull()
        if (scanner == null) { set(NrfDfuPhase.FAILED, 0, "Bluetooth is off."); return }
        set(NrfDfuPhase.SCANNING, 0, "Looking for the co-processor in update mode…")

        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                // Once-guard: the scan is unfiltered LOW_LATENCY against a ~100ms advertiser, so
                // duplicate results can already be queued on the main looper when the winning
                // match calls stopScan(). Without this, a queued duplicate overwrites the settle
                // runnable and posts a SECOND beginDfu (FLASHING passes the isRunning check),
                // enqueuing a doomed second transfer into the DfuBaseService queue. Drop anything
                // from a callback that is no longer the active scan.
                if (scanCb !== this) return
                val addr = matchingDfuAddress(result) ?: return
                val rssi = result.rssi
                if (!isCloseDfuRssi(rssi)) {
                    if (closeCandidates.isEmpty()) {
                        set(NrfDfuPhase.SCANNING, 0, "A co-processor is in update mode but too far. Hold the phone closer.")
                    }
                    return
                }
                closeCandidates[addr] = maxOf(closeCandidates[addr] ?: Int.MIN_VALUE, rssi)
                if (candidateWindowRunnable == null) {
                    set(NrfDfuPhase.SCANNING, 0, "Checking that only this co-processor is nearby…")
                    val r = Runnable { chooseDfuCandidate(zipFile) }
                    candidateWindowRunnable = r
                    main.postDelayed(r, CANDIDATE_WINDOW_MS)
                }
            }
        }
        scanCb = cb
        // No hardware filter; match in the callback (see above).
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        runCatching { scanner.startScan(null, settings, cb) }
            .onFailure { set(NrfDfuPhase.FAILED, 0, "Couldn't start the update scan."); return }

        clearScanTimeout()
        val to = Runnable {
            if (_progress.value.phase == NrfDfuPhase.SCANNING) {
                stopScan()
                set(NrfDfuPhase.FAILED, 0,
                    "The co-processor didn't show up in update mode. It usually recovers on its own; reconnect and try again.")
            }
        }
        scanTimeoutRunnable = to
        main.postDelayed(to, SCAN_TIMEOUT_MS)
    }

    @SuppressLint("MissingPermission")
    private fun matchingDfuAddress(result: ScanResult): String? {
        val address = runCatching { result.device?.address }.getOrNull() ?: return null
        val name = runCatching { result.device?.name }.getOrNull()
            ?: result.scanRecord?.deviceName
        val hasService = result.scanRecord?.serviceUuids?.any { it.uuid == DFU_SERVICE } == true
        return address.takeIf { name?.equals("AdaDFU", ignoreCase = true) == true || hasService }
    }

    private fun matchingCloseDfuAddress(result: ScanResult): String? =
        matchingDfuAddress(result)?.takeIf { isCloseDfuRssi(result.rssi) }

    private fun isCloseDfuRssi(rssi: Int): Boolean = rssi != 127 && rssi > MIN_RSSI

    /** Freeze the brief candidate set. Exactly one close bootloader is safe; zero keeps scanning
     *  only when the window has not actually collected anything, and two or more fail closed. */
    private fun chooseDfuCandidate(zipFile: File) {
        candidateWindowRunnable = null
        if (_progress.value.phase != NrfDfuPhase.SCANNING || !ownsLiveSession()) {
            if (_progress.value.phase == NrfDfuPhase.SCANNING) {
                stopScan()
                set(NrfDfuPhase.FAILED, 0,
                    "The board connection changed during target selection. Reconnect and try again.")
            }
            return
        }
        when (val decision = decideDfuCandidates(closeCandidates.keys)) {
            is DfuCandidateDecision.One -> {
                stopScan()
                clearScanTimeout()
                set(NrfDfuPhase.SCANNING, 0, "Found the co-processor; settling…")
                val r = Runnable { beginDfu(decision.address, zipFile) }
                settleRunnable = r
                main.postDelayed(r, SETTLE_MS)
            }
            DfuCandidateDecision.Ambiguous -> {
                stopScan()
                clearScanTimeout()
                set(NrfDfuPhase.FAILED, 0,
                    "More than one nearby co-processor is in update mode. Move the other beacon away, reconnect, and try again.")
            }
            DfuCandidateDecision.None -> Unit
        }
    }

    private fun clearScanTimeout() {
        scanTimeoutRunnable?.let { main.removeCallbacks(it) }
        scanTimeoutRunnable = null
    }

    private fun clearPendingCallbacks() {
        settleRunnable?.let { main.removeCallbacks(it) }; settleRunnable = null
        watchdogRunnable?.let { main.removeCallbacks(it) }; watchdogRunnable = null
        armReplyTimeoutRunnable?.let { main.removeCallbacks(it) }; armReplyTimeoutRunnable = null
        candidateWindowRunnable?.let { main.removeCallbacks(it) }; candidateWindowRunnable = null
        preflightWindowRunnable?.let { main.removeCallbacks(it) }; preflightWindowRunnable = null
        stopPreflightScan()
        clearScanTimeout()
    }

    @SuppressLint("MissingPermission")
    private fun stopScan() {
        val cb = scanCb ?: return
        scanCb = null
        runCatching { adapter?.bluetoothLeScanner?.stopScan(cb) }
    }

    private fun beginDfu(address: String, zipFile: File) {
        if (!_progress.value.isRunning) return
        if (!ownsLiveSession()) {
            set(NrfDfuPhase.FAILED, 0,
                "The board connection changed before the transfer started. Reconnect and try again.")
            return
        }
        settleRunnable = null
        registerDfuListener()
        pastStart = false
        set(NrfDfuPhase.FLASHING, 0, "Sending to co-processor…")
        DfuServiceInitiator(address)
            .setDeviceName("AdaDFU")
            .setKeepBond(false)
            .setForceDfu(false)
            // We connect straight to the bootloader (AdaDFU), so there's no buttonless jump and no
            // address change to chase.
            .setForceScanningForNewAddressInLegacyDfu(false)
            // OBSERVED (bench, Pixel 2 + rev-A, 2026-08-06): the library connects to the AdaDFU
            // bootloader, reads DFU version 0.8, raises the MTU to 247, sends Start DFU (op 1,
            // mode 4) and the image-size array, and the bootloader answers with status 2
            // (INVALID_STATE). LegacyDfuImpl's only route to that reply is resetAndRestart(), so
            // it writes Reset (op 6); the link drops with status 8 and the restarted service can
            // no longer reach the device. Zero firmware bytes ship, and the nRF is left in its
            // bootloader with BLE detection offline. A power cycle does NOT restore the erased
            // application; recovery requires a physical USB UF2 reflash.
            //
            // PROVEN by A/B on hardware, same board / same zip / same phone / same library 2.5.0,
            // this line the only variable:
            //   WITH the MTU request  -> "Requesting MTU = 517", "MTU changed to: 247", then Start
            //                            DFU answered status 2 and LegacyDfuImpl reset the device.
            //                            Zero bytes transferred, co-processor left in its bootloader.
            //   WITHOUT it (this line) -> no MTU negotiation at all, Start DFU accepted, Init DFU
            //                            Parameters + the 14-byte init packet accepted, PRN set,
            //                            Receive Firmware Image accepted, 123120 bytes in 96.1 s,
            //                            Validate status 1, Activate and Reset, and the board then
            //                            reported "[nrf] co-processor app version 2" with scanning
            //                            and forwarding resumed. (2026-08-06, Pixel 2, rev-A.)
            //
            // Note the mechanism is NOT a transport-size problem - status 2 is a bootloader-level
            // reply and both the Start DFU op code and the 12-byte size array fit inside the
            // default 23-byte ATT payload. Raising the MTU upsets the stock Adafruit legacy-DFU
            // bootloader itself. Do not re-enable the request to "speed up" the transfer.
            .disableMtuRequest()
            .setPacketsReceiptNotificationsEnabled(true)
            .setPacketsReceiptNotificationsValue(PRN)
            .setZip(zipFile.absolutePath)
            .start(context, NrfDfuService::class.java)
        armStartWatchdog()
    }

    // ---- START-phase slow-start notice ----

    private fun armStartWatchdog() {
        watchdogRunnable?.let { main.removeCallbacks(it) }
        val r = Runnable { startStalled() }
        watchdogRunnable = r
        main.postDelayed(r, START_WATCHDOG_MS)
    }

    private fun startStalled() {
        watchdogRunnable = null
        if (nrfStartStallAction(_progress.value.phase, pastStart) !=
            NrfStartStallAction.KEEP_WAITING) return
        // Do not fail, unregister, or send ACTION_ABORT here. Start DFU may already have erased the
        // application even though no progress callback arrived; only Nordic may finish/error now.
        set(NrfDfuPhase.FLASHING, 0,
            "The co-processor is still preparing. Keep the beacon powered and nearby…")
    }

    private fun registerDfuListener() {
        if (listenerRegistered) return
        DfuServiceListenerHelper.registerProgressListener(context, dfuListener)
        // The library reports the protocol blow-by-blow (bootloader response op codes and status
        // values, init-packet decisions, the exact reason it terminates) ONLY through this log
        // broadcast - none of it reaches logcat. Without it a bench failure shows as "connected,
        // then reset, then gone" with no cause. Debug builds only; it is noisy per-packet.
        if (tech.acab.app.BuildConfig.DEBUG) {
            DfuServiceListenerHelper.registerLogListener(context, dfuLogListener)
        }
        listenerRegistered = true
    }

    private fun unregisterDfuListener() {
        if (!listenerRegistered) return
        DfuServiceListenerHelper.unregisterProgressListener(context, dfuListener)
        if (tech.acab.app.BuildConfig.DEBUG) {
            DfuServiceListenerHelper.unregisterLogListener(context, dfuLogListener)
        }
        listenerRegistered = false
    }

    private val dfuLogListener = no.nordicsemi.android.dfu.DfuLogListener { _, level, message ->
        android.util.Log.i("AcabDfuLog", "[$level] $message")
    }

    private val dfuListener = object : DfuProgressListenerAdapter() {
        override fun onDfuProcessStarted(deviceAddress: String) {
            if (_progress.value.phase != NrfDfuPhase.FLASHING) return
            // Upload is underway: past the START handshake, stand the watchdog down.
            disarmStartWatchdog()
        }
        override fun onProgressChanged(deviceAddress: String, percent: Int, speed: Float,
                                       avgSpeed: Float, currentPart: Int, partsTotal: Int) {
            if (_progress.value.phase != NrfDfuPhase.FLASHING) return
            disarmStartWatchdog()
            set(NrfDfuPhase.FLASHING, percent.coerceIn(0, 100), "Sending to co-processor…")
        }
        override fun onDfuCompleted(deviceAddress: String) {
            if (_progress.value.phase != NrfDfuPhase.FLASHING) return
            unregisterDfuListener()
            clearPendingCallbacks()
            startConfirm()
        }
        override fun onDfuAborted(deviceAddress: String) {
            if (_progress.value.phase != NrfDfuPhase.FLASHING) return
            unregisterDfuListener()
            clearPendingCallbacks()
            set(NrfDfuPhase.FAILED, 0, "The co-processor update was stopped.")
        }
        override fun onError(deviceAddress: String, error: Int, errorType: Int, message: String?) {
            if (_progress.value.phase != NrfDfuPhase.FLASHING) return
            unregisterDfuListener()
            clearPendingCallbacks()
            set(NrfDfuPhase.FAILED, 0, "The co-processor update failed: ${message ?: "error $error"}. Reconnect and try again.")
        }
    }

    private fun disarmStartWatchdog() {
        if (pastStart) return
        pastStart = true
        watchdogRunnable?.let { main.removeCallbacks(it) }
        watchdogRunnable = null
    }

    /** After the flash, the nRF reboots into the new app and reports its version to the S3 over
     *  UART (emitted as nrfv). Only that report associates the generic legacy-DFU transfer with
     *  this beacon, so a missing target version is unconfirmed, never success. */
    private fun startConfirm() {
        if (!ownsLiveSession()) {
            set(NrfDfuPhase.FAILED, 100,
                "The transfer finished, but the initiating beacon is no longer connected, so it could not be confirmed.")
            return
        }
        set(NrfDfuPhase.CONFIRMING, 100, "Confirming update…")
        val deadline = System.currentTimeMillis() + 60_000
        var nextStatusReadAt = 0L
        fun tick() {
            if (_progress.value.phase != NrfDfuPhase.CONFIRMING) return
            if (!ownsLiveSession()) {
                set(NrfDfuPhase.FAILED, 100,
                    "The transfer finished, but the initiating beacon is no longer connected, so it could not be confirmed.")
                return
            }
            val now = System.currentTimeMillis()
            if (now >= nextStatusReadAt) {
                requestStatus()
                nextStatusReadAt = now + 5_000L
            }
            val v = statusProvider()?.nrfVersion
            if (v != null && v >= confirmTarget) { set(NrfDfuPhase.DONE, 100, "Co-processor updated."); return }
            if (now >= deadline) {
                set(NrfDfuPhase.FAILED, 100,
                    "The transfer finished, but this beacon did not report the new co-processor version. It was not confirmed; reconnect and try again.")
                return
            }
            main.postDelayed({ tick() }, 1_000)
        }
        tick()
    }

    private fun set(phase: NrfDfuPhase, pct: Int, message: String) {
        if (phase == NrfDfuPhase.FAILED || phase == NrfDfuPhase.DONE) {
            val terminalOwner = ownerSession
            if (phase == NrfDfuPhase.FAILED && triggerSent && terminalOwner != null) {
                quarantinedSession = terminalOwner
            }
            pendingZip?.delete()
            pendingZip = null
            clearPendingCallbacks()
            stopScan()
            closeCandidates.clear()
            triggerSent = false
            ownerSession = null
        }
        _progress.value = NrfDfuProgress(phase, pct, message)
    }

    private fun ownsLiveSession(): Boolean {
        val owner = ownerSession ?: return false
        return linkReady() && linkSessionProvider() == owner
    }
}

/** Pure target decision so ambiguity stays pinned without an Android BLE runtime. */
internal sealed interface DfuCandidateDecision {
    data object None : DfuCandidateDecision
    data class One(val address: String) : DfuCandidateDecision
    data object Ambiguous : DfuCandidateDecision
}

internal fun decideDfuCandidates(addresses: Collection<String>): DfuCandidateDecision =
    when (val unique = addresses.toSet()) {
        emptySet<String>() -> DfuCandidateDecision.None
        else -> if (unique.size == 1) DfuCandidateDecision.One(unique.first())
                else DfuCandidateDecision.Ambiguous
    }

internal fun preflightDfuClear(addresses: Collection<String>): Boolean = addresses.isEmpty()

internal fun nrfUpdateOfferAllowed(
    releaseEnabled: Boolean,
    nrf: NrfBuild?,
    buildLabel: String,
    liveLabel: String?,
    runningVersion: Int?,
    protocolVersion: Int?,
): Boolean = releaseEnabled && protocolVersion == DeviceStatus.SUPPORTED_PROTO_VERSION &&
    nrf != null && nrf.ota && nrf.hasVerifiableImage &&
    buildLabel.isNotBlank() && buildLabel == liveLabel && runningVersion != null &&
    nrf.version > runningVersion

internal fun nrfHandoffStatusIsFresh(
    protoVersion: Int,
    nrfUpdating: Boolean,
    statusRevision: Long,
    triggerRevision: Long,
    ownerSession: Long?,
    sourceSession: Long,
): Boolean = protoVersion == DeviceStatus.SUPPORTED_PROTO_VERSION && nrfUpdating &&
    statusRevision > triggerRevision &&
    ownerSession != null && ownerSession == sourceSession

/** Validate an application-only Nordic DFU package and extract its signed inner version. The
 * detached signature covers the complete zip, while this parser binds that package to the outer
 * version and refuses any extra firmware section or file. */
internal fun nrfPackageApplicationVersion(zipBytes: ByteArray): Long? = runCatching {
    var manifest: ByteArray? = null
    val entryNames = LinkedHashSet<String>()
    ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
        while (true) {
            val entry = zip.nextEntry ?: break
            val name = entry.name
            if (entry.isDirectory || name.isBlank() || name.contains('/') || name.contains('\\') ||
                !entryNames.add(name) || entry.method != ZipEntry.STORED) {
                return@runCatching null
            }
            if (name == "manifest.json") {
                if (manifest != null || entry.size > MAX_NRF_MANIFEST_BYTES) {
                    return@runCatching null
                }
                val out = java.io.ByteArrayOutputStream(
                    if (entry.size in 1..MAX_NRF_MANIFEST_BYTES) entry.size.toInt() else 1024,
                )
                val buffer = ByteArray(1024)
                var total = 0
                while (true) {
                    val read = zip.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > MAX_NRF_MANIFEST_BYTES) return@runCatching null
                    out.write(buffer, 0, read)
                }
                manifest = out.toByteArray()
            } else {
                if (entry.size > NrfBuild.MAX_PACKAGE_BYTES) return@runCatching null
                val buffer = ByteArray(16 * 1024)
                var total = 0L
                while (true) {
                    val read = zip.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > NrfBuild.MAX_PACKAGE_BYTES) return@runCatching null
                }
                if (total == 0L) return@runCatching null
            }
        }
    }
    val raw = manifest ?: return@runCatching null
    val packageManifest = org.json.JSONObject(raw.toString(Charsets.UTF_8))
        .getJSONObject("manifest")
    if (packageManifest.has("softdevice") || packageManifest.has("bootloader") ||
        packageManifest.has("softdevice_bootloader")) return@runCatching null
    val application = packageManifest.getJSONObject("application")
    val binFile = application.getString("bin_file")
    val datFile = application.getString("dat_file")
    if (binFile.isBlank() || datFile.isBlank() || binFile == datFile ||
        binFile.contains('/') || binFile.contains('\\') ||
        datFile.contains('/') || datFile.contains('\\') ||
        entryNames != linkedSetOf("manifest.json", binFile, datFile)) return@runCatching null
    val init = application.getJSONObject("init_packet_data")
    if (!init.has("application_version")) return@runCatching null
    val manifestVersion = init.getLong("application_version")
        .takeIf { it in 0..0xffff_ffffL } ?: return@runCatching null
    val initPacket = storedRootZipEntry(
        zipBytes, datFile, MAX_NRF_INIT_PACKET_BYTES,
    ) ?: return@runCatching null
    manifestVersion.takeIf { legacyDfuInitPacketVersion(initPacket) == it }
}.getOrNull()

private const val MAX_NRF_MANIFEST_BYTES = 64 * 1024L
private const val MAX_NRF_INIT_PACKET_BYTES = 64 * 1024

/** Legacy Nordic init packets bind application_version as a little-endian UInt32 at bytes 4..7. */
internal fun legacyDfuInitPacketVersion(bytes: ByteArray): Long? {
    if (bytes.size !in 8..MAX_NRF_INIT_PACKET_BYTES) return null
    return (bytes[4].toLong() and 0xffL) or
        ((bytes[5].toLong() and 0xffL) shl 8) or
        ((bytes[6].toLong() and 0xffL) shl 16) or
        ((bytes[7].toLong() and 0xffL) shl 24)
}

private fun storedRootZipEntry(zipBytes: ByteArray, wanted: String, maxBytes: Int): ByteArray? =
    try {
        ZipInputStream(ByteArrayInputStream(zipBytes)).use { zip ->
            var found: ByteArray? = null
            while (found == null) {
                val entry = zip.nextEntry ?: break
                if (entry.name != wanted) continue
                if (entry.isDirectory || entry.method != ZipEntry.STORED ||
                    entry.size > maxBytes) return@use null
                val out = java.io.ByteArrayOutputStream(
                    if (entry.size in 1..maxBytes.toLong()) entry.size.toInt() else 64,
                )
                val buffer = ByteArray(1024)
                var total = 0
                while (true) {
                    val read = zip.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > maxBytes) return@use null
                    out.write(buffer, 0, read)
                }
                found = out.toByteArray()
            }
            found
        }
    } catch (_: Exception) {
        null
    }
