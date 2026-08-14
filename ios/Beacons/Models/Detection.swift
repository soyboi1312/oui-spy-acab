import Foundation
import CoreLocation

/// One detection event, decoded from a Detections-characteristic notify.
/// JSON shape and keys live in docs/ble-protocol.md.
struct Detection: Identifiable, Equatable {
    let type: DeviceType
    let source: DetectionSource
    let method: DetectionMethod
    let confidence: Int          // 0...100
    let mac: String
    let rssi: Int

    let name: String?            // advertised name
    let uasID: String?           // RID serial / operator id  (json "id")
    let detail: String?          // raven fw, ssid, op-id, etc. (json "det")
    let companyId: Int?          // BLE mfg company ID, SIG assigned # (json "cid"); nil for WiFi / no mfg data

    let lat: Double?
    let lon: Double?
    let pilotLat: Double?        // json "plat"
    let pilotLon: Double?        // json "plon"
    let altitude: Int?           // metres MSL (drones)
    let gpsAgeSec: Int?          // age (s) of the phone fix used for lat/lon (json "gage"; offline/Desert)

    // Drone Remote ID flight telemetry (drones only; nil when not broadcast).
    let speedH: Int?             // horizontal speed m/s   (json "spd")
    let speedV: Int?             // vertical speed m/s     (json "vspd")
    let heading: Int?            // track direction deg    (json "hdg")
    let heightAGL: Int?          // height above takeoff m (json "hgt")
    let pilotAlt: Int?           // operator altitude m    (json "palt")
    let ridStatus: Int?          // ODID op status         (json "sta")

    let count: Int               // sightings this session (json "n")
    let isNew: Bool              // first sighting in the dedup window (json "new")
    let randomAddr: Bool         // transmitter address is randomized / locally-administered (json "rnd")

    // Offline-buffer replay fields (only set on a history drain; nil/false live).
    let isHistory: Bool          // a replayed buffered record (json "hist")
    let seq: UInt32?             // the board's buffer sequence number (json "seq")
    let capturedAt: Date?        // when the board actually saw it, unix secs (json "at")
    let approx: Bool             // timestamp unknown; only ordering is meaningful (json "approx")
    // The raw inputs behind capturedAt, sent on EVERY history record including the approx ones.
    // whenMs is millis() uptime at capture and bootCount says which boot session that uptime
    // belongs to, so a record survives reboots. Together they let the app bound a record the
    // board itself could not date: see BLEManager's bracketing.
    let whenMs: UInt32?          // json "ms"
    let bootCount: UInt32?       // json "boot"

    // True for any record filed through the offline-buffer replay path, i.e. captured by
    // the board while the phone was away. Drives the "OFFLINE" chip in the log. Set from
    // the replay handshake (mirrors isHistory) and persisted so a reloaded row keeps it.
    let offline: Bool            // json "off"; falls back to hist on decode

    /// Stable identity. Drones group by UAS-ID so they survive MAC rotation, matching the firmware's
    /// dedup key. Everything else is one entry per (type, MAC).
    /// STORED, not computed: `id` is read in the publish sort comparator AND the eviction filter, so a
    /// String-interpolating computed version burned ~110k allocations per publish and saturated the main
    /// thread. Computed once in init(from:); identity semantics are unchanged.
    let id: String

    var coordinate: CLLocationCoordinate2D? {
        guard let lat, let lon, !(lat == 0 && lon == 0) else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        // Reject NaN / infinite / out-of-range (|lat|>90, |lon|>180) before it reaches MapKit:
        // a garbled drone Remote ID can decode lat/lon to e.g. ~214 deg, and feeding a non-finite
        // Mercator projection to MapKit hangs the main thread (freeze, not a clean crash).
        return CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    var pilotCoordinate: CLLocationCoordinate2D? {
        guard let pilotLat, let pilotLon, !(pilotLat == 0 && pilotLon == 0) else { return nil }
        let c = CLLocationCoordinate2D(latitude: pilotLat, longitude: pilotLon)
        return CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    /// Bare magnitude of the GPS-fix age used for lat/lon ("45s"/"4m"/"2h"/"1d"); nil when
    /// the fix is fresh (under 30s) or there's no location.
    private var gpsFixAgeMagnitude: String? {
        guard coordinate != nil, let s = gpsAgeSec, s >= 30 else { return nil }
        if s < 90 { return "\(s)s" }
        let m = s / 60
        if m < 90 { return "\(m)m" }
        let h = m / 60
        return h < 48 ? "\(h)h" : "\(h / 24)d"
    }

    /// Compact LOC-badge text for a stale-fix position. A LIVE detection reads "4m ago" (the
    /// fix trails roughly now). An OFFLINE/replayed record was captured at an unknown PAST
    /// time, so "ago" would falsely imply the position is recent; show the fix-to-sighting
    /// lag instead ("fix 4m"). nil when the fix is fresh or there's no location.
    var locationAgeText: String? {
        guard let m = gpsFixAgeMagnitude else { return nil }
        return offline ? "fix \(m)" : "\(m) ago"
    }

    /// Longer form for the detail card, same live/offline split as `locationAgeText`.
    var locationAgeDetail: String? {
        guard let m = gpsFixAgeMagnitude else { return nil }
        return offline ? "location from a fix \(m) old" : "location as of \(m) ago"
    }

    /// A name the USER assigned to this exact MAC on the managed-devices screen (watched or
    /// ignored), if any. Beats everything else: if you bothered to type "Jane's tag" you never
    /// want to read "Tracker" again. Resolved through the shared DeviceNames registry so a plain
    /// value-type Detection can carry it without every view threading the BLEManager down.
    var customName: String? { DeviceNames.shared.label(for: mac) }

    /// Best label we have: the user's own name, else advertised name, else UAS serial, else the
    /// manufacturer the device broadcast, else the device class.
    ///
    /// The `maker` rung is why a log full of network cameras no longer reads "Network camera"
    /// twelve times beside a glyph that already said so. It sits BELOW the UAS serial (a drone's
    /// serial is a unique handle, and beats a maker shared by every DJI in the sky) and ABOVE
    /// type.label. It is nil for every category with no honest manufacturer, so those rows are
    /// unchanged. See Detection.maker for what may and may not feed it.
    var displayName: String {
        if let c = customName { return c }
        if let name, !name.isEmpty { return name }
        if let uasID, !uasID.isEmpty { return uasID }
        if let m = maker { return m }
        return type.label
    }

    /// True when the row leads with something other than the bare device class, which is what
    /// every caller was really asking. Derived FROM displayName rather than re-listing its steps:
    /// the two drifted the moment `maker` was added, and a row that leads with "Hikvision" while
    /// hasName reports false renders the category in NEITHER the title nor the subtitle. Keep
    /// this defined in terms of displayName.
    var hasName: Bool { displayName != type.label }

    /// Readable label for the drone's ODID operational status.
    var ridStatusLabel: String? {
        switch ridStatus {
        case 1: return "On ground"
        case 2: return "Airborne"
        case 3: return "Emergency"
        case 4: return "System fault"
        default: return nil
        }
    }

    /// Drone maker decoded from a CTA-2063-A Remote ID serial. The serial is a 4-char
    /// maker code, then a length digit, then the device serial. We name the codes we
    /// know and show the raw code otherwise.
    var ridManufacturer: String? {
        guard type == .drone, let s = uasID, s.count >= 5 else { return nil }
        let chars = Array(s)
        let code = String(chars[0..<4])
        let codeOK = code.allSatisfy { $0.isNumber || (("A"..."Z").contains($0) && $0 != "I" && $0 != "O") }
        guard codeOK, "123456789ABCDEF".contains(chars[4]) else { return nil }
        let names = ["1581": "DJI", "1748": "Autel", "1588": "Parrot", "1668": "Skydio", "1871": "Aurora"]
        return names[code] ?? "Mfr \(code)"
    }

    /// True when the address rotates: the board's `rnd` flag, or (as a fallback when
    /// the board doesn't send it) the locally-administered bit on the first MAC octet,
    /// which is the same test the firmware uses. Phones and item trackers randomize
    /// their address every few minutes, so a starred entry against one can stop matching.
    var addressIsRandomized: Bool {
        if randomAddr { return true }
        let hex = mac.filter { $0.isHexDigit }
        guard hex.count >= 2, let first = UInt8(hex.prefix(2), radix: 16) else { return false }
        return (first & 0x02) != 0
    }

    /// Rough signal bucket for the bars indicator (0...4).
    var signalBars: Int {
        switch rssi {
        case ..<(-90): return 1
        case ..<(-80): return 2
        case ..<(-67): return 3
        default:       return 4
        }
    }
}

// Hashable by id, so the log can use lazy value-based navigation (NavigationLink(value:) +
// navigationDestination) instead of building a detail-view destination for every row.
extension Detection: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension Detection: Codable {
    // The firmware's short keys; they map to the longer property names above.
    enum CodingKeys: String, CodingKey {
        case t, s, meth, c, mac, rssi, name, id, det, cid, lat, lon, plat, plon, alt
        case spd, vspd, hdg, hgt, palt, sta, n, new, gage
        case rnd                     // randomized / locally-administered transmitter address
        case hist, seq, at, approx   // offline-buffer replay
        case ms, boot                // uptime + boot session behind "at"; sent even when approx
        case off                     // offline-recorded flag (persisted; defaults to hist)
    }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        // A `t` this build doesn't know files as a generic .unknown row instead of throwing
        // the record away. OTA ships board firmware independently of app releases, so a future
        // type (or the retired t=6 off an old build) is a frame we WILL meet in the field, and
        // dropping it silently hid on iOS a detection Android showed as "Unknown". Mirrors
        // Android's DeviceType.from() fallback; no case is ever mislabeled as .flockCamera.
        let dt = DeviceType(rawValue: (try? k.decode(Int.self, forKey: .t)) ?? 0) ?? .unknown
        type       = dt
        source     = DetectionSource(rawValue: (try? k.decode(Int.self, forKey: .s)) ?? 0) ?? .ble
        method     = DetectionMethod(rawValue: (try? k.decode(Int.self, forKey: .meth)) ?? 0) ?? .none
        confidence = (try? k.decode(Int.self, forKey: .c)) ?? 0
        mac        = (try? k.decode(String.self, forKey: .mac)) ?? "??:??:??:??:??:??"
        // Clamped to the int16 wire type (firmware sends an int16 dBm). Unclamped, a hostile
        // rssi = Int.max reaches smoothedRssi's average (Double(2^63) -> Int traps), overflows
        // the window sum, and arms the best + 4 comparison in the closest-approach update.
        rssi       = min(32_767, max(-32_768, (try? k.decode(Int.self, forKey: .rssi)) ?? 0))
        name       = try? k.decodeIfPresent(String.self, forKey: .name)
        uasID      = try? k.decodeIfPresent(String.self, forKey: .id)
        // Stored identity, computed exactly once (see `id`). Same rule as the old computed property:
        // drones key on UAS-ID (survives MAC rotation), everything else on (type, MAC).
        if dt == .drone, let u = uasID, !u.isEmpty { id = "\(dt.rawValue):\(u)" }
        else                                       { id = "\(dt.rawValue):\(mac)" }
        detail     = try? k.decodeIfPresent(String.self, forKey: .det)
        companyId  = try? k.decodeIfPresent(Int.self, forKey: .cid)
        lat        = try? k.decodeIfPresent(Double.self, forKey: .lat)
        lon        = try? k.decodeIfPresent(Double.self, forKey: .lon)
        pilotLat   = try? k.decodeIfPresent(Double.self, forKey: .plat)
        pilotLon   = try? k.decodeIfPresent(Double.self, forKey: .plon)
        altitude   = try? k.decodeIfPresent(Int.self, forKey: .alt)
        gpsAgeSec  = try? k.decodeIfPresent(Int.self, forKey: .gage)
        speedH     = try? k.decodeIfPresent(Int.self, forKey: .spd)
        speedV     = try? k.decodeIfPresent(Int.self, forKey: .vspd)
        heading    = try? k.decodeIfPresent(Int.self, forKey: .hdg)
        heightAGL  = try? k.decodeIfPresent(Int.self, forKey: .hgt)
        pilotAlt   = try? k.decodeIfPresent(Int.self, forKey: .palt)
        ridStatus  = try? k.decodeIfPresent(Int.self, forKey: .sta)
        count      = (try? k.decode(Int.self, forKey: .n)) ?? 1
        isNew      = (try? k.decode(Bool.self, forKey: .new)) ?? false
        randomAddr = (try? k.decode(Bool.self, forKey: .rnd)) ?? false
        isHistory  = (try? k.decode(Bool.self, forKey: .hist)) ?? false
        seq        = try? k.decodeIfPresent(UInt32.self, forKey: .seq)
        // Clamp at the decode boundary. The wire type is a uint32 (firmware det_log.h atUnix), so
        // a legitimate board can only send 0...4294967295; anything else (NaN, infinities, huge or
        // negative doubles from an impostor peripheral) is dropped rather than converted, because
        // a poisoned Date reaches trapping Int conversions downstream AND gets checkpointed, which
        // made the crash persistent across relaunch.
        capturedAt = (try? k.decodeIfPresent(TimeInterval.self, forKey: .at) ?? nil)
            .flatMap { $0.isFinite && (0...4_294_967_295).contains($0)
                       ? Date(timeIntervalSince1970: $0) : nil }
        approx     = (try? k.decode(Bool.self, forKey: .approx)) ?? false
        whenMs     = try? k.decodeIfPresent(UInt32.self, forKey: .ms)
        bootCount  = try? k.decodeIfPresent(UInt32.self, forKey: .boot)
        // Live wire records carry neither key -> false. Replayed records carry hist=true.
        // Our on-disk checkpoint writes "off" explicitly so a reloaded row keeps the chip.
        offline    = (try? k.decode(Bool.self, forKey: .off)) ?? isHistory
    }

    // Encoded only for our own on-disk history checkpoint, using the same short keys
    // so init(from:) reads it straight back. Not part of the BLE wire protocol.
    func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        try k.encode(type.rawValue, forKey: .t)
        try k.encode(source.rawValue, forKey: .s)
        try k.encode(method.rawValue, forKey: .meth)
        try k.encode(confidence, forKey: .c)
        try k.encode(mac, forKey: .mac)
        try k.encode(rssi, forKey: .rssi)
        try k.encodeIfPresent(name, forKey: .name)
        try k.encodeIfPresent(uasID, forKey: .id)
        try k.encodeIfPresent(detail, forKey: .det)
        try k.encodeIfPresent(companyId, forKey: .cid)
        try k.encodeIfPresent(lat, forKey: .lat)
        try k.encodeIfPresent(lon, forKey: .lon)
        try k.encodeIfPresent(pilotLat, forKey: .plat)
        try k.encodeIfPresent(pilotLon, forKey: .plon)
        try k.encodeIfPresent(altitude, forKey: .alt)
        try k.encodeIfPresent(gpsAgeSec, forKey: .gage)
        try k.encodeIfPresent(speedH, forKey: .spd)
        try k.encodeIfPresent(speedV, forKey: .vspd)
        try k.encodeIfPresent(heading, forKey: .hdg)
        try k.encodeIfPresent(heightAGL, forKey: .hgt)
        try k.encodeIfPresent(pilotAlt, forKey: .palt)
        try k.encodeIfPresent(ridStatus, forKey: .sta)
        try k.encode(count, forKey: .n)
        try k.encode(isNew, forKey: .new)
        try k.encode(randomAddr, forKey: .rnd)
        try k.encode(isHistory, forKey: .hist)
        try k.encodeIfPresent(seq, forKey: .seq)
        try k.encodeIfPresent(capturedAt.map { $0.timeIntervalSince1970 }, forKey: .at)
        try k.encode(approx, forKey: .approx)
        try k.encodeIfPresent(whenMs, forKey: .ms)
        try k.encodeIfPresent(bootCount, forKey: .boot)
        try k.encode(offline, forKey: .off)
    }
}

extension Detection {
    /// The BLE manufacturer company ID as "0x058E" (+ vendor when we know it), for the detail
    /// screen. nil when there's no company ID (WiFi devices, or a BLE advert with no mfg data).
    var companyIdText: String? {
        guard let cid = companyId, cid > 0 else { return nil }
        let hex = String(format: "0x%04X", cid)
        if let name = Detection.bleCompanyName(cid) { return "\(hex) \u{00B7} \(name)" }
        return hex
    }

    /// Bare "0x058E" hex, no vendor - used for the CSV column so it stays machine-parseable.
    var companyIdHex: String? {
        guard let cid = companyId, cid > 0 else { return nil }
        return String(format: "0x%04X", cid)
    }

    /// Short vendor label for the BLE SIG company IDs most relevant here (camera glasses,
    /// trackers, a few common makers). Everything else just shows the raw hex.
    static func bleCompanyName(_ id: Int) -> String? {
        switch id {
        case 0x004C: return "Apple"
        case 0x0075: return "Samsung"
        case 0x00E0: return "Google"
        case 0x0006: return "Microsoft"
        case 0x0D53: return "Luxottica (Ray-Ban Meta)"
        case 0x03C2: return "Snap (Spectacles)"
        case 0x060C: return "Vuzix"
        case 0x058E: return "Meta Platforms Technologies"
        case 0x01AB: return "Meta Platforms"
        case 0x0BC6: return "TCL / RayNeo"
        default:     return nil
        }
    }
}
