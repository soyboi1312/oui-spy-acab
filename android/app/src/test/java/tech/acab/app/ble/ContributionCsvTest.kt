package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Location-redaction guarantees for a shared contribution CSV. The point under test is that a
 * contribution never leaks the CONTRIBUTOR'S phone position by accident, that the drone AIRCRAFT
 * and drone OPERATOR broadcast coordinates are controlled independently (the operator position
 * points at a person on the ground, the aircraft position does not), and that all three are
 * controlled by NAME, never by matching the text "lat"/"lon".
 */
class ContributionCsvTest {

    @Test fun spreadsheetText_neutralizesFormulaPrefixesAfterLeadingWhitespace() {
        for (value in listOf("=1+1", "+SUM(A:A)", "-2+3", "@HYPERLINK(\"x\")",
                "  =1+1", "\t@cmd")) {
            assertEquals(value, "'$value", spreadsheetSafeText(value))
        }
    }

    @Test fun spreadsheetText_preservesOrdinaryTextAndStructuralSerializer() {
        for (value in listOf("", "   ", "UAS123", "DJI", "1-2", "'already literal")) {
            assertEquals(value, value, spreadsheetSafeText(value))
        }
        assertEquals("\"'=1,2\"", csvField(spreadsheetSafeText("=1,2")))
        assertEquals("=1+1", csvField("=1+1"))
    }

    @Test fun productionExternalTextSelector_neutralizesBothExportedRadioTextCells() {
        val cells = detectionCsvExternalText("  =UAS", "@Maker")
        assertEquals("'  =UAS", cells.uasId)
        assertEquals("'@Maker", cells.maker)
        assertEquals(DetectionCsvExternalText("", ""), detectionCsvExternalText(null, null))
    }

    // The real column order (AcabBleManager.detectionsCsv header). approx_* at 10/11 are the phone;
    // drone_* at 14/15 and operator_* at 20/21 are the Remote ID broadcast.
    private val header =
        "detected_at,time_basis,time_precision_s,type,mac,rssi,source,matched_on,confidence,sightings," +
        "approx_lat,approx_lon,company_id,uas_id,drone_lat,drone_lon,altitude_m,speed_ms,heading_deg," +
        "height_agl_m,operator_lat,operator_lon,operator_alt_m,rid_status,maker"

    private val cols = header.split(",")
    private fun col(csv: String, row: Int, name: String): String {
        val records = requireNotNull(parseCsvDocument(csv))
        return records.records[row][cols.indexOf(name)]
    }

    // A drone row (has both phone and broadcast coords) and a non-drone row.
    private fun sample(): String {
        val drone = "2026-08-09T21:00:00Z,exact,,Drone,0c:9a:e6:00:00:01,-70,BLE,ODID,60,3," +
            "32.700000,-117.100000,0x0000,UAS123,32.712345,-117.156789,120,5,90,110," +
            "32.799999,-117.188888,0,airborne,DJI"
        val cam = "2026-08-09T21:01:00Z,exact,,Network camera,a4:11:62:00:00:02,-80,WiFi,OUI match,65,1," +
            "32.760000,-117.120000,,,,,,,,,,,,,Arlo"
        return "$header\n$drone\n$cam"
    }

    @Test fun observerLocationRemovedByDefault_blanksApproxOnEveryRow() {
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals("", col(redacted, 1, "approx_lat"))
        assertEquals("", col(redacted, 1, "approx_lon"))
        assertEquals("", col(redacted, 2, "approx_lat"))
        assertEquals("", col(redacted, 2, "approx_lon"))
    }

    @Test fun observerExclusion_isByName_notByTextMatch_keepsDroneBroadcast() {
        // The critical guarantee: excluding the OBSERVER location must NOT touch drone_lat /
        // operator_lat, even though their names contain "lat". Those are broadcast coords.
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals("32.712345", col(redacted, 1, "drone_lat"))
        assertEquals("-117.156789", col(redacted, 1, "drone_lon"))
        assertEquals("32.799999", col(redacted, 1, "operator_lat"))
        assertEquals("-117.188888", col(redacted, 1, "operator_lon"))
    }

    @Test fun droneExcluded_blanksAircraftCoords_leavesObserverAndOperatorAlone() {
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = false, includeOperatorLocation = true))
        assertEquals("", col(redacted, 1, "drone_lat"))
        assertEquals("", col(redacted, 1, "drone_lon"))
        assertEquals("32.700000", col(redacted, 1, "approx_lat"))       // observer kept
        assertEquals("32.799999", col(redacted, 1, "operator_lat"))    // operator kept
    }

    @Test fun operatorExcluded_blanksOnlyOperatorCoords_droneKept() {
        // The composer's DEFAULT drone policy: aircraft in, operator out. Excluding the operator
        // must blank ALL THREE operator columns and NOTHING else - the aircraft coords stay.
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = true, includeOperatorLocation = false))
        assertEquals("", col(redacted, 1, "operator_lat"))
        assertEquals("", col(redacted, 1, "operator_lon"))
        // operator altitude is part of the person's POSITION (the floor they stand on), not
        // telemetry; leaving it behind leaked a coordinate the disclosure said was removed
        assertEquals("", col(redacted, 1, "operator_alt_m"))
        assertEquals("32.712345", col(redacted, 1, "drone_lat"))       // aircraft kept
        assertEquals("-117.156789", col(redacted, 1, "drone_lon"))
        assertEquals("32.700000", col(redacted, 1, "approx_lat"))      // observer kept
        // AIRCRAFT telemetry is not a location column and must never be touched by any switch
        assertEquals("120", col(redacted, 1, "altitude_m"))
    }

    @Test fun operatorIncluded_keepsAllThreeOperatorColumns() {
        // The operator switch owns lat, lon AND alt as one unit: including the operator must
        // keep all three, never a partial position.
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals("32.799999", col(redacted, 1, "operator_lat"))
        assertEquals("-117.188888", col(redacted, 1, "operator_lon"))
        assertEquals("0", col(redacted, 1, "operator_alt_m"))
    }

    @Test fun droneToggle_neverTouchesOperatorColumns() {
        // The aircraft switch and the operator switch are independent subjects: excluding the
        // AIRCRAFT position must leave the operator's full position (lat, lon, alt) alone.
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = false, includeOperatorLocation = true))
        assertEquals("32.799999", col(redacted, 1, "operator_lat"))
        assertEquals("-117.188888", col(redacted, 1, "operator_lon"))
        assertEquals("0", col(redacted, 1, "operator_alt_m"))
        assertEquals("", col(redacted, 1, "drone_lat"))
        assertEquals("", col(redacted, 1, "drone_lon"))
    }

    @Test fun everyLocationBearingColumnBlank_whenAllExcluded() {
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = false, includeOperatorLocation = false))
        for (row in 1..2) {
            for (c in OBSERVER_LOCATION_COLS + DRONE_LOCATION_COLS + OPERATOR_LOCATION_COLS) {
                assertEquals("column $c row $row must be blank", "", col(redacted, row, c))
            }
        }
    }

    @Test fun nothingBlanked_whenAllIncluded() {
        val redacted = redactCsvColumns(sample(), contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals(sample(), redacted)
    }

    @Test fun quotedFieldWithComma_doesNotMisalignRedaction() {
        // A maker with a comma is a quoted field; a naive split would shift every later column and
        // blank the wrong one. approx_lat must still be found and blanked, the quoted field intact.
        val row = "2026-08-09T21:02:00Z,exact,,Network camera,a4:11:62:00:00:03,-80,WiFi,OUI match,65,1," +
            "32.760000,-117.120000,,,,,,,,,,,,,\"Acme, Inc.\""
        val csv = "$header\n$row"
        val redacted = redactCsvColumns(csv, contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals("", col(redacted, 1, "approx_lat"))
        assertEquals("", col(redacted, 1, "approx_lon"))
        assertEquals("Acme, Inc.", col(redacted, 1, "maker"))   // preserved, still one field
    }

    @Test fun recordSeparatorParityTable_multilineUasIdStaysAlignedAndRedacted() {
        // uas_id precedes all drone/operator coordinates. Exercise every accepted record ending,
        // the same ending embedded inside that quoted id, doubled quotes, and a trailing ending.
        // Splitting on physical lines would leak the later columns in every one of these cases.
        val base = sample().split("\n")[1]
        val locationCols = OBSERVER_LOCATION_COLS + DRONE_LOCATION_COLS + OPERATOR_LOCATION_COLS
        val separators = listOf("LF" to "\n", "CR" to "\r", "CRLF" to "\r\n")
        for ((name, separator) in separators) {
            val drone = base.replace(
                ",UAS123,",
                ",\"UAS line 1${separator}UAS \"\"line 2\"\"\",",
            )
            val csv = "$header$separator$drone$separator"
            val redacted = redactCsvColumns(csv, contributionBlankColumns(
                includeObserverLocation = false,
                includeDroneLocation = false,
                includeOperatorLocation = false,
            ))

            assertEquals(name, "UAS line 1${separator}UAS \"line 2\"", col(redacted, 1, "uas_id"))
            for (c in locationCols) assertEquals("$name column $c", "", col(redacted, 1, c))
            assertEquals(name, "120", col(redacted, 1, "altitude_m"))
            assertTrue("$name trailing separator", redacted.endsWith(separator))
            assertEquals(name, 1, contributionCsvDataRowCount(csv))
            assertEquals("$name redacted count", 1, contributionCsvDataRowCount(redacted))
        }
    }

    @Test fun malformedDocumentParityTable_parserRedactorAndCountFailClosed() {
        val base = sample().split("\n")[1]
        val malformedRows = listOf(
            "short row" to base.substringBeforeLast(","),
            "long row" to "$base,EXTRA",
            "injected CR" to base.replace(",UAS123,", ",UAS\r123,"),
            "quote in unquoted field" to base.replace(",UAS123,", ",UAS\"123,"),
            "bytes after closing quote" to base.replace(",UAS123,", ",\"UAS\"junk,"),
            "unterminated quote" to base.replace(",UAS123,", ",\"unterminated UAS,"),
        )
        val blankAll = contributionBlankColumns(
            includeObserverLocation = false,
            includeDroneLocation = false,
            includeOperatorLocation = false,
        )
        for ((name, malformed) in malformedRows) {
            val csv = "$header\n$malformed\n"
            assertNull("$name parser", parseCsvDocument(csv))
            assertEquals("$name redaction", header, redactCsvColumns(csv, blankAll))
            assertEquals("$name all-included path", header, redactCsvColumns(csv, emptySet()))
            assertEquals("$name count", 0, contributionCsvDataRowCount(csv))
        }
    }

    @Test fun productionHeaderFixture_containsAllSevenPolicyColumns() {
        // Android's manager header is embedded in its instance export method, so this exact mirror
        // is the test boundary here. iOS additionally compares the fixture to its pure builder.
        val policyColumns = OBSERVER_LOCATION_COLS + DRONE_LOCATION_COLS + OPERATOR_LOCATION_COLS
        assertEquals(7, policyColumns.size)
        assertTrue(cols.containsAll(policyColumns))
    }

    // A capture window [1000, 2000]. Overlap membership, not containment.
    @Test fun captureWindow_overlapSemantics() {
        val start = 1000L; val stop = 2000L
        // entirely before / after the window -> out
        assertTrue(!inCaptureWindow(200, 800, start, stop))
        assertTrue(!inCaptureWindow(2200, 2500, start, stop))
        // entirely inside -> in
        assertTrue(inCaptureWindow(1200, 1800, start, stop))
        // present before Start but still audible during the window -> IN (the key overlap case)
        assertTrue(inCaptureWindow(500, 1500, start, stop))
        // first heard inside, still going after Stop -> in
        assertTrue(inCaptureWindow(1500, 3000, start, stop))
        // spans the whole window -> in
        assertTrue(inCaptureWindow(0, 5000, start, stop))
        // touches the boundary exactly -> in (inclusive)
        assertTrue(inCaptureWindow(2000, 2000, start, stop))
        assertTrue(inCaptureWindow(1000, 1000, start, stop))
        // a device with no phone-side timestamp cannot be placed -> out
        assertTrue(!inCaptureWindow(null, 1500, start, stop))
        assertTrue(!inCaptureWindow(1500, null, start, stop))
    }

    @Test fun captureTimestamp_usesLastSighting_clampedInsideWindow() {
        val start = 1000L; val stop = 2000L
        assertEquals(start, captureTimestamp(800, start, stop))
        assertEquals(1500L, captureTimestamp(1500, start, stop))
        assertEquals(stop, captureTimestamp(2200, start, stop))
        assertEquals(null, captureTimestamp(null, start, stop))
    }

    @Test fun policySet_mapsToTheRightColumns() {
        assertEquals(OBSERVER_LOCATION_COLS, contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = true))
        assertEquals(DRONE_LOCATION_COLS, contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = false, includeOperatorLocation = true))
        assertEquals(OPERATOR_LOCATION_COLS, contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = true, includeOperatorLocation = false))
        // The composer's defaults: observer OUT, aircraft IN, operator OUT.
        assertEquals(OBSERVER_LOCATION_COLS + OPERATOR_LOCATION_COLS, contributionBlankColumns(
            includeObserverLocation = false, includeDroneLocation = true, includeOperatorLocation = false))
        assertTrue(contributionBlankColumns(
            includeObserverLocation = true, includeDroneLocation = true, includeOperatorLocation = true).isEmpty())
    }
}
