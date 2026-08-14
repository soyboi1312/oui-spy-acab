package tech.acab.app.ui

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import tech.acab.app.ble.DetectionExportSnapshot
import tech.acab.app.model.Detection

/** The paused Log is a real frozen feed, not just a saved Boolean. Holding both pieces in the
 *  activity ViewModel preserves the exact rows across tab disposal and configuration recreation;
 *  a rotation must not silently re-freeze at a newer point and call that the same pause. */
class LogViewModel : ViewModel() {
    var paused by mutableStateOf(false)
        private set
    var frozen by mutableStateOf<List<Detection>>(emptyList())
        private set
    internal var frozenExport by mutableStateOf<DetectionExportSnapshot?>(null)
        private set

    /** Pause from one manager snapshot so displayed rows and their evictable side metadata are
     * indivisible. Holding only Detection objects let STORE_CAP eviction erase their timestamps
     * and observer fixes before a later paused export. */
    internal fun pause(snapshot: DetectionExportSnapshot) {
        frozenExport = snapshot
        frozen = snapshot.rows.map { it.detection }
        paused = true
    }

    /** Apply the current UI lens to the already-frozen metadata, preserving shown-row order. */
    internal fun exportSnapshot(rows: List<Detection>): DetectionExportSnapshot? {
        val snapshot = frozenExport ?: return null
        val byId = snapshot.rows.associateBy { it.detection.id }
        return DetectionExportSnapshot(rows.mapNotNull { byId[it.id] })
    }

    fun resume() {
        paused = false
        frozen = emptyList()
        frozenExport = null
    }
}
