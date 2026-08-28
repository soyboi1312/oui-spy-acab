package tech.acab.app.ble

/*
 * Location redaction for a SHARED contribution CSV.
 *
 * A contribution can leave the phone, so its location must be a deliberate choice, not a default.
 * The detection CSV carries location from THREE distinct subjects and they must be controlled
 * SEPARATELY:
 *
 *   - approx_lat / approx_lon  = the CONTRIBUTOR'S PHONE position when it heard the device. This
 *     reveals the observer, not the surveillance gear, so it is removed by DEFAULT.
 *   - drone_lat / drone_lon = the AIRCRAFT's own position from its Remote ID broadcast. It
 *     describes the drone, not any person, so it is kept by default for a drone observation.
 *   - operator_lat / operator_lon / operator_alt_m = the OPERATOR position from the same
 *     broadcast. It can reveal where a PERSON is standing, which is exactly the class of data
 *     this file exists to guard, so it gets its own switch and is removed by DEFAULT even
 *     though it was broadcast. Altitude rides with it: the altitude OF a person's position is
 *     still that person's location (a floor, a rooftop, a parking-structure level), unlike the
 *     aircraft's altitude/speed/heading, which describe the machine and stay as telemetry.
 *
 * Columns are named EXPLICITLY, never matched on the text "lat"/"lon". That distinction is the
 * whole point: a rule that blanked every column containing "lat" would wrongly strip drone_lat
 * (broadcast, keepable) while a rule that only knew about approx_lat would be correct. The pure
 * functions below are unit-tested (ContributionCsvTest) so this cannot silently regress.
 */

/** The contributor's own phone position. Removed by default in a shared contribution. */
val OBSERVER_LOCATION_COLS = setOf("approx_lat", "approx_lon")

/** The aircraft position a drone broadcast about ITSELF over Remote ID. NOT the contributor's
 *  phone and not a person; kept by default. Deliberately does NOT include altitude/speed/heading,
 *  which are telemetry, not a place on a map. */
val DRONE_LOCATION_COLS = setOf("drone_lat", "drone_lon")

/** The OPERATOR position from the same Remote ID broadcast. Broadcast or not, it points at a
 *  person on the ground, so it rides its own switch, off by default. operator_alt_m is part of
 *  that position, not telemetry: the altitude of a person's location is location (it names the
 *  floor or rooftop they are standing on), so leaving it out let the export leak a coordinate
 *  the disclosure said was removed. Only the AIRCRAFT's altitude/speed/heading are telemetry. */
val OPERATOR_LOCATION_COLS = setOf("operator_lat", "operator_lon", "operator_alt_m")

/**
 * True when a device's presence overlaps a capture window. A bounded "Start -> observe -> Stop"
 * contribution exports ONLY the devices audible during [startMs, stopMs], not the whole history.
 *
 * Membership is OVERLAP, not containment: a device first heard before Start but still present
 * during the window WAS observed during it, so `firstSeen <= stop && lastSeen >= start`. Both times
 * are the phone's wall clock (firstSeenAt/lastSeenAt). A device with no phone-side timestamp
 * (e.g. a buffered replay never heard live) cannot be placed in a live window and is excluded,
 * which is the conservative call for "what came by while I was capturing".
 */
fun inCaptureWindow(firstSeenMs: Long?, lastSeenMs: Long?, startMs: Long, stopMs: Long): Boolean {
    if (firstSeenMs == null || lastSeenMs == null) return false
    return firstSeenMs <= stopMs && lastSeenMs >= startMs
}

/** Timestamp written by a bounded capture. Full history uses first-ever sighting; a bounded row
 *  must name when the device was heard inside this window. The caller freezes [lastSeenMs] at Stop;
 *  clamping is a final invariant guard and keeps every emitted instant in [startMs, stopMs]. */
fun captureTimestamp(lastSeenMs: Long?, startMs: Long, stopMs: Long): Long? =
    lastSeenMs?.coerceIn(startMs, stopMs)

/** Which columns to blank, from the three independent policy switches. */
fun contributionBlankColumns(
    includeObserverLocation: Boolean,
    includeDroneLocation: Boolean,
    includeOperatorLocation: Boolean,
): Set<String> =
    buildSet {
        if (!includeObserverLocation) addAll(OBSERVER_LOCATION_COLS)
        if (!includeDroneLocation) addAll(DRONE_LOCATION_COLS)
        if (!includeOperatorLocation) addAll(OPERATOR_LOCATION_COLS)
    }

/**
 * Return a copy of [csv] with the named columns blanked, structure otherwise intact. NEVER mutates
 * the source: the caller redacts the EXPORTED copy only, the app's own log is untouched.
 *
 * Quote-aware on purpose. Earlier columns (type label, maker, rid) can be quoted and contain
 * commas or record separators, so splitting on ',' or '\n' would misalign and blank the wrong
 * field. It parses the complete RFC 4180 document, blanks target columns by their HEADER-derived
 * index, and re-serialises. Malformed quoted input fails closed to a header-only CSV: sharing no
 * observations is safer than returning a row whose location fields could not be identified. A
 * requested column the header does not carry fails closed the same way, for the same reason.
 */
fun redactCsvColumns(csv: String, blankColumnNames: Set<String>): String {
    if (csv.isEmpty()) return csv
    val document = parseCsvDocument(csv) ?: return safeCsvHeader(csv)
    if (blankColumnNames.isEmpty()) return csv
    val header = document.records.firstOrNull() ?: return ""
    // Every policy column must be present. The emitter's header is DETECTION_CSV_COLUMNS and every
    // set here is a subset of it, so a missing name means the two drifted - a renamed column - and
    // blanking only the names that still match would ship the renamed coordinate under its new name
    // in a file whose disclosure says it was removed. This used to return the ORIGINAL csv in that
    // case, which is the one outcome the whole file exists to prevent. Partial matches fail closed
    // too: half a policy applied is not the policy.
    // iOS twin: the `blankColumns.allSatisfy` guard in ContributionCsv.redact, backed the same way
    // by ContributionCsv.detectionColumns. A redaction policy that cannot be applied must never
    // emit the unredacted column, on either platform.
    if (!blankColumnNames.all { it in header }) return safeCsvHeader(csv)
    val blankIdx = header.withIndex().filter { it.value in blankColumnNames }.map { it.index }.toSet()

    val redacted = ArrayList<List<String>>(document.records.size)
    redacted.add(header)
    for (record in document.records.drop(1)) {
        val fields = record.toMutableList()
        for (b in blankIdx) if (b < fields.size) fields[b] = ""
        redacted.add(fields)
    }
    return serialiseCsv(redacted, document.recordSeparator, document.endsWithRecordSeparator)
}

/** Number of real observation records after the header. Unlike counting physical newlines, this
 * stays correct when a quoted field contains CRLF/LF and ignores preserved empty records. A
 * malformed document returns zero because its record boundaries cannot be trusted. */
fun contributionCsvDataRowCount(csv: String): Int {
    val records = parseCsvDocument(csv)?.records ?: return 0
    return records.drop(1).count { record -> record.any { it.isNotEmpty() } }
}

private enum class CsvParseState { FIELD_START, UNQUOTED, QUOTED, AFTER_QUOTE }

internal data class ParsedCsvDocument(
    val records: List<List<String>>,
    val recordSeparator: String,
    val endsWithRecordSeparator: Boolean,
)

/** Strict RFC 4180 document parser. Newlines inside quoted fields belong to that field, while
 * CRLF, LF, and CR outside quotes terminate a record. Quotes in an unquoted field, bytes after a
 * closing quote, and unterminated quoted fields are malformed and return null. */
internal fun parseCsvDocument(csv: String): ParsedCsvDocument? {
    if (csv.isEmpty()) return ParsedCsvDocument(emptyList(), "\n", false)

    val records = ArrayList<List<String>>()
    var fields = ArrayList<String>()
    var field = StringBuilder()
    var state = CsvParseState.FIELD_START
    var recordSeparator: String? = null
    var endsWithRecordSeparator = false
    var i = 0
    while (i < csv.length) {
        val c = csv[i]
        when (state) {
            CsvParseState.FIELD_START -> when (c) {
                '"' -> { state = CsvParseState.QUOTED; endsWithRecordSeparator = false }
                ',' -> { fields.add(""); endsWithRecordSeparator = false }
                '\r', '\n' -> {
                    fields.add("")
                    records.add(fields)
                    fields = ArrayList()
                    val separator = if (c == '\r' && i + 1 < csv.length && csv[i + 1] == '\n') {
                        i++
                        "\r\n"
                    } else c.toString()
                    if (recordSeparator == null) recordSeparator = separator
                    endsWithRecordSeparator = true
                }
                else -> { field.append(c); state = CsvParseState.UNQUOTED; endsWithRecordSeparator = false }
            }
            CsvParseState.UNQUOTED -> when (c) {
                '"' -> return null
                ',' -> {
                    fields.add(field.toString())
                    field = StringBuilder()
                    state = CsvParseState.FIELD_START
                    endsWithRecordSeparator = false
                }
                '\r', '\n' -> {
                    fields.add(field.toString())
                    field = StringBuilder()
                    records.add(fields)
                    fields = ArrayList()
                    state = CsvParseState.FIELD_START
                    val separator = if (c == '\r' && i + 1 < csv.length && csv[i + 1] == '\n') {
                        i++
                        "\r\n"
                    } else c.toString()
                    if (recordSeparator == null) recordSeparator = separator
                    endsWithRecordSeparator = true
                }
                else -> { field.append(c); endsWithRecordSeparator = false }
            }
            CsvParseState.QUOTED -> when {
                c == '"' && i + 1 < csv.length && csv[i + 1] == '"' -> { field.append('"'); i++ }
                c == '"' -> state = CsvParseState.AFTER_QUOTE
                else -> field.append(c)
            }
            CsvParseState.AFTER_QUOTE -> when (c) {
                ',' -> {
                    fields.add(field.toString())
                    field = StringBuilder()
                    state = CsvParseState.FIELD_START
                    endsWithRecordSeparator = false
                }
                '\r', '\n' -> {
                    fields.add(field.toString())
                    field = StringBuilder()
                    records.add(fields)
                    fields = ArrayList()
                    state = CsvParseState.FIELD_START
                    val separator = if (c == '\r' && i + 1 < csv.length && csv[i + 1] == '\n') {
                        i++
                        "\r\n"
                    } else c.toString()
                    if (recordSeparator == null) recordSeparator = separator
                    endsWithRecordSeparator = true
                }
                else -> return null
            }
        }
        i++
    }

    if (state == CsvParseState.QUOTED) return null
    if (!endsWithRecordSeparator) {
        fields.add(field.toString())
        records.add(fields)
    }
    // A contribution is a table, not merely a stream of individually valid CSV records. If any
    // nonempty data record has a different width from the header, column identity is unknowable:
    // blanking index 10 could leave a shifted coordinate at index 9. Reject the whole document so
    // redaction falls back to the header and row counting reports zero. Preserved blank records
    // are harmless and intentionally exempt.
    val headerWidth = records.firstOrNull()?.size ?: 0
    if (records.drop(1).any { record ->
            record.any { it.isNotEmpty() } && record.size != headerWidth
        }) return null

    return ParsedCsvDocument(records, recordSeparator ?: "\n", endsWithRecordSeparator)
}

/** Compatibility helper for tests and callers parsing exactly one record. Malformed input returns
 * an empty list rather than exposing partially parsed fields. */
internal fun parseCsvLine(line: String): List<String> =
    parseCsvDocument(line)?.records?.singleOrNull() ?: emptyList()

private fun serialiseCsv(records: List<List<String>>, separator: String, trailingSeparator: Boolean): String {
    if (records.isEmpty()) return ""
    val body = records.joinToString(separator) { record -> record.joinToString(",") { csvField(it) } }
    return if (trailingSeparator) body + separator else body
}

/** Recover only a valid physical header after a malformed document. Observation rows are dropped
 * because their column boundaries are unknowable and could otherwise leak a location. */
private fun safeCsvHeader(csv: String): String {
    val boundary = csv.indexOfAny(charArrayOf('\r', '\n'))
    val physicalHeader = if (boundary >= 0) csv.substring(0, boundary) else csv
    val header = parseCsvDocument(physicalHeader)?.records?.singleOrNull() ?: return ""
    return header.joinToString(",") { csvField(it) }
}

/** Re-serialise one field, quoting only when needed. Mirrors AcabBleManager.csvSafe. */
internal fun csvField(s: String): String =
    if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r'))
        "\"" + s.replace("\"", "\"\"") + "\"" else s

/** Neutralize spreadsheet formulas in radio-controlled TEXT cells before RFC 4180 serialization.
 * Leading spaces/tabs are preserved, but do not bypass the check: Excel and Sheets can still
 * interpret a formula after them. Prefixing the whole value with an apostrophe makes the cell
 * literal without changing structural [csvField] behavior used by the redactor. */
internal fun spreadsheetSafeText(s: String): String {
    val first = s.indexOfFirst { it != ' ' && it != '\t' }
    if (first < 0) return s
    return if (s[first] == '=' || s[first] == '+' || s[first] == '-' || s[first] == '@') "'$s" else s
}

/** The externally sourced free-text cells in the production detection CSV. Keeping the selection
 * here makes it impossible to protect a helper in tests while the row emitter keeps using raw
 * radio strings. */
internal data class DetectionCsvExternalText(val uasId: String, val maker: String)

internal fun detectionCsvExternalText(uasId: String?, maker: String?): DetectionCsvExternalText =
    DetectionCsvExternalText(
        uasId = spreadsheetSafeText(uasId ?: ""),
        maker = spreadsheetSafeText(maker ?: ""),
    )
