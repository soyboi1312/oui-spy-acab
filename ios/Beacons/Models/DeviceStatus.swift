import Foundation

/// One firmware-version policy for offer, install and post-reboot confirmation. The board packs
/// only the numeric core, so suffixes never make an otherwise-equal image newer.
enum FirmwareVersionPolicy {
    static func isValid(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 31 else { return false }
        let pieces = value.split(separator: "-", maxSplits: 1,
                                 omittingEmptySubsequences: false)
        guard let core = pieces.first, !core.isEmpty else { return false }

        if pieces.count == 2 {
            let suffix = pieces[1]
            guard let first = suffix.utf8.first, isASCIIAlphaNumeric(first),
                  suffix.utf8.allSatisfy({ isASCIIAlphaNumeric($0) || $0 == 0x2D || $0 == 0x2E })
            else { return false }
        }

        let fields = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return false }
        var anyNonzero = false
        for field in fields {
            guard !field.isEmpty, field.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let number = UInt64(field), number <= 1023 else { return false }
            anyNonzero = anyNonzero || number != 0
        }
        return anyNonzero
    }

    static func isAtLeast(_ have: String, _ want: String) -> Bool {
        guard isValid(have), isValid(want) else { return false }
        func fields(_ value: String) -> [UInt64] {
            let core = value.split(separator: "-", maxSplits: 1).first ?? Substring(value)
            return core.split(separator: ".").compactMap { UInt64(String($0)) }
        }
        let current = fields(have)
        let target = fields(want)
        for index in 0..<max(current.count, target.count) {
            let lhs = index < current.count ? current[index] : 0
            let rhs = index < target.count ? target[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return true
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
            || (byte >= 0x61 && byte <= 0x7A)
    }
}

/// Device status from the Status characteristic (read + notify).
/// JSON keys live in docs/ble-protocol.md.
struct DeviceStatus: Equatable {
    let firmware: String     // "fw"
    let uptime: Int          // seconds ("up")
    let total: Int           // detections this session
    let ble: Bool
    let wifi: Bool
    let wifiEco: Int         // WiFi eco sleep, seconds between sweeps (0/3/7/15); 0 = continuous
    let flock: Bool          // ALPR (Flock) detector enabled
    let drone: Bool          // drone (remote ID) detector enabled
    let droui: Bool          // drone vendor-OUI FALLBACK enabled ("droui"). Sub-option of `drone`:
                             // when on, a DJI/Parrot OUI with no Remote ID is flagged too. OFF by
                             // default because a stationary Parrot gadget can't be told from a drone,
                             // so it's a false-positive source; the RID path stays on regardless.
    let axon: Bool           // body-cam (Axon) detector enabled
    let tracker: Bool        // BLE item-tracker detector enabled
    let glasses: Bool        // recording / smart-glasses detector enabled
    let ncam: Bool           // network-camera (branded IP-camera OUI on WiFi) detector enabled ("ncam").
                             // OFF by default, exactly like the drone-OUI opt-in: catching it needs the
                             // 802.11 DATA-frame source-MAC path, which stays disabled unless opted in.
    let buzzer: Bool         // detection/session alert audio on/off; physical power cues are independent
    let volume: Int          // buzzer loudness, 0...100
    let ledEnabled: Bool     // onboard LED / idle heartbeat on ("ledon"; absent = on, the default)
    let gps: Bool
    let bufCount: Int        // detections currently buffered on the board ("buf")
    let bufferingOn: Bool    // offline buffering enabled ("bufon")
    /// Stationary/record-all capture reached the raw-ring capacity. Sent only while true and
    /// retained until a successful clear; absence on each fresh frame therefore means false.
    let bufferSaturated: Bool
    /// Latched offline-buffer fault mask ("buferr"). Bits 0x01...0x10 are raw-ring failures,
    /// 0x20 is an offline-buffer metadata load/save failure (generation, anchors, privacy lifecycle,
    /// and diagnostic state), and 0x40 is a cryptography failure. Firmware retries eligible work,
    /// but these historical bits remain set until a successful physical clear.
    let bufferFaults: Int
    /// The authenticated phone offered a durable buffer key that does not match the key protecting
    /// this nonempty history generation. Replay is denied and history is preserved. The firmware
    /// emits `keymis:true` only for that authenticated session; absence means false.
    let bufferKeyMismatch: Bool
    let desertMode: Bool     // Desert mode enabled ("desert")
    let ignoreCount: Int     // entries on the board's ignore list ("ign")
    let watchCount: Int      // entries on the board's watch list ("wat")
    let battery: Int?        // battery %, nil unless the board has a sense divider ("bat")
    let coproc: Bool?        // co-processor (nRF) alive on dual-radio boards ("co"); nil = single-radio / unknown
    let nrfUpdating: Bool?   // nRF is in its BLE-DFU window ("nrfup"); the board only emits it while
                             // true, so nil/false = not updating. `co` legitimately reads false for
                             // the whole window (the co-processor is in its bootloader, not answering
                             // UART), and without this the app cried radio fault over a healthy update.
    let nrfVersion: Int?     // running nRF co-processor app version ("nrfv"), a small monotonic int
                             // (NRF_APP_VERSION); nil when absent (single-radio boards, or the co-
                             // processor hasn't reported yet). Compared against the manifest's
                             // nrf.version to decide whether a co-processor update is available.
    let charging: Bool       // battery charging, VBAT sustained high ("chg"); absent = not charging
    let boardRev: String?    // carrier revision the board reports ("A" = the first 250, slide
                             // switch; "B" = button power + VBUS sense). nil on firmware older than
                             // 2026-07-28 and on single-radio builds, which never emit it.

    /// BLE JSON contract version the board reports; 0 when the firmware predates the key.
    let protoVersion: Int

    /// The newest contract this build knows how to parse. Raise it in the SAME commit that teaches
    /// the app that contract, never ahead of it.
    static let supportedProtoVersion = 2

    /// True when the BOARD speaks a newer contract than this app understands. The honest response
    /// is to say so and stop trusting the parse, rather than keep reading fields whose meaning may
    /// have changed underneath. Mirrors the firmware-update nudge, pointed the other way.
    var needsNewerApp: Bool { protoVersion > DeviceStatus.supportedProtoVersion }

    var uptimeText: String {
        let h = uptime / 3600, m = (uptime % 3600) / 60, s = uptime % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

extension DeviceStatus: Decodable {
    enum CodingKeys: String, CodingKey {
        case fw, up, total, ble, wifi, wifiEco, flock, drone, axon, tracker, glasses, buzzer, gps
        case bodycam     // clearer alias for `axon` (ble-protocol.md prefers it); today's firmware
                         // still EMITS only `axon`, so read bodycam first and fall back, exactly
                         // as Android does, so a firmware-side rename cannot strand this app
        case droui       // drone vendor-OUI fallback enabled; absent = off (the default)
        case ncam        // network-camera detector enabled; absent = off (the default)
        case vol         // firmware sends "vol"; we call it `volume`
        case ledon       // onboard LED master; the board omits it when on, so absent = on
        case buf, bufon, bufsat, buferr, keymis  // offline buffer state, faults and key mismatch
        case desert      // Desert mode (report every device)
        case ign         // board ignore-list count
        case wat         // board watch-list count
        case bat         // battery %, sense-divider boards only
        case co          // co-processor (nRF) alive, dual-radio boards only; absent on single-radio
        case nrfup       // nRF BLE-DFU in progress; the board emits it only while true
        case nrfv        // running nRF co-processor version (int); absent until the co-proc reports
        case chg         // battery charging flag
        case rev         // carrier revision, "A" or "B"; absent on older/single-radio firmware
        case proto       // BLE JSON contract version; ABSENT MEANS 0 (see protoVersion)
    }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        // ABSENT MEANS 0, not unknown. Every firmware shipped before 2026-08-06 omits this key and
        // is fully compatible with this app, so a missing key must read as "fine", never as a
        // warning. Only a board reporting a HIGHER proto than this app understands is a problem.
        protoVersion = (try? k.decode(Int.self, forKey: .proto)) ?? 0
        firmware = (try? k.decode(String.self, forKey: .fw)) ?? "ESP32"
        uptime   = (try? k.decode(Int.self, forKey: .up)) ?? 0
        total    = (try? k.decode(Int.self, forKey: .total)) ?? 0
        ble      = (try? k.decode(Bool.self, forKey: .ble)) ?? false
        wifi     = (try? k.decode(Bool.self, forKey: .wifi)) ?? false
        wifiEco  = (try? k.decode(Int.self,  forKey: .wifiEco)) ?? 0
        flock    = (try? k.decode(Bool.self, forKey: .flock)) ?? true   // default on, absent = on like glasses
        drone    = (try? k.decode(Bool.self, forKey: .drone)) ?? true   // default on, absent = on like glasses
        droui    = (try? k.decode(Bool.self, forKey: .droui)) ?? false  // default OFF, absent = off like axon
        axon     = (try? k.decode(Bool.self, forKey: .bodycam))
                ?? (try? k.decode(Bool.self, forKey: .axon)) ?? false
        tracker  = (try? k.decode(Bool.self, forKey: .tracker)) ?? false
        glasses  = (try? k.decode(Bool.self, forKey: .glasses)) ?? true   // default on, like the body-cam detector
        ncam     = (try? k.decode(Bool.self, forKey: .ncam)) ?? false  // default OFF, absent = off like droui
        buzzer   = (try? k.decode(Bool.self, forKey: .buzzer)) ?? false
        volume   = (try? k.decode(Int.self, forKey: .vol)) ?? 80
        ledEnabled = (try? k.decode(Bool.self, forKey: .ledon)) ?? true   // absent = on (default)
        gps      = (try? k.decode(Bool.self, forKey: .gps)) ?? false
        bufCount    = (try? k.decode(Int.self, forKey: .buf)) ?? 0
        bufferingOn = (try? k.decode(Bool.self, forKey: .bufon)) ?? false
        bufferSaturated = (try? k.decode(Bool.self, forKey: .bufsat)) ?? false
        bufferFaults = max(0, (try? k.decode(Int.self, forKey: .buferr)) ?? 0)
        bufferKeyMismatch = (try? k.decode(Bool.self, forKey: .keymis)) ?? false
        desertMode  = (try? k.decode(Bool.self, forKey: .desert)) ?? false
        ignoreCount = (try? k.decode(Int.self, forKey: .ign)) ?? 0
        watchCount  = (try? k.decode(Int.self, forKey: .wat)) ?? 0
        battery     = try? k.decode(Int.self, forKey: .bat)   // nil when the key is absent
        coproc      = try? k.decode(Bool.self, forKey: .co)    // nil when absent (single-radio boards omit it)
        nrfUpdating = try? k.decode(Bool.self, forKey: .nrfup) // nil when absent (emitted only during a DFU window)
        nrfVersion  = try? k.decode(Int.self, forKey: .nrfv)  // nil when absent (single-radio, or not yet reported)
        charging    = (try? k.decode(Bool.self, forKey: .chg)) ?? false   // absent = not charging
        boardRev    = try? k.decode(String.self, forKey: .rev)  // nil when absent; DO NOT default to
                                                                // "A" - "we were not told" and "this
                                                                // is a rev-A board" must stay
                                                                // distinguishable to the OTA gate.
    }
}

/// A user-visible consequence of the board's offline-buffer health fields. Keeping this policy
/// beside the decoded status makes the Logbook and board control show the same ordered warnings.
enum BufferHealthNotice: Hashable {
    case keyNotAccepted
    case storageFailed
    case capacityReached
    case persistenceErrorRecorded

    var title: String {
        switch self {
        case .keyNotAccepted: return "BUFFER KEY NOT ACCEPTED"
        case .storageFailed: return "OFFLINE LOG INCOMPLETE"
        case .capacityReached: return "CAPTURE REACHED CAPACITY"
        case .persistenceErrorRecorded: return "BUFFER METADATA ERROR RECORDED"
        }
    }

    var detail: String {
        switch self {
        case .keyNotAccepted:
            return "This phone’s buffer key was not accepted. Existing history was preserved and was not replayed. Sync with the originating phone, or explicitly clear the board buffer to transfer."
        case .storageFailed:
            return "Offline logging encountered a storage or encryption failure. Some offline detections may be missing or unavailable. Clear the offline buffer after reviewing or exporting it to reset this warning."
        case .capacityReached:
            return "Stationary capture filled the board. Later nearby detections may be missing. Export what synced, then clear the board buffer before another deployment."
        case .persistenceErrorRecorded:
            return "The board recorded an offline-buffer metadata save/load error. Current status may already reflect a successful retry; confirm buffer state and replay timestamps before relying on them. Clear the board buffer to reset this warning."
        }
    }

    var critical: Bool { self == .storageFailed || self == .keyNotAccepted }
}

extension DeviceStatus {
    /// Most severe first. Unknown future non-NVS bits surface as a storage failure instead of
    /// disappearing; a newer board can independently raise the protocol-version warning.
    var bufferHealthNotices: [BufferHealthNotice] {
        var result: [BufferHealthNotice] = []
        if bufferKeyMismatch { result.append(.keyNotAccepted) }
        if bufferFaults & ~0x20 != 0 { result.append(.storageFailed) }
        if bufferSaturated { result.append(.capacityReached) }
        if bufferFaults & 0x20 != 0 { result.append(.persistenceErrorRecorded) }
        return result
    }
}

extension DeviceStatus {
    /// Latest BEACON-BOARD firmware this app ships against: the OFFLINE FALLBACK when we have no
    /// manifest, and the default compare target. The live "update available" nudge comes from the
    /// firmware manifest (see FirmwareManifestStore); bump this on a beacon-board release so the
    /// offline path still matches. The Colonel Panic single-board builds (oui-spy / mesh-detect)
    /// track a separate line now that the beacon board has moved ahead - see colonelLatestVersion.
    static let latestVersion = "2.0.7"

    /// Latest firmware for the Colonel Panic single-board builds, which stayed on the shared
    /// acab_version.h default when the beacon board diverged. Offline fallback only; bump on a
    /// Colonel Panic release.
    static let colonelLatestVersion = "2.0.7"

    /// Just the version number out of `fw` ("ACAB-ouispy 0.1.0" -> "0.1.0").
    var version: String { firmware.split(separator: " ").last.map(String.init) ?? firmware }

    /// `fw` with the trailing version stripped ("beacon board 1.7" -> "beacon board").
    var firmwareLabel: String {
        let parts = firmware.split(separator: " ")
        return parts.count > 1 ? parts.dropLast().joined(separator: " ") : firmware
    }

    /// True for a Mesh-Detect board (no buzzer; its fw label starts "mesh-detect").
    var isMeshDetect: Bool { firmware.hasPrefix("mesh-detect") }

    /// Installed firmware strictly older than `latest`, using the exact validated numeric core
    /// the board packs. A suffix does not make an equal core newer, and malformed input fails
    /// closed instead of presenting an update that the board can only reject.
    func updateAvailable(latest: String = DeviceStatus.latestVersion) -> Bool {
        FirmwareVersionPolicy.isValid(version) && FirmwareVersionPolicy.isValid(latest)
            && !FirmwareVersionPolicy.isAtLeast(version, latest)
    }

    /// Offline-fallback update check (manifest not consulted). Kept as a convenience for any
    /// call site that has no manifest handy; the UI routes through `updateAvailable(latest:)`.
    var updateAvailable: Bool { updateAvailable(latest: Self.latestVersion) }
}
