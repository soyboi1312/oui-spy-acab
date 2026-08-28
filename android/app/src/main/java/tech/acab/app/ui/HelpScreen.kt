package tech.acab.app.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import tech.acab.app.model.FaqContent
import tech.acab.app.model.FaqQuestion
import tech.acab.app.model.FaqSupportRow
import tech.acab.app.ui.theme.Acab

/**
 * Bundled Help + FAQ. Mirrors iOS HelpView: same content file, same sections, same search
 * semantics, same support rows, same accordion behaviour.
 *
 * NO WEBVIEW AND NO FETCH. Every answer ships in the APK and renders locally, so opening Help
 * cannot tell anyone that you opened Help. That is the same no-cloud stance as the detection path,
 * and it is why the "FAQ online" support row is the only thing here that reaches the network , and
 * only when the user taps it.
 *
 * [scrollToId] is the deep link from a dossier's RELATED HELP row: that question opens expanded
 * and its bring-into-view requester scrolls it into view after the first layout pass.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun HelpScreen(
    scrollToId: String? = null,
    onImproveDetection: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val faq = remember { FaqContent.get(context) }
    var query by remember { mutableStateOf("") }
    // Seeded from the deep link so the linked answer is already open on arrival.
    var openId by remember { mutableStateOf(scrollToId) }
    var tourOpen by remember { mutableStateOf(false) }

    val searching = query.trim().isNotEmpty()
    val results = remember(query) { faq.search(query) }
    val relatedHelpRequester = remember { BringIntoViewRequester() }
    LaunchedEffect(scrollToId) {
        if (scrollToId != null && faq.question(scrollToId) != null) {
            withFrameNanos { }
            relatedHelpRequester.bringIntoView()
        }
    }

    // Own a bounded viewport and scroll the FAQ inside it. The tour is a sibling in this root Box,
    // so fillMaxSize means the visible Help route, not an unbounded parent scrolling Column.
    Box(modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize()
                .verticalScroll(rememberScrollState())
                .then(if (tourOpen) Modifier.clearAndSetSemantics { } else Modifier)
                .padding(horizontal = 14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
        // ---- search ----------------------------------------------------------------------
        Row(
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(Acab.radius))
                .background(Acab.bg2)
                .border(1.dp, Acab.line, RoundedCornerShape(Acab.radius))
                .padding(horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("?", color = Acab.faint, fontSize = 13.sp, fontFamily = Acab.mono)
            Spacer(Modifier.width(9.dp))
            BasicTextField(
                value = query,
                onValueChange = { query = it },
                singleLine = true,
                textStyle = TextStyle(color = Acab.text, fontSize = 13.sp, fontFamily = Acab.mono),
                cursorBrush = SolidColor(Acab.accent),
                modifier = Modifier.weight(1f).minimumInteractiveComponentSize()
                    .semantics { contentDescription = "Search help" },
                decorationBox = { inner ->
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.CenterStart) {
                        if (query.isEmpty()) {
                            Text("search help", color = Acab.faint, fontSize = 13.sp,
                                fontFamily = Acab.mono)
                        }
                        inner()
                    }
                },
            )
            if (query.isNotEmpty()) {
                Text(
                    "clear",
                    color = Acab.dim, fontSize = 11.sp, fontFamily = Acab.mono,
                    modifier = Modifier.minimumInteractiveComponentSize().clickable { query = "" },
                )
            }
        }

        if (searching) {
            // ---- results -----------------------------------------------------------------
            Column(
                Modifier.fillMaxWidth().panel().padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                Kicker(if (results.isEmpty()) "NO MATCHES" else "${results.size} RESULT${if (results.size == 1) "" else "S"}")
                if (results.isEmpty()) {
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "nothing here matches that. the support rows below reach a human, and the " +
                            "full FAQ online may be newer than this build.",
                        color = Acab.dim, fontSize = 12.5.sp, fontFamily = Acab.mono, lineHeight = 17.sp,
                    )
                } else {
                    results.forEachIndexed { i, (kicker, q) ->
                        QuestionRow(q, kicker, openId == q.id) { openId = if (openId == q.id) null else q.id }
                        if (i < results.size - 1) Hairline()
                    }
                }
            }
        } else {
            // ---- sections ----------------------------------------------------------------
            faq.sections.forEach { section ->
                Column(
                    Modifier.fillMaxWidth().panel().padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Kicker(section.kicker)
                    section.questions.forEachIndexed { i, q ->
                        QuestionRow(
                            q, null, openId == q.id,
                            modifier = if (q.id == scrollToId) {
                                Modifier.bringIntoViewRequester(relatedHelpRequester)
                            } else Modifier,
                        ) { openId = if (openId == q.id) null else q.id }
                        if (i < section.questions.size - 1) Hairline()
                    }
                }
            }
        }

        // ---- support ---------------------------------------------------------------------
        Column(
            Modifier.fillMaxWidth().panel().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Kicker("SUPPORT")
            // The "improve detection" row opens the contribution composer, which lives on the
            // Beacon tab. When Help is shown somewhere that cannot reach it (a dossier's related
            // help passes no handler), drop the row rather than render a dead one.
            val rows = faq.support.filter { it.action != "improveDetection" || onImproveDetection != null }
            rows.forEachIndexed { i, row ->
                SupportRow(row) {
                    when {
                        // Named actions, not URLs, so the JSON never has to know about navigation.
                        row.action == "improveDetection" -> onImproveDetection?.invoke()
                        row.action == "firstRunTour" -> tourOpen = true
                        row.url != null -> runCatching {
                            context.startActivity(Intent(Intent.ACTION_VIEW, row.url.toUri()))
                        }
                    }
                }
                if (i < rows.size - 1) Hairline()
            }
        }

            Spacer(Modifier.height(6.dp))
        }

        if (tourOpen) FirstRunTourOverlay(onFinish = { tourOpen = false })
    }
}

@Composable
private fun QuestionRow(
    q: FaqQuestion,
    sectionKicker: String?,
    open: Boolean,
    modifier: Modifier = Modifier,
    onToggle: () -> Unit,
) {
    Column(modifier.fillMaxWidth().minimumInteractiveComponentSize()
        .clickable(role = Role.Button) { onToggle() }
        .semantics(mergeDescendants = true) {
            stateDescription = if (open) "expanded" else "collapsed"
        }
        .padding(vertical = 10.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f)) {
                // Search results carry their section so an answer found out of context still says
                // where it lives; the sectioned list does not, because the kicker is right above.
                if (sectionKicker != null) {
                    Text(sectionKicker, color = Acab.faint, fontSize = 9.sp, fontFamily = Acab.mono)
                    Spacer(Modifier.height(3.dp))
                }
                Text(q.q, color = Acab.text, fontSize = 13.5.sp, lineHeight = 18.sp, fontFamily = Acab.display)
            }
            Spacer(Modifier.width(10.dp))
            Text(if (open) "−" else "+", color = Acab.faint, fontSize = 14.sp,
                fontFamily = Acab.mono, modifier = Modifier.clearAndSetSemantics { })
        }
        if (open) {
            Spacer(Modifier.height(8.dp))
            Text(q.a, color = Acab.dim, fontSize = 12.5.sp, lineHeight = 18.sp, fontFamily = Acab.mono)
        }
    }
}

@Composable
private fun SupportRow(row: FaqSupportRow, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .clickable(
                onClickLabel = if (row.external) {
                    "open ${row.title} in browser"
                } else "open ${row.title}",
                role = Role.Button,
                onClick = onClick,
            ).padding(vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(
                row.title, color = Acab.text, fontSize = 13.5.sp, fontFamily = Acab.display,
                textDecoration = if (row.external) TextDecoration.Underline else TextDecoration.None,
            )
            Spacer(Modifier.height(2.dp))
            Text(row.sub, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        // An outward-opening row says so before it is tapped: this app never opens a browser
        // without warning, because leaving the app is exactly the moment a network request happens.
        Text(if (row.external) "↗" else "›", color = Acab.faint, fontSize = 13.sp, fontFamily = Acab.mono)
    }
}

@Composable
private fun Hairline() {
    Box(Modifier.fillMaxWidth().height(1.dp).background(Acab.line))
}
