import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

// Widget-local slice of the app's Crimson theme. The shared ActivityAttributes is
// intentionally Color-free and the extension does not compile Theme.swift, so the
// widget owns its own tokens. Fonts are bundled into the extension (see Info.plist
// UIAppFonts): Space Grotesk Bold for digits, JetBrains Mono Medium for kickers.
private enum WidgetTheme {
    static let crimson = Color(red: 0xEE / 255, green: 0x40 / 255, blue: 0x34 / 255)
    static let amber   = Color(red: 0xF2 / 255, green: 0xB5 / 255, blue: 0x3C / 255)
    static let bodyCam = Color(red: 0xCD / 255, green: 0xC1 / 255, blue: 0xC3 / 255)
    static let tracker = Color(red: 0x49 / 255, green: 0xC5 / 255, blue: 0xB1 / 255)
    /// Network-camera column. Distinct from `tracker`, which it briefly shared, so two adjacent
    /// columns are not the same colour at a glance.
    static let teal    = Color(red: 0x6E / 255, green: 0xA8 / 255, blue: 0xE0 / 255)
    static let glasses = Color(red: 0xB0 / 255, green: 0x7C / 255, blue: 0xFF / 255)

    /// Display face for digits: Space Grotesk Bold.
    static func digits(_ size: CGFloat) -> Font { .custom("SpaceGrotesk-Bold", size: size) }
    /// Data / kicker face: JetBrains Mono Medium.
    static func mono(_ size: CGFloat) -> Font { .custom("JetBrainsMono-Medium", size: size) }
}

// Widget-local presentation tokens for the six detection buckets. The symbol map
// mirrors the app's DeviceType, kept self-contained here.
private enum DetCat: String, CaseIterable {
    // rawValue MUST equal the matching WidgetCategory rawValue: DetectionState.enabled
    // carries those strings and this is what matches them back to a column.
    case alpr = "ALPR", drone = "DRONE", bodyCam = "BODY", tracker = "TRACKER"
    case glasses = "GLASSES", camera = "CAMERA"

    var symbol: String {
        switch self {
        case .alpr:    return "camera.fill"
        case .drone:   return "airplane"
        case .bodyCam: return "person.fill.viewfinder"
        case .tracker: return "dot.radiowaves.left.and.right"
        case .glasses: return "eyeglasses"
        case .camera:  return "video.fill"
        }
    }
    var tint: Color {
        switch self {
        case .alpr:    return WidgetTheme.crimson
        case .drone:   return WidgetTheme.amber
        case .bodyCam: return WidgetTheme.bodyCam
        case .tracker: return WidgetTheme.tracker
        case .glasses: return WidgetTheme.glasses
        case .camera:  return WidgetTheme.teal   // its own tint: reusing the tracker colour made two adjacent columns indistinguishable
        }
    }
    var label: String {
        switch self {
        case .alpr:    return "ALPR"
        case .drone:   return "DRONE"
        case .bodyCam: return "BODY"
        case .tracker: return "TRACK"
        case .glasses: return "GLASS"
        case .camera:  return "CAM"
        }
    }
    var spokenLabel: String {
        switch self {
        case .alpr: return "automatic license plate readers"
        case .drone: return "drones"
        case .bodyCam: return "body cameras"
        case .tracker: return "item trackers"
        case .glasses: return "recording glasses"
        case .camera: return "network cameras"
        }
    }
    func count(_ s: DetectionActivityAttributes.DetectionState) -> Int {
        switch self {
        case .alpr:    return s.alpr
        case .drone:   return s.drones
        case .bodyCam: return s.bodyCams
        case .tracker: return s.trackers
        case .glasses: return s.glasses
        case .camera:  return s.cameras
        }
    }
}

/// The columns to draw: exactly the detectors the board reports ON, in canonical order.
///
/// A zero under an enabled detector means "watching, nothing found" and is worth showing. A zero
/// under a disabled one implies coverage that is not running, which is why this is driven off the
/// board's toggles rather than off the counts. Falls back to the historical five only when
/// `enabled` is nil (no status yet, or an activity started by a build that predates the field);
/// an EMPTY set means every detector is genuinely off and draws no columns - the call sites
/// render "all detectors off" instead.
private func visibleCats(_ s: DetectionActivityAttributes.DetectionState) -> [DetCat] {
    // nil = no status yet -> fall back to the historical five rather than render nothing.
    // [] = every detector genuinely OFF -> draw NOTHING. Those two cases used to collapse into the
    // same empty array, which made this branch unreachable and left five phantom columns claiming
    // coverage that is not running. Keep `enabled` optional for exactly this reason.
    guard let on = s.enabled else { return [.alpr, .drone, .bodyCam, .tracker, .glasses] }
    let set = Set(on)
    return DetCat.allCases.filter { set.contains($0.rawValue) }
}

/// Dynamic Island slots go to whichever buckets are actually firing: leading and
/// trailing get the top two by live count, expanded bottom-left gets the third.
/// Zero-count buckets never claim a slot, so all six (glasses and cameras included) are
/// reachable; when everything is zero the first three fall back in fixed order.
private func rankedCats(_ s: DetectionActivityAttributes.DetectionState) -> [DetCat] {
    // Imperative on purpose: the chained tuple map/sort was too much for the type-checker.
    var live: [(idx: Int, cat: DetCat, n: Int)] = []
    for (idx, cat) in visibleCats(s).enumerated() {
        let n = cat.count(s)
        if n > 0 { live.append((idx: idx, cat: cat, n: n)) }
    }
    live.sort { a, b in
        if a.n != b.n { return a.n > b.n }
        return a.idx < b.idx
    }
    if live.isEmpty { return Array(visibleCats(s).prefix(3)) }   // all-zero: first three ENABLED, not first three defined
    return live.map { $0.cat }
}

/// VoiceOver should never announce "1 detections" on a glanceable count surface.
private func detectionCountPhrase(_ count: Int, nearby: Bool = false) -> String {
    let noun = count == 1 ? "detection" : "detections"
    return nearby ? "\(count) nearby \(noun)" : "\(count) \(noun)"
}

/// Tapping any Live Mode surface deep-links into the app's Log tab with the NEW
/// filter armed (RootView routes the URL, DetectionsView reads the pending flag).
private let driveModeDeepLink = URL(string: "beacons://log/new")

// TODO(iOS27, wire up after Xcode 27 GM ~Sept 2026; these need the iOS 27 SDK and
// won't compile on stable Xcode 26.5, so they are intentionally NOT added yet):
//   • @Environment(\.isDynamicIslandLimitedInWidth) in compactLeading/compactTrailing
//     -> collapse to icon + number when the Island is width-limited (landscape mount).
//   • @Environment(\.showsWidgetContainerBackground) in LockScreenView -> paint the
//     panel edge-to-edge in StandBy (charging + landscape dock).
// Landscape Dynamic Island rendering itself is automatic on iOS 27, no code needed.

/// The Live Mode detection counter, presented on the Lock Screen and in the
/// Dynamic Island. One ActivityConfiguration drives both surfaces.
struct DetectionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DetectionActivityAttributes.self) { context in
            // Routes by activity family: Lock Screen (medium), and the compact "small"
            // cell that iOS 26 auto-mirrors onto the CarPlay Dashboard (also the Watch
            // Smart Stack). The small family is declared below via supplementalActivityFamilies.
            DetectionActivityContent(state: context.state, deviceName: context.attributes.deviceName)
                .widgetURL(driveModeDeepLink)
                .activityBackgroundTint(Color.black.opacity(0.92))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            let ranked = rankedCats(s)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if ranked.count > 0 { StatBadge(cat: ranked[0], state: s) }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if ranked.count > 1 { StatBadge(cat: ranked[1], state: s) }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(s.connected ? "LIVE MODE" : "RECONNECTING")
                            .font(WidgetTheme.mono(9)).tracking(1.6)
                            .foregroundStyle(s.connected ? Color.white.opacity(0.6) : WidgetTheme.amber)
                        Text("\(s.total)")
                            .font(WidgetTheme.digits(20))
                            .monospacedDigit()
                    }
                    .widgetURL(driveModeDeepLink)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Live Mode, \(detectionCountPhrase(s.total, nearby: true))")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 12) {
                        if ranked.count > 2 { StatBadge(cat: ranked[2], state: s) }
                        Spacer(minLength: 4)
                        Group {
                            if s.enabled?.isEmpty == true {
                                Text("all detectors off").foregroundStyle(.secondary)
                            } else if s.total > 0 && s.lastKind.isEmpty {
                                // Nonzero total with no LIVE lastKind (post-relaunch, offline replay): say how
                                // many, never "no detections" over real hits.
                                Text("\(s.total) seen").foregroundStyle(.secondary)
                            } else if s.total > 0 {
                                Text("last \(s.lastKind) ").foregroundStyle(.secondary)
                                + Text(s.lastSeen, style: .relative).foregroundStyle(.secondary)
                                + Text(" ago").foregroundStyle(.secondary)
                            } else {
                                Text("no detections").foregroundStyle(.secondary)
                            }
                        }
                        .font(WidgetTheme.mono(10))
                        Spacer(minLength: 4)
                    }
                }
            } compactLeading: {
                Image(systemName: s.connected ? "shield.lefthalf.filled" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(s.total > 0 ? WidgetTheme.crimson : Color.white.opacity(0.6))
                    .widgetURL(driveModeDeepLink)
                    .accessibilityLabel(s.connected ? "Live Mode active" : "Live Mode reconnecting")
            } compactTrailing: {
                Text("\(s.total)").font(WidgetTheme.digits(15)).monospacedDigit()
                    .accessibilityLabel(detectionCountPhrase(s.total, nearby: true))
            } minimal: {
                Text("\(s.total)").font(WidgetTheme.digits(15)).monospacedDigit()
                    .foregroundStyle(s.total > 0 ? WidgetTheme.crimson : Color.white)
                    .widgetURL(driveModeDeepLink)
                    .accessibilityLabel("Live Mode, \(detectionCountPhrase(s.total, nearby: true))")
            }
            .keylineTint(WidgetTheme.crimson)
        }
        // iOS 26 auto-mirrors the .small family onto the CarPlay Dashboard (no CarPlay
        // entitlement); also drives the Apple Watch Smart Stack. iOS 18+ API.
        .supplementalActivityFamilies([.small])
    }
}

// MARK: - Content router (Lock Screen vs CarPlay / Watch "small")

private struct DetectionActivityContent: View {
    @Environment(\.activityFamily) private var family
    let state: DetectionActivityAttributes.DetectionState
    let deviceName: String
    var body: some View {
        switch family {
        case .small:
            SmallCell(state: state)
        default:                       // .medium -> Lock Screen
            LockScreenView(state: state, deviceName: deviceName).padding(14)
        }
    }
}

/// Compact standalone cell for the CarPlay Dashboard (iOS 26 auto-mirror) and the Apple
/// Watch Smart Stack. Has to read on its own glance , just the shield, the total, a word.
private struct SmallCell: View {
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(state.total > 0 ? WidgetTheme.crimson : Color.white.opacity(0.6))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(state.total)")
                    .font(WidgetTheme.digits(22)).monospacedDigit()
                Text(stateLabel)
                    .font(WidgetTheme.mono(8)).tracking(0.8)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live Mode. \(detectionCountPhrase(state.total, nearby: true)). \(stateLabel).")
        .accessibilityHint("Opens the new detections log")
    }

    private var stateLabel: String {
        guard state.connected else { return "reconnecting" }
        // All detectors off is not "no detections", it is "not looking". Saying the former over an
        // explicitly empty enabled-set is the same lie the phantom columns were.
        if state.enabled?.isEmpty == true { return "all detectors off" }
        guard state.total > 0 else { return "no detections" }
        // Nonzero total but no LIVE lastKind (post-relaunch, or an offline replay whose rows count
        // but never set the live pointer): say how many, never "no detections" over real hits.
        guard !state.lastKind.isEmpty else { return "\(state.total) seen" }
        return "last · \(state.lastKind.lowercased())"
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let state: DetectionActivityAttributes.DetectionState
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(WidgetTheme.crimson)
                Text("BEACONS · LIVE MODE")
                    .font(WidgetTheme.mono(10)).tracking(1.6)
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if !state.connected {
                    Text("RECONNECTING")
                        .font(WidgetTheme.mono(9)).tracking(0.8)
                        .foregroundStyle(WidgetTheme.amber)
                }
                Button(intent: EndDriveModeIntent()) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("End Live Mode")
                .accessibilityHint("Removes Live Mode from supported system surfaces")
            }
            if state.redact {
                // Lock-Screen privacy (user setting, ships OFF so counts are visible unless the
                // user hides them): when ON, no counts or per-category breakdown on a locked
                // phone, so a glance reveals nothing about what's being detected. Full counts
                // still show in the Dynamic Island and in the app.
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
                    Text(state.connected ? "Live Mode active · counts hidden" : "Reconnecting…")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
            } else {
                HStack(spacing: 8) {
                    // An explicit empty set means EVERY detector is off. Rendering nothing there
                    // reads as a broken widget; say it, matching Android's breakdownOf().
                    let cats = visibleCats(state)
                    if cats.isEmpty {
                        Text("all detectors off")
                            .font(WidgetTheme.mono(10)).foregroundStyle(.white.opacity(0.5))
                    } else {
                        ForEach(cats, id: \.self) { StatTile(cat: $0, state: state) }
                    }
                }
                HStack(spacing: 4) {
                    Text(deviceName).font(WidgetTheme.mono(9.5)).foregroundStyle(.white.opacity(0.33)).lineLimit(1)
                    Spacer(minLength: 6)
                    Group {
                        if state.total > 0 && state.lastKind.isEmpty {
                            Text("\(state.total) seen")
                        } else if state.total > 0 {
                            Text("last \(state.lastKind) ")
                            + Text(state.lastSeen, style: .relative)
                            + Text(" ago")
                        } else {
                            Text("no detections")
                        }
                    }
                    .font(WidgetTheme.mono(9.5)).foregroundStyle(.white.opacity(0.33))
                }
            }
        }
    }
}

private struct StatTile: View {
    let cat: DetCat
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        let n = cat.count(state)
        VStack(spacing: 3) {
            Image(systemName: cat.symbol).font(.system(size: 13))
                .foregroundStyle(n > 0 ? cat.tint : .white.opacity(0.35))
            Text("\(n)")
                .font(WidgetTheme.digits(18)).monospacedDigit()
                .foregroundStyle(n > 0 ? .white : .white.opacity(0.4))
            Text(cat.label)
                .font(WidgetTheme.mono(8)).tracking(0.8)
                .foregroundStyle(n > 0 ? cat.tint : .white.opacity(0.35))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cat.spokenLabel), \(detectionCountPhrase(n))")
    }
}

// MARK: - Dynamic Island badge

private struct StatBadge: View {
    let cat: DetCat
    let state: DetectionActivityAttributes.DetectionState
    var body: some View {
        let n = cat.count(state)
        HStack(spacing: 4) {
            Image(systemName: cat.symbol).font(.system(size: 12))
                .foregroundStyle(n > 0 ? cat.tint : Color.white.opacity(0.6))
            Text("\(n)").font(WidgetTheme.digits(15)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(cat.spokenLabel), \(detectionCountPhrase(n))")
    }
}
