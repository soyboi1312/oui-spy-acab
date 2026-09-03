import SwiftUI
import UIKit
import Combine

/// The ordered category set shown as filter tiles (Log) and chips (Map), defined once and
/// shared by both surfaces so they stay in lockstep as categories grow. Each entry carries a
/// representative DeviceType (supplies the tint + glyph), the `DeviceType.category` key it
/// filters on, and its labels. "Nearby Device" (Desert-mode ambient noise) is deliberately
/// absent - it is not a filter category.
struct DetectionCategory: Identifiable {
    let type: DeviceType    // representative type: supplies tint + SF Symbol
    let key: String         // the DeviceType.category key this chip/tile filters on
    let tileLabel: String   // compact label for the Log summary tiles
    let chipLabel: String   // label for the Map filter chip
    var id: String { key }
}

/// One-shot handoff from a Status category tile to the Log tab with that category filter
/// armed. Same static-slot + notification pattern as MapFocus (and deliberately NOT the
/// UserDefaults channel the Live Activity uses): a tile tap must never outlive the session,
/// or a stale persisted category would hijack an unrelated later launch's Log open.
/// MainTabView switches tabs on the notification; DetectionsView consumes the slot exactly
/// once (onAppear when the tab was cold, onReceive when it is already alive).
enum LogFocus {
    static var pendingCategory: String?
    static let notification = Notification.Name("acabFocusLogCategory")
}

/// ALPR, DRONE, BODY CAM, TRACKER, GLASSES, CAMERA (Network camera). Reuses each type's
/// existing tint + glyph (netcamTone + web.camera.fill for the CAMERA / networkCamera entry).
let detectionCategories: [DetectionCategory] = [
    .init(type: .flockCamera,      key: "ALPR",     tileLabel: "ALPR",  chipLabel: "ALPR"),
    .init(type: .drone,            key: "DRONE",    tileLabel: "DRONE", chipLabel: "DRONE"),
    .init(type: .axonBodyCam,      key: "BODY CAM", tileLabel: "BODY",  chipLabel: "BODY CAM"),
    .init(type: .tracker,          key: "TRACKER",  tileLabel: "TRKR",  chipLabel: "TRACKER"),
    .init(type: .recordingGlasses, key: "GLASSES",  tileLabel: "GLAS",  chipLabel: "GLASSES"),
    .init(type: .networkCamera,    key: "CAMERA",   tileLabel: "NETCAM", chipLabel: "NETWORK CAM"),
]

/// Logbook: detection history, with category tiles that double as filters over the
/// list below. New/All filtering, a "mark all seen" baseline, and a select mode for
/// bulk-muting rows.
struct DetectionsView: View {
    @EnvironmentObject var ble: BLEManager
    @State private var filter: String?     // category key: ALPR / DRONE / BODY CAM / TRACKER
    @State private var scope: StatusScope = .all   // all / new (after the seen watermark) / offline-recorded
    @State private var selecting = false   // bulk-select mode
    @State private var selection: Set<String> = []   // selected Detection.id
    @State private var exportFile: ExportFile?
    @State private var exportProblem: ExportProblem?
    @State private var confirmClear = false           // gate the destructive log wipe
    // Pause the live feed so a fast-scrolling list can actually be read. Paused freezes the
    // DISPLAYED rows to a snapshot; the store keeps accumulating in BLEManager (nothing is
    // dropped), and resume snaps back to live. The frozen export also owns NEW and time metadata,
    // so the visible row and any file made from it cannot drift apart.
    @State private var paused = false
    @State private var frozenExport: BLEManager.DetectionExportSnapshot?
    // The two things body reads out of that snapshot, taken ONCE at the freeze. Both are computed
    // properties on DetectionExportSnapshot (a full map, and a full Set build), and the store
    // keeps filling while paused - that is the point of pause - so body re-read them on every
    // ~3 Hz publish, over the whole capped store, in the one state the user entered to make the
    // screen hold still. The live path pays neither.
    @State private var frozenRows: [Detection] = []
    @State private var frozenIDs: Set<String> = []
    // T3: on regular width the log is a two-pane master/detail; this drives the right pane.
    // Never set at compact width, so the phone-portrait path is untouched.
    @State private var selectedDetail: Detection?
    @Environment(\.horizontalSizeClass) private var hSize
    // Accessibility text sizes reflow the tile strip into a grid and pad the scroll bottom.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Three-way status scope over the feed: everything, only-new (after the seen
    /// watermark), or only records the board buffered offline and replayed.
    private enum StatusScope { case all, new, offline }

    private struct ExportProblem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    private var shown: [Detection] {
        // Paused: read from the frozen snapshot so the list holds still. Live otherwise.
        let base = paused ? frozenRows : ble.logDetections
        return base.filter { d in
            (filter == nil || d.type.category == filter) && matchesScope(d)
        }
    }

    private func pauseFeed() {
        let snap = ble.detectionExportSnapshot()
        frozenExport = snap
        frozenRows = snap.detections
        frozenIDs = snap.ids
        paused = true
    }
    private func resumeFeed() {
        paused = false
        frozenExport = nil
        frozenRows = []
        frozenIDs = []
    }
    private func matchesScope(_ d: Detection) -> Bool {
        switch scope {
        case .all:     return true
        case .new:
            return paused ? (frozenExport?.unseenIDs.contains(d.id) == true) : ble.isUnseen(d)
        case .offline: return d.offline
        }
    }
    /// Everything one body eval needs from the store, computed in a single pass. shown /
    /// count(cat) / newCount / offlineCount used to be independent computed properties, each
    /// a full O(store) filter, and body read them ~12x per eval at the ~3 Hz publish cadence.
    private struct LogSnapshot {
        let shown: [Detection]
        let counts: [String: Int]   // per category key, unfiltered (feeds the tiles)
        let newCount: Int
        let offlineCount: Int
        /// While paused, how many detections have landed in the live store since the freeze -
        /// the "N new" hint. The store never stops filling; only the display is frozen. Counted
        /// in the pass below rather than by its own property: the header read it twice per eval
        /// (once for the test, once for the number), so it was two extra store walks on the one
        /// screen state that exists to be calm.
        let pausedNewCount: Int
    }

    private func makeSnapshot() -> LogSnapshot {
        var counts: [String: Int] = [:]
        var newN = 0, offN = 0, pausedNewN = 0
        for d in ble.logDetections {
            counts[d.type.category, default: 0] += 1
            if ble.isUnseen(d) { newN += 1 }
            if d.offline { offN += 1 }
            if paused && !frozenIDs.contains(d.id) { pausedNewN += 1 }
        }
        return LogSnapshot(shown: shown, counts: counts, newCount: newN, offlineCount: offN,
                           pausedNewCount: pausedNewN)
    }

    var body: some View {
        let snap = makeSnapshot()   // ONE store pass per body eval; everything below reads this
        NavigationStack {
            layout(snap)
                // R8: if the selected detection disappears (clear log / capped-store eviction) while its
                // dossier is open in the two-pane, drop the selection so the pane returns to the
                // placeholder instead of showing a detection that no longer exists.
                .onChange(of: ble.logDetections) {
                    if let d = selectedDetail, !ble.logDetections.contains(where: { $0.id == d.id }) {
                        selectedDetail = nil
                    }
                    // Log cleared out from under a paused view: drop the frozen snapshot so we
                    // don't keep showing rows that no longer exist and can't be resumed away from.
                    if paused && ble.logDetections.isEmpty { resumeFeed() }
                }
        }
    }

    /// Regular width: two-pane master/detail (list left, dossier right). Compact:
    /// today's single-column logbook, verbatim.
    @ViewBuilder
    private func layout(_ snap: LogSnapshot) -> some View {
        if hSize == .regular {
            HStack(spacing: 0) {
                masterList(snap).frame(width: 380)
                Divider().overlay(ACABTheme.line)
                ZStack {
                    ACABTheme.bg.ignoresSafeArea()
                    detailPane
                }
                .frame(maxWidth: .infinity)
            }
            // The embedded dossier carries .toolbar(.hidden, for: .tabBar); in this
            // persistent two-pane it would swallow the tab bar, so keep it visible.
            .toolbar(.visible, for: .tabBar)
        } else {
            masterList(snap)
        }
    }

    /// A picked row's full dossier, capped and centered in the right pane; a placeholder
    /// until something is selected.
    @ViewBuilder
    private var detailPane: some View {
        if let d = selectedDetail {
            DetectionDetailView(detection: d, embedded: true)
                .environmentObject(ble)
                .id(d.id)                       // fresh dossier (and its @State) per selection
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "scope").font(.system(size: 34)).foregroundStyle(ACABTheme.line)
                Text("Select a detection")
                    .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                Text("Pick a row to open its full dossier here.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    /// Today's logbook screen: the whole view when compact, the left column when regular.
    /// Keeps its own nav / sheet / dialog modifiers so both layouts get them.
    private func masterList(_ snap: LogSnapshot) -> some View {
            ZStack(alignment: .bottom) {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(snap)
                        // Persistent board-side loss/censoring flags belong beside the evidence,
                        // not behind a settings disclosure. The Offline Buffer card repeats them.
                        ForEach(ble.status?.bufferHealthNotices ?? [], id: \.self) {
                            BufferHealthBanner(notice: $0)
                        }
                        if !selecting && !ble.logDetections.isEmpty { actionChips }
                        summaryTiles(snap)
                        if !ble.logDetections.isEmpty { statusFilter(snap) }
                        if ble.logDetections.isEmpty { emptyState }
                        else if snap.shown.isEmpty { noMatchState }
                        else { logCard(snap) }
                        Spacer(minLength: selecting ? 72 : 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                    // T2: cap the readable column so tablets/landscape don't stretch a
                    // single column full-width. A no-op at phone portrait (~390pt < 640);
                    // the ScrollView itself stays full-width, only this content centers.
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                // Extra bottom margin only at accessibility sizes, so grown content never ends
                // under the tab bar; zero at default sizes (layout untouched).
                .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
                if selecting { selectBar }
            }
            .navigationBarHidden(true)
            .navigationDestination(for: Detection.self) { d in
                DetectionDetailView(detection: d)
            }
            .onAppear {
                // Drive-mode surfaces (widget / notification) deep-link here with
                // the NEW filter pre-armed via this flag; consume it once.
                let deepLinkNew = UserDefaults.standard.bool(forKey: "acab.pendingNewFilter")
                if deepLinkNew {
                    scope = .new
                    UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
                } else {
                    // First ordinary open, baseline the New dots to what is already here so a
                    // fresh install / first backlog is not a wall of dots. Once-only. Skipped on a
                    // NEW deep-link, or the baseline would erase the very rows it exists to show.
                    ble.seedSeenWatermarkOnce()
                }
                consumeLogFocus()   // Status-tile category handoff, cold-tab path
            }
            // A Live Activity tap while this tab is already showing never re-fires
            // onAppear; RootView posts this notification so the filter arms right away.
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("acabOpenLogNew"))) { _ in
                scope = .new
                UserDefaults.standard.removeObject(forKey: "acab.pendingNewFilter")
            }
            // Status-tile category handoff, warm-tab path (see LogFocus).
            .onReceive(NotificationCenter.default.publisher(for: LogFocus.notification)) { _ in
                consumeLogFocus()
            }
            .sheet(item: $exportFile) { ShareSheet(items: [$0.url]) }
            .alert(item: $exportProblem) { problem in
                Alert(title: Text(problem.title), message: Text(problem.message),
                      dismissButton: .default(Text("OK")))
            }
            .confirmationDialog("Clear \(ble.demoMode ? "sample" : "log") \(ble.logDetections.count) detection\(ble.logDetections.count == 1 ? "" : "s")?",
                                isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Export CSV first") {
                    export(.csv, snapshot: ble.detectionExportSnapshot(), qualifier: nil)
                }
                Button(ble.demoMode ? "Clear sample" : "Clear log", role: .destructive) {
                    if !ble.clearDetections() {
                        exportProblem = ExportProblem(
                            title: "Couldn't clear log",
                            message: "The saved log could not be secured for deletion. Nothing was cleared. Try again while the phone is unlocked.")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ble.demoMode
                     ? "This clears only the sample rows. Your saved detection log stays unchanged."
                     : "This deletes the log on this phone and can't be undone. If this is evidence, export it first.")
            }
    }

    private func header(_ snap: LogSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Logbook").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(selecting ? "\(selection.count) SELECTED"
                                 : "\(ble.logDetections.count) DETECTED · \(snap.newCount) NEW")
            }
            Spacer()
            if selecting {
                Button { exitSelect() } label: {
                    Text("DONE").font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 12).frame(height: 36)
                        .background(ACABTheme.bg2, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Labeled action chips under the title row (replaces the old anonymous
    /// icon buttons). Clear lives in the filter row (statusFilter), always reachable.
    private var actionChips: some View {
        // Horizontally scrollable because this row is now FOUR chips, and a filtered label
        // ("EXPORT BODY CAM CSV") is far wider than the unfiltered one. Android's twin got the
        // same treatment; without it the last chip is clipped with no way to reach it.
        ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
            actionChip("checkmark.circle", "SELECT") { resumeFeed(); selecting = true }   // bulk-mute acts on retained Log rows
            // CSV and GPX used to be two chips. That was two of the four slots in a row that must
            // scroll on a phone, spent on two variants of one action, so they fold into a single
            // EXPORT chip with a menu. Both formats still carry the CURRENT category filter, and
            // the chip names it ("EXPORT DRONE") so a partial export can't be mistaken for the
            // whole log. Mirrors Android LogScreen's export menu.
            Menu {
                Button {
                    export(.csv)
                } label: { Label("CSV, shown rows", systemImage: "tablecells") }
                Button {
                    export(.gpx)
                } label: { Label("GPX, for maps", systemImage: "mappin.and.ellipse") }
            } label: {
                chipLabel("square.and.arrow.up", filter.map { "EXPORT \($0)" } ?? "EXPORT")
            }
            .buttonStyle(.plain)
            actionChip("checkmark", "MARK SEEN") { ble.markAllSeen(); scope = .all }
        }
        }
    }

    // The chip's visual, factored out so the plain-action chips and the EXPORT menu share one
    // capsule. A Menu needs a label view, not a Button, so actionChip below wraps this in a Button
    // and the export menu uses it directly.
    private func chipLabel(_ system: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: system).font(.system(size: 11, weight: .semibold))
            Text(label).font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(ACABTheme.dim)
        .padding(.horizontal, 11).frame(height: 36)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
        // 44pt minimum hit target: the capsule stays 36pt visually, the extra height is
        // invisible tappable area (contentShape), so the look is unchanged.
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private func actionChip(_ system: String, _ label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(system, label) }
        .buttonStyle(.plain)
    }

    /// A strip of compact category tiles, one per category that has a detection this session;
    /// tapping one toggles it as a filter for the list. Dynamic so the row scales as categories
    /// grow and a zero-count (useless) filter never takes up space. At accessibility text sizes
    /// the strip reflows into a 3-wide grid: up to six-across tiles get ~55pt each while the
    /// labels quadruple, and the row became unreadable. Default layout untouched.
    @ViewBuilder
    private func summaryTiles(_ snap: LogSnapshot) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                ForEach(shownCategories(snap)) { c in
                    tile(c.type, c.key, c.tileLabel, count: snap.counts[c.key] ?? 0)
                }
            }
        } else {
            HStack(spacing: 8) {
                ForEach(shownCategories(snap)) { c in
                    tile(c.type, c.key, c.tileLabel, count: snap.counts[c.key] ?? 0)
                }
            }
        }
    }

    /// Which category tiles to actually render: a category with at least one detection this
    /// session, OR the currently-active filter even at count 0. The active-filter exception is
    /// REQUIRED: if the user has filtered to a category and its live count momentarily drops to 0
    /// (eviction / staleness), the tile must NOT vanish out from under them, or the filter breaks
    /// silently with no visible way to clear it. Empty row (nothing detected yet) is fine.
    private func shownCategories(_ snap: LogSnapshot) -> [DetectionCategory] {
        detectionCategories.filter { (snap.counts[$0.key] ?? 0) > 0 || filter == $0.key }
    }

    private func tile(_ type: DeviceType, _ cat: String, _ label: String, count n: Int) -> some View {
        let active = filter == cat
        return Button { filter = active ? nil : cat } label: {
            VStack(spacing: 5) {
                Image(systemName: type.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.tint)
                Text("\(n)")
                    .font(ACABTheme.display(18, weight: .bold))
                    .foregroundStyle(n == 0 ? ACABTheme.faint : ACABTheme.text)
                    .monospacedDigit()
                Text(label)
                    .font(ACABTheme.mono(8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(n == 0 ? ACABTheme.faint : type.textTint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(active ? type.tint.opacity(0.12) : ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(active ? type.tint.opacity(0.4) : ACABTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spokenCategory(label)), \(n) detection\(n == 1 ? "" : "s")")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityHint(active ? "Clears this filter" : "Filters the log to this category")
    }

    private func spokenCategory(_ label: String) -> String {
        // Tiles pass tileLabel ("BODY", "NETCAM", "TRKR"...), chips pass chipLabel ("BODY CAM",
        // "NETWORK CAM"...). Match BOTH spellings of each category, or the expansion silently
        // stops firing for one caller - which is exactly how "BODY" spent weeks announced as
        // "body" instead of "body cameras".
        switch label {
        case "ALPR": return "automatic license plate readers"
        case "BODY", "BODY CAM": return "body cameras"
        case "DRONE": return "drones"
        case "CAMERA", "NETCAM", "NETWORK CAM": return "network cameras"
        case "TRKR", "TRACKER": return "item trackers"
        case "GLAS", "GLASSES": return "recording glasses"
        default: return label.lowercased()
        }
    }

    /// All / New / Offline segmented chips ("mark all seen" lives in the header chips now).
    private func statusFilter(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            segChip("ALL", ble.logDetections.count, active: scope == .all) { scope = .all }
            segChip("NEW", snap.newCount, active: scope == .new, tint: ACABTheme.accent) { scope = .new }
            segChip("OFFLINE", snap.offlineCount, active: scope == .offline) { scope = .offline }
            Spacer(minLength: 0)
            // Quick clear at the top: reaching the bottom "clear log..." row is a long scroll
            // once the log is big. Goes through the same confirmation, quiet so it's not a mis-tap
            // magnet. Hidden in select mode (that's for bulk-muting, not clearing).
            if !selecting {
                // Icon-only (trash reads on its own): a worded chip crowds this row on
                // narrower screens - Android's equivalent wrapped "CLEAR" mid-word.
                Button { confirmClear = true } label: {
                    Image(systemName: "trash").font(.system(size: 13))
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        // Small destructive control: pad the hit area out to 44pt without
                        // growing the drawn capsule.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(ble.demoMode ? "Clear sample" : "Clear log")
            }
        }
    }

    private func segChip(_ label: String, _ n: Int, active: Bool,
                         tint: Color = ACABTheme.dim,
                         _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
                Text("\(n)").font(ACABTheme.mono(10))
                    .foregroundStyle(active ? ACABTheme.onAccent.opacity(0.7) : ACABTheme.faint)
            }
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? tint : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : ACABTheme.line, lineWidth: 1))
            // 44pt hit target; the drawn capsule keeps its size.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// The detection list (honoring the active filters), divider between rows.
    /// LazyVStack so a Desert-mode log of thousands only builds the rows on screen
    /// (was a plain VStack that materialized every row at once).
    private func logCard(_ snap: LogSnapshot) -> some View {
        let rows = snap.shown   // filtered once per body eval, in the snapshot
        return LazyVStack(alignment: .leading, spacing: 0) {
            logCardHeader(snap).padding(.bottom, 8)
            ForEach(rows) { d in
                row(d)
                if d.id != rows.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    /// Log heading plus the pause/resume control. Pausing shows a "PAUSED · N NEW" pill so it's
    /// obvious the feed is still filling behind the frozen list. Hidden in select mode (that's
    /// bulk-muting, which acts on the retained Log rows).
    private func logCardHeader(_ snap: LogSnapshot) -> some View {
        HStack(spacing: 8) {
            Kicker(logHeading)
            if paused {
                Text(snap.pausedNewCount > 0 ? "PAUSED \u{00B7} \(snap.pausedNewCount) NEW" : "PAUSED")
                    .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(ACABTheme.accent.opacity(0.12), in: Capsule())
            }
            Spacer(minLength: 0)
            if !selecting { pauseButton }
        }
    }

    /// Freeze / unfreeze the displayed feed. Accent-filled while paused so it reads as active.
    /// Icon-only: the header's "PAUSED · N NEW" pill already words the state, and the worded
    /// chip crowded this row (Android's equivalent wrapped its labels on narrower screens).
    private var pauseButton: some View {
        Button { paused ? resumeFeed() : pauseFeed() } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(paused ? ACABTheme.onAccent : ACABTheme.dim)
                .padding(.horizontal, 11).frame(height: 30)
                .background(paused ? ACABTheme.accent : ACABTheme.bg2, in: Capsule())
                .overlay(Capsule().strokeBorder(paused ? .clear : ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 30pt capsule.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(paused ? "Resume live feed" : "Pause live feed")
    }

    private var logHeading: String {
        let scopeTag: String
        switch scope {
        case .all:     scopeTag = "ALL"
        case .new:     scopeTag = "NEW"
        case .offline: scopeTag = "OFFLINE"
        }
        return filter == nil ? "\(scopeTag) DETECTIONS" : "\(filter!) \u{00B7} \(scopeTag)"
    }

    @ViewBuilder
    private func row(_ d: Detection) -> some View {
        // Resolved once per row: the log is where a buffered record is most likely to be read as
        // a plain timestamp, so the caveat has to travel with it.
        let basis = paused ? (frozenExport?.basis(for: d.id) ?? .unknown) : ble.timeBasis(for: d.id)
        if selecting {
            let selected = selection.contains(d.id)
            Button { toggle(d) } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(selected ? ACABTheme.accent : ACABTheme.faint)
                    DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else if hSize == .regular {
            // Two-pane: rows select the right dossier instead of pushing; the active
            // row carries a subtle highlight.
            Button { selectedDetail = d } label: {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selectedDetail?.id == d.id ? ACABTheme.lineStrong : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedDetail?.id == d.id ? .isSelected : [])
        } else {
            // Value-based nav: the destination is built ONCE on tap (via navigationDestination),
            // not eagerly per row. A closure-NavigationLink here would materialize a full
            // DetectionDetailView for every row in the LazyVStack, so fast-scrolling thousands of
            // rows spiked memory/CPU and crashed the app.
            NavigationLink(value: d) {
                DetectionRow(detection: d, timeBasis: basis, isMuted: ble.isIgnored(d.mac))
            }
            .buttonStyle(.plain)
        }
    }

    /// Export the exact rows the user is reviewing. A paused view keeps its row fields, NEW
    /// membership, timestamps, and observer positions frozen together; a live view takes one
    /// authoritative manager snapshot at the tap instead of exporting the delayed UI projection.
    private func export(_ format: BLEManager.ExportFormat,
                        snapshot supplied: BLEManager.DetectionExportSnapshot? = nil,
                        qualifier suppliedQualifier: String? = nil) {
        let base = supplied ?? (paused ? frozenExport : nil) ?? ble.detectionExportSnapshot()
        let scoped = supplied == nil
            ? base.filtered(category: filter, unseenOnly: scope == .new, offlineOnly: scope == .offline)
            : base
        let qualifier = suppliedQualifier ?? exportQualifier
        ble.writeDetections(format, snapshot: scoped, filenameQualifier: qualifier) { result in
            switch result {
            case .success(let url):
                exportFile = ExportFile(url: url)
            case .emptyGPX:
                exportProblem = ExportProblem(
                    title: "Nothing to map",
                    message: "None of the reviewed detections has a location. Export CSV instead; it keeps every reviewed row with blank location columns.")
            case .failure(let detail):
                exportProblem = ExportProblem(
                    title: "Export failed",
                    message: "The file could not be prepared. \(detail)")
            }
        }
    }

    private var exportQualifier: String? {
        var parts: [String] = []
        if let filter { parts.append(filter) }
        switch scope {
        case .all: break
        case .new: parts.append("NEW")
        case .offline: parts.append("OFFLINE")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    /// Bottom action bar shown in select mode: bulk-mute the selected rows.
    private var selectBar: some View {
        HStack(spacing: 10) {
            Button { selection = Set(shown.map { $0.id }) } label: {
                Text("SELECT ALL").font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                    .foregroundStyle(ACABTheme.dim)
                    .padding(.horizontal, 14).frame(height: 44)
                    .background(ACABTheme.bg2, in: Capsule())
                    .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(!shown.isEmpty && selection.isSuperset(of: shown.map(\.id))
                                    ? .isSelected : [])
            Button(action: ignoreSelected) {
                HStack(spacing: 7) {
                    Image(systemName: "bell.slash").font(.system(size: 13, weight: .bold))
                    Text("MUTE \(selection.count)").font(ACABTheme.mono(12, weight: .bold)).tracking(0.5)
                }
                .foregroundStyle(selection.isEmpty ? ACABTheme.faint : ACABTheme.onAccent)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(selection.isEmpty ? ACABTheme.bg2 : ACABTheme.accent, in: Capsule())
                .overlay(Capsule().strokeBorder(selection.isEmpty ? ACABTheme.line : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(selection.isEmpty)
        }
        .padding(.horizontal, ACABTheme.pad)
        .padding(.top, 10).padding(.bottom, 8)
        .background(
            LinearGradient(colors: [ACABTheme.bg.opacity(0), ACABTheme.bg],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    /// Consume the one-shot Status-tile handoff: arm the category filter over the ALL scope.
    /// The nil-out makes it exactly-once, so a later plain visit to the tab is unfiltered.
    private func consumeLogFocus() {
        guard let cat = LogFocus.pendingCategory else { return }
        LogFocus.pendingCategory = nil
        filter = cat
        scope = .all
    }

    private func toggle(_ d: Detection) {
        if selection.contains(d.id) { selection.remove(d.id) } else { selection.insert(d.id) }
    }

    private func ignoreSelected() {
        let picks = ble.logDetections.filter { selection.contains($0.id) }
        let refused = ble.ignoreDevices(picks)
        let requested = Set(picks.map { $0.mac.lowercased() }).count
        let muted = max(0, requested - refused)
        exportProblem = ExportProblem(
            title: refused == 0 ? "Devices muted" : "Some devices weren't muted",
            message: refused == 0
                ? "\(muted) device\(muted == 1 ? "" : "s") muted. Existing history was kept."
                : "\(muted) muted; \(refused) couldn't be added because the muted-device list is full."
        )
        exitSelect()
    }

    private func exitSelect() {
        selecting = false
        selection.removeAll()
    }

    /// Headline tracks radio state so an empty log never lies about scanning.
    private var emptyHeadline: String {
        if ble.demoMode { return "Sample data mode." }
        // No status frame at all = no board linked; "Scanning…" would be a lie.
        if ble.status == nil { return "No board linked." }
        if radiosOff { return "Radios are off, flip them on in Beacon." }
        return "Scanning\u{2026}"
    }
    private var radiosOff: Bool { if let s = ble.status { return !s.ble && !s.wifi }; return false }
    /// Only while genuinely scanning does the "log here" hint make sense (not in demo, not with
    /// no board linked, not when the radios are off. Then the headline already explains why
    /// nothing shows).
    private var isScanning: Bool { !ble.demoMode && ble.status != nil && !radiosOff }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "scope").font(.system(size: 38)).foregroundStyle(ACABTheme.line)
            Text(emptyHeadline)
                .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
            if isScanning {
                Text("Detections log here as beacons spots surveillance gear nearby.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            } else if !ble.demoMode && ble.status == nil {
                Text("connect your beacon, it does the listening")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 60)
    }

    /// Shown when filters hide everything (e.g. New-only with nothing new yet).
    private var noMatchState: some View {
        VStack(spacing: 10) {
            Image(systemName: noMatchSymbol)
                .font(.system(size: 32)).foregroundStyle(ACABTheme.line)
            Text(noMatchTitle)
                .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.dim)
            Text(noMatchBody)
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                .multilineTextAlignment(.center)
            // Keep resume reachable even if the active filter hides every frozen row while paused.
            if paused { pauseButton.padding(.top, 4) }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 48)
        .panel()
    }

    private var noMatchSymbol: String {
        switch scope {
        case .new:     return "checkmark.seal"
        case .offline: return "tray"
        case .all:     return "line.3.horizontal.decrease.circle"
        }
    }
    private var noMatchTitle: String {
        switch scope {
        case .new:     return "Nothing new"
        case .offline: return "Nothing offline"
        // ALPR gets its specific title (Android parity): the body below already explains why a
        // quiet ALPR lens is the expected result, and the generic "No matches" undersold that.
        case .all:     return filter == "ALPR" ? "No ALPR radio signal" : "No matches"
        }
    }
    private var noMatchBody: String {
        switch scope {
        case .new:     return "Everything here is marked seen. New hits show up as they arrive."
        case .offline: return "No offline-recorded detections yet. The board buffers these while your phone is away."
        case .all:
            // ALPR gets a specific line because a quiet result there means something different:
            // most current installs are RF-silent (see the site + faq), so absence is expected,
            // not a failure, and the map is the primary ALPR surface.
            if filter == "ALPR" {
                return "No compatible ALPR radio signal was observed. Some cameras do not broadcast "
                     + "a detectable signal, many backhaul over cellular and stay silent. Check the "
                     + "map for known installations, or export a diagnostic capture to contribute if "
                     + "you can visually confirm one nearby."
            }
            return "No detections in this category yet."
        }
    }
}

/// A temp file to share. Identifiable so it can drive `.sheet(item:)`.
struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Share-sheet wrapper around UIActivityViewController.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
