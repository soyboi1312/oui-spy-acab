import XCTest
@testable import Beacons

/// Location-redaction guarantees for a shared contribution CSV. iOS twin of Android's
/// ContributionCsvTest; the two assert the same behaviour so a contribution is safe on either
/// platform. The point: a contribution never leaks the CONTRIBUTOR'S phone position by accident,
/// keeps the drone Remote ID BROADCAST coords when asked, and controls the two by NAME, never by
/// matching the text "lat"/"lon".
final class ContributionCsvTests: XCTestCase {

    // The real column order (BLEManager buildCSV header). approx_* at 10/11 are the phone; drone_*
    // at 14/15 and operator_* at 20/21 are the Remote ID broadcast.
    private let header =
        "detected_at,time_basis,time_precision_s,type,mac,rssi,source,matched_on,confidence,sightings," +
        "approx_lat,approx_lon,company_id,uas_id,drone_lat,drone_lon,altitude_m,speed_ms,heading_deg," +
        "height_agl_m,operator_lat,operator_lon,operator_alt_m,rid_status,maker"

    private var cols: [String] { header.components(separatedBy: ",") }
    private func col(_ csv: String, _ row: Int, _ name: String) -> String {
        let records = ContributionCsv.parseDocument(csv)!.records
        return records[row][cols.firstIndex(of: name)!]
    }

    private func sample() -> String {
        // operator_alt_m is deliberately non-zero (30) so "kept" and "blanked" can never be
        // confused in an assertion.
        let drone = "2026-08-09T21:00:00Z,exact,,Drone,0c:9a:e6:00:00:01,-70,BLE,ODID,60,3," +
            "32.700000,-117.100000,0x0000,UAS123,32.712345,-117.156789,120,5,90,110," +
            "32.799999,-117.188888,30,airborne,DJI"
        let cam = "2026-08-09T21:01:00Z,exact,,Network camera,a4:11:62:00:00:02,-80,WiFi,OUI match,65,1," +
            "32.760000,-117.120000,,,,,,,,,,,,,Arlo"
        return "\(header)\n\(drone)\n\(cam)"
    }

    func testObserverLocationRemovedByDefault() {
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(r, 1, "approx_lat"), "")
        XCTAssertEqual(col(r, 1, "approx_lon"), "")
        XCTAssertEqual(col(r, 2, "approx_lat"), "")
        XCTAssertEqual(col(r, 2, "approx_lon"), "")
    }

    func testObserverExclusionIsByNameNotTextMatch_keepsDroneBroadcast() {
        // The critical guarantee: excluding the OBSERVER location must NOT touch drone_lat /
        // operator_lat, even though their names contain "lat". Those are broadcast coords.
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(r, 1, "drone_lat"), "32.712345")
        XCTAssertEqual(col(r, 1, "drone_lon"), "-117.156789")
        XCTAssertEqual(col(r, 1, "operator_lat"), "32.799999")
        XCTAssertEqual(col(r, 1, "operator_lon"), "-117.188888")
    }

    func testDroneAircraftExcluded_blanksAircraft_leavesObserverAndOperator() {
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: false,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(r, 1, "drone_lat"), "")
        XCTAssertEqual(col(r, 1, "drone_lon"), "")
        XCTAssertEqual(col(r, 1, "operator_lat"), "32.799999")
        XCTAssertEqual(col(r, 1, "operator_lon"), "-117.188888")
        XCTAssertEqual(col(r, 1, "approx_lat"), "32.700000")
    }

    func testOperatorExcluded_blanksOnlyOperator_keepsDroneAircraft() {
        // The point of the toggle split: the DEFAULT posture (operator out, aircraft in) must
        // strip exactly the person's coordinates while the machine's survive untouched. All
        // THREE operator columns go: the altitude of a person's position is location too.
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                         includeOperatorLocation: false))
        XCTAssertEqual(col(r, 1, "operator_lat"), "")
        XCTAssertEqual(col(r, 1, "operator_lon"), "")
        XCTAssertEqual(col(r, 1, "operator_alt_m"), "")
        XCTAssertEqual(col(r, 1, "drone_lat"), "32.712345")
        XCTAssertEqual(col(r, 1, "drone_lon"), "-117.156789")
        XCTAssertEqual(col(r, 1, "approx_lat"), "32.700000")
        XCTAssertEqual(col(r, 1, "approx_lon"), "-117.100000")
    }

    func testOperatorAltitudeRidesTheOperatorToggle_notTheAircraftToggle() {
        // operator_alt_m is the third coordinate of a PERSON's position (which floor, hilltop vs
        // street), so it must blank and survive exactly with operator_lat/lon and never move with
        // the aircraft toggle. Operator excluded: all three blank.
        let excluded = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                         includeOperatorLocation: false))
        XCTAssertEqual(col(excluded, 1, "operator_lat"), "")
        XCTAssertEqual(col(excluded, 1, "operator_lon"), "")
        XCTAssertEqual(col(excluded, 1, "operator_alt_m"), "")
        // Operator included: all three survive.
        let included = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(included, 1, "operator_lat"), "32.799999")
        XCTAssertEqual(col(included, 1, "operator_lon"), "-117.188888")
        XCTAssertEqual(col(included, 1, "operator_alt_m"), "30")
        // The AIRCRAFT toggle owns drone_lat/lon only; excluding the aircraft must not touch any
        // operator column (and the aircraft's own altitude_m is telemetry, also untouched).
        let aircraftOff = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: false,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(aircraftOff, 1, "operator_lat"), "32.799999")
        XCTAssertEqual(col(aircraftOff, 1, "operator_lon"), "-117.188888")
        XCTAssertEqual(col(aircraftOff, 1, "operator_alt_m"), "30")
        XCTAssertEqual(col(aircraftOff, 1, "altitude_m"), "120")
    }

    func testEveryLocationColumnBlank_whenAllExcluded() {
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: false,
                                         includeOperatorLocation: false))
        for row in 1...2 {
            for c in ContributionCsv.observerLocationCols
                .union(ContributionCsv.droneLocationCols)
                .union(ContributionCsv.operatorLocationCols) {
                XCTAssertEqual(col(r, row, c), "", "column \(c) row \(row) must be blank")
            }
        }
    }

    func testNothingBlanked_whenAllIncluded() {
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                         includeOperatorLocation: true))
        XCTAssertEqual(r, sample())
    }

    func testQuotedFieldWithComma_doesNotMisalign() {
        let row = "2026-08-09T21:02:00Z,exact,,Network camera,a4:11:62:00:00:03,-80,WiFi,OUI match,65,1," +
            "32.760000,-117.120000,,,,,,,,,,,,,\"Acme, Inc.\""
        let csv = "\(header)\n\(row)"
        let r = ContributionCsv.redact(csv, blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                         includeOperatorLocation: true))
        XCTAssertEqual(col(r, 1, "approx_lat"), "")
        XCTAssertEqual(col(r, 1, "approx_lon"), "")
        XCTAssertEqual(col(r, 1, "maker"), "Acme, Inc.")   // preserved, still one field
    }

    func testRecordSeparatorParityTable_multilineUasIdStaysAlignedAndRedacted() {
        // uas_id precedes every drone/operator coordinate. Exercise every accepted record ending,
        // that same ending embedded in the quoted id, doubled quotes, and a trailing ending.
        let base = sample().components(separatedBy: "\n")[1]
        let locationCols = ContributionCsv.observerLocationCols
            .union(ContributionCsv.droneLocationCols)
            .union(ContributionCsv.operatorLocationCols)
        let separators = [("LF", "\n"), ("CR", "\r"), ("CRLF", "\r\n")]
        for (name, separator) in separators {
            let drone = base.replacingOccurrences(
                of: ",UAS123,",
                with: ",\"UAS line 1\(separator)UAS \"\"line 2\"\"\",")
            let csv = "\(header)\(separator)\(drone)\(separator)"
            let r = ContributionCsv.redact(csv, blankColumns:
                ContributionCsv.blankColumns(includeObserverLocation: false,
                                             includeDroneLocation: false,
                                             includeOperatorLocation: false))

            XCTAssertEqual(col(r, 1, "uas_id"), "UAS line 1\(separator)UAS \"line 2\"", name)
            for c in locationCols { XCTAssertEqual(col(r, 1, c), "", "\(name) column \(c)") }
            XCTAssertEqual(col(r, 1, "altitude_m"), "120", name)
            XCTAssertTrue(r.hasSuffix(separator), "\(name) trailing separator")
            XCTAssertEqual(ContributionCsv.dataRowCount(csv), 1, name)
            XCTAssertEqual(ContributionCsv.dataRowCount(r), 1, "\(name) redacted count")
        }
    }

    func testMalformedDocumentParityTable_parserRedactorAndCountFailClosed() {
        let base = sample().components(separatedBy: "\n")[1]
        let malformedRows = [
            ("short row", String(base[..<base.lastIndex(of: ",")!])),
            ("long row", "\(base),EXTRA"),
            ("injected CR", base.replacingOccurrences(of: ",UAS123,", with: ",UAS\r123,")),
            ("quote in unquoted field", base.replacingOccurrences(of: ",UAS123,", with: ",UAS\"123,")),
            ("bytes after closing quote", base.replacingOccurrences(of: ",UAS123,", with: ",\"UAS\"junk,")),
            ("unterminated quote", base.replacingOccurrences(of: ",UAS123,", with: ",\"unterminated UAS,")),
        ]
        let blankAll = ContributionCsv.blankColumns(includeObserverLocation: false,
                                                    includeDroneLocation: false,
                                                    includeOperatorLocation: false)
        for (name, malformed) in malformedRows {
            let csv = "\(header)\n\(malformed)\n"
            XCTAssertNil(ContributionCsv.parseDocument(csv), "\(name) parser")
            XCTAssertEqual(ContributionCsv.redact(csv, blankColumns: blankAll), header,
                           "\(name) redaction")
            XCTAssertEqual(ContributionCsv.redact(csv, blankColumns: []), header,
                           "\(name) all-included path")
            XCTAssertEqual(ContributionCsv.dataRowCount(csv), 0, "\(name) count")
        }
    }

    func testProductionHeader_containsAllSevenPolicyColumns() {
        let productionHeader = BLEManager.buildCSV([]).components(separatedBy: "\n")[0]
        let policyColumns = ContributionCsv.observerLocationCols
            .union(ContributionCsv.droneLocationCols)
            .union(ContributionCsv.operatorLocationCols)
        XCTAssertEqual(productionHeader, header)
        XCTAssertEqual(policyColumns.count, 7)
        XCTAssertTrue(Set(productionHeader.components(separatedBy: ",")).isSuperset(of: policyColumns))
    }

    func testCaptureWindowOverlapSemantics() {
        let start: Int64 = 1000, stop: Int64 = 2000
        XCTAssertFalse(ContributionCsv.inCaptureWindow(200, 800, start, stop))   // before
        XCTAssertFalse(ContributionCsv.inCaptureWindow(2200, 2500, start, stop)) // after
        XCTAssertTrue(ContributionCsv.inCaptureWindow(1200, 1800, start, stop))  // inside
        XCTAssertTrue(ContributionCsv.inCaptureWindow(500, 1500, start, stop))   // present before Start, still audible
        XCTAssertTrue(ContributionCsv.inCaptureWindow(1500, 3000, start, stop))  // starts inside, runs past Stop
        XCTAssertTrue(ContributionCsv.inCaptureWindow(0, 5000, start, stop))     // spans the window
        XCTAssertTrue(ContributionCsv.inCaptureWindow(2000, 2000, start, stop))  // boundary, inclusive
        XCTAssertTrue(ContributionCsv.inCaptureWindow(1000, 1000, start, stop))
        XCTAssertFalse(ContributionCsv.inCaptureWindow(nil, 1500, start, stop))  // no timestamp -> out
        XCTAssertFalse(ContributionCsv.inCaptureWindow(1500, nil, start, stop))
    }

    func testCaptureTimestampUsesLastSightingClampedInsideWindow() {
        let start: Int64 = 1000, stop: Int64 = 2000
        XCTAssertEqual(ContributionCsv.captureTimestamp(800, start, stop), start)
        XCTAssertEqual(ContributionCsv.captureTimestamp(1500, start, stop), 1500)
        XCTAssertEqual(ContributionCsv.captureTimestamp(2200, start, stop), stop)
        XCTAssertNil(ContributionCsv.captureTimestamp(nil, start, stop))
    }

    func testPolicySetMapsToTheRightColumns() {
        // Exhaustive single-flag mapping: each include flag owns exactly its column set.
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                                    includeOperatorLocation: true),
                       ContributionCsv.observerLocationCols)
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: false,
                                                    includeOperatorLocation: true),
                       ContributionCsv.droneLocationCols)
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                                    includeOperatorLocation: false),
                       ContributionCsv.operatorLocationCols)
        // Pairs + all-off compose by union; all-on blanks nothing.
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: false,
                                                    includeOperatorLocation: true),
                       ContributionCsv.observerLocationCols.union(ContributionCsv.droneLocationCols))
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                                    includeOperatorLocation: false),
                       ContributionCsv.observerLocationCols.union(ContributionCsv.operatorLocationCols))
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: false,
                                                    includeOperatorLocation: false),
                       ContributionCsv.droneLocationCols.union(ContributionCsv.operatorLocationCols))
        XCTAssertEqual(ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: false,
                                                    includeOperatorLocation: false),
                       ContributionCsv.observerLocationCols
                           .union(ContributionCsv.droneLocationCols)
                           .union(ContributionCsv.operatorLocationCols))
        XCTAssertTrue(ContributionCsv.blankColumns(includeObserverLocation: true, includeDroneLocation: true,
                                                   includeOperatorLocation: true).isEmpty)
    }

    func testDefaultPolicy_operatorOut_aircraftIn_observerOut() {
        // The shipped defaults (observer OFF, aircraft ON, operator OFF) as one end-to-end pass:
        // a person's coordinates (contributor + operator) are gone, the machine's stay.
        let r = ContributionCsv.redact(sample(), blankColumns:
            ContributionCsv.blankColumns(includeObserverLocation: false, includeDroneLocation: true,
                                         includeOperatorLocation: false))
        XCTAssertEqual(col(r, 1, "approx_lat"), "")
        XCTAssertEqual(col(r, 1, "approx_lon"), "")
        XCTAssertEqual(col(r, 1, "operator_lat"), "")
        XCTAssertEqual(col(r, 1, "operator_lon"), "")
        XCTAssertEqual(col(r, 1, "operator_alt_m"), "")
        XCTAssertEqual(col(r, 1, "drone_lat"), "32.712345")
        XCTAssertEqual(col(r, 1, "drone_lon"), "-117.156789")
        // AIRCRAFT telemetry is not a location column and must never be swept up by the location
        // policy. (operator_alt_m, blanked above, is the deliberate exception: the altitude of a
        // person's position is location.)
        XCTAssertEqual(col(r, 1, "altitude_m"), "120")
        XCTAssertEqual(col(r, 1, "speed_ms"), "5")
        XCTAssertEqual(col(r, 1, "heading_deg"), "90")
    }
}
