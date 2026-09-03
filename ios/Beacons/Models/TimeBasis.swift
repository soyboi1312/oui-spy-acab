import Foundation

/// How a detection's timestamp was arrived at.
///
/// The board has no real-time clock. A record it buffered while the phone was away carries only
/// an uptime and a boot counter, so its wall-clock time is DERIVED, never read. These logs get
/// handed over as evidence, and a derived time printed like a clock reading invites more
/// confidence than the method can carry, so every row states its basis alongside its time.
///
/// One enum rather than a pile of booleans: a row can never claim two bases at once, and adding a
/// fifth quality later cannot silently produce a row that is both approx and exact. Mirrors
/// Android's TimeBasis; the four cases and the CSV tokens must stay in step with it.
enum TimeBasis: Equatable {
    /// Stamped by the phone's own clock as the detection arrived. The live path.
    case exact
    /// Buffered, and the board dated it from an epoch anchor it recorded during the same boot.
    /// `precisionSec` is the error bar on that arithmetic, not a display rounding.
    case reconstructed(precisionSec: Int)
    /// Buffered during a boot the phone never anchored, so the board could not date it at all,
    /// but it falls between boots that WERE anchored. At least one bound is non-nil.
    case bracketed(after: Date?, before: Date?)
    /// Buffered, unanchored, and with no anchored boot on either side to bound it against.
    case unknown
}

extension TimeBasis {
    /// Column value for the CSV's time_basis. Byte-identical to Android's tokens: an export from
    /// either phone has to parse the same way.
    var csvToken: String {
        switch self {
        case .exact:         return "exact"
        case .reconstructed: return "reconstructed"
        case .bracketed:     return "bracketed"
        case .unknown:       return "unknown"
        }
    }

    /// Column value for the CSV's time_precision_s. Only a reconstructed time has a meaningful
    /// error bar; a bracket's width is already stated by its two endpoints, so the column stays
    /// empty rather than restating it as a plus-or-minus it isn't.
    var csvPrecisionSec: String {
        if case .reconstructed(let p) = self { return "\(p)" }
        return ""
    }

    /// True when the row must NOT render a single clock time. A bracket is a range and an unknown
    /// is nothing; printing either as one instant is the exact failure this model exists to stop.
    var hidesInstant: Bool {
        switch self {
        case .exact, .reconstructed: return false
        case .bracketed, .unknown:   return true
        }
    }
}

/// The error bar on a reconstructed time, and where it comes from.
enum ReconstructedTime {
    /// The ESP32's crystal is specified at roughly +/-20 ppm, so a record captured N seconds
    /// before the anchor can be off by N * this much.
    static let driftPerSecond = 0.00002
    /// Floor on the error bar. The anchor itself is only as good as the BLE round trip that
    /// carried the epoch push, so no reconstruction is better than a couple of seconds however
    /// short the elapsed interval.
    static let floorSec = 2

    static func precisionSec(elapsedSec: TimeInterval) -> Int {
        // Int(exactly:) instead of the trapping Int(_: Double): the decode boundary clamps `at`,
        // but a checkpoint written by an older build can still replay a poisoned Date into here,
        // and an absurd error bar must degrade, not crash.
        let scaled = (max(0, elapsedSec) * driftPerSecond).rounded()
        return max(floorSec, Int(exactly: scaled) ?? Int.max)
    }
}

// MARK: - Display

/// Copy for a derived time. Plain language on purpose: the reader is a person holding a log,
/// not a lawyer, and hedging that reads as legalese gets skimmed past. Mirrors Android's strings.
enum TimeBasisCopy {
    /// A fixed dateFormat MUST be paired with the POSIX locale. Without it, Foundation is free to
    /// rewrite "HH" into a 12-hour rendering on a device whose region uses 12-hour time, and since
    /// these patterns carry no "a" designator the result is an hour with NO AM/PM: 02:30 and 14:30
    /// become indistinguishable. That is a bad bug in any UI and a disqualifying one in a log
    /// somebody hands over as evidence.
    private static func fixed(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = pattern
        return f
    }

    /// "14:32:07" for a same-week stamp, "Mar 4, 14:32:07" once it's older than that.
    static func instant(_ date: Date) -> String {
        fixed(isRecent(date) ? "HH:mm:ss" : "MMM d, HH:mm:ss").string(from: date)
    }

    /// Bracket endpoints are coarser than an instant on purpose: a bound is not a measurement,
    /// and printing it to the second would dress it up as one.
    static func endpoint(_ date: Date) -> String {
        fixed(isRecent(date) ? "EEE HH:mm" : "MMM d, HH:mm").string(from: date)
    }

    /// "14:32": the capture-window endpoints in the contribution flow (review sentence,
    /// disclosure block, and the note that ships with the CSV). Fixed 24-hour, same POSIX pin as
    /// the rest of this file, because the note is evidence handed to a third party and the
    /// disclosure text is a byte-for-byte contract with Android. Until 2026-09-02 this was a bare
    /// "h:mm a" DateFormatter: a 12-hour clock whose AM/PM token the device locale spelled
    /// differently, and one that Foundation rewrote to a 24-hour clock with no token at all
    /// whenever the user had forced 24-Hour Time in Settings, so the string followed the device
    /// preference as well as the locale (the same rewrite `fixed` documents in the other
    /// direction). Android twin: clockTimeText in ui/Components.kt.
    static func clock(_ date: Date) -> String {
        fixed("HH:mm").string(from: date)
    }

    /// "between Tue 14:00 and Wed 09:00", or the one-sided forms when only one boot could be
    /// found to bound against. Returns nil when there is nothing to state.
    static func range(after: Date?, before: Date?) -> String? {
        switch (after, before) {
        case let (a?, b?): return "between \(endpoint(a)) and \(endpoint(b))"
        case let (a?, nil): return "after \(endpoint(a))"
        case let (nil, b?): return "before \(endpoint(b))"
        default: return nil
        }
    }

    /// The value a row shows where a live row shows its time.
    static func value(for basis: TimeBasis, stamp: Date?) -> String {
        switch basis {
        case .exact:
            return stamp.map(instant) ?? "-"
        case .reconstructed:
            // The tilde is the dense-list shorthand for "derived"; the note below spells it out.
            return stamp.map { "~\(instant($0))" } ?? "-"
        case .bracketed(let after, let before):
            return range(after: after, before: before) ?? unknownValue
        case .unknown:
            return unknownValue
        }
    }

    /// Kept word for word from the pre-existing approx handling, so a row that really is
    /// undateable reads the same as it always has.
    static let unknownValue = "time unknown \u{00B7} offline buffer"

    /// Secondary line under the value. nil for a live row: an exact time needs no defence.
    static func note(for basis: TimeBasis) -> String? {
        switch basis {
        case .exact:
            return nil
        case .reconstructed(let p):
            return "reconstructed from device uptime, +/-\(p)s"
        case .bracketed:
            return "the beacon restarted, so this is bounded, not measured"
        case .unknown:
            return "the beacon had no clock reference for this record"
        }
    }

    /// Short marker for a dense list row. nil where a marker would only add noise.
    static func tag(for basis: TimeBasis) -> String? {
        switch basis {
        case .exact:         return nil
        case .reconstructed: return "RECON"
        case .bracketed:     return "RANGE"
        case .unknown:       return "NO TIME"
        }
    }

    /// Within the last six days, a weekday plus a time is unambiguous and much easier to read
    /// than a full date. Past that it isn't, so the date comes back.
    private static func isRecent(_ date: Date) -> Bool {
        let age = Date().timeIntervalSince(date)
        return age >= 0 && age < 6 * 86_400
    }
}

// MARK: - Persistence

/// Written into the on-disk checkpoint so a reloaded row keeps its basis instead of decaying to
/// "unknown" on the next launch. Flat keys, short values, because this rides in every stored row.
extension TimeBasis: Codable {
    private enum CodingKeys: String, CodingKey { case kind, prec, after, before }

    init(from decoder: Decoder) throws {
        let k = try decoder.container(keyedBy: CodingKeys.self)
        let kind = (try? k.decode(String.self, forKey: .kind)) ?? "exact"
        switch kind {
        case "recon":
            self = .reconstructed(precisionSec: (try? k.decode(Int.self, forKey: .prec)) ?? ReconstructedTime.floorSec)
        case "bracket":
            let a = (try? k.decodeIfPresent(TimeInterval.self, forKey: .after) ?? nil).map(Date.init(timeIntervalSince1970:))
            let b = (try? k.decodeIfPresent(TimeInterval.self, forKey: .before) ?? nil).map(Date.init(timeIntervalSince1970:))
            // A bracket with neither bound is not a bracket. Decode it as what it actually is.
            self = (a == nil && b == nil) ? .unknown : .bracketed(after: a, before: b)
        case "unknown":
            self = .unknown
        default:
            self = .exact
        }
    }

    func encode(to encoder: Encoder) throws {
        var k = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .exact:
            try k.encode("exact", forKey: .kind)
        case .reconstructed(let p):
            try k.encode("recon", forKey: .kind)
            try k.encode(p, forKey: .prec)
        case .bracketed(let a, let b):
            try k.encode("bracket", forKey: .kind)
            try k.encodeIfPresent(a.map { $0.timeIntervalSince1970 }, forKey: .after)
            try k.encodeIfPresent(b.map { $0.timeIntervalSince1970 }, forKey: .before)
        case .unknown:
            try k.encode("unknown", forKey: .kind)
        }
    }
}
