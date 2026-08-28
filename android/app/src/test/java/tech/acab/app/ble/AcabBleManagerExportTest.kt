package tech.acab.app.ble

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.Detection
import tech.acab.app.model.historyBeginFromOrAbsent
import tech.acab.app.model.historyBeginGenerationOrAbsent

/**
 * The detection CSV's drone-column type gate, the Android half of iOS's ExportTests.
 *
 * WHY THIS EXISTS. On 2026-08-05 a real 2747-row export was found to carry a bogus drone position
 * on 2746 of 2746 NON-drone rows: `lat`/`lon` on the wire is overloaded ("drones = the aircraft's
 * own broadcast position; everything else = the DETECTOR's GPS", the `lat`,`lon` row of
 * ble-protocol.md's detection-frame table) and the CSV writer copied it into
 * drone_lat/drone_lon unconditionally. 555 of those rows were byte-identical to the row's own
 * approx_lat/lon, i.e. the phone's position exported as an aircraft's. Both writers already carried
 * a comment claiming "blank for a non-drone row"; nothing on THIS side enforced it. iOS pinned the
 * gate the day it was fixed and named this file in its fixture comment; here it finally is.
 *
 * WHAT THIS SUITE DOES NOT COVER, so nobody reads more assurance into it than it gives. These
 * tests call droneExportCoords directly - the gate function, not the writer. detectionsCsv is
 * never run here, so its CALL to the gate is unpinned on this side: a writer that stopped calling
 * droneExportCoords, or that filled the drone columns from somewhere else, would still pass. iOS
 * asserts on buildCSV output instead, so it covers writer and gate together. Until this side runs
 * the writer too, the end-to-end guarantee exists on iOS only.
 *
 * Fixtures are the wire JSON, verbatim from ExportTests.swift - keep the strings identical.
 * Detection is decode-only on both platforms, which makes the wire format the natural parity
 * surface.
 */
class AcabBleManagerExportTest {

    /** A BLE "nearby device" that carries lat/lon, which for a non-drone is the DETECTOR's GPS.
     *  This is the exact shape that produced the phantom-aircraft bug. */
    private val nearbyJson =
        """{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,""" +
        """"lat":32.763243,"lon":-117.116077,"cid":76,"n":1}"""

    /** A drone with Remote ID: its lat/lon IS the aircraft, and plat/plon is the operator. */
    private val droneJson =
        """{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,""" +
        """"lat":32.763950,"lon":-117.114273,"plat":32.762257,"plon":-117.114303,""" +
        """"alt":208,"id":"1581F67QC236L014509G","n":15}"""

    /** Exercise the same raw-lexeme boundary as BLE ingress, not desktop org.json's more precise
     * BigDecimal representation. */
    private fun decode(json: String): Detection =
        Detection.fromWireJson(json, JSONObject(json))

    @Test fun nonDroneRow_leavesEveryDroneAndOperatorColumnBlank() {
        val c = droneExportCoords(decode(nearbyJson))
        assertNull("drone_lat must be blank on a non-drone row", c.droneLat)
        assertNull("drone_lon must be blank on a non-drone row", c.droneLon)
        assertNull("operator_lat must be blank on a non-drone row", c.operatorLat)
        assertNull("operator_lon must be blank on a non-drone row", c.operatorLon)
    }

    @Test fun nonDroneRow_droneColumnsAreNotACopyOfTheWirePosition() {
        // The sharpest form of the regression: this fixture's wire lat/lon is exactly what the row
        // would export as the OBSERVER position. If the gate is removed the two become equal, which
        // is the 555-row signature seen in the real export.
        val d = decode(nearbyJson)
        assertEquals("sanity: the fixture does carry a wire position", 32.763243, d.lat!!, 1e-9)
        assertNull("drone_lat must never mirror a non-drone's wire position",
            droneExportCoords(d).droneLat)
    }

    @Test fun droneRow_keepsItsAircraftAndOperatorPositions() {
        val c = droneExportCoords(decode(droneJson))
        assertEquals(32.763950, c.droneLat!!, 1e-9)
        assertEquals(-117.114273, c.droneLon!!, 1e-9)
        // The operator position is the single most valuable field in a drone capture.
        assertEquals(32.762257, c.operatorLat!!, 1e-9)
        assertEquals(-117.114303, c.operatorLon!!, 1e-9)
    }

    @Test fun droneRow_withNullIslandCoords_blanksBothPairs() {
        // 0,0 is the "no fix yet" value a Remote ID broadcast can carry, not a position off West
        // Africa. validCoord rejects it; the pairs must fall together.
        val c = droneExportCoords(decode(
            droneJson.replace("\"lat\":32.763950", "\"lat\":0").replace("\"lon\":-117.114273", "\"lon\":0")
                .replace("\"plat\":32.762257", "\"plat\":0").replace("\"plon\":-117.114303", "\"plon\":0")))
        assertNull(c.droneLat); assertNull(c.droneLon)
        assertNull(c.operatorLat); assertNull(c.operatorLon)
    }

    @Test fun droneRow_missingOperatorPosition_stillExportsTheAircraft() {
        // The two pairs are independent subjects: an aircraft with no reported pilot position must
        // not lose its own, and a half-filled operator pair must never export.
        val c = droneExportCoords(decode(droneJson.replace("\"plon\":-117.114303,", "")))
        assertEquals(32.763950, c.droneLat!!, 1e-9)
        assertNull(c.operatorLat)
        assertNull(c.operatorLon)
    }

    // The other pure guard over the same wire-sourced `mac` field, kept next to the export gate
    // because both exist for the same reason: a MAC is free text off the radio, not a datum.
    @Test fun boardPushableMac_acceptsOnlyTheShapeTheFirmwareEmits() {
        // The managed lists are pushed to the board as these strings and its parseMac6 silently
        // drops anything else, so a rule keyed on another shape is one the app shows as applied
        // while the board keeps alerting on the device.
        assertTrue(isBoardPushableMac(decode(nearbyJson).mac))
        assertTrue(isBoardPushableMac("00:00:00:00:00:00"))
        for (bad in listOf(
            "", "   ", "not-a-mac", "c2:40:d8:1c:2b", "c2:40:d8:1c:2b:96:aa",
            "C2:40:D8:1C:2B:96",          // callers lowercase first; unlowered must not slip through
            "c2-40-d8-1c-2b-96", "c240d81c2b96", "c2:40:d8:1c:2b:9g", "=cmd|' /c calc'!A0",
            " c2:40:d8:1c:2b:96", "c2:40:d8:1c:2b:96 ",
        )) assertFalse(bad, isBoardPushableMac(bad))
    }

    // ---- wire clamps (parity table, shared with ExportTests.swift) ---------------------------

    /** One legal history row with the field under test appended. The TAILS are the shared half:
     *  ExportTests.swift builds the same bytes from the same tails and asserts the same decoded
     *  OUTCOME, because a fixture the two platforms pass for different reasons proves nothing.
     *  The two spellings of "no value" differ, and writing both sides is what pins that: Android
     *  says 0, iOS says nil, each its platform's existing absent value.
     *
     *  None of these values can come off a genuine board - the firmware's slotValid() rejects
     *  seq 0 and 0xFFFFFFFF, and at/ms/boot are uint32 on the wire - so what this table pins is
     *  the behaviour when the peer is NOT a genuine board. That is the case that matters: a
     *  poisoned seq or timestamp is checkpointed to prefs and survives relaunch. */
    private fun clamped(tail: String): Detection =
        decode("""{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","n":1,"hist":true,$tail}""")

    /** The empty-slot sentinels, the sharpest case in the table: one of these riding into
     *  lastSeq is persisted, and the board then never replays another buffered record. */
    @Test fun seqEmptySlotSentinels_neverBecomeACursor() {
        for (tail in listOf(""""seq":0""", """"seq":4294967295""")) {
            val d = clamped(tail)
            assertEquals("$tail must move no cursor", 0L, d.seq)
            assertTrue("$tail: the record is still received and counted, it just moves no cursor",
                d.hist)
        }
    }

    @Test fun seqOutsideTheUint32WireType_isRejectedButALegalSeqSurvives() {
        assertEquals(0L, clamped(""""seq":-1""").seq)
        assertEquals(0L, clamped(""""seq":4294967296""").seq)
        // The guard has to reject the sentinels without swallowing the ordinary case, or the
        // offline buffer stops draining for the opposite reason.
        assertEquals(1L, clamped(""""seq":1""").seq)
        assertEquals(4294967294L, clamped(""""seq":4294967294""").seq)
    }

    /** Out of range is NO TIMESTAMP (0 here, nil on iOS), never the nearest legal value: pinned
     *  to the ceiling it would present 2106 as a real capture time and widen that boot's anchor
     *  bounds to match. */
    @Test fun capturedAtOutsideTheUint32WireType_isDroppedNotPinned() {
        assertEquals(0L, clamped(""""at":4294967296""").at)
        assertEquals(0L, clamped(""""at":-1""").at)
        // A BigDecimal on this path: longValue() would wrap it modulo 2^64 back into range.
        assertEquals(0L, clamped(""""at":1e30""").at)
        // Both ends of the legal range still decode.
        assertEquals(4294967295L, clamped(""""at":4294967295""").at)
        assertEquals(1780000000L, clamped(""""at":1780000000""").at)
    }

    /** Uptime and boot session are uint32 too, and they feed the reconstruction that dates every
     *  unanchored record, so they read as absent by the same rule. */
    @Test fun uptimeAndBootSessionOutsideTheWireType_readAsAbsent() {
        val poisoned = clamped(""""ms":4294967296,"boot":4294967296""")
        assertEquals(0L, poisoned.ms)
        assertEquals(0L, poisoned.boot)
        val legal = clamped(""""ms":1234,"boot":7""")
        assertEquals(1234L, legal.ms)
        assertEquals(7L, legal.boot)
    }

    /** JSON decimal numbers are not uint32 values merely because Long conversion can discard the
     *  fractional part. seq is a persisted replay cursor, while at/ms/boot feed reconstruction,
     *  so truncating any one of them manufactures durable ordering or time data. */
    @Test fun fractionalUint32WireValues_areRejectedBeforeConversion() {
        val fractional = clamped(
            """"seq":1.5,"at":1780000000.5,"ms":1234.5,"boot":7.5""",
        )
        assertEquals(0L, fractional.seq)
        assertEquals(0L, fractional.at)
        assertEquals(0L, fractional.ms)
        assertEquals(0L, fractional.boot)

        // This fraction disappears if the parser first narrows through Double, so it pins that
        // integrality is checked against the JSON number itself rather than a rounded proxy.
        assertEquals(0L, clamped(""""seq":1.0000000000000000001""").seq)

        // A decimal spelling is still legal when its mathematical value is exactly integral.
        val integral = clamped(""""seq":1.0,"at":1780000000.0,"ms":1234.0,"boot":7.0""")
        assertEquals(1L, integral.seq)
        assertEquals(1780000000L, integral.at)
        assertEquals(1234L, integral.ms)
        assertEquals(7L, integral.boot)
    }

    /** Android's framework JSONTokener parses decimal/exponent tokens as Double. Model that exact
     * runtime handoff explicitly instead of letting the desktop org.json test dependency preserve
     * these tokens as BigDecimal: all four parsed Numbers below have already rounded to integers,
     * but the raw BLE spellings remain fractional and must win. */
    @Test fun androidRoundedNumbers_cannotHideFractionalWireLexemes() {
        val raw = """{"t":7,"mac":"c2:40:d8:1c:2b:96","hist":true,""" +
            """"seq":1.0000000000000000001,"at":1780000000.0000000001,""" +
            """"ms":1234.0000000000000001,"boot":7.0000000000000001}"""
        val parsedAsAndroidRuntime = JSONObject()
            .put("t", 7)
            .put("mac", "c2:40:d8:1c:2b:96")
            .put("hist", true)
            .put("seq", 1.0)
            .put("at", 1_780_000_000.0)
            .put("ms", 1_234.0)
            .put("boot", 7.0)

        // Control: once only the rounded object remains, the fraction is irrecoverable.
        val objectOnly = Detection.fromJson(parsedAsAndroidRuntime)
        assertEquals(1L, objectOnly.seq)
        assertEquals(1_780_000_000L, objectOnly.at)
        assertEquals(1_234L, objectOnly.ms)
        assertEquals(7L, objectOnly.boot)

        val wire = Detection.fromWireJson(raw, parsedAsAndroidRuntime)
        assertEquals(0L, wire.seq)
        assertEquals(0L, wire.at)
        assertEquals(0L, wire.ms)
        assertEquals(0L, wire.boot)
    }

    @Test fun wireUint32Lexemes_areTopLevelAndPreserveExactExponentSpellings() {
        val raw = """{"t":7,"mac":"c2:40:d8:1c:2b:96","hist":true,""" +
            """"det":"quoted \\\"seq\\\":99 is not a property","extra":{"seq":88},""" +
            """"\u0073eq":1e0,"at":17800000000e-1,"ms":12340e-1,"boot":70e-1}"""
        val decoded = Detection.fromWireJson(raw, JSONObject(raw))
        assertEquals(1L, decoded.seq)
        assertEquals(1_780_000_000L, decoded.at)
        assertEquals(1_234L, decoded.ms)
        assertEquals(7L, decoded.boot)
    }

    /** Duplicate-member semantics are deliberately not inherited from JSONObject. Android and
     * iOS must both make the duplicated cursor/time field absent, regardless of which occurrence
     * their general-purpose decoder keeps. Other unambiguous fields remain usable. */
    @Test fun duplicatePrecisionSensitiveFields_failClosedIncludingEscapedKeySpellings() {
        val allDuplicated = """{"t":7,"mac":"c2:40:d8:1c:2b:96","hist":true,""" +
            """"seq":1,"seq":2,"at":10,"at":11,"ms":20,"ms":21,"boot":30,"boot":31,""" +
            """"rssi":-87,"rssi":-40}"""
        // The host org.json dependency rejects duplicate members while Android's implementation
        // keeps one. Supply the already-materialized last-key view explicitly: the raw scanner,
        // not that platform choice, is the authority for these fields.
        val parsedLastWins = JSONObject()
            .put("t", 7)
            .put("mac", "c2:40:d8:1c:2b:96")
            .put("hist", true)
            .put("seq", 2)
            .put("at", 11)
            .put("ms", 21)
            .put("boot", 31)
            .put("rssi", -40)
        val duplicated = Detection.fromWireJson(allDuplicated, parsedLastWins)
        assertEquals(0L, duplicated.seq)
        assertEquals(0L, duplicated.at)
        assertEquals(0L, duplicated.ms)
        assertEquals(0L, duplicated.boot)
        assertEquals(0, duplicated.rssi)

        val escapedDuplicate = """{"t":7,"mac":"c2:40:d8:1c:2b:96","hist":true,""" +
            """"seq":1,"s\u0065q":2,"at":123,"rssi":-87,"r\u0073si":-40}"""
        val escapedParsed = JSONObject()
            .put("t", 7)
            .put("mac", "c2:40:d8:1c:2b:96")
            .put("hist", true)
            .put("seq", 2)
            .put("at", 123)
            .put("rssi", -40)
        val escaped = Detection.fromWireJson(escapedDuplicate, escapedParsed)
        assertEquals(0L, escaped.seq)
        assertEquals(0, escaped.rssi)
        assertEquals("an unrelated unambiguous field must survive", 123L, escaped.at)
    }

    /** `from` is the same persisted replay-cursor trust boundary as a record's `seq`. Simulate the
     * Android framework parser's already-rounded Double explicitly, then prove the raw sentinel
     * helper does not accept the integer-looking proxy. */
    @Test fun historyBeginFrom_rejectsFractionHiddenByAndroidDoubleRounding() {
        val rawFraction = """{"hist":"begin","n":1,"from":1.0000000000000000001}"""
        val parsedAsAndroidRuntime = JSONObject()
            .put("hist", "begin")
            .put("n", 1)
            .put("from", 1.0)
        assertEquals(1L, parsedAsAndroidRuntime.optLong("from")) // the unsafe object-only result
        assertEquals(0L, historyBeginFromOrAbsent(rawFraction))

        for (raw in listOf(
            """{"hist":"begin","from":0}""",
            """{"hist":"begin","from":-1}""",
            """{"hist":"begin","from":1.5}""",
            """{"hist":"begin","from":4294967296}""",
            """{"hist":"begin","from":"1"}""",
            """{"hist":"begin","from":null}""",
        )) assertEquals(raw, 0L, historyBeginFromOrAbsent(raw))

        assertEquals(1L, historyBeginFromOrAbsent("""{"hist":"begin","from":1.0}"""))
        assertEquals(1L, historyBeginFromOrAbsent("""{"hist":"begin","from":10e-1}"""))
        assertEquals(
            0xFFFF_FFFFL,
            historyBeginFromOrAbsent("""{"hist":"begin","from":4294967295}"""),
        )
    }

    @Test fun historyBeginFrom_rejectsOrdinaryAndEscapedDuplicates() {
        for (raw in listOf(
            """{"hist":"begin","from":1504,"from":1505}""",
            """{"hist":"begin","from":1504,"fr\u006fm":1505}""",
            """{"hist":"begin","from":1504,"from":null}""",
            """{"hist":"begin","from":null,"from":1504}""",
        )) assertEquals(raw, 0L, historyBeginFromOrAbsent(raw))
    }

    @Test fun historyBeginGeneration_usesTheExactUint32Lexeme() {
        assertEquals(42L, historyBeginGenerationOrAbsent(
            """{"hist":"begin","from":1,"gen":42}""",
        ))
        for (raw in listOf(
            """{"hist":"begin","gen":0}""",
            """{"hist":"begin","gen":1.0000000000000000001}""",
            """{"hist":"begin","gen":4294967296}""",
            """{"hist":"begin","gen":42,"gen":43}""",
            """{"hist":"begin","gen":42,"g\u0065n":43}""",
        )) assertEquals(raw, 0L, historyBeginGenerationOrAbsent(raw))
    }

    @Test fun rssi_isClampedToTheInt16WireType() {
        assertEquals(32767, clamped(""""rssi":32767""").rssi)
        assertEquals(-32768, clamped(""""rssi":-32768""").rssi)
        assertEquals(32767, clamped(""""rssi":32768""").rssi)
        assertEquals(-32768, clamped(""""rssi":-32769""").rssi)
        assertEquals(32767, clamped(""""rssi":2147483647""").rssi)
        assertEquals(-32768, clamped(""""rssi":-2147483648""").rssi)
        // Wider than Int32: optInt NARROWED this into a negative dBm, i.e. an impossibly close
        // device reported as impossibly far away.
        assertEquals(32767, clamped(""""rssi":2147483648""").rssi)
        assertEquals(-87, clamped(""""rssi":-87""").rssi)
    }

    @Test fun rssi_requiresAnIntegralNumericJsonTokenBeforeClamping() {
        for (tail in listOf(
            """"rssi":"-87"""",
            """"rssi":-87.5""",
            // Android's framework JSONTokener rounds this to -87.0; the raw lexeme must win.
            """"rssi":-87.0000000000000000001""",
            """"rssi":null""",
            """"rssi":true""",
            // iOS's Int decode also rejects an integer outside signed 64-bit before its clamp.
            """"rssi":9223372036854775808""",
            """"rssi":1e30""",
        )) assertEquals(tail, 0, clamped(tail).rssi)

        // Decimal/exponent spellings are valid when their mathematical value is integral.
        assertEquals(-87, clamped(""""rssi":-87.0""").rssi)
        assertEquals(-87, clamped(""""rssi":-870e-1""").rssi)
        assertEquals(32767, clamped(""""rssi":9223372036854775807""").rssi)

        // Persisted/demo objects use the same strict type/integrality rule without a raw frame.
        val stored = JSONObject().put("t", 7).put("rssi", "-87")
        assertEquals(0, Detection.fromJson(stored).rssi)
        stored.put("rssi", -87.5)
        assertEquals(0, Detection.fromJson(stored).rssi)
        stored.put("rssi", -87.0)
        assertEquals(-87, Detection.fromJson(stored).rssi)
    }
}
