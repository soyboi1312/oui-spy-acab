package tech.acab.app.ui

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.filled.Percent
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material3.Icon
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import kotlinx.coroutines.launch
import tech.acab.app.ui.theme.Acab

/**
 * One-time orientation, shown the first time a real board connects (mirrors the iOS
 * FirstRunTourView card-for-card and word-for-word).
 *
 * WHY THIS EXISTS: AcabApp hands off to MainScreen the instant state == READY, so the moment of
 * peak confusion , "I'm connected, now what?" , had zero guidance. New users landed on tabs full
 * of vocabulary (Desert mode, watchlist, confidence, category toggles) with nothing telling them
 * where to look first. Friends kept getting stuck exactly here (2026-07-29).
 *
 * Deliberately NOT a feature tour. Four cards, each answering one question a first-timer actually
 * asks, in the order they ask it. Skippable, never shows twice, and it teaches the two ideas the
 * rest of the app assumes you already have: what a confidence number means, and that silence is a
 * real (good) result rather than a broken device.
 */
private data class TourCard(
    val icon: ImageVector,
    val title: String,
    val body: String,
    val note: String,
)

private val TOUR_CARDS = listOf(
    TourCard(
        Icons.Filled.SettingsInputAntenna,
        "your beacon is listening",
        "It scans on two radios at once and sends what it hears to your phone. You don't have to point it, aim it, or press anything.",
        "Detection is passive: it does not jam, spoof, or control nearby devices. It only reports what they already broadcast.",
    ),
    TourCard(
        Icons.AutoMirrored.Filled.ListAlt,
        "the Log is the answer",
        "Every device it recognizes lands in the Log, newest first. Tap any row to see what it is, how sure the beacon is, and where you were when it was heard.",
        "The Log lives on your phone, not on the beacon. It survives the board going flat, and you can export it as CSV.",
    ),
    TourCard(
        Icons.Filled.Percent,
        "read the confidence number",
        "Each hit carries a percentage. 80 and up is a strong signature match. Under 50 means something looked similar and is worth a second glance, not an alarm.",
        "Tap a row for the full reasoning: which signal matched, and why the beacon scored it that way.",
    ),
    // The body leads with "Most places are quiet." then the canonical empty-log wording (both
    // kept in step with iOS): an empty log is a statement about compatible BROADCASTS, never a
    // clean bill of health. Silent gear exists. The note names the right opt-in set: body cams
    // default ON in firmware, so it is trackers and network cameras that need the settings trip.
    TourCard(
        Icons.Filled.CheckCircle,
        "quiet is a real result",
        "Most places are quiet. An empty log means no compatible radio broadcast was recognized nearby - not that nothing is there. Silent, wired, cellular-only, or powered-off equipment has nothing for beacons to hear.",
        "Want to see it work? Body cams and drones are common. Trackers and network cameras are opt-in, switch them on in Beacon settings.",
    ),
    // Closing trust card (kept word-for-word with iOS). Prompted by the Improve detection / log
    // export flows: users reasonably wonder what file access those need. The honest answer is a
    // win: exports are written in app-private space and leave only via the share sheet, and the
    // app never requests a storage permission (the manifest's WRITE_EXTERNAL_STORAGE is a legacy
    // maxSdk=29 grant nothing ever requests at runtime).
    TourCard(
        Icons.Filled.Lock,
        "nothing leaves without you",
        "Log exports and Improve detection reports are files the app writes in its own private space. Sharing one opens the system share sheet, and you choose exactly where it goes.",
        "Nothing is uploaded automatically. beacons never asks for storage permission and cannot see your photos or files.",
    ),
)

@Composable
fun FirstRunTourOverlay(onFinish: () -> Unit) {
    BackHandler(onBack = onFinish)
    val pager = rememberPagerState(pageCount = { TOUR_CARDS.size })
    val scope = rememberCoroutineScope()
    // Full-bleed opaque surface with a swallow-taps click so nothing behind it can be reached
    // while the tour is up (Compose has no modal-sheet equivalent here without extra deps).
    Box(
        Modifier
            .fillMaxSize()
            .background(Acab.bg)
            .windowInsetsPadding(WindowInsets.safeDrawing)
            // Consume only pointer changes no child handled. Skip/Next still receive their taps,
            // while empty overlay space cannot reach the app beneath and no giant disabled
            // TalkBack node is published for this touch shield.
            .pointerInput(Unit) {
                awaitPointerEventScope {
                    while (true) {
                        val event = awaitPointerEvent(PointerEventPass.Final)
                        event.changes.filterNot { it.isConsumed }.forEach { it.consume() }
                    }
                }
            },
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 12.dp, top = 10.dp),
                horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onFinish) {
                    Text("Skip", color = Acab.dim, fontSize = 12.sp,
                        fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
                }
            }

            HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { i ->
                val c = TOUR_CARDS[i]
                // Scrollable: at large font scales (or a short landscape window) a page's copy
                // outgrows the viewport, and without the scroll the overflow was simply cut off.
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState())
                        .padding(horizontal = 26.dp, vertical = 18.dp),
                    verticalArrangement = Arrangement.Center,
                ) {
                    Icon(c.icon, contentDescription = null, tint = Acab.accent,
                        modifier = Modifier.size(34.dp))
                    Spacer(Modifier.height(18.dp))
                    Text(c.title, color = Acab.text, fontSize = 23.sp,
                        fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(18.dp))
                    Text(c.body, color = Acab.dim, fontSize = 12.5.sp,
                        fontFamily = Acab.mono, lineHeight = 19.sp)
                    Spacer(Modifier.height(18.dp))
                    Text(c.note, color = Acab.faint, fontSize = 10.5.sp,
                        fontFamily = Acab.mono, lineHeight = 16.sp)
                }
            }

            Row(
                Modifier.fillMaxWidth().padding(bottom = 18.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                TOUR_CARDS.indices.forEach { i ->
                    val on = i == pager.currentPage
                    Box(
                        Modifier
                            .padding(horizontal = 3.5.dp)
                            .size(if (on) 7.dp else 5.dp)
                            .background(if (on) Acab.accent else Acab.faint, CircleShape),
                    )
                }
            }

            val last = pager.currentPage >= TOUR_CARDS.size - 1
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 26.dp)
                    .minimumInteractiveComponentSize()
                    .background(Acab.accent, RoundedCornerShape(Acab.radiusSm))
                    .clickable {
                        if (last) onFinish()
                        else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                    }
                    .padding(vertical = 15.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(if (last) "Start listening" else "Next", color = Acab.onAccent,
                    fontSize = 14.sp, fontWeight = FontWeight.Bold, fontFamily = Acab.mono)
            }
        }
    }
}

/** Persistence for the one-time tour. Mirrors iOS FirstRunTour. */
object FirstRunTour {
    private const val PREFS = "acab_ui"
    private const val KEY = "first_run_tour_seen"
    fun hasSeen(ctx: Context): Boolean =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(KEY, false)
    fun markSeen(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, true).apply()
    /** "Show the tour again" from Device settings. */
    fun reset(ctx: Context) =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(KEY, false).apply()
}
