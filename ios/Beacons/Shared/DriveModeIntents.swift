import AppIntents
import ActivityKit
import Foundation

/// The user's Drive-mode INTENT, persisted. This is NOT the same fact as "a Live Activity is
/// running", and conflating the two is what made the setting reset on every app close:
/// `BLEManager.driveModeOn` is derived state with no backing store, and BLEManager's own
/// willTerminate handler calls `liveActivity.endBlocking()` on the way out. So the app destroys
/// the only carrier of the setting itself, and the next launch finds nothing to adopt.
///
/// The split: the ACTIVITY is the surface and is still torn down at terminate (a counter left
/// frozen on the Lock Screen after a force-quit was its own bug, and that fix stays). The INTENT
/// lives here and survives, so the app can re-create the surface when it next comes forward.
///
/// App Group rather than UserDefaults.standard so the app and the widget extension read one
/// value; same id as both entitlements and BLEManager.widgetSuite.
enum DriveModeState {
    private static let suite = "group.tech.beacons.app"
    private static let key = "acab.driveModeWanted"

    private static var sharedDefaults: UserDefaults? { UserDefaults(suiteName: suite) }

    /// Nil means the user has never made a choice. Keep that distinct from false so the default
    /// can be enabled without reviving a setting the user explicitly turned off.
    static func storedChoice(in defaults: UserDefaults?) -> Bool? {
        defaults?.object(forKey: key) as? Bool
    }

    static func setWanted(_ value: Bool, in defaults: UserDefaults?) {
        defaults?.set(value, forKey: key)
    }

    static func wanted(in defaults: UserDefaults?) -> Bool {
        storedChoice(in: defaults) ?? true
    }

    static var wanted: Bool {
        get { wanted(in: sharedDefaults) }
        set { setWanted(newValue, in: sharedDefaults) }
    }
}

extension Notification.Name {
    /// Warm-app handoff for Control Center/Live Activity intents. Shared defaults remain the source
    /// of truth for cold or cross-process execution; this notification closes the ordering gap
    /// when an intent runs after an already-active scene's foreground reconciliation.
    static let driveModeIntentChanged = Notification.Name("tech.beacons.app.liveModeIntentChanged")
}

let driveModeDarwinNotification = CFNotificationName(
    "tech.beacons.app.liveModeIntentChanged.darwin" as CFString)

/// Posts BOTH channels on purpose: the in-process notification reaches a warm app immediately,
/// and the Darwin mirror is the only channel that crosses from the widget extension process.
/// Darwin notifications also loop back to the posting process, so an in-app execution delivers
/// twice - BLEManager coalesces bursts at the observer (scheduleDriveModeReconcile) and
/// reconcile is idempotent, so any duplicate that outruns the coalescer is harmless. Do not
/// "fix" the duplication here by dropping a leg: each leg is load-bearing.
func postDriveModeIntentChanged() {
    NotificationCenter.default.post(name: .driveModeIntentChanged, object: nil)
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         driveModeDarwinNotification, nil, nil, true)
}

// Interactive intents for the Drive-mode Live Activity (the in-activity End button) and the
// Control Center toggle. Deliberately dependency-free - they use only ActivityKit and the
// shared DetectionActivityAttributes, NEVER BLEManager - so this one file compiles into BOTH
// the app and the widget extension. The app re-syncs its own `driveModeOn` flag from
// ActivityKit when it next comes to the foreground (BLEManager.reconcileDriveMode()).

/// Ends the Drive-mode Live Activity. Backs the "End" button shown inside the activity.
struct EndDriveModeIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "End Live Mode"

    func perform() async throws -> some IntentResult {
        DriveModeState.wanted = false   // an explicit End must not come back at the next launch
        for activity in Activity<DetectionActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        postDriveModeIntentChanged()
        return .result()
    }
}

/// Control Center toggle for Drive mode. Off ends the activity (works from anywhere); on
/// opens the app and starts one, since iOS only lets a Live Activity begin while the app is
/// foregrounded (openAppWhenRun brings it forward, and perform() then runs in-app).
struct ToggleDriveModeIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Live Mode"
    static var openAppWhenRun = true

    @Parameter(title: "On") var value: Bool

    func perform() async throws -> some IntentResult {
        let running = Activity<DetectionActivityAttributes>.activities
        DriveModeState.wanted = value   // Control Center is a real user choice; remember it too
        // On only records intent and opens the app. BLEManager owns creation after the encrypted
        // Detections subscription and Location grant are both ready; creating an empty activity in
        // the extension bypassed both gates and could leave "Reconnecting" stuck indefinitely.
        if !value {
            for activity in running { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        postDriveModeIntentChanged()
        return .result()
    }
}
