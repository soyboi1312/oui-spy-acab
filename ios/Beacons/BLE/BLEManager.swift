import Foundation
import CoreBluetooth
import CoreLocation
import Combine
import UIKit
import Intents
import ActivityKit
import WidgetKit
import Security

/// A board we spotted while scanning.
///
/// Keyed on `peripheral.identifier`, which is CoreBluetooth's PER-HOST UUID and not the board's
/// BLE address. That does NOT make the row immune to the firmware's rotating Resolvable Private
/// Address; see the staleness prune in didDiscover for the evidence and the window.
struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var firmware: String?
}

enum MuteScope: Equatable { case permanent, oneHour, oneDay, here }

/// A device the user has chosen to silence. Optional fields preserve old permanent rows.
struct IgnoredDevice: Codable, Identifiable, Equatable {
    let mac: String
    var label: String        // renameable, same as WatchedDevice
    var expiresAt: Date? = nil
    var latitude: Double? = nil
    var longitude: Double? = nil
    var radiusMeters: Double? = nil
    var id: String { mac }

    var isPlaceScoped: Bool { latitude != nil && longitude != nil }

    var scopeLabel: String {
        if isPlaceScoped { return "within \(Int(radiusMeters ?? 50)) m" }
        // Half-anchored (one coordinate, not both) is what evaluateMuteRule reads as .invalidPlace:
        // the rule silences nothing. Falling through to "permanent" told the user the exact
        // opposite - silenced forever - and on this threat model a false "you are covered" is the
        // wrong way to fail. Say plainly that the rule cannot be used, because the managed-list row
        // prints this label with no MuteRuleStatus beside it.
        // Android twin: IgnoredDevice.scopeLabel in AcabBleManager.kt, same string.
        if latitude != nil || longitude != nil { return "place rule unusable" }
        if let expiresAt {
            let left = max(0, expiresAt.timeIntervalSinceNow)
            return left >= 3600 ? "\(Int(ceil(left / 3600)))h remaining" : "\(Int(ceil(left / 60)))m remaining"
        }
        return "permanent"
    }
}

/// The board has neither a clock nor a geofence evaluator; only unscoped rules belong in NVS.
func isBoardBackedMute(_ item: IgnoredDevice) -> Bool {
    item.expiresAt == nil && item.latitude == nil && item.longitude == nil
}

/// The one MAC shape a managed-list entry may take: six lowercase hex octets, colon separated.
/// That is exactly what the firmware emits (acabFormatMac in detection.h) and what its parseMac6
/// accepts on the way back in. `mac` is decoded off the wire as free text, so anything else is a
/// rule the phone would show as applied while the BOARD silently dropped it: the device keeps
/// buzzing, and the two sides can never agree on a count again - which then pins the ignore/watch
/// re-push loop that maxListPushAttempts bounds. Callers must lowercase first.
/// Android twin: isBoardPushableMac / BOARD_MAC_SHAPE in AcabBleManager.kt, same rule, same three
/// call sites (ignoreDevice, ignoreDevices, watchDevice).
func isBoardPushableMac(_ mac: String) -> Bool {
    // Spelled out rather than matched with Character.isHexDigit: that property also accepts the
    // fullwidth compatibility forms of 0-9 and a-f, which no MAC ever contains. Uppercase is
    // refused because every managed-list path in both apps lowercases before storing and compares
    // lowercased sets, not because the firmware's sscanf-based parseMac6 would choke on it.
    let hex = "0123456789abcdef"
    let octets = mac.split(separator: ":", omittingEmptySubsequences: false)
    guard octets.count == 6 else { return false }
    return octets.allSatisfy { o in o.count == 2 && o.allSatisfy { hex.contains($0) } }
}

/// Whether a configured mute is suppressing the device right now. A place rule remains
/// configured when the phone is outside its radius or has no current fix, but neither state is
/// an active mute. Keeping those states distinct prevents the dossier from claiming "MUTED"
/// while the active feed is correctly showing the device. Mirrors Android's MuteRuleStatus.
enum MuteRuleStatus {
    case active
    case expired
    case currentLocationRequired
    case outsideRadius
    case invalidPlace
}

/// Pure mute policy - the ONE reading of a rule against a moment and a fix. Both the
/// activeIgnoredMacSet rebuild and the dossier headline go through here, so the two can never
/// disagree about what a rule means; they can still differ on WHEN it was asked (the cached
/// set refreshes on its own schedule - see muteRuleStatus(for:)).
func evaluateMuteRule(_ item: IgnoredDevice, now: Date, here: CLLocation?) -> MuteRuleStatus {
    if let end = item.expiresAt, end <= now { return .expired }
    if item.latitude == nil, item.longitude == nil { return .active }
    // A half-anchored place rule fails closed: it must neither mute nor claim it could.
    guard let lat = item.latitude, let lon = item.longitude else { return .invalidPlace }
    guard let here else { return .currentLocationRequired }
    return here.distance(from: CLLocation(latitude: lat, longitude: lon)) <= (item.radiusMeters ?? 50)
        ? .active : .outsideRadius
}

let activeNearbyInterval: TimeInterval = 45
let currentLocationFixMaxAge: TimeInterval = 120
let hereMuteRadiusMeters: Double = 50

/// Shared pure boundary for Status and Live Mode policy tests.
func lastSeenIsNearby(_ lastSeen: Date?, now: Date,
                      window: TimeInterval = activeNearbyInterval) -> Bool {
    guard let lastSeen else { return false }
    let age = now.timeIntervalSince(lastSeen)
    return age >= 0 && age <= window
}

/// UI staleness is one-sided: a timestamp a few milliseconds ahead of a view's captured `now`
/// is fresh, not stale. Live Mode uses the stricter `lastSeenIsNearby` boundary above to reject
/// genuinely future/corrupt data; Status must not flicker stale between adjacent main-runloop reads.
func lastSeenIsStale(_ lastSeen: Date?, now: Date,
                     window: TimeInterval = activeNearbyInterval) -> Bool {
    guard let lastSeen else { return true }
    return now.timeIntervalSince(lastSeen) > window
}

/// A place mute must be anchored and evaluated against a genuinely current fix, never the cached
/// coordinate retained for map centering. Reject future timestamps too: clock-skewed/corrupt fixes
/// must not remain "fresh" indefinitely because their age is negative.
func locationFixIsCurrent(_ timestamp: Date?, now: Date,
                          maxAge: TimeInterval = currentLocationFixMaxAge) -> Bool {
    guard let timestamp else { return false }
    let age = now.timeIntervalSince(timestamp)
    return age >= 0 && age <= maxAge
}

/// A 50-meter place mute needs a fix whose uncertainty is no larger than the geofence itself.
/// Core Location uses a negative horizontalAccuracy for an invalid fix, and a cached fix may be
/// current in time while still being far too imprecise to claim that the phone is inside 50 m.
func locationFixSupportsHere(_ timestamp: Date?, horizontalAccuracy: Double, now: Date,
                             maxAge: TimeInterval = currentLocationFixMaxAge,
                             maxAccuracy: Double = hereMuteRadiusMeters) -> Bool {
    locationFixIsCurrent(timestamp, now: now, maxAge: maxAge)
        && horizontalAccuracy.isFinite
        && horizontalAccuracy >= 0
        && horizontalAccuracy <= maxAccuracy
}

/// Reconcile any authoritative managed list, not just an empty-list clear. A failed nonempty
/// write otherwise remains wrong for the rest of a still-connected session. An empty phone is
/// intentionally non-authoritative unless it carries an explicit pending clear, preserving rules
/// created by another phone.
enum BoardListSyncAction: Equatable { case none, pushList, pushClear, acknowledgeClear }

func boardListSyncAction(localCount: Int, boardCount: Int?,
                         clearPending: Bool) -> BoardListSyncAction {
    if localCount > 0 {
        return boardCount == localCount ? .none : .pushList
    }
    guard clearPending else { return .none }
    return boardCount == 0 ? .acknowledgeClear : .pushClear
}

/// Number of board rules that cannot be represented by this phone's local list. The protocol
/// exposes only a count, not the MACs, so a secondary phone can disclose these rules but cannot
/// identify or edit them individually.
func unrepresentedBoardRuleCount(boardCount: Int, localBoardBackedCount: Int) -> Int {
    max(0, boardCount - localBoardBackedCount)
}

/// A Live Activity is a real system surface, so sample data must never start one. Outside the
/// sample tour it also requires both the encrypted Detections subscription and Location
/// authorization. Location keeps the process resident across ordinary background periods;
/// starting without it is what leaves a disconnected activity stuck on "Reconnecting" after iOS
/// suspends the grace timer.
func liveModeCanRun(hasReadySession: Bool, isDemoMode: Bool,
                    locationAuthorized: Bool) -> Bool {
    !isDemoMode && hasReadySession && locationAuthorized
}

/// Live Mode may wait on Location, but it never owns the permission prompt itself. The first real
/// connection offers Location after the tour, and later users can choose Enable Location under
/// Beacon. Keeping the permission action outside reconciliation prevents a default preference,
/// cold launch, or reconnect from raising a system sheet without current explanatory copy.
func liveModeShouldWaitForLocation(hasReadySession: Bool, isDemoMode: Bool,
                                   locationAuthorized: Bool) -> Bool {
    hasReadySession && !isDemoMode && !locationAuthorized
}

func automaticLiveModeCanRun(hasReadySession: Bool, isDemoMode: Bool,
                              locationAuthorized: Bool,
                              firstRunOnboardingActive: Bool) -> Bool {
    !firstRunOnboardingActive
        && liveModeCanRun(hasReadySession: hasReadySession, isDemoMode: isDemoMode,
                          locationAuthorized: locationAuthorized)
}

enum BeaconConnectionFailure: Equatable {
    case timeout
    case transport
    case securePairing
    case missingService
}

/// One diagnosis per failure path. The second-phone pairing window stays separate because an
/// ordinary timeout or radio error is not evidence that another phone owns the beacon.
func beaconConnectionRecovery(_ failure: BeaconConnectionFailure) -> String {
    switch failure {
    case .timeout:
        return "the connection timed out. keep the beacon powered on and nearby, then scan again."
    case .transport:
        return "the beacon could not connect. keep it powered on and nearby, then scan again."
    case .securePairing:
        return "secure pairing did not finish. scan again, tap your beacon, then accept the iOS pairing request if it appears."
    case .missingService:
        return "this does not appear to be a compatible beacon. check its firmware, then scan again."
    }
}

func demoEntryNeedsScanCancellation(isScanning: Bool, scanDeferred: Bool) -> Bool {
    isScanning || scanDeferred
}

enum SecureReadinessWatchdogEvent: Equatable {
    case transportConnected
    case sessionReady
    case teardown
}

enum SecureReadinessWatchdogAction: Equatable { case arm, cancel }

let secureReadinessTimeoutInterval: TimeInterval = 45

func secureReadinessWatchdogAction(for event: SecureReadinessWatchdogEvent)
    -> SecureReadinessWatchdogAction {
    event == .transportConnected ? .arm : .cancel
}

func secureReadinessTimeoutApplies(expectedID: UUID, currentID: UUID?,
                                   sessionReady: Bool, isDemoMode: Bool) -> Bool {
    !sessionReady && !isDemoMode && currentID == expectedID
}

func liveRowIsNearby(_ lastSeen: Date?, now: Date, isDemoMode: Bool) -> Bool {
    isDemoMode || lastSeenIsNearby(lastSeen, now: now)
}

/// A wire row typed `.watched` is historical evidence of how the board classified it at capture
/// time, not a permanent bypass. Only the current watchlist outranks a current mute.
func activeProjectionIncludes(mac: String, isCurrentlyWatched: Bool,
                              activeIgnoredMacs: Set<String>) -> Bool {
    activeProjectionIncludes(loweredMac: mac.lowercased(),
                             isCurrentlyWatched: isCurrentlyWatched,
                             activeIgnoredMacs: activeIgnoredMacs)
}

/// Pre-lowered variant for the per-row publish hot path: publishDetections, recomputeLiveCounts
/// and the widget summary run this up to the 5,000-row cap on main, so they pass Detection's
/// stored `loweredMac` (computed once at decode) and feed the same String to both membership
/// checks instead of allocating one throwaway String per row per pass.
func activeProjectionIncludes(loweredMac: String, isCurrentlyWatched: Bool,
                              activeIgnoredMacs: Set<String>) -> Bool {
    isCurrentlyWatched || !activeIgnoredMacs.contains(loweredMac)
}

/// Sample-mode managed-list edits are a preview only. Centralizing the boundary keeps bulk and
/// single-row paths from accidentally persisting or scheduling a board write through a helper.
func managedListWritesAllowed(isDemoMode: Bool) -> Bool { !isDemoMode }

/// The two protected managed-list files share one failure/retry policy. Kept outside BLEManager so
/// the pending-state transition can be exercised without constructing a manager that reads the
/// simulator's real Application Support directory.
enum ManagedListKind: Hashable { case ignored, watched }

struct ManagedListPersistenceState {
    private(set) var pending: Set<ManagedListKind> = []

    mutating func record(_ kind: ManagedListKind, succeeded: Bool) {
        if succeeded { pending.remove(kind) }
        else { pending.insert(kind) }
    }

    var hasPendingWrites: Bool { !pending.isEmpty }
    func needsRetry(_ kind: ManagedListKind) -> Bool { pending.contains(kind) }
}

/// Encode and perform the protected write as one success/failure operation. The injected writer is
/// the test seam and, in production, includes both the atomic file write and the backup-exclusion
/// attribute: either step failing means the privacy-preserving save is not complete.
func performProtectedManagedListWrite<T: Encodable>(
    _ value: T, to url: URL?,
    writer: (Data, URL) throws -> Void
) -> Bool {
    guard let url, let data = try? JSONEncoder().encode(value) else { return false }
    do {
        try writer(data, url)
        return true
    } catch {
        return false
    }
}

struct LegacyManagedListMigration<Value> {
    let value: Value
    let protectedWriteSucceeded: Bool
}

/// Decode a legacy UserDefaults value and attempt its protected replacement. The caller receives
/// the list even when the write fails so it remains usable for this session, but the legacy removal
/// callback runs ONLY after durable protected persistence succeeds.
func migrateLegacyManagedList<T: Decodable>(
    _ type: T.Type, data: Data?,
    persistProtected: (T) -> Bool,
    removeLegacy: () -> Void
) -> LegacyManagedListMigration<T>? {
    guard let data, let value = try? JSONDecoder().decode(type, from: data) else { return nil }
    let saved = persistProtected(value)
    if saved { removeLegacy() }
    return LegacyManagedListMigration(value: value, protectedWriteSucceeded: saved)
}

/// A protected managed-list file can exist even though its first migration did not finish: the
/// atomic data write may land and the following backup-exclusion attribute may fail. On the next
/// launch that valid file wins as the source of truth, but the legacy UserDefaults copy must not be
/// forgotten. Re-write the loaded value through the complete protection + exclusion operation and
/// scrub the legacy copy only after that whole operation succeeds.
@discardableResult
func reconcileLegacyManagedListAfterProtectedLoad<T>(
    _ value: T, legacyPresent: Bool,
    persistProtected: (T) -> Bool,
    removeLegacy: () -> Void
) -> Bool {
    guard legacyPresent else { return true }
    let saved = persistProtected(value)
    if saved { removeLegacy() }
    return saved
}

/// One synchronous deletion attempt with outcome-based semantics. A file that is already absent is
/// success; a remove call is success only once absence is confirmed. The second check also handles
/// an API that reports an error after actually unlinking the file without keeping a privacy promise
/// pending forever.
func performConfirmedPersistedDetectionDeletion(
    fileExists: () -> Bool,
    remove: () throws -> Void
) -> Bool {
    guard fileExists() else { return true }
    do { try remove() } catch { return !fileExists() }
    return !fileExists()
}

func persistedDetectionLoadAllowed(clearPending: Bool) -> Bool { !clearPending }

enum PersistedDetectionClearCommit: Equatable {
    case durableTombstone
    case confirmedDeletion
    case unavailable
}

/// A real clear may transition the visible store only after one of two durable boundaries: either
/// its write-ahead tombstone is confirmed flushed, or the condemned file is already confirmed
/// absent. If both operations fail, keeping the rows visible makes the failed action honest and
/// avoids reporting a clear that could resurrect after process death.
func preparePersistedDetectionClear(
    armTombstone: () -> Bool,
    deleteSynchronously: () -> Bool
) -> PersistedDetectionClearCommit {
    if armTombstone() { return .durableTombstone }
    return deleteSynchronously() ? .confirmedDeletion : .unavailable
}

/// Process-death-safe intent for Clear Log. UserDefaults is used rather than process memory so a
/// kill between the user's tap and the serialized file deletion turns into a retry on next launch.
/// synchronize() is intentional at this one destructive write-ahead boundary: the delete must not
/// begin while its recovery intent is only queued in cfprefsd.
struct PersistedDetectionClearTombstone {
    static let key = "acab.detections.clearPending"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var isPending: Bool { defaults.bool(forKey: Self.key) }

    @discardableResult
    func arm() -> Bool {
        defaults.set(true, forKey: Self.key)
        let synchronized = defaults.synchronize()
        return synchronized && defaults.bool(forKey: Self.key)
    }

    /// Retire only after confirmed file absence. If the preferences flush fails, restore the
    /// in-process flag and keep retrying; otherwise a new checkpoint could land under a tombstone
    /// that reappears after process death and be erased on the next launch.
    @discardableResult
    func retire() -> Bool {
        defaults.removeObject(forKey: Self.key)
        guard defaults.synchronize(), !defaults.bool(forKey: Self.key) else {
            defaults.set(true, forKey: Self.key)
            _ = defaults.synchronize()
            return false
        }
        return true
    }
}

/// Every asynchronous persisted-log load gets a unique token. A real Clear invalidates the token
/// before deleting the file, so an already-decoded batch queued on main cannot resurrect evidence.
/// Starting another load also supersedes older work (notably the launch load versus exitDemo()).
struct PersistedDetectionLoadGate {
    private var generation: UInt64 = 0

    mutating func beginLoad() -> UInt64 {
        generation &+= 1
        return generation
    }

    mutating func invalidate() { generation &+= 1 }
    func accepts(_ token: UInt64) -> Bool { token == generation }
}

/// Phone-owned settings shown during the sample tour. Keeping the preview in a value type makes
/// it impossible for a sample toggle to reach App Group defaults, UserDefaults, ActivityKit, or a
/// permission request. The real values are copied in only to make the preview feel familiar; the
/// copy is discarded at exit rather than written back.
struct SamplePhoneSettings: Equatable {
    var liveModeWanted: Bool
    var redactLockScreen: Bool
    var notificationTypes: Set<Int>

    func notificationEnabled(_ rawValue: Int) -> Bool {
        notificationTypes.contains(rawValue)
    }

    mutating func setNotification(_ enabled: Bool, rawValue: Int) {
        if enabled { notificationTypes.insert(rawValue) }
        else { notificationTypes.remove(rawValue) }
    }
}

enum DetectionLogClearAction: Equatable { case sampleMemoryOnly, memoryAndDisk }

/// Clear on sample data is deliberately an in-memory preview action. The persisted evidence log
/// is reloaded on exit and may only be deleted by the confirmed real-log path.
func detectionLogClearAction(isDemoMode: Bool) -> DetectionLogClearAction {
    isDemoMode ? .sampleMemoryOnly : .memoryAndDisk
}

/// Seen-watermark changes are useful while exploring the sample log, but they must not mark the
/// user's retained detections seen in UserDefaults.
func seenWatermarkWritesAllowed(isDemoMode: Bool) -> Bool { !isDemoMode }

/// Resolve the board-reported detector set for Live Mode. `nil` means Status has not arrived yet,
/// so preserve the historical five-column fallback; an explicit empty list means every detector
/// is off and must stay empty.
func effectiveLiveModeCategories(_ reported: [String]?) -> Set<String> {
    Set(reported ?? [
        WidgetCategory.alpr.rawValue, WidgetCategory.drone.rawValue,
        WidgetCategory.body.rawValue, WidgetCategory.tracker.rawValue,
        WidgetCategory.glasses.rawValue,
    ])
}

/// User-assigned names for specific MACs, shared so `Detection.displayName` can consult them
/// WITHOUT every view having to thread the BLEManager down to the row that draws the label.
///
/// WHY A REGISTRY: a Detection is a value type built from a BLE notify; it has no idea the user
/// starred or muted that MAC. Resolving here means the custom name reaches the log, the dossier,
/// the map pin, the CSV export and notifications from a single place. Rebuilt whenever the watched
/// or ignored list changes, which is rare (a tap), so a plain dictionary is plenty.
/// Keys are ALWAYS lowercased MACs, matching how both lists store them.
final class DeviceNames {
    static let shared = DeviceNames()
    private var byMac: [String: String] = [:]
    private init() {}
    func label(for mac: String) -> String? {
        let v = byMac[mac.lowercased()]
        return (v?.isEmpty == false) ? v : nil
    }
    /// Watched wins over ignored if a MAC somehow appears on both (it shouldn't, but the lists
    /// are independent files on disk and a hand-edit could do it).
    func rebuild(watched: [WatchedDevice], ignored: [IgnoredDevice]) {
        var m: [String: String] = [:]
        for i in ignored where !i.label.isEmpty { m[i.mac.lowercased()] = i.label }
        for w in watched where !w.label.isEmpty { m[w.mac.lowercased()] = w.label }
        byMac = m
    }
}

/// A device the user has chosen to watch: the board alerts on this exact MAC every
/// time it's seen, even with no built-in signature match. The inverse of IgnoredDevice.
struct WatchedDevice: Codable, Identifiable, Equatable {
    let mac: String
    var label: String
    var id: String { mac }
}

/// One-shot summary published when an offline-buffer drain finishes with records to
/// report. Identifiable so a fresh drain re-triggers the banner's transition even if
/// the count is unchanged; the id also lets the banner animate in/out cleanly.
struct OfflineSyncSummary: Identifiable, Equatable {
    let id = UUID()
    let count: Int
    /// Records the board PROMISED ({"hist":"begin","n"}) but never SENT ({"hist":"end","n"}).
    /// Current firmware leaves a notifyCap-blocked row uncommitted in the ring, so this is the
    /// shortfall for the current attempt and a later larger-MTU/corrected attempt may replay it.
    /// The banner still discloses what this phone did not receive now.
    /// ble-protocol.md, "Why the replay check needs all three numbers".
    var unreplayed: Int = 0
}

/// A bounded retry stops radio churn for this connection, but `.deferIncomplete` deliberately
/// does not authorize advancing the durable cursor past a sequence gap.
enum HistoryEndDisposition: Equatable { case complete, retryNow, deferIncomplete }

func historyEndDisposition(received: Int, expected: Int,
                           resyncAttempts: Int, resyncCap: Int,
                           beginSeen: Bool = true) -> HistoryEndDisposition {
    // An equal count is not a complete drain without its begin envelope. In particular, a lost
    // begin followed by end(n: 0) used to finalize the OLD generation after a board-side wipe.
    // Re-request a fresh envelope within the connection budget, then defer to reconnect.
    if !beginSeen { return resyncAttempts < resyncCap ? .retryNow : .deferIncomplete }
    if received == expected { return .complete }
    return resyncAttempts < resyncCap ? .retryNow : .deferIncomplete
}

func historyEnvelopeAuthorizesCheckpoint(beginSeen: Bool) -> Bool { beginSeen }

let durableBufferKeyByteCount = 32

enum DurableBufferKeyReadResult {
    case found(Data)
    case missing
    /// Covers Keychain access errors, unexpected result types, and corrupt key lengths. These are
    /// deliberately distinct from missing: replacing such an item could strand encrypted evidence.
    case unavailable
}

func durableBufferKeyIsUsable(_ data: Data?) -> Bool {
    guard let data, data.count == durableBufferKeyByteCount else { return false }
    return data.contains { $0 != 0 }
}

/// Resolve a long-lived buffer key without ever exposing a generated-but-uncommitted candidate.
/// `install` returns the value read back from durable storage; in a duplicate-add race that is the
/// persistent winner, which may intentionally differ from this caller's candidate.
func resolveDurableBufferKey(
    read: () -> DurableBufferKeyReadResult,
    generate: () -> Data?,
    install: (Data) -> Data?
) -> Data? {
    switch read() {
    case .found(let existing):
        return durableBufferKeyIsUsable(existing) ? existing : nil
    case .unavailable:
        return nil
    case .missing:
        guard let candidate = generate(), durableBufferKeyIsUsable(candidate),
              let persisted = install(candidate), durableBufferKeyIsUsable(persisted) else {
            return nil
        }
        return persisted
    }
}

enum BufferHandshakeWrite {
    case key, epoch, sync
}

struct BufferHandshakeTransition {
    let next: BufferHandshakeWrite?
    let complete: Bool
    let failed: Bool
}

/// The key write is a security barrier: epoch and sync do not exist until its ACK succeeds.
func bufferHandshakeTransition(completed: BufferHandshakeWrite,
                               success: Bool) -> BufferHandshakeTransition {
    guard success else {
        return BufferHandshakeTransition(next: nil, complete: false, failed: true)
    }
    switch completed {
    case .key:
        return BufferHandshakeTransition(next: .epoch, complete: false, failed: false)
    case .epoch:
        return BufferHandshakeTransition(next: .sync, complete: false, failed: false)
    case .sync:
        return BufferHandshakeTransition(next: nil, complete: true, failed: false)
    }
}

enum PostSyncReadyStep: Equatable {
    case subscribeStatus, subscribeOTA, finishReady
}

/// The readiness channel chain begins only after the sync write's successful response. Keeping
/// this ordering explicit prevents an early Status frame from reconciling settings onto Config
/// while the key transaction is still establishing replay authority.
func postSyncReadyStep(statusAvailable: Bool, statusSettled: Bool,
                       otaAvailable: Bool, otaSettled: Bool) -> PostSyncReadyStep {
    if statusAvailable && !statusSettled { return .subscribeStatus }
    if otaAvailable && !otaSettled { return .subscribeOTA }
    return .finishReady
}

func enqueueBufferControlWrite<T>(_ value: T, into queue: inout [T],
                                  handshakeSuccessor: Bool) {
    // A clear requested while KEY is in flight stays behind EPOCH and SYNC. The same rule makes a
    // second clear wait until the first clear's full rekey completes, so completion ownership can
    // never be overwritten by an interleaved transaction.
    if handshakeSuccessor { queue.insert(value, at: 0) }
    else { queue.append(value) }
}

/// A successful startup SYNC begins an asynchronous Status/OTA readiness chain. Config writes
/// enqueued by a Status reconciliation (or an already-pending clear) must stay parked until that
/// whole chain settles; checking only the in-flight slot makes `enqueueConfigWrite` a back door
/// around the pause.
func configWriteDispatchAllowed(postSyncPaused: Bool, hasInFlight: Bool,
                                hasQueuedWrite: Bool) -> Bool {
    !postSyncPaused && !hasInFlight && hasQueuedWrite
}

func resetBufferControlWriteState<Write, Owner>(queue: inout [Write],
                                                inFlight: inout Write?,
                                                owner: inout Owner?) {
    queue.removeAll()
    inFlight = nil
    owner = nil
}

func callbackBelongsToCurrentSession<Owner: AnyObject, Channel: AnyObject>(
    callbackOwner: Owner, currentOwner: Owner?,
    callbackChannel: Channel, currentChannel: Channel?
) -> Bool {
    callbackOwner === currentOwner && callbackChannel === currentChannel
}

enum SessionDiscoveryCallbackDisposition: Equatable {
    case ignore, fail, accept
}

/// A discovery error must win over a CBPeripheral's retained service cache. Looking at
/// `peripheral.services` after an errored callback can otherwise promote the prior connection's
/// service object into the new trust boundary.
func sessionServiceDiscoveryDisposition<Owner: AnyObject>(
    callbackOwner: Owner, currentOwner: Owner?, awaitingServices: Bool,
    error: Error?
) -> SessionDiscoveryCallbackDisposition {
    guard callbackOwner === currentOwner, awaitingServices else { return .ignore }
    return error == nil ? .accept : .fail
}

/// Characteristic discovery is accepted only for the exact CBService selected by this session's
/// successful service-discovery callback. UUID equality is insufficient because cached retired
/// services and their characteristics can survive on a reused CBPeripheral.
func sessionCharacteristicDiscoveryDisposition<Owner: AnyObject, Service: AnyObject>(
    callbackOwner: Owner, currentOwner: Owner?, awaitingCharacteristics: Bool,
    callbackService: Service, currentService: Service?, error: Error?
) -> SessionDiscoveryCallbackDisposition {
    guard callbackOwner === currentOwner, awaitingCharacteristics,
          callbackService === currentService else { return .ignore }
    return error == nil ? .accept : .fail
}

/// Best available count of rows not delivered in this attempt. A duplicate-only mismatch cannot
/// identify the missing sequence, so report at least one instead of presenting the drain as clean.
func replayUnreplayedCount(promised: Int, sent: Int, received: Int,
                           transportComplete: Bool) -> Int {
    let safePromised = max(0, promised)
    let safeSent = max(0, sent)
    let safeReceived = max(0, received)
    let missing = safePromised > 0
        ? max(0, safePromised - min(safeSent, safeReceived))
        : max(0, safeSent - safeReceived)
    return transportComplete ? missing : max(1, missing)
}

/// How alerts reach you: board buzzer, phone haptics, or nothing.
enum AlertMode: String, CaseIterable {
    case buzzer   // board buzzes, phone stays quiet (the default)
    case vibrate  // board muted, phone buzzes on each first sighting
    case silent   // board muted, no phone feedback either
}

/// Connection lifecycle the UI watches. Doesn't track data-readiness separately.
enum BLEConnectionState: Equatable {
    case unknown          // haven't heard the radio's state yet
    case poweredOff
    case unauthorized
    case idle             // ready, just not scanning
    case scanning
    case connecting
    case connected
}

/// Drives the link to an OUI-Spy board: scan, connect, stream detections, push
/// config. CoreBluetooth runs on `queue: nil`, so every delegate callback lands on
/// the main thread. That's why we can set @Published state straight from them.
final class BLEManager: NSObject, ObservableObject {
    /// Shared instance: the app, its App Intents (the Control Center toggle), and the Live
    /// Activity End button all drive ONE link. ACABApp injects this as the environment object.
    static let shared = BLEManager()

    @Published private(set) var connectionState: BLEConnectionState = .unknown
    /// True only after the encrypted Detections subscription succeeds. `.connected` now moves at
    /// the same boundary, while this explicit publication lets onboarding and tests name the
    /// security/readiness fact instead of inferring it from transport state.
    @Published private(set) var sessionReady = false
    /// RootView owns this first-run gate. It starts closed so cold-launch reconciliation cannot
    /// create a Live Activity while SwiftUI is still deciding whether onboarding is due.
    @Published private(set) var firstRunOnboardingActive = true

    /// Recovery hint shown when a connect attempt ends before the encrypted detection stream is
    /// usable. Timeout, transport, secure-pairing, and profile failures use distinct copy; the
    /// second-phone pairing window is standing setup guidance rather than a guessed diagnosis.
    @Published private(set) var connectHint: String?

    /// The one sentence a user needs. Kept byte-identical to Android's PAIR_WINDOW_HINT:
    /// user-facing copy the two apps must not diverge.
    static let pairWindowHint = "turn the beacon off and on, then connect within two minutes."
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var detections: [Detection] = []
    /// Evidence/log projection. Active mute rules hide rows elsewhere, not from prior history.
    @Published private(set) var logDetections: [Detection] = []
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connectedName: String?
    @Published private(set) var ignored: [IgnoredDevice] = [] {
        didSet {
            DeviceNames.shared.rebuild(watched: watched, ignored: ignored)
            rebuildActiveIgnoredMacSet()
            updateLocationDesiredAccuracy()
        }
    }
    @Published private(set) var watched: [WatchedDevice] = [] {
        didSet {
            watchedMacSet = Set(watched.map { $0.mac.lowercased() })
            DeviceNames.shared.rebuild(watched: watched, ignored: ignored)
        }
    }
    /// A failed managed-list edit remains active in memory, but is not described as durable. The
    /// global alert surfaces the first failure immediately; the managed-devices screen keeps a
    /// persistent retry affordance visible until every dirty list reaches protected storage.
    @Published private(set) var managedListPersistenceError: String?
    @Published private(set) var managedListSavePending = false
    private var managedListPersistenceState = ManagedListPersistenceState()
    private var pendingLegacyManagedLists: Set<ManagedListKind> = []
    private var managedListRetryTimer: Timer?
    /// Raised when a star is refused because the watchlist is already at the firmware's 256-entry
    /// cap. Lets the UI tell the user the list is full instead of the tap silently doing nothing;
    /// the view owns the reset (it's the alert's binding), so this is settable, not private(set).
    @Published var watchlistFull = false
    /// "Mark all seen" baseline. A detection counts as New if we first heard it after
    /// this point. Nil until the user sets a watermark (then everything older is "seen").
    @Published private(set) var seenWatermark: Date?
    @Published private(set) var demoMode = false   // canned sample data, no real board
    /// True only for the user-invoked sample tour. The `-demo` launch argument is a deterministic
    /// visual/test fixture and must land directly on the requested tab instead of covering every
    /// screenshot with onboarding.
    @Published private(set) var demoTourRequested = false
    private var demoNeedsRelocate = false          // demo seeded before a GPS fix -> re-place around the user when one arrives
    private var demoStatusPayload: [String: Any] = [:]
    private var demoAlertModeSnapshot: AlertMode?
    private var demoAlertModeBeforeDesert: AlertMode?
    /// Phone-owned settings are previews during the tour. Unlike board controls, these would
    /// otherwise persist immediately or invoke a system permission sheet, so every Settings
    /// binding routes through this value while demoMode is true.
    @Published private var samplePhoneSettings: SamplePhoneSettings?
    @Published private(set) var enabledPhoneNotificationTypes: Set<Int> = []
    private struct SeenWatermarkSnapshot {
        let watermark: Date?
        let approxSeq: UInt32
    }
    private var demoSeenWatermarkSnapshot: SeenWatermarkSnapshot?
    // Managed-list edits in the sample tour are an in-memory preview. Keep the real lists here so
    // Exit can restore them synchronously; persistence and board-write paths are also demo-gated,
    // so a force-quit midway through the tour leaves disk and board state untouched.
    private var demoIgnoredSnapshot: [IgnoredDevice]?
    private var demoWatchedSnapshot: [WatchedDevice]?
    @Published private(set) var alertMode: AlertMode = .buzzer
    /// Alert mode to restore when Desert mode turns off.
    ///
    /// PERSISTED. This used to be plain in-memory state, and Desert mode force-writes Silent to
    /// BOTH UserDefaults and the board's NVS (buzz=false). So relaunching the app while Desert was
    /// on lost the restore target, and turning Desert off afterwards left the board permanently
    /// mute with no way back except hand-picking the mode again. A user in that state reports "my
    /// starred device never beeps", which reads as a detection bug and is not one.
    private var alertModeBeforeDesert: AlertMode? {
        get { AlertMode(rawValue: UserDefaults.standard.string(forKey: alertModeBeforeDesertKey) ?? "") }
        set {
            if let v = newValue { UserDefaults.standard.set(v.rawValue, forKey: alertModeBeforeDesertKey) }
            else { UserDefaults.standard.removeObject(forKey: alertModeBeforeDesertKey) }
        }
    }
    private let alertModeBeforeDesertKey = "acab.alertModeBeforeDesert"
    @Published private(set) var driveModeOn = false   // Live Activity (Drive mode) actually RUNNING
    /// The user's PERSISTED Drive-mode INTENT (mirror of DriveModeState.wanted, default ON), kept
    /// @Published so the settings toggle observes it. This is what the toggle must reflect, NOT
    /// driveModeOn: the activity only starts once foregrounded + a board is ready, and it drops on
    /// a disconnect, so binding the toggle to driveModeOn read OFF by default and flipped OFF on
    /// every dropout. Every write to DriveModeState.wanted routes through setDriveModeWanted().
    @Published private(set) var driveModeWanted = DriveModeState.wanted
    /// True while a pending auto-reconnect is armed after an UNEXPECTED drop (board unplugged /
    /// power-cycled). Distinct from a fresh scan-connect (which is also .connecting but has no
    /// reconnectTarget): ConnectView uses this to offer a foreground escape from the otherwise
    /// indefinite "Reconnecting…" wait, so a board that never returns can't trap the user on the
    /// connect screen with no way to scan for a different one. Kept in lockstep with reconnectTarget.
    @Published private(set) var isReconnecting = false
    /// Hide detection counts on the Lock Screen banner (user setting, default OFF: counts are
    /// visible on a fresh install, because most users never found the toggle). The nil-checked
    /// load in init means only an explicitly stored choice overrides this default. The counts
    /// always show in the Dynamic Island and in the app either way.
    @Published var redactLockScreen = false {
        didSet {
            UserDefaults.standard.set(redactLockScreen, forKey: redactKey)
            if driveModeOn { liveActivity.update(liveState(), escalate: true) }
        }
    }

    // Creating CBCentralManager is itself the first Bluetooth access and may display the system
    // prompt. Defer it on a never-asked install so ConnectView's rationale is genuinely visible
    // first; already-authorized installs still initialize immediately for background recovery.
    private var central: CBCentralManager?
    private var scanWhenCentralIsReady = false
    private var peripheral: CBPeripheral?
    private var detectionsChar: CBCharacteristic?
    private var configChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var otaChar: CBCharacteristic?
    private var sessionService: CBService?
    private enum SessionDiscoveryPhase: Equatable {
        case inactive, awaitingServices, awaitingCharacteristics, installed
    }
    private var sessionDiscoveryPhase: SessionDiscoveryPhase = .inactive

    private enum ConfigWritePurpose {
        case normal
        case handshake(BufferHandshakeWrite)
        case clearLog
    }
    private struct PendingConfigWrite {
        let data: Data
        let purpose: ConfigWritePurpose
    }
    private enum BufferHandshakeCompletion { case startup, rekeyAfterClear }
    /// CoreBluetooth does not echo a Config payload in its response callback. Serialize and tag
    /// every with-response write so key/epoch/sync ACKs can never be confused with a setting write.
    private var configWriteQueue: [PendingConfigWrite] = []
    private var configWriteInFlight: PendingConfigWrite?
    private var bufferHandshakeCompletion: BufferHandshakeCompletion?
    private var readyStatusSettled = false
    private var readyOTASettled = false
    private var readySubscriptionStep: PostSyncReadyStep?
    /// True only between the startup SYNC ACK and completion of the post-sync Status/OTA chain.
    /// Both enqueue and dispatch honor it so callbacks cannot leak queued Config work through.
    private var postSyncConfigDispatchPaused = false

    /// Peripheral we're holding a PENDING auto-reconnect on after an UNEXPECTED drop - the board
    /// was unplugged / power-cycled. This is the fix for "the app won't come back after the board
    /// reboots." We must retain the CBPeripheral ourselves AND call central.connect(_, options: nil)
    /// with no timeout: CoreBluetooth parks that request indefinitely and fires didConnect the moment
    /// the board re-advertises, in the foreground OR backgrounded (the app declares the
    /// bluetooth-central UIBackgroundMode). Held here rather than in `peripheral` so the rest of the
    /// code keeps its "peripheral != nil means a live link" invariant while we wait. Nil whenever
    /// there's nothing to auto-reconnect: never connected, a user-initiated disconnect(), or the OTA
    /// reboot path (which reconnects via its own otaAwaitingReboot bookkeeping).
    private var reconnectTarget: CBPeripheral? {
        didSet { isReconnecting = (reconnectTarget != nil) }   // single source of truth for the UI escape
    }
    /// Identifies the exact peripheral whose disconnect is intentional and must NOT arm an
    /// auto-reconnect. A global Boolean is unsafe because CoreBluetooth can deliver callbacks from
    /// a retired peripheral after a replacement session has started. Internal so the OTA extension
    /// can honor a user teardown during its reboot window.
    var intentionalDisconnectID: UUID?

    /// True once THIS session actually reached ready: the Detections CCCD subscribe succeeded,
    /// the buffer handshake was ACKed through sync, and the post-sync subscriptions settled.
    /// Gates the unexpected-drop auto-reconnect. A connect that
    /// NEVER reached ready - the user declined the encryption/pairing prompt, or the board holds
    /// stale bond keys for another phone and drops us during setup - must fail to the resting
    /// screen, not arm an indefinite reconnect that re-fires the pairing prompt on every
    /// re-advertise. Mirrors Android's sessionWasReady, which is set only in finishReady, i.e.
    /// after the subscribe chain succeeds; .connected alone is too early (it lands before the
    /// async CCCD write resolves). Cleared on every fresh connect() and in the teardown paths.
    private var sessionWasReady = false

    /// True from the OTA reboot command until the reconnected board confirms the new firmware.
    /// The encrypted stream is down only because we restarted the board ourselves, so UI gates
    /// (RootView's shell, the Live Mode session checks below) treat this window as a held
    /// session instead of dropping the user to the scan panel mid-update.
    var isRebootingForUpdate: Bool { otaAwaitingReboot != nil }

    /// Session gate for Live Mode and the secure-readiness watchdog: an OTA reboot in flight
    /// counts as ready, so the update window cannot end Drive Mode or race the reboot timeout.
    private var sessionHeldForUpdate: Bool { sessionWasReady || isRebootingForUpdate }

    private func setSessionReady(_ ready: Bool) {
        if ready {
            updateSecureReadinessWatchdog(.sessionReady)
        }
        sessionWasReady = ready
        sessionReady = ready
    }

    /// RootView holds automatic Live Mode until the first real tour and its finish-setup rationale
    /// have closed. Releasing the gate may start a default Live Activity only when Location was
    /// already granted; it never requests permission.
    func setFirstRunOnboardingActive(_ active: Bool) {
        guard firstRunOnboardingActive != active else { return }
        firstRunOnboardingActive = active
        guard !active,
              automaticLiveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                                       locationAuthorized: locationAuthorized,
                                       firstRunOnboardingActive: firstRunOnboardingActive),
              DriveModeState.wanted, UIApplication.shared.applicationState == .active else { return }
        resumeDriveModeIfWanted()
    }

    /// Watchdog for a FRESH scan-connect. central.connect has no OS timeout and didFailToConnect
    /// never fires for a board that simply is not there (powered off since discovery, or claimed
    /// by another phone), so without this a tapped stale row pins connectionState at .connecting
    /// forever. One-shot, armed only by connect(_:); the unexpected-drop auto-reconnect stays
    /// deliberately indefinite and never runs it.
    private var connectTimeoutTimer: Timer?
    private let connectTimeoutInterval: TimeInterval = 15

    /// A transport connection is not a usable session. Service discovery, encrypted pairing, and
    /// the Detections CCCD still have to finish, and CoreBluetooth promises no terminal callback if
    /// one of those stages stalls. didConnect arms a fresh identity-scoped window; only readiness or
    /// link teardown retires it.
    private var secureReadinessTimeoutTimer: Timer?

    /// Bound on a FOREGROUND scan window, matching Android's SCAN_TIMEOUT_MS. An allow-duplicates
    /// service scan left running is a multi-percent-per-hour battery cost, and "tapped Scan and
    /// set the phone down" used to keep the radio hot until the user connected, stopped, or
    /// backgrounded the app. One-shot, armed by startScan(), disarmed by stopScan()/connect();
    /// on expiry the discovered list stays so the UI lands on the resting screen with the boards
    /// it found, exactly like Android keeps _found.
    private var scanTimeoutTimer: Timer?
    private let scanTimeoutInterval: TimeInterval = 45

    /// How long a scanned board stays in the picker after its last advertisement, matching
    /// Android's FOUND_STALE_MS. See the prune in didDiscover for why a picker keyed on a UUID
    /// still needs one.
    private let foundStaleInterval: TimeInterval = 6
    /// Last advertisement time per discovered id, feeding that prune.
    ///
    /// Deliberately a SIDE MAP rather than a field on DiscoveredDevice, which is where Android
    /// puts it (FoundBoard.seenAt). `discovered` is @Published, an advertising board arrives
    /// 10-20 times a second, and stamping the row on every advert would republish the picker at
    /// that rate - the exact re-render storm the meaningful-change filter in didDiscover exists to
    /// stop. Android rebuilds its whole _found list per result anyway, so the field costs it
    /// nothing there. The window and the behaviour are identical; only the storage differs.
    private var lastAdvertAt: [UUID: Date] = [:]

    // MARK: OTA firmware update
    // The whole OTA state machine lives in BLEManager+OTA.swift; these are the pieces it
    // needs to hang onto across delegate callbacks (extensions can't add stored properties).

    /// Progress + phase the Device screen watches to draw the update UI. Left internal (the
    /// default, not private) because the OTA state machine that drives it lives in the
    /// BLEManager+OTA.swift extension, which needs write access.
    @Published var otaState: OTAState = .idle
    /// True only when the connected board actually exposes the acab0104 OTA characteristic.
    /// Released 1.7 boards do NOT, so this is a runtime capability gate for the update button.
    @Published private(set) var otaCapable = false

    /// Live OTA session context, non-nil only while an update is running. Reset on finish.
    var otaSession: OTASession?
    /// Board and generation that own the asynchronous S3 update. The download must never hand
    /// verified bytes to whichever board happens to be current later.
    var otaOwnerPeripheralID: UUID?
    var otaGeneration: UInt64 = 0
    /// A cancelled/failed S3 transfer may leave delayed replies in the current GATT session.
    /// Do not arm another run on that same link; a disconnect flushes the protocol boundary.
    var otaQuarantinedPeripheralID: UUID?
    /// The background download+verify Task, held so cancelFirmwareUpdate() can actually stop it.
    /// otaSession only exists after beginTransfer, so a cancel during download/verify needs this.
    var otaDownloadTask: Task<Void, Never>?
    /// Fires if the board goes quiet mid-transfer (no prog notify / write-ready callback).
    var otaStallTimer: Timer?
    /// After we reboot the board we reconnect and confirm; this holds the target while we wait.
    var otaAwaitingReboot: OTARebootWait?
    /// Generation of the current post-reboot link attempt. Unlike otaGeneration (one whole
    /// update), this changes on every disconnect and successful reconnect so timers from an older
    /// link cannot fail or confirm a newer one.
    var otaPostRebootAttempt: UInt64 = 0
    var otaPostRebootConnected = false
    /// True once a Status frame has decoded since the last OTA reboot reconnect. The post-reboot
    /// version check keys on it: the OTA reboot path deliberately skips the normal disconnect
    /// teardown, so `status` (and currentFwVersion) still hold PRE-reboot values at reconnect,
    /// and deciding on those would read a successful update as a rollback. Cleared by
    /// otaHandleReconnected, set by ingestStatus.
    var otaSawFreshStatus = false

    // MARK: nRF co-processor DFU (separate from the S3 OTA above)
    /// Progress of a co-processor (nRF) BLE-DFU. Driven by the BLEManager+NrfDFU extension.
    @Published var nrfDfuState: NrfDfuState = .idle
    /// The live flasher (its own CBCentralManager), non-nil only while a co-proc DFU runs.
    var nrfFlasher: NrfDfuFlasher?
    /// Pre-trigger scan that proves no nearby legacy DFU advertiser was already present.
    var nrfBaselineScanner: NrfDfuBaselineScanner?
    /// The background download+verify Task for the co-proc zip; held so a cancel can stop it.
    var nrfDownloadTask: Task<Void, Never>?
    /// Board and generation that own the asynchronous co-processor update.
    var nrfOwnerPeripheralID: UUID?
    var nrfDfuGeneration: UInt64 = 0
    /// Once this Config session has sent a legacy-DFU trigger, do not arm another. The request and
    /// reply protocol has no session token, so reconnecting is the boundary that retires delays.
    var nrfQuarantinedPeripheralID: UUID?
    var nrfPackageURL: URL?
    /// nRF version we expect after the flash; the confirm step polls status.nrfVersion for it.
    var nrfConfirmTarget: Int?

    // MARK: One-click combined update (orchestrates the S3 OTA + nRF DFU above; see
    // BLEManager+CombinedUpdate.swift). These stored properties live here because extensions
    // can't add them; all the sequencing logic lives in that file.
    /// The combined flow's phase the Device screen watches to draw the single-button UI. The
    /// orchestration in BLEManager+CombinedUpdate.swift writes all of these, so they can't be
    /// `private(set)` (that would scope the setter to this file only).
    @Published var combinedState: CombinedUpdatePhase = .idle
    /// Determinate 0...1 progress across both legs (S3 then nRF), mapped from their two streams.
    @Published var combinedProgress: Double = 0
    /// Plain-language label for the current step ("Updating board firmware", etc.).
    @Published var combinedPhaseLabel: String = ""
    /// Wall-clock seconds since the flow started, ticked by the combined timer.
    @Published var combinedElapsed: TimeInterval = 0
    /// A soft, non-failure note shown on a done/partial finish (e.g. couldn't re-check the nRF).
    @Published var combinedNotice: String?
    /// Did the BOARD leg actually flash during the run that just finished? `combinedCtx` is torn
    /// down at the terminal, so the card cannot ask it after the fact - and the PARTIAL copy has to
    /// say what really happened. A co-processor-only run that fails never touched the board, and
    /// telling the user "Board updated" there is simply false.
    @Published var combinedS3Updated: Bool = false
    /// Live context for the running combined flow; nil when idle. Class so the timer mutates it.
    var combinedCtx: CombinedUpdateContext?
    /// Drives the elapsed clock and polls the two sub-engines while the combined flow runs.
    var combinedTimer: Timer?

    // Detections keyed by Detection.id (type:mac), plus arrival time so the feed
    // can sort most-recent-first.
    private var store: [String: Detection] = [:]
    private var lastSeen: [String: Date] = [:]
    private var rssiHistory: [String: [Int]] = [:]
    private var trackHistory: [String: [CLLocationCoordinate2D]] = [:]   // drone flight paths
    private var firstSeenAt: [String: Date] = [:]
    private var capturedLoc: [String: CLLocationCoordinate2D] = [:]
    /// Latest LIVE sighting captured specifically during the currently armed contribution window.
    /// This ledger, not the coalesced UI projection or the session-wide store, defines bounded
    /// membership. Replay/history rows never enter it, while a device first heard before Start
    /// enters as soon as it produces a new live sighting. Keeping row fields, one clock instant,
    /// and the phone fix together makes `.exact` truthful and prevents session-old observer GPS
    /// from being paired with an in-window timestamp.
    private struct ContributionLiveSample {
        let detection: Detection
        let observedAtMs: Int64
        let coordinate: CLLocationCoordinate2D?
    }
    private var contributionCaptureStartMs: Int64?
    private var contributionLiveSamples: [String: ContributionLiveSample] = [:]
    /// Strongest RSSI seen so far for a no-GPS device, the reference the closest-approach pin
    /// migrates against. RSSI is a distance proxy (stronger = closer), so first sighting is the
    /// WORST place estimate (edge of range); capturedLoc chases the best sample instead. Paired
    /// with capturedLoc everywhere it is cleared, so the two can never desync.
    private var bestRssi: [String: Int] = [:]
    /// Per-tracker breadcrumb trail of the PHONE's position over time, so a separated tag that
    /// stays with us across many places draws a visible path. Rate- and distance-gated on the way
    /// in (see the tracker block in ingestDetection); capped, session-only, never persisted -
    /// exactly like trackHistory. lastCrumbAt holds the last append time per id for the rate gate.
    private var crumbHistory: [String: [CLLocationCoordinate2D]] = [:]
    private var lastCrumbAt: [String: Date] = [:]
    /// When this device's FIRST crumb was dropped, i.e. the START of its crumb window.
    ///
    /// Separate from firstSeenAt, and the difference is the whole point: firstSeenAt is when the
    /// device was first HEARD and it is PERSISTED across launches, while crumbs begin later (the
    /// first fresh fix after the sighting) and are session-only. Scoring a follow window from
    /// firstSeenAt therefore narrated a duration the trail does not cover, and let the band time
    /// floors be satisfied by time that contains no crumbs at all. Torn down in lockstep with
    /// lastCrumbAt at EVERY site, because a stamp that outlives its crumbs is exactly the stale
    /// input this exists to remove.
    private var firstCrumbAt: [String: Date] = [:]

    /// What ingestHistory filed for a row, and how honest the time on it is. Keyed by detection
    /// id but carrying the STAMP it applies to, because the two can disagree: a device replayed
    /// from the buffer and THEN heard live keeps its buffered firstSeenAt (the live path only
    /// stamps a FIRST sighting) while its lastSeen becomes a real clock reading. Asking with the
    /// stamp in hand is the only way to tell those two apart, which is the same rule the older
    /// isApproxTime followed. `boot` and `seq` are kept so a record the board could not date can
    /// still be bounded and ordered once the rest of the drain arrives.
    private struct HistoryStamp {
        let stamp: Date
        let boot: UInt32?
        let seq: UInt32
        var basis: TimeBasis
    }
    private var histBasis: [String: HistoryStamp] = [:]
    /// Per-boot min/max of the timestamps the board DID resolve, in wall-clock time. These are the
    /// anchors every unanchored boot gets bracketed against. NOT per-drain: boot counters are
    /// monotonic, so a boot anchored in an earlier session bounds this session's records just as
    /// soundly - rebuilt from the persisted log on reload and extended by every drain, exactly like
    /// Android's bootMinAt/bootMaxAt. Cleared only with the rows it was derived from (clear log /
    /// in-memory reset), or a wiped log's anchors would bracket records whose basis is gone.
    private var histAnchoredBoots: [UInt32: (min: Date, max: Date)] = [:]
    /// When this drain's {"epoch"} push went out. The board writes its anchor on receiving that
    /// push, so this is the app's own record of the anchor moment, which is what the precision
    /// estimate measures drift over.
    private var syncStartedAt: Date?
    private let ignoreKey = "acab.ignoredDevices"
    private let watchKey = "acab.watchedDevices"
    private let watermarkKey = "acab.seenWatermark"   // "mark all seen" baseline
    private let seenWatermarkSeededKey = "acab.seenWatermarkSeeded"   // first-open baseline set once
    /// Second "mark all seen" baseline, for the PSEUDO-TIME band (undateable buffered rows).
    /// Those rows' near-epoch stamps are ordering keys that get renumbered on every clean drain
    /// end (resolveBracketedHistory), so a stamp-value watermark there would go stale on the next
    /// renumber; the board's buffer seq is the stable recency axis underneath the stamps, and it
    /// is the same quantity Android's approxWatermark encodes (HIST_PSEUDO_BASE - seq*1000).
    /// 0 = nothing marked seen yet, so a first drain of undateable records reads as New.
    private var approxSeenSeq: UInt32 = 0
    private let approxSeenSeqKey = "acab.approxSeenSeq"
    private let alertModeKey = "acab.alertMode"
    private let lastSeqKey = "acab.lastSeq"   // persisted across disconnects; survives relaunch
    private let replayCursorKey = "acab.replayCursorV2" // one atomic "generation:sequence" tuple
    private let redactKey = "acab.redactLockScreen"

    // Offline detection buffer. The board buffers detections (encrypted at rest with
    // our key) while we're away, then replays them on {sync}. We file replayed records
    // into the same store + dedup as live ones, but with their original timestamp and
    // no alert.
    @Published private(set) var bufferingOn = false   // mirrors the board's "bufon"
    @Published private(set) var bufferWiping = false  // mirrors the board's "wiping": a deferred buffer erase is still sweeping (absent = idle)

    // Broad Motorola Solutions OUI match ("moto"), a SUB-toggle underneath the body-cam
    // category. It used to share the body-cam switch, so quieting the noisy vendor proxy also
    // silenced the conf-90 Axon BWCDEVICE payload match; the board splits them now.
    // Pre-split firmware omits the key entirely. That build has no separate switch (the broad
    // match rides the body-cam toggle), so absent = ON, and `motorolaSupported` stays false so
    // Settings can drop a control that board would ignore. Both are recomputed from every
    // status frame, so reconnecting to an older board corrects them on its first frame.
    @Published private(set) var motorolaOn = true
    @Published private(set) var motorolaSupported = false

    // Reconnect replay UX. True from the moment we ask the board to replay (on reconnect)
    // until the end sentinel arrives; feeds the subtle "syncing offline log" indicator.
    // offlineSyncCount is the running tally filed this drain, for the optional live count.
    @Published private(set) var syncingOfflineLog = false
    @Published private(set) var offlineSyncCount = 0
    @Published private(set) var offlineSyncTotal = 0   // total this drain, from {"hist":"begin"}; 0 = unknown
    // One-shot, published only when a drain finished with records buffered (n > 0). Drives
    // the transient count banner; cleared on view / dismiss. Not persisted across launches.
    @Published var offlineSyncBanner: OfflineSyncSummary?

    private var histReceived = 0                       // records counted this drain (filed OR ignored)
    private var lastGoodSeq: UInt32 = 0                // highest contiguous seq filed this drain
    private var histHighestSeq: UInt32 = 0             // highest seq actually RECEIVED this drain
    /// True only after THIS attempt's begin sentinel. `n == 0` is a valid begin, so total cannot
    /// stand in for this bit; an end without it has no authority to finalize a generation/cursor.
    private var histBeginSeen = false
    private var histResyncs = 0                        // gap re-syncs issued this connection
    private let histResyncCap = 2                      // matches Android; at the cap, accept the drain as-is
    private var histPseudoTick = 0                     // monotonically-decreasing pseudo-time source for approx records
    /// Base for the order-only pseudo-time ingestHistory stamps onto buffered records the board
    /// had no clock for. Sits just above epoch, far below any real wall clock, so every pseudo
    /// stamp (base - tick) sorts before every real capture AND isApproxTime can separate the two
    /// time axes. The single source of truth for both the stamp math and isApproxTime, so they
    /// can never drift. Mirrors Android's HIST_PSEUDO_BASE.
    private let histPseudoBase = Date(timeIntervalSince1970: 1)
    private let notifHaptic = UINotificationFeedbackGenerator()
    private let impactHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// Per-device haptic cooldown. THE COOLDOWN IS THE EDGE, NOT `firstTime`.
    ///
    /// This is the same defect DetectionNotifier already fixed for notifications, left behind on
    /// the haptic line. `firstTime` is `store[d.id] == nil`, and the store is PERSISTED across
    /// launches (init -> loadPersistedDetections), so a device seen in ANY earlier session was
    /// never "first" again and could never buzz. On a commute past the same hardware that is every
    /// device, which is why the vibrate setting read as doing nothing at all. See the DESIGN RULES
    /// block in DetectionNotifier.swift, which spells out this exact trap.
    ///
    /// Deliberately NOT shared with the notifier's table: a silent board is not a silent phone, and
    /// one shared cooldown would let a notification suppress a haptic or the reverse. Bounded the
    /// same way the notifier's is, which matters in Desert mode where one drive sees thousands of
    /// MACs.
    private var lastHapticByMac: [String: Date] = [:]
    private static let hapticCooldown: TimeInterval = 600   // 10 min, matches DetectionNotifier

    private let locationManager = CLLocationManager()
    /// A one-shot precision request while the HERE menu waits for a usable fix. Persisted place
    /// rules keep the same accuracy target so their 50 m boundary remains meaningful.
    private var awaitingHereFix = false
    /// Published permission state gives SwiftUI an explicit, live model for denied/restricted
    /// recovery instead of relying on an unrelated BLE publication to refresh the screen.
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus = .notDetermined
    /// The whole CLLocation, not just its coordinate, because the coordinate alone can't be tested
    /// for freshness even in principle. See freshCoord.
    private var lastFix: CLLocation?
    /// Last-known coordinate, no expiry. Only for centering a map, never for stamping a detection
    /// or for the board uplink.
    private var lastCoord: CLLocationCoordinate2D? { lastFix?.coordinate }
    /// The phone's position, but only if the fix is actually recent enough to describe where we are
    /// NOW. lastFix is a last-seen value: location only runs while something needs it, so the
    /// moment it stops (disconnect, Drive mode off, leaving the tour) the value holds forever, and
    /// a frozen coordinate is not a missing coordinate, it pins the rest of the drive on the
    /// driveway, in the map and in the exported CSV both. CLLocationCoordinate2DIsValid can't catch
    /// it: a two-hour-old coordinate is a valid coordinate. Nor is a cold launch safe, since
    /// startUpdatingLocation delivers CoreLocation's own cached fix first and that can be any age.
    /// 2 minutes matches Android's FIX_MAX_AGE_NANOS.
    private var freshCoord: CLLocationCoordinate2D? {
        guard locationAuthorized, let f = lastFix,
              locationFixIsCurrent(f.timestamp, now: .now) else { return nil }
        return f.coordinate
    }

    /// Stricter coordinate for a 50-meter HERE rule. Observer geotagging can honestly retain a
    /// coarser fresh fix with its normal accuracy semantics; a binary geofence cannot claim the
    /// phone is inside a radius smaller than the fix's uncertainty.
    private var freshHereCoord: CLLocationCoordinate2D? {
        guard locationAuthorized, let f = lastFix,
              CLLocationCoordinate2DIsValid(f.coordinate),
              locationFixSupportsHere(f.timestamp, horizontalAccuracy: f.horizontalAccuracy,
                                      now: .now) else { return nil }
        return f.coordinate
    }

    private let liveActivity = LiveActivityController()   // Dynamic Island / Lock Screen counter
    /// Per-category phone notifications (see DetectionNotifier). Independent of alertMode.
    let notifier = DetectionNotifier()
    /// Enabled-detector set as last pushed to the Live Activity, so a status frame only forces an
    /// activity update when the toggles actually changed (see ingestStatus).
    ///
    /// MUST be cleared when a link is (re)established. Otherwise the first status frame of the next connection
    /// compares equal to this stale value, the push is suppressed, and the drive surface stays on
    /// the fallback five columns for the rest of the session.
    private var lastPushedEnabled: [String]?
    // Drive-mode link-loss grace. A live disconnect flips the Live Activity to
    // "Reconnecting…" and keeps it up briefly, so a transient BLE dropout mid-drive (a
    // parking structure, the board two cars back at a light) doesn't tear Drive mode down -
    // and iOS won't let us restart a Live Activity from the background, so we can't simply
    // end and re-add it on reconnect. But a board that actually powered off (parked, walked
    // away) never comes back, and the counter must NOT sit frozen on the Lock Screen
    // forever. If nothing reconnects within this window, end the activity. The controller's
    // 8-minute staleDate is the last-ditch backstop if even this timer never fires (app
    // suspended with location denied).
    private var driveLinkGrace: Timer?
    private let driveLinkGraceInterval: TimeInterval = 120
    // Per-category live counts, maintained in publishDetections() so the Live Activity
    // snapshot is O(1) instead of re-scanning the store on every detection notify.
    private var liveCounts = (alpr: 0, drones: 0, body: 0, trackers: 0, glasses: 0, cameras: 0)
    // The most recent live detection's category + time, remembered so foreground
    // reconciles and setting toggles don't wipe the activity's "last ALPR 2m ago" footer.
    private var lastLiveKind = ""
    private var lastLiveSeen = Date()
    // Floor between ESCALATED (immediate, coalescer-bypassing) Live Activity pushes. Every
    // first sighting used to escalate, so a dense crowd was a sustained per-device
    // ActivityKit flood (widget re-renders, budget throttling, battery). Excess first
    // sightings fall through to the controller's own coalescer, never dropped.
    private var lastEscalatedPush = Date.distantPast
    private let escalateMinGap: TimeInterval = 1.5

    // Live-feed performance. A Desert-mode firehose can fire detection notifies far
    // faster than SwiftUI can diff a list, so we (1) cap the published array at the
    // most-recent `liveFeedCap` rows and (2) coalesce republishes to a few Hz.
    private let liveFeedCap = 5000                 // most-recent rows kept (map + list + backing store). High enough to just keep logging through any real session (~5MB); still bounded so a marathon Desert firehose can't exhaust memory. The board's black box is the uncapped record.
    private var publishTimer: Timer?               // pending coalesced republish
    private var muteExpiryTimer: Timer?
    /// O(1) lookup used by every incoming detection and every rendered log row. Rebuilt only when
    /// a managed rule, Location fix/authorization, or expiry boundary changes; the former computed
    /// array filtered all 256 rules on each hot-path lookup.
    private var activeIgnoredMacSet: Set<String> = []
    private var watchedMacSet: Set<String> = []
    private var publishedActiveIgnoredMacs: Set<String> = []
    private var liveNearbyTimer: Timer?
    /// Main-thread generation gate for persistQueue loads. All mutations happen at UI/CB entry
    /// points on main; the background decoder carries only the immutable token it was given.
    private var persistedDetectionLoadGate = PersistedDetectionLoadGate()
    /// Write-ahead Clear intent. It outlives this manager/process and is retired only after the
    /// serialized detections file is confirmed absent.
    private let persistedDetectionClearTombstone = PersistedDetectionClearTombstone()
    /// Tokens for the block observers registered in init(), so deinit can remove them. See observe().
    private var notificationObservers: [NSObjectProtocol] = []
    private var lastPublish = Date.distantPast     // when we last pushed to @Published
    private let publishInterval: TimeInterval = 0.3   // ~3 Hz ceiling on UI updates
    private let liveNearbyRefreshInterval: TimeInterval = 5

    override init() {
        super.init()
        enabledPhoneNotificationTypes = Set(DetectionNotifier.notifiableTypes
            .filter { DetectionNotifier.isEnabled($0) }
            .map(\.rawValue))
        // Seed the stored authorization before loading mutes/history. `freshCoord` deliberately
        // reads this published mirror so a revoked grant invalidates place rules immediately.
        locationAuthorizationStatus = locationManager.authorizationStatus
        loadIgnored()
        pruneExpiredMutes()
        muteExpiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshMutePolicy()
        }
        loadWatched()
        if let t = UserDefaults.standard.object(forKey: watermarkKey) as? Double {
            seenWatermark = Date(timeIntervalSince1970: t)
        }
        approxSeenSeq = UInt32(clamping: UserDefaults.standard.integer(forKey: approxSeenSeqKey))
        // A previous Clear may have been interrupted after its durable tombstone landed but before
        // the file disappeared. Resolve that intent synchronously before even scheduling a decode;
        // on failure loadPersistedDetections stays gated and foregrounding retries.
        retryPendingDetectionClear()
        loadPersistedDetections()   // bring back any history filed in a past session
        // Nil-check on purpose: a missing value keeps the shipped default (counts visible),
        // while a stored Bool is the user's explicit past choice and always wins.
        if let v = UserDefaults.standard.object(forKey: redactKey) as? Bool { redactLockScreen = v }
        // Keep the Drive-mode toggle honest: the controller flips it back off if the Live
        // Activity ends or the user swipes it away, and re-adopts one still running from a
        // previous launch (so a relaunch mid-drive resumes instead of orphaning it).
        liveActivity.onInactive = { [weak self] reason in
            self?.driveLinkGrace?.invalidate(); self?.driveLinkGrace = nil   // activity is gone; nothing to auto-end
            self?.liveNearbyTimer?.invalidate(); self?.liveNearbyTimer = nil
            // A swipe dismissal is an explicit surface-level Off. A plain .ended state is
            // ambiguous (system lifecycle/budget, or an intent that already wrote its choice), so
            // preserve wanted there. This distinction prevents both unwanted resurrection after a
            // swipe and unwanted preference loss after system retirement.
            if self?.demoMode != true, !shouldPreserveLiveModeIntent(after: reason) {
                self?.setDriveModeWanted(false)
            }
            self?.driveModeOn = false
            self?.stopLocationIfIdle()   // Drive mode was the only thing holding location, disconnected
        }
        // Best-effort: end the Drive-mode Live Activity when the app is force-quit, so the
        // Dynamic Island / Lock Screen counter doesn't linger. willTerminate only fires
        // while the app is actually running in the background - during Drive mode that comes
        // from the location updates (when location is granted), NOT bluetooth-central alone,
        // which iOS suspends between events. A suspended app (e.g. location denied) can be
        // killed without willTerminate; the activity's staleDate + the next-launch
        // adoptExisting() reconcile are the backstops there. endBlocking waits for ActivityKit
        // to take the dismissal before we return, since the process is about to die.
        observe(UIApplication.willTerminateNotification) { [weak self] _ in
            self?.liveActivity.endBlocking()
            // The link dies with the process; leave the home widget honest rather than frozen
            // on "connected". (Best-effort, same caveat as endBlocking: a suspended app may
            // never reach here, but the widget also degrades on its own next refresh.)
            self?.widgetDefaults?.set(false, forKey: "w_connected")
            WidgetCenter.shared.reloadAllTimelines()
        }
        // Checkpoint the live log on the way out. Backgrounding is when a session ends and when
        // the app is about to be jetsammed or force-quit (a swipe-away backgrounds first), and
        // the board buffers nothing while we're connected, so this is the last chance to get the
        // drive onto disk. willTerminate is too late for an async write.
        observe(UIApplication.didEnterBackgroundNotification) { [weak self] _ in
            self?.checkpointLive()
            // Park a running connect scan: nothing consumes its results while backgrounded, and
            // with the bluetooth-central background mode a service-filtered scan otherwise keeps
            // the radio lit for days ("board off, tapped Scan, pressed Home"). Stop the radio
            // work directly but LEAVE connectionState == .scanning as the resume flag; the
            // foreground observer below re-issues the scan. Auto-reconnect is unaffected: it
            // rides a parked central.connect, not a scan.
            if self?.connectionState == .scanning { self?.central?.stopScan() }
        }
        // Resume the parked connect scan when the user comes back to it.
        observe(UIApplication.willEnterForegroundNotification) { [weak self] _ in
            guard let self else { return }
            // Re-read notification permission on EVERY foreground, not just at launch. A user who
            // grants it in iOS Settings mid-session would otherwise stay silently unauthorized for
            // the whole process, with green toggles over a dead feature.
            self.notifier.refreshAuthorization()
            self.locationAuthorizationStatus = self.locationManager.authorizationStatus
            self.retryPendingDetectionClear(checkpointCurrentStoreOnSuccess: true)
            self.retryManagedListPersistence()
            // If permission changed in Settings while the first-use manager was deferred, create
            // it now without requiring a relaunch. Denied/restricted remain an actionable state.
            if self.central == nil {
                switch CBManager.authorization {
                case .allowedAlways: self.initializeCentral()
                case .denied, .restricted: self.connectionState = .unauthorized
                case .notDetermined: self.connectionState = .idle
                @unknown default: self.connectionState = .unknown
                }
            }
            guard self.connectionState == .scanning else { return }
            self.startScan()
        }
        // A Control Center intent can execute after the scene's active transition when the app was
        // already warm. Its in-process notification closes that ordering gap; a cold/cross-process
        // invocation is still covered by ACABApp's foreground reconciliation of shared defaults.
        observe(.driveModeIntentChanged) { [weak self] _ in
            self?.scheduleDriveModeReconcile()
        }
        // App Intents may execute in the widget extension even though openAppWhenRun foregrounds
        // the app. A process-local notification cannot cross that boundary, so mirror the handoff
        // through Darwin notification center. Shared defaults still carry the value if launch
        // happens after the post; this callback closes the warm/cold-launch ordering race.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(self).toOpaque(),
            { _, observer, _, _, _ in
                guard let observer else { return }
                let manager = Unmanaged<BLEManager>.fromOpaque(observer).takeUnretainedValue()
                DispatchQueue.main.async {
                    if !manager.demoMode { manager.driveModeWanted = DriveModeState.wanted }
                    manager.scheduleDriveModeReconcile()
                }
            },
            driveModeDarwinNotification.rawValue,
            nil,
            .deliverImmediately)
        // Do not adopt here. At initialization there is no ready encrypted session yet and the
        // Location state has not been acted on; reconcileDriveMode owns adoption after both gates.
        notifier.refreshAuthorization()   // trust the system's answer, not our own last request
        alertMode = AlertMode(rawValue: UserDefaults.standard.string(forKey: alertModeKey) ?? "") ?? .buzzer
        if alertMode == .vibrate { requestFocusAuthIfNeeded() }
        locationManager.delegate = self
        updateLocationDesiredAccuracy()
        locationManager.activityType = .automotiveNavigation   // what this actually is: tagging hits from a moving car
        switch CBManager.authorization {
        case .allowedAlways:
            initializeCentral()   // returning user: preserve normal reconnect/background startup
        case .denied, .restricted:
            connectionState = .unauthorized
        case .notDetermined:
            connectionState = .idle   // rationale + user CTA appear before CBCentralManager exists
        @unknown default:
            connectionState = .unknown
        }
    }

    /// Register a block observer on the default center and KEEP its token, so deinit can retire it.
    /// A block observer is not tied to the object that armed it: the token is the only handle.
    private func observe(_ name: Notification.Name,
                         _ handler: @escaping (Notification) -> Void) {
        notificationObservers.append(
            NotificationCenter.default.addObserver(forName: name, object: nil,
                                                   queue: .main, using: handler))
    }

    /// Almost always `shared`, which lives for the process - but `init()` is not private and
    /// BeaconsTests builds short-lived instances, so everything armed above has to be retirable.
    /// The Darwin observer is the one that matters: it is keyed on a RAW unretained pointer to
    /// self, so a driveModeIntentChanged post after this object is gone would call
    /// takeUnretainedValue() on freed memory. The timers are retained by the run loop rather than
    /// by us, so an uninvalidated repeating one keeps firing for the life of the process.
    deinit {
        CFNotificationCenterRemoveEveryObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                                Unmanaged.passUnretained(self).toOpaque())
        for token in notificationObservers { NotificationCenter.default.removeObserver(token) }
        for timer in [muteExpiryTimer, publishTimer, liveCheckpointTimer, liveNearbyTimer,
                      driveLinkGrace, widgetReloadTimer, widgetSampleTimer, connectTimeoutTimer,
                      secureReadinessTimeoutTimer, scanTimeoutTimer, statusPollTimer,
                      otaStallTimer, combinedTimer, managedListRetryTimer] {
            timer?.invalidate()
        }
    }

    // MARK: - Intent

    private func initializeCentral() {
        guard central == nil else { return }
        connectionState = .unknown
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// The only first-use Bluetooth path. Location is optional and requested contextually from
    /// features that need it (Map/HERE mute), not bundled into the required pairing flow.
    func startScanFromUser() {
        guard central == nil else { startScan(); return }
        switch CBManager.authorization {
        case .denied, .restricted:
            connectionState = .unauthorized
        case .allowedAlways, .notDetermined:
            scanWhenCentralIsReady = true
            initializeCentral()
        @unknown default:
            connectionState = .unknown
        }
    }

    /// Location is optional. Contextual callers explain why they need it; an existing grant simply
    /// starts updates when a connected session needs them.
    func requestLocationAccessIfNeeded() {
        guard !firstRunOnboardingActive else { return }
        locationAuthorizationStatus = locationManager.authorizationStatus
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            startLocationIfNeeded()
        }
    }

    /// HERE is a 50 m binary decision, so ask Core Location for a fix meaningfully tighter than
    /// the normal observer-geotagging target. The fix still has to pass horizontalAccuracy <= 50.
    func requestLocationForPlaceMute() {
        awaitingHereFix = true
        updateLocationDesiredAccuracy()
        requestLocationAccessIfNeeded()
    }

    func startScan() {
        guard let central else {
            // Automatic resume is allowed only for a previously-granted install. Never create the
            // first manager (and therefore a prompt) outside startScanFromUser().
            guard CBManager.authorization == .allowedAlways else { return }
            scanWhenCentralIsReady = true
            initializeCentral()
            return
        }
        guard central.state == .poweredOn else { return }
        discovered.removeAll()
        lastAdvertAt.removeAll()   // freshness stamps belong to the list they describe
        connectionState = .scanning
        // Allow duplicates so we don't miss the scan-response manufacturer data
        // (the firmware version) - it usually shows up a callback or two after the first advert.
        #if DEBUG
        loggedScanIDs.removeAll()   // re-describe each board once per scan session
        #endif
        // AllowDuplicates is what keeps the RSSI live on the picker rows, and it is also why the
        // trace above has to be once-per-peripheral: this delivers every advertisement, not just
        // the first sighting of each device.
        central.scanForPeripherals(withServices: [ACABProfile.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        // Self-stop after 45 s, like Android: without a bound this hot scan ran until the user
        // connected, tapped stop, or backgrounded the app. stopScan() keeps the found list, so
        // expiry lands on the resting screen with the boards it saw.
        scanTimeoutTimer?.invalidate()
        scanTimeoutTimer = Timer.scheduledTimer(withTimeInterval: scanTimeoutInterval,
                                                repeats: false) { [weak self] _ in
            self?.scanTimeoutTimer = nil
            if self?.connectionState == .scanning { self?.stopScan() }
        }
    }

    func stopScan() {
        scanTimeoutTimer?.invalidate(); scanTimeoutTimer = nil
        // "Stopped" should mean no scan running OR pending, so an explicit stop retires a deferred
        // intent as well. Two of the three callers only ever arrive with a scan already running
        // (the Scan/Stop button in ConnectView and the 45 s timeout both key on .scanning). The
        // third does not: seedDemoData calls us whenever demoEntryNeedsScanCancellation reports
        // isScanning OR scanDeferred, so demo entry with a pending-but-unstarted scan reaches here
        // with nothing running. That caller clears scanWhenCentralIsReady itself on the line above
        // its call, so today the clear below is belt-and-braces for it rather than the thing that
        // saves it - but the invariant is what lets a future caller arrive the same way safely.
        // The reachable half of the never-expiring intent is retired in centralManagerDidUpdateState.
        scanWhenCentralIsReady = false
        central?.stopScan()
        if connectionState == .scanning { connectionState = .idle }
    }

    func connect(_ device: DiscoveredDevice) {
        guard let central else { return }
        cancelUpdatesForLinkTeardown(
            reason: "The prior update was stopped before connecting to another board.")
        // A fresh user-selected session can never inherit teardown intent from a prior handle whose
        // terminal callback was suppressed by a radio reset.
        intentionalDisconnectID = nil
        connectHint = nil   // fresh attempt: drop any stale recovery hint from the last one
        central.stopScan()
        scanTimeoutTimer?.invalidate(); scanTimeoutTimer = nil   // the window closes with the scan
        updateSecureReadinessWatchdog(.teardown)
        setSessionReady(false)   // a fresh session hasn't reached ready until its CCCD subscribe lands
        retireSessionCharacteristics()
        connectionState = .connecting
        peripheral = device.peripheral
        peripheral?.delegate = self
        central.connect(device.peripheral, options: nil)
        connectTimeoutTimer?.invalidate()
        connectTimeoutTimer = Timer.scheduledTimer(withTimeInterval: connectTimeoutInterval,
                                                   repeats: false) { [weak self] _ in
            self?.connectTimedOut()
        }
    }

    /// The fresh connect never resolved. Cancel it and show a specific retry, instead of silently
    /// starting another 45-second scan that makes the original tap look ignored. It gets no
    /// intentional-disconnect target: a cancelled never-established connect yields no
    /// didDisconnect callback to consume it.
    private func connectTimedOut() {
        connectTimeoutTimer = nil
        guard connectionState == .connecting, reconnectTarget == nil,
              otaAwaitingReboot == nil, let pending = peripheral else { return }
        updateSecureReadinessWatchdog(.teardown)
        cancelUpdatesForLinkTeardown(reason: "The board connection timed out during the update.")
        resetConfigWriteQueue()
        retireSessionCharacteristics()
        central?.cancelPeripheralConnection(pending)
        peripheral = nil
        connectionState = (central?.state == .poweredOn) ? .idle : .unknown
        connectHint = beaconConnectionRecovery(.timeout)
    }

    private func updateSecureReadinessWatchdog(_ event: SecureReadinessWatchdogEvent,
                                               peripheral: CBPeripheral? = nil) {
        switch secureReadinessWatchdogAction(for: event) {
        case .cancel:
            secureReadinessTimeoutTimer?.invalidate()
            secureReadinessTimeoutTimer = nil
        case .arm:
            guard let peripheral else { return }
            let expectedID = peripheral.identifier
            secureReadinessTimeoutTimer?.invalidate()
            secureReadinessTimeoutTimer = Timer.scheduledTimer(
                withTimeInterval: secureReadinessTimeoutInterval,
                repeats: false) { [weak self] _ in
                    self?.secureReadinessTimedOut(expectedID: expectedID)
                }
        }
    }

    private func secureReadinessTimedOut(expectedID: UUID) {
        secureReadinessTimeoutTimer = nil
        guard secureReadinessTimeoutApplies(expectedID: expectedID,
                                            currentID: peripheral?.identifier,
                                            sessionReady: sessionHeldForUpdate,
                                            isDemoMode: demoMode) else { return }
        connectHint = beaconConnectionRecovery(.securePairing)
        retireSessionCharacteristics()
        otaCapable = false
        connectedName = nil
        status = nil
        syncingOfflineLog = false
        resetConfigWriteQueue()
        setSessionReady(false)
        disconnect()
    }

    func disconnect() {
        let pendingOtaReconnect = otaAwaitingReboot != nil ? peripheral : nil
        updateSecureReadinessWatchdog(.teardown)
        cancelUpdatesForLinkTeardown(
            reason: "Update cancelled because you disconnected from the board.")
        resetConfigWriteQueue()
        retireSessionCharacteristics()
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        if let target = reconnectTarget {
            // We were already holding a pending auto-reconnect from an earlier unexpected drop.
            // Cancelling a pending (never-established) connect yields NO didDisconnect callback, so
            // settle the UI + widget here rather than waiting for one that won't arrive.
            central?.cancelPeripheralConnection(target)
            reconnectTarget = nil
            intentionalDisconnectID = nil
            connectionState = (central?.state == .poweredOn) ? .idle : .unknown
            // This pending reconnect came from an earlier unexpected drop, which ran
            // driveModeLinkLost(): the Live Activity is sitting on "Reconnecting…" with the 120s
            // grace armed. Cancelling a pending connect fires no didDisconnect, so the intentional
            // branch there never runs. End Drive mode here or the
            // stale counter lingers on the Lock Screen for two minutes after the user disconnected.
            if driveModeOn { suspendDriveModeForLinkEnd() }
            writeWidgetSummary(force: true)
            return
        }
        // During the OTA reboot wait CoreBluetooth holds a pending connect while the public state
        // intentionally remains connected. Cancelling that request may produce didFailToConnect,
        // didDisconnect, or no terminal callback. Settle it synchronously so none of those outcomes
        // can retry an update after the user explicitly disconnected.
        if let target = pendingOtaReconnect {
            central?.cancelPeripheralConnection(target)
            stopStatusPolling()
            checkpointLive()
            intentionalDisconnectID = nil
            peripheral = nil
            otaCapable = false
            connectedName = nil
            status = nil
            syncingOfflineLog = false
            histBeginSeen = false
            histResyncs = 0
            setSessionReady(false)
            reconnectTarget = nil
            connectionState = (central?.state == .poweredOn) ? .idle : .unknown
            if driveModeOn { suspendDriveModeForLinkEnd() }
            writeWidgetSummary(force: true)
            stopLocationIfIdle()
            return
        }
        // A FRESH scan-connect still pending (tapped a board row, no didConnect yet): same
        // problem as the reconnect branch above, cancelling a never-established connect yields
        // NO didDisconnect, so settle the state inline and consume the flag here too. Without
        // this the UI stays pinned on .connecting. (An OTA reboot wait
        // never lands here: it holds connectionState at .connected.) If the link did come up in
        // the race window, the didDisconnect that follows finds a peripheral we no longer hold
        // and didDisconnectPeripheral treats that as finished business.
        if connectionState == .connecting, reconnectTarget == nil, let pending = peripheral {
            central?.cancelPeripheralConnection(pending)
            peripheral = nil
            intentionalDisconnectID = nil
            connectionState = (central?.state == .poweredOn) ? .idle : .unknown
            return
        }
        if let peripheral {
            // Scope the intent to this exact board. Late callbacks from any retired board may
            // clear only their own matching intent and can never affect this session.
            intentionalDisconnectID = peripheral.identifier
            central?.cancelPeripheralConnection(peripheral)
        }
    }

    /// Arm (or re-arm) the pending auto-reconnect for `reconnectTarget`. central.connect with no
    /// options and no timeout parks the request until the board re-advertises; iOS then fires
    /// didConnect and the standard discover-services handshake resyncs status + widget + Live
    /// Activity. Guarded so we never stomp a live link and only fire while the radio is on; when
    /// the radio is off we defer and centralManagerDidUpdateState re-arms on .poweredOn.
    private func armReconnect() {
        guard let central, let target = reconnectTarget,
              central.state == .poweredOn,
              connectionState != .connected else { return }
        target.delegate = self
        central.connect(target, options: nil)   // stays pending until the board comes back; works backgrounded
    }

    /// Invalidate every asynchronous update owner before a board handle can be replaced. Each
    /// engine has its own generation guard; the combined coordinator is stopped separately so an
    /// old timer cannot start the next leg on a new board.
    private func cancelUpdatesForLinkTeardown(reason: String, settleAsIdle: Bool = false) {
        let nrfPastPointOfNoReturn = nrfFlasher?.canCancelSafely == false
            && nrfDfuState.isRunning
        // Nordic validation/commit runs on its own BLE central and cannot be undone by losing the
        // S3 Config link. Keep its owner, callbacks, and combined coordinator alive so the app can
        // verify the result after the same board reconnects instead of reporting a false cancel.
        if !nrfPastPointOfNoReturn {
            combinedCancelForLinkTeardown(reason: reason, settleAsIdle: settleAsIdle)
        } else if combinedState.isRunning {
            combinedState = .verifying
            combinedPhaseLabel = "Finishing co-processor update"
        }
        otaCancelForLinkTeardown(reason: reason, settleAsIdle: settleAsIdle)
        nrfCancelForLinkTeardown(reason: reason, settleAsIdle: settleAsIdle)
    }

    /// Drop the log from memory only, leaving the on-disk history alone. This half exists so
    /// paths that just need a clean store (exiting the tour) can't cost the user real records.
    private func resetDetectionState() {
        notifier.reset()   // a new session may alert on the same devices again
        publishTimer?.invalidate(); publishTimer = nil   // drop any queued coalesced republish
        liveCheckpointTimer?.invalidate(); liveCheckpointTimer = nil   // and any queued disk write of the store we're dropping
        store.removeAll(); lastSeen.removeAll(); rssiHistory.removeAll()
        trackHistory.removeAll(); crumbHistory.removeAll()
        lastCrumbAt.removeAll(); firstCrumbAt.removeAll()   // both crumb stamps die with the crumbs
        firstSeenAt.removeAll(); capturedLoc.removeAll(); bestRssi.removeAll()
        logDetections = []; detections = []
        histBasis.removeAll(); histAnchoredBoots.removeAll()
        publishedActiveIgnoredMacs = activeIgnoredMacSet
        liveCounts = (0, 0, 0, 0, 0, 0)
        lastLiveKind = ""; lastLiveSeen = Date()
    }

    /// The user-confirmed "Clear log". A sample clear drops only the synthetic in-memory rows;
    /// the real path drops memory AND disk and remains the only path allowed to delete the file.
    /// Keeping that distinction here (rather than only hiding a button) makes every caller safe.
    @discardableResult
    func clearDetections() -> Bool {
        let action = detectionLogClearAction(isDemoMode: demoMode)
        guard action == .memoryAndDisk else {
            resetDetectionState()
            return true
        }

        // Write-ahead, synchronously flushed before the first destructive transition. If that
        // boundary itself cannot be confirmed, a synchronous confirmed deletion is the only safe
        // fallback. When BOTH fail, leave the visible store intact and let the caller surface the
        // failure; a Clear that reported success must never resurrect after process death.
        let commit = preparePersistedDetectionClear(
            armTombstone: { persistedDetectionClearTombstone.arm() },
            deleteSynchronously: { deletePersistedDetectionsSynchronously() })
        guard commit != .unavailable else { return false }

        // Invalidate before clearing memory or unlinking the file. A decoded load may already be
        // queued on main behind this tap; its token must be stale by the time it can run. Sample
        // Clear deliberately does not invalidate real-history work: exitDemo starts a fresh load,
        // which supersedes any older token without changing the tour's memory-only contract.
        persistedDetectionLoadGate.invalidate()
        resetDetectionState()
        if commit == .durableTombstone {
            // This waits behind every already-queued checkpoint on the same serial queue, then
            // confirms absence before retiring the tombstone. A failed unlink stays pending for
            // foreground or next-launch retry; no later checkpoint may run while it remains armed.
            retryPendingDetectionClear()
        } else {
            // The file is already confirmed absent. Clear the failed flush's in-process tombstone;
            // if retirement itself cannot flush, leaving it pending is conservative and launch will
            // simply confirm absence again.
            _ = persistedDetectionClearTombstone.retire()
        }
        if driveModeOn { liveActivity.update(liveState()) }
        writeWidgetSummary(force: true)   // count is now 0; reflect it on the home widget
        return true
    }

    // MARK: - Drive mode (Live Activity: Dynamic Island + Lock Screen counter)

    /// Values presented by Settings. During sample mode these come from an isolated in-memory
    /// preview; outside it they are the real persisted/system-backed preferences.
    var settingsDriveModeWanted: Bool {
        demoMode ? (samplePhoneSettings?.liveModeWanted ?? driveModeWanted) : driveModeWanted
    }

    var settingsRedactLockScreen: Bool {
        demoMode ? (samplePhoneSettings?.redactLockScreen ?? redactLockScreen) : redactLockScreen
    }

    func phoneNotificationEnabled(_ type: DeviceType) -> Bool {
        if demoMode, let preview = samplePhoneSettings {
            return preview.notificationEnabled(type.rawValue)
        }
        return enabledPhoneNotificationTypes.contains(type.rawValue)
    }

    private func updateSamplePhoneSettings(_ update: (inout SamplePhoneSettings) -> Void) {
        guard var preview = samplePhoneSettings else { return }
        update(&preview)
        samplePhoneSettings = preview
    }

    func setSettingsRedactLockScreen(_ value: Bool) {
        if demoMode {
            updateSamplePhoneSettings { $0.redactLockScreen = value }
        } else {
            redactLockScreen = value
        }
    }

    func setPhoneNotificationEnabled(_ enabled: Bool, for type: DeviceType) {
        if demoMode {
            updateSamplePhoneSettings { $0.setNotification(enabled, rawValue: type.rawValue) }
            return
        }
        notifier.setEnabled(enabled, for: type)
        if enabled { enabledPhoneNotificationTypes.insert(type.rawValue) }
        else { enabledPhoneNotificationTypes.remove(type.rawValue) }
    }

    /// Live Activities can be disabled per-app in Settings; the toggle surfaces a hint.
    var liveActivitiesEnabled: Bool { liveActivity.isAvailable }

    /// Persist the Drive-mode INTENT and keep the @Published mirror the toggle observes in step.
    /// The single writer for DriveModeState.wanted from the app side.
    private func setDriveModeWanted(_ value: Bool) {
        DriveModeState.wanted = value
        driveModeWanted = value
    }

    /// Start the Drive-mode Live Activity. iOS requires the app to be foregrounded to
    /// begin one; the toggle lives in DeviceView, which is on-screen when tapped.
    func startDriveMode() {
        if demoMode {
            updateSamplePhoneSettings { $0.liveModeWanted = true }
            return
        }
        // An explicit On outranks a previously dismissed corpse. Consume that dismissal first,
        // then persist the new choice and attempt the gated start.
        liveActivity.dropIfInactive()
        // Persist the user's choice even when Live Activities are currently disabled. If they
        // enable the capability in Settings, foreground reconciliation can honor the choice.
        setDriveModeWanted(true)    // survives the willTerminate teardown below
        beginDriveModeIfReady(explicitOn: true)
    }

    /// Automatic/default resume. Unlike the public toggle action, this must never turn a swipe
    /// dismissal back on while consuming an inactive ActivityKit handle.
    private func resumeDriveModeIfWanted() {
        guard automaticLiveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                                       locationAuthorized: locationAuthorized,
                                       firstRunOnboardingActive: firstRunOnboardingActive) else { return }
        driveModeWanted = DriveModeState.wanted
        guard driveModeWanted else { return }
        liveActivity.dropIfInactive()
        guard driveModeWanted else { return }
        beginDriveModeIfReady(explicitOn: false)
    }

    private func beginDriveModeIfReady(explicitOn: Bool) {
        guard !firstRunOnboardingActive else { return }
        guard liveActivity.isAvailable else { return }
        guard liveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                             locationAuthorized: locationAuthorized) else {
            // Never adopt or leave behind an activity that cannot be kept alive truthfully. A real
            // ready link with no Location grant remains visibly "Location needed" under Beacon.
            // Permission prompts are owned by explicit, contextual actions: the post-tour Continue
            // button or Enable Location in settings. A default preference, relaunch, or reconnect
            // must never raise a system sheet on its own.
            stopDriveModeActivity(rememberOff: false, updateWidget: false)
            return
        }
        _ = recomputeLiveCounts()
        switch liveActivity.adoptExisting() {
        case .adopted:   // reuse one already running from a previous process
            driveModeOn = true
            liveActivity.update(liveState())
            startLiveNearbyRefresh()
            return
        case .dismissed where !explicitOn:
            stopDriveModeActivity(rememberOff: true, updateWidget: false)
            return
        case .dismissed, .none:
            break
        }
        // Reflect whether the system actually started the activity (request can fail
        // silently); the controller also resets driveModeOn if it's later dismissed.
        driveModeOn = liveActivity.start(deviceName: connectedName ?? "beacons",
                                         state: liveState())
        if driveModeOn { startLiveNearbyRefresh() }
        startLocationIfNeeded()   // Drive mode's background residency rides on location updates
    }

    func endDriveMode() {
        if demoMode {
            updateSamplePhoneSettings { $0.liveModeWanted = false }
            return
        }
        stopDriveModeActivity(rememberOff: true)
    }

    /// A board session ending must remove its stale system surface, but it is not the same choice
    /// as switching the counter off. Preserve the preference so the next ready foreground session
    /// starts the counter again.
    private func suspendDriveModeForLinkEnd() {
        stopDriveModeActivity(rememberOff: false)
    }

    private func stopDriveModeActivity(rememberOff: Bool, updateWidget: Bool = true) {
        driveLinkGrace?.invalidate(); driveLinkGrace = nil   // no pending auto-end to fire later
        liveNearbyTimer?.invalidate(); liveNearbyTimer = nil
        if rememberOff { setDriveModeWanted(false) }
        driveModeOn = false
        liveActivity.end()
        if updateWidget {
            writeWidgetSummary(force: true)   // reflect "not connected / drive off" on the home widget
        }
        stopLocationIfIdle()
    }

    /// The live link dropped while Drive mode is on. Flip the Live Activity to
    /// "Reconnecting…" right away so a brief dropout reads honestly, and arm the grace
    /// timer that ends the activity if the board never comes back (the fix for the counter
    /// that used to sit frozen on the Lock Screen forever after a power-off). A no-op when
    /// Drive mode isn't running.
    private func driveModeLinkLost() {
        guard driveModeOn else { return }
        liveActivity.setConnected(false)
        driveLinkGrace?.invalidate()
        driveLinkGrace = Timer.scheduledTimer(withTimeInterval: driveLinkGraceInterval,
                                              repeats: false) { [weak self] _ in
            self?.driveModeGraceExpired()
        }
    }

    /// The board reconnected within the grace window: cancel the pending auto-end and clear
    /// the "Reconnecting…" line so the live counter resumes.
    private func driveModeLinkRestored() {
        driveLinkGrace?.invalidate(); driveLinkGrace = nil
        if driveModeOn { liveActivity.setConnected(true) }
    }

    /// Grace window elapsed with no reconnect: end the stale Live Activity instead of
    /// letting it linger. Ends Drive mode too, because iOS can't restart a Live Activity
    /// from the background - there's nothing to silently resume, and a fresh foreground
    /// toggle (or the Control Center control) starts a new one cleanly. Guarded so a
    /// reconnect that raced the timer, or a Drive mode the user already turned off, is a
    /// no-op.
    private func driveModeGraceExpired() {
        driveLinkGrace?.invalidate(); driveLinkGrace = nil
        guard driveModeOn, connectionState != .connected, !demoMode else { return }
        suspendDriveModeForLinkEnd()
    }

    /// Main-queue confined; both intent observers already hop to main before touching it.
    private var driveModeReconcilePending = false

    /// Coalesces intent-driven reconcile requests. An in-app intent execution (the Control
    /// Center toggle runs in-app via openAppWhenRun) posts BOTH the in-process notification
    /// and its Darwin mirror, and Darwin notifications are delivered to the posting process
    /// too - so both observers fire for one intent. The zero-delay main hop collapses
    /// same-hop bursts into one reconcileDriveMode() call; the Darwin loopback rides notifyd
    /// IPC plus its own main hop, so it can land after the first block drains and still
    /// reconcile a second time. That is accepted: reconcileDriveMode is idempotent and the
    /// worst case equals the pre-coalescer behavior. The extension-process path still arrives
    /// via Darwin alone and pays no extra latency. applicationState is checked at execution
    /// time, not scheduling time, so a not-yet-active post stays a no-op exactly as before.
    private func scheduleDriveModeReconcile() {
        guard !driveModeReconcilePending else { return }
        driveModeReconcilePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.driveModeReconcilePending = false
            guard UIApplication.shared.applicationState == .active else { return }
            self.reconcileDriveMode()
        }
    }

    /// Re-sync Drive mode with reality when the app returns to the foreground: adopt an
    /// activity started by the Control Center toggle, and turn the flag off if the Live
    /// Activity was ended (the in-activity End button, the toggle, or a swipe-away).
    func reconcileDriveMode() {
        guard !demoMode else {
            // Sample controls are an in-app preview. Never adopt, create, or infer a persisted
            // preference from a real ActivityKit surface while the synthetic board is active.
            driveLinkGrace?.invalidate(); driveLinkGrace = nil
            liveNearbyTimer?.invalidate(); liveNearbyTimer = nil
            driveModeOn = false
            liveActivity.end()
            return
        }
        // RootView releases this only after the real tour and finish-setup rationale close. While
        // held, do not adopt, create, or infer anything from ActivityKit. A returning user may keep
        // an existing surface alive during the brief launch handoff; release reconciles it.
        if firstRunOnboardingActive {
            driveModeWanted = DriveModeState.wanted
            driveModeOn = false
            return
        }
        // Pick up an intent change made while backgrounded (the in-activity End button or the
        // Control Center toggle write DriveModeState.wanted directly), so the settings toggle
        // reflects it on return.
        driveModeWanted = DriveModeState.wanted
        liveActivity.dropIfInactive()
        guard driveModeWanted else {
            // Explicit-off callers persist false before this reconciliation. End every local or
            // orphaned activity so a stale Control Center-created surface cannot survive it.
            stopDriveModeActivity(rememberOff: false)
            return
        }
        guard liveActivity.isAvailable else {
            stopDriveModeActivity(rememberOff: false, updateWidget: false)
            return
        }
        guard liveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                             locationAuthorized: locationAuthorized) else {
            // Adoption is gated by the same prerequisites as creation. A previous process or an
            // older Control Center implementation may have left an activity in ActivityKit; end
            // it now rather than adopting a counter with no ready data source/background grant.
            stopDriveModeActivity(rememberOff: false, updateWidget: false)
            return
        }
        switch liveActivity.adoptExisting() {
        case .adopted:
            driveModeOn = true
            _ = recomputeLiveCounts()
            liveActivity.update(liveState())
            startLiveNearbyRefresh()
            startLocationIfNeeded()
        case .dismissed:
            // A swipe that happened while the app was gone is still an explicit Off. The system
            // retains only a dismissed corpse; translate it before any automatic restart.
            setDriveModeWanted(false)
            stopDriveModeActivity(rememberOff: false)
        case .none where driveModeWanted:
            // No activity running, but the user never turned Drive mode off - so this is the
            // relaunch case: willTerminate ended the activity, and the intent outlived it.
            // Re-create the surface. This is the only path that reads `wanted`; every way of
            // turning Drive mode OFF (endDriveMode, the End button, the Control Center toggle,
            // a swipe-away via onInactive) clears it first, so a deliberate off cannot land here.
            // Foreground-gated at two of the three call sites (the scenePhase .active onChange in
            // ACABApp, and scheduleDriveModeReconcile's applicationState check); the cold-launch
            // onAppear call in ACABApp has no phase gate and can land before .active, where
            // Activity.request fails harmlessly and the .active pass retries - see ACABApp.swift.
            resumeDriveModeIfWanted()
        case .none:
            // The shared choice changed while reconciliation was in flight.
            stopDriveModeActivity(rememberOff: false)
        }
    }

    /// WidgetCategory rawValues for the detectors the BOARD reports switched on, which is what
    /// decides the drive-mode columns. Read off the live status rather than any app-side mirror,
    /// so a toggle flipped from the mesh or another phone is reflected too.
    ///
    /// Returns nil (NOT []) when no status has arrived yet: the widget reads nil as "unknown" and
    /// falls back to the historical five columns, while [] means every detector is genuinely off
    /// and draws none. Those two need opposite handling, which is the whole reason this is
    /// Optional; see DetectionActivityAttributes.enabled.
    private func enabledWidgetCategories() -> [String]? {
        // nil, NOT [], when no status has arrived. [] now means "every detector is off" and makes
        // the surface draw no columns at all; returning it here would blank the drive surface for
        // the whole window before the first status frame.
        guard let s = status else { return nil }
        var out: [String] = []
        if s.flock   { out.append(WidgetCategory.alpr.rawValue) }
        if s.drone   { out.append(WidgetCategory.drone.rawValue) }
        if s.axon    { out.append(WidgetCategory.body.rawValue) }
        if s.tracker { out.append(WidgetCategory.tracker.rawValue) }
        if s.glasses { out.append(WidgetCategory.glasses.rawValue) }
        if s.ncam    { out.append(WidgetCategory.camera.rawValue) }
        return out
    }

    /** Recompute the six nearby-now buckets from live rows only. Persisted history remains in
     * `store`, but it cannot keep a Live Activity count alive after Status's 45-second window. */
    @discardableResult
    private func recomputeLiveCounts(now: Date = .now) -> Bool {
        let previousKind = lastLiveKind
        let previousSeen = lastLiveSeen
        let muted = activeIgnoredMacSet
        let enabled = effectiveLiveModeCategories(enabledWidgetCategories())
        var a = 0, dr = 0, b = 0, tr = 0, gl = 0, nc = 0
        var newest: (kind: String, seen: Date)?
        for d in store.values {
            guard !d.isHistory else { continue }
            guard activeProjectionIncludes(loweredMac: d.loweredMac,
                      isCurrentlyWatched: watchedMacSet.contains(d.loweredMac),
                      activeIgnoredMacs: muted),
                  let seen = lastSeen[d.id],
                  liveRowIsNearby(seen, now: now, isDemoMode: demoMode) else { continue }
            guard let categoryKey = d.type.widgetCategoryKey,
                  enabled.contains(categoryKey) else { continue }
            switch d.type {
            case .flockCamera, .flockRaven: a += 1
            case .drone:                    dr += 1
            case .axonBodyCam:              b += 1
            case .tracker:                  tr += 1
            case .recordingGlasses:         gl += 1
            case .networkCamera:            nc += 1
            case .nearbyDevice, .watched, .unknown: break
            }
            if newest == nil || seen > newest!.seen {
                newest = (d.type.category, seen)
            }
        }
        var changed = a != liveCounts.alpr || dr != liveCounts.drones ||
            b != liveCounts.body || tr != liveCounts.trackers ||
            gl != liveCounts.glasses || nc != liveCounts.cameras
        liveCounts = (a, dr, b, tr, gl, nc)
        lastLiveKind = newest?.kind ?? ""
        if let seen = newest?.seen { lastLiveSeen = seen }
        changed = changed || lastLiveKind != previousKind || lastLiveSeen != previousSeen
        return changed
    }

    /// Run only while the system surface exists. A five-second cadence means a quiet detection
    /// disappears no later than about 50 seconds after it was last heard, while unchanged pushes
    /// are skipped entirely.
    private func startLiveNearbyRefresh() {
        guard liveNearbyTimer == nil else { return }
        liveNearbyTimer = Timer.scheduledTimer(withTimeInterval: liveNearbyRefreshInterval,
                                               repeats: true) { [weak self] _ in
            guard let self, self.driveModeOn else {
                self?.liveNearbyTimer?.invalidate(); self?.liveNearbyTimer = nil
                return
            }
            if self.recomputeLiveCounts() { self.liveActivity.update(self.liveState()) }
        }
    }

    /// Snapshot nearby counts into the Live Activity. Mirrors the dashboard categories exactly
    /// (ALPR = flockCamera + flockRaven; no police bucket, because the retired firmware t=6 has no
    /// DeviceType raw value: it decodes to .unknown, which recomputeLiveCounts skips because it
    /// has no widgetCategoryKey - onDriveSurface only decides whether a first sighting escalates
    /// an immediate Live Activity push).
    private func liveState() -> DetectionActivityAttributes.DetectionState {
        return .init(alpr: liveCounts.alpr, drones: liveCounts.drones,
                     bodyCams: liveCounts.body, trackers: liveCounts.trackers,
                     glasses: liveCounts.glasses, cameras: liveCounts.cameras,
                     lastKind: lastLiveKind, lastSeen: lastLiveSeen,
                     connected: connectionState == .connected || demoMode,
                     redact: redactLockScreen,
                     enabled: enabledWidgetCategories())
    }

    // MARK: - Home-screen widget summary (App Group shared store)
    //
    // The WidgetKit widget runs in its own process and cannot read our @Published state, so
    // we mirror a tiny summary into the shared App Group defaults whenever it changes: today's
    // detection count, the last detection (label + when), and whether the board is linked. The
    // widget reads these EXACT keys (see the widget data-sharing contract) and we nudge
    // WidgetKit to refresh. The recompute is NOT cheap - it walks every row first-seen today and
    // pays a store lookup plus a mute/watchlist test on each - which is why it is sampled instead
    // of run on every detection publish; see writeWidgetSummary.
    private let widgetSuite = "group.tech.beacons.app"
    private lazy var widgetDefaults = UserDefaults(suiteName: widgetSuite)
    // Local day index (whole days since epoch in the device's current time zone). Stored
    // alongside the count as "w_day" so the widget resets "today" at LOCAL midnight even when
    // the app hasn't written since yesterday: it compares this to its own day and shows 0 on a
    // mismatch. Our own recompute below is day-scoped too, so a write after midnight self-heals.
    private var widgetDayIndex: Int {
        Int((Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())) / 86400)
    }
    // WidgetKit budgets timeline reloads HARD: request them too often and the system stops
    // honoring BOTH our reloadAllTimelines() calls AND the 15-minute .after backstop, which
    // freezes the glance on its last-built entry until the user removes and re-adds the widget
    // (a fresh install rebuilds the timeline outside the spent budget). A Desert-mode firehose
    // used to drain that budget: publishDetections runs ~3 Hz and each write reloaded every 10s,
    // ~360 reloads/hour, and it reloaded even when nothing the widget shows had changed. So now
    // both the shared-defaults write and the reload key on the same edge - the summary the widget
    // actually RENDERS changed - and the reload is additionally capped at one per
    // widgetReloadMinGap. An unchanged summary means the stored values are already the ones we
    // would write, so whichever refresh does land still reads current data.
    private var lastWidgetReload = Date.distantPast
    private let widgetReloadMinGap: TimeInterval = 30
    // Sample cadence for the recompute itself, which is a separate problem from the reload budget
    // above. publishDetections used to call it at the ~3 Hz publish ceiling (publishInterval 0.3 s),
    // so a store at the liveFeedCap of 5000 rows paid the whole today-walk three times a second on
    // main for a glance that reloads at most twice a minute. Android samples its own recompute the
    // same way and at the same 2 s (WIDGET_SAMPLE_MS, driving the collector in
    // AcabBleManager.startWidgetFeed) so a Desert-mode firehose cannot thrash cross-process
    // updates; match the cadence. The two are NOT otherwise identical: AcabBleManager.updateWidget
    // also returns before its store walk when no widget is placed (BeaconsWidgetProvider.isPlaced),
    // and this side has no equivalent placement check, so it pays the walk either way.
    // A publish landing
    // inside the window is not dropped: it arms ONE trailing recompute for the end of the window,
    // so the last row of a burst still reaches the shared defaults. `force` bypasses both.
    private var lastWidgetSample = Date.distantPast
    private let widgetSampleGap: TimeInterval = 2
    private var widgetSampleTimer: Timer?
    // One-shot trailing reload so a change that arrives inside the min-gap window still reaches
    // the widget by the end of the window instead of waiting for the 15-minute backstop.
    private var widgetReloadTimer: Timer?
    // Last summary we reloaded for; a write whose visible fields match this skips the reload.
    private var lastWidgetSnapshot: WidgetSummarySnapshot?
    /// Exactly the fields DetectionsWidget renders, so equality means "the glance would look the
    /// same" and a reload would be wasted budget. cats is ordered by WidgetCategory.allCases.
    private struct WidgetSummarySnapshot: Equatable {
        let day: Int; let count: Int; let lastType: String
        let lastAt: Double; let connected: Bool; let cats: [Int]
    }
    #if DEBUG
    /// Peripherals already described by the scan trace, so it logs once each instead of once per
    /// advertisement. Cleared on each fresh scan so a new session still prints.
    private var loggedScanIDs = Set<UUID>()
    #endif

    /// Write the shared summary and (budget-permitting, or when forced) reload the widget.
    /// `force` is used on the connect/disconnect edges so the connected flag flips promptly.
    private func writeWidgetSummary(force: Bool = false) {
        guard let d = widgetDefaults else { return }
        if !force {
            let since = Date().timeIntervalSince(lastWidgetSample)
            guard since >= widgetSampleGap else {
                // Inside the window: queue one trailing pass so this change still lands, then bail
                // before the walk. Only ever one is queued.
                if widgetSampleTimer == nil {
                    widgetSampleTimer = Timer.scheduledTimer(withTimeInterval: widgetSampleGap - since,
                                                             repeats: false) { [weak self] _ in
                        self?.widgetSampleTimer = nil
                        self?.writeWidgetSummary()
                    }
                }
                return
            }
        }
        widgetSampleTimer?.invalidate(); widgetSampleTimer = nil   // this pass supersedes any queued one
        lastWidgetSample = Date()
        let day = widgetDayIndex
        // Calendar, not day*86400 minus the CURRENT UTC offset. That arithmetic used today's offset
        // for every row, so on a DST changeover the boundary moved an hour and rows either side were
        // counted into the wrong day. It also had no upper bound, so a row stamped in the future
        // counted as today's. Android windows this as the half-open [midnight, next midnight) via
        // LocalDate.atStartOfDay (AcabBleManager.updateWidget), and the two apps have to agree or
        // the same drive prints a different headline on each phone.
        let cal = Calendar.current
        let startOfTodayDate = cal.startOfDay(for: Date())
        let startOfToday = startOfTodayDate.timeIntervalSince1970
        let endOfToday = (cal.date(byAdding: .day, value: 1, to: startOfTodayDate)
                          ?? startOfTodayDate.addingTimeInterval(86400)).timeIntervalSince1970
        // Today's count = distinct detections first heard today (local). Naturally resets at
        // local midnight.
        // The old comment claimed this "skips replayed-approx history (its synthetic time sits near
        // epoch)". That stopped being true the moment bracketing moved those rows OFF the epoch onto
        // a plausible ordering key: a bracket straddling local midnight would now silently count a
        // row we explicitly cannot date to today. Exclude anything whose instant is not measured.
        // Per-category counts come out of this SAME loop, and are therefore also TODAY-scoped.
        // That is deliberate: the widget's headline number is today's count, so a breakdown taken
        // from the whole-store liveCounts could overshoot it and would read as a bug. These use
        // the same hidesInstant gate, so an undateable row is excluded from both the total and the
        // categories rather than being counted in one and not the other.
        //
        // widgetCategoryKey is NOT that same kind of gate, and it belongs on the buckets alone.
        // hidesInstant drops a row from both sides because we cannot place it in TODAY at all; a
        // .nearbyDevice (Desert's firehose), .watched or .unknown row is dated perfectly well, it
        // just has no strip glyph to draw it with. Gating the headline on it made the glance
        // contradict itself in the mode that produces the most hits: Desert's catch-all files
        // nearly everything as .nearbyDevice, so the face rendered a dimmed "0" over "today"
        // directly above a live "Nearby Device 12s ago", and a starred device firing read
        // "0 today" beside "Watched device 1m ago". A muted row is one the user asked us to drop;
        // a watched row is one the user asked us to shout about, and neither it nor an ambient row
        // may be quietly subtracted from the only running total this product puts on a home screen.
        //
        // So: the headline counts EVERY projected row first heard today whose instant we measured,
        // whatever its type, and the six buckets are a named breakdown of the part of that total
        // the widget has a glyph for. The strip can sum to LESS than the number above it (never
        // more), which reads as "412 today, 3 of them ALPR" rather than as a lost count.
        // Android twin: the same loop in AcabBleManager.updateWidget. The two apps have to answer
        // this identically or the same drive prints a different headline on each phone.
        var todayCount = 0
        var cat: [String: Int] = [:]
        let muted = activeIgnoredMacSet
        for (id, first) in firstSeenAt
        where first.timeIntervalSince1970 >= startOfToday && first.timeIntervalSince1970 < endOfToday {
            if timeBasis(for: id, stamp: first).hidesInstant { continue }
            guard let row = store[id],
                  activeProjectionIncludes(loweredMac: row.loweredMac,
                      isCurrentlyWatched: watchedMacSet.contains(row.loweredMac),
                      activeIgnoredMacs: muted) else { continue }
            todayCount += 1
            if let key = row.type.widgetCategoryKey { cat[key, default: 0] += 1 }
        }
        // Last detection = the most recent row (detections is already sorted newest-first).
        // TimeBasis does NOT cross the App Group boundary, and the widget renders w_lastAt with
        // Text(_, style: .relative), which can only say "X ago". There is no way to render "we
        // cannot date this" through that API, so a bracketed or unknown row must never become
        // w_lastAt: it would print a confident "3h ago" for an instant nothing measured. Pick the
        // newest row that actually HAS a measured instant instead, and if there is none, leave the
        // slot empty so the widget falls back to its no-recent-detection state.
        var lastType = ""
        var lastAt = 0.0
        if let latest = detections.first(where: { !timeBasis(for: $0.id, stamp: lastSeen[$0.id]).hidesInstant }),
           let seen = lastSeen[latest.id] {
            lastType = latest.type.label
            lastAt = seen.timeIntervalSince1970
        }
        let connected = connectionState == .connected || demoMode
        // Today's breakdown for the medium face. One key per category rather than a dictionary,
        // because UserDefaults across an App Group is happiest with plain scalars and the widget
        // reads them individually anyway. Keys match DeviceType.widgetCategoryKey.
        let catCounts = WidgetCategory.allCases.map { cat[$0.rawValue] ?? 0 }
        // Snapshot FIRST, then decide. Its fields are exactly the eleven values written below, so
        // an unchanged snapshot proves every stored value is already current and every write would
        // be a no-op - the writes used to go out unconditionally and only the reload was gated.
        // The reload gate itself is unchanged and is the important one: reloading for identical
        // data is what used to exhaust WidgetKit's budget and freeze the glance until the widget
        // was removed and re-added.
        let snapshot = WidgetSummarySnapshot(day: day, count: todayCount, lastType: lastType,
                                             lastAt: lastAt, connected: connected, cats: catCounts)
        guard force || snapshot != lastWidgetSnapshot else { return }
        lastWidgetSnapshot = snapshot
        d.set(todayCount, forKey: "w_countToday")
        d.set(day,        forKey: "w_day")
        d.set(lastType,   forKey: "w_lastType")
        d.set(lastAt,     forKey: "w_lastAt")
        d.set(connected,  forKey: "w_connected")
        for (c, n) in zip(WidgetCategory.allCases, catCounts) { d.set(n, forKey: c.defaultsKey) }
        reloadWidgetSoon(force: force)
    }

    /// Ask WidgetKit to refresh, at most once per `widgetReloadMinGap`. A change that lands inside
    /// the current window is not dropped: it arms a single trailing reload for the end of the
    /// window, so the glance catches up within the gap instead of waiting on the 15-minute
    /// backstop. Only ever one trailing reload is queued.
    private func reloadWidgetSoon(force: Bool) {
        let since = Date().timeIntervalSince(lastWidgetReload)
        if force || since >= widgetReloadMinGap {
            widgetReloadTimer?.invalidate(); widgetReloadTimer = nil
            lastWidgetReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        } else if widgetReloadTimer == nil {
            widgetReloadTimer = Timer.scheduledTimer(withTimeInterval: widgetReloadMinGap - since,
                                                     repeats: false) { [weak self] _ in
                self?.widgetReloadTimer = nil
                self?.lastWidgetReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// A drone's accumulated flight path (empty for everything else).
    func track(for id: String) -> [CLLocationCoordinate2D] { trackHistory[id] ?? [] }

    /// A tracker's accumulated breadcrumb trail - the phone's path while it stayed with us
    /// (empty for everything else).
    func crumbTrail(for id: String) -> [CLLocationCoordinate2D] { crumbHistory[id] ?? [] }

    /// When this device's most recent crumb was dropped, i.e. the END of its crumb window.
    /// Read-only, added for FollowEvidence and nothing else: the follow score needs the close of
    /// the window, and lastSeen is the wrong stamp for it (a tag heard once more from a parked
    /// phone advances lastSeen without adding a crumb, which would stretch the duration in the
    /// sentence past the ground the crumbs actually cover). Mirrors Android's lastCrumbAt(id).
    func lastCrumbAt(for id: String) -> Date? { lastCrumbAt[id] }

    /// When this device's FIRST crumb was dropped, i.e. the START of its crumb window.
    /// The follow scorer's other stamp, and deliberately NOT firstSeenDate(for:): that one is when
    /// the device was first HEARD, it survives app restarts, and the crumbs do not, so scoring
    /// between them measured a window the trail never covered. Mirrors Android's firstCrumbAt(id).
    func firstCrumbAt(for id: String) -> Date? { firstCrumbAt[id] }

    /// Whether location is authorized at all, which is the difference between "we looked and saw
    /// nothing move" and "we were never watching". Only the follow panel asks, and only to pick
    /// which empty state to print: an unexplained blank there reads as a clean bill of health.
    /// Reading authorizationStatus does not prompt and does not start the radio.
    var locationAuthorized: Bool {
        switch locationAuthorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// True when the user (or MDM) has explicitly shut location off - the map's "permission is
    /// off" empty state, which needs an Open Settings pointer. Distinct from .notDetermined,
    /// where the honest message is "nothing located yet", not "you turned this off".
    /// Reading authorizationStatus does not prompt and does not start the radio.
    var locationDenied: Bool {
        switch locationAuthorizationStatus {
        case .denied, .restricted: return true
        default: return false
        }
    }

    var locationRestricted: Bool { locationAuthorizationStatus == .restricted }
    var bluetoothRestricted: Bool { CBManager.authorization == .restricted }

    /// Phone's last known coordinate - used to center the no-GPS RSSI ring. Falls back to
    /// CoreLocation's cached fix, so browsing history while disconnected still has a center now
    /// that we don't keep location running when nothing needs it. Reading the cache costs no radio.
    var selfCoord: CLLocationCoordinate2D? { lastCoord ?? locationManager.location?.coordinate }

    /// Fresh, authorized phone position for actions that claim to happen "here". Unlike
    /// `selfCoord`, this never falls back to Core Location's undated cache and is therefore the
    /// only coordinate place-mute creation/evaluation may use.
    var currentLocationCoord: CLLocationCoordinate2D? { freshHereCoord }

    /// Board-backed mutes whose identities are unavailable on this phone (normally created from
    /// another phone). STATUS exposes only the total, so this is disclosure rather than editable
    /// synthetic rows.
    var boardOnlyMuteCount: Int {
        unrepresentedBoardRuleCount(boardCount: status?.ignoreCount ?? 0,
                                    localBoardBackedCount: boardIgnoredMacs.count)
    }

    // MARK: - Location gating
    //
    // Location is only ever used on-device to stamp detections and center the map, so it must run
    // only while something actually needs it. It used to start from the authorization callback,
    // which CoreLocation fires as soon as the delegate is assigned in init(), so an authorized
    // install began continuous background location on cold launch before the user touched
    // anything, and nothing ever stopped it: the blue indicator stayed lit and the process could
    // never suspend. Disconnected it wasn't even doing anything, sendPhoneLocation() bails without
    // a configChar.

    /// True while the phone's position is genuinely needed: a live board whose detections we
    /// stamp, Drive mode (whose background residency depends on location updates), or the tour's
    /// map centering.
    private var needsLocation: Bool {
        connectionState == .connected || driveModeOn || demoMode
    }

    private func updateLocationDesiredAccuracy() {
        let needsHereAccuracy = awaitingHereFix || ignored.contains(where: \.isPlaceScoped)
        locationManager.desiredAccuracy = needsHereAccuracy
            ? kCLLocationAccuracyNearestTenMeters
            : kCLLocationAccuracyHundredMeters
    }

    /// Start location if something needs it and we're allowed. Background updates are only ever
    /// enabled here, i.e. only while needed.
    private func startLocationIfNeeded() {
        guard needsLocation else { return }
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: break
        default: return
        }
        locationManager.allowsBackgroundLocationUpdates = true   // keep tagging if the app is backgrounded mid-drive
        locationManager.startUpdatingLocation()
    }

    /// Stop location once nothing needs it. Re-checks needsLocation rather than stopping outright:
    /// a dropout mid-drive must NOT kill the updates, they're what keeps the process alive so
    /// Drive mode survives the gap and willTerminate can still end the Live Activity.
    private func stopLocationIfIdle() {
        guard !needsLocation else { return }
        locationManager.stopUpdatingLocation()
        locationManager.allowsBackgroundLocationUpdates = false
    }

    // MARK: - Whitelist (ignored devices)

    /// Drop EVERY per-id side map for one detection - the same eleven maps the cap eviction in
    /// publishDetections clears. Any teardown that removes a row by id must go through this:
    /// clearing only store + lastSeen left firstSeenAt (and friends) populated, which kept
    /// inflating the widget's today count for an ignored device, resumed a stale breadcrumb
    /// trail and closest-approach pin after an unignore, and let RSSI smoothing ride a window
    /// from before the mute. Mirrors Android's perDeviceMaps + evictKey.
    private func evictKey(_ id: String) {
        store[id] = nil; lastSeen[id] = nil; rssiHistory[id] = nil
        trackHistory[id] = nil; firstSeenAt[id] = nil; capturedLoc[id] = nil
        bestRssi[id] = nil; crumbHistory[id] = nil
        lastCrumbAt[id] = nil; firstCrumbAt[id] = nil   // both crumb stamps die with the crumbs
        histBasis[id] = nil
    }

    /// Fresh policy for ONE rule, read at call time - expiry, place radius, and fix age all
    /// checked NOW. The dossier renders this directly (mirroring Android's muteRuleStatus):
    /// deriving its headline from the 60 s-cached activeIgnoredMacSet let it claim
    /// MUTED-WITHIN-50-M for up to a minute after the HERE fix aged out. The cached set stays
    /// the per-packet hot-path filter; this is presentation-rate only.
    func muteRuleStatus(for item: IgnoredDevice, now: Date = .now) -> MuteRuleStatus {
        let here = item.isPlaceScoped
            ? currentLocationCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            : nil
        return evaluateMuteRule(item, now: now, here: here)
    }

    private func rebuildActiveIgnoredMacSet(now: Date = .now) {
        // Snapshot the fix once for the whole projection (mirrors Android's activeIgnoredMacs):
        // reading currentLocationCoord per rule re-ran the freshHereCoord validity/accuracy
        // chain and allocated a fresh "here" CLLocation for every place rule on every rebuild.
        let here = ignored.contains(where: \.isPlaceScoped)
            ? currentLocationCoord.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            : nil
        activeIgnoredMacSet = Set(ignored.lazy.filter { evaluateMuteRule($0, now: now, here: here) == .active }
            .map { $0.mac.lowercased() })
    }

    private var boardIgnoredMacs: [String] { ignored.filter(isBoardBackedMute).map(\.mac) }
    private var boardIgnoredMacSet: Set<String> { Set(boardIgnoredMacs) }

    func isIgnored(_ mac: String) -> Bool {
        activeIgnoredMacSet.contains(mac.lowercased())
    }

    /// Silence a device locally; permanent scope is also persisted on the board.
    /// Ignoring and watching are mutually exclusive, so this also un-stars the MAC.
    /// Capped at the firmware's 256 like the bulk path: the board truncates the list, so a 257th
    /// entry would sit in the app looking silenced while the board kept alerting on it.
    ///
    /// Returns false for THREE reasons and the caller can only tell two of them apart: the list is
    /// already full and the device was NOT ignored; a `.here` scope with no fix to anchor it; or a
    /// MAC the board could never store (see isBoardPushableMac). DetectionDetailView's mute sheet
    /// has a two-branch else, so that third case shows the "the muted-device list is full" copy and
    /// an instruction that can never help. Unreachable from genuine hardware - only a spoofed or
    /// non-conforming peer advertises a MAC of that shape - and fixing it properly means a third
    /// message in that sheet, not a change here. Android's ignoreDevice carries the same three
    /// reasons and the same caller gap.
    @discardableResult
    func ignoreDevice(_ d: Detection, scope: MuteScope = .permanent) -> Bool {
        let mac = d.mac.lowercased()
        // Same guard the batch path applies, on the shape the board can actually store. A blank or
        // malformed MAC would become a rule the app shows as muted while parseMac6 drops it, so the
        // board keeps alerting on the device and its count can never match ours again.
        guard isBoardPushableMac(mac) else { return false }
        let previousBoardMacs = boardIgnoredMacSet
        let here = currentLocationCoord
        if scope == .here, here == nil { return false }
        let index = ignored.firstIndex { $0.mac == mac }
        guard index != nil || ignored.count < 256 else { return false }
        let prior = index.map { ignored[$0] }
        let replacement = IgnoredDevice(
            mac: mac, label: prior?.label.isEmpty == false ? prior!.label : d.displayName,
            expiresAt: scope == .oneHour ? .now.addingTimeInterval(3600) :
                (scope == .oneDay ? .now.addingTimeInterval(86_400) : nil),
            latitude: scope == .here ? here?.latitude : nil,
            longitude: scope == .here ? here?.longitude : nil,
            radiusMeters: scope == .here ? 50 : nil
        )
        let wasWatched = isWatched(mac)
        guard prior != replacement || wasWatched else { return true }   // already has this rule
        watched.removeAll { $0.mac == mac }
        if let index { ignored[index] = replacement } else { ignored.append(replacement) }
        persistIgnored(); syncIgnoreListIfChanged(from: previousBoardMacs)
        if wasWatched { persistWatched(); sendWatchList() }
        // Preserve the sealed evidence row. publishDetections() filters active rules from the
        // visible feed and reveals the row again after a timed/HERE rule ends.
        publishDetections()
        return true
    }

    /// Silence several devices at once (the Logbook's select mode). One ignore-list
    /// push and one republish instead of one per row. The firmware accepts up to 256
    /// entries, so we cap the list there.
    ///
    /// A MAC the board could never store (isBoardPushableMac) IS counted in the return, because a
    /// row the board cannot parse ends up muted nowhere. That shares the return's wording with the
    /// list-full case, which stays a known gap. Same spoofed/non-conforming-peer envelope as
    /// ignoreDevice's third false, and the honest repair is a second reason in the caller's message
    /// rather than a bigger number out of here: today every unit of this return is worded as "the
    /// muted-device list is full". Android twin: AcabBleManager.ignoreDevices, same rule and same
    /// wording gap.
    @discardableResult
    func ignoreDevices(_ list: [Detection]) -> Int {
        let previousBoardMacs = boardIgnoredMacSet
        // Mutate local copies, not the @Published arrays: every element-wise write fires
        // didSet (DeviceNames rebuild, active-set rebuild, accuracy update, SwiftUI
        // invalidation), so a select-all bulk mute would run hundreds of O(n) rebuilds
        // on the main thread. One assignment per array fires each observer exactly once.
        var newIgnored = ignored
        var newWatched = watched
        var changed = false
        var unstarred = false
        var refused = 0
        var accepted = Set<String>()
        var attempted = Set<String>()
        for d in list {
            let mac = d.mac.lowercased()
            // Full board shape, not merely non-empty: a MAC parseMac6 rejects would sit in the app
            // looking silenced while the board kept alerting on it, and would pin the ignore
            // re-push loop at a count the two sides can never agree on.
            // Dedupe FIRST so one device listed twice cannot be refused twice, then count a
            // shape refusal. Dropping it silently made the Logbook's `requested - refused` tally
            // report a device as muted that is muted NOWHERE - not on the board, which cannot
            // parse the MAC, and not usefully in the app, which would show a rule the board never
            // took. Android twin: the same two lines in AcabBleManager.ignoreDevices.
            guard attempted.insert(mac).inserted else { continue }
            guard isBoardPushableMac(mac) else { refused += 1; continue }
            if let index = newIgnored.firstIndex(where: { $0.mac == mac }) {
                accepted.insert(mac)
                if !isBoardBackedMute(newIgnored[index]) {
                    newIgnored[index].expiresAt = nil
                    newIgnored[index].latitude = nil
                    newIgnored[index].longitude = nil
                    newIgnored[index].radiusMeters = nil
                    changed = true
                }
                continue
            }
            guard newIgnored.count < 256 else { refused += 1; continue }
            accepted.insert(mac)
            if isWatched(mac) { newWatched.removeAll { $0.mac == mac }; unstarred = true }
            newIgnored.append(IgnoredDevice(mac: mac, label: d.displayName, expiresAt: nil,
                                            latitude: nil, longitude: nil, radiusMeters: nil))
            changed = true
        }
        if newWatched.contains(where: { accepted.contains($0.mac) }) {
            newWatched.removeAll { accepted.contains($0.mac) }
            unstarred = true
        }
        if unstarred { watched = newWatched }
        if changed { ignored = newIgnored }
        if changed { persistIgnored(); syncIgnoreListIfChanged(from: previousBoardMacs) }
        if unstarred { persistWatched(); sendWatchList() }
        if changed || unstarred { publishDetections() }
        return refused
    }

    /// Un-silence a device.
    func unignore(_ mac: String) {
        let previousBoardMacs = boardIgnoredMacSet
        let oldCount = ignored.count
        ignored.removeAll { $0.mac == mac.lowercased() }
        guard ignored.count != oldCount else { return }
        persistIgnored(); syncIgnoreListIfChanged(from: previousBoardMacs)
        publishDetections()
    }

    private func pruneExpiredMutes() {
        let previousBoardMacs = boardIgnoredMacSet
        let kept = ignored.filter { $0.expiresAt.map { $0 > .now } ?? true }
        guard kept.count != ignored.count else { return }
        ignored = kept
        persistIgnored(); syncIgnoreListIfChanged(from: previousBoardMacs)
        publishDetections()
    }

    /// Timed rules and coordinate freshness change with the clock even when no BLE or GPS event
    /// arrives. Re-evaluate once a minute so a HERE rule whose last fix ages out reveals retained
    /// evidence promptly instead of waiting for an unrelated detection to republish the feed.
    private func refreshMutePolicy() {
        pruneExpiredMutes()
        rebuildActiveIgnoredMacSet()
        if activeIgnoredMacSet != publishedActiveIgnoredMacs { publishDetections() }
    }

    // MARK: - Watchlist (starred devices)

    /// Is this MAC starred?
    func isWatched(_ mac: String) -> Bool { watchedMacSet.contains(mac.lowercased()) }

    /// Star a device: the board alerts on this exact MAC every time it's seen, even
    /// with no signature match. Watching and ignoring are mutually exclusive, so this
    /// also removes the MAC from the ignore list (the scan path drops ignored MACs
    /// before classification, so a starred MAC must not also be silenced).
    func watchDevice(_ d: Detection) {
        let mac = d.mac.lowercased()
        // Same shape guard as the ignore paths: a star the board's parser drops leaves the app
        // claiming a watch the board never took, and "wat" diverged for the session.
        guard isBoardPushableMac(mac), !isWatched(mac) else { return }
        let previousBoardMacs = boardIgnoredMacSet
        // At the firmware's 256 cap the board would truncate the list, so a 257th star would sit in
        // the app looking watched while the board never alerted on it. Refuse, but tell the user.
        guard watched.count < 256 else { watchlistFull = true; return }
        let wasIgnored = ignored.contains { $0.mac == mac }
        ignored.removeAll { $0.mac == mac }
        watched.append(WatchedDevice(mac: mac, label: d.displayName))
        persistWatched(); sendWatchList()
        if wasIgnored {
            persistIgnored(); syncIgnoreListIfChanged(from: previousBoardMacs)
            publishDetections()
        }
    }

    /// Un-star a device.
    func unwatch(_ mac: String) {
        watched.removeAll { $0.mac == mac.lowercased() }
        persistWatched(); sendWatchList()
    }

    /// Rename a starred device's label.
    /// Rename an ignored device. Same contract as renameWatched: an empty string is ignored so a
    /// cleared field can't blank the label and leave an unidentifiable row on the managed screen.
    func renameIgnored(_ mac: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = ignored.firstIndex(where: { $0.mac == mac.lowercased() }) else { return }
        ignored[i].label = trimmed
        persistIgnored()   // label is app-side only; the board only needs the MAC list
    }

    /// Rename a starred device. Trims and rejects an empty label, so clearing the field cannot
    /// blank the name and leave an unidentifiable row. renameIgnored's comment already claimed
    /// "same contract as renameWatched", but this side had neither the trim nor the guard, so a
    /// cleared field silently wiped the label and the log row fell back to the device class.
    func renameWatched(_ mac: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = mac.lowercased()
        guard !trimmed.isEmpty, let i = watched.firstIndex(where: { $0.mac == m }) else { return }
        watched[i].label = trimmed
        persistWatched()   // label is app-side only; the board only needs the MAC list
    }

    private func loadWatched() {
        if let url = watchURL, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([WatchedDevice].self, from: data) {
            watched = list
            reconcileLegacyAfterProtectedLoad(list, to: url, kind: .watched,
                                               legacyKey: watchKey)
            return
        }
        // one-time migration off the old plaintext, backed-up UserDefaults store, then scrub it so
        // the tracked-gear MACs + names no longer sit unprotected in the app's defaults / backup.
        if let migration = migrateLegacyManagedList(
            [WatchedDevice].self,
            data: UserDefaults.standard.data(forKey: watchKey),
            persistProtected: { [weak self] list in
                self?.persistManagedList(list, to: self?.watchURL, kind: .watched) ?? false
            },
            removeLegacy: { UserDefaults.standard.removeObject(forKey: self.watchKey) }
        ) {
            watched = migration.value
            if !migration.protectedWriteSucceeded { pendingLegacyManagedLists.insert(.watched) }
        }
    }
    @discardableResult
    private func persistWatched(scheduleRetryOnFailure: Bool = true) -> Bool {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return true }
        return persistManagedList(watched, to: watchURL, kind: .watched,
                                  scheduleRetryOnFailure: scheduleRetryOnFailure)
    }
    /// Send the watch list to the board so it alerts on those MACs at the source. Same
    /// MAC string format as the ignore push, chunked the same way, debounced per key.
    /// USER-EDIT path only (see sendIgnoreList).
    private func sendWatchList() {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return }
        listPushAttempts["watch"] = 0   // user edit: re-arm the budget, as syncIgnoreListIfChanged does
        setListClearPending("watch", watched.isEmpty)   // tracks the edit; re-starring retires it
        scheduleListPush("watch")
    }

    // MARK: - Seen watermark ("mark all seen")

    /// Drop a "seen" baseline at now: everything currently in the log becomes "seen",
    /// and the New-only filter then shows only what arrives after this.
    func markAllSeen() {
        let now = Date()
        seenWatermark = now
        // Baseline the pseudo band too, on its stable axis: the highest buffer seq among the
        // still-.unknown rows is the most recent undateable record, so anything the board hands
        // us beyond it is New. Without this second baseline a post-mark drain of records nothing
        // can date (pre-boot-counter firmware, or a drain that never closes) could never surface
        // in the New-only filter again: pseudo stamps sit just above the epoch, forever below any
        // wall-clock watermark. Mirrors Android's approxWatermark.
        let maxUnknownSeq = histBasis.values.filter { $0.basis == .unknown }.map(\.seq).max() ?? 0
        if maxUnknownSeq > approxSeenSeq { approxSeenSeq = maxUnknownSeq }
        guard seenWatermarkWritesAllowed(isDemoMode: demoMode) else { return }
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: watermarkKey)
        UserDefaults.standard.set(Int(approxSeenSeq), forKey: approxSeenSeqKey)
    }

    /// First-run baseline for the New dots. The first time the log is ever opened, treat whatever
    /// is already stored as seen, so a fresh install (or a first offline backlog) does not paint a
    /// dot on every row. Once-only, guarded by a persisted flag; from then on the watermark
    /// advances each time the user leaves the Log tab (see MainTabView.onChange(of: tab)), so a New
    /// dot always means "arrived since you last looked". Mirrors Android's seedSeenWatermarkOnce.
    func seedSeenWatermarkOnce() {
        // The sample log gets its own transient baseline every time it is seeded. Do not read or
        // write the real once-only flag: doing so made merely browsing the tour mark retained
        // evidence as seen after exit.
        if demoMode {
            markAllSeen()
            return
        }
        guard !UserDefaults.standard.bool(forKey: seenWatermarkSeededKey) else { return }
        markAllSeen()
        UserDefaults.standard.set(true, forKey: seenWatermarkSeededKey)
    }

    /// Has this detection been seen yet? New means first heard after the watermark
    /// (or always New when no watermark is set).
    func isUnseen(_ d: Detection) -> Bool {
        guard let mark = seenWatermark else { return true }
        guard let first = firstSeenAt[d.id] else { return true }
        // Two axes, two baselines (mirrors Android's isNewSinceWatermark). Live stamps ascend
        // with the wall clock and compare against the date watermark. Pseudo-band stamps are
        // renumbered ordering keys (see resolveBracketedHistory), so recency there is judged on
        // the buffer seq underneath them: only a record buffered AFTER the mark reads as New.
        if first <= histPseudoBase {
            // A pre-basis legacy row carries no seq to order by; it can only have entered at
            // load time, so it was present when the user marked - call it seen.
            guard let h = histBasis[d.id] else { return false }
            return h.seq > approxSeenSeq
        }
        return first > mark
    }

    private func loadIgnored() {
        if let url = ignoreURL, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([IgnoredDevice].self, from: data) {
            ignored = list
            reconcileLegacyAfterProtectedLoad(list, to: url, kind: .ignored,
                                               legacyKey: ignoreKey)
            return
        }
        // one-time migration off the old plaintext, backed-up UserDefaults store, then scrub it.
        if let migration = migrateLegacyManagedList(
            [IgnoredDevice].self,
            data: UserDefaults.standard.data(forKey: ignoreKey),
            persistProtected: { [weak self] list in
                self?.persistManagedList(list, to: self?.ignoreURL, kind: .ignored) ?? false
            },
            removeLegacy: { UserDefaults.standard.removeObject(forKey: self.ignoreKey) }
        ) {
            ignored = migration.value
            if !migration.protectedWriteSucceeded { pendingLegacyManagedLists.insert(.ignored) }
        }
    }
    @discardableResult
    private func persistIgnored(scheduleRetryOnFailure: Bool = true) -> Bool {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return true }
        return persistManagedList(ignored, to: ignoreURL, kind: .ignored,
                                  scheduleRetryOnFailure: scheduleRetryOnFailure)
    }

    // MARK: whitelist / watchlist persistence (Application Support, file-protected)
    // The ignore + watch lists hold MACs plus the advertised NAMES of tracked surveillance gear,
    // so they get the same at-rest posture as the detections store: a completeFileProtection file
    // in Application Support, excluded from iCloud/iTunes backup. (Previously plaintext, backed-up
    // UserDefaults, readable while the phone was locked and copied into device backups.)
    private var ignoreURL: URL? { appSupportFile("acab-ignored.json") }
    private var watchURL: URL? { appSupportFile("acab-watched.json") }

    private func appSupportFile(_ name: String) -> URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent(name)
    }

    private func writeProtectedList<T: Encodable>(_ value: T, to url: URL?) -> Bool {
        performProtectedManagedListWrite(value, to: url) { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            var u = url
            try u.setResourceValues(v)
        }
    }

    /// Complete an interrupted migration whose protected JSON landed but whose backup exclusion did
    /// not. The loaded protected value is authoritative; the legacy copy is only a privacy fallback.
    /// Re-writing through writeProtectedList reasserts BOTH complete protection and exclusion after
    /// the atomic replacement, and the helper removes UserDefaults only after that full operation.
    private func reconcileLegacyAfterProtectedLoad<T: Encodable>(
        _ value: T, to url: URL, kind: ManagedListKind, legacyKey: String
    ) {
        let legacyPresent = UserDefaults.standard.object(forKey: legacyKey) != nil
        guard legacyPresent else { return }
        pendingLegacyManagedLists.insert(kind)
        _ = reconcileLegacyManagedListAfterProtectedLoad(
            value, legacyPresent: true,
            persistProtected: { [weak self] value in
                self?.persistManagedList(value, to: url, kind: kind,
                                         scrubPendingLegacyOnSuccess: false) ?? false
            },
            removeLegacy: { [weak self] in
                UserDefaults.standard.removeObject(forKey: legacyKey)
                self?.pendingLegacyManagedLists.remove(kind)
            })
    }

    @discardableResult
    private func persistManagedList<T: Encodable>(
        _ value: T, to url: URL?, kind: ManagedListKind,
        scheduleRetryOnFailure: Bool = true,
        scrubPendingLegacyOnSuccess: Bool = true
    ) -> Bool {
        let saved = writeProtectedList(value, to: url)
        managedListPersistenceState.record(kind, succeeded: saved)
        managedListSavePending = managedListPersistenceState.hasPendingWrites
        if saved {
            // A migration fallback is privacy-sensitive but also the only durable copy after a
            // failed first write. Scrub it at the first later success, never earlier.
            if scrubPendingLegacyOnSuccess,
               pendingLegacyManagedLists.remove(kind) != nil {
                let key = kind == .watched ? watchKey : ignoreKey
                UserDefaults.standard.removeObject(forKey: key)
            }
            if !managedListSavePending {
                managedListRetryTimer?.invalidate()
                managedListRetryTimer = nil
                managedListPersistenceError = nil
            }
        } else {
            managedListPersistenceError = "The change is active for this session but has not been saved to protected storage. The app will retry shortly and whenever it returns to the foreground."
            if scheduleRetryOnFailure { scheduleManagedListPersistenceRetry() }
        }
        return saved
    }

    private func scheduleManagedListPersistenceRetry() {
        guard managedListRetryTimer == nil else { return }
        managedListRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) {
            [weak self] _ in
            self?.managedListRetryTimer = nil
            self?.retryManagedListPersistence()
        }
    }

    /// Retry once per failure plus on foreground/manual request. A persistent disk-full/protection
    /// failure must stay visible, but should not wake the process in an unbounded timer loop.
    func retryManagedListPersistence() {
        managedListRetryTimer?.invalidate()
        managedListRetryTimer = nil
        if managedListPersistenceState.needsRetry(.ignored) {
            persistIgnored(scheduleRetryOnFailure: false)
        }
        if managedListPersistenceState.needsRetry(.watched) {
            persistWatched(scheduleRetryOnFailure: false)
        }
    }

    func dismissManagedListPersistenceError() {
        managedListPersistenceError = nil
    }
    /// Persisted USER-EDIT path. A scoped-only edit does not change the board-backed projection,
    /// so it must not send an empty replacement or create a clear-pending flag. That preserves
    /// permanent board mutes owned by another phone while timed/HERE rules stay local.
    private func syncIgnoreListIfChanged(from previousBoardMacs: Set<String>) {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return }
        let currentBoardMacs = boardIgnoredMacSet
        guard currentBoardMacs != previousBoardMacs else { return }
        // A real change to the list the board holds re-arms the reconciler's budget: the divergence
        // it gave up on was about the OLD list, and this push is not the reconciler spending from
        // it. Android twin: sendIgnoreList's `if (userEdit) ignorePushAttempts = 0`.
        listPushAttempts["ignore"] = 0
        setListClearPending("ignore", currentBoardMacs.isEmpty)
        scheduleListPush("ignore")
    }

    /// Whether the last user edit on `key` emptied the list and we have not yet delivered that
    /// clear to a board. Persisted, because the edit can happen while disconnected and the board
    /// must still learn about it on the next connect.
    private func listClearPending(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: "acab.\(key).clearPending")
    }
    private func setListClearPending(_ key: String, _ pending: Bool) {
        UserDefaults.standard.set(pending, forKey: "acab.\(key).clearPending")
    }

    /// Re-state both lists to a freshly connected board.
    ///
    /// Skips a list we have nothing to say about. Pushing an EMPTY list unconditionally is how a
    /// fresh install (or any second phone that had never starred anything) silently wiped every
    /// star on a board the instant it connected: the push committed an empty list and the board
    /// rewrote its NVS. An empty list is only worth sending when the user actually emptied it,
    /// which is what the persisted clear-pending flag records. The firmware refuses a bare empty
    /// commit as well (it requires "clr"), so this is belt and braces, not the only guard.
    private func resyncListsOnConnect() {
        switch boardListSyncAction(localCount: min(boardIgnoredMacs.count, 256), boardCount: nil,
                                   clearPending: listClearPending("ignore")) {
        case .pushList, .pushClear: sendIgnoreListResync()
        case .none, .acknowledgeClear: break
        }
        switch boardListSyncAction(localCount: min(watched.count, 256), boardCount: nil,
                                   clearPending: listClearPending("watch")) {
        case .pushList, .pushClear: sendWatchListResync()
        case .none, .acknowledgeClear: break
        }
    }
    private func sendIgnoreListResync() { scheduleListPush("ignore") }
    private func sendWatchListResync()  { scheduleListPush("watch") }

    // Star/ignore pushes are debounced per list key: every toggle resends the ENTIRE list
    // (13 chunked write-with-response writes at a full 256 entries), so rapid taps queued
    // seconds of serialized GATT traffic ahead of every other config write - volume,
    // detector toggles, GPS uplink - plus an NVS rewrite per committed list on the board.
    // Each push is a full-list replacement (last one wins) and both lists are re-pushed on
    // every connect, so trailing-edge coalescing is lossless.
    private var listPushTimers: [String: Timer] = [:]
    private var lastListPush: [String: Date] = [:]
    private let listPushInterval: TimeInterval = 1.0

    /// Full-list re-pushes the STATUS reconciler may spend on ONE divergence, per key, before it
    /// gives up on this connection. Reset on a fresh link and on any user edit, so only a
    /// divergence the board can never resolve runs the budget out. Android twin:
    /// ignorePushAttempts / watchPushAttempts and MAX_LIST_PUSH_ATTEMPTS in AcabBleManager.
    private var listPushAttempts: [String: Int] = [:]
    private static let maxListPushAttempts = 3

    /// Leading edge + trailing coalesce, per key: a single tap (and the connect-time
    /// re-push) still goes out immediately; spam collapses into one trailing send that
    /// reads the list's LATEST contents when it fires.
    private func scheduleListPush(_ key: String) {
        guard listPushTimers[key] == nil else { return }   // a trailing push is already queued
        let elapsed = Date().timeIntervalSince(lastListPush[key] ?? .distantPast)
        if elapsed >= listPushInterval {
            pushMacList(key)
        } else {
            listPushTimers[key] = Timer.scheduledTimer(withTimeInterval: listPushInterval - elapsed,
                                                       repeats: false) { [weak self] _ in
                self?.listPushTimers[key] = nil
                self?.pushMacList(key)
            }
        }
    }

    private func pushMacList(_ key: String) {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return }
        lastListPush[key] = Date()
        let macs = (key == "watch") ? watched.map({ $0.mac }) : boardIgnoredMacs
        sendMacList(key: key, macs: macs)
        // Do not retire an empty-list intent here. Enqueue/canWriteConfig proves only that a write
        // was attempted; reconcilePendingListClear waits for a later board STATUS count of zero.
    }

    private func reconcileBoardList(_ key: String, localCount: Int, boardCount: Int) {
        switch boardListSyncAction(localCount: min(localCount, 256), boardCount: boardCount,
                                   clearPending: listClearPending(key)) {
        case .none:
            listPushAttempts[key] = 0   // the board agrees: the next divergence gets a full budget
        case .pushList, .pushClear:
            // BOUNDED, like every other convergence loop in this file (reconcileBuzzer's fast
            // burst, handleHistEnd's histResyncCap). A count the board can never match - a MAC its
            // parseMac6 rejects, a list saved by an older build, a v1.7 board with no "watch"
            // handler that never reports "wat" - leaves the two sides permanently unequal, and the
            // commit chunk of every push we make sets the firmware's statusDirty, so the status
            // frame that comes back asks for the next push. The 1 s debounce below only paces that
            // loop, it does not end it: unbounded, this sent a full 13-chunk list push about once
            // a second for the whole session, on the serialized GATT queue ahead of every buzzer,
            // detector and GPS write, and rewrote the board's NVS on each committed round. Past
            // the cap, stop asking: the phone-side mute still holds (ingest drops muted MACs
            // itself) and the next connection or user edit re-arms the attempts. Android twin: the
            // MAX_LIST_PUSH_ATTEMPTS gate in the STATUS branch of AcabBleManager.ingest.
            let spent = listPushAttempts[key] ?? 0
            guard spent < Self.maxListPushAttempts else { return }
            listPushAttempts[key] = spent + 1
            scheduleListPush(key)
        case .acknowledgeClear:
            listPushAttempts[key] = 0   // the board just proved it took the clear
            setListClearPending(key, false)
        }
    }

    /// CoreBluetooth does not echo the payload in didWriteValueFor, so a failed Config response
    /// cannot be attributed to one chunk. Re-arm each authoritative managed list; the debounce
    /// coalesces duplicates and the next STATUS count terminates reconciliation.
    private func retryManagedListsAfterConfigWriteFailure() {
        guard managedListWritesAllowed(isDemoMode: demoMode) else { return }
        if !boardIgnoredMacs.isEmpty || listClearPending("ignore") { scheduleListPush("ignore") }
        if !watched.isEmpty || listClearPending("watch") { scheduleListPush("watch") }
    }

    /// Push a MAC list to the board under `key` ("ignore" or "watch"), split into chunks of
    /// at most 20 MACs so even a full 256-entry list stays well under the 512 B ATT write
    /// cap. Every chunk except the last carries "more":true, which the firmware STAGES
    /// (appends without committing); the final chunk omits "more" so the firmware appends
    /// then COMMITS the whole staged list. A list of <=20 sends as a single write with no
    /// "more" (unchanged behavior), and an empty list sends one bare write that commits an
    /// empty list (clears it on the board). Writes go out write-with-response, so the chunks
    /// arrive in order.
    private func sendMacList(key: String, macs: [String]) {
        let chunkSize = 20
        // "clr" marks an empty list as a DELIBERATE clear. Firmware refuses a bare empty commit
        // and keeps whatever it had, so this flag is what makes "unstar the last device" work.
        guard macs.count > chunkSize else {
            var cfg: [String: Any] = [key: macs]
            if macs.isEmpty { cfg["clr"] = true }
            writeConfig(cfg)
            return
        }
        var i = 0
        while i < macs.count {
            let end = min(i + chunkSize, macs.count)
            var cfg: [String: Any] = [key: Array(macs[i..<end])]
            if end < macs.count { cfg["more"] = true }   // non-final chunk: stage, don't commit
            writeConfig(cfg)
            i = end
        }
    }

    /// Push the store into the published feed immediately. Recomputes the per-category
    /// counts (O(store), needed for the Live Activity), sorts most-recent-first, and
    /// caps the array so a huge Desert-mode store doesn't hand SwiftUI thousands of rows.
    private func publishDetections() {
        publishTimer?.invalidate()
        publishTimer = nil
        lastPublish = Date()

        // Mirror the drain tally here, at the coalesced cadence (ingest schedules a publish
        // for every history record): writing this @Published counter per record defeated the
        // 3 Hz ceiling and re-rendered every mounted tab once per replayed record.
        if offlineSyncCount != histReceived { offlineSyncCount = histReceived }

        // Newest-first on lastSeen. A bracketed row's lastSeen is the ordering key
        // resolveBracketedHistory() derived from the boots on either side of it, so it lands
        // between them instead of at the epoch; only a row nothing could bound still sorts down
        // in the pseudo-time band. Neither is ever rendered as a time (see timeBasis).
        // Decorate-sort-undecorate. The old comparator resolved lastSeen through a String-keyed
        // dictionary INSIDE the comparison, so a 5,000-row sort paid ~123,000 hashed lookups per
        // publish, three times a second, on main. Resolving each key once first makes it 5,000
        // lookups and leaves the sort comparing plain Doubles.
        let sorted = store.values
            .map { (d: $0, t: (lastSeen[$0.id] ?? .distantPast).timeIntervalSinceReferenceDate) }
            .sorted { $0.t > $1.t }
            .map(\.d)
        // Rolling cap on the backing store too, so a long Desert-mode session can't grow
        // memory without bound (parity with Android's STORE_CAP). Priority-aware eviction:
        // an airport-density flood of confidence-0 "nearby device" rows must never push a
        // real flag (tracker, body cam, drone, glasses, or a starred/watched device) out of
        // the store. Drop the oldest ambient rows first; only if the store is somehow all
        // flags past the cap do we fall back to dropping the oldest flags too.
        var logRows = sorted
        if sorted.count > liveFeedCap {
            let overflow = sorted.count - liveFeedCap
            let oldestFirst = Array(sorted.reversed())
            var evict: [Detection] = []
            for d in oldestFirst where d.type == .nearbyDevice {
                if evict.count == overflow { break }
                evict.append(d)
            }
            if evict.count < overflow {                     // last resort: too many flags to fit
                for d in oldestFirst where d.type != .nearbyDevice {
                    if evict.count == overflow { break }
                    evict.append(d)
                }
            }
            for d in evict { evictKey(d.id) }   // the one full-teardown list, shared with the ignore paths
            let evictIds = Set(evict.map { $0.id })
            logRows = sorted.filter { !evictIds.contains($0.id) }
        }
        // Both @Published projections come from the same capped/sorted array. Log keeps the
        // evidence row; active surfaces receive the current mute-filtered subset.
        logDetections = logRows
        let muted = activeIgnoredMacSet
        publishedActiveIgnoredMacs = muted
        detections = logRows.filter {
            activeProjectionIncludes(loweredMac: $0.loweredMac,
                isCurrentlyWatched: watchedMacSet.contains($0.loweredMac),
                activeIgnoredMacs: muted)
        }
        let liveChanged = recomputeLiveCounts(now: lastPublish)
        writeWidgetSummary()   // mirror today's count + last detection to the home widget (reload throttled)
        if driveModeOn && liveChanged { liveActivity.update(liveState()) }
    }

    /// Coalesced republish for the hot path. Publishes at most once per
    /// `publishInterval`; rapid-fire notifies in between collapse into one trailing
    /// update, so a Desert-mode firehose updates the feed a few times a second instead
    /// of thrashing SwiftUI on every record.
    private func schedulePublish() {
        guard publishTimer == nil else { return }   // a trailing publish is already queued
        let elapsed = Date().timeIntervalSince(lastPublish)
        if elapsed >= publishInterval {
            publishDetections()
        } else {
            publishTimer = Timer.scheduledTimer(withTimeInterval: publishInterval - elapsed,
                                                repeats: false) { [weak self] _ in
                self?.publishTimer = nil
                self?.publishDetections()
            }
        }
    }

    /// The live row for an id, or nil once it's been evicted. Detection is a value type with
    /// let fields, so a captured copy can never update: screens that hold one (the detail
    /// dossier) must re-read through this. Dictionary-backed on purpose, a first-where scan
    /// over `detections` would be an O(store) String compare on the main thread per read.
    func detection(for id: String) -> Detection? { store[id] }

    /// Recent RSSI samples, oldest-first - feeds the detail sparkline.
    func rssiTrend(for id: String) -> [Int] { rssiHistory[id] ?? [] }

    /// Mean of the last 3 RSSI samples for `id`, the basis the closest-approach pin compares on.
    /// One raw sample can swing far enough on multipath alone to trip the 4 dB gate and yank the
    /// pin to a spot we were never closest at; three samples ride over that. Mirrors Android's
    /// `rssiHistory[id]?.takeLast(3)?.average()?.roundToInt() ?: d.rssi` so both platforms gate on
    /// the same quantity - including Kotlin roundToInt's ties-toward-positive-infinity, which
    /// Swift's .rounded() would take the other way on negative halves.
    private func smoothedRssi(for id: String, fallback: Int) -> Int {
        let recent = rssiHistory[id]?.suffix(3) ?? []
        guard !recent.isEmpty else { return fallback }
        return Int((Double(recent.reduce(0, +)) / Double(recent.count) + 0.5).rounded(.down))
    }

    /// True when `stamp` sits in ingestHistory's pseudo-time band rather than being a real clock
    /// reading. Superseded by timeBasis(for:stamp:), which knows the actual basis, and kept only
    /// as its fallback for rows checkpointed by a build that predates the basis model: those have
    /// nothing on disk except the band itself. Mirrors Android's isApproxTime.
    func isApproxTime(_ stamp: Date?) -> Bool {
        guard let stamp else { return false }
        return stamp <= histPseudoBase
    }

    /// When we first heard this detection, or nil if never.
    func firstSeenDate(for id: String) -> Date? { firstSeenAt[id] }

    /// When we last heard this detection, or nil if never.
    func lastSeenDate(for id: String) -> Date? { lastSeen[id] }

    /// Has this detection gone quiet? True if we've never heard it, or the last
    /// sighting is older than `seconds` ago. Staleness moves with the clock, not with any
    /// @Published state, so a view that must re-evaluate it on a timer passes its own tick
    /// as `asOf` to make that dependency explicit.
    func isStale(for id: String, olderThan seconds: TimeInterval = 45, asOf now: Date = Date()) -> Bool {
        lastSeenIsStale(lastSeen[id], now: now, window: seconds)
    }

    /// Where the phone was when we first heard this (the board has no GPS). Drones
    /// send their own position, but for Flock/Raven/Axon this is what pins them on
    /// the map. Nil if we had no location at first sighting.
    func capturedLocation(for id: String) -> CLLocationCoordinate2D? { capturedLoc[id] }

    // MARK: - Export

    /// Everything one CSV row reads, resolved on the MAIN thread: the timing/location
    /// dictionaries (and the isApproxTime verdict they feed) are main-confined, so the
    /// background CSV build must never touch them. Mirrors the StoredRow snapshot pattern.
    /// Internal (not private) so the export tests can build fixtures directly against the pure
    /// builders below, which is what makes the iOS/Android byte-parity assertions possible.
    struct CSVRowInput {
        let d: Detection
        let firstSeen: Date?
        let loc: CLLocationCoordinate2D?
        let basis: TimeBasis

        /// Standard log exports may fall back to a non-drone wire coordinate: for those rows the
        /// protocol defines `d.coordinate` as detector GPS. A bounded contribution must not. Its
        /// timestamp names one exact in-window sighting, so an older/session-wide coordinate would
        /// falsely claim to describe that sighting when no matching capture-local phone fix exists.
        let allowDetectionCoordinateFallback: Bool

        init(d: Detection, firstSeen: Date?, loc: CLLocationCoordinate2D?, basis: TimeBasis,
             allowDetectionCoordinateFallback: Bool = true) {
            self.d = d
            self.firstSeen = firstSeen
            self.loc = loc
            self.basis = basis
            self.allowDetectionCoordinateFallback = allowDetectionCoordinateFallback
        }
    }

    /// One immutable Log export view. `detections` is a coalesced SwiftUI projection and cannot
    /// define an evidence export: ingest can update `store` and its timing/location side tables
    /// before the next published frame. Capture every row and its NEW verdict together on the
    /// callback thread, then filter and render only this value.
    struct DetectionExportSnapshot {
        let rows: [CSVRowInput]
        let unseenIDs: Set<String>
        private let rowByID: [String: CSVRowInput]

        init(rows: [CSVRowInput], unseenIDs: Set<String>) {
            self.rows = rows
            self.unseenIDs = unseenIDs
            self.rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.d.id, $0) })
        }

        var detections: [Detection] { rows.map(\.d) }
        var ids: Set<String> { Set(rows.map { $0.d.id }) }

        func basis(for id: String) -> TimeBasis? {
            rowByID[id]?.basis
        }

        func filtered(category: String?, unseenOnly: Bool, offlineOnly: Bool) -> DetectionExportSnapshot {
            let kept = rows.filter { row in
                (category == nil || row.d.type.category == category)
                    && (!unseenOnly || unseenIDs.contains(row.d.id))
                    && (!offlineOnly || row.d.offline)
            }
            let keptIDs = Set(kept.map { $0.d.id })
            return DetectionExportSnapshot(rows: kept, unseenIDs: unseenIDs.intersection(keptIDs))
        }
    }

    /// Snapshot the authoritative Log plus every side-table field used by CSV/GPX. All BLE
    /// callbacks and UI actions arrive on the main queue, so this is one non-interleavable pass.
    func detectionExportSnapshot() -> DetectionExportSnapshot {
        let ordered = store.values
            .map { (d: $0, t: (lastSeen[$0.id] ?? .distantPast).timeIntervalSinceReferenceDate) }
            .sorted { $0.t > $1.t }
            .map(\.d)
        let rows = ordered.map { d in
            CSVRowInput(d: d, firstSeen: firstSeenAt[d.id], loc: capturedLoc[d.id],
                        basis: timeBasis(for: d.id))
        }
        return DetectionExportSnapshot(rows: rows,
                                       unseenIDs: Set(ordered.lazy.filter { self.isUnseen($0) }.map(\.id)))
    }

    /// CSV of the current log: when, what, and where for each detection. "Where" is
    /// your phone's position at first sighting (the board has no GPS), or blank if we
    /// had no location then. Pure function of the snapshot, safe to run off-main.
    static func buildCSV(_ snapshot: [CSVRowInput]) -> String {
        let fmt = ISO8601DateFormatter()
        // Milliseconds always printed (exactly 3 fractional digits, .000 when zero): the default
        // options never emit fractional seconds while Android's live rows carry real millis, so
        // the same log exported from the two phones differed byte-wise in the one file that gets
        // compared as evidence. Both platforms now write fixed 3-digit millis.
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // time_basis and time_precision_s sit immediately after detected_at because they qualify
        // it: a reader who takes detected_at without them is reading a derived time as a clock
        // reading, which is the misuse this export exists to prevent. Header must stay
        // byte-identical to Android's.
        // `maker` is appended LAST so an existing parser keyed on column order still reads every
        // field it knew about. Byte-identical to Android's, which is why it moves in the same
        // commit or not at all: the UI now names a manufacturer, and the evidence file has to be
        // able to say the same thing.
        // The header is ContributionCsv.detectionColumns, shared with the contribution redactor so
        // a rename can never leave a location column unblanked - the redactor now fails closed on
        // a policy column the header does not carry, and a hand-copied literal here was the drift
        // that would have tripped it. Android twin: detectionsCsv builds its header the same way,
        // out of DETECTION_CSV_COLUMNS.
        var rows = [ContributionCsv.detectionColumns.map(ContributionCsv.field).joined(separator: ",")]
        func f6(_ v: Double?) -> String { v.map { String(format: "%.6f", $0) } ?? "" }
        func iStr(_ v: Int?) -> String { v.map { "\($0)" } ?? "" }
        for r in snapshot {
            let d = r.d
            // detected_at holds an instant for a time we can state as one, and an ISO 8601
            // interval ("start/end") for a bracketed row, whose only honest answer is a range.
            // One-sided brackets write the open forms "start/" and "/end": ISO doesn't define
            // them, but a half-open range is what we actually know, and inventing the missing
            // endpoint would be worse. An unknown row leaves the column empty rather than
            // exporting the near-epoch pseudo stamp as a real 1969 date, in the one file that
            // gets handed over as evidence.
            // The basis is resolved per STAMP, not per row: a device replayed from the buffer and
            // THEN heard live keeps its buffered firstSeenAt while its store row becomes a live
            // one, so d.approx alone gets this wrong. Mirrors Android detectionsCsv.
            let when: String
            switch r.basis {
            case .exact, .reconstructed:
                when = r.firstSeen.map { fmt.string(from: $0) } ?? ""
            case .bracketed(let after, let before):
                // Open end is "..", the ISO 8601-2 unknown-endpoint designator, NOT an empty
                // string. Explicit beats blank in a file handed over as evidence: a bare trailing
                // slash reads like truncation or a broken export, while ".." says the bound is
                // deliberately unknown. Byte-identical to Android's detectionsCsv.
                when = "\(after.map { fmt.string(from: $0) } ?? "..")/\(before.map { fmt.string(from: $0) } ?? "..")"
            case .unknown:
                when = ""
            }
            // approx_lat/lon is the PHONE's position. The d.coordinate fallback is drone-gated
            // for the same reason the drone columns below are: on a drone row that field is the
            // AIRCRAFT's Remote ID broadcast, so ungated it exported the aircraft as the observer
            // and made approx_lat identical to drone_lat. Matches Android mapCoordForExport.
            let fallback = r.allowDetectionCoordinateFallback && d.type != .drone
                ? d.coordinate : nil
            let coord = r.loc ?? fallback
            let lat = coord.map { String(format: "%.6f", $0.latitude) } ?? ""
            let lon = coord.map { String(format: "%.6f", $0.longitude) } ?? ""
            // Drone Remote ID telemetry, all blank for a non-drone row. approx_lat/lon above is
            // the PHONE's position when it heard the device; a drone ALSO broadcasts its own
            // position and, crucially, the OPERATOR (pilot) position, the single most valuable
            // field in a drone capture. It must survive into the evidence export, not just the
            // detail view. Coords go through coordinate/pilotCoordinate so a 0,0 reads blank.
            //
            // THE TYPE GATE IS LOAD-BEARING (added 2026-08-05, fixing a real export defect).
            // `lat`/`lon` on the wire is OVERLOADED: the `lat`,`lon` row of ble-protocol.md's
            // detection-frame table defines it as "drones = the aircraft's own broadcast position;
            // everything else = the DETECTOR's GPS". Cited by FIELD, not by line number: the
            // "line 88" pointer this replaces had drifted off the row it named, which is what every
            // line-number citation eventually does to the one warning this whole gate depends on.
            // Without this gate every non-drone row copied the PHONE's own position into
            // drone_lat/drone_lon. Measured on a real 2747-row export: 2746 of 2746 non-drone rows
            // carried a bogus drone position, 555 of them byte-identical to that row's own
            // approx_lat/lon. Anything reading the drone columns (a GPX/KML export, a map layer)
            // would plot thousands of phantom aircraft. This comment already claimed "blank for a
            // non-drone row"; now it is true. Kept byte-identical to Android's detectionsCsv.
            let isDrone = d.type == .drone
            let dc = isDrone ? d.coordinate : nil, pc = isDrone ? d.pilotCoordinate : nil
            // Serialize EVERY cell through the one document-aware encoder. Several fields are
            // numeric or protocol-shaped today, but keeping a hand-picked "safe" subset is a
            // brittle privacy boundary: the moment an external field accepts a record separator,
            // later location columns can shift before redaction sees them.
            // csvUntrustedText on mac too: it is decoded off the wire as a free string, so an
            // impostor board can put "=cmd(...)" in it. A real MAC is untouched. Mirrors Android.
            let fields = [when, r.basis.csvToken, r.basis.csvPrecisionSec,
                          d.type.label, Self.csvUntrustedText(d.mac), "\(d.rssi)",
                          d.source.label, d.method.label, "\(d.confidence)",
                          "\(d.count)", lat, lon, d.companyIdHex ?? "",
                          csvUntrustedText(d.uasID ?? ""), f6(dc?.latitude), f6(dc?.longitude),
                          iStr(d.altitude), iStr(d.speedH), iStr(d.heading), iStr(d.heightAGL),
                          f6(pc?.latitude), f6(pc?.longitude), iStr(d.pilotAlt),
                          d.ridStatusLabel ?? "", csvUntrustedText(d.maker ?? "")]
            rows.append(fields.map(csvSafe).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    /// XML text escape. Ampersand FIRST or it double-escapes the entities added after it.
    private static func xmlSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// GPX 1.1 for import into a mapping app (Gaia GPS, Caltopo, OsmAnd).
    ///
    /// THE ONE THING A READER MUST NOT MISUNDERSTAND: for everything except a drone, the pin is
    /// where the PHONE was standing, NOT where the device is. A passive radio cannot tell you
    /// where a transmitter is - only that it was audible from here, which at BLE range could be
    /// most of a block in any direction. GPX has no way to express that uncertainty, so every
    /// such waypoint is NAMED "Heard:" and its description says so in words. Do not "clean that
    /// up": the whole file is misread the moment it looks like a map of camera positions.
    ///
    /// A drone is the exception and gets up to three waypoints, because Remote ID broadcasts real
    /// positions: where it was heard from, where the AIRCRAFT said it was, and where the OPERATOR
    /// said they were. Those last two are the only true device positions this product can export.
    ///
    /// TEST COVERAGE, stated honestly: BeaconsTests/ExportTests.swift covers THIS side (the drone
    /// gate, waypoint counts, escaping, the bracketed-row time omission). Android's
    /// AcabBleManagerExportTest.kt exists but covers only the CSV drone gate and wire clamps,
    /// zero GPX; renderDetectionsGpx already takes a snapshot, but it still lives on the
    /// Context-requiring manager class, so it cannot run under plain JUnit yet. The JSON fixtures
    /// in ExportTests are deliberately written to be reusable verbatim when that happens, so this
    /// is a gap, not a divergence. Do not claim GPX parity is enforced until a Kotlin test runs
    /// renderDetectionsGpx on these shared fixtures.
    static func buildGPX(_ snapshot: [CSVRowInput]) -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="beacons" xmlns="http://www.topografix.com/GPX/1/1">
        """
        func f6(_ v: Double) -> String { String(format: "%.6f", v) }

        // One waypoint. `time` is omitted rather than faked when the row has no single instant:
        // a bracketed row's honest answer is a RANGE, and GPX <time> can only hold a point, so
        // writing either end of the bracket would state a precision the data does not have. The
        // basis always rides in <desc> instead.
        func wpt(lat: Double, lon: Double, name: String, desc: String, time: String?) {
            out += "\n  <wpt lat=\"\(f6(lat))\" lon=\"\(f6(lon))\">"
            if let t = time, !t.isEmpty { out += "\n    <time>\(xmlSafe(t))</time>" }
            out += "\n    <name>\(xmlSafe(name))</name>"
            out += "\n    <desc>\(xmlSafe(desc))</desc>"
            out += "\n  </wpt>"
        }

        for r in snapshot {
            let d = r.d
            // A single instant, or nil when the row is bracketed/unknown (see wpt above).
            var stamp: String? = nil
            var basisNote = ""
            switch r.basis {
            case .exact:
                stamp = r.firstSeen.map { fmt.string(from: $0) }
                basisNote = "exact"
            case .reconstructed(let precision):
                // Same source as buildCSV: the instant lives on the ROW; the basis only carries
                // how wide that instant could be.
                stamp = r.firstSeen.map { fmt.string(from: $0) }
                basisNote = "reconstructed, +/-\(precision)s"
            case .bracketed(let after, let before):
                basisNote = "bracketed \(after.map { fmt.string(from: $0) } ?? "..")/"
                          + "\(before.map { fmt.string(from: $0) } ?? "..")"
            case .unknown:
                basisNote = "time unknown"
            }
            let label = d.maker.map { "\(d.type.label) (\($0))" } ?? d.type.label
            var facts = ["\(d.mac)", "\(d.rssi) dBm", "conf \(d.confidence)",
                         "matched on \(d.method.label)", "\(d.count)x", "time: \(basisNote)"]
            if let det = d.detail, !det.isEmpty { facts.append(det) }

            // Where we heard it FROM. The `d.coordinate` fallback is DRONE-GATED because for a
            // drone that field is the aircraft's Remote ID position, not the phone - the same wire
            // overload that produced the CSV bug. Without the gate a drone's own position would be
            // labelled "Position is where the PHONE was", the exact inversion of the honesty rule
            // this writer exists to enforce. Its real position gets its own waypoint below.
            // Matches Android detectionsGpx.
            let fallback = r.allowDetectionCoordinateFallback && d.type != .drone
                ? d.coordinate : nil
            if let c = r.loc ?? fallback {
                wpt(lat: c.latitude, lon: c.longitude,
                    name: "Heard: \(label)",
                    desc: "Position is where the PHONE was, not the device. "
                        + "Audible from here only. " + facts.joined(separator: " | "),
                    time: stamp)
            }
            // Real broadcast positions. Drone-only, matching the CSV's type gate.
            if d.type == .drone {
                if let dc = d.coordinate {
                    wpt(lat: dc.latitude, lon: dc.longitude,
                        name: "Drone (broadcast position): \(label)",
                        desc: "Aircraft position from its own Remote ID broadcast. "
                            + facts.joined(separator: " | "),
                        time: stamp)
                }
                if let pc = d.pilotCoordinate {
                    wpt(lat: pc.latitude, lon: pc.longitude,
                        name: "Drone OPERATOR: \(label)",
                        desc: "Operator position from the aircraft's Remote ID broadcast. "
                            + facts.joined(separator: " | "),
                        time: stamp)
                }
            }
        }
        out += "\n</gpx>"
        return out
    }

    /// Build the log CSV and write it to a temp file for the share sheet, then hand the
    /// URL (nil on failure) to `completion` on the main thread. Snapshot on main,
    /// format + write off-main: string-formatting up to 5000 rows synchronously in the
    /// button action froze the UI for hundreds of ms right at the export tap, the same
    /// stall persistDetections() already had fixed for the checkpoint path.
    /// Export formats. CSV is the evidence file; GPX is for a mapping app (see buildGPX for the
    /// "the pin is the phone, not the device" caveat that rides in every waypoint name).
    enum ExportFormat {
        case csv, gpx
        var ext: String { self == .csv ? "csv" : "gpx" }
    }

    enum DetectionExportResult {
        case success(URL)
        case emptyGPX
        case failure(String)
    }

    /// `category` is a DeviceType.category key (ALPR / DRONE / BODY CAM / TRACKER), or nil for
    /// everything. Callers pass the filter the user is already looking at in the log, so export
    /// means "give me what is on screen" rather than silently handing over the whole history.
    /// The chosen category also lands in the FILENAME, so a partial export can never be mistaken
    /// for a complete one after it leaves the app.
    // MARK: - Bounded contribution capture window

    private static func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }

    /// Arm a bounded contribution's live-sighting ledger. The session store remains authoritative
    /// for the normal Log, but cannot define this artifact because it also contains replayed rows
    /// and devices last heard before Start.
    func beginContributionCapture(startMs: Int64) {
        contributionCaptureStartMs = startMs
        contributionLiveSamples.removeAll(keepingCapacity: true)
    }

    /// Abandon any capture-only location state. Review owns a fully rendered CSV, so nothing in
    /// this table is needed after Stop.
    func cancelContributionCapture() {
        contributionCaptureStartMs = nil
        contributionLiveSamples.removeAll(keepingCapacity: true)
    }

    /// Record the phone position paired with this exact live sighting. A nil coordinate is still
    /// a real sample and intentionally replaces an earlier fix: exporting the older position next
    /// to the newer timestamp would claim they described the same observation.
    private func recordContributionObservation(_ d: Detection, observedAt: Date,
                                               observerLocation: CLLocationCoordinate2D?) {
        guard let startMs = contributionCaptureStartMs else { return }
        let observedAtMs = Self.ms(observedAt)!
        guard observedAtMs >= startMs else { return }
        contributionLiveSamples[d.id] = ContributionLiveSample(
            detection: d, observedAtMs: observedAtMs, coordinate: observerLocation)
    }

    /// Device ID -> latest in-window LIVE sighting. This bypasses the coalesced `@Published`
    /// projection without admitting offline replay records from the broader session store.
    func windowObservationTimes(startMs: Int64, stopMs: Int64) -> [String: Int64] {
        guard contributionCaptureStartMs == startMs else { return [:] }
        return Dictionary(uniqueKeysWithValues: contributionLiveSamples.compactMap { id, sample in
            guard sample.observedAtMs >= startMs, sample.observedAtMs <= stopMs else { return nil }
            return (id, sample.observedAtMs)
        })
    }

    /// Live count while capturing. Review uses the frozen timestamp map captured at Stop.
    ///
    /// Counted straight off the ledger rather than through windowObservationTimes: ContributeView
    /// reads this twice inside one Text while capturing, and its body re-evaluates on every
    /// BLEManager publish (~3 Hz) as well as its own 1 Hz ticker, so building the map just to read
    /// .count threw away a dictionary sized to every device heard since Start, several times a
    /// second, on main. Same membership rule as the map, so the two can never disagree.
    func windowObservationCount(startMs: Int64, stopMs: Int64) -> Int {
        guard contributionCaptureStartMs == startMs else { return 0 }
        return contributionLiveSamples.values.lazy
            .filter { $0.observedAtMs >= startMs && $0.observedAtMs <= stopMs }
            .count
    }

    /// The one atomic Stop result. CoreBluetooth and the Stop action both run on the main thread,
    /// so no ingest can interleave between membership, row fields, timestamps, and the capture-
    /// local observer coordinate. Rows are sorted for deterministic CSV output.
    struct ContributionCaptureSnapshot {
        let capturedAtByID: [String: Int64]
        let rows: [CSVRowInput]
    }

    func finishContributionCapture(startMs: Int64, stopMs: Int64) -> ContributionCaptureSnapshot {
        let times = windowObservationTimes(startMs: startMs, stopMs: stopMs)
        let rows = contributionLiveSamples.compactMap { id, sample -> CSVRowInput? in
            guard let capturedAt = times[id], sample.observedAtMs == capturedAt else { return nil }
            return CSVRowInput(d: sample.detection,
                               firstSeen: Date(timeIntervalSince1970: Double(capturedAt) / 1000),
                               loc: sample.coordinate, basis: .exact,
                               allowDetectionCoordinateFallback: false)
        }.sorted {
            let l = times[$0.d.id] ?? 0, r = times[$1.d.id] ?? 0
            return l == r ? $0.d.id < $1.d.id : l > r
        }
        cancelContributionCapture()
        return ContributionCaptureSnapshot(capturedAtByID: times, rows: rows)
    }

    /// The pure formatting leg (buildCSV + redact): no manager state, safe on any thread.
    /// Three separate location flags - observer (the phone), drone AIRCRAFT coords, and drone
    /// OPERATOR coords - because the operator position locates a person (see ContributionCsv).
    static func renderContributionCSV(_ snapshot: [CSVRowInput],
                                      includeObserverLocation: Bool, includeDroneLocation: Bool,
                                      includeOperatorLocation: Bool) -> String {
        let csv = buildCSV(snapshot)
        return ContributionCsv.redact(csv, blankColumns: ContributionCsv.blankColumns(
            includeObserverLocation: includeObserverLocation,
            includeDroneLocation: includeDroneLocation,
            includeOperatorLocation: includeOperatorLocation))
    }

    #if DEBUG
    /// Regression hook: seed the authoritative store without publishing its UI projection and,
    /// when armed, model the matching live ledger write. This pins both the coalescing regression
    /// and the capture-local observer-position contract without exposing production mutators.
    func testSeedContributionDetection(_ d: Detection, firstSeen: Date, lastSeen: Date,
                                       observerLocation: CLLocationCoordinate2D? = nil) {
        store[d.id] = d
        firstSeenAt[d.id] = firstSeen
        self.lastSeen[d.id] = lastSeen
        if contributionCaptureStartMs != nil, !d.isHistory {
            recordContributionObservation(d, observedAt: lastSeen,
                                           observerLocation: observerLocation)
        }
    }
    #endif

    func writeDetections(_ format: ExportFormat, snapshot: DetectionExportSnapshot,
                         filenameQualifier: String? = nil,
                         completion: @escaping (DetectionExportResult) -> Void) {
        // Not persistQueue: that serial queue can be mid-checkpoint during a big replay, and
        // a user-initiated export shouldn't wait its turn behind a multi-MB store encode.
        DispatchQueue.global(qos: .userInitiated).async {
            let body = format == .csv ? BLEManager.buildCSV(snapshot.rows) : BLEManager.buildGPX(snapshot.rows)
            // A GPX with no waypoints is a valid 125-byte document that maps nothing, and handing
            // that to a share sheet looks like the export silently failed. It happens whenever the
            // selected rows have no GPS fix: a detection heard with location off, or before the
            // first fix, still exports fine as CSV (blank approx columns) but has nothing to plot.
            // Report it as a failure so the UI can say WHY, rather than shipping an empty map.
            if format == .gpx && !body.contains("<wpt ") {
                DispatchQueue.main.async { completion(.emptyGPX) }
                return
            }
            let slug = filenameQualifier.map {
                "-" + $0.lowercased().replacingOccurrences(of: " ", with: "-")
            } ?? ""
            // A share extension may read the URL long after this callback returns. A fixed temp
            // filename lets a second export overwrite the bytes behind the first open share sheet
            // or mail draft. Give every export an immutable UUID parent while preserving the
            // human-readable leaf name recipients see. Successful dirs intentionally live until
            // iOS reclaims temporaryDirectory; deleting them here or on sheet dismissal can race
            // an activity that retained the file provider URL.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = dir.appendingPathComponent("acab-detections\(slug).\(format.ext)")
            // write as Data with completeFileProtection: the GPS+MAC file must stay unreadable while
            // the phone is locked. String.write(to:atomically:encoding:) applies NO data protection,
            // so it was readable on a seized locked phone. The strict class is fine here (unlike the
            // checkpoint's UnlessOpen): exporting only happens with the phone unlocked in hand.
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try Data(body.utf8).write(to: url, options: [.atomic, .completeFileProtection])
                DispatchQueue.main.async { completion(.success(url)) }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                DispatchQueue.main.async { completion(.failure(error.localizedDescription)) }
            }
        }
    }

    /// Convenience for a whole-log export. It still snapshots the authoritative store rather than
    /// the delayed SwiftUI projection.
    func writeDetections(_ format: ExportFormat, category: String? = nil,
                         completion: @escaping (DetectionExportResult) -> Void) {
        let snapshot = detectionExportSnapshot().filtered(category: category,
                                                          unseenOnly: false, offlineOnly: false)
        writeDetections(format, snapshot: snapshot, filenameQualifier: category, completion: completion)
    }

    /// Use the same document-aware field serializer the redactor tests. Delegating here is
    /// load-bearing: a lone carriage return is a CSV record separator too, so the old local
    /// comma/quote/LF-only rule could emit an unquoted UAS ID that shifted later location columns
    /// into a new physical record before redaction saw them.
    private static func csvSafe(_ s: String) -> String { ContributionCsv.field(s) }

    /// Spreadsheet applications may interpret an externally supplied text cell as a formula even
    /// when RFC 4180 quoting is correct. Preserve the broadcast text, but make it literal by adding
    /// one apostrophe when the first non-space/tab character is a formula sigil. This is export-only:
    /// structural CSV parsing and numeric evidence cells must remain unchanged.
    static func csvUntrustedText(_ s: String) -> String {
        let first = s.drop(while: { $0 == " " || $0 == "\t" }).first
        guard let first, "=+-@".contains(first) else { return s }
        return "'" + s
    }

    /// Update the synthetic board's status in memory. Sample controls are a durable preview for
    /// the lifetime of the tour, but they never write a real preference or peripheral.
    @discardableResult
    private func setDemoStatusValue(_ value: Any, for key: String) -> Bool {
        guard demoMode else { return false }
        demoStatusPayload[key] = value
        status = decodeJSON(DeviceStatus.self, demoStatusPayload)
        return true
    }

    /// Toggle the board's ALPR (Flock) detector (on by default).
    func setFlockEnabled(_ on: Bool) {
        writeConfig(["flock": on])
    }

    /// Toggle the board's drone (remote ID) detector (on by default).
    func setDroneEnabled(_ on: Bool) {
        writeConfig(["drone": on])
    }

    /// Toggle the drone vendor-OUI FALLBACK (off by default). Sub-option of the drone
    /// detector: on, a DJI/Parrot OUI with no Remote ID is also flagged; off (the default),
    /// only the Remote ID path fires. Off by default because a stationary Parrot gadget can't
    /// be distinguished from a flying drone by OUI alone, so it's a false-positive source.
    func setDroneOuiEnabled(_ on: Bool) {
        writeConfig(["droneoui": on])
    }

    /// Toggle the board's network-camera detector (off by default). Mirrors the drone-OUI
    /// opt-in: when on, the board enables the 802.11 DATA-frame source-MAC path and flags a
    /// branded IP-camera OUI (Hikvision/Dahua/etc.) streaming on the host WiFi. Off by default
    /// because that data-frame path adds CPU + 2.4GHz coexistence load, so it stays disabled
    /// until the user opts in. It matches known IP-camera BRANDS only and cannot find every camera.
    func setNetcamEnabled(_ on: Bool) {
        writeConfig(["netcam": on])
    }

    /// Toggle the board's body-cam CATEGORY: the Axon BWCDEVICE payload tag, the Axon OUI, the
    /// Utility BodyWorn signatures, and the broad Motorola Solutions OUI proxy. Off silences all
    /// of them. It no longer clobbers the Motorola sub-setting below, so turning the category
    /// back on restores whatever the user last chose there.
    func setBodyCamEnabled(_ on: Bool) {
        writeConfig(["bodycam": on])
    }

    /// Toggle the broad Motorola Solutions OUI match, a sub-option of the body-cam detector.
    /// Off quiets just that vendor proxy (confidence 45, deliberately below the weak-match
    /// threshold, because the same corporate blocks cover two-way radios and docks); the
    /// field-validated Axon BWCDEVICE tag and the Utility BodyWorn signatures keep running.
    /// Classification needs BOTH switches, so this changes nothing while the category is off.
    func setMotorolaEnabled(_ on: Bool) {
        writeConfig(["motorola": on])
    }

    /// Toggle the board's BLE item-tracker detector (off by default).
    func setTrackerEnabled(_ on: Bool) {
        writeConfig(["tracker": on])
    }

    /// Toggle the board's recording / smart-glasses detector (on by default, like body cams).
    func setGlassesEnabled(_ on: Bool) {
        writeConfig(["glasses": on])
    }

    /// Toggle Desert mode: the board reports EVERY device in range (not just signatures).
    /// Enabling it drops alerts to Silent; with everything reporting in, the buzzer and
    /// haptics would otherwise never stop. The user can switch sound back on afterward.
    func setDesertMode(_ on: Bool) {
        if demoMode {
            _ = setDemoStatusValue(on, for: "desert")
            if on {
                if alertMode != .silent { demoAlertModeBeforeDesert = alertMode }
                alertMode = .silent
                _ = setDemoStatusValue(false, for: "buzzer")
            } else if let prior = demoAlertModeBeforeDesert {
                if alertMode == .silent { alertMode = prior }
                _ = setDemoStatusValue(alertMode == .buzzer, for: "buzzer")
                demoAlertModeBeforeDesert = nil
            }
            return
        }
        writeConfig(["desert": on])
        if on {
            // Remember the prior mode so turning Desert off can restore it. Only capture when we're
            // actually forcing a change (not already Silent), so a manual Silent isn't overwritten.
            if alertMode != .silent {
                alertModeBeforeDesert = alertMode
                setAlertMode(.silent)
            } else {
                // Already Silent, so there is nothing to restore. CLEAR the token rather than
                // leaving it: now that it is persisted it would otherwise be an arbitrarily old
                // mode, and a later Desert-off would un-mute a user who deliberately chose Silent.
                alertModeBeforeDesert = nil
            }
            desertSeenOn = false   // wait for the board to confirm before arming the reconciler
        } else if let prior = alertModeBeforeDesert {
            // Desert forced Silent on; put the user's earlier alert mode back - but only if the
            // mode is still Silent. The card says "Switch sound back on anytime", and a mode the
            // user hand-picked WHILE Desert ran is an explicit choice that must survive the
            // toggle going off, not get stomped back to the captured one. Mirrors Android.
            if alertMode == .silent { setAlertMode(prior) }
            alertModeBeforeDesert = nil
        }
    }

    /// Toggle the board's offline detection buffer (off by default in firmware). When
    /// on, the board stores detections while we're disconnected and replays them on
    /// the next {sync}.
    func setBufferingEnabled(_ on: Bool) {
        bufferingOn = on
        writeConfig(["buffer": on])
    }

    /// Onboard LED master. off = "lights out" (fully dark: no idle heartbeat, detection flashes,
    /// or boot sweep), for covert/stationary deploys. The board persists it across reboots.
    func setLedEnabled(_ on: Bool) {
        writeConfig(["led": on])
    }

    /// Erase the board's stored buffer. The board restarts its record sequence from 1 after a
    /// wipe, so reset our replay cursor to 0. A stale-high cursor would skip every post-erase
    /// record on the next reconnect and the fresh buffer would be lost.
    func clearBufferLog() {
        if setDemoStatusValue(0, for: "buf") { return }
        guard let data = try? JSONSerialization.data(withJSONObject: ["clearlog": true]) else { return }
        // Cursor authority changes only after the board ACKs the destructive write. Its callback
        // then re-sends this phone's durable key through the same ACK-gated handshake, so a cleared
        // multi-bond board is never left with a keyless fresh ring.
        _ = enqueueConfigWrite(PendingConfigWrite(data: data, purpose: .clearLog))
    }

    /// Master audio on/off.
    func setBuzzerEnabled(_ on: Bool) {
        writeConfig(["buzzer": on])
    }

    /// Re-assert attempts made since the app and board last agreed on the buzzer. Reset on every
    /// fresh connection (see the connect path) so a stale value can't skip the grace period.
    private var buzzerReassertAttempts = 0
    private static let maxBuzzerReasserts = 3
    /// When the last mute write went out. After the fast burst above, an AUDIBLE board the user
    /// asked to keep quiet keeps getting the write at `buzzerMuteRetryInterval` for as long as the
    /// two disagree. See reconcileBuzzer for why that direction never gives up. Android twin:
    /// lastBuzzerMuteWrite / BUZZER_MUTE_RETRY_MS in AcabBleManager, same 30 s cadence.
    private var lastBuzzerMuteWrite = Date.distantPast
    private static let buzzerMuteRetryInterval: TimeInterval = 30

    /// Reconcile the alert mode against what the board actually reports.
    ///
    /// THE BUG THIS FIXES (reported 2026-07-31): turn Desert mode on, then off, and the app showed
    /// sound ON while the board stayed silent. `alertMode` was optimistic local state: setAlertMode()
    /// assigned it, persisted it and fired writeConfig(["buzzer":]) without checking the result,
    /// while ingestStatus reconciled `bufferingOn` from status but never the buzzer.
    /// Any lost config write left the two diverged with nothing to heal it. Desert is where it shows
    /// because setDesertMode is the only path firing TWO config writes back to back.
    ///
    /// THREE THINGS THE FIRST VERSION OF THIS GOT WRONG, all found in re-review:
    ///  1. Mesh-Detect boards have NO buzzer hardware. `alertsBuzzerEnabled()` is a weak stub
    ///     returning false forever and buzzer writes are discarded, so want(true) != report(false)
    ///     could never converge, and the reconciler wrote .silent into the SHARED preference, which
    ///     then muted the user's real beacon board on its next connect. Hence the isMeshDetect bail.
    ///  2. It collapsed three alert modes onto a Bool and could write back only .buzzer or .silent,
    ///     so a .vibrate user could be silently promoted to .buzzer: an audible board for someone
    ///     who deliberately chose a quiet one, on a counter-surveillance device. Never do that; when
    ///     the board is audible and the user wanted quiet, keep trying to MUTE. Erring quiet is the
    ///     only safe direction here.
    ///  3. The correction was persisted, so one transient link fault could rewrite a stored
    ///     preference. The correction is now in-memory for the session; the stored preference is
    ///     re-asserted from scratch on the next launch.
    /// Latched view of the board's Desert state, so a `desert:false` frame can be told apart from
    /// "our enable write has not landed yet". Only flips true once the BOARD confirms Desert on.
    private var desertSeenOn = false

    /// Restore the pre-Desert alert mode when Desert ends WITHOUT going through setDesertMode(off).
    ///
    /// HISTORY, because the rationale changed under this code. Desert USED TO BE the one toggle
    /// with no NVS backing (desert_detect.cpp held a plain `static bool`), so any board reboot came
    /// back with it off. The Settings toggle only follows the status frame (SettingsView:
    /// `desertOn = s.desertMode`), so the restore branch in setDesertMode never ran for the single
    /// most common way Desert ended, and because the board's Silent IS persisted (buzz=false in its
    /// NVS) the board was left permanently mute after a power cycle. That reads as "my starred
    /// device stopped beeping" and is not a detection fault.
    ///
    /// Firmware from 2026-08-08 PERSISTS Desert (desertRestoreEnabled), so a reboot no longer ends
    /// it behind our back and that specific bug cannot recur on current firmware. This is kept
    /// deliberately and must not be deleted as dead code:
    ///   - boards already in the field still run the non-persisting build and this app pairs with
    ///     them,
    ///   - a factory reset or NVS wipe still clears it,
    ///   - Desert can still end without passing through setDesertMode(off) from another client.
    /// The condition it guards, "Desert stopped and we are not the ones who stopped it", is
    /// unchanged. What changed is only how often it fires.
    private func reconcileDesert(_ s: DeviceStatus) {
        if s.desertMode { desertSeenOn = true; return }
        guard desertSeenOn else { return }        // never saw it on: nothing to restore
        desertSeenOn = false
        // Same conditions as the manual path: only un-mute if we are still on the Silent that
        // Desert forced, so a mode the user hand-picked while Desert ran survives.
        if let prior = alertModeBeforeDesert, alertMode == .silent { setAlertMode(prior) }
        alertModeBeforeDesert = nil
    }

    private func reconcileBuzzer(_ s: DeviceStatus) {
        guard !s.isMeshDetect else { buzzerReassertAttempts = 0; return }   // no buzzer to reconcile

        let wantBuzzer = (alertMode == .buzzer)
        guard wantBuzzer != s.buzzer else {
            buzzerReassertAttempts = 0
            lastBuzzerMuteWrite = .distantPast
            return
        }

        if buzzerReassertAttempts < Self.maxBuzzerReasserts {
            buzzerReassertAttempts += 1
            lastBuzzerMuteWrite = Date()
            setBuzzerEnabled(wantBuzzer)     // most likely a dropped write; say it again
            return
        }
        // Re-asserting did not take. Only correct the UI where the mapping is LOSSLESS.
        if wantBuzzer {
            // We claim sound, the board is muted: the originally reported bug. Tell the truth for
            // this session, WITHOUT persisting, so a transient fault can't rewrite the preference.
            alertMode = .silent
            return
        }
        // The other direction is the one we must never give up on: the board is AUDIBLE while the
        // user chose .vibrate or .silent. Leaving alertMode alone is still right (both modes are
        // honest about what the PHONE does), but going quiet about it was not. Nothing else in the
        // app re-sends the mute, and no surface reports the disagreement, so running the burst out
        // used to mean "beeping for the rest of the session" unless the user happened to re-pick a
        // mode or reconnect - a beacon making noise for someone who asked for silence, which is the
        // covert-use promise breaking. Keep sending it. writeConfig(["buzzer": false]) is one small
        // idempotent frame, so a slow cadence costs almost nothing and heals the moment the board
        // starts listening again. Android twin: the same terminal branch in AcabBleManager's
        // reconcileBuzzer, gated on BUZZER_MUTE_RETRY_MS.
        let now = Date()
        guard now.timeIntervalSince(lastBuzzerMuteWrite) >= Self.buzzerMuteRetryInterval else { return }
        lastBuzzerMuteWrite = now
        setBuzzerEnabled(false)
    }

    /// Pick how alerts reach you. Only `.buzzer` keeps the board's buzzer live;
    /// the others mute it.
    func setAlertMode(_ m: AlertMode) {
        alertMode = m
        if demoMode {
            if m != .silent { demoAlertModeBeforeDesert = nil }
            _ = setDemoStatusValue(m == .buzzer, for: "buzzer")
            return
        }
        UserDefaults.standard.set(m.rawValue, forKey: alertModeKey)
        // A mode picked while Desert is running is an explicit choice and outranks whatever we
        // captured on the way in, so drop the token. setDesertMode's own restore calls this too,
        // which is harmless: it nils the token a line later anyway.
        if m != .silent { alertModeBeforeDesert = nil }
        setBuzzerEnabled(m == .buzzer)
        // Prime BOTH generators. impactHaptic is the one used for every type EXCEPT Flock and
        // drone (see alertHaptic), i.e. the common case, and it was never being prepared - an
        // unprepared generator still fires but with enough latency to feel like a miss on a
        // single medium tap.
        if m == .vibrate { notifHaptic.prepare(); impactHaptic.prepare(); requestFocusAuthIfNeeded() }
    }

    /// May this MAC buzz now? True when it has never buzzed or is past `hapticCooldown`, and it
    /// RECORDS the buzz, so only call it once you know everything else has passed.
    private func hapticDue(_ mac: String, now: Date = Date()) -> Bool {
        if let last = lastHapticByMac[mac], now.timeIntervalSince(last) < Self.hapticCooldown {
            return false
        }
        lastHapticByMac[mac] = now
        if lastHapticByMac.count > 256 {
            lastHapticByMac = lastHapticByMac.filter { now.timeIntervalSince($0.value) < Self.hapticCooldown }
        }
        return true
    }

    /// Category-shaped tactile cue: glasses double-tap; body cameras repeat distinctly.
    private func alertHaptic(for type: DeviceType) {
        switch type {
        case .recordingGlasses:
            impactHaptic.impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.impactHaptic.impactOccurred()
            }
        case .axonBodyCam:
            notifHaptic.notificationOccurred(.warning)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.notifHaptic.notificationOccurred(.warning)
            }
        case .flockCamera, .flockRaven, .drone: notifHaptic.notificationOccurred(.error)
        default:                                impactHaptic.impactOccurred()
        }
    }

    /// Ask once for Focus access, so vibrate alerts can defer to Do Not Disturb.
    private func requestFocusAuthIfNeeded() {
        if INFocusStatusCenter.default.authorizationStatus == .notDetermined {
            INFocusStatusCenter.default.requestAuthorization { _ in }
        }
    }

    /// True when a Focus (or Do Not Disturb) is on, so vibrate alerts stay quiet.
    /// If we can't read Focus (never authorized), treat it as off so alerts still fire.
    private var focusActive: Bool {
        INFocusStatusCenter.default.focusStatus.isFocused == true
    }

    /// Buzzer loudness, 0...100. `preview: true` also has the board beep once at that
    /// level, so you can hear it on slider release.
    func setVolume(_ v: Int, preview: Bool = false) {
        let clamped = max(0, min(100, v))
        var cfg: [String: Any] = ["volume": clamped]
        if preview { cfg["beep"] = true }
        writeConfig(cfg)
    }

    /// Turn the board's BLE detection scan on/off. This only stops scanning - our
    /// BLE link to the board stays up.
    func setBLEScan(_ on: Bool) {
        writeConfig(["ble": on])
    }

    /// Turn the board's Wi-Fi (promiscuous) detection scan on/off.
    func setWiFiScan(_ on: Bool) {
        writeConfig(["wifi": on])
    }
    /// WiFi eco: 0/3/7/15 s of RX sleep between channel sweeps (battery SKU). Firmware snaps to the ladder.
    func setWifiEco(_ sec: Int) {
        writeConfig(["wifiEco": sec])
    }

    /// Config-char key -> canned-status key: the ONE place sample mode learns how a board
    /// setting echoes. The wire names grew apart across firmware revisions (droneoui->droui,
    /// buffer->bufon, led->ledon, volume->vol) and the compiler cannot verify a string pair,
    /// so the whole mapping lives in this table instead of being restated inside each setter.
    /// "bodycam" is deliberately identity: the demo seed carries the firmware's legacy "axon"
    /// key, but the DeviceStatus decoder reads "bodycam" first, so an echo written under
    /// "bodycam" outranks the seed's "axon" without touching it.
    private static let demoStatusKeyByConfigKey: [String: String] = [
        "flock": "flock", "drone": "drone", "droneoui": "droui", "netcam": "ncam",
        "bodycam": "bodycam", "tracker": "tracker", "glasses": "glasses",
        "desert": "desert", "buffer": "bufon", "led": "ledon", "buzzer": "buzzer",
        "volume": "vol", "ble": "ble", "wifi": "wifi", "wifiEco": "wifiEco",
    ]

    /// Transient board commands (never state) with nothing to echo in sample mode. Kept apart
    /// from the table above so the unmapped-key trap below stays meaningful for real settings.
    private static let demoInertConfigKeys: Set<String> = ["beep"]

    @discardableResult
    private func writeConfig(_ dict: [String: Any]) -> Bool {
        // Sample mode: echo the write into the canned status instead of a peripheral, so board
        // settings take the SAME call path in both modes and the demo special-casing lives at
        // this one boundary, not in fifteen setters. Every non-setting writeConfig producer
        // (list pushes, buffer handshake, GPS uplink, OTA/DFU, power-off) is demo-guarded
        // upstream, so an unmapped key here is a board setting added without a table entry: in
        // sample mode it would silently no-op and the canned status would snap the control
        // back, shipping a dead tour toggle. Fail loudly instead of covering for it.
        if demoMode {
            for (key, value) in dict {
                if let statusKey = Self.demoStatusKeyByConfigKey[key] {
                    setDemoStatusValue(value, for: statusKey)
                } else if key == "motorola" {
                    // "moto" rides outside DeviceStatus (ingestStatus assigns motorolaOn from
                    // the raw frame), so the canned re-decode cannot carry it; mirror directly.
                    motorolaOn = value as? Bool ?? motorolaOn
                } else if !Self.demoInertConfigKeys.contains(key) {
                    print("[ACAB-demo] no status echo mapped for config key \"\(key)\"")
                    assertionFailure("sample mode: unmapped config key \"\(key)\"")
                }
            }
            return true
        }
        guard let peripheral, let configChar,
              peripheral.state == .connected,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return false }
        return enqueueConfigWrite(
            PendingConfigWrite(data: data, purpose: .normal),
            peripheral: peripheral, configChar: configChar)
    }

    @discardableResult
    private func enqueueConfigWrite(
        _ write: PendingConfigWrite,
        peripheral: CBPeripheral? = nil,
        configChar: CBCharacteristic? = nil,
        prioritize: Bool = false
    ) -> Bool {
        guard let owner = peripheral ?? self.peripheral,
              let characteristic = configChar ?? self.configChar,
              owner === self.peripheral, owner.state == .connected else { return false }
        enqueueBufferControlWrite(
            write, into: &configWriteQueue, handshakeSuccessor: prioritize)
        dispatchNextConfigWrite(peripheral: owner, configChar: characteristic)
        return true
    }

    private func dispatchNextConfigWrite(peripheral: CBPeripheral? = nil,
                                         configChar: CBCharacteristic? = nil) {
        guard configWriteDispatchAllowed(
                postSyncPaused: postSyncConfigDispatchPaused,
                hasInFlight: configWriteInFlight != nil,
                hasQueuedWrite: !configWriteQueue.isEmpty),
              let owner = peripheral ?? self.peripheral,
              let characteristic = configChar ?? self.configChar,
              owner === self.peripheral, owner.state == .connected else { return }
        let next = configWriteQueue.removeFirst()
        configWriteInFlight = next
        owner.writeValue(next.data, for: characteristic, type: .withResponse)
    }

    private func resetConfigWriteQueue() {
        resetBufferControlWriteState(
            queue: &configWriteQueue,
            inFlight: &configWriteInFlight,
            owner: &bufferHandshakeCompletion)
        readyStatusSettled = false
        readyOTASettled = false
        readySubscriptionStep = nil
        postSyncConfigDispatchPaused = false
    }

    /// Retire every characteristic identity owned by the prior connection generation. A
    /// CBPeripheral can retain its old `services` array across reconnects, so consulting that
    /// cache in a callback does not prove the callback belongs to the new link.
    private func retireSessionCharacteristics() {
        sessionService = nil
        detectionsChar = nil
        configChar = nil
        statusChar = nil
        otaChar = nil
        sessionDiscoveryPhase = .inactive
    }

    private func currentSessionCharacteristic(for uuid: CBUUID) -> CBCharacteristic? {
        switch uuid {
        case ACABProfile.detections: return detectionsChar
        case ACABProfile.config: return configChar
        case ACABProfile.status: return statusChar
        case ACABProfile.ota: return otaChar
        default: return nil
        }
    }

    private func failSessionDiscovery(_ peripheral: CBPeripheral, hint: String) {
        guard self.peripheral === peripheral else { return }
        connectHint = hint
        // `disconnect` resets the Config queue and retires the service/channel identities before
        // cancelling the link, including reconnect and OTA-reboot adoption paths.
        disconnect()
    }

    /// EXACTLY what writeConfig needs to actually put bytes on the wire.
    ///
    /// `connectionState == .connected` is NOT the same thing and must not be used as a proxy for
    /// it: demo mode publishes .connected with a nil peripheral, and the OTA reboot window keeps
    /// .connected while the link is down and configChar is stale. Retiring a persisted "the user
    /// cleared this list" flag off a write that was silently dropped loses the clear for good,
    /// because resyncListsOnConnect then has nothing to say and never pushes again.
    private var canWriteConfig: Bool {
        peripheral?.state == .connected && configChar != nil
    }

    // MARK: - OTA bridges (internal, so BLEManager+OTA.swift can drive the link)
    // Swift extensions in a separate file can't touch `private` members; these expose just
    // the pieces the OTA engine needs, reusing the same Config-char write path.

    /// Write an {"ota":{...}} control object on the Config char (the OTA control channel).
    func otaWriteControl(_ ota: [String: Any]) { writeConfig(["ota": ota]) }

    /// Tell the S3 to relay the DFU trigger to the nRF co-processor, which reboots into its
    /// bootloader (advertising AdaDFU). Same Config-char path as every other toggle. Used by the
    /// BLEManager+NrfDFU extension, which can't reach the private writeConfig itself.
    func nrfSendDfuTrigger() { writeConfig(["nrfdfu": true]) }

    /// Ask the beacon to power off (rev-B). The board deep-sleeps and drops the link ITSELF. We do
    /// NOT flag the disconnect here: the board answers with a {"pwr":"off"} notify only when it is
    /// really about to drop, and `handlePwrNotify` arms `intentionalDisconnectID` on THAT. Arming on
    /// the confirmation rather than on this request is what stops a board that ignores the key (older
    /// firmware still reporting rev "B", or a write lost on the wire) from leaving the flag armed to
    /// mis-classify a later unrelated disconnect. Once off, only a physical ~1s button hold wakes it.
    func powerOffBeacon() {
        guard canWriteConfig else { return }
        writeConfig(["poweroff": true])
    }

    /// Intercept the board's {"pwr":"off"} shutdown heads-up on the OTA notify channel. The board
    /// sends it only when it is genuinely about to deep-sleep - a physical button-hold OR an app
    /// power-off - so flag the coming drop as intentional here, exactly as `disconnect()` does;
    /// didDisconnectPeripheral then treats it as a clean teardown (no error banner, no auto-reconnect)
    /// instead of a supervision-timeout loss. Returns true if it consumed the frame; a board that
    /// never powers off never sends this, so the flag is never armed against one that keeps running.
    func handlePwrNotify(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["pwr"] as? String) == "off" else { return false }
        intentionalDisconnectID = peripheral?.identifier
        return true
    }

    /// The live peripheral + OTA characteristic, or nil when we don't have a usable link.
    var otaLink: (peripheral: CBPeripheral, char: CBCharacteristic)? {
        guard otaCapable, let peripheral, let otaChar, otaChar.isNotifying else { return nil }
        return (peripheral, otaChar)
    }

    /// Identity of the board that can currently receive Config writes. The nRF updater uses this
    /// to bind its download and DFU trigger to the board that initiated the operation.
    var currentConfigPeripheralID: UUID? {
        guard canWriteConfig, let peripheral else { return nil }
        return peripheral.identifier
    }

    /// The board's current fw label ("beacon board" etc.), for the post-reboot version check.
    var currentFwLabel: String? { status?.firmwareLabel }
    /// The board's current version number, for the post-reboot version check.
    var currentFwVersion: String? { status?.version }
    /// Re-read the Status characteristic so the post-reboot version check has fresh data.
    func otaRereadStatus() { readStatusValue() }

    // MARK: - Status READ poll (MTU fallback)

    /// iPhones often negotiate an ATT MTU around 185, so a large status NOTIFY can be
    /// skipped firmware-side (it only notifies when the frame fits the negotiated MTU)
    /// while a READ of the same characteristic always returns the current value. Alongside
    /// the notify subscription we poll a READ every ~5 s while connected, feeding the same
    /// decode path, so the app's status stays fresh even when the notify can't fit. The
    /// timer is created on connect and invalidated on any disconnect.
    private var statusPollTimer: Timer?
    private let statusPollInterval: TimeInterval = 5

    private func startStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = Timer.scheduledTimer(withTimeInterval: statusPollInterval,
                                               repeats: true) { [weak self] _ in
            // Hold the poll while an OTA is running: a status READ mid-transfer would race the
            // chunk stream on the same link. The OTA path re-reads status itself (otaRereadStatus)
            // when it needs a fresh version for the post-reboot check, so nothing is lost.
            guard let self, !self.otaState.isRunning else { return }
            self.readStatusValue()
        }
    }

    private func stopStatusPolling() {
        statusPollTimer?.invalidate()
        statusPollTimer = nil
    }

    /// Read the Status characteristic once. Shared by the repeating poll and the
    /// post-reboot OTA re-read; the value lands in didUpdateValueFor -> ingestStatus.
    private func readStatusValue() {
        guard let peripheral, let statusChar else { return }
        peripheral.readValue(for: statusChar)
    }
    /// Reconnect to the peripheral we already hold (used after an OTA reboot).
    func otaReconnectPeripheral() {
        guard let central, let peripheral,
              otaOwnerPeripheralID == peripheral.identifier else { return }
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    /// The post-flash reconnect exhausted its overall timeout. A pending CoreBluetooth connect
    /// does not promise a terminal callback when cancelled, so settle the link synchronously as
    /// well as failing the update. Leaving the retained peripheral and stale characteristics in
    /// place would keep the app looking connected and let a later callback revive dead state.
    func otaRebootReconnectTimedOut(ownerID: UUID, reason: String) {
        updateSecureReadinessWatchdog(.teardown)
        guard let target = peripheral, target.identifier == ownerID else {
            cancelUpdatesForLinkTeardown(reason: reason)
            return
        }
        central?.cancelPeripheralConnection(target)
        stopStatusPolling()
        checkpointLive()
        cancelUpdatesForLinkTeardown(reason: reason)
        intentionalDisconnectID = nil
        peripheral = nil
        retireSessionCharacteristics()
        otaCapable = false
        connectedName = nil
        status = nil
        syncingOfflineLog = false
        histBeginSeen = false
        histResyncs = 0
        setSessionReady(false)
        reconnectTarget = nil
        connectionState = (central?.state == .poweredOn) ? .idle : .unknown
        if driveModeOn { suspendDriveModeForLinkEnd() }
        writeWidgetSummary(force: true)
        stopLocationIfIdle()
    }

    /// Push the phone's GPS to the board so a Mesh-Detect uplink can carry where we
    /// are. Throttled - the board only needs a periodic fix, not every CL update.
    private var lastGpsSent = Date.distantPast
    private func sendPhoneLocation() {
        // freshCoord, not lastCoord: this is called straight out of didDiscoverCharacteristicsFor
        // with the throttle reset, and CoreLocation cannot deliver a fix synchronously inside that
        // callback, so lastCoord there is the PREVIOUS session's position with certainty. Sending
        // it also stamps lastGpsSent, which then suppresses the real fix landing a second later.
        // The board omits location entirely when lat is absent, so bailing here means the uplink
        // carries no position rather than the wrong one.
        guard let c = freshCoord, configChar != nil,
              Date().timeIntervalSince(lastGpsSent) > 15 else { return }
        lastGpsSent = Date()
        writeConfig(["lat": c.latitude, "lon": c.longitude])
    }

    // MARK: - Offline buffer: key, handshake, lastSeq, persistence

    /// One durable replay position. Generation and sequence live in one string so a process death
    /// cannot pair a fresh generation with a stale-high cursor (or vice versa). The old seq key is
    /// retained only as a downgrade/migration mirror; this build always prefers the tuple.
    private func persistedReplayCursor() -> (seq: UInt32, generation: UInt32) {
        if let raw = UserDefaults.standard.string(forKey: replayCursorKey) {
            let fields = raw.split(separator: ":", omittingEmptySubsequences: false)
            if fields.count == 2,
               let generation = UInt32(fields[0]), let seq = UInt32(fields[1]) {
                return (seq, generation)
            }
        }
        return (UInt32(clamping: UserDefaults.standard.integer(forKey: lastSeqKey)), 0)
    }

    private func persistReplayCursor(seq: UInt32, generation: UInt32) {
        UserDefaults.standard.set("\(generation):\(seq)", forKey: replayCursorKey)
        UserDefaults.standard.set(Int(seq), forKey: lastSeqKey)
    }

    /// Highest buffer seq we've successfully filed in the persisted generation. Survives
    /// disconnects/relaunches; disconnect cleanup must not clear it.
    private var lastSeq: UInt32 {
        get { persistedReplayCursor().seq }
        set { persistReplayCursor(seq: newValue, generation: persistedReplayCursor().generation) }
    }
    private var activeLogGeneration: UInt32 = 0
    private var replayCursorEpoch: UInt64 = 0

    private func replaySyncConfig(cursor: UInt32) -> [String: Any] {
        ["sync": Int(cursor), "syncgen": Int(activeLogGeneration)]
    }

    /// Start an ACK-gated key -> epoch -> sync transaction. Only key enters the queue now; each
    /// successful Config response creates its successor, and sync success alone may publish READY.
    private func startBufferHandshake(key: String,
                                      completion: BufferHandshakeCompletion) -> Bool {
        // Priority successors normally make overlap impossible; keep this invariant explicit for
        // duplicate callbacks and future callers that might bypass the queue policy.
        guard bufferHandshakeCompletion == nil else { return false }
        // Reset per-drain counters; resume contiguity from where we left off.
        let persistedCursor = persistedReplayCursor()
        histReceived = 0
        histPseudoTick = 0
        histBeginSeen = false
        lastGoodSeq = persistedCursor.seq
        histHighestSeq = persistedCursor.seq
        activeLogGeneration = persistedCursor.generation
        histResyncs = 0   // fresh connection, fresh gap-retry budget
        // histAnchoredBoots deliberately NOT cleared: boot counters are monotonic, so anchors
        // proven by an earlier drain (or rebuilt from the persisted log at launch) bound this
        // drain's undateable records just as soundly, turning a loose "before <sync>" bracket
        // into a tight "before <boot N's min>". Matches Android's bootMinAt/bootMaxAt, which
        // only the clear-log path drops.
        // The pill is driven by the board's {"hist":"begin"} lead-in, NOT by this handshake: the
        // board streams sentinels only when it actually buffered records, so a connect with the
        // buffer off/empty shows no pill (and can't stick waiting for an end that never comes).
        syncingOfflineLog = false
        offlineSyncCount = 0
        offlineSyncTotal = 0   // the board's {"hist":"begin"} fills this in when a real drain starts
        if case .startup = completion {
            readyStatusSettled = false
            readyOTASettled = false
            readySubscriptionStep = nil
        }
        bufferHandshakeCompletion = completion
        let queued = enqueueBufferHandshakeWrite(.key, key: key)
        if !queued { bufferHandshakeCompletion = nil }
        return queued
    }

    private func enqueueBufferHandshakeWrite(_ step: BufferHandshakeWrite,
                                             key: String? = nil) -> Bool {
        let payload: [String: Any]
        switch step {
        case .key:
            guard let key else { return false }
            payload = ["key": key]
        case .epoch:
            // Capture the reconstruction anchor at the actual epoch-write attempt, after key ACK.
            syncStartedAt = Date()
            payload = ["epoch": Int(Date().timeIntervalSince1970)]
        case .sync:
            payload = replaySyncConfig(cursor: lastGoodSeq)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return enqueueConfigWrite(
            PendingConfigWrite(data: data, purpose: .handshake(step)), prioritize: true)
    }

    private func failBufferHandshake(at step: BufferHandshakeWrite) {
        #if DEBUG
        print("[ACAB-ble] buffer handshake failed at \(step)")
        #endif
        resetConfigWriteQueue()
        connectHint =
            "Secure offline-history setup failed. Reconnect and try again before relying on replay."
        disconnect()
    }

    /// Continue the post-sync subscription chain. Status is intentionally first because its read
    /// can enqueue reconciliation writes; reaching here proves key, epoch and sync were each ACKed.
    private func advancePostSyncReadyChain() {
        guard let peripheral, peripheral.state == .connected else {
            failBufferHandshake(at: .sync)
            return
        }
        let step = postSyncReadyStep(
            statusAvailable: statusChar != nil,
            statusSettled: readyStatusSettled,
            otaAvailable: otaChar != nil,
            otaSettled: readyOTASettled)
        readySubscriptionStep = step
        switch step {
        case .subscribeStatus:
            guard let statusChar else {
                readyStatusSettled = true
                advancePostSyncReadyChain()
                return
            }
            peripheral.setNotifyValue(true, for: statusChar)
        case .subscribeOTA:
            guard let otaChar else {
                readyOTASettled = true
                advancePostSyncReadyChain()
                return
            }
            peripheral.setNotifyValue(true, for: otaChar)
        case .finishReady:
            readySubscriptionStep = nil
            finishReadyAfterBufferHandshake()
        }
    }

    private func resetReplayCursorAfterClearAck() {
        replayCursorEpoch &+= 1
        persistReplayCursor(seq: 0, generation: 0)
        activeLogGeneration = 0
        lastGoodSeq = 0
        histHighestSeq = 0
        histBeginSeen = false
    }

    // MARK: key (Keychain)

    private let keyTag = "tech.beacons.app.bufferKey"

    /// Our persistent 32-byte buffer key as 64 lowercase hex chars. Generated once and
    /// stored in the Keychain, reused on every launch.
    private func bufferKeyHex() -> String? {
        loadOrCreateBufferKey()?.map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrCreateBufferKey() -> Data? {
        resolveDurableBufferKey(
            read: keychainReadKey,
            generate: generateBufferKey,
            install: keychainInstallKey)
    }

    private func generateBufferKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: durableBufferKeyByteCount)
        let status = bytes.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        guard status == errSecSuccess else { return nil }
        let data = Data(bytes)
        return durableBufferKeyIsUsable(data) ? data : nil
    }

    private func keychainReadKey() -> DurableBufferKeyReadResult {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = out as? Data,
              durableBufferKeyIsUsable(data) else { return .unavailable }
        return .found(data)
    }

    /// Add without a delete window, then read back what durable storage actually owns. If another
    /// caller wins a duplicate-add race, use that persistent winner. An existing corrupt or
    /// temporarily unreadable item is never overwritten: it may be the only route to old evidence.
    private func keychainInstallKey(_ data: Data) -> Data? {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
        ]
        var add = base
        add[kSecValueData as String] = data
        // AfterFirstUnlockThisDeviceOnly: readable for the while-locked BLE handshake, but
        // ThisDeviceOnly makes the key non-exportable (kept out of iTunes/Finder backups).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        guard case .found(let persisted) = keychainReadKey() else { return nil }
        return persisted
    }

    // MARK: local persistence (Application Support)

    /// Where we checkpoint filed detections so replayed history survives a relaunch.
    private var persistURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return dir.appendingPathComponent("acab-detections.json")
    }

    /// One persisted detection row: the raw record plus the timing we reconstructed.
    private struct StoredRow: Codable {
        let detection: Detection
        let firstSeen: Date?
        let lastSeen: Date?
        let lat: Double?
        let lon: Double?
        // How the buffered stamp on this row was derived, and which stamp it applies to. Both
        // optional so a file written before this model still decodes; a row without them falls
        // back to the pseudo-stamp test, same as it did then.
        let timeBasis: TimeBasis?
        let basisStamp: Date?
        let basisBoot: UInt32?
        let basisSeq: UInt32?
    }

    private let persistQueue = DispatchQueue(label: "tech.acab.persist", qos: .utility)  // serial, off-main
    /// Checkpoint the store to disk. `completion` runs on the main thread with whether the
    /// write actually landed; anything that commits state the file is supposed to back (the
    /// replay cursor) must wait for it rather than assume success.
    private func persistDetections(completion: ((Bool) -> Void)? = nil) {
        guard let url = persistURL else { completion?(false); return }
        // The tour's sample hits live in the same store, so every checkpoint has to refuse while
        // it's up, or fabricated detections get written to disk and reload as genuine history.
        guard !demoMode else { completion?(false); return }
        // A failed Clear owns the old path until confirmed deletion. Writing post-clear rows into
        // it would either preserve the evidence the user condemned or make the next retry erase new
        // evidence too. Hold those rows in memory; foreground retry checkpoints them after success.
        guard persistedDetectionLoadAllowed(
            clearPending: persistedDetectionClearTombstone.isPending
        ) else { completion?(false); return }
        // Snapshot on the main thread (cheap: just builds value structs from the store), then do the
        // JSON encode + atomic disk write on a background queue. Encoding thousands of rows + writing
        // a multi-MB file was the thing blocking the main thread during a big replay, freezing the log
        // scroll and the radar. `rows` is a value type, so handing it to the async closure is safe.
        let rows = store.values.map { d -> StoredRow in
            let c = capturedLoc[d.id]
            let h = histBasis[d.id]
            return StoredRow(detection: d, firstSeen: firstSeenAt[d.id], lastSeen: lastSeen[d.id],
                             lat: c?.latitude, lon: c?.longitude,
                             timeBasis: h?.basis, basisStamp: h?.stamp,
                             basisBoot: h?.boot, basisSeq: h?.seq)
        }
        // Never let an empty store overwrite a non-empty file. An in-memory reset (exiting the
        // tour, a radio teardown) must not be able to erase real history through the next
        // checkpoint; deleting the log is the confirmed Clear-log path's job and nothing else's.
        if rows.isEmpty {
            let exists = FileManager.default.fileExists(atPath: url.path)
            completion?(!exists)   // nothing to write is only "saved" when there was nothing to lose
            return
        }
        // .completeFileProtectionUnlessOpen: the detections file (MACs + phone GPS + timestamps)
        // still can't be read on a seized locked phone, but .atomic creates a fresh temp file per
        // write, so a checkpoint that lands while the phone is locked (pocketed mid-drive, which is
        // the offline buffer's whole scenario) succeeds instead of silently failing. Plain
        // .completeFileProtection makes every locked write fail.
        persistQueue.async {
            var ok = false
            do {
                let data = try JSONEncoder().encode(rows)
                try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
                // Keep the log out of iCloud/iTunes backups, same as writeProtectedList() does for
                // the ignore/watch lists. File protection guards a SEIZED phone; it does nothing
                // about a backup copy sitting in someone else's cloud, and this file is MACs +
                // phone GPS + timestamps. Re-applied after EVERY write on purpose: .atomic swaps in
                // a brand-new file, so the flag can't survive a checkpoint - which also means an
                // already-written log picks the exclusion up on its next checkpoint, no migration.
                var u = url
                var v = URLResourceValues()
                v.isExcludedFromBackup = true
                try? u.setResourceValues(v)
                ok = true
            } catch {
                ok = false
            }
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    /// Write-ahead checkpoint for the replay path: persist the store, THEN advance the on-disk
    /// resume cursor, and only if the write actually landed. lastSeq is UserDefaults (class C,
    /// writes fine while locked) but the store is a protected file, so committing the cursor
    /// first meant a locked write could fail while the board was told it had nothing pending:
    /// the records were then gone from disk, gone from the board, and reclaimed by auto-wipe.
    /// The cursor is captured at snapshot time, or we'd advance past rows that arrived during
    /// the async encode. On failure lastSeq stays put; the board re-sends and filing is
    /// idempotent by id, so a re-drain costs a little radio and nothing else.
    /// Set while a checkpoint's encode + disk write is still on persistQueue. Mid-drain checkpoints
    /// skip rather than pile up behind it (see the caller); the completion always clears it, on
    /// both the success and failure paths, so a refused write (demo mode, missing URL) cannot wedge
    /// checkpointing off for the rest of the session.
    private var checkpointInFlight = false

    private func checkpointHistory(finalizeGeneration: Bool = false) {
        let cursor = lastGoodSeq
        let generation = activeLogGeneration
        let cursorEpoch = replayCursorEpoch
        checkpointInFlight = true
        persistDetections { [weak self] saved in
            guard let self else { return }
            self.checkpointInFlight = false
            guard saved, cursorEpoch == self.replayCursorEpoch,
                  generation == self.activeLogGeneration else { return }
            let persisted = self.persistedReplayCursor()
            if generation != persisted.generation {
                guard finalizeGeneration, generation != 0 else { return }
            } else if cursor <= persisted.seq {
                return
            }
            self.persistReplayCursor(seq: cursor, generation: generation)
        }
    }

    // Live-path disk checkpoint. The board only buffers while we're AWAY (it skips the buffer
    // entirely while a client is connected), so during a connected drive RAM is the only copy of
    // the session: not on the board, not on disk. A jetsam, a swipe-away or a reboot took the
    // whole drive with it. persistDetections() re-encodes the entire store (up to liveFeedCap
    // rows, a few MB), so this cannot run per detection at an airport-density notify rate. 30 s
    // bounds the exposure to well under a minute while keeping the write rate in the same order
    // as the replay path's every-200-records batch. The tail is covered by the disconnect and
    // background checkpoints, which is where a kill actually happens.
    private var liveCheckpointTimer: Timer?
    private var lastLiveCheckpoint = Date.distantPast
    private let liveCheckpointInterval: TimeInterval = 30

    private func scheduleLiveCheckpoint() {
        guard liveCheckpointTimer == nil else { return }   // a trailing checkpoint is already queued
        let elapsed = Date().timeIntervalSince(lastLiveCheckpoint)
        if elapsed >= liveCheckpointInterval {
            checkpointLive()
        } else {
            liveCheckpointTimer = Timer.scheduledTimer(withTimeInterval: liveCheckpointInterval - elapsed,
                                                       repeats: false) { [weak self] _ in
                self?.liveCheckpointTimer = nil
                self?.checkpointLive()
            }
        }
    }

    /// Checkpoint the live session now. Safe to call from the teardown paths: the empty-store
    /// and demo guards in persistDetections() keep it from destroying anything.
    private func checkpointLive() {
        liveCheckpointTimer?.invalidate()
        liveCheckpointTimer = nil
        lastLiveCheckpoint = Date()
        persistDetections()
    }

    /// Per-row tolerant wrapper for the load path. Decoding the store as a plain `[StoredRow]`
    /// is all-or-nothing: ONE row the current build can't parse (a record written by a newer
    /// app that changed a field's shape, or a row corrupted by a kill mid-write) threw, `try?`
    /// swallowed it, and the WHOLE saved history blanked. This never throws, so a bad element
    /// costs exactly that element and the outer array decode always completes.
    private struct LenientStoredRow: Decodable {
        let row: StoredRow?
        init(from decoder: Decoder) throws { row = try? StoredRow(from: decoder) }
    }

    private func loadPersistedDetections() {
        // A durable Clear tombstone outranks whatever bytes remain at this path. Launch attempts its
        // deletion before reaching here; if that failed, do not even enqueue a decode. Foregrounding
        // retries, and exitDemo's reload observes the same gate.
        guard persistedDetectionLoadAllowed(
            clearPending: persistedDetectionClearTombstone.isPending
        ) else { return }
        let loadToken = persistedDetectionLoadGate.beginLoad()
        // Decode + sort OFF the main thread, then populate the store back ON it. The file caps at
        // liveFeedCap (5000) rows / ~5MB, so doing this inline in init() on the main thread is a
        // launch-watchdog (0x8badf00d) risk on a full log - Android already runs it off-main. CB is
        // created queue: nil (every callback lands on main), so applying the rows back on main keeps
        // store access main-confined and needs no locks. Routed through persistQueue so a load can't
        // race a checkpoint write of the same file. exitDemo() re-runs this after clearing the tour.
        persistQueue.async { [weak self] in
            guard let self,
                  let url = self.persistURL, let data = try? Data(contentsOf: url),
                  let decoded = try? JSONDecoder().decode([LenientStoredRow].self, from: data) else { return }
            let rows = decoded.compactMap(\.row)
            #if DEBUG
            // Skipped rows signal the on-disk shape drifted; surface the count (DEBUG only).
            let skipped = decoded.count - rows.count
            if skipped > 0 {
                print("[ACAB-store] skipped \(skipped) unreadable row(s) of \(decoded.count); kept \(rows.count)")
            }
            #endif
            // CAP THE RELOAD to liveFeedCap, MIRRORING publishDetections' eviction: keep real flags,
            // drop ambient Desert rows first (a plain newest-first cut would discard an old body-cam
            // hit to make room for a fresh confidence-0 phone). Defensive today - the file is written
            // from the already-capped store - but must not be the one place that prefers noise over
            // evidence if that stops being true (e.g. a file from a build with a larger cap).
            let byRecency = rows.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            let flags   = byRecency.filter { $0.detection.type != .nearbyDevice }
            let ambient = byRecency.filter { $0.detection.type == .nearbyDevice }
            let newest  = flags.count >= self.liveFeedCap
                ? Array(flags.prefix(self.liveFeedCap))
                : flags + ambient.prefix(self.liveFeedCap - flags.count)
            DispatchQueue.main.async {
                guard self.persistedDetectionLoadGate.accepts(loadToken),
                      persistedDetectionLoadAllowed(
                        clearPending: self.persistedDetectionClearTombstone.isPending
                      ) else { return }
                self.applyLoadedRows(newest)
            }
        }
    }

    /// Checkpoint-boundary twin of the wire-side `at` clamp in Detection.init(from:). A file
    /// written by a build BEFORE that clamp can carry a poisoned Date (the wire `at` was decoded
    /// unchecked and checkpointed), and StoredRow's own Date fields never pass through
    /// Detection.init(from:), so the load path must guard them itself or the poisoned stamp
    /// reaches the same trapping Int conversions the wire clamp exists to protect.
    private static func sanitizedStoredDate(_ d: Date?) -> Date? {
        guard let d else { return nil }
        let t = d.timeIntervalSince1970
        return t.isFinite && (0...4_294_967_295).contains(t) ? d : nil
    }

    /// Populate the store from a decoded, capped, recency-sorted batch. MAIN THREAD only (the store
    /// is main-confined; CB runs queue: nil). Split out of loadPersistedDetections so the heavy
    /// decode + sort can run off-main without moving store access off it.
    private func applyLoadedRows(_ newest: [StoredRow]) {
        // A load landing mid-tour must not inject real history into the sample store; exitDemo()
        // re-runs the load once the tour ends, so skipping here loses nothing.
        guard !demoMode else { return }
        for r in newest {
            let d = r.detection
            // Fresh live ingest (a connect inside the ~1s load window) wins over stale persisted
            // data; the load almost always lands first, so this only matters for that rare race.
            if store[d.id] != nil { continue }
            store[d.id] = d
            // Clamped, not raw: see sanitizedStoredDate. A poisoned stamp is dropped entirely,
            // which degrades the row to "time unknown" instead of a crash-on-open.
            let rowFirstSeen = Self.sanitizedStoredDate(r.firstSeen)
            if let f = rowFirstSeen { firstSeenAt[d.id] = f }
            if let l = Self.sanitizedStoredDate(r.lastSeen) { lastSeen[d.id] = l }
            if let b = r.timeBasis, let s = Self.sanitizedStoredDate(r.basisStamp) {
                histBasis[d.id] = HistoryStamp(stamp: s, boot: r.basisBoot, seq: r.basisSeq ?? 0, basis: b)
            } else if d.offline, let f = rowFirstSeen, !isApproxTime(f) {
                // A row checkpointed before TimeBasis existed carries no basis, and leaving
                // histBasis empty makes timeBasis(for:) fall through isApproxTime to .exact,
                // labelling a board-derived time as a phone-clock measurement. Its instant IS real
                // (the board reconstructed it from an uptime anchor), but its error bar was never
                // written down, so call it reconstructed and let the precision widen with age: an
                // old row gets a deliberately wide bar rather than a fabricated tight one.
                // Mirrors the Android reload, which already covers this boundary. Live rows are
                // untouched, they are not offline.
                // The !isApproxTime guard is the axis test that keeps this honest: a pre-basis
                // APPROX row carries only the seq-derived pseudo stamp (no instant was ever
                // reconstructed for it), and calling THAT reconstructed would export a confident
                // near-epoch date with time_basis=reconstructed in the evidence CSV - the exact
                // fabricated timestamp this model exists to prevent. Left basis-less, it falls
                // through isApproxTime to .unknown, which the CSV correctly blanks.
                histBasis[d.id] = HistoryStamp(stamp: f, boot: d.bootCount, seq: d.seq ?? 0,
                                               basis: .reconstructed(precisionSec: reconstructedPrecision(at: f)))
            }
            // Rebuild the cross-session boot anchors off the reloaded log, so a drain in THIS
            // session can bracket against boots anchored in an earlier one. Reconstructed rows
            // only: their stamp is the board-resolved instant (never rekeyed), which is exactly
            // what an anchor is. Matches the Android reload's bootMinAt/bootMaxAt rebuild.
            if let h = histBasis[d.id], case .reconstructed = h.basis, let boot = h.boot {
                let span = histAnchoredBoots[boot]
                histAnchoredBoots[boot] = (min: min(span?.min ?? h.stamp, h.stamp),
                                           max: max(span?.max ?? h.stamp, h.stamp))
            }
            if let lat = r.lat, let lon = r.lon {
                let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if CLLocationCoordinate2DIsValid(c) { capturedLoc[d.id] = c }   // never reload junk into the map
            }
        }
        publishDetections()
    }

    /// Serialize with every checkpoint AND wait for a confirmed outcome. A pre-clear checkpoint may
    /// already own persistQueue and atomically replace the file after its snapshot was taken; sync
    /// puts deletion after that write and prevents Clear from returning while only a best-effort
    /// block is queued. This method is main-thread-only at all call sites.
    private func deletePersistedDetectionsSynchronously() -> Bool {
        guard let url = persistURL else { return false }
        return persistQueue.sync {
            performConfirmedPersistedDetectionDeletion(
                fileExists: { FileManager.default.fileExists(atPath: url.path) },
                remove: { try FileManager.default.removeItem(at: url) })
        }
    }

    /// Resolve a durable Clear intent on the real store. Called at the tap, before launch loading,
    /// and on every foreground. The tombstone survives every failure/process-death boundary and is
    /// retired only after confirmed absence; a failed retirement remains pending too.
    @discardableResult
    private func retryPendingDetectionClear(
        checkpointCurrentStoreOnSuccess: Bool = false
    ) -> Bool {
        guard persistedDetectionClearTombstone.isPending else { return true }
        persistedDetectionLoadGate.invalidate()
        guard deletePersistedDetectionsSynchronously(),
              persistedDetectionClearTombstone.retire() else { return false }
        // Rows captured AFTER a failed clear were deliberately held in memory while the tombstone
        // owned the path. Once the old file is gone, a foreground retry may safely seal them.
        if checkpointCurrentStoreOnSuccess, !demoMode, !store.isEmpty { checkpointLive() }
        return true
    }

    // MARK: - Decoding

    // Hot path: every detection notify from the board lands here. This carries both
    // live detections and, during a buffer drain, replayed history records plus a
    // closing sentinel.
    // The drain sentinels carry `hist` as a STRING, so their compact JSON always contains the
    // `"hist":"` byte sequence; live + history records (hist as a bool) never do. Byte-scan for
    // it before paying for a JSONSerialization pass on every notify.
    private static let histStringMarker = Data("\"hist\":\"".utf8)

    private func ingestDetection(_ data: Data) {
        // The drain brackets its records with sentinels: {"hist":"begin","n":N} up front (so we
        // can show a determinate "X of N"), and {"hist":"end","n":N} to verify the count. Both
        // carry `hist` as a STRING (live/history records use a bool), so catch those first. The
        // byte-scan prefilter keeps JSONSerialization off the hot path for the common record case.
        if data.range(of: Self.histStringMarker) != nil,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let phase = obj["hist"] as? String {
            if phase == "begin" {
                histBeginSeen = true
                // Clamp to the uint32 wire range: n and the derived arithmetic (promised -
                // expected in handleHistEnd) must stay overflow-safe against an impostor board
                // sending Int.max/Int.min.
                offlineSyncTotal = min(4_294_967_295, max(0, (obj["n"] as? Int) ?? 0))
                if offlineSyncTotal > 0 { syncingOfflineLog = true }   // a real replay is starting
                // "from" is the first sequence in this drain; "gen" is the board's unpredictable
                // record-generation token. A changed generation gives every numeric sequence a
                // new meaning, even when from is ABOVE the old cursor, so rebase to from-1 and do
                // not make the new tuple durable until the detection store checkpoint lands.
                // Older firmware omits gen; its downward-from fallback remains supported.
                // Read the original JSON numeric token, not Foundation's rounded NSNumber: a
                // precision-hidden fraction such as 1.0000000000000000001 is not an integer cursor.
                let from = Detection.exactWireUInt32(forKey: "from", in: data)
                let generation = Detection.exactWireUInt32(forKey: "gen", in: data)
                let rebased = from.flatMap { $0 >= 1 ? $0 - 1 : nil } ?? 0
                if obj.keys.contains("gen"), generation == nil || generation == 0 {
                    activeLogGeneration = 0
                    replayCursorEpoch &+= 1
                    lastGoodSeq = rebased
                    histHighestSeq = rebased
                } else if let generation, generation > 0, generation != activeLogGeneration {
                    // A wipe gives numeric seqs a new meaning even if this fresh generation has
                    // already grown beyond the old cursor. Keep the rebase in memory until the
                    // store checkpoint lands; a crash leaves the persisted generation mismatched
                    // and firmware safely offers the full window again.
                    replayCursorEpoch &+= 1
                    activeLogGeneration = generation
                    lastGoodSeq = rebased
                    histHighestSeq = rebased
                } else if let from, from >= 1, rebased < lastGoodSeq {
                    replayCursorEpoch &+= 1
                    lastGoodSeq = rebased
                    histHighestSeq = rebased   // clean-end cursor advances to this; must drop too
                    lastSeq = rebased          // legacy firmware has no generation to reject stale syncs
                }
            } else if phase == "end" {
                // Same uint32 clamp as begin: keeps promised - expected inside safe Int range.
                handleHistEnd(expected: min(4_294_967_295, max(0, (obj["n"] as? Int) ?? histReceived)))
            }
            return
        }

        guard let d = try? Detection.decodeWireJSON(data) else {
            // Undecodable record - a garbled/truncated frame. (Unknown wire TYPES no longer land
            // here: Detection files them as .unknown rows now.) During a buffer drain it must
            // STILL run the drain bookkeeping: the board's end sentinel counts every record it
            // sent, so exiting before the count left histReceived short and handleHistEnd burned
            // its full histResyncCap budget re-requesting a tail that can never decode, on every
            // reconnect, for the life of the buffer. Pull just the bits the bookkeeping needs
            // off the raw frame; live frames keep the plain drop.
            // THE SECOND DECODE BOUNDARY for `seq`, and it clamps exactly like the first one
            // (Detection.decodeWireJSON): exact raw numeric lexeme for the wire type, then drop the
            // firmware's own empty-slot sentinels 0 and 0xFFFFFFFF, which det_log.cpp's
            // slotValid() rejects so a genuine board can never send either. A garbled frame is
            // the ONE frame an impostor gets to choose the bytes of, so the boundary that reads
            // it raw must not be the softer of the two: an accepted 0xFFFFFFFF rides
            // histHighestSeq into lastGoodSeq, gets checkpointed into `acab.lastSeq`, and then
            // traps the next record on lastGoodSeq + 1 - a crash that survives relaunch because
            // the poison is on disk. The record is still received and still counted toward the
            // drain tally; it just moves no cursor. Android twin: Detection.fromJson's seq clamp
            // in Models.kt, whose "no seq" sentinel is 0 rather than nil.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["hist"] as? Bool) == true {
                recordHistoryProgress(seq: Detection.exactWireUInt32(forKey: "seq", in: data)
                    .flatMap { $0 == 0 || $0 == UInt32.max ? nil : $0 })
                schedulePublish()   // the syncing pill's count still climbs, at the coalesced rate
            }
            return
        }
        if isIgnored(d.mac) {
            // Whitelisted: file nothing, alert on nothing. But a replayed HISTORY record must
            // still run the drain bookkeeping: the board's end sentinel counts every record it
            // sent (its replay path has no ignore filter - it can hold records buffered before
            // the MAC was ignored), so dropping one before the count left histReceived short on
            // every pass and the gap retry re-requested the same tail forever. Live frames keep
            // the plain drop (the board suppresses those at capture anyway).
            if d.isHistory {
                recordHistoryProgress(d)
                schedulePublish()   // the syncing pill's count still climbs, at the coalesced rate
            }
            return
        }

        let firstTime = store[d.id] == nil

        // Filed BEFORE the closest-approach block below (it used to run after), so the smoothing
        // there averages a window that INCLUDES this sample - the same order Android files in
        // (fileLive() calls file() first, then smooths). Nothing between here and there reads
        // rssiHistory, so moving it up only changes what the smoother can see.
        var h = rssiHistory[d.id] ?? []
        h.append(d.rssi); if h.count > 48 { h.removeFirst(h.count - 48) }  // keep the last 48
        rssiHistory[d.id] = h

        if d.isHistory {
            // Replayed buffered record: file it with its original time, no alert.
            ingestHistory(d, firstTime: firstTime)
        } else {
            // One clock read names this live sighting everywhere. Stop deliberately pairs ledger
            // row, lastSeen, and observer fix at this exact instant; separate Date() calls can
            // straddle a millisecond boundary and erase a valid capture-local fix.
            let observedAt = Date()
            if firstTime {                   // first sighting: stamp time and place
                firstSeenAt[d.id] = observedAt
                capturedLoc[d.id] = freshCoord   // no location beats a stale one on the map and in the CSV
                bestRssi[d.id] = d.rssi           // baseline the closest-approach pin chases from here
            } else if let coord = freshCoord {
                // `capturedLoc` is the PHONE/observer position and is independent of d.coordinate.
                // A drone's d.coordinate is the AIRCRAFT's Remote ID broadcast; it must not block
                // acquiring a later phone fix for approx_lat/lon after the first sighting arrived
                // without one. Two DIFFERENT jobs live here: ACQUIRING a first observer position
                // for any detection, and REFINING a non-drone fallback pin at closest approach.
                //
                // Acquisition can't be gated on the hysteresis. capturedLoc is a dictionary of
                // non-optional values, so stamping it with a nil freshCoord above leaves the key
                // ABSENT while bestRssi is still baselined; a device first heard without a fix (or
                // filed from the offline buffer, where ingestHistory sets no bestRssi at all) then
                // had to get 4 dB LOUDER than its own baseline to ever be placed, which a close,
                // roughly-stationary device never does. It simply never showed on the map.
                let smoothed = smoothedRssi(for: d.id, fallback: d.rssi)
                if capturedLoc[d.id] == nil {
                    // Acquire for EVERY type, including a drone that already has aircraft coords.
                    capturedLoc[d.id] = coord
                    bestRssi[d.id] = smoothed
                } else if d.coordinate == nil, let best = bestRssi[d.id], smoothed >= best + 4 {
                    // Refine: only MOVE an existing pin. A stronger sighting means we are
                    // physically nearer, so the pin chases where we heard it best. The 4 dB gate
                    // is hysteresis: RSSI wobbles a few dB at rest. Any row with its own coordinate
                    // maps there instead, so its independently captured observer fix need not
                    // chase signal strength once acquired. A no-position drone still refines the
                    // observer fallback exactly as before.
                    capturedLoc[d.id] = coord
                    bestRssi[d.id] = smoothed
                }
            }
            store[d.id] = d
            lastSeen[d.id] = observedAt
            recordContributionObservation(d, observedAt: observedAt,
                                           observerLocation: freshCoord)
        }

        if d.type == .drone, let c = d.coordinate {       // grow the drone's flight path
            var t = trackHistory[d.id] ?? []
            if t.last?.latitude != c.latitude || t.last?.longitude != c.longitude {
                t.append(c); if t.count > 60 { t.removeFirst(t.count - 60) }
                trackHistory[d.id] = t
            }
        }
        // Tracker breadcrumb: drop a crumb of the PHONE's position while a separated tracker
        // (with-owner tags are hushed upstream) stays with us. LIVE only - a replayed record's
        // "now" position is meaningless. Gated so a parked phone doesn't pile crumbs on one spot:
        // at least 60 s since the last crumb AND at least 25 m of real movement from it. Capped at
        // 120, oldest dropped, session-only like trackHistory.
        if !d.isHistory, d.type == .tracker, let coord = freshCoord {
            let now = Date()
            let farEnough = crumbHistory[d.id]?.last.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                    .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)) >= 25
            } ?? true
            let longEnough = lastCrumbAt[d.id].map { now.timeIntervalSince($0) >= 60 } ?? true
            if farEnough, longEnough {
                var c = crumbHistory[d.id] ?? []
                c.append(coord); if c.count > 120 { c.removeFirst(c.count - 120) }
                crumbHistory[d.id] = c
                lastCrumbAt[d.id] = now
                // Only when absent, so this stays the START of the window rather than tracking the
                // latest crumb. Set here and nowhere else: the follow scorer's duration is only
                // honest if its opening stamp is the moment a crumb actually landed.
                // Known limit, stated rather than hidden: the 120 cap above can drop the crumb this
                // stamp names (120 crumbs at 60 s minimum spacing is a run over two hours long), and
                // the stamp is deliberately NOT advanced with it. Erring long here only ever makes
                // the mean-gap test stricter and the run look older, both of which under-claim.
                if firstCrumbAt[d.id] == nil { firstCrumbAt[d.id] = now }
            }
        }
        schedulePublish()   // coalesced: a Desert-mode firehose updates the feed a few Hz, not per-record
        // (Replayed-history persistence is BATCHED in ingestHistory + handleHistEnd, NOT per record:
        // a full-store disk write on every one of thousands of replayed records jams the main thread.
        // Live rows get their own, slower checkpoint: the board does not buffer while we're
        // connected, so nothing else is holding this session.)
        if !d.isHistory { scheduleLiveCheckpoint() }
        // Live sightings buzz, past their per-device cooldown; replayed history never does.
        // `hapticDue` RECORDS, so it stays LAST: the cheap gates short-circuit ahead of it, and a
        // buzz suppressed by Focus must not start the cooldown that suppressed it.
        if !d.isHistory, alertMode == .vibrate, !focusActive, hapticDue(d.mac) { alertHaptic(for: d.type) }
        // Phone notification, per category, opt-in. Deliberately INDEPENDENT of alertMode: that
        // governs the board's buzzer, and choosing a silent board is not the same as choosing a
        // silent phone. Ignored devices never reach here (dropped above), so one cannot notify.
        //
        // NOT gated on `firstTime`, deliberately. `firstTime` is `store[d.id] == nil`, and the store
        // is PERSISTED across launches, so a device seen in any previous session was never first
        // again and could never notify. The notifier owns the dedup via its per-device cooldown,
        // which is what the settings copy actually promises.
        if !d.isHistory, DetectionNotifier.anyEnabled {
            notifier.silenceForeground = (alertMode != .buzzer) && focusActive
            notifier.notifyIfNeeded(d)
        }
        // Drive mode: push the live count to the Dynamic Island / Lock Screen. History never
        // updates. A brand-new device escalates (immediate), but only for the categories that
        // change what the activity shows (the six counter buckets - Desert-mode .nearbyDevice and
        // a starred .watched row both fill none, so escalating for them spent the gap on a
        // ContentState nothing had changed; network cameras have had a bucket since 2026-07-31,
        // when the columns became toggle-driven) and
        // at most one escalation per escalateMinGap: everything else rides the controller's
        // coalescer, so the counts still land within its window.
        if !d.isHistory {
            if driveModeOn {
                var escalate = false
                if firstTime && d.type.onDriveSurface {
                    escalate = Date().timeIntervalSince(lastEscalatedPush) >= escalateMinGap
                }
                if escalate {
                    lastEscalatedPush = Date()
                    publishDetections()   // an immediate push must carry the fresh bucket counts, not the coalesced ones
                    liveActivity.update(liveState(), escalate: true)
                }
            }
        }
    }

    /// File one replayed buffered record. Uses the record's own timestamp ("at") when
    /// the board knew it; otherwise a synthetic monotonically-DECREASING pseudo-time
    /// derived from seq, so the newest-first sort in publishDetections() leaves history
    /// behind live hits instead of pulling it to "now".
    private func ingestHistory(_ d: Detection, firstTime: Bool) {
        let stamp: Date
        let basis: TimeBasis
        if let at = d.capturedAt {
            stamp = at                       // absolute time the board reconstructed for it
            basis = .reconstructed(precisionSec: reconstructedPrecision(at: at))
            // Remember the boot this proves was anchored, and how far the anchored window
            // reaches, so the boots that were never anchored can be bounded at the end sentinel.
            if let boot = d.bootCount {
                let span = histAnchoredBoots[boot]
                histAnchoredBoots[boot] = (min: min(span?.min ?? at, at), max: max(span?.max ?? at, at))
            }
        } else {
            // approx: the phone never connected during that boot, so the board holds no anchor to
            // date it against. Fabricate a strictly-decreasing ordering key well in the past, and
            // file it as UNKNOWN. resolveBracketedHistory() upgrades it to a real bracket at the
            // end of the drain, once the anchored boots on both sides are known.
            histPseudoTick += 1
            stamp = histPseudoBase.addingTimeInterval(-Double(histPseudoTick))
            basis = .unknown
        }
        // Don't let a replayed record clobber a fresher live entry or an earlier-filed
        // history record for the same id.
        if firstTime {
            firstSeenAt[d.id] = stamp
            // NOT for a drone. capturedLoc means "where the PHONE was", and it feeds approx_lat/lon
            // in the CSV and the "Heard:" waypoint in the GPX. For a drone, d.coordinate is the
            // AIRCRAFT's own Remote ID broadcast (the `lat`,`lon` row of ble-protocol.md's
            // detection-frame table: "drones = the aircraft's own broadcast position; everything
            // else = the DETECTOR's GPS"), so storing it here labelled the aircraft as the
            // observer. The firmware makes the same distinction at the source - acab_scanner.cpp
            // gates its detector-GPS stamp on `d.type != ACAB_DRONE`. A replayed drone therefore
            // has NO known observer position, which is the truth; its own position still exports
            // via drone_lat/lon and its own GPX waypoint.
            capturedLoc[d.id] = (d.type == .drone) ? nil : d.coordinate
            store[d.id] = d
            lastSeen[d.id] = stamp
            noteHistoryBasis(d, stamp: stamp, basis: basis)
        } else if let existing = lastSeen[d.id], stamp < existing {
            // keep the newer of the two as the sort key, but make sure the record exists
            if store[d.id] == nil { store[d.id] = d }
            // ...but a buffered record that genuinely PREDATES the stored first-seen has to pull
            // it back, or first-seen ends up order-dependent. A device still present when you
            // reconnect emits a live advert while the drain is still running, so the live record
            // usually wins the race, stamps firstSeenAt at the reconnect moment, and this branch
            // then discarded the earlier record entirely: the row claimed it was first heard when
            // you walked back into range, not when the board actually logged it.
            //
            // The axis guard is what makes this safe, and it is why the naive "stamp < f" version
            // would be a BUG: an unanchored record is stamped histPseudoBase - tick, which sorts
            // below every real capture by construction, so without the guard a pseudo-time would
            // always beat a real first-seen and replace a measured time with a synthetic one.
            // Only compare stamps on the same axis. Mirrors Android's rule in AcabBleManager.
            let prevFirst = firstSeenAt[d.id]
            if prevFirst == nil || (isApproxTime(prevFirst) == isApproxTime(stamp) && stamp < prevFirst!) {
                firstSeenAt[d.id] = stamp
                noteHistoryBasis(d, stamp: stamp, basis: basis)
            }
        } else {
            store[d.id] = d
            lastSeen[d.id] = stamp
            // The basis describes how firstSeenAt was DERIVED, and timeBasis(for:) looks it up by
            // that exact stamp, so it may only be rebound when firstSeenAt itself moves. Rebinding
            // it to this newer record's stamp (which the old code did unconditionally) left
            // histBasis.stamp != firstSeenAt, the lookup guard then missed, and the row fell
            // through to isApproxTime, which sees a real reconstructed date and answers .exact.
            // A second buffered record for the same device therefore silently PROMOTED a
            // reconstructed first-seen to a measured one: the log row lost its RECON tag, the
            // dossier lost the "~" and the +/- note, and the CSV wrote time_basis=exact with an
            // empty precision for a time derived from an uptime counter.
            // It also stranded the reverse case: an id whose first record was unanchored and whose
            // second was anchored stopped being .unknown, so resolveBracketedHistory skipped it and
            // it showed "time unknown" forever instead of getting bracketed.
            if firstSeenAt[d.id] == nil {
                firstSeenAt[d.id] = stamp
                noteHistoryBasis(d, stamp: stamp, basis: basis)
            }
        }

        recordHistoryProgress(d)
    }

    private func noteHistoryBasis(_ d: Detection, stamp: Date, basis: TimeBasis) {
        histBasis[d.id] = HistoryStamp(stamp: stamp, boot: d.bootCount, seq: d.seq ?? 0, basis: basis)
    }

    /// Error bar on a board-reconstructed timestamp, in whole seconds.
    ///
    /// The board resolves a record as anchor.epochUnix - (anchor.atMs - whenMs)/1000, and the
    /// crystal it counted those milliseconds on drifts. We are not told anchor.atMs, so we
    /// approximate the drifting interval as (this sync's epoch push -> the reconstructed time).
    ///
    /// Why that errs WIDE, which is the only acceptable direction for a number read as evidence:
    /// the real drifting interval is (anchorTime - captureTime); ours is (pushTime - captureTime).
    /// Ours is the larger of the two exactly when pushTime >= anchorTime, i.e. when the anchor is
    /// OLDER than or equal to this push. That always holds, because the board writes an anchor at
    /// the moment it receives an epoch push (det_log.cpp detLogSetEpoch), so the newest anchor it
    /// can hold for a record's boot is the one from this very push. Never NEWER than the push.
    /// (An earlier version of this note had the condition backwards, saying "whenever the anchor
    /// is more recent than the push". The conclusion was right and the code was right; only the
    /// stated reason was inverted, and this comment is the sole written justification for the
    /// error bar's direction, so it needs to argue for the direction it actually takes.)
    ///
    /// One term this does NOT yet include: the pushed epoch is whole unix seconds on the wire
    /// (acab_ble_service.cpp takes a uint32), so every anchor is quantized to 1 s. That is inside
    /// the 2 s floor in ReconstructedTime, so it never changes the answer today, but it is a real
    /// term and it would matter if the floor were ever lowered.
    private func reconstructedPrecision(at: Date) -> Int {
        let anchorMoment = syncStartedAt ?? Date()
        return ReconstructedTime.precisionSec(elapsedSec: anchorMoment.timeIntervalSince(at))
    }

    /// Bound the boots the phone never anchored against the boots it did.
    ///
    /// Runs once, at the end sentinel, because a boot's UPPER bound can only come from a boot
    /// replayed AFTER it. The firmware increments and persists gBoot every boot, so boot counters
    /// are monotonic and "an earlier boot" is exactly "a lower boot number".
    ///
    /// Rows left over from an earlier drain are re-checked too: a boot number ordered against
    /// this drain's anchors just as soundly as against its own, so a later sync can tighten a row
    /// that was undateable when it first arrived.
    private func resolveBracketedHistory() {
        let anchoredBoots = histAnchoredBoots.keys.sorted()
        // Group the still-unknown rows by the boot that captured them, then walk each group in
        // seq order so the ordering keys we hand out below stay in capture order.
        var pendingByBoot: [UInt32: [String]] = [:]
        for (id, h) in histBasis where h.basis == .unknown {
            guard let boot = h.boot else { continue }      // pre-"boot" firmware: nothing to order by
            pendingByBoot[boot, default: []].append(id)
        }
        var stillUnknown: [(boot: UInt32, seq: UInt32, id: String)] = []
        for (boot, ids) in pendingByBoot {
            let after  = anchoredBoots.filter { $0 < boot }.compactMap { histAnchoredBoots[$0]?.max }.max()
            // The HIGHEST unanchored boot has no anchored boot above it, so the anchored-boots
            // scan alone always leaves it open-ended ("after X"). But a buffered record was
            // necessarily captured BEFORE we connected to collect it, and syncStartedAt is exactly
            // that moment, so the sync itself is a sound upper bound. Using it turns the weakest,
            // most-recent, most-likely-to-matter bracket from "after X" into "between X and <sync>".
            // Not using a bound we hold understates what is actually known, which in an evidence
            // log is a real loss, not just a cosmetic one.
            let before = anchoredBoots.filter { $0 > boot }.compactMap { histAnchoredBoots[$0]?.min }.min()
                      ?? syncStartedAt
            let ordered = ids.sorted { (histBasis[$0]?.seq ?? 0) < (histBasis[$1]?.seq ?? 0) }
            guard after != nil || before != nil else {
                stillUnknown += ordered.map { (boot: boot, seq: histBasis[$0]?.seq ?? 0, id: $0) }
                continue
            }
            for (i, id) in ordered.enumerated() {
                guard let h = histBasis[id] else { continue }
                let key = orderingKey(index: i, of: ordered.count, after: after, before: before)
                rekey(id, from: h, to: key, basis: .bracketed(after: after, before: before))
            }
        }
        // Rows nothing can bound stay unknown, and stay in the pseudo-time band just above the
        // epoch: with no anchored boot on either side there is no honest place to put them, and
        // the bottom of the log claims the least. Re-key the band anyway so it reads in boot then
        // seq order, because the ingest tick hands out DECREASING stamps and a newest-first list
        // shows that backwards.
        guard !stillUnknown.isEmpty else { return }
        let band = stillUnknown.sorted { ($0.boot, $0.seq) < ($1.boot, $1.seq) }
        for (i, e) in band.enumerated() {
            guard let h = histBasis[e.id] else { continue }
            rekey(e.id, from: h, to: histPseudoBase.addingTimeInterval(-Double(band.count - i)), basis: .unknown)
        }
    }

    /// Move a history row onto a new ordering key. Only the stamps this record actually wrote are
    /// touched: if the live path has since stamped the row, that stamp is a real clock reading and
    /// must survive untouched.
    private func rekey(_ id: String, from h: HistoryStamp, to key: Date, basis: TimeBasis) {
        if firstSeenAt[id] == h.stamp { firstSeenAt[id] = key }
        if lastSeen[id] == h.stamp { lastSeen[id] = key }
        histBasis[id] = HistoryStamp(stamp: key, boot: h.boot, seq: h.seq, basis: basis)
    }

    /// A sort position for a bracketed row, and ONLY a sort position. The row renders its range,
    /// never this value, so spreading the group evenly across the bracket claims nothing: it just
    /// keeps the rows contiguous, in capture order, and sitting between the anchored boots that
    /// bound them instead of piled at the unix epoch. One-sided brackets step off their single
    /// bound in milliseconds, which is far below any real gap between boots.
    private func orderingKey(index i: Int, of count: Int, after: Date?, before: Date?) -> Date {
        let step: TimeInterval = 0.001
        switch (after, before) {
        case let (a?, b?):
            let share = Double(i + 1) / Double(count + 1)
            return a.addingTimeInterval(b.timeIntervalSince(a) * share)
        case let (a?, nil):
            return a.addingTimeInterval(step * Double(i + 1))
        case let (nil, b?):
            return b.addingTimeInterval(-step * Double(count - i))
        default:
            return histPseudoBase
        }
    }

    /// How `stamp` on row `id` came to be, for anything that prints or exports a time.
    ///
    /// Asked per STAMP, not per row, because one row can carry both a buffered stamp and a live
    /// one (see HistoryStamp). A stamp we have no history record for was written by the live
    /// path and is a real clock reading, EXCEPT for rows checkpointed by a build that predates
    /// this model: those carry only the near-epoch pseudo stamp, which isApproxTime still
    /// recognises. Mirrors Android's timeBasis().
    func timeBasis(for id: String, stamp: Date?) -> TimeBasis {
        // A nil stamp is not a measured clock reading - it is the absence of one - so it must
        // not come back certified .exact. .unknown is the same answer a near-epoch pseudo stamp
        // gets, and it can only reach a caller that has no time to print in the first place.
        // Android's twin cannot hit this case: its stamps are non-null by type.
        guard let stamp else { return .unknown }
        guard let h = histBasis[id], h.stamp == stamp else {
            return isApproxTime(stamp) ? .unknown : .exact
        }
        return h.basis
    }

    /// The basis on the row's first-sighting stamp, which is the one the log and the export
    /// lead with.
    func timeBasis(for id: String) -> TimeBasis { timeBasis(for: id, stamp: firstSeenAt[id]) }

    /// Drain bookkeeping for ONE replayed record, filed or not. Ignored-MAC records run this
    /// too - they were received, only their filing is filtered - so the count can converge on
    /// the board's end sentinel instead of resyncing forever. Undecodable records go through
    /// the seq-only overload below: received is received, whatever the app made of the bytes.
    private func recordHistoryProgress(_ d: Detection) { recordHistoryProgress(seq: d.seq) }

    private func recordHistoryProgress(seq: UInt32?) {
        histReceived += 1
        // offlineSyncCount (the pill's live count) is mirrored from histReceived inside
        // publishDetections(), i.e. at the coalesced ~3 Hz cadence: a per-record @Published
        // write here defeated the coalescer and re-rendered every mounted tab per record.
        // A record whose begin notify was lost is retained as evidence, but cannot move a cursor
        // whose generation was never established. The fresh-envelope retry re-files it safely.
        if historyEnvelopeAuthorizesCheckpoint(beginSeen: histBeginSeen), let s = seq {
            // Advance the contiguous high-water mark only on an in-order seq (mid-drain
            // checkpoints and the gap retry resume from it), but also remember the highest seq
            // actually RECEIVED: the clean-end cursor advances to that, or a legacy board-side
            // skip/torn slot would pin a full-tail re-replay on every reconnect forever. Current
            // firmware does not skip an over-MTU row: it leaves that row uncommitted and ends the
            // attempt short so it remains eligible for a later retry.
            // `lastGoodSeq < .max` before the + 1: the cursor is restored from UserDefaults on
            // every connect, so an out-of-range value already on disk must not trap arithmetic
            // here. Detection's decoder rejects the 0xFFFFFFFF sentinel, so this guard can only
            // fire on a poisoned stored cursor, and at the ceiling there is no next seq anyway.
            if lastGoodSeq < .max, s == lastGoodSeq + 1 { lastGoodSeq = s }
            if s > histHighestSeq { histHighestSeq = s }
        }
        // Batch the disk write: persisting the whole (up to 5000-row) store on EVERY replayed record
        // jams the main thread on a big drain. Checkpoint every ~200 instead; handleHistEnd does the
        // final persist, and a re-drained record is idempotent by id, so a crash mid-drain loses nothing.
        // The persisted resume cursor rides the SAME checkpoint (see checkpointHistory) so it can
        // never move ahead of the write it depends on; without any mid-drain checkpoint, lastSeq only
        // advances at a clean end and a disconnect partway through a long replay restarts the lot.
        // Mid-drain checkpoint, guarded. Each one re-encodes the WHOLE store, so without a guard a
        // long replay queues N/200 whole-store encodes into a serial queue that cannot keep up, and
        // every pending block retains its own multi-MB rows array. Today's ring is tiny (Desert rows
        // are never buffered, so a 113-minute drive leaves ~74 records and this never even fires),
        // but that is a property of the current data, not of the code. Skip if one is still in
        // flight; handleHistEnd's final checkpoint is the one that has to be complete.
        if historyEnvelopeAuthorizesCheckpoint(beginSeen: histBeginSeen),
           histReceived % 200 == 0, !checkpointInFlight { checkpointHistory() }
    }

    /// End-of-drain sentinel. Verify we got every record the board promised; if a seq
    /// gap dropped some, re-issue {sync} from the last contiguous seq to refill - at most
    /// histResyncCap times per connection, because a record the phone can never receive
    /// would otherwise loop the drain forever. At the cap, stop this connection's retry loop but
    /// retain the contiguous cursor so the missing sequence remains eligible on reconnect.
    private func handleHistEnd(expected: Int) {
        let received = histReceived
        let beginSeen = histBeginSeen
        let disposition = historyEndDisposition(
            received: received, expected: expected,
            resyncAttempts: histResyncs, resyncCap: histResyncCap,
            beginSeen: beginSeen)
        if disposition != .retryNow {
            // Advance the cursor to the highest seq actually RECEIVED, not just the highest
            // contiguous one: a matching count proves nothing was lost on the wire, so any
            // remaining seq gap is a legacy board-side skip/torn slot that this drain cannot
            // refill - a contiguous-only cursor would pin below it and re-replay the full tail on
            // every reconnect for the life of the buffer. Current firmware's over-MTU path stops
            // before committing the blocked row, so that case appears as begin.n > end.n instead
            // and the row remains eligible for a later larger-MTU/corrected attempt. At the retry
            // cap a wire gap is different: keep lastGoodSeq contiguous, checkpoint
            // the idempotently filed rows, and retry the missing sequence on a later connection.
            if beginSeen, disposition == .complete, histHighestSeq > lastGoodSeq {
                lastGoodSeq = histHighestSeq
            }
            // Bound the undateable boots BEFORE the checkpoint, or the brackets we just worked
            // out are the one thing the on-disk copy is missing. It re-keys sort stamps, so the
            // feed has to be re-sorted after it.
            if historyEnvelopeAuthorizesCheckpoint(beginSeen: beginSeen) {
                resolveBracketedHistory()
                publishDetections()
                // Persist the detection store first, then its generation+cursor tuple; see
                // checkpointHistory. No begin means no generation authority: at the retry cap
                // leave the durable tuple untouched so reconnect requests the envelope again.
                checkpointHistory(finalizeGeneration: disposition == .complete)
            }
            // Drain complete: land the final tally (the per-record mirror is coalesced, so
            // the last publish may not have caught it), drop the syncing indicator and, only
            // when the board actually buffered something, raise the one-shot count banner. A
            // bare reconnect with nothing buffered (expected == 0) clears silently, no banner.
            if offlineSyncCount != received { offlineSyncCount = received }
            // Third number: begin.n promised vs end.n sent. A shortfall means this attempt stopped
            // before every promised row was queued (for example, an over-MTU row). Current firmware
            // leaves that row uncommitted in the ring for a later larger-MTU/corrected attempt;
            // disclose the present shortfall instead of passing received == end.n off as complete.
            // promised == 0 means the begin sentinel never landed, so no judgement.
            let promised = offlineSyncTotal
            let unreplayed = replayUnreplayedCount(
                promised: promised, sent: expected, received: received,
                transportComplete: disposition == .complete)
            syncingOfflineLog = false
            offlineSyncTotal = 0
            if disposition == .complete { histResyncs = 0 }
            if expected > 0 || unreplayed > 0 {
                offlineSyncBanner = OfflineSyncSummary(count: expected, unreplayed: unreplayed)
            }
        } else {
            // Gap: ask the board to replay again from the last good contiguous seq. Stay
            // in the syncing state; a fresh end sentinel will settle it.
            histResyncs += 1
            histBeginSeen = false
            offlineSyncTotal = 0
            writeConfig(replaySyncConfig(cursor: lastGoodSeq))
        }
        histReceived = 0
        histPseudoTick = 0
        histBeginSeen = false
    }

    /// Clear the reconnect count banner (after the user taps view or dismisses it).
    func clearOfflineSyncBanner() { offlineSyncBanner = nil }

    private func ingestStatus(_ data: Data) {
        if let s = try? JSONDecoder().decode(DeviceStatus.self, from: data) {
            let previousEnabled = lastPushedEnabled
            status = s
            nrfHandleStatusUpdate(s)
            otaSawFreshStatus = true      // a frame off THIS link; the post-reboot check keys on it
            bufferingOn = s.bufferingOn   // keep the toggle in step with the board
            reconcileBuzzer(s)            // and the buzzer, which used to be the one that drifted
            reconcileDesert(s)            // rare since firmware persists Desert; still needed for older boards / NVS wipe
            // Reconcile every authoritative list against the board's count. Empty replacements
            // remain gated by an explicit pending clear, while a failed nonempty write is retried
            // instead of remaining wrong until the next reconnect.
            reconcileBoardList("ignore", localCount: boardIgnoredMacs.count,
                               boardCount: s.ignoreCount)
            reconcileBoardList("watch", localCount: watched.count,
                               boardCount: s.watchCount)
            // The drive-mode columns follow the board's detector toggles, and the Live Activity is
            // otherwise only pushed from publishDetections(). Without this, flipping a detector did
            // nothing visible until the NEXT detection arrived, which in a quiet area is minutes,
            // and is worst exactly when you turn a detector ON to watch for something. Push only on
            // an actual change so a 1 Hz status frame is not a 1 Hz activity update.
            let nowEnabled = enabledWidgetCategories()
            if driveModeOn, nowEnabled != previousEnabled {
                lastPushedEnabled = nowEnabled
                _ = recomputeLiveCounts()
                liveActivity.update(liveState())
            }
        }
        // "wiping": true rides the status frame while the board is still sweeping a deferred buffer
        // erase (absent = idle). It isn't part of DeviceStatus, so read it straight off the frame
        // here; the UI shows a brief "clearing buffer" state instead of the about-to-be-zero count.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            bufferWiping = (obj["wiping"] as? Bool) ?? false
            // "moto" is the broad Motorola-OUI sub-toggle, read off the frame for the same
            // reason: it isn't part of DeviceStatus. Absent = pre-split firmware, where the
            // broad match had no switch of its own, so report it on but unsupported.
            let moto = obj["moto"] as? Bool
            motorolaSupported = moto != nil
            motorolaOn = moto ?? true
        }
    }

    /// Fill the app with sample detections so you can explore the whole UI without a
    /// board. Used by the connect screen's "Continue without pairing" and the `-demo`
    /// launch argument in debug builds.
    func seedDemoData(showTour: Bool = true) {
        // Stop radio work before sample state becomes .connected. Once that synthetic state lands,
        // the scan timeout and background guard deliberately stop looking for .scanning, so a
        // low-latency CoreBluetooth scan left alive here would otherwise have no remaining owner.
        let scanActive = connectionState == .scanning || central?.isScanning == true
        if demoEntryNeedsScanCancellation(isScanning: scanActive,
                                          scanDeferred: scanWhenCentralIsReady) {
            scanWhenCentralIsReady = false
            stopScan()
        }
        updateSecureReadinessWatchdog(.teardown)
        cancelUpdatesForLinkTeardown(reason: "Update cancelled before entering the demo.")
        resetConfigWriteQueue()
        retireSessionCharacteristics()
        // A pending auto-reconnect from an earlier unexpected drop must NOT survive into the tour.
        // If the board re-advertises mid-demo, the armed central.connect fires didConnect, adopts
        // the peripheral over the demo, and its live detection notifies file into (or get dropped
        // by) the sample store, silently losing real hits. Cancel the parked connect and clear the
        // reconnect bookkeeping BEFORE seeding, exactly as disconnect() does. Setting
        // reconnectTarget = nil also clears isReconnecting via its didSet.
        if let target = reconnectTarget { central?.cancelPeripheralConnection(target) }
        reconnectTarget = nil
        // A parked FRESH connect must not survive into the tour either (the connect screen
        // stays reachable while .connecting): if the board turned up mid-demo, the armed
        // connect would fire didConnect under the sample store. Cancel it and drop the
        // handle; didDisconnectPeripheral ignores a peripheral we no longer hold.
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        if connectionState == .connecting, let pending = peripheral {
            central?.cancelPeripheralConnection(pending)
            peripheral = nil
        }
        intentionalDisconnectID = nil
        if !demoMode {
            demoIgnoredSnapshot = ignored
            demoWatchedSnapshot = watched
            demoAlertModeSnapshot = alertMode
            samplePhoneSettings = SamplePhoneSettings(
                liveModeWanted: driveModeWanted,
                redactLockScreen: redactLockScreen,
                notificationTypes: enabledPhoneNotificationTypes)
            demoSeenWatermarkSnapshot = SeenWatermarkSnapshot(
                watermark: seenWatermark, approxSeq: approxSeenSeq)
        }
        // A sample toggle is only a preview, and sample data must never own a system surface.
        // End both the local handle and any matching orphan before synthetic state becomes active,
        // preserving the user's real persisted preference for the next genuine session.
        stopDriveModeActivity(rememberOff: false, updateWidget: false)
        setSessionReady(false)   // sample .connected is a UI fixture, never an encrypted real session
        // A trailing real-session write must not wake after sample edits have changed the in-memory
        // arrays. The next genuine connection re-states any nonempty/pending real list.
        for timer in listPushTimers.values { timer.invalidate() }
        listPushTimers.removeAll()
        demoTourRequested = showTour
        demoMode = true
        demoAlertModeBeforeDesert = nil
        connectionState = .connected
        connectedName = "beacon board"
        // "axon": true so the body-cam category shows ON and the Motorola sub-row below is not
        // dimmed - the demo forces motorolaSupported precisely to introduce that control, and a
        // dimmed sub-toggle under an off parent defeats the tour. Matches the Android seed.
        demoStatusPayload = [
            "fw": "beacon board 2.0.7", "up": 4920, "total": 6, "ble": true, "wifi": true,
            "axon": true, "tracker": true, "glasses": true, "ncam": true,
            "buzzer": true, "vol": 70, "gps": true, "bat": 82,
        ]
        status = decodeJSON(DeviceStatus.self, demoStatusPayload)
        // The sample board is a current one. Without this the tour would read it as pre-split
        // firmware and hide the Motorola sub-toggle (the demo never runs a real status frame).
        motorolaSupported = true
        motorolaOn = true
        placeDemoDetections(around: lastCoord)       // cluster the sample hits around the user
        demoNeedsRelocate = (lastCoord == nil)       // no fix yet? re-place once one arrives
        // Demo data already carries Remote ID and canned observer coordinates. Do not surprise a
        // user who chose the no-hardware tour with a location prompt; an existing grant can still
        // re-center the samples around them.
        startLocationIfNeeded()   // already-authorized: get a fix so the samples land around the user
    }

    /// Place (or re-place) the demo detections around `base` (the user), preserving their
    /// relative spread. Falls back to the canned San Francisco coords when there's no fix yet.
    private func placeDemoDetections(around base: CLLocationCoordinate2D?) {
        let sfLat = 37.7799, sfLon = -122.4188        // coords the samples were authored at
        // One sample per category the Status strip, Log tiles, and Map chips all show: ALPR,
        // DRONE, BODY CAM, TRACKER, GLASSES, and Network camera. Exactly six, so the demo status
        // "total" below matches the seed count and lines up with the Android tour's seed set.
        let samples: [[String: Any]] = [
            ["t": 1, "s": 1, "meth": 1, "c": 95, "mac": "AC:AB:00:7F:2A:10", "rssi": -54,
             "name": "FlockSafety", "lat": 37.7799, "lon": -122.4202, "n": 12, "new": true],
            ["t": 4, "s": 2, "meth": 7, "c": 99, "mac": "DA:7E:E0:44:21:09", "rssi": -61,
             "id": "1581F4FED0A2B7", "lat": 37.7816, "lon": -122.4169,
             "plat": 37.7821, "plon": -122.4151, "alt": 84, "n": 1, "new": true],
            ["t": 3, "s": 0, "meth": 3, "c": 45, "mac": "A0:0F:11:BA:7C:33", "rssi": -88, "n": 1],
            ["t": 5, "s": 0, "meth": 3, "c": 85, "mac": "4C:00:12:19:AA:BB", "rssi": -72,
             "det": "Apple Find My (offline)", "cid": 76, "lat": 37.7791, "lon": -122.4196, "n": 3],
            // Ray-Ban / Oakley Meta glasses share Meta's BLE company ID with Quest headsets,
            // so this one lands at moderate confidence and says so in the detail.
            ["t": 9, "s": 0, "meth": 3, "c": 60, "mac": "1A:2B:3C:4D:5E:6F", "rssi": -71,
            // VERBATIM from glasses_signatures.h. These seeds must carry the firmware's real
            // strings, not a prettified paraphrase: `maker` parses them, so a paraphrase would
            // demo the OLD behaviour (a row reading "Recording glasses") while real hardware
            // shows the new one. This one resolves to "Meta".
             "det": "Meta: possible recording glasses or Quest",
             "cid": 1422, "lat": 37.7795, "lon": -122.4193, "n": 2, "new": true, "rnd": true],
            // Branded IP-camera OUI seen on the host WiFi (matched by source MAC), so the NETCAM
            // tile and NETWORK CAM map chip both show up on the tour. The MAC is a real Hikvision
            // block, so this row demonstrates the maker-led title end to end. Wire values are the
            // firmware's own: s=1 is SRC_WIFI (netcamClassifyWiFi never emits a BLE source) and
            // c=65 is NETCAM_OUI_CONFIDENCE, the registry tier a validated=0 block lands on; the
            // twin row in Android AcabBleManager carries the same values.
            ["t": 10, "s": 1, "meth": 1, "c": 65, "mac": "44:19:B6:22:0A:5C", "rssi": -70,
             "det": "Hikvision on wifi", "lat": 37.7788, "lon": -122.4183, "n": 2, "new": true],
        ]
        // The demo replaces the WHOLE store, so clear every per-id side map - the same eleven-map
        // list as evictKey/resetDetectionState. Leaving capturedLoc/bestRssi/crumb trails alive
        // under the sample store let a real session's pins and trails bleed into the tour.
        store.removeAll(); lastSeen.removeAll(); firstSeenAt.removeAll(); rssiHistory.removeAll()
        trackHistory.removeAll(); crumbHistory.removeAll()
        lastCrumbAt.removeAll(); firstCrumbAt.removeAll()   // both crumb stamps die with the crumbs
        capturedLoc.removeAll(); bestRssi.removeAll()
        histBasis.removeAll()   // the tour's stamps are all live-path; no buffered basis survives it
        for var dict in samples {
            if let base, let lat = dict["lat"] as? Double, let lon = dict["lon"] as? Double {
                dict["lat"] = base.latitude  + (lat - sfLat)   // keep each hit's relative offset, re-based on the user
                dict["lon"] = base.longitude + (lon - sfLon)
                if let plat = dict["plat"] as? Double { dict["plat"] = base.latitude  + (plat - sfLat) }
                if let plon = dict["plon"] as? Double { dict["plon"] = base.longitude + (plon - sfLon) }
            }
            guard let data = try? JSONSerialization.data(withJSONObject: dict),
                  let d = try? JSONDecoder().decode(Detection.self, from: data) else { continue }
            store[d.id] = d
            lastSeen[d.id] = Date()
            firstSeenAt[d.id] = Date()
            let r = d.rssi
            rssiHistory[d.id] = [-6, -3, -7, -1, -4, 2, -2, 1, -3, 0, -1, 1, -2, 0]
                .map { max(-99, min(-30, r + $0)) }
        }
        publishDetections()   // sort the feed + populate the live category counts
    }

    /// Drop demo mode and go back to the connect screen.
    func exitDemo() {
        // End defensively while demoMode is still true, so an ActivityKit callback cannot infer a
        // real preference change from anything the user did in the preview.
        stopDriveModeActivity(rememberOff: false, updateWidget: false)
        demoMode = false
        demoTourRequested = false
        samplePhoneSettings = nil
        driveModeWanted = DriveModeState.wanted
        if let snapshot = demoSeenWatermarkSnapshot {
            seenWatermark = snapshot.watermark
            approxSeenSeq = snapshot.approxSeq
        }
        demoSeenWatermarkSnapshot = nil
        // Throw away every sample-mode Watch/Mute/Rename/Bulk edit and restore the real managed
        // lists before a future connection can re-state them to a board.
        if let snapshot = demoIgnoredSnapshot { ignored = snapshot }
        else { ignored = []; loadIgnored() }
        if let snapshot = demoWatchedSnapshot { watched = snapshot }
        else { watched = []; loadWatched() }
        demoIgnoredSnapshot = nil
        demoWatchedSnapshot = nil
        if let realAlertMode = demoAlertModeSnapshot { alertMode = realAlertMode }
        demoAlertModeSnapshot = nil
        demoAlertModeBeforeDesert = nil
        demoStatusPayload.removeAll()
        watchlistFull = false
        // seedDemoData() forces this true so the tour can show the Motorola sub-toggle. Reset it
        // with the rest of the demo state: otherwise a user who runs the tour and then connects a
        // real PRE-SPLIT board keeps being shown a control that board has no key to write to.
        // The next real status frame recomputes it either way, this just closes the gap before one arrives.
        motorolaSupported = false
        connectedName = nil
        status = nil
        // The tour is not a reason to destroy real data. Its sample hits do have to leave the
        // store (a later checkpoint would otherwise file them to disk as genuine detections), but
        // they leave via an in-memory reset plus a reload of what was already on disk, NOT via
        // clearDetections(), which deletes the file. Board off is exactly when the user is offered
        // the tour, so this one-tap path used to be the unguarded way to lose a real log.
        resetDetectionState()
        loadPersistedDetections()
        if let radioState = central?.state {
            switch radioState {
            case .poweredOn:    connectionState = .idle
            case .poweredOff:   connectionState = .poweredOff
            case .unauthorized: connectionState = .unauthorized
            default:            connectionState = .unknown
            }
        } else {
            // The no-hardware tour can run before first Bluetooth use. Returning from it must
            // restore the rationale + CTA, not strand an uninitialized manager on "Starting".
            switch CBManager.authorization {
            case .notDetermined:          connectionState = .idle
            case .denied, .restricted:    connectionState = .unauthorized
            case .allowedAlways:          initializeCentral()
            @unknown default:             connectionState = .unknown
            }
        }
        stopLocationIfIdle()
        writeWidgetSummary(force: true)   // out of the tour: connected flag + real count restored
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, _ dict: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if demoMode { return }      // demo mode pins us as connected
        switch central.state {
        case .poweredOn:
            // A live session only predates this callback via a redundant .poweredOn while still
            // connected, so leave that alone. Otherwise the radio just came back: land on a clean
            // .idle, the same place a cold launch starts. The old code preserved the prior state
            // whenever a stale peripheral survived the power-off, which pinned the UI on
            // "Bluetooth is off" until the app was force-quit.
            if connectionState == .connected { break }
            // We dropped while the radio was off but are still holding a peripheral to auto-reconnect
            // to: re-arm the pending connect now that the radio is back, instead of falling through to
            // a plain rescan. (armReconnect deferred here because central.connect needs .poweredOn.)
            if reconnectTarget != nil {
                connectionState = .connecting
                armReconnect()
                break
            }
            if scanWhenCentralIsReady {
                // Consume the intent either way: nothing else expires it, and re-arming it for
                // "later" is what let one Scan tap start a scan an unbounded time afterwards.
                // Honour it in the foreground only - the same guard the recovering branch below
                // carries. A deferred scan fired while backgrounded is exactly the unowned,
                // service-filtered scan the didEnterBackground park was written to eliminate
                // ("board off, tapped Scan, pressed Home"), and on a counter-surveillance tool an
                // unrequested scan is an RF emission, not only battery.
                scanWhenCentralIsReady = false
                connectionState = .idle
                if UIApplication.shared.applicationState != .background { startScan() }
                break
            }
            let recovering = (connectionState == .poweredOff)
            connectionState = .idle
            // Already used a board this session and Bluetooth is granted? Resume the scan so it
            // reappears without a manual tap. Guarded so a first launch still shows the
            // pre-permission rationale instead of silently firing the system prompt. Foreground
            // only: a Bluetooth off/on cycle while backgrounded must not re-arm exactly the
            // background scan the didEnterBackground observer parks.
            if recovering && CBManager.authorization == .allowedAlways
                && UIApplication.shared.applicationState != .background { startScan() }
        case .poweredOff:
            // Powering the radio off invalidates every peripheral, and iOS may never deliver a
            // didDisconnect for the live link, so tear the session down here or a dead handle
            // lingers and blocks recovery. The deferred scan intent dies with the radio too, the
            // same way .unauthorized retires it below: it has no expiry, so leaving it armed on a
            // first-ever use with Bluetooth off meant the eventual power-on honoured a tap the
            // user made in a session that has read "bluetooth is off" ever since.
            scanWhenCentralIsReady = false
            clearConnection()
            connectionState = .poweredOff
        case .unauthorized:
            scanWhenCentralIsReady = false
            clearConnection()
            connectionState = .unauthorized
        default:
            clearConnection()
            connectionState = .unknown
        }
        stopLocationIfIdle()   // after the state assign, so needsLocation reads the settled value
        writeWidgetSummary(force: true)   // radio state settled; keep the home widget's connected flag honest
    }

    /// Drop every handle tied to a live connection. Used when the radio itself goes away
    /// (power-off / unauthorized / resetting), where the OS invalidates the peripheral and may
    /// never send a didDisconnect. Mirrors the teardown in didDisconnectPeripheral, without the
    /// reconnect bookkeeping, since there is nothing to reconnect to until the radio is back.
    private func clearConnection() {
        resetConfigWriteQueue()
        checkpointLive()   // the session's only copy is in RAM; get it to disk before the link state goes
        stopStatusPolling()
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        updateSecureReadinessWatchdog(.teardown)
        // CoreBluetooth may provide no disconnect callback when its radio becomes unavailable.
        // Retaining any update state here would let a later board inherit this board's transfer or
        // confirmation. Settle every asynchronous owner before dropping the handle.
        let wasAwaitingOtaReboot = otaAwaitingReboot != nil
        cancelUpdatesForLinkTeardown(reason: wasAwaitingOtaReboot
            ? "Bluetooth became unavailable before the app could confirm the update. Reconnect and check the board's firmware."
            : "Bluetooth became unavailable during the update. Turn it back on, reconnect, and try again.")
        setSessionReady(false)   // whatever readiness this session had died with the radio
        intentionalDisconnectID = nil   // there may be no didDisconnect callback to consume it
        otaQuarantinedPeripheralID = nil
        nrfQuarantinedPeripheralID = nil
        peripheral = nil
        retireSessionCharacteristics()
        otaCapable = false
        connectedName = nil
        status = nil
        syncingOfflineLog = false
        histBeginSeen = false
        histResyncs = 0   // the gap-retry budget is per connection
        driveModeLinkLost()   // -> "Reconnecting…", then auto-end if the radio never returns
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? ACABProfile.advertisedName
        let fw = parseFirmwareVersion(advertisementData)
        #if DEBUG
        // ONCE PER PERIPHERAL, not once per advertisement. This callback runs on the MAIN thread
        // (the central is created with queue: nil), a board advertises many times a second, and the
        // old unconditional version did a hex map+join over the manufacturer data, a keys join, and
        // a print() on every single one. With the Xcode debugger attached each print round-trips to
        // the debugger, so a scan screen sitting next to two boards generated a sustained main
        // thread load that made the app feel slow and, worse, polluted every timing measurement
        // taken while trying to diagnose an unrelated stall. The payload is identical on every
        // advert from a given board, so repeating it carried no information at all.
        if name.uppercased().contains("ACAB"), !loggedScanIDs.contains(peripheral.identifier) {
            loggedScanIDs.insert(peripheral.identifier)
            let raw = (advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data)?
                .map { String(format: "%02X", $0) }.joined() ?? "none"
            print("[ACAB-scan] name=\(name) mfg=\(raw) parsedFW=\(fw ?? "nil") " +
                  "keys=[\(advertisementData.keys.joined(separator: ","))]")
        }
        #endif
        let dev = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral,
                                   name: name, rssi: RSSI.intValue, firmware: fw)
        let now = Date()
        lastAdvertAt[dev.id] = now
        if let i = discovered.firstIndex(where: { $0.id == dev.id }) {
            // Allow-duplicates exists to catch the LATE scan-response manufacturer data (the
            // firmware version), but republishing on every advert re-rendered ConnectView
            // 10-20x/s per advertising board. Only publish a meaningful change: the version
            // landing, or the RSSI moving by a visible step. (The freshness stamp above is NOT a
            // meaningful change: it lives outside the published row precisely so it can be
            // written every time without costing a render.)
            if (fw != nil && discovered[i].firmware == nil) || abs(discovered[i].rssi - dev.rssi) >= 3 {
                discovered[i].rssi = dev.rssi
                if let fw { discovered[i].firmware = fw }
            }
        } else {
            discovered.append(dev)
        }
        pruneStaleDiscovered(now)
    }

    /// Drop picker rows we have not heard an advertisement from in `foundStaleInterval`.
    ///
    /// WHY THIS EXISTS ON IOS AT ALL, since the list is keyed on peripheral.identifier and that is
    /// a CoreBluetooth per-host UUID rather than the board's BLE address. The question is whether
    /// CoreBluetooth collapses a peripheral whose advertised address rotates (the firmware
    /// advertises a Resolvable Private Address, re-rolled every CONFIG_BT_NIMBLE_RPA_TIMEOUT =
    /// 900 s) onto ONE identifier. It does not, and cannot, before the board is bonded:
    ///
    ///   - An RPA is only resolvable with the advertiser's Identity Resolving Key, and a central
    ///     receives that key during bonding (Bluetooth Core Spec; the firmware distributes it
    ///     explicitly via BLE_SM_PAIR_KEY_DIST_ID in acab_ble_service.cpp for exactly this reason).
    ///     CoreBluetooth exposes no API to hand it an IRK, so before the first pair iOS has nothing
    ///     to resolve WITH: each new address is a device it has never met.
    ///   - Apple documents the identifier only as "The unique, persistent identifier associated
    ///     with the peer" (CBPeer.h) and promises nothing about an unresolvable address change.
    ///     Punch Through's Core Bluetooth guide is blunter: the UUID "isn't guaranteed to stay the
    ///     same across scanning sessions and should not be 100% relied upon for peripheral
    ///     re-identification", and their iOS 18 write-up states the mechanism directly: "If a
    ///     device is unbonded and rotates its BLE address, it may become unconnectable. Without
    ///     bonding, the BLE central cannot identify a device with a new address."
    ///
    /// So iOS is exposed in the same way Android is, and Android's prune is NOT redundant: for an
    /// unbonded board a rotation mid-scan mints a second identifier and the old row would sit in
    /// the picker as a phantom duplicate of the same physical unit. Once bonded, the OS resolves
    /// the rotation with the IRK it holds and the identifier stays put, so the exposure is the
    /// first-pair window (and any board the user has since forgotten). It is narrower here than on
    /// Android only because a scan window is bounded at 45 s and startScan() empties the list, so
    /// a 900 s rotation has to land inside that window; narrower is not absent.
    ///
    /// Advert-driven, like Android's: nothing prunes while no results arrive, so a scan that ends
    /// with the boards it found still shows them. That is the resting screen behaviour both
    /// platforms already document, not an accident of where the call sits.
    private func pruneStaleDiscovered(_ now: Date) {
        // An id with no stamp is treated as fresh, mirroring Android's `seenAt == 0L ||` guard:
        // absent bookkeeping must never be a reason to delete a row the user can see.
        let isStale = { (d: DiscoveredDevice) in
            now.timeIntervalSince(self.lastAdvertAt[d.id] ?? now) >= self.foundStaleInterval
        }
        let goners = Set(discovered.filter(isStale).map(\.id))
        guard !goners.isEmpty else { return }   // never republish for nothing
        // Take the ids FIRST. Clearing the stamps before the removal would make isStale read the
        // absent-is-fresh branch above and quietly delete nothing.
        discovered.removeAll { goners.contains($0.id) }
        for id in goners { lastAdvertAt[id] = nil }
    }

    /// Pull the firmware version out of our scan-response manufacturer data (company id 0xACAB).
    private func parseFirmwareVersion(_ adv: [String: Any]) -> String? {
        guard let data = adv[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count > 2, data[0] == 0xAB, data[1] == 0xAC else { return nil }
        return String(data: data.subdata(in: 2..<data.count), encoding: .utf8)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        // Demo guard: a parked auto-reconnect can still fire a didConnect after the user entered
        // the tour, when the board's re-advertise raced seedDemoData's cancel. Adopting it here
        // would tear the demo out from under the user and file live notifies into the sample store.
        // Drop the connection and leave demo mode intact; the user pairs for real by exiting the tour.
        if demoMode { central.cancelPeripheralConnection(peripheral); return }
        // Global `.connecting` is not identity. A delayed callback from board A may arrive after
        // the user has started connecting board B, so accept only the exact object held for the
        // fresh attempt, pending reconnect, or OTA reboot.
        let fresh = connectionState == .connecting && self.peripheral === peripheral
        let reconnect = connectionState == .connecting && reconnectTarget === peripheral
        let ota = otaAwaitingReboot != nil && self.peripheral === peripheral
            && otaOwnerPeripheralID == peripheral.identifier
        guard fresh || reconnect || ota else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        // Defensive session boundary: a dropped with-response Config write may never receive its
        // callback. No in-flight tag or queued payload from the retired link may block/inherit the
        // new link's KEY write.
        resetConfigWriteQueue()
        // A CBPeripheral object and its cached services can be reused across reconnects. Retire
        // every old channel now; fresh discovery installs the only identities callbacks may use.
        retireSessionCharacteristics()
        // Adopt the handle. The auto-reconnect path holds the peripheral in reconnectTarget (not
        // self.peripheral) while the connect is pending, so on a successful reconnect self.peripheral
        // is nil here - set it now, or every peripheral.* call downstream (status reads, config
        // writes, OTA) would no-op. The scan-connect and OTA-reboot paths already set it; re-assigning
        // the same object is harmless. Then clear reconnectTarget: the pending reconnect is fulfilled.
        self.peripheral = peripheral
        peripheral.delegate = self
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil   // transport resolved
        updateSecureReadinessWatchdog(.transportConnected, peripheral: peripheral)
        if reconnectTarget === peripheral { reconnectTarget = nil }
        connectedName = peripheral.name ?? ACABProfile.advertisedName
        sessionDiscoveryPhase = .awaitingServices
        peripheral.discoverServices([ACABProfile.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        // A no-timeout pending auto-reconnect shouldn't normally fail, but if the OS reports one for
        // our reconnect target, re-arm rather than silently giving up on the board coming back.
        if reconnectTarget === peripheral {
            armReconnect()
            return
        }
        guard self.peripheral === peripheral else { return }
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        updateSecureReadinessWatchdog(.teardown)
        if otaAwaitingReboot != nil {
            // The reboot wait owns this exact handle and has its own overall timeout. A transient
            // failed reconnect should retry rather than clear the handle and strand confirmation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.peripheral === peripheral,
                      self.otaAwaitingReboot != nil else { return }
                self.otaReconnectPeripheral()
            }
            return
        }
        guard connectionState == .connecting else { return }
        resetConfigWriteQueue()
        retireSessionCharacteristics()
        connectionState = .idle
        connectHint = beaconConnectionRecovery(.transport)
        self.peripheral = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        // A disconnect for a peripheral we no longer hold is finished business: the connect
        // timeout / cancel-pending / demo-entry cleanup already cancelled it and settled
        // connectionState inline (a cancelled connect guarantees no didDisconnect, so they
        // couldn't wait for this one). Arming the auto-reconnect below would resurrect a
        // connect the user or the watchdog just tore down. The stray-connect reject in
        // didConnect can cancel a peripheral it never adopted. Its later callback must not
        // consume the adopted session's intentional-disconnect intent: doing so could turn the
        // current
        // board's user-requested disconnect into an unexpected drop and reconnect it. Stop here:
        // the teardown below is scoped to the ADOPTED session. Running it for a stray used to force
        // connectionState to
        // .idle (and end Drive mode) out from under whatever the app was actually doing, e.g.
        // orphaning a live scan the background park then never stopped (it only parks
        // .scanning), leaving the radio lit indefinitely.
        if self.peripheral !== peripheral {
            return
        }
        // Includes the OTA-reboot early-return below. CoreBluetooth need not answer an in-flight
        // Config write after link loss, so carrying that tag would wedge the reconnect handshake.
        resetConfigWriteQueue()
        retireSessionCharacteristics()
        updateSecureReadinessWatchdog(.teardown)
        if otaQuarantinedPeripheralID == peripheral.identifier {
            otaQuarantinedPeripheralID = nil
        }
        if nrfQuarantinedPeripheralID == peripheral.identifier {
            nrfQuarantinedPeripheralID = nil
        }
        stopStatusPolling()   // link is down; a reconnect restarts it in didDiscoverCharacteristicsFor
        // An OTA in the "rebooting" phase EXPECTS this disconnect (the board just reflashed and
        // restarted). Kick off the reconnect-and-confirm instead of tearing everything down.
        if otaHandleDisconnect(peripheral) {
            // Readiness must reset even though the rest of the teardown is skipped:
            // didUpdateNotificationStateFor runs the ready chain (status polling, list resync,
            // otaHandleReconnected, buffer handshake) only while !sessionWasReady. Left true, the
            // rebooted board's CCCD success would be swallowed as a duplicate and the reboot
            // timeout would falsely report the board never came back.
            setSessionReady(false)
            return
        }
        cancelUpdatesForLinkTeardown(
            reason: "The connection to the board was lost during the update. Reconnect and try again.")
        checkpointLive()   // session over: the board buffered nothing while we were connected, so RAM was the only copy
        self.peripheral = nil
        otaCapable = false
        connectedName = nil
        status = nil
        // A drop mid-drain never delivers the end sentinel; don't leave the indicator
        // stuck on. The next reconnect re-runs the handshake and re-enters the state.
        syncingOfflineLog = false
        histBeginSeen = false
        histResyncs = 0   // the gap-retry budget is per connection
        let wasReady = sessionWasReady   // the auto-reconnect decision below judges THIS session
        setSessionReady(false)
        // Decide whether to auto-reconnect. A user-initiated disconnect() must stay disconnected;
        // anything else is an UNEXPECTED drop (the board was unplugged / power-cycled), and THAT is
        // the bug we're fixing: keep the CBPeripheral handle and arm a pending auto-reconnect so the
        // link, widget, and Live Activity resync the instant the board re-advertises - no manual tap.
        if intentionalDisconnectID == peripheral.identifier {
            intentionalDisconnectID = nil   // consume this board's intentional-disconnect target
            reconnectTarget = nil    // and make sure no stale pending reconnect survives
            connectionState = (central.state == .poweredOn) ? .idle : .unknown
            // The user chose to disconnect: there is nothing to reconnect to, so end Drive mode /
            // the Live Activity right now instead of flipping it to "Reconnecting…" and arming the
            // 120s grace (which would leave a stale counter on the Lock Screen for two minutes).
            // Only the unexpected-drop path below wants the grace. End the current activity but
            // preserve the counter preference for the next ready board session.
            if driveModeOn { suspendDriveModeForLinkEnd() }
        } else if wasReady {
            reconnectTarget = peripheral   // retain the handle we just lost; a pending connect needs it alive
            // .connecting (not .idle) keeps the UI + the "Reconnecting…" Live Activity truthful, and
            // lets driveModeLinkLost()'s grace timer coexist: a reconnect that lands inside the window
            // runs driveModeLinkRestored() from didDiscoverCharacteristicsFor and cancels the auto-end.
            connectionState = .connecting
            armReconnect()   // no-op if the radio is off; centralManagerDidUpdateState re-arms on .poweredOn
            driveModeLinkLost()   // -> "Reconnecting…", then auto-end if the board never comes back
        } else {
            // A connect that NEVER reached ready dropped us: the user declined the pairing
            // prompt, or the board holds stale bond keys and cut the link during setup. Arming
            // the indefinite reconnect here is what created the endless connect -> pairing
            // prompt -> drop -> reconnect loop (CoreBluetooth re-fires the parked connect the
            // moment the board re-advertises). Fail to the resting screen instead, exactly like
            // Android's sessionWasReady gate; the user retries with a tap when they're ready.
            reconnectTarget = nil
            if connectHint == nil {
                connectHint = beaconConnectionRecovery(.securePairing)
            }
            connectionState = (central.state == .poweredOn) ? .idle : .unknown
        }
        writeWidgetSummary(force: true)   // home widget goes to "not connected" until the reconnect handshake completes
        stopLocationIfIdle()   // no-op while Drive mode is on: a dropout must not cost us the residency
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        switch sessionServiceDiscoveryDisposition(
            callbackOwner: peripheral,
            currentOwner: self.peripheral,
            awaitingServices: sessionDiscoveryPhase == .awaitingServices,
            error: error
        ) {
        case .ignore:
            return
        case .fail:
            failSessionDiscovery(
                peripheral,
                hint: "The beacon's secure service could not be discovered. Reconnect and try again.")
            return
        case .accept:
            break
        }
        guard let svc = peripheral.services?.first(where: { $0.uuid == ACABProfile.service }) else {
            failSessionDiscovery(peripheral, hint: beaconConnectionRecovery(.missingService))
            return
        }
        sessionService = svc
        sessionDiscoveryPhase = .awaitingCharacteristics
        peripheral.discoverCharacteristics(
            [ACABProfile.detections, ACABProfile.config, ACABProfile.status, ACABProfile.ota], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        switch sessionCharacteristicDiscoveryDisposition(
            callbackOwner: peripheral,
            currentOwner: self.peripheral,
            awaitingCharacteristics: sessionDiscoveryPhase == .awaitingCharacteristics,
            callbackService: service,
            currentService: sessionService,
            error: error
        ) {
        case .ignore:
            return
        case .fail:
            failSessionDiscovery(
                peripheral,
                hint: "The beacon's secure channels could not be discovered. Reconnect and try again.")
            return
        case .accept:
            break
        }
        var discoveredDetections: CBCharacteristic?
        var discoveredConfig: CBCharacteristic?
        var discoveredStatus: CBCharacteristic?
        var discoveredOTA: CBCharacteristic?
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case ACABProfile.detections: discoveredDetections = ch
            // Status can enqueue reconciliation writes when decoded. Its subscription and first
            // read therefore begin only after key -> epoch -> sync has been ACKed.
            case ACABProfile.status:     discoveredStatus = ch
            case ACABProfile.config:     discoveredConfig = ch
            // Keep the characteristic, but subscribe in the same post-sync chain as Android.
            case ACABProfile.ota:        discoveredOTA = ch
            default: break
            }
        }
        // REQUIRED CHARACTERISTICS. Detections is the entire product and Config is how every
        // setting, list and OTA trigger is sent; without either, "connected" is a lie. This used to
        // mark the link connected regardless, so a board advertising our service UUID with a
        // truncated or wrong profile produced a healthy-looking session that could never report
        // anything. Mirrors the Android policy in AcabBleManager.onSubscribeFailed, where a dead
        // Detections subscription is fatal and Status merely degrades to polling.
        //
        // OTA is deliberately NOT required: released 1.7 boards do not carry acab0104, and refusing
        // them would strand working hardware.
        guard let discoveredDetections, let discoveredConfig else {
            retireSessionCharacteristics()
            let missing = [discoveredDetections == nil ? "detections" : nil,
                           discoveredConfig == nil ? "config" : nil]
                .compactMap { $0 }.joined(separator: " + ")
            connectHint = "this beacon is missing its \(missing) channel, so it cannot report to the app. "
                        + "check its firmware, then scan again."
            updateSecureReadinessWatchdog(.teardown)
            intentionalDisconnectID = peripheral.identifier
            central?.cancelPeripheralConnection(peripheral)
            // Keep this unresolved attempt non-idle until its own disconnect callback consumes the
            // scoped intent. Exposing idle here allowed a replacement board to start while the old
            // callback was still pending.
            return
        }
        // Install identities atomically before issuing the first subscribe. These are the only
        // callback channels trusted for this connection generation; `peripheral.services` may
        // still contain characteristic objects retained from the prior link.
        detectionsChar = discoveredDetections
        configChar = discoveredConfig
        statusChar = discoveredStatus
        otaChar = discoveredOTA
        sessionDiscoveryPhase = .installed
        peripheral.setNotifyValue(true, for: discoveredDetections)
        // Merely discovering acab0104 is not enough. OTA waits exclusively for notifications on
        // that characteristic, so capability becomes true only after its CCCD succeeds below.
        otaCapable = false
        // Stay in .connecting until the encrypted Detections subscription succeeds. Calling the
        // public session connected here used to open the first-run tour underneath the iOS pairing
        // request and could consume onboarding even when the user declined it.
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // CoreBluetooth may deliver a CCCD completion after the old link has already torn down.
        // CBPeripheral itself is reused across reconnects, so compare the characteristic object
        // from fresh discovery too. No retired callback may mark its replacement ready, expose
        // OTA, or send a buffer handshake through the new session's Config characteristic.
        guard callbackBelongsToCurrentSession(
            callbackOwner: peripheral, currentOwner: self.peripheral,
            callbackChannel: characteristic,
            currentChannel: currentSessionCharacteristic(for: characteristic.uuid)) else { return }
        if let error {
            // A refused CCCD write is how a pairing decline (or a board holding stale bond keys
            // for another phone) actually surfaces: the characteristics are READ_ENC/WRITE_ENC,
            // so iOS raises the pairing prompt on the subscribe, and a decline lands here as
            // insufficient encryption/authentication. Ignoring it silently was what let the
            // session look connected until the board dropped us. If the DETECTIONS subscribe
            // failed the session can never stream, so tear down now; sessionWasReady was never
            // set, so the drop falls to the resting screen instead of arming a reconnect that
            // would re-fire the pairing prompt forever.
            #if DEBUG
            print("[ACAB-ble] notify subscribe failed for \(characteristic.uuid): \(error.localizedDescription)")
            #endif
            // Identity-guarded: if the board already dropped us (its own reaction to the refused
            // encryption) the teardown ran and a second disconnect would be redundant.
            if characteristic.uuid == ACABProfile.detections {
                connectHint = beaconConnectionRecovery(.securePairing)
                disconnect()
            } else if characteristic.uuid == ACABProfile.status,
                      readySubscriptionStep == .subscribeStatus {
                // Status notify is optional because periodic reads cover it. The read is still
                // post-sync, and a failed CCCD cannot block READY indefinitely.
                readyStatusSettled = true
                readStatusValue()
                advancePostSyncReadyChain()
            } else if characteristic.uuid == ACABProfile.ota {
                // OTA is optional. A refused OTA CCCD must hide only the updater, not tear down a
                // working detection link or let a transfer arm the board and wait forever.
                otaCapable = false
                if readySubscriptionStep == .subscribeOTA {
                    readyOTASettled = true
                    advancePostSyncReadyChain()
                }
            }
            return
        }
        if characteristic.uuid == ACABProfile.status {
            guard readySubscriptionStep == .subscribeStatus else { return }
            readyStatusSettled = true
            // The first authoritative status read cannot trigger reconciliation until all three
            // replay-control writes have received successful responses.
            readStatusValue()
            advancePostSyncReadyChain()
            return
        }
        if characteristic.uuid == ACABProfile.ota {
            otaCapable = characteristic.isNotifying
            if readySubscriptionStep == .subscribeOTA {
                readyOTASettled = true
                advancePostSyncReadyChain()
            }
            return
        }
        // Once the Detections characteristic is actually subscribed, run the buffer
        // handshake (key, epoch, sync) so the board can replay anything it buffered
        // while we were away. Order matters: this must come AFTER the subscribe.
        guard characteristic.uuid == ACABProfile.detections, characteristic.isNotifying else { return }
        // Subscribe success opens secure setup; READY is published only after the ACK-gated
        // key -> epoch -> sync transaction and post-sync Status/OTA subscription chain settle.
        guard !sessionWasReady else { return }
        // Resolve (and, on first use, read back) a DURABLE key before this session becomes ready
        // or any handshake write is queued. A generated-but-uncommitted key would let the board
        // encrypt evidence that becomes permanently unreadable after this process exits.
        guard let bufferKey = bufferKeyHex() else {
            connectHint = "Secure buffer key storage is unavailable. Unlock your phone and reconnect."
            disconnect()
            return
        }
        guard startBufferHandshake(key: bufferKey, completion: .startup) else {
            failBufferHandshake(at: .key)
            return
        }
        // READY is published from the sync write's successful response, never merely because
        // CoreBluetooth accepted three writes into its local queue.
    }

    private func finishReadyAfterBufferHandshake() {
        guard !sessionWasReady, peripheral?.state == .connected else { return }
        setSessionReady(true)
        connectHint = nil   // link is usable; the hint no longer applies
        connectionState = .connected
        startLocationIfNeeded()   // an existing grant can now stamp detections; this never prompts
        startStatusPolling()   // periodic READ fallback for status frames too big for a small MTU notify
        driveModeLinkRestored()   // back from a dropout: cancel the auto-end, resume the live counter
        writeWidgetSummary(force: true)   // home widget goes to "connected"
        resyncListsOnConnect()   // re-state ignore then watch, skipping a list we never emptied
        buzzerReassertAttempts = 0               // fresh link: the first status frame is pre-write, don't count it
        lastBuzzerMuteWrite = .distantPast       // and the slow mute retry starts over with it
        listPushAttempts.removeAll()             // and a fresh board gets a fresh convergence budget
        lastPushedEnabled = nil                  // force the next status frame to re-push the columns
        setBuzzerEnabled(alertMode == .buzzer)   // a fresh beacon boots up buzzing; match the phone's mode
        lastGpsSent = .distantPast; sendPhoneLocation()   // push an existing fix to the freshly-connected beacon
        // Background: keep the "latest"/OTA gate current. Hop to the main actor explicitly
        // (the store is @MainActor); CB callbacks already run on main, so this is immediate.
        Task { @MainActor in FirmwareManifestStore.shared.refreshIfNeeded() }
        otaHandleReconnected()   // if we just came back from an OTA reboot, confirm or report rollback
        // The live counter preference defaults on, but the surface starts only after a real board
        // has completed its encrypted Detections subscription. A stored false is an explicit user
        // choice and is never overwritten. If this reconnect happened in the background,
        // scene-phase reconciliation starts the activity when the app next becomes active.
        if DriveModeState.wanted,
           automaticLiveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                                   locationAuthorized: locationAuthorized,
                                   firstRunOnboardingActive: firstRunOnboardingActive),
           UIApplication.shared.applicationState == .active {
            resumeDriveModeIfWanted()
        }
        // The startup SYNC callback deliberately pauses the Config queue while Status/OTA
        // subscriptions settle. Resume any clear/settings writes only after READY owns the link.
        postSyncConfigDispatchPaused = false
        dispatchNextConfigWrite()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // The peripheral object survives a reconnect, but its discovered characteristic objects
        // do not. Reject a late value/read callback from the retired link by both identities.
        guard callbackBelongsToCurrentSession(
            callbackOwner: peripheral, currentOwner: self.peripheral,
            callbackChannel: characteristic,
            currentChannel: currentSessionCharacteristic(for: characteristic.uuid)) else { return }
        guard error == nil else {
            #if DEBUG
            if let error {
                print("[ACAB-ble] value update failed for \(characteristic.uuid): \(error.localizedDescription)")
            }
            #endif
            return
        }
        guard let data = characteristic.value else { return }
        switch characteristic.uuid {
        case ACABProfile.detections: ingestDetection(data)
        case ACABProfile.status:     ingestStatus(data)
        case ACABProfile.ota:        if !handlePwrNotify(data) { otaHandleNotify(data) }
        default: break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        // CoreBluetooth reuses the CBPeripheral object across reconnects. Characteristic identity
        // is the session boundary here: a delayed response carrying the retired characteristic
        // must not consume the replacement session's in-flight KEY tag and falsely open the ACK
        // barrier. didConnect clears configChar until fresh discovery installs the new object.
        guard characteristic.uuid == ACABProfile.config,
              callbackBelongsToCurrentSession(
                callbackOwner: peripheral, currentOwner: self.peripheral,
                callbackChannel: characteristic, currentChannel: configChar) else { return }
        guard let completed = configWriteInFlight else {
            if error != nil { retryManagedListsAfterConfigWriteFailure() }
            return
        }
        configWriteInFlight = nil
        let shouldContinue = handleConfigWriteResult(
            completed.purpose, success: error == nil)
        if shouldContinue { dispatchNextConfigWrite() }
    }

    private func handleConfigWriteResult(_ purpose: ConfigWritePurpose,
                                         success: Bool) -> Bool {
        switch purpose {
        case .normal:
            if !success { retryManagedListsAfterConfigWriteFailure() }
            return true

        case .handshake(let completed):
            let transition = bufferHandshakeTransition(completed: completed, success: success)
            if transition.failed {
                failBufferHandshake(at: completed)
                return false
            }
            if let next = transition.next, !enqueueBufferHandshakeWrite(next) {
                failBufferHandshake(at: next)
                return false
            }
            if transition.complete {
                let completion = bufferHandshakeCompletion
                bufferHandshakeCompletion = nil
                switch completion {
                case .startup:
                    // Keep later Config work (including a clear queued during KEY) parked until
                    // the post-sync Status/OTA chain reaches READY. Otherwise a clear could start
                    // its rekey transaction while the startup readiness callbacks are still live.
                    postSyncConfigDispatchPaused = true
                    advancePostSyncReadyChain()
                    return false
                case .rekeyAfterClear: readStatusValue()
                case nil:
                    failBufferHandshake(at: completed)
                    return false
                }
            }
            return true

        case .clearLog:
            guard success else {
                resetConfigWriteQueue()
                connectHint = "Offline history was not cleared. Reconnect and try again."
                disconnect()
                return false
            }
            resetReplayCursorAfterClearAck()
            guard let key = bufferKeyHex(),
                  startBufferHandshake(key: key, completion: .rekeyAfterClear) else {
                failBufferHandshake(at: .key)
                return false
            }
            return true
        }
    }

    /// Write-without-response back-pressure: CoreBluetooth calls this when its send buffer
    /// has room again. The OTA streamer parks here when a write returns "not ready" and
    /// resumes from this callback, so we never overrun the link.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        otaResumeStreaming()
    }
}

// MARK: - CLLocationManagerDelegate

extension BLEManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let hadCurrentFix = currentLocationCoord != nil
        lastFix = locations.last
        if demoMode, demoNeedsRelocate, let c = lastCoord {   // snap the demo hits onto the user once a fix arrives
            demoNeedsRelocate = false
            placeDemoDetections(around: c)
        }
        // A permanent-only rule set cannot change with a fix, so skip the per-sample O(rules)
        // rebuild unless some rule is time- or place-scoped (Drive mode delivers ~1 fix/s for
        // hours); refreshMutePolicy's minute timer still re-evaluates scoped rules regardless.
        // Android guards its location-driven republish the same way.
        if ignored.contains(where: { $0.expiresAt != nil || $0.isPlaceScoped }) {
            rebuildActiveIgnoredMacSet()
        }
        let after = activeIgnoredMacSet
        if awaitingHereFix, currentLocationCoord != nil {
            awaitingHereFix = false
            updateLocationDesiredAccuracy()
        }
        if after != publishedActiveIgnoredMacs {
            publishDetections()
        } else if hadCurrentFix != (currentLocationCoord != nil) {
            // `lastFix` is intentionally not @Published (publishing every GPS sample would redraw
            // the entire app). The first usable fix still has to wake a waiting HERE-mute dialog.
            objectWillChange.send()
        }
        sendPhoneLocation()
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        locationAuthorizationStatus = manager.authorizationStatus
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            // Just-granted, mid-session: start only if something is actually waiting on a fix.
            // This callback also fires the moment the delegate is assigned in init(), which is why
            // it must never start unconditionally.
            startLocationIfNeeded()
            if DriveModeState.wanted,
               automaticLiveModeCanRun(hasReadySession: sessionHeldForUpdate, isDemoMode: demoMode,
                                       locationAuthorized: locationAuthorized,
                                       firstRunOnboardingActive: firstRunOnboardingActive),
               UIApplication.shared.applicationState == .active {
                resumeDriveModeIfWanted()
            }
        default:
            awaitingHereFix = false
            updateLocationDesiredAccuracy()
            manager.stopUpdatingLocation()   // revoked mid-session
            manager.allowsBackgroundLocationUpdates = false
            // A real Live Activity without the Location residency guarantee can outlive the app's
            // reconnect timer and freeze on a stale state. End the surface but preserve wanted so
            // restoring permission can start it again.
            if driveModeOn, !demoMode { suspendDriveModeForLinkEnd() }
        }
        // Revoking Location makes every place rule inactive immediately; reveal its retained rows
        // and refresh Live Mode instead of waiting for an unrelated BLE publication.
        rebuildActiveIgnoredMacSet()
        if activeIgnoredMacSet != publishedActiveIgnoredMacs { publishDetections() }
    }
}
