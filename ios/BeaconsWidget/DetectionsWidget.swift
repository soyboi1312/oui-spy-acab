import WidgetKit
import SwiftUI

// Home-Screen glance widget: today's detection count, the last hit, and link state.
//
// A widget runs in its own process and cannot read the app's memory, so it reads a
// small summary the app writes to the shared App Group container. Keys and types are
// fixed by the widget data-sharing contract and MUST match what the app writes:
//   w_countToday (Int)    - detections seen since local midnight (app owns the reset)
//   w_lastType   (String) - category label of the most recent hit, empty if none
//   w_lastAt     (Double) - epoch seconds of the most recent hit, 0 if none
//   w_connected  (Bool)   - whether a beacon board is currently linked
//   w_c_<CAT>    (Int)    - today's count per category, one key per WidgetCategory case
//                           (w_c_ALPR, w_c_DRONE, w_c_BODY, w_c_TRACKER, w_c_GLASSES, w_c_CAMERA).
//                           Today-scoped and gated like w_countToday, so no key can exceed it;
//                           rows with no strip glyph (nearby device, watched, unknown) count in
//                           w_countToday but in no w_c_ key, so the cells may sum to LESS - see
//                           the MediumView comment below and writeWidgetSummary in BLEManager.
// The app calls WidgetCenter.shared.reloadAllTimelines() whenever it writes, so the
// glance updates promptly on change; the 15-minute timeline policy below is only a
// backstop so relative time and link state cannot drift too far while the app is idle.
private let appGroupID = "group.tech.beacons.app"

private enum WK {
    static let countToday = "w_countToday"
    static let day        = "w_day"
    static let lastType   = "w_lastType"
    static let lastAt     = "w_lastAt"
    static let connected  = "w_connected"
}

/// Local day index (whole days since epoch in the device's current time zone). MUST match the
/// app's widgetDayIndex so the widget agrees with the app about where the day boundary falls.
private func localDayIndex() -> Int {
    Int((Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())) / 86400)
}

// MARK: - Theme

// Widget-local slice of the app's Crimson theme. The extension does not compile the app
// target's Theme.swift, so the widget owns its own tokens (kept in sync with the values
// in DetectionLiveActivity.swift). Fonts are bundled into the extension (see Info.plist
// UIAppFonts): Space Grotesk Bold for digits, JetBrains Mono Medium for kickers.
private enum WidgetTheme {
    static let crimson = Color(red: 0xEE / 255, green: 0x40 / 255, blue: 0x34 / 255)
    static let amber   = Color(red: 0xF2 / 255, green: 0xB5 / 255, blue: 0x3C / 255)
    static let bodyCam = Color(red: 0xCD / 255, green: 0xC1 / 255, blue: 0xC3 / 255)
    static let tracker = Color(red: 0x49 / 255, green: 0xC5 / 255, blue: 0xB1 / 255)
    static let glasses = Color(red: 0xB0 / 255, green: 0x7C / 255, blue: 0xFF / 255)
    static let netcam  = Color(red: 0x3D / 255, green: 0x8B / 255, blue: 0xFF / 255)
    static let clear   = Color(red: 0x5A / 255, green: 0xD0 / 255, blue: 0x8A / 255)  // "all clear" green

    /// Display face for digits: Space Grotesk Bold.
    static func digits(_ size: CGFloat) -> Font { .custom("SpaceGrotesk-Bold", size: size) }
    /// Data / kicker face: JetBrains Mono Medium.
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Medium", size: size) }
}

/// Best-effort symbol/tint for the last-hit label. The app writes a free-form category
/// string (e.g. "ALPR Camera", "Body Camera", "Tracker"), so match on keywords rather
/// than an exact enum: robust to whichever label format the app chooses, and falls back
/// to a neutral shield when nothing matches.
///
/// ORDER MATTERS, and it is the whole correctness story here. Three of the app's labels
/// end in "camera" ("ALPR Camera", "Body Camera", "Network camera"), so the broad CAMERA
/// test has to run LAST among them or it swallows the other two and draws them as ALPR in
/// ALPR crimson. Same shape for "Flock Raven", which is an audio sensor, not a camera, and
/// would otherwise be caught by FLOCK. Every keyword below is checked before the broad one
/// it would collide with; keep new keywords specific-first.
private struct LastLook {
    let symbol: String
    let tint: Color

    init(_ raw: String) {
        let s = raw.uppercased()
        if s.contains("BODY") {
            symbol = "person.fill.viewfinder"; tint = WidgetTheme.bodyCam
        } else if s.contains("NETWORK") {
            symbol = "web.camera.fill"; tint = WidgetTheme.netcam
        } else if s.contains("RAVEN") {
            symbol = "waveform"; tint = WidgetTheme.crimson
        } else if s.contains("ALPR") || s.contains("FLOCK") || s.contains("CAMERA") {
            symbol = "camera.fill"; tint = WidgetTheme.crimson
        } else if s.contains("DRONE") {
            symbol = "airplane"; tint = WidgetTheme.amber
        } else if s.contains("TRACK") {
            symbol = "dot.radiowaves.left.and.right"; tint = WidgetTheme.tracker
        } else if s.contains("GLASS") {
            symbol = "eyeglasses"; tint = WidgetTheme.glasses
        } else if s.contains("WATCH") {
            symbol = "star.fill"; tint = WidgetTheme.amber
        } else {
            symbol = "shield.lefthalf.filled"; tint = Color.white.opacity(0.7)
        }
    }
}

// MARK: - Timeline

/// One category's count for the medium strip.
struct CategoryCount: Identifiable {
    let cat: WidgetCategory
    let n: Int
    var id: WidgetCategory { cat }
}

struct DetectionsEntry: TimelineEntry {
    let date: Date
    let countToday: Int
    let lastType: String
    let lastAt: Date?     // nil when there is no recorded last hit
    let connected: Bool
    /// Today's per-category counts, same day-stamp rule as countToday. Only non-zero entries are
    /// drawn, so a quiet day collapses the strip instead of showing six zeroes.
    /// A struct, not a tuple: ForEach needs an id key path and Swift has no key paths into tuples.
    let categories: [CategoryCount]

    var hasLast: Bool { lastAt != nil && !lastType.isEmpty }
    var hasCategories: Bool { !categories.isEmpty }
}

struct DetectionsProvider: TimelineProvider {
    /// Shown in the widget gallery and before the first read resolves.
    func placeholder(in context: Context) -> DetectionsEntry {
        DetectionsEntry(date: Date(), countToday: 0, lastType: "", lastAt: nil, connected: false,
                        categories: [])
    }

    func getSnapshot(in context: Context, completion: @escaping (DetectionsEntry) -> Void) {
        completion(readEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DetectionsEntry>) -> Void) {
        let entry = readEntry()
        // Reload every ~15 minutes as a backstop; the app also forces an immediate reload
        // on every write, so this only bounds drift while the app is idle.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// Read the shared summary. The app owns the local-midnight reset and stamps w_day next to
    /// the count, but a widget refresh can land AFTER local midnight while the app has been idle
    /// since yesterday (no write to reset the count). Honesty at the day boundary: show 0 unless
    /// the stored day is today, so the glance never reads yesterday's total as "today". The count
    /// is only trustworthy for the day it was stamped. Mirrors Android BeaconsWidgetProvider.
    private func readEntry() -> DetectionsEntry {
        let d = UserDefaults(suiteName: appGroupID)
        let storedDay = d?.integer(forKey: WK.day) ?? 0
        let count = (storedDay == localDayIndex()) ? (d?.integer(forKey: WK.countToday) ?? 0) : 0
        let type  = d?.string(forKey: WK.lastType) ?? ""
        let atRaw = d?.double(forKey: WK.lastAt) ?? 0
        let connected = d?.bool(forKey: WK.connected) ?? false
        let at: Date? = atRaw > 0 ? Date(timeIntervalSince1970: atRaw) : nil
        // Same stale-day rule as the headline count: a breakdown from yesterday next to a zeroed
        // total would be worse than showing nothing.
        let cats: [CategoryCount] = (storedDay == localDayIndex())
            ? WidgetCategory.allCases.compactMap { c in
                  let n = d?.integer(forKey: c.defaultsKey) ?? 0
                  return n > 0 ? CategoryCount(cat: c, n: n) : nil
              }
            : []
        return DetectionsEntry(date: Date(), countToday: count, lastType: type, lastAt: at,
                               connected: connected, categories: cats)
    }
}

// MARK: - Views

/// Connection status dot: crimson when linked, dim gray when not.
private struct LinkDot: View {
    let connected: Bool
    var body: some View {
        Circle()
            .fill(connected ? WidgetTheme.crimson : Color.white.opacity(0.28))
            .frame(width: 7, height: 7)
    }
}

/// Lowercase "beacons" wordmark plus a link dot, the shared header for both sizes.
private struct WidgetHeader: View {
    let connected: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text("beacons")
                .font(WidgetTheme.mono(11)).tracking(1.2)
                .foregroundStyle(.white.opacity(0.6))
            Spacer(minLength: 4)
            LinkDot(connected: connected)
        }
    }
}

/// The last-detection line (category + "3m ago"), or an honest empty state. Uses a
/// self-updating relative Text so "ago" stays fresh between the 15-minute reloads.
private struct LastHitLine: View {
    let entry: DetectionsEntry
    var compact: Bool

    var body: some View {
        if entry.hasLast, let at = entry.lastAt {
            let look = LastLook(entry.lastType)
            HStack(spacing: 5) {
                Image(systemName: look.symbol)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(look.tint)
                (Text(entry.lastType + " ")
                    + Text(at, style: .relative)
                    + Text(" ago"))
                    .font(WidgetTheme.mono(compact ? 9.5 : 11))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        } else {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundStyle(WidgetTheme.clear)
                Text(entry.connected ? "no detections" : "not connected")
                    .font(WidgetTheme.mono(compact ? 9.5 : 11))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer(minLength: 0)
            }
        }
    }
}

/// Today's count with its kicker. Crimson when anything fired today, dim when zero.
private struct CountBlock: View {
    let entry: DetectionsEntry
    var size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(entry.countToday)")
                .font(WidgetTheme.digits(size)).monospacedDigit()
                .foregroundStyle(entry.countToday > 0 ? .white : .white.opacity(0.55))
            Text("today")
                .font(WidgetTheme.mono(9)).tracking(1.0)
                .foregroundStyle(entry.countToday > 0 ? WidgetTheme.crimson : .white.opacity(0.4))
        }
    }
}

private struct SmallView: View {
    let entry: DetectionsEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeader(connected: entry.connected)
            Spacer(minLength: 4)
            CountBlock(entry: entry, size: 46)
            Spacer(minLength: 6)
            LastHitLine(entry: entry, compact: true)
        }
    }
}

/// Tints for the strip. Defined widget-side because WidgetCategory lives in Shared/, which imports
/// only ActivityKit + Foundation, and Color needs SwiftUI. Values match WidgetTheme, which in turn
/// mirrors the app's per-type tints, so a body-cam count reads the same colour here as in the app.
private extension WidgetCategory {
    var tint: Color {
        switch self {
        case .alpr:    return WidgetTheme.crimson
        case .drone:   return WidgetTheme.amber
        case .body:    return WidgetTheme.bodyCam
        case .tracker: return WidgetTheme.tracker
        case .glasses: return WidgetTheme.glasses
        case .camera:  return WidgetTheme.netcam
        }
    }
}

/// Today's breakdown as a single compact row: glyph + count per category, non-zero only.
///
/// A ROW, not a list. Medium is short and already carries the header, the count, the link state and
/// the last-hit line, so six stacked rows would not fit. Six glyph-and-count cells do. Empty
/// categories are dropped rather than shown as zeroes, so a quiet day just collapses the strip and
/// the layout gives the space back to whatever is above it.
private struct CategoryStrip: View {
    let items: [CategoryCount]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(items) { item in
                HStack(spacing: 3.5) {
                    Image(systemName: item.cat.symbol)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(item.cat.tint)
                    Text("\(item.n)")
                        .font(WidgetTheme.mono(11))
                        .foregroundStyle(.white.opacity(0.92))
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(item.n) \(item.cat.rawValue.lowercased())")
            }
            Spacer(minLength: 0)
        }
    }
}

private struct MediumView: View {
    let entry: DetectionsEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(connected: entry.connected)
            HStack(alignment: .bottom, spacing: 16) {
                CountBlock(entry: entry, size: 54)
                Spacer(minLength: 0)
                // Link state spelled out on the roomier medium face.
                HStack(spacing: 5) {
                    LinkDot(connected: entry.connected)
                    Text(entry.connected ? "connected" : "not connected")
                        .font(WidgetTheme.mono(9.5)).tracking(0.6)
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            // Sits directly under the headline number because it is a breakdown OF that number:
            // both are today-scoped and both skip rows whose time we cannot establish, so no
            // category cell can ever exceed the count above it. It is a breakdown of the PART of
            // that total the widget has a glyph for, though, not a partition of it: rows with no
            // strip cell (nearby device, watched, unknown) are counted in the headline and drawn
            // nowhere here, so the cells can sum to LESS. That is the deliberate rule on both
            // platforms - see writeWidgetSummary in BLEManager and its Android twin - and it reads
            // as "412 today, 3 of them ALPR", never as a lost count.
            if entry.hasCategories { CategoryStrip(items: entry.categories) }
            Spacer(minLength: 0)
            LastHitLine(entry: entry, compact: false)
        }
    }
}

// MARK: - Widget

struct DetectionsWidget: Widget {
    private let kind = "tech.beacons.app.detections"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: DetectionsProvider()) { entry in
            Group {
                if #available(iOS 17.0, *) {
                    DetectionsWidgetView(entry: entry)
                        .containerBackground(Color.black.opacity(0.92), for: .widget)
                } else {
                    DetectionsWidgetView(entry: entry)
                        .padding()
                        .background(Color.black.opacity(0.92))
                }
            }
        }
        .configurationDisplayName("beacons")
        .description("Today's detections at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Routes by family so the two sizes share one entry but lay out for their space.
private struct DetectionsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DetectionsEntry
    var body: some View {
        switch family {
        case .systemMedium: MediumView(entry: entry)
        default:            SmallView(entry: entry)
        }
    }
}
