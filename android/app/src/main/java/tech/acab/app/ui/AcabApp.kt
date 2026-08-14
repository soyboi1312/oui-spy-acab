package tech.acab.app.ui

import android.Manifest
import android.app.Activity
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
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
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.ConnState
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

/**
 * The pre-connection / first-run screen: says what the beacon hears, explains the permissions
 * before the OS asks, scans for a board, and offers a first-class "tour on sample data" path.
 * Once the link is up, the four-tab MainScreen takes over.
 */
@Composable
fun AcabApp(
    ble: AcabBleManager,
    permissionsGranted: Boolean,
    onRequestPermissions: () -> Unit,
) {
    val state by ble.state.collectAsState()
    val found by ble.found.collectAsState()
    val ota by ble.otaProgress.collectAsState()
    val detections by ble.detections.collectAsState()
    val demoMode by ble.demoMode.collectAsState()
    val uriHandler = LocalUriHandler.current
    val context = LocalContext.current
    val activity = context as? Activity

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
    LaunchedEffect(state) {
        if (state == ConnState.SCANNING) scanEndedEmpty = false
        if (prevConnState == ConnState.SCANNING && state == ConnState.DISCONNECTED &&
            found.isEmpty() && !userStoppedScan) {
            scanEndedEmpty = true
        }
        if (state != ConnState.SCANNING) userStoppedScan = false
        prevConnState = state
    }

    // "Don't allow" twice (or the OS auto-deny) makes the permission prompt return immediately
    // with no dialog, which left the CTA a silent no-op forever. rationale == false only means
    // "permanently denied" once we know we HAVE asked, so remember that across launches (the
    // denial itself persists across launches too). Checked at composition for the relaunch case
    // and re-checked on each CTA tap for the denied-twice-this-session case.
    val prefs = remember { context.getSharedPreferences("acab_ui", Context.MODE_PRIVATE) }
    var askedBefore by remember { mutableStateOf(prefs.getBoolean(KEY_PERMS_REQUESTED, false)) }
    fun permanentlyDenied() = !permissionsGranted && askedBefore && activity != null &&
        scanPermissions().none { activity.shouldShowRequestPermissionRationale(it) }
    var showDeniedPanel by remember { mutableStateOf(permanentlyDenied()) }

    val otaActive = ota.phase != OtaPhase.IDLE && ota.phase != OtaPhase.DONE && ota.phase != OtaPhase.FAILED
    val reconnectUsable = shouldUseReconnectShell(shellEstablished, hadLink, state, otaActive)
    // Hoisted so the shell can be removed from the semantics tree while the opaque first-run
    // overlay is visible. Demo must not spend the one-time tour on sample data.
    var tourDone by rememberSaveable { mutableStateOf(FirstRunTour.hasSeen(context)) }
    val firstRunTourOpen = shellEstablished && state == ConnState.READY && !demoMode && !tourDone
    val shellCovered = shellEstablished &&
        ((state != ConnState.READY && !reconnectUsable) || firstRunTourOpen)

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
        MainScreen(ble, reconnecting = reconnectUsable, modifier = shellModifier)
    }

    // Once linked, hand off to the four-tab shell, but the FIRST time a real board connects,
    // show the one-time orientation over it. This is the "I'm connected, now what?" moment new
    // users were getting stuck at. Demo mode is excluded: the tour on sample data would spend the
    // one-time moment on a fake board (mirrors iOS RootView).
    if (state == ConnState.READY) {
        if (firstRunTourOpen) {
            FirstRunTourOverlay(onFinish = { FirstRunTour.markSeen(context); tourDone = true })
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
        SavedLogScreen(ble, onClose = { showSavedLog = false })
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
                item { BeaconHearsPanel() }

                when (state) {
                    ConnState.CONNECTING ->
                        if (hadLink) item { ReconnectingPanel(onStop = { ble.disconnect() }) }
                        else item { ConnectingRow("Connecting…", onCancel = { ble.disconnect() }) }
                    ConnState.BONDING -> item { ConnectingRow("Pairing…", onCancel = { ble.disconnect() }) }
                    ConnState.POWERED_OFF -> item { RadioOffPanel() }
                    else -> {
                        if (showDeniedPanel && !permissionsGranted) {
                            // The OS will never show the prompt again; the app's Settings page
                            // is the only way back in, so send the user straight there.
                            item {
                                PermissionDeniedPanel(onOpenSettings = {
                                    context.startActivity(
                                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                            Uri.fromParts("package", context.packageName, null))
                                    )
                                })
                            }
                        } else {
                            item {
                                ScanCtaPanel(
                                    permissionsGranted = permissionsGranted,
                                    scanning = state == ConnState.SCANNING,
                                    onAllowScan = {
                                        when {
                                            !permissionsGranted && permanentlyDenied() -> showDeniedPanel = true
                                            !permissionsGranted -> {
                                                prefs.edit().putBoolean(KEY_PERMS_REQUESTED, true).apply()
                                                askedBefore = true
                                                onRequestPermissions()
                                            }
                                            // The CTA is a stop/start toggle while a scan runs (iOS parity).
                                            // userStoppedScan: a deliberate stop must not raise
                                            // the "No boards found" timeout message.
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
                                    Text("Looking for your board…", color = Acab.dim,
                                        fontSize = 12.sp, fontFamily = Acab.mono)
                                }
                            }
                            // The scan window closed with nothing heard: say so and offer the
                            // retry, instead of the spinner silently becoming a resting button.
                            if (scanEndedEmpty && state != ConnState.SCANNING && found.isEmpty()) {
                                item { NoBoardsFoundPanel(onScanAgain = { ble.startScan() }) }
                            }
                            items(found) { board -> BoardRow(board, onConnect = { ble.connect(board) }) }
                        }
                    }
                }

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
                    if (!demoMode && detections.isNotEmpty()) {
                        item { SavedLogCard(count = detections.size, onClick = { showSavedLog = true }) }
                    }
                    // No board yet? Point straight at the shop.
                    item { GetBeaconCard(onClick = { uriHandler.openUri("https://soyboi.tech") }) }
                    item { SoyboiLink(onClick = { uriHandler.openUri("https://soyboi.tech") }) }
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

/** The six signatures the beacon listens for, as a SINGLE row of glyph tiles on every font size,
 *  matching iOS. Each tile is an equal-weight column so all six always share one row; when a label
 *  is too wide for its column it wraps to two lines rather than the tiles wrapping to a second row,
 *  which is what used to happen at large font sizes (columns dropped to 3, so a 5-item strip became
 *  two rows). Network cameras belong here beside trackers: both are opt-in, and the copy below
 *  names them, so leaving the glyph out read as a gap. */
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
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            hears.forEach { (type, label) ->
                Column(
                    Modifier.weight(1f),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    CatGlyph(type, size = 30, filled = true)
                    Text(label, color = Acab.dim, fontSize = 8.5.sp,
                        fontFamily = Acab.mono, maxLines = 2,
                        textAlign = TextAlign.Center)
                }
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
        if (!permissionsGranted) {
            Kicker("BEFORE THE SYSTEM ASKS")
            RationaleRow(Icons.Filled.Bluetooth, "Bluetooth",
                "pairs you to the beacon. The board does the listening, not your phone.")
            // The claim is scoped honestly: explicit export and the contribution composer
            // exist, so "nothing leaves this phone" would be a lie. Uploads: never automatic.
            RationaleRow(Icons.Filled.LocationOn, "Location",
                "pins observer-based hits to the map and sends your current coordinates over encrypted local Bluetooth to your own beacon for geotagging. Drones can still provide their own Remote ID position if you decline. The app does not automatically upload detections or location to us. Beyond your own beacon, they reach another recipient only when you explicitly export or send them. Map tiles and optional datasets are requested from their providers. No account is required.")
        }
        val label = when {
            !permissionsGranted -> "Allow & scan for boards"
            scanning -> "Scanning…"
            else -> "Scan for boards"
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
    Row(
        Modifier.fillMaxWidth().clickable { onConnect() }.panel(),
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
                    Text("v${board.firmware}", color = Acab.accent, fontSize = 9.sp,
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
            val addrHi = board.device.address.substringBefore(':').toIntOrNull(16) ?: 0
            if ((addrHi shr 6) != 0b01) {
                Text(board.device.address, color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
            }
        }
        SignalBars(rssiBars(board.rssi), tint = Acab.accent)
        Spacer(Modifier.width(8.dp))
        Text("${board.rssi}", color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

@Composable
private fun ConnectingRow(text: String, onCancel: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(vertical = 44.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator(color = Acab.accent, strokeWidth = 3.dp,
                modifier = Modifier.size(28.dp))
            Text(text, color = Acab.dim, fontSize = 13.sp, fontFamily = Acab.mono)
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
        Modifier.fillMaxWidth().panel().padding(horizontal = 4.dp, vertical = 26.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        CircularProgressIndicator(color = Acab.accent, strokeWidth = 3.dp,
            modifier = Modifier.size(28.dp))
        Text("Reconnecting to your board…", color = Acab.text, fontSize = 15.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text(
            "It reconnects on its own the moment the board is back in range, even in the background. Keep waiting, or stop to scan for a different board.",
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
        Modifier.fillMaxWidth().padding(vertical = 36.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Filled.Lock, contentDescription = null, tint = Acab.dim,
            modifier = Modifier.size(34.dp))
        Text("Bluetooth not allowed", color = Acab.text, fontSize = 16.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text("Enable Bluetooth for beacons in Settings.", color = Acab.dim, fontSize = 12.sp,
            fontFamily = Acab.mono, textAlign = TextAlign.Center)
        Spacer(Modifier.height(2.dp))
        PrimaryButton("Open Settings", onOpenSettings)
    }
}

/** Shown when the bounded scan window ends with no boards heard. Names the two overwhelmingly
 *  likely causes (power, range) and offers the retry inline, so the timeout never reads as the
 *  app giving up silently. */
@Composable
private fun NoBoardsFoundPanel(onScanAgain: () -> Unit) {
    Column(
        Modifier.fillMaxWidth().panel(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("No boards found. Make sure your beacon is powered on and nearby, then scan again.",
            color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono, lineHeight = 17.sp)
        PrimaryButton("SCAN AGAIN", onScanAgain)
    }
}

/** Radio-off screen, shown when the phone's Bluetooth is turned off (mirrors iOS). Recovers on
 *  its own when the radio comes back, via the adapter receiver in AcabBleManager. */
@Composable
private fun RadioOffPanel() {
    Box(Modifier.fillMaxWidth().padding(vertical = 40.dp), contentAlignment = Alignment.Center) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Icon(Icons.Filled.BluetoothDisabled, contentDescription = null, tint = Acab.dim,
                modifier = Modifier.size(34.dp))
            Text("Bluetooth is off", color = Acab.text, fontSize = 16.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Text("Turn on Bluetooth to find your board.", color = Acab.dim, fontSize = 12.sp,
                fontFamily = Acab.mono, textAlign = TextAlign.Center)
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
            Text("history on this phone · browse and export, no board needed", color = Acab.dim,
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
            Text("the board that does the listening · soyboi.tech", color = Acab.dim,
                fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Icon(Icons.AutoMirrored.Filled.OpenInNew, contentDescription = null, tint = Acab.faint,
            modifier = Modifier.size(18.dp))
    }
}

/** Secondary text link to the same shop, for people who just want the plain URL. */
@Composable
private fun SoyboiLink(onClick: () -> Unit) {
    Text(
        "soyboi.tech",
        color = Acab.accent,
        fontSize = 10.5.sp,
        fontFamily = Acab.mono,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .clickable { onClick() }.padding(top = 2.dp),
    )
}

@Composable
private fun ScopeFootnote() {
    Text(
        "Passive detection only. beacons never jams, spoofs, or interferes.",
        color = Acab.dim,
        fontSize = 9.sp,
        fontFamily = Acab.mono,
        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
        textAlign = TextAlign.Center,
    )
}

/** Full-screen, board-less view of the persisted log (the Log tab is normally gated behind a
 *  READY link). Everything inside is phone-local: view, mark seen, export CSV, clear; the
 *  board-config writes no-op while disconnected. Mirrors the iOS savedLogCard sheet. */
@Composable
private fun SavedLogScreen(ble: AcabBleManager, onClose: () -> Unit) {
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
        DetailScreen(d, ble, onBack = { selected = null }, onOpenInMap = { lat, lon ->
            runCatching { uriHandler.openUri("geo:$lat,$lon?q=$lat,$lon") }
        })
    }
}

/** Prefs key: the permission prompt has been fired at least once (see the denied-for-good
 *  detection in AcabApp; rationale == false is only meaningful after a real ask). */
private const val KEY_PERMS_REQUESTED = "perms_requested"

/** What MainActivity.requiredPermissions gates scanning on, duplicated here (it's private to
 *  the activity) to ask "would the OS ever show the prompt again?". */
private fun scanPermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    else
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

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
                ota.message.ifBlank { "The board is rebooting into the new firmware. Keep the app open, it reconnects on its own." },
                color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 24.dp),
            )
            Spacer(Modifier.height(6.dp))
            Text("this can take up to a minute. don't unplug the board.",
                color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono, textAlign = TextAlign.Center)
        }
    }
}
