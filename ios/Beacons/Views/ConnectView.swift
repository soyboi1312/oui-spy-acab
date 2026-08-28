import SwiftUI
import CoreBluetooth
import UIKit
import Accessibility

/// Spoken word for a scan row's signal, derived from the same banding that drives the
/// visual SignalBars (Detection.signalBars) so the two can never disagree. Android's
/// BoardRow maps rssiBars the same way.
func beaconSignalDescription(rssi: Int) -> String {
    switch Detection.signalBars(rssi: rssi) {
    case ...1: return "weak"
    case 2:    return "fair"
    case 3:    return "good"
    default:   return "strong"
    }
}

/// A pre-permission action opens the system alert; only that alert can grant Bluetooth access.
/// Keep the first-use title neutral so the app never appears to make the permission decision.
func bluetoothScanButtonTitle(isScanning: Bool, bluetoothGranted: Bool) -> String {
    if isScanning { return "Stop scanning" }
    return bluetoothGranted ? "Scan for beacons" : "Continue"
}

/// Pre-connection / first-run screen: gets the beacon connected, explains permissions before the
/// OS asks, and offers a first-class sample path plus offline setup help.
struct ConnectView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showSavedLog = false   // read-only path into the persisted log, no beacon needed
    var onOpenSetupHelp: () -> Void = {}
    // Scan-outcome bookkeeping: BLEManager's 45s scan window closes by silently settling back
    // to .idle, which looked like a spinner that just gave up. Track when the window closed
    // with nothing found so the panel can say so and offer another go.
    @State private var scanStartedAt: Date?
    @State private var scanCameUpEmpty = false
    // A recovery hint stays published until another connect begins. Hide the handled instance
    // while its retry scan runs, then clear this guard when the user picks a board so a new failure
    // (even with identical copy) is surfaced again.
    @State private var handledConnectHint: String?

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
                    // Setup comes before the capability catalog. A first-time owner needs the next
                    // physical action before learning every category the beacon can recognize.
                    setupIntro
                    content
                    setupHelpCard
                    // ORDER MATTERS (2026-07-29): the tour used to sit third, under the saved log
                    // and above the shop link, and new users never found it - yet it is the single
                    // best answer to "what does this thing even do", because it IS the app running
                    // on sample data. It now leads, and it is the only card with a filled accent
                    // background so it reads as the primary action for anyone who is stuck.
                    demoCard
                    beaconHearsPanel
                    if !ble.demoMode && !ble.logDetections.isEmpty { savedLogCard }
                    getBeaconCard
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            scopeFootnote
        }
        // Timed-out-empty detection. Only a scan that ran (near) the full 45s window counts:
        // a user tapping Stop scanning early chose to stop, and showing an empty result for it
        // would be wrong.
        .onChange(of: ble.connectionState) { old, new in
            if new == .scanning {
                scanStartedAt = Date()
                scanCameUpEmpty = false
                postAccessibilityAnnouncement("scanning for beacons. activate Stop scanning to stop.",
                                              priority: .polite)
            }
            if old == .scanning, new != .scanning {
                let ranFull = scanStartedAt.map { Date().timeIntervalSince($0) >= 40 } ?? false
                scanCameUpEmpty = ranFull && ble.discovered.isEmpty
                scanStartedAt = nil
                if scanCameUpEmpty {
                    postAccessibilityAnnouncement(
                        "no beacons found. make sure your beacon is powered on and nearby, then scan again.",
                        priority: .assertive)
                }
            }
        }
        .onChange(of: ble.connectHint) { _, hint in
            guard let hint, hint != handledConnectHint else { return }
            postAccessibilityAnnouncement("connection did not finish. \(hint)",
                                          priority: .assertive)
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

    // MARK: setup first

    private var setupIntro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Kicker("SET UP YOUR BEACON")
            Text("power on your beacon and keep it nearby. scan, tap your beacon, then approve the iOS pairing request if it appears to finish the encrypted connection.")
                .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    private var setupHelpCard: some View {
        Button(action: onOpenSetupHelp) {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ACABTheme.dim)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("setup + pairing help")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("power, secure pairing, and recovery \u{00B7} works offline")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
                .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("opens setup help included with the app")
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
            message("Bluetooth is off", "turn on Bluetooth to find your beacon.", "bolt.slash.fill")
        case .unauthorized:
            permissionMessage("Bluetooth not allowed",
                              ble.bluetoothRestricted
                                ? "Bluetooth is restricted by device policy, so the app cannot scan for a beacon."
                                : "Bluetooth access is off for beacons. turn it on in Settings to scan for your beacon.",
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
                    Text("securing connection\u{2026}").font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.dim)
                    Text("accept the iOS pairing request if it appears.")
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                        .multilineTextAlignment(.center)
                    Button { ble.disconnect() } label: {
                        Text("cancel")
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

    /// Shown while a pending auto-reconnect is armed (beacon unplugged / power-cycled). Says the
    /// reconnect is automatic AND gives a way out: "stop reconnecting" calls disconnect(), which cancels
    /// the pending connect and settles the state to .idle so the scan panel returns. Without this the
    /// user is stuck on the connect screen until the board comes back, which it may never do.
    private var reconnectingPanel: some View {
        VStack(spacing: 14) {
            ProgressView().tint(ACABTheme.accent)
            Text("reconnecting to your beacon\u{2026}")
                .font(ACABTheme.mono(15, weight: .bold)).foregroundStyle(ACABTheme.ink)
            Text("it reconnects on its own when the beacon is back in range, even in the background. keep waiting, or stop to scan for a different beacon.")
                .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button { ble.disconnect() } label: {
                Text("stop reconnecting")
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

    /// Pre-permission rationale + the primary scan CTA, then the discovered boards. Bluetooth is
    /// requested by the scan CTA; optional Location is requested later from the feature that needs it.
    private var scanPanel: some View {
        VStack(spacing: 14) {
            if let hint = ble.connectHint,
               hint != handledConnectHint,
               ble.connectionState != .scanning {
                connectionFailurePanel(hint)
            }
            // The 45s scan window closed with nothing found: name the outcome and the fix.
            // Sits above the CTA so it is the first thing read after the timeout.
            if scanCameUpEmpty, ble.discovered.isEmpty { noBoardsPanel }
            if btGranted {
                scanCTA
                pairWindowNote
            } else {
                VStack(alignment: .leading, spacing: 13) {
                    Kicker("BEFORE THE SYSTEM ASKS")
                    rationaleRow("antenna.radiowaves.left.and.right", "Bluetooth",
                                 "connects your phone to the beacon. the beacon does the listening.")
                    scanCTA
                    pairWindowNote
                }
                .panel()
            }

            if ble.locationDenied { locationPermissionPanel }

            if ble.discovered.isEmpty, ble.connectionState == .scanning {
                Text("looking for your beacon\u{2026}")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .padding(.top, 2)
                    .accessibilityLabel("scanning for beacons")
                    .accessibilityAddTraits(.updatesFrequently)
            }

            if !ble.discovered.isEmpty {
                securePairingNote
            }

            // one tappable row per board we've found
            ForEach(ble.discovered) { dev in
                Button {
                    handledConnectHint = nil
                    ble.connect(dev)
                } label: { boardRow(dev) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(dev.name), \(beaconSignalDescription(rssi: dev.rssi)) signal, connects securely"
                        + (dev.firmware.map { ", firmware \($0)" } ?? ""))
                    .accessibilityHint("activate to connect. iOS may show a pairing request")
            }
        }
    }

    /// BLEManager already distinguishes an ordinary empty scan from a failed/incomplete board
    /// link. Render that diagnosis instead of silently falling back to an undifferentiated picker.
    private func connectionFailurePanel(_ hint: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ACABTheme.warn).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text("connection did not finish")
                        .font(ACABTheme.mono(12.5, weight: .bold)).foregroundStyle(ACABTheme.text)
                    Text(hint)
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                handledConnectHint = hint
                ble.startScanFromUser()
            } label: {
                Text("SCAN AGAIN")
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                    .foregroundStyle(ACABTheme.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                        .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .panel()
    }

    /// Shown after a full scan window found nothing: an actionable outcome instead of the
    /// silent settle back to the idle CTA (which read as an indefinite spinner giving up).
    private var noBoardsPanel: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 22)).foregroundStyle(ACABTheme.dim)
            Text("no beacons found. make sure your beacon is powered on and nearby, then scan again.")
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
        case "NET CAM": return "network cameras"
        default: return label.lowercased()
        }
    }

    private var scanCTA: some View {
        Button {
            ble.connectionState == .scanning ? ble.stopScan() : ble.startScanFromUser()
        } label: {
            Label(bluetoothScanButtonTitle(
                    isScanning: ble.connectionState == .scanning,
                    bluetoothGranted: btGranted),
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
                         ? "a device policy prevents the app from recording where your phone heard detections. beacon scanning still works, and drones with Remote ID coordinates can still appear on the map."
                         : "beacon scanning still works. most pins showing where your phone heard a detection will be absent, while drones with Remote ID coordinates can still appear.")
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button("OPEN SETTINGS", action: openAppSettings)
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
            Button("OPEN SETTINGS", action: openAppSettings)
                .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                .foregroundStyle(ACABTheme.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                    .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
    }

    private var securePairingNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.fill")
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.accent)
            Text("tap your beacon, then accept the iOS pairing request. pairing encrypts the detection link to this phone.")
                .font(ACABTheme.mono(11))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
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
            Text("already paired to another phone? "
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
                Text("tap to pair securely").font(ACABTheme.mono(10))
                    .foregroundStyle(ACABTheme.dim)
            }
            Spacer()
            SignalBars(bars: Detection.signalBars(rssi: dev.rssi))
            Text(beaconSignalDescription(rssi: dev.rssi))
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
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
                    Text("View saved log (\(ble.logDetections.count))")
                        .font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.ink)
                    Text("history on this phone \u{00B7} browse and export, no beacon needed")
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
                    Text("the beacon that does the listening \u{00B7} soyboi.tech")
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

    private var scopeFootnote: some View {
        Text("Passive detection only. The beacon never jams, spoofs, or interferes.")
            .font(ACABTheme.mono(9))
            .foregroundStyle(ACABTheme.dim)
            .multilineTextAlignment(.center)
            .padding(20)
    }

    private enum AnnouncementPriority {
        case polite
        case assertive
    }

    private func postAccessibilityAnnouncement(_ message: String,
                                               priority: AnnouncementPriority) {
        guard UIAccessibility.isVoiceOverRunning else { return }
        let spokenPriority: UIAccessibilityPriority
        switch priority {
        case .polite: spokenPriority = .low
        case .assertive: spokenPriority = .high
        }
        let spoken = NSAttributedString(
            string: message,
            attributes: [
                .accessibilitySpeechAnnouncementPriority: spokenPriority,
            ])
        AccessibilityNotification.Announcement(spoken).post()
    }
}
