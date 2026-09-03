package tech.acab.app.ui

import android.content.Context
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.textTone
import tech.acab.app.ui.theme.tone
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

internal fun shouldShowFinishSetupCard(demo: Boolean, dismissed: Boolean): Boolean =
    !demo && !dismissed

internal enum class FinishSetupLiveState(val label: String) {
    ACTIVE("ACTIVE"),
    BLOCKED("BLOCKED"),
    WAITING("WAITING"),
    OFF("OFF"),
}

internal fun finishSetupLiveState(
    wanted: Boolean,
    active: Boolean,
    notificationsAvailable: Boolean,
): FinishSetupLiveState = when {
    !wanted -> FinishSetupLiveState.OFF
    !notificationsAvailable -> FinishSetupLiveState.BLOCKED
    active -> FinishSetupLiveState.ACTIVE
    else -> FinishSetupLiveState.WAITING
}

internal fun finishSetupPhoneAlertsLabel(
    enabled: Boolean,
    notificationsAvailable: Boolean,
): String = when {
    !enabled -> "OFF"
    !notificationsAvailable -> "BLOCKED"
    else -> "ON"
}

private const val FINISH_SETUP_DISMISSED = "finish_setup_dismissed"

/** Status / home: the at-a-glance "how many eyes are on me" view.
 *  [onOpenLogCategory] jumps to the Log tab with the given category filter applied; the
 *  count tiles call it so a number here is one tap from its rows. */
@Composable
fun StatusScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit = {},
    onOpenLogCategory: (String) -> Unit = {},
    onOpenDetectorSettings: () -> Unit = {},
    onOpenHelp: () -> Unit = {},
    locationGranted: Boolean = false,
    notificationsAvailable: Boolean = false,
    onOpenSetup: () -> Unit = {},
) {
    val detections by ble.detections.collectAsState()
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val liveWanted by ble.driveModeWanted.collectAsState()
    val liveRunning by ble.driveMode.collectAsState()
    val syncing by ble.syncingOfflineLog.collectAsState()
    val syncCount by ble.offlineSyncCount.collectAsState()
    val syncTotal by ble.offlineSyncTotal.collectAsState()
    val context = LocalContext.current
    val setupPrefs = remember { context.getSharedPreferences("acab_ui", Context.MODE_PRIVATE) }
    var finishSetupDismissed by remember {
        mutableStateOf(setupPrefs.getBoolean(FINISH_SETUP_DISMISSED, false))
    }
    val phoneAlertsOn = DetectionNotifier.anyEnabled(context)
    val showFinishSetup = shouldShowFinishSetupCard(demo, finishSetupDismissed)
    // mutedBySystem costs two Binder IPCs and its answer feeds only the finish-setup card,
    // while this screen recomposes at ~1-3 Hz under the tick and detection flows - so it is
    // asked only while the card can show, never per recomposition (zero IPCs once dismissed).
    // ON_RESUME is the one moment the answer can have changed: system settings and the
    // permission dialog both pause the activity (same pattern as DeviceScreen's notifGranted).
    // Keying the effect on showFinishSetup makes addObserver's sync-up ON_RESUME re-ask the
    // moment the card becomes showable again (e.g. sample mode ending), not just on a real
    // return from background.
    var phoneAlertsAvailable by remember {
        mutableStateOf(!showFinishSetup || !DetectionNotifier.mutedBySystem(context))
    }
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner, showFinishSetup) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME && showFinishSetup) {
                phoneAlertsAvailable = !DetectionNotifier.mutedBySystem(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
    val finishLiveState = finishSetupLiveState(
        wanted = liveWanted,
        active = liveRunning && ble.driveServiceReady,
        notificationsAvailable = notificationsAvailable,
    )
    val finishPhoneAlerts = finishSetupPhoneAlertsLabel(
        enabled = phoneAlertsOn,
        notificationsAvailable = phoneAlertsAvailable,
    )
    val dismissFinishSetup = {
        finishSetupDismissed = true
        setupPrefs.edit().putBoolean(FINISH_SETUP_DISMISSED, true).apply()
    }

    // Staleness is a function of the clock, not of anything the UI observes, and eviction is
    // cap-only, so nothing recomposes this screen when a device simply stops being heard.
    // Without this tick the radar freezes at its last-publish count and a Flock heard twenty
    // minutes ago keeps winning "STRONGEST SIGNAL · LIVE" for the rest of the session.
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) {
        while (true) {
            delay(1_000)
            tick++
        }
    }
    // "Nearby" means heard in the last ~45s. Offline rows are the board's buffer replayed, never
    // a live sighting, so they're out regardless of how fileHistory happened to stamp them.
    // Demo rows are exempt: they're a fixture stamped once at seed time, and ageing them out
    // would empty the tour's radar 45s in.
    //
    // freshIdSet, not isStale per row: this block re-runs on every ~3 Hz publish AND on the tick,
    // over the whole active feed, so the per-row form took storeLock up to FEED_CAP times a pass
    // on the main thread - the same monitor the BLE thread holds for every arriving advert. One
    // locked pass instead, the way LogScreen already reads newIdSet. Same window, same one-sided
    // comparison, so the radar counts exactly what it counted before.
    val nearby = remember(detections, tick, demo) {
        if (demo) detections else {
            val fresh = ble.freshIdSet(detections)
            detections.filter { !it.offline && it.id in fresh }
        }
    }
    val nearest = remember(nearby) { nearby.maxByOrNull { it.rssi } }

    // The tiles sit directly under the radar's "DEVICES NEARBY" count, so they have to measure
    // the same thing. Off the whole store they were session totals, and the strip could read
    // "ALPR 3" under a radar honestly reporting 0 nearby. One grouped pass per publish
    // instead of an O(n) scan per tile per recomposition.
    val typeCounts = remember(nearby) { nearby.groupingBy { it.type }.eachCount() }
    fun count(type: DeviceType) = typeCounts[type] ?: 0

    // Headline tracks radio state so a pulsing dot never claims a scan that isn't happening.
    // status.ble/status.wifi are toggle INTENT, not liveness: on a dual-radio board a dead nRF
    // leaves status.ble true while the whole BLE half is dark, so coAlive is what says it's
    // actually listening (single-radio boards omit it, hence != false rather than == true).
    // A null status is "no frame yet", not "radios off"; treating it as off flashes RADIOS OFF
    // in the gap between connect and the first frame. Same handling as the Log's empty state.
    val s = status
    // No frame YET, not "no board": this screen only exists once the link is READY, and the
    // first status frame still has to cross the link (finishReady's queued read sits behind the
    // handshake writes, and the board's connect-time notify is async), so there is a real gap on
    // every connect. Claiming "not scanning" across it is the same lie in the other direction, so a
    // null frame reads as scanning until the board tells us otherwise. Same as iOS.
    // A nRF mid BLE DFU is silent on purpose (it reboots into its bootloader), which reads as
    // coAlive == false through no fault of the radio. nrfUpdating is the board saying so, so an
    // update in flight gets its own line instead of the crimson "radio fault" one.
    val bleUpdating = s != null && s.ble && s.coAlive == false && s.nrfUpdating
    // An update is not a fault, but the nRF really is dark for that window: bleListening is the
    // honest liveness bit, so the sweep and the dot key off it and the radar parks instead of
    // animating over a silent radio (iOS parity, DashboardView.bleLive).
    val bleListening = s == null || (s.ble && s.coAlive != false)
    val bleFault = s != null && s.ble && s.coAlive == false && !s.nrfUpdating
    val wifiUp = s == null || s.wifi
    val scanning = demo || bleListening || wifiUp
    val scanLabel = when {
        demo -> "SAMPLE DATA"
        // before the plain bleListening branches: an update is not a fault, but the BLE half
        // really is down for the window, so say that rather than claim a BLE scan.
        bleUpdating && wifiUp -> "SCANNING · WI-FI ONLY · UPDATING CO-PROCESSOR"
        bleUpdating -> "UPDATING CO-PROCESSOR · NOT SCANNING"
        bleListening && wifiUp -> "SCANNING · BLE · WI-FI"
        bleFault && wifiUp -> "SCANNING · WI-FI ONLY · BLE RADIO FAULT"
        bleListening -> "SCANNING · BLE"
        wifiUp -> "SCANNING · WI-FI"
        bleFault -> "BLE RADIO FAULT · NOT SCANNING"
        else -> "RADIOS OFF · NOT SCANNING"
    }

    // T2: cap readable content width so tablets/landscape stop stretching one column edge to
    // edge; at phone width the 640 cap is a no-op. Box scrolls + centers, inner Column is capped.
    Box(
        Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState()),
        contentAlignment = Alignment.TopCenter,
    ) {
    Column(
        Modifier
            .widthIn(max = 640.dp)
            .fillMaxWidth()
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp, bottom = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        // header: wordmark + link chip
        Row(verticalAlignment = Alignment.CenterVertically) {
            BrandMark(size = 21)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onOpenHelp) {
                Icon(Icons.AutoMirrored.Outlined.HelpOutline, contentDescription = "help and support",
                    tint = Acab.dim, modifier = Modifier.size(19.dp))
            }
            LinkChip(version = status?.version, demo = demo)
        }

        // OS-level "remove animations": the looping ornaments (dot pulse, radar sweep) park.
        val reduceMotion = rememberReduceMotion()

        Row(verticalAlignment = Alignment.CenterVertically) {
            // the scan dot breathes so the header reads as live, not a static badge;
            // the animated alpha is read inside graphicsLayer (draw phase), so the
            // pulse repaints one dot instead of recomposing the whole screen at 60fps.
            // It only breathes while something is actually listening: a pulse over
            // "RADIOS OFF" is the lie this header exists to not tell.
            // Null under reduce-motion: no transition even runs, the dot just holds solid.
            val blink = if (reduceMotion) null else rememberInfiniteTransition(label = "scanDot").animateFloat(
                initialValue = 1f, targetValue = 0.2f,
                animationSpec = infiniteRepeatable(tween(800, easing = LinearEasing), RepeatMode.Reverse),
                label = "scanDotAlpha",
            )
            Box(
                Modifier
                    .size(7.dp)
                    .graphicsLayer { alpha = if (scanning) (blink?.value ?: 1f) else 1f }
                    // With WI-FI up and the nRF dead, scanning is still true, so a plain accent
                    // dot pulses identically to a healthy scan while half the detection surface
                    // is dark. Amber is the only thing separating the two at a glance.
                    .background(
                        if (!scanning) Acab.faint else if (bleFault) Acab.warn else Acab.accent,
                        CircleShape,
                    ),
            )
            Spacer(Modifier.size(8.dp))
            Kicker(scanLabel, color = if (bleFault) Acab.warn else Acab.dim)
            // Far-right recency note: everything on the radar / in the counts was heard within the
            // ~45s "nearby" window (ble.freshIdSet), so say so - only when there's actually something up.
            if (!demo && nearby.isNotEmpty()) {
                Spacer(Modifier.weight(1f))
                Kicker("SEEN < 45s", color = Acab.faint)
            }
        }

        if (bleFault) CoprocFaultPill() else if (bleUpdating) CoprocUpdatingPill()

        // While the board replays its offline buffer on reconnect: a subtle, non-blocking pill.
        // determinate once the board's hist lead-in supplies a total; a live count until then.
        if (syncing) SyncingPill(count = syncCount, total = syncTotal)

        if (showFinishSetup) {
            FinishSetupCard(
                liveState = finishLiveState,
                locationOn = locationGranted,
                phoneAlertsState = finishPhoneAlerts,
                bufferOn = status?.bufOn,
                onReview = {
                    dismissFinishSetup()
                    onOpenSetup()
                },
                onDismiss = dismissFinishSetup,
            )
        }

        // T2: keep the scope from stretching screen-wide on tablets; capped + centered.
        RadarScope(detections = nearby, scanning = scanning, reduceMotion = reduceMotion,
            modifier = Modifier.align(Alignment.CenterHorizontally).widthIn(max = 420.dp))

        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.Center) { PunkLine() }

        // per-category counts: one strip of compact tiles. Network Cam rides the same
        // strip as Log and Map so Status shows every category the other tabs do (netcamTone +
        // CameraOutdoor come from the type's own tone()/icon(), like every other tile here).
        // Each tile deep-links to the Log with that category's filter, so a count is one tap
        // from its rows. Six-across squeezes to slivers at large font scales, so past 1.5x the
        // strip wraps to two rows of three.
        val strip = listOf(
            StripTile(DeviceType.FLOCK_CAMERA, "ALPR",
                count(DeviceType.FLOCK_CAMERA) + count(DeviceType.FLOCK_RAVEN), "ALPR", status?.flock),
            StripTile(DeviceType.DRONE, "DRONE", count(DeviceType.DRONE), "DRONE", status?.drone),
            StripTile(DeviceType.BODY_CAM, "BODY", count(DeviceType.BODY_CAM), "BODY CAM", status?.bodyCam),
            StripTile(DeviceType.TRACKER, "TRKR", count(DeviceType.TRACKER), "TRACKER", status?.tracker),
            StripTile(DeviceType.GLASSES, "GLAS", count(DeviceType.GLASSES), "GLASSES", status?.glasses),
            StripTile(DeviceType.NETWORK_CAMERA, "NETCAM",
                count(DeviceType.NETWORK_CAMERA), "CAMERA", status?.ncam),
        )
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val perRow = if (maxWidth < 360.dp || LocalDensity.current.fontScale >= 1.5f) 3 else strip.size
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                strip.chunked(perRow).forEach { rowTiles ->
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        rowTiles.forEach { t ->
                            CountTile(t.type, t.label, t.n, t.enabled, Modifier.weight(1f)) {
                                if (t.enabled == false) onOpenDetectorSettings()
                                else onOpenLogCategory(t.filterKey)
                            }
                        }
                    }
                }
            }
        }

        if (nearest != null) NearestCard(nearest, onSelect)
    }
    }
}

/** Categories render lowercase, brand-wide ("body cam", "drone"). Mirrors iOS categoryTitle. */
private fun categoryTitle(cat: String): String = cat.lowercase()

/** One tile of the category strip: glyph/tone source, short caption, live count, and the
 *  DeviceType.category key the Log filter matches on. */
private data class StripTile(
    val type: DeviceType,
    val label: String,
    val n: Int,
    val filterKey: String,
    val enabled: Boolean?,
)

/** The "Beacons" wordmark. */
@Composable
private fun BrandMark(size: Int) {
    Row(verticalAlignment = Alignment.Bottom) {
        Text("beacons", color = Acab.text, fontSize = size.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.display)
    }
}

/** Optional setup review kept out of the one-time tour. Every choice remains usable as-is. */
@Composable
private fun FinishSetupCard(
    liveState: FinishSetupLiveState,
    locationOn: Boolean,
    phoneAlertsState: String,
    bufferOn: Boolean?,
    onReview: () -> Unit,
    onDismiss: () -> Unit,
) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Column(
        Modifier.fillMaxWidth().background(Acab.bg2, shape)
            .border(1.dp, Acab.lineStrong, shape).padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text("finish setup", color = Acab.text, fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold)
                Text("optional choices you can review anytime in Beacon", color = Acab.faint,
                    fontSize = 10.sp, fontFamily = Acab.mono)
            }
            Icon(
                Icons.Filled.Close,
                contentDescription = "dismiss finish setup",
                tint = Acab.dim,
                modifier = Modifier.minimumInteractiveComponentSize().size(20.dp)
                    .clickable(role = Role.Button, onClick = onDismiss),
            )
        }
        SetupStateRow("Live Mode", liveState.label)
        SetupStateRow("Location", if (locationOn) "ALLOWED" else "OPTIONAL")
        SetupStateRow("Phone alerts", phoneAlertsState)
        SetupStateRow("Offline buffer", when (bufferOn) { true -> "ON"; false -> "OFF"; null -> "CHECK" })
        Row(
            Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                .clip(RoundedCornerShape(50))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(50))
                .clickable(onClickLabel = "review setup in Beacon", role = Role.Button, onClick = onReview)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
        ) {
            Text("REVIEW IN BEACON", color = Acab.accentText, fontSize = 10.sp,
                fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            Spacer(Modifier.size(6.dp))
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.accent,
                modifier = Modifier.size(14.dp))
        }
    }
}

@Composable
private fun SetupStateRow(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = Acab.dim, fontSize = 11.sp, modifier = Modifier.weight(1f))
        Text(value, color = Acab.faint, fontSize = 9.5.sp, fontWeight = FontWeight.Bold,
            fontFamily = Acab.mono, letterSpacing = 0.7.sp)
    }
}

// (LinkChip now lives in Components.kt as the one shared status pill; the Map
// header uses the same composable.)

/** Radar: concentric rings, crosshairs, a rotating sweep, and a dot per detection.
 *  Rings are honest: blips snap to the NEAR/MID/FAR ring of their signal band, and the
 *  caption says outright that the angle (a stable MAC hash) carries no bearing.
 *  [detections] is the nearby set, already filtered for staleness by the caller; the count in
 *  the middle is its size, so the number and the blips can never disagree. The sweep only turns
 *  while [scanning], since a sweeping radar over a dead radio reads as a live all-clear. */
@Composable
private fun RadarScope(detections: List<Detection>, scanning: Boolean, reduceMotion: Boolean, modifier: Modifier = Modifier) {
    // Under reduce-motion no transition runs at all; the wedge still draws, parked, so the
    // scope keeps its look without the loop.
    val sweep = if (reduceMotion) null else rememberInfiniteTransition(label = "sweep").animateFloat(
        initialValue = 0f, targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(4500, easing = LinearEasing), RepeatMode.Restart),
        label = "sweepAngle",
    )
    // Cap at 14 so the scope stays readable when there's a lot around.
    val dots = detections.take(14)

    // NEAR / MID / FAR band labels, fading with distance (45/38/30% text). Ornamental dial
    // furniture, so the size is divided back out of the font scale: at 2x text these labels
    // would collide with the rings and the center count, and they carry no information the
    // caption below does not restate.
    val fontScale = LocalDensity.current.fontScale
    val measurer = rememberTextMeasurer()
    val ringLabels = remember(measurer, fontScale) {
        listOf("NEAR" to 0.45f, "MID" to 0.38f, "FAR" to 0.30f).map { (word, alpha) ->
            measurer.measure(
                AnnotatedString(word),
                TextStyle(
                    color = Acab.text.copy(alpha = alpha), fontSize = (7.5f / fontScale).sp,
                    fontFamily = Acab.mono, fontWeight = FontWeight.Medium, letterSpacing = 1.sp,
                ),
            )
        }
    }

    Column(modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(
            Modifier.fillMaxWidth().aspectRatio(1f).padding(top = 4.dp),
            contentAlignment = Alignment.Center,
        ) {
            Canvas(Modifier.fillMaxSize()) {
                val r = size.minDimension / 2f
                val c = Offset(size.width / 2f, size.height / 2f)

                // three rings, the outer one stronger
                for (i in 1..3) {
                    drawCircle(
                        color = if (i == 3) Acab.lineStrong else Acab.line,
                        radius = r * i / 3f, center = c, style = Stroke(1.dp.toPx()),
                    )
                }
                // crosshairs
                drawLine(Acab.line, Offset(c.x, c.y - r), Offset(c.x, c.y + r), 1.dp.toPx())
                drawLine(Acab.line, Offset(c.x - r, c.y), Offset(c.x + r, c.y), 1.dp.toPx())

                // ring labels on the vertical axis above center; FAR sits just inside
                // the outer ring so it doesn't clip at the canvas edge
                for ((i, layout) in ringLabels.withIndex()) {
                    val ringR = r * (i + 1) / 3f
                    val y = if (i == 2) c.y - ringR + 4.dp.toPx()
                    else c.y - ringR - layout.size.height - 3.dp.toPx()
                    drawText(layout, topLeft = Offset(c.x - layout.size.width / 2f, y))
                }

                // rotating sweep, a soft crimson wedge. Reading `sweep` inside the branch means
                // a parked radar also stops re-drawing at 60fps, not just stops lying. With
                // reduce-motion on, sweep is null and the wedge draws once, parked at 0.
                if (scanning) {
                    rotate(sweep?.value ?: 0f, c) {
                        drawArc(
                            brush = Brush.sweepGradient(
                                0.72f to Color.Transparent,
                                0.99f to Acab.accentGlow,
                                1.0f to Color.Transparent,
                                center = c,
                            ),
                            startAngle = 0f, sweepAngle = 360f, useCenter = true,
                            topLeft = Offset(c.x - r, c.y - r), size = Size(r * 2, r * 2),
                        )
                    }
                }

                // one blip per detection: angle from the MAC (stable), radius snapped
                // to the ring of its signal band (bars 4 = near, 3 = mid, weaker = far)
                for (d in dots) {
                    val angle = (abs(d.mac.hashCode()) % 360) * (PI / 180.0)
                    val bars = rssiBars(d.rssi)
                    val rad = when {
                        bars >= 4 -> r / 3f
                        bars == 3 -> r * 2f / 3f
                        else -> r
                    }
                    val pos = Offset(c.x + (cos(angle) * rad).toFloat(), c.y + (sin(angle) * rad).toFloat())
                    // two-layer glow under a solid core
                    drawCircle(d.type.tone().copy(alpha = 0.12f), 12.dp.toPx(), pos)
                    drawCircle(d.type.tone().copy(alpha = 0.35f), 7.dp.toPx(), pos)
                    drawCircle(d.type.tone(), 4.dp.toPx(), pos)
                }
            }

            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("${detections.size}", color = Acab.text, fontSize = 62.sp, fontWeight = FontWeight.Bold)
                // "active" makes clear this count is the recently-seen set (already filtered for
                // staleness), so it reading lower than the full-session Log count is self-explanatory.
                // pinned: the kicker is an ornament under a 62sp number that already scales;
                // iOS pins it the same way so the dial composition holds at large font scales.
                Kicker("ACTIVE NEARBY", pinned = true)
            }
        }

        // The one fact that stops the radar being read as a direction finder, promoted from a
        // 9sp whisper to a legible pill (parity with iOS doing the same). The line under it
        // keeps the longer explanation.
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Row(
                Modifier
                    .background(Acab.bg2, RoundedCornerShape(50))
                    .border(1.dp, Acab.line, RoundedCornerShape(50))
                    .padding(horizontal = 14.dp, vertical = 7.dp),
            ) {
                Text(
                    "SIGNAL STRENGTH ONLY · NO DIRECTION",
                    color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                    fontWeight = FontWeight.Bold, letterSpacing = 1.sp, textAlign = TextAlign.Center,
                )
            }
            Text(
                "rings = signal strength · position around the dial means nothing",
                color = Acab.faint, fontSize = 9.5.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** The nRF fault is a whole half of the detection surface going dark, so it can't live only on
 *  the Device tab. Short form here, Device carries the full what-to-try. Amber rather than the
 *  Device banner's crimson: this sits beside the scan dot, and a crimson pill next to a crimson
 *  dot reads as decoration instead of a warning. */
@Composable
private fun CoprocFaultPill() {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.warn.copy(alpha = 0.4f), shape)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(Icons.Filled.WarningAmber, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(12.dp))
        Spacer(Modifier.size(8.dp))
        Text(
            "nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.",
            color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** Same slot as CoprocFaultPill, for the one case where the dark nRF is intentional: it's
 *  taking new firmware. Says the same thing about coverage without the alarm colours. */
@Composable
private fun CoprocUpdatingPill() {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        CircularProgressIndicator(color = Acab.dim, strokeWidth = 1.5.dp,
            modifier = Modifier.size(12.dp))
        Spacer(Modifier.size(8.dp))
        Text(
            "updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** Subtle inline pill shown while the board is draining its offline buffer on reconnect.
 *  Determinate once the board's hist lead-in supplies a total (a live count until then), with a
 *  breathing dot and, when records have started landing, a live "N so far" count. Non-blocking, no modal. */
@Composable
private fun SyncingPill(count: Int, total: Int) {
    val shape = RoundedCornerShape(50)
    // Reduce-motion parks the breathing dot (the text already says syncing is in progress).
    val reduceMotion = rememberReduceMotion()
    val blink = if (reduceMotion) null else rememberInfiniteTransition(label = "syncDot").animateFloat(
        initialValue = 1f, targetValue = 0.25f,
        animationSpec = infiniteRepeatable(tween(700, easing = LinearEasing), RepeatMode.Reverse),
        label = "syncDotAlpha",
    )
    Row(
        Modifier
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier
                .size(6.dp)
                .graphicsLayer { alpha = blink?.value ?: 1f }
                .background(Acab.dim, CircleShape),
        )
        Text(
            when {
                total > 0 -> "syncing offline log, $count of $total"
                count > 0 -> "syncing offline log, $count so far"
                else -> "syncing offline log…"
            },
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
        )
    }
}

/** One compact count tile in the category strip. Tapping deep-links to the Log filtered to
 *  this category; the click label tells a screen reader that is what the tap does. */
@Composable
private fun CountTile(
    type: DeviceType,
    label: String,
    n: Int,
    enabled: Boolean?,
    modifier: Modifier = Modifier,
    onClick: () -> Unit = {},
) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    val off = enabled == false
    val spokenLabel = when (label) {
        "ALPR" -> "License plate reader"
        "DRONE" -> "Drone"
        "BODY" -> "Body camera"
        "TRKR" -> "Tracker"
        "GLAS" -> "Glasses"
        "NETCAM" -> "Network camera"
        else -> label
    }
    Column(
        modifier
            .minimumInteractiveComponentSize()
            .clip(shape)
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClickLabel = if (off) "open detector settings" else "show in log",
                role = Role.Button, onClick = onClick)
            .semantics(mergeDescendants = true) {
                contentDescription = if (off) "$spokenLabel, detector off"
                else "$spokenLabel, $n detection${if (n == 1) "" else "s"}"
            }
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        // null: the tile is ONE merged clickable node and the label Text below already names
        // it; a contentDescription here made TalkBack read the category twice per tile.
        Icon(type.icon(), contentDescription = null,
            tint = if (off || n == 0) Acab.faint else type.tone(), modifier = Modifier.size(14.dp))
        Text(if (off) "off" else "$n", color = if (off || n == 0) Acab.faint else Acab.text,
            fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = if (off || n == 0) Acab.faint else type.textTone(),
            fontSize = 8.sp, letterSpacing = 1.sp, fontWeight = FontWeight.Medium,
            fontFamily = Acab.mono, maxLines = 1)
    }
}

/** Hero card for the closest device (highest RSSI). Tappable, opens the dossier. */
@Composable
private fun NearestCard(d: Detection, onSelect: (Detection) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Kicker("STRONGEST SIGNAL · LIVE", color = Acab.accent)
        // Inline the panel so the click ripple sits ABOVE the opaque bg and clipped to the
        // rounded shape (panel() bundles bg+border+padding, which would hide a ripple behind it).
        Row(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(Acab.radius))
                .background(Acab.bg2, RoundedCornerShape(Acab.radius))
                .border(1.dp, Acab.lineStrong, RoundedCornerShape(Acab.radius))
                .clickable { onSelect(d) }
                .padding(Acab.padCard),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CatGlyph(d.type, size = 40, filled = true)
            Spacer(Modifier.size(12.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(categoryTitle(d.type.category),
                        color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.size(6.dp))
                    Text("NODE ${nodeName(d.mac)}", color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                }
                Text("${d.sourceLabel} · seen ${d.count}× · ~${approxMeters(d.rssi)} m",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
            }
            Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
                Text("${d.rssi}", color = Acab.accentText, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono)
                SignalBars(rssiBars(d.rssi), tint = d.type.tone())
            }
            Spacer(Modifier.size(10.dp))
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
                modifier = Modifier.size(20.dp))
        }
    }
}

/** "they're watching. watch back." Pinned against fontScale (divide by it) like iOS: this is
 *  brand ornament, not information, and at accessibility sizes it wrapped into the layout's
 *  budget while carrying nothing a screen reader or low-vision user needs larger. */
@Composable
private fun PunkLine() {
    val fs = LocalDensity.current.fontScale
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("they're watching. ", color = Acab.dim, fontSize = 14.sp / fs, fontWeight = FontWeight.Medium)
        Text("watch back.", color = Acab.accentText, fontSize = 14.sp / fs, fontWeight = FontWeight.Medium,
            fontStyle = FontStyle.Italic)
    }
}

/** Last 4 hex of the MAC, uppercased: a short node handle. */
private fun nodeName(mac: String): String = mac.replace(":", "").takeLast(4).uppercase()
