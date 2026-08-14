import XCTest
@testable import Beacons

final class FirmwareDownloadPolicyTests: XCTestCase {
    func testOnlyExactSoyboiHttpsFirmwareURLsAreAllowed() {
        XCTAssertTrue(FirmwareDownloadPolicy.permits(
            URL(string: "https://soyboi.tech/firmware/beacon-app.bin")))
        XCTAssertTrue(FirmwareDownloadPolicy.permits(
            URL(string: "https://soyboi.tech:443/firmware/beacon-nrf-dfu.zip")))
        XCTAssertFalse(FirmwareDownloadPolicy.permits(
            URL(string: "http://soyboi.tech/firmware/beacon-app.bin")))
        XCTAssertFalse(FirmwareDownloadPolicy.permits(
            URL(string: "https://cdn.example/firmware/beacon-app.bin")))
        XCTAssertFalse(FirmwareDownloadPolicy.permits(
            URL(string: "https://soyboi.tech.evil.example/firmware/beacon-app.bin")))
        XCTAssertFalse(FirmwareDownloadPolicy.permits(
            URL(string: "https://user@soyboi.tech/firmware/beacon-app.bin")))
    }
}
