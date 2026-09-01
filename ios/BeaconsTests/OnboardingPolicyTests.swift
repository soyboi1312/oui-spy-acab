import XCTest
@testable import Beacons

final class OnboardingPolicyTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "tech.beacons.tests.onboarding.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testRealTourWaitsForEncryptedSessionReadiness() {
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: false, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .firstRunTour)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: true, hasSeenTour: false,
            finishSetupPending: false, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: false, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .none)
    }

    func testReadyRealTourDurablyArmsFinishSetupAcrossRelaunch() {
        XCTAssertTrue(persistRealTourCompletion(
            isSampleData: false, isSessionReady: true, defaults: defaults))
        XCTAssertTrue(FirstRunTour.hasSeen(in: defaults))
        XCTAssertTrue(FinishSetupOnboarding.isPending(in: defaults))

        let relaunchedDefaults = UserDefaults(suiteName: suiteName)!
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false,
            hasSeenTour: FirstRunTour.hasSeen(in: relaunchedDefaults),
            finishSetupPending: FinishSetupOnboarding.isPending(in: relaunchedDefaults),
            setupHelpPresented: false, tourPresented: false,
            finishSetupPresented: false), .finishSetup)

        persistFinishSetupCompletion(defaults: relaunchedDefaults)
        XCTAssertFalse(FinishSetupOnboarding.isPending(in: defaults))
        XCTAssertTrue(FirstRunTour.hasSeen(in: defaults))
    }

    func testInterruptedTourWriteConvergesWhenRecoveredFinishSetupCloses() {
        FinishSetupOnboarding.arm(in: defaults)
        XCTAssertFalse(FirstRunTour.hasSeen(in: defaults))
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: false,
            finishSetupPending: true, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .finishSetup)

        persistFinishSetupCompletion(defaults: defaults)
        XCTAssertTrue(FirstRunTour.hasSeen(in: defaults))
        XCTAssertFalse(FinishSetupOnboarding.isPending(in: defaults))
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: false, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .none)
    }

    func testSampleHelpReplayAndLostReadinessNeverArmRealOnboarding() {
        XCTAssertFalse(persistRealTourCompletion(
            isSampleData: true, isSessionReady: true, defaults: defaults))
        XCTAssertFalse(persistRealTourCompletion(
            isSampleData: false, isSessionReady: false, defaults: defaults))
        XCTAssertFalse(FirstRunTour.hasSeen(in: defaults))
        XCTAssertFalse(FinishSetupOnboarding.isPending(in: defaults))
        XCTAssertFalse(realTourCompletionCanPersist(isSampleData: true,
                                                     isSessionReady: true))
        XCTAssertFalse(realTourCompletionCanPersist(isSampleData: false,
                                                     isSessionReady: false))
    }

    func testFinishSetupQueuesBehindHelpAndNeverStacksWithAnotherSheet() {
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: true,
            tourPresented: false, finishSetupPresented: false), .waitForSetupHelp)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: false,
            tourPresented: true, finishSetupPresented: false), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: false, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: true), .none)
        XCTAssertEqual(onboardingPresentation(
            isSessionReady: true, isDemoMode: true, hasSeenTour: true,
            finishSetupPending: true, setupHelpPresented: false,
            tourPresented: false, finishSetupPresented: false), .none)
    }

    func testOnboardingGateIncludesDurableFinishSetup() {
        XCTAssertTrue(firstRunOnboardingShouldRemainActive(
            hasSeenTour: false, finishSetupPending: false))
        XCTAssertTrue(firstRunOnboardingShouldRemainActive(
            hasSeenTour: true, finishSetupPending: true))
        XCTAssertFalse(firstRunOnboardingShouldRemainActive(
            hasSeenTour: true, finishSetupPending: false))
    }

    func testAutomaticLiveModeStaysBlockedUntilOnboardingIsReleased() {
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: false,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: true))
        XCTAssertTrue(automaticLiveModeCanRun(hasReadySession: true,
                                               isDemoMode: false,
                                               locationAuthorized: true,
                                               firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: false,
                                                isDemoMode: false,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: false,
                                                locationAuthorized: false,
                                                firstRunOnboardingActive: false))
        XCTAssertFalse(automaticLiveModeCanRun(hasReadySession: true,
                                                isDemoMode: true,
                                                locationAuthorized: true,
                                                firstRunOnboardingActive: false))
    }

    func testLocationChoiceHasExplicitContinueAndNotNowState() {
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: false, isDenied: false),
                       .continueOrNotNow)
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: false, isDenied: true),
                       .openSettingsOrDone)
        XCTAssertEqual(finishSetupLocationChoice(isAuthorized: true, isDenied: false),
                       .done)
    }

    func testLocationPromptRequiresAVisibleCompletedFinishSetupSheet() {
        XCTAssertTrue(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: false, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: false, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: false,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: true, isAppActive: true))
        XCTAssertFalse(shouldRequestOnboardingLocation(
            continueChosen: true, isSessionReady: true,
            finishSetupWasPresented: true, isDemoMode: false, isAppActive: false))
    }

    func testDemoEntryCancelsActiveAndDeferredScanWork() {
        XCTAssertFalse(demoEntryNeedsScanCancellation(isScanning: false,
                                                       scanDeferred: false))
        XCTAssertTrue(demoEntryNeedsScanCancellation(isScanning: true,
                                                      scanDeferred: false))
        XCTAssertTrue(demoEntryNeedsScanCancellation(isScanning: false,
                                                      scanDeferred: true))
    }

    func testSecureReadinessWatchdogSpansTransportThroughReady() {
        XCTAssertEqual(secureReadinessTimeoutInterval, 45)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .transportConnected), .arm)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .sessionReady), .cancel)
        XCTAssertEqual(secureReadinessWatchdogAction(for: .teardown), .cancel)

        let expected = UUID()
        XCTAssertTrue(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: false, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: UUID(),
            sessionReady: false, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: true, isDemoMode: false))
        XCTAssertFalse(secureReadinessTimeoutApplies(
            expectedID: expected, currentID: expected,
            sessionReady: false, isDemoMode: true))
    }

    func testImproveDetectionRequiresAReadyRealBeacon() {
        XCTAssertTrue(improveDetectionAvailable(isSessionReady: true, isDemoMode: false))
        XCTAssertFalse(improveDetectionAvailable(isSessionReady: false, isDemoMode: false))
        XCTAssertFalse(improveDetectionAvailable(isSessionReady: true, isDemoMode: true))
        XCTAssertFalse(helpSupportActionIsVisible(
            "improveDetection", canImproveDetection: false))
        XCTAssertTrue(helpSupportActionIsVisible(
            "improveDetection", canImproveDetection: true))
        XCTAssertTrue(helpSupportActionIsVisible("firstRunTour", canImproveDetection: false))
        XCTAssertTrue(contributionCaptureCanStart(isSessionReady: true, isDemoMode: false))
        XCTAssertFalse(contributionCaptureCanStart(isSessionReady: false, isDemoMode: false))
        XCTAssertFalse(contributionCaptureCanStart(isSessionReady: true, isDemoMode: true))
    }

    func testConnectionFailuresGiveDistinctBeaconRecovery() {
        let failures: [BeaconConnectionFailure] = [
            .timeout, .transport, .securePairing, .missingService,
        ]
        let messages = failures.map(beaconConnectionRecovery)

        XCTAssertEqual(Set(messages).count, failures.count)
        XCTAssertTrue(messages.allSatisfy { $0.contains("beacon") })
        XCTAssertTrue(messages.allSatisfy { !$0.contains("board") })
        XCTAssertTrue(messages.allSatisfy {
            !$0.contains("\u{2013}") && !$0.contains("\u{2014}")
        })
        XCTAssertTrue(beaconConnectionRecovery(.securePairing).contains("iOS pairing request"))
        XCTAssertTrue(BLEManager.pairWindowHint.contains("within two minutes"))
    }

    func testScanRowsUseHumanSignalBands() {
        XCTAssertEqual(beaconSignalDescription(rssi: -91), "weak")
        XCTAssertEqual(beaconSignalDescription(rssi: -90), "fair")
        XCTAssertEqual(beaconSignalDescription(rssi: -80), "good")
        XCTAssertEqual(beaconSignalDescription(rssi: -67), "strong")
    }

    func testBluetoothPrePermissionActionUsesNeutralContinueTitle() {
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: false, bluetoothGranted: false), "Continue")
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: false, bluetoothGranted: true), "Scan for beacons")
        XCTAssertEqual(bluetoothScanButtonTitle(
            isScanning: true, bluetoothGranted: false), "Stop scanning")
    }
}
