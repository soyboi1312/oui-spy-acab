import SwiftUI
import UIKit

enum FinishSetupLocationChoice: Equatable {
    case continueOrNotNow
    case openSettingsOrDone
    case done
}

func finishSetupLocationChoice(isAuthorized: Bool, isDenied: Bool) -> FinishSetupLocationChoice {
    if isAuthorized { return .done }
    return isDenied ? .openSettingsOrDone : .continueOrNotNow
}

/// Durable handoff between the real first-run tour and Finish setup. A missing key means there is
/// nothing pending, which keeps upgrades from showing first-use setup to people who completed the
/// older tour before this handoff existed. Root arms this before marking the tour seen, so a process
/// death between those writes still resumes at Finish setup instead of skipping it.
enum FinishSetupOnboarding {
    private static let pendingKey = "acab.firstRunFinishSetup.pending"

    static var isPending: Bool { isPending(in: .standard) }
    static func isPending(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pendingKey)
    }
    static func arm(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }
    static func complete(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }
}

/// A short handoff after the first real tour. It names the four independent readiness states new
/// users otherwise have to discover inside Beacon, and owns the only automatic-default Location
/// rationale. The system prompt starts only after this sheet has dismissed.
struct FinishSetupView: View {
    @EnvironmentObject private var ble: BLEManager
    let onContinueLocation: () -> Void
    let onNotNow: () -> Void
    /// Invalidation token for the notification row. `notifier.mutedBySystem` is a plain cached var
    /// with no publisher, so a user who leaves for iOS Settings and comes back would otherwise read
    /// the answer this sheet was built with. Same mechanism SettingsView uses for its notify card.
    @State private var systemPermissionRevision = 0

    private var locationChoice: FinishSetupLocationChoice {
        finishSetupLocationChoice(isAuthorized: ble.locationAuthorized,
                                  isDenied: ble.locationDenied)
    }

    private var liveModeDetail: String {
        if ble.driveModeOn { return "active on supported system surfaces" }
        if !ble.driveModeWanted { return "off by choice; change it later under Beacon" }
        if !ble.liveActivitiesEnabled { return "on by default, but Live Activities are blocked by iOS" }
        if liveModeShouldWaitForLocation(hasReadySession: ble.sessionReady,
                                         isDemoMode: ble.demoMode,
                                         locationAuthorized: ble.locationAuthorized) {
            return "on by default; waits for Location before showing a system surface"
        }
        return "ready to start with this beacon"
    }

    private var locationDetail: String {
        if ble.locationAuthorized { return "allowed; Map and background Live Mode are ready" }
        if ble.locationRestricted { return "restricted by device policy; detection still works" }
        if ble.locationDenied { return "off in iOS settings; detection still works" }
        return "optional; not decided yet"
    }

    private var notificationDetail: String {
        let count = ble.enabledPhoneNotificationTypes.count
        if count == 0 { return "off until you choose categories under Beacon" }
        // enabledPhoneNotificationTypes is built from UserDefaults alone and carries no
        // authorization state, so the bare count reads as ready over a feature iOS will not
        // deliver. Every other row on this sheet folds the system's answer in (Live Mode reads
        // liveActivitiesEnabled, Location reads locationDenied / locationRestricted), Settings'
        // notify card already warns on exactly this state, and Android's twin row says BLOCKED.
        if !ble.demoMode, ble.notifier.mutedBySystem {
            return "\(count) chosen, but iOS is blocking them; turn notifications on for beacons in Settings"
        }
        return "\(count) categor\(count == 1 ? "y" : "ies") enabled on this phone"
    }

    private var bufferDetail: String {
        if ble.bufferingOn { return "on; the beacon retains hits while this phone is away" }
        return "off; turn it on under Beacon if you want away-time hits retained"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // SwiftUI never invalidates for a @State the body does not read.
                    let _ = systemPermissionRevision
                    Kicker("FINISH SETUP")
                    Text("your beacon is connected")
                        .font(ACABTheme.display(23, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                    Text("detection is already active. these optional phone and beacon features can be changed later under Beacon.")
                        .font(ACABTheme.mono(11.5)).foregroundStyle(ACABTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(spacing: 0) {
                        readinessRow("dot.radiowaves.left.and.right", "Live Mode", liveModeDetail)
                        divider
                        readinessRow("location.fill", "Location", locationDetail)
                        divider
                        readinessRow("app.badge", "phone notifications", notificationDetail)
                        divider
                        readinessRow("externaldrive.fill", "offline buffer", bufferDetail)
                    }
                    .background(ACABTheme.bg2,
                                in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
                        .strokeBorder(ACABTheme.line, lineWidth: 1))

                    locationRationale
                    actions
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(20)
            }
            .background(ACABTheme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onNotNow) {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("close finish setup")
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationContentInteraction(.scrolls)
        // The manager already re-reads the system answer on willEnterForeground; issue it here too
        // (cheap and idempotent) so an activation without one - dismissing Control Center - counts,
        // and bump the token in the completion, after the notifier's cache is written.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            ble.notifier.refreshAuthorization {
                systemPermissionRevision &+= 1
            }
        }
    }

    private func readinessRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(ACABTheme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                Text(detail)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle().fill(ACABTheme.line).frame(height: 1).padding(.leading, 48)
    }

    @ViewBuilder private var locationRationale: some View {
        switch locationChoice {
        case .continueOrNotNow:
            Text("Location is optional. it keeps Live Mode current in the background, shows where your phone heard detections on Map, and lets the beacon label buffered hits with the last location your phone shared over encrypted Bluetooth. choose not now and detection still works. nothing uploads automatically.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        case .openSettingsOrDone:
            Text("Location is off. detection still works, while background Live Mode and most pins showing where your phone heard a detection stay unavailable.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        case .done:
            Text("Location is ready. Live Mode can stay current in the background, and Map can show where your phone heard detections.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var actions: some View {
        switch locationChoice {
        case .continueOrNotNow:
            VStack(spacing: 8) {
                primaryButton("CONTINUE", action: onContinueLocation)
                Button("NOT NOW", action: onNotNow)
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.8)
                    .foregroundStyle(ACABTheme.dim)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        case .openSettingsOrDone:
            VStack(spacing: 8) {
                primaryButton("OPEN SETTINGS", action: openSettings)
                Button("OPEN STATUS", action: onNotNow)
                    .font(ACABTheme.mono(11, weight: .bold)).tracking(0.8)
                    .foregroundStyle(ACABTheme.dim)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
        case .done:
            primaryButton("OPEN STATUS", action: onNotNow)
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(ACABTheme.mono(12, weight: .bold)).tracking(0.8)
                .foregroundStyle(ACABTheme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(ACABTheme.accent,
                            in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openSettings() {
        openAppSettings()
        onNotNow()
    }
}
