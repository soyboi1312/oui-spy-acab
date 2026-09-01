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
import androidx.compose.material.icons.automirrored.filled.ListAlt
import androidx.compose.material.icons.filled.SettingsInputAntenna
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.Icon
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
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
 * asks, in the order they ask it. Skippable, never shows twice, and it teaches the ideas the rest
 * of the app assumes you already have: what the beacon does, what quiet means, how to read
 * confidence, and where detector coverage lives.
 *
 * EVERY STRING HERE IS SHARED COPY, and "word-for-word" above is a claim nothing enforces: a
 * wording change made on one side alone drifts silently. The last one left card 4 with a different
 * title and body on each platform, and only iOS told the user that tapping an OFF category opens
 * its setting - which THIS platform does too (StatusScreen's onClickLabel is "open detector
 * settings" for exactly that tap). Edit both files in the same change.
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
        "the beacon does the scanning and the app is its screen. keep it powered and nearby; you do not have to point it, aim it, or press anything.",
        "detection is passive. it does not jam, spoof, or control nearby devices. it only reports what they already broadcast.",
    ),
    TourCard(
        Icons.Filled.CheckCircle,
        "quiet does not mean clear",
        "zero nearby means no supported broadcast was recognized in the last 45 seconds. silent, wired, cellular-only, 5 GHz-only, powered-off, or unsupported gear can still be there.",
        "the radar shows signal strength, not direction.",
    ),
    TourCard(
        Icons.AutoMirrored.Filled.ListAlt,
        "the Log keeps the details",
        "each detection lands in the Log, newest first. tap one to see what matched and its confidence. when Location is allowed, it also shows where your phone heard it.",
        "80 and up is a strong signature match. under 50 is worth a second look, not an alarm. the phone keeps the main Log. the optional offline buffer lets the beacon keep hits while your phone is away, tagged with the last location your phone shared until that fix is 18 hours old, then with no location.",
    ),
    TourCard(
        Icons.Filled.Tune,
        "Status is your starting point",
        "tap a category on Status to open its filtered Log. if that detector is off, the same tap opens its setting on the Beacon tab.",
        "ALPR, drones, body cams, and glasses start on. trackers and network cameras start off because they can be noisy. desert mode reports every nearby broadcast when you want proof of life, so turn it back off when you are done.",
    ),
)

/** Session-only orientation for sample data. It deliberately has no persistence key: leaving
 * sample data resets it, while rotating in the same sample session does not consume or replay the
 * real-board tour. */
private val SAMPLE_TOUR_CARDS = listOf(
    TourCard(
        Icons.Filled.SettingsInputAntenna,
        "this is sample data",
        "six fictional nearby devices fill the app so you can try every screen without a beacon. nothing here came from your surroundings.",
        "sample settings are safe to explore. they do not configure hardware or replace the one-time orientation shown when your real beacon connects.",
    ),
    TourCard(
        Icons.AutoMirrored.Filled.ListAlt,
        "follow a sample hit",
        "tap a category on Status to open its filtered Log, tap a row for the full details, and use Map to see where your phone heard each example.",
        "the examples cover ALPR, a drone, body camera, tracker, recording glasses, and a network camera.",
    ),
    TourCard(
        Icons.Filled.Tune,
        "leave whenever you are ready",
        "an Exit sample data banner stays at the top of the app, so you never have to hunt through settings to return to beacon scanning.",
        "your real saved Log is restored after you exit. sample detections are never added to it.",
    ),
)

@Composable
fun FirstRunTourOverlay(
    sampleMode: Boolean = false,
    onFinish: () -> Unit,
    onBack: () -> Unit = onFinish,
) {
    BackHandler(onBack = onBack)
    val cards = if (sampleMode) SAMPLE_TOUR_CARDS else TOUR_CARDS
    val pager = rememberPagerState(pageCount = { cards.size })
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
                    Text("skip", color = Acab.dim, fontSize = 12.sp,
                        fontWeight = FontWeight.Medium, fontFamily = Acab.mono)
                }
            }

            HorizontalPager(state = pager, modifier = Modifier.weight(1f)) { i ->
                val c = cards[i]
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
                    Text(
                        c.title,
                        color = Acab.text,
                        fontSize = 23.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.semantics { heading() },
                    )
                    Spacer(Modifier.height(18.dp))
                    Text(c.body, color = Acab.dim, fontSize = 12.5.sp,
                        fontFamily = Acab.mono, lineHeight = 19.sp)
                    Spacer(Modifier.height(18.dp))
                    Text(c.note, color = Acab.faint, fontSize = 10.5.sp,
                        fontFamily = Acab.mono, lineHeight = 16.sp)
                }
            }

            Column(
                Modifier.fillMaxWidth().padding(bottom = 18.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    "step ${pager.currentPage + 1} of ${cards.size}",
                    color = Acab.dim,
                    fontSize = 10.5.sp,
                    fontFamily = Acab.mono,
                    modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite },
                )
                Row(horizontalArrangement = Arrangement.Center) {
                    cards.indices.forEach { i ->
                        val on = i == pager.currentPage
                        Box(
                            Modifier
                                .padding(horizontal = 3.5.dp)
                                .size(if (on) 7.dp else 5.dp)
                                .background(if (on) Acab.accent else Acab.faint, CircleShape),
                        )
                    }
                }
            }

            val last = pager.currentPage >= cards.size - 1
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 20.dp)
                    .padding(bottom = 26.dp)
                    .minimumInteractiveComponentSize()
                    .background(Acab.accent, RoundedCornerShape(Acab.radiusSm))
                    .clickable(
                        onClickLabel = if (last) {
                            if (sampleMode) "explore sample data" else "open Status"
                        } else "next tour step",
                        role = Role.Button,
                    ) {
                        if (last) onFinish()
                        else scope.launch { pager.animateScrollToPage(pager.currentPage + 1) }
                    }
                    .padding(vertical = 15.dp),
                contentAlignment = Alignment.Center,
            ) {
                Text(if (last) {
                    if (sampleMode) "explore sample data" else "open Status"
                } else "next", color = Acab.onAccent,
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
