package tech.acab.app.ui

import android.Manifest
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Landscape
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Contrast
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.mapSaver
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import tech.acab.app.model.bufferHealthNotices
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import tech.acab.app.MainActivity
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.AlertMode
import tech.acab.app.ble.CombinedUpdatePhase
import tech.acab.app.ble.CombinedUpdateProgress
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.isBoardBackedMute
import tech.acab.app.ble.isFirmwareVersionOlder
import tech.acab.app.ble.unrepresentedBoardRuleCount
import tech.acab.app.model.DeviceStatus
import tech.acab.app.model.DeviceType
import tech.acab.app.net.FirmwareBuild
import tech.acab.app.net.FirmwareManifest
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.ContrastMode
import tech.acab.app.ui.theme.tone
import tech.acab.app.widget.BeaconsWidgetProvider

private val NotificationToggleMapSaver = mapSaver<Map<Int, Boolean>>(
    save = { values -> values.mapKeys { (key, _) -> key.toString() } },
    restore = { values -> values.mapKeys { (key, _) -> key.toInt() }.mapValues { it.value as Boolean } },
)

internal fun shouldHandleOpenToken(token: Int, handledWatermark: Int): Boolean =
    token > handledWatermark

/** A retained/key-mismatched log must remain erasable even when offline capture is switched off. */
internal fun shouldOfferBufferClear(
    isDemoMode: Boolean,
    bufferOn: Boolean,
    bufferedCount: Int,
    keyMismatch: Boolean,
    wiping: Boolean,
): Boolean = !isDemoMode && (bufferOn || bufferedCount > 0 || keyMismatch || wiping)

internal data class BufferClearConfirmationCopy(val title: String, val message: String)

internal fun bufferClearConfirmationCopy(
    bufferedCount: Int,
    keyMismatch: Boolean,
): BufferClearConfirmationCopy = if (keyMismatch) {
    BufferClearConfirmationCopy(
        title = "Erase the board’s retained offline history and transfer future buffering to this phone?",
        message = "This permanently erases the board’s preserved offline history. Any history only readable by the originating phone will be permanently lost. The app will then install this phone’s buffer key for future offline transfers.",
    )
} else {
    BufferClearConfirmationCopy(
        title = "Erase $bufferedCount buffered detection${if (bufferedCount == 1) "" else "s"} on the board?",
        message = "This permanently wipes the board's offline log and can't be undone. Detections already synced to this phone stay in your log; anything not yet synced is lost.",
    )
}

/** Latest published beacon-board firmware; last-resort offline fallback for an unrecognized
 *  board label (known boards read their per-board version from the manifest). Bump on release. */
private const val LATEST = "2.0.7"

/** Which config drawer section is open. Exactly one at a time (proposal 1g). */
private enum class ConfigSection { NONE, FIRMWARE, RADIOS, DETECTORS, ALERTS, NOTIFY, DISPLAY, DRIVE, DESERT, LED }

/**
 * One optimistic board control, described once. Three sites derive everything from the list of
 * these (the status-frame sync, the write-timeout revert, and the demo-crossing pending reset),
 * so a control's caught-up compare and its restore expression cannot drift apart across
 * hand-maintained copies. Mirrors iOS's PendingControl mechanism. Accessors are lambdas rather
 * than MutableStates so the screen's delegated `var`s (used all over the UI below) stay as-is.
 * Volume is deliberately NOT in the table: its drag shield and roundToInt echo compare are real
 * semantic differences, not copy-paste variance.
 */
private class BoardControl(
    /** User-facing name for the "didn't apply" timeout banner. */
    val label: String,
    val pending: () -> Boolean,
    val setPending: (Boolean) -> Unit,
    /** True when this status frame matches the local value (the board has caught up). */
    val caughtUp: (DeviceStatus) -> Boolean,
    /** Adopt the frame's value; keep the local value when there is no frame (timeout with no status). */
    val restore: (DeviceStatus?) -> Unit,
)

/** Device tab: board status, scan radios, detectors, and the alert buzzer. */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun DeviceScreen(
    ble: AcabBleManager,
    openDetectorsToken: Int = 0,
    openHelpToken: Int = 0,
    openReadinessToken: Int = 0,
    locationGranted: Boolean = false,
    onRequestLocation: () -> Unit = {},
) {
    val status by ble.status.collectAsState()
    val logDetections by ble.logDetections.collectAsState()
    val name by ble.deviceName.collectAsState()
    val ignored by ble.ignored.collectAsState()
    val watched by ble.watched.collectAsState()
    val mode by ble.alertMode.collectAsState()
    val driveMode by ble.driveMode.collectAsState()
    val driveModeWanted by ble.driveModeWanted.collectAsState()
    val redactLock by ble.redactLockScreen.collectAsState()
    // One value drives the whole firmware card now: the combined S3-then-nRF update flow.
    val combined by ble.combinedProgress.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val context = LocalContext.current

    // The firmware manifest is the source of truth for "latest" and the in-app OTA gate; the
    // hardcoded LATEST is only an offline fallback. Collect the singleton's flow directly.
    val manifest by remember { FirmwareManifest.getInstance(context) }.manifest.collectAsState()

    // POST_NOTIFICATIONS (Android 13+) and the app-level notification switch both determine
    // whether Live Mode can actually appear. Refresh this whenever Settings returns to foreground.
    var notifGranted by remember {
        mutableStateOf(DetectionNotifier.liveChannelDeliverable(context))
    }
    // Whether the system will actually deliver the phone-notification categories, HELD rather
    // than asked per recomposition: mutedBySystem asks the system three separate questions (the
    // post permission, the app-level switch, the channel's importance), and the Notifications
    // fold re-runs its content with every board status frame. Same rule StatusScreen states for
    // the finish-setup card, and the same pattern as notifGranted above. Exactly two things can
    // move the answer - ON_RESUME, because system settings and the permission dialog both pause
    // the activity, and a category switch in this card, because mutedBySystem answers false
    // while every category is off. Both refresh it below.
    var notifMuted by remember { mutableStateOf(DetectionNotifier.mutedBySystem(context)) }
    val notifLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) {
        notifGranted = DetectionNotifier.liveChannelDeliverable(context)
        notifMuted = DetectionNotifier.mutedBySystem(context)
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    val widgetManager = remember { AppWidgetManager.getInstance(context) }
    val widgetProvider = remember { ComponentName(context, BeaconsWidgetProvider::class.java) }
    var widgetAdded by remember {
        mutableStateOf(widgetManager.getAppWidgetIds(widgetProvider).isNotEmpty())
    }
    var widgetPinSupported by remember {
        mutableStateOf(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            widgetManager.isRequestPinAppWidgetSupported)
    }
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                notifGranted = DetectionNotifier.liveChannelDeliverable(context)
                notifMuted = DetectionNotifier.mutedBySystem(context)
                widgetAdded = widgetManager.getAppWidgetIds(widgetProvider).isNotEmpty()
                widgetPinSupported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                    widgetManager.isRequestPinAppWidgetSupported
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    /** Phone-notification toggles mirrored into state so the switches animate. The source of truth
     *  is DetectionNotifier's prefs; keyed by DeviceType.raw. */
    var notifyOn by rememberSaveable(stateSaver = NotificationToggleMapSaver) {
        mutableStateOf(mapOf<Int, Boolean>())
    }
    // Sample-mode flips are previews: they shadow notifyOn only while the tour runs and are
    // dropped on the demo transition below, so exploring the tour cannot rewrite the real
    // notifier state (mirrors iOS SamplePhoneSettings). Plain remember - a preview owes
    // nothing to rotation.
    var sampleNotifyOn by remember { mutableStateOf(mapOf<Int, Boolean>()) }
    /** One read path for the notify switches + kicker, so both honor the sample shadow. */
    val notifyIsOn: (DeviceType) -> Boolean = { t ->
        (if (demo) sampleNotifyOn[t.raw] else null)
            ?: notifyOn[t.raw] ?: DetectionNotifier.isEnabled(context, t)
    }
    /** Ask on the FIRST enable, with obvious context, rather than at launch. */
    val askPostPermission: () -> Unit = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && !hasNotifPermission(context)) {
            notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    // Keep a local copy of each toggle so flipping one sticks until the next status
    // frame, instead of snapping back to the old value mid-write. Each toggle also
    // carries a pending flag (set on a user flip, mirrors iOS): a status frame that
    // predates the write must not overwrite a just-flipped switch.
    var bleOn by rememberSaveable { mutableStateOf(status?.ble == true) }
    var blePending by rememberSaveable { mutableStateOf(false) }
    var wifiOn by rememberSaveable { mutableStateOf(status?.wifi == true) }
    var wifiPending by rememberSaveable { mutableStateOf(false) }
    var wifiEco by rememberSaveable { mutableStateOf(status?.wifiEco ?: 0) }   // WiFi eco seconds (0/3/7/15)
    var wifiEcoPending by rememberSaveable { mutableStateOf(false) }
    var flockOn by rememberSaveable { mutableStateOf(status?.flock != false) }   // absent = on
    var flockPending by rememberSaveable { mutableStateOf(false) }
    var droneOn by rememberSaveable { mutableStateOf(status?.drone != false) }   // absent = on
    var dronePending by rememberSaveable { mutableStateOf(false) }
    var droneOuiOn by rememberSaveable { mutableStateOf(status?.droui == true) }  // OUI fallback, default off
    var droneOuiPending by rememberSaveable { mutableStateOf(false) }
    var bodyCamOn by rememberSaveable { mutableStateOf(status?.bodyCam == true) }
    var bodyCamPending by rememberSaveable { mutableStateOf(false) }
    // Motorola-OUI proxy, the sub-toggle under body cams. Seed on: pre-split firmware has it
    // fused to the category, and the board ships it enabled, so on is the honest starting read.
    var motoOn by rememberSaveable { mutableStateOf(status?.moto != false) }
    var motoPending by rememberSaveable { mutableStateOf(false) }
    var trackerOn by rememberSaveable { mutableStateOf(status?.tracker == true) }
    var trackerPending by rememberSaveable { mutableStateOf(false) }
    // Seed from the firmware default enable state (glasses ships ON), not off, so the detectors
    // kicker doesn't flicker its count when the first status frame lands. Matches iOS. Once a
    // frame arrives the LaunchedEffect below syncs it to the board's real value.
    var glassesOn by rememberSaveable { mutableStateOf(status?.glasses ?: true) }
    var glassesPending by rememberSaveable { mutableStateOf(false) }
    var netcamOn by rememberSaveable { mutableStateOf(status?.ncam == true) }   // IP-camera OUI on wifi, default off
    var netcamPending by rememberSaveable { mutableStateOf(false) }
    var bufferOn by rememberSaveable { mutableStateOf(status?.bufOn == true) }
    var bufferPending by rememberSaveable { mutableStateOf(false) }
    var confirmEraseBuffer by remember { mutableStateOf(false) }   // gate the destructive board-buffer erase
    var confirmPowerOff by remember { mutableStateOf(false) }      // gate the rev-B app-driven power-off
    var lightsOut by rememberSaveable { mutableStateOf(status?.ledOn == false) }   // LED fully dark
    var ledPending by rememberSaveable { mutableStateOf(false) }
    var desertOn by rememberSaveable { mutableStateOf(status?.desertMode == true) }
    var desertPending by rememberSaveable { mutableStateOf(false) }
    // Master volume rides here (not inside BuzzerCard) so the Alerts kicker reads the live value,
    // and carries the same pending hold as the toggles: a status frame mid-drag (or the echo of
    // the previous commit) must not snap the thumb to the board's stale volume. Mirrors iOS.
    var masterVolume by rememberSaveable { mutableFloatStateOf((status?.volume ?: 0).toFloat()) }
    var volumePending by rememberSaveable { mutableStateOf(false) }
    // volumePending arms only at COMMIT (release), matching iOS: armed at first movement, a slow
    // drag outlives the 10s echo window and false-reverts under the user's finger. The drag
    // therefore needs its own shield so mid-drag status frames cannot snap the thumb. Plain
    // remember - rotation kills the gesture anyway.
    var volumeDragging by remember { mutableStateOf(false) }
    var sampleAlertModeName by rememberSaveable { mutableStateOf(mode.name) }
    var sampleLiveWanted by rememberSaveable { mutableStateOf(false) }
    var sampleRedactLock by rememberSaveable { mutableStateOf(redactLock) }
    var settingFeedback by remember { mutableStateOf<String?>(null) }

    // The single source of truth for every table-driven board control: label, pending flag,
    // caught-up compare, restore. remember with no keys is sound because the lambdas capture the
    // state DELEGATES (stable across recompositions), never a snapshot of their values.
    val boardControls = remember {
        listOf(
            BoardControl("Bluetooth scanning", { blePending }, { blePending = it },
                { s -> s.ble == bleOn }, { s -> bleOn = s?.ble ?: bleOn }),
            BoardControl("Wi-Fi scanning", { wifiPending }, { wifiPending = it },
                { s -> s.wifi == wifiOn }, { s -> wifiOn = s?.wifi ?: wifiOn }),
            BoardControl("Wi-Fi Eco", { wifiEcoPending }, { wifiEcoPending = it },
                { s -> s.wifiEco == wifiEco }, { s -> wifiEco = s?.wifiEco ?: wifiEco }),
            BoardControl("ALPR detection", { flockPending }, { flockPending = it },
                { s -> s.flock == flockOn }, { s -> flockOn = s?.flock ?: flockOn }),
            BoardControl("Drone detection", { dronePending }, { dronePending = it },
                { s -> s.drone == droneOn }, { s -> droneOn = s?.drone ?: droneOn }),
            BoardControl("Non-broadcasting drone detection", { droneOuiPending }, { droneOuiPending = it },
                { s -> s.droui == droneOuiOn }, { s -> droneOuiOn = s?.droui ?: droneOuiOn }),
            BoardControl("Body-camera detection", { bodyCamPending }, { bodyCamPending = it },
                { s -> s.bodyCam == bodyCamOn }, { s -> bodyCamOn = s?.bodyCam ?: bodyCamOn }),
            BoardControl("Motorola vendor detection", { motoPending }, { motoPending = it },
                { s -> s.moto == motoOn }, { s -> motoOn = s?.moto ?: motoOn }),
            BoardControl("Tracker detection", { trackerPending }, { trackerPending = it },
                { s -> s.tracker == trackerOn }, { s -> trackerOn = s?.tracker ?: trackerOn }),
            BoardControl("Recording-glasses detection", { glassesPending }, { glassesPending = it },
                { s -> s.glasses == glassesOn }, { s -> glassesOn = s?.glasses ?: glassesOn }),
            BoardControl("Network-camera detection", { netcamPending }, { netcamPending = it },
                { s -> s.ncam == netcamOn }, { s -> netcamOn = s?.ncam ?: netcamOn }),
            BoardControl("Offline buffer", { bufferPending }, { bufferPending = it },
                { s -> s.bufOn == bufferOn }, { s -> bufferOn = s?.bufOn ?: bufferOn }),
            // The one inverted control: the switch is "lights out" but the board reports ledOn.
            BoardControl("Board LED", { ledPending }, { ledPending = it },
                { s -> (!s.ledOn) == lightsOut }, { s -> lightsOut = s?.ledOn?.not() ?: lightsOut }),
            BoardControl("Desert mode", { desertPending }, { desertPending = it },
                { s -> s.desertMode == desertOn }, { s -> desertOn = s?.desertMode ?: desertOn }),
        )
    }

    // Sample controls intentionally have no board echo. Clear any real-board pending state when
    // crossing that boundary so sample exploration cannot arm a false timeout after Exit - but
    // ONLY on a real crossing: LaunchedEffect(demo) also restarts on every re-entry into
    // composition (tab bounce, rotation), and clearing then would wipe the just-restored pending
    // flags and disarm the revert/banner for any write whose echo window spans the bounce.
    var wasDemo by rememberSaveable { mutableStateOf(demo) }
    LaunchedEffect(demo) {
        if (demo == wasDemo) return@LaunchedEffect
        wasDemo = demo
        boardControls.forEach { it.setPending(false) }
        volumePending = false
        settingFeedback = null
        sampleNotifyOn = emptyMap()   // preview flips must not leak into the next tour either
    }

    // Re-sync the local copies whenever a fresh status frame lands, but only overwrite
    // a toggle when no flip is pending, or when the board has caught up (the frame
    // matches the local value), which also clears the pending flag.
    LaunchedEffect(status, demo) {
        // Sample choices have no board echo by design. On tab re-entry the same canned status is
        // emitted again; treating it as an acknowledgement reset every preview toggle to its seed.
        if (demo) return@LaunchedEffect
        status?.let { s ->
            for (c in boardControls) {
                if (!c.pending() || c.caughtUp(s)) { c.restore(s); c.setPending(false) }
            }
            // The drag shield is absolute: even a matching frame must not rewrite the thumb
            // mid-drag (the write would quantize the float position under the user's finger).
            if (!volumeDragging && (!volumePending || s.volume == masterVolume.roundToInt())) {
                masterVolume = s.volume.toFloat(); volumePending = false
            }
        }
    }

    fun settingTimedOut(label: String) {
        settingFeedback = "$label didn't apply. The beacon's previous setting was restored."
    }
    for (c in boardControls) {
        SettingWriteTimeout(c.pending() && !demo) {
            c.restore(status); c.setPending(false); settingTimedOut(c.label)
        }
    }
    SettingWriteTimeout(volumePending && !demo) {
        masterVolume = (status?.volume ?: masterVolume.roundToInt()).toFloat()
        volumePending = false
        settingTimedOut("Alert volume")
    }
    LaunchedEffect(settingFeedback) {
        if (settingFeedback != null) {
            delay(6_000L)
            settingFeedback = null
        }
    }

    // --- proposal 1g state: one config section open at a time; firmware + sub-screens ---
    // rememberSaveable, not remember: with the tab shell now preserving per-tab state, the open
    // drawer/sub-screen must survive a tab switch or rotation like everything else here does.
    var openSection by rememberSaveable { mutableStateOf(ConfigSection.NONE) }
    var managedOpen by rememberSaveable { mutableStateOf(false) }
    var helpOpen by rememberSaveable { mutableStateOf(false) }
    var aboutOpen by rememberSaveable { mutableStateOf(false) }
    val detectorsRequester = remember { BringIntoViewRequester() }
    val readinessRequester = remember { BringIntoViewRequester() }
    var handledDetectorsToken by rememberSaveable { mutableStateOf(0) }
    LaunchedEffect(openDetectorsToken) {
        if (shouldHandleOpenToken(openDetectorsToken, handledDetectorsToken)) {
            handledDetectorsToken = openDetectorsToken
            openSection = ConfigSection.DETECTORS
            withFrameNanos { }
            withFrameNanos { }
            detectorsRequester.bringIntoView()
        }
    }
    var handledHelpToken by rememberSaveable { mutableStateOf(0) }
    LaunchedEffect(openHelpToken) {
        if (shouldHandleOpenToken(openHelpToken, handledHelpToken)) {
            handledHelpToken = openHelpToken
            helpOpen = true
        }
    }
    var handledReadinessToken by rememberSaveable { mutableStateOf(0) }
    LaunchedEffect(openReadinessToken) {
        if (shouldHandleOpenToken(openReadinessToken, handledReadinessToken)) {
            handledReadinessToken = openReadinessToken
            withFrameNanos { }
            withFrameNanos { }
            readinessRequester.bringIntoView()
        }
    }
    // The contribution composer's whole flow lives in an activity-scoped ViewModel so a
    // mid-capture tab switch, back press, resize, or recreation cannot discard the capture.
    val contribVm: ContributionViewModel = viewModel()
    fun toggleSection(s: ConfigSection) { openSection = if (openSection == s) ConfigSection.NONE else s }

    // Firmware: the SAME update-available check FirmwareCard uses (manifest entry vs installed).
    // An update exists -> crimson banner; otherwise firmware is a plain "UP TO DATE" fold row.
    val fwEntry = manifest.build(status?.firmwareLabel)
    val fwLatest = fwEntry?.version ?: LATEST
    val fwInstalled = status?.version
    // BELT-AND-BRACES OTA REVISION GATE. Android had none at all: it parsed no `rev` and applied
    // no revision check. iOS had the LOGIC but not the protection: its revisionMatchesManifest was
    // referenced only from `otaEligible`, which nothing ever read, so the gate was dead code there
    // while every update actually offered went through combinedStale, which did not check it.
    // Both platforms now apply it on their live paths. An earlier version of this comment claimed
    // iOS was already protected; it was not, and that claim is what hid the hole.
    //
    // The PRIMARY defence is shared and unchanged: rev-B firmware reports a distinct fw label
    // ("beacon board rev-B", set in platformio.ini) and the manifest is KEYED by that label, so a
    // rev-B board cannot resolve the rev-A entry at all. This second check catches the case where
    // someone re-unifies the labels or hand-edits the manifest: if the board TELLS us its
    // revision, the entry we are about to flash from has to agree.
    //
    // A wrong-image flash parks the unit after every boot and is USB-recovery only, so a false
    // refusal is by far the cheaper error. "Not told" never blocks: docs/ble-protocol.md is
    // explicit that an absent `rev` means absent, never rev-A.
    val boardRev = status?.boardRev
    val revisionMatchesManifest =
        if (boardRev != "A" && boardRev != "B") true
        else (status?.firmwareLabel?.lowercase()?.contains("rev-b") == true) == (boardRev == "B")
    val fwOutdated = fwInstalled != null && isFirmwareVersionOlder(fwInstalled, fwLatest) &&
        revisionMatchesManifest
    // Either radio behind (S3 OR nRF); a terminal we keep on screen (done / failed / partial).
    val combinedStale = (fwEntry?.let { ble.combinedUpdateStale(it) } ?: false) &&
        revisionMatchesManifest
    // Which leg is behind, so the offer can name it. combinedStale is the OR of the two; without
    // this the card said "Update available: v$latest" for a co-processor-only offer.
    val s3Stale = (fwEntry?.let { ble.s3UpdateStale(it) } ?: false) && revisionMatchesManifest
    val combinedTerminal = combined.phase == CombinedUpdatePhase.DONE ||
        combined.phase == CombinedUpdatePhase.FAILED || combined.phase == CombinedUpdatePhase.PARTIAL
    // The crimson banner promotes only when the S3 firmware is behind, or the flow is live/just
    // finished; an nRF-only update stays a fold row (kicker "UPDATE READY"). Mirrors iOS updateExists.
    val showBanner = fwOutdated || combined.isRunning || combinedTerminal
    // Collapsible even mid-update (matches iOS): the crimson banner header stays on screen the
    // whole flow (showBanner includes isRunning), so progress/Cancel is one re-tap away.
    val fwExpanded = openSection == ConfigSection.FIRMWARE

    // Today's firmware card verbatim, reused as banner / fold-row expanded content.
    val firmwareCard: @Composable () -> Unit = {
        FirmwareCard(
            installed = status?.version,
            entry = fwEntry,
            combined = combined,
            combinedStale = combinedStale,
            s3Stale = s3Stale,
            onCombinedUpdate = { ble.startCombinedUpdate(it) },
            onCombinedCancel = { ble.cancelCombinedUpdate() },
            onCombinedDismiss = { ble.dismissCombinedUpdate() },
            onFlash = { context.openUrl(it) },
        )
    }

    // Sample settings are previews. Board-backed toggles already live in local state; mirror the
    // three phone/persisted settings locally too so exploring the tour cannot rewrite real setup.
    val shownAlertMode = if (demo) {
        runCatching { AlertMode.valueOf(sampleAlertModeName) }.getOrDefault(AlertMode.BUZZER)
    } else mode
    val shownLiveWanted = if (demo) sampleLiveWanted else driveModeWanted
    val shownRedactLock = if (demo) sampleRedactLock else redactLock

    // Live-state kickers (terse ALL-CAPS), computed from the same status/prefs the cards read.
    val radiosKicker = when {
        bleOn && wifiOn -> "BLE + WI-FI ON"
        bleOn -> "BLE ON · WI-FI OFF"
        wifiOn -> "WI-FI ON · BLE OFF"
        else -> "ALL RADIOS OFF"
    }
    val detOn = listOf(flockOn, droneOn, bodyCamOn, trackerOn, glassesOn, netcamOn).count { it }
    // Body cam is a shipped detector now, not experimental; only glasses still carries the tag.
    val expOn = listOf(glassesOn).count { it }
    // The EXP segment always renders (even "0 EXP"), same as iOS, so the kicker shape is stable.
    val detectorsKicker = "$detOn ON · $expOn EXP · TRACKERS ${if (trackerOn) "ON" else "OFF"}"
    val alertsKicker = when (shownAlertMode) {
        AlertMode.BUZZER -> "BUZZER · VOLUME ${masterVolume.toInt()}"
        AlertMode.VIBRATE -> "VIBRATE · PHONE BUZZES"
        AlertMode.SILENT -> "SILENT"
    }
    // "3 ON" / "OFF", so the collapsed row says whether anything will interrupt you.
    val displayKicker = when {
        ContrastMode.forced -> "HIGHER CONTRAST · ALWAYS"
        ContrastMode.systemWantsHigher -> "HIGHER CONTRAST · FROM ANDROID"
        else -> "DEFAULT CONTRAST"
    }
    val notifyKicker = DetectionNotifier.NOTIFIABLE.count { notifyIsOn(it) }
        .let { if (it == 0) "OFF" else "$it ON" }
    val driveKicker = "LIVE ${if (shownLiveWanted) "ON" else "OFF"} · COUNTS ${if (shownRedactLock) "PRIVATE" else "VISIBLE"}"
    val desertBufKicker = when {
        desertOn && bufferOn -> "BOTH ON"
        desertOn -> "DESERT ON · BUFFER OFF"
        bufferOn -> "BUFFER ON · DESERT OFF"
        else -> "BOTH OFF"
    }
    val ledKicker = if (lightsOut) "LIGHTS OUT" else "HEARTBEAT ON"
    val boardOnlyMuteCount = unrepresentedBoardRuleCount(
        boardCount = status?.ignoreCount ?: 0,
        localBoardBackedCount = ignored.count(::isBoardBackedMute),
    )
    val managedKicker = buildString {
        append("${watched.size} WATCHED · ${status?.watchCount ?: 0} ON BOARD · ${ignored.size} MUTED")
        if (boardOnlyMuteCount > 0) append(" · $boardOnlyMuteCount BOARD ONLY")
    }

    // The config cards, VERBATIM, reused as the expanded content of their fold rows.
    val radiosContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("SCAN RADIOS")
            ToggleRow("bluetooth", "ALPR · drone · trackers", checked = bleOn, pending = blePending && !demo) {
                bleOn = it; blePending = true; if (!demo) ble.setBleScan(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("Wi-Fi", "2.4 GHz · ALPR · drone RID", checked = wifiOn, pending = wifiPending && !demo) {
                wifiOn = it; wifiPending = true; if (!demo) ble.setWifiScan(it)
            }
            // Eco: battery boards only (the board reports "bat" only with the sense divider), and
            // only while Wi-Fi is on. Duty-cycles the Wi-Fi RX to stretch runtime; Bluetooth is
            // untouched. Honest tradeoff line under the pills.
            if (wifiOn && status?.battery != null) {
                HorizontalDivider(color = Acab.line)
                Column(Modifier.padding(top = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Kicker("WI-FI ECO")
                        Spacer(Modifier.weight(1f))
                        if (wifiEcoPending && !demo) {
                            CircularProgressIndicator(color = Acab.accent, strokeWidth = 2.dp,
                                modifier = Modifier.size(14.dp))
                            Spacer(Modifier.size(7.dp))
                        }
                        Text(if (wifiEco == 0) "always on" else "sleeps ${wifiEco}s / sweep",
                            color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        listOf(0 to "MAX", 3 to "3s", 7 to "7s", 15 to "15s").forEach { (v, label) ->
                            val sel = wifiEco == v
                            Box(
                                Modifier.weight(1f)
                                    .minimumInteractiveComponentSize()
                                    .clip(CircleShape)
                                    .then(if (sel) Modifier.background(Acab.accent) else Modifier.border(1.dp, Acab.line, CircleShape))
                                    .selectable(
                                        selected = sel,
                                        enabled = !wifiEcoPending || demo,
                                        role = Role.RadioButton,
                                        onClick = {
                                            wifiEco = v
                                            wifiEcoPending = true
                                            if (!demo) ble.setWifiEco(v)
                                        },
                                    )
                                    .padding(vertical = 7.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(label, color = if (sel) Acab.onAccent else Acab.dim,
                                    fontSize = 11.sp, fontWeight = FontWeight.Bold,
                                    letterSpacing = 0.5.sp, fontFamily = Acab.mono)
                            }
                        }
                    }
                    Text("stretches battery by sweeping Wi-Fi less often. you may miss a Wi-Fi-only camera between sweeps; Bluetooth detection is unaffected.",
                        color = Acab.faint, fontSize = 9.5.sp, fontFamily = Acab.mono)
                }
            }
        }
    }
    val detectorsContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("DETECTORS")
            ToggleRow("alpr radio signals", "flock, raven, when they broadcast over bluetooth or 2.4 GHz wifi · many installs now stay silent",
                checked = flockOn, pending = flockPending && !demo) {
                flockOn = it; flockPending = true; if (!demo) ble.setFlock(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("drones (remote ID)", "FAA remote ID · operator location",
                checked = droneOn, pending = dronePending && !demo) {
                droneOn = it; dronePending = true; if (!demo) ble.setDrone(it)
            }
            // Subordinate to the drones toggle: inset + shown-disabled while drone detection is
            // off, so the sub-option stays discoverable (mirrors iOS). Default off - it can flag a
            // stationary Parrot gadget as a drone, so the user opts in knowing it may false-positive.
            ToggleRow("non-broadcasting drones", "OUI match only, off by default, may false-positive",
                checked = droneOuiOn, enabled = droneOn, pending = droneOuiPending && !demo,
                modifier = Modifier.padding(start = 22.dp).alpha(if (droneOn) 1f else 0.4f)) {
                droneOuiOn = it; droneOuiPending = true; if (!demo) ble.setDroneOuiEnabled(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("body cams", "Axon · Utility BodyWorn · Motorola vendor match",
                checked = bodyCamOn, pending = bodyCamPending && !demo) {
                bodyCamOn = it; bodyCamPending = true; if (!demo) ble.setBodyCam(it)
            }
            // Subordinate to the body-cam toggle, same shape as the drone-OUI row above:
            // classification needs BOTH, so it sits inset + disabled while the category is off.
            // Hidden entirely only on firmware that predates the split (motoSupported false),
            // where the proxy is welded to the category and the board would just ignore the
            // write. Off by default it is NOT - the board ships it on, and it's the noisy half
            // of the category, which is the whole reason it gets its own switch.
            if (status?.motoSupported == true) {
                // Say what the switch matches and what it costs, not "off still detects X", which
                // reads as a riddle. Kept in step with the iOS row.
                ToggleRow("motorola solutions", "vendor match only · their radios and docks too",
                    checked = motoOn, enabled = bodyCamOn, pending = motoPending && !demo,
                    modifier = Modifier.padding(start = 22.dp).alpha(if (bodyCamOn) 1f else 0.4f)) {
                    motoOn = it; motoPending = true; if (!demo) ble.setMotorolaOui(it)
                }
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("bluetooth trackers", "AirTag · Tile · SmartTag · opt-in",
                checked = trackerOn, pending = trackerPending && !demo) {
                trackerOn = it; trackerPending = true; if (!demo) ble.setTracker(it)
            }
            HorizontalDivider(color = Acab.line)
            ToggleRow("recording glasses", "Ray-Ban / Oakley Meta · Snap · Vuzix · Luxottica · experimental",
                checked = glassesOn, exp = true, pending = glassesPending && !demo) {
                glassesOn = it; glassesPending = true; if (!demo) ble.setGlasses(it)
            }
            HorizontalDivider(color = Acab.line)
            // Opt-in + default off: it enables 802.11 DATA-frame source-MAC inspection (off by default).
            // Honest copy - it matches known IP-camera BRANDS on the network, so it can't find every
            // camera and NEVER claims a "hidden camera". Mirrors the drone-OUI opt-in.
            ToggleRow("network cameras", "known IP-camera brands on wifi, opt-in, cannot find every camera",
                checked = netcamOn, pending = netcamPending && !demo) {
                netcamOn = it; netcamPending = true; if (!demo) ble.setNetcamEnabled(it)
            }
        }
    }
    val bufferContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("OFFLINE BUFFER")
            // Keep storage/lifecycle failures visible at the control the user is being asked to
            // trust. The Logbook shows the same notices beside the retained evidence.
            status?.bufferHealthNotices?.forEach { BufferHealthBanner(it) }
            // While a deferred board-side erase is still sweeping, the bufCount is stale, so say
            // "clearing…" instead of a leftover number until the wipe settles.
            val bufferSubtitle = if (status?.wiping == true) "clearing buffer…"
                else status?.bufCount?.takeIf { bufferOn }?.let { "$it buffered · replays on reconnect" }
                    ?: "board records while phone is away"
            ToggleRow(
                "store detections offline",
                bufferSubtitle,
                checked = bufferOn,
                pending = bufferPending && !demo,
            ) {
                bufferOn = it; bufferPending = true; if (!demo) ble.setBuffer(it)
            }
            // Sample mode must never expose a real-board destructive action. `clearBufferLog()`
            // also resets this phone's replay cursor even when there is no GATT connection, so
            // merely previewing the sample settings cannot safely offer ERASE.
            if (shouldOfferBufferClear(
                    isDemoMode = demo,
                    bufferOn = bufferOn,
                    bufferedCount = status?.bufCount ?: 0,
                    keyMismatch = status?.bufferKeyMismatch == true,
                    wiping = status?.wiping == true,
                )) {
                // Erase the board-side buffer only. Separate from the log screen's clear, which
                // just empties this phone's copy, this wipes what the board stored while away.
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("buffered log", color = Acab.text, fontSize = 14.sp, fontFamily = Acab.display)
                        // While the board is still sweeping a deferred erase, say so rather than
                        // inviting another erase against an about-to-be-zero count.
                        Text(if (status?.wiping == true) "clearing buffer…"
                            else "erase what the board stored while away",
                            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                    }
                    if (status?.wiping == true) {
                        // Mid-wipe the ERASE pill swaps for a non-interactive chip (mirrors iOS):
                        // the confirm dialog would only show a stale count and fire a redundant erase.
                        Text(
                            "CLEARING",
                            color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono,
                            fontWeight = FontWeight.Bold, letterSpacing = 1.sp,
                            modifier = Modifier
                                .clip(CircleShape)
                                .border(1.dp, Acab.line, CircleShape)
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    } else {
                        Text(
                            "ERASE",
                            color = Acab.accent, fontSize = 10.sp, fontFamily = Acab.mono,
                            fontWeight = FontWeight.Bold, letterSpacing = 1.sp,
                            modifier = Modifier
                                .minimumInteractiveComponentSize()
                                .clip(CircleShape)
                                .border(1.dp, Acab.lineStrong, CircleShape)
                                .clickable { confirmEraseBuffer = true }
                                .padding(horizontal = 10.dp, vertical = 6.dp),
                        )
                    }
                }
                if (confirmEraseBuffer) {
                    val n = status?.bufCount ?: 0
                    val copy = bufferClearConfirmationCopy(
                        bufferedCount = n,
                        keyMismatch = status?.bufferKeyMismatch == true,
                    )
                    androidx.compose.material3.AlertDialog(
                        onDismissRequest = { confirmEraseBuffer = false },
                        containerColor = Acab.bg2,
                        titleContentColor = Acab.text,
                        title = {
                            Text(copy.title,
                                fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        },
                        text = {
                            Text(
                                copy.message,
                                color = Acab.dim, fontSize = 14.sp)
                        },
                        confirmButton = {
                            Text("ERASE", color = Acab.accentText, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                                modifier = Modifier.minimumInteractiveComponentSize()
                                    .clickable { ble.clearBufferLog(); confirmEraseBuffer = false }
                                    .padding(8.dp))
                        },
                        dismissButton = {
                            Text("CANCEL", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                                modifier = Modifier.minimumInteractiveComponentSize()
                                    .clickable { confirmEraseBuffer = false }.padding(8.dp))
                        },
                    )
                }
            }
        }
    }
    val driveContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("LIVE MODE")
            ToggleRow(
                "live counter notification",
                "lock screen + status bar · glance without opening the app",
                checked = shownLiveWanted,
            ) { on ->
                if (demo) {
                    sampleLiveWanted = on
                } else if (on) {
                    if (!hasNotifPermission(context) && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    }
                    ble.startDriveMode()
                } else ble.endDriveMode()
            }
            if (driveMode && !notifGranted) {
                Text("Allow notifications to see the counter.",
                    color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono)
            }
            HorizontalDivider(color = Acab.line)
            // The subtitle names ALL THREE surfaces this switch reaches on Android, because it
            // reaches more than the lock screen: the Live Mode notification (locked face drops to
            // "Live Mode active"), the Android 16 promoted chip (loses its running count, locked
            // or not), and per-detection alerts (locked face stops naming the category). The old
            // wording promised counts "remain visible in the shade", which the chip half has not
            // been true of since AcabLinkService.shortCriticalText started reading this flag, and
            // it said nothing about the alerts half at all. Erring quieter than advertised is the
            // safe side of a mismatch on this product, so the copy widened, not the behaviour.
            // iOS scopes its same-named toggle to the Live Activity only, which is why its
            // subtitle (SettingsView.swift) still reads narrower; see the _redactLockScreen
            // declaration in AcabBleManager for the full scope.
            ToggleRow(
                "keep counts private on lock screen",
                "lock screen shows only “Live Mode active” · locked alerts drop their details, and the status-bar chip drops its count everywhere · the app itself still shows everything",
                checked = shownRedactLock,
            ) { if (demo) sampleRedactLock = it else ble.setRedactLockScreen(it) }
        }
    }
    val desertContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("DESERT MODE")
            ToggleRow(
                "report every device",
                "show + log ANY device nearby · best out in the open",
                checked = desertOn,
                pending = desertPending && !demo,
            ) { desertOn = it; desertPending = true; if (!demo) ble.setDesert(it) }
            Text("Off the grid, anything new on the air means something arrived. Each device is tagged hardware or randomized (phone) MAC, or OUI unknown when the radio cannot tell.",
                color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
            if (desertOn) {
                // The startup jingle is NOT exempt from the mute (alerts.cpp, 2026-08-24: the boot
                // motif is a UserAlert, so a muted board never announces itself - an unattended
                // power restore is indistinguishable from a hand on the plug). The shutdown motif
                // is the cue that still plays muted. Said plainly here so a user who mutes the
                // board, power-cycles it and hears nothing does not read silence as a dead board.
                // Worded as the JINGLE, not as "starts silently": the rev-B hold-to-start ack is a
                // separate cue and does still chirp through the mute.
                // iOS twin: the same string in SettingsView.swift's desertModeCard.
                Text("Detection alerts are muted while Desert mode runs. With every nearby device reporting in, a beep for each would never let up. The shutdown cue still plays unless volume is 0; the startup jingle is muted along with everything else.",
                    color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono)
            }
        }
    }
    val ledContent: @Composable () -> Unit = {
        Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Kicker("BOARD LED")
            ToggleRow(
                "lights out",
                "no LEDs · for covert or stationary deploys",
                checked = lightsOut,
                pending = ledPending && !demo,
            ) { lightsOut = it; ledPending = true; if (!demo) ble.setLed(!it) }
            Text("On by default the board LED gives a slow heartbeat so you can see it's alive, and flashes on a hit. Lights out keeps it completely dark.",
                color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }

    val liveReadiness = when {
        demo -> "SAMPLE DATA"
        !driveModeWanted -> "OFF"
        !notifGranted -> "BLOCKED"
        driveMode -> "ACTIVE"
        else -> "WAITING"
    }
    val previewLiveMode: () -> Unit = {
        if (!demo) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !hasNotifPermission(context)) {
                notifLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
            }
            ble.startDriveMode()
        }
    }
    val openNotificationSettings: () -> Unit = {
        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        runCatching { context.startActivity(intent) }.onFailure {
            context.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", context.packageName, null))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }
    val addWidget: () -> Unit = {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && widgetPinSupported && !widgetAdded) {
            val success = PendingIntent.getActivity(
                context,
                22,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            widgetManager.requestPinAppWidget(widgetProvider, null, success)
        }
    }
    val readinessSlot: @Composable () -> Unit = {
        SystemReadinessCard(
            modifier = Modifier.bringIntoViewRequester(readinessRequester),
            liveState = liveReadiness,
            notificationsReady = notifGranted,
            countsPrivate = shownRedactLock,
            locationReady = locationGranted,
            widgetAdded = widgetAdded,
            widgetPinSupported = widgetPinSupported,
            previewEnabled = !demo,
            onNotificationSettings = openNotificationSettings,
            onAddWidget = addWidget,
            onPreview = previewLiveMode,
            onRequestLocation = onRequestLocation,
        )
    }

    val subScreenOpen = helpOpen || contribVm.open || managedOpen || aboutOpen
    Box(Modifier.fillMaxSize()) {
        // T2/T5: cap readable content width so tablets/landscape stop stretching one column edge to
        // edge; at phone width the cap is a no-op. BoxWithConstraints scrolls + centers. Below 840dp
        // the inner Column is a single 640-capped stack. At expanded width (>=840dp) the row slots
        // below the hero/firmware split into two balanced columns and the cap opens to 1000dp. The
        // folded rows flow into that split unchanged.
        BoxWithConstraints(
            Modifier
                .fillMaxSize()
                .then(if (subScreenOpen) Modifier.clearAndSetSemantics { } else Modifier)
                .verticalScroll(rememberScrollState()),
            contentAlignment = Alignment.TopCenter,
        ) {
            val twoCol = maxWidth >= 840.dp

            // 3. Config drawer: one bg2 panel, hairline dividers, exactly one section open at a time.
            //    Each expanded section is today's card VERBATIM. Alerts is skipped on a mesh board
            //    (no buzzer), same gate as before.
            val configPanel: @Composable () -> Unit = {
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(Acab.radius))
                        .background(Acab.bg2)
                        .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius)),
                ) {
                    // Firmware folds in as row 1 when it's UP TO DATE (matches iOS anatomy). When an
                    // update EXISTS it promotes to the crimson banner under the hero instead.
                    if (!showBanner) {
                        FoldRow(
                            Icons.Filled.Memory, "Firmware",
                            // An nRF-only update leaves the S3 version current, so it lives here
                            // rather than the crimson banner; say "UPDATE READY" so it isn't
                            // misleadingly "UP TO DATE".
                            fwInstalled?.let { "v$it · ${if (combinedStale) "UPDATE READY" else "UP TO DATE"}" } ?: "FIRMWARE",
                            openSection == ConfigSection.FIRMWARE, { toggleSection(ConfigSection.FIRMWARE) },
                            content = firmwareCard,
                        )
                        HorizontalDivider(color = Acab.line)
                    }
                    FoldRow(Icons.Filled.SettingsInputAntenna, "Scan radios", radiosKicker,
                        openSection == ConfigSection.RADIOS, { toggleSection(ConfigSection.RADIOS) },
                        content = radiosContent)
                    HorizontalDivider(color = Acab.line)
                    FoldRow(Icons.Filled.Radar, "Detectors", detectorsKicker,
                        openSection == ConfigSection.DETECTORS, { toggleSection(ConfigSection.DETECTORS) },
                        targetModifier = Modifier.bringIntoViewRequester(detectorsRequester),
                        content = detectorsContent)
                    HorizontalDivider(color = Acab.line)
                    if (status?.isMeshDetect != true) {   // mesh board has no buzzer
                        FoldRow(Icons.Filled.Notifications, "Alerts", alertsKicker,
                            openSection == ConfigSection.ALERTS, { toggleSection(ConfigSection.ALERTS) }) {
                            BuzzerCard(
                                mode = shownAlertMode,
                                master = masterVolume,
                                onMasterChange = { masterVolume = it; volumeDragging = true },
                                onMode = {
                                    if (demo) sampleAlertModeName = it.name else ble.setAlertMode(it)
                                },
                                onVolumeCommit = {
                                    volumeDragging = false
                                    volumePending = true
                                    // The preview chirp is a detection-alert sound, so ask for it
                                    // only in Buzzer mode. The board plays it as a UserAlert and
                                    // therefore already drops it while alerts are muted; asking
                                    // only when it can be heard keeps the request honest.
                                    if (!demo) ble.setVolume(
                                        it, preview = shownAlertMode == AlertMode.BUZZER)
                                },
                            )
                        }
                        HorizontalDivider(color = Acab.line)
                    }
                    // NOT gated on isMeshDetect, unlike Alerts: these are PHONE notifications, so
                    // they work the same on a board with no buzzer, which is where they matter most.
                    FoldRow(Icons.Filled.PhoneAndroid, "Notifications", notifyKicker,
                        openSection == ConfigSection.NOTIFY, { toggleSection(ConfigSection.NOTIFY) }) {
                        NotifyCard(
                            isOn = notifyIsOn,
                            muted = notifMuted,
                            detectorOff = { t ->
                                // false when no status yet (do not cry wolf) and for WATCHED,
                                // which has no detector switch: the watchlist is always live.
                                status?.let { st ->
                                    when (t) {
                                        DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> !st.flock
                                        DeviceType.DRONE -> !st.drone
                                        DeviceType.BODY_CAM -> !st.bodyCam
                                        DeviceType.TRACKER -> !st.tracker
                                        DeviceType.GLASSES -> !st.glasses
                                        DeviceType.NETWORK_CAMERA -> !st.ncam
                                        else -> false
                                    }
                                } ?: false
                            },
                            onChange = { t, on ->
                                if (demo) {
                                    sampleNotifyOn = sampleNotifyOn + (t.raw to on)
                                } else {
                                    notifyOn = notifyOn + (t.raw to on)
                                    DetectionNotifier.setEnabled(context, t, on)
                                    // Re-ask here as well as on ON_RESUME: mutedBySystem is false
                                    // while no category is on, so the very flip that makes the
                                    // warning true happens without the activity ever pausing.
                                    notifMuted = DetectionNotifier.mutedBySystem(context)
                                    // Ask on the FIRST enable, with obvious context, rather than at launch.
                                    if (on) askPostPermission()
                                }
                            },
                        )
                    }
                    HorizontalDivider(color = Acab.line)
                    // Phone-side like Notifications: nothing here touches the board.
                    FoldRow(Icons.Filled.Contrast, "Display", displayKicker,
                        openSection == ConfigSection.DISPLAY, { toggleSection(ConfigSection.DISPLAY) }) {
                        DisplayCard()
                    }
                    HorizontalDivider(color = Acab.line)
                    // Board LED sits with Alerts (both are local feedback), above the situational modes.
                    FoldRow(Icons.Filled.Lightbulb, "Board LED", ledKicker,
                        openSection == ConfigSection.LED, { toggleSection(ConfigSection.LED) },
                        content = ledContent)
                    HorizontalDivider(color = Acab.line)
                    FoldRow(Icons.Filled.Radar, "Live Mode", driveKicker,
                        openSection == ConfigSection.DRIVE, { toggleSection(ConfigSection.DRIVE) },
                        content = driveContent)
                    HorizontalDivider(color = Acab.line)
                    FoldRow(Icons.Filled.Landscape, "Desert mode + buffer", desertBufKicker,
                        openSection == ConfigSection.DESERT, { toggleSection(ConfigSection.DESERT) }) {
                        desertContent()
                        Spacer(Modifier.size(12.dp))
                        bufferContent()
                    }
                }
            }

            // 4. Watched + muted devices collapse behind one nav row.
            // Reference surface, not a control, so it sits below the toggles that change what the
            // board does and above Disconnect. Mirrors the iOS placement.
            val helpRow: @Composable () -> Unit = {
                NavRow(Icons.Filled.Info, Acab.dim, "Help + support",
                    "FAQ · TROUBLESHOOTING · CONTACT") { helpOpen = true }
            }
            // Field research: contribute a capture of a device the beacon did not identify. The
            // submission path is manual (see ContributeContent): it starts only after review.
            val contributeRow: @Composable () -> Unit = {
                NavRow(Icons.Filled.Science, Acab.dim, "Help improve detection",
                    "CONTRIBUTE A FIELD OBSERVATION") { contribVm.open = true }
            }
            val managedRow: @Composable () -> Unit = {
                NavRow(Icons.Filled.Star, Acab.watchTone, "Managed devices", managedKicker) { managedOpen = true }
            }
            // 1. Glanceable stats, trimmed to uptime + detections. The DETECTIONS tile counts the
            //    phone-side log (same source as iOS), not the board's since-boot session total,
            //    so the two platforms show the same number for the same board.
            val statsSlot: @Composable () -> Unit = {
                StatsGrid(uptime = status?.uptime, detections = logDetections.size)
            }
            val disconnectSlot: @Composable () -> Unit = {
                // In demo there is no GATT to disconnect; the same button exits sample data instead.
                // Block Disconnect while the combined update runs: a mid-reboot teardown races the
                // OTA reconnect. Sample data isn't an update, so it stays tappable. (Mirrors iOS.)
                DisconnectButton(
                    label = if (demo) "Exit sample data" else "Disconnect",
                    enabled = demo || !combined.isRunning,
                ) {
                    if (demo) ble.exitDemo() else ble.disconnect()
                }
            }
            // rev-B only (gated in `slots`): shut the board down over BLE. Same block styling as
            // Disconnect and blocked during the combined update for the same reason (a power-off
            // mid-reboot strands the flow). The board drops the link itself; the manager pre-arms the
            // expected-teardown flags so that drop is clean.
            val powerOffSlot: @Composable () -> Unit = {
                DisconnectButton(label = "Power off beacon", enabled = !combined.isRunning) {
                    confirmPowerOff = true
                }
                if (confirmPowerOff) {
                    androidx.compose.material3.AlertDialog(
                        onDismissRequest = { confirmPowerOff = false },
                        containerColor = Acab.bg2,
                        titleContentColor = Acab.text,
                        title = {
                            Text("Power off the beacon?", fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                        },
                        text = {
                            Text(
                                "The beacon shuts down and stops detecting. You'll turn it back on with the " +
                                    "button on the device (hold it for about a second). It can't be powered back on from the app.",
                                color = Acab.dim, fontSize = 14.sp)
                        },
                        confirmButton = {
                            Text("POWER OFF", color = Acab.accentText, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                                modifier = Modifier.minimumInteractiveComponentSize()
                                    .clickable { ble.powerOff(); confirmPowerOff = false }
                                    .padding(8.dp))
                        },
                        dismissButton = {
                            Text("CANCEL", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                                modifier = Modifier.minimumInteractiveComponentSize()
                                    .clickable { confirmPowerOff = false }.padding(8.dp))
                        },
                    )
                }
            }
            // 5. About collapses to a footer link that pushes the About sub-screen.
            val aboutFooter: @Composable () -> Unit = {
                Text(
                    "about · made by soyboi",
                    color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono, letterSpacing = 1.sp,
                    modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                        .clickable { aboutOpen = true }.padding(vertical = 8.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }

            // Row slots below the hero + firmware: single column (compact) or split two-up (>=840dp).
            // Power-off rides just under Disconnect, and ONLY on rev-B: a rev-A slide board would
            // re-wake the instant it slept, and absent boardRev (older firmware without the poweroff
            // handler) it would do nothing - so the button never appears where it can't work.
            val slots = buildList<Pair<String, @Composable () -> Unit>> {
                add("stats" to statsSlot)
                if (!demo) add("readiness" to readinessSlot)
                add("config" to configPanel)
                add("managed" to managedRow)
                add("contribute" to contributeRow)
                add("help" to helpRow)
                add("disconnect" to disconnectSlot)
                if (!demo && boardRev == "B") add("poweroff" to powerOffSlot)
                add("aboutfooter" to aboutFooter)
            }

            Column(
                Modifier
                    .widthIn(max = if (twoCol) 1000.dp else 640.dp)
                    .fillMaxWidth()
                    .padding(horizontal = Acab.pad)
                    .padding(top = 8.dp, bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                // header (honest in demo: nothing is paired, it's canned sample data). A refresh
                // control asks the board for a fresh status frame now instead of waiting for the
                // next periodic poll (mirrors iOS).
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                        // "Beacon", matching the tab label (Tab.DEVICE renders "Beacon"); the
                        // header saying "Device" was a leftover from before the tab rename.
                        Text("Beacon", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                        Kicker(if (demo) "SAMPLE DATA" else "PAIRED OVER BLE")
                    }
                    StatusRefreshButton { ble.refreshStatus() }
                }

                // Carrier revision rides on the firmware label, matching iOS boardRevSuffix, so
                // support can tell which board is in the case without asking the owner to open it.
                // Silent when the board does not report one: an unlabelled board reads as "we were
                // not told", never as rev-A.
                val fwWithRev = status?.firmwareLabel?.let { label ->
                    // The rev-B fw label already ends in "rev-B", so appending the badge there
                    // prints "... rev-B · rev-B". Only add it when the label does not already name
                    // this rev (rev-A's label is just "beacon board", so it still gets the badge).
                    if ((boardRev == "A" || boardRev == "B") &&
                        !label.lowercase().contains("rev-${boardRev.lowercase()}"))
                        "$label · rev-$boardRev" else label
                }
                DeviceHero(name = name, firmware = fwWithRev, battery = status?.battery,
                    charging = status?.charging == true, connected = !demo && status != null, demo = demo)

                settingFeedback?.let { SettingFailureBanner(it) }

                // nRF radio fault: dual-radio boards report "co" (co-processor alive). When it's
                // explicitly false the BLE-detection half is dark, so surface a crimson banner.
                // single-radio boards omit "co" (coAlive == null) so this never shows for them.
                // A nRF mid BLE DFU ("nrfup") is silent for a good reason - it's sitting in its
                // bootloader - so that window gets the calm "updating" banner, never the fault.
                // App-authoritative suppression (mirrors iOS coprocFault): while the one-click flow
                // runs we KNOW the nRF is being reset-pulsed / reflashed, so the FAULT banner is
                // forced off regardless of what "co"/"nrfup" report this frame. The calm "updating"
                // banner still shows during the actual DFU window.
                // The updating banner keys on "nrfup" alone (not coAlive): the S3 flags the DFU
                // window the moment it forwards the trigger, but "co" can hold true for several
                // more seconds of UART-silence grace, and the calm banner should show through
                // that whole window. Same gating as iOS.
                if (status?.nrfUpdating == true) NrfUpdatingBanner()
                else if (status?.coAlive == false && !combined.isRunning) NrfFaultBanner()

                // 2. Firmware: crimson update banner directly under the hero when an update exists.
                //    When UP TO DATE the firmware folds into the config drawer as row 1 (below),
                //    so nothing is rendered here. Both expand to today's firmware card.
                if (showBanner) {
                    FirmwareBanner(
                        title = "Firmware v$fwLatest ready",
                        kicker = "installed v${fwInstalled ?: "-"} · updates over Bluetooth",
                        expanded = fwExpanded,
                        onToggle = { toggleSection(ConfigSection.FIRMWARE) },
                        content = firmwareCard,
                    )
                }

                if (twoCol) {
                    // Expanded: two balanced columns, slots split in list order (left gets the
                    // extra one on an odd count). Same 14dp inter-slot gap in each column.
                    val half = (slots.size + 1) / 2
                    Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            slots.take(half).forEach { (k, content) -> key(k) { content() } }
                        }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                            slots.drop(half).forEach { (k, content) -> key(k) { content() } }
                        }
                    }
                } else {
                    // Compact (phone portrait): single 640-capped stack.
                    slots.forEach { (k, content) -> key(k) { content() } }
                }
            }
        }

        // State-driven full-bleed sub-screens (this tab has no NavHost of its own). Each hosts
        // today's cards verbatim and closes on the back arrow or the system back gesture.
        if (helpOpen) {
            SubScreen(
                title = "Help + support",
                onBack = { helpOpen = false },
                scrollable = false,
            ) {
                // The "improve detection" support row opens the contribution composer over Help
                // (Help stays underneath, so backing out of the composer returns here). Same shape
                // as the iOS NavigationLink from HelpView to ContributeView.
                HelpScreen(
                    onImproveDetection = { contribVm.open = true },
                    modifier = Modifier.weight(1f),
                )
            }
        }
        if (contribVm.open) {
            // Back routes through requestExit: with a capture in flight it arms the "Discard this
            // capture?" confirmation instead of silently dropping the user's field work.
            SubScreen(title = "Improve detection", onBack = { contribVm.requestExit() }) {
                ContributeContent(ble, contribVm)
            }
        }
        if (managedOpen) {
            SubScreen(title = "Managed devices", onBack = { managedOpen = false }) {
                if (watched.isNotEmpty()) {
                    WatchedCard(
                        watched = watched,
                        boardCount = status?.watchCount ?: 0,
                        onUnwatch = { ble.unwatch(it) },
                        onRename = { mac, label -> ble.renameWatched(mac, label) },
                    )
                }
                if (ignored.isNotEmpty() || boardOnlyMuteCount > 0) {
                    IgnoredCard(
                        ignored = ignored,
                        boardOnlyCount = boardOnlyMuteCount,
                        onUnmute = { ble.unignore(it) },
                        onRename = { mac, label -> ble.renameIgnored(mac, label) },
                    )
                }
                if (watched.isEmpty() && ignored.isEmpty() && boardOnlyMuteCount == 0) {
                    Text("No watched or muted devices yet.",
                        color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono)
                }
            }
        }
        if (aboutOpen) {
            SubScreen(title = "About", onBack = { aboutOpen = false }) {
                AboutCard(
                    showColonel = status?.firmwareLabel?.startsWith("beacon board") != true,
                    onSoyboi = { context.openUrl("https://soyboi.tech") },
                    onHowItDetects = { context.openUrl("https://soyboi.tech/how-it-detects.html") },
                    onSource = { context.openUrl("https://github.com/soyboi1312/all-cameras-are-beacons") },
                    onColonel = { context.openUrl("https://colonelpanic.tech") },
                    // One canonical policy. The former soyboi.tech copy drifted and claimed the
                    // phone GPS fix was never sent to the board; check-signature-drift.py pins this
                    // URL to the same repository-owned page iOS opens.
                    onPrivacy = { context.openUrl(
                        "https://soyboi1312.github.io/all-cameras-are-beacons/privacy.html") },
                    onMadeBy = { context.openUrl("https://github.com/soyboi1312") },
                )
            }
        }
    }
}

/** A fold row in the config drawer: accent-tinted glyph + title + live kicker, a chevron that
 *  flips, and a faint accent wash while open. The expanded body is today's card, verbatim. */
@Composable
private fun FoldRow(
    glyph: ImageVector,
    title: String,
    kicker: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    targetModifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(if (expanded) Acab.accent.copy(alpha = 0.04f) else Color.Transparent),
    ) {
        Row(
            targetModifier.fillMaxWidth().clickable(onClick = onToggle)
                // Expand/collapse state for TalkBack: the flipping chevron is invisible to it.
                .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
                .padding(Acab.padCard),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(glyph, contentDescription = null,
                tint = if (expanded) Acab.accent else Acab.dim, modifier = Modifier.size(18.dp))
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
                Text(kicker, color = if (expanded) Acab.accent else Acab.dim, fontSize = 10.sp,
                    letterSpacing = 1.5.sp, fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
            }
            Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null, tint = if (expanded) Acab.accent else Acab.dim,
                modifier = Modifier.size(20.dp))
        }
        AnimatedVisibility(visible = expanded) {
            Column(Modifier.fillMaxWidth().padding(start = Acab.padCard, end = Acab.padCard, bottom = Acab.padCard)) {
                content()
            }
        }
    }
}

/** The crimson "update ready" banner under the hero. Filled accent, radiusSm; taps to reveal
 *  today's firmware card (which owns all OTA progress/failed UI). */
@Composable
private fun FirmwareBanner(
    title: String,
    kicker: String,
    expanded: Boolean,
    onToggle: () -> Unit,
    content: @Composable () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Acab.radiusSm))
            .background(Acab.accent),
    ) {
        Row(
            Modifier.fillMaxWidth().clickable(onClick = onToggle)
                .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" }
                .padding(Acab.padCard),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, color = Acab.onAccent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                Text(kicker, color = Acab.onAccent.copy(alpha = 0.7f), fontSize = 10.sp,
                    letterSpacing = 1.5.sp, fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
            }
            Icon(if (expanded) Icons.Filled.ExpandLess else Icons.Filled.ExpandMore,
                contentDescription = null, tint = Acab.onAccent, modifier = Modifier.size(20.dp))
        }
        AnimatedVisibility(visible = expanded) {
            Column(Modifier.fillMaxWidth().padding(start = Acab.padCard, end = Acab.padCard, bottom = Acab.padCard)) {
                content()
            }
        }
    }
}

/** A top-level nav row that pushes a sub-screen (chevron-forward, no expand). */
@Composable
private fun NavRow(glyph: ImageVector, glyphTint: Color, title: String, kicker: String, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Acab.radius))
            .background(Acab.bg2)
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
            .clickable(onClick = onClick)
            .padding(Acab.padCard),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(glyph, contentDescription = null, tint = glyphTint, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(title, color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.Medium)
            Text(kicker, color = Acab.dim, fontSize = 10.sp, letterSpacing = 1.5.sp,
                fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.dim, modifier = Modifier.size(20.dp))
    }
}

/** A full-bleed sub-screen overlay hosting existing cards verbatim, with a back arrow and a
 *  system-back handler. DeviceScreen has no NavHost, so navigation stays state-driven here. */
@Composable
private fun SubScreen(
    title: String,
    onBack: () -> Unit,
    scrollable: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    BackHandler(enabled = true, onBack = onBack)
    val outerModifier = Modifier.fillMaxSize().background(Acab.bg).then(
        if (scrollable) Modifier.verticalScroll(rememberScrollState()) else Modifier,
    )
    Column(
        outerModifier,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Column(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .then(if (scrollable) Modifier else Modifier.fillMaxHeight())
                .padding(horizontal = Acab.pad)
                .padding(top = 8.dp, bottom = 16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Row(
                Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                    .clickable(onClick = onBack),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back",
                    tint = Acab.accent, modifier = Modifier.size(22.dp))
                Spacer(Modifier.size(10.dp))
                Text(title, color = Acab.text, fontSize = 22.sp, fontWeight = FontWeight.SemiBold)
            }
            content()
        }
    }
}

/** Open an external link in the browser. Fails soft: ACTION_VIEW throws when the device has no
 *  app willing to answer, and a tap on a help or flasher link is never worth taking the whole
 *  screen down. (The links themselves are trusted before they get here - the hardcoded ones are
 *  literals, and the manifest's flasher string is confined to a plain https address at parse
 *  time, in FirmwareManifest's trustedFlasherUrl.) */
private fun Context.openUrl(url: String) {
    runCatching {
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }.onFailure {
        Toast.makeText(applicationContext, "Couldn't open the link. No browser is installed.",
            Toast.LENGTH_LONG).show()
    }
}

/** Whether we can post notifications (always true before Android 13). */
private fun hasNotifPermission(context: Context): Boolean =
    DetectionNotifier.hasPostPermission(context)

/** Connected-device hero card. Honest in [demo]: says sample data, never "CONNECTED".
 *  At large font scales the name/firmware column stacks UNDER the glyph+battery row instead of
 *  sharing it: at 2x text the firmware line was ellipsizing into uselessness beside the glyph. */
@Composable
private fun DeviceHero(name: String?, firmware: String?, battery: Int?, charging: Boolean, connected: Boolean, demo: Boolean) {
    val stacked = LocalDensity.current.fontScale >= 1.5f
    val glyph: @Composable () -> Unit = {
        Box(
            Modifier
                .size(width = 52.dp, height = 38.dp)
                .background(Acab.bg3, RoundedCornerShape(10.dp))
                .border(1.dp, Acab.line, RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.TopStart,
        ) {
            Box(Modifier.padding(start = 12.dp, top = 10.dp).size(7.dp)
                .background(if (connected) Acab.accent else Acab.faint, CircleShape))
        }
    }
    val nameBlock: @Composable (Modifier) -> Unit = { m ->
        Column(m, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(
                if (name?.contains("ACAB") == true || name?.contains("beacon") == true) "All Cameras Are Beacons" else (name ?: "ESP32 board"),
                color = Acab.text, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, maxLines = 2,
            )
            Text(if (demo) "SAMPLE DATA · no live board" else "CONNECTED · ${firmware ?: "beacons"}",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }
    if (stacked) {
        Column(Modifier.fillMaxWidth().panel(strong = true), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                glyph()
                Spacer(Modifier.weight(1f))
                HeroBattery(battery, charging)
                Box(Modifier.size(7.dp).background(if (connected) Acab.accent else Acab.faint, CircleShape))
            }
            nameBlock(Modifier.fillMaxWidth())
        }
        return
    }
    Row(Modifier.fillMaxWidth().panel(strong = true), verticalAlignment = Alignment.CenterVertically) {
        glyph()
        Spacer(Modifier.size(14.dp))
        nameBlock(Modifier.weight(1f))
        HeroBattery(battery, charging)
        Box(Modifier.size(7.dp).background(if (connected) Acab.accent else Acab.faint, CircleShape))
    }
}

/** The hero's battery read, shared by the stacked and inline layouts. */
@Composable
private fun HeroBattery(battery: Int?, charging: Boolean) {
    battery?.let {
            // while charging, show a bolt + % in the trackerTone (teal) rather than a low-battery
            // crimson draining read; the pack is topping up, not running down.
            if (charging) {
                Icon(Icons.Filled.Bolt, contentDescription = "charging",
                     tint = Acab.trackerTone, modifier = Modifier.size(13.dp))
                Spacer(Modifier.size(3.dp))
                Text("$it%", color = Acab.trackerTone,
                     fontSize = 11.sp, fontFamily = Acab.mono, fontWeight = FontWeight.Medium)
            } else {
                Text("$it%", color = if (it <= 15) Acab.accent else Acab.dim,
                     fontSize = 11.sp, fontFamily = Acab.mono, fontWeight = FontWeight.Medium)
            }
            Spacer(Modifier.size(8.dp))
        }
}

/** Crimson banner shown only when a dual-radio board reports its nRF co-processor as faulted,
 *  meaning the BLE-detection half is dark. A tinted crimson card, not the filled accent, so it
 *  reads as a warning rather than an action. */
@Composable
private fun NrfFaultBanner() {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Acab.radiusSm))
            .background(Acab.accent.copy(alpha = 0.12f))
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .padding(Acab.padCard),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.WarningAmber, contentDescription = null,
            tint = Acab.accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("nRF radio fault - bluetooth detection offline",
                color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("the second radio stopped answering, so BLE gear won't be spotted. Wi-Fi detection still runs. try a power cycle, and reflash if it sticks.",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }
}

/** The calm twin of [NrfFaultBanner], shown when the board says its nRF is mid BLE DFU
 *  ("nrfup"). Same silence on the co-processor line, but expected: a neutral card with a
 *  spinner, so an update in progress never reads as a broken radio. */
@Composable
private fun NrfUpdatingBanner() {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Acab.radiusSm))
            .background(Acab.bg2)
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
            .padding(Acab.padCard),
        verticalAlignment = Alignment.Top,
    ) {
        CircularProgressIndicator(color = Acab.warn, strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text("updating co-processor",
                color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
            Text("the second radio is taking new firmware, so BLE gear won't be spotted until it comes back. Wi-Fi detection still runs. keep the board powered and stay close.",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }
}

// The browser flasher to fall back on when the manifest has none (mirrors the shipped default).
private const val FALLBACK_FLASHER = "https://soyboi1312.github.io/all-cameras-are-beacons/"

/**
 * Installed vs latest firmware, and the ONE-CLICK combined update. The "latest" and the update
 * path come from the manifest [entry] for this board's fw label, falling back to the hardcoded
 * [LATEST] offline. When either radio is behind ([combinedStale]) it offers a single "update"
 * button that flashes the S3 application firmware and, when it applies, the nRF co-processor in
 * one determinate flow (see CombinedUpdateCoordinator). A board that can't update in-app (not
 * OTA-capable) still points at the browser flasher.
 */
@Composable
private fun FirmwareCard(
    installed: String?,
    entry: FirmwareBuild?,
    combined: CombinedUpdateProgress,
    combinedStale: Boolean,
    /** The BOARD leg specifically is behind. [combinedStale] is the OR of both radios, so this is
     *  what lets the offer copy tell "board is behind" from "only the co-processor is behind". */
    s3Stale: Boolean,
    onCombinedUpdate: (FirmwareBuild) -> Unit,
    onCombinedCancel: () -> Unit,
    onCombinedDismiss: () -> Unit,
    onFlash: (String) -> Unit,
) {
    // Manifest version is the source of truth for "latest"; fall back to the baked-in constant
    // only when the manifest has no entry for this board (offline cold start).
    val latest = entry?.version ?: LATEST
    val outdated = installed != null && isFirmwareVersionOlder(installed, latest)
    val flasher = entry?.flasher?.takeIf { it.isNotEmpty() } ?: FALLBACK_FLASHER

    // The combined flow (running, or a done / failed / partial terminal) owns the action area.
    val combinedTerminal = combined.phase == CombinedUpdatePhase.DONE ||
        combined.phase == CombinedUpdatePhase.FAILED || combined.phase == CombinedUpdatePhase.PARTIAL

    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("FIRMWARE")
        Row(verticalAlignment = Alignment.Top) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(installed?.let { "v$it" } ?: "-",
                    color = Acab.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Kicker("INSTALLED")
            }
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("v$latest", color = if (outdated) Acab.warn else Acab.dim,
                    fontSize = 20.sp, fontWeight = FontWeight.SemiBold)
                Kicker("LATEST")
            }
        }
        HorizontalDivider(color = Acab.line)

        when {
            // Running, or a terminal we keep on screen: one merged progress view for both legs.
            combined.isRunning || combinedTerminal ->
                CombinedStatus(combined, entry, onCombinedUpdate, onCombinedCancel, onCombinedDismiss)

            // Either radio behind and self-updatable: offer the single one-click update. This is
            // the ONLY update button (no per-leg firmware/co-processor buttons anymore).
            combinedStale -> {
                // Name what is ACTUALLY behind. When only the co-processor is stale the board is
                // already on $latest, and the old unconditional "Update available: v$latest" read
                // as a contradiction next to the "v$latest INSTALLED / v$latest LATEST" row right
                // above it (seen on hardware 2026-08-06).
                Text(
                    if (s3Stale) "Update available: v$latest. You can install it here, over Bluetooth."
                    else "Co-processor update available. The board firmware is already current; this updates the second radio, over Bluetooth.",
                    color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono,
                )
                CardButton("update", filled = true) { entry?.let { onCombinedUpdate(it) } }
                Text(
                    "Installs over Bluetooth and usually takes about 2-3 minutes. The board restarts on its own partway through. Keep this phone next to the beacon with the app open until it finishes.",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                )
            }

            // Behind but can't update in-app (not OTA-capable / no verifiable image): browser path.
            outdated -> {
                Text(
                    "Update available. Reflash your board to v$latest in your browser.",
                    color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono,
                )
                CardButton("Open the browser flasher") { onFlash(flasher) }
            }

            else -> Text(
                "You're on the latest firmware.",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
            )
        }

        // Manual "check for updates": force a manifest refresh past the 6h TTL, then the card
        // re-evaluates (entry/outdated recompute from the collected manifest flow). Mirrors iOS;
        // reachable in every state except mid-update.
        if (!combined.isRunning) {
            CheckForUpdatesRow(updateAvailable = outdated || combinedStale)
        }
    }
}

/** The one-click combined update, running or terminal: a status line, ONE determinate bar bound to
 *  the merged S3+nRF progress, the phase label + elapsed, and the right control button. On PARTIAL
 *  the same primary button re-offers just the nRF leg (S3 is current, so a fresh run does the
 *  co-processor only). Mirrors iOS combinedProgressView. */
@Composable
private fun CombinedStatus(
    combined: CombinedUpdateProgress,
    entry: FirmwareBuild?,
    onUpdate: (FirmwareBuild) -> Unit,
    onCancel: () -> Unit,
    onDismiss: () -> Unit,
) {
    // Keep the screen awake for the whole multi-minute flow: a dozing/locked phone can drop the BLE
    // link and background the app mid-transfer. Released when it stops or the card leaves.
    val view = LocalView.current
    DisposableEffect(combined.isRunning) {
        view.keepScreenOn = combined.isRunning
        onDispose { view.keepScreenOn = false }
    }

    val tone = when (combined.phase) {
        CombinedUpdatePhase.DONE -> Acab.accent
        CombinedUpdatePhase.FAILED, CombinedUpdatePhase.PARTIAL -> Acab.warn
        else -> Acab.dim
    }

    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(combined.label.ifEmpty { "Updating" }, color = Acab.text,
            fontSize = 14.sp, fontWeight = FontWeight.Medium)
        Spacer(Modifier.weight(1f))
        if (combined.isRunning) {
            Text("${(combined.progress * 100).roundToInt()}%", color = tone,
                fontSize = 12.sp, fontFamily = Acab.mono, fontWeight = FontWeight.SemiBold)
        }
    }

    if (combined.isRunning) {
        LinearProgressIndicator(
            progress = { combined.progress.coerceIn(0f, 1f) },
            modifier = Modifier.fillMaxWidth(), color = Acab.accent, trackColor = Acab.line,
        )
        val e = combined.elapsedSeconds
        // Locale.US: the default-locale overload localizes %d digits on some phones.
        Text(String.format(java.util.Locale.US, "elapsed %d:%02d", e / 60, e % 60),
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
    }

    val detail = when (combined.phase) {
        CombinedUpdatePhase.FAILED -> combined.reason
        // PARTIAL means "some leg didn't land", and which leg depends on the run. A co-processor-only
        // run that fails never touched the board, so it must not claim the board was updated.
        CombinedUpdatePhase.PARTIAL ->
            if (combined.s3Updated)
                "Board updated. Second radio update didn't finish. Tap to finish the second radio, or dismiss - the button re-offers it on its own once the co-processor reports in."
            else
                "Second radio update didn't finish. The board firmware is unchanged and still working. Tap to try the second radio again, or dismiss - the button re-offers it on its own once the co-processor reports in."
        CombinedUpdatePhase.DONE -> combined.notice ?: "Your beacon is up to date."
        else -> combined.notice
    }
    detail?.let {
        Text(it, color = tone, fontSize = 11.sp, fontFamily = Acab.mono)
    }

    if (combined.isRunning) {
        Text("Keep this phone next to the beacon with the app open. Don't lock it or leave this screen.",
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
    }

    when {
        combined.isRunning && combined.canCancel -> CardButton("Cancel", tint = Acab.dim) { onCancel() }
        combined.isRunning -> Unit
        combined.phase == CombinedUpdatePhase.PARTIAL -> {
            // S3 took; the second radio didn't finish. The same primary button re-offers just the
            // nRF leg (the S3 is current now, so a fresh run does the co-processor only).
            CardButton("finish second radio", filled = true) { entry?.let { onUpdate(it) } }
            CardButton("Not now", tint = Acab.dim) { onDismiss() }
        }
        else -> CardButton("Done", tint = Acab.dim) { onDismiss() }
    }
}

/** The manual "check for updates" control at the foot of the firmware card: forces a manifest
 *  refresh past the TTL, spins while it resolves, then flashes a brief confirmation. Don't claim
 *  "Up to date" if the refresh just revealed a newer version (the card above then offers an
 *  update); show a neutral "Checked" instead. The card's update state re-evaluates automatically
 *  off the refreshed manifest flow. Mirrors iOS. */
@Composable
private fun CheckForUpdatesRow(updateAvailable: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var checking by remember { mutableStateOf(false) }
    var justChecked by remember { mutableStateOf(false) }
    Row(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .background(Acab.bg2, RoundedCornerShape(Acab.radiusSm))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
            .clickable(enabled = !checking) {
                scope.launch {
                    checking = true
                    justChecked = false
                    FirmwareManifest.getInstance(context).refreshNow()
                    checking = false
                    justChecked = true
                    delay(1800)
                    justChecked = false
                }
            }
            .padding(vertical = 9.dp, horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (checking) {
            CircularProgressIndicator(color = Acab.dim, strokeWidth = 2.dp, modifier = Modifier.size(14.dp))
        } else {
            Icon(
                if (justChecked && !updateAvailable) Icons.Filled.Check else Icons.Filled.Refresh,
                contentDescription = null,
                tint = if (justChecked && !updateAvailable) Acab.accent else Acab.dim,
                modifier = Modifier.size(14.dp),
            )
        }
        Text(
            if (checking) "Checking…"
            else if (justChecked) (if (updateAvailable) "Checked" else "Up to date")
            else "Check for updates",
            color = if (justChecked && !updateAvailable) Acab.accent else Acab.dim,
            fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.5.sp, fontFamily = Acab.mono,
        )
    }
}

/** A full-width action button in the card style (matches DisconnectButton). Outlined by
 *  default; [filled] is the primary-CTA treatment per spec: solid crimson, radius 12. */
@Composable
private fun CardButton(label: String, tint: Color = Acab.accent, filled: Boolean = false, onClick: () -> Unit) {
    val shape = RoundedCornerShape(if (filled) Acab.radiusSm else Acab.radius)
    Box(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .background(if (filled) Acab.accent else Acab.bg2, shape)
            .border(1.dp, if (filled) Color.Transparent else if (tint == Acab.accent) Acab.lineStrong else Acab.line, shape)
            .clickable(onClick = onClick)
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = if (filled) Acab.onAccent else tint, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/**
 * Mute switch (checked = silenced) and a single master volume slider. The firmware has only
 * one master level (same as iOS), so there is nothing per-threat to expose. The [master] value
 * lives in DeviceScreen (with its pending-echo hold), so a status frame mid-drag can't snap
 * the thumb; dragging only repaints, one write on release.
 */
/** "always use higher contrast": OFF follows the system (the Android 14+ contrast slider, the
 *  Android 16 high-contrast-text switch), ON forces the higher-contrast palette. Named that way,
 *  rather than "higher contrast", so a user whose system setting is on understands why turning
 *  this off changes nothing. The palette lives in Theme.kt; this card only flips ContrastMode.
 *  Mirrors iOS displayCard (SettingsView.swift). */
@Composable
private fun DisplayCard() {
    val context = LocalContext.current
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Kicker("DISPLAY")
        ToggleRow(
            "always use higher contrast",
            if (ContrastMode.systemHasControl)
                "brighter secondary text and clearer control edges · off follows the system contrast settings"
            else "brighter secondary text and clearer control edges",
            checked = ContrastMode.forced,
        ) { ContrastMode.setForced(context, it) }
        Text(
            if (ContrastMode.systemWantsHigher)
                "Android asks for higher contrast, so it stays on while this switch is off."
            else "text size and bold text follow the Android settings.",
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** Per-category phone notifications. A SEPARATE card from ALERTS on purpose: ALERTS picks how the
 *  BOARD behaves, this picks what is worth interrupting you for on the PHONE. Folding them together
 *  would imply a dependency that does not exist. Mirrors iOS notifyCard. */
@Composable
private fun NotifyCard(
    isOn: (DeviceType) -> Boolean,
    muted: Boolean,
    detectorOff: (DeviceType) -> Boolean,
    onChange: (DeviceType, Boolean) -> Unit,
) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Kicker("PHONE NOTIFICATIONS")
        if (muted) {
            // A green toggle over a dead feature is the worst outcome here: the user believes they
            // are covered. Say it plainly instead.
            Text(
                "Android is blocking these. Turn notifications on for beacons in Settings, or nothing here will arrive.",
                color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono, lineHeight = 16.sp,
            )
        }
        Text(
            "Pick what's worth a notification. Every category is off until you turn it on, and Android asks permission the first time you do.",
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono, lineHeight = 16.sp,
        )
        DetectionNotifier.NOTIFIABLE.forEach { t ->
            val on = isOn(t)
            ToggleRow(t.label, notifySubtitle(t), on, exp = t.isExperimental) { onChange(t, it) }
            // A notification for a detector the BOARD is not running can never fire. Left unsaid,
            // that is the worst kind of dead switch: it reads as coverage. Only shown once the
            // toggle is on, so the card is not a wall of warnings.
            if (on && detectorOff(t)) {
                Text(
                    "the ${t.label.lowercase()} detector is off, so this won't fire. turn it on under Detectors.",
                    color = Acab.warn, fontSize = 10.sp, fontFamily = Acab.mono, lineHeight = 14.sp,
                )
            }
        }
        Text(
            "The same device won't notify again for ten minutes, so one camera can't keep buzzing you. Muted devices never notify at all.",
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono, lineHeight = 16.sp,
        )
    }
}

/** Mirrors iOS SettingsView.notifySubtitle word for word. */
private fun notifySubtitle(t: DeviceType): String = when (t) {
    DeviceType.FLOCK_CAMERA -> "plate readers"
    DeviceType.BODY_CAM -> "worn cameras"
    DeviceType.GLASSES -> "camera glasses"
    DeviceType.NETWORK_CAMERA -> "cameras on nearby wifi"
    DeviceType.DRONE -> "remote ID broadcasts"
    DeviceType.TRACKER -> "separated AirTag \u00B7 Tile \u00B7 SmartTag"
    DeviceType.WATCHED -> "devices you starred"
    else -> ""
}

@Composable
private fun BuzzerCard(
    mode: AlertMode,
    master: Float,
    onMasterChange: (Float) -> Unit,
    onMode: (AlertMode) -> Unit,
    onVolumeCommit: (Int) -> Unit,
) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Kicker("ALERTS")

        AlertModeSelector(mode = mode, onMode = onMode)
        // "power cues" used to cover the boot jingle too, which the board no longer plays while
        // muted (alerts.cpp 2026-08-24: the boot motif is a UserAlert, so mute wins; see the
        // Desert-mode note in DeviceScreen). Two cues still bypass the mute, both PowerState: the
        // shutdown motif and the rev-B hold-to-start ack. Only the shutdown one is named here,
        // because it is the one every SKU plays and the one a muted user is surprised by; the ack
        // always directly follows the user's own hold on the button, so it explains itself.
        // Volume 0 silences both. iOS twin: alertModeCaption in SettingsView.swift. Buzzer and
        // Silent are byte-identical there and MUST stay so. Vibrate is NOT, deliberately: the
        // haptic here fires in AcabBleManager.alertHaptic on the detection ingest path, so it
        // runs wherever ingest runs - including with the screen locked, whenever something keeps
        // the process and the link alive, which in the background is Live Mode's foreground
        // service. iOS haptics are UIKit feedback generators the system plays only in the
        // foreground, so the iOS string carries a scope qualifier this one does not. The
        // alert-modes paragraph in README.md records the difference. Sync the other two strings
        // freely; do not converge this one without changing the behaviour first.
        Text(
            when (mode) {
                AlertMode.BUZZER -> "board beeps when it spots gear"
                AlertMode.VIBRATE -> "detection beeps off, the shutdown cue still plays unless volume is 0. This phone buzzes on new hits"
                AlertMode.SILENT -> "detection beeps and phone feedback off, the shutdown cue still plays unless volume is 0"
            },
            color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
        )

        // LIVE IN ALL THREE MODES. Vibrate and Silent turn detection beeps off, so the only
        // thing this level still governs there is the shutdown cue the caption above names - and
        // volume 0 is the ONLY thing that silences it (firmware alerts.cpp buzzerTone: a
        // PowerState cue bypasses the alert mute, a zero volume does not). Greying the slider out
        // in those two modes made the remedy their own copy names unreachable from them.
        // iOS twin: the same rule on the Master volume slider in SettingsView.swift's buzzerCard.
        VolumeSlider("Master volume", value = master, tone = Acab.accent, bold = true,
            // Round, don't truncate: the status-echo check compares roundToInt(), so a truncated
            // send (49.7 -> 49) could never match and the 10s timeout would false-fire.
            onValueChange = onMasterChange, onCommit = { onVolumeCommit(master.roundToInt()) })
    }
}

/** Three-way alert mode: one joined capsule of equal segments split by hairlines,
 *  segmented-control style. The active segment fills with the accent; the rest sit
 *  on bg2 in dim. Same anatomy as iOS. */
@Composable
private fun AlertModeSelector(mode: AlertMode, onMode: (AlertMode) -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .fillMaxWidth()
            .height(IntrinsicSize.Min)
            .clip(shape)
            .background(Acab.bg2)
            .border(1.dp, Acab.line, shape),
    ) {
        AlertModeSegment("Buzzer", mode == AlertMode.BUZZER, Modifier.weight(1f)) { onMode(AlertMode.BUZZER) }
        SegmentDivider()
        AlertModeSegment("Vibrate", mode == AlertMode.VIBRATE, Modifier.weight(1f)) { onMode(AlertMode.VIBRATE) }
        SegmentDivider()
        AlertModeSegment("Silent", mode == AlertMode.SILENT, Modifier.weight(1f)) { onMode(AlertMode.SILENT) }
    }
}

@Composable
private fun SegmentDivider() {
    Box(Modifier.width(1.dp).fillMaxHeight().background(Acab.line))
}

@Composable
private fun AlertModeSegment(label: String, active: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .fillMaxHeight()
            .minimumInteractiveComponentSize()
            .background(if (active) Acab.accent else Color.Transparent)
            .selectable(
                selected = active,
                role = Role.RadioButton,
                onClick = onClick,
            )
            .padding(vertical = 9.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (active) Acab.onAccent else Acab.dim,
            fontSize = 11.sp,
            letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono,
            maxLines = 1,
        )
    }
}

/** Labelled volume slider: drag repaints only, one write on release. */
@Composable
private fun VolumeSlider(
    label: String, value: Float, tone: Color, bold: Boolean,
    onValueChange: (Float) -> Unit, onCommit: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label, color = Acab.text, fontSize = 14.sp,
                fontWeight = if (bold) FontWeight.Medium else FontWeight.Normal)
            Spacer(Modifier.weight(1f))
            Text("${value.toInt()}",
                color = tone, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
        }
        Slider(
            value = value, onValueChange = onValueChange, onValueChangeFinished = onCommit,
            valueRange = 0f..100f,
            modifier = Modifier.semantics { contentDescription = label },
            colors = SliderDefaults.colors(
                thumbColor = tone, activeTrackColor = tone, inactiveTrackColor = Acab.line,
            ),
        )
    }
}

/** Glanceable summary, 2-up: uptime + detections. (Alerts/scanning now live in the fold kickers.)
 *  Stacks vertically at large font scales so the values never truncate against each other. */
@Composable
private fun StatsGrid(uptime: Int?, detections: Int) {
    if (LocalDensity.current.fontScale >= 1.5f) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("UPTIME", uptime?.let(::uptimeText) ?: "-", Modifier.fillMaxWidth())
            StatTile("DETECTIONS", detections.toString(), Modifier.fillMaxWidth())
        }
    } else {
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("UPTIME", uptime?.let(::uptimeText) ?: "-", Modifier.weight(1f))
            StatTile("DETECTIONS", detections.toString(), Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatTile(kick: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Kicker(kick)
        Text(value, color = Acab.text, fontSize = 20.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Seconds to a short "1h 22m" or "22m" string. */
private fun uptimeText(seconds: Int): String {
    val h = seconds / 3600
    val m = (seconds % 3600) / 60
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}

/** Muted devices, each with an UNMUTE button. */
@Composable
private fun IgnoredCard(
    ignored: List<tech.acab.app.ble.IgnoredDevice>,
    boardOnlyCount: Int,
    onUnmute: (String) -> Unit,
    onRename: (String, String) -> Unit,
) {
    var renaming by remember { mutableStateOf<tech.acab.app.ble.IgnoredDevice?>(null) }
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("MUTED")
        ignored.forEachIndexed { i, dev ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(dev.label.ifEmpty { "Unknown device" },
                        color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    Text(dev.mac.uppercase(), color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
                    Text(dev.scopeLabel.uppercase(), color = Acab.faint, fontSize = 9.sp,
                        letterSpacing = 0.4.sp, fontFamily = Acab.mono)
                }
                Spacer(Modifier.size(8.dp))
                // Naming a muted device matters as much as naming a starred one: six weeks on,
                // "my own AirTag" is the difference between trusting the mute and undoing it.
                Icon(
                    Icons.Filled.Edit, contentDescription = "Rename", tint = Acab.dim,
                    modifier = Modifier.minimumInteractiveComponentSize()
                        .size(28.dp).clickable { renaming = dev }.padding(6.dp),
                )
                Spacer(Modifier.size(4.dp))
                Box(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .border(1.dp, Acab.lineStrong, CircleShape)
                        .clickable { onUnmute(dev.mac) }
                        .padding(horizontal = 8.dp, vertical = 8.dp),
                ) {
                    Text("UNMUTE", color = Acab.accentText, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp, fontFamily = Acab.mono)
                }
            }
            if (i != ignored.lastIndex) HorizontalDivider(color = Acab.line)
        }
        if (boardOnlyCount > 0) {
            if (ignored.isNotEmpty()) HorizontalDivider(color = Acab.line)
            Row(
                Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Icon(
                    Icons.Filled.PhoneAndroid,
                    contentDescription = null,
                    tint = Acab.faint,
                    modifier = Modifier.size(18.dp),
                )
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text(
                        "$boardOnlyCount board-only mute${if (boardOnlyCount == 1) "" else "s"}",
                        color = Acab.text,
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "Created from another phone. This beacon reports only the count, so this " +
                            "phone cannot show or remove those devices individually.",
                        color = Acab.faint,
                        fontSize = 10.sp,
                        fontFamily = Acab.mono,
                    )
                }
            }
        }
    }

    renaming?.let { dev ->
        RenameWatchedDialog(
            initial = dev.label,
            onDismiss = { renaming = null },
            onSave = { label -> onRename(dev.mac, label); renaming = null },
        )
    }
}

/** Starred (watched) devices in gold: star per row, full MAC, pencil to rename, UNSTAR to
 *  drop. The board alerts on these exact MACs every time they're seen, even with no
 *  signature match; [boardCount] echoes how many MACs the board itself is watching. */
@Composable
private fun WatchedCard(
    watched: List<tech.acab.app.ble.WatchedDevice>,
    boardCount: Int,
    onUnwatch: (String) -> Unit,
    onRename: (String, String) -> Unit,
) {
    var renaming by remember { mutableStateOf<tech.acab.app.ble.WatchedDevice?>(null) }
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Kicker("WATCHING", color = Acab.watchTone)
            Spacer(Modifier.weight(1f))
            if (boardCount > 0) Kicker("$boardCount ON BOARD", color = Acab.dim)
        }
        watched.forEachIndexed { i, dev ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.Star, contentDescription = null, tint = Acab.watchTone,
                    modifier = Modifier.size(14.dp))
                Spacer(Modifier.size(10.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(dev.label.ifEmpty { "Unknown device" },
                        color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium, maxLines = 1)
                    Text(dev.mac.uppercase(), color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
                }
                Spacer(Modifier.size(8.dp))
                // pencil rides in an explicit >=28dp box so the rename target is hittable
                Box(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .size(32.dp)
                        .clip(CircleShape)
                        .clickable { renaming = dev },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.Edit, contentDescription = "Rename", tint = Acab.dim,
                        modifier = Modifier.size(16.dp))
                }
                Spacer(Modifier.size(6.dp))
                Box(
                    Modifier
                        .minimumInteractiveComponentSize()
                        .border(1.dp, Acab.watchTone.copy(alpha = 0.4f), CircleShape)
                        .clickable { onUnwatch(dev.mac) }
                        .padding(horizontal = 8.dp, vertical = 8.dp),
                ) {
                    Text("UNSTAR", color = Acab.watchTone, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                        letterSpacing = 1.sp, fontFamily = Acab.mono)
                }
            }
            if (i != watched.lastIndex) HorizontalDivider(color = Acab.line)
        }
    }

    renaming?.let { dev ->
        RenameWatchedDialog(
            initial = dev.label,
            onDismiss = { renaming = null },
            onSave = { label -> onRename(dev.mac, label); renaming = null },
        )
    }
}

/** Rename sheet for a starred device's app-only label. */
@Composable
private fun RenameWatchedDialog(initial: String, onDismiss: () -> Unit, onSave: (String) -> Unit) {
    var text by remember { mutableStateOf(initial) }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Acab.bg2,
        titleContentColor = Acab.text,
        title = { Text("Rename device", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text("Name this device so you recognize it in the log.",
                    color = Acab.dim, fontSize = 13.sp)
                androidx.compose.material3.OutlinedTextField(
                    value = text,
                    onValueChange = { text = it },
                    singleLine = true,
                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                        focusedTextColor = Acab.text,
                        unfocusedTextColor = Acab.text,
                        focusedBorderColor = Acab.accent,
                        unfocusedBorderColor = Acab.line,
                        cursorColor = Acab.accent,
                    ),
                )
            }
        },
        confirmButton = {
            Text("SAVE", color = Acab.accentText, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable { onSave(text.trim()) }.padding(8.dp))
        },
        dismissButton = {
            Text("CANCEL", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClick = onDismiss).padding(8.dp))
        },
    )
}

/** What the app is, the hardware it runs on, where the source lives, and the privacy stance.
 *  [showColonel] drops the OUI-Spy vendor link while a beacon board is the connected hardware. */
@Composable
private fun AboutCard(showColonel: Boolean, onSoyboi: () -> Unit, onHowItDetects: () -> Unit, onSource: () -> Unit, onColonel: () -> Unit, onPrivacy: () -> Unit, onMadeBy: () -> Unit) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("ABOUT")
        Text("built for the beacon. also works on the Colonel Panic hardware.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
        HorizontalDivider(color = Acab.line)
        AboutLink("soyboi.tech", "the beacon board", onSoyboi)
        HorizontalDivider(color = Acab.line)
        AboutLink("How it detects", "what it can and can't see", onHowItDetects)
        HorizontalDivider(color = Acab.line)
        AboutLink("Source on GitHub", "github.com/soyboi1312/all-cameras-are-beacons", onSource)
        if (showColonel) {
            HorizontalDivider(color = Acab.line)
            AboutLink("Colonel Panic", "colonelpanic.tech · OUI-Spy hardware", onColonel)
        }
        HorizontalDivider(color = Acab.line)
        // Not "no data leaves your device": explicit export and contribution exist, and the
        // privacy promise has to survive contact with the share sheet. Uploads: never automatic.
        AboutLink("Privacy", "nothing is uploaded automatically", onPrivacy)
        Text("made by soyboi", color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono,
            modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                .clickable(onClick = onMadeBy).padding(top = 4.dp), textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

@Composable
private fun AboutLink(title: String, sub: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().minimumInteractiveComponentSize().clickable(onClick = onClick),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(title, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
            Text(sub, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Text("↗", color = Acab.accentText, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

/** Compact, state-backed setup audit. Every row reflects the same values used by the controls
 * below, while the actions jump directly to the OS/user boundary that can resolve a blocked row. */
@Composable
private fun SystemReadinessCard(
    modifier: Modifier = Modifier,
    liveState: String,
    notificationsReady: Boolean,
    countsPrivate: Boolean,
    locationReady: Boolean,
    widgetAdded: Boolean,
    widgetPinSupported: Boolean,
    previewEnabled: Boolean,
    onNotificationSettings: () -> Unit,
    onAddWidget: () -> Unit,
    onPreview: () -> Unit,
    onRequestLocation: () -> Unit,
) {
    Column(modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Kicker("SYSTEM READINESS")
        ReadinessRow("Live Mode", liveState,
            if (liveState == "ACTIVE") Acab.trackerTone else if (liveState == "BLOCKED") Acab.warn else Acab.dim)
        ReadinessRow("Notifications", if (notificationsReady) "ALLOWED" else "BLOCKED",
            if (notificationsReady) Acab.trackerTone else Acab.warn)
        ReadinessRow("Lock-screen counts", if (countsPrivate) "PRIVATE" else "VISIBLE", Acab.dim)
        ReadinessRow("Location context", if (locationReady) "ALLOWED" else "OPTIONAL", Acab.dim)
        ReadinessRow(
            "Widget",
            when {
                widgetAdded -> "ADDED"
                widgetPinSupported -> "READY TO ADD"
                else -> "ADD FROM LAUNCHER"
            },
            if (widgetAdded) Acab.trackerTone else Acab.dim,
        )
        HorizontalDivider(color = Acab.line)
        val actions: @Composable () -> Unit = {
            ReadinessAction("NOTIFICATIONS", "Open notification settings", true, onNotificationSettings)
            ReadinessAction(
                if (widgetAdded) "WIDGET ADDED" else "ADD WIDGET",
                "Ask your launcher to add the beacons widget",
                widgetPinSupported && !widgetAdded,
                onAddWidget,
            )
            ReadinessAction("PREVIEW", "Start or restore the Live Mode surface", previewEnabled, onPreview)
            if (!locationReady) {
                ReadinessAction("ALLOW LOCATION", "Add your position and future hit pins", true,
                    onRequestLocation)
            }
        }
        if (LocalDensity.current.fontScale >= 1.3f) {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { actions() }
        } else {
            // Short labels stay two-up; wrapping all four into one row would create sub-48dp slivers.
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    Box(Modifier.weight(1f)) {
                        ReadinessAction("NOTIFICATIONS", "Open notification settings", true,
                            onNotificationSettings)
                    }
                    Box(Modifier.weight(1f)) {
                        ReadinessAction(if (widgetAdded) "WIDGET ADDED" else "ADD WIDGET",
                            "Ask your launcher to add the beacons widget",
                            widgetPinSupported && !widgetAdded, onAddWidget)
                    }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    if (locationReady) {
                        ReadinessAction("PREVIEW", "Start or restore the Live Mode surface",
                            previewEnabled, onPreview)
                    } else {
                        Box(Modifier.weight(1f)) {
                            ReadinessAction("PREVIEW", "Start or restore the Live Mode surface",
                                previewEnabled, onPreview)
                        }
                        Box(Modifier.weight(1f)) {
                            ReadinessAction("ALLOW LOCATION", "Add your position and future hit pins",
                                true, onRequestLocation)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ReadinessRow(label: String, value: String, valueColor: Color) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Acab.text, fontSize = 12.sp, modifier = Modifier.weight(1f))
        Text(value, color = valueColor, fontSize = 9.5.sp, fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp, fontFamily = Acab.mono)
    }
}

@Composable
private fun ReadinessAction(
    label: String,
    talkBackLabel: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Box(
        Modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .alpha(if (enabled) 1f else 0.45f)
            .clip(RoundedCornerShape(Acab.radiusSm))
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .clickable(enabled = enabled, onClick = onClick)
            .semantics { contentDescription = talkBackLabel },
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Acab.accentText, fontSize = 9.5.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono, modifier = Modifier.padding(horizontal = 7.dp, vertical = 8.dp))
    }
}

/** Status writes are optimistic, but never indefinitely so. A matching status frame clears the
 * pending flag earlier; otherwise this reverts the local control after the bounded echo window. */
@Composable
private fun SettingWriteTimeout(pending: Boolean, onTimeout: () -> Unit) {
    val latestTimeout by rememberUpdatedState(onTimeout)
    LaunchedEffect(pending) {
        if (pending) {
            delay(10_000L)
            latestTimeout()
        }
    }
}

@Composable
private fun SettingFailureBanner(message: String) {
    Row(
        Modifier.fillMaxWidth().background(Acab.warn.copy(alpha = 0.10f), RoundedCornerShape(Acab.radiusSm))
            .border(1.dp, Acab.warn.copy(alpha = 0.55f), RoundedCornerShape(Acab.radiusSm))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Icon(Icons.Filled.WarningAmber, contentDescription = null, tint = Acab.warn,
            modifier = Modifier.size(17.dp))
        Text(message, color = Acab.text, fontSize = 11.sp, fontFamily = Acab.mono,
            modifier = Modifier.weight(1f))
    }
}

/** Labelled switch row; checked state comes straight from the caller. Sub-option rows pass
 *  [enabled] false (plus an inset/alpha [modifier]) to render shown-disabled while their
 *  parent toggle is off, instead of vanishing from the list. */
@Composable
private fun ToggleRow(
    name: String, sub: String, checked: Boolean,
    exp: Boolean = false, tint: Color = Acab.accent,
    enabled: Boolean = true, pending: Boolean = false, modifier: Modifier = Modifier,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .toggleable(
                value = checked,
                enabled = enabled && !pending,
                role = Role.Switch,
                onValueChange = onChange,
            )
            .semantics(mergeDescendants = true) {
                if (pending) stateDescription = "Applying"
            },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                if (exp) {
                    Spacer(Modifier.size(6.dp))
                    ExpTag()
                }
            }
            Text(sub, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        if (pending) {
            CircularProgressIndicator(
                color = Acab.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.padding(horizontal = 10.dp).size(16.dp),
            )
        }
        Switch(
            checked = checked, onCheckedChange = null, enabled = enabled && !pending,
            colors = SwitchDefaults.colors(
                checkedThumbColor = Acab.onAccent, checkedTrackColor = tint,
                uncheckedThumbColor = Acab.dim, uncheckedTrackColor = Acab.bg3,
                uncheckedBorderColor = Acab.line,
            ),
        )
    }
}

/** Small circular refresh control in the Device header: asks the board for a fresh status frame
 *  now instead of waiting for the next periodic poll. Mirrors iOS's header refresh button. */
@Composable
private fun StatusRefreshButton(onClick: () -> Unit) {
    Box(
        Modifier
            .minimumInteractiveComponentSize()
            .size(38.dp)
            .clip(CircleShape)
            .background(Acab.bg2)
            .border(1.dp, Acab.line, CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(Icons.Filled.Refresh, contentDescription = "Refresh device status",
            tint = Acab.dim, modifier = Modifier.size(16.dp))
    }
}

/** The disconnect button (relabelled "Exit sample data" in demo mode). */
@Composable
private fun DisconnectButton(label: String = "Disconnect", enabled: Boolean = true, onClick: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .alpha(if (enabled) 1f else 0.5f)
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radius))
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 13.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(label, color = Acab.accentText, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}
