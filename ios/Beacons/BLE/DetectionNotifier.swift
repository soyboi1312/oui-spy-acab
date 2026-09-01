import Foundation
import UserNotifications

/// Per-category phone notifications for detections.
///
/// WHY THIS IS SEPARATE FROM AlertMode: `AlertMode` governs the BOARD's buzzer (and, in `.vibrate`,
/// an in-app haptic that only fires while the app is foregrounded). It is not a notification
/// system, and before this file the app had none at all. Silencing the board is not the same
/// decision as silencing your phone, so the two are deliberately independent axes.
///
/// DESIGN RULES, each of which exists because the alternative is a firehose or a lie:
///  - Per CATEGORY, opt-in, every one default OFF.
///  - THE COOLDOWN IS THE EDGE, not the caller's `firstTime`. This is the correction that matters:
///    the first version gated on BLEManager's `firstTime`, which is `store[d.id] == nil`. The store
///    is PERSISTED across launches, so a device seen in any previous session was never "first"
///    again and could never notify, and the ten-minute cooldown decided nothing. Worse, a detection
///    suppressed by the global gap was destroyed rather than deferred, because there was only ever
///    one offer per device. Owning the dedup here makes both correct and matches the shipped copy.
///  - Never for ignored devices (dropped before the hook), never for Desert-mode `.nearbyDevice`.
///  - Authorization is requested LAZILY on the first enable, not at launch.
///
/// FOREGROUND PRESENTATION: this must be the notification-center delegate. Without one, iOS
/// silently discards the alert whenever the app is on screen: no banner, no sound, no entry, and
/// `add()` reports success. Since the app has no in-app banner either, the feature produced
/// literally nothing while you were looking at it.
///
/// THREADING: plain NSObject, no actor isolation, because BLEManager is a non-isolated
/// NSObject/ObservableObject and a @MainActor property initializer cannot be constructed from it.
/// Entry points run on the main thread (CoreBluetooth is created with a nil queue, so its callbacks
/// are main) and the async completion handlers hop back to main explicitly.
final class DetectionNotifier: NSObject, UNUserNotificationCenterDelegate {

    /// Per-device cooldown. This is the real rate limit, and the only one: a board re-reports a
    /// device it can still hear about once a second, so without this a single camera would notify
    /// continuously.
    private static let perDeviceCooldown: TimeInterval = 600      // 10 minutes, matches the UI copy

    /// Floor between notifications for DIFFERENT devices, so arriving somewhere dense cannot produce
    /// a burst you cannot read. Deliberately small: it suppresses one alert, and because the
    /// cooldown (not `firstTime`) is now the edge, the device gets another chance on its next
    /// sighting a second later rather than being silently dropped forever.
    private static let globalMinGap: TimeInterval = 4

    private var lastNotifiedByMac: [String: Date] = [:]
    private var lastNotifiedAt: Date = .distantPast
    private(set) var authorized = false
    private var authRequested = false

    /// Cached because the detection path consults it per record. It used to be recomputed from 8
    /// UserDefaults reads on every one, which is hot enough to matter at Desert-mode rates.
    private static var enabledCache: Set<Int>?

    override init() {
        super.init()
        // Must be set before any notification is posted, and this object is built during
        // BLEManager's own construction, which happens at app launch.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Foreground presentation

    /// Show the banner even when the app is foregrounded. Without this the alert is dropped
    /// entirely. The sound is withheld when the user has chosen a silent board and a Focus is
    /// active, matching what the in-app haptic already does rather than chirping over it.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(silenceForeground ? [.banner, .list] : [.banner, .list, .sound])
    }

    /// Set by BLEManager so the delegate can honor the same Focus/alert-mode rule the haptic uses.
    var silenceForeground = false

    /// Tapping the notification opens the Log filtered to new detections, the same destination
    /// Android's contentIntent uses and the same one the offline-sync banner's "view" action
    /// already drives. Without this the notification was inert on tap, which on iOS just
    /// foregrounds the app on whatever screen it was last on.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Deferred one runloop turn ON PURPOSE. RootView.onAppear clears both pending keys once
        // per process, deliberately, so a stale tap cannot replay days later. `.onOpenURL` is
        // documented to land after that clear; a notification response has no such guarantee on a
        // COLD launch, and setting the keys first would let onAppear wipe them. Hopping to the
        // next turn puts us after any synchronous onAppear either way.
        DispatchQueue.main.async {
            UserDefaults.standard.set(true, forKey: "acab.pendingNewFilter")
            UserDefaults.standard.set(2, forKey: "acab.pendingTab")
            NotificationCenter.default.post(name: Notification.Name("acabOpenLogNew"), object: nil)
        }
        completionHandler()
    }

    // MARK: - Preferences

    private static func key(for type: DeviceType) -> String { "acab.notify.\(type.rawValue)" }

    static func isEnabled(_ type: DeviceType) -> Bool {
        if enabledCache == nil { rebuildCache() }
        return enabledCache?.contains(type.rawValue) ?? false
    }

    private static func rebuildCache() {
        var s = Set<Int>()
        for t in notifiableTypes where UserDefaults.standard.bool(forKey: key(for: t)) {
            s.insert(t.rawValue)
            // ALPR is one user-facing category. flockRaven has no row of its own (see
            // notifiableTypes), so it follows flockCamera's switch.
            if t == .flockCamera { s.insert(DeviceType.flockRaven.rawValue) }
        }
        enabledCache = s
    }

    /// The categories a user can switch on. ONE ALPR row: everywhere else in both apps flockCamera
    /// and flockRaven are a single "ALPR" category, and Raven is an acoustic sensor rather than a
    /// plate reader, so listing it separately under "plate readers" was both a duplicate-looking
    /// row and factually wrong. `.nearbyDevice` is excluded (Desert is ambient, not an event).
    static let notifiableTypes: [DeviceType] = [
        .flockCamera, .axonBodyCam, .recordingGlasses,
        .networkCamera, .drone, .tracker, .watched,
    ]

    static var anyEnabled: Bool {
        if enabledCache == nil { rebuildCache() }
        return !(enabledCache?.isEmpty ?? true)
    }

    func setEnabled(_ on: Bool, for type: DeviceType) {
        UserDefaults.standard.set(on, forKey: Self.key(for: type))
        Self.rebuildCache()
        if on { requestAuthorizationIfNeeded() }
    }

    // MARK: - Authorization

    func requestAuthorizationIfNeeded() {
        guard !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) {
            [weak self] granted, _ in
            DispatchQueue.main.async { self?.authorized = granted }
        }
    }

    /// Re-read the real system state. Called on launch AND on every foreground: a user who grants
    /// permission in iOS Settings mid-session would otherwise stay silently unauthorized for the
    /// whole process lifetime, since `authorized` is only ever set by our own request.
    ///
    /// `completion` runs on the main queue AFTER the cached state is written, so a caller that
    /// re-renders off `mutedBySystem` can bump its own invalidation token there and be guaranteed
    /// to repaint against the fresh answer, not the stale cache.
    func refreshAuthorization(completion: (() -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] s in
            DispatchQueue.main.async {
                self?.authorized = (s.authorizationStatus == .authorized ||
                                    s.authorizationStatus == .provisional)
                // `authRequested` means "iOS has already answered", NOT "we were granted". Setting
                // it only on success meant a DENIED user came back false on every launch, so
                // mutedBySystem stayed false and the amber "iOS is blocking these" warning could
                // never appear again: green toggles over a permanently dead feature, which is the
                // exact outcome that warning exists to prevent.
                if s.authorizationStatus != .notDetermined { self?.authRequested = true }
                completion?()
            }
        }
    }

    /// True when the user has switched something on but the system will not deliver it, so the UI
    /// can say so instead of showing a green toggle over a dead feature.
    var mutedBySystem: Bool { Self.anyEnabled && !authorized && authRequested }

    // MARK: - Posting

    /// Post for a detection if its category is on and the rate limits allow.
    ///
    /// NOT gated on the caller's first-sighting edge, deliberately. See the type comment.
    ///
    /// REDACTION: the notification TEXT is never redacted here. `redactLockScreen` is a
    /// lock-screen-scoped setting, and redacting the body unconditionally hid the category on an
    /// UNLOCKED phone too, which is the state the feature exists for. iOS already has the right
    /// mechanism: the user's own "Show Previews" setting governs whether the body appears on a
    /// locked screen, per-app and system-wide. Honoring that instead of second-guessing it is both
    /// correct and less surprising.
    func notifyIfNeeded(_ d: Detection) {
        guard authorized,
              !d.isHistory,                       // an offline replay is not a live event
              d.type != .nearbyDevice,            // Desert rows are ambient, never an alert
              Self.isEnabled(d.type)
        else { return }

        let now = Date()
        if let last = lastNotifiedByMac[d.mac], now.timeIntervalSince(last) < Self.perDeviceCooldown {
            return
        }
        // Different-device burst floor. Suppressing here is safe now: the device is not marked, so
        // its next sighting is offered again rather than lost.
        guard now.timeIntervalSince(lastNotifiedAt) >= Self.globalMinGap else { return }

        lastNotifiedByMac[d.mac] = now
        lastNotifiedAt = now
        pruneCooldowns(now)

        let content = UNMutableNotificationContent()
        content.title = d.type.label
        let who = d.hasName ? d.displayName : d.type.label
        // Avoid "Tracker / Tracker detected" when the device has no name of its own.
        content.body = who == d.type.label
            ? "Detected nearby, \(d.confidence)% confidence."
            : "\(who) detected, \(d.confidence)% confidence."
        content.sound = .default

        // NOTE: .timeSensitive is deliberately NOT set. It requires the
        // com.apple.developer.usernotifications.time-sensitive entitlement, which this target does
        // not declare, so iOS silently downgrades it and the line reads like a working feature
        // while doing nothing. If Focus breakthrough is wanted, add the entitlement to
        // project.yml AND the provisioning profile first, then set it here. Until then this
        // matches Android, which no longer uses CATEGORY_ALARM for the same reason.

        // Per-MAC identifier so a repeat replaces rather than stacks.
        let req = UNNotificationRequest(identifier: "acab.det.\(d.mac)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { err in
            if let err { print("[ACAB] notification post failed: \(err.localizedDescription)") }
        }
    }

    /// Drop expired entries so a long drive past thousands of devices cannot grow this without
    /// bound. Cheap: it only runs when something was actually posted.
    private func pruneCooldowns(_ now: Date) {
        guard lastNotifiedByMac.count > 256 else { return }
        lastNotifiedByMac = lastNotifiedByMac.filter {
            now.timeIntervalSince($0.value) < Self.perDeviceCooldown
        }
    }

    /// Drop cooldown state so a genuinely new session can alert on the same devices again.
    func reset() {
        lastNotifiedByMac.removeAll()
        lastNotifiedAt = .distantPast
    }
}
