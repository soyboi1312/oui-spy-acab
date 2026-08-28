import XCTest
import CoreLocation
@testable import Beacons

/// Export-format tests: the CSV drone-column gate and the GPX writer.
///
/// WHY THESE EXIST. On 2026-08-05 a real 2747-row export was found to carry a bogus drone position
/// on 2746 of 2746 NON-drone rows: `lat`/`lon` on the wire is overloaded ("drones = the aircraft's
/// own broadcast position; everything else = the DETECTOR's GPS", the `lat`,`lon` row of
/// ble-protocol.md's detection-frame table) and the CSV writer copied it into
/// drone_lat/drone_lon unconditionally. 555 of those rows were byte-identical to the row's own
/// approx_lat/lon, i.e. the phone's position exported as an aircraft's. Both writers already
/// carried a comment claiming "blank for a non-drone row"; nothing enforced it. These tests are
/// that enforcement.
///
/// Fixtures are built as WIRE JSON rather than by calling an initializer, so the exact same
/// fixture strings can be handed to the Android suite. Detection is decode-only, which makes the
/// wire format the only construction path and therefore the natural parity surface.
final class ExportTests: XCTestCase {

    // MARK: fixtures (shared with AcabBleManagerExportTest.kt - keep these strings identical)

    /// A BLE "nearby device" that carries lat/lon, which for a non-drone is the DETECTOR's GPS.
    /// This is the exact shape that produced the phantom-aircraft bug.
    static let nearbyJSON = """
    {"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,\
    "lat":32.763243,"lon":-117.116077,"cid":76,"n":1}
    """

    /// A drone with Remote ID: its lat/lon IS the aircraft, and plat/plon is the operator.
    static let droneJSON = """
    {"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,\
    "lat":32.763950,"lon":-117.114273,"plat":32.762257,"plon":-117.114303,\
    "alt":208,"id":"1581F67QC236L014509G","n":15}
    """

    /// Name/detail containing XML metacharacters, to pin the GPX escaping.
    static let xmlNastyJSON = """
    {"t":7,"s":0,"meth":0,"c":0,"mac":"aa:bb:cc:dd:ee:ff","rssi":-50,\
    "lat":1.5,"lon":2.5,"det":"a & b <tag> \\"quoted\\"","n":1}
    """

    private func decode(_ json: String) throws -> Detection {
        try Detection.decodeWireJSON(Data(json.utf8))
    }

    private func row(_ json: String,
                     loc: CLLocationCoordinate2D? = CLLocationCoordinate2D(latitude: 40.0, longitude: -70.0),
                     basis: TimeBasis = .exact,
                     at: Date = Date(timeIntervalSince1970: 1_780_000_000)) throws -> BLEManager.CSVRowInput {
        BLEManager.CSVRowInput(d: try decode(json), firstSeen: at, loc: loc, basis: basis)
    }

    private func cols(_ csvLine: String) -> [String] { csvLine.components(separatedBy: ",") }

    /// XMLDocument is macOS-only, so well-formedness is checked with XMLParser, which ships on
    /// iOS. This is the assertion that actually matters for GPX: a mapping app rejects the whole
    /// file on a parse error, so "contains the right substring" is not enough on its own.
    private func isWellFormedXML(_ s: String) -> Bool {
        let p = XMLParser(data: Data(s.utf8))
        return p.parse()
    }

    // MARK: - the drone-column gate (the bug)

    func testNonDroneRowLeavesDroneColumnsEmpty() throws {
        let csv = BLEManager.buildCSV([try row(Self.nearbyJSON)])
        let body = csv.components(separatedBy: "\n")[1]
        let c = cols(body)
        // Columns are 0-indexed against the header: 14 drone_lat, 15 drone_lon,
        // 20 operator_lat, 21 operator_lon.
        XCTAssertEqual(c[14], "", "drone_lat must be blank on a non-drone row")
        XCTAssertEqual(c[15], "", "drone_lon must be blank on a non-drone row")
        XCTAssertEqual(c[20], "", "operator_lat must be blank on a non-drone row")
        XCTAssertEqual(c[21], "", "operator_lon must be blank on a non-drone row")
    }

    /// The sharpest form of the regression: the fixture's wire lat/lon is ALSO what a detector-GPS
    /// row would export as approx. If the gate is removed, these two columns become equal, which
    /// is exactly the 555-row signature seen in the real export.
    func testNonDroneDroneColumnsAreNotACopyOfTheApproxPosition() throws {
        let here = CLLocationCoordinate2D(latitude: 32.763243, longitude: -117.116077)
        let csv = BLEManager.buildCSV([try row(Self.nearbyJSON, loc: here)])
        let c = cols(csv.components(separatedBy: "\n")[1])
        XCTAssertEqual(c[10], "32.763243", "sanity: approx_lat is the phone position")
        XCTAssertNotEqual(c[14], c[10], "drone_lat must never mirror approx_lat")
        XCTAssertEqual(c[14], "")
    }

    func testDroneRowKeepsItsBroadcastAndOperatorPositions() throws {
        let csv = BLEManager.buildCSV([try row(Self.droneJSON)])
        let c = cols(csv.components(separatedBy: "\n")[1])
        XCTAssertEqual(c[14], "32.763950", "a real drone must still export its aircraft position")
        XCTAssertEqual(c[15], "-117.114273")
        XCTAssertEqual(c[20], "32.762257", "operator position is the most valuable drone field")
        XCTAssertEqual(c[21], "-117.114303")
    }

    func testDroneObserverPositionIsIndependentOfAircraftPosition() throws {
        // `loc` is where the PHONE heard the drone. The wire lat/lon is where the AIRCRAFT says
        // it is. Both must survive as distinct fields; acquiring one can never be gated on the
        // presence of the other.
        let observer = CLLocationCoordinate2D(latitude: 40.123456, longitude: -70.654321)
        let csv = BLEManager.renderContributionCSV(
            [try row(Self.droneJSON, loc: observer)],
            includeObserverLocation: true,
            includeDroneLocation: true,
            includeOperatorLocation: true)
        let records = try XCTUnwrap(ContributionCsv.parseDocument(csv)?.records)
        XCTAssertEqual(records.count, 2)
        let header = records[0], data = records[1]
        func value(_ name: String) -> String { data[header.firstIndex(of: name)!] }
        XCTAssertEqual(value("approx_lat"), "40.123456")
        XCTAssertEqual(value("approx_lon"), "-70.654321")
        XCTAssertEqual(value("drone_lat"), "32.763950")
        XCTAssertEqual(value("drone_lon"), "-117.114273")
    }

    func testContributionStopUsesUnpublishedLiveLedgerAndMatchingObserverFix() throws {
        // The UI projection is deliberately never published. Stop must still see the manager's
        // capture-local live ledger, and the observer coordinate must be the one paired with this
        // exact sighting rather than a session-wide first/closest position.
        let manager = BLEManager()
        let d = try decode(Self.nearbyJSON.replacingOccurrences(
            of: "c2:40:d8:1c:2b:96", with: "02:aa:bb:cc:dd:01"))
        let start: Int64 = 1_780_000_000_000
        let seen = start + 1_234
        let observer = CLLocationCoordinate2D(latitude: 40.123456, longitude: -70.654321)

        manager.beginContributionCapture(startMs: start)
        manager.testSeedContributionDetection(
            d,
            firstSeen: Date(timeIntervalSince1970: Double(start - 60_000) / 1000),
            lastSeen: Date(timeIntervalSince1970: Double(seen) / 1000),
            observerLocation: observer)
        XCTAssertFalse(manager.detections.contains(where: { $0.id == d.id }),
                       "the regression fixture must not enter the coalesced UI projection")

        let snapshot = manager.finishContributionCapture(startMs: start, stopMs: start + 2_000)
        XCTAssertEqual(snapshot.capturedAtByID, [d.id: seen])
        XCTAssertEqual(snapshot.rows.count, 1)
        XCTAssertEqual(snapshot.rows[0].loc?.latitude, observer.latitude)
        XCTAssertEqual(snapshot.rows[0].loc?.longitude, observer.longitude)
        XCTAssertFalse(snapshot.rows[0].allowDetectionCoordinateFallback)

        let csv = BLEManager.renderContributionCSV(
            snapshot.rows,
            includeObserverLocation: true,
            includeDroneLocation: true,
            includeOperatorLocation: true)
        let records = try XCTUnwrap(ContributionCsv.parseDocument(csv)?.records)
        let header = records[0], data = records[1]
        XCTAssertEqual(data[header.firstIndex(of: "approx_lat")!], "40.123456")
        XCTAssertEqual(data[header.firstIndex(of: "approx_lon")!], "-70.654321")
        XCTAssertEqual(ContributionCsv.dataRowCount(csv), 1)
    }

    func testContributionExcludesReplayOnlyStoreRow() throws {
        // A replay can land in the authoritative session store during a reconnect and carry times
        // that overlap the user's window. It is not a live in-window observation, so it must never
        // receive the contribution's `.exact` timestamp.
        let manager = BLEManager()
        let historyJSON = Self.nearbyJSON
            .replacingOccurrences(of: "c2:40:d8:1c:2b:96", with: "02:aa:bb:cc:dd:02")
            .replacingOccurrences(of: "\"n\":1}", with: "\"n\":1,\"hist\":true,\"seq\":7}")
        let d = try decode(historyJSON)
        XCTAssertTrue(d.isHistory)
        let start: Int64 = 1_780_000_100_000

        manager.beginContributionCapture(startMs: start)
        manager.testSeedContributionDetection(
            d,
            firstSeen: Date(timeIntervalSince1970: Double(start + 100) / 1000),
            lastSeen: Date(timeIntervalSince1970: Double(start + 500) / 1000))
        let snapshot = manager.finishContributionCapture(startMs: start, stopMs: start + 1_000)
        XCTAssertTrue(snapshot.capturedAtByID.isEmpty)
        XCTAssertTrue(snapshot.rows.isEmpty)
    }

    func testContributionWithoutInWindowFixDoesNotFallBackToWireCoordinate() throws {
        // For a non-drone, wire lat/lon may be detector GPS and remains useful in a standard Log
        // export. A bounded contribution timestamp describes one exact live sighting, though, so
        // that fallback is too old/ambiguous when the capture ledger has no matching phone fix.
        let manager = BLEManager()
        let d = try decode(Self.nearbyJSON.replacingOccurrences(
            of: "c2:40:d8:1c:2b:96", with: "02:aa:bb:cc:dd:03"))
        let start: Int64 = 1_780_000_200_000
        manager.beginContributionCapture(startMs: start)
        manager.testSeedContributionDetection(
            d,
            firstSeen: Date(timeIntervalSince1970: Double(start - 5_000) / 1000),
            lastSeen: Date(timeIntervalSince1970: Double(start + 500) / 1000),
            observerLocation: nil)

        let snapshot = manager.finishContributionCapture(startMs: start, stopMs: start + 1_000)
        let csv = BLEManager.renderContributionCSV(
            snapshot.rows,
            includeObserverLocation: true,
            includeDroneLocation: true,
            includeOperatorLocation: true)
        let records = try XCTUnwrap(ContributionCsv.parseDocument(csv)?.records)
        let header = records[0], data = records[1]
        XCTAssertEqual(data[header.firstIndex(of: "approx_lat")!], "")
        XCTAssertEqual(data[header.firstIndex(of: "approx_lon")!], "")

        // The standard-export default is intentionally unchanged.
        let standard = BLEManager.buildCSV([try row(Self.nearbyJSON, loc: nil)])
        let standardRecords = try XCTUnwrap(ContributionCsv.parseDocument(standard)?.records)
        let standardHeader = standardRecords[0], standardData = standardRecords[1]
        XCTAssertEqual(standardData[standardHeader.firstIndex(of: "approx_lat")!], "32.763243")
        XCTAssertEqual(standardData[standardHeader.firstIndex(of: "approx_lon")!], "-117.116077")
    }

    func testStandardExportSnapshotUsesAuthoritativeStoreAndFreezesScope() throws {
        let manager = BLEManager()
        let live = try decode(Self.nearbyJSON.replacingOccurrences(
            of: "c2:40:d8:1c:2b:96", with: "02:aa:bb:cc:ee:01"))
        let offlineJSON = Self.droneJSON
            .replacingOccurrences(of: "60:60:1f:1a:1a:3f", with: "02:aa:bb:cc:ee:02")
            .replacingOccurrences(of: "\"n\":15}", with: "\"n\":15,\"hist\":true,\"seq\":8}")
        let offline = try decode(offlineJSON)
        let now = Date(timeIntervalSince1970: 1_780_001_000)
        manager.testSeedContributionDetection(live, firstSeen: now, lastSeen: now)
        manager.testSeedContributionDetection(offline, firstSeen: now, lastSeen: now)
        XCTAssertTrue(manager.detections.isEmpty,
                      "the fixture must bypass the coalesced SwiftUI projection")

        let frozen = manager.detectionExportSnapshot()
        XCTAssertEqual(frozen.ids, [live.id, offline.id])
        XCTAssertEqual(frozen.filtered(category: nil, unseenOnly: false, offlineOnly: true).ids,
                       [offline.id])
        XCTAssertEqual(frozen.filtered(category: "DRONE", unseenOnly: false, offlineOnly: false).ids,
                       [offline.id])
        XCTAssertEqual(frozen.filtered(category: nil, unseenOnly: true, offlineOnly: false).ids,
                       [live.id, offline.id])
    }

    func testLoneCarriageReturnInUasIdCannotBypassRealEmitterRedaction() throws {
        // A lone CR is a CSV record separator just like LF/CRLF. uas_id precedes every drone and
        // operator location column, so leaving it unquoted lets the apparent row break before the
        // sensitive fields. Exercise BLEManager's real emitter AND redactor, not merely field().
        let json = """
        {"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:40","rssi":-70,\
        "lat":32.763950,"lon":-117.114273,"plat":32.762257,"plon":-117.114303,\
        "alt":208,"id":"UAS\\rSECOND RECORD","n":2}
        """
        let snapshot = [try row(json)]
        let raw = BLEManager.buildCSV(snapshot)
        XCTAssertTrue(raw.contains("\"UAS\rSECOND RECORD\""),
                      "the real emitter must quote a lone carriage return")

        let redacted = BLEManager.renderContributionCSV(
            snapshot,
            includeObserverLocation: false,
            includeDroneLocation: false,
            includeOperatorLocation: false)
        let records = try XCTUnwrap(ContributionCsv.parseDocument(redacted)?.records)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(ContributionCsv.dataRowCount(redacted), 1)
        let header = records[0], data = records[1]
        func value(_ name: String) -> String { data[header.firstIndex(of: name)!] }
        XCTAssertEqual(value("uas_id"), "UAS\rSECOND RECORD")
        for name in ContributionCsv.observerLocationCols
            .union(ContributionCsv.droneLocationCols)
            .union(ContributionCsv.operatorLocationCols) {
            XCTAssertEqual(value(name), "", "\(name) must be blank after real-path redaction")
        }
        XCTAssertEqual(value("altitude_m"), "208", "non-location telemetry still survives")
    }

    func testRealEmitterSerializesEveryCellBeforeLocationRedaction() throws {
        // MAC is protocol-shaped today, but it is intentionally a field the old builder emitted
        // raw. Put comma + CRLF into that cell to prove the production writer does not rely on a
        // hand-picked list of fields that happen to look safe. Every row must remain rectangular,
        // and later location columns must still be found and removed by name.
        let json = Self.droneJSON.replacingOccurrences(
            of: "60:60:1f:1a:1a:3f", with: "MAC,\\r\\nSECOND LINE")
        let snapshot = [try row(json)]
        let raw = BLEManager.buildCSV(snapshot)
        let rawRecords = try XCTUnwrap(ContributionCsv.parseDocument(raw)?.records)
        XCTAssertEqual(rawRecords.count, 2)
        XCTAssertEqual(rawRecords[1].count, rawRecords[0].count)
        XCTAssertEqual(rawRecords[1][4], "MAC,\r\nSECOND LINE")

        let redacted = BLEManager.renderContributionCSV(
            snapshot,
            includeObserverLocation: false,
            includeDroneLocation: false,
            includeOperatorLocation: false)
        let records = try XCTUnwrap(ContributionCsv.parseDocument(redacted)?.records)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[1].count, records[0].count)
        let header = records[0], data = records[1]
        for name in ContributionCsv.observerLocationCols
            .union(ContributionCsv.droneLocationCols)
            .union(ContributionCsv.operatorLocationCols) {
            XCTAssertEqual(data[header.firstIndex(of: name)!], "", "\(name) must be blank")
        }
    }

    func testUntrustedSpreadsheetFormulaTextIsMadeLiteral() throws {
        for value in ["=2+2", "+SUM(A1:A2)", "-1+2", "@cmd", "  \t=HYPERLINK(\"x\")"] {
            XCTAssertEqual(BLEManager.csvUntrustedText(value), "'" + value)
        }
        for value in ["", "safe", "  safe", "1+2"] {
            XCTAssertEqual(BLEManager.csvUntrustedText(value), value)
        }

        let malicious = Self.droneJSON.replacingOccurrences(
            of: "1581F67QC236L014509G", with: "=2+2")
        let csv = BLEManager.buildCSV([try row(malicious)])
        let records = try XCTUnwrap(ContributionCsv.parseDocument(csv)?.records)
        let header = records[0]
        XCTAssertEqual(records[1][header.firstIndex(of: "uas_id")!], "'=2+2")
        XCTAssertEqual(records[1][header.firstIndex(of: "rssi")!], "-86",
                       "numeric evidence must not be rewritten as text")

        let maliciousMaker = #"{"t":10,"s":1,"meth":1,"c":65,"mac":"11:22:33:44:55:66","rssi":-70,"det":"=cmd on wifi","n":1}"#
        XCTAssertEqual(try decode(maliciousMaker).maker, "=cmd")
        let makerCSV = BLEManager.buildCSV([try row(maliciousMaker)])
        let makerRecords = try XCTUnwrap(ContributionCsv.parseDocument(makerCSV)?.records)
        let makerHeader = makerRecords[0]
        XCTAssertEqual(makerRecords[1][makerHeader.firstIndex(of: "maker")!], "'=cmd",
                       "radio-derived maker text must remain literal in spreadsheets")
    }

    func testRepeatedStandardExportsKeepReadableNameButUseUniqueParents() throws {
        // Two share sheets can overlap in time. The second export must not mutate the URL already
        // handed to the first, while the leaf filename should remain useful to the recipient.
        //
        // The snapshot is handed in EXPLICITLY rather than letting the convenience overload build
        // one from the manager's store. That store is whatever the simulator container already
        // holds, so the old form's output rode a race: loadPersistedDetections() hands off to
        // persistQueue and landed AFTER both snapshots, which is the only reason the two files
        // were header-only and the byte-equality assertion below passed by construction. Win that
        // race on a developer machine and the same test writes real captured MACs and GPS out to
        // temporaryDirectory. A fixture row removes both halves: no real user state is read, and
        // there is real content on both sides of the comparison.
        let manager = BLEManager()
        let snapshot = BLEManager.DetectionExportSnapshot(rows: [try row(Self.nearbyJSON)],
                                                          unseenIDs: [])
        let done = expectation(description: "two exports finish")
        done.expectedFulfillmentCount = 2
        var urls: [URL] = []
        for _ in 0..<2 {
            manager.writeDetections(.csv, snapshot: snapshot) { result in
                if case let .success(url) = result { urls.append(url) }
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["acab-detections.csv", "acab-detections.csv"])
        XCTAssertNotEqual(urls[0].deletingLastPathComponent(), urls[1].deletingLastPathComponent())
        XCTAssertEqual(try Data(contentsOf: urls[0]), try Data(contentsOf: urls[1]))

        // No activity owns these test artifacts, so the test may clean up its exact UUID dirs.
        for url in urls { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    }

    // MARK: - GPX

    func testGpxIsWellFormedAndDeclaresTheNamespace() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        XCTAssertTrue(gpx.contains("<gpx version=\"1.1\""))
        XCTAssertTrue(gpx.contains("xmlns=\"http://www.topografix.com/GPX/1/1\""))
        XCTAssertTrue(gpx.hasSuffix("</gpx>"))
        // Parses as XML, not just "looks right".
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// The honesty rule: a non-drone pin is the PHONE, and the file has to say so, because a
    /// mapping app will otherwise render it as the device's location.
    func testNonDroneWaypointIsNamedAsHeardNotAsALocation() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.contains("<name>Heard:"), "non-drone waypoints must be named 'Heard:'")
        XCTAssertTrue(gpx.contains("Position is where the PHONE was, not the device."))
    }

    func testNonDroneEmitsExactlyOneWaypointAtThePhonePosition() throws {
        let here = CLLocationCoordinate2D(latitude: 12.5, longitude: -34.25)
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON, loc: here)])
        XCTAssertEqual(gpx.components(separatedBy: "<wpt ").count - 1, 1)
        XCTAssertTrue(gpx.contains("lat=\"12.500000\" lon=\"-34.250000\""))
        XCTAssertFalse(gpx.contains("broadcast position"), "no aircraft waypoint for a non-drone")
    }

    func testDroneEmitsHeardAircraftAndOperatorWaypoints() throws {
        let gpx = BLEManager.buildGPX([try row(Self.droneJSON)])
        XCTAssertEqual(gpx.components(separatedBy: "<wpt ").count - 1, 3)
        XCTAssertTrue(gpx.contains("<name>Heard:"))
        XCTAssertTrue(gpx.contains("Drone (broadcast position)"))
        XCTAssertTrue(gpx.contains("Drone OPERATOR"))
        XCTAssertTrue(gpx.contains("lat=\"32.763950\" lon=\"-117.114273\""))
        XCTAssertTrue(gpx.contains("lat=\"32.762257\" lon=\"-117.114303\""))
    }

    func testRowWithNoFixEmitsNoWaypoint() throws {
        // A non-drone with no captured location has nothing mappable; a <wpt> without lat/lon is
        // invalid GPX, so the row must be skipped rather than emitted with empty attributes.
        let json = """
        {"t":7,"s":0,"meth":0,"c":0,"mac":"11:22:33:44:55:66","rssi":-70,"n":1}
        """
        let gpx = BLEManager.buildGPX([try row(json, loc: nil)])
        XCTAssertFalse(gpx.contains("<wpt "))
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// A bracketed row has no single instant. GPX <time> can only hold a point, so writing either
    /// end would claim a precision the data does not have; the basis goes in <desc> instead.
    func testBracketedRowOmitsTimeButStatesTheBasis() throws {
        let r = try row(Self.nearbyJSON,
                        basis: .bracketed(after: Date(timeIntervalSince1970: 1_780_000_000),
                                          before: Date(timeIntervalSince1970: 1_780_000_600)))
        let gpx = BLEManager.buildGPX([r])
        XCTAssertFalse(gpx.contains("<time>"), "a bracketed row must not export a point time")
        XCTAssertTrue(gpx.contains("time: bracketed"))
    }

    func testExactRowCarriesATimeElement() throws {
        let gpx = BLEManager.buildGPX([try row(Self.nearbyJSON)])
        XCTAssertTrue(gpx.contains("<time>"))
        XCTAssertTrue(gpx.contains("time: exact"))
    }

    /// Unescaped user/vendor text would produce invalid XML that a mapping app rejects outright.
    func testXmlMetacharactersAreEscaped() throws {
        let gpx = BLEManager.buildGPX([try row(Self.xmlNastyJSON)])
        XCTAssertTrue(gpx.contains("&amp;"))
        XCTAssertTrue(gpx.contains("&lt;tag&gt;"))
        XCTAssertFalse(gpx.contains("<tag>"), "raw markup must not survive into the document")
        // The real assertion: it still parses.
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
    }

    /// Ampersand must be escaped FIRST or the entities introduced by the later replacements get
    /// their own ampersand re-escaped into "&amp;lt;".
    func testAmpersandIsNotDoubleEscaped() throws {
        let gpx = BLEManager.buildGPX([try row(Self.xmlNastyJSON)])
        XCTAssertFalse(gpx.contains("&amp;lt;"), "double-escaped entity: & was replaced after <")
    }

    func testEmptySnapshotIsStillAValidGpxDocument() throws {
        let gpx = BLEManager.buildGPX([])
        XCTAssertTrue(isWellFormedXML(gpx), "GPX must parse as XML")
        XCTAssertFalse(gpx.contains("<wpt "))
    }
}

/// Elided live-notify records must still decode. The firmware trims optional Remote ID fields to
/// fit a small ATT MTU rather than dropping the sighting (see firmware detect_elide.h), so a phone
/// on a 185-MTU link receives records missing any suffix of
/// palt -> hgt -> vspd -> spd -> hdg -> sta -> plat/plon.
/// The parser is written with decodeIfPresent throughout, so this SHOULD hold; the brief asked for
/// a fixture rather than an assumption, and this is it.
final class ElidedRecordTests: XCTestCase {

    private func decode(_ json: String) throws -> Detection {
        try Detection.decodeWireJSON(Data(json.utf8))
    }

    /// Fully populated drone record, then each elision level applied in the documented order.
    private static let levels: [String] = [
        // 0: nothing elided
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"hgt":125,"palt":82,"sta":1,"n":15,"new":true}"#,
        // 1: palt gone
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"hgt":125,"sta":1,"n":15,"new":true}"#,
        // 2: + hgt
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"vspd":1,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 3: + vspd
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"spd":2,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 4: + spd
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"hdg":336,"sta":1,"n":15,"new":true}"#,
        // 5: + hdg
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"sta":1,"n":15,"new":true}"#,
        // 6: + sta
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"plat":32.75,"plon":-117.12,"alt":208,"n":15,"new":true}"#,
        // 7: + plat/plon (maximum elision)
        #"{"t":4,"s":2,"meth":6,"c":99,"mac":"60:60:1f:1a:1a:3f","rssi":-86,"id":"1581F67QC236L014509G","lat":32.76,"lon":-117.11,"alt":208,"n":15,"new":true}"#,
    ]

    func testEveryElisionLevelStillDecodes() throws {
        for (level, json) in Self.levels.enumerated() {
            let d = try decode(json)
            // The mandatory set survives every level, which is the actual promise: the alert still
            // says what it is, how sure, and where.
            XCTAssertEqual(d.type, .drone, "level \(level)")
            XCTAssertEqual(d.mac, "60:60:1f:1a:1a:3f", "level \(level)")
            XCTAssertEqual(d.rssi, -86, "level \(level)")
            XCTAssertEqual(d.confidence, 99, "level \(level)")
            XCTAssertEqual(d.uasID, "1581F67QC236L014509G", "level \(level)")
            XCTAssertNotNil(d.coordinate, "aircraft position must survive level \(level)")
        }
    }

    func testElisionRemovesFieldsInTheDocumentedOrder() throws {
        let full = try decode(Self.levels[0])
        XCTAssertNotNil(full.pilotAlt); XCTAssertNotNil(full.pilotCoordinate)

        XCTAssertNil(try decode(Self.levels[1]).pilotAlt, "palt goes first")
        XCTAssertNotNil(try decode(Self.levels[1]).heightAGL, "hgt is still present at level 1")
        XCTAssertNil(try decode(Self.levels[2]).heightAGL, "hgt goes second")
        XCTAssertNil(try decode(Self.levels[3]).speedV, "vspd goes third")
        XCTAssertNil(try decode(Self.levels[4]).speedH, "spd goes fourth")
        XCTAssertNil(try decode(Self.levels[5]).heading, "hdg goes fifth")
        XCTAssertNil(try decode(Self.levels[6]).ridStatus, "sta goes sixth")
        // Operator position is last on purpose: it is the most actionable optional field.
        XCTAssertNotNil(try decode(Self.levels[6]).pilotCoordinate,
                        "operator position must survive until the final level")
        XCTAssertNil(try decode(Self.levels[7]).pilotCoordinate, "plat/plon goes last")
    }

    /// The non-drone path is 99% of traffic and must be untouched by any of this.
    func testOrdinaryRecordIsUnaffected() throws {
        let d = try decode(#"{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","rssi":-87,"n":1}"#)
        XCTAssertEqual(d.mac, "c2:40:d8:1c:2b:96")
        XCTAssertNil(d.pilotCoordinate)
        XCTAssertNil(d.speedH)
    }

    // MARK: - wire clamps (parity table, shared with AcabBleManagerExportTest.kt)

    /// One legal history row with the field under test appended. The TAILS are the shared half:
    /// AcabBleManagerExportTest.kt builds the same bytes from the same tails and asserts the same
    /// decoded OUTCOME, because a fixture the two platforms pass for different reasons proves
    /// nothing. The two spellings of "no value" differ, and writing both sides is what pins that:
    /// iOS says nil, Android says 0, each its platform's existing absent value.
    ///
    /// None of these values can come off a genuine board - the firmware's slotValid() rejects
    /// seq 0 and 0xFFFFFFFF, and at/ms/boot are uint32 on the wire - so what this table pins is
    /// the behaviour when the peer is NOT a genuine board. That is the case that matters: a
    /// poisoned seq or timestamp is checkpointed to disk and survives relaunch.
    private func clamped(_ tail: String) throws -> Detection {
        try decode(#"{"t":7,"s":0,"meth":0,"c":0,"mac":"c2:40:d8:1c:2b:96","n":1,"hist":true,"#
                   + tail + "}")
    }

    /// The empty-slot sentinels, the sharpest case in the table: one of these riding into the
    /// replay cursor is checkpointed, and the board then never replays another buffered record.
    func testSeqEmptySlotSentinelsNeverBecomeACursor() throws {
        for tail in [#""seq":0"#, #""seq":4294967295"#] {
            let d = try clamped(tail)
            XCTAssertNil(d.seq, "\(tail) must move no cursor")
            XCTAssertTrue(d.isHistory,
                          "\(tail): the record is still received and counted, it just moves no cursor")
        }
    }

    func testSeqOutsideTheUint32WireTypeIsRejectedButALegalSeqSurvives() throws {
        XCTAssertNil(try clamped(#""seq":-1"#).seq)
        XCTAssertNil(try clamped(#""seq":4294967296"#).seq)
        // The guard has to reject the sentinels without swallowing the ordinary case, or the
        // offline buffer stops draining for the opposite reason.
        XCTAssertEqual(try clamped(#""seq":1"#).seq, 1)
        XCTAssertEqual(try clamped(#""seq":4294967294"#).seq, 4_294_967_294)
    }

    /// Out of range is NO TIMESTAMP, never the nearest legal value: pinned to the ceiling it
    /// would present 2106 as a real capture time and widen that boot's anchor bounds to match.
    func testCapturedAtOutsideTheUint32WireTypeIsDroppedNotPinned() throws {
        XCTAssertNil(try clamped(#""at":4294967296"#).capturedAt)
        XCTAssertNil(try clamped(#""at":-1"#).capturedAt)
        XCTAssertNil(try clamped(#""at":1e30"#).capturedAt)
        // Both ends of the legal range still decode.
        XCTAssertEqual(try clamped(#""at":4294967295"#).capturedAt,
                       Date(timeIntervalSince1970: 4_294_967_295))
        XCTAssertEqual(try clamped(#""at":1780000000"#).capturedAt,
                       Date(timeIntervalSince1970: 1_780_000_000))
    }

    /// Uptime and boot session are uint32 too, and they feed the reconstruction that dates every
    /// unanchored record, so they read as absent by the same rule.
    func testUptimeAndBootSessionOutsideTheWireTypeReadAsAbsent() throws {
        let poisoned = try clamped(#""ms":4294967296,"boot":4294967296"#)
        XCTAssertNil(poisoned.whenMs)
        XCTAssertNil(poisoned.bootCount)
        let legal = try clamped(#""ms":1234,"boot":7"#)
        XCTAssertEqual(legal.whenMs, 1234)
        XCTAssertEqual(legal.bootCount, 7)
    }

    /// A fractional JSON number can be numerically inside the uint32 bounds without being a
    /// uint32. Keep this vector beside the other shared wire fixtures. The verdict comes from the
    /// exact raw numeric token for all four fields; JSONDecoder is not an exact boundary because it
    /// can round a precision-hidden fractional tail away. A `.0` spelling is still the same integer.
    func testFractionalUint32WireFieldsReadAsAbsent() throws {
        let fractional = try clamped(#""seq":1.9,"at":1780000000.9,"ms":1234.9,"boot":7.9"#)
        XCTAssertNil(fractional.seq)
        XCTAssertNil(fractional.capturedAt)
        XCTAssertNil(fractional.whenMs)
        XCTAssertNil(fractional.bootCount)

        let integral = try clamped(#""seq":1.0,"at":1780000000.0,"ms":1234.0,"boot":7.0"#)
        XCTAssertEqual(integral.seq, 1)
        XCTAssertEqual(integral.capturedAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(integral.whenMs, 1234)
        XCTAssertEqual(integral.bootCount, 7)
    }

    /// These are the runtime-representative holes in a decoded-number guard. Current Foundation
    /// rounds the first tail into its binary UInt32/Double value, and Decimal-based preflights lose
    /// the second tail beyond their precision. The raw BLE boundary must retain neither value.
    func testPrecisionHiddenFractionalUint32WireFieldsReadAsAbsent() throws {
        let binaryRounded = try clamped(
            #""seq":1.0000000000000000001,"at":1780000000.0000000000000000001,"ms":1234.0000000000000000001,"boot":7.0000000000000000001"#)
        XCTAssertNil(binaryRounded.seq)
        XCTAssertNil(binaryRounded.capturedAt)
        XCTAssertNil(binaryRounded.whenMs)
        XCTAssertNil(binaryRounded.bootCount)

        let beyondDecimal = try clamped(
            #""seq":1.0000000000000000000000000000000000000001,"at":1780000000.0000000000000000000000000000000000000001,"ms":1234.0000000000000000000000000000000000000001,"boot":7.0000000000000000000000000000000000000001"#)
        XCTAssertNil(beyondDecimal.seq)
        XCTAssertNil(beyondDecimal.capturedAt)
        XCTAssertNil(beyondDecimal.whenMs)
        XCTAssertNil(beyondDecimal.bootCount)
    }

    func testMathematicallyIntegralDecimalAndExponentWireSpellingsSurvive() throws {
        let d = try clamped(
            #""seq":10e-1,"at":178000000000e-2,"ms":123400e-2,"boot":7000e-3"#)
        XCTAssertEqual(d.seq, 1)
        XCTAssertEqual(d.capturedAt, Date(timeIntervalSince1970: 1_780_000_000))
        XCTAssertEqual(d.whenMs, 1_234)
        XCTAssertEqual(d.bootCount, 7)

        XCTAssertEqual(try clamped(#""at":4.294967295e9"#).capturedAt,
                       Date(timeIntervalSince1970: 4_294_967_295))
    }

    func testFractionHiddenBehindAnExponentIsRejected() throws {
        let d = try clamped(
            #""seq":100000000000000000001e-20,"at":178000000000000000001e-11,"ms":123400000000000000001e-17,"boot":70000000000000000001e-19"#)
        XCTAssertNil(d.seq)
        XCTAssertNil(d.capturedAt)
        XCTAssertNil(d.whenMs)
        XCTAssertNil(d.bootCount)
    }

    func testHistoryBeginFromUsesTheSameExactTopLevelUint32Boundary() {
        func value(_ token: String) -> UInt32? {
            let json = #"{"hist":"begin","n":1,"from":"# + token + "}"
            return Detection.exactWireUInt32(forKey: "from", in: Data(json.utf8))
        }

        XCTAssertNil(value("1.0000000000000000001"))
        XCTAssertNil(value("1.0000000000000000000000000000000000000001"))
        XCTAssertNil(value("100000000000000000001e-20"))
        XCTAssertEqual(value("15040e-1"), 1_504)
        XCTAssertEqual(value("1504.000"), 1_504)
        XCTAssertNil(value("4294967296"))

        // Only the decoded top-level member counts: keys in strings/nested objects cannot spoof
        // it, an escaped spelling is the same key, and ambiguous duplicates fail closed.
        let escaped = #"{"hist":"begin","fr\u006fm":15040e-1}"#
        XCTAssertEqual(Detection.exactWireUInt32(forKey: "from", in: Data(escaped.utf8)), 1_504)
        let nested = #"{"hist":"begin","note":"\"from\":1504","x":{"from":1504}}"#
        XCTAssertNil(Detection.exactWireUInt32(forKey: "from", in: Data(nested.utf8)))
        let duplicate = #"{"hist":"begin","from":1504,"from":1505}"#
        XCTAssertNil(Detection.exactWireUInt32(forKey: "from", in: Data(duplicate.utf8)))
    }

    func testRssiIsClampedToTheInt16WireType() throws {
        XCTAssertEqual(try clamped(#""rssi":32767"#).rssi, 32_767)
        XCTAssertEqual(try clamped(#""rssi":-32768"#).rssi, -32_768)
        XCTAssertEqual(try clamped(#""rssi":32768"#).rssi, 32_767)
        XCTAssertEqual(try clamped(#""rssi":-32769"#).rssi, -32_768)
        XCTAssertEqual(try clamped(#""rssi":2147483647"#).rssi, 32_767)
        XCTAssertEqual(try clamped(#""rssi":-2147483648"#).rssi, -32_768)
        // Wider than Int32: the value Android's optInt used to NARROW into a negative dBm, i.e.
        // an impossibly close device reported as impossibly far away.
        XCTAssertEqual(try clamped(#""rssi":2147483648"#).rssi, 32_767)
        XCTAssertEqual(try clamped(#""rssi":-87"#).rssi, -87)
    }

    /// Keep RSSI on the same raw-token boundary as Android. Foundation accepts the precision-hidden
    /// fraction below as Int(-87), which would otherwise make the two apps assign different signal
    /// strength and proximity behavior to the same hostile/malformed frame.
    func testRssiRequiresAnExactIntegralNumericWireTokenBeforeClamping() throws {
        for tail in [
            #""rssi":"-87""#,
            #""rssi":-87.5"#,
            #""rssi":-87.0000000000000000001"#,
            #""rssi":null"#,
            #""rssi":true"#,
            #""rssi":9223372036854775808"#,
            #""rssi":1e30"#,
        ] {
            XCTAssertEqual(try clamped(tail).rssi, 0, tail)
        }

        // Decimal/exponent spellings are valid when their mathematical value is exactly integral.
        XCTAssertEqual(try clamped(#""rssi":-87.0"#).rssi, -87)
        XCTAssertEqual(try clamped(#""rssi":-870e-1"#).rssi, -87)
        XCTAssertEqual(try clamped(#""rssi":9223372036854775807"#).rssi, 32_767)
        XCTAssertEqual(try clamped(#""rssi":-9223372036854775808"#).rssi, -32_768)
    }

    /// JSON leaves duplicate-member semantics undefined: Foundation keeps the first RSSI while
    /// Android's general parser keeps the last. The exact scanners therefore make either spelling
    /// absent/0, including an escaped spelling of the same top-level key.
    func testDuplicateRssiFailsClosedIncludingEscapedKeySpellings() throws {
        XCTAssertEqual(try clamped(#""rssi":-87,"rssi":-40"#).rssi, 0)
        XCTAssertEqual(try clamped(#""rssi":-87,"r\u0073si":-40"#).rssi, 0)

        let nested = try clamped(#""rssi":-87,"extra":{"rssi":-40}"#)
        XCTAssertEqual(nested.rssi, -87, "a nested member is not a duplicate top-level RSSI")
    }
}
