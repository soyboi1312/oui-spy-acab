package tech.acab.app.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import tech.acab.app.ble.contributionCsvDataRowCount

/** The contribution composer's flow position. Lives here (not in the screen) so it means the
 *  same thing everywhere the ViewModel is read. */
enum class CapturePhase { IDLE, CAPTURING, REVIEW }

/** What a confirmed "Discard this capture?" does: close the composer, or return to IDLE for a
 *  fresh capture (the Start-over path keeps the composer open). */
enum class DiscardTarget { CLOSE, RESTART }

/** Everything an export is allowed to read, captured atomically on the main thread before IO.
 *  Keeping this immutable prevents a toggle, attestation edit, Back, or Discard action from
 *  changing either the bytes or the note while an attachment is being prepared. */
data class ContributionExportSpec(
    val frozenCsv: String,
    val kind: String?,
    val makerModel: String,
    val photo: Uri?,
    val includeObserverLocation: Boolean,
    val includeDroneLocation: Boolean,
    val includeOperatorLocation: Boolean,
    val startMs: Long,
    val stopMs: Long,
)

data class PendingContributionShare(val id: Long, val intent: Intent)

/**
 * Activity-scoped home for the contribution composer's state. It used to live in `remember`s
 * inside the Device tab, which meant a tab switch, a back press, a resize crossing the two-pane
 * breakpoint, or any activity recreation silently threw away a capture the user was mid-way
 * through walking - the worst possible loss, because a field capture cannot be re-taken from the
 * couch. A ViewModel survives all of those; only finishing or discarding clears it.
 *
 * The capture window itself is wall-clock based (startMs), so time spent on another tab still
 * counts toward the window - leaving the Device tab mid-capture no longer truncates anything.
 */
class ContributionViewModel : ViewModel() {
    /** Composer visibility. In the ViewModel so a mid-capture tab switch lands back INSIDE the
     *  composer rather than on the Device list with the capture invisibly still running. */
    var open by mutableStateOf(false)

    var phase by mutableStateOf(CapturePhase.IDLE)
    var startMs by mutableLongStateOf(0L)
    var stopMs by mutableLongStateOf(0L)
    var nowMs by mutableLongStateOf(0L)

    /** Frozen exactly once at Stop: membership plus each device's last in-window sighting.
     *  The windowing input for [frozenCsv]; kept for the empty-window check and Start-over. */
    var capturedAtById by mutableStateOf<Map<String, Long>>(emptyMap())

    /** The capture CONTENT, frozen at Stop: the full UNREDACTED windowed CSV, rendered once
     *  from the live store the moment Stop is tapped. THE invariant: nothing after Stop reads
     *  the mutable store again. Rows evicted between Stop and Share (ignore, clear-log, the
     *  store cap) used to silently vanish from the export while the REVIEW count and the
     *  disclosure still claimed the frozen membership size - the user shared a file that was
     *  not the one they reviewed. Now REVIEW's count and the disclosure derive from THIS
     *  string, and share / save-a-copy apply redactCsvColumns over it - pure text ops.
     *  Unredacted on purpose: the location switches stay live in REVIEW, so redaction must be
     *  applied per-export, not baked in at Stop. Never persisted; dies with the capture. */
    var frozenCsv by mutableStateOf<String?>(null)

    /** Logical CSV records in the frozen capture. Document-aware parsing matters because a quoted
     *  field may legally contain a newline; physical-line counting would overstate the export. */
    val frozenRowCount: Int
        get() = frozenCsv?.let(::contributionCsvDataRowCount) ?: 0

    var kind by mutableStateOf<String?>(null)
    var makerModel by mutableStateOf("")
    var photo by mutableStateOf<Uri?>(null)

    // Location policy. Observer position (the CONTRIBUTOR's phone) is OUT by default. A drone's
    // Remote ID broadcast splits in two: the AIRCRAFT position is kept by default (it describes
    // the drone, not a person), the OPERATOR position is out by default (it can reveal where a
    // person is standing). See ContributionCsv for the column-name doctrine.
    var includeObserverLocation by mutableStateOf(false)
    var includeDroneLocation by mutableStateOf(true)
    var includeOperatorLocation by mutableStateOf(false)

    /** Non-null while a "Discard this capture?" confirmation is up; names what a confirm does. */
    var confirmDiscard by mutableStateOf<DiscardTarget?>(null)

    /** True while the share/save export is being built on IO; drives the visible preparing state. */
    var sharePreparing by mutableStateOf(false)

    /** One-shot failure message from the last export attempt; the screen shows and clears it. */
    var shareError by mutableStateOf<String?>(null)

    /** Prepared off the Activity lifecycle, then consumed exactly once by the currently mounted
     *  ContributeContent. This closes the rotate-during-photo-processing Activity race. */
    var pendingShare by mutableStateOf<PendingContributionShare?>(null)
        private set
    private var nextShareId = 0L

    /** Leaving the flow. With a capture in flight (Capturing or Review) this only ARMS the
     *  confirmation; an idle composer just closes. */
    fun requestExit() {
        if (sharePreparing) return
        if (phase == CapturePhase.IDLE) close() else confirmDiscard = DiscardTarget.CLOSE
    }

    /** Start-over from Review/Capturing: same confirmation, but a confirm returns to IDLE. */
    fun requestRestart() {
        if (sharePreparing) return
        confirmDiscard = DiscardTarget.RESTART
    }

    /** The confirmation's Discard action. */
    fun confirmDiscardNow() {
        if (sharePreparing) return
        when (confirmDiscard) {
            DiscardTarget.CLOSE -> close()
            DiscardTarget.RESTART -> {
                // Keep kind/maker/photo/switches: start-over re-captures the window, it does not
                // make the user re-type their attestation.
                capturedAtById = emptyMap()
                frozenCsv = null
                phase = CapturePhase.IDLE
            }
            null -> Unit
        }
        confirmDiscard = null
    }

    fun dismissDiscard() {
        if (!sharePreparing) confirmDiscard = null
    }

    /** Lock the review form and return its one immutable export request. Must be called before a
     *  coroutine is launched so there is no frame in which IO has started but the form is still
     *  interactive. null means another build is running or there is no stopped capture. */
    fun beginExport(): ContributionExportSpec? {
        if (sharePreparing || phase != CapturePhase.REVIEW) return null
        val csv = frozenCsv ?: return null
        sharePreparing = true
        shareError = null
        return ContributionExportSpec(
            frozenCsv = csv,
            kind = kind,
            makerModel = makerModel,
            photo = photo,
            includeObserverLocation = includeObserverLocation,
            includeDroneLocation = includeDroneLocation,
            includeOperatorLocation = includeOperatorLocation,
            startMs = startMs,
            stopMs = stopMs,
        )
    }

    /** End a build on the main thread and optionally surface its user-readable failure. */
    fun finishExport(error: String? = null) {
        if (error != null) shareError = error
        sharePreparing = false
    }

    fun publishPreparedShare(intent: Intent) {
        pendingShare = PendingContributionShare(++nextShareId, intent)
        sharePreparing = false
    }

    fun consumePreparedShare(id: Long): Intent? {
        val pending = pendingShare?.takeIf { it.id == id } ?: return null
        pendingShare = null
        return pending.intent
    }

    /** Full reset + close. Only called from requestExit (idle) or a confirmed discard. */
    private fun close() {
        open = false
        phase = CapturePhase.IDLE
        startMs = 0L; stopMs = 0L; nowMs = 0L
        capturedAtById = emptyMap()
        frozenCsv = null
        kind = null
        makerModel = ""
        photo = null
        includeObserverLocation = false
        includeDroneLocation = true
        includeOperatorLocation = false
        confirmDiscard = null
        sharePreparing = false
        shareError = null
        pendingShare = null
    }
}
