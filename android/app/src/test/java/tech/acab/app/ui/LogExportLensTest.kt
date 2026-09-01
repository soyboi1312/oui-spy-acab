package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.ble.DetectionExportRowSnapshot
import tech.acab.app.ble.DetectionExportSnapshot
import tech.acab.app.ble.frozenNewIdSet
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis

class LogExportLensTest {
    private fun row(mac: String, type: DeviceType, offline: Boolean = false) = Detection(
        type = type,
        source = 0,
        method = 0,
        confidence = 1,
        mac = mac,
        rssi = -50,
        name = null,
        rid = null,
        detail = null,
        lat = null,
        lon = null,
        pilotLat = null,
        pilotLon = null,
        altitude = null,
        speedH = null,
        speedV = null,
        heading = null,
        heightAGL = null,
        pilotAlt = null,
        ridStatus = null,
        count = 1,
        isNew = true,
        gpsAgeSec = null,
        hist = offline,
        seq = 0L,
        at = 0L,
        approx = false,
        offline = offline,
    )

    @Test
    fun categoryAndScopeApplyToTheSuppliedLiveOrPausedFeed() {
        val alpr = row("a", DeviceType.FLOCK_CAMERA)
        val trackerOffline = row("b", DeviceType.TRACKER, offline = true)
        val trackerLive = row("c", DeviceType.TRACKER)
        val laterLive = row("d", DeviceType.TRACKER)
        val live = listOf(laterLive, trackerLive, trackerOffline, alpr)

        assertEquals(
            listOf(trackerOffline),
            filterLogRows(live, "TRACKER", LogScope.New, setOf(trackerOffline.id)),
        )
        assertEquals(
            listOf(trackerOffline),
            filterLogRows(live, "TRACKER", LogScope.Offline, emptySet()),
        )

        // A paused export supplies its frozen feed; a later live row is not available for the
        // lens to accidentally re-read or add.
        val paused = live.drop(1)
        assertEquals(
            listOf(trackerLive, trackerOffline),
            filterLogRows(paused, "TRACKER", LogScope.All, emptySet()),
        )
    }

    @Test
    fun pausedExportKeepsSideMetadataAfterTheLiveStoreDropsItsRows() {
        val kept = row("kept", DeviceType.TRACKER)
        val filteredOut = row("other", DeviceType.FLOCK_CAMERA)
        val keptAt = 1_700_000_123_456L
        val frozen = DetectionExportSnapshot(listOf(
            DetectionExportRowSnapshot(
                kept, firstSeenMs = keptAt,
                timeBasis = TimeBasis.Reconstructed(keptAt, 9),
                observerCoord = 32.7 to -117.1,
            ),
            DetectionExportRowSnapshot(
                filteredOut, firstSeenMs = keptAt + 1_000L,
                timeBasis = TimeBasis.Exact,
                observerCoord = 40.0 to -73.0,
            ),
        ))
        val vm = LogViewModel()
        vm.pause(frozen)

        // No live store is modelled here, and none can be: exportSnapshot reads only the frozen
        // field and the rows it is handed, so what the manager holds is irrelevant BY
        // CONSTRUCTION. That is the property under test - the paused export lenses its own
        // immutable snapshot and therefore keeps the original evidence metadata. (A local list
        // built and cleared here used to stand in for the eviction; it was read by nothing, and
        // reading like coverage is worse than having none.)
        val exported = vm.exportSnapshot(listOf(kept))!!

        assertEquals(listOf(kept), exported.rows.map { it.detection })
        assertEquals(keptAt, exported.rows.single().firstSeenMs)
        assertEquals(TimeBasis.Reconstructed(keptAt, 9), exported.rows.single().timeBasis)
        assertEquals(32.7 to -117.1, exported.rows.single().observerCoord)

        // NEW membership must come from the frozen firstSeenMs, which is what makes it survive an
        // eviction: the live sibling (AcabBleManager.newIdSet) reads firstSeenAt, and a missing
        // entry there turns an evicted row into NEW. frozenNewIdSet is called directly, with no
        // manager involved, so what this pins is that the frozen path never consults one.
        assertEquals(emptySet<String>(), frozenNewIdSet(
            exported.rows, seenWatermark = keptAt + 10_000L,
            approxWatermark = AcabBleManager.HIST_PSEUDO_BASE))
    }
}
