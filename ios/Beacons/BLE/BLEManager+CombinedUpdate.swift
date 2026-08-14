import Foundation

// MARK: - One-click combined update
//
// A single "Update" button that brings a beacon fully current in one determinate flow:
// the nRF co-processor first while its physical authorization is live, then the S3 application
// firmware. This file COMPOSES those two proven engines; it does
// not re-implement any transfer. It only sequences them, maps their two progress streams
// onto one 0...1 bar, and self-heals the awkward seam where the S3 reboot reset-pulses the
// nRF (so its reported version briefly disappears).
//
// The @Published state + a little bookkeeping live as stored properties on BLEManager
// (extensions can't add stored properties); the phase enum and all orchestration live here.

/// The combined flow as the Device screen sees it. One value at a time on
/// `BLEManager.combinedState`, alongside `combinedProgress` / `combinedPhaseLabel` /
/// `combinedElapsed` / `combinedNotice`.
enum CombinedUpdatePhase: Equatable {
    case idle
    case checking          // deciding which legs to run
    case updatingS3        // S3 application firmware transfer is streaming
    case reconnecting      // board is rebooting after S3, and/or we're waiting for the nRF
                           // version to repopulate before deciding the co-processor leg
    case updatingCoproc    // nRF DFU is streaming
    case verifying         // nRF flashed; confirming the new version
    case done              // everything current
    case failed(reason: String)   // the flow stopped; reason is user-facing
    case partial           // S3 took but the co-processor leg didn't finish (re-offer the nRF leg)

    /// True while the flow is actively working (drives banner suppression + the progress UI).
    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed, .partial: return false
        default:                              return true
        }
    }
}

/// Context + bookkeeping for one running combined flow. Held on `BLEManager.combinedCtx`
/// while active, cleared at a terminal state. A class so the timer callback mutates one shared
/// instance (mirrors how OTASession is used by the OTA engine).
final class CombinedUpdateContext {
    let entry: FirmwareManifest.Build
    let fwLabel: String
    let latest: String
    let startedAt = Date()

    // What we planned to run at the start. Decides how the 0...1 bar is split so a single
    // stale leg spans the full range. When both are stale, nRF runs first while the physical-start
    // authorization is live, then S3 spans the remaining range.
    let s3Planned: Bool
    let nrfPlanned: Bool
    let s3Base: Double, s3Span: Double
    let nrfBase: Double, nrfSpan: Double

    // Progress of the S3 leg.
    var s3Finished = false          // S3 reached .done (or was never planned)
    var s3DidUpdate = false         // S3 actually flashed something (for honest messaging)
    var s3DoneAt: Date?             // when S3 hit .done, to time the nrfv-repopulate wait
    var reconnectStartedAt: Date?   // start of the reboot/reconnect creep window

    // Progress of the nRF leg.
    var nrfIndeterminateStartedAt: Date?   // trigger/scan creep timing (indeterminate)
    var verifyStartedAt: Date?             // confirm creep timing (indeterminate)
    var nrfFinished = false                // durable across dismissNrfUpdate before the S3 leg

    init(entry: FirmwareManifest.Build, fwLabel: String, latest: String,
         s3Planned: Bool, nrfPlanned: Bool) {
        self.entry = entry
        self.fwLabel = fwLabel
        self.latest = latest
        self.s3Planned = s3Planned
        self.nrfPlanned = nrfPlanned
        if s3Planned && nrfPlanned {
            nrfBase = 0;   nrfSpan = 0.40         // nRF = 0-40%
            s3Base = 0.40; s3Span = 0.60          // S3 = 40-100%
        } else if s3Planned {
            s3Base = 0;   s3Span = 1.0            // S3 spans the whole bar
            nrfBase = 1.0; nrfSpan = 0
        } else {
            s3Base = 0;   s3Span = 0
            nrfBase = 0;  nrfSpan = 1.0           // nRF spans the whole bar
        }
    }
}

extension BLEManager {

    // Timing for the indeterminate creeps and the post-S3 version-repopulate wait.
    private static let combinedReconnectCreep: TimeInterval = 45   // S3 reboot/reconnect band
    private static let combinedTriggerCreep: TimeInterval = 12     // nRF trigger/scan band
    private static let combinedConfirmCreep: TimeInterval = 30     // nRF confirm band
    private static let combinedNrfvWait: TimeInterval = 15         // wait for nrfv to come back

    // MARK: Staleness (the single button's offer condition)

    /// The S3 application firmware is behind AND self-updatable. Keeps BOTH comparators the
    /// per-leg UI used: the version compare (`updateAvailable`) and the OTA eligibility gate
    /// (`ota` + verifiable image + the board actually exposing the OTA characteristic).
    func s3UpdateStale(entry: FirmwareManifest.Build, fwLabel: String, latest: String) -> Bool {
        guard let status, !status.needsNewerApp,
              status.firmwareLabel == fwLabel,
              entry.ota, entry.hasVerifiableImage, otaCapable else { return false }
        return status.updateAvailable(latest: latest)
    }

    /// Either radio is behind: the OR of the two existing checks. Drives whether the single
    /// "Update" button is offered at all.
    func combinedUpdateStale(entry: FirmwareManifest.Build, fwLabel: String,
                             latest: String) -> Bool {
        s3UpdateStale(entry: entry, fwLabel: fwLabel, latest: latest)
            || nrfUpdateAvailable(entry)
    }

    // MARK: Entry points

    private var combinedCompletedAwaitingStatus: Bool {
        guard let ctx = combinedCtx, ctx.s3Finished, ctx.nrfFinished,
              ctx.s3Planned, ctx.nrfPlanned, case .done = otaState,
              case .reconnecting = combinedState else { return false }
        return true
    }

    /// The S3 can be cancelled only before it commits and reboots. Once it reaches the reboot or
    /// confirmation phase, stopping only this coordinator would lie to the user while the board
    /// update continued in the background and would also abandon the planned second-radio leg.
    var combinedCanCancel: Bool {
        guard combinedState.isRunning else { return false }
        if combinedCompletedAwaitingStatus { return false }
        if otaState.isRunning { return firmwareUpdateCanCancel }
        if nrfDfuState.isRunning { return nrfUpdateCanCancel }
        return true
    }

    /// Start the one-click flow. Non-throwing: any real failure lands in `combinedState`.
    func startCombinedUpdate(entry: FirmwareManifest.Build, fwLabel: String, latest: String) {
        guard !combinedState.isRunning else { return }
        // Never collide with a directly-driven engine (there is no per-leg button anymore, but
        // an in-flight sub-engine from a prior path would be clobbered).
        guard !otaState.isRunning, !nrfDfuState.isRunning else { return }

        let s3 = s3UpdateStale(entry: entry, fwLabel: fwLabel, latest: latest)
        let nrf = nrfUpdateAvailable(entry)
        guard s3 || nrf else { return }   // button wouldn't be shown; defense in depth

        // Clear any lingering terminal sub-state so the engines are idle before we drive them.
        dismissFirmwareUpdate()
        dismissNrfUpdate()

        let ctx = CombinedUpdateContext(entry: entry, fwLabel: fwLabel, latest: latest,
                                        s3Planned: s3, nrfPlanned: nrf)
        combinedCtx = ctx
        combinedNotice = nil
        combinedProgress = 0
        combinedElapsed = 0
        combinedState = .checking
        combinedPhaseLabel = "Checking for updates"
        combinedStartTimer()
        combinedBeginFirstLeg(ctx)
    }

    /// User asked to stop a running flow. Best-effort: stops the timer and the live sub-engine.
    func combinedCancel() {
        guard combinedState.isRunning, combinedCanCancel else { return }
        combinedStopTimer()
        if firmwareUpdateCanCancel { cancelFirmwareUpdate() }
        if nrfDfuState.isRunning, nrfUpdateCanCancel { cancelNrfUpdate() }
        combinedCtx = nil
        combinedPhaseLabel = "Update cancelled"
        combinedState = .failed(reason: "Update cancelled.")
    }

    /// Settle only the combined coordinator when its initiating board link is terminal. The caller
    /// separately cancels the two transfer engines so this method never re-enters their callbacks.
    func combinedCancelForLinkTeardown(reason: String, settleAsIdle: Bool = false) {
        if combinedCompletedAwaitingStatus {
            combinedNotice = "Both updates completed. Reconnect to refresh the co-processor status."
            combinedFinish(.done)
            return
        }
        let wasRunning = combinedState.isRunning || combinedCtx != nil || combinedTimer != nil
        combinedStopTimer()
        combinedCtx = nil
        guard wasRunning else { return }
        combinedNotice = nil
        if settleAsIdle {
            combinedProgress = 0
            combinedElapsed = 0
            combinedPhaseLabel = ""
            combinedState = .idle
        } else {
            combinedPhaseLabel = "Update stopped"
            combinedState = .failed(reason: reason)
        }
    }

    /// Consume a transfer engine's terminal in the same MainActor turn that publishes it. The
    /// timer remains useful for progress, but a completed single-leg update must not have a window
    /// where Disconnect or Cancel can overwrite success before the next 0.4 second tick.
    func combinedHandleSubengineTerminal() {
        guard let ctx = combinedCtx, combinedState.isRunning else { return }
        if case .done = nrfDfuState {
            combinedDriveNrf(ctx)
            return
        }
        guard case .done = otaState else { return }
        if !ctx.s3Finished {
            ctx.s3Finished = true
            ctx.s3DidUpdate = true
            ctx.s3DoneAt = Date()
            ctx.reconnectStartedAt = ctx.reconnectStartedAt ?? Date()
            otaRereadStatus()
        }
        if !ctx.nrfPlanned {
            combinedFinish(.done)
        } else {
            // Both-radio flow already completed and confirmed the nRF leg before S3. Keep the
            // existing fresh-status seam so a missing nrfv is reported honestly, but Cancel is no
            // longer exposed because both transfer engines are terminal.
            combinedState = .reconnecting
            combinedSetProgress(ctx.s3Base + ctx.s3Span * 0.95)
        }
    }

    /// Clear a terminal state back to rest.
    func dismissCombinedUpdate() {
        guard !combinedState.isRunning else { return }
        combinedStopTimer()
        dismissFirmwareUpdate()
        dismissNrfUpdate()
        combinedCtx = nil
        combinedNotice = nil
        combinedProgress = 0
        combinedElapsed = 0
        combinedPhaseLabel = ""
        combinedState = .idle
    }

    // MARK: Timer / tick

    func combinedStartTimer() {
        combinedStopTimer()
        combinedTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.combinedTick()
        }
    }

    func combinedStopTimer() {
        combinedTimer?.invalidate()
        combinedTimer = nil
    }

    private func combinedTick() {
        guard let ctx = combinedCtx else { combinedStopTimer(); return }
        combinedElapsed = Date().timeIntervalSince(ctx.startedAt)   // wall clock

        switch combinedState {
        case .updatingS3:
            combinedDriveS3(ctx)
        case .reconnecting:
            combinedDriveReconnect(ctx)
        case .updatingCoproc, .verifying:
            combinedDriveNrf(ctx)
        case .checking:
            break   // start() advances immediately; nothing to poll
        case .idle, .done, .failed, .partial:
            combinedStopTimer()
            return
        }
        // Keep the plain-language label live for whatever running phase we're in.
        if combinedState.isRunning { combinedPhaseLabel = combinedLabel(ctx) }
    }

    // MARK: Leg 1 - S3 application firmware

    private func combinedBeginFirstLeg(_ ctx: CombinedUpdateContext) {
        if ctx.s3Planned && ctx.nrfPlanned {
            combinedBeginNrfLeg(ctx)
        } else if ctx.s3Planned {
            combinedState = .updatingS3
            startFirmwareUpdate(entry: ctx.entry, fwLabel: ctx.fwLabel)
        } else {
            // No S3 work. Go straight to the co-processor decision on a fresh status read.
            ctx.s3Finished = true
            ctx.reconnectStartedAt = Date()
            otaRereadStatus()
            combinedState = .reconnecting
        }
    }

    private func combinedDriveS3(_ ctx: CombinedUpdateContext) {
        switch otaState {
        case .failed(let reason):
            // S3 failed: abort the whole flow, never touch the nRF.
            combinedFail(reason)
        case .done:
            // Engine handled reboot + reconnect + confirm internally.
            ctx.s3Finished = true
            ctx.s3DidUpdate = true
            ctx.s3DoneAt = Date()
            ctx.reconnectStartedAt = ctx.reconnectStartedAt ?? Date()
            otaRereadStatus()
            combinedState = .reconnecting
            combinedSetProgress(ctx.s3Base + ctx.s3Span * 0.95)
        case .rebooting, .confirming:
            // The engine is rebooting/reconnecting the board. Enter our reconnect band.
            ctx.reconnectStartedAt = ctx.reconnectStartedAt ?? Date()
            combinedState = .reconnecting
        default:
            // checking / downloading / verifying / sending -> real-pct portion of the S3 band.
            combinedSetProgress(ctx.s3Base + ctx.s3Span * combinedS3RealSub())
        }
    }

    /// Sub-progress 0...0.75 across the S3 transfer's real-percentage phases (the top 0.75...1.0
    /// of the S3 band is the indeterminate reboot creep, handled in the reconnect driver).
    private func combinedS3RealSub() -> Double {
        switch otaState {
        case .checking:            return 0.03
        case .downloading(let p):  return 0.03 + 0.13 * Double(min(100, max(0, p))) / 100
        case .verifying:           return 0.18
        case .sending(let p):      return 0.18 + 0.57 * Double(min(100, max(0, p))) / 100
        default:                   return 0.03
        }
    }

    // MARK: Seam - reboot / reconnect / wait for nrfv

    private func combinedDriveReconnect(_ ctx: CombinedUpdateContext) {
        // Indeterminate creep across the top of the S3 band, never quite reaching the top until
        // a real transition fires.
        let base = ctx.s3Base + ctx.s3Span * 0.75
        let top  = ctx.s3Base + ctx.s3Span
        let started = ctx.reconnectStartedAt ?? ctx.startedAt
        let t = min(1.0, Date().timeIntervalSince(started) / Self.combinedReconnectCreep)
        combinedSetProgress(base + (top - base) * t * 0.9)

        if !ctx.s3Finished {
            // The S3 engine is still finishing its own reboot/confirm. Watch for its terminal.
            switch otaState {
            case .done:
                ctx.s3Finished = true
                ctx.s3DidUpdate = true
                ctx.s3DoneAt = Date()
                otaRereadStatus()
            case .failed(let r):
                combinedFail(r)
            default:
                break
            }
            return
        }

        // S3 finished (or was skipped). If there is no planned co-processor leg, we're done as
        // soon as the S3 reboot settled - don't stall on a nrfv that a single-radio board never
        // reports.
        if !ctx.nrfPlanned {
            // Keep the plan frozen. In particular, a legacy proto<2 board can become proto2
            // after this S3 leg, but the warm OTA reboot deliberately did not reopen the
            // physical-start window required to arm legacy nRF DFU. The user must power-cycle,
            // reconnect, and start a separate nRF run from a freshly authorized session.
            combinedFinish(.done)
            return
        }

        // The S3 reboot reset-pulsed the nRF, so `nrfv` is briefly absent. Wait for it to
        // repopulate before re-evaluating the co-processor leg on a fresh Status.
        let doneAt = ctx.s3DoneAt ?? started
        if status?.nrfVersion != nil || Date().timeIntervalSince(doneAt) > Self.combinedNrfvWait {
            combinedDecideNrfLeg(ctx)
        }
    }

    private func combinedDecideNrfLeg(_ ctx: CombinedUpdateContext) {
        // Re-evaluate on the freshest Status we have.
        if status?.nrfVersion == nil {
            if ctx.nrfPlanned {
                // We meant to update the co-processor but can't read its version right now. Do
                // NOT claim it updated; finish S3-only with a soft notice. The single button
                // self-heals: staleness re-evaluates per Status frame, so it re-offers the
                // nRF-only run once nrfv returns.
                combinedNotice = "Couldn't reach the co-processor to check its version - reconnect and try Update again if its update is available."
                combinedFinish(ctx.s3DidUpdate ? .done : .partial)
            } else {
                // Single-radio board (or no co-processor package): S3-only, cleanly done.
                combinedFinish(.done)
            }
            return
        }
        if nrfUpdateAvailable(ctx.entry) {
            combinedBeginNrfLeg(ctx)
        } else {
            // Co-processor already current (or nothing was planned for it).
            combinedFinish(.done)
        }
    }

    // MARK: Leg 2 - nRF co-processor

    private func combinedBeginNrfLeg(_ ctx: CombinedUpdateContext) {
        ctx.nrfIndeterminateStartedAt = Date()
        combinedState = .updatingCoproc
        combinedSetProgress(ctx.nrfBase)
        startNrfUpdate(entry: ctx.entry)
    }

    private func combinedDriveNrf(_ ctx: CombinedUpdateContext) {
        switch nrfDfuState {
        case .preparing, .triggering:
            combinedState = .updatingCoproc
            let started = ctx.nrfIndeterminateStartedAt ?? Date()
            let t = min(1.0, Date().timeIntervalSince(started) / Self.combinedTriggerCreep)
            combinedSetProgress(ctx.nrfBase + ctx.nrfSpan * (0.25 * t))
        case .flashing(let p):
            combinedState = .updatingCoproc
            let sub = 0.25 + 0.625 * Double(min(100, max(0, p))) / 100
            combinedSetProgress(ctx.nrfBase + ctx.nrfSpan * sub)
        case .confirming:
            // The initiating S3 must report the target version before the nRF engine reaches done.
            if case .verifying = combinedState {} else { ctx.verifyStartedAt = Date() }
            combinedState = .verifying
            let started = ctx.verifyStartedAt ?? Date()
            let t = min(1.0, Date().timeIntervalSince(started) / Self.combinedConfirmCreep)
            combinedSetProgress(ctx.nrfBase + ctx.nrfSpan * (0.875 + 0.125 * t * 0.9))
        case .done:
            ctx.nrfFinished = true
            if ctx.s3Planned && !ctx.s3Finished {
                dismissNrfUpdate()
                combinedState = .updatingS3
                startFirmwareUpdate(entry: ctx.entry, fwLabel: ctx.fwLabel)
            } else {
                combinedFinish(.done)
            }
        case .failed(let reason):
            // A transfer may have landed just after its bounded confirmation timed out. Re-read
            // the live version before retrying so we never put an already-current co-processor
            // back into its unauthenticated legacy bootloader unnecessarily.
            if let target = ctx.entry.nrf?.version,
               let running = status?.nrfVersion, running >= target {
                combinedFinish(.done)
                return
            }
            // The stock legacy DFU bootloader cannot authenticate its own image or expose a
            // cryptographic target identity. Do not automatically re-arm it after a failure. The
            // user can inspect the result, power-cycle deliberately, and retry from a clean link.
            if ctx.s3Planned && !ctx.s3Finished {
                combinedFail(reason)
            } else {
                // S3 already took (or was not needed); the co-processor did not. Surface partial
                // so the same button can re-offer just the nRF leg after a deliberate restart.
                combinedNotice = reason
                combinedFinish(.partial)
            }
        case .idle:
            break   // transient between a retry reset and the next start
        }
    }

    // MARK: Terminals + helpers

    private func combinedFinish(_ phase: CombinedUpdatePhase) {
        // Capture what actually landed BEFORE combinedCtx is torn down at the end of this function;
        // the card reads it to word the terminal copy honestly (see combinedS3Updated).
        combinedS3Updated = combinedCtx?.s3DidUpdate ?? false
        switch phase {
        case .done:
            combinedProgress = 1.0
            combinedPhaseLabel = "Update complete"
            combinedState = .done
        case .partial:
            // Leave the bar where it is (S3 region); the co-processor leg didn't complete.
            combinedPhaseLabel = "Partly updated"
            combinedState = .partial
        default:
            return
        }
        combinedStopTimer()
        combinedCtx = nil
    }

    private func combinedFail(_ reason: String) {
        combinedStopTimer()
        combinedCtx = nil
        combinedPhaseLabel = "Update failed"
        combinedState = .failed(reason: reason)
    }

    /// Monotonic, clamped progress setter (never goes backward within a run).
    private func combinedSetProgress(_ p: Double) {
        combinedProgress = min(1.0, max(combinedProgress, p))
    }

    private func combinedLabel(_ ctx: CombinedUpdateContext) -> String {
        switch combinedState {
        case .checking:
            return "Checking for updates"
        case .updatingS3:
            switch otaState {
            case .downloading: return "Downloading firmware"
            case .verifying:   return "Verifying download"
            default:           return "Updating board firmware"
            }
        case .reconnecting:
            return ctx.s3Finished ? "Reconnecting to the board" : "Board is restarting"
        case .updatingCoproc:
            return "Updating the second radio"
        case .verifying:
            return "Finishing up"
        case .idle, .done, .failed, .partial:
            return combinedPhaseLabel
        }
    }
}
