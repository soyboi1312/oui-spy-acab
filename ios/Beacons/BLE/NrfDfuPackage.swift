import Foundation

/// Minimal, fail-closed reader for the signed Adafruit legacy-DFU ZIP. The release packager stores
/// manifest.json without compression, so accepting any other ZIP feature would add parser surface
/// without helping a package we publish. Whole-ZIP SHA and signature verification happen before
/// this check; this binds the authenticated inner application_version to the outer update entry.
enum NrfDfuPackage {
    private static let localMagic: UInt32 = 0x04034B50
    private static let centralMagic: UInt32 = 0x02014B50
    private static let endMagic: UInt32 = 0x06054B50
    private static let maxManifestBytes = 64 * 1024
    private static let maxInitPacketBytes = 4 * 1024

    private struct StoredEntry {
        let localOffset: Int
        let length: Int
    }

    static func applicationVersion(in zip: Data) -> UInt32? {
        guard let end = findEnd(in: zip),
              u16(zip, end + 4) == 0, u16(zip, end + 6) == 0,
              let entryCount = u16(zip, end + 10),
              let centralSize32 = u32(zip, end + 12),
              let centralOffset32 = u32(zip, end + 16) else { return nil }
        let centralOffset = Int(centralOffset32)
        let centralSize = Int(centralSize32)
        guard entryCount > 0, range(centralOffset, centralSize, fits: zip.count),
              centralOffset + centralSize <= end else { return nil }

        var cursor = centralOffset
        var manifest: Data?
        var entryNames = Set<String>()
        var storedEntries: [String: StoredEntry] = [:]
        for _ in 0..<entryCount {
            guard u32(zip, cursor) == centralMagic,
                  let flags = u16(zip, cursor + 8),
                  let method = u16(zip, cursor + 10),
                  let compressed32 = u32(zip, cursor + 20),
                  let uncompressed32 = u32(zip, cursor + 24),
                  let nameLength16 = u16(zip, cursor + 28),
                  let extraLength16 = u16(zip, cursor + 30),
                  let commentLength16 = u16(zip, cursor + 32),
                  let localOffset32 = u32(zip, cursor + 42) else { return nil }
            let nameLength = Int(nameLength16)
            let extraLength = Int(extraLength16)
            let commentLength = Int(commentLength16)
            let headerLength = 46
            guard range(cursor, headerLength + nameLength + extraLength + commentLength,
                        fits: zip.count) else { return nil }
            let nameRange = (cursor + headerLength)..<(cursor + headerLength + nameLength)
            guard let name = String(data: zip.subdata(in: nameRange), encoding: .utf8) else {
                return nil
            }
            guard entryNames.insert(name).inserted, flags & 0x1 == 0, method == 0 else {
                return nil
            }
            guard compressed32 == uncompressed32 else { return nil }
            storedEntries[name] = StoredEntry(
                localOffset: Int(localOffset32),
                length: Int(compressed32)
            )
            if name == "manifest.json" {
                guard manifest == nil,
                      uncompressed32 <= UInt32(maxManifestBytes),
                      let payload = storedPayload(
                          zip: zip,
                          localOffset: Int(localOffset32),
                          expectedName: name,
                          length: Int(compressed32)
                      ) else { return nil }
                manifest = payload
            }
            cursor += headerLength + nameLength + extraLength + commentLength
        }
        guard cursor == centralOffset + centralSize, let manifest else { return nil }
        guard let decoded = decodeManifest(manifest), !decoded.hasForbiddenSections,
              !decoded.binFile.isEmpty, !decoded.datFile.isEmpty,
              !decoded.binFile.contains("/"), !decoded.datFile.contains("/"),
              entryNames == ["manifest.json", decoded.binFile, decoded.datFile],
              let initEntry = storedEntries[decoded.datFile],
              initEntry.length > 0, initEntry.length <= maxInitPacketBytes,
              let initPacket = storedPayload(
                  zip: zip,
                  localOffset: initEntry.localOffset,
                  expectedName: decoded.datFile,
                  length: initEntry.length
              ),
              let packetVersion = legacyApplicationVersion(in: initPacket),
              packetVersion == decoded.applicationVersion else { return nil }
        return decoded.applicationVersion
    }

    /// Legacy init packet layout: device type u16, device revision u16, application version u32,
    /// softdevice count u16, that many u16 requirements, then firmware CRC16. The bootloader
    /// consumes this .dat payload, so its version must agree with the authenticated JSON entry.
    private static func legacyApplicationVersion(in data: Data) -> UInt32? {
        guard let requirementCount = u16(data, 8),
              Int(requirementCount) <= (maxInitPacketBytes - 12) / 2,
              data.count == 12 + Int(requirementCount) * 2 else { return nil }
        return u32(data, 4)
    }

    private static func storedPayload(
        zip: Data,
        localOffset: Int,
        expectedName: String,
        length: Int
    ) -> Data? {
        guard u32(zip, localOffset) == localMagic,
              let flags = u16(zip, localOffset + 6), flags & 0x1 == 0,
              u16(zip, localOffset + 8) == 0,
              let nameLength16 = u16(zip, localOffset + 26),
              let extraLength16 = u16(zip, localOffset + 28) else { return nil }
        let nameLength = Int(nameLength16)
        let payloadOffset = localOffset + 30 + nameLength + Int(extraLength16)
        guard range(localOffset, 30 + nameLength + Int(extraLength16), fits: zip.count),
              range(payloadOffset, length, fits: zip.count),
              let localName = String(
                  data: zip.subdata(in: (localOffset + 30)..<(localOffset + 30 + nameLength)),
                  encoding: .utf8
              ), localName == expectedName else { return nil }
        return zip.subdata(in: payloadOffset..<(payloadOffset + length))
    }

    private static func decodeManifest(_ data: Data) -> DecodedManifest? {
        guard let root = try? JSONDecoder().decode(PackageRoot.self, from: data) else { return nil }
        return DecodedManifest(
            applicationVersion: root.manifest.application.initPacketData.applicationVersion,
            binFile: root.manifest.application.binFile,
            datFile: root.manifest.application.datFile,
            hasForbiddenSections: root.manifest.hasForbiddenSections
        )
    }

    private static func findEnd(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let floor = max(0, data.count - 65_557)
        for offset in stride(from: data.count - 22, through: floor, by: -1) {
            if u32(data, offset) == endMagic,
               let commentLength = u16(data, offset + 20),
               offset + 22 + Int(commentLength) == data.count {
                return offset
            }
        }
        return nil
    }

    private static func range(_ offset: Int, _ length: Int, fits count: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }

    private static func u16(_ data: Data, _ offset: Int) -> UInt16? {
        guard range(offset, 2, fits: data.count) else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> UInt32? {
        guard range(offset, 4, fits: data.count) else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private struct PackageRoot: Decodable {
        let manifest: PackageManifest
    }

    private struct PackageManifest: Decodable {
        let application: PackageApplication
        let hasForbiddenSections: Bool

        enum CodingKeys: String, CodingKey {
            case application
            case softdevice
            case bootloader
            case softdeviceBootloader = "softdevice_bootloader"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            application = try container.decode(PackageApplication.self, forKey: .application)
            hasForbiddenSections = container.contains(.softdevice)
                || container.contains(.bootloader)
                || container.contains(.softdeviceBootloader)
        }
    }

    private struct PackageApplication: Decodable {
        let binFile: String
        let datFile: String
        let initPacketData: InitPacket

        enum CodingKeys: String, CodingKey {
            case binFile = "bin_file"
            case datFile = "dat_file"
            case initPacketData = "init_packet_data"
        }
    }

    private struct InitPacket: Decodable {
        let applicationVersion: UInt32

        enum CodingKeys: String, CodingKey {
            case applicationVersion = "application_version"
        }
    }

    private struct DecodedManifest {
        let applicationVersion: UInt32
        let binFile: String
        let datFile: String
        let hasForbiddenSections: Bool
    }
}
