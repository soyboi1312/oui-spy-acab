package tech.acab.app.ble

/**
 * One capture-local, live-only ledger. Each ID's latest row, phone-clock instant and optional
 * observer fix are replaced together. A null observer means the row was heard in-window without
 * a fresh phone fix, so export must not fall back to a session-global or drone coordinate.
 * Guarded by AcabBleManager.storeLock in production.
 */
internal data class CapturedLiveSighting(
    val detection: tech.acab.app.model.Detection,
    val observedAtMs: Long,
    val observer: Pair<Double, Double>?,
)

internal class ContributionCaptureLedger {
    private var activeStartMs: Long? = null
    private val sightings = LinkedHashMap<String, CapturedLiveSighting>()

    fun begin(startMs: Long) {
        activeStartMs = startMs
        sightings.clear()
    }

    fun record(
        detection: tech.acab.app.model.Detection,
        observedAtMs: Long,
        observer: Pair<Double, Double>?,
    ) {
        if (detection.hist || detection.offline) return
        val start = activeStartMs ?: return
        if (observedAtMs >= start) {
            // Reinsert so iteration order reflects each ID's latest in-window sighting.
            sightings.remove(detection.id)
            sightings[detection.id] = CapturedLiveSighting(detection, observedAtMs, observer)
        }
    }

    fun count(startMs: Long, stopMs: Long): Int =
        if (activeStartMs == startMs) sightings.values.count { it.observedAtMs <= stopMs } else 0

    fun finish(startMs: Long, stopMs: Long): List<CapturedLiveSighting> {
        val matched = activeStartMs == startMs
        val result = if (matched) sightings.values.filter { it.observedAtMs <= stopMs } else emptyList()
        cancel()
        return result
    }

    fun cancel() {
        activeStartMs = null
        sightings.clear()
    }
}

/** All cells, including numbers and timestamps, pass through the same tested RFC 4180 encoder. */
internal fun detectionCsvRow(
    cells: List<String>,
    fieldEncoder: (String) -> String = ::csvField,
): String = cells.joinToString(",") { fieldEncoder(it) }
