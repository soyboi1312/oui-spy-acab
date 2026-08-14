package tech.acab.app.ui

import android.content.Intent
import android.content.ClipData
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.Spacer
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Switch
import androidx.compose.material3.minimumInteractiveComponentSize
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.ButtonDefaults
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import androidx.exifinterface.media.ExifInterface
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.contributionBlankColumns
import tech.acab.app.ble.contributionCsvDataRowCount
import tech.acab.app.ble.redactCsvColumns
import java.io.File

/**
 * "Help improve detection" - a structured MANUAL export composer. Rendered inside DeviceScreen's
 * SubScreen overlay. All flow state lives in [ContributionViewModel] (activity-scoped), so a tab
 * switch, back press, resize, or activity recreation can no longer silently discard a capture.
 *
 * THIS CONTRIBUTION SHARES NOTHING BY ITSELF. It builds a capture the user REVIEWS, then hands it
 * to the OS share sheet (or saves a copy). This flow has no automatic submission path: the user
 * picks the target and confirms. Pre-addressed to logs@soyboi.tech (email, not a public issue,
 * because a capture can contain GPS - mirrors the site's "send the raw capture" flow).
 *
 * WHAT THIS DOES AND DOES NOT SETTLE. The engineering fact is only that this contribution is never
 * submitted automatically. It does NOT by itself decide the store declarations, and the comment must not
 * pretend it does. Apple's optional-feedback exception has several simultaneous conditions (it must
 * clearly show the submitting user's identity, be infrequent, and sit outside primary functionality)
 * that a share like this does not obviously meet; Google requires accurate disclosure of optional
 * collection, though a user-initiated transfer may fall under "sharing" rather than "collection".
 * Treat the Data Safety / App Privacy answers as a SEPARATE determination to make against the
 * current policies before shipping this, not something this file can assert. See
 * developer.apple.com/app-store/app-privacy-details and
 * support.google.com/googleplay/android-developer/answer/10787469.
 *
 * The iOS twin is built separately (Spencer builds that in Xcode); keep the copy in step.
 */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun ContributeContent(ble: AcabBleManager, vm: ContributionViewModel) {
    val context = LocalContext.current

    // What the user VISUALLY confirmed. This is their attestation, never a machine claim, so the
    // options are plain-language device classes, including "Unknown" so an unclassifiable
    // sighting is still contributable - those are the most valuable captures. Kept identical to
    // the iOS composer's list.
    val kinds = listOf("ALPR camera", "Body camera", "Mobile surveillance trailer", "Drone", "Unknown")

    // BOUNDED capture window. The contribution exports ONLY what was audible between Start and Stop,
    // so it is a purpose-built diagnostic capture, not the full history. nowMs ticks while capturing
    // to drive the live count and elapsed timer; the window itself is wall-clock, so time spent on
    // another tab still counts (the ViewModel keeps startMs alive across navigation).
    // Recomposition happens on the detections flow AND this tick, so the window count re-reads.
    // REVIEW counts rows of the FROZEN CSV, not the membership map: the CSV is the artifact
    // that leaves, so it is the only count the header and disclosure are allowed to claim.
    val liveCount = if (vm.phase == CapturePhase.CAPTURING) ble.windowObservationCount(vm.startMs, vm.nowMs)
                    else if (vm.phase == CapturePhase.REVIEW) vm.frozenRowCount else 0
    LaunchedEffect(vm.phase) {
        if (vm.phase == CapturePhase.CAPTURING) {
            while (true) { vm.nowMs = System.currentTimeMillis(); kotlinx.coroutines.delay(1000) }
        }
    }

    // Export failures surface as a toast (this overlay has no snackbar host); one-shot, then cleared.
    LaunchedEffect(vm.shareError) {
        vm.shareError?.let {
            Toast.makeText(context, it, Toast.LENGTH_LONG).show()
            vm.shareError = null
        }
    }

    // The preparation coroutine is activity-independent. Delivery is consumed here, by the
    // currently composed Activity, so a rotation cannot make a destroyed Activity launch the
    // chooser. consumePreparedShare is atomic and makes recomposition single-delivery.
    val pendingShare = vm.pendingShare
    LaunchedEffect(pendingShare?.id) {
        val prepared = pendingShare?.let { vm.consumePreparedShare(it.id) } ?: return@LaunchedEffect
        try {
            context.startActivity(Intent.createChooser(prepared, "Share observation for review"))
        } catch (e: Exception) {
            vm.finishExport("Couldn't open the share sheet: ${e.message ?: "no compatible app"}")
        }
    }

    val pickPhoto = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia()
    ) { uri -> if (uri != null && !vm.sharePreparing) vm.photo = uri }

    // CSV-only save: SAF create-document, so the user picks the destination themselves. It writes
    // the same redacted CSV as Share but intentionally never claims or copies the optional photo;
    // the visible action says SAVE CSV COPY so the two delivery manifests cannot be confused.
    val saveCopy = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument("text/csv")
    ) { uri ->
        // Redacted per the current switches, same as the share path. Leaves the composer OPEN after
        // saving so the user can also share, or adjust and re-export. viewModelScope, not a
        // composition scope: leaving the tab mid-write must not cancel the file half-written.
        if (uri != null) vm.beginExport()?.let { spec ->
            vm.viewModelScope.launch {
                var error: String? = null
                try {
                    // Pure text ops over the immutable request captured before this coroutine.
                    val csv = withContext(Dispatchers.Default) {
                        redactCsvColumns(spec.frozenCsv, contributionBlankColumns(
                            spec.includeObserverLocation, spec.includeDroneLocation,
                            spec.includeOperatorLocation))
                    }
                    withContext(Dispatchers.IO) {
                        context.contentResolver.openOutputStream(uri)?.use {
                            it.write(csv.toByteArray(Charsets.UTF_8)); it.flush()
                        } ?: throw java.io.IOException("could not open the destination")
                    }
                } catch (e: Exception) {
                    error = "Couldn't save the CSV: ${e.message ?: "write failed"}"
                } finally {
                    vm.finishExport(error)
                }
            }
        }
    }

    Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
        when (vm.phase) {
            // ---- IDLE: explain, then arm a bounded capture window --------------------------------
            CapturePhase.IDLE -> {
                Text(
                    "Found a device beacons didn't identify? Start a short capture, walk around the " +
                        "device, then stop. Only what the beacon heard during that window is exported, " +
                        "so your contribution is a focused diagnostic capture, not your whole history.",
                    color = Acab.dim, fontSize = 13.sp,
                )
                OutlinedButton(
                    onClick = {
                        if (vm.sharePreparing) return@OutlinedButton
                        vm.capturedAtById = emptyMap()
                        vm.frozenCsv = null
                        vm.startMs = ble.beginContributionCapture(); vm.nowMs = vm.startMs
                        vm.phase = CapturePhase.CAPTURING
                    },
                    enabled = !vm.sharePreparing,
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, Acab.accent),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.text),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) { Text("START CAPTURE", fontFamily = Acab.mono, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                Text("Discard", color = Acab.faint, fontSize = 12.sp, fontFamily = Acab.mono,
                    modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                        .clickable(enabled = !vm.sharePreparing) { vm.requestExit() }
                        .padding(vertical = 8.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }

            // ---- CAPTURING: live count + elapsed, until the user stops ---------------------------
            CapturePhase.CAPTURING -> {
                Text("CAPTURING", color = Acab.accent, fontSize = 11.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 1.sp)
                Text("Walk around the device, then stop.", color = Acab.dim, fontSize = 13.sp)
                Text("$liveCount observation${if (liveCount == 1) "" else "s"} heard  ·  ${elapsed(vm.startMs, vm.nowMs)}",
                    color = Acab.text, fontSize = 16.sp, fontFamily = Acab.mono, fontWeight = FontWeight.Bold)
                OutlinedButton(
                    onClick = {
                        if (vm.sharePreparing) return@OutlinedButton
                        val stopped = System.currentTimeMillis()
                        // One manager call freezes membership, timestamps and row fields under
                        // one store lock. No live update can land between the map and the CSV.
                        val frozen = ble.freezeContributionWindow(vm.startMs, stopped)
                        vm.capturedAtById = frozen.capturedAtById
                        vm.frozenCsv = frozen.csv
                        vm.stopMs = stopped
                        vm.phase = CapturePhase.REVIEW
                    },
                    enabled = !vm.sharePreparing,
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, Acab.accent),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.text),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) { Text("STOP CAPTURE", fontFamily = Acab.mono, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                Text("Discard", color = Acab.faint, fontSize = 12.sp, fontFamily = Acab.mono,
                    modifier = Modifier.fillMaxWidth().minimumInteractiveComponentSize()
                        .clickable(enabled = !vm.sharePreparing) { vm.requestExit() }
                        .padding(vertical = 8.dp),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center)
            }

            // ---- REVIEW: attest, set policy, see exactly what leaves, export the window ----------
            CapturePhase.REVIEW -> {
                // Gate on the FROZEN ARTIFACT's row count, not a second interpretation of its
                // membership map. Stop now produces both atomically, and the CSV remains the
                // user-visible/exported source of truth for how many rows were captured.
                val emptyWindow = vm.frozenRowCount == 0
                if (emptyWindow) {
                    // The honest zero-result read, worded so silence is a finding, not a failure.
                    Column(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(Acab.radiusSm))
                            .background(Acab.bg2).border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
                            .padding(14.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Text("NOTHING HEARD", color = Acab.faint, fontSize = 11.sp,
                            fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 0.5.sp)
                        Text(
                            "Nothing was heard in this window. That means no compatible broadcast was " +
                                "recognized while you captured - it doesn't prove nothing is there. Try " +
                                "capturing closer to the device, or for longer.",
                            color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono,
                        )
                    }
                    // Primary action: try again. Nothing was captured, so no discard confirmation.
                    OutlinedButton(
                        onClick = {
                            if (vm.sharePreparing) return@OutlinedButton
                            vm.capturedAtById = emptyMap()
                            vm.frozenCsv = null
                            vm.startMs = ble.beginContributionCapture(); vm.nowMs = vm.startMs
                            vm.phase = CapturePhase.CAPTURING
                        },
                        enabled = !vm.sharePreparing,
                        modifier = Modifier.fillMaxWidth(),
                        border = BorderStroke(1.dp, Acab.accent),
                        colors = ButtonDefaults.outlinedButtonColors(
                            containerColor = Acab.accent, contentColor = Acab.onAccent),
                        shape = RoundedCornerShape(Acab.radiusSm),
                    ) { Text("START A NEW CAPTURE", fontFamily = Acab.mono, fontWeight = FontWeight.Bold, fontSize = 13.sp) }
                } else {
                    Text("Captured $liveCount observation${if (liveCount == 1) "" else "s"} over ${elapsed(vm.startMs, vm.stopMs)} " +
                        "(${clockTime(vm.startMs)} to ${clockTime(vm.stopMs)}).",
                        color = Acab.text, fontSize = 13.sp, fontFamily = Acab.mono)
                }

                Text("WHAT DID YOU SEE?", color = Acab.faint, fontSize = 11.sp,
                    fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 0.5.sp)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    kinds.forEach { k ->
                        val on = vm.kind == k
                        Row(
                            Modifier
                                .minimumInteractiveComponentSize()
                                .clip(RoundedCornerShape(Acab.radiusSm))
                                .background(if (on) Acab.bg3 else Acab.bg2)
                                .border(1.dp, if (on) Acab.accent else Acab.line, RoundedCornerShape(Acab.radiusSm))
                                .clickable(enabled = !vm.sharePreparing) {
                                    if (!vm.sharePreparing) vm.kind = if (on) null else k
                                }
                                .semantics { selected = on }
                                .padding(horizontal = 12.dp, vertical = 8.dp),
                        ) {
                            Text(k, color = if (on) Acab.text else Acab.dim, fontSize = 12.sp,
                                fontFamily = Acab.mono, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal)
                        }
                    }
                }

                OutlinedTextField(
                    value = vm.makerModel,
                    onValueChange = { if (!vm.sharePreparing) vm.makerModel = it },
                    label = { Text("Manufacturer / model (optional)") },
                    singleLine = true, enabled = !vm.sharePreparing,
                    modifier = Modifier.fillMaxWidth(),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Acab.accent, unfocusedBorderColor = Acab.line,
                        focusedTextColor = Acab.text, unfocusedTextColor = Acab.text,
                        focusedLabelColor = Acab.dim, unfocusedLabelColor = Acab.faint,
                        cursorColor = Acab.accent,
                    ),
                )
                val photoUri = vm.photo
                if (photoUri == null) {
                    OutlinedButton(
                        onClick = {
                            if (!vm.sharePreparing) pickPhoto.launch(
                                androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        },
                        enabled = !vm.sharePreparing,
                        modifier = Modifier.fillMaxWidth(),
                        border = BorderStroke(1.dp, Acab.line),
                        colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.dim),
                        shape = RoundedCornerShape(Acab.radiusSm),
                    ) {
                        Icon(Icons.Filled.Image,
                            contentDescription = null, modifier = Modifier.padding(end = 8.dp))
                        Text("Attach a photo (optional)", fontFamily = Acab.mono, fontSize = 12.sp)
                    }
                } else {
                    // The actual picked image, so review shows what will really be attached, with
                    // explicit Replace / Remove instead of a mystery "tap to change".
                    PhotoAttachmentRow(
                        uri = photoUri,
                        enabled = !vm.sharePreparing,
                        onReplace = {
                            if (!vm.sharePreparing) pickPhoto.launch(
                                androidx.activity.result.PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                        },
                        onRemove = { if (!vm.sharePreparing) vm.photo = null },
                    )
                }

                SwitchRow("Include where I made this observation", vm.includeObserverLocation,
                    "Off by default. Your phone's location is removed from the export.",
                    enabled = !vm.sharePreparing) {
                        if (!vm.sharePreparing) vm.includeObserverLocation = it
                    }
                SwitchRow("Include drone aircraft locations", vm.includeDroneLocation,
                    "Only affects drone rows. The aircraft position from its Remote ID broadcast, not your phone.",
                    enabled = !vm.sharePreparing) {
                        if (!vm.sharePreparing) vm.includeDroneLocation = it
                    }
                SwitchRow("Include drone operator locations", vm.includeOperatorLocation,
                    "The operator position from the same broadcast. Off by default because it can reveal a person's location.",
                    enabled = !vm.sharePreparing) {
                        if (!vm.sharePreparing) vm.includeOperatorLocation = it
                    }

                // DYNAMIC disclosure: states the actual result of the window + switches. The
                // count is the frozen CSV's row count (liveCount in REVIEW), so this card can
                // never claim rows the export no longer carries. Sentence-for-sentence
                // canonical with iOS: the contents list, the three location lines, the photo
                // line, and the two-sentence closing are byte-identical on both platforms;
                // only the trailing platform-mechanics sentence may differ.
                Column(
                    Modifier.fillMaxWidth().clip(RoundedCornerShape(Acab.radiusSm))
                        .background(Acab.bg2).border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm)).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text("WHAT THIS EXPORT CONTAINS", color = Acab.faint, fontSize = 11.sp,
                        fontWeight = FontWeight.Bold, fontFamily = Acab.mono, letterSpacing = 0.5.sp)
                    Text(
                        "$liveCount observation${if (liveCount == 1) "" else "s"} from ${clockTime(vm.startMs)} to ${clockTime(vm.stopMs)}, " +
                            "as CSV: MAC addresses, device type and maker, signal strength, timestamps, " +
                            "match evidence and confidence, sighting counts, company and UAS identifiers, " +
                            "drone telemetry (altitude, speed, heading, height above ground), and Remote ID status.\n" +
                            (if (vm.includeObserverLocation) "Your location: INCLUDED.\n" else "Your location: removed.\n") +
                            "Drone aircraft coordinates: ${if (vm.includeDroneLocation) "included" else "removed"}.\n" +
                            "Drone operator position: ${if (vm.includeOperatorLocation) "included" else "removed"}.\n" +
                            (if (vm.photo != null) "Photo location metadata removed automatically.\n" else "") +
                            "\nNothing is shared automatically. Diagnostic captures may contain identifiers " +
                            "from nearby devices. Review and export only what you choose.",
                        color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono,
                    )
                }

                OutlinedButton(
                    onClick = { shareContribution(context, vm) },
                    enabled = !vm.sharePreparing,
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, if (emptyWindow) Acab.line else Acab.accent),
                    colors = ButtonDefaults.outlinedButtonColors(
                        contentColor = if (emptyWindow) Acab.dim else Acab.text),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) {
                    if (vm.sharePreparing) {
                        CircularProgressIndicator(color = Acab.dim, strokeWidth = 2.dp,
                            modifier = Modifier.size(14.dp).padding(end = 0.dp))
                        Spacer(Modifier.padding(horizontal = 4.dp))
                        Text("PREPARING…", fontFamily = Acab.mono, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    } else {
                        Text("REVIEW & SHARE", fontFamily = Acab.mono, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                    }
                }

                OutlinedButton(
                    onClick = {
                        if (!vm.sharePreparing) saveCopy.launch("beacons-observation.csv")
                    },
                    enabled = !vm.sharePreparing,
                    modifier = Modifier.fillMaxWidth(),
                    border = BorderStroke(1.dp, Acab.line),
                    colors = ButtonDefaults.outlinedButtonColors(contentColor = Acab.dim),
                    shape = RoundedCornerShape(Acab.radiusSm),
                ) { Text("SAVE CSV COPY", fontFamily = Acab.mono, fontSize = 13.sp) }

                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    Text("Start over", color = Acab.faint, fontSize = 12.sp, fontFamily = Acab.mono,
                        modifier = Modifier.minimumInteractiveComponentSize()
                            .clickable(enabled = !vm.sharePreparing) {
                                if (!vm.sharePreparing) {
                                    // An empty window has nothing to lose; a real capture confirms first.
                                    if (emptyWindow) {
                                        vm.capturedAtById = emptyMap(); vm.frozenCsv = null
                                        vm.phase = CapturePhase.IDLE
                                    } else vm.requestRestart()
                                }
                            }
                            .padding(vertical = 8.dp))
                    Text("Discard", color = Acab.faint, fontSize = 12.sp, fontFamily = Acab.mono,
                        modifier = Modifier.minimumInteractiveComponentSize()
                            .clickable(enabled = !vm.sharePreparing) { vm.requestExit() }
                            .padding(vertical = 8.dp))
                }
            }
        }
    }

    // One confirmation for every way out of a live capture (back press, Discard, Start over):
    // a field capture cannot be re-taken from the couch, so it is never dropped silently.
    if (vm.confirmDiscard != null) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { vm.dismissDiscard() },
            containerColor = Acab.bg2,
            titleContentColor = Acab.text,
            title = { Text("Discard this capture?", fontSize = 16.sp, fontWeight = FontWeight.SemiBold) },
            text = {
                Text("The captured window and its details will be lost. This can't be undone.",
                    color = Acab.dim, fontSize = 14.sp)
            },
            confirmButton = {
                Text("DISCARD", color = Acab.accent, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                    modifier = Modifier.minimumInteractiveComponentSize()
                        .clickable(enabled = !vm.sharePreparing) {
                            ble.cancelContributionCapture()
                            vm.confirmDiscardNow()
                        }
                        .padding(8.dp))
            },
            dismissButton = {
                Text("KEEP CAPTURE", color = Acab.dim, fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    letterSpacing = 0.5.sp, fontFamily = Acab.mono,
                    modifier = Modifier.minimumInteractiveComponentSize()
                        .clickable(enabled = !vm.sharePreparing) { vm.dismissDiscard() }
                        .padding(8.dp))
            },
        )
    }
}

/** "M:SS" elapsed between two wall-clock millis. */
private fun elapsed(fromMs: Long, toMs: Long): String {
    val s = ((toMs - fromMs).coerceAtLeast(0)) / 1000
    return "%d:%02d".format(s / 60, s % 60)
}

/** Local clock time like "2:14 PM". */
private fun clockTime(ms: Long): String =
    java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault()).format(java.util.Date(ms))

/** The picked photo as a real thumbnail with explicit Replace / Remove actions (48dp targets).
 *  Decoded downsampled on IO so a 50MP camera roll image never stalls the main thread. */
@Composable
private fun PhotoAttachmentRow(
    uri: Uri,
    enabled: Boolean,
    onReplace: () -> Unit,
    onRemove: () -> Unit,
) {
    val context = LocalContext.current
    val bmp by produceState<Bitmap?>(initialValue = null, key1 = uri) {
        value = withContext(Dispatchers.IO) { decodeScaled(context, uri, 384) }
    }
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(Acab.radiusSm))
            .background(Acab.bg2).border(1.dp, Acab.line, RoundedCornerShape(Acab.radiusSm))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier.size(64.dp).clip(RoundedCornerShape(8.dp)).background(Acab.bg3),
            contentAlignment = Alignment.Center,
        ) {
            val b = bmp
            if (b != null) {
                Image(bitmap = b.asImageBitmap(), contentDescription = "Attached photo",
                    contentScale = ContentScale.Crop, modifier = Modifier.size(64.dp))
            } else {
                Icon(Icons.Filled.Image, contentDescription = "Attached photo",
                    tint = Acab.faint, modifier = Modifier.size(22.dp))
            }
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("Photo attached", color = Acab.text, fontSize = 13.sp, fontFamily = Acab.mono)
            Text("location metadata removed on export", color = Acab.faint, fontSize = 10.sp, fontFamily = Acab.mono)
        }
        Text("Replace", color = Acab.dim, fontSize = 12.sp, fontFamily = Acab.mono,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.minimumInteractiveComponentSize()
                .clickable(enabled = enabled, onClick = onReplace).padding(4.dp))
        Text("Remove", color = Acab.accent, fontSize = 12.sp, fontFamily = Acab.mono,
            fontWeight = FontWeight.Bold,
            modifier = Modifier.minimumInteractiveComponentSize()
                .clickable(enabled = enabled, onClick = onRemove).padding(4.dp))
    }
}

/** Bounded decode of a content Uri: bounds pass first, then inSampleSize, so even a huge source
 *  has a predictable allocation. Null when the image can't be read or allocated. */
private fun decodeScaled(context: android.content.Context, src: Uri, maxDim: Int): Bitmap? {
    var decoded: Bitmap? = null
    return try {
        val resolver = context.contentResolver
        // EXIF is optional (PNG/WebP/HEIF providers can expose none). A parser failure means
        // normal orientation, not a rejected photo; the bounded BitmapFactory decode is the
        // actual validity check.
        val orientation = runCatching {
            resolver.openInputStream(src)?.use { input ->
                ExifInterface(input).getAttributeInt(
                    ExifInterface.TAG_ORIENTATION,
                    ExifInterface.ORIENTATION_NORMAL,
                )
            }
        }.getOrNull() ?: ExifInterface.ORIENTATION_NORMAL
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(src)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        val longest = maxOf(bounds.outWidth.toLong(), bounds.outHeight.toLong())
        while (longest / sample > maxDim.toLong() && sample <= Int.MAX_VALUE / 2) sample *= 2
        decoded = resolver.openInputStream(src)?.use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply {
                inSampleSize = sample
                inPreferredConfig = Bitmap.Config.ARGB_8888
            })
        } ?: return null
        val source = decoded ?: return null
        val matrix = android.graphics.Matrix()
        when (orientation) {
            ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.setScale(-1f, 1f)
            ExifInterface.ORIENTATION_ROTATE_180 -> matrix.setRotate(180f)
            ExifInterface.ORIENTATION_FLIP_VERTICAL -> {
                matrix.setRotate(180f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_TRANSPOSE -> {
                matrix.setRotate(90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_90 -> matrix.setRotate(90f)
            ExifInterface.ORIENTATION_TRANSVERSE -> {
                matrix.setRotate(-90f); matrix.postScale(-1f, 1f)
            }
            ExifInterface.ORIENTATION_ROTATE_270 -> matrix.setRotate(-90f)
            else -> {
                decoded = null
                return source
            }
        }
        Bitmap.createBitmap(source, 0, 0, source.width, source.height, matrix, true).also {
            if (it !== source) source.recycle()
            decoded = null
        }
    } catch (_: OutOfMemoryError) {
        decoded?.recycle()
        null
    } catch (_: Exception) {
        decoded?.recycle()
        null
    }
}

/** Build the REDACTED contribution CSV + note (+ EXIF-stripped photo) and hand it to the share
 *  sheet, pre-addressed to logs@soyboi.tech. Never sends on its own; the user still picks the
 *  target and confirms.
 *
 *  The note's attachment manifest is derived from the FINALIZED artifacts: the row count is read
 *  off the actual CSV text and the photo clause appears only when the strip really produced a
 *  file, so the manifest can never disagree with what is attached.
 *
 *  Deliberately does NOT close the composer: it stays OPEN beneath the chooser, so cancelling
 *  the share or abandoning an email draft leaves the user's form intact to retry. They leave via
 *  Discard or the back button. */
private fun shareContribution(
    context: android.content.Context,
    vm: ContributionViewModel,
) {
    // No AcabBleManager parameter ON PURPOSE: the share path redacts the frozen-at-Stop CSV and
    // must never be handed a live-store handle a future edit could quietly re-read.
    // Lock + snapshot happen synchronously, before a coroutine exists. The form cannot mutate
    // while the immutable request is being rendered, and no background code reads Compose state.
    val spec = vm.beginExport() ?: return
    val appContext = context.applicationContext
    vm.viewModelScope.launch {
        try {
            val send = withContext(Dispatchers.IO) {
                prepareContributionShare(appContext, spec)
            }
            // Do not retain or launch from the Activity captured before IO. The currently
            // composed ContributeContent consumes this prepared event after rotation, if any.
            vm.publishPreparedShare(send)
        } catch (e: Exception) {
            vm.finishExport("Couldn't build the export: ${e.message ?: "write failed"}")
        }
    }
}

/** Render one immutable share package in a never-reused UUID directory. A receiving app may read
 *  a granted content URI long after the chooser opens (for example, an email draft); unique files
 *  ensure a later, differently-redacted export cannot replace those bytes underneath it. */
private fun prepareContributionShare(
    context: android.content.Context,
    spec: ContributionExportSpec,
): Intent {
    val dir = createExportPackage(context.cacheDir, "contribution-shares")
    try {
        val csvText = redactCsvColumns(spec.frozenCsv, contributionBlankColumns(
            spec.includeObserverLocation, spec.includeDroneLocation,
            spec.includeOperatorLocation))
        val csv = File(dir, "beacons-observation.csv")
        csv.writeText(csvText, Charsets.UTF_8)
        val csvUri = FileProvider.getUriForFile(
            context, "${context.packageName}.fileprovider", csv)

        // A photo the user reviewed is all-or-nothing. Falling through to a CSV-only chooser
        // would silently change the attachment manifest; abort instead so they can replace or
        // remove the image deliberately. Save CSV Copy remains the explicit CSV-only path.
        val photoFile = spec.photo?.let { src ->
            strippedPhoto(context, src, File(dir, "beacons-observation.jpg"))
                ?: throw java.io.IOException(
                    "couldn't process the selected photo; remove or replace it and try again")
        }
        val photoUri = photoFile?.let {
            FileProvider.getUriForFile(context, "${context.packageName}.fileprovider", it)
        }

        // Logical-record count from the FINALIZED CSV, never from mutable UI state. The parser
        // treats a newline inside a quoted field as part of one row rather than a second row.
        val rowCount = contributionCsvDataRowCount(csvText)
        val note = buildString {
            append("beacons field observation\n\n")
            append("Visually observed: ").append(spec.kind ?: "(not specified)").append('\n')
            if (spec.makerModel.isNotBlank()) {
                append("Manufacturer / model: ").append(spec.makerModel.trim()).append('\n')
            }
            append("Captured ").append(rowCount)
                .append(if (rowCount == 1) " observation " else " observations ")
            append("from ").append(clockTime(spec.startMs)).append(" to ")
                .append(clockTime(spec.stopMs)).append(".\n")
            append("\nAttached: capture window (CSV, your location ")
            append(if (spec.includeObserverLocation) "included" else "removed")
            append("; drone aircraft coords ")
                .append(if (spec.includeDroneLocation) "included" else "removed")
            append("; operator coords ")
                .append(if (spec.includeOperatorLocation) "included" else "removed").append(')')
            if (photoUri != null) append(" + photo (location metadata removed)")
            append(".\nSend to: logs@soyboi.tech\n\n")
            append("This capture may contain identifiers from nearby devices. ")
            append("Shared voluntarily for signature research.")
        }

        val send = Intent(
            if (photoUri != null) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND,
        ).apply {
            type = if (photoUri != null) "*/*" else "text/csv"
            putExtra(Intent.EXTRA_EMAIL, arrayOf("logs@soyboi.tech"))
            putExtra(Intent.EXTRA_SUBJECT,
                "beacons field observation" + (spec.kind?.let { " - $it" } ?: ""))
            putExtra(Intent.EXTRA_TEXT, note)
            if (photoUri != null) {
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, arrayListOf(csvUri, photoUri))
            } else {
                putExtra(Intent.EXTRA_STREAM, csvUri)
            }
            // ClipData makes the read grant apply reliably to every URI on Android versions and
            // target apps that inspect grants there rather than walking EXTRA_STREAM.
            clipData = ClipData.newUri(context.contentResolver, "observation CSV", csvUri).apply {
                if (photoUri != null) addItem(ClipData.Item(photoUri))
            }
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        return send
    } catch (e: Exception) {
        // No URI escaped if preparation failed, so this partial package is safe to remove.
        runCatching { dir.deleteRecursively() }
        throw e
    }
}

/** Decode a bounded, orientation-correct bitmap and re-encode it to a new JPEG. The new file has
 *  no source EXIF segment (including GPS/date/device); orientation is baked into pixels. A false
 *  Bitmap.compress result or an empty file is failure, never a valid attachment. */
private fun strippedPhoto(
    context: android.content.Context,
    src: Uri,
    out: File,
): File? {
    var bmp: Bitmap? = null
    return try {
        bmp = decodeScaled(context, src, 2560) ?: return null
        out.parentFile?.let { parent ->
            if ((!parent.exists() && !parent.mkdirs()) || !parent.isDirectory) return null
        }
        val compressed = java.io.FileOutputStream(out).use { stream ->
            bmp.compress(Bitmap.CompressFormat.JPEG, 90, stream).also { stream.flush() }
        }
        if (!compressed || out.length() == 0L) {
            out.delete()
            null
        } else out
    } catch (_: OutOfMemoryError) {
        out.delete()
        null
    } catch (_: Exception) {
        out.delete()
        null
    } finally {
        bmp?.recycle()
    }
}

@Composable
private fun SwitchRow(
    label: String,
    checked: Boolean,
    hint: String,
    enabled: Boolean = true,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().minimumInteractiveComponentSize()
            .toggleable(
                value = checked,
                enabled = enabled,
                role = Role.Switch,
                onValueChange = onChange,
            )
            .semantics(mergeDescendants = true) {},
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(label, color = Acab.text, fontSize = 13.sp, fontFamily = Acab.mono)
            Text(hint, color = Acab.faint, fontSize = 11.sp, fontFamily = Acab.mono)
        }
        Spacer(Modifier.padding(horizontal = 6.dp))
        Switch(checked = checked, enabled = enabled, onCheckedChange = null,
            colors = SwitchDefaults.colors(checkedTrackColor = Acab.accent, checkedThumbColor = Acab.text))
    }
}
