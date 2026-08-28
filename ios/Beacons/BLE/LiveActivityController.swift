import Foundation
import ActivityKit

enum LiveActivityInactiveReason: Equatable { case ended, dismissed }
enum LiveActivityAdoptionResult: Equatable { case none, adopted, dismissed }

/// A swipe dismissal is a direct surface-level Off. An ended activity may be lifecycle/budget
/// retirement or an explicit intent that already persisted its own choice, so it must not erase a
/// still-wanted preference by inference.
func shouldPreserveLiveModeIntent(after reason: LiveActivityInactiveReason) -> Bool {
    reason == .ended
}

/// Owns the Drive-mode Live Activity: started in the foreground, fed throttled count
/// updates as detections arrive over BLE, and ended on demand. Kept off BLEManager so
/// the manager stays focused on the link. Call on the main thread (BLEManager's
/// CoreBluetooth delegates already land there).
final class LiveActivityController {
    private var activity: Activity<DetectionActivityAttributes>?
    private var lastPushed = Date.distantPast
    private var pending: DispatchWorkItem?
    private var latest = DetectionActivityAttributes.DetectionState.empty
    /// ActivityKit ends asynchronously. Keep an activity that this controller is retiring out of
    /// the adoption pool until its dismissal has actually settled, or a quick reconnect can adopt
    /// the old handle and let its delayed terminal event tear down the replacement session.
    private var retiringIDs: Set<String> = []

    private let stale: TimeInterval = 8 * 60   // -> "stale" if no update in 8 min (drive dropout)
    private let minGap: TimeInterval = 1.5     // coalesce routine updates to ~1 / 1.5 s

    /// Fired when the system ends or dismisses the activity out from under us (e.g. the
    /// user swiped it away), so the owner can sync its Drive-mode toggle back to off.
    var onInactive: ((LiveActivityInactiveReason) -> Void)?

    /// Live Activities can be disabled per-app in Settings.
    var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }
    var isRunning: Bool { activity != nil }

    /// True only while the system is actually showing the activity. A handle can linger
    /// non-nil after the user dismisses it, so check the real state for reconciliation.
    var isActive: Bool {
        guard let a = activity else { return false }
        switch a.activityState {
        case .active, .stale: return true
        default:              return false   // .ended, .dismissed
        }
    }

    /// Drop a handle the system already ended/dismissed, so a fresh start() can begin anew.
    func dropIfInactive() {
        guard let a = activity else { return }
        switch a.activityState {
        case .ended:
            pending?.cancel(); pending = nil; activity = nil
            onInactive?(.ended)
        case .dismissed:
            pending?.cancel(); pending = nil; activity = nil
            onInactive?(.dismissed)
        default: break
        }
    }

    /// Start a session. iOS requires the app to be foregrounded to begin one. Returns
    /// whether the activity actually started (request can fail silently).
    @discardableResult
    func start(deviceName: String, state: DetectionActivityAttributes.DetectionState) -> Bool {
        // A handle the system already ended/dismissed must not satisfy the guard below: it
        // would return true ("already running") without requesting anything, so Drive mode
        // showed on with no Live Activity anywhere. Drop the corpse first.
        dropIfInactive()
        guard isAvailable, activity == nil else { return activity != nil }
        latest = state
        let attrs = DetectionActivityAttributes(deviceName: deviceName, sessionStart: .now)
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(stale))
        activity = try? Activity.request(attributes: attrs, content: content, pushType: nil)
        if let a = activity { observe(a) }
        return activity != nil
    }

    /// Re-attach to an activity still running from a previous launch, so a relaunch
    /// mid-drive resumes it instead of orphaning it. Returns whether one was adopted.
    ///
    /// Only a LIVE (.active/.stale) activity is adoptable. A user-dismissed activity lingers
    /// in Activity.activities in the .dismissed state until the app ends it, so taking .first
    /// blindly could adopt a dead handle - isActive stayed false while start()'s
    /// activity == nil guard then reported "already running", leaving Drive mode on with no
    /// visible surface. The corpses get ended here so they can't be re-adopted on every call
    /// (or shadow a live second entry).
    func adoptExisting() -> LiveActivityAdoptionResult {
        guard activity == nil else { return isActive ? .adopted : .none }
        var adopted: Activity<DetectionActivityAttributes>?
        var sawDismissed = false
        for a in Activity<DetectionActivityAttributes>.activities {
            if retiringIDs.contains(a.id) { continue }
            switch a.activityState {
            case .active, .stale:
                if adopted == nil { adopted = a }
            case .dismissed:
                sawDismissed = true
                Task { await a.end(nil, dismissalPolicy: .immediate) }
            default:
                Task { await a.end(nil, dismissalPolicy: .immediate) }   // dead orphan: finish it off
            }
        }
        guard let a = adopted else { return sawDismissed ? .dismissed : .none }
        activity = a
        latest = a.content.state
        observe(a)
        return isActive ? .adopted : .none
    }

    /// Watch for the system ending/dismissing this activity and notify the owner once.
    private func observe(_ a: Activity<DetectionActivityAttributes>) {
        let id = a.id
        Task { @MainActor [weak self] in
            for await s in a.activityStateUpdates where s == .ended || s == .dismissed {
                self?.handleInactive(id: id, reason: s == .dismissed ? .dismissed : .ended)
                // A dismissed activity stays in Activity.activities until the app ends it, and
                // a lingering corpse is what adoptExisting used to re-adopt. Finish it here.
                if s == .dismissed { await a.end(nil, dismissalPolicy: .immediate) }
                return
            }
        }
    }

    /// The system ended/dismissed the activity: drop our handle and tell the owner so it
    /// can sync its Drive-mode toggle off. Runs on the main thread.
    private func handleInactive(id: String, reason: LiveActivityInactiveReason) {
        // Only the CURRENT activity's terminal event may clear state and fire the callback.
        // end() never cancels the observe Task, so after a quick Drive off -> on the OLD
        // activity's .ended still arrives here; an unconditional onInactive then flipped the
        // toggle off and killed the freshly started session (the owner's handler syncs
        // driveModeOn = false and stops location, unconditionally). A stale id is a no-op.
        guard activity?.id == id else { return }
        pending?.cancel(); pending = nil; activity = nil
        onInactive?(reason)
    }

    /// Push new counts. Coalesced to ~1 update / `minGap`, EXCEPT `escalate` (a brand-new
    /// device) goes out immediately so a fresh threat shows without delay.
    func update(_ state: DetectionActivityAttributes.DetectionState, escalate: Bool = false) {
        guard isRunning else { return }
        latest = state
        let gap = Date().timeIntervalSince(lastPushed)
        if escalate || gap >= minGap {
            pending?.cancel(); pending = nil
            push()
        } else if pending == nil {
            let work = DispatchWorkItem { [weak self] in self?.push() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (minGap - gap), execute: work)
        }
    }

    /// Flip the connected flag (drives the "Reconnecting…" line) without ending.
    func setConnected(_ connected: Bool) {
        guard isRunning else { return }
        latest.connected = connected
        push()
    }

    /// Shared gather step for both enders: cancel any pending push, collect every activity of
    /// our type (plus the owned handle, in case it has already fallen out of
    /// Activity.activities), and drop the handle. Returns the set to end - possibly empty.
    /// retiringIDs bookkeeping deliberately stays at the end() call site: the willTerminate
    /// path (endBlocking) dies with the process, so it has no adoption window to guard.
    private func takeActivitiesToEnd() -> [Activity<DetectionActivityAttributes>] {
        pending?.cancel(); pending = nil
        var all = Activity<DetectionActivityAttributes>.activities
        if let owned = activity, !all.contains(where: { $0.id == owned.id }) { all.append(owned) }
        activity = nil
        return all
    }

    func end() {
        let all = takeActivitiesToEnd()
        guard !all.isEmpty else { return }
        let ids = Set(all.map(\.id))
        retiringIDs.formUnion(ids)
        Task { @MainActor [weak self] in
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
            self?.retiringIDs.subtract(ids)
        }
    }

    /// End and block (up to `timeout`) until ActivityKit has taken the dismissal, for use
    /// from app termination where the process is about to die and a fire-and-forget Task
    /// might not run. The end runs on a DETACHED task (off the blocked thread), so the
    /// semaphore wait can't deadlock; the timeout is a safety cap inside willTerminate's
    /// budget. Best-effort: a suspended (e.g. location-denied) app may never reach here.
    func endBlocking(timeout: TimeInterval = 2) {
        let all = takeActivitiesToEnd()
        guard !all.isEmpty else { return }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            for a in all { await a.end(nil, dismissalPolicy: .immediate) }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
    }

    private func push() {
        guard let activity else { return }
        lastPushed = Date(); pending = nil
        let content = ActivityContent(state: latest, staleDate: Date().addingTimeInterval(stale))
        Task { await activity.update(content) }
    }
}
