import XCTest
@testable import Beacons

/// The BLE JSON contract version (`proto`) and, more importantly, the ABSENCE rule.
///
/// Absence must mean 0 and must read as fully compatible. Every firmware shipped before 2026-08-06
/// omits the key, so a bug here would put a "your firmware needs a newer app" warning in front of
/// every existing user on the day this ships. A fixture rather than a code read, because the
/// failure is silent and lands on people who did nothing wrong.
///
/// The JSON fixture strings are shared verbatim with the Android DeviceStatusProtoTest.
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

    func testBufferHealthFieldsDefaultOffOnEveryFreshStatus() throws {
        let s = try status(#"{"fw":"x","buf":9,"bufon":true}"#)
        XCTAssertFalse(s.bufferSaturated)
        XCTAssertEqual(s.bufferFaults, 0)
        XCTAssertFalse(s.bufferKeyMismatch)
        XCTAssertEqual(s.bufferHealthNotices, [])
    }

    func testKeyMismatchPreservesHistoryAndBecomesAPersistentTransferWarning() throws {
        let s = try status(#"{"fw":"x","buf":9,"keymis":true}"#)
        XCTAssertTrue(s.bufferKeyMismatch)
        XCTAssertEqual(s.bufferHealthNotices, [.keyNotAccepted])
        XCTAssertEqual(
            s.bufferHealthNotices[0].detail,
            "This phone’s buffer key was not accepted. Existing history was preserved and was not replayed. Sync with the originating phone, or explicitly clear the board buffer to transfer."
        )
        XCTAssertTrue(s.bufferHealthNotices[0].critical)
    }

    func testBufferFaultsAndSaturationBecomeOrderedUserVisibleWarnings() throws {
        // WRITE (0x04) and CRYPTO (0x40) make evidence incomplete; NVS (0x20) is historical.
        let s = try status(#"{"fw":"x","bufsat":true,"buferr":100}"#)
        XCTAssertTrue(s.bufferSaturated)
        XCTAssertEqual(s.bufferFaults, 100)
        XCTAssertEqual(s.bufferHealthNotices,
                       [.storageFailed, .capacityReached, .persistenceErrorRecorded])
        XCTAssertTrue(s.bufferHealthNotices[0].detail.contains("storage or encryption failure"))
        XCTAssertTrue(s.bufferHealthNotices[0].detail.contains("may be missing or unavailable"))
        XCTAssertTrue(s.bufferHealthNotices[1].detail.contains("may be missing"))
        XCTAssertTrue(s.bufferHealthNotices[2].detail.contains("metadata save/load error"))
        XCTAssertTrue(s.bufferHealthNotices[2].detail.contains("may already reflect a successful retry"))
        XCTAssertTrue(s.bufferHealthNotices[2].detail.contains("replay timestamps"))
        XCTAssertTrue(s.bufferHealthNotices[2].detail.contains("Clear the board buffer"))
    }

    func testNVSRetryAloneIsNotMislabeledAsRawStorageFailure() throws {
        let s = try status(#"{"fw":"x","buferr":32}"#)
        XCTAssertEqual(s.bufferHealthNotices, [.persistenceErrorRecorded])
    }

    func testFutureUInt32HighFaultBitRemainsFailClosed() throws {
        let s = try status(#"{"fw":"x","buferr":2147483648}"#)
        XCTAssertEqual(s.bufferFaults, 0x8000_0000)
        XCTAssertEqual(s.bufferHealthNotices, [.storageFailed])
    }

    /// A ONE-SIDED pin, and the name now says so. It compares the iOS constant to a literal, so it
    /// cannot see an Android or firmware bump. It was called
    /// testSupportedVersionMatchesTheAndroidConstant, which promised a comparison nothing in the
    /// body performs.
    ///
    /// It still earns its place in the direction it does cover. The contract version has three
    /// copies - ACAB_BLE_PROTO_VERSION (firmware/lib/acab_core/acab_ble_service.h),
    /// SUPPORTED_PROTO_VERSION (android .../model/Models.kt) and this one - and moving the iOS copy
    /// alone fails right here, so nobody moves it without reading the other two off the message.
    ///
    /// The reverse direction is an admitted gap: bump the other two and nothing in the repo fails.
    /// check-signature-drift.py does not look at `proto`, and Android's DeviceStatusProtoTest has
    /// no equivalent pin. Left as a gap on purpose, because that direction is fail-SAFE -
    /// needsNewerApp is `protoVersion > supported` on both platforms, so the app that lagged
    /// over-warns instead of silently misparsing a newer board - and closing it from here would
    /// mean reading Kotlin and C off the filesystem from a suite that is otherwise hermetic.
    func testSupportedVersionIsPinnedSoABumpMustBeDeliberate() {
        XCTAssertEqual(DeviceStatus.supportedProtoVersion, 2,
                       "bumping this means bumping ACAB_BLE_PROTO_VERSION in "
                       + "firmware/lib/acab_core/acab_ble_service.h and SUPPORTED_PROTO_VERSION in "
                       + "android/app/src/main/java/tech/acab/app/model/Models.kt in the same change")
    }
}
