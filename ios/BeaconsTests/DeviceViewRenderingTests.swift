import SwiftUI
import UIKit
import XCTest
@testable import Beacons

@MainActor
final class DeviceViewRenderingTests: XCTestCase {
    func testKeyMismatchKeepsBoardClearActionAvailableWhenBufferingIsOff() {
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 0,
            keyMismatch: true, wiping: false))
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 3,
            keyMismatch: false, wiping: false))
        XCTAssertTrue(shouldOfferBufferClear(
            isDemoMode: false, bufferOn: false, bufferedCount: 0,
            keyMismatch: false, wiping: true))
        XCTAssertFalse(shouldOfferBufferClear(
            isDemoMode: true, bufferOn: true, bufferedCount: 3,
            keyMismatch: true, wiping: true))
    }

    func testKeyMismatchClearConfirmationNeverClaimsZeroMeansNothingIsRetained() {
        let mismatch = bufferClearConfirmationCopy(bufferedCount: 0, keyMismatch: true)
        XCTAssertTrue(mismatch.title.contains("retained offline history"))
        XCTAssertFalse(mismatch.title.contains("0 buffered"))
        XCTAssertTrue(mismatch.message.contains("only readable by the originating phone"))
        XCTAssertTrue(mismatch.message.contains("permanently lost"))

        let ordinary = bufferClearConfirmationCopy(bufferedCount: 3, keyMismatch: false)
        XCTAssertEqual(ordinary.title, "Erase 3 buffered detections on the board?")
        XCTAssertTrue(ordinary.message.contains("already synced to this phone stay"))
    }


    /// DeviceView previously crashed while Swift resolved the concrete metadata for its combined
    /// disclosure panel. Mounting the view is the regression assertion because that failure occurs
    /// before the first frame is drawn or any disclosure row is opened.
    func testDeviceViewMaterializesWithoutMetadataCrash() {
        let root = DeviceView()
            .environmentObject(BLEManager.shared)
            .environmentObject(FirmwareManifestStore.shared)

        let host = UIHostingController(rootView: root)
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()

        XCTAssertEqual(host.view.bounds.size, CGSize(width: 390, height: 844))
    }
}
