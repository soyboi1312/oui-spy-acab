package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType

class ContributionCaptureObserverTest {
    private fun row(id: String, rssi: Int = -50, replay: Boolean = false) = Detection(
        type = DeviceType.NEARBY_DEVICE,
        source = 0,
        method = 0,
        confidence = 1,
        mac = id,
        rssi = rssi,
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
        hist = replay,
        seq = 0L,
        at = 0L,
        approx = false,
        offline = replay,
    )

    @Test
    fun latestInWindowSampleWinsAndExplicitNullSuppressesFallback() {
        val capture = ContributionCaptureLedger()
        capture.begin(100L)
        capture.record(row("a", -70), 99L, 1.0 to 2.0)
        capture.record(row("a", -60), 100L, 3.0 to 4.0)
        capture.record(row("a", -40), 150L, null)
        capture.record(row("b"), 160L, 5.0 to 6.0)
        capture.record(row("history", replay = true), 170L, 9.0 to 10.0)
        capture.record(row("late"), 201L, 7.0 to 8.0)

        val frozen = capture.finish(100L, 200L).associateBy { it.detection.mac }

        assertEquals(setOf("a", "b"), frozen.keys)
        assertNull(frozen["a"]?.observer)
        assertEquals(-40, frozen["a"]?.detection?.rssi)
        assertEquals(5.0 to 6.0, frozen["b"]?.observer)
        capture.record(row("b"), 170L, 7.0 to 8.0)
        assertEquals(emptyList<CapturedLiveSighting>(), capture.finish(100L, 200L))
    }

    @Test
    fun cancelDisarmsAndClearsAnInProgressCapture() {
        val capture = ContributionCaptureLedger()
        capture.begin(100L)
        capture.record(row("before-cancel"), 120L, 1.0 to 2.0)

        capture.cancel()
        capture.record(row("after-cancel"), 130L, 3.0 to 4.0)

        assertEquals(0, capture.count(100L, 200L))
        assertEquals(emptyList<CapturedLiveSighting>(), capture.finish(100L, 200L))
    }

    @Test
    fun everyCsvCellUsesTheSharedEncoder() {
        val encoded = detectionCsvRow(listOf(
            "plain", "external,company", "lone\rcarriage", "line\nfeed", "a\"b", "42",
        ))
        assertEquals(
            "plain,\"external,company\",\"lone\rcarriage\",\"line\nfeed\",\"a\"\"b\",42",
            encoded,
        )
        assertFalse(encoded.contains("external,company,lone"))

        // The same production row builder remains rectangular through document parsing and
        // redaction when an external string contains a comma plus a CR/LF record-looking value.
        val document = detectionCsvRow(listOf("type", "approx_lat", "approx_lon", "maker")) +
            "\r\n" + detectionCsvRow(listOf("external,type", "1.0", "2.0", "maker\r\nmodel"))
        val redacted = redactCsvColumns(document, setOf("approx_lat", "approx_lon"))
        assertEquals(
            "type,approx_lat,approx_lon,maker\r\n\"external,type\",,,\"maker\r\nmodel\"",
            redacted,
        )
        assertEquals(1, contributionCsvDataRowCount(redacted))
    }
}
