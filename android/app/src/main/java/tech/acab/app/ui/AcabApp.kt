package tech.acab.app.ui

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.BluetoothDisabled
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.ShoppingCart
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.ConnState
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.FoundBoard
import tech.acab.app.ble.OtaPhase
import tech.acab.app.ble.OtaProgress
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab

internal fun shouldUseReconnectShell(
    shellEstablished: Boolean,
    hadLink: Boolean,
    state: ConnState,
    otaActive: Boolean,
): Boolean = shellEstablished && hadLink && state == ConnState.CONNECTING && !otaActive

internal fun shouldPresentFirstRunTour(seen: Boolean, deferred: Boolean): Boolean =
    !seen && !deferred

/** READY must open the real orientation before any effect can start Live Mode. */
internal fun shouldOpenRealFirstRunTour(
    state: ConnState,
    demoMode: Boolean,
    seen: Boolean,
    deferred: Boolean,
): Boolean = state == ConnState.READY && !demoMode &&
    shouldPresentFirstRunTour(seen = seen, deferred = deferred)

/** Automatic Live startup is earned only by explicitly finishing or skipping the real tour. */
internal fun shouldAttemptDefaultLive(
    state: ConnState,
    demoMode: Boolean,
    tourSeen: Boolean,
    promptDeferred: Boolean,
    wanted: Boolean,
    active: Boolean,
    attempted: Boolean,
): Boolean = state == ConnState.READY && !demoMode && tourSeen && !promptDeferred && wanted &&
    !active && !attempted

enum class NearbyPermissionDenial { NONE, RETRYABLE, SETTINGS }

/** Turn the platform permission result into a stable, directly renderable recovery state. */
internal fun resolveNearbyPermissionDenial(
    granted: Boolean,
    requestedBefore: Boolean,
    canAskAgain: Boolean,
): NearbyPermissionDenial = when {
    granted || !requestedBefore -> NearbyPermissionDenial.NONE
    canAskAgain -> NearbyPermissionDenial.RETRYABLE
    else -> NearbyPermissionDenial.SETTINGS
}

internal fun canRetryAllMissingPermissions(missingPermissionCanAskAgain: List<Boolean>): Boolean =
    missingPermissionCanAskAgain.isNotEmpty() && missingPermissionCanAskAgain.all { it }

/**
 * The pre-connection / first-run screen: says what the beacon hears, explains the permissions
 * before the OS asks, scans for a board, and offers a first-class "tour on sample data" path.
 * Once the link is up, the four-tab MainScreen takes over.
 */
@Composable
fun AcabApp(
    ble: AcabBleManager,
    permissionsGranted: Boolean,
    locationGranted: Boolean,
    notificationsAvailable: Boolean,
    nearbyPermissionDenial: NearbyPermissionDenial,
    liveNotificationDenied: Boolean,
    onRequestPermissions: () -> Unit,
    onRequestLocation: () -> Unit,
    onStartDefaultLiveMode: (requestNotification: Boolean) -> Unit,
    onLiveNotificationDenialHandled: () -> Unit,
) {
    val state by ble.state.collectAsState()
    val found by ble.found.collectAsState()
    val connectHint by ble.connectHint.collectAsState()
    val scanHint by ble.scanHint.collectAsState()
    val ota by ble.otaProgress.collectAsState()
    val logDetections by ble.logDetections.collectAsState()
    val demoMode by ble.demoMode.collectAsState()
    val liveMode by ble.driveMode.collectAsState()
    val liveModeWanted by ble.driveModeWanted.collectAsState()
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current

    // Once the app shell has existed, keep that single composition alive for the rest of this
    // activity. A transient reconnect must not destroy an in-progress contribution capture,
    // map camera, log pause snapshot, or dossier. Opaque connect/OTA surfaces can cover it, but
    // the parked shell is both pointer-disabled and hidden from accessibility while covered.
    var shellEstablished by rememberSaveable { mutableStateOf(state == ConnState.READY) }
    LaunchedEffect(state) {
        if (state == ConnState.READY) shellEstablished = true
    }

    // AcabBleManager keeps its auto-reconnect flag internal, but the transition is visible from
    // here: a user connect enters CONNECTING from SCANNING/DISCONNECTED, while the unexpected-drop
    // auto-reconnect is the only path that arrives at CONNECTING straight from READY (the OTA
    // reboot-reconnect does too, but OtaWaitScreen owns that state below). Tracked above the
    // early returns so the READY hand-off doesn't reset it.
    var hadLink by rememberSaveable { mutableStateOf(state == ConnState.READY) }
    LaunchedEffect(state) {
        when (state) {
            ConnState.READY -> hadLink = true
            ConnState.CONNECTING -> Unit    // hold: this is the reconnect window itself
            else -> hadLink = false         // any other state ends the session for good
        }
    }

    // Read-only path into the persisted log, no board needed (mirrors the iOS savedLogCard sheet).
    var showSavedLog by remember { mutableStateOf(false) }

    // The 45s scan window (AcabBleManager.SCAN_TIMEOUT_MS) ending with nothing found used to
    // fall silently back to the resting panel: the spinner just vanished, which reads as a hang
    // or a shrug. Track the SCANNING -> DISCONNECTED edge, distinguish the user's own stop-tap
    // (no message: they asked) from the timeout (message + SCAN AGAIN), and clear on re-scan.
    var userStoppedScan by remember { mutableStateOf(false) }
    var scanEndedEmpty by remember { mutableStateOf(false) }
    var prevConnState by remember { mutableStateOf(state) }
    LaunchedEffect(state, scanHint) {
        if (state == ConnState.SCANNING || scanHint != null) scanEndedEmpty = false
        if (prevConnState == ConnState.SCANNING && state == ConnState.DISCONNECTED &&
            found.isEmpty() && !userStoppedScan && scanHint == null) {
            scanEndedEmpty = true
        }
        if (state != ConnState.SCANNING) userStoppedScan = false
        prevConnState = state
    }

    val otaActive = ota.phase != OtaPhase.IDLE && ota.phase != OtaPhase.DONE && ota.phase != OtaPhase.FAILED
    val reconnectUsable = shouldUseReconnectShell(shellEstablished, hadLink, state, otaActive)
    // Hoisted so the shell can be removed from the semantics tree while an orientation overlay is
    // visible. Sample data gets its own non-persisting orientation and never spends the real tour.
    var tourDone by rememberSaveable { mutableStateOf(FirstRunTour.hasSeen(context)) }
    // Android Back temporarily dismisses the tour without writing its one-time seen flag. The
    // explicit skip and final buttons are the only actions that spend it.
    var tourDeferred by rememberSaveable { mutableStateOf(false) }
    // Derive directly from the authoritative link state. shellEstablished flips in a
    // LaunchedEffect, which is one frame too late to prevent the Live-start effect from winning.
    val firstRunTourOpen = shouldOpenRealFirstRunTour(
        state = state,
        demoMode = demoMode,
        seen = tourDone,
        deferred = tourDeferred,
    )
    var sampleTourHandled by rememberSaveable { mutableStateOf(false) }
    LaunchedEffect(demoMode) {
        if (!demoMode) sampleTourHandled = false
    }
    val sampleTourOpen = state == ConnState.READY && demoMode && !sampleTourHandled

    // Help must remain reachable before a beacon connects, which is when setup questions happen.
    var preConnectHelpOpen by rememberSaveable { mutableStateOf(false) }

    // Live Mode defaults on, but Android 13+ needs a notification permission before its glanceable
    // surface can appear. Explain that request only after the real-board orientation has closed.
    // The explanation is persisted independently from the one-time product tour: denying the OS
    // prompt must not cause a nag on every reconnect; Beacon readiness shows the recovery instead.
    val livePromptPrefs = remember { context.getSharedPreferences("acab_ui", Context.MODE_PRIVATE) }
    var livePermissionExplained by remember {
        mutableStateOf(livePromptPrefs.getBoolean(KEY_LIVE_PERMISSION_EXPLAINED, false))
    }
    var showLivePermissionPrompt by rememberSaveable { mutableStateOf(false) }
    // Scrim, Back, and Not now defer both the rationale and automatic start for this Activity
    // session. Saveable keeps that promise across rotation and reconnects without persisting Off.
    var livePromptDeferred by rememberSaveable { mutableStateOf(false) }
    // Session-only: activity recreation while Android owns the permission dialog must retry the
    // start after the result is delivered, rather than restoring a stale "attempted" latch.
    var liveStartAttempted by remember { mutableStateOf(false) }
    val notificationRuntimeGranted = DetectionNotifier.hasPostPermission(context)
    LaunchedEffect(state, demoMode, tourDone, livePromptDeferred, liveModeWanted, liveMode,
        notificationsAvailable, livePermissionExplained) {
        if (state != ConnState.READY || demoMode) {
            liveStartAttempted = false
            showLivePermissionPrompt = false
            return@LaunchedEffect
        }
        if (shouldAttemptDefaultLive(
                state = state,
                demoMode = demoMode,
                tourSeen = tourDone,
                promptDeferred = livePromptDeferred,
                wanted = liveModeWanted,
                active = liveMode,
                attempted = liveStartAttempted,
            )) {
            liveStartAttempted = true
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                !notificationRuntimeGranted && !livePermissionExplained) {
                showLivePermissionPrompt = true
            } else {
                onStartDefaultLiveMode(false)
            }
        }
    }
    val shellCovered = shellEstablished &&
        ((state != ConnState.READY && !reconnectUsable) || firstRunTourOpen || sampleTourOpen)

    Box(Modifier.fillMaxSize()) {
    if (shellEstablished) {
        val shellModifier = if (shellCovered) {
            Modifier
                .clearAndSetSemantics { }
                .pointerInput(Unit) {
                    awaitPointerEventScope {
                        while (true) {
                            awaitPointerEvent(PointerEventPass.Initial).changes.forEach { it.consume() }
                        }
                    }
                }
        } else Modifier
        MainScreen(
            ble = ble,
            reconnecting = reconnectUsable,
            locationGranted = locationGranted,
            notificationsAvailable = notificationsAvailable,
            onRequestLocation = onRequestLocation,
            modifier = shellModifier,
        )
    }

    // Once linked, hand off to the four-tab shell, but the FIRST time a real board connects,
    // show the one-time orientation over it. This is the "I'm connected, now what?" moment new
    // users were getting stuck at. Demo mode is excluded: the tour on sample data would spend the
    // one-time moment on a fake board (mirrors iOS RootView).
    if (state == ConnState.READY) {
        if (firstRunTourOpen) {
            FirstRunTourOverlay(
                onBack = { tourDeferred = true },
                onFinish = { FirstRunTour.markSeen(context); tourDone = true },
            )
        } else if (sampleTourOpen) {
            FirstRunTourOverlay(
                sampleMode = true,
                onBack = { sampleTourHandled = true },
                onFinish = { sampleTourHandled = true },
            )
        }
        if (showLivePermissionPrompt) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = {
                    showLivePermissionPrompt = false
                    livePromptDeferred = true
                    // Back/scrim is a defer, not an explicit settings change. Persisting Off here
                    // made an accidental outside tap defeat the fresh-install default forever.
                },
                containerColor = Acab.bg2,
                titleContentColor = Acab.text,
                title = { Text("Keep Live Mode at a glance?", fontWeight = FontWeight.SemiBold) },
                text = {
                    Text(
                        "Live Mode keeps a private counter in the status bar and on the lock " +
                            "screen while your beacon is connected. Android may ask to allow notifications next.",
                        color = Acab.dim,
                    )
                },
                confirmButton = {
                    TextButton(
                        onClick = {
                            livePromptPrefs.edit().putBoolean(KEY_LIVE_PERMISSION_EXPLAINED, true).apply()
                            livePermissionExplained = true
                            showLivePermissionPrompt = false
                            onStartDefaultLiveMode(true)
                        },
                    ) {
                        Text("CONTINUE", color = Acab.accentText, fontSize = 12.sp,
                            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                    }
                },
                dismissButton = {
                    TextButton(
                        onClick = {
                            showLivePermissionPrompt = false
                            livePromptDeferred = true
                            // "Not now" defers the one-time prompt for this session; the dedicated
                            // Live Mode toggle remains the only control that persists Off.
                        },
                    ) {
                        Text("NOT NOW", color = Acab.dim, fontSize = 12.sp,
                            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                    }
                },
            )
        }
        if (liveNotificationDenied && !firstRunTourOpen && !showLivePermissionPrompt) {
            LiveNotificationBlockedBanner(
                onDismiss = onLiveNotificationDenialHandled,
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }
        return@Box
    }

    // An OTA reboot drops the link to non-READY while the update is still in flight. Show a locked
    // "updating" screen instead of the interactive scan/connect UI, so the user can't fire a second
    // connect that would collide with the post-reboot reconnect loop.
    if (otaActive) {
        OtaWaitScreen(ota)
        return@Box
    }

    // Unexpected reconnects leave the established shell fully usable. MainScreen owns the
    // compact status banner; no opaque connect surface is placed over it.
    if (reconnectUsable) {
        return@Box
    }

    if (showSavedLog) {
        SavedLogScreen(
            ble = ble,
            locationGranted = locationGranted,
            onRequestLocation = onRequestLocation,
            onClose = { showSavedLog = false },
        )
        return@Box
    }

    if (preConnectHelpOpen) {
        PreConnectHelpScreen(onClose = { preConnectHelpOpen = false })
        return@Box
    }

    Surface(modifier = Modifier.fillMaxSize(), color = Acab.bg) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(Acab.pad),
        ) {
            WordmarkHero()
            Spacer(Modifier.height(22.dp))

            LazyColumn(
                Modifier.weight(1f).fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                when (state) {
                    ConnState.CONNECTING ->
                        if (hadLink) item { ReconnectingPanel(onStop = { ble.stopConnectionAndScan() }) }
                        else item {
                            ConnectingRow(
                                text = "Connecting…",
                                guidance = "Keep the beacon powered and nearby.",
                                onCancel = { ble.stopConnectionAndScan() },
                            )
                        }
                    ConnState.BONDING -> item {
                        ConnectingRow(
                            text = "Pairing…",
                            guidance = "Keep the beacon powered and nearby. Approve Android's pairing request if it appears.",
                            onCancel = { ble.stopConnectionAndScan() },
                        )
                    }
                    ConnState.POWERED_OFF -> item {
                        RadioOffPanel(onOpenBluetoothSettings = {
                            runCatching {
                                context.startActivity(Intent(Settings.ACTION_BLUETOOTH_SETTINGS))
                            }.onFailure {
                                context.startActivity(Intent(Settings.ACTION_SETTINGS))
                            }
                        })
                    }
                    else -> {
                        when {
                            !permissionsGranted && nearbyPermissionDenial == NearbyPermissionDenial.SETTINGS -> item {
                                PermissionDeniedPanel(onOpenSettings = {
                                    context.startActivity(
                                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null))
                                    )
                                })
                            }
                            !permissionsGranted && nearbyPermissionDenial == NearbyPermissionDenial.RETRYABLE -> item {
                                PermissionRetryPanel(onTryAgain = onRequestPermissions)
                            }
                            else -> {
                            item {
                                ScanCtaPanel(
                                    permissionsGranted = permissionsGranted,
                                    scanning = state == ConnState.SCANNING,
                                    onAllowScan = {
                                        when {
                                            !permissionsGranted -> onRequestPermissions()
                                            // The CTA is an explicit stop/start toggle while a scan runs.
                                            // userStoppedScan: a deliberate stop must not raise
                                            // the "No beacons found" timeout message.
                                            state == ConnState.SCANNING -> {
                                                userStoppedScan = true; ble.stopScan()
                                            }
                                            else -> ble.startScan()
                                        }
                                    },
                                )
                            }
                            if (found.isEmpty() && state == ConnState.SCANNING) {
                                item {
                                    Text(
                                        "Looking for your beacon…",
                                        color = Acab.dim,
                                        fontSize = 12.sp,
                                        fontFamily = Acab.mono,
                                        modifier = Modifier.semantics {
                                            liveRegion = LiveRegionMode.Polite
                                        },
                                    )
                                }
                            }
                            if (state != ConnState.SCANNING) {
                                scanHint?.let { hint ->
                                    item { ScanFailurePanel(hint = hint, onRetry = { ble.startScan() }) }
                                }
                            }
                            // The scan window closed with nothing heard: say so and offer the
                            // retry, instead of the spinner silently becoming a resting button.
                            if (scanHint == null && scanEndedEmpty && state != ConnState.SCANNING && found.isEmpty()) {
                                item { NoBoardsFoundPanel(onScanAgain = { ble.startScan() }) }
                            }
                            if (state != ConnState.SCANNING) {
                                connectHint?.let { hint ->
                                    item {
                                        ConnectionHintPanel(hint = hint, onRetry = { ble.startScan() })
                                    }
                                }
                            }
                            items(found) { board -> BoardRow(board, onConnect = { ble.connect(board) }) }
                            }
                        }
                    }
                }

                // The first action stays above the catalog, especially at large text sizes.
                item { BeaconHearsPanel() }
                item { SetupHelpCard(onClick = { preConnectHelpOpen = true }) }

                // Demo is a first-class path: explore the full app on sample data, no board needed.
                if (state != ConnState.CONNECTING && state != ConnState.BONDING) {
                    // The history on this phone stays reachable with no board and no Bluetooth: a
                    // log that may be evidence must never be locked behind hardware that died or a
                    // permission that was denied. Hidden during the tour so the sample store can
                    // never be exported here (mirrors iOS savedLogCard).
                    // ORDER MATTERS (2026-07-29, mirrors iOS): the tour used to sit under the saved
                    // log and new users never found it, yet it is the best answer to "what does this
                    // even do" because it IS the app on sample data. It leads now, and it is the only
                    // filled card so it reads as the primary action for anyone stuck.
                    item { DemoCard(onClick = { ble.seedDemoData() }) }
                    if (!demoMode && logDetections.isNotEmpty()) {
                        item { SavedLogCard(count = logDetections.size, onClick = { showSavedLog = true }) }
                    }
                    // No beacon yet? Point straight at the shop.
                    item { GetBeaconCard(onClick = { uriHandler.openUri("https://soyboi.tech") }) }
                }
            }

            ScopeFootnote()
        }
    }
    }
}

/** "Beacons" wordmark hero over the connect screen. */
@Composable
private fun WordmarkHero() {
    Column(
        Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("beacons", color = Acab.text, fontSize = 40.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.display)
        Kicker("ALL CAMERAS ARE BEACONS", color = Acab.faint)
    }
}

/** The six signatures the beacon listens for. Normal text keeps a compact six-up strip; large text
 *  reflows to two three-up rows so labels and TalkBack targets stay usable. */
@Composable
private fun BeaconHearsPanel() {
    val hears = listOf(
        DeviceType.FLOCK_CAMERA to "ALPR",
        DeviceType.DRONE to "DRONES",
        DeviceType.BODY_CAM to "BODY CAMS",
        DeviceType.TRACKER to "TRACKERS",
        DeviceType.GLASSES to "GLASSES",
        DeviceType.NETWORK_CAMERA to "NET CAM",
    )
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Kicker("WHAT YOUR BEACON CAN HEAR")
        val groups = if (LocalDensity.current.fontScale >= 1.35f) hears.chunked(3) else listOf(hears)
        groups.forEach { group ->
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                group.forEach { (type, label) ->
                    Column(
                        Modifier.weight(1f).minimumInteractiveComponentSize().clearAndSetSemantics {
                            contentDescription = when (type) {
                                DeviceType.TRACKER -> "Bluetooth tracker detector, optional"
                                DeviceType.NETWORK_CAMERA -> "Network camera detector, optional"
                                else -> "${type.label} detector"
                            }
                        },
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(7.dp),
                    ) {
                        CatGlyph(type, size = 30, filled = true)
                        Text(label, color = Acab.dim, fontSize = 8.5.sp,
                            fontFamily = Acab.mono, maxLines = 2,
                            textAlign = TextAlign.Center)
                    }
                }
                repeat((3 - group.size).coerceAtLeast(0)) { Spacer(Modifier.weight(1f)) }
            }
        }
        Text(
            "a passive detector. it never jams, spoofs, or interferes with nearby devices; its bluetooth link reports what it heard to your phone.",
            color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono, lineHeight = 15.sp,
        )
        Text(
            "trackers and network cameras are opt-in, switch them on in Beacon settings.",
            color = Acab.faint, fontSize = 9.5.sp, fontFamily = Acab.mono, lineHeight = 14.sp,
        )
    }
}

/** Pre-permission rationale (shown before the OS prompt) + the primary Allow-and-scan CTA. */
@Composable
private fun ScanCtaPanel(permissionsGranted: Boolean, scanning: Boolean, onAllowScan: () -> Unit) {
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(13.dp)) {
        Text(
            "Power on your beacon and keep it nearby.",
            color = Acab.text,
            fontSize = 13.sp,
            fontWeight = FontWeight.SemiBold,
        )
        if (!permissionsGranted) {
            Kicker("BEFORE THE SYSTEM ASKS")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                RationaleRow(
                    Icons.Filled.Bluetooth,
                    "Nearby devices",
                    "finds and connects to your beacon. The beacon does the listening, not your phone.",
                )
            } else {
                RationaleRow(Icons.Filled.LocationOn, "Location",
                    "is required by this Android version to scan for Bluetooth devices. it also records where your phone heard a detection. detections and location are never uploaded automatically.")
            }
        }
        val label = when {
            !permissionsGranted -> "Allow & scan for beacons"
            scanning -> "Stop scanning"
            else -> "Scan for beacons"
        }
        PrimaryButton(label, onAllowScan)
        PairWindowNote()
    }
}

/** First-time pairing note, shown under the scan button whenever no board is connected.
 *
 *  A board that already belongs to a phone only accepts a NEW phone in the two minutes after it
 *  powers on. That rule is invisible from the phone's side: the board hangs up before any
 *  characteristic exists to explain itself, so a user who misses the window just sees a connect that
 *  will not take. Stating it BEFORE the failure is worth more than any error message after it, which
 *  is why this is always present rather than a dialog.
 *
 *  Deliberately says "already paired to another phone", not "your beacon": on a brand new board with
 *  no bonds the rule does not apply at all (the firmware admits any phone until the board has an
 *  owner), and telling a first-time customer to power-cycle would be a made-up ritual.
 *  Mirrors iOS ConnectView.pairWindowNote. */
@Composable
private fun PairWindowNote() {
    Spacer(Modifier.height(10.dp))
    Row(verticalAlignment = Alignment.Top) {
        Icon(Icons.Outlined.Info, contentDescription = null, tint = Acab.dim,
             modifier = Modifier.size(14.dp))
        Spacer(Modifier.width(8.dp))
        Text(
            "Connecting a beacon that is already paired to another phone? " +
                AcabBleManager.PAIR_WINDOW_HINT,
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono, lineHeight = 15.sp,
        )
    }
}

@Composable
private fun RationaleRow(icon: ImageVector, lead: String, rest: String) {
    Row(verticalAlignment = Alignment.Top) {
        Icon(icon, contentDescription = null, tint = Acab.accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(11.dp))
        Text(
            buildAnnotatedString {
                withStyle(SpanStyle(color = Acab.text, fontWeight = FontWeight.Bold)) { append(lead) }
                withStyle(SpanStyle(color = Acab.dim)) { append(" $rest") }
            },
            fontSize = 11.5.sp, fontFamily = Acab.mono, lineHeight = 16.sp,
        )
    }
}

/** One discovered board: cpu glyph, name, firmware pill, short id, signal bars, RSSI (iOS anatomy). */
@Composable
private fun BoardRow(board: FoundBoard, onConnect: () -> Unit) {
    val bars = rssiBars(board.rssi)
    val signal = when {
        bars >= 4 -> "strong"
        bars == 3 -> "good"
        bars == 2 -> "fair"
        else -> "weak"
    }
    val addrHi = board.device.address.substringBefore(':').toIntOrNull(16) ?: 0
    val stableAddress = board.device.address.takeIf { (addrHi shr 6) != 0b01 }
    val spoken = buildString {
        append(board.name)
        board.firmware?.let { append(", firmware ").append(it) }
        append(", ").append(signal).append(" signal")
        stableAddress?.let { append(", hardware address ").append(it) }
    }
    Row(
        Modifier.fillMaxWidth()
            .clickable(onClickLabel = "connect to ${board.name}", role = Role.Button) { onConnect() }
            .semantics(mergeDescendants = true) { contentDescription = spoken }
            .panel(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Memory, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(22.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(board.name, color = Acab.text, fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                    fontFamily = Acab.mono)
                if (board.firmware != null) {
                    Spacer(Modifier.width(6.dp))
                    Text("v${board.firmware}", color = Acab.accentText, fontSize = 9.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono,
                        modifier = Modifier
                            .background(Acab.accent.copy(alpha = 0.15f), CircleShape)
                            .padding(horizontal = 5.dp, vertical = 1.dp))
                }
            }
            // Only show the advertised address when it is STABLE. With address privacy on, the
            // board advertises a Resolvable Private Address that rotates roughly every 15 minutes,
            // so this line showed a DIFFERENT value for the same board each time you opened the
            // picker, and two boards could not be told apart across a rotation. Worse, someone who
            // wrote it down would never match it again. Android does not reliably resolve a peer
            // RPA to its identity inside scan results (it does that at connect), so the value here
            // really is the rotating one even for a board you have already bonded.
            //
            // Detect it by the top two bits of the first octet: 01 = resolvable private. A board on
            // older firmware, or built with ACAB_BLE_PRIVACY=0, still advertises a fixed public MAC
            // that IS worth showing, so this hides the line rather than deleting it.
            //
            // iOS deliberately differs and needs no equivalent: CoreBluetooth never exposes a peer
            // MAC at all, it substitutes a per-host UUID that stays stable for that phone, which is
            // why ConnectView keeps showing its 8-character handle.
            if (stableAddress != null) {
                Text(stableAddress, color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
            }
        }
        SignalBars(bars, tint = Acab.accent)
        Spacer(Modifier.width(8.dp))
        Text("$signal · ${board.rssi} dBm", color = Acab.dim, fontSize = 11.sp,
            fontFamily = Acab.mono)
    }
}

@Composable
private fun ConnectingRow(text: String, guidance: String, onCancel: () -> Unit) {
    Box(
        Modifier.fillMaxWidth().padding(vertical = 44.dp).semantics {
            liveRegion = LiveRegionMode.Polite
        },
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator(color = Acab.accent, strokeWidth = 3.dp,
                modifier = Modifier.size(28.dp))
            Text(text, color = Acab.dim, fontSize = 13.sp, fontFamily = Acab.mono)
            Text(
                guidance,
                color = Acab.faint,
                fontSize = 11.sp,
                fontFamily = Acab.mono,
                lineHeight = 16.sp,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 24.dp),
            )
            // A stuck bond/connect (a powered-off board still in the scan list, an OS pairing
            // prompt dismissed) otherwise leaves this spinner with no way out but a cold launch.
            // disconnect() tears down the pending client, including the never-linked case.
            Spacer(Modifier.height(4.dp))
            CancelConnectButton(onCancel)
        }
    }
}

/** Quiet outlined pill to bail out of a stuck Connecting / Pairing spinner (iOS copy + anatomy). */
@Composable
private fun CancelConnectButton(onClick: () -> Unit) {
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(RoundedCornerShape(50))
            .background(Acab.bg2, RoundedCornerShape(50))
            .border(1.dp, Acab.line, RoundedCornerShape(50))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("Stop and scan", color = Acab.dim, fontSize = 12.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Shown while a pending auto-reconnect is armed (board unplugged / power-cycled). Says the
 *  reconnect is automatic AND gives a way out: "Stop and scan" calls disconnect(), which cancels
 *  the pending client and settles the state back to the scan panel. Without it a board that
 *  never returns would trap the user behind a generic "Connecting…" forever (mirrors iOS). */
@Composable
private fun ReconnectingPanel(onStop: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel().padding(horizontal = 4.dp, vertical = 26.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        CircularProgressIndicator(color = Acab.accent, strokeWidth = 3.dp,
            modifier = Modifier.size(28.dp))
        Text("Reconnecting to your beacon…", color = Acab.text, fontSize = 15.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text(
            "It reconnects on its own the moment the beacon is back in range, even in the background. Keep waiting, or stop to scan for a different beacon.",
            color = Acab.dim, fontSize = 11.5.sp, fontFamily = Acab.mono, lineHeight = 16.sp,
            textAlign = TextAlign.Center,
        )
        PrimaryButton("Stop and scan", onStop)
    }
}

/** The permissions were denied for good ("Don't allow" twice, or the OS auto-deny), so the
 *  prompt will never show again and the CTA would be a silent no-op. iOS .unauthorized copy,
 *  plus the deep link into the app's Settings page that Android can offer. */
@Composable
private fun PermissionDeniedPanel(onOpenSettings: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 36.dp)
            .semantics { liveRegion = LiveRegionMode.Polite },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Acab.dim,
            modifier = Modifier.size(34.dp))
        Text(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) "Nearby devices not allowed"
            else "Location not allowed",
            color = Acab.text, fontSize = 16.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                "Allow Nearby devices for beacons in Settings. It is used only to find and connect to your beacon."
            else
                "Allow Location for beacons in Settings. This Android version requires it to find Bluetooth beacons.",
            color = Acab.dim, fontSize = 12.sp,
            fontFamily = Acab.mono, textAlign = TextAlign.Center)
        Spacer(Modifier.height(2.dp))
        PrimaryButton("Open Settings", onOpenSettings)
    }
}

/** A retryable first denial. This appears as soon as Android returns the result. */
@Composable
private fun PermissionRetryPanel(onTryAgain: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel().semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                "Nearby devices permission was not allowed. It is used only to find and connect to your beacon. The beacon does the listening."
            else
                "Location was not allowed. This Android version requires it to find Bluetooth beacons. Nothing is uploaded automatically.",
            color = Acab.dim,
            fontSize = 12.sp,
            fontFamily = Acab.mono,
            lineHeight = 17.sp,
        )
        PrimaryButton("TRY AGAIN", onTryAgain)
    }
}

/** Shown when the bounded scan window ends with no boards heard. Names the two overwhelmingly
 *  likely causes (power, range) and offers the retry inline, so the timeout never reads as the
 *  app giving up silently. */
@Composable
private fun NoBoardsFoundPanel(onScanAgain: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel().semantics { liveRegion = LiveRegionMode.Polite },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("No beacons found. Make sure your beacon is powered on and nearby, then scan again.",
            color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono, lineHeight = 17.sp)
        PrimaryButton("SCAN AGAIN", onScanAgain)
    }
}

/** A platform scanner failure is not the same thing as an empty scan. */
@Composable
private fun ScanFailurePanel(hint: String, onRetry: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel().semantics { liveRegion = LiveRegionMode.Assertive },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Bluetooth scan did not start", color = Acab.text, fontSize = 14.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text(hint, color = Acab.warn, fontSize = 12.sp, fontFamily = Acab.mono,
            lineHeight = 17.sp)
        PrimaryButton("TRY AGAIN", onRetry)
    }
}

/** Actionable recovery after a connection attempt ended before the link became usable. */
@Composable
private fun ConnectionHintPanel(hint: String, onRetry: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel().semantics { liveRegion = LiveRegionMode.Assertive },
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("Connection didn't finish", color = Acab.text, fontSize = 14.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text(hint, color = Acab.warn, fontSize = 12.sp, fontFamily = Acab.mono,
            lineHeight = 17.sp)
        PrimaryButton("SCAN AGAIN", onRetry)
    }
}

/** Radio-off screen, shown when the phone's Bluetooth is turned off (mirrors iOS). Recovers on
 *  its own when the radio comes back, via the adapter receiver in AcabBleManager. */
@Composable
private fun RadioOffPanel(onOpenBluetoothSettings: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.BluetoothDisabled, contentDescription = null, tint = Acab.dim,
                modifier = Modifier.size(34.dp))
            Text("Bluetooth is off", color = Acab.text, fontSize = 16.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("Turn on Bluetooth to find your beacon.", color = Acab.dim, fontSize = 12.sp,
                fontFamily = Acab.mono, textAlign = TextAlign.Center)
            PrimaryButton("OPEN BLUETOOTH SETTINGS", onOpenBluetoothSettings)
        }
    }
}

@Composable
private fun PrimaryButton(label: String, onClick: () -> Unit) {
    Button(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(Acab.radiusSm),
        colors = ButtonDefaults.buttonColors(containerColor = Acab.accent, contentColor = Acab.onAccent),
    ) { Text(label, fontWeight = FontWeight.Bold) }
}

/** Read-only path into the persisted log, no board needed (mirrors the iOS savedLogCard). */
@Composable
private fun SavedLogCard(count: Int, onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .clickable { onClick() }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.AutoMirrored.Outlined.ListAlt, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("View saved log ($count)", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("history on this phone · browse and export, no beacon needed", color = Acab.dim,
                fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
            modifier = Modifier.size(20.dp))
    }
}

/** Outlined first-class demo path: full app on sample data, no board needed. */
@Composable
private fun DemoCard(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.accent.copy(alpha = 0.13f), RoundedCornerShape(Acab.radiusSm))
            .border(1.dp, Acab.accent.copy(alpha = 0.55f), RoundedCornerShape(Acab.radiusSm))
            .clickable { onClick() }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.Radar, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("See how it works", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("the full app on sample data · no beacon needed", color = Acab.dim,
                fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(20.dp))
    }
}

/** Offline setup and pairing help, available before a successful connection. */
@Composable
private fun SetupHelpCard(onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .clickable(onClickLabel = "open setup and pairing help", role = Role.Button, onClick = onClick)
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.Info, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Setup + pairing help", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("offline help for power, permissions, pairing, and connection recovery",
                color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
            modifier = Modifier.size(20.dp))
    }
}

/** Outlined buy CTA: no board yet, get one. Opens the shop (soyboi.tech) in the browser. */
@Composable
private fun GetBeaconCard(onClick: () -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
            .clickable { onClick() }
            .padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.ShoppingCart, contentDescription = null, tint = Acab.accent,
            modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Get a beacon", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("the beacon that does the listening · soyboi.tech", color = Acab.dim,
                fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = Acab.faint,
            modifier = Modifier.size(18.dp))
    }
}

@Composable
private fun ScopeFootnote() {
    Text(
        "Passive detection only. beacons never jam, spoof, or interfere.",
        color = Acab.dim,
        fontSize = 9.sp,
        fontFamily = Acab.mono,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        textAlign = TextAlign.Center,
    )
}

/** Full-screen offline Help for a user who has not connected a beacon yet. */
@Composable
private fun PreConnectHelpScreen(onClose: () -> Unit) {
    BackHandler(onBack = onClose)
    Surface(Modifier.fillMaxSize(), color = Acab.bg) {
        Column(
            Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing),
        ) {
            Row(
                Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                    .clickable(onClickLabel = "back to beacon setup", role = Role.Button, onClick = onClose)
                    .padding(horizontal = Acab.pad, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = null,
                    tint = Acab.accent, modifier = Modifier.size(22.dp))
                Spacer(Modifier.width(10.dp))
                Text("Setup + pairing help", color = Acab.text, fontSize = 22.sp,
                    fontWeight = FontWeight.SemiBold)
            }
            HelpScreen(
                scrollToId = "q-setup",
                modifier = Modifier.weight(1f).fillMaxWidth(),
            )
        }
    }
}

/** Immediate, dismissible recovery after Android declines the Live Mode notification request. */
@Composable
private fun LiveNotificationBlockedBanner(onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    Box(
        modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.safeDrawing).padding(Acab.pad),
        contentAlignment = Alignment.TopCenter,
    ) {
        Row(
            Modifier.widthIn(max = 640.dp).fillMaxWidth().panel()
                .semantics { liveRegion = LiveRegionMode.Assertive },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Android blocked the Live Mode lock-screen and status-bar counter. You can allow notifications later under Beacon, System readiness.",
                color = Acab.warn,
                fontSize = 11.sp,
                fontFamily = Acab.mono,
                lineHeight = 16.sp,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                "GOT IT",
                color = Acab.accentText,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClickLabel = "dismiss notification help", role = Role.Button, onClick = onDismiss)
                    .padding(8.dp),
            )
        }
    }
}

/** Full-screen, board-less view of the persisted log (the Log tab is normally gated behind a
 *  READY link). Everything inside is phone-local: view, mark seen, export CSV, clear; the
 *  board-config writes no-op while disconnected. Mirrors the iOS savedLogCard sheet. */
@Composable
private fun SavedLogScreen(
    ble: AcabBleManager,
    locationGranted: Boolean,
    onRequestLocation: () -> Unit,
    onClose: () -> Unit,
) {
    var selected by remember { mutableStateOf<Detection?>(null) }
    val uriHandler = LocalUriHandler.current
    // System back peels the dossier first, then closes the saved log (not the app).
    BackHandler { if (selected != null) selected = null else onClose() }
    Surface(
        modifier = Modifier.fillMaxSize().then(
            if (selected != null) Modifier.clearAndSetSemantics { } else Modifier),
        color = Acab.bg,
    ) {
        Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(
                Modifier.fillMaxWidth().padding(horizontal = Acab.pad, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Saved log", color = Acab.text, fontSize = 16.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                Spacer(Modifier.weight(1f))
                Icon(Icons.Filled.Close, contentDescription = "Close saved log", tint = Acab.dim,
                    modifier = Modifier
                        .minimumInteractiveComponentSize()
                        .clip(CircleShape)
                        .clickable(onClick = onClose)
                        .padding(6.dp)
                        .size(20.dp))
            }
            LogScreen(ble, onSelect = { selected = it }, pauseStateKey = "saved")
        }
    }
    // Dossier over the log, like MainScreen's compact overlay. "Open in map" has no Map tab to
    // land on with no board linked, so hand the coordinate to the system maps app instead.
    selected?.let { d ->
        DetailScreen(
            detection = d,
            ble = ble,
            onBack = { selected = null },
            onOpenInMap = { lat, lon ->
                runCatching { uriHandler.openUri("geo:$lat,$lon?q=$lat,$lon") }
            },
            locationGranted = locationGranted,
            onRequestLocation = onRequestLocation,
        )
    }
}

private const val KEY_LIVE_PERMISSION_EXPLAINED = "live_permission_explained"

/** Locked screen shown while an OTA is in flight but the link is down (the reboot/reconnect
 *  window). No scan/connect controls, so the reconnect loop can finish uninterrupted. */
@Composable
private fun OtaWaitScreen(ota: OtaProgress) {
    Surface(modifier = Modifier.fillMaxSize(), color = Acab.bg) {
        Column(
            Modifier.fillMaxSize()
                .windowInsetsPadding(WindowInsets.safeDrawing)
                .padding(Acab.pad),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            CircularProgressIndicator(color = Acab.accent, strokeWidth = 3.dp)
            Spacer(Modifier.height(20.dp))
            Text("Updating firmware", color = Acab.text, fontSize = 18.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Spacer(Modifier.height(8.dp))
            Text(
                ota.message.ifBlank { "The beacon is rebooting into the new firmware. Keep the app open, it reconnects on its own." },
                color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(6.dp))
            Text("this can take up to a minute. don't unplug the beacon.",
                color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono, textAlign = TextAlign.Center)
        }
    }
}
