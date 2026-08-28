import Foundation
import CoreLocation

/// Exact numeric values read from the top-level BLE JSON object before Foundation turns JSON
/// numbers into binary/decimal values. JSONDecoder is deliberately not the authority here:
/// on current iOS it rounds precision-hidden fractional tails for both UInt32 and Int. The replay
/// fields become cursors/dates and RSSI feeds proximity policy, so the original numeric lexeme is
/// the only lossless boundary.
private struct DetectionWireNumericFields {
    let uint32Values: [String: UInt32]
    let rssi: Int?
    subscript(_ key: String) -> UInt32? { uint32Values[key] }
}

private let detectionWireNumericFieldsKey = CodingUserInfoKey(
    rawValue: "tech.acab.detection.raw-wire-numeric-fields")!
private let detectionWireNumericFieldNames: Set<String> = ["seq", "at", "ms", "boot", "rssi"]

private enum ExactWireJSONError: Error { case malformedTopLevelObject }

/// A small structural scanner for the compact, top-level JSON objects carried by the BLE
/// characteristic. It does not interpret arbitrary values; it only preserves the byte range of
/// requested top-level members while correctly stepping over strings and nested containers.
/// JSONDecoder still validates and decodes the complete Detection afterwards.
private struct ExactWireJSONObject {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) { bytes = Array(data) }

    mutating func numericValues(for wanted: Set<String>) throws -> DetectionWireNumericFields {
        var uint32Values: [String: UInt32] = [:]
        var rssi: Int?
        var seen = Set<String>()
        var duplicates = Set<String>()

        skipWhitespace()
        guard consume(0x7B) else { throw ExactWireJSONError.malformedTopLevelObject } // {
        skipWhitespace()
        if consume(0x7D) { // }
            skipWhitespace()
            guard index == bytes.count else { throw ExactWireJSONError.malformedTopLevelObject }
            return DetectionWireNumericFields(uint32Values: uint32Values, rssi: rssi)
        }

        while true {
            skipWhitespace()
            guard peek == 0x22 else { throw ExactWireJSONError.malformedTopLevelObject } // "
            let keyStart = index
            try skipString()
            let keyEnd = index
            let key = requestedKey(in: keyStart..<keyEnd, wanted: wanted)

            skipWhitespace()
            guard consume(0x3A) else { throw ExactWireJSONError.malformedTopLevelObject } // :
            skipWhitespace()
            let valueStart = index
            try skipValue()
            let valueEnd = index

            if let key {
                if seen.insert(key).inserted {
                    if key == "rssi" {
                        if let value = Self.exactInt64(in: bytes, range: valueStart..<valueEnd) {
                            rssi = Int(min(Int64(Int16.max), max(Int64(Int16.min), value)))
                        }
                    } else if let value = Self.exactUInt32(in: bytes,
                                                          range: valueStart..<valueEnd) {
                        uint32Values[key] = value
                    }
                } else {
                    // Duplicate member semantics are not defined by JSON, and Foundation's choice
                    // must never disagree with the raw security verdict. Fail this field closed.
                    duplicates.insert(key)
                    if key == "rssi" { rssi = nil }
                    else { uint32Values.removeValue(forKey: key) }
                }
            }

            skipWhitespace()
            if consume(0x2C) { continue } // ,
            guard consume(0x7D) else { throw ExactWireJSONError.malformedTopLevelObject } // }
            break
        }

        skipWhitespace()
        guard index == bytes.count else { throw ExactWireJSONError.malformedTopLevelObject }
        for key in duplicates {
            if key == "rssi" { rssi = nil }
            else { uint32Values.removeValue(forKey: key) }
        }
        return DetectionWireNumericFields(uint32Values: uint32Values, rssi: rssi)
    }

    /// Firmware keys are short unescaped ASCII. Compare those bytes in place so the detection hot
    /// path does not construct a JSONDecoder (or even a String) for every one of ~20 members. An
    /// escaped key is rare/adversarial and takes the slower decoder path so `"s\u0065q"` cannot
    /// evade the same raw-token verdict as `"seq"`.
    private func requestedKey(in quotedRange: Range<Int>, wanted: Set<String>) -> String? {
        let content = bytes[(quotedRange.lowerBound + 1)..<(quotedRange.upperBound - 1)]
        if !content.contains(0x5C) { // backslash
            for key in wanted where content.elementsEqual(key.utf8) { return key }
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(
            String.self, from: Data(bytes[quotedRange])), wanted.contains(decoded) else { return nil }
        return decoded
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard peek == byte else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
    }

    private mutating func skipString() throws {
        guard consume(0x22) else { throw ExactWireJSONError.malformedTopLevelObject }
        while let b = peek {
            index += 1
            if b == 0x22 { return }
            guard b >= 0x20 else { throw ExactWireJSONError.malformedTopLevelObject }
            if b == 0x5C { // backslash
                guard let escaped = peek else { throw ExactWireJSONError.malformedTopLevelObject }
                index += 1
                if escaped == 0x75 { // u, followed by exactly four ASCII hex digits
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy(Self.isHex) else {
                        throw ExactWireJSONError.malformedTopLevelObject
                    }
                    index += 4
                } else if ![0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    throw ExactWireJSONError.malformedTopLevelObject
                }
            }
        }
        throw ExactWireJSONError.malformedTopLevelObject
    }

    private mutating func skipValue() throws {
        guard let first = peek else { throw ExactWireJSONError.malformedTopLevelObject }
        if first == 0x22 { try skipString(); return }

        if first == 0x7B || first == 0x5B { // { or [
            var closers: [UInt8] = [first == 0x7B ? 0x7D : 0x5D]
            index += 1
            while !closers.isEmpty {
                guard let b = peek else { throw ExactWireJSONError.malformedTopLevelObject }
                if b == 0x22 { try skipString(); continue }
                if b == 0x7B { closers.append(0x7D); index += 1; continue }
                if b == 0x5B { closers.append(0x5D); index += 1; continue }
                if b == 0x7D || b == 0x5D {
                    guard closers.last == b else { throw ExactWireJSONError.malformedTopLevelObject }
                    closers.removeLast()
                }
                index += 1
            }
            return
        }

        let start = index
        while let b = peek,
              b != 0x20 && b != 0x09 && b != 0x0A && b != 0x0D
                && b != 0x2C && b != 0x7D && b != 0x5D {
            index += 1
        }
        guard index > start else { throw ExactWireJSONError.malformedTopLevelObject }
    }

    private static func isHex(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x46).contains(b) || (0x61...0x66).contains(b)
    }

    private static func isDigit(_ b: UInt8) -> Bool { (0x30...0x39).contains(b) }

    /// Parse one JSON numeric token as a mathematical uint32 without ever converting through
    /// Double or Decimal. Decimal points and exponents are accepted when the represented value is
    /// integral (`1.0`, `1000e-3`); any non-zero discarded digit makes the field invalid.
    private static func exactUInt32(in bytes: [UInt8], range: Range<Int>) -> UInt32? {
        guard let value = exactIntegerMagnitude(in: bytes, range: range,
                                                maximum: UInt64(UInt32.max)),
              !value.negative else { return nil }
        return UInt32(value.magnitude)
    }

    /// RSSI is signed on the wire. Match JSONDecoder's useful domain by accepting an exact Int64,
    /// then let the caller clamp it to the firmware's int16 storage type. This intentionally rejects
    /// a precision-hidden fractional token that Foundation rounds to an apparently integral Int.
    private static func exactInt64(in bytes: [UInt8], range: Range<Int>) -> Int64? {
        let negativeLimit = UInt64(Int64.max) + 1
        guard let value = exactIntegerMagnitude(in: bytes, range: range,
                                                maximum: negativeLimit) else { return nil }
        if value.magnitude == 0 { return 0 }
        if value.negative {
            if value.magnitude == negativeLimit { return Int64.min }
            return -Int64(value.magnitude)
        }
        guard value.magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(value.magnitude)
    }

    /// Exact shared parser for signed/unsigned integral JSON numbers. [maximum] bounds the decimal
    /// accumulator before conversion, so hostile exponents and long mantissas cannot overflow or
    /// turn into work proportional to their claimed scale.
    private static func exactIntegerMagnitude(in bytes: [UInt8], range: Range<Int>,
                                              maximum: UInt64) ->
        (negative: Bool, magnitude: UInt64)? {
        var i = range.lowerBound
        let end = range.upperBound
        guard i < end else { return nil }

        var negative = false
        if bytes[i] == 0x2D { negative = true; i += 1 } // -
        guard i < end else { return nil }

        var digits: [UInt8] = []
        if bytes[i] == 0x30 {
            digits.append(bytes[i]); i += 1
            // JSON numbers may not carry an integer-part leading zero.
            if i < end, isDigit(bytes[i]) { return nil }
        } else {
            guard (0x31...0x39).contains(bytes[i]) else { return nil }
            while i < end, isDigit(bytes[i]) { digits.append(bytes[i]); i += 1 }
        }

        var fractionalDigits = 0
        if i < end, bytes[i] == 0x2E { // .
            i += 1
            let fractionStart = i
            while i < end, isDigit(bytes[i]) {
                digits.append(bytes[i]); fractionalDigits += 1; i += 1
            }
            guard i > fractionStart else { return nil }
        }

        var exponent = 0
        if i < end, bytes[i] == 0x65 || bytes[i] == 0x45 { // e/E
            i += 1
            var exponentNegative = false
            if i < end, bytes[i] == 0x2B || bytes[i] == 0x2D { // +/-
                exponentNegative = bytes[i] == 0x2D
                i += 1
            }
            let exponentStart = i
            // Saturating is enough: anything beyond this bound is either zero (handled below) or
            // far outside uint32. It also keeps a hostile exponent from overflowing Int.
            let limit = 1_000_000
            var magnitude = 0
            while i < end, isDigit(bytes[i]) {
                if magnitude < limit {
                    magnitude = min(limit, magnitude * 10 + Int(bytes[i] - 0x30))
                }
                i += 1
            }
            guard i > exponentStart else { return nil }
            exponent = exponentNegative ? -magnitude : magnitude
        }
        guard i == end else { return nil }

        guard let firstNonZero = digits.firstIndex(where: { $0 != 0x30 }) else {
            // JSON -0 and zero with any decimal/exponent spelling are still integer zero.
            return (false, 0)
        }

        let scale = exponent - fractionalDigits
        var significantEnd = digits.count
        var appendedZeros = 0
        if scale < 0 {
            let dropped = -scale
            guard dropped < significantEnd - firstNonZero else { return nil }
            guard digits[(significantEnd - dropped)..<significantEnd].allSatisfy({ $0 == 0x30 }) else {
                return nil
            }
            significantEnd -= dropped
        } else {
            appendedZeros = scale
        }

        var maximumDigits = 1
        var maximumProbe = maximum
        while maximumProbe >= 10 { maximumDigits += 1; maximumProbe /= 10 }
        // Check length first so a huge positive exponent never becomes a huge loop; the accumulator
        // below enforces the exact caller-supplied ceiling.
        guard appendedZeros <= maximumDigits,
              significantEnd - firstNonZero + appendedZeros <= maximumDigits else { return nil }
        var result: UInt64 = 0
        for digitByte in digits[firstNonZero..<significantEnd] {
            let digit = UInt64(digitByte - 0x30)
            guard result <= (maximum - digit) / 10 else { return nil }
            result = result * 10 + digit
        }
        for _ in 0..<appendedZeros {
            guard result <= maximum / 10 else { return nil }
            result *= 10
        }
        return (negative, result)
    }
}

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
    let gpsAgeSec: Int?          // age (s) of the fix behind lat/lon (json "gage"). Present on any
                                 // non-drone row whose stamping fix was >= 1s old, LIVE rows included;
                                 // nil = fresh sub-second fix, no coordinate, the board's own onboard
                                 // fix, a drone's broadcast position, or a trimmed hist row

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
    // The raw inputs behind capturedAt. Guaranteed on approx records, where they are the only
    // dating information; on an at-bearing record a small-MTU link may shed both via the replay
    // trim ladder (HIST_TRIM_ANCHOR, see docs/ble-protocol.md), so decode and treat both as
    // optional. whenMs is millis() uptime at capture and bootCount says which boot session that
    // uptime belongs to, so a record survives reboots. Together they let the app bound a record
    // the board itself could not date: see BLEManager's bracketing.
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

    /// `mac` lowercased, STORED for the same reason as `id`. The watchlist and mute sets are keyed
    /// on lowercased MACs, so every projection test needs this form: publishDetections and
    /// recomputeLiveCounts both walk up to the 5,000-row cap at the ~3 Hz publish cadence (and the
    /// widget summary walks today's rows on its own sample), and each was allocating its own
    /// throwaway String per row per pass. Computed once in init(from:); derived from `mac`, so it
    /// is not a wire key and not encoded.
    let loweredMac: String

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
    var signalBars: Int { Detection.signalBars(rssi: rssi) }

    /// Single owner of the RSSI band thresholds. The static form exists for callers that
    /// hold a bare RSSI and no Detection (the connect screen's scan rows); every bars
    /// indicator and its spoken strong/good/fair/weak label must band through here so
    /// tuning a boundary can never split the visual from the accessibility copy.
    static func signalBars(rssi: Int) -> Int {
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

extension Detection {
    /// Decode one raw Detections-characteristic frame. All callers at the BLE boundary must use
    /// this entry point instead of feeding the bytes straight to JSONDecoder, because Foundation
    /// can round a fractional numeric lexeme to an apparently valid integer before Codable sees it.
    static func decodeWireJSON(_ data: Data) throws -> Detection {
        var object = ExactWireJSONObject(data)
        let values = try object.numericValues(for: detectionWireNumericFieldNames)
        let decoder = JSONDecoder()
        decoder.userInfo[detectionWireNumericFieldsKey] = values
        return try decoder.decode(Detection.self, from: data)
    }

    /// Exact raw-token helper for the two BLE paths that do not decode a Detection: the history
    /// begin sentinel's `from`, and seq-only bookkeeping for an otherwise undecodable history row.
    /// Missing, duplicated, non-numeric, fractional and out-of-range members all return nil.
    static func exactWireUInt32(forKey key: String, in data: Data) -> UInt32? {
        var object = ExactWireJSONObject(data)
        return (try? object.numericValues(for: [key]))?[key]
    }
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
        loweredMac = mac.lowercased()   // once per row, not once per projection test (see `loweredMac`)
        // Clamped to the int16 wire type (firmware sends an int16 dBm). At the BLE boundary the
        // value comes from the exact raw numeric lexeme: Foundation rounds a precision-hidden
        // fraction such as -87.0000000000000000001 to Int(-87), and its duplicate-member choice
        // differs from Android's. Both are ambiguous wire data and therefore read as absent/0.
        // Locally JSONEncoder-authored checkpoint/demo data retains the ordinary Int fallback.
        if let wire = decoder.userInfo[detectionWireNumericFieldsKey]
            as? DetectionWireNumericFields {
            rssi = wire.rssi ?? 0
        } else {
            rssi = min(32_767, max(-32_768, (try? k.decode(Int.self, forKey: .rssi)) ?? 0))
        }
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
        // Clamped at the decode boundary, same rule as `rssi` above and `capturedAt` below. 0 and
        // 0xFFFFFFFF are the firmware's own empty-slot sentinels - det_log.cpp's slotValid()
        // rejects both - so a genuine board can never send either. An impostor peripheral that
        // sends 0xFFFFFFFF would ride histHighestSeq into lastGoodSeq, get checkpointed into
        // `acab.lastSeq`, and then trap the next record on lastGoodSeq + 1: a crash that survives
        // relaunch because the poison is on disk. A record with no usable seq is still received
        // and still counted toward the drain tally; it just moves no cursor.
        // THE RULE, and both apps hold it at EVERY boundary that reads these uint32 fields off the
        // wire, because a rule enforced at only one of them is the softest one an impostor can aim
        // at. `decodeWireJSON` supplies values parsed from the exact raw numeric lexemes: asking
        // JSONDecoder for UInt32/Double is not exact because it rounds precision-hidden fractions.
        // The fallback branch is only for our own JSONEncoder-written checkpoint and demo data;
        // those trusted local encoders emit an exact integer or `.0` Double spelling.
        if let wire = decoder.userInfo[detectionWireNumericFieldsKey]
            as? DetectionWireNumericFields {
            seq = wire["seq"].flatMap { $0 == 0 || $0 == UInt32.max ? nil : $0 }
            capturedAt = wire["at"].map { Date(timeIntervalSince1970: TimeInterval($0)) }
            whenMs = wire["ms"]
            bootCount = wire["boot"]
        } else {
            seq = (try? k.decodeIfPresent(UInt32.self, forKey: .seq) ?? nil)
                .flatMap { $0 == 0 || $0 == UInt32.max ? nil : $0 }
            capturedAt = (try? k.decodeIfPresent(TimeInterval.self, forKey: .at) ?? nil)
                .flatMap { $0.isFinite && $0.rounded(.towardZero) == $0
                           && (0...4_294_967_295).contains($0)
                           ? Date(timeIntervalSince1970: $0) : nil }
            whenMs = try? k.decodeIfPresent(UInt32.self, forKey: .ms)
            bootCount = try? k.decodeIfPresent(UInt32.self, forKey: .boot)
        }
        approx     = (try? k.decode(Bool.self, forKey: .approx)) ?? false
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
