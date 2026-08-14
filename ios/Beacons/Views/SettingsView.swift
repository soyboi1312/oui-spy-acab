import SwiftUI

/// Device tab: OUI-Spy hardware status, scan radios, and alert controls.
struct DeviceView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var manifest: FirmwareManifestStore

    @State private var master: Double = 72
    @State private var pendingVolume = false   // hold the slider at the user's value while dragging + until the board confirms
    @State private var flockOn = true
    @State private var droneOn = true
    @State private var bodyCamOn = false
    @State private var trackerOn = false
    @State private var glassesOn = true
    @State private var droneOuiOn = false        // drone vendor-OUI fallback; sub-option of droneOn, off by default
    @State private var netcamOn = false          // network-camera detector; opt-in, off by default (like droneOui)
    /// Phone-notification toggles, mirrored into @State so the switches animate; the source of
    /// truth is DetectionNotifier's UserDefaults keys. Keyed by DeviceType.rawValue.
    @State private var notifyOn: [Int: Bool] = [:]
    @State private var motorolaOn = true         // broad Motorola-OUI match; sub-option of bodyCamOn, on by default
    @State private var pendingFlock = false     // just flipped; hold the value until the board confirms
    @State private var pendingDrone = false
    @State private var pendingDroneOui = false
    @State private var pendingTracker = false
    @State private var pendingBodyCam = false
    @State private var pendingMotorola = false
    @State private var pendingGlasses = false
    @State private var pendingNetcam = false
    @State private var bleOn = true
    @State private var wifiOn = true
    @State private var wifiEco = 0             // WiFi eco sleep seconds (0/3/7/15); battery SKU only
    @State private var pendingWifiEco = false
    @State private var pendingBle = false      // just flipped; hold until the board confirms
    @State private var pendingWifi = false
    @State private var bufferOn = false
    @State private var pendingBuffer = false   // just flipped; hold until the board confirms
    @State private var lightsOut = false       // "lights out": board LED fully dark
    @State private var pendingLed = false
    @State private var desertOn = false
    @State private var pendingDesert = false
    @State private var confirmEraseBuffer = false   // gate the destructive board-buffer erase
    @State private var confirmPowerOff = false      // gate the rev-B app-driven power-off
    @State private var checkingForUpdate = false    // manual "check for updates" spinner
    @State private var justChecked = false          // brief "checked" confirmation state
    // Rename flow for a watched (starred) device.
    @State private var renameMac: String?
    @State private var renameText = ""
    /// Which list the pencil was tapped in. One alert serves both cards; without this the Save
    /// button would always call renameWatched and silently no-op on an ignored device.
    @State private var renameIsIgnored = false
    // T5: regular width lays the cards out two-up; compact stays a single column.
    @Environment(\.horizontalSizeClass) private var hSize
    // Accessibility text sizes stack the hero and stat rows vertically and pad the scroll
    // bottom; the default layout is untouched.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // Any mode but the buzzer dims the volume sliders.
    private var muted: Bool { ble.alertMode != .buzzer }

    var body: some View {
        NavigationStack {
            ZStack {
                ACABTheme.bg.ignoresSafeArea()
                ScrollView {
                    Group {
                        if hSize == .regular {
                            // R13: mirror the Android tablet split (>=840dp). The page header, the
                            // hero, and the fault/firmware banners span the FULL content width; the
                            // remaining slots split into two balanced columns in list order. The tall
                            // config drawer lives in the left column (with stats + managed devices),
                            // the rest goes right, so no row ever pairs the drawer with a lone card.
                            VStack(alignment: .leading, spacing: 16) {
                                header
                                deviceHero
                                if coprocFault { coprocFaultBanner } else if nrfUpdating { nrfUpdatingBanner }
                                if updateExists { firmwareBanner }
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 14) {
                                        statsGrid
                                        configPanel
                                        managedDevicesRow
                                        // Present on iPad the same as compact: this row was
                                        // simply missing from the regular-width split, so the
                                        // whole contribute feature did not exist on iPad.
                                        helpImproveRow
                                        helpSupportRow
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                    VStack(alignment: .leading, spacing: 14) {
                                        disconnectButton
                                        if showPowerOff { powerOffButton }
                                        aboutFooter
                                    }
                                    .frame(maxWidth: .infinity, alignment: .top)
                                }
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: 1000)
                            .frame(maxWidth: .infinity)
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                settingsCards
                                Spacer(minLength: 8)
                            }
                            .frame(maxWidth: 640)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, ACABTheme.pad)
                    .padding(.top, 8)
                }
                // Extra bottom margin only at accessibility sizes, so grown content never ends
                // under the tab bar; zero at default sizes (layout untouched).
                .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
            }
            .navigationBarHidden(true)
            .confirmationDialog(
                "Erase \(ble.status?.bufCount ?? 0) buffered detection\((ble.status?.bufCount ?? 0) == 1 ? "" : "s") on the board?",
                isPresented: $confirmEraseBuffer, titleVisibility: .visible
            ) {
                Button("Erase", role: .destructive) { ble.clearBufferLog() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently wipes the board's offline log and can't be undone. Detections already synced to this phone stay in your log; anything not yet synced is lost.")
            }
        }
        .onAppear(perform: sync)
        .onChange(of: ble.status) { _, _ in sync() }
        // "moto" lives outside DeviceStatus, so a frame that changed only the Motorola sub-toggle
        // (the board echoing our write back) wouldn't move `status` and wouldn't clear the pending
        // hold. Watch it directly.
        .onChange(of: ble.motorolaOn) { _, _ in sync() }
    }

    // copy board state into local UI vars; runs on appear and on every status update
    private func sync() {
        guard let s = ble.status else { return }
        // Hold the slider at the user's value while dragging + until the board echoes it back, so a
        // status frame mid-drag can't snap it to the board's stale volume (same idea as the toggles).
        if pendingVolume { if s.volume == Int(master.rounded()) { pendingVolume = false } } else { master = Double(s.volume) }
        // Hold a just-toggled switch at the user's value until the board confirms it,
        // so the ~5s status frame can't snap it back to off before then.
        if pendingFlock { if s.flock == flockOn { pendingFlock = false } } else { flockOn = s.flock }
        if pendingDrone { if s.drone == droneOn { pendingDrone = false } } else { droneOn = s.drone }
        if pendingDroneOui { if s.droui == droneOuiOn { pendingDroneOui = false } } else { droneOuiOn = s.droui }
        if pendingBodyCam { if s.axon == bodyCamOn { pendingBodyCam = false } } else { bodyCamOn = s.axon }
        // The Motorola sub-toggle rides "moto", which isn't part of DeviceStatus; BLEManager reads
        // it off the status frame, so mirror from there instead of `s`. Same hold-until-confirmed.
        if pendingMotorola { if ble.motorolaOn == motorolaOn { pendingMotorola = false } } else { motorolaOn = ble.motorolaOn }
        if pendingTracker { if s.tracker == trackerOn { pendingTracker = false } } else { trackerOn = s.tracker }
        if pendingGlasses { if s.glasses == glassesOn { pendingGlasses = false } } else { glassesOn = s.glasses }
        if pendingNetcam { if s.ncam == netcamOn { pendingNetcam = false } } else { netcamOn = s.ncam }
        if pendingBuffer { if s.bufferingOn == bufferOn { pendingBuffer = false } } else { bufferOn = s.bufferingOn }
        if pendingLed { if (!s.ledEnabled) == lightsOut { pendingLed = false } } else { lightsOut = !s.ledEnabled }
        if pendingDesert { if s.desertMode == desertOn { pendingDesert = false } } else { desertOn = s.desertMode }
        // Scan radios get the same hold: a periodic status frame generated before the write
        // lands would otherwise snap the switch back, inviting a duplicate tap and write.
        if pendingBle { if s.ble == bleOn { pendingBle = false } } else { bleOn = s.ble }
        if pendingWifi { if s.wifi == wifiOn { pendingWifi = false } } else { wifiOn = s.wifi }
        if pendingWifiEco { if s.wifiEco == wifiEco { pendingWifiEco = false } } else { wifiEco = s.wifiEco }
    }

    // MARK: 1g composition
    // Three content classes: glanceable state stays open (hero + trimmed stats),
    // firmware promotes to a crimson banner when an update exists, and everything
    // configurable folds into one single-open-at-a-time section panel. Watched/ignored
    // and About push to sub-screens. The same builder feeds both the compact column
    // and the regular two-up grid; the folded rows just flow into the grid unchanged.
    @ViewBuilder
    private var settingsCards: some View {
        header
        deviceHero
        if coprocFault { coprocFaultBanner }        // dual-radio nRF fault, right under the hero
        else if nrfUpdating { nrfUpdatingBanner }   // same slot, but the nRF is down on purpose
        if updateExists { firmwareBanner }   // crimson banner directly under the hero
        statsGrid                            // UPTIME + DETECTIONS (2-up)
        configPanel                          // scan radios / detectors / alerts / drive / desert+buffer / LED
        managedDevicesRow                    // -> watched + ignored sub-screen
        helpImproveRow                       // -> contribute a field observation (manual export)
        helpSupportRow                       // -> bundled FAQ + support routes
        disconnectButton
        if showPowerOff { powerOffButton }   // rev-B only: shut the board down over BLE
        aboutFooter                          // -> about sub-screen
    }

    // Which config fold section is currently open. Exactly one at a time (nil = all closed).
    // The firmware row/banner shares this state under `.firmware`, so opening it also
    // collapses any open config section.
    private enum ConfigSection: Hashable { case firmware, radios, detectors, alerts, notify, drive, desert, led }
    @State private var openSection: ConfigSection?

    // An update "exists" whenever the board is behind the manifest, or an OTA is mid-flight
    // / just finished. Drives banner-vs-fold-row for firmware. Same signals the card reads.
    private var updateExists: Bool { outdated || ble.combinedState.isRunning || combinedTerminal }

    // MARK: firmware banner (shown only when updateExists)
    // Filled crimson header; tap expands today's firmwareCard verbatim (OTA progress /
    // failed states keep their current UI, since it IS the same card).
    private var firmwareBanner: some View {
        let open = openSection == .firmware
        return VStack(spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { openSection = open ? nil : .firmware }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Firmware v\(latestVersion) ready")
                            .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.onAccent)
                        Text("installed v\(ble.status?.version ?? "-") \u{00B7} updates over Bluetooth")
                            .font(ACABTheme.mono(10.5)).tracking(1.0)
                            .foregroundStyle(ACABTheme.onAccent.opacity(0.82))
                    }
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ACABTheme.onAccent)
                }
                .padding(16)
                .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { firmwareCard }   // today's card, unchanged
        }
    }

    // MARK: config fold panel (one open section at a time)
    private var configPanel: some View {
        VStack(spacing: 0) {
            // Firmware lives here as a plain fold row only when there's no banner (up to date).
            if !updateExists {
                foldRow(.firmware, glyph: "memorychip", title: "Firmware", kicker: firmwareRowKicker) { firmwareCard }
                rowDivider
            }
            foldRow(.radios, glyph: "antenna.radiowaves.left.and.right",
                    title: "Scan radios", kicker: radiosKicker) { radiosCard }
            rowDivider
            foldRow(.detectors, glyph: "scope",
                    title: "Detectors", kicker: detectorsKicker) { detectorsCard }
            if ble.status?.isMeshDetect != true {   // mesh board has no buzzer -> no Alerts row
                rowDivider
                foldRow(.alerts, glyph: "bell", title: "Alerts", kicker: alertsKicker) { buzzerCard }
            }
            rowDivider
            // NOT gated on isMeshDetect, unlike Alerts: these are PHONE notifications, so they work
            // the same on a board with no buzzer. That is precisely the board where they matter most.
            foldRow(.notify, glyph: "app.badge", title: "Notifications", kicker: notifyKicker) { notifyCard }
            rowDivider
            // Board LED sits with Alerts (both are local feedback), above the situational modes.
            foldRow(.led, glyph: "lightbulb", title: "Board LED", kicker: ledKicker) { lightsOutCard }
            rowDivider
            foldRow(.drive, glyph: "car", title: "Drive mode", kicker: driveKicker) { driveModeCard }
            rowDivider
            foldRow(.desert, glyph: "mountain.2",
                    title: "Desert mode + buffer", kicker: desertKicker) {
                VStack(spacing: 12) { desertModeCard; offlineBufferCard }
            }
        }
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var rowDivider: some View {
        Rectangle().fill(ACABTheme.line).frame(height: 1).padding(.horizontal, 16)
    }

    // Hand-rolled disclosure row: glyph + title + live kicker + flipping chevron. Open ->
    // accent-tinted glyph, flipped chevron, faint accent wash, and today's card verbatim below.
    @ViewBuilder
    private func foldRow<Content: View>(_ section: ConfigSection, glyph: String, title: String,
                                        kicker: String, @ViewBuilder content: () -> Content) -> some View {
        let open = openSection == section
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { openSection = open ? nil : section }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: glyph)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(open ? ACABTheme.accent : ACABTheme.dim)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        // fixedSize(vertical:) lets both lines GROW DOWNWARD at large Dynamic Type
                        // instead of widening the row. Without it the HStack is sized by the text's
                        // ideal width and the whole page runs off the screen edge.
                        Text(title).font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Kicker(kicker)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 8)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(open ? ACABTheme.accent : ACABTheme.faint)
                }
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Spoken disclosure state: the flipped chevron is the only visual cue, which a
            // screen reader cannot see.
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open { content().padding(.bottom, 14) }
        }
        .padding(.horizontal, 16)
        .background(open ? ACABTheme.accent.opacity(0.04) : Color.clear)
    }

    // MARK: managed devices row -> watched + ignored sub-screen
    private var managedDevicesRow: some View {
        NavigationLink { managedDevicesScreen } label: {
            HStack(spacing: 12) {
                Image(systemName: "star.fill")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.watchTone).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Managed devices").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker(managedKicker)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    /// Entry point for the bundled FAQ. Sits below Managed devices and above Disconnect on
    /// purpose: it is a reference surface, not a control, so it should not sit among the toggles
    /// that change what the board does.
    // Field research: contribute a capture of a device the beacon did not identify. Manual export
    // only (see ContributeView) - nothing leaves the phone without the user. Mirrors Android's
    // "Help improve detection" row.
    private var helpImproveRow: some View {
        NavigationLink { ContributeView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "flask")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Improve detection").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker("CONTRIBUTE A FIELD OBSERVATION")
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    private var helpSupportRow: some View {
        NavigationLink { HelpView() } label: {
            HStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(ACABTheme.dim).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Help + support").font(ACABTheme.display(15, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Kicker("FAQ · TROUBLESHOOTING · CONTACT")
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(ACABTheme.faint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .panel()
    }

    private var managedDevicesScreen: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !ble.watched.isEmpty { watchedCard }
                    if !ble.ignored.isEmpty { ignoredCard }
                    // Both lists empty: say so, or the pushed screen reads as a loading failure.
                    if ble.watched.isEmpty && ble.ignored.isEmpty {
                        Text("No watched or ignored devices yet.")
                            .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                }
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
                .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
            }
        }
        .navigationTitle("Managed devices")
        .navigationBarTitleDisplayMode(.inline)
        // The rename alert MUST live here, not on the root Device screen: the pencil is in watchedCard,
        // which only renders inside this pushed sub-screen. An alert attached to the covered root never
        // presents, so tapping the pencil silently did nothing.
        .alert("Rename device", isPresented: renameAlertBinding) {
            TextField("Label", text: $renameText)
            Button("Cancel", role: .cancel) { renameMac = nil }
            Button("Save") {
                if let mac = renameMac {
                    let t = renameText.trimmingCharacters(in: .whitespaces)
                    if renameIsIgnored { ble.renameIgnored(mac, to: t) } else { ble.renameWatched(mac, to: t) }
                }
                renameMac = nil
            }
        } message: {
            Text("Name this device so you recognize it in the log.")
        }
    }

    // MARK: about footer link -> about sub-screen
    private var aboutFooter: some View {
        NavigationLink { aboutScreen } label: {
            Text("about \u{00B7} made by soyboi")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var aboutScreen: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { aboutCard }
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .padding(.horizontal, ACABTheme.pad).padding(.top, 8)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: fold-row kickers (all live state, terse ALL-CAPS)
    private var firmwareRowKicker: String {
        // An nRF-only update leaves the S3 version current, so it lives in this fold row rather
        // than the crimson banner; say "UPDATE READY" so the kicker isn't misleadingly "UP TO DATE".
        "v\(ble.status?.version ?? latestVersion) \u{00B7} \(combinedStale ? "UPDATE READY" : "UP TO DATE")"
    }

    private var radiosKicker: String {
        switch (bleOn, wifiOn) {
        case (true, true):   return "BLE + WI-FI ON"
        case (true, false):  return "BLE ON \u{00B7} WI-FI OFF"
        case (false, true):  return "WI-FI ON \u{00B7} BLE OFF"
        case (false, false): return "ALL RADIOS OFF"
        }
    }

    private var detectorsKicker: String {
        let onCount = [flockOn, droneOn, bodyCamOn, trackerOn, glassesOn, netcamOn].filter { $0 }.count
        let expOn = [glassesOn].filter { $0 }.count
        return "\(onCount) ON \u{00B7} \(expOn) EXP \u{00B7} TRACKERS \(trackerOn ? "ON" : "OFF")"
    }

    private var alertsKicker: String {
        switch ble.alertMode {
        case .buzzer:  return "BUZZER \u{00B7} VOLUME \(Int(master))"
        case .vibrate: return "VIBRATE \u{00B7} PHONE BUZZES"
        case .silent:  return "SILENT"
        }
    }

    private var driveKicker: String {
        "COUNTER \(ble.driveModeWanted ? "ON" : "OFF") \u{00B7} LOCK SCREEN \(ble.redactLockScreen ? "HIDDEN" : "SHOWN")"
    }

    private var desertKicker: String {
        switch (desertOn, bufferOn) {
        case (false, false): return "BOTH OFF"
        case (true, true):   return "BOTH ON"
        case (true, false):  return "DESERT ON \u{00B7} BUFFER OFF"
        case (false, true):  return "BUFFER ON \u{00B7} DESERT OFF"
        }
    }

    private var ledKicker: String { lightsOut ? "LIGHTS OUT" : "HEARTBEAT ON" }

    private var managedKicker: String {
        "\(ble.watched.count) WATCHED \u{00B7} \(ble.status?.watchCount ?? 0) ON BOARD \u{00B7} \(ble.ignored.count) IGNORED"
    }

    // MARK: header
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Beacon").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker(ble.demoMode ? "SAMPLE DATA" : "PAIRED OVER BLE")
            }
            Spacer()
            // Ask the board for a fresh status frame right now, instead of waiting
            // for the next periodic notify.
            Button { ble.otaRereadStatus() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(ACABTheme.dim)
                    .frame(width: 38, height: 38)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                    .frame(minWidth: 44, minHeight: 44)   // 44pt hit target; drawn circle unchanged
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Refresh device status")
        }
    }

    // MARK: device hero
    /// At accessibility text sizes the one-line hero (badge · name · battery · dot) has no
    /// room left for the name, so it stacks: badge + status glyphs on top, the text below.
    /// Default sizes keep the original single row.
    @ViewBuilder
    private var deviceHero: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 14) {
                        heroBadge
                        Spacer()
                        heroBattery
                        heroDot
                    }
                    heroText
                }
            } else {
                HStack(spacing: 14) {
                    heroBadge
                    heroText
                    Spacer()
                    heroBattery
                    heroDot
                }
            }
        }
        .panel(strong: true)
    }

    private var heroBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(ACABTheme.bg3).frame(width: 52, height: 38)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ACABTheme.line, lineWidth: 1))
            Circle().fill(ACABTheme.accent).frame(width: 7, height: 7)
                .shadow(color: ACABTheme.accentGlow, radius: 4).offset(x: -14, y: -9)
        }
    }

    private var heroText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text((ble.connectedName?.contains("ACAB") == true || ble.connectedName?.contains("beacon") == true)
                 ? "All Cameras Are Beacons" : (ble.connectedName ?? "ESP32 board"))
                .font(ACABTheme.display(16, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(2).minimumScaleFactor(0.8).fixedSize(horizontal: false, vertical: true)
            Text(ble.demoMode ? "SAMPLE DATA · no live board"
                              : "CONNECTED · \(ble.status?.firmwareLabel ?? "beacons")\(boardRevSuffix)")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
        }
    }

    @ViewBuilder
    private var heroBattery: some View {
        if let bat = ble.status?.battery {
            let charging = ble.status?.charging == true
            HStack(spacing: 4) {
                Image(systemName: charging ? "battery.100.bolt" : batterySymbol(bat))
                Text("\(bat)%")
            }
            .font(ACABTheme.mono(11))
            .foregroundStyle(charging ? ACABTheme.accent : (bat <= 15 ? ACABTheme.warn : ACABTheme.dim))
        }
    }

    private var heroDot: some View {
        ScanDot(color: ble.connectionState == .connected ? ACABTheme.accent : ACABTheme.faint)
    }

    private func batterySymbol(_ p: Int) -> String {
        switch p {
        case ..<13: return "battery.0";   case ..<38: return "battery.25"
        case ..<63: return "battery.50";  case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    // MARK: nRF radio fault (dual-radio beacon board only)
    // The ESP32 only emits "co" when it's a dual-radio board; when it does and the value is
    // false, the nRF co-processor stopped answering over UART, so the whole BLE-detection half
    // is dark. Single-radio boards omit the key, so `coproc == nil` and this never fires.
    // Except during a BLE-DFU window: the nRF sits in its bootloader on purpose, so "co" reads
    // false for minutes at a time and the board flags that with "nrfup". Same dark radio, wholly
    // different story, so the fault defers to it rather than crying wolf over a healthy update.
    private var nrfUpdating: Bool { ble.status?.nrfUpdating == true }
    // App-authoritative suppression: while the one-click flow is running we KNOW the nRF is being
    // reset-pulsed / reflashed, so force the fault banner off regardless of what the firmware's
    // `nrfup`/`co` happen to report this frame. OR-in the running flag here at the source.
    private var coprocFault: Bool { ble.status?.coproc == false && !nrfUpdating && !ble.combinedState.isRunning }

    /// The calm twin of coprocFaultBanner: same dark BLE half, on purpose and temporary.
    private var nrfUpdatingBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(0.7)
                .tint(ACABTheme.dim)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("updating co-processor")
                    .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("the second radio is taking new firmware, so BLE gear won't be spotted until it comes back. Wi-Fi detection still runs. keep the board powered and stay close.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var coprocFaultBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(ACABTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("nRF radio fault - bluetooth detection offline")
                    .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("the second radio stopped answering, so BLE gear won't be spotted. Wi-Fi detection still runs. try a power cycle, and reflash if it sticks.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(ACABTheme.accentSoft, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.accent.opacity(0.5), lineWidth: 1))
    }

    // MARK: firmware
    // The board's fw label ("beacon board" etc.), used to look up its manifest entry.
    private var fwLabel: String { ble.status?.firmwareLabel ?? "" }
    // The manifest entry for this board, if the manifest lists it.
    private var fwEntry: FirmwareManifest.Build? { manifest.entry(forFwLabel: fwLabel) }
    // Carrier revision, shown next to the fw label so support can tell which board is in the case
    // without opening it. Silent when the board does not report it (older/single-radio firmware) -
    // an unlabelled board reads as "we were not told", not as rev-A.
    private var boardRevSuffix: String {
        guard let r = ble.status?.boardRev, r == "A" || r == "B" else { return "" }
        // The rev-B fw label already ends in "rev-B", so appending the badge there prints
        // "... rev-B · rev-B". Only add it when the label does not already name this rev
        // (rev-A's label is just "beacon board", so it still gets the badge).
        if (ble.status?.firmwareLabel ?? "").lowercased().contains("rev-\(r.lowercased())") { return "" }
        return " · rev-\(r)"
    }
    // Belt-and-braces OTA revision gate. The PRIMARY defence is that rev-B firmware reports a
    // distinct fw label ("beacon board rev-B", set in platformio.ini) and the manifest is KEYED by
    // that label (FirmwareManifest.build(forFwLabel:) is a dictionary lookup), so a rev-B board
    // cannot resolve the rev-A entry at all - and until the manifest gains a rev-B key it resolves
    // nothing and falls back to the browser flasher. Both are fail-closed.
    // This second check catches the case where someone re-unifies the labels or hand-edits the
    // manifest: if the board TELLS us its revision, the key we are about to flash from has to agree.
    // A wrong-image flash parks the unit after every boot and is USB-recovery only, so a false
    // refusal is by far the cheaper error.
    private var revisionMatchesManifest: Bool {
        guard let rev = ble.status?.boardRev, rev == "A" || rev == "B" else { return true }  // not told = do not block
        let entryIsRevB = fwLabel.lowercased().contains("rev-b")
        return entryIsRevB == (rev == "B")
    }
    // Latest version from the manifest (falls back to the shipped constant when unlisted).
    private var latestVersion: String { manifest.latestVersion(forFwLabel: fwLabel) }
    // Installed firmware older than the manifest's latest?
    private var outdated: Bool { ble.status?.updateAvailable(latest: latestVersion) ?? false }

    /// Every condition that must hold for in-app OTA to be offered:
    /// (1) the manifest lists this board, (2) it's marked OTA-capable, (3) it carries a
    /// verifiable image (sha256 + size), (4) the connected board actually exposes the OTA
    /// characteristic, (5) the installed version is strictly older than the manifest's,
    /// (6) the manifest key matches the carrier revision the board reports (see below).
    private var otaEligible: Bool {
        guard let e = fwEntry, e.ota, e.hasVerifiableImage, ble.otaCapable, outdated,
              revisionMatchesManifest else { return false }
        return true
    }

    /// The flasher URL to send the user to when OTA isn't offered: manifest first, then the
    /// baked-in default.
    private var flasherURL: URL {
        let fromManifest = (fwEntry?.flasher).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        return fromManifest ?? URL(string: "https://soyboi1312.github.io/all-cameras-are-beacons/")!
    }

    /// TYPE-ERASED ON PURPOSE - do not "clean this up" back to `some View`.
    ///
    /// This is the deepest view in the app: a three-way state branch whose arms are themselves
    /// stacks of heavily-modified buttons (`.background(_:in:)` + `.overlay(strokeBorder:)` each
    /// add another `ModifiedContent` layer), and the whole thing is handed to the GENERIC
    /// `foldRow<Content:>` as its Content. Left concrete, the composed static type nests deep
    /// enough that flipping the branch - which is exactly what tapping "update" does - made
    /// SwiftUI instantiate that type's metadata at runtime, and the Swift runtime's RECURSIVE
    /// demangler overflowed the 1 MB main-thread stack. The app died on the tap, every time.
    ///
    /// Reproduced on device 2026-08-06 (Beacons-2026-08-06-115438.ips): EXC_BAD_ACCESS /
    /// KERN_PROTECTION_FAILURE on the stack guard page, thread 0, frames
    ///   closure #1 in DeviceView.firmwareCard.getter
    ///   -> __swift_instantiateConcreteTypeFromMangledNameV2
    ///   -> swift_getTypeByMangledNameInContext2
    ///   -> decodeMangledType / decodeGenericArgs x37.
    ///
    /// `AnyView` boxes the branch so the mangled name stays shallow. The cost is that SwiftUI
    /// cannot diff across the box, which is free here: the three arms are different types and
    /// would be replaced wholesale anyway.
    ///
    /// VERIFIED on the same device that produced the crash: with this boxing (plus the matching
    /// boxing on `combinedControlButtons`) tapping the firmware card no longer terminates the app.
    private var firmwareCard: AnyView {
        let installed = ble.status?.version
        return AnyView(VStack(alignment: .leading, spacing: 12) {
            Kicker("FIRMWARE")
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(installed.map { "v\($0)" } ?? "-")
                        .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                    Kicker("INSTALLED")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("v\(latestVersion)")
                        .font(ACABTheme.display(20, weight: .semibold))
                        .foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.dim)
                    Kicker("LATEST")
                }
            }
            Divider().overlay(ACABTheme.line)

            // One-click combined update: ONE button that flashes the board firmware (S3) and, when
            // it applies, the co-processor (nRF) in a single determinate flow. The transfer engines
            // are unchanged; BLEManager+CombinedUpdate sequences them and merges their progress.
            firmwareCardState
            // Manual refresh stays reachable except mid-update, so a stale cached manifest can be
            // re-fetched even when an update already looks available.
            if !ble.combinedState.isRunning {
                checkForUpdatesButton
            }
        }
        .panel())
    }

    /// The three-way state branch, boxed so `firmwareCard`'s type does not carry the whole
    /// progress/offer/status subtree inside two nested `_ConditionalContent` layers. See the
    /// stack-overflow note on `firmwareCard`.
    private var firmwareCardState: AnyView {
        if ble.combinedState.isRunning || combinedTerminal {
            return AnyView(combinedProgressView)   // running, or just finished (done / failed / partial)
        }
        if combinedStale {
            return AnyView(combinedOfferView)      // either radio is behind: offer the single update
        }
        return AnyView(firmwareStatusLine)         // up to date, or outdated with browser guidance
    }

    // MARK: one-click combined update UI

    /// Either the board firmware or the co-processor is behind and self-updatable.
    ///
    /// `revisionMatchesManifest` is checked HERE because this is the live path. It was previously
    /// only inside `otaEligible`, which is defined and referenced nowhere: the rev-B safety gate
    /// was dead code on iOS while every update actually offered came through this property. So the
    /// belt-and-braces revision check that Android performs did not exist here at all, which is
    /// the reverse of what the comments on both sides claimed.
    ///
    /// It matters because a wrong-revision image parks the unit after every boot and is
    /// USB-recovery only, so a false refusal is by far the cheaper error.
    private var combinedStale: Bool {
        guard let e = fwEntry, revisionMatchesManifest else { return false }
        return ble.combinedUpdateStale(entry: e, fwLabel: fwLabel, latest: latestVersion)
    }
    /// The BOARD leg specifically is behind. `combinedStale` is the OR of both radios, so this is
    /// what lets the offer copy tell "board is behind" from "only the co-processor is behind".
    private var s3Stale: Bool {
        guard let e = fwEntry, revisionMatchesManifest else { return false }
        return ble.s3UpdateStale(entry: e, fwLabel: fwLabel, latest: latestVersion)
    }
    /// The combined flow is at a terminal point we keep on screen (done / failed / partial).
    private var combinedTerminal: Bool {
        switch ble.combinedState { case .done, .failed, .partial: return true; default: return false }
    }

    private var combinedOfferView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(ACABTheme.accent)
                // Name what is ACTUALLY behind. When only the co-processor is stale the board is
                // already on latestVersion, and the old unconditional wording read as a
                // contradiction next to the "vX INSTALLED / vX LATEST" row directly above it.
                Text(s3Stale
                     ? "Update available: v\(latestVersion). You can install it here, over Bluetooth."
                     : "Co-processor update available. The board firmware is already current; this updates the second radio, over Bluetooth.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            combinedUpdateButton(title: "update")
            Text("Installs over Bluetooth and usually takes about 2-3 minutes. The board restarts on its own partway through. Keep this phone next to the beacon with the app open until it finishes.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func combinedUpdateButton(title: String) -> some View {
        Button { if let e = fwEntry { ble.startCombinedUpdate(entry: e, fwLabel: fwLabel, latest: latestVersion) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                Text(title).font(ACABTheme.display(15, weight: .semibold))
            }
            .foregroundStyle(ACABTheme.onAccent)
            .frame(maxWidth: .infinity).padding(.vertical, 13)
            .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var combinedProgressView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: combinedStatusSymbol)
                    .font(.system(size: 13)).foregroundStyle(combinedStatusTone)
                Text(combinedStatusLabel)
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                Spacer(minLength: 0)
                if ble.combinedState.isRunning {
                    Text("\(Int((ble.combinedProgress * 100).rounded()))%")
                        .font(ACABTheme.mono(12, weight: .semibold)).foregroundStyle(combinedStatusTone)
                }
            }
            if ble.combinedState.isRunning {
                ProgressView(value: min(max(ble.combinedProgress, 0), 1), total: 1).tint(ACABTheme.accent)
                Text(combinedElapsedText)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
            if let detail = combinedDetailText {
                Text(detail).font(ACABTheme.mono(10.5)).foregroundStyle(combinedStatusTone)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if ble.combinedState.isRunning {
                Text("Keep this phone next to the beacon with the app open. Don't lock it or leave this screen.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            combinedControlButtons
        }
    }

    /// Boxed for the same reason as `firmwareCard`: three arms, each a Button carrying a
    /// `.background(_:in:)` and an `.overlay(strokeBorder:)`, sitting inside the progress arm of
    /// the card's own branch. This is the single biggest contributor to the nesting depth that
    /// overflowed the demangler's stack.
    private var combinedControlButtons: AnyView {
        if ble.combinedCanCancel {
            return AnyView(secondaryButton("Cancel", tone: ACABTheme.accent,
                                           border: ACABTheme.lineStrong, role: .destructive) {
                ble.combinedCancel()
            })
        }
        if ble.combinedState.isRunning {
            return AnyView(Text("The board has committed this update and is finishing safely.")
                .font(ACABTheme.mono(10.5))
                .foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true))
        }
        if case .partial = ble.combinedState {
            // S3 took; the second radio didn't finish. The same primary button re-offers just the
            // nRF leg (the S3 is current now, so a fresh run does the co-processor only).
            // Spacing 12 matches what the enclosing VStack gave these when they were loose
            // siblings in a ViewBuilder tuple, so the box does not change the layout.
            return AnyView(VStack(alignment: .leading, spacing: 12) {
                combinedUpdateButton(title: "finish second radio")
                secondaryButton("Not now") { ble.dismissCombinedUpdate() }
            })
        }
        return AnyView(secondaryButton("Done") { ble.dismissCombinedUpdate() })
    }

    /// The card's flat secondary button. Factored out because all three control arms drew the same
    /// stack of modifiers inline, and every repetition of it deepened the composed view type that
    /// overflowed the demangler (see `firmwareCard`).
    private func secondaryButton(_ title: String,
                                 tone: Color = ACABTheme.dim,
                                 border: Color = ACABTheme.line,
                                 role: ButtonRole? = nil,
                                 action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title).font(ACABTheme.display(14, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 11)
                .foregroundStyle(tone)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm).strokeBorder(border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var combinedStatusLabel: String {
        ble.combinedPhaseLabel.isEmpty ? "Updating" : ble.combinedPhaseLabel
    }
    private var combinedElapsedText: String {
        let t = max(0, Int(ble.combinedElapsed)); return String(format: "elapsed %d:%02d", t / 60, t % 60)
    }
    private var combinedDetailText: String? {
        switch ble.combinedState {
        case .failed(let r): return r
        // PARTIAL means "some leg didn't land", and which leg depends on the run. A co-processor-only
        // run that fails never touched the board, so it must not claim the board was updated.
        case .partial:
            return ble.combinedS3Updated
                ? "Board updated. Second radio update didn't finish. Tap to finish the second radio, or dismiss - the button re-offers it on its own once the co-processor reports in."
                : "Second radio update didn't finish. The board firmware is unchanged and still working. Tap to try the second radio again, or dismiss - the button re-offers it on its own once the co-processor reports in."
        case .done:          return ble.combinedNotice ?? "Your beacon is up to date."
        default:             return ble.combinedNotice
        }
    }
    private var combinedStatusSymbol: String {
        switch ble.combinedState {
        case .done:    return "checkmark.seal.fill"
        case .failed:  return "exclamationmark.triangle.fill"
        case .partial: return "exclamationmark.circle.fill"
        default:       return "arrow.triangle.2.circlepath"
        }
    }
    private var combinedStatusTone: Color {
        switch ble.combinedState {
        case .done:             return ACABTheme.accent
        case .failed, .partial: return ACABTheme.warn
        default:                return ACABTheme.dim
        }
    }

    // Plain status line: on the latest, or outdated with a pointer to the browser flasher.
    private var firmwareStatusLine: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: outdated ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 13)).foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.accent)
                Text(outdated
                     ? "Update available. Reflash your board to v\(latestVersion) in your browser."
                     : "You're on the latest firmware.")
                    .font(ACABTheme.mono(11)).foregroundStyle(outdated ? ACABTheme.warn : ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if outdated {
                Link(destination: flasherURL) {
                    HStack(spacing: 8) {
                        Image(systemName: "safari").font(.system(size: 13))
                        Text("Open the browser flasher")
                            .font(ACABTheme.display(14, weight: .semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(ACABTheme.accent)
                    .padding(.vertical, 11).padding(.horizontal, 13)
                    .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                        .strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // Manual "check for updates": forces a manifest refresh past the 6h TTL, then the view
    // re-evaluates update availability off the fresh manifest (updateExists / outdated are
    // computed from it). This is what lets a freshly-published version show up on demand.
    private var checkForUpdatesButton: some View {
        Button {
            guard !checkingForUpdate else { return }
            Task {
                checkingForUpdate = true
                justChecked = false
                await manifest.refreshNow()
                checkingForUpdate = false
                justChecked = true
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                justChecked = false
            }
        } label: {
            HStack(spacing: 8) {
                if checkingForUpdate {
                    ProgressView().controlSize(.mini).tint(ACABTheme.dim)
                } else {
                    Image(systemName: (justChecked && !outdated) ? "checkmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                }
                // Don't claim "Up to date" if the refresh just revealed a newer version (the banner
                // above then says an update is ready); show a neutral "Checked" instead.
                Text(checkingForUpdate ? "Checking\u{2026}" : (justChecked ? (outdated ? "Checked" : "Up to date") : "Check for updates"))
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                Spacer(minLength: 0)
            }
            .foregroundStyle((justChecked && !outdated) ? ACABTheme.accent : ACABTheme.dim)
            .padding(.vertical, 9).padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(checkingForUpdate)
    }

    // MARK: scan radios
    private var radiosCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("SCAN RADIOS")
            radioToggle("bluetooth", "ALPR \u{00B7} drone \u{00B7} trackers", isOn: Binding(
                get: { bleOn }, set: { bleOn = $0; pendingBle = true; ble.setBLEScan($0) }))
            Divider().overlay(ACABTheme.line)
            radioToggle("Wi-Fi", "2.4 GHz \u{00B7} ALPR \u{00B7} drone RID", isOn: Binding(
                get: { wifiOn }, set: { wifiOn = $0; pendingWifi = true; ble.setWiFiScan($0) }))
            // Eco: only on battery boards (the board reports "bat" only when it has the sense
            // divider), and only meaningful while Wi-Fi is on. Duty-cycles the Wi-Fi RX to stretch
            // runtime; Bluetooth is untouched. Honest about the tradeoff right below the pills.
            if wifiOn, ble.status?.battery != nil {
                Divider().overlay(ACABTheme.line)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Kicker("WI-FI ECO")
                        Spacer()
                        Text(wifiEco == 0 ? "always on" : "sleeps \(wifiEco)s / sweep")
                            .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                    }
                    HStack(spacing: 6) {
                        ForEach([(0, "MAX"), (3, "3s"), (7, "7s"), (15, "15s")], id: \.0) { v, label in
                            Button {
                                wifiEco = v; pendingWifiEco = true; ble.setWifiEco(v)
                            } label: {
                                Text(label)
                                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(wifiEco == v ? ACABTheme.onAccent : ACABTheme.dim)
                                    .frame(maxWidth: .infinity).padding(.vertical, 7)
                                    .background(wifiEco == v ? ACABTheme.accent : ACABTheme.bg2, in: Capsule())
                                    .overlay(Capsule().strokeBorder(wifiEco == v ? .clear : ACABTheme.line, lineWidth: 1))
                                    // 44pt hit target; drawn pill unchanged.
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(wifiEco == v ? .isSelected : [])
                        }
                    }
                    Text("stretches battery by sweeping Wi-Fi less often. you may miss a Wi-Fi-only camera between sweeps; Bluetooth detection is unaffected.")
                        .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                }
            }
        }
        .panel()
    }

    // MARK: detectors
    private var detectorsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("DETECTORS")
            radioToggle("alpr radio signals", "flock, raven, when they broadcast over bluetooth or 2.4 GHz wifi \u{00B7} many installs now stay silent", isOn: Binding(
                get: { flockOn }, set: { flockOn = $0; pendingFlock = true; ble.setFlockEnabled($0) }))
            Divider().overlay(ACABTheme.line)
            radioToggle("drones (remote ID)", "FAA remote ID \u{00B7} operator location", isOn: Binding(
                get: { droneOn }, set: { droneOn = $0; pendingDrone = true; ble.setDroneEnabled($0) }))
            // Sub-option of the drone detector: the vendor-OUI fallback. Inset + disabled while the
            // parent drone detector is off, to read as subordinate to the toggle above it. Off by
            // default because an OUI match alone can't tell a stationary Parrot gadget from a drone.
            radioToggle("non-broadcasting drones", "OUI match only, off by default, may false-positive", isOn: Binding(
                get: { droneOuiOn }, set: { droneOuiOn = $0; pendingDroneOui = true; ble.setDroneOuiEnabled($0) }))
                .padding(.leading, 22)
                .disabled(!droneOn)
                .opacity(droneOn ? 1 : 0.4)
            Divider().overlay(ACABTheme.line)
            // Names the whole category, not just Axon: post-split this covers Axon (payload tag
            // + OUI), Utility BodyWorn, and the Motorola vendor proxy in the sub-row below. The
            // old "Axon signature" copy read oddly directly above a Motorola control. Matches
            // Android's DeviceScreen wording so the two platforms describe the switch the same way.
            radioToggle("body cams", "Axon \u{00B7} Utility BodyWorn \u{00B7} Motorola vendor match", isOn: Binding(
                get: { bodyCamOn }, set: { bodyCamOn = $0; pendingBodyCam = true; ble.setBodyCamEnabled($0) }))
            // Sub-option of the body-cam detector, laid out like the drone-OUI one above: inset,
            // and disabled while the parent category is off (classification needs both switches).
            // The broad Motorola Solutions OUI is a vendor proxy, not a camera signature, so the
            // same blocks cover their two-way radios and docks. Turning it off is the way to quiet
            // that noise WITHOUT losing the Axon payload match, which is the whole point of the
            // split. Hidden entirely on pre-split firmware, which has no such switch to write to.
            if ble.motorolaSupported {
                // "off keeps Axon running" read as a riddle: off WHAT, and why is Axon involved.
                // Say what the switch matches and what it costs you, and let the parent row's
                // "Axon · Utility BodyWorn · Motorola vendor match" carry the rest.
                radioToggle("motorola solutions", "vendor match only \u{00B7} their radios and docks too", isOn: Binding(
                    get: { motorolaOn }, set: { motorolaOn = $0; pendingMotorola = true; ble.setMotorolaEnabled($0) }))
                    .padding(.leading, 22)
                    .disabled(!bodyCamOn)
                    .opacity(bodyCamOn ? 1 : 0.4)
            }
            Divider().overlay(ACABTheme.line)
            radioToggle("bluetooth trackers", "AirTag \u{00B7} Tile \u{00B7} SmartTag \u{00B7} opt-in", isOn: Binding(
                get: { trackerOn }, set: { trackerOn = $0; pendingTracker = true; ble.setTrackerEnabled($0) }))
            Divider().overlay(ACABTheme.line)
            radioToggle("recording glasses", "Ray-Ban / Oakley Meta \u{00B7} Snap \u{00B7} Vuzix \u{00B7} Luxottica \u{00B7} experimental", isOn: Binding(
                get: { glassesOn }, set: { glassesOn = $0; pendingGlasses = true; ble.setGlassesEnabled($0) }), exp: true)
            Divider().overlay(ACABTheme.line)
            // Opt-in, off by default: enabling it turns on the board's 802.11 DATA-frame
            // source-MAC path (added CPU + 2.4GHz load), which is why it is gated. Honest copy:
            // it matches known IP-camera BRANDS on the host WiFi and cannot find every camera.
            radioToggle("network cameras", "known IP-camera brands on wifi, opt-in, cannot find every camera", isOn: Binding(
                get: { netcamOn }, set: { netcamOn = $0; pendingNetcam = true; ble.setNetcamEnabled($0) }))
        }
        .panel()
    }

    // MARK: offline buffer
    // Board-side flash buffer: record while the phone is away, replay on reconnect.
    private var offlineBufferCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("OFFLINE BUFFER")
            radioToggle("store detections offline", "board buffers while away \u{00B7} replays on reconnect", isOn: Binding(
                get: { bufferOn }, set: { bufferOn = $0; pendingBuffer = true; ble.setBufferingEnabled($0) }))
            if bufferOn {
                Divider().overlay(ACABTheme.line)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("buffered log").font(ACABTheme.display(14, weight: .medium))
                            .foregroundStyle(ACABTheme.text)
                        // While the board is still sweeping a deferred erase, say so rather than
                        // inviting another erase against an about-to-be-zero count.
                        Text(ble.bufferWiping ? "clearing buffer\u{2026}" : "erase what the board stored while away")
                            .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                    Spacer(minLength: 8)
                    if ble.bufferWiping {
                        Text("CLEARING").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.dim)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                    } else {
                        Button { confirmEraseBuffer = true } label: {
                            Text("ERASE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                                .foregroundStyle(ACABTheme.accent)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                                .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .panel()
    }

    // Board LED: on by default (a slow idle heartbeat + detection flashes, so it visibly runs);
    // "lights out" takes it fully dark for covert or stationary deploys. Persists on the board.
    private var lightsOutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("BOARD LED")
            radioToggle("lights out", "no LEDs \u{00B7} for covert or stationary deploys", isOn: Binding(
                get: { lightsOut }, set: { lightsOut = $0; pendingLed = true; ble.setLedEnabled(!$0) }))
            Text("On by default the board LED gives a slow heartbeat so you can see it's alive, and flashes on a hit. Lights out keeps it completely dark.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    // MARK: drive mode (Live Activity)
    private var driveModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("DRIVE MODE")
            radioToggle("live activity counter",
                        "lock screen + dynamic island \u{00B7} live count while you drive",
                        isOn: Binding(get: { ble.driveModeWanted },
                                      set: { on in if on { ble.startDriveMode() } else { ble.endDriveMode() } }))
            Divider().overlay(ACABTheme.line)
            radioToggle("hide counts on lock screen",
                        "show only \u{201C}Drive mode active\u{201D} when locked \u{00B7} counts stay in the Dynamic Island + app",
                        isOn: Binding(get: { ble.redactLockScreen },
                                      set: { ble.redactLockScreen = $0 }))
            if !ble.liveActivitiesEnabled {
                Text("Turn on live activities for beacons in Settings to use this.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    // MARK: desert mode (report every device)
    private var desertModeCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("DESERT MODE")
            radioToggle("report every device",
                        "show + log ANY device nearby \u{00B7} best out in the open",
                        isOn: Binding(get: { desertOn },
                                      set: { desertOn = $0; pendingDesert = true; ble.setDesertMode($0) }))
            Text("Off the grid, anything new on the air means something arrived. Each device is tagged hardware vs. randomized (phone) MAC.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if desertOn {
                Text("Alerts are muted while Desert mode runs. With every nearby device reporting in, a beep for each would never let up. Switch sound back on anytime.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panel()
    }

    private func radioToggle(_ name: String, _ sub: String,
                             isOn: Binding<Bool>, exp: Bool = false) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    if exp { ExpTag() }
                }
                Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
        }
        .tint(ACABTheme.accent)
        .accessibilityLabel(spokenControlText(name))
        .accessibilityHint((exp ? "Experimental. " : "") + spokenControlText(sub))
    }

    /// VoiceOver should speak the domain abbreviations as concepts, not guess at strings such as
    /// ALPR, OUI, RID, and MAC. Visible copy stays compact; only the spoken surface expands it.
    private func spokenControlText(_ text: String) -> String {
        var spoken = text
        let expansions = [
            (#"(?i)\bALPR\b"#, "automatic license plate reader"),
            (#"(?i)\bOUI\b"#, "vendor address prefix"),
            (#"(?i)\bremote ID\b"#, "remote identification"),
            (#"(?i)\bRID\b"#, "remote identification"),
            (#"(?i)\bMAC\b"#, "hardware address"),
            (#"(?i)\bBLE\b"#, "Bluetooth Low Energy"),
        ]
        for (pattern, replacement) in expansions {
            spoken = spoken.replacingOccurrences(of: pattern, with: replacement,
                                                  options: .regularExpression)
        }
        return spoken
    }

    // MARK: alerts
    private var buzzerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("ALERTS")

            alertModePicker

            Text(alertModeCaption)
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 14) {
                slider("Master volume", value: $master, tone: ACABTheme.accent, bold: true,
                       onEditing: { editing in if editing { pendingVolume = true } }) {
                    ble.setVolume(Int(master), preview: true)
                }
            }
            .opacity(muted ? 0.4 : 1)
            .disabled(muted)
        }
        .panel()
    }

    // MARK: phone notifications
    //
    // A SEPARATE card from ALERTS on purpose. ALERTS picks how the BOARD behaves (buzzer / vibrate
    // / silent); this picks which categories are worth interrupting you for on the PHONE. Folding
    // them together implied a dependency that does not exist: a silent board with notifications on
    // is a perfectly normal setup, and arguably the main one for a device you keep in a bag.
    private var notifyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Kicker("PHONE NOTIFICATIONS")

            if ble.notifier.mutedBySystem {
                // A green toggle over a dead feature is the worst outcome here: the user believes
                // they are covered. Say it plainly instead.
                Text("iOS is blocking these. Turn notifications on for beacons in Settings, or nothing here will arrive.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Pick what's worth a notification. Every category is off until you turn it on, and iOS asks permission the first time you do.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                ForEach(DetectionNotifier.notifiableTypes, id: \.self) { t in
                    let on = notifyOn[t.rawValue] ?? DetectionNotifier.isEnabled(t)
                    VStack(alignment: .leading, spacing: 4) {
                        radioToggle(t.label, notifySubtitle(t), isOn: Binding(
                            get: { on },
                            set: { v in
                                notifyOn[t.rawValue] = v
                                ble.notifier.setEnabled(v, for: t)
                            }), exp: t.isExperimental)
                        // A notification for a detector the BOARD is not running can never fire.
                        // Left unsaid, that is the worst kind of dead switch: it reads as coverage.
                        // Only shown once the toggle is on, so the card is not a wall of warnings.
                        if on, detectorIsOff(t) {
                            Text("the \(t.label.lowercased()) detector is off, so this won't fire. turn it on under Detectors.")
                                .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.warn)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            Text("The same device won't notify again for ten minutes, so one camera can't keep buzzing you. Ignored devices never notify at all.")
                .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panel()
    }

    /// True when the board is NOT running the detector behind this notification category, so the
    /// toggle cannot ever fire. Returns false when no status has arrived (do not cry wolf) and for
    /// `.watched`, which has no detector switch: the watchlist is always live.
    private func detectorIsOff(_ t: DeviceType) -> Bool {
        guard let s = ble.status else { return false }
        switch t {
        case .flockCamera, .flockRaven: return !s.flock
        case .drone:                    return !s.drone
        case .axonBodyCam:              return !s.axon
        case .tracker:                  return !s.tracker
        case .recordingGlasses:         return !s.glasses
        case .networkCamera:            return !s.ncam
        case .watched, .nearbyDevice, .unknown: return false
        }
    }

    private func notifySubtitle(_ t: DeviceType) -> String {
        switch t {
        case .flockCamera:              return "plate readers"
        case .axonBodyCam:              return "worn cameras"
        case .recordingGlasses:         return "camera glasses"
        case .networkCamera:            return "cameras on nearby wifi"
        case .drone:                    return "remote ID broadcasts"
        case .tracker:                  return "separated AirTag \u{00B7} Tile \u{00B7} SmartTag"
        case .watched:                  return "devices you starred"
        default:                        return ""
        }
    }

    // Themed 3-way switch: one joined capsule of equal segments split by hairlines,
    // the active one filled with the accent. Rolled our own because a stock
    // .segmented Picker won't match the theme. Same anatomy as Android.
    private var alertModePicker: some View {
        HStack(spacing: 0) {
            segment("Buzzer",  .buzzer)
            segmentDivider
            segment("Vibrate", .vibrate)
            segmentDivider
            segment("Silent",  .silent)
        }
        // minHeight 44, up from a fixed 36: each third of the capsule is its own tap target, and
        // 36pt was under the minimum. minHeight (not height) because the segment labels scale
        // with Dynamic Type; a pinned capsule clipped them at accessibility sizes. Same anatomy
        // otherwise.
        .frame(minHeight: 44)
        .background(ACABTheme.bg2)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private var segmentDivider: some View {
        Rectangle().fill(ACABTheme.line).frame(width: 1)
    }

    private func segment(_ label: String, _ mode: AlertMode) -> some View {
        let active = ble.alertMode == mode
        return Button { ble.setAlertMode(mode) } label: {
            Text(label)
                .font(ACABTheme.mono(11.5, weight: .bold)).tracking(0.5)
                .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? ACABTheme.accent : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// "3 ON" / "OFF", so the collapsed row says whether anything will interrupt you.
    private var notifyKicker: String {
        let n = DetectionNotifier.notifiableTypes.filter {
            notifyOn[$0.rawValue] ?? DetectionNotifier.isEnabled($0)
        }.count
        return n == 0 ? "OFF" : "\(n) ON"
    }

    private var alertModeCaption: String {
        switch ble.alertMode {
        case .buzzer:  return "board beeps when it spots gear"
        case .vibrate: return "board silent, this phone buzzes on new hits while the app is open. Use Drive mode for locked-screen alerts."
        case .silent:  return "board silent, no phone feedback"
        }
    }

    private func slider(_ label: String, value: Binding<Double>, tone: Color,
                        bold: Bool = false, onEditing: ((Bool) -> Void)? = nil,
                        onCommit: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(ACABTheme.display(14, weight: bold ? .medium : .regular)).foregroundStyle(ACABTheme.text)
                Spacer()
                Text(muted ? "-" : "\(Int(value.wrappedValue))")
                    .font(ACABTheme.mono(12, weight: .semibold)).foregroundStyle(tone)
            }
            Slider(value: value, in: 0...100, step: 1) { editing in
                onEditing?(editing)
                if !editing { onCommit() }
            }
                .tint(tone)
        }
    }

    // MARK: stats
    /// Glanceable stats that stay open: uptime + total detections (2-up). Alert/scanning
    /// state now lives in the fold-row kickers, so those tiles are gone.
    /// DETECTIONS is the PHONE-SIDE LOG count (`detections.count`), matching Android's StatsGrid.
    ///
    /// It used to read the board's since-boot session total (status "total"), and the comment even
    /// claimed that was "the same source as Android" - it was not: Android has always shown the
    /// phone log. The board total is a different number that Clear cannot lower (it only resets on a
    /// power cycle) and that Desert mode inflates into the tens of thousands, so it read as a
    /// runaway counter the user could not reconcile with a log they had just cleared. The phone log
    /// responds to Clear, matches what the Log tab holds, and now agrees across both platforms.
    private var statsGrid: some View {
        // One column at accessibility sizes: half-width tiles truncate their values once the
        // type doubles. Two-up otherwise, unchanged.
        let cols = dynamicTypeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12)]
            : [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            statTile("UPTIME", ble.status.map(uptimeText) ?? "-")
            statTile("DETECTIONS", "\(ble.detections.count)")
        }
    }

    private func statTile(_ kick: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(kick)
            Text(value).font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel(padding: 14)
    }

    private func uptimeText(_ s: DeviceStatus) -> String {
        let h = s.uptime / 3600, m = (s.uptime % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private var disconnectButton: some View {
        // Block Disconnect while an update is running: a mid-reboot teardown races the OTA reconnect
        // (and can drop into a pending-connect cancel that fires no callback), so keep the link put
        // until the flow reaches a terminal state. Sample data isn't an update, so it stays tappable.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button(role: .destructive) { ble.demoMode ? ble.exitDemo() : ble.disconnect() } label: {
            Text(ble.demoMode ? "Exit sample data" : "Disconnect")
                .font(ACABTheme.display(15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(ACABTheme.accent)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius).strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .disabled(otaRunning)
        .opacity(otaRunning ? 0.5 : 1)
    }

    // Only offer the app power-off on rev-B: on a rev-A slide board the firmware would re-wake
    // instantly (the slide holds the wake line low), so the drain no-ops there. Demo mode has no
    // real board to shut down. Absent boardRev (older firmware without the poweroff handler) also
    // hides it, so the button never appears where it would do nothing.
    private var showPowerOff: Bool { !ble.demoMode && ble.status?.boardRev == "B" }

    private var powerOffButton: some View {
        // Same block as Disconnect, and blocked during an update for the same reason (a power-off
        // mid-OTA would strand the flow). Tapping only opens the confirm; the actual shutdown is
        // irreversible from the app, so it must be deliberate.
        let otaRunning = !ble.demoMode && (ble.otaState.isRunning || ble.combinedState.isRunning)
        return Button(role: .destructive) { confirmPowerOff = true } label: {
            Text("Power off beacon")
                .font(ACABTheme.display(15, weight: .semibold))
                .frame(maxWidth: .infinity).padding(.vertical, 13)
                .foregroundStyle(ACABTheme.accent)
                .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius).strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
        }
        .disabled(otaRunning)
        .opacity(otaRunning ? 0.5 : 1)
        // Anchored to the BUTTON, not stacked on the NavigationStack next to the buffer-erase dialog:
        // two .confirmationDialog modifiers on the same view fight over the presentation anchor, which
        // is why the sheet pointed at the wrong (top) row. On its own trigger view it anchors here.
        .confirmationDialog(
            "Power off the beacon?",
            isPresented: $confirmPowerOff, titleVisibility: .visible
        ) {
            Button("Power off", role: .destructive) { ble.powerOffBeacon() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The beacon shuts down and stops detecting. You'll turn it back on with the button on the device (hold about 2 seconds). It can't be powered back on from the app.")
        }
    }

    // MARK: watched (starred) devices

    private var renameAlertBinding: Binding<Bool> {
        Binding(get: { renameMac != nil }, set: { if !$0 { renameMac = nil } })
    }

    private var watchedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Kicker("WATCHING", color: ACABTheme.watchTone)
                Spacer()
                // The board echoes how many MACs it's watching at the source.
                if let n = ble.status?.watchCount, n > 0 {
                    Kicker("\(n) ON BOARD", color: ACABTheme.dim)
                }
            }
            ForEach(ble.watched) { dev in
                HStack(spacing: 10) {
                    Image(systemName: "star.fill").font(.system(size: 12)).foregroundStyle(ACABTheme.watchTone)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased()).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer(minLength: 8)
                    Button {
                        renameText = dev.label
                        renameIsIgnored = false
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(width: 44, height: 44)   // 44pt hit target; glyph size unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unwatch(dev.mac) } label: {
                        Text("UNSTAR").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.watchTone)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.watchTone.opacity(0.4), lineWidth: 1))
                            .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.watched.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    // MARK: ignored devices
    private var ignoredCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Kicker("IGNORED")
                Spacer()
                // The board echoes how many MACs it's suppressing at the source.
                if let n = ble.status?.ignoreCount, n > 0 {
                    Kicker("\(n) ON BOARD", color: ACABTheme.dim)
                }
            }
            ForEach(ble.ignored) { dev in
                HStack(spacing: 10) {
                    Image(systemName: "bell.slash").font(.system(size: 12)).foregroundStyle(ACABTheme.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.label.isEmpty ? "Unknown device" : dev.label)
                            .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                            .lineLimit(1)
                        // MACs are stored lowercased; render uppercase, same as Android.
                        Text(dev.mac.uppercased()).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    }
                    Spacer(minLength: 8)
                    // Naming a muted device matters as much as naming a starred one: six weeks on,
                    // "my own AirTag" is the difference between trusting the mute and undoing it.
                    Button {
                        renameText = dev.label
                        renameIsIgnored = true
                        renameMac = dev.mac
                    } label: {
                        Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(ACABTheme.dim)
                            .frame(width: 44, height: 44)   // 44pt hit target; glyph size unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rename")
                    Button { ble.unignore(dev.mac) } label: {
                        Text("UNMUTE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                            .foregroundStyle(ACABTheme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                            .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if dev.id != ble.ignored.last?.id { Divider().overlay(ACABTheme.line) }
            }
        }
        .panel()
    }

    // MARK: about
    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Kicker("ABOUT")
            Text("built for the beacon. also works on the Colonel Panic hardware.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            Divider().overlay(ACABTheme.line)
            linkRow("soyboi.tech", "the beacon board",
                    URL(string: "https://soyboi.tech")!)
            Divider().overlay(ACABTheme.line)
            linkRow("How it detects", "what it can and can't see",
                    URL(string: "https://soyboi.tech/how-it-detects.html")!)
            Divider().overlay(ACABTheme.line)
            linkRow("Source on GitHub", "github.com/soyboi1312/all-cameras-are-beacons",
                    URL(string: "https://github.com/soyboi1312/all-cameras-are-beacons")!)
            if !fwLabel.hasPrefix("beacon board") {
                Divider().overlay(ACABTheme.line)
                linkRow("Colonel Panic", "colonelpanic.tech \u{00B7} OUI-Spy hardware",
                        URL(string: "https://colonelpanic.tech")!)
            }
            Divider().overlay(ACABTheme.line)
            // "no data leaves your device" stopped being true the day explicit export and the
            // contribution flow shipped. The canonical claim is automatic-upload-shaped only.
            linkRow("Privacy", "nothing is uploaded automatically",
                    URL(string: "https://soyboi.tech/privacy.html")!)
            Link(destination: URL(string: "https://github.com/soyboi1312")!) {
                Text("made by soyboi")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
        }
        .panel()
    }

    private func linkRow(_ title: String, _ sub: String, _ url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                    Text(sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(ACABTheme.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
