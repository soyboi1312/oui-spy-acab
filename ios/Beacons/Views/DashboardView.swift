import SwiftUI

/// Status / home: the at-a-glance "how much is watching me right now" screen.
/// Built around the radar scope, fed by live BLE detections.
struct DashboardView: View {
    @EnvironmentObject var ble: BLEManager
    var onOpenDetectors: () -> Void = {}
    // Accessibility text sizes reflow the six-across tile strip into a grid and pad the scroll
    // bottom; read once here so every consumer keys off the same threshold.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    // SF Symbols have different intrinsic bounds (the wide tracker radio waves are taller than
    // the glasses, for example), and lowercase "off" has a shorter optical height than a digit.
    // Give every tile the same three scaled slots so neither glyph choice nor state changes the
    // card's outer height. The value/caption metrics follow the same Dynamic Type curves as the
    // matching ACABTheme fonts below.
    @ScaledMetric(relativeTo: .title) private var categoryValueLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .caption) private var categoryCaptionLineHeight: CGFloat = 10

    // Staleness moves with the clock, not with @Published state, so nothing would invalidate
    // this screen as rows go quiet: without the tick the count freezes at its last-publish
    // value and a device we stopped hearing 20 minutes ago keeps reading LIVE. Pass `tick`
    // into isStale rather than just reading it, so the dependency can't get optimized or
    // tidied away. 1 s cadence, same as Android's StatusScreen, so a device crossing the
    // 45 s boundary ages off the radar at the same moment on both platforms.
    @State private var tick = Date()
    /// Held in @State so the SAME publisher survives a re-render, exactly like the dossier's
    /// followTick. MainTabView holds the manager, so its body re-runs on every publish and builds
    /// this view fresh with it: as a plain `let` the timer was rebuilt each time and onReceive
    /// cancelled and resubscribed with it, so under a streaming feed it never lived the whole
    /// second it needs to fire once. `tick` then stuck at the instant Status appeared - and it
    /// stuck hardest during a drive or Desert mode, which is exactly when a row that went quiet
    /// has to age off instead of holding the radar at "SEEN < 45s".
    @State private var staleTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Only what we can still hear. The store is capped, never time-evicted, so an
    /// unfiltered read hands "strongest signal" to a Flock heard at 9:00 and left fifteen
    /// miles behind by 9:20. Replayed buffer rows are dropped too: ingest backdates their
    /// lastSeen but they keep the RSSI they were recorded at, so a buffered body cam would
    /// win the nearest comparison outright.
    ///
    /// The tour is exempt: its sample rows are a fixture stamped with one lastSeen at seed
    /// time and never refreshed, so ageing them out empties the radar to "0 DEVICES NEARBY"
    /// 45 s in. App Review takes the tour, so that reads as a broken app.
    private var detections: [Detection] {
        if ble.demoMode { return ble.detections }
        return ble.detections.filter { !$0.isHistory && !ble.isStale(for: $0.id, asOf: tick) }
    }

    /// Per-category counts in ONE pass over the body's snapshot. The tiles used to call a
    /// per-type filter each, so every body eval (~3 Hz while detections stream) re-filtered
    /// the full store seven more times.
    private func categoryCounts(_ live: [Detection]) -> [DeviceType: Int] {
        var counts: [DeviceType: Int] = [:]
        for d in live { counts[d.type, default: 0] += 1 }
        return counts
    }

    private func dots(from live: [Detection]) -> [RadarDot] {
        // cap at 14 so a busy scope stays readable
        live.prefix(14).map { d in
            RadarDot(id: d.id, angle: angle(for: d.mac),
                     radius: ringRadius(bars: d.signalBars), tone: d.type.tint)
        }
    }

    // Honest radar: blips snap to the ring of their signal band instead of a
    // fake continuous range. Full bars = inner ring, 3 = mid, weaker = outer.
    private func ringRadius(bars: Int) -> Double {
        switch bars {
        case 4:  return 1.0 / 3.0
        case 3:  return 2.0 / 3.0
        default: return 1.0
        }
    }

    private func nearest(in live: [Detection]) -> Detection? {
        live.max(by: { $0.rssi < $1.rssi })
    }

    // MARK: Live radio state

    // The board reports ble/wifi as toggle INTENT, and on dual-radio boards "co" as nRF
    // liveness. A dead nRF gives coproc == false while status.ble still says true, so the
    // whole BLE half is dark and the toggle alone can't tell us. Single-radio boards omit
    // "co" (coproc == nil), where the toggle is the whole story.
    // A BLE-DFU window is the one benign reason for a dark nRF: it sits in its bootloader for
    // minutes, so "co" reads false and the board says so with "nrfup". Split the two - the radio
    // is equally dark either way (coprocDown, which is what drives scanning state), but only one
    // of them is a fault worth alarming about.
    private var coprocDown: Bool { ble.status?.coproc == false }
    private var nrfUpdating: Bool { ble.status?.nrfUpdating == true }
    private var coprocFault: Bool { coprocDown && !nrfUpdating }
    /// The nRF is only worth shouting about when BLE is meant to be running.
    private var bleFault: Bool { coprocFault && ble.status?.ble == true }
    /// Same gate for the calm twin: a running update only matters if BLE was meant to be on.
    private var bleUpdating: Bool { nrfUpdating && ble.status?.ble == true }
    // No status frame yet (between connect and the first poll, and in demo) reads as
    // scanning, mirroring the Log tab, so Status doesn't flash "RADIOS OFF" on every connect.
    private var bleLive: Bool { ble.status.map { $0.ble && !coprocDown } ?? true }
    private var wifiLive: Bool { ble.status?.wifi ?? true }
    private var scanning: Bool { bleLive || wifiLive }

    /// Kicker tracks radio state so the at-a-glance screen never claims to be scanning
    /// with the radios off or the nRF dark. Wording is shared with Android.
    private var scanKicker: String {
        // The tour seeds a fake status with both radios up, so the ladder below would read
        // "SCANNING · BLE · WI-FI" over fabricated rows. Name it, same as the Log tab's
        // "Sample data mode." and the Android kicker.
        if ble.demoMode { return "SAMPLE DATA" }
        switch (bleLive, wifiLive) {
        case (true, true):   return "SCANNING \u{00B7} BLE \u{00B7} WI-FI"
        case (true, false):  return "SCANNING \u{00B7} BLE"
        case (false, true):
            if bleFault    { return "SCANNING \u{00B7} WI-FI ONLY \u{00B7} BLE RADIO FAULT" }
            if bleUpdating { return "SCANNING \u{00B7} WI-FI ONLY \u{00B7} UPDATING CO-PROCESSOR" }
            return "SCANNING \u{00B7} WI-FI"
        case (false, false):
            if bleFault    { return "BLE RADIO FAULT \u{00B7} NOT SCANNING" }
            if bleUpdating { return "UPDATING CO-PROCESSOR \u{00B7} NOT SCANNING" }
            return "RADIOS OFF \u{00B7} NOT SCANNING"
        }
    }

    /// Amber for a fault, plain dim for radios the user turned off himself (and for an update,
    /// which is a state to wait out, not a warning).
    private var scanKickerColor: Color { bleFault ? ACABTheme.warn : ACABTheme.dim }

    var body: some View {
        // Snapshot ONCE per body eval: `detections` is an O(store) filter with a dictionary
        // lookup per row, and reading it through count/dots/nearest/the tiles re-ran it ~10x
        // per eval. One filter pass + one counts pass, everything below derives from these.
        let live = detections
        let counts = categoryCounts(live)
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            BrandMark(size: 21)
                            Spacer()
                            NavigationLink {
                                HelpView(canImproveDetection: improveDetectionAvailable(
                                    isSessionReady: ble.sessionReady,
                                    isDemoMode: ble.demoMode))
                            } label: {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(ACABTheme.dim)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("help and support")
                            LinkChip(version: ble.status?.version, connected: ble.connectionState == .connected, demo: ble.demoMode)
                        }
                        HStack(spacing: 8) {
                            if scanning {
                                ScanDot(color: bleFault ? ACABTheme.warn : ACABTheme.accent)
                            } else {
                                // A pulsing dot beside "NOT SCANNING" would still read as alive.
                                Circle().fill(ACABTheme.faint).frame(width: 7, height: 7)
                            }
                            Kicker(scanKicker, color: scanKickerColor)
                            // Far-right recency note: the radar + counts only include devices heard
                            // within the ~45s isStale window, so name it - only when something's up.
                            if !ble.demoMode, !live.isEmpty {
                                Spacer()
                                Kicker("SEEN < 45s", color: ACABTheme.faint)
                            }
                        }

                        if bleFault { coprocFaultPill } else if bleUpdating { coprocUpdatingPill }
                        if ble.syncingOfflineLog { syncingPill }

                        RadarScope(count: live.count, dots: dots(from: live), sweeping: scanning)
                            .frame(height: 250)
                            .overlay(ringLabels)
                            .frame(maxWidth: 420)
                            .frame(maxWidth: .infinity)   // center the capped radar in the (leading) column, matters on iPad
                            .padding(.top, 4)

                        // Promoted from a 9pt afterthought to a standing element of the radar
                        // presentation: a dial reads as bearing to everyone who has ever seen one,
                        // and here the angle is a MAC hash. The one line that corrects that mental
                        // model has to be legible and always on screen, not a caption you squint at.
                        // Scales with Dynamic Type (it is content, not chrome).
                        Text("SIGNAL STRENGTH ONLY \u{00B7} NO DIRECTION")
                            .font(ACABTheme.mono(10.5, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(ACABTheme.dim)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(ACABTheme.bg2, in: Capsule())
                            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                            .frame(maxWidth: .infinity)

                        HStack { Spacer(); PunkLine(); Spacer() }
                            .padding(.vertical, 2)

                        categoryTiles(counts)

                        if let nearest = nearest(in: live) { nearestCard(nearest) }
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                }
                // Extra bottom margin ONLY at accessibility sizes, where the grown content can
                // otherwise end flush against (or under) the tab bar. Zero at default sizes so
                // the standard layout is untouched.
                .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
            }
            .navigationBarHidden(true)
        }
        .onReceive(staleTick) { tick = $0 }
    }

    /// The nRF fault is a whole half of the detection surface going dark, so it can't live
    /// only on the Beacon tab. Short form here, Beacon carries the full what-to-try.
    private var coprocFaultPill: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(ACABTheme.warn)
            Text("nRF radio fault - bluetooth detection offline. trackers, glasses and other bluetooth gear won't be picked up. see Beacon.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.warn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.warn.opacity(0.4), lineWidth: 1))
    }

    /// Same slot as coprocFaultPill, for the one case where the dark nRF is intentional: it's
    /// taking new firmware. Says the same thing about coverage without the alarm colours.
    private var coprocUpdatingPill: some View {
        HStack(alignment: .top, spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .tint(ACABTheme.dim)
            Text("updating co-processor - bluetooth detection paused. trackers, glasses and other bluetooth gear won't be picked up until it comes back. see Beacon.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Subtle, non-blocking indicator shown while the board is replaying its offline
    /// "black box" buffer on reconnect. Indeterminate (the total isn't known until the
    /// end), with a live-climbing count when we have one.
    private var syncingPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.6)
                .tint(ACABTheme.dim)
            Text(syncingLabel)
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Determinate "X of N" once the board's {"hist":"begin"} lead-in gives the total; falls back
    /// to a live "so far" count, then a bare spinner label before any record lands.
    private var syncingLabel: String {
        let n = ble.offlineSyncCount, total = ble.offlineSyncTotal
        if total > 0 { return "syncing offline log, \(n) of \(total)" }
        if n > 0     { return "syncing offline log, \(n) so far" }
        return "syncing offline log\u{2026}"
    }

    /// NEAR / MID / FAR stacked up the vertical axis, naming the rings the
    /// blips snap to. Lives in an overlay so RadarScope itself stays generic.
    private var ringLabels: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            let cx = geo.size.width / 2
            let cy = s / 2
            Group {
                ringLabel("NEAR", opacity: 0.45).position(x: cx, y: cy - s / 6)
                ringLabel("MID",  opacity: 0.38).position(x: cx, y: cy - s / 3)
                ringLabel("FAR",  opacity: 0.30).position(x: cx, y: cy - s / 2 + 7)
            }
        }
        .allowsHitTesting(false)
        // Decorative instrument chrome: VoiceOver otherwise reads NEAR/MID/FAR as three stray
        // elements. The scope's own summary label already carries the meaning.
        .accessibilityHidden(true)
    }

    private func ringLabel(_ text: String, opacity: Double) -> some View {
        // Fixed size on purpose - decorative instrument chrome positioned absolutely on the
        // scope's fixed geometry. On the Dynamic Type caption curve these roughly quadruple at
        // accessibility sizes and overlapped each other and the count. The scope's real content
        // (the count) still scales, and RadarScope speaks a full summary for VoiceOver.
        Text(text)
            .font(Font.custom("JetBrainsMono-Medium", fixedSize: 7.5))
            .tracking(1)
            .foregroundStyle(ACABTheme.text.opacity(opacity))
    }

    /// One strip of compact per-category counts, matching the Log tiles and Map chips
    /// (ALPR, DRONE, BODY, TRACKER, GLASSES, plus Network camera). Six compact tiles share the
    /// row width evenly, so Status surfaces the netcam count the same way Log and Map already do.
    /// At accessibility text sizes six-across leaves each tile ~55pt while its label quadruples,
    /// so the strip reflows into a 3x2 grid; the default layout is untouched.
    @ViewBuilder
    private func categoryTiles(_ counts: [DeviceType: Int]) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                      spacing: 6) { tileSet(counts) }
        } else {
            HStack(spacing: 6) { tileSet(counts) }
        }
    }

    /// The six tiles themselves, shared by both containers above. `spoken` is what VoiceOver
    /// says: the drawn label is a width-budget abbreviation ("TRKR", "GLAS") that a screen
    /// reader would speak as gibberish, so each tile carries its full-word name too.
    @ViewBuilder
    private func tileSet(_ counts: [DeviceType: Int]) -> some View {
        tile(.flockCamera, "ALPR",  spoken: "ALPR cameras", enabled: detectorEnabled(.flockCamera),
             (counts[.flockCamera] ?? 0) + (counts[.flockRaven] ?? 0))
        tile(.drone,       "DRONE", spoken: "Drones", enabled: detectorEnabled(.drone), counts[.drone] ?? 0)
        tile(.axonBodyCam, "BODY",  spoken: "Body cameras", enabled: detectorEnabled(.axonBodyCam), counts[.axonBodyCam] ?? 0)
        tile(.tracker,     "TRKR",  spoken: "Trackers", enabled: detectorEnabled(.tracker), counts[.tracker] ?? 0)
        tile(.recordingGlasses, "GLAS", spoken: "Glasses", enabled: detectorEnabled(.recordingGlasses), counts[.recordingGlasses] ?? 0)
        tile(.networkCamera, "NETCAM", spoken: "Network cameras", enabled: detectorEnabled(.networkCamera),
             counts[.networkCamera] ?? 0)
    }

    private func detectorEnabled(_ type: DeviceType) -> Bool? {
        guard let s = ble.status else { return nil }
        switch type {
        case .flockCamera, .flockRaven: return s.flock
        case .drone: return s.drone
        case .axonBodyCam: return s.axon
        case .tracker: return s.tracker
        case .recordingGlasses: return s.glasses
        case .networkCamera: return s.ncam
        default: return true
        }
    }

    /// Each tile deep-links to the Log tab with its category filter armed (LogFocus is the
    /// same one-shot static-slot pattern MapFocus uses, session-only on purpose), so the
    /// at-a-glance count answers "show me those" in one tap instead of being a dead number.
    private func tile(_ type: DeviceType, _ label: String, spoken: String,
                      enabled: Bool?, _ n: Int) -> some View {
        let off = enabled == false
        return Button {
            if off {
                onOpenDetectors()
            } else {
                LogFocus.pendingCategory = type.category
                NotificationCenter.default.post(name: LogFocus.notification, object: nil)
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: type.symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : type.tint)
                    .frame(width: 22, height: 18)
                // Uppercase keeps OFF on the same cap-height as the numeric state. Both still use
                // one exact font and one exact line box across all six categories.
                Text(off ? "OFF" : "\(n)")
                    .font(ACABTheme.display(18, weight: .bold))
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : ACABTheme.text)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(height: categoryValueLineHeight)
                Text(label)
                    .font(ACABTheme.mono(8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(off || n == 0 ? ACABTheme.faint : type.tint)
                    .lineLimit(1)
                    .frame(height: categoryCaptionLineHeight)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(ACABTheme.bg2,
                        in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(off ? "\(spoken), detector off" : "\(spoken), \(n) active")
        .accessibilityHint(off ? "opens detector settings on Beacon" : "opens the Log filtered to this category")
    }

    /// Tappable card for the closest device (highest RSSI).
    private func nearestCard(_ d: Detection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker("STRONGEST SIGNAL · LIVE", color: ACABTheme.accent)
            NavigationLink {
                DetectionDetailView(detection: d)
            } label: {
                HStack(spacing: 12) {
                    CatGlyph(type: d.type, size: 40, filled: true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(categoryTitle(d.type.category))
                                .font(ACABTheme.display(15, weight: .semibold))
                                .foregroundStyle(ACABTheme.text)
                            Text("NODE \(d.nodeName)")
                                .font(ACABTheme.mono(11, weight: .medium))
                                .foregroundStyle(ACABTheme.dim)
                        }
                        Text("\(d.source.label) · seen \(d.count)× · ~\(approxMeters(d.rssi)) m")
                            .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        Text("\(d.rssi)")
                            .font(ACABTheme.mono(15, weight: .semibold))
                            .foregroundStyle(ACABTheme.accent)
                        SignalBars(bars: d.signalBars, tint: d.type.tint)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ACABTheme.faint)
                }
                .panel(strong: true)
            }
            .buttonStyle(.plain)
        }
    }

    // Rough RSSI to metres for the hero card, using the SAME constants as the map's
    // rssiRadiusMeters (TxPower -50 dBm, n ~2.5) so the card and the map's no-GPS ring
    // never disagree about the same signal. Deliberately fuzzy, a "somewhere around
    // here" hint, not a measurement.
    private func approxMeters(_ rssi: Int) -> Int {
        let d = pow(10.0, (-50.0 - Double(rssi)) / 25.0)
        return Int(min(max(d, 5), 600).rounded())   // same [5, 600] clamp as the map
    }

    // Fake-but-stable bearing hashed from the MAC, we only have RSSI, not a real one.
    private func angle(for mac: String) -> Double {
        var h: UInt64 = 5381
        for b in mac.utf8 { h = (h &* 33) &+ UInt64(b) }
        return Double(h % 360)
    }

    // Categories render lowercase, brand-wide, so the identifier ("BODY CAM") and the
    // label ("body cam") stay separate things.
    private func categoryTitle(_ cat: String) -> String {
        return cat.lowercased()
    }
}
