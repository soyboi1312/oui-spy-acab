import Foundation
import CoreBluetooth
import CryptoKit

/// UI-facing state of a co-processor (nRF) DFU. Parallel to OTAState but a separate flow: the S3
/// stays connected the whole time, only the nRF reboots into its bootloader and is flashed over a
/// second, throwaway BLE link (NrfDfuFlasher).
enum NrfDfuState: Equatable {
    case idle
    case preparing              // downloading + verifying the package
    case triggering             // told the S3 to relay DFU; waiting for the nRF to enter it
    case flashing(pct: Int)     // Nordic DFU is streaming to AdaDFU
    case confirming             // nRF rebooted; waiting for the S3 to report the new version
    case done
    case failed(reason: String)

    var isRunning: Bool {
        switch self {
        case .idle, .done, .failed: return false
        default: return true
        }
    }

    var isCancellable: Bool {
        switch self {
        case .preparing, .triggering, .flashing: return true
        case .idle, .confirming, .done, .failed: return false
        }
    }
}

extension BLEManager {
    var nrfUpdateCanCancel: Bool {
        nrfDfuState.isCancellable && (nrfFlasher?.canCancelSafely ?? true)
    }

    /// Whether a co-processor update is available: the board reports its running nRF version,
    /// the manifest carries a NEWER, verifiable nRF package, and we're linked to a board that
    /// actually has a co-processor. Nil `nrfVersion` (single-radio boards) => never.
    func nrfUpdateAvailable(_ entry: FirmwareManifest.Build) -> Bool {
        guard let status, status.protoVersion == DeviceStatus.supportedProtoVersion,
              let running = status.nrfVersion, let nrf = entry.nrf,
              nrf.ota, entry.hasVerifiableNrfImage else { return false }
        return nrf.version > running
    }

    /// Kick off a co-processor DFU for the given manifest build. Download + verify the package,
    /// trigger the nRF into its bootloader, then flash it over BLE and confirm the new version.
    func startNrfUpdate(entry: FirmwareManifest.Build) {
        guard case .idle = nrfDfuState else { return }          // one at a time
        guard !otaState.isRunning else {                         // never overlap an S3 OTA
            nrfDfuState = .failed(reason: "Finish the board update first, then update the co-processor.")
            return
        }
        if status?.needsNewerApp == true {
            nrfDfuState = .failed(reason: "Install the latest companion app before updating this board.")
            return
        }
        guard status?.protoVersion == DeviceStatus.supportedProtoVersion else {
            nrfDfuState = .failed(reason: "Update the board firmware first. Then power-cycle the beacon, reconnect, and retry the co-processor update within two minutes.")
            return
        }
        // https only, same gate as the S3 OTA path and Android's coordinator: this is the one
        // image whose ONLY signature check is the app (the nRF bootloader flashes whatever it
        // is handed), so a manifest edit must not be able to point it at http or file:.
        guard let nrf = entry.nrf, nrf.ota, entry.hasVerifiableNrfImage,
              (1...(4 * 1024 * 1024)).contains(nrf.size),
              let url = URL(string: nrf.url), FirmwareDownloadPolicy.permits(url) else {
            nrfDfuState = .failed(reason: "No verified co-processor update is published for this board yet.")
            return
        }
        guard let ownerID = currentConfigPeripheralID else {
            nrfDfuState = .failed(reason: "The board isn't connected. Reconnect and try again.")
            return
        }
        guard nrfQuarantinedPeripheralID != ownerID else {
            nrfDfuState = .failed(reason: "Reconnect to the board before starting another co-processor update. This clears any delayed reply from the previous attempt.")
            return
        }
        nrfDfuGeneration &+= 1
        let generation = nrfDfuGeneration
        nrfOwnerPeripheralID = ownerID
        nrfConfirmTarget = nrf.version
        nrfDfuState = .preparing

        nrfDownloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let zip = try await self.downloadNrfZip(url: url, expectedSize: nrf.size,
                                                        expectedSha: nrf.sha256.lowercased(),
                                                        sigHexDER: (nrf.sig ?? "").lowercased(),
                                                        expectedVersion: nrf.version)
                if Task.isCancelled { return }
                // Stage to a temp file; DFUFirmware reads the zip from disk.
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("beacon-nrf-dfu-\(nrf.version)-\(UUID().uuidString).zip")
                try zip.write(to: tmp, options: .atomic)
                await MainActor.run {
                    guard self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID,
                          self.currentConfigPeripheralID == ownerID else {
                        try? FileManager.default.removeItem(at: tmp)
                        return
                    }
                    self.nrfDownloadTask = nil
                    self.nrfPackageURL = tmp
                    self.beginNrfFlash(zipURL: tmp, ownerID: ownerID,
                                       generation: generation)
                }
            } catch is CancellationError {
                return
            } catch let e as NrfPrepError {
                await MainActor.run {
                    guard self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID else { return }
                    self.nrfDownloadTask = nil
                    self.nrfOwnerPeripheralID = nil
                    self.nrfDfuState = .failed(reason: e.message)
                }
            } catch {
                await MainActor.run {
                    guard self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID else { return }
                    self.nrfDownloadTask = nil
                    self.nrfOwnerPeripheralID = nil
                    self.nrfDfuState = .failed(reason: "Couldn't download the co-processor update. Check your connection and try again.")
                }
            }
        }
    }

    /// User-cancel. Stops the download or aborts the transfer, whichever is live.
    func cancelNrfUpdate() {
        guard nrfUpdateCanCancel else { return }
        nrfCancelForLinkTeardown(reason: "Co-processor update cancelled.")
    }

    /// Clear a finished flow back to idle (dismiss the sheet).
    func dismissNrfUpdate() {
        guard !nrfDfuState.isRunning else { return }
        nrfDfuState = .idle
        nrfConfirmTarget = nil
        nrfCleanup()
    }

    // MARK: - steps

    private struct NrfPrepError: Error { let message: String }

    private func downloadNrfZip(url: URL, expectedSize: Int, expectedSha: String,
                                sigHexDER: String, expectedVersion: Int) async throws -> Data {
        // Cap both the allocation and accepted body before trusting manifest-controlled size.
        guard (1...(4 * 1024 * 1024)).contains(expectedSize) else {
            throw NrfPrepError(message: "The co-processor update was the wrong size, so it wasn't installed.")
        }
        let cap = expectedSize
        var req = URLRequest(url: url)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let session = FirmwareDownloadPolicy.makeSession()
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: req)
        guard let http = response as? HTTPURLResponse,
              FirmwareDownloadPolicy.permits(http.url), http.statusCode == 200 else {
            throw NrfPrepError(message: "Couldn't download the co-processor update. Check your connection and try again.")
        }
        var data = Data(); data.reserveCapacity(cap)
        for try await b in bytes {
            data.append(b)
            if data.count > cap {
                throw NrfPrepError(message: "The co-processor update was the wrong size, so it wasn't installed.")
            }
        }
        guard data.count == expectedSize else {
            throw NrfPrepError(message: "The co-processor update was the wrong size, so it wasn't installed.")
        }
        let sha = SHA256Hex(data)
        guard sha == expectedSha else {
            throw NrfPrepError(message: "The co-processor update failed its integrity check, so it wasn't installed.")
        }
        // App-side signature gate. Unlike the S3, the nRF bootloader can't verify our signature,
        // so this IS the gate: refuse to hand an unsigned/tampered package to a bootloader that
        // would flash it blindly.
        guard NrfDfuSignature.isValid(zip: data, sigHexDER: sigHexDER) else {
            throw NrfPrepError(message: "The co-processor update couldn't be verified as signed by the beacon maker, so it wasn't installed.")
        }
        guard let expectedWireVersion = UInt32(exactly: expectedVersion),
              NrfDfuPackage.applicationVersion(in: data) == expectedWireVersion else {
            throw NrfPrepError(message: "The signed co-processor package did not match the version advertised for it, so it wasn't installed.")
        }
        return data
    }

    private func beginNrfFlash(zipURL: URL, ownerID: UUID, generation: UInt64) {
        // A cancel can land after the download task's last isCancelled check; without this guard
        // it would clobber the .failed state, send the trigger, and flash a cancelled update.
        guard case .preparing = nrfDfuState,
              nrfDfuGeneration == generation,
              nrfOwnerPeripheralID == ownerID,
              currentConfigPeripheralID == ownerID else {
            nrfDfuState = .failed(reason: "The board changed before the co-processor update could start.")
            nrfCleanup()
            return
        }
        // First prove that no nearby legacy bootloader is already advertising. Since AdaDFU has no
        // authenticated identity, a pre-existing candidate cannot be distinguished safely after
        // this beacon enters DFU and must block the operation before the trigger is sent.
        let baseline = NrfDfuBaselineScanner { [weak self] result in
            Task { @MainActor in
                guard let self, self.nrfDfuGeneration == generation,
                      self.nrfOwnerPeripheralID == ownerID,
                      self.currentConfigPeripheralID == ownerID,
                      case .preparing = self.nrfDfuState else { return }
                self.nrfBaselineScanner = nil
                switch result {
                case .success(let existing) where existing.isEmpty:
                    self.triggerNrfFlash(zipURL: zipURL, ownerID: ownerID,
                                         generation: generation)
                case .success:
                    self.nrfDfuState = .failed(reason: "Another nearby device is already in co-processor update mode. Power it off, keep this beacon next to the phone, and retry.")
                    self.nrfCleanup()
                case .failure:
                    self.nrfDfuState = .failed(reason: "Bluetooth could not verify a safe co-processor update target. Check Bluetooth and try again.")
                    self.nrfCleanup()
                }
            }
        }
        nrfBaselineScanner = baseline
        baseline.start()
    }

    private func triggerNrfFlash(zipURL: URL, ownerID: UUID, generation: UInt64) {
        guard nrfDfuGeneration == generation,
              nrfOwnerPeripheralID == ownerID,
              currentConfigPeripheralID == ownerID,
              case .preparing = nrfDfuState else { return }
        // Tell the S3 to put the nRF into DFU, then flash. Protocol v2 explicitly accepts or
        // denies this request because current firmware requires a recent physical start. Do not
        // scan until status proves this exact board actually forwarded the handoff.
        nrfDfuState = .triggering
        nrfQuarantinedPeripheralID = ownerID
        nrfSendDfuTrigger()
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.nrfDfuGeneration == generation,
                  self.nrfOwnerPeripheralID == ownerID,
                  self.nrfFlasher == nil,
                  case .triggering = self.nrfDfuState else { return }
            self.nrfDfuState = .failed(reason: "The beacon did not acknowledge co-processor update mode. Power-cycle it, reconnect, and retry within two minutes.")
            self.nrfCleanup()
        }
    }

    /// Protocol-v2 reply from the board's OTA notification channel. An accepted trigger is the
    /// temporal association between this encrypted S3 session and the bootloader that appears
    /// next; a denial is the intended physical-start safety gate, not a scan timeout.
    func nrfHandleArmReply(allowed: Bool) {
        guard case .triggering = nrfDfuState,
              let ownerID = nrfOwnerPeripheralID,
              currentConfigPeripheralID == ownerID,
              nrfPackageURL != nil else { return }
        guard allowed else {
            nrfDfuState = .failed(reason: "For safety, co-processor updates require a recent physical start. Power-cycle the beacon, reconnect, and retry within two minutes.")
            nrfCleanup()
            return
        }
        // Acceptance is still before the loop-task drain rechecks the secure link/window. Wait for
        // status.nrfup, which is set only by the actual nrfEnterDfu handoff, before scanning.
        otaRereadStatus()
    }

    /// Status-side proof that the initiating S3 actually forwarded the DFU command. This is also
    /// the fallback when the optional OTA acknowledgement notification is slow or lost.
    func nrfHandleStatusUpdate(_ status: DeviceStatus) {
        guard status.protoVersion == DeviceStatus.supportedProtoVersion,
              status.nrfUpdating == true,
              case .triggering = nrfDfuState,
              let ownerID = nrfOwnerPeripheralID,
              currentConfigPeripheralID == ownerID,
              let zipURL = nrfPackageURL else { return }
        startNrfFlasher(zipURL: zipURL, ownerID: ownerID, generation: nrfDfuGeneration)
    }

    private func startNrfFlasher(zipURL: URL, ownerID: UUID, generation: UInt64) {
        guard nrfDfuGeneration == generation,
              nrfOwnerPeripheralID == ownerID,
              currentConfigPeripheralID == ownerID,
              nrfFlasher == nil,
              case .triggering = nrfDfuState else { return }

        let flasher = NrfDfuFlasher(
            zipURL: zipURL,
            onProgress: { [weak self] pct in
                Task { @MainActor in
                    guard let self, self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID else { return }
                    switch self.nrfDfuState {
                    case .triggering, .flashing: break
                    case .idle, .preparing, .confirming, .done, .failed: return
                    }
                    self.nrfDfuState = .flashing(pct: pct)
                }
            },
            onFinalizing: { [weak self] in
                Task { @MainActor in
                    guard let self, self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID else { return }
                    switch self.nrfDfuState {
                    case .triggering, .flashing:
                        self.nrfDfuState = .confirming
                    case .idle, .preparing, .confirming, .done, .failed:
                        break
                    }
                }
            },
            onLog: { print("[nrfdfu] \($0)") },
            onFinish: { [weak self] result in
                Task { @MainActor in
                    guard let self, self.nrfDfuGeneration == generation,
                          self.nrfOwnerPeripheralID == ownerID else { return }
                    switch result {
                    case .success:
                        self.nrfDfuState = .confirming
                        self.startNrfConfirm(generation: generation)
                    case .failure(let e):
                        self.nrfDfuState = .failed(reason: (e as? LocalizedError)?.errorDescription
                                                   ?? "The co-processor update failed. Reconnect and try again.")
                        self.nrfCleanup()
                    }
                }
            })
        nrfFlasher = flasher
        flasher.start()
    }

    /// After the flash, the nRF reboots into the new app and reports its version to the S3 over
    /// UART; the S3 emits it as `nrfv`. We're still connected to the S3, so just watch status for
    /// the target version. A successful Nordic transfer proves only that a nearby legacy
    /// bootloader accepted the package; this S3 reporting the target version is what associates
    /// that transfer with this beacon. Never turn a missing report into success.
    private func startNrfConfirm(generation: UInt64) {
        let target = nrfConfirmTarget ?? 0
        let deadline = Date().addingTimeInterval(60)
        func tick() {
            guard nrfDfuGeneration == generation,
                  case .confirming = nrfDfuState else { return }
            if let ownerID = nrfOwnerPeripheralID,
               currentConfigPeripheralID == ownerID {
                otaRereadStatus()
                if let v = status?.nrfVersion, v >= target {
                    nrfDfuState = .done
                    nrfCleanup()
                    combinedHandleSubengineTerminal()
                    return
                }
            }
            if Date() >= deadline {
                nrfDfuState = .failed(reason: "The transfer finished, but this beacon did not report the new co-processor version. It was not confirmed; reconnect and try again.")
                nrfCleanup(); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { tick() }
        }
        tick()
    }

    private func nrfCleanup() {
        nrfBaselineScanner?.cancel()
        nrfBaselineScanner = nil
        if let url = nrfPackageURL { try? FileManager.default.removeItem(at: url) }
        nrfPackageURL = nil
        nrfFlasher = nil
        nrfDownloadTask = nil
        nrfOwnerPeripheralID = nil
    }

    /// Cancel every asynchronous nRF owner when its initiating S3 link becomes terminal.
    func nrfCancelForLinkTeardown(reason: String, settleAsIdle: Bool = false) {
        let wasRunning = nrfDfuState.isRunning || nrfDownloadTask != nil
            || nrfBaselineScanner != nil || nrfFlasher != nil
        if let flasher = nrfFlasher, !flasher.canCancelSafely, nrfDfuState.isRunning {
            // The image is already validating or committed on the independent Nordic link. Keep
            // the exact flasher/generation/package owner until its terminal callback, then verify
            // only from a fresh status on the same S3 owner after reconnect.
            nrfDfuState = .confirming
            return
        }
        nrfDfuGeneration &+= 1
        nrfDownloadTask?.cancel()
        nrfDownloadTask = nil
        nrfFlasher?.cancel()
        nrfFlasher = nil
        nrfConfirmTarget = nil
        nrfCleanup()
        if wasRunning {
            nrfDfuState = settleAsIdle ? .idle : .failed(reason: reason)
        }
    }
}

/// Lowercase hex SHA-256, local so this flow doesn't depend on the OTA extension's private helper.
private func SHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
