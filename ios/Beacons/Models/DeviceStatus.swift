import Foundation

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
    let buzzer: Bool         // master audio on/off
    let volume: Int          // buzzer loudness, 0...100
    let ledEnabled: Bool     // onboard LED / idle heartbeat on ("ledon"; absent = on, the default)
    let gps: Bool
    let bufCount: Int        // detections currently buffered on the board ("buf")
    let bufferingOn: Bool    // offline buffering enabled ("bufon")
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
        case buf, bufon  // offline buffer: stored count + enabled flag
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

extension DeviceStatus {
    /// Latest BEACON-BOARD firmware this app ships against: the OFFLINE FALLBACK when we have no
    /// manifest, and the default compare target. The live "update available" nudge comes from the
    /// firmware manifest (see FirmwareManifestStore); bump this on a beacon-board release so the
    /// offline path still matches. The Colonel Panic single-board builds (oui-spy / mesh-detect)
    /// track a separate line now that the beacon board has moved ahead - see colonelLatestVersion.
    static let latestVersion = "2.0.5"

    /// Latest firmware for the Colonel Panic single-board builds, which stayed on the shared
    /// acab_version.h default when the beacon board diverged. Offline fallback only; bump on a
    /// Colonel Panic release.
    static let colonelLatestVersion = "2.0.5"

    /// Just the version number out of `fw` ("ACAB-ouispy 0.1.0" -> "0.1.0").
    var version: String { firmware.split(separator: " ").last.map(String.init) ?? firmware }

    /// `fw` with the trailing version stripped ("beacon board 1.7" -> "beacon board").
    var firmwareLabel: String {
        let parts = firmware.split(separator: " ")
        return parts.count > 1 ? parts.dropLast().joined(separator: " ") : firmware
    }

    /// True for a Mesh-Detect board (no buzzer; its fw label starts "mesh-detect").
    var isMeshDetect: Bool { firmware.hasPrefix("mesh-detect") }

    /// Installed firmware strictly older than `latest`, compared numerically field-wise
    /// ("1.7" < "1.10" < "2.0.0"). Pass the manifest's version for this board so the nudge
    /// tracks the live manifest; the argument defaults to the offline fallback constant so
    /// existing call sites keep working.
    func updateAvailable(latest: String = DeviceStatus.latestVersion) -> Bool {
        version.compare(latest, options: .numeric) == .orderedAscending
    }

    /// Offline-fallback update check (manifest not consulted). Kept as a convenience for any
    /// call site that has no manifest handy; the UI routes through `updateAvailable(latest:)`.
    var updateAvailable: Bool { updateAvailable(latest: Self.latestVersion) }
}
