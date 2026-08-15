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

/// A device the user has chosen to silence (one whitelist entry).
struct IgnoredDevice: Codable, Identifiable, Equatable {
    let mac: String
    var label: String        // renameable, same as WatchedDevice
    var id: String { mac }
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
    /// A record past notifyCap() is consumed from the ring and skipped without being counted,
    /// so it is gone and no retry can refill it. Disclosure, not resync: rides the banner.
    /// ble-protocol.md, "Why the replay check needs all three numbers".
    var unreplayed: Int = 0
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

    /// Recovery hint shown when a connect attempt ends before the link is usable. The overwhelmingly
    /// likely cause on a board that is present and advertising is the PAIRING WINDOW: a phone that
    /// has never bonded may only pair in the two minutes after power-on, and outside that the board
    /// refuses at connect (see ACAB_PAIR_WINDOW_MS in the firmware). The board cannot tell us why it
    /// refused, because it hangs up before any of our characteristics exist to be read, so the app
    /// offers the one recovery that covers this and most other stuck states. Cleared on a good link.
    @Published private(set) var connectHint: String?

    /// The one sentence a user needs. Kept identical to Android's PAIR_WINDOW_HINT.
    static let pairWindowHint = "Turn the beacon off and on, then connect within two minutes."
    @Published private(set) var discovered: [DiscoveredDevice] = []
    @Published private(set) var detections: [Detection] = []
    @Published private(set) var status: DeviceStatus?
    @Published private(set) var connectedName: String?
    @Published private(set) var ignored: [IgnoredDevice] = [] {
        // keep an O(1) lookup set of the (already-lowercased) ignored MACs in step with the array,
        // so the per-notify isIgnored() check is a set hit instead of a linear scan that lowercased
        // every entry. Rebuilt on the rare mutations (load / ignore / unignore), not on the hot path.
        didSet {
            ignoredMacs = Set(ignored.map { $0.mac })
            DeviceNames.shared.rebuild(watched: watched, ignored: ignored)
        }
    }
    private var ignoredMacs: Set<String> = []
    @Published private(set) var watched: [WatchedDevice] = [] {
        didSet { DeviceNames.shared.rebuild(watched: watched, ignored: ignored) }
    }
    /// Raised when a star is refused because the watchlist is already at the firmware's 256-entry
    /// cap. Lets the UI tell the user the list is full instead of the tap silently doing nothing;
    /// the view owns the reset (it's the alert's binding), so this is settable, not private(set).
    @Published var watchlistFull = false
    /// "Mark all seen" baseline. A detection counts as New if we first heard it after
    /// this point. Nil until the user sets a watermark (then everything older is "seen").
    @Published private(set) var seenWatermark: Date?
    @Published private(set) var demoMode = false   // canned sample data, no real board
    private var demoNeedsRelocate = false          // demo seeded before a GPS fix -> re-place around the user when one arrives
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
    /// Hide detection counts on the Lock Screen banner (user setting, default on). The
    /// counts still show in the Dynamic Island and in the app.
    @Published var redactLockScreen = true {
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
    private var configChar: CBCharacteristic?
    private var otaChar: CBCharacteristic?

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

    /// True once THIS session actually reached ready: the Detections CCCD subscribe succeeded, so
    /// the buffer handshake could run. Gates the unexpected-drop auto-reconnect. A connect that
    /// NEVER reached ready - the user declined the encryption/pairing prompt, or the board holds
    /// stale bond keys for another phone and drops us during setup - must fail to the resting
    /// screen, not arm an indefinite reconnect that re-fires the pairing prompt on every
    /// re-advertise. Mirrors Android's sessionWasReady, which is set only in finishReady, i.e.
    /// after the subscribe chain succeeds; .connected alone is too early (it lands before the
    /// async CCCD write resolves). Cleared on every fresh connect() and in the teardown paths.
    private var sessionWasReady = false

    /// Watchdog for a FRESH scan-connect. central.connect has no OS timeout and didFailToConnect
    /// never fires for a board that simply is not there (powered off since discovery, or claimed
    /// by another phone), so without this a tapped stale row pins connectionState at .connecting
    /// forever. One-shot, armed only by connect(_:); the unexpected-drop auto-reconnect stays
    /// deliberately indefinite and never runs it.
    private var connectTimeoutTimer: Timer?
    private let connectTimeoutInterval: TimeInterval = 15

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
    private let redactKey = "acab.redactLockScreen"

    // Offline detection buffer. The board buffers detections (encrypted at rest with
    // our key) while we're away, then replays them on {sync}. We file replayed records
    // into the same store + dedup as live ones, but with their original timestamp and
    // no alert.
    @Published private(set) var bufferingOn = false   // mirrors the board's "bufon"
    @Published private(set) var ledOn = true          // mirrors the board's "ledon" (absent = on)
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
    private let fixMaxAge: TimeInterval = 120
    private var freshCoord: CLLocationCoordinate2D? {
        guard let f = lastFix, Date().timeIntervalSince(f.timestamp) <= fixMaxAge else { return nil }
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
    private var lastPublish = Date.distantPast     // when we last pushed to @Published
    private let publishInterval: TimeInterval = 0.3   // ~3 Hz ceiling on UI updates

    override init() {
        super.init()
        loadIgnored()
        loadWatched()
        if let t = UserDefaults.standard.object(forKey: watermarkKey) as? Double {
            seenWatermark = Date(timeIntervalSince1970: t)
        }
        approxSeenSeq = UInt32(clamping: UserDefaults.standard.integer(forKey: approxSeenSeqKey))
        loadPersistedDetections()   // bring back any history filed in a past session
        if let v = UserDefaults.standard.object(forKey: redactKey) as? Bool { redactLockScreen = v }
        // Keep the Drive-mode toggle honest: the controller flips it back off if the Live
        // Activity ends or the user swipes it away, and re-adopts one still running from a
        // previous launch (so a relaunch mid-drive resumes instead of orphaning it).
        liveActivity.onInactive = { [weak self] in
            self?.driveLinkGrace?.invalidate(); self?.driveLinkGrace = nil   // activity is gone; nothing to auto-end
            // Reached ONLY on an OUTSIDE end: a swipe-away, the in-activity End button, the
            // Control Center toggle, or the system's own ceiling. Our own teardowns cannot land
            // here, because end()/endBlocking() nil `activity` before ending and handleInactive
            // guards on `activity?.id == id`. That is exactly what makes it safe to clear the
            // persisted intent here: a user dismissing the activity means OFF and must not
            // resurrect, while the willTerminate teardown leaves the intent standing.
            self?.setDriveModeWanted(false)
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
        NotificationCenter.default.addObserver(forName: UIApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
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
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
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
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            // Re-read notification permission on EVERY foreground, not just at launch. A user who
            // grants it in iOS Settings mid-session would otherwise stay silently unauthorized for
            // the whole process, with green toggles over a dead feature.
            self.notifier.refreshAuthorization()
            self.locationAuthorizationStatus = self.locationManager.authorizationStatus
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
        if liveActivity.adoptExisting() { driveModeOn = true }
        notifier.refreshAuthorization()   // trust the system's answer, not our own last request
        alertMode = AlertMode(rawValue: UserDefaults.standard.string(forKey: alertModeKey) ?? "") ?? .buzzer
        if alertMode == .vibrate { requestFocusAuthIfNeeded() }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        locationManager.activityType = .automotiveNavigation   // what this actually is: tagging hits from a moving car
        locationAuthorizationStatus = locationManager.authorizationStatus
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

    // MARK: - Intent

    private func initializeCentral() {
        guard central == nil else { return }
        connectionState = .unknown
        central = CBCentralManager(delegate: self, queue: nil)
    }

    /// The only first-use path. ConnectView calls this from the rationale's primary button, so
    /// both Bluetooth and Location prompts follow an explicit, informed action. Either permission
    /// may be denied; Bluetooth is required to scan, while Location only affects observer pins.
    func startScanFromUser() {
        requestLocationAccessIfNeeded()
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

    /// Location is optional and is requested only after ConnectView has explained its use and the
    /// user asks to scan. Existing grants simply begin updates when a connected session needs them.
    func requestLocationAccessIfNeeded() {
        locationAuthorizationStatus = locationManager.authorizationStatus
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            startLocationIfNeeded()
        }
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
        sessionWasReady = false   // a fresh session hasn't reached ready until its CCCD subscribe lands
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

    /// The fresh connect never resolved: cancel it and go back to scanning, so the stale row
    /// only re-lists if the board is really still advertising. It gets no intentional-disconnect
    /// target: a cancelled never-established connect yields no didDisconnect callback to consume it.
    private func connectTimedOut() {
        connectTimeoutTimer = nil
        guard connectionState == .connecting, reconnectTarget == nil,
              otaAwaitingReboot == nil, let pending = peripheral else { return }
        cancelUpdatesForLinkTeardown(reason: "The board connection timed out during the update.")
        central?.cancelPeripheralConnection(pending)
        peripheral = nil
        connectionState = (central?.state == .poweredOn) ? .idle : .unknown
        if central?.state == .poweredOn { startScan() }
    }

    func disconnect() {
        let pendingOtaReconnect = otaAwaitingReboot != nil ? peripheral : nil
        cancelUpdatesForLinkTeardown(
            reason: "Update cancelled because you disconnected from the board.")
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
            configChar = nil
            otaChar = nil
            otaCapable = false
            connectedName = nil
            status = nil
            syncingOfflineLog = false
            histResyncs = 0
            sessionWasReady = false
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
        firstSeenAt.removeAll(); capturedLoc.removeAll(); bestRssi.removeAll(); detections = []
        histBasis.removeAll(); histAnchoredBoots.removeAll()
        liveCounts = (0, 0, 0, 0, 0, 0)
        lastLiveKind = ""; lastLiveSeen = Date()
    }

    /// The user-confirmed "Clear log": drop the log from memory AND from disk. This is the only
    /// path allowed to delete the file. It's gated behind a confirmation that tells the user to
    /// export first, so nothing else may reach the delete, or the unguarded path becomes the
    /// destructive one.
    func clearDetections() {
        resetDetectionState()
        deletePersistedDetections()   // also wipe the on-disk history
        if driveModeOn { liveActivity.update(liveState()) }
        writeWidgetSummary(force: true)   // count is now 0; reflect it on the home widget
    }

    // MARK: - Drive mode (Live Activity: Dynamic Island + Lock Screen counter)

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
        // Persist the user's choice even when Live Activities are currently disabled. If they
        // enable the capability in Settings, foreground reconciliation can honor the choice.
        setDriveModeWanted(true)    // survives the willTerminate teardown below
        guard liveActivity.isAvailable else { return }
        liveActivity.dropIfInactive()
        if liveActivity.adoptExisting() {   // reuse one already running (e.g. the Control Center toggle)
            driveModeOn = true
            liveActivity.update(liveState())
            return
        }
        // `connectionState` becomes connected before the encrypted Detections subscription
        // resolves. Remember an early On choice, but do not create the counter until the board is
        // genuinely ready. The successful CCCD callback retries this method.
        guard sessionWasReady || demoMode else { return }
        // Reflect whether the system actually started the activity (request can fail
        // silently); the controller also resets driveModeOn if it's later dismissed.
        driveModeOn = liveActivity.start(deviceName: connectedName ?? "beacons",
                                         state: liveState())
        startLocationIfNeeded()   // Drive mode's background residency rides on location updates
    }

    func endDriveMode() {
        stopDriveModeActivity(rememberOff: true)
    }

    /// A board session ending must remove its stale system surface, but it is not the same choice
    /// as switching the counter off. Preserve the preference so the next ready foreground session
    /// starts the counter again.
    private func suspendDriveModeForLinkEnd() {
        stopDriveModeActivity(rememberOff: false)
    }

    private func stopDriveModeActivity(rememberOff: Bool) {
        driveLinkGrace?.invalidate(); driveLinkGrace = nil   // no pending auto-end to fire later
        if rememberOff { setDriveModeWanted(false) }
        driveModeOn = false
        liveActivity.end()
        writeWidgetSummary(force: true)   // reflect "not connected / drive off" on the home widget
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

    /// Re-sync Drive mode with reality when the app returns to the foreground: adopt an
    /// activity started by the Control Center toggle, and turn the flag off if the Live
    /// Activity was ended (the in-activity End button, the toggle, or a swipe-away).
    func reconcileDriveMode() {
        // Pick up an intent change made while backgrounded (the in-activity End button or the
        // Control Center toggle write DriveModeState.wanted directly), so the settings toggle
        // reflects it on return.
        driveModeWanted = DriveModeState.wanted
        liveActivity.dropIfInactive()
        if liveActivity.adoptExisting() {
            driveModeOn = true
            liveActivity.update(liveState())
            startLocationIfNeeded()
        } else if DriveModeState.wanted, liveActivity.isAvailable,
                  sessionWasReady || demoMode {
            // No activity running, but the user never turned Drive mode off - so this is the
            // relaunch case: willTerminate ended the activity, and the intent outlived it.
            // Re-create the surface. This is the only path that reads `wanted`; every way of
            // turning Drive mode OFF (endDriveMode, the End button, the Control Center toggle,
            // a swipe-away via onInactive) clears it first, so a deliberate off cannot land here.
            // Foreground-safe by construction: reconcileDriveMode is only called from scenePhase
            // .active, which is the state iOS requires to begin a Live Activity.
            startDriveMode()
        } else {
            driveModeOn = false
            stopLocationIfIdle()
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

    /// Snapshot the live store into the Live Activity's per-category counts. Mirrors the
    /// dashboard tiles exactly (ALPR = flockCamera + flockRaven; no police bucket).
    private func liveState() -> DetectionActivityAttributes.DetectionState {
        // O(1): counts are maintained by publishDetections() (which already iterates the
        // store for the sort), not re-scanned here on every detection notify.
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
    // WidgetKit to refresh. Kept cheap because it runs on the detection publish path.
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
    // we (a) always write the shared defaults fresh, so whichever refresh does land is current,
    // and (b) spend a reload only when the summary the widget actually RENDERS changed, at most
    // once per widgetReloadMinGap.
    private var lastWidgetReload = Date.distantPast
    private let widgetReloadMinGap: TimeInterval = 30
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
        let day = widgetDayIndex
        let startOfToday = Double(day) * 86400 - Double(TimeZone.current.secondsFromGMT())
        // Today's count = distinct detections first heard today (local). Naturally resets at
        // local midnight.
        // The old comment claimed this "skips replayed-approx history (its synthetic time sits near
        // epoch)". That stopped being true the moment bracketing moved those rows OFF the epoch onto
        // a plausible ordering key: a bracket straddling local midnight would now silently count a
        // row we explicitly cannot date to today. Exclude anything whose instant is not measured.
        // Per-category counts come out of this SAME loop, and are therefore also TODAY-scoped.
        // That is deliberate: the widget's headline number is today's count, so a breakdown taken
        // from the whole-store liveCounts would not sum to it and would read as a bug. These use
        // the same hidesInstant gate, so an undateable row is excluded from both the total and the
        // categories rather than being counted in one and not the other.
        var todayCount = 0
        var cat: [String: Int] = [:]
        for (id, first) in firstSeenAt where first.timeIntervalSince1970 >= startOfToday {
            if timeBasis(for: id, stamp: first).hidesInstant { continue }
            todayCount += 1
            if let t = store[id]?.type, let key = t.widgetCategoryKey { cat[key, default: 0] += 1 }
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
        d.set(todayCount, forKey: "w_countToday")
        d.set(day,        forKey: "w_day")
        d.set(lastType,   forKey: "w_lastType")
        d.set(lastAt,     forKey: "w_lastAt")
        d.set(connected,  forKey: "w_connected")
        // Today's breakdown for the medium face. One key per category rather than a dictionary,
        // because UserDefaults across an App Group is happiest with plain scalars and the widget
        // reads them individually anyway. Keys match DeviceType.widgetCategoryKey.
        let catCounts = WidgetCategory.allCases.map { cat[$0.rawValue] ?? 0 }
        for (c, n) in zip(WidgetCategory.allCases, catCounts) { d.set(n, forKey: c.defaultsKey) }
        // The defaults are now fresh no matter what. Only spend a reload if the glance actually
        // changed (or a connect/disconnect edge forces it): reloading for identical data is what
        // used to exhaust WidgetKit's budget and freeze the widget until it was re-added.
        let snapshot = WidgetSummarySnapshot(day: day, count: todayCount, lastType: lastType,
                                             lastAt: lastAt, connected: connected, cats: catCounts)
        let changed = snapshot != lastWidgetSnapshot
        lastWidgetSnapshot = snapshot
        guard force || changed else { return }
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

    /// Is this MAC on the ignore list? O(1) set hit against the lowercased ignore set.
    func isIgnored(_ mac: String) -> Bool { ignoredMacs.contains(mac.lowercased()) }

    /// Silence a device: the board stops alerting on it and it drops out of the app.
    /// Ignoring and watching are mutually exclusive, so this also un-stars the MAC.
    /// Capped at the firmware's 256 like the bulk path: the board truncates the list, so a 257th
    /// entry would sit in the app looking silenced while the board kept alerting on it.
    func ignoreDevice(_ d: Detection) {
        let mac = d.mac.lowercased()
        guard !isIgnored(mac), ignored.count < 256 else { return }
        let wasWatched = isWatched(mac)
        watched.removeAll { $0.mac == mac }
        ignored.append(IgnoredDevice(mac: mac, label: d.displayName))
        persistIgnored(); sendIgnoreList()
        if wasWatched { persistWatched(); sendWatchList() }
        for e in store.values where e.mac.lowercased() == mac { evictKey(e.id) }
        publishDetections()
    }

    /// Silence several devices at once (the Logbook's select mode). One ignore-list
    /// push and one republish instead of one per row. The firmware accepts up to 256
    /// entries, so we cap the list there.
    func ignoreDevices(_ list: [Detection]) {
        var added = false
        var unstarred = false
        for d in list {
            let mac = d.mac.lowercased()
            guard !isIgnored(mac), ignored.count < 256 else { continue }
            if isWatched(mac) { watched.removeAll { $0.mac == mac }; unstarred = true }
            ignored.append(IgnoredDevice(mac: mac, label: d.displayName))
            added = true
        }
        guard added else { return }
        persistIgnored(); sendIgnoreList()
        if unstarred { persistWatched(); sendWatchList() }
        let muted = Set(ignored.map { $0.mac })
        for e in store.values where muted.contains(e.mac.lowercased()) { evictKey(e.id) }
        publishDetections()
    }

    /// Un-silence a device.
    func unignore(_ mac: String) {
        ignored.removeAll { $0.mac == mac.lowercased() }
        persistIgnored(); sendIgnoreList()
    }

    // MARK: - Watchlist (starred devices)

    /// Is this MAC starred?
    func isWatched(_ mac: String) -> Bool { watched.contains { $0.mac == mac.lowercased() } }

    /// Star a device: the board alerts on this exact MAC every time it's seen, even
    /// with no signature match. Watching and ignoring are mutually exclusive, so this
    /// also removes the MAC from the ignore list (the scan path drops ignored MACs
    /// before classification, so a starred MAC must not also be silenced).
    func watchDevice(_ d: Detection) {
        let mac = d.mac.lowercased()
        guard !isWatched(mac) else { return }
        // At the firmware's 256 cap the board would truncate the list, so a 257th star would sit in
        // the app looking watched while the board never alerted on it. Refuse, but tell the user.
        guard watched.count < 256 else { watchlistFull = true; return }
        let wasIgnored = isIgnored(mac)
        ignored.removeAll { $0.mac == mac }
        watched.append(WatchedDevice(mac: mac, label: d.displayName))
        persistWatched(); sendWatchList()
        if wasIgnored { persistIgnored(); sendIgnoreList() }
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
            return
        }
        // one-time migration off the old plaintext, backed-up UserDefaults store, then scrub it so
        // the tracked-gear MACs + names no longer sit unprotected in the app's defaults / backup.
        if let data = UserDefaults.standard.data(forKey: watchKey),
           let list = try? JSONDecoder().decode([WatchedDevice].self, from: data) {
            watched = list
            persistWatched()
            UserDefaults.standard.removeObject(forKey: watchKey)
        }
    }
    private func persistWatched() {
        writeProtectedList(watched, to: watchURL)
    }
    /// Send the watch list to the board so it alerts on those MACs at the source. Same
    /// MAC string format as the ignore push, chunked the same way, debounced per key.
    /// USER-EDIT path only (see sendIgnoreList).
    private func sendWatchList() {
        setListClearPending("watch", watched.isEmpty)   // tracks the edit; re-starring retires it
        scheduleListPush("watch")
    }

    // MARK: - Seen watermark ("mark all seen")

    /// Drop a "seen" baseline at now: everything currently in the log becomes "seen",
    /// and the New-only filter then shows only what arrives after this.
    func markAllSeen() {
        let now = Date()
        seenWatermark = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: watermarkKey)
        // Baseline the pseudo band too, on its stable axis: the highest buffer seq among the
        // still-.unknown rows is the most recent undateable record, so anything the board hands
        // us beyond it is New. Without this second baseline a post-mark drain of records nothing
        // can date (pre-boot-counter firmware, or a drain that never closes) could never surface
        // in the New-only filter again: pseudo stamps sit just above the epoch, forever below any
        // wall-clock watermark. Mirrors Android's approxWatermark.
        let maxUnknownSeq = histBasis.values.filter { $0.basis == .unknown }.map(\.seq).max() ?? 0
        if maxUnknownSeq > approxSeenSeq { approxSeenSeq = maxUnknownSeq }
        UserDefaults.standard.set(Int(approxSeenSeq), forKey: approxSeenSeqKey)
    }

    /// First-run baseline for the New dots. The first time the log is ever opened, treat whatever
    /// is already stored as seen, so a fresh install (or a first offline backlog) does not paint a
    /// dot on every row. Once-only, guarded by a persisted flag; from then on the watermark
    /// advances each time the user leaves the Log tab (see MainTabView.onChange(of: tab)), so a New
    /// dot always means "arrived since you last looked". Mirrors Android's seedSeenWatermarkOnce.
    func seedSeenWatermarkOnce() {
        guard !UserDefaults.standard.bool(forKey: seenWatermarkSeededKey) else { return }
        markAllSeen()
        UserDefaults.standard.set(true, forKey: seenWatermarkSeededKey)
    }

    /// Clear the baseline so every detection counts as New again. Also re-arms the first-open
    /// seed, so a deliberate "show me everything as new" reset is not silently undone the next
    /// time the Log opens.
    func clearSeenWatermark() {
        seenWatermark = nil
        approxSeenSeq = 0   // pseudo-band baseline back to "nothing marked seen" too
        UserDefaults.standard.removeObject(forKey: watermarkKey)
        UserDefaults.standard.removeObject(forKey: approxSeenSeqKey)
        UserDefaults.standard.removeObject(forKey: seenWatermarkSeededKey)
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
            return
        }
        // one-time migration off the old plaintext, backed-up UserDefaults store, then scrub it.
        if let data = UserDefaults.standard.data(forKey: ignoreKey),
           let list = try? JSONDecoder().decode([IgnoredDevice].self, from: data) {
            ignored = list
            persistIgnored()
            UserDefaults.standard.removeObject(forKey: ignoreKey)
        }
    }
    private func persistIgnored() {
        writeProtectedList(ignored, to: ignoreURL)
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

    private func writeProtectedList<T: Encodable>(_ value: T, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(value) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var v = URLResourceValues()
            v.isExcludedFromBackup = true
            var u = url
            try? u.setResourceValues(v)
        } catch { }
    }
    /// Send the ignore list to the board so it suppresses those MACs at the source.
    /// USER-EDIT path only; the connect-time re-statement goes through resyncListsOnConnect().
    private func sendIgnoreList() {
        setListClearPending("ignore", ignored.isEmpty)   // tracks the edit; re-adding retires it
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
        if !ignored.isEmpty || listClearPending("ignore") { sendIgnoreListResync() }
        if !watched.isEmpty || listClearPending("watch") { sendWatchListResync() }
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
        lastListPush[key] = Date()
        let macs = (key == "watch") ? watched.map({ $0.mac }) : ignored.map({ $0.mac })
        sendMacList(key: key, macs: macs)
        // The clear is only delivered once a board has actually taken the write. writeConfig
        // silently no-ops when it has no peripheral or no characteristic, so clearing the flag off
        // a dropped write would lose the user's intent for good.
        if macs.isEmpty && canWriteConfig { setListClearPending(key, false) }
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

        var a = 0, dr = 0, b = 0, tr = 0, gl = 0, nc = 0
        for d in store.values {
            switch d.type {
            case .flockCamera, .flockRaven: a += 1
            case .drone:                    dr += 1
            case .axonBodyCam:              b += 1
            case .tracker:                  tr += 1
            case .recordingGlasses:         gl += 1
            case .networkCamera:            nc += 1   // counted since 2026-07-31: the Live Activity renders this column only when the opt-in is on
            case .nearbyDevice, .watched, .unknown:
                break   // Desert-mode, starred and unrecognized-type hits don't fill the drive-mode buckets
            }
        }
        liveCounts = (a, dr, b, tr, gl, nc)
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
            detections = sorted.filter { !evictIds.contains($0.id) }
        } else {
            detections = sorted
        }
        writeWidgetSummary()   // mirror today's count + last detection to the home widget (reload throttled)
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
        guard let last = lastSeen[id] else { return true }
        return now.timeIntervalSince(last) > seconds
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
        var rows = ["detected_at,time_basis,time_precision_s,type,mac,rssi,source,matched_on,confidence,sightings,approx_lat,approx_lon,company_id,uas_id,drone_lat,drone_lon,altitude_m,speed_ms,heading_deg,height_agl_m,operator_lat,operator_lon,operator_alt_m,rid_status,maker"]
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
            // `lat`/`lon` on the wire is OVERLOADED: ble-protocol.md line 88 defines it as
            // "drones: broadcast position; others: detector GPS". Without this gate every
            // non-drone row copied the PHONE's own position into drone_lat/drone_lon. Measured on
            // a real 2747-row export: 2746 of 2746 non-drone rows carried a bogus drone position,
            // 555 of them byte-identical to that row's own approx_lat/lon. Anything reading the
            // drone columns (a GPX/KML export, a map layer) would plot thousands of phantom
            // aircraft. This comment already claimed "blank for a non-drone row"; now it is true.
            // Kept byte-identical to Android's detectionsCsv.
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
    /// TEST COVERAGE, stated honestly: BeaconsTests/ExportTests.swift covers THIS side (13 cases:
    /// the drone gate, waypoint counts, escaping, the bracketed-row time omission). Android's
    /// detectionsGpx is NOT yet under test - it is an instance method on the manager and needs the
    /// same pure-function extraction this side already has. The JSON fixtures in ExportTests are
    /// deliberately written to be reusable verbatim when that happens, so this is a gap, not a
    /// divergence. Do not claim parity is enforced until AcabBleManagerExportTest.kt exists.
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
    func windowObservationCount(startMs: Int64, stopMs: Int64) -> Int {
        windowObservationTimes(startMs: startMs, stopMs: stopMs).count
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

    /// Toggle the board's ALPR (Flock) detector (on by default).
    func setFlockEnabled(_ on: Bool) { writeConfig(["flock": on]) }

    /// Toggle the board's drone (remote ID) detector (on by default).
    func setDroneEnabled(_ on: Bool) { writeConfig(["drone": on]) }

    /// Toggle the drone vendor-OUI FALLBACK (off by default). Sub-option of the drone
    /// detector: on, a DJI/Parrot OUI with no Remote ID is also flagged; off (the default),
    /// only the Remote ID path fires. Off by default because a stationary Parrot gadget can't
    /// be distinguished from a flying drone by OUI alone, so it's a false-positive source.
    func setDroneOuiEnabled(_ on: Bool) { writeConfig(["droneoui": on]) }

    /// Toggle the board's network-camera detector (off by default). Mirrors the drone-OUI
    /// opt-in: when on, the board enables the 802.11 DATA-frame source-MAC path and flags a
    /// branded IP-camera OUI (Hikvision/Dahua/etc.) streaming on the host WiFi. Off by default
    /// because that data-frame path adds CPU + 2.4GHz coexistence load, so it stays disabled
    /// until the user opts in. It matches known IP-camera BRANDS only and cannot find every camera.
    func setNetcamEnabled(_ on: Bool) { writeConfig(["netcam": on]) }

    /// Toggle the board's body-cam CATEGORY: the Axon BWCDEVICE payload tag, the Axon OUI, the
    /// Utility BodyWorn signatures, and the broad Motorola Solutions OUI proxy. Off silences all
    /// of them. It no longer clobbers the Motorola sub-setting below, so turning the category
    /// back on restores whatever the user last chose there.
    func setBodyCamEnabled(_ on: Bool) { writeConfig(["bodycam": on]) }

    /// Toggle the broad Motorola Solutions OUI match, a sub-option of the body-cam detector.
    /// Off quiets just that vendor proxy (confidence 45, deliberately below the weak-match
    /// threshold, because the same corporate blocks cover two-way radios and docks); the
    /// field-validated Axon BWCDEVICE tag and the Utility BodyWorn signatures keep running.
    /// Classification needs BOTH switches, so this changes nothing while the category is off.
    func setMotorolaEnabled(_ on: Bool) { writeConfig(["motorola": on]) }

    /// Toggle the board's BLE item-tracker detector (off by default).
    func setTrackerEnabled(_ on: Bool) { writeConfig(["tracker": on]) }

    /// Toggle the board's recording / smart-glasses detector (on by default, like body cams).
    func setGlassesEnabled(_ on: Bool) { writeConfig(["glasses": on]) }

    /// Toggle Desert mode: the board reports EVERY device in range (not just signatures).
    /// Enabling it drops alerts to Silent; with everything reporting in, the buzzer and
    /// haptics would otherwise never stop. The user can switch sound back on afterward.
    func setDesertMode(_ on: Bool) {
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
        ledOn = on
        writeConfig(["led": on])
    }

    /// Erase the board's stored buffer. The board restarts its record sequence from 1 after a
    /// wipe, so reset our replay cursor to 0. A stale-high cursor would skip every post-erase
    /// record on the next reconnect and the fresh buffer would be lost.
    func clearBufferLog() {
        writeConfig(["clearlog": true])
        lastSeq = 0
        lastGoodSeq = 0
        histHighestSeq = 0   // a stale high-water mark would re-advance the cursor past fresh records
    }

    /// Master audio on/off.
    func setBuzzerEnabled(_ on: Bool) { writeConfig(["buzzer": on]) }

    /// Re-assert attempts made since the app and board last agreed on the buzzer. Reset on every
    /// fresh connection (see the connect path) so a stale value can't skip the grace period.
    private var buzzerReassertAttempts = 0
    private static let maxBuzzerReasserts = 3

    /// Reconcile the alert mode against what the board actually reports.
    ///
    /// THE BUG THIS FIXES (reported 2026-07-31): turn Desert mode on, then off, and the app showed
    /// sound ON while the board stayed silent. `alertMode` was optimistic local state: setAlertMode()
    /// assigned it, persisted it and fired writeConfig(["buzzer":]) without checking the result,
    /// while ingestStatus reconciled `bufferingOn` and `ledOn` from status but never the buzzer.
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
        guard wantBuzzer != s.buzzer else { buzzerReassertAttempts = 0; return }

        if buzzerReassertAttempts < Self.maxBuzzerReasserts {
            buzzerReassertAttempts += 1
            setBuzzerEnabled(wantBuzzer)     // most likely a dropped write; say it again
            return
        }
        // Re-asserting did not take. Only correct the UI where the mapping is LOSSLESS.
        if wantBuzzer {
            // We claim sound, the board is muted: the originally reported bug. Tell the truth for
            // this session, WITHOUT persisting, so a transient fault can't rewrite the preference.
            alertMode = .silent
        }
        // Otherwise the board is audible while the user chose .vibrate or .silent. Leave the mode
        // alone (both are honest about what the PHONE does) and stop writing; an audible board at
        // this point is a link or firmware fault, not a preference to overwrite.
    }

    /// Pick how alerts reach you. Only `.buzzer` keeps the board's buzzer live;
    /// the others mute it.
    func setAlertMode(_ m: AlertMode) {
        alertMode = m
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

    /// Buzz the phone on a fresh sighting - a sharper pattern for priority threats.
    private func alertHaptic(for type: DeviceType) {
        switch type {
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
        var cfg: [String: Any] = ["volume": max(0, min(100, v))]
        if preview { cfg["beep"] = true }
        writeConfig(cfg)
    }

    /// Turn the board's BLE detection scan on/off. This only stops scanning - our
    /// BLE link to the board stays up.
    func setBLEScan(_ on: Bool) { writeConfig(["ble": on]) }

    /// Turn the board's Wi-Fi (promiscuous) detection scan on/off.
    func setWiFiScan(_ on: Bool) { writeConfig(["wifi": on]) }
    /// WiFi eco: 0/3/7/15 s of RX sleep between channel sweeps (battery SKU). Firmware snaps to the ladder.
    func setWifiEco(_ sec: Int) { writeConfig(["wifiEco": sec]) }

    private func writeConfig(_ dict: [String: Any]) {
        guard let peripheral, let configChar,
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        peripheral.writeValue(data, for: configChar, type: .withResponse)
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
        guard let peripheral,
              let svc = peripheral.services?.first(where: { $0.uuid == ACABProfile.service }),
              let ch = svc.characteristics?.first(where: { $0.uuid == ACABProfile.status })
        else { return }
        peripheral.readValue(for: ch)
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
        configChar = nil
        otaChar = nil
        otaCapable = false
        connectedName = nil
        status = nil
        syncingOfflineLog = false
        histResyncs = 0
        sessionWasReady = false
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

    /// Highest buffer seq we've successfully filed. Persisted so a reconnect only asks
    /// the board for records newer than this. Survives disconnects and relaunches -
    /// disconnect cleanup must NOT clear it.
    private var lastSeq: UInt32 {
        get { UInt32(UserDefaults.standard.integer(forKey: lastSeqKey)) }
        set { UserDefaults.standard.set(Int(newValue), forKey: lastSeqKey) }
    }

    /// The Detections-replay handshake, run once the Detections characteristic starts
    /// notifying: hand the board our key, the current epoch, then ask it to replay
    /// everything newer than lastSeq. Order matters and must follow the subscribe.
    private func sendBufferHandshake() {
        let key = bufferKeyHex()
        // Reset per-drain counters; resume contiguity from where we left off.
        histReceived = 0
        histPseudoTick = 0
        lastGoodSeq = lastSeq
        histHighestSeq = lastSeq
        histResyncs = 0   // fresh connection, fresh gap-retry budget
        // histAnchoredBoots deliberately NOT cleared: boot counters are monotonic, so anchors
        // proven by an earlier drain (or rebuilt from the persisted log at launch) bound this
        // drain's undateable records just as soundly, turning a loose "before <sync>" bracket
        // into a tight "before <boot N's min>". Matches Android's bootMinAt/bootMaxAt, which
        // only the clear-log path drops.
        syncStartedAt = Date()          // the anchor moment, captured before the epoch push below
        // The pill is driven by the board's {"hist":"begin"} lead-in, NOT by this handshake: the
        // board streams sentinels only when it actually buffered records, so a connect with the
        // buffer off/empty shows no pill (and can't stick waiting for an end that never comes).
        syncingOfflineLog = false
        offlineSyncCount = 0
        offlineSyncTotal = 0   // the board's {"hist":"begin"} fills this in when a real drain starts
        writeConfig(["key": key])
        writeConfig(["epoch": Int(Date().timeIntervalSince1970)])
        writeConfig(["sync": Int(lastSeq)])
    }

    // MARK: key (Keychain)

    private let keyTag = "tech.beacons.app.bufferKey"

    /// Our persistent 32-byte buffer key as 64 lowercase hex chars. Generated once and
    /// stored in the Keychain, reused on every launch.
    private func bufferKeyHex() -> String {
        let raw = loadOrCreateBufferKey()
        return raw.map { String(format: "%02x", $0) }.joined()
    }

    private func loadOrCreateBufferKey() -> Data {
        if let existing = keychainReadKey() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let data = Data(bytes)
        keychainWriteKey(data)
        return data
    }

    private func keychainReadKey() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private func keychainWriteKey(_ data: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: keyTag,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        // AfterFirstUnlockThisDeviceOnly: readable for the while-locked BLE handshake, but
        // ThisDeviceOnly makes the key non-exportable (kept out of iTunes/Finder backups).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
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

    private func checkpointHistory() {
        let cursor = lastGoodSeq
        checkpointInFlight = true
        persistDetections { [weak self] saved in
            guard let self else { return }
            self.checkpointInFlight = false
            guard saved, cursor > self.lastSeq else { return }
            self.lastSeq = cursor
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
            DispatchQueue.main.async { self.applyLoadedRows(newest) }
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

    /// The delete has to ride the same serial queue as the writes, or it loses a race it looks like
    /// it can't lose. persistDetections() snapshots on main but encodes + writes async, and .atomic
    /// renames a temp file into place, so a checkpoint dispatched before the clear (the 30 s live
    /// timer, or one of the every-200-records batches a big replay backlogs onto the queue) holds a
    /// pre-clear copy of the rows and RE-CREATES the file after a main-thread removeItem ran.
    /// Invalidating the checkpoint timer can't reach a block that's already dispatched. Enqueuing
    /// here instead puts the delete behind those writes in FIFO order, and any checkpoint after the
    /// clear hits the empty-store guard and never enqueues at all. The user confirmed "this cannot
    /// be undone" about MACs and phone GPS, so it has to actually be gone.
    private func deletePersistedDetections() {
        guard let url = persistURL else { return }
        persistQueue.async { try? FileManager.default.removeItem(at: url) }
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
                // Clamp to the uint32 wire range: n and the derived arithmetic (promised -
                // expected in handleHistEnd) must stay overflow-safe against an impostor board
                // sending Int.max/Int.min.
                offlineSyncTotal = min(4_294_967_295, max(0, (obj["n"] as? Int) ?? 0))
                if offlineSyncTotal > 0 { syncingOfflineLog = true }   // a real replay is starting
                // "from" = the first seq this drain will send (gDrain+1 on the board). After a
                // board-side buffer wipe or key change the board's seq generation resets low, so a
                // cursor left high from the previous generation can never match the fresh records:
                // the contiguous s == lastGoodSeq+1 test stalls and the whole buffer re-replays on
                // every reconnect. Rebase every cursor DOWN to from-1 so the next in-order seq
                // (== from) lands and the end-of-drain checkpoint advances in the new generation.
                // Guarded by from-1 < lastGoodSeq, so only a reset moves it (a normal reconnect or a
                // gap resync asks to sync from the cursor, i.e. from-1 == lastGoodSeq, no change).
                // Older firmware omits "from"; then leave the handshake's cursors untouched.
                // UInt32(exactly:), like the seq read below: a hostile from = 2^32+1 passes the
                // >= 1 guard and the plain narrowing traps.
                if let from = obj["from"] as? Int, from >= 1,
                   let rebased = UInt32(exactly: from - 1) {
                    if rebased < lastGoodSeq {
                        lastGoodSeq = rebased
                        histHighestSeq = rebased   // clean-end cursor advances to this; must drop too
                        lastSeq = rebased          // persisted cursor too, or the clean-end checkpoint can't advance into the new generation
                    }
                }
            } else if phase == "end" {
                // Same uint32 clamp as begin: keeps promised - expected inside safe Int range.
                handleHistEnd(expected: min(4_294_967_295, max(0, (obj["n"] as? Int) ?? histReceived)))
            }
            return
        }

        guard let d = try? JSONDecoder().decode(Detection.self, from: data) else {
            // Undecodable record - a garbled/truncated frame. (Unknown wire TYPES no longer land
            // here: Detection files them as .unknown rows now.) During a buffer drain it must
            // STILL run the drain bookkeeping: the board's end sentinel counts every record it
            // sent, so exiting before the count left histReceived short and handleHistEnd burned
            // its full histResyncCap budget re-requesting a tail that can never decode, on every
            // reconnect, for the life of the buffer. Pull just the bits the bookkeeping needs
            // off the raw frame; live frames keep the plain drop.
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["hist"] as? Bool) == true {
                recordHistoryProgress(seq: (obj["seq"] as? Int).flatMap { UInt32(exactly: $0) })
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
        // change what the activity shows (the six counter buckets plus a starred device -
        // Desert-mode .nearbyDevice fills no bucket; network cameras have had one since
        // 2026-07-31, when the columns became toggle-driven) and
        // at most one escalation per escalateMinGap: everything else rides the controller's
        // coalescer, so the counts still land within its window.
        if !d.isHistory {
            // Only a bucket this surface actually shows may name the "last ..." line.
            if d.type.onDriveSurface {
                lastLiveKind = d.type.category
                lastLiveSeen = Date()
            }
            if driveModeOn {
                var escalate = false
                if firstTime && d.type.onDriveSurface {
                    escalate = Date().timeIntervalSince(lastEscalatedPush) >= escalateMinGap
                }
                if escalate {
                    lastEscalatedPush = Date()
                    publishDetections()   // an immediate push must carry the fresh bucket counts, not the coalesced ones
                }
                liveActivity.update(liveState(), escalate: escalate)
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
            // AIRCRAFT's own Remote ID broadcast (ble-protocol.md line 88: "drones: broadcast
            // position; others: detector GPS"), so storing it here labelled the aircraft as the
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
        guard let stamp else { return .exact }
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
        if let s = seq {
            // Advance the contiguous high-water mark only on an in-order seq (mid-drain
            // checkpoints and the gap retry resume from it), but also remember the highest seq
            // actually RECEIVED: the clean-end cursor advances to that, or a seq the board
            // skipped (over-MTU record, torn slot) would pin a full-tail re-replay on every
            // reconnect forever.
            if s == lastGoodSeq + 1 { lastGoodSeq = s }
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
        if histReceived % 200 == 0 && !checkpointInFlight { checkpointHistory() }
    }

    /// End-of-drain sentinel. Verify we got every record the board promised; if a seq
    /// gap dropped some, re-issue {sync} from the last contiguous seq to refill - at most
    /// histResyncCap times per connection, because a record the phone can never receive
    /// would otherwise loop the drain forever. On a clean (or cap-accepted) drain, persist
    /// lastSeq so we don't re-request what we already have.
    private func handleHistEnd(expected: Int) {
        let ok = histReceived == expected
        if ok || histResyncs >= histResyncCap {
            // Advance the cursor to the highest seq actually RECEIVED, not just the highest
            // contiguous one: a matching count proves nothing was lost on the wire, so any
            // remaining seq gap is a board-side skip (an over-MTU record, a torn slot) that
            // no retry can ever refill - a contiguous-only cursor would pin below it and
            // re-replay the full tail on every reconnect for the life of the buffer. At the
            // retry cap the same advance is the deliberate tradeoff: accept the drain and
            // skip the undeliverable gap rather than loop (filing is idempotent by id).
            if histHighestSeq > lastGoodSeq { lastGoodSeq = histHighestSeq }
            // Bound the undateable boots BEFORE the checkpoint, or the brackets we just worked
            // out are the one thing the on-disk copy is missing. It re-keys sort stamps, so the
            // feed has to be re-sorted after it.
            resolveBracketedHistory()
            publishDetections()
            checkpointHistory()   // persist first, cursor second: see checkpointHistory
            // Drain complete: land the final tally (the per-record mirror is coalesced, so
            // the last publish may not have caught it), drop the syncing indicator and, only
            // when the board actually buffered something, raise the one-shot count banner. A
            // bare reconnect with nothing buffered (expected == 0) clears silently, no banner.
            if offlineSyncCount != histReceived { offlineSyncCount = histReceived }
            // Third number: begin.n promised vs end.n sent. A shortfall is a record the board
            // consumed from the ring and skipped (over-MTU), so it is gone and a re-drain cannot
            // refill it; disclose it in the banner instead of passing received == end.n off as
            // complete. promised == 0 means the begin sentinel never landed, so no judgement.
            let promised = offlineSyncTotal
            let unreplayed = promised > 0 ? max(0, promised - expected) : 0
            syncingOfflineLog = false
            offlineSyncTotal = 0
            histResyncs = 0
            if expected > 0 || unreplayed > 0 {
                offlineSyncBanner = OfflineSyncSummary(count: expected, unreplayed: unreplayed)
            }
        } else {
            // Gap: ask the board to replay again from the last good contiguous seq. Stay
            // in the syncing state; a fresh end sentinel will settle it.
            histResyncs += 1
            writeConfig(["sync": Int(lastGoodSeq)])
        }
        histReceived = 0
        histPseudoTick = 0
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
            ledOn = s.ledEnabled          // same, for the lights-out toggle
            reconcileBuzzer(s)            // and the buzzer, which used to be the one that drifted
            reconcileDesert(s)            // rare since firmware persists Desert; still needed for older boards / NVS wipe
            // The drive-mode columns follow the board's detector toggles, and the Live Activity is
            // otherwise only pushed from publishDetections(). Without this, flipping a detector did
            // nothing visible until the NEXT detection arrived, which in a quiet area is minutes,
            // and is worst exactly when you turn a detector ON to watch for something. Push only on
            // an actual change so a 1 Hz status frame is not a 1 Hz activity update.
            let nowEnabled = enabledWidgetCategories()
            if driveModeOn, nowEnabled != previousEnabled {
                lastPushedEnabled = nowEnabled
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
    func seedDemoData() {
        cancelUpdatesForLinkTeardown(reason: "Update cancelled before entering the demo.")
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
        demoMode = true
        connectionState = .connected
        connectedName = "beacon board"
        // "axon": true so the body-cam category shows ON and the Motorola sub-row below is not
        // dimmed - the demo forces motorolaSupported precisely to introduce that control, and a
        // dimmed sub-toggle under an off parent defeats the tour. Matches the Android seed.
        status = decodeJSON(DeviceStatus.self, [
            "fw": "beacon board 2.0.5", "up": 4920, "total": 6, "ble": true, "wifi": true,
            "axon": true, "tracker": true, "glasses": true, "buzzer": true, "vol": 70, "gps": true, "bat": 82,
        ])
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
            // block, so this row demonstrates the maker-led title end to end.
            ["t": 10, "s": 0, "meth": 1, "c": 80, "mac": "44:19:B6:22:0A:5C", "rssi": -70,
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
        demoMode = false
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
                scanWhenCentralIsReady = false
                connectionState = .idle
                startScan()
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
            // lingers and blocks recovery.
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
        checkpointLive()   // the session's only copy is in RAM; get it to disk before the link state goes
        stopStatusPolling()
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil
        // CoreBluetooth may provide no disconnect callback when its radio becomes unavailable.
        // Retaining any update state here would let a later board inherit this board's transfer or
        // confirmation. Settle every asynchronous owner before dropping the handle.
        let wasAwaitingOtaReboot = otaAwaitingReboot != nil
        cancelUpdatesForLinkTeardown(reason: wasAwaitingOtaReboot
            ? "Bluetooth became unavailable before the app could confirm the update. Reconnect and check the board's firmware."
            : "Bluetooth became unavailable during the update. Turn it back on, reconnect, and try again.")
        sessionWasReady = false   // whatever readiness this session had died with the radio
        intentionalDisconnectID = nil   // there may be no didDisconnect callback to consume it
        otaQuarantinedPeripheralID = nil
        nrfQuarantinedPeripheralID = nil
        peripheral = nil
        configChar = nil
        otaChar = nil
        otaCapable = false
        connectedName = nil
        status = nil
        syncingOfflineLog = false
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
        // Adopt the handle. The auto-reconnect path holds the peripheral in reconnectTarget (not
        // self.peripheral) while the connect is pending, so on a successful reconnect self.peripheral
        // is nil here - set it now, or every peripheral.* call downstream (status reads, config
        // writes, OTA) would no-op. The scan-connect and OTA-reboot paths already set it; re-assigning
        // the same object is harmless. Then clear reconnectTarget: the pending reconnect is fulfilled.
        self.peripheral = peripheral
        peripheral.delegate = self
        connectTimeoutTimer?.invalidate(); connectTimeoutTimer = nil   // the connect resolved
        if reconnectTarget === peripheral { reconnectTarget = nil }
        connectedName = peripheral.name ?? ACABProfile.advertisedName
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
        connectionState = .idle
        connectHint = BLEManager.pairWindowHint
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
        if otaQuarantinedPeripheralID == peripheral.identifier {
            otaQuarantinedPeripheralID = nil
        }
        if nrfQuarantinedPeripheralID == peripheral.identifier {
            nrfQuarantinedPeripheralID = nil
        }
        stopStatusPolling()   // link is down; a reconnect restarts it in didDiscoverCharacteristicsFor
        // An OTA in the "rebooting" phase EXPECTS this disconnect (the board just reflashed and
        // restarted). Kick off the reconnect-and-confirm instead of tearing everything down.
        if otaHandleDisconnect(peripheral) { return }
        cancelUpdatesForLinkTeardown(
            reason: "The connection to the board was lost during the update. Reconnect and try again.")
        checkpointLive()   // session over: the board buffered nothing while we were connected, so RAM was the only copy
        self.peripheral = nil
        configChar = nil
        otaChar = nil
        otaCapable = false
        connectedName = nil
        status = nil
        // A drop mid-drain never delivers the end sentinel; don't leave the indicator
        // stuck on. The next reconnect re-runs the handshake and re-enters the state.
        syncingOfflineLog = false
        histResyncs = 0   // the gap-retry budget is per connection
        let wasReady = sessionWasReady   // the auto-reconnect decision below judges THIS session
        sessionWasReady = false
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
            connectionState = (central.state == .poweredOn) ? .idle : .unknown
        }
        writeWidgetSummary(force: true)   // home widget goes to "not connected" until the reconnect handshake completes
        stopLocationIfIdle()   // no-op while Drive mode is on: a dropout must not cost us the residency
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == ACABProfile.service }) else {
            disconnect(); return
        }
        peripheral.discoverCharacteristics(
            [ACABProfile.detections, ACABProfile.config, ACABProfile.status, ACABProfile.ota], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard self.peripheral === peripheral else { return }
        otaChar = nil
        var sawDetections = false, sawConfig = false
        for ch in service.characteristics ?? [] {
            switch ch.uuid {
            case ACABProfile.detections: sawDetections = true; peripheral.setNotifyValue(true, for: ch)
            case ACABProfile.status:     peripheral.setNotifyValue(true, for: ch); peripheral.readValue(for: ch)
            case ACABProfile.config:     configChar = ch; sawConfig = true
            case ACABProfile.ota:        otaChar = ch; peripheral.setNotifyValue(true, for: ch)
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
        guard sawDetections, sawConfig else {
            let missing = [sawDetections ? nil : "detections", sawConfig ? nil : "config"]
                .compactMap { $0 }.joined(separator: " + ")
            connectHint = "This board is missing its \(missing) channel, so it cannot report to the app. "
                        + "Turn it off and on, then try again."
            intentionalDisconnectID = peripheral.identifier
            central?.cancelPeripheralConnection(peripheral)
            // Keep this unresolved attempt non-idle until its own disconnect callback consumes the
            // scoped intent. Exposing idle here allowed a replacement board to start while the old
            // callback was still pending.
            return
        }
        // Merely discovering acab0104 is not enough. OTA waits exclusively for notifications on
        // that characteristic, so capability becomes true only after its CCCD succeeds below.
        otaCapable = false
        connectionState = .connected
        startLocationIfNeeded()   // now we have a board whose detections need stamping
        startStatusPolling()   // periodic READ fallback for status frames too big for a small MTU notify
        driveModeLinkRestored()   // back from a dropout: cancel the auto-end, resume the live counter
        writeWidgetSummary(force: true)   // home widget goes to "connected"
        resyncListsOnConnect()   // re-state ignore then watch, skipping a list we never emptied
        buzzerReassertAttempts = 0               // fresh link: the first status frame is pre-write, don't count it
        lastPushedEnabled = nil                  // force the next status frame to re-push the columns
        setBuzzerEnabled(alertMode == .buzzer)   // a fresh board boots up buzzing; match the phone's mode
        lastGpsSent = .distantPast; sendPhoneLocation()   // push our location to the freshly-connected board
        // Background: keep the "latest"/OTA gate current. Hop to the main actor explicitly
        // (the store is @MainActor); CB callbacks already run on main, so this is immediate.
        Task { @MainActor in FirmwareManifestStore.shared.refreshIfNeeded() }
        otaHandleReconnected()   // if we just came back from an OTA reboot, confirm or report rollback
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        // CoreBluetooth may deliver a CCCD completion after the old link has already torn down.
        // No callback from a retired peripheral may mark its replacement ready, expose OTA, or
        // send a buffer handshake through the manager's current characteristic.
        guard self.peripheral === peripheral else { return }
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
                disconnect()
            } else if characteristic.uuid == ACABProfile.ota {
                // OTA is optional. A refused OTA CCCD must hide only the updater, not tear down a
                // working detection link or let a transfer arm the board and wait forever.
                otaCapable = false
            }
            return
        }
        if characteristic.uuid == ACABProfile.ota {
            otaCapable = characteristic.isNotifying
            return
        }
        // Once the Detections characteristic is actually subscribed, run the buffer
        // handshake (key, epoch, sync) so the board can replay anything it buffered
        // while we were away. Order matters: this must come AFTER the subscribe.
        guard characteristic.uuid == ACABProfile.detections, characteristic.isNotifying else { return }
        // Subscribe SUCCESS is the moment this session provably reached ready - the analog of
        // Android's finishReady, and the gate the unexpected-drop auto-reconnect checks.
        // (.connected in didDiscoverCharacteristicsFor is too early: it lands before this
        // async CCCD write resolves, so a declined pairing would still count as ready there.)
        sessionWasReady = true
        connectHint = nil   // link is usable; the hint no longer applies
        // The live counter preference defaults on, but the surface starts only after a real board
        // has completed its encrypted Detections subscription. A stored false is an explicit user
        // choice and is never overwritten. If this reconnect happened in the background,
        // scene-phase reconciliation starts the activity when the app next becomes active.
        if DriveModeState.wanted, UIApplication.shared.applicationState == .active {
            startDriveMode()
        }
        sendBufferHandshake()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard self.peripheral === peripheral else { return }
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
        lastFix = locations.last
        if demoMode, demoNeedsRelocate, let c = lastCoord {   // snap the demo hits onto the user once a fix arrives
            demoNeedsRelocate = false
            placeDemoDetections(around: c)
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
        default:
            manager.stopUpdatingLocation()   // revoked mid-session
            manager.allowsBackgroundLocationUpdates = false
        }
    }
}
