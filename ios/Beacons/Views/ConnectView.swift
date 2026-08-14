import SwiftUI
import CoreBluetooth
import UIKit

/// Pre-connection / first-run screen: says what the beacon does, explains the permissions
/// before the OS asks, scans for a board, and offers a first-class "tour on sample data" path.
struct ConnectView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSavedLog = false   // read-only path into the persisted log, no board needed
    // Scan-outcome bookkeeping: BLEManager's 45s scan window closes by silently settling back
    // to .idle, which looked like a spinner that just gave up. Track when the window closed
    // with nothing found so the panel can say so and offer another go.
    @State private var scanStartedAt: Date?
    @State private var scanCameUpEmpty = false

    // The six things the beacon listens for, as shown in the "what it hears" strip. Network
    // cameras belong beside trackers: both are opt-in, and the copy below names them.
    private let hears: [(DeviceType, String)] = [
        (.flockCamera, "ALPR"), (.drone, "DRONES"), (.axonBodyCam, "BODY CAMS"),
        (.tracker, "TRACKERS"), (.recordingGlasses, "GLASSES"), (.networkCamera, "NET CAM"),
    ]
    // Start reflowing before the accessibility categories: at XX Large the five fixed columns
    // already force BODY CAMS / TRACKERS through minimumScaleFactor. Accessibility sizes get two
    // generous columns; XX Large and XXX Large get three or four depending on device width.
    private var expandedHearsLayout: Bool { dynamicTypeSize >= .xxLarge }

    var body: some View {
        VStack(spacing: 0) {
            ACABWordmark()
                .padding(.top, 56)
                .padding(.bottom, 22)

            ScrollView {
                VStack(spacing: 16) {
                    beaconHearsPanel
                    content
                    // ORDER MATTERS (2026-07-29): the tour used to sit third, under the saved log
                    // and above the shop link, and new users never found it - yet it is the single
                    // best answer to "what does this thing even do", because it IS the app running
                    // on sample data. It now leads, and it is the only card with a filled accent
                    // background so it reads as the primary action for anyone who is stuck.
                    demoCard
                    if !ble.demoMode && !ble.detections.isEmpty { savedLogCard }
                    getBeaconCard
                    soyboiLink
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            scopeFootnote
        }
        // Timed-out-empty detection. Only a scan that ran (near) the full 45s window counts:
        // a user tapping "Scanning..." to stop early chose to stop, and scolding them with
        // "No boards found" for it would be wrong.
        .onChange(of: ble.connectionState) { old, new in
            if new == .scanning { scanStartedAt = Date(); scanCameUpEmpty = false }
            if old == .scanning, new != .scanning {
                let ranFull = scanStartedAt.map { Date().timeIntervalSince($0) >= 40 } ?? false
                scanCameUpEmpty = ranFull && ble.discovered.isEmpty
                scanStartedAt = nil
            }
        }
        .sheet(isPresented: $showSavedLog) {
            DetectionsView()
                .environmentObject(ble)
                // No MainTabView while disconnected, so a dossier's OPEN IN MAP handoff has no
                // receiver here: it would dead-end and park a stale MapFocus coordinate that
                // hijacks a later connect's first map open. The flag hides the affordance.
                .environment(\.mapHandoffAvailable, false)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: what it hears

    private var beaconHearsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("WHAT YOUR BEACON CAN HEAR")
            // One row for all six tiles at normal + large type: equal flexible columns divide the
            // width so they never wrap to a second row (labels wrap to two lines instead). Only at
            // true accessibility sizes does it fall back to an adaptive grid that wraps on purpose.
            LazyVGrid(
                columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.adaptive(minimum: 116), spacing: 8)]
                    : Array(repeating: GridItem(.flexible(), spacing: 6), count: hears.count),
                spacing: expandedHearsLayout ? 14 : 8
            ) {
                ForEach(hears, id: \.1) { type, label in
                    VStack(spacing: 7) {
                        CatGlyph(type: type, size: 30, filled: true)
                        Text(label)
                            .font(ACABTheme.mono(8.5, weight: .medium)).tracking(0.5)
                            .foregroundStyle(ACABTheme.dim)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(spokenHearsLabel(label))
                }
            }
            Text("a passive detector. it never jams or spoofs nearby devices. it listens for their broadcasts, then reports detections to your phone.")
                .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Text("trackers and network cameras are opt-in, switch them on in Beacon settings.")
                .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    // MARK: state-driven scan / message UI

    @ViewBuilder private var content: some View {
        switch ble.connectionState {
        case .poweredOff:
            message("Bluetooth is off", "Turn on Bluetooth to find your board.", "bolt.slash.fill")
        case .unauthorized:
            permissionMessage("Bluetooth not allowed",
                              ble.bluetoothRestricted
                                ? "Bluetooth is restricted by device policy, so beacons cannot scan for a board."
                                : "Bluetooth access is off for beacons. Turn it on in Settings to scan for a board.",
                              "lock.fill")
        case .unknown:
            message("Starting Bluetooth\u{2026}", "", "antenna.radiowaves.left.and.right")
        case .connecting:
            // An unexpected-drop auto-reconnect is armed indefinitely (good: it resyncs the moment
            // the board is back, even backgrounded). But RootView only shows the tabs when
            // .connected, so without an escape here a board that never returns would trap the user
            // on this screen forever with no way to scan for a different one. The fresh scan-connect
            // path needs the same way out: central.connect never times out on its own, so a stale
            // row (board powered off since discovery, or claimed by another phone) would park the
            // spinner forever. BLEManager arms a 15 s watchdog for that; the button here is the
            // manual escape, and both call disconnect(), which settles the state back to the scan
            // panel.
            if ble.isReconnecting {
                reconnectingPanel
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(ACABTheme.accent)
                    Text("Connecting\u{2026}").font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.dim)
                    Button { ble.disconnect() } label: {
                        Text("Stop and scan")
                            .font(ACABTheme.mono(12, weight: .bold))
                            .foregroundStyle(ACABTheme.dim)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(ACABTheme.bg2, in: Capsule())
                            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .padding(.top, 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        default:
            scanPanel
        }
    }

    /// Shown while a pending auto-reconnect is armed (board unplugged / power-cycled). Says the
    /// reconnect is automatic AND gives a way out: "Stop and scan" calls disconnect(), which cancels
    /// the pending connect and settles the state to .idle so the scan panel returns. Without this the
    /// user is stuck on the connect screen until the board comes back, which it may never do.
    private var reconnectingPanel: some View {
        VStack(spacing: 14) {
            ProgressView().tint(ACABTheme.accent)
            Text("Reconnecting to your board\u{2026}")
                .font(ACABTheme.mono(15, weight: .bold)).foregroundStyle(ACABTheme.ink)
            Text("It reconnects on its own the moment the board is back in range, even in the background. Keep waiting, or stop to scan for a different board.")
                .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.disconnect() } label: {
                Text("Stop and scan")
                    .font(ACABTheme.mono(13, weight: .bold))
                    .foregroundStyle(ACABTheme.onAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(ACABTheme.accent,
                                in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .padding(.horizontal, 4)
        .panel()
    }

    /// True once Bluetooth is granted. Reads the static authorization (no prompt, no "access"),
    /// so the pre-permission rationale retires once the system has already asked.
    private var btGranted: Bool { CBManager.authorization == .allowedAlways }

    /// Pre-permission rationale + the primary scan CTA, then the discovered boards. The rationale
    /// panel only shows before Bluetooth is granted; once it is, the CTA stands on its own.
    private var scanPanel: some View {
        VStack(spacing: 14) {
            // The 45s scan window closed with nothing found: name the outcome and the fix.
            // Sits above the CTA so it is the first thing read after the timeout.
            if scanCameUpEmpty, ble.discovered.isEmpty { noBoardsPanel }
            if btGranted && ble.locationAuthorizationStatus != .notDetermined {
                scanCTA
                pairWindowNote
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    Kicker("BEFORE THE SYSTEM ASKS")
                    if !btGranted {
                        rationaleRow("antenna.radiowaves.left.and.right", "Bluetooth",
                                     "pairs you to the beacon. The board does the listening, not your phone.")
                    }
                    // Claim is deliberately automatic-upload-shaped: "nothing leaves this phone"
                    // stopped being true when explicit CSV export and the contribution flow
                    // shipped, and an absolute promise the app can be caught breaking is worse
                    // than the accurate one. Same canonical sentence as Android.
                    if ble.locationAuthorizationStatus == .notDetermined {
                        rationaleRow("location.fill", "Location (optional)",
                                     "pins observer-based hits to the map and sends your current coordinates over encrypted local Bluetooth to your own beacon for geotagging. Drones can still provide their own Remote ID position if you decline. The app does not automatically upload detections or location to us. Beyond your own beacon, they reach another recipient only when you explicitly export or send them. Map tiles and optional datasets are requested from their providers. No account is required.")
                    }
                    scanCTA
                    pairWindowNote
                }
                .panel()
            }

            if ble.locationDenied { locationPermissionPanel }

            if ble.discovered.isEmpty, ble.connectionState == .scanning {
                Text("Looking for your board\u{2026}")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .padding(.top, 2)
            }

            // one tappable row per board we've found
            ForEach(ble.discovered) { dev in
                Button { ble.connect(dev) } label: { boardRow(dev) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(dev.name), signal strength \(dev.rssi) decibels relative to one milliwatt"
                        + (dev.firmware.map { ", firmware \($0)" } ?? ""))
                    .accessibilityHint("Connects to this beacon")
            }
        }
    }

    /// Shown after a full scan window found nothing: an actionable outcome instead of the
    /// silent settle back to the idle CTA (which read as an indefinite spinner giving up).
    private var noBoardsPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 22)).foregroundStyle(ACABTheme.dim)
            Text("No boards found. Make sure your beacon is powered on and nearby, then scan again.")
                .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.startScanFromUser() } label: {
                Text("SCAN AGAIN")
                    .font(ACABTheme.mono(12, weight: .bold)).tracking(1)
                    .foregroundStyle(ACABTheme.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)   // 44pt target
                    .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .panel()
    }

    private func rationaleRow(_ symbol: String, _ lead: String, _ rest: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 15)).foregroundStyle(ACABTheme.accent)
                .frame(width: 20)
            (Text(lead).font(ACABTheme.mono(11.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                + Text(" \(rest)").font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func spokenHearsLabel(_ label: String) -> String {
        switch label {
        case "ALPR": return "automatic license plate readers"
        case "DRONES": return "drones"
        case "BODY CAMS": return "body cameras"
        case "TRACKERS": return "item trackers"
        case "GLASSES": return "recording glasses"
        default: return label.lowercased()
        }
    }

    private var scanCTA: some View {
        Button {
            ble.connectionState == .scanning ? ble.stopScan() : ble.startScanFromUser()
        } label: {
            Label(ble.connectionState == .scanning ? "Scanning\u{2026}"
                    : (!btGranted ? "Allow Bluetooth & scan"
                       : (ble.locationAuthorizationStatus == .notDetermined
                          ? "Continue & scan for boards" : "Scan for boards")),
                  systemImage: ble.connectionState == .scanning
                    ? "stop.circle.fill" : "antenna.radiowaves.left.and.right")
                .font(ACABTheme.mono(14, weight: .bold))
                .foregroundStyle(ACABTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ACABTheme.accent,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    /// Location is optional: the board scan and Remote ID coordinates still work without it.
    /// This recovery card avoids both bad extremes, a dead-looking map and a false claim that no
    /// detections can ever be mapped, while offering the system route to change the decision.
    private var locationPermissionPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "location.slash.fill")
                    .foregroundStyle(ACABTheme.warn).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(ble.locationRestricted ? "Location is restricted" : "Location is off")
                        .font(ACABTheme.mono(12.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                    Text(ble.locationRestricted
                         ? "A device policy prevents observer-location access. Board scanning still works, and drones with Remote ID coordinates can still appear on the map."
                         : "Board scanning still works. Observer-based map pins will be absent, while drones with Remote ID coordinates can still appear.")
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("OPEN SETTINGS", action: openSettings)
                .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                .foregroundStyle(ACABTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                    .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .panel()
    }

    private func permissionMessage(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            message(title, body, symbol)
            Button("OPEN SETTINGS", action: openSettings)
                .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                .foregroundStyle(ACABTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                    .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// First-time pairing note, shown under the scan button whenever no board is connected.
    ///
    /// A board that already belongs to a phone only accepts a NEW phone in the two minutes after it
    /// powers on. That rule is invisible from the phone's side: the board hangs up before any
    /// characteristic exists to explain itself, so a user who misses the window just sees a connect
    /// that will not take. Stating it BEFORE the failure is worth more than any error message
    /// after it, which is why this is always present rather than an alert.
    ///
    /// Deliberately says "already paired to another phone", not "your beacon": on a brand new board
    /// with no bonds the rule does not apply at all (the firmware admits any phone until the board
    /// has an owner), and telling a first-time customer to power-cycle would be a made-up ritual.
    private var pairWindowNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
            Text("Connecting a beacon that is already paired to another phone? "
                 + BLEManager.pairWindowHint)
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
    }

    private func boardRow(_ dev: DiscoveredDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "cpu").foregroundStyle(ACABTheme.accent)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(dev.name).font(ACABTheme.mono(14, weight: .semibold))
                    if let fw = dev.firmware {
                        Text("v\(fw)").font(ACABTheme.mono(9, weight: .bold))
                            .foregroundStyle(ACABTheme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(ACABTheme.accent.opacity(0.15), in: Capsule())
                    }
                }
                Text(dev.id.uuidString.prefix(8)).font(ACABTheme.mono(10))
                    .foregroundStyle(ACABTheme.dim)
            }
            Spacer()
            SignalBars(bars: bars(for: dev.rssi))
            Text("\(dev.rssi)").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
        .foregroundStyle(ACABTheme.ink)
        .panel()
    }

    private func message(_ title: String, _ body: String, _ symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(ACABTheme.dim)
            Text(title).font(ACABTheme.mono(16, weight: .bold)).foregroundStyle(ACABTheme.ink)
            if !body.isEmpty {
                Text(body).font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    // MARK: saved log (no board required)

    /// The history on this phone stays reachable with no board and no Bluetooth. The Log tab
    /// is normally gated behind .connected, but a log that may be evidence must never be
    /// locked behind hardware that died or a permission that was denied. Everything inside is
    /// phone-local (view, mark seen, export CSV, clear); board-config writes no-op while
    /// disconnected. Hidden during the tour so the sample store can never be exported here.
    private var savedLogCard: some View {
        Button { showSavedLog = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("View saved log (\(ble.detections.count))")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("history on this phone \u{00B7} browse and export, no board needed")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: demo (first-class)

    /// Explore the full app with sample data, no board needed (also handy for App Review).
    private var demoCard: some View {
        Button { ble.seedDemoData() } label: {
            HStack(spacing: 12) {
                Image(systemName: "scope")   // R5: the tracker category owns dot.radiowaves...
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See how it works")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("the full app on sample data \u{00B7} no beacon needed")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(ACABTheme.accentSoft, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: get a beacon

    /// No hardware yet? Point straight at the shop. Styled to match the demo/saved-log cards so it
    /// reads as a first-class path, but it's a Link (arrow.up.right) since it leaves the app.
    private var getBeaconCard: some View {
        Link(destination: URL(string: "https://soyboi.tech")!) {
            HStack(spacing: 12) {
                Image(systemName: "cart")
                    .font(.system(size: 18)).foregroundStyle(ACABTheme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Get a beacon")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("the board that does the listening \u{00B7} soyboi.tech")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Secondary text link to the same shop, for people who just want the plain URL.
    private var soyboiLink: some View {
        Link(destination: URL(string: "https://soyboi.tech")!) {
            Text("soyboi.tech")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }

    private var scopeFootnote: some View {
        Text("Passive detection only. beacons never jams, spoofs, or interferes.")
            .font(ACABTheme.mono(9))
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(.center)
            .padding(20)
    }

    private func bars(for rssi: Int) -> Int {
        switch rssi {
        case ..<(-90): return 1
        case ..<(-80): return 2
        case ..<(-67): return 3
        default:       return 4
        }
    }
}
