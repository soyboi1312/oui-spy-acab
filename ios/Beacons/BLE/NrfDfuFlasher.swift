import Foundation
import CoreBluetooth
import NordicDFU

/// Drives one nRF co-processor DFU over BLE, self-contained on its OWN CBCentralManager so the
/// app's live link to the S3 (BLEManager's central) is never disturbed while this runs.
///
/// The nRF, once the S3 relays the `nrfdfu` trigger, reboots into its Adafruit/Seeed bootloader
/// and advertises as "AdaDFU" with the legacy DFU service (0x1530). This class scans for that,
/// then hands the target to Nordic's DFUServiceInitiator, which speaks the legacy DFU protocol
/// end to end. The initiator deliberately uses the SAME central that discovered the peripheral,
/// so the START-stall watchdog can forcibly cancel the exact connection Nordic is using. The
/// NordicDFU 4.x compatibility call that preserves that ownership lives in one isolated file.
final class NrfDfuFlasher: NSObject {
    /// Legacy Nordic DFU service, as advertised by the Adafruit/Seeed bootloader in OTA mode.
    static let dfuServiceUUID = CBUUID(string: "00001530-1212-EFDE-1523-785FEABCD123")

    private let zipURL: URL
    private let onProgress: (Int) -> Void
    private let onFinalizing: () -> Void
    private let onLog: (String) -> Void
    private let onFinish: (Result<Void, Error>) -> Void

    private var scanCentral: CBCentralManager?
    private var dfuPeripheral: CBPeripheral?     // the discovered AdaDFU target, bound to scanCentral
    private var controller: DFUServiceController?
    private var scanTimeout: DispatchWorkItem?
    private var finished = false
    /// False once Nordic begins validating the transferred image. Past this boundary an abort can
    /// no longer be represented honestly as preventing installation.
    private(set) var canCancelSafely = true
    private var announcedFinalizing = false

    // START-phase stall recovery. Two field-confirmed failure modes stall the legacy START
    // handshake indefinitely (the library waits forever by design): (1) CoreBluetooth silently
    // drops the image-size write-without-response under radio congestion (IOS-DFU-Library #505),
    // and (2) the Adafruit bootloader wedges in its erase-before-response window. Watchdog the
    // phase between start() and .uploading and fail it cleanly. A retry creates a new flasher:
    // Nordic callbacks carry no attempt identity, so overlapping controllers are unsafe.
    private var startWatchdog: DispatchWorkItem?
    /// Once upload begins, refresh this on every progress callback. Legacy DFU can otherwise wait
    /// forever for a missing packet-receipt response while the link still appears connected.
    private var uploadWatchdog: DispatchWorkItem?
    private static let uploadStallTimeout: TimeInterval = 45
    /// Legacy DFU has no built-in bound for its validating/activate response. Once validation
    /// begins we cannot honestly abort installation, but we also cannot retain the transport
    /// forever if that final response is lost. After this bound, retire the Nordic link and let
    /// BLEManager verify the result from the initiating S3's reported nRF version.
    private var finalizationWatchdog: DispatchWorkItem?
    private static let finalizationTimeout: TimeInterval = 30
    /// A scan can queue several discoveries before stopScan takes effect. Lock the first accepted
    /// candidate synchronously so only one transfer can ever be scheduled for this flasher.
    private var targetLocked = false
    private struct Candidate {
        let peripheral: CBPeripheral
        var strongestRSSI: Int
    }
    private var candidates: [UUID: Candidate] = [:]
    private var candidateDecision: DispatchWorkItem?
    fileprivate static let closeTargetRSSI = -55
    private static let candidateWindow: TimeInterval = 2

    /// `scanTimeoutSec` bounds how long we wait for AdaDFU to appear after the trigger; if the
    /// nRF never enters DFU (bad GPREGRET, no reboot), we fail rather than hang.
    init(zipURL: URL,
         onProgress: @escaping (Int) -> Void,
         onFinalizing: @escaping () -> Void = {},
         onLog: @escaping (String) -> Void = { _ in },
         onFinish: @escaping (Result<Void, Error>) -> Void) {
        self.zipURL = zipURL
        self.onProgress = onProgress
        self.onFinalizing = onFinalizing
        self.onLog = onLog
        self.onFinish = onFinish
    }

    enum FlashError: LocalizedError {
        case targetNotFound
        case ambiguousTargets
        case badPackage
        case dfu(String)
        var errorDescription: String? {
            switch self {
            case .targetNotFound: return "The co-processor didn't show up in update mode. It usually recovers on its own; reconnect and try again."
            case .ambiguousTargets: return "More than one nearby device is in update mode. Power off the other device, keep this beacon next to the phone, and retry."
            case .badPackage:     return "The co-processor update package was unreadable."
            case .dfu(let m):     return m
            }
        }
    }

    fileprivate static func isDfuAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any]
    ) -> Bool {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let advServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]
        return (peripheral.name?.caseInsensitiveCompare("AdaDFU") == .orderedSame)
            || (advName?.caseInsensitiveCompare("AdaDFU") == .orderedSame)
            || (advServices?.contains(dfuServiceUUID) ?? false)
    }

    /// Begin: scan for AdaDFU, then flash. Safe to call once per instance.
    func start(scanTimeoutSec: TimeInterval = 40) {
        onLog("scanning for the co-processor in update mode (AdaDFU)")
        scanCentral = CBCentralManager(delegate: self, queue: .main)
        let to = DispatchWorkItem { [weak self] in self?.fail(.targetNotFound) }
        scanTimeout = to
        DispatchQueue.main.asyncAfter(deadline: .now() + scanTimeoutSec, execute: to)
    }

    /// Abort an in-flight transfer (user cancel). No-op once finished.
    func cancel() {
        guard !finished, canCancelSafely else { return }
        fail(.dfu("Co-processor update cancelled."))
    }

    // MARK: - internals

    private func beginDfu(peripheral: CBPeripheral) {
        guard !finished, !targetLocked else { return }
        targetLocked = true
        dfuPeripheral = peripheral
        teardownScan()
        // Settle before starting: lets CoreBluetooth's shared outgoing buffer drain (the S3 link
        // is streaming notifications concurrently) so the START-phase write-without-response isn't
        // silently discarded - the documented #505 failure this pause works around.
        onLog("found AdaDFU; settling 3s, then starting transfer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.startTransfer(peripheral: peripheral)
        }
    }

    private func chooseCandidate() {
        candidateDecision = nil
        guard !finished, !targetLocked else { return }
        let ranked = candidates.values.sorted { $0.strongestRSSI > $1.strongestRSSI }
        guard ranked.count == 1, let winner = ranked.first else {
            fail(.ambiguousTargets)
            return
        }
        beginDfu(peripheral: winner.peripheral)
    }

    private func startTransfer(peripheral: CBPeripheral) {
        guard !finished else { return }
        let firmware: DFUFirmware
        do {
            firmware = try DFUFirmware(urlToZipFile: zipURL)
        } catch {
            fail(.badPackage); return
        }
        guard let central0 = scanCentral else { fail(.dfu("Bluetooth became unavailable.")); return }
        let initiator = NrfDfuOwnedCentralCompatibility.initiator(
            centralManager: central0,
            target: peripheral
        )
            .with(firmware: firmware)
        initiator.delegate = self
        initiator.progressDelegate = self
        initiator.logger = self          // route the library's verbose steps to onLog for diagnosis
        // We are already connected to the bootloader (AdaDFU), not the app, so there is no
        // buttonless jump and no address change to chase: flash this target in place.
        initiator.forceScanningForNewAddressInLegacyDfu = false
        initiator.alternativeAdvertisingNameEnabled = false
        // The stock Adafruit bootloader's HCI RX queue is shallow and hard-fails the transfer
        // (Response op=3 status=6 "Operation failed" + disconnect, seen on hardware 2026-07-23)
        // when data packets outrun it. Adafruit's own guidance: OTA needs PRN <= 8. The library
        // default is 12. Use 6 for headroom - each PRN is a flow-control stop that lets the
        // bootloader drain its queue to flash before the next burst.
        initiator.packetReceiptNotificationParameter = 6
        // Arm the stall watchdog: connect + service discovery + START + the bootloader's
        // erase-before-response all fit well inside 25s (the 123KB erase is 3-15s); .uploading
        // disarms it. On expiry the whole attempt fails and releases its controller.
        armStartWatchdog()
        // Start with OUR central + the discovered peripheral (Bluefruit-parity path). Nordic's
        // replacement init(queue:) path owns a private central, and a wedged START leaves a
        // connection nothing can cancel (controller.abort() is a link-layer no-op there, and the
        // retain cycle inside the DFU stack keeps its central alive after controller=nil). Owning
        // the central makes the watchdog disconnect explicit and certain. The current start API
        // still uses the central already installed on this initiator.
        controller = initiator.start(target: peripheral)
    }

    private func armStartWatchdog() {
        startWatchdog?.cancel()
        let wd = DispatchWorkItem { [weak self] in self?.startStalled() }
        startWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: wd)
    }

    private func startStalled() {
        guard !finished else { return }
        // Nordic callbacks carry no controller/attempt identity. Starting a second controller
        // behind the same delegate lets a late callback from the aborted attempt complete or
        // disarm the watchdog for the retry. Fail this attempt completely; a user retry creates a
        // fresh flasher with no overlapping callbacks or connection ownership.
        fail(.dfu("The co-processor didn't acknowledge the update. Reconnect and try again."))
    }

    private func armUploadWatchdog() {
        uploadWatchdog?.cancel()
        let wd = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, self.canCancelSafely else { return }
            self.fail(.dfu("The co-processor stopped responding during the update. Reconnect and try again."))
        }
        uploadWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.uploadStallTimeout, execute: wd)
    }

    private func teardownScan() {
        // Stop scanning + cancel the timeout, but KEEP the central: the DFU transfer runs on it,
        // and the stall recovery needs it to cancel the connection + rescan.
        scanTimeout?.cancel(); scanTimeout = nil
        candidateDecision?.cancel(); candidateDecision = nil
        candidates.removeAll()
        scanCentral?.stopScan()
    }

    private func succeed() {
        guard !finished else { return }
        finished = true
        finishCleanup(abortTransfer: false)
        onFinish(.success(()))
    }

    private func enterFinalizing() {
        canCancelSafely = false
        uploadWatchdog?.cancel(); uploadWatchdog = nil
        guard !announcedFinalizing else { return }
        announcedFinalizing = true
        onFinalizing()
        let wd = DispatchWorkItem { [weak self] in
            guard let self, !self.finished else { return }
            self.onLog("dfu final response timed out; verifying from the initiating beacon")
            self.succeed()
        }
        finalizationWatchdog = wd
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalizationTimeout, execute: wd)
    }

    private func fail(_ e: FlashError) {
        guard !finished else { return }
        finished = true
        finishCleanup(abortTransfer: true)
        onFinish(.failure(e))
    }

    /// Break every CoreBluetooth/Nordic ownership edge at a terminal. In particular, the final
    /// START-watchdog failure used to report failure while leaving the controller and connection
    /// live, allowing a retry to overlap an old transfer whose package file had been removed.
    private func finishCleanup(abortTransfer: Bool) {
        scanTimeout?.cancel(); scanTimeout = nil
        startWatchdog?.cancel(); startWatchdog = nil
        uploadWatchdog?.cancel(); uploadWatchdog = nil
        finalizationWatchdog?.cancel(); finalizationWatchdog = nil
        scanCentral?.stopScan()
        if abortTransfer { _ = controller?.abort() }
        if let central = scanCentral, let peripheral = dfuPeripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        scanCentral?.delegate = nil
        controller = nil
        dfuPeripheral = nil
        scanCentral = nil
        targetLocked = false
    }
}

// MARK: - scanning for AdaDFU

extension NrfDfuFlasher: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn, central === scanCentral else { return }
        // Scan WITHOUT a service filter and match by name below. The Adafruit/Seeed bootloader's
        // DFU service is a 128-bit UUID that iOS scan filters match unreliably (it can ride in the
        // scan response rather than the primary advert), so filtering on it silently drops the
        // target. The name "AdaDFU" is the reliable key.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanCentral != nil, !finished, !targetLocked else { return }
        // Match by name (peripheral.name or the advertised local name), OR by the DFU service if
        // it happens to be in the advertisement. Either identifies our bootloader unambiguously.
        guard Self.isDfuAdvertisement(
            peripheral: peripheral,
            advertisementData: advertisementData
        ) else { return }
        // The protocol-v2 status gate proves the initiating S3 actually forwarded its DFU command.
        // The stock bootloader still exposes no authenticated identity, so require a very-close
        // candidate and collect briefly. More than one close candidate fails closed instead of
        // flashing whichever callback happened to arrive first. 127 = RSSI unavailable.
        let rssi = RSSI.intValue
        guard rssi != 127, rssi > Self.closeTargetRSSI else {
            onLog("ignoring far AdaDFU (rssi \(rssi))")
            return
        }
        let id = peripheral.identifier
        if let prior = candidates[id] {
            candidates[id] = Candidate(peripheral: peripheral,
                                       strongestRSSI: max(prior.strongestRSSI, rssi))
        } else {
            candidates[id] = Candidate(peripheral: peripheral, strongestRSSI: rssi)
        }
        if candidateDecision == nil {
            let work = DispatchWorkItem { [weak self] in self?.chooseCandidate() }
            candidateDecision = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.candidateWindow, execute: work)
        }
    }
}

/// A short scan before the S3 is asked to arm its co-processor. The stock legacy bootloader has no
/// authenticated device identity, so an AdaDFU device already present on the bench must never be
/// eligible for the subsequent scan. Failing before the trigger is safer than discovering the
/// ambiguity after writing firmware to the wrong target.
final class NrfDfuBaselineScanner: NSObject, CBCentralManagerDelegate {
    enum ScanError: Error { case unavailable }

    private var central: CBCentralManager?
    private var startupTimeout: DispatchWorkItem?
    private var scanTimeout: DispatchWorkItem?
    private var nearby = Set<UUID>()
    private var finished = false
    private var scanStarted = false
    private var scanDuration: TimeInterval = 2
    private let onFinish: (Result<Set<UUID>, Error>) -> Void

    init(onFinish: @escaping (Result<Set<UUID>, Error>) -> Void) {
        self.onFinish = onFinish
    }

    func start(duration: TimeInterval = 2) {
        scanDuration = duration
        central = CBCentralManager(delegate: self, queue: .main)
        let startup = DispatchWorkItem { [weak self] in
            self?.finish(.failure(ScanError.unavailable))
        }
        startupTimeout = startup
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: startup)
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        startupTimeout?.cancel(); startupTimeout = nil
        scanTimeout?.cancel(); scanTimeout = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central === self.central, !finished else { return }
        switch central.state {
        case .poweredOn:
            guard !scanStarted else { return }
            scanStarted = true
            startupTimeout?.cancel(); startupTimeout = nil
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
            let scan = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finish(.success(self.nearby))
            }
            scanTimeout = scan
            DispatchQueue.main.asyncAfter(deadline: .now() + scanDuration, execute: scan)
        case .unsupported, .unauthorized, .poweredOff:
            finish(.failure(ScanError.unavailable))
        case .unknown, .resetting:
            break
        @unknown default:
            finish(.failure(ScanError.unavailable))
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard central === self.central, !finished,
              NrfDfuFlasher.isDfuAdvertisement(
                  peripheral: peripheral,
                  advertisementData: advertisementData
              ) else { return }
        let rssi = RSSI.intValue
        if rssi != 127, rssi > NrfDfuFlasher.closeTargetRSSI {
            nearby.insert(peripheral.identifier)
        }
    }

    private func finish(_ result: Result<Set<UUID>, Error>) {
        guard !finished else { return }
        finished = true
        startupTimeout?.cancel(); startupTimeout = nil
        scanTimeout?.cancel(); scanTimeout = nil
        central?.stopScan()
        central?.delegate = nil
        central = nil
        onFinish(result)
    }
}

// MARK: - DFU library callbacks

extension NrfDfuFlasher: DFUServiceDelegate {
    func dfuStateDidChange(to state: DFUState) {
        onLog("dfu: \(state.description)")
        switch state {
        case .uploading:
            // Past the START handshake: the stall window is over, stand the watchdog down.
            startWatchdog?.cancel(); startWatchdog = nil
            armUploadWatchdog()
        case .validating:
            startWatchdog?.cancel(); startWatchdog = nil
            enterFinalizing()
        case .completed:
            enterFinalizing()
            succeed()
        case .aborted:
            if canCancelSafely {
                fail(.dfu("The co-processor update was stopped."))
            } else {
                onLog("dfu stopped after validation began; verifying from the initiating beacon")
                succeed()
            }
        default:
            break
        }
    }

    func dfuError(_ error: DFUError, didOccurWithMessage message: String) {
        if !canCancelSafely {
            onLog("dfu terminal after validation began: \(message); verifying from the initiating beacon")
            succeed()
            return
        }
        // Word-for-word the Android string for the same terminal library error, recovery
        // suffix included: every other user-facing string in this flow is already identical.
        fail(.dfu("The co-processor update failed: \(message). Reconnect and try again."))
    }
}

extension NrfDfuFlasher: DFUProgressDelegate {
    func dfuProgressDidChange(for part: Int, outOf totalParts: Int, to progress: Int,
                              currentSpeedBytesPerSecond: Double, avgSpeedBytesPerSecond: Double) {
        if canCancelSafely { armUploadWatchdog() }
        onProgress(max(0, min(100, progress)))
    }
}

// Verbose DFU-library logging, surfaced through onLog so a stalled transfer shows exactly which
// step (connecting / enabling DFU mode / sending init packet / uploading) it hangs on.
extension NrfDfuFlasher: LoggerDelegate {
    func logWith(_ level: LogLevel, message: String) {
        onLog("[\(level)] \(message)")
    }
}
