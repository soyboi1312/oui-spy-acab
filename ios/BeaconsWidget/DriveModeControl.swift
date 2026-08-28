import WidgetKit
import SwiftUI
import AppIntents
import ActivityKit

/// Control Center toggle (iOS 18+) for Drive mode. The displayed state mirrors whether a
/// Drive-mode Live Activity is running; turning it off ends the activity from anywhere,
/// turning it on opens the app and starts one (iOS only lets a Live Activity begin while the
/// app is foregrounded). The app reconciles its own toggle on the next foreground.
struct DriveModeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "tech.beacons.app.drivemode") {
            ControlWidgetToggle(
                "Live Mode",
                isOn: !Activity<DetectionActivityAttributes>.activities.isEmpty,
                action: ToggleDriveModeIntent()
            ) { isOn in
                Label(isOn ? "Detecting" : "Live Mode",
                      systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .displayName("beacons Live Mode")
        .description("Start or stop the surveillance-detection counter.")
    }
}
