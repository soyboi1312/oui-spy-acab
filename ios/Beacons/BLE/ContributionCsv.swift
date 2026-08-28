import Foundation

/// Location redaction for a SHARED contribution CSV. iOS twin of Android ContributionCsv.kt; the
/// two must stay identical so a contribution behaves the same on either platform.
///
/// The detection CSV carries location from THREE distinct sources, controlled SEPARATELY:
///   - approx_lat / approx_lon         = the CONTRIBUTOR'S PHONE position. Removed by DEFAULT.
///   - drone_lat / drone_lon           = the AIRCRAFT's Remote ID broadcast position. Kept by
///     default for a drone observation, because it describes a machine in the air.
///   - operator_lat / operator_lon /   = the OPERATOR's Remote ID broadcast position. Removed by
///     operator_alt_m                    DEFAULT: it is a PERSON's location, so it gets the same
///     caution as the contributor's own, even though the drone broadcast it. Previously these rode
///     one toggle with the aircraft coords, which quietly shipped a bystander's position under an
///     "aircraft" label. Altitude rides along because the altitude OF A PERSON'S POSITION is part
///     of that position (which floor, hilltop vs street), unlike the aircraft's altitude_m, which
///     is flight telemetry about a machine.
///
/// Columns are named EXPLICITLY, never matched on the text "lat"/"lon": a rule that blanked every
/// "lat" column would wrongly strip drone_lat. The pure functions are unit-tested (ContributionCsvTests).
enum ContributionCsv {
    /// The detection CSV's columns, in order. Byte-identical to Android's DETECTION_CSV_COLUMNS
    /// (AcabBleManager.kt), which is why it moves in the same commit or not at all.
    ///
    /// It lives HERE rather than as a literal inside BLEManager.buildCSV because the redaction
    /// policy below names these columns as STRINGS: observer/drone/operatorLocationCols have to
    /// match the emitter exactly or a coordinate the disclosure says was removed ships under its
    /// new name. With one shared list, ContributionCsvTests pins the two against each other
    /// instead of against a hand-copied fixture that a rename would leave green.
    ///
    /// `maker` is appended LAST so an existing parser keyed on column order still reads every
    /// field it knew about.
    static let detectionColumns: [String] = [
        "detected_at", "time_basis", "time_precision_s", "type", "mac", "rssi",
        "source", "matched_on", "confidence", "sightings", "approx_lat", "approx_lon",
        "company_id", "uas_id", "drone_lat", "drone_lon", "altitude_m", "speed_ms",
        "heading_deg", "height_agl_m", "operator_lat", "operator_lon", "operator_alt_m",
        "rid_status", "maker",
    ]

    /// The contributor's own phone position. Removed by default in a shared contribution.
    static let observerLocationCols: Set<String> = ["approx_lat", "approx_lon"]
    /// The aircraft's Remote ID broadcast position. A separate opt-in, on by default. Deliberately
    /// NOT altitude/speed/heading, which are telemetry, not a place on a map.
    static let droneLocationCols: Set<String> = ["drone_lat", "drone_lon"]
    /// The operator's Remote ID broadcast position. Its own opt-in, OFF by default: same
    /// broadcast as the aircraft coords, but it locates a person, not a machine. operator_alt_m
    /// is INCLUDED here, unlike the aircraft's altitude_m: the altitude of a person's position is
    /// location, not telemetry, and leaving it while blanking lat/lon would still leak which
    /// building or floor the operator stood on.
    static let operatorLocationCols: Set<String> = ["operator_lat", "operator_lon", "operator_alt_m"]

    /// True when a device's presence overlaps a capture window. A bounded "Start -> observe -> Stop"
    /// contribution exports ONLY the devices audible during [startMs, stopMs], not the whole history.
    /// Membership is OVERLAP, not containment: a device first heard before Start but still present
    /// during the window WAS observed during it. A device with no phone-side timestamp is excluded.
    /// Millis (not Date) to stay byte-identical to Android ContributionCsv.inCaptureWindow.
    static func inCaptureWindow(_ firstSeenMs: Int64?, _ lastSeenMs: Int64?, _ startMs: Int64, _ stopMs: Int64) -> Bool {
        guard let f = firstSeenMs, let l = lastSeenMs else { return false }
        return f <= stopMs && l >= startMs
    }

    /// Timestamp written by a bounded capture. The full-history CSV uses first-ever sighting, but
    /// a capture row must name when that device was actually heard inside this window. The caller
    /// freezes `lastSeenMs` at Stop; clamping is a final invariant guard against clock/boundary
    /// skew and guarantees every emitted instant lies inside [startMs, stopMs].
    static func captureTimestamp(_ lastSeenMs: Int64?, _ startMs: Int64, _ stopMs: Int64) -> Int64? {
        guard let lastSeenMs else { return nil }
        return min(stopMs, max(startMs, lastSeenMs))
    }

    static func blankColumns(includeObserverLocation: Bool, includeDroneLocation: Bool,
                             includeOperatorLocation: Bool) -> Set<String> {
        var s = Set<String>()
        if !includeObserverLocation { s.formUnion(observerLocationCols) }
        if !includeDroneLocation    { s.formUnion(droneLocationCols) }
        if !includeOperatorLocation { s.formUnion(operatorLocationCols) }
        return s
    }

    /// A copy of `csv` with the named columns blanked, structure otherwise intact. NEVER mutates the
    /// source: the caller redacts the EXPORTED copy only. Quote-aware (RFC 4180), because earlier
    /// columns (type label, maker, rid) can be quoted and hold commas or record separators, so
    /// splitting on commas or newlines would misalign and blank the wrong field. Malformed quoted
    /// input fails closed to a header-only CSV rather than returning possibly sensitive row bytes.
    /// A requested column the header does not carry fails closed the same way, for the same reason.
    static func redact(_ csv: String, blankColumns: Set<String>) -> String {
        if csv.isEmpty { return csv }
        guard let document = parseDocument(csv) else { return safeHeader(csv) }
        if blankColumns.isEmpty { return csv }
        guard let header = document.records.first else { return "" }
        // Every policy column must be present. The emitter's header is `detectionColumns` and every
        // set above is a subset of it, so a missing name means the two drifted - a renamed column -
        // and blanking only the names that still match would ship the renamed coordinate under its
        // new name in a file whose disclosure says it was removed. This used to return the ORIGINAL
        // csv in that case, which is the one outcome the whole file exists to prevent. Partial
        // matches fail closed too: half a policy applied is not the policy. Android twin: the
        // `blankColumnNames.all { it in header }` guard in redactCsvColumns.
        guard blankColumns.allSatisfy({ header.contains($0) }) else { return safeHeader(csv) }
        let blankIdx = Set(header.enumerated().filter { blankColumns.contains($0.element) }.map { $0.offset })

        var records = [header]
        for record in document.records.dropFirst() {
            var fields = record
            for b in blankIdx where b < fields.count { fields[b] = "" }
            records.append(fields)
        }
        return serialize(records, separator: document.recordSeparator,
                         trailingSeparator: document.endsWithRecordSeparator)
    }

    /// Number of real observation records after the header. Unlike counting physical newlines,
    /// this stays correct when a quoted field contains CRLF/LF and ignores preserved empty
    /// records. A malformed document returns zero because its record boundaries are untrusted.
    static func dataRowCount(_ csv: String) -> Int {
        guard let records = parseDocument(csv)?.records else { return 0 }
        return records.dropFirst().filter { record in record.contains { !$0.isEmpty } }.count
    }

    private enum ParseState { case fieldStart, unquoted, quoted, afterQuote }

    struct ParsedDocument {
        let records: [[String]]
        let recordSeparator: String
        let endsWithRecordSeparator: Bool
    }

    /// Swift treats CRLF as one extended-grapheme `Character`, while lone CR and LF are separate
    /// characters. All three are valid record separators outside a quoted field.
    private static func isRecordSeparator(_ c: Character) -> Bool {
        c == "\r\n" || c == "\r" || c == "\n"
    }

    /// Strict RFC 4180 document parser. Newlines inside quoted fields belong to that field, while
    /// CRLF, LF, and CR outside quotes terminate a record. Illegal or unterminated quotes fail.
    static func parseDocument(_ csv: String) -> ParsedDocument? {
        if csv.isEmpty { return ParsedDocument(records: [], recordSeparator: "\n", endsWithRecordSeparator: false) }

        let chars = Array(csv)
        var records: [[String]] = []
        var fields: [String] = []
        var value = ""
        var state = ParseState.fieldStart
        var firstRecordSeparator: String?
        var endsWithRecordSeparator = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            switch state {
            case .fieldStart:
                if c == "\"" {
                    state = .quoted
                    endsWithRecordSeparator = false
                } else if c == "," {
                    fields.append("")
                    endsWithRecordSeparator = false
                } else if isRecordSeparator(c) {
                    fields.append("")
                    records.append(fields)
                    fields = []
                    let separator: String
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" {
                        i += 1
                        separator = "\r\n"
                    } else {
                        separator = String(c)
                    }
                    if firstRecordSeparator == nil { firstRecordSeparator = separator }
                    endsWithRecordSeparator = true
                } else {
                    value.append(c)
                    state = .unquoted
                    endsWithRecordSeparator = false
                }
            case .unquoted:
                if c == "\"" {
                    return nil
                } else if c == "," {
                    fields.append(value)
                    value = ""
                    state = .fieldStart
                    endsWithRecordSeparator = false
                } else if isRecordSeparator(c) {
                    fields.append(value)
                    value = ""
                    records.append(fields)
                    fields = []
                    state = .fieldStart
                    let separator: String
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" {
                        i += 1
                        separator = "\r\n"
                    } else {
                        separator = String(c)
                    }
                    if firstRecordSeparator == nil { firstRecordSeparator = separator }
                    endsWithRecordSeparator = true
                } else {
                    value.append(c)
                    endsWithRecordSeparator = false
                }
            case .quoted:
                if c == "\"", i + 1 < chars.count, chars[i + 1] == "\"" {
                    value.append("\"")
                    i += 1
                } else if c == "\"" {
                    state = .afterQuote
                } else {
                    value.append(c)
                }
            case .afterQuote:
                if c == "," {
                    fields.append(value)
                    value = ""
                    state = .fieldStart
                    endsWithRecordSeparator = false
                } else if isRecordSeparator(c) {
                    fields.append(value)
                    value = ""
                    records.append(fields)
                    fields = []
                    state = .fieldStart
                    let separator: String
                    if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" {
                        i += 1
                        separator = "\r\n"
                    } else {
                        separator = String(c)
                    }
                    if firstRecordSeparator == nil { firstRecordSeparator = separator }
                    endsWithRecordSeparator = true
                } else {
                    return nil
                }
            }
            i += 1
        }

        if case .quoted = state { return nil }
        if !endsWithRecordSeparator {
            fields.append(value)
            records.append(fields)
        }
        // A contribution is a table, not just a stream of individually valid records. Once a
        // nonempty row differs from the header width, column identity is unknowable and blanking
        // a nominal location index could leave a shifted coordinate intact. Reject the document;
        // preserved blank records carry no data and are intentionally exempt.
        let headerWidth = records.first?.count ?? 0
        if records.dropFirst().contains(where: { record in
            record.contains(where: { !$0.isEmpty }) && record.count != headerWidth
        }) { return nil }

        return ParsedDocument(records: records, recordSeparator: firstRecordSeparator ?? "\n",
                              endsWithRecordSeparator: endsWithRecordSeparator)
    }

    private static func serialize(_ records: [[String]], separator: String,
                                  trailingSeparator: Bool) -> String {
        if records.isEmpty { return "" }
        let body = records.map { $0.map(field).joined(separator: ",") }.joined(separator: separator)
        return trailingSeparator ? body + separator : body
    }

    /// Recover only a valid physical header from a malformed document. Observation rows are
    /// dropped because their column boundaries are unknowable and could otherwise leak location.
    private static func safeHeader(_ csv: String) -> String {
        let physicalHeader = String(csv.split(maxSplits: 1, omittingEmptySubsequences: false,
                                              whereSeparator: isRecordSeparator).first ?? "")
        guard let header = parseDocument(physicalHeader)?.records.first else { return "" }
        return header.map(field).joined(separator: ",")
    }

    /// Re-serialise one field, quoting only when needed. Mirrors BLEManager.csvSafe.
    static func field(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\r\n")
            || s.contains("\n") || s.contains("\r") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
