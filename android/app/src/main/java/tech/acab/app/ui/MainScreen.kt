package tech.acab.app.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Map
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.automirrored.outlined.ListAlt
import androidx.compose.material3.Icon
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.NavigationRail
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRailItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.movableContentOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.SaveableStateHolder
import androidx.compose.runtime.saveable.Saver
import androidx.compose.runtime.saveable.listSaver
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.viewmodel.compose.viewModel
import tech.acab.app.MainActivity
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.ui.theme.Acab

private enum class Tab(val label: String, val icon: ImageVector) {
    STATUS("Status", Icons.Filled.Radar),
    MAP("Map", Icons.Filled.Map),
    LOG("Log", Icons.AutoMirrored.Outlined.ListAlt),
    DEVICE("Beacon", Icons.Filled.Memory),   // user-facing label; enum name stays DEVICE (identifier)
}

/** String round-trip for the nullable Log-lens seed. LogFilter is a sealed interface, not
 *  Parcelable, so rememberSaveable needs this by hand; null itself round-trips (the framework
 *  stores the null and skips restore), so only the four concrete shapes are encoded. */
private val LogFilterSeedSaver = Saver<LogFilter?, String>(
    save = { f ->
        when (f) {
            null -> null
            LogFilter.All -> "ALL"
            LogFilter.NewOnly -> "NEW"
            LogFilter.OfflineOnly -> "OFFLINE"
            is LogFilter.Category -> "CAT:${f.key}"
        }
    },
    restore = { s ->
        when {
            s == "ALL" -> LogFilter.All
            s == "NEW" -> LogFilter.NewOnly
            s == "OFFLINE" -> LogFilter.OfflineOnly
            s.startsWith("CAT:") -> LogFilter.Category(s.removePrefix("CAT:"))
            else -> null
        }
    },
)

/** Four-tab shell: bottom nav swaps the body between screens. */
@Composable
fun MainScreen(
    ble: AcabBleManager,
    initialTab: Int = 0,
    initialLogFilter: LogFilter? = null,
    reconnecting: Boolean = false,
    locationGranted: Boolean = false,
    notificationsAvailable: Boolean = false,
    onRequestLocation: () -> Unit = {},
    modifier: Modifier = Modifier,
) {
    val demoMode by ble.demoMode.collectAsState()
    // Saveable: no configChanges are declared, so a dark-theme flip or multi-window resize
    // recreates the activity; without this the shell would snap back to the Status tab
    // (iOS SwiftUI state survives the equivalent).
    var tab by rememberSaveable { mutableIntStateOf(initialTab) }
    // The open dossier: a Detection SNAPSHOT, frozen at tap (MapScreen re-resolves the live row
    // on tap; the ~3 Hz feed must not recompose the whole dossier).
    var selected by remember { mutableStateOf<Detection?>(null) }
    // Rotation survival for the dossier: Detection is not Parcelable and its live fields would
    // be stale by restore anyway, so the SAVEABLE footprint is the ID STRING only. The first
    // detections pass after recreation re-resolves it against the log (dropped silently when
    // the row is gone - the same rule the vanish effect below applies to a live dossier).
    var selectedId by rememberSaveable { mutableStateOf<String?>(null) }
    // One-shot restore latch: holds the restored id only between recreation and the first
    // detections pass. A plain holder, not Compose state.
    val selectedIdToRestore = remember { arrayOf(selectedId) }
    // The ONLY way to open/close the dossier: writes the snapshot and its saveable id together.
    // A SideEffect mirror was tried first and zombie-restored closed dossiers: it lived in a
    // recompose scope that never READS `selected`, so with a quiet detections StateFlow (board
    // disconnected, nothing new heard) a manual close never cleared selectedId, and rotation
    // resurrected the dossier. Paired writes cannot desynchronize.
    val setSelected: (Detection?) -> Unit = { d ->
        selected = d
        selectedId = d?.id
    }
    // Filter seed handed to LogScreen; cleared on the next manual tab tap so a consumed
    // deep link doesn't keep re-applying the NEW lens forever. Saveable (with logScreenKey):
    // rotation right after a deep link must restore the same lens, not silently reset it.
    var logFilterSeed by rememberSaveable(stateSaver = LogFilterSeedSaver) { mutableStateOf(initialLogFilter) }
    var logScreenKey by rememberSaveable { mutableIntStateOf(0) }
    var openDetectorsToken by rememberSaveable { mutableIntStateOf(0) }
    var openHelpToken by rememberSaveable { mutableIntStateOf(0) }
    var openReadinessToken by rememberSaveable { mutableIntStateOf(0) }

    // The paused-Log feed lives in an activity-scoped ViewModel keyed by a FIXED string (see
    // LogScreen pauseStateKey = "main"), so it survives tab switches but is NOT reset by the
    // key(logScreenKey) re-seed a deep link uses. Resume it on every deep-link re-seed below, or
    // arriving at the Log via the offline-sync banner, a Live-Activity NEW link, or a Status
    // category tile lands on a stale frozen snapshot instead of the live rows those exist to show.
    val logPauseVm: LogViewModel = viewModel(key = "log-pause:main")

    // Per-tab UI state (Log lens, Map camera, Device drawer) parks here while a tab is off
    // screen, so switching tabs stops silently resetting filters, pause state and camera
    // position. The screens themselves use rememberSaveable, which this holder also routes
    // through onSaveInstanceState, so rotation and recreation restore the same state.
    val tabStateHolder = rememberSaveableStateHolder()

    // Status category tiles deep-link into the Log with that category's lens applied. Reuses
    // the deep-link seed + key bump so an already-composed LogScreen re-seeds too.
    val openLogCategory: (String) -> Unit = { key ->
        logFilterSeed = LogFilter.Category(key)
        logScreenKey++
        if (logPauseVm.paused) logPauseVm.resume()   // show the tile's live rows, not a frozen list
        setSelected(null)
        tab = Tab.LOG.ordinal
    }
    val openDetectorSettings: () -> Unit = {
        openDetectorsToken++
        setSelected(null)
        tab = Tab.DEVICE.ordinal
    }
    val openHelp: () -> Unit = {
        openHelpToken++
        setSelected(null)
        tab = Tab.DEVICE.ordinal
    }
    val openSetup: () -> Unit = {
        openReadinessToken++
        setSelected(null)
        tab = Tab.DEVICE.ordinal
    }

    // "Open in map" jump from a dossier's location thumbnail. The coordinate is stashed here
    // so the request survives the Map tab not being composed yet; MapScreen consumes it
    // exactly once and clears it back through onMapFocusConsumed. Saveable so an activity
    // recreation between the tap and the consume replays the jump instead of dropping it.
    var mapFocus by rememberSaveable(
        stateSaver = listSaver<Pair<Double, Double>?, Double>(
            save = { it?.let { (lat, lon) -> listOf(lat, lon) } ?: emptyList() },
            restore = { if (it.size == 2) it[0] to it[1] else null },
        ),
    ) { mutableStateOf<Pair<Double, Double>?>(null) }
    val openInMap: (Double, Double) -> Unit = { lat, lon ->
        mapFocus = lat to lon
        setSelected(null)          // close the dossier (overlay or inline pane alike)
        tab = Tab.MAP.ordinal      // no-op when the dossier was opened from the map itself
    }

    // Offline-buffer replay count banner (raised at replay-complete when n > 0). Shown over the
    // tabs so it's seen on reconnect regardless of the active tab; cleared only by its own
    // view/dismiss buttons, so a tab switch can't silently discard the one-shot count (iOS parity).
    val offlineBanner by ble.offlineSyncBanner.collectAsState()
    // Board-side replay shortfall (begin.n promised vs end.n sent): rides the same banner as an
    // attempt-level disclosure. The blocked row remains uncommitted in the ring for a later sync.
    val offlineUnreplayed by ble.offlineSyncUnreplayed.collectAsState()

    // Drive-mode notification tap (F27): land on the Log tab with the NEW filter active.
    // The signal lives on MainActivity because AcabApp sits between the activity and this
    // shell; it stays pending until this shell is composed (READY link) to consume it.
    val openLogNew by MainActivity.openLogNew
    LaunchedEffect(openLogNew) {
        if (openLogNew) {
            MainActivity.openLogNew.value = false
            logFilterSeed = LogFilter.NewOnly
            logScreenKey++   // re-seed LogScreen even if the Log tab is already showing
            if (logPauseVm.paused) logPauseVm.resume()   // surface the just-synced/NEW rows, not a frozen list
            tab = Tab.LOG.ordinal
            setSelected(null)  // an open dossier would cover the log
        }
    }

    // R8: if a dossier is open in the two-pane and its detection vanishes (clear log / bulk-ignore),
    // drop the selection so the pane returns to the placeholder instead of a stale dossier.
    // Selection belongs to the evidence log, not the active nearby projection. Muting a device
    // removes it from Status/Map but must not make an open dossier vanish or break rotation restore.
    val detections by ble.logDetections.collectAsState()
    LaunchedEffect(detections) {
        // Restore leg first: re-resolve a rotation-restored dossier id once, against the first
        // log pass after recreation. A missing row restores to "no dossier", never an error.
        selectedIdToRestore[0]?.let { id ->
            selectedIdToRestore[0] = null
            // setSelected on purpose: a missing row must also CLEAR the saveable id, or the
            // stale id would zombie-restore on the next rotation.
            setSelected(detections.firstOrNull { it.id == id })
        }
        // sid hoisted out of the closure so this ~3 Hz membership scan compares against a local
        // rather than re-reading through the optional on every compared row. Detection.id is a
        // plain stored val (see the id initializer in Models.kt), so nothing is allocated either
        // way: the hoist saves a field load, not string churn.
        selected?.let { s ->
            val sid = s.id
            if (detections.none { it.id == sid }) setSelected(null)
        }
    }

    // One MOVABLE instance of the tab content: the wide (NavigationRail) and compact (bottom
    // bar) shells below are two different call sites, and composing TabBody directly in each
    // meant crossing the 840dp width class (rotating a big phone, changing a foldable's
    // posture) destroyed and rebuilt the whole tab subtree - every per-tab rememberSaveable
    // (Log lens, Map camera, Device drawer) died in the same frame the SaveableStateHolder was
    // reparking it, because the leaving provider saves AFTER the entering one has already
    // restored-empty. movableContentOf MOVES the live composition between the call sites
    // instead, so nothing is recreated and nothing needs to save at all. Width-dependent
    // values ride as parameters (a captured `wide` would freeze at its first value); the
    // state-backed vars (tab, selected, seeds) are captured and recompose normally.
    val tabBody = remember {
        movableContentOf<Boolean, Dp, Modifier> { wide, detailWidth, modifier ->
            TabBody(
                ble = ble,
                tab = tab,
                selected = selected,
                wide = wide,
                detailWidth = detailWidth,
                stateHolder = tabStateHolder,
                logScreenKey = logScreenKey,
                logFilterSeed = logFilterSeed,
                mapFocus = mapFocus,
                onMapFocusConsumed = { mapFocus = null },
                onOpenInMap = openInMap,
                onOpenLogCategory = openLogCategory,
                onOpenDetectorSettings = openDetectorSettings,
                onOpenHelp = openHelp,
                onOpenSetup = openSetup,
                openDetectorsToken = openDetectorsToken,
                openHelpToken = openHelpToken,
                openReadinessToken = openReadinessToken,
                demoMode = demoMode,
                locationGranted = locationGranted,
                notificationsAvailable = notificationsAvailable,
                onRequestLocation = onRequestLocation,
                onSelect = { setSelected(it) },
                modifier = modifier,
            )
        }
    }

    // T4/T3/T5: layouts split on the viewport width class. Phone and small-tablet widths
    // (< 840.dp) keep the single column: Scaffold + bottom bar, each screen full width. The
    // Log/Map two-pane used to unlock at 600.dp, where reserving 380-420.dp for the detail
    // column left the OTHER pane unusably narrow; both panes only get a workable minimum at
    // >= 840.dp, so `wide` and the NavigationRail (`expanded`) now split together there.
    BoxWithConstraints(modifier.fillMaxSize()) {
        val wide = maxWidth >= 840.dp
        val expanded = maxWidth >= 840.dp
        val fullScreenDetailOpen = selected != null && (!wide || Tab.entries[tab] == Tab.STATUS)
        val baseSemanticsModifier = if (fullScreenDetailOpen) {
            Modifier.clearAndSetSemantics { }
        } else Modifier
        // The inline detail pane's width: 380.dp keeps the companion pane >= ~380.dp at the
        // 840 breakpoint (minus the rail); the roomier 420 only where there is width to spare.
        val detailWidth: Dp = if (maxWidth >= 1100.dp) 420.dp else 380.dp

        if (expanded) {
            // targetSdk 36 enforces edge-to-edge, and unlike the compact branch (whose Scaffold
            // insets its content) this Row had no inset handling at all: landscape content drew
            // under the status bar, gesture bar and display cutout. background BEFORE the inset
            // padding so bg still paints to the physical edges; windowInsetsPadding consumes
            // what it applies, so the rail (which handles its own safe-drawing insets
            // internally) doesn't double-pad.
            Row(
                Modifier.fillMaxSize().background(Acab.bg)
                    .then(baseSemanticsModifier)
                    .windowInsetsPadding(WindowInsets.safeDrawing),
            ) {
                NavigationRail(containerColor = Acab.bg2) {
                    Tab.entries.forEachIndexed { i, t ->
                        NavigationRailItem(
                            selected = tab == i,
                            onClick = { logFilterSeed = initialLogFilter; tab = i },
                            // The adjacent NavigationRailItem label names the destination; a
                            // second description on the glyph makes TalkBack announce it twice.
                            icon = { Icon(t.icon, contentDescription = null) },
                            label = { Text(t.label) },
                            colors = NavigationRailItemDefaults.colors(
                                selectedIconColor = Acab.accent,
                                selectedTextColor = Acab.accent,
                                indicatorColor = Acab.bg3,
                                unselectedIconColor = Acab.faint,
                                unselectedTextColor = Acab.faint,
                            ),
                        )
                    }
                }
                Column(Modifier.weight(1f).fillMaxSize()) {
                    // Reserve real layout space for the sample escape hatch. The former overlay
                    // sat directly on top of every screen's title and first controls.
                    if (demoMode && !fullScreenDetailOpen) {
                        SampleDataBanner(onExit = { ble.exitDemo() }, includeStatusInset = false)
                    }
                    tabBody(wide, detailWidth, Modifier.weight(1f).fillMaxSize())
                }
            }
        } else {
            Scaffold(
                modifier = baseSemanticsModifier,
                containerColor = Acab.bg,
                topBar = {
                    if (demoMode && !fullScreenDetailOpen) {
                        SampleDataBanner(onExit = { ble.exitDemo() })
                    }
                },
                bottomBar = {
                    NavigationBar(containerColor = Acab.bg2) {
                        Tab.entries.forEachIndexed { i, t ->
                            NavigationBarItem(
                                selected = tab == i,
                                onClick = { logFilterSeed = initialLogFilter; tab = i },
                                icon = { Icon(t.icon, contentDescription = null) },
                                label = { Text(t.label) },
                                colors = NavigationBarItemDefaults.colors(
                                    selectedIconColor = Acab.accent,
                                    selectedTextColor = Acab.accent,
                                    indicatorColor = Acab.bg3,
                                    unselectedIconColor = Acab.faint,
                                    unselectedTextColor = Acab.faint,
                                ),
                            )
                        }
                    }
                },
            ) { inner ->
                tabBody(wide, detailWidth, Modifier.fillMaxSize().padding(inner))
            }
        }

        // dossier sits full-screen over the tabs; system back closes it (not the app).
        // At `wide` on LOG/MAP the dossier is already inline (drawn by TabBody), so the
        // overlay only fires in compact, or on STATUS where there's no inline pane.
        BackHandler(enabled = selected != null) { setSelected(null) }
        if (fullScreenDetailOpen) {
            selected?.let { d ->
                DetailScreen(
                    detection = d,
                    ble = ble,
                    onBack = { setSelected(null) },
                    onOpenInMap = openInMap,
                    locationGranted = locationGranted,
                    onRequestLocation = onRequestLocation,
                )
            }
        }

        // Reconnect count banner, pinned near the top over whatever tab is showing. "view"
        // reuses the Live-Activity deep-link path (openLogNew) to land on the Log/NEW lens.
        if (!fullScreenDetailOpen && !demoMode) offlineBanner?.let { n ->
            OfflineSyncBanner(
                n = n,
                unreplayed = offlineUnreplayed,
                onView = {
                    ble.clearOfflineSyncBanner()
                    setSelected(null)             // an open dossier would cover the log
                    MainActivity.openLogNew.value = true
                },
                onDismiss = { ble.clearOfflineSyncBanner() },
                modifier = Modifier.align(Alignment.TopCenter),
            )
        }

        if (reconnecting) {
            ReconnectingBanner(Modifier.align(Alignment.TopCenter))
        }
    }
}

/** Always-visible escape hatch while the synthetic store is active. */
@Composable
private fun SampleDataBanner(
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
    includeStatusInset: Boolean = true,
) {
    Box(
        modifier.fillMaxWidth()
            .then(if (includeStatusInset) Modifier.statusBarsPadding() else Modifier)
            .padding(Acab.pad),
        contentAlignment = Alignment.TopCenter,
    ) {
        Row(
            Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.accent.copy(alpha = 0.55f), RoundedCornerShape(Acab.radiusSm))
                .padding(start = 14.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "sample data, not nearby devices",
                color = Acab.text,
                fontSize = 11.sp,
                fontFamily = Acab.mono,
                modifier = Modifier.weight(1f),
            )
            Box(
                Modifier.minimumInteractiveComponentSize()
                    .clip(RoundedCornerShape(50))
                    .border(1.dp, Acab.lineStrong, RoundedCornerShape(50))
                    .clickable(onClick = onExit)
                    .padding(horizontal = 12.dp, vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("EXIT SAMPLE DATA", color = Acab.accent, fontSize = 10.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
        }
    }
}

/** A transient link drop is status, not navigation: keep the shell and its field-work state
 *  usable while the manager reconnects in the background. */
@Composable
private fun ReconnectingBanner(modifier: Modifier = Modifier) {
    Box(
        modifier.fillMaxWidth().statusBarsPadding().padding(Acab.pad),
        contentAlignment = Alignment.TopCenter,
    ) {
        Row(
            Modifier.widthIn(max = 640.dp).fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
                .padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            CircularProgressIndicator(
                color = Acab.accent,
                strokeWidth = 2.dp,
                modifier = Modifier.size(16.dp),
            )
            Text(
                "reconnecting to beacon, your work stays open",
                color = Acab.text,
                fontSize = 11.sp,
                fontFamily = Acab.mono,
                modifier = Modifier.weight(1f),
            )
        }
    }
}

/** Transient, dismissible banner raised when the beacon reconnects and replays records it
 *  buffered while the phone was away. "view" jumps to the Log's NEW lens; the x dismisses it.
 *  Copy voice: all-lowercase, a comma, no em-dash. Singular "1 detection" when n == 1. */
@Composable
private fun OfflineSyncBanner(n: Int, unreplayed: Int = 0, onView: () -> Unit, onDismiss: () -> Unit, modifier: Modifier = Modifier) {
    // R9: match the iOS OfflineSyncBannerView anatomy (1e button/radius rules) - radiusSm corners,
    // a tray glyph in accent, mono 11.5 message, and a filled-capsule "view". Copy is unchanged.
    val shape = RoundedCornerShape(Acab.radiusSm)
    // TopCenter: the row is capped at 640dp, and the Box's default TopStart alignment left it
    // hugging the left edge on anything wider than the cap (tablet, landscape).
    Box(modifier.fillMaxWidth().statusBarsPadding().padding(Acab.pad),
        contentAlignment = Alignment.TopCenter) {
        Row(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .background(Acab.bg2, shape)
                .border(1.dp, Acab.lineStrong, shape)
                .padding(start = 14.dp, end = 8.dp, top = 10.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Inventory2, contentDescription = null,
                tint = Acab.accent, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(10.dp))
            Text(
                // The unreplayed clause describes THIS attempt, not permanent evidence loss: an
                // over-MTU row remains uncommitted in the board's ring and a later sync can retry
                // it. Kept byte-identical to iOS OfflineSyncBannerView.message.
                when {
                    n == 0 && unreplayed > 0 ->
                        (if (unreplayed == 1) "1 buffered detection couldn't be replayed from the beacon"
                         else "$unreplayed buffered detections couldn't be replayed from the beacon")
                    unreplayed > 0 ->
                        (if (n == 1) "1 detection recorded while you were away"
                         else "$n detections recorded while you were away") +
                            " ($unreplayed more couldn't be replayed)"
                    n == 1 -> "1 detection recorded while you were away"
                    else -> "$n detections recorded while you were away"
                },
                color = Acab.text, fontSize = 11.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            // minimumInteractiveComponentSize: the 30dp pills keep their look, the touch
            // target grows to the 48dp accessibility floor.
            Box(
                Modifier
                    .minimumInteractiveComponentSize()
                    .height(30.dp)
                    .background(Acab.accent, RoundedCornerShape(50))
                    .clickable(onClick = onView)
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("view", color = Acab.onAccent, fontSize = 11.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 0.5.sp)
            }
            Box(
                Modifier.minimumInteractiveComponentSize().size(30.dp).clickable(onClick = onDismiss),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, contentDescription = "Dismiss",
                    tint = Acab.faint, modifier = Modifier.size(16.dp))
            }
        }
    }
}

/** The tab content, shared by the bottom-bar (compact/medium) and nav-rail (expanded)
 *  shells. In compact (`wide` false) each screen fills the single column exactly as before.
 *  When `wide`, Log and Map split into a list/map pane plus an inline detail pane. */
@Composable
private fun TabBody(
    ble: AcabBleManager,
    tab: Int,
    selected: Detection?,
    wide: Boolean,
    detailWidth: Dp,
    stateHolder: SaveableStateHolder,
    logScreenKey: Int,
    logFilterSeed: LogFilter?,
    mapFocus: Pair<Double, Double>?,
    onMapFocusConsumed: () -> Unit,
    onOpenInMap: (Double, Double) -> Unit,
    onOpenLogCategory: (String) -> Unit,
    onOpenDetectorSettings: () -> Unit,
    onOpenHelp: () -> Unit,
    onOpenSetup: () -> Unit,
    openDetectorsToken: Int,
    openHelpToken: Int,
    openReadinessToken: Int,
    demoMode: Boolean,
    locationGranted: Boolean,
    notificationsAvailable: Boolean,
    onRequestLocation: () -> Unit,
    onSelect: (Detection?) -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(modifier) {
        // SaveableStateProvider keyed by tab: each tab's rememberSaveable state (Log lens,
        // Map camera, Device drawer) parks while the tab is off screen instead of being lost
        // with the composition, so a tab switch is no longer a silent reset.
        stateHolder.SaveableStateProvider(Tab.entries[tab].name) {
        when (Tab.entries[tab]) {
            Tab.STATUS -> StatusScreen(ble, onSelect = { onSelect(it) },
                onOpenLogCategory = onOpenLogCategory,
                onOpenDetectorSettings = onOpenDetectorSettings,
                onOpenHelp = onOpenHelp,
                locationGranted = locationGranted,
                notificationsAvailable = notificationsAvailable,
                onOpenSetup = onOpenSetup)
            Tab.MAP -> {
                // T5: keep the pin visible by parking the dossier in a right rail; the map
                // stays full-width until something is selected. ONE MapScreen call site
                // whatever the width class or selection: a Row with a single weighted child
                // renders identically to a bare full-size map, and the detail pane enters and
                // leaves BESIDE the map's slot instead of swapping it. The old shape branched
                // on `wide && selected != null` with MapScreen on both sides, so on a tablet
                // every pin tap and every dossier close tore down the MapView (camera, follow
                // mode, category lens) and snapped the map back to follow-location.
                Row(Modifier.fillMaxSize()) {
                    Box(Modifier.weight(1f).fillMaxSize()) {
                        MapScreen(ble, onSelect = { onSelect(it) },
                            focus = mapFocus, onFocusConsumed = onMapFocusConsumed)
                        if (!locationGranted && !demoMode) {
                            LocationContextBanner(
                                onAllow = onRequestLocation,
                                modifier = Modifier.align(Alignment.TopCenter),
                            )
                        }
                    }
                    if (wide && selected != null) {
                        Box(Modifier.width(detailWidth).fillMaxSize()) {
                            DetailScreen(selected, ble, onBack = { onSelect(null) },
                                onOpenInMap = onOpenInMap,
                                locationGranted = locationGranted,
                                onRequestLocation = onRequestLocation)
                        }
                    }
                }
            }
            Tab.LOG -> {
                // T3: a fixed list column beside an inline detail pane; tapping a row fills
                // the pane instead of pushing a full-screen dossier. Same single-call-site
                // rule as MAP: the list column is the constant, only its width rule and the
                // divider + detail pane flip with `wide`, so LogScreen keeps one composition
                // slot and the movable TabBody can carry the lens across the 840dp crossing
                // (two call sites would re-key every rememberSaveable inside it).
                // A New dot means "arrived since you last looked at the log": advance the
                // seen-watermark when this branch leaves composition, i.e. when the user switches
                // AWAY from the Log tab. Sits OUTSIDE key(logScreenKey) below, so a deep-link
                // re-key (openLogNew) does not dispose it and empty the NEW lens; and opening a
                // dossier keeps tab == LOG, so drilling into a row never counts as leaving.
                // Mirrors iOS MainTabView.onChange(of: tab). markAllSeen is a cheap locked read.
                // Capture the mode when this Log composition is created. exitDemo flips the
                // manager's demo flag before Compose disposes this branch; checking only inside
                // markAllSeen at disposal time would therefore let sample navigation advance the
                // genuine persisted watermark during the exit edge.
                val openedInDemo = demoMode
                DisposableEffect(Unit) {
                    onDispose { if (!openedInDemo) ble.markAllSeen() }
                }
                Row(Modifier.fillMaxSize()) {
                    val listWidth = if (wide) Modifier.width(380.dp) else Modifier.weight(1f)
                    Box(listWidth.fillMaxSize()) {
                        key(logScreenKey) {
                            LogScreen(
                                ble,
                                onSelect = { onSelect(it) },
                                initialFilter = logFilterSeed,
                                // compact never highlights: the dossier is a full-screen
                                // overlay there, not a row selection (matches the old shape)
                                selectedId = if (wide) selected?.id else null,
                            )
                        }
                    }
                    if (wide) {
                        VerticalDivider(color = Acab.line)
                        Box(Modifier.weight(1f).fillMaxSize()) {
                            selected?.let {
                                DetailScreen(it, ble, onBack = { onSelect(null) },
                                    onOpenInMap = onOpenInMap,
                                    locationGranted = locationGranted,
                                    onRequestLocation = onRequestLocation)
                            } ?: EmptyDetailPlaceholder()
                        }
                    }
                }
            }
            Tab.DEVICE -> DeviceScreen(
                ble = ble,
                openDetectorsToken = openDetectorsToken,
                openHelpToken = openHelpToken,
                openReadinessToken = openReadinessToken,
                locationGranted = locationGranted,
                onRequestLocation = onRequestLocation,
            )
        }
        }
    }
}

/** Optional permission request lives at the feature boundary instead of the pairing prompt. The
 * map remains usable for already-geotagged detections while this non-blocking banner is present. */
@Composable
private fun LocationContextBanner(onAllow: () -> Unit, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().padding(Acab.pad), contentAlignment = Alignment.TopCenter) {
        Row(
            Modifier.widthIn(max = 520.dp).fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radiusSm))
                .padding(start = 12.dp, end = 8.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.LocationOn, contentDescription = null, tint = Acab.accent,
                modifier = Modifier.size(17.dp))
            Spacer(Modifier.width(9.dp))
            Text(
                "optional: adds your position and future hit pins. detection works without it. location stays on your devices and is never uploaded automatically.",
                color = Acab.text,
                fontSize = 10.5.sp,
                fontFamily = Acab.mono,
                lineHeight = 15.sp,
                modifier = Modifier.weight(1f),
            )
            Box(
                Modifier.minimumInteractiveComponentSize().clip(RoundedCornerShape(50))
                    .background(Acab.accent).clickable(onClick = onAllow)
                    .padding(horizontal = 11.dp, vertical = 7.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text("ALLOW", color = Acab.onAccent, fontSize = 10.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
        }
    }
}

/** Resting state of the two-pane detail column: nothing is open yet. */
@Composable
private fun EmptyDetailPlaceholder() {
    Box(
        Modifier.fillMaxSize().background(Acab.bg),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(
                Icons.AutoMirrored.Outlined.ListAlt,
                contentDescription = null,
                tint = Acab.line,
                modifier = Modifier.size(40.dp),
            )
            Text("Select a detection", color = Acab.dim, fontSize = 14.sp,
                fontWeight = FontWeight.Medium)
            Text("Pick a row to open its full dossier here.", color = Acab.faint,
                fontSize = 11.sp, fontFamily = Acab.mono)
        }
    }
}
