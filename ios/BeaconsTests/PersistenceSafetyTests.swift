import XCTest
@testable import Beacons

final class PersistenceSafetyTests: XCTestCase {
    private struct Fixture: Codable, Equatable {
        let mac: String
    }

    private enum WriteFailure: Error { case refused }

    private func isolatedDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "PersistenceSafetyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }

    func testRealClearInvalidatesAlreadyQueuedPersistedLoad() {
        var gate = PersistedDetectionLoadGate()
        let queuedBeforeClear = gate.beginLoad()
        XCTAssertTrue(gate.accepts(queuedBeforeClear))

        gate.invalidate()

        XCTAssertFalse(gate.accepts(queuedBeforeClear),
                       "a decoded batch queued before Clear must not restore deleted evidence")
    }

    func testNewLoadSupersedesLaunchLoadForDemoExit() {
        var gate = PersistedDetectionLoadGate()
        let launchLoad = gate.beginLoad()
        let exitDemoReload = gate.beginLoad()

        XCTAssertFalse(gate.accepts(launchLoad))
        XCTAssertTrue(gate.accepts(exitDemoReload),
                      "exitDemo's fresh reload must remain eligible after its memory-only reset")
    }

    func testPendingClearSurvivesRelaunchAndBlocksLoadUntilDeleteRetrySucceeds() {
        let isolated = isolatedDefaults()
        defer { isolated.defaults.removePersistentDomain(forName: isolated.suite) }
        let firstProcess = PersistedDetectionClearTombstone(defaults: isolated.defaults)
        XCTAssertTrue(firstProcess.arm())

        var fileExists = true
        XCTAssertFalse(performConfirmedPersistedDetectionDeletion(
            fileExists: { fileExists },
            remove: { throw WriteFailure.refused }))
        XCTAssertTrue(firstProcess.isPending)
        XCTAssertFalse(persistedDetectionLoadAllowed(clearPending: firstProcess.isPending),
                       "failed deletion must not let the condemned file reload")

        // New value object over the same suite models a new process reading the durable tombstone.
        let relaunched = PersistedDetectionClearTombstone(defaults: isolated.defaults)
        XCTAssertTrue(relaunched.isPending)
        XCTAssertTrue(performConfirmedPersistedDetectionDeletion(
            fileExists: { fileExists },
            remove: { fileExists = false }))
        XCTAssertTrue(relaunched.retire())
        XCTAssertFalse(PersistedDetectionClearTombstone(defaults: isolated.defaults).isPending)
        XCTAssertTrue(persistedDetectionLoadAllowed(clearPending: relaunched.isPending))
    }

    func testConfirmedDeleteAcceptsAbsenceAndRejectsAFileThatRemains() {
        var fileExists = false
        var removes = 0
        XCTAssertTrue(performConfirmedPersistedDetectionDeletion(
            fileExists: { fileExists },
            remove: { removes += 1 }))
        XCTAssertEqual(removes, 0, "already absent is success without a spurious remove")

        fileExists = true
        XCTAssertFalse(performConfirmedPersistedDetectionDeletion(
            fileExists: { fileExists },
            remove: { removes += 1 /* a faulty/no-op filesystem seam */ }))
        XCTAssertEqual(removes, 1)
    }

    func testClearCommitsOnlyAfterDurableTombstoneOrConfirmedDeletion() {
        var deletes = 0
        XCTAssertEqual(preparePersistedDetectionClear(
            armTombstone: { true },
            deleteSynchronously: { deletes += 1; return false }), .durableTombstone)
        XCTAssertEqual(deletes, 0, "a durable intent makes an eager fallback delete unnecessary")

        XCTAssertEqual(preparePersistedDetectionClear(
            armTombstone: { false },
            deleteSynchronously: { deletes += 1; return true }), .confirmedDeletion)
        XCTAssertEqual(deletes, 1)

        XCTAssertEqual(preparePersistedDetectionClear(
            armTombstone: { false },
            deleteSynchronously: { deletes += 1; return false }), .unavailable)
        XCTAssertEqual(deletes, 2,
                       "failed arm plus failed delete must reject the clear before memory resets")
    }

    func testProtectedWriterReportsMissingURLAndWriteFailure() {
        let fixture = [Fixture(mac: "aa:bb:cc:dd:ee:ff")]
        XCTAssertFalse(performProtectedManagedListWrite(fixture, to: nil) { _, _ in
            XCTFail("a missing destination must not invoke the writer")
        })

        let destination = URL(fileURLWithPath: "/test-only/managed.json")
        XCTAssertFalse(performProtectedManagedListWrite(fixture, to: destination) { _, _ in
            throw WriteFailure.refused
        })
    }

    func testFailedNormalWriteStaysPendingUntilARealSuccess() {
        var state = ManagedListPersistenceState()
        state.record(.ignored, succeeded: false)
        XCTAssertTrue(state.hasPendingWrites)
        XCTAssertTrue(state.needsRetry(.ignored))

        // Saving a different file cannot make the failed edit look durable.
        state.record(.watched, succeeded: true)
        XCTAssertTrue(state.hasPendingWrites)
        XCTAssertTrue(state.needsRetry(.ignored))

        state.record(.ignored, succeeded: true)
        XCTAssertFalse(state.hasPendingWrites)
    }

    func testFailedMigrationRetainsLegacyFallback() throws {
        let fixture = [Fixture(mac: "aa:bb:cc:dd:ee:ff")]
        let data = try JSONEncoder().encode(fixture)
        var removals = 0

        let migration = migrateLegacyManagedList(
            [Fixture].self, data: data,
            persistProtected: { _ in false },
            removeLegacy: { removals += 1 })

        XCTAssertEqual(migration?.value, fixture)
        XCTAssertEqual(migration?.protectedWriteSucceeded, false)
        XCTAssertEqual(removals, 0, "failed protected migration must keep its only durable copy")
    }

    func testSuccessfulMigrationScrubsLegacyFallback() throws {
        let fixture = [Fixture(mac: "aa:bb:cc:dd:ee:ff")]
        let data = try JSONEncoder().encode(fixture)
        var removals = 0

        let migration = migrateLegacyManagedList(
            [Fixture].self, data: data,
            persistProtected: { $0 == fixture },
            removeLegacy: { removals += 1 })

        XCTAssertEqual(migration?.protectedWriteSucceeded, true)
        XCTAssertEqual(removals, 1)
    }

    func testPartialProtectedMigrationIsCompletedAndScrubbedAfterRelaunch() throws {
        let fixture = [Fixture(mac: "aa:bb:cc:dd:ee:ff")]
        let legacyData = try JSONEncoder().encode(fixture)
        var protectedData: Data?
        var legacyPresent = true

        // First launch: the atomic JSON write lands, then backup exclusion fails. Migration must
        // report failure and retain plaintext even though a decodable protected file now exists.
        let first = migrateLegacyManagedList(
            [Fixture].self, data: legacyData,
            persistProtected: { value in
                protectedData = try? JSONEncoder().encode(value)
                return false
            },
            removeLegacy: { legacyPresent = false })
        XCTAssertEqual(first?.protectedWriteSucceeded, false)
        XCTAssertNotNil(protectedData)
        XCTAssertTrue(legacyPresent)

        // Relaunch loads that file first. It must re-run the FULL protection operation instead of
        // returning early forever, and only that success is allowed to scrub UserDefaults.
        let loaded = try JSONDecoder().decode([Fixture].self, from: protectedData!)
        var reassertions = 0
        XCTAssertTrue(reconcileLegacyManagedListAfterProtectedLoad(
            loaded, legacyPresent: legacyPresent,
            persistProtected: { value in
                reassertions += 1
                return value == fixture
            },
            removeLegacy: { legacyPresent = false }))
        XCTAssertEqual(reassertions, 1)
        XCTAssertFalse(legacyPresent)
    }

    func testProtectedLoadKeepsLegacyWhenReprotectionStillFails() {
        let fixture = [Fixture(mac: "aa:bb:cc:dd:ee:ff")]
        var removals = 0
        XCTAssertFalse(reconcileLegacyManagedListAfterProtectedLoad(
            fixture, legacyPresent: true,
            persistProtected: { _ in false },
            removeLegacy: { removals += 1 }))
        XCTAssertEqual(removals, 0)
    }
}

final class BufferKeyDurabilityTests: XCTestCase {
    private func key(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: durableBufferKeyByteCount)
    }

    func testExistingUnavailableOrCorruptKeyFailsClosedWithoutGeneration() {
        var generations = 0
        var installs = 0
        let failures: [DurableBufferKeyReadResult] = [
            .unavailable,
            .found(Data(repeating: 1, count: durableBufferKeyByteCount - 1)),
        ]
        for read in failures {
            XCTAssertNil(resolveDurableBufferKey(
                read: { read },
                generate: { generations += 1; return self.key(1) },
                install: { _ in installs += 1; return self.key(1) }))
        }
        XCTAssertEqual(generations, 0, "existing key failures must not rotate evidence keys")
        XCTAssertEqual(installs, 0, "the existing Keychain item must remain untouched")
    }

    func testEntropyAndPersistenceFailuresNeverExposeAnEphemeralKey() {
        var installs = 0
        XCTAssertNil(resolveDurableBufferKey(
            read: { .missing }, generate: { nil },
            install: { _ in installs += 1; return self.key(1) }))
        XCTAssertEqual(installs, 0)

        let candidate = key(0x5a)
        XCTAssertNil(resolveDurableBufferKey(
            read: { .missing }, generate: { candidate }, install: { _ in nil }))
        XCTAssertNil(resolveDurableBufferKey(
            read: { .missing }, generate: { self.key(0) }, install: { $0 }))
    }

    func testDuplicateAddUsesTheDurableWinnerNotTheLosingCandidate() {
        let candidate = key(0x11)
        let persistentWinner = key(0x22)
        let result = resolveDurableBufferKey(
            read: { .missing },
            generate: { candidate },
            install: { supplied in
                XCTAssertEqual(supplied, candidate)
                return persistentWinner
            })
        XCTAssertEqual(result, persistentWinner)
    }

    func testKeyFailureEmitsNeitherEpochNorSyncAndSyncFailureIsNotComplete() {
        let keyFailure = bufferHandshakeTransition(completed: .key, success: false)
        XCTAssertNil(keyFailure.next)
        XCTAssertTrue(keyFailure.failed)
        XCTAssertFalse(keyFailure.complete)

        let syncFailure = bufferHandshakeTransition(completed: .sync, success: false)
        XCTAssertTrue(syncFailure.failed)
        XCTAssertFalse(syncFailure.complete)
    }

    func testStatusAndOTAReadinessAreStrictlyPostSyncAndOrdered() {
        XCTAssertFalse(bufferHandshakeTransition(completed: .key, success: true).complete)
        XCTAssertFalse(bufferHandshakeTransition(completed: .epoch, success: true).complete)
        XCTAssertTrue(bufferHandshakeTransition(completed: .sync, success: true).complete)

        XCTAssertEqual(
            postSyncReadyStep(statusAvailable: true, statusSettled: false,
                              otaAvailable: true, otaSettled: false),
            .subscribeStatus)
        XCTAssertEqual(
            postSyncReadyStep(statusAvailable: true, statusSettled: true,
                              otaAvailable: true, otaSettled: false),
            .subscribeOTA)
        XCTAssertEqual(
            postSyncReadyStep(statusAvailable: true, statusSettled: true,
                              otaAvailable: true, otaSettled: true),
            .finishReady)
    }

    func testPostSyncPauseParksClearAndStatusReconciliationUntilReadinessSettles() {
        // The clear was requested while startup KEY/EPOCH/SYNC was still in flight. The first
        // Status frame then discovers a setting mismatch and queues reconciliation. Neither the
        // enqueue call nor the later OTA CCCD callback may dispatch through the post-SYNC pause.
        var queue = ["clear"]
        var postSyncPaused = true
        var inFlight: String?

        func nextDispatch() -> String? {
            guard configWriteDispatchAllowed(
                postSyncPaused: postSyncPaused,
                hasInFlight: inFlight != nil,
                hasQueuedWrite: !queue.isEmpty
            ) else { return nil }
            return queue.removeFirst()
        }

        XCTAssertNil(nextDispatch(), "startup SYNC must park an already-queued clear")
        queue.append("status-reconciliation")
        XCTAssertNil(nextDispatch(), "Status reconciliation enqueue must honor the same pause")
        XCTAssertNil(nextDispatch(), "OTA subscription completion alone must not leak Config work")

        // finishReady is the sole normal release point. Once clear is dispatched, its rekey
        // successors stay ahead of the reconciliation write through the full ACK transaction.
        postSyncPaused = false
        XCTAssertEqual(nextDispatch(), "clear")
        enqueueBufferControlWrite("key", into: &queue, handshakeSuccessor: true)
        XCTAssertEqual(nextDispatch(), "key")
        enqueueBufferControlWrite("epoch", into: &queue, handshakeSuccessor: true)
        XCTAssertEqual(nextDispatch(), "epoch")
        enqueueBufferControlWrite("sync", into: &queue, handshakeSuccessor: true)
        XCTAssertEqual(nextDispatch(), "sync")
        XCTAssertEqual(nextDispatch(), "status-reconciliation")
    }

    func testClearAndDoubleClearStayBehindEveryHandshakeSuccessor() {
        var queue = ["clear-1", "clear-2"]
        enqueueBufferControlWrite("epoch", into: &queue, handshakeSuccessor: true)
        XCTAssertEqual(queue, ["epoch", "clear-1", "clear-2"])
        queue.removeFirst()
        enqueueBufferControlWrite("sync", into: &queue, handshakeSuccessor: true)
        XCTAssertEqual(queue, ["sync", "clear-1", "clear-2"])
    }

    func testLinkDropClearsKeyOrEpochOwnerAndEveryQueuedSuccessor() {
        for current in ["key", "epoch"] {
            var queue = ["epoch", "sync", "clear"]
            var inFlight: String? = current
            var owner: String? = "startup"
            resetBufferControlWriteState(
                queue: &queue, inFlight: &inFlight, owner: &owner)
            XCTAssertTrue(queue.isEmpty)
            XCTAssertNil(inFlight)
            XCTAssertNil(owner)
        }
    }

    func testRetiredCharacteristicCannotAcknowledgeReplacementSessionsKey() {
        let reusedPeripheral = NSObject()
        let retiredConfig = NSObject()
        let replacementConfig = NSObject()

        XCTAssertFalse(callbackBelongsToCurrentSession(
            callbackOwner: reusedPeripheral, currentOwner: reusedPeripheral,
            callbackChannel: retiredConfig, currentChannel: replacementConfig))
        XCTAssertTrue(callbackBelongsToCurrentSession(
            callbackOwner: reusedPeripheral, currentOwner: reusedPeripheral,
            callbackChannel: replacementConfig, currentChannel: replacementConfig))
    }

    func testReconnectRejectsRetiredCCCDAndValueCallbacksUntilFreshDiscovery() {
        let reusedPeripheral = NSObject()
        let retiredChannels = (0..<3).map { _ in NSObject() }

        // didConnect/teardown clear every trusted identity. A reused CBPeripheral's retained
        // services are deliberately irrelevant until this connection's discovery installs one.
        for retired in retiredChannels {
            XCTAssertFalse(callbackBelongsToCurrentSession(
                callbackOwner: reusedPeripheral, currentOwner: reusedPeripheral,
                callbackChannel: retired, currentChannel: nil as NSObject?))
        }

        // Once fresh discovery installs the replacement identity, only that object is accepted;
        // late Detections CCCD and Status/OTA value callbacks from the old link remain inert.
        for retired in retiredChannels {
            let fresh = NSObject()
            XCTAssertFalse(callbackBelongsToCurrentSession(
                callbackOwner: reusedPeripheral, currentOwner: reusedPeripheral,
                callbackChannel: retired, currentChannel: fresh))
            XCTAssertTrue(callbackBelongsToCurrentSession(
                callbackOwner: reusedPeripheral, currentOwner: reusedPeripheral,
                callbackChannel: fresh, currentChannel: fresh))
        }
    }

    func testErroredServiceDiscoveryCannotInstallCachedRetiredService() {
        let reusedPeripheral = NSObject()
        let cachedRetiredService = NSObject()
        var installedService: NSObject?

        let disposition = sessionServiceDiscoveryDisposition(
            callbackOwner: reusedPeripheral,
            currentOwner: reusedPeripheral,
            awaitingServices: true,
            error: NSError(domain: "test.discovery", code: 1))
        if disposition == .accept { installedService = cachedRetiredService }

        XCTAssertEqual(disposition, .fail)
        XCTAssertNil(installedService,
                     "an errored callback must fail before cached peripheral.services is trusted")
    }

    func testCharacteristicDiscoveryRequiresExactFreshServiceAndNilError() {
        let reusedPeripheral = NSObject()
        let retiredService = NSObject()
        let freshService = NSObject()

        XCTAssertEqual(sessionCharacteristicDiscoveryDisposition(
            callbackOwner: reusedPeripheral,
            currentOwner: reusedPeripheral,
            awaitingCharacteristics: true,
            callbackService: retiredService,
            currentService: freshService,
            error: nil), .ignore)
        XCTAssertEqual(sessionCharacteristicDiscoveryDisposition(
            callbackOwner: reusedPeripheral,
            currentOwner: reusedPeripheral,
            awaitingCharacteristics: true,
            callbackService: freshService,
            currentService: freshService,
            error: NSError(domain: "test.discovery", code: 2)), .fail)
        XCTAssertEqual(sessionCharacteristicDiscoveryDisposition(
            callbackOwner: reusedPeripheral,
            currentOwner: reusedPeripheral,
            awaitingCharacteristics: true,
            callbackService: freshService,
            currentService: freshService,
            error: nil), .accept)
    }
}
