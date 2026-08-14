import XCTest
@testable import Beacons

/// The BLE JSON contract version (`proto`) and, more importantly, the ABSENCE rule.
///
/// Absence must mean 0 and must read as fully compatible. Every firmware shipped before 2026-08-06
/// omits the key, so a bug here would put a "your firmware needs a newer app" warning in front of
/// every existing user on the day this ships. A fixture rather than a code read, because the
/// failure is silent and lands on people who did nothing wrong.
///
/// The three JSON strings are shared verbatim with the Android DeviceStatusProtoTest.
final class DeviceStatusProtoTests: XCTestCase {

    private func status(_ json: String) throws -> DeviceStatus {
        try JSONDecoder().decode(DeviceStatus.self, from: Data(json.utf8))
    }

    func testMissingProtoReadsAsZeroAndIsCompatible() throws {
        let s = try status(#"{"fw":"beacon board 2.0.3","up":10,"total":0}"#)
        XCTAssertEqual(s.protoVersion, 0)
        XCTAssertFalse(s.needsNewerApp, "older firmware must never demand a newer app")
    }

    func testProtoBelowSupportedIsCompatible() throws {
        let s = try status(#"{"fw":"beacon board 2.0.4","proto":1}"#)
        XCTAssertEqual(s.protoVersion, 1)
        XCTAssertFalse(s.needsNewerApp)
    }

    func testProtoEqualToSupportedIsCompatible() throws {
        let s = try status(#"{"fw":"beacon board 2.0.5","proto":2,"bodycam":true}"#)
        XCTAssertEqual(s.protoVersion, 2)
        XCTAssertFalse(s.needsNewerApp)
        XCTAssertTrue(s.axon, "the v2 bodycam alias must land on the body-cam field")
    }

    func testProtoGreaterThanSupportedAsksForANewerApp() throws {
        let s = try status(#"{"fw":"beacon board 9.9.9","proto":99}"#)
        XCTAssertEqual(s.protoVersion, 99)
        XCTAssertTrue(s.needsNewerApp, "a board on a newer contract must not be silently misparsed")
    }

    /// Unknown keys must stay harmless: that is what makes an ADDITIVE contract change safe, and is
    /// exactly why `proto` should only ever move for a BREAKING one.
    func testUnknownKeysAreIgnored() throws {
        let s = try status(#"{"fw":"x","proto":1,"somethingNew":true,"sdrop":4,"nElide":2}"#)
        XCTAssertEqual(s.protoVersion, 1)
        XCTAssertFalse(s.needsNewerApp)
        XCTAssertEqual(s.firmware, "x")
    }

    /// Both platforms must agree on the supported version, or one will warn where the other does not.
    func testSupportedVersionMatchesTheAndroidConstant() {
        XCTAssertEqual(DeviceStatus.supportedProtoVersion, 2,
                       "must equal DeviceStatus.SUPPORTED_PROTO_VERSION in Android Models.kt")
    }
}
