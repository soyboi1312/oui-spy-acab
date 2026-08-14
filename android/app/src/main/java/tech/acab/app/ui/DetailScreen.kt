package tech.acab.app.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ColorMatrix
import android.graphics.ColorMatrixColorFilter
import androidx.core.content.ContextCompat
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.CheckBox
import androidx.compose.material.icons.filled.CheckBoxOutlineBlank
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT
import kotlin.math.roundToInt
import kotlinx.coroutines.delay
import android.view.MotionEvent
import org.osmdroid.tileprovider.tilesource.TileSourceFactory
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.CustomZoomButtonsController
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.Marker
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.FaqContent
import tech.acab.app.model.DeviceType
import tech.acab.app.model.FollowEvidence
import tech.acab.app.net.AlprStore
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.isOuiMatch
import tech.acab.app.model.companyIdText
import tech.acab.app.model.methodLabel
import tech.acab.app.model.ouiVendor
import tech.acab.app.model.sourceLabel
import tech.acab.app.model.validCoord
import tech.acab.app.model.vendor
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import tech.acab.app.model.maker
import tech.acab.app.model.isChipsetRegistrant

/** Detection dossier: top bar, title block, match-quality verdict (with a confirm-it
 *  checklist for weak hits), live RSSI + band, a slim stat pair, and an identity panel
 *  with first/last seen. Mirrors the iOS detail sheet. */
@Composable
fun DetailScreen(
    detection: Detection,
    ble: AcabBleManager,
    onBack: () -> Unit,
    onOpenInMap: (Double, Double) -> Unit,
) {
    // Which FAQ answer a RELATED HELP row asked for; non-null opens the Help sheet on it.
    var helpDeepLink by remember { mutableStateOf<String?>(null) }
    // The pushed-in dossier is a frozen snapshot, so shadow it with the live record
    // from the feed; "seen N×" and friends keep updating while the screen is open.
    // The id is hoisted once so the ~3 Hz scan below compares against a local rather than
    // re-reading detection.id each pass.
    val detections by ble.detections.collectAsState()
    val targetId = remember(detection) { detection.id }
    val d = detections.firstOrNull { it.id == targetId } ?: detection
    val tone = d.type.tone()
    val trend = ble.rssiTrend(d.id)
    val stale = ble.isStale(d.id)
    // Buffered rows the board had no clock for carry an ordering key, not a time. Rendering that
    // as an age reads "24 years ago" with total confidence, so say what we actually know instead.
    val firstSeen = ble.firstSeen(d.id)
    val lastSeen = ble.lastSeen(d.id)
    val approxFirst = ble.isApproxTime(firstSeen)
    // How this row's first-seen stamp was arrived at. Exact for a live sighting, in which case
    // nothing below changes. The revision key is what makes a screen already open when a drain
    // finishes pick up the bracketing it just did (see AcabBleManager.timeBasisRev).
    val timeRev by ble.timeBasisRev.collectAsState()
    val timeBasis = remember(d.id, timeRev) { ble.timeBasis(d.id) }
    // The reconstructed / bracketed / unknown line, or null when the stamp is a plain clock
    // reading and the existing relative age is the honest thing to show.
    val firstSeenText = timeBasis.primaryText()
        ?: if (approxFirst) APPROX_TIME else relativeAgo(firstSeen)
    val watchedList by ble.watched.collectAsState()
    val isWatched = watchedList.any { it.mac == d.mac.lowercase() }
    // Confirm before starring a randomized address: it rotates, so the star may stop matching.
    var showRandomWarn by remember { mutableStateOf(false) }
    // A star refused at the firmware's 256-entry cap: surface it instead of the WATCH tap
    // silently doing nothing (the manager's watchDevice returns without adding at the cap).
    var showWatchlistFull by remember { mutableStateOf(false) }
    var showRssiInfo by remember { mutableStateOf(false) }   // info dot next to SIGNAL explains the RSSI graph
    // One watch/star toggle shared by the CONFIRM IT chip and the big button below.
    val toggleWatch: () -> Unit = {
        if (isWatched) {
            ble.unwatch(d.mac)
        } else if (watchedList.size >= WATCH_CAP) {
            showWatchlistFull = true   // cap first, like the manager: say so rather than no-op
        } else if (d.isRandomAddr) {
            showRandomWarn = true   // confirm first: a rotating address may stop matching
        } else {
            ble.watchDevice(d)
        }
    }

    // T2: cap the readable dossier width so tablets/landscape stop stretching one column edge to
    // edge; at phone width the 640 cap is a no-op. The outer Box centers the capped content; the
    // top bar and scrim below stay full-bleed. The map thumbnail rides inside the capped column.
    Box(
        Modifier.fillMaxSize().background(Acab.bg)
            .then(if (helpDeepLink != null) Modifier.clearAndSetSemantics { } else Modifier)
            // Compact dossiers are siblings of Scaffold and otherwise draw under status,
            // navigation and cutout insets. In wide panes the parent already consumes these,
            // so Compose applies zero here rather than double-padding.
            .windowInsetsPadding(WindowInsets.safeDrawing),
        contentAlignment = Alignment.TopCenter,
    ) {
        Column(
            Modifier
                .widthIn(max = 640.dp)
                .fillMaxWidth()
                .fillMaxHeight()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = Acab.pad)
                .padding(top = 64.dp, bottom = 24.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // ---- title: glyph, label, last 4 of the MAC ----
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                CatGlyph(d.type, size = 54, filled = true)
                Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                    // Category lowercased like iOS: the caps in the pill belong to the class
                    // label, the category reads as content.
                    BadgePill("${d.type.category.lowercase()} · ${d.type.classLabel}", tone)
                    Text("NODE ${nodeName(d.mac)}", color = Acab.text,
                        fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    // NEITHER branch may consult the OUI lookup: the OUI resolves a Flock
                    // Falcon to its Liteon WiFi module and would head the ALPR dossier with
                    // "Liteon" instead of "Flock Safety". The OUI reading still shows in the
                    // identity panel below, where it is labelled as such. maker is null for
                    // Flock, so the ALPR case is unaffected by the new first branch.
                    Text(d.maker ?: d.vendor, color = Acab.dim,
                        fontSize = 11.sp, fontFamily = Acab.mono)
                }
            }

            // ---- how good the match is: verdict, meter, plain-language explainer ----
            MatchQualityPanel(d)

            // ---- the FAQ answers that speak to THIS category ----
            RelatedHelpPanel(d) { helpDeepLink = it }

            // ---- heads-up that THIS category's signatures aren't field-verified ----
            if (d.type.isExperimental) ExperimentalNote(d.type)

            // ---- signal: big RSSI + band + sparkline, dimmed if stale ----
            Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Kicker(if (stale) "SIGNAL · STALE" else "SIGNAL · LIVE",
                        color = if (stale) Acab.dim else Acab.faint)
                    Box(
                        Modifier.minimumInteractiveComponentSize()
                            .clickable { showRssiInfo = !showRssiInfo },
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Outlined.Info,
                            contentDescription = "What the RSSI graph means",
                            tint = Acab.dim, modifier = Modifier.size(14.dp))
                    }
                    Spacer(Modifier.weight(1f))
                    SignalBars(rssiBars(d.rssi), tint = tone)
                }
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                            Text("${d.rssi}", color = Acab.text, fontSize = 30.sp,
                                fontWeight = FontWeight.SemiBold, fontFamily = Acab.display)
                            Text("dBm", color = Acab.dim, fontSize = 11.sp,
                                fontFamily = Acab.mono, modifier = Modifier.padding(bottom = 4.dp))
                        }
                        Kicker("RSSI")
                    }
                    Spacer(Modifier.weight(1f))
                    Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text(d.sourceLabel, color = tone, fontSize = 20.sp,
                            fontWeight = FontWeight.SemiBold, fontFamily = Acab.display)
                        Kicker("BAND")
                    }
                }
                Sparkline(trend, tone, stale, Modifier.fillMaxWidth().height(46.dp))
                if (showRssiInfo) {
                    Text("RSSI is signal strength, moment to moment. closer to 0 is stronger, so the line climbs as you get nearer the source and drops as you move away, use it to home in on a hit.",
                        color = Acab.dim, fontSize = 11.5.sp, fontFamily = Acab.mono, lineHeight = 16.sp)
                }
            }

            // ---- slim stat pair: matched-on / confidence live in the panel above ----
            StatGrid(
                listOf(
                    "SIGNAL" to "${d.rssi} dBm · ${d.sourceLabel}",
                    // A reconstructed first-sighting still has a real age, but it is an age
                    // measured off a derived point, so it gets the "~" that marks it as one.
                    // A bracketed row has no point to measure from, so it says so.
                    "SIGHTINGS" to when {
                        timeBasis is TimeBasis.Reconstructed -> "${d.count} · first ~${relativeAgo(firstSeen)}"
                        timeBasis is TimeBasis.Bracketed -> "${d.count} · time bounded"
                        approxFirst -> "${d.count} · time unknown"
                        else -> "${d.count} · first ${relativeAgo(firstSeen)}"
                    },
                ),
            )

            // ---- weak / chipset-only hits get a field checklist instead of a shrug ----
            if (d.isOuiMatch || d.confidence < 50) {
                // null firstSeen on an approx row drops the "over 18m" clause rather than
                // quoting a span measured off the ordering key.
                ConfirmItPanel(d, firstSeen = if (approxFirst) null else firstSeen,
                    watched = isWatched, onWatch = toggleWatch)
            }

            // ---- identity ----
            Column(Modifier.fillMaxWidth().panel()) {
                Kicker("IDENTITY")
                Spacer(Modifier.size(4.dp))
                val rows = buildList {
                    // TWO ROWS, NOT ONE. The old single "Vendor" row rendered a union of a real
                    // IEEE registrant and a per-type constant, so it printed "Vendor: IP camera"
                    // and "Vendor: Unknown vendor": the category restated under a label that
                    // claims an identification the detector never made. Renaming it "Category"
                    // would have been worse, not better, since the same row also holds "Liteon"
                    // on a genuine Falcon and "Motorola Solutions" on a body cam.
                    //
                    // So: Maker = who built it (payload-derived, absorbing the old Brand row),
                    // OUI vendor = who owns the MAC block, annotated when that is only the radio
                    // module. When neither resolves NOTHING RENDERS, which is the actual fix.
                    // Row-for-row identical to iOS DetectionDetailView.identityPanel.
                    val mk = d.maker ?: d.type.brand
                    mk?.let { add("Maker" to it) }
                    d.ouiVendor?.takeIf { it != mk }?.let {
                        add("OUI vendor" to if (isChipsetRegistrant(it)) "$it · chipset" else it)
                    }
                    d.companyIdText?.let { add("Company ID" to it) }
                    add("Identifier" to d.mac)
                    add(FIRST_SEEN_LABEL to firstSeenText)
                    // isApproxTime alone is not enough here. It screens Bracketed and Unknown,
                    // which keep the pseudo stamp, but a Reconstructed row holds a REAL ms value,
                    // so it passed straight through and rendered a bare "3h ago" as if the phone
                    // had watched the clock. Qualify it: the instant is derived, and a device that
                    // exists purely from the offline buffer has no live last-seen at all.
                    // Asked per STAMP, not per row (iOS timeBasis(for:stamp:)): a device replayed
                    // from the buffer and THEN heard live has a derived First seen and a genuine
                    // Last seen, and each has to say so for itself. A live sighting advances
                    // lastSeenAt past the drained stamp, so equality with firstSeen is what "this
                    // stamp IS the reconstructed one" looks like from here.
                    add("Last seen" to when {
                        ble.isApproxTime(lastSeen) -> APPROX_TIME
                        timeBasis is TimeBasis.Reconstructed && lastSeen == firstSeen ->
                            "${relativeAgo(lastSeen)} · reconstructed"
                        else -> relativeAgo(lastSeen)
                    })
                    d.name?.takeIf { it.isNotEmpty() }?.let { add("Name" to it) }
                    d.rid?.takeIf { it.isNotEmpty() }?.let { add("UAS ID" to it) }
                    // No separate "Manufacturer" row: maker's step 2 IS ridManufacturer, so it
                    // now renders as Maker above. Keeping both printed the same company twice,
                    // rows apart, under two different labels.
                    //
                    // The Detail row stays VERBATIM and is load-bearing, not decoration. Every
                    // hedge the firmware authors wrote lives only here now that maker parses the
                    // same string: " on wifi" (a device on the network, not necessarily a camera
                    // pointed at you), "(offline)" (a separated tag, NOT buffer replay), "or
                    // Quest" (glasses_signatures.h says that caveat must be present), and "gear,
                    // no Remote ID" (may be a controller, not an aircraft). Do not condense it.
                    d.detail?.takeIf { it.isNotEmpty() }?.let { add("Detail" to it) }
                    // Numeric lat/lon alongside the mini-map: the coordinates are the actionable
                    // datum in an evidence export, and the operator (pilot) fix is the whole point
                    // of a drone detection, so show both as text, not only as a pin.
                    run { val la = d.lat; val lo = d.lon
                        if (la != null && lo != null && validCoord(la, lo)) add("Position" to "%.5f, %.5f".format(la, lo)) }
                    d.altitude?.let { add("Altitude" to "$it m") }
                    d.speedH?.let { add("Speed" to "$it m/s") }
                    d.speedV?.takeIf { it != 0 }?.let { add("Vert. speed" to "$it m/s") }
                    d.heading?.let { add("Heading" to "$it°") }
                    d.heightAGL?.let { add("Height AGL" to "$it m") }
                    run { val pla = d.pilotLat; val plo = d.pilotLon
                        if (pla != null && plo != null && validCoord(pla, plo)) add("Operator pos" to "%.5f, %.5f".format(pla, plo)) }
                    d.pilotAlt?.let { add("Operator alt" to "$it m") }
                    d.ridStatusLabel?.let { add("Status" to it) }
                }
                rows.forEachIndexed { i, (label, value) ->
                    IdRow(label, value, last = i == rows.lastIndex,
                        // Only the first-seen row carries a derived time, so it is the only one
                        // that has anything to qualify.
                        note = if (label == FIRST_SEEN_LABEL) timeBasis.qualifierText() else null)
                }
                WhyFlagged(d, tone)
            }

            // ---- location: static map thumbnail centered on the sighting ----
            ble.mapCoord(d)?.let { (lat, lon) -> LocationPanel(d, lat, lon, onOpenInMap) }

            // ---- has this tag been near you across more than one place? trackers only ----
            // Deliberately BELOW the location panel and ABOVE the actions: it is the last thing
            // read before deciding to star or ignore, and it is a reading of the map above it.
            if (d.type == DeviceType.TRACKER) FollowEvidencePanel(d.id, d.type, ble, timeBasis)

            // ---- actions ----
            CopyMacButton(d.mac)
            WatchButton(watched = isWatched, onToggle = toggleWatch)
            IgnoreButton { ble.ignoreDevice(d); onBack() }
        }

        // Randomized-address confirm sheet: star it anyway, but say plainly why it may lapse.
        // One dialog, one body, picked by type inside, so a tracker never stacks a second prompt.
        if (showRandomWarn) {
            RandomAddrWarnDialog(
                type = d.type,
                onDismiss = { showRandomWarn = false },
                // Re-check the cap on confirm: the list could have filled while the sheet sat open.
                onConfirm = {
                    showRandomWarn = false
                    if (watchedList.size >= WATCH_CAP) showWatchlistFull = true
                    else ble.watchDevice(d)
                },
            )
        }

        // Refused star at the cap, iOS "Watchlist full" alert word for word.
        if (showWatchlistFull) {
            WatchlistFullDialog { showWatchlistFull = false }
        }

        // ---- top bar: back arrow + centered kicker, on a bg->clear scrim like iOS ----
        Row(
            Modifier
                .fillMaxWidth()
                .background(Brush.verticalGradient(listOf(Acab.bg, Acab.bg.copy(alpha = 0f))))
                .padding(horizontal = Acab.pad)
                .padding(top = 8.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .minimumInteractiveComponentSize()
                    .size(36.dp)
                    .background(Acab.bg2, RoundedCornerShape(50))
                    .border(1.dp, Acab.line, RoundedCornerShape(50))
                    .clickable(onClick = onBack),
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back",
                    tint = Acab.text, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.weight(1f))
            Kicker("DETECTION")
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(48.dp))   // match the back button's 48dp layout target
        }
    }

    // A RELATED HELP row opens the bundled FAQ ON that answer. Rendered as a full-bleed overlay
    // rather than a nav push because the dossier is itself already a pushed screen here, and
    // stacking a second push makes the back button ambiguous. BackHandler in the overlay takes
    // precedence, so back closes Help and leaves the dossier where it was.
    helpDeepLink?.let { id ->
        HelpOverlay(questionId = id, onClose = { helpDeepLink = null })
    }
}

/** Full-bleed Help, opened on a specific answer from a dossier's RELATED HELP row. */
@Composable
private fun HelpOverlay(questionId: String, onClose: () -> Unit) {
    BackHandler(enabled = true, onBack = onClose)
    Column(
        Modifier
            .fillMaxSize()
            .background(Acab.bg)
            // A semantics-free touch shield: child controls and scrolling consume first; only
            // otherwise-unhandled events are stopped from reaching the dossier underneath.
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Final)
                        event.changes.filterNot { it.isConsumed }.forEach { it.consume() }
                    }
                }
            }
            .verticalScroll(rememberScrollState()),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Row(
            Modifier.widthIn(max = 640.dp).fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                Modifier
                    .minimumInteractiveComponentSize()
                    .size(36.dp)
                    .clip(RoundedCornerShape(Acab.radius))
                    .background(Acab.bg2)
                    .clickable { onClose() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back",
                    tint = Acab.text, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.weight(1f))
            Kicker("HELP")
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(48.dp))
        }
        Box(Modifier.widthIn(max = 640.dp).fillMaxWidth()) {
            HelpScreen(scrollToId = questionId)
        }
        Spacer(Modifier.height(24.dp))
    }
}

/** Category badge pill in the type tone, like the iOS detail header. */
@Composable
private fun BadgePill(label: String, tone: Color) {
    val shape = RoundedCornerShape(50)
    Box(
        Modifier
            .background(tone.copy(alpha = 0.13f), shape)
            .border(1.dp, tone.copy(alpha = 0.35f), shape)
            .padding(horizontal = 9.dp, vertical = 4.dp),
    ) {
        Text(label, color = tone, fontSize = 9.5.sp, letterSpacing = 1.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/**
 * RELATED HELP: the one or two FAQ answers that speak to THIS category, deep-linked.
 *
 * Sits directly under match quality because that is where the doubt lands. Someone looking at a 45%
 * hit, or an ALPR pin with nothing detected next to it, is already asking a question, and until now
 * the answer only existed on the website. A reporter using the device hit exactly that and
 * concluded the hardware was broken.
 *
 * Renders nothing for categories with no mapped questions (nearby device and unknown, whose
 * faqKey is ""). Every real category has entries now, glasses and body cam included, and the
 * drift check enforces that; the panel sits above each category's own experimental note where
 * one exists. Mirrors iOS relatedHelpPanel.
 */
@Composable
private fun RelatedHelpPanel(d: Detection, onOpen: (String) -> Unit) {
    val context = LocalContext.current
    val qs = remember(d.type) { FaqContent.get(context).related(d.type) }
    if (qs.isEmpty()) return
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Kicker("RELATED HELP")
        qs.forEachIndexed { i, q ->
            Row(
                Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                    .clickable { onOpen(q.id) }.padding(vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    q.q, color = Acab.text, fontSize = 13.5.sp, lineHeight = 18.sp,
                    fontFamily = Acab.display, modifier = Modifier.weight(1f),
                )
                Spacer(Modifier.width(10.dp))
                Text("\u203A", color = Acab.faint, fontSize = 13.sp, fontFamily = Acab.mono)
            }
            if (i < qs.size - 1) {
                Box(Modifier.fillMaxWidth().height(1.dp).background(Acab.line))
            }
        }
    }
}

/** MATCH QUALITY: verdict + 5-segment meter + a plain-language line about what actually
 *  matched. Weak matches go loud amber; strong ones stay calm white. Crimson is reserved
 *  for the category, never for certainty. */
@Composable
private fun MatchQualityPanel(d: Detection) {
    val weak = d.confidence < 50
    val shape = RoundedCornerShape(Acab.radius)
    Column(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, shape)
            .border(1.dp, if (weak) Acab.warn.copy(alpha = 0.4f) else Acab.line, shape)
            .padding(Acab.pad),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Kicker("MATCH QUALITY")
            Spacer(Modifier.weight(1f))
            MethodChip(d)
        }
        Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(verdictLabel(d.confidence), color = verdictColor(d.confidence),
                fontSize = 22.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.display)
            Text("${d.confidence}%", color = Acab.dim, fontSize = 11.sp,
                fontFamily = Acab.mono, modifier = Modifier.padding(bottom = 3.dp))
        }
        MatchMeter(d.confidence, weak)
        Text(plainMatchLine(d), color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Top-right chip naming the match method. OUI-only is the false-positive-prone case,
 *  so it gets the loud tinted-amber treatment; everything else stays neutral. */
@Composable
private fun MethodChip(d: Detection) {
    val amber = d.isOuiMatch
    val label = when {
        // Some OUI hits land on the maker's OWN registered block (Axon, Utility, Motorola
        // Solutions, and every camera brand in netcam_signatures.h), not a chipset shared
        // with unrelated gear, so "chipset only" would understate what we know. What's
        // uncertain is which of the vendor's products this is, which is why it keeps the
        // amber weak-match treatment. Keyed on `maker` rather than bodyCamSigDetail so
        // network cameras stop sitting on the wrong side of this exact distinction, and so
        // this stops being a THIRD hardcoded copy of the body-cam wire contract.
        d.method == 1 && d.maker != null -> "OUI · VENDOR ONLY"
        d.method == 1 -> "OUI · CHIPSET ONLY"
        d.method == 2 -> "NAME MATCH"
        else -> d.methodLabel.lowercase()   // "manufacturer id", "service uuid", ... like iOS
    }
    val shape = RoundedCornerShape(4.dp)
    Box(
        Modifier
            .background(if (amber) Acab.warn.copy(alpha = 0.14f) else Acab.bg3, shape)
            .border(1.dp, if (amber) Acab.warn.copy(alpha = 0.4f) else Acab.line, shape)
            .padding(horizontal = 6.dp, vertical = 3.dp),
    ) {
        Text(label, color = if (amber) Acab.warn else Acab.dim, fontSize = 8.5.sp,
            letterSpacing = 1.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Five 6dp segments, filled = round(pct/20). Amber when weak, white otherwise. */
@Composable
private fun MatchMeter(pct: Int, weak: Boolean) {
    val filled = (pct / 20.0).roundToInt().coerceIn(0, 5)
    val fill = if (weak) Acab.warn else Acab.text
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        repeat(5) { i ->
            Box(
                Modifier
                    .weight(1f)
                    .height(6.dp)
                    .background(if (i < filled) fill else Acab.bg3, RoundedCornerShape(3.dp))
            )
        }
    }
}

private fun verdictLabel(pct: Int): String = when {
    pct < 50 -> "Weak match, verify"
    pct < 80 -> "Partial match"
    else -> "Strong match"
}

private fun verdictColor(pct: Int): Color = when {
    pct < 50 -> Acab.warn
    pct < 80 -> Acab.dim
    else -> Acab.text
}

/** What actually matched, in plain language, composed from the method and OUI vendor.
 *  Copy mirrors iOS matchExplainer word for word. */
private fun plainMatchLine(d: Detection): AnnotatedString = buildAnnotatedString {
    // Body cam covers four signatures of very different weight under one label, so the
    // generic per-method line is too vague here (and its "shared chipset" wording is
    // wrong for a vendor's own OUI block). Name the signature that fired instead.
    val sig = d.bodyCamSigDetail
    if (sig != null) {
        appendSignatureExplainer(d, sig)
        return@buildAnnotatedString
    }
    // Replayed from the offline buffer: the stored record (firmware det_log.h) has no detail
    // field, so the signature is gone for a buffered body-cam hit even though the method and
    // confidence survived. Do NOT fall through to the OUI branch below, which would
    // confidently assert "shared chipset" wording that is simply wrong for a vendor's own
    // OUI block, and flatly false if the original hit was the conf-90 BWC DEVICE payload
    // tag. Say what we actually still know instead.
    if (d.type == DeviceType.BODY_CAM) {
        append("Matched a body-worn camera signature. This record came from the offline buffer, which doesn't keep which signature fired.")
        return@buildAnnotatedString
    }
    when (d.method) {
        1 -> {   // OUI: one of two very different things, and the copy has to say which
            // When `maker` resolved, the block is the MAKER'S OWN registration (Hikvision's
            // 44:19:B6, Axon's 00:25:DF), so the old "only the radio chipset matched" line was
            // flatly false, and would have contradicted a row now titled "Hikvision" on the same
            // screen. What stays open is which of that maker's products this is.
            val mk = d.maker
            if (mk != null) {
                append("Matched ")
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(mk) }
                append("'s own registered MAC block. That names the maker, not which of their products this is.")
                return@buildAnnotatedString
            }
            // No maker: the block really does name a chipset vendor, the false-positive-prone case.
            val isFlock = d.type == DeviceType.FLOCK_CAMERA || d.type == DeviceType.FLOCK_RAVEN
            val part = if (isFlock) "a part Flock shares with routers and home cameras"
                       else "a part shared with routers and home cameras"
            val vendor = d.ouiVendor
            if (vendor != null) {
                append("Only the radio chipset matched: ")
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(vendor) }
                append(", $part. The name and service IDs didn't match.")
            } else {
                append("Only the radio chipset matched, $part. The name and service IDs didn't match.")
            }
        }
        2 -> append("The name this device broadcasts matched a known signature.")
        3 -> append("The manufacturer ID in the advertisement matched a known signature.")
        4 -> append("The device advertises a service UUID tied to this hardware.")
        5 -> append("The WiFi network name matched a known signature.")
        6 -> append("The device probed for a network tied to this hardware.")
        7 -> append("The aircraft identified itself over Remote ID.")
        8 -> append("A service-data tag tied to this hardware matched.")
        9 -> append("A decoded manufacturer-data subtype matched a known signature.")
        10 -> append("You starred this exact device, so every sighting matches.")
        else -> append("No match method was reported for this hit.")
    }
}

/** The firmware detail strings for the four body-cam signatures, exactly as axon_detect.cpp
 *  and police_detect.cpp write them. Membership is what upgrades the chip to VENDOR ONLY and
 *  selects a per-signature explainer below. */
private val BODY_CAM_SIGNATURES =
    setOf("BWC DEVICE", "Axon OUI", "Utility BodyWorn", "Motorola Solutions OUI")

/** The body-cam signature behind this hit, when the board reported one. Null for every other
 *  category, and for a buffered record (the offline store keeps no detail field). */
private val Detection.bodyCamSigDetail: String?
    get() = detail?.takeIf { type == DeviceType.BODY_CAM && it in BODY_CAM_SIGNATURES }

/** Which body-cam signature fired, and how much weight it carries. The four sources under
 *  this one category range from Axon's own broadcast identifier to a vendor-block proxy, and
 *  without this they all read as "Body camera". Says nothing about the numbers: the verdict,
 *  meter, and percentage above already carry the strength. Copy mirrors iOS word for word. */
private fun AnnotatedString.Builder.appendSignatureExplainer(d: Detection, sig: String) {
    fun name() = withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(sig) }
    when (sig) {
        "BWC DEVICE" -> {
            append("Matched "); name()
            append(", the tag Axon body cams broadcast about themselves. It rides in the advertisement rather than in the address, so it holds even when the device randomizes its MAC. This is the strongest body cam signature the board carries.")
        }
        "Axon OUI" -> {
            append("Matched "); name()
            append(" only. The address block is Axon Enterprise's, but the broadcast body cam tag never appeared, so this is Axon-made gear of some kind. They ship other products on the same block.")
        }
        "Utility BodyWorn" -> {
            append("Matched "); name()
            if (d.method == 2) {
                append(" by broadcast name. The device announced itself as part of Utility's body cam system, which is a deliberate self-identification and a solid match, though a name is easy for anything to copy.")
            } else {
                append(" by address block only. The block is Utility Inc's, but the broadcast name didn't match and Utility ships other gear on it, so treat this as a maybe.")
            }
        }
        "Motorola Solutions OUI" -> {
            append("Matched "); name()
            append(", a vendor proxy rather than a body cam signature. The block is Motorola Solutions' own, so the maker is right, but they also sell two-way radios, docks, and site infrastructure on it. Read this as their equipment nearby, not a confirmed camera.")
        }
    }
}

/** Field checklist for weak / chipset-only hits: what to look for, whether it sticks
 *  around, and a one-tap star. The checkboxes are scratch state, local to this screen. */
@Composable
private fun ConfirmItPanel(d: Detection, firstSeen: Long?, watched: Boolean, onWatch: () -> Unit) {
    var looked by remember(d.id) { mutableStateOf(false) }
    var secondPass by remember(d.id) { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Kicker("CONFIRM IT", color = Acab.warn)   // amber header, iOS parity: this is a to-do, not chrome
        CheckRow(d.type.confirmPrompt,
            checked = looked) { looked = !looked }
        val span = seenSpan(firstSeen)
        CheckRow(
            if (span != null) "Still here on a second pass? It's been seen ${d.count}× over $span so far."
            else "Still here on a second pass? It's been seen ${d.count}× so far.",
            checked = secondPass) { secondPass = !secondPass }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(if (watched) Icons.Filled.Star else Icons.Filled.StarBorder,
                contentDescription = null, tint = Acab.watchTone, modifier = Modifier.size(18.dp))
            Text("Star it to get pinged every time this exact device shows up.",
                color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                modifier = Modifier.weight(1f))
            WatchChip(watched, onWatch)
        }
    }
}

/** Tappable checkbox row; the check is just a field note for the user, nothing persists. */
@Composable
private fun CheckRow(text: String, checked: Boolean, onToggle: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .minimumInteractiveComponentSize()
            .toggleable(
                value = checked,
                role = Role.Checkbox,
                onValueChange = { onToggle() },
            )
            .semantics(mergeDescendants = true) {}
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.Top,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // iOS polarity: the UNREAD prompt is the bright one, a completed row dims, and the
        // checked box goes amber. Brightening finished items made the pending work recede.
        Icon(if (checked) Icons.Filled.CheckBox else Icons.Filled.CheckBoxOutlineBlank,
            contentDescription = null, tint = if (checked) Acab.warn else Acab.faint,
            modifier = Modifier.size(18.dp))
        Text(text, color = if (checked) Acab.dim else Acab.text,
            fontSize = 11.sp, fontFamily = Acab.mono, modifier = Modifier.weight(1f))
    }
}

/** Small gold chip wired to the same watch/star action as the big button below. */
@Composable
private fun WatchChip(watched: Boolean, onClick: () -> Unit) {
    val gold = Acab.watchTone
    val shape = RoundedCornerShape(6.dp)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(shape)
            .background(if (watched) gold else gold.copy(alpha = 0.14f), shape)
            .border(1.dp, if (watched) Color.Transparent else gold.copy(alpha = 0.4f), shape)
            .clickable(onClick = onClick)
            .padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(if (watched) Icons.Filled.Star else Icons.Filled.StarBorder,
            contentDescription = null, tint = if (watched) Acab.onAccent else gold,
            modifier = Modifier.size(12.dp))
        Text(if (watched) "WATCHING" else "WATCH", color = if (watched) Acab.onAccent else gold,
            fontSize = 10.sp, letterSpacing = 1.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Amber warning for experimental detectors: body-cam signatures are still guesswork. */
@Composable
private fun ExperimentalNote(type: DeviceType) {
    Row(
        Modifier.fillMaxWidth().panel(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.Warning, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(13.dp))
        Text("Experimental detector. ${type.experimentalNoun} signatures are not field-verified yet, so treat this as a maybe.",
            color = Acab.warn, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Dim footer recapping how the node was matched. */
@Composable
private fun WhyFlagged(d: Detection, tone: Color) {
    Row(
        Modifier.fillMaxWidth().padding(top = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(Icons.Filled.GpsFixed, contentDescription = null,
            tint = tone, modifier = Modifier.size(11.dp))
        Text("Flagged by ${d.methodLabel} over ${d.sourceLabel}.",
            color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
    }
}

/** Dark-mode tile filter for the light MAPNIK tiles: a color-matrix inversion
 *  concatenated with a partial-saturation matrix, so the inverted land/water hues read
 *  as muted dark surfaces instead of neon. The standard osmdroid dark-map approach. */
// R4: the one shared dark-tile filter, used by both this mini-map and the full MapScreen so
// the two surfaces render an identical tint (inversion first, then saturation).
internal val osmDarkTileFilter: ColorMatrixColorFilter by lazy {
    val inversion = ColorMatrix(
        floatArrayOf(
            -1f, 0f, 0f, 0f, 255f,
            0f, -1f, 0f, 0f, 255f,
            0f, 0f, -1f, 0f, 255f,
            0f, 0f, 0f, 1f, 0f,
        )
    )
    // Invert first, then pull chroma down to ~30% of the inverted result.
    val adjust = ColorMatrix().apply { setSaturation(0.3f) }
    adjust.preConcat(inversion)
    ColorMatrixColorFilter(adjust)
}

/** Static map thumbnail centered on the sighting, with the device pin and (for drones)
 *  a separate operator marker. Mirrors the iOS location panel. Tapping the thumbnail (it
 *  never pans or zooms itself) jumps to the full Map tab centered close-in on this spot. */
@Composable
private fun LocationPanel(d: Detection, lat: Double, lon: Double, onOpenInMap: (Double, Double) -> Unit) {
    val context = LocalContext.current
    val markers = rememberCategoryMarkers()
    val operatorMarker = rememberOperatorMarker()
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    val liveMap = remember { mutableStateOf<MapView?>(null) }
    val mapResumed = remember { booleanArrayOf(false) }
    androidx.compose.runtime.DisposableEffect(lifecycleOwner) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    if (!mapResumed[0]) liveMap.value?.onResume()
                    mapResumed[0] = liveMap.value != null
                }
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE -> {
                    if (mapResumed[0]) liveMap.value?.onPause()
                    mapResumed[0] = false
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            if (mapResumed[0]) liveMap.value?.onPause()
            mapResumed[0] = false
        }
    }

    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Kicker("LOCATION")
            Spacer(Modifier.weight(1f))
            Text(String.format("%.5f, %.5f", lat, lon),
                color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono)
        }
        // When the board stamped this from a stale phone fix (offline / Desert mode), say how
        // old the position is so it isn't read as a live "here, now". The v1.7 headline.
        d.locationAgeDetail?.let { age ->
            Text(age, color = Acab.warn,
                fontSize = 11.sp, fontFamily = Acab.mono)
        }
        // CORROBORATION, positive-only (mirrors iOS). An ALPR-type hit within ~150m of a
        // community-mapped camera is strong confirmation, and names the mapped maker when known.
        // We NEVER show a "no mapped camera" line: OSM lags installs and cruiser ALPR is meant to
        // move, so absence is not evidence of a false positive (the confidence % chip is that tell).
        if (d.type == DeviceType.FLOCK_CAMERA || d.type == DeviceType.FLOCK_RAVEN) {
            AlprStore.getInstance(context).nearest(lat, lon)?.let { (meters, maker, tier) ->
                if (meters <= 150) {
                    val m = meters.roundToInt()
                    // This line is the app using the mapped record as corroboration. Only tier 1
                    // carries structured manufacturer attribution; tier 0 can support the mapped
                    // location without naming a maker, while tier 2 stays explicitly a legacy
                    // candidate. Mirrors iOS DetectionDetailView.
                    Text(
                        when {
                            tier == 0 ->
                                "\u2713 near a mapped ALPR camera · no structured manufacturer · $m m"
                            tier == 2 -> "near a legacy ALPR candidate · $m m"
                            tier == ALPR_TIER_LEGACY_FORMAT ->
                                "\u2713 near a mapped ALPR camera · legacy dataset format · $m m"
                            tier == 1 && maker.isEmpty() ->
                                "\u2713 near a mapped ALPR camera · manufacturer attributed · $m m"
                            tier == 1 -> "\u2713 matches a mapped $maker camera · $m m"
                            else -> "near a mapped ALPR record · unknown attribution tier · $m m"
                        },
                        color = if (tier == 1 || tier == ALPR_TIER_LEGACY_FORMAT)
                            Acab.flockTone else Acab.warn,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium, fontFamily = Acab.mono,
                    )
                }
            }
        }
        // The whole thumbnail is one tap target: the inner MapView refuses every touch at
        // dispatch, so the clickable on this wrapper receives the tap and hands off to the
        // real map, centered on this sighting.
        Box(
            Modifier
                .fillMaxWidth()
                .height(170.dp)
                .clip(RoundedCornerShape(Acab.radiusSm))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
                .clickable(role = Role.Button) { onOpenInMap(lat, lon) }
                .semantics { contentDescription = "Open this location in the map" },
        ) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { ctx ->
                // osmdroid setup (user agent + bounded tile cache) MUST land before the first tile
                // fetch, and the factory is the last point before MapView is constructed. It used
                // to sit in a remember{} in composition, which lint flags as a side effect in
                // remember (it is: remember is for caching, not for running things). Idempotent
                // via compareAndSet, so calling it per factory is free.
                configureOsmdroid(ctx)
                    // A TRUE static thumbnail, the analog of iOS's .allowsHitTesting(false) on this
                    // same panel: refuse every touch at dispatch so the gesture falls through to the
                    // scrolling sheet instead of being half-eaten by a map that won't pan anyway.
                    // The real map tab is for panning.
                    object : MapView(ctx) {
                        override fun dispatchTouchEvent(event: MotionEvent?): Boolean = false
                    }.apply {
                        liveMap.value = this
                        if (lifecycleOwner.lifecycle.currentState.isAtLeast(
                                androidx.lifecycle.Lifecycle.State.RESUMED)) {
                            onResume()
                            mapResumed[0] = true
                        }
                        importantForAccessibility =
                            android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS
                        setTileSource(TileSourceFactory.MAPNIK)
                        // MAPNIK ships light-only tiles; invert + desaturate so the thumbnail
                        // sits in the dark app instead of glowing like a flashlight.
                        overlayManager.tilesOverlay.setColorFilter(osmDarkTileFilter)
                        setMultiTouchControls(false)
                        // With pinch off, osmdroid force-shows its +/- buttons as the "only zoom
                        // affordance left" - on a static thumbnail they're clutter on top of the
                        // OSM attribution (same overlap the main map hid them for).
                        zoomController.setVisibility(CustomZoomButtonsController.Visibility.NEVER)
                        controller.setZoom(15.0)
                        controller.setCenter(GeoPoint(lat, lon))
                        overlays.add(
                            Marker(this).apply {
                                position = GeoPoint(lat, lon)
                                icon = markers.getValue(d.type)
                                setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                title = d.type.category
                            }
                        )
                        // drones broadcast the operator's position too; drop a pin for it
                        val plat = d.pilotLat
                        val plon = d.pilotLon
                        if (d.type == DeviceType.DRONE && plat != null && plon != null &&
                            validCoord(plat, plon)) {
                            overlays.add(
                                Marker(this).apply {
                                    position = GeoPoint(plat, plon)
                                    icon = operatorMarker
                                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                    title = "Operator"
                                }
                            )
                        }
                    }
                },
                // The screen live-shadows the row (~3 Hz), so the coordinates can move while the
                // panel is up: a drone in flight, or a closest-approach migration on a stronger
                // sighting. The header text and openOnMap already recompose with the new values;
                // without this block the retained MapView kept the first composition's center and
                // pins and the panel disagreed with itself. Signature-guarded so the 3 Hz feed
                // doesn't churn osmdroid when nothing moved; zoom is deliberately untouched.
                update = { map ->
                    val sig = listOf(lat, lon, d.pilotLat, d.pilotLon)
                    if (map.tag != sig) {
                        map.tag = sig
                        map.controller.setCenter(GeoPoint(lat, lon))
                        val pins = map.overlays.filterIsInstance<Marker>()
                        pins.firstOrNull { it.title != "Operator" }?.position = GeoPoint(lat, lon)
                        val plat = d.pilotLat
                        val plon = d.pilotLon
                        val op = pins.firstOrNull { it.title == "Operator" }
                        if (d.type == DeviceType.DRONE && plat != null && plon != null &&
                            validCoord(plat, plon)) {
                            if (op != null) {
                                op.position = GeoPoint(plat, plon)
                            } else {
                                map.overlays.add(
                                    Marker(map).apply {
                                        position = GeoPoint(plat, plon)
                                        icon = operatorMarker
                                        setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                                        title = "Operator"
                                    }
                                )
                            }
                        } else if (op != null) {
                            map.overlays.remove(op)
                        }
                        map.invalidate()
                    }
                },
                onRelease = { map ->
                    if (mapResumed[0]) map.onPause()
                    mapResumed[0] = false
                    if (liveMap.value === map) liveMap.value = null
                    map.onDetach()
                },
            )
            // Corner pill that makes the tap discoverable; the tap target is the whole
            // thumbnail, not just the pill. Kicker-style mono caps on a dim scrim. Top-trailing
            // like iOS, which also keeps it off the OSM attribution's bottom corner.
            Box(
                Modifier
                    .align(Alignment.TopEnd)
                    .padding(7.dp)
                    .background(Acab.bg.copy(alpha = 0.8f), RoundedCornerShape(50))
                    .border(1.dp, Acab.line, RoundedCornerShape(50))
                    .padding(horizontal = 9.dp, vertical = 5.dp),
            ) {
                Text("OPEN IN MAP", color = Acab.dim, fontSize = 9.5.sp, letterSpacing = 1.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
        }
    }
}

/**
 * "Seen with you": what the phone's own breadcrumb trail says about this tracker, and nothing else.
 *
 * TRACKERS ONLY, and the caller already gated on it. The manager collects crumbs for no other type,
 * so a body cam has nothing to score; showing it an empty panel would claim a check that never ran.
 *
 * NEVER AN ALARM. No tone colour, no icon, no amber. A band is a header plus two dim paragraphs, and
 * the second one names the innocent explanation. The NONE, NOT_MEASURED and no-crumb states get no
 * Kicker at all, so a header can never assert something the body then walks back.
 *
 * FIVE STATES, FIVE SENTENCES, and none of them may be borrowed from another: a band, "scored and
 * found nothing" (NONE), "refused to score" (NOT_MEASURED), "location is off", and "no position was
 * recorded this session". Every one of those sentences is authored in FollowEvidence, never here.
 *
 * COST. The span pass is O(n^2) over up to 120 crumbs (7140 haversines). That is cheap, but it must
 * never ride the ~3 Hz publish this screen live-shadows, or a Desert-mode flood would pay for it on
 * every frame. So: score once when the screen appears, then at most once per 5 s, off a snapshot
 * copy of the crumb list taken outside storeLock (crumbs() already hands back a .toList()).
 */
@Composable
private fun FollowEvidencePanel(
    id: String,
    // Passed through rather than hardcoded to TRACKER at the evaluate() call below. The caller
    // already gated on type, so this looks redundant, and that is the point: the scorer carries its
    // own type guard so that widening crumb collection past trackers cannot start scoring body cams
    // by accident. Handing it a constant would quietly disarm the guard on this platform only, and
    // iOS would keep an assertion Android had lost.
    type: DeviceType,
    ble: AcabBleManager,
    timeBasis: TimeBasis,
) {
    val context = LocalContext.current
    val demo by ble.demoMode.collectAsState()
    // The 5 s recompute clock. A plain counter rather than a re-read of the feed: the feed changes
    // ~3 Hz and almost none of those changes can move a band, which needs a fresh crumb, and a
    // crumb needs 60 s and 25 m.
    var tick by remember(id) { mutableStateOf(0) }
    LaunchedEffect(id) {
        while (true) {
            delay(5_000)
            tick++
        }
    }
    // Asked on every recompute rather than remembered: the user can grant location from the system
    // sheet while this screen sits open, and the panel would otherwise keep saying we aren't using it.
    //
    // FINE *or* COARSE, matching the manager's own hasLocationPermission() gate and iOS's
    // authorizedWhenInUse/Always test. Testing FINE alone would tell a user who chose Android 12's
    // "Approximate location" that the app is not using location at all, which is false: coarse fixes
    // do reach freshSelfCoord and do produce crumbs. Getting this wrong is not a cosmetic slip in a
    // panel whose entire job is to say honestly what the app did and did not look at.
    val locationGranted = ContextCompat.checkSelfPermission(
        context, android.Manifest.permission.ACCESS_FINE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED || ContextCompat.checkSelfPermission(
        context, android.Manifest.permission.ACCESS_COARSE_LOCATION,
    ) == PackageManager.PERMISSION_GRANTED

    val crumbs = remember(id, tick) { ble.crumbs(id) }
    val ev = remember(id, tick, timeBasis, type) {
        FollowEvidence.evaluate(
            type = type,
            crumbs = crumbs,
            // The FIRST CRUMB, not first-seen. first-seen is when the device was first HEARD, and
            // it comes back off the persisted store on launch while the crumbs do not. Handing the
            // scorer first-seen made it narrate a window the trail never covered, and let the
            // bands' time floors be satisfied by minutes containing no crumbs at all. The scorer's
            // parameter was RENAMED along with the fix precisely so this call site could not keep
            // passing the wrong instant and still compile.
            firstCrumbAtMs = ble.firstCrumbAt(id),
            lastCrumbAtMs = ble.lastCrumbAt(id),
            timeBasis = timeBasis,
        )
    }

    // No crumbs at all has three different causes and they are not interchangeable. Demo seeds the
    // store directly and never runs the live filing path, so a demo tracker has zero crumbs for a
    // reason that is neither a permission problem nor a fix problem: it says the ordinary "not
    // enough ground" line and stays at band NONE forever. Fabricating follow evidence inside a tour
    // would teach the user to trust a fabricated judgement.
    val hasTrail = crumbs.isNotEmpty() || demo
    val body = when {
        // A trail exists (or this is the tour), so the model owns the sentence, and it now has FOUR
        // of them. NOT_MEASURED is the one this has to keep distinct: a refusal (a derived time
        // basis off the board's offline buffer, a clock jump, a window longer than an address
        // lives) is not a finding, and reporting it through the NONE branch is how the panel came
        // to tell a user "not across enough ground to read anything into yet" about a tag it had
        // never compared against anything. Under-claiming cuts both ways here: a false reassurance
        // is as much a false statement as a false alarm, and it is the one nobody audits.
        hasTrail -> ev.detailText
        !locationGranted -> FollowEvidence.NO_LOCATION_TEXT
        else -> FollowEvidence.NO_FIX_TEXT
    }
    // EVERY state, no exceptions. This used to be suppressed on the two no-crumb states, on the
    // reasoning that a session-and-trackers caveat under them would qualify a measurement that was
    // never taken. That had it backwards. The no-crumb states are precisely where the user needs to
    // be told the memory is session-scoped: after an app restart the store row is restored from
    // disk and the crumbs are not, so the panel says there is nothing to compare, and this is the
    // one line that explains why a tag they watched ride along with them yesterday shows nothing
    // today. Suppressing it left the false-looking sentence standing with no context at all.
    val scope = FollowEvidence.SCOPE_TEXT

    // Always the card, never the Kicker unless a band fired. Same shape as iOS: the panel chrome is
    // constant so the screen does not visibly restructure itself when a band appears, but the header
    // is conditional so it can never assert a finding that the body immediately walks back. Reading
    // the label straight off the band covers the empty-crumb and refused states for free: fewer than
    // three crumbs can only score NONE, and NONE and NOT_MEASURED both have no label.
    val label = ev.band.label
    Column(Modifier.fillMaxWidth().panel(), verticalArrangement = Arrangement.spacedBy(9.dp)) {
        if (label != null) {
            Kicker(FollowEvidence.KICKER)
            // Plain body text, NOT a Kicker: the band label is content, and passing it through a
            // casing transform is exactly how two platforms end up rendering it differently.
            Text(label, color = Acab.text, fontSize = 15.sp, fontWeight = FontWeight.Medium,
                fontFamily = Acab.display)
        }
        Text(body, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono, lineHeight = 16.sp)
        Text(scope, color = Acab.faint, fontSize = 9.5.sp, fontFamily = Acab.mono, lineHeight = 13.sp)
    }
}

/** Crimson button that copies the MAC and flashes "COPIED" for a beat. */
@Composable
private fun CopyMacButton(mac: String) {
    val context = LocalContext.current
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(copied) {
        if (copied) {
            delay(1500)
            copied = false
        }
    }

    Row(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .background(Acab.accent, RoundedCornerShape(Acab.radiusSm))
            .clickable {
                val clip = context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                clip.setPrimaryClip(ClipData.newPlainText("MAC", mac))
                copied = true
            }
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (copied) Icons.Filled.Check else Icons.Filled.ContentCopy,
            contentDescription = null, tint = Acab.onAccent, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(7.dp))
        Text(if (copied) "COPIED" else "COPY MAC ADDRESS", color = Acab.onAccent,
            fontSize = 12.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Outlined button that mutes the device and pops back. */
@Composable
private fun IgnoreButton(onIgnore: () -> Unit) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    Row(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .background(Acab.bg2, shape)
            .border(1.dp, Acab.line, shape)
            .clickable(onClick = onIgnore)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Filled.NotificationsOff, contentDescription = null,
            tint = Acab.dim, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(7.dp))
        Text("IGNORE THIS DEVICE", color = Acab.dim,
            fontSize = 12.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Star toggle: add/remove this exact MAC from the watchlist. Filled + amber when active. */
@Composable
private fun WatchButton(watched: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(Acab.radiusSm)
    // R3: match iOS , watched fills gold with onAccent content ("STOP WATCHING"); unwatched
    // is a gold-outlined bg2 button.
    val content = if (watched) Acab.onAccent else Acab.watchTone
    Row(
        Modifier
            .fillMaxWidth()
            .minimumInteractiveComponentSize()
            .background(if (watched) Acab.watchTone else Acab.bg2, shape)
            .border(1.dp, if (watched) Color.Transparent else Acab.watchTone.copy(alpha = 0.4f), shape)
            .clickable(onClick = onToggle)
            .padding(vertical = 14.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(if (watched) Icons.Filled.Star else Icons.Filled.StarBorder,
            contentDescription = null, tint = content, modifier = Modifier.size(15.dp))
        Spacer(Modifier.size(7.dp))
        Text(if (watched) "STOP WATCHING" else "WATCH THIS DEVICE", color = content,
            fontSize = 12.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Honest heads-up before starring a randomized address: it rotates, so the star may lapse.
 *  Exactly one body, chosen by type: a separated Find My tag holds its address for about a day
 *  and rolls near 4am, a phone churns every few minutes, everything else gets the generic line.
 *  Detection never uses the address, so rotation only costs you the star, never the hit. */
@Composable
private fun RandomAddrWarnDialog(type: DeviceType, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    val body = when (type) {
        DeviceType.TRACKER -> "This tag's address holds for about a day, then changes around 4am. The star stops matching when it does. The tracker detector finds it either way."
        DeviceType.NEARBY_DEVICE -> "Most phones change their address every few minutes, so this star will likely stop matching within the hour."
        // No "trackers" here: TRACKER is handled one branch above, and a separated tag rotates
        // about once a day, not every few minutes. Repeating the near-owner interval in the
        // fallback would put the debunked claim straight back in front of the user.
        else -> "This address looks randomized, so the star may stop matching this device."
    }
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Acab.bg2,
        titleContentColor = Acab.text,
        textContentColor = Acab.dim,
        title = { Text("Watch a rotating address?", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
        text = {
            Text(body, fontSize = 12.sp, fontFamily = Acab.mono)
        },
        confirmButton = {
            Text("WATCH ANYWAY", color = Acab.warn, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClick = onConfirm).padding(8.dp))
        },
        dismissButton = {
            Text("CANCEL", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClick = onDismiss).padding(8.dp))
        },
    )
}

/** The firmware watchlist holds 256 MACs. Mirrors AcabBleManager.WATCH_CAP (private there);
 *  checked here so a refused star gets the alert below instead of a silent no-op. */
private const val WATCH_CAP = 256

/** iOS's "Watchlist full" alert: the manager refuses a 257th star without a word, so the
 *  screen has to say why the WATCH tap did nothing. */
@Composable
private fun WatchlistFullDialog(onDismiss: () -> Unit) {
    androidx.compose.material3.AlertDialog(
        onDismissRequest = onDismiss,
        containerColor = Acab.bg2,
        titleContentColor = Acab.text,
        textContentColor = Acab.dim,
        title = { Text("Watchlist full", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
        text = {
            Text("You can watch up to 256 devices at once. Un-watch one before adding another.",
                fontSize = 12.sp, fontFamily = Acab.mono)
        },
        confirmButton = {
            Text("OK", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                modifier = Modifier.minimumInteractiveComponentSize()
                    .clickable(onClick = onDismiss).padding(8.dp))
        },
    )
}

/** Single row of stat cells with a hairline divider between them. */
@Composable
private fun StatGrid(cells: List<Pair<String, String>>) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(Acab.bg2, RoundedCornerShape(Acab.radius))
            .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius)),
    ) {
        cells.forEachIndexed { i, cell ->
            if (i > 0) VDivider()
            StatCell(cell, Acab.text, Modifier.weight(1f))
        }
    }
}

@Composable
private fun StatCell(cell: Pair<String, String>, valueColor: Color, modifier: Modifier = Modifier) {
    Column(modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Kicker(cell.first)
        Text(cell.second, color = valueColor, fontSize = 14.sp,
            fontWeight = FontWeight.Medium, fontFamily = Acab.mono, maxLines = 1)
    }
}

/** Vertical hairline between grid columns. */
@Composable
private fun VDivider() {
    Box(Modifier.size(width = 1.dp, height = 56.dp).background(Acab.line))
}

/** Identity label/value row, hairline under all but the last. */
@Composable
private fun IdRow(label: String, value: String, last: Boolean = false, note: String? = null) {
    Column {
        Row(
            Modifier.fillMaxWidth().padding(vertical = 9.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Text(label, color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
            Spacer(Modifier.weight(1f))
            Spacer(Modifier.size(16.dp))
            // [note] says how a derived value was arrived at, and it rides directly under that
            // value rather than in a row of its own: split apart, a reader can pair the
            // qualification with the wrong number, which is the whole failure it exists to stop.
            Column(horizontalAlignment = Alignment.End) {
                Text(value, color = Acab.text, fontSize = 12.sp,
                    fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
                note?.let {
                    Spacer(Modifier.size(3.dp))
                    Text(it, color = Acab.dim, fontSize = 10.sp, fontFamily = Acab.mono,
                        lineHeight = 13.sp, textAlign = TextAlign.End)
                }
            }
        }
        if (!last) HorizontalDivider(color = Acab.line)
    }
}

/** RSSI history as a line with a faint fill; dimmed when the node is stale. */
@Composable
private fun Sparkline(values: List<Int>, tone: Color, stale: Boolean, modifier: Modifier = Modifier) {
    val alpha = if (stale) 0.35f else 1f
    Canvas(modifier) { drawSparkline(values, tone, alpha) }
}

private fun DrawScope.drawSparkline(values: List<Int>, tone: Color, alpha: Float) {
    if (values.size < 2) return
    val w = size.width
    val h = size.height
    val lo = values.min()
    val hi = values.max()
    val span = (hi - lo).coerceAtLeast(1).toFloat()
    val step = w / (values.size - 1)
    // RSSI is negative, so closer to 0 sits near the top.
    fun y(v: Int) = h - ((v - lo) / span) * h
    val line = Path().apply {
        moveTo(0f, y(values[0]))
        values.forEachIndexed { i, v -> lineTo(i * step, y(v)) }
    }
    val fill = Path().apply {
        addPath(line)
        lineTo(w, h)
        lineTo(0f, h)
        close()
    }
    drawPath(fill, tone.copy(alpha = 0.12f * alpha))
    drawPath(line, tone.copy(alpha = alpha), style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx()))
}

/** Last 4 hex of the MAC (colons stripped) for the NODE name. */
private fun nodeName(mac: String): String {
    val hex = mac.filter { it != ':' && it != '-' }
    return hex.takeLast(4).uppercase().ifEmpty { "????" }
}

/** The identity row that carries a derived time, named once so the qualifier line under it and
 *  the row itself can never drift apart. (APPROX_TIME and the rest of the time copy live in
 *  Components.kt now, shared with the log rows.) */
private const val FIRST_SEEN_LABEL = "First seen"

/** Short "ago" string like "now", "12s ago", "4m ago", "1h ago", "3d ago".
 *  A dash if we don't know the time. (internal: the map-settings ALPR caption reuses it.) */
internal fun relativeAgo(ms: Long?): String {
    if (ms == null) return "-"
    val secs = ((System.currentTimeMillis() - ms) / 1000).coerceAtLeast(0)
    return when {
        secs < 5 -> "now"
        secs < 60 -> "${secs}s ago"
        secs < 3600 -> "${secs / 60}m ago"
        secs < 86_400 -> "${secs / 3600}h ago"
        else -> "${secs / 86_400}d ago"
    }
}

/** Bare duration since a timestamp, for "seen 4× over 18m so far": "45s", "18m", "2h", "3d".
 *  null when the first sighting time is unknown, so the caller can drop the clause. */
private fun seenSpan(ms: Long?): String? {
    if (ms == null) return null
    // Floor of 1, like iOS: a fresh detection reads "over 1s", never "over 0s".
    val secs = ((System.currentTimeMillis() - ms) / 1000).coerceAtLeast(1)
    return when {
        secs < 60 -> "${secs}s"
        secs < 3600 -> "${secs / 60}m"
        secs < 86_400 -> "${secs / 3600}h"
        else -> "${secs / 86_400}d"
    }
}
