import XCTest
@testable import Beacons

final class NrfDfuPackageTests: XCTestCase {
    func testReadsBoundApplicationVersionFromStoredManifest() {
        XCTAssertEqual(NrfDfuPackage.applicationVersion(in: package(version: 7)), 7)
        XCTAssertNotEqual(NrfDfuPackage.applicationVersion(in: package(version: 7)), 8)
    }

    func testRejectsInitPacketVersionMismatchOrMalformedLayout() {
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(version: 7, packetVersion: 8)))
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("firmware.bin", Data([1]), 0),
            ("manifest.json", body(7), 0),
            ("firmware.dat", Data([0, 1, 2, 3, 7, 0, 0, 0]), 0),
        ])))
    }

    func testRejectsMissingDuplicateAndCompressedManifestEntries() {
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [("other.json", body(7), 0)])))
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("manifest.json", body(7), 0),
            ("manifest.json", body(7), 0),
        ])))
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("manifest.json", body(7), 8),
        ])))
    }

    func testRejectsMalformedOrOutOfRangeVersion() {
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("manifest.json", Data("{}".utf8), 0),
        ])))
        let tooLarge = Data("{\"manifest\":{\"application\":{\"init_packet_data\":{\"application_version\":4294967296}}}}".utf8)
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("manifest.json", tooLarge, 0),
        ])))
    }

    func testRejectsBootloaderOrSoftDevicePayloads() {
        let mixed = Data("{\"manifest\":{\"application\":{\"bin_file\":\"firmware.bin\",\"dat_file\":\"firmware.dat\",\"init_packet_data\":{\"application_version\":7}},\"bootloader\":{}}}".utf8)
        XCTAssertNil(NrfDfuPackage.applicationVersion(in: package(entries: [
            ("firmware.bin", Data([1]), 0),
            ("firmware.dat", Data([2]), 0),
            ("manifest.json", mixed, 0),
        ])))
    }

    private func body(_ version: UInt32) -> Data {
        Data("{\"manifest\":{\"application\":{\"bin_file\":\"firmware.bin\",\"dat_file\":\"firmware.dat\",\"init_packet_data\":{\"application_version\":\(version)}}}}".utf8)
    }

    private func package(version: UInt32, packetVersion: UInt32? = nil) -> Data {
        package(entries: [
            ("firmware.bin", Data([1, 2, 3]), 0),
            ("manifest.json", body(version), 0),
            ("firmware.dat", initPacket(version: packetVersion ?? version), 0),
        ])
    }

    private func initPacket(version: UInt32) -> Data {
        var data = Data()
        data.appendLE(UInt16(82))
        data.appendLE(UInt16.max)
        data.appendLE(version)
        data.appendLE(UInt16(1))
        data.appendLE(UInt16(0xfffe))
        data.appendLE(UInt16(0))
        return data
    }

    /// Small stored-entry ZIP fixture. CRC fields are deliberately zero because the production
    /// parser binds structure/version after the whole ZIP's SHA and signature have passed.
    private func package(entries: [(String, Data, UInt16)]) -> Data {
        var zip = Data()
        var central: [(name: String, body: Data, method: UInt16, offset: UInt32)] = []
        for entry in entries {
            let offset = UInt32(zip.count)
            let name = Data(entry.0.utf8)
            zip.appendLE(UInt32(0x04034B50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(0))
            zip.appendLE(entry.2); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0))
            zip.appendLE(UInt32(entry.1.count)); zip.appendLE(UInt32(entry.1.count))
            zip.appendLE(UInt16(name.count)); zip.appendLE(UInt16(0)); zip.append(name); zip.append(entry.1)
            central.append((entry.0, entry.1, entry.2, offset))
        }
        let centralOffset = UInt32(zip.count)
        for entry in central {
            let name = Data(entry.name.utf8)
            zip.appendLE(UInt32(0x02014B50)); zip.appendLE(UInt16(20)); zip.appendLE(UInt16(20))
            zip.appendLE(UInt16(0)); zip.appendLE(entry.method); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
            zip.appendLE(UInt32(0)); zip.appendLE(UInt32(entry.body.count)); zip.appendLE(UInt32(entry.body.count))
            zip.appendLE(UInt16(name.count)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
            zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0)); zip.appendLE(UInt32(0)); zip.appendLE(entry.offset)
            zip.append(name)
        }
        let centralSize = UInt32(zip.count) - centralOffset
        zip.appendLE(UInt32(0x06054B50)); zip.appendLE(UInt16(0)); zip.appendLE(UInt16(0))
        zip.appendLE(UInt16(central.count)); zip.appendLE(UInt16(central.count))
        zip.appendLE(centralSize); zip.appendLE(centralOffset); zip.appendLE(UInt16(0))
        return zip
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
    }

    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }
}
