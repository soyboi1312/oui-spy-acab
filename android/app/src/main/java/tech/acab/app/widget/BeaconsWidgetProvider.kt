package tech.acab.app.widget

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.ColorFilter
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.Image
import androidx.glance.ImageProvider
import androidx.glance.LocalSize
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.SizeMode
import androidx.glance.appwidget.action.actionStartActivity
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.appwidget.updateAll
import androidx.glance.background
import androidx.glance.color.ColorProvider
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.layout.size
import androidx.glance.layout.width
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import androidx.glance.unit.ColorProvider
import java.time.LocalDate
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import tech.acab.app.MainActivity
import tech.acab.app.R
import tech.acab.app.ble.AcabBleManager

/** Responsive Glance widget for launcher home screens. The provider declares home_screen only:
 *  this face carries the TODAY count, the category strip and the last hit's category, none of
 *  which is gated on the "keep counts private on lock screen" switch, so keyguard hosting would
 *  disclose them on a locked phone. See widget_beacons_info.xml for the full note. */
private class BeaconsGlanceWidget : GlanceAppWidget() {
    // LocalSize is used for real layout decisions below. The default Single mode freezes it at
    // one provider size even after a launcher resize, making one branch effectively permanent.
    override val sizeMode: SizeMode = SizeMode.Exact

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val summary = Summary.read(context)
        provideContent { WidgetContent(context, summary) }
    }
}

class BeaconsWidgetProvider : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = BeaconsGlanceWidget()

    // The first instance placed and the last one removed are the only two edges that can flip
    // "is anything placed at all", so setting the cached answer at those edges keeps it exact without
    // asking AppWidgetManager on every sample. Adding or removing one of several instances
    // leaves the answer unchanged, which is why those edges need no hook.
    override fun onEnabled(context: Context) {
        super.onEnabled(context)
        // This callback is the authoritative first-instance edge. Mark it directly instead of
        // racing a launcher binder query before the new ID is visible; a false result cached here
        // would suppress the summary feed for the whole lifetime of the placed widget.
        placedCache = true
        // Then seed, because the feed only writes while a widget is placed. Without this the first
        // render shows whatever the prefs held when the last widget was removed, and on an idle or
        // disconnected board no publish ever arrives to replace it. peekInstance() never builds a
        // manager. A cold process therefore writes a privacy-safe summary itself; constructing the
        // BLE singleton just to populate a launcher card would also start process-lifetime work.
        // Always retire the old snapshot first. If the process dies between this write and a live
        // manager's store pass, the launcher keeps a safe disconnected zero rather than the prior
        // placement's private count/last hit.
        resetSummary(context)
        val manager = AcabBleManager.peekInstance()
        when (widgetSummaryLifecycleAction(enabled = true, managerAvailable = manager != null)) {
            WidgetSummaryLifecycleAction.SEED_AUTHORITATIVE ->
                manager?.seedWidgetSummary()
            WidgetSummaryLifecycleAction.RESET_SAFE -> Unit
        }
    }

    override fun onDisabled(context: Context) {
        super.onDisabled(context)
        placedCache = false
        // onDisabled is the LAST-instance edge. Retire the cross-process snapshot now, while the
        // process is alive, so removing a CONNECTED/count-bearing widget and later adding it from
        // a cold process cannot resurrect that private state indefinitely.
        resetSummary(context)
    }

    companion object {
        const val PREFS = "beacons_widget"
        const val KEY_COUNT = "w_countToday"
        const val KEY_LAST_TYPE = "w_lastType"
        const val KEY_LAST_AT = "w_lastAt"
        const val KEY_CONNECTED = "w_connected"
        const val KEY_DAY = "w_day"
        const val KEY_CAT_PREFIX = "w_c_"
        const val KEY_PROCESS_GENERATION = "w_processGeneration"
        val CAT_TOKENS = listOf("ALPR", "DRONE", "BODY", "TRACKER", "GLASSES", "CAMERA")

        private val updateScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        // A persisted widget snapshot is readable only in the exact process that published it.
        // This intentionally gives up cold-process cached counts: if a last-removal reset could
        // not reach disk, a later process must show disconnected zero rather than resurrecting a
        // previous placement's private count/last hit. UUID collision is cryptographically
        // negligible and AppWidget-ID reuse is therefore irrelevant to this boundary.
        private val processGeneration = UUID.randomUUID().toString()
        @Volatile private var summaryReadableInProcess = false

        /** Last answer from [isPlaced]; null means "not asked yet". The authoritative
         * enable/disable edges set it directly. */
        @Volatile private var placedCache: Boolean? = null

        /**
         * Whether the user has this widget on a home screen at all.
         * Most installs never place it, and the summary feed samples for the whole length of a
         * drive, so callers should ask this before doing the work that feeds it. getAppWidgetIds
         * is a binder call into AppWidgetService, hence the cache. False on a device with no
         * app-widget host, where getInstance hands back null.
         */
        fun isPlaced(context: Context): Boolean {
            placedCache?.let { return it }
            val app = context.applicationContext
            val fresh = runCatching {
                AppWidgetManager.getInstance(app)
                    .getAppWidgetIds(ComponentName(app, BeaconsWidgetProvider::class.java))
                    .isNotEmpty()
            }.getOrDefault(false)
            placedCache = fresh
            return fresh
        }

        /** Re-render every placed instance from the manager's sampled background feed. That feed
         *  is gated on [isPlaced] at its source now (AcabBleManager.updateWidget returns before
         *  the store pass and the prefs write), so this second ask is belt and braces for any
         *  other caller: with nothing placed there is nothing to re-render, and the answer is
         *  cached either way. */
        fun refresh(context: Context) {
            val app = context.applicationContext
            if (!isPlaced(app)) return
            updateScope.launch { BeaconsGlanceWidget().updateAll(app) }
        }

        fun currentProcessGeneration(): String = processGeneration

        /** Called after the manager atomically applies a complete summary editor. The token is in
         * that same in-memory preferences generation as every summary field. A new process starts
         * unreadable even if an old token remains on disk. */
        fun markCurrentSummaryPublished(context: Context): Boolean {
            val prefs = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val readable = prefs.getString(KEY_PROCESS_GENERATION, null) == processGeneration
            summaryReadableInProcess = readable
            return readable
        }

        fun mayReadPersistedSummary(context: Context): Boolean {
            val stored = context.applicationContext
                .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PROCESS_GENERATION, null)
            return widgetPersistedSummaryMayRender(
                managerAvailable = AcabBleManager.peekInstance() != null,
                processMarkedReadable = summaryReadableInProcess,
                storedGeneration = stored,
                currentGeneration = processGeneration,
            )
        }

        /** Replace, rather than partially update, the cross-process snapshot. `commit` closes the
         * process-death window before this lifecycle callback returns; `clear` also retires any
         * category keys added by a future version that this build does not know how to zero. */
        private fun resetSummary(context: Context) {
            val app = context.applicationContext
            val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val day = LocalDate.now().toEpochDay().toInt()
            summaryReadableInProcess = false
            val committed = prefs.edit()
                .clear()
                .putInt(KEY_COUNT, 0)
                .putString(KEY_LAST_TYPE, "")
                .putLong(KEY_LAST_AT, 0L)
                .putBoolean(KEY_CONNECTED, false)
                .putInt(KEY_DAY, day)
                .putString(KEY_PROCESS_GENERATION, processGeneration)
                .commit()
            // commit() updates the process cache even when its disk write fails. Require BOTH its
            // result and an exact readback; on failure, Summary.read returns a constructed safe
            // value and never consults the possibly stale private fields.
            summaryReadableInProcess = committed &&
                prefs.getInt(KEY_COUNT, -1) == 0 &&
                prefs.getString(KEY_LAST_TYPE, null) == "" &&
                prefs.getLong(KEY_LAST_AT, -1L) == 0L &&
                !prefs.getBoolean(KEY_CONNECTED, true) &&
                prefs.getInt(KEY_DAY, 0) == day &&
                prefs.getString(KEY_PROCESS_GENERATION, null) == processGeneration &&
                CAT_TOKENS.none { prefs.contains(KEY_CAT_PREFIX + it) }
            if (isPlaced(app)) updateScope.launch { BeaconsGlanceWidget().updateAll(app) }
        }
    }
}

/** Pure lifecycle policy so the remove/re-add/cold-process boundary is pinned by local JVM tests. */
internal enum class WidgetSummaryLifecycleAction { RESET_SAFE, SEED_AUTHORITATIVE }

internal fun widgetSummaryLifecycleAction(
    enabled: Boolean,
    managerAvailable: Boolean,
): WidgetSummaryLifecycleAction =
    if (enabled && managerAvailable) WidgetSummaryLifecycleAction.SEED_AUTHORITATIVE
    else WidgetSummaryLifecycleAction.RESET_SAFE

internal fun widgetPersistedSummaryMayRender(
    managerAvailable: Boolean,
    processMarkedReadable: Boolean,
    storedGeneration: String?,
    currentGeneration: String,
): Boolean = managerAvailable && processMarkedReadable && storedGeneration == currentGeneration

private data class Summary(
    val count: Int,
    val connected: Boolean,
    val lastType: String,
    val lastAt: Long,
    val categories: List<Pair<String, Int>>,
) {
    companion object {
        fun read(context: Context): Summary {
            if (!BeaconsWidgetProvider.mayReadPersistedSummary(context)) {
                return Summary(0, false, "", 0L, emptyList())
            }
            val prefs = context.getSharedPreferences(BeaconsWidgetProvider.PREFS, Context.MODE_PRIVATE)
            val fresh = prefs.getInt(BeaconsWidgetProvider.KEY_DAY, 0) ==
                LocalDate.now().toEpochDay().toInt()
            return Summary(
                count = if (fresh) prefs.getInt(BeaconsWidgetProvider.KEY_COUNT, 0) else 0,
                connected = prefs.getBoolean(BeaconsWidgetProvider.KEY_CONNECTED, false),
                // The stale-day rule covers the TODAY count and category strip only. The last hit
                // survives midnight ("body cam · 8h ago" is still true at 00:30), matching iOS
                // readEntry; gating it here swaps in the green no-detections shield at the first
                // post-midnight re-render.
                lastType = prefs.getString(BeaconsWidgetProvider.KEY_LAST_TYPE, "") ?: "",
                lastAt = prefs.getLong(BeaconsWidgetProvider.KEY_LAST_AT, 0L),
                categories = BeaconsWidgetProvider.CAT_TOKENS.mapNotNull { token ->
                    val n = if (fresh) prefs.getInt(BeaconsWidgetProvider.KEY_CAT_PREFIX + token, 0) else 0
                    if (n > 0) token to n else null
                },
            )
        }
    }
}

private data class WidgetPalette(
    val bg: ColorProvider,
    val text: ColorProvider,
    val dim: ColorProvider,
    val accent: ColorProvider,
    val okay: ColorProvider,
)

// Every color goes through the day/night ColorProvider overload so the launcher re-resolves
// at draw time. Picking one value at compose time bakes it into the generated RemoteViews,
// and a placed widget then wears the stale palette after a system theme flip until the next
// refresh (up to 30 min of a near-white card on a dark home screen).
private val palette = WidgetPalette(
    bg = ColorProvider(day = Color(0xFFFFF8F8), night = Color(0xFF130F10)),
    text = ColorProvider(day = Color(0xFF271F21), night = Color(0xFFF4EEF0)),
    dim = ColorProvider(day = Color(0xFF685E61), night = Color(0xFFA99EA1)),
    accent = ColorProvider(day = Color(0xFFD52D25), night = Color(0xFFFF4B40)),
    okay = ColorProvider(day = Color(0xFF217A45), night = Color(0xFF65DA93)),
)

@Composable
private fun WidgetContent(context: Context, summary: Summary) {
    val colors = palette
    val size = LocalSize.current
    val short = size.height < 138.dp
    val showCategories = summary.categories.isNotEmpty() && size.height >= 100.dp
    val categoryRows = summary.categories.chunked(3)
    // At the provider's minimum height, two bounded category rows take the last-line slot. A
    // taller resize shows both; an empty day always keeps the useful connection/no-hits line.
    val showLast = !showCategories || !short
    Column(
        modifier = GlanceModifier.fillMaxSize().appWidgetBackground().background(colors.bg)
            .cornerRadius(20.dp).clickable(actionStartActivity(Intent(context, MainActivity::class.java)))
            .padding(horizontal = 14.dp, vertical = if (short) 10.dp else 16.dp),
    ) {
        Row(GlanceModifier.fillMaxWidth(), verticalAlignment = Alignment.Vertical.CenterVertically) {
            Text("beacons", style = TextStyle(color = colors.dim, fontSize = 11.sp,
                fontWeight = FontWeight.Bold))
            Spacer(GlanceModifier.width(10.dp))
            Text(if (summary.connected) "● CONNECTED" else "○ NOT CONNECTED",
                style = TextStyle(color = if (summary.connected) colors.accent else colors.dim,
                    fontSize = 10.sp, fontWeight = FontWeight.Bold))
        }
        Spacer(GlanceModifier.height(if (short) 4.dp else 8.dp))
        Row(verticalAlignment = Alignment.Vertical.Bottom) {
            Text(summary.count.toString(), style = TextStyle(color = colors.text,
                fontSize = if (short) 34.sp else 42.sp,
                fontWeight = FontWeight.Bold))
            Spacer(GlanceModifier.width(8.dp))
            Text("TODAY", style = TextStyle(color = colors.accent, fontSize = 10.sp,
                fontWeight = FontWeight.Bold))
        }
        if (showCategories) {
            Spacer(GlanceModifier.height(if (short) 2.dp else 6.dp))
            // Three cells per row keeps long labels bounded at the 4-cell provider width. Never
            // truncate the list: a six-category day renders two rows rather than losing 5 and 6.
            categoryRows.forEachIndexed { rowIndex, row ->
                Row(GlanceModifier.fillMaxWidth()) {
                    row.forEach { (name, n) ->
                        Text("$name $n", style = TextStyle(color = colors.dim, fontSize = 9.sp,
                            fontWeight = FontWeight.Bold),
                            modifier = GlanceModifier.padding(end = 12.dp))
                    }
                }
                if (rowIndex < categoryRows.lastIndex) {
                    Spacer(GlanceModifier.height(1.dp))
                }
            }
        }
        if (showLast) {
            Spacer(GlanceModifier.height(if (short) 4.dp else 8.dp))
            Row(verticalAlignment = Alignment.Vertical.CenterVertically) {
                val hasLiveHit = summary.lastType.isNotEmpty() && summary.lastAt > 0
                Image(
                    provider = ImageProvider(if (hasLiveHit) lastIcon(summary.lastType) else R.drawable.ic_w_ok),
                    contentDescription = null,
                    modifier = GlanceModifier.size(16.dp),
                    // The checked-in vectors are white. Tint is required on the light palette or
                    // the glyph disappears against the widget background.
                    colorFilter = ColorFilter.tint(if (hasLiveHit) colors.accent else colors.okay),
                )
                Spacer(GlanceModifier.width(7.dp))
                val last = when {
                    hasLiveHit ->
                        "${summary.lastType.lowercase()} · ${relativeAgo(summary.lastAt)}"
                    summary.connected -> "no detections"
                    else -> "open the app to connect"
                }
                Text(last, style = TextStyle(color = if (hasLiveHit) colors.dim else colors.okay,
                    fontSize = 11.sp))
            }
        }
    }
}

private fun lastIcon(cat: String): Int = when (cat) {
    "ALPR" -> R.drawable.ic_w_alpr
    "DRONE" -> R.drawable.ic_w_drone
    "BODY CAM" -> R.drawable.ic_w_body
    "TRACKER" -> R.drawable.ic_w_tracker
    "GLASSES" -> R.drawable.ic_w_glasses
    "CAMERA" -> R.drawable.ic_w_netcam
    "WATCHED" -> R.drawable.ic_w_star
    else -> R.drawable.ic_w_ok
}

private fun relativeAgo(atMs: Long): String {
    val secs = ((System.currentTimeMillis() - atMs) / 1000).coerceAtLeast(0)
    return when {
        secs < 5 -> "now"
        secs < 60 -> "${secs}s ago"
        secs < 3600 -> "${secs / 60}m ago"
        secs < 86_400 -> "${secs / 3600}h ago"
        else -> "${secs / 86_400}d ago"
    }
}
