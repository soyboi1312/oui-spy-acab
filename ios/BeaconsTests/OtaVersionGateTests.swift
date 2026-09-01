import XCTest
@testable import Beacons

/// Pins the ASCII-only firmware-version gate. `Character.isNumber` alone accepts every Unicode
/// number (fullwidth digits, Arabic-Indic, Devanagari, Roman numerals, fractions), and the
/// running-version string comes off the board's Status frame, which the threat model treats as
/// attacker-influenced. A spoofed "numeric" version that satisfies the >= compare reaches the
/// confirm write, which disarms bootloader rollback. Mirrors Android's OtaSafetyPolicyTest.
final class OtaVersionGateTests: XCTestCase {

    private func status(version: String) throws -> DeviceStatus {
        let json = #"{"fw":"beacon board \#(version)"}"#
        return try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }

    func testPlainDottedNumericVersionsPass() {
        XCTAssertTrue(BLEManager.isNumericVersion("2"))
        XCTAssertTrue(BLEManager.isNumericVersion("1.7"))
        XCTAssertTrue(BLEManager.isNumericVersion("2.0.0"))
        XCTAssertTrue(BLEManager.isNumericVersion("2.0.4-rc1"))
        XCTAssertTrue(BLEManager.isNumericVersion("2.0.4-rc.1-test"))
        XCTAssertTrue(BLEManager.isNumericVersion("1023.0.0"))
        XCTAssertTrue(BLEManager.isNumericVersion("000000000000000000000000000001"))
    }

    func testNonAsciiDigitsNeverPass() {
        XCTAssertFalse(BLEManager.isNumericVersion("\u{FF12}.\u{FF10}.\u{FF14}"))   // fullwidth 2.0.4
        XCTAssertFalse(BLEManager.isNumericVersion("\u{0662}.\u{0660}.\u{0664}"))   // Arabic-Indic
        XCTAssertFalse(BLEManager.isNumericVersion("\u{0968}.\u{0966}.\u{096A}"))   // Devanagari
        XCTAssertFalse(BLEManager.isNumericVersion("2.\u{FF10}.4"))                 // one smuggled field
        XCTAssertFalse(BLEManager.isNumericVersion("\u{2162}.0.0"))                 // Roman numeral III (No/Nl)
        XCTAssertFalse(BLEManager.isNumericVersion("\u{00BD}"))                     // vulgar fraction 1/2
    }

    func testMalformedShapesNeverPass() {
        XCTAssertFalse(BLEManager.isNumericVersion(""))
        XCTAssertFalse(BLEManager.isNumericVersion("ESP32"))
        XCTAssertFalse(BLEManager.isNumericVersion("2..4"))
        XCTAssertFalse(BLEManager.isNumericVersion("-rc1"))
        XCTAssertFalse(BLEManager.isNumericVersion("1024.0.0"))
        XCTAssertFalse(BLEManager.isNumericVersion("2.0.4.1"))
        XCTAssertFalse(BLEManager.isNumericVersion("0.0.0"))
        XCTAssertFalse(BLEManager.isNumericVersion("2.0.4-"))
        XCTAssertFalse(BLEManager.isNumericVersion("2.0.4-_rc"))
        XCTAssertFalse(BLEManager.isNumericVersion("2.0.4-rc+meta"))
        XCTAssertFalse(BLEManager.isNumericVersion("2.0.4-" + String(repeating: "r", count: 26)))
        // Leading dash: Swift's split omits empty subsequences by default, so "-1" used to yield
        // core "1" and PASS while Android's substringBefore("-") rejected it. Cross-platform
        // parity is the contract; these pin the omittingEmptySubsequences: false fix.
        XCTAssertFalse(BLEManager.isNumericVersion("-1"))
        XCTAssertFalse(BLEManager.isNumericVersion("-2.0.4"))
        XCTAssertFalse(BLEManager.isNumericVersion("--1"))
    }

    func testComparisonUsesThePackedNumericCore() {
        XCTAssertTrue(BLEManager.isFirmwareVersionAtLeast("2", "2.0.0"))
        XCTAssertTrue(BLEManager.isFirmwareVersionAtLeast("2.0.6", "2.0.6-rc1"))
        XCTAssertTrue(BLEManager.isFirmwareVersionAtLeast(
            "000000000000000000000000000001", "1"))
        XCTAssertFalse(BLEManager.isFirmwareVersionAtLeast("2.0.5", "2.0.6"))
        XCTAssertFalse(BLEManager.isFirmwareVersionAtLeast("2.0.1024", "2.0.6"))
    }

    func testOfferGateUsesPackedCoreAndFailsClosed() throws {
        XCTAssertFalse(try status(version: "2.0.6").updateAvailable(latest: "2.0.6-rc1"))
        XCTAssertFalse(try status(version: "2.0.6-rc1").updateAvailable(latest: "2.0.6"))
        XCTAssertTrue(try status(version: "2.0.5").updateAvailable(latest: "2.0.6-rc1"))
        XCTAssertFalse(try status(version: "2.0.5").updateAvailable(latest: "2.0.1024"))
        XCTAssertFalse(try status(version: "ESP32").updateAvailable(latest: "2.0.6"))
    }
}
