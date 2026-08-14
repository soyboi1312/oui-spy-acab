package tech.acab.app.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.widget.Toast
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.DoneAll
import androidx.compose.material.icons.filled.Place
import androidx.compose.material.icons.automirrored.filled.PlaylistAddCheck
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.IosShare
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.FilterAlt
import androidx.compose.material.icons.outlined.Inbox
import androidx.compose.material.icons.outlined.RadioButtonChecked
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.TextButton
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.RectangleShape
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.lifecycle.viewmodel.compose.viewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.model.displayName
import tech.acab.app.model.methodLabel
import tech.acab.app.model.sourceLabel
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import java.io.File
import tech.acab.app.model.hasName
import androidx.compose.ui.text.style.TextOverflow

/** Seed for the Log's lens: everything, only-new-since-the-watermark, or one category.
 *  Public so callers (MainScreen deep links) can seed LogScreen with an initial filter.
 *  Internally the screen splits this into two composable axes (category x scope, like
 *  iOS), so a seed only picks the starting position of one axis. */
sealed interface LogFilter {
    data object All : LogFilter
    data object NewOnly : LogFilter
    data object OfflineOnly : LogFilter
    data class Category(val key: String) : LogFilter
}

/** The scope axis of the log lens: everything, only-new (after the seen watermark), or
 *  only offline-buffered records. Composes with the nullable category filter, matching
 *  iOS StatusScope, so ALPR+NEW is one lens rather than two mutually exclusive ones. */
internal enum class LogScope { All, New, Offline }

internal fun filterLogRows(
    feed: List<Detection>,
    category: String?,
    scope: LogScope,
    newIds: Set<String>,
): List<Detection> = feed.filter { d ->
    (category == null || d.type.category == category) && when (scope) {
        LogScope.All -> true
        LogScope.New -> d.id in newIds
        LogScope.Offline -> d.offline
    }
}

private tailrec fun Context.hostActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.hostActivity()
    else -> null
}

/** One entry in the ordered category set for the tile strip. [type] supplies the tone +
 *  glyph, [key] is the DeviceType.category the filter matches on, [label] is the short tile
 *  caption. Defined once (mirrors iOS + MapScreen) so a new category is added in one place.
 *  "Nearby Device" is deliberately absent: it is ambient noise, not a filter category. */
private data class LogCategory(val type: DeviceType, val key: String, val label: String)

private val LOG_CATEGORIES = listOf(
    LogCategory(DeviceType.FLOCK_CAMERA, "ALPR", "ALPR"),
    LogCategory(DeviceType.DRONE, "DRONE", "DRONE"),
    LogCategory(DeviceType.BODY_CAM, "BODY CAM", "BODY"),
    LogCategory(DeviceType.TRACKER, "TRACKER", "TRKR"),
    LogCategory(DeviceType.GLASSES, "GLASSES", "GLAS"),
    LogCategory(DeviceType.NETWORK_CAMERA, "CAMERA", "NETCAM"),
)

/** AND-PERF-2: header tallies computed in one pass over the list, instead of ~seven full
 *  O(n) scans (count() x5 + new + offline) on every ~3 Hz recomposition. [newIds] is the
 *  batch newIdSet result (ONE storeLock take per publish), shared by the NEW count, the
 *  NEW scope filter, and every row's new-dot so none of them re-take the lock per row. */
private class LogTallies(
    val byCategory: Map<String, Int>,
    val newIds: Set<String>,
    val offlineCount: Int,
)

/** Logbook: detection history with category tiles that double as filters, a new/all
 *  segmented filter, select-mode for batch-ignoring, and a "mark all seen" watermark.
 *  [initialFilter] seeds the filter on first composition (drive-mode notifications
 *  deep-link here with NewOnly); null keeps the default ALL lens.
 *  [selectedId] is the currently open dossier in the tablet two-pane layout; the matching
 *  row gets a subtle highlight. null (the phone default) means no row is highlighted. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LogScreen(
    ble: AcabBleManager,
    onSelect: (Detection) -> Unit,
    initialFilter: LogFilter? = null,
    selectedId: String? = null,
    pauseStateKey: String = "main",
) {
    val detections by ble.detections.collectAsState()
    val watermark by ble.seenWatermark.collectAsState()   // recomposes "New only" when it moves
    val status by ble.status.collectAsState()
    val demo by ble.demoMode.collectAsState()
    val context = LocalContext.current
    val coScope = rememberCoroutineScope()   // for the CSV export; `scope` below is the log lens
    var exportMenuOpen by remember { mutableStateOf(false) }   // EXPORT chip dropdown (CSV / GPX)
    // Two independent lens axes, ANDed together like iOS: a nullable category filter and a
    // three-way scope. A seed only positions the axis it names; the other stays at default.
    // rememberSaveable (under MainScreen's per-tab SaveableStateProvider): a tab switch or a
    // rotation must not reset a lens the user set. Deep-link re-seeding still works because
    // the key(logScreenKey) wrapper discards this state when a fresh seed arrives.
    var catFilter by rememberSaveable { mutableStateOf((initialFilter as? LogFilter.Category)?.key) }
    var scope by rememberSaveable {
        mutableStateOf(
            when (initialFilter) {
                LogFilter.NewOnly -> LogScope.New
                LogFilter.OfflineOnly -> LogScope.Offline
                else -> LogScope.All
            }
        )
    }

    // First ordinary open of the log baselines the New dots to what is already here, so a fresh
    // install / first offline backlog is not a wall of red dots. Once-only (persisted flag inside).
    // Skipped when we arrived via a NEW deep-link, or the baseline would mark the very rows the
    // deep-link exists to show. From here on the watermark advances on Log-tab leave (MainScreen).
    LaunchedEffect(Unit) {
        if (initialFilter != LogFilter.NewOnly) ble.seedSeenWatermarkOnce()
    }

    // Select mode: a set of selected detection ids (empty set = not in select mode).
    var selectMode by remember { mutableStateOf(false) }
    var selected by remember { mutableStateOf<Set<String>>(emptySet()) }
    var confirmClear by remember { mutableStateOf(false) }   // gate the destructive log wipe

    // Pause/resume the live feed. On a busy drive the log scrolls too fast to read; pausing
    // FREEZES a snapshot of the feed so it holds still. New sightings keep landing in the store
    // (ble.detections advances underneath, nothing is dropped) - we just don't show them until
    // resume, which snaps back to live. `feed` is what the whole screen renders from.
    // A Boolean in rememberSaveable was not enough: after a tab switch or rotation the actual
    // frozen rows were gone and the screen silently re-froze at a newer feed. The activity-scoped
    // ViewModel owns both pieces. Separate keys keep the connected and saved-log surfaces apart.
    val pauseVm: LogViewModel = viewModel(key = "log-pause:$pauseStateKey")
    val paused = pauseVm.paused
    val frozen = pauseVm.frozen
    val feed = if (paused) frozen else detections
    // Ids in the frozen snapshot, so we can count how many NEW sightings have piled up since the
    // pause (by id: the capped feed also sheds old rows, so a size delta would undercount).
    val frozenIds = remember(frozen) { frozen.mapTo(HashSet(frozen.size)) { it.id } }
    // once per publish while paused, not per recomposition: the id-diff walks the whole feed
    val pausedNew = remember(paused, detections, frozenIds) {
        if (paused) detections.count { it.id !in frozenIds } else 0
    }
    fun togglePause() {
        if (pauseVm.paused) pauseVm.resume()
        else pauseVm.pause(ble.freezeFeedExport())
    }

    // one traversal per (detections, watermark) change; category counts via groupingBy, with
    // new/offline derived in the same pass. newIdSet reads the watermark, so it keys here.
    // Built off the LIVE store (iOS parity): while paused only the ROWS freeze; the header,
    // tiles, and seg-chip counts keep climbing, and the PAUSED pill words the frozen list.
    // The per-row isNewSinceWatermark would take storeLock once per row; newIdSet is ONE take.
    val tallies = remember(detections, watermark) {
        val byCategory = detections.groupingBy { it.type.category }.eachCount()
        val newIds = ble.newIdSet(detections)
        var offlineCount = 0
        for (d in detections) {
            if (d.offline) offlineCount++
        }
        LogTallies(byCategory, newIds, offlineCount)
    }
    // New-ness for the DISPLAYED rows: while paused the frozen snapshot can hold rows the live
    // store has since evicted, so their ids get their own watermark check (one extra lock take,
    // and only while paused). Live, this is exactly tallies.newIds.
    val rowNewIds = if (!paused) tallies.newIds
                    else remember(pauseVm.frozenExport, watermark) {
                        pauseVm.frozenExport?.let(ble::newIdSet) ?: emptySet()
                    }
    // Time quality per row, one locked read for the whole feed rather than one per visible row.
    // Keyed on the revision as well as the feed: bracketing lands at the END of a drain, long
    // after the rows themselves were published, and the feed alone wouldn't notice.
    val timeRev by ble.timeBasisRev.collectAsState()
    val timeBases = remember(feed, timeRev, paused, pauseVm.frozenExport) {
        if (paused) {
            pauseVm.frozenExport?.rows
                ?.associate { it.detection.id to it.timeBasis }
                ?: emptyMap()
        } else {
            ble.timeBasisMap(feed)
        }
    }
    fun count(cat: String) = tallies.byCategory[cat] ?: 0
    val newCount = tallies.newIds.size
    val offlineCount = tallies.offlineCount

    // memoized per (feed, axes, rowNewIds) so a filtered list isn't re-scanned on every
    // unrelated recomposition (select-mode taps, pause chip, sheet state). Both axes AND
    // together, so ALPR+NEW is a real lens (iOS parity).
    val shown = remember(feed, catFilter, scope, rowNewIds) {
        filterLogRows(feed, catFilter, scope, rowNewIds)
    }

    fun exitSelect() { selectMode = false; selected = emptySet() }

    /** [gpx] false = the CSV evidence file, true = GPX for a mapping app.
     *
     *  Exports whatever the log is CURRENTLY FILTERED TO, not the whole history. That is what the
     *  button appears to promise while a category tile is lit, and the alternative (silently
     *  handing over everything) is the worse surprise for this product in particular. The chosen
     *  category also lands in the FILENAME, so a partial export cannot be mistaken for a complete
     *  one once it has left the app. */
    fun exportLog(gpx: Boolean = false, wholeLog: Boolean = false) {
        // The file write goes to IO (a Desert-mode log can be thousands of rows, which
        // would jank the main thread); the share sheet fires back on Main once it's done.
        // Freeze before launching IO. For a routine export this is EXACTLY the currently shown
        // live/paused + category + NEW/OFFLINE lens. The Clear-sheet escape hatch is the sole
        // whole-store path because it is about to delete the whole store.
        val exportSnapshot = when {
            wholeLog -> ble.freezeWholeLogExport()
            paused -> pauseVm.exportSnapshot(shown)
                // This invariant should be unreachable because pause publishes metadata before
                // paused=true. Fail closed instead of ever re-reading mutable/evictable maps.
                ?: run {
                    Toast.makeText(context.applicationContext,
                        "Couldn't export the paused snapshot; resume and try again.",
                        Toast.LENGTH_LONG).show()
                    return
                }
            else -> ble.freezeLogExport(shown.toList())
        }
        val slugParts = if (wholeLog) emptyList() else buildList {
            catFilter?.let { add(it.lowercase().replace(' ', '-')) }
            when (scope) {
                LogScope.All -> Unit
                LogScope.New -> add("new")
                LogScope.Offline -> add("offline")
            }
            if (paused) add("paused")
        }
        val appContext = context.applicationContext
        coScope.launch {
            var packageDir: File? = null
            try {
                val send = withContext(Dispatchers.IO) {
                    val slug = slugParts.takeIf { it.isNotEmpty() }
                        ?.joinToString(prefix = "-", separator = "-") ?: ""
                    val ext = if (gpx) "gpx" else "csv"
                    val dir = createExportPackage(appContext.cacheDir, "log-exports")
                    packageDir = dir
                    try {
                        // Preserve the readable leaf while the UUID parent makes the bytes
                        // immutable for receivers that read after a later export starts.
                        val file = File(dir, "acab-detections$slug.$ext")
                        file.writeText(if (gpx) ble.renderDetectionsGpx(exportSnapshot)
                            else ble.renderDetectionsCsv(exportSnapshot))
                        val uri = FileProvider.getUriForFile(
                            appContext, "${appContext.packageName}.fileprovider", file)
                        Intent(Intent.ACTION_SEND).apply {
                            // application/gpx+xml is the registered type; mapping apps key their
                            // share-sheet filters off it, and text/xml hides the Gaia importer.
                            type = if (gpx) "application/gpx+xml" else "text/csv"
                            putExtra(Intent.EXTRA_STREAM, uri)
                            clipData = android.content.ClipData.newUri(
                                appContext.contentResolver, file.name, uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                    } catch (e: Throwable) {
                        runCatching { dir.deleteRecursively() }
                        packageDir = null
                        throw e
                    }
                }
                // The composition scope is cancelled on rotation, but check the host explicitly
                // too: no stale Activity captured before IO may receive the chooser.
                val activity = context.hostActivity()?.takeUnless {
                    it.isFinishing || it.isDestroyed
                } ?: throw IllegalStateException("this screen is no longer available; try again")
                activity.startActivity(Intent.createChooser(send, "Export detections"))
                // A receiving app can keep reading after the chooser closes. Once launch succeeds,
                // age-pruning owns cleanup; never delete this package in our finally path.
                packageDir = null
            } catch (e: CancellationException) {
                packageDir?.let { runCatching { it.deleteRecursively() } }
                throw e
            } catch (e: Throwable) {
                packageDir?.let { runCatching { it.deleteRecursively() } }
                Toast.makeText(
                    context.applicationContext,
                    "Couldn't export detections: ${e.message ?: "write failed"}",
                    Toast.LENGTH_LONG,
                ).show()
            }
        }
    }

    // T2: cap the readable list width and center it, so a tablet/landscape viewport stops
    // stretching one column across the whole screen. At phone width the 640 cap is a no-op.
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
    LazyColumn(
        Modifier
            .widthIn(max = 640.dp)
            .fillMaxSize()
            .padding(horizontal = Acab.pad)
            .padding(top = 8.dp),
        contentPadding = PaddingValues(bottom = 16.dp),
    ) {
        // No spacedBy here: the log rows below must sit flush so they read as one panel,
        // so each section item carries its own bottom padding instead.
        item {
            Column(
                Modifier.padding(bottom = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                    Text("Logbook", color = Acab.text, fontSize = 26.sp, fontWeight = FontWeight.SemiBold)
                    Kicker("${detections.size} DETECTED · $newCount NEW")
                }
                // Labeled action chips, like the iOS header; hidden until there's data and
                // during select mode (a stray SELECT re-tap would wipe the checks, and MARK
                // SEEN would clear the new-dots mid-triage).
                // Clear lives at the end of the list, not up here with the routine actions.
                if (!selectMode && detections.isNotEmpty()) {
                    // horizontalScroll because this row is now FOUR chips: at 411dp phone width
                    // minus 20dp padding each side there is ~371dp, and SELECT + EXPORT + GPX +
                    // MARK SEEN exceeds it, so the last chip was clipped with no way to reach it.
                    // A filtered label ("DRONE CSV") makes it wider still.
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.horizontalScroll(rememberScrollState())) {
                        ActionChip(Icons.AutoMirrored.Filled.PlaylistAddCheck, "SELECT") {
                            // resume first: bulk-ignore acts on live rows (iOS parity)
                            pauseVm.resume()
                            selectMode = true; selected = emptySet()
                        }
                        // CSV and GPX used to be two chips. That spent two of the four slots in a
                        // row that already has to scroll on a phone on two variants of one action,
                        // so they fold into a single EXPORT chip with a menu (iOS parity). The
                        // chip still names the SCOPE when a category tile is lit ("EXPORT DRONE"),
                        // so a partial export can't be mistaken for the whole log.
                        Box {
                            ActionChip(Icons.Filled.IosShare,
                                catFilter?.let { "EXPORT $it" } ?: "EXPORT") { exportMenuOpen = true }
                            DropdownMenu(expanded = exportMenuOpen, onDismissRequest = { exportMenuOpen = false }) {
                                DropdownMenuItem(
                                    text = { Text("CSV, shown rows") },
                                    leadingIcon = { Icon(Icons.Filled.IosShare, contentDescription = null) },
                                    onClick = { exportMenuOpen = false; exportLog(false) })
                                DropdownMenuItem(
                                    text = { Text("GPX, shown rows") },
                                    leadingIcon = { Icon(Icons.Filled.Place, contentDescription = null) },
                                    onClick = { exportMenuOpen = false; exportLog(true) })
                            }
                        }
                        // scope resets to ALL so the user is never stranded on an empty NEW lens
                        ActionChip(Icons.Filled.DoneAll, "MARK SEEN") {
                            ble.markAllSeen(); scope = LogScope.All
                        }
                    }
                }
            }
        }

        // All / New / Offline scope chips; they compose with the category tiles below.
        item {
            Row(
                Modifier.padding(bottom = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // R7: grey ALL, crimson NEW (match iOS), so "new" is the one that pops.
                SegChip("ALL", detections.size, scope == LogScope.All) { scope = LogScope.All }
                SegChip("NEW", newCount, scope == LogScope.New, activeTone = Acab.accent) { scope = LogScope.New }
                SegChip("OFFLINE", offlineCount, scope == LogScope.Offline) { scope = LogScope.Offline }
                if (!selectMode) {
                    Spacer(Modifier.weight(1f))
                    // Pause/resume the live feed so a fast-scrolling log can be read. Only offered
                    // once there's something to freeze (or while already paused).
                    if (feed.isNotEmpty() || paused) {
                        PauseChip(paused = paused, onToggle = ::togglePause)
                    }
                    // quick clear: the bottom "clear log…" row is a long scroll once the log is big.
                    // same confirmation, quiet styling so it isn't a mis-tap magnet. Icon-only
                    // (trash reads on its own): with the three counted seg chips to the left, a
                    // worded chip is what made "CLEAR" wrap mid-word on a 411dp-wide screen.
                    Row(
                        Modifier
                            .minimumInteractiveComponentSize()
                            .clip(RoundedCornerShape(50))
                            .border(1.dp, Acab.line, RoundedCornerShape(50))
                            .clickable { confirmClear = true }
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.DeleteOutline, contentDescription = "Clear log",
                            tint = Acab.dim, modifier = Modifier.size(15.dp))
                    }
                }
            }
        }

        // Category tile strip; each tile toggles the list filter. Dynamic: a tile appears
        // only once its category has a detection this session, so the strip grows with the
        // categories the board actually saw instead of a fixed hardcoded row.
        item {
            // Which tiles to draw: any category with a count, plus the active filter's
            // category. The active-filter exception keeps a tile visible while it is the
            // current filter even if its live count falls to 0 (eviction/staleness); without
            // it the tile would vanish out from under the user, leaving the list filtered with
            // no tile left to tap to clear it.
            val visibleCats = LOG_CATEGORIES.filter { count(it.key) > 0 || it.key == catFilter }
            if (visibleCats.isNotEmpty()) {
                // At large font scales a six-across strip squeezes each label into a sliver;
                // wrap to rows of three so the numbers stay legible instead of truncating.
                BoxWithConstraints(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
                    val perRow = if (maxWidth < 360.dp || LocalDensity.current.fontScale >= 1.5f)
                        3 else visibleCats.size
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        visibleCats.chunked(perRow.coerceAtLeast(1)).forEach { rowCats ->
                            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                rowCats.forEach { c ->
                                    CategoryTile(c.type, c.key, c.label, count(c.key), catFilter, Modifier.weight(1f)) { catFilter = it }
                                }
                            }
                        }
                    }
                }
            }
        }

        if (feed.isEmpty()) {
            item {
                val radiosOff = status?.let { !it.ble && !it.wifi } == true
                when {
                    demo -> EmptyState("Sample data mode.", null)
                    // no status frame at all = no board linked; "Scanning…" would be a lie
                    status == null -> EmptyState(
                        "No board linked.",
                        "connect your beacon, it does the listening",
                    )
                    radiosOff -> EmptyState("Radios are off, flip them on in Beacon.", null)
                    else -> EmptyState(
                        "Scanning…",
                        "Detections log here as beacons spots surveillance gear nearby.",
                    )
                }
            }
        } else if (shown.isEmpty()) {
            // Rows exist but the active lens hides them all (NEW with everything seen,
            // OFFLINE with no buffered rows, a pinned category tile at count 0): explain
            // instead of a kicker over a blank void. Mirrors iOS noMatchState.
            item { NoMatchState(scope, catFilter) }
        } else {
            item {
                // Both axes read in one heading, like iOS: "ALL DETECTIONS" when no
                // category, "ALPR · NEW" when both lenses are on.
                val scopeTag = when (scope) {
                    LogScope.All -> "ALL"
                    LogScope.New -> "NEW"
                    LogScope.Offline -> "OFFLINE"
                }
                val label = catFilter?.let { "$it · $scopeTag" } ?: "$scopeTag DETECTIONS"
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Kicker(label)
                    // The pause chip is icon-only, so this is what words the frozen state
                    // (even at zero backlog) and the pile-up behind it.
                    if (paused) PausedPill(pausedNew)
                }
                Spacer(Modifier.size(8.dp))
            }
            // Each row is its own lazy item (keyed), so a Desert-mode log of thousands
            // only composes the rows on screen instead of building every row at once.
            // Visually the rows form ONE panel: each item paints its slice of the shared
            // surface (PanelSegment) with hairline dividers between rows.
            itemsIndexed(shown, key = { _, d -> d.id }) { index, d ->
                PanelSegment(
                    isFirst = index == 0,
                    isLast = index == shown.lastIndex,
                    highlighted = selectedId != null && d.id == selectedId,
                ) {
                    DetectionRow(
                        d = d,
                        timeBasis = timeBases[d.id],
                        selectMode = selectMode,
                        checked = d.id in selected,
                        onClick = {
                            if (selectMode) {
                                selected = if (d.id in selected) selected - d.id else selected + d.id
                            } else onSelect(d)
                        },
                    )
                    if (index != shown.lastIndex) HorizontalDivider(color = Acab.line)
                }
            }
        }
    }
    }

    // Select-mode action bar, floating over the bottom of the list.
    if (selectMode) {
        SelectBar(
            count = selected.size,
            onCancel = ::exitSelect,
            // every currently SHOWN (filtered) row, like iOS: select-all under an active
            // lens grabs just that lens's rows
            onSelectAll = { selected = shown.mapTo(HashSet(shown.size)) { it.id } },
            onIgnore = {
                val toIgnore = detections.filter { it.id in selected }
                ble.ignoreDevices(toIgnore)
                exitSelect()
            },
        )
    }

    // Destructive log wipe needs a confirmation, with an export-first escape hatch. R6: a bottom
    // sheet with FULL-WIDTH STACKED buttons, so the three wide mono labels never crowd one row.
    if (confirmClear) {
        ModalBottomSheet(
            onDismissRequest = { confirmClear = false },
            containerColor = Acab.bg3,
        ) {
            Column(
                Modifier.padding(horizontal = Acab.pad).padding(bottom = 28.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Clear ${detections.size} detection${if (detections.size == 1) "" else "s"}?", color = Acab.text,
                    fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
                Text(
                    "This deletes the log on this phone and can't be undone. " +
                        "If this is evidence, export it first.",
                    color = Acab.dim, fontSize = 14.sp,
                )
                Spacer(Modifier.size(4.dp))
                OutlinedButton(
                    // ALWAYS the whole log, never the category filter. The button beside it
                    // deletes EVERYTHING, so a filtered export here would hand back a subset and
                    // then destroy the rest - the one place a partial export is silent data loss.
                    onClick = { exportLog(gpx = false, wholeLog = true); confirmClear = false },
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, Acab.line),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.dim),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) {
                    Text("EXPORT CSV FIRST", fontSize = 12.sp, letterSpacing = 0.5.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
                Button(
                    // Drop the frozen snapshot too, or a paused screen would keep showing rows
                    // the user just cleared from the store.
                    onClick = { ble.clearLog(); pauseVm.resume(); confirmClear = false },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = Acab.accent, contentColor = Acab.onAccent),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) {
                    Text("CLEAR LOG", fontSize = 12.sp, letterSpacing = 0.5.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
                }
                TextButton(onClick = { confirmClear = false }, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel", color = Acab.dim)
                }
            }
        }
    }
}

/** Labeled header action chip: capsule, small glyph, mono label. minimumInteractiveComponentSize
 *  keeps the capsule's look while growing the touch target to the 48dp accessibility floor. */
@Composable
private fun ActionChip(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(CircleShape)
            .background(Acab.bg2, CircleShape)
            .border(1.dp, Acab.line, CircleShape)
            .clickable(onClick = onClick)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Acab.dim, modifier = Modifier.size(12.dp))
        Text(label, color = Acab.dim, fontSize = 10.sp, letterSpacing = 0.5.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Freeze/resume the live feed. Icon-only, with the accent fill flagging the paused state:
 *  the worded PAUSE/RESUME chip crowded this row into wrapping CLEAR on narrower screens,
 *  and the [PausedPill] beside the log heading now words the state + backlog instead.
 *  Same capsule anatomy as the CLEAR pill it sits beside. */
@Composable
private fun PauseChip(paused: Boolean, onToggle: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .clip(shape)
            .then(if (paused) Modifier.background(Acab.accent, shape) else Modifier.border(1.dp, Acab.line, shape))
            .clickable(onClick = onToggle)
            .semantics { stateDescription = if (paused) "Paused" else "Live" }
            .padding(horizontal = 10.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            if (paused) Icons.Filled.PlayArrow else Icons.Filled.Pause,
            contentDescription = if (paused) "Resume live feed" else "Pause live feed",
            tint = if (paused) Acab.onAccent else Acab.dim,
            modifier = Modifier.size(15.dp),
        )
    }
}

/** Worded frozen-state pill beside the log heading (iOS parity): "PAUSED", or
 *  "PAUSED · N NEW" once sightings pile up behind the freeze. Shown even at zero
 *  backlog, so a frozen list never reads as a stalled scan. */
@Composable
private fun PausedPill(newCount: Int) {
    Text(
        if (newCount > 0) "PAUSED · $newCount NEW" else "PAUSED",
        color = Acab.accent,
        fontSize = 9.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono,
        maxLines = 1,
        modifier = Modifier
            .background(Acab.accent.copy(alpha = 0.12f), RoundedCornerShape(50))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    )
}

/** One lazy item's slice of a shared panel. Rows stay individually lazy (a Desert-mode
 *  log can hold thousands) but paint as one continuous card: the first slice rounds the
 *  top, the last rounds the bottom, and every slice draws the side borders by clipping
 *  an oversized rounded-rect outline so no horizontal hairline lands between rows. */
@Composable
private fun PanelSegment(isFirst: Boolean, isLast: Boolean, highlighted: Boolean = false, content: @Composable () -> Unit) {
    val shape = when {
        isFirst && isLast -> RoundedCornerShape(Acab.radius)
        isFirst -> RoundedCornerShape(topStart = Acab.radius, topEnd = Acab.radius)
        isLast -> RoundedCornerShape(bottomStart = Acab.radius, bottomEnd = Acab.radius)
        else -> RectangleShape
    }
    // Two-pane selection: the open dossier's row lifts to bg3 with a crimson-tinted edge.
    // highlighted is only ever true when a selectedId is passed (tablet), so phone stays flat.
    val fill = if (highlighted) Acab.bg3 else Acab.bg2
    val edge = if (highlighted) Acab.lineStrong else Acab.line
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(fill)
            .drawBehind {
                val stroke = 1.dp.toPx()
                val corner = Acab.radius.toPx()
                // extend past whichever edges join a neighbor; the clip trims the overflow
                val topExtend = if (isFirst) 0f else corner
                val bottomExtend = if (isLast) 0f else corner
                drawRoundRect(
                    color = edge,
                    topLeft = Offset(stroke / 2f, -topExtend + stroke / 2f),
                    size = Size(
                        size.width - stroke,
                        size.height + topExtend + bottomExtend - stroke,
                    ),
                    cornerRadius = CornerRadius(corner),
                    style = Stroke(stroke),
                )
            }
            .padding(horizontal = Acab.padCard),
    ) { content() }
}

/** All / New-only segmented chip. */
@Composable
private fun SegChip(label: String, n: Int, active: Boolean, activeTone: Color = Acab.dim, onClick: () -> Unit) {
    val shape = RoundedCornerShape(50)
    Row(
        Modifier
            .minimumInteractiveComponentSize()
            .background(if (active) activeTone else Acab.bg2, shape)
            .border(1.dp, if (active) Color.Transparent else Acab.line, shape)
            .clickable(onClick = onClick)
            .semantics { selected = active }
            .padding(horizontal = 13.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(label, color = if (active) Acab.onAccent else Acab.dim, fontSize = 10.5.sp,
            letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
        Text("$n", color = if (active) Acab.onAccent.copy(alpha = 0.7f) else Acab.faint,
            fontSize = 10.sp, fontFamily = Acab.mono)
    }
}

/** Compact category tile in the 5-across strip; highlighted when its filter is on.
 *  [key] is the category the filter matches on; [label] is the short display name.
 *  [activeKey] is the current category axis; tapping toggles just that axis (the
 *  NEW/OFFLINE scope composes independently), so [onFilter] hands back a key or null. */
@Composable
private fun CategoryTile(
    type: DeviceType, key: String, label: String, n: Int, activeKey: String?,
    modifier: Modifier = Modifier, onFilter: (String?) -> Unit,
) {
    val active = activeKey == key
    val spokenLabel = when (label) {
        "TRKR" -> "Tracker"
        "GLAS" -> "Glasses"
        "NETCAM" -> "Network camera"
        "BODY" -> "Body camera"
        else -> label
    }
    val shape = RoundedCornerShape(Acab.radiusSm)
    Column(
        modifier
            .minimumInteractiveComponentSize()
            .background(if (active) type.tone().copy(alpha = 0.12f) else Acab.bg2, shape)
            .border(1.dp, if (active) type.tone().copy(alpha = 0.4f) else Acab.line, shape)
            .clickable { onFilter(if (active) null else key) }
            .semantics(mergeDescendants = true) {
                selected = active
                contentDescription = "$spokenLabel, $n detection${if (n == 1) "" else "s"}"
            }
            .padding(10.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(type.icon(), contentDescription = null,
            tint = if (n == 0 && !active) Acab.faint else type.tone(), modifier = Modifier.size(14.dp))
        Text("$n", color = if (n == 0) Acab.faint else Acab.text,
            fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Text(label, color = if (active) type.tone() else if (n == 0) Acab.faint else Acab.dim,
            fontSize = 8.sp, letterSpacing = 1.sp, fontWeight = FontWeight.Medium,
            fontFamily = Acab.mono, maxLines = 1)
    }
}

/** One log row: glyph, name, source/method, RSSI + bars. Tap opens the dossier, or toggles
 *  the checkbox in select mode. */
@Composable
private fun DetectionRow(
    d: Detection,
    timeBasis: TimeBasis?,
    selectMode: Boolean,
    checked: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (selectMode) {
            Icon(
                if (checked) Icons.Filled.CheckCircle else Icons.Outlined.Circle,
                contentDescription = if (checked) "Selected" else "Not selected",
                tint = if (checked) Acab.accent else Acab.faint,
                modifier = Modifier.size(22.dp),
            )
            Spacer(Modifier.size(12.dp))
        }
        CatGlyph(d.type, size = 40)
        Spacer(Modifier.size(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // the advertised name when present, else the broadcast maker, else the type label
                //
                // weight(fill = false) makes the TITLE the flexible child, so Compose measures
                // the fixed-width siblings first. Without it a long title (a user rename has no
                // length cap) eats the whole Row and every chip after it is measured at 0dp and
                // clipped away: no NODE, no EXP, no OFFLINE, no time-basis tag. Those
                // chips are exactly what stops a reader trusting a reconstructed timestamp or
                // mistaking a buffer replay for a live sighting, so losing them is not cosmetic.
                // This is how SwiftUI's HStack already behaves on the iOS row; Android needed to
                // be told, and adding the NODE handle ahead of the chips made it reachable at
                // ordinary title lengths rather than only absurd ones.
                Text(d.displayName, color = Acab.text, fontSize = 15.sp,
                    fontWeight = FontWeight.SemiBold, maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                // NODE handle, matching iOS DetectionRow. Android rendered NOTHING here, which is
                // why three cameras in a row were LITERALLY identical on this platform and merely
                // near-identical on iPhone: the last-4 of the MAC is the only per-device text on a
                // row whose title falls back to a shared label. The comment above claimed a "type
                // + last-4 label" that had never existed.
                Text("NODE ${d.mac.replace(":", "").takeLast(4).uppercase()}",
                    color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono)
                if (d.type.isExperimental) ExpTag()
                if (d.offline) OfflineTag()
                // A dense row has no space to explain itself, so it flags that this record's
                // time is derived (or absent) and leaves the explanation to the dossier.
                // Exact rows get nothing.
                when (timeBasis) {
                    is TimeBasis.Reconstructed -> ReconTag()
                    is TimeBasis.Bracketed -> RangeTag()
                    is TimeBasis.Unknown -> NoTimeTag()
                    else -> Unit
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                // how it was seen, like the iOS row: "BLE · OUI match". When the title leads with
                // something OTHER than the category (an advertised name, or now the broadcast
                // maker), the category moves here so it is never absent from the row entirely.
                // This branch is why the iOS row can afford a maker-led title; Android printed
                // source·method unconditionally and would have lost the category outright.
                // weight(fill = false) + maxLines=1, same fix the TITLE row above carries: make
                // THIS text the flexible child so Compose measures the fixed-size chips (confidence,
                // the amber GPS-age pill) first and lets the source/method label ellipsize instead.
                // Without it, a narrow or large-font screen (a Pixel 2 with display size bumped)
                // overflowed this row: the label wrapped to two lines and the GPS-age pill was
                // shoved against the RSSI column. The subtitle never got the treatment the title did.
                Text(if (d.hasName) "${d.type.label} · ${d.methodLabel}"
                     else "${d.sourceLabel} · ${d.methodLabel}",
                    color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                    maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                // Confidence, so the list answers "definitely something, or just suspected?"
                // without opening the dossier. Bands match the dossier's verdict copy exactly
                // (<50 weak / <80 partial / >=80 strong) and iOS DetectionRow.confidenceTint.
                // HIDDEN at 0: Desert nearby-devices are confidence 0 by construction (nothing
                // matched), and a wall of "0%" chips would be noise.
                if (d.confidence > 0) ConfidenceBadge(d.confidence)
                // offline / Desert mode: the coordinate came from a stale phone fix
                d.locationAgeText?.let { GpsAgeBadge(it) }
            }
        }
        // Guaranteed gutter so the middle column's rightmost chip can never kiss the RSSI, even
        // if its content still runs to the column edge on some future locale/font combination.
        Spacer(Modifier.size(10.dp))
        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("${d.rssi}", color = d.type.tone(), fontSize = 13.sp,
                fontWeight = FontWeight.SemiBold, fontFamily = Acab.mono, maxLines = 1)
            SignalBars(rssiBars(d.rssi), tint = d.type.tone())
        }
        Spacer(Modifier.size(8.dp))
        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = Acab.faint,
            modifier = Modifier.size(16.dp))
    }
}


/** Sibling of [ReconTag]/[RangeTag] for a record nothing bounds at all: the board logged
 *  only the order of the sighting. Same neutral provenance anatomy; the dossier explains. */
@Composable
private fun NoTimeTag() {
    Text(
        "NO TIME",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** Muted "OFFLINE" chip: a record replayed from the board's offline buffer (the black box it
 *  kept while the phone was away), not a live sighting. Neutral tone so it reads as provenance,
 *  not an alert; same small-badge anatomy as ExpTag but on the neutral bg3/line palette. */
@Composable
private fun OfflineTag() {
    Text(
        "OFFLINE",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** Amber clock pill for an offline-stamped location, with the fix age. */
@Composable
private fun GpsAgeBadge(age: String) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        modifier = Modifier
            .background(Acab.warn.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
            .border(1.dp, Acab.warn.copy(alpha = 0.35f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    ) {
        Icon(Icons.Filled.Schedule, contentDescription = null,
            tint = Acab.warn, modifier = Modifier.size(9.dp))
        Text(age, color = Acab.warn, fontSize = 9.sp,
            fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
    }
}

/** Confidence chip on a log row. Colour bands are shared with the dossier and with iOS:
 *  under 50 = weak match (warn), under 80 = partial (dim), 80+ = strong (text). */
@Composable
private fun ConfidenceBadge(pct: Int) {
    val tint = when {
        pct < 50 -> Acab.warn
        pct < 80 -> Acab.dim
        else     -> Acab.text
    }
    Box(
        Modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    ) {
        Text("$pct%", color = tint, fontSize = 9.sp,
            fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
    }
}

/** Floating action bar shown in select mode: cancel, count, select-all, and ignore-selected. */
@Composable
private fun SelectBar(count: Int, onCancel: () -> Unit, onSelectAll: () -> Unit, onIgnore: () -> Unit) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.BottomCenter) {
        Row(
            Modifier
                .padding(Acab.pad)
                .fillMaxWidth()
                .background(Acab.bg2, RoundedCornerShape(Acab.radius))
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(Modifier.minimumInteractiveComponentSize().size(32.dp)
                .clickable(onClick = onCancel), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, contentDescription = "Cancel selection",
                    tint = Acab.dim, modifier = Modifier.size(18.dp))
            }
            Spacer(Modifier.size(10.dp))
            Text("$count selected", color = Acab.text, fontSize = 13.sp,
                fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
            Spacer(Modifier.weight(1f))
            // Bulk-select every shown row (iOS parity): the whole point of select mode is
            // batch-ignoring a filtered pile, not tapping hundreds of rows one by one.
            Row(
                Modifier
                    .minimumInteractiveComponentSize()
                    .clip(RoundedCornerShape(50))
                    .border(1.dp, Acab.line, RoundedCornerShape(50))
                    .clickable(onClick = onSelectAll)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("SELECT ALL", color = Acab.dim,
                    fontSize = 11.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
            Spacer(Modifier.size(8.dp))
            val enabled = count > 0
            Row(
                Modifier
                    .minimumInteractiveComponentSize()
                    .background(if (enabled) Acab.accent else Acab.bg3, RoundedCornerShape(50))
                    .clickable(enabled = enabled, onClick = onIgnore)
                    .padding(horizontal = 14.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(Icons.Filled.NotificationsOff, contentDescription = null,
                    tint = if (enabled) Acab.onAccent else Acab.faint, modifier = Modifier.size(14.dp))
                Text("IGNORE", color = if (enabled) Acab.onAccent else Acab.faint,
                    fontSize = 11.sp, letterSpacing = 0.5.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
        }
    }
}

// (The EXP tag now lives in Components.kt as the one shared ExpTag composable.)

/** Shown when the log has rows but the active lens hides every one (NEW with everything
 *  seen, OFFLINE with nothing buffered, a pinned category tile at count 0). Mirrors the
 *  iOS noMatchState copy so a filtered-to-empty list explains itself; the seg chips and
 *  tiles stay right above it, so clearing the lens is one tap away. */
@Composable
private fun NoMatchState(scope: LogScope, catFilter: String? = null) {
    val shape = RoundedCornerShape(Acab.radius)
    val (icon, title, body) = when (scope) {
        LogScope.New -> Triple(
            Icons.Filled.DoneAll, "Nothing new",
            "Everything here is marked seen. New hits show up as they arrive.",
        )
        LogScope.Offline -> Triple(
            Icons.Outlined.Inbox, "Nothing offline",
            "No offline-recorded detections yet. The board buffers these while your phone is away.",
        )
        // ALPR gets a specific line: a quiet result there means something different, most current
        // installs are RF-silent (see the site + faq), so absence is expected and the map is the
        // primary ALPR surface. Mirrors iOS noMatchBody.
        LogScope.All -> if (catFilter == "ALPR") Triple(
            Icons.Outlined.FilterAlt, "No ALPR radio signal",
            "No compatible ALPR radio signal was observed. Some cameras do not broadcast a detectable " +
                "signal, many backhaul over cellular and stay silent. Check the map for known " +
                "installations, or export a diagnostic capture to contribute if you can visually confirm one nearby.",
        ) else Triple(
            Icons.Outlined.FilterAlt, "No matches",
            "No detections in this category yet.",
        )
    }
    Column(
        Modifier
            .fillMaxWidth()
            .clip(shape)
            .background(Acab.bg2)
            .border(1.dp, Acab.line, shape)
            .padding(horizontal = Acab.padCard, vertical = 48.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(icon, contentDescription = null, tint = Acab.line, modifier = Modifier.size(32.dp))
        Text(title, color = Acab.dim, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
        Text(body, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
            textAlign = TextAlign.Center)
    }
}

/** Placeholder shown while nothing's been spotted yet. The [title] names the actual
 *  state (scanning, radios off, sample data) so an empty log never reads as a mystery. */
@Composable
private fun EmptyState(title: String, hint: String?) {
    Column(
        Modifier.fillMaxWidth().padding(vertical = 60.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(Icons.Outlined.RadioButtonChecked, contentDescription = null,
            tint = Acab.line, modifier = Modifier.size(38.dp))
        Text(title, color = Acab.dim, fontSize = 16.sp, fontWeight = FontWeight.SemiBold,
            textAlign = TextAlign.Center)
        if (hint != null) {
            Text(hint, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono,
                textAlign = TextAlign.Center)
        }
    }
}
