import XCTest
@testable import Beacons

final class MuteAndNearbyPolicyTests: XCTestCase {
    private let base = IgnoredDevice(mac: "aa:bb:cc:dd:ee:ff", label: "camera")

    func testOnlyUnscopedMutesAreBoardBacked() {
        XCTAssertTrue(isBoardBackedMute(base))
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, expiresAt: Date(timeIntervalSince1970: 100))))
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, latitude: 1, longitude: 2, radiusMeters: 50)))
        // A partially decoded/corrupt location rule must fail closed instead of becoming permanent.
        XCTAssertFalse(isBoardBackedMute(IgnoredDevice(
            mac: base.mac, label: base.label, latitude: 1)))
    }

    func testNearbyWindowMatchesStatusBoundary() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(lastSeenIsNearby(now, now: now))
        XCTAssertTrue(lastSeenIsNearby(now.addingTimeInterval(-activeNearbyInterval), now: now))
        XCTAssertFalse(lastSeenIsNearby(
            now.addingTimeInterval(-activeNearbyInterval - 0.001), now: now))
        XCTAssertFalse(lastSeenIsNearby(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(lastSeenIsNearby(nil, now: now))
    }

    func testStatusStalenessTreatsAdjacentFutureTimestampAsFresh() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(lastSeenIsStale(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(lastSeenIsStale(now.addingTimeInterval(-activeNearbyInterval), now: now))
        XCTAssertTrue(lastSeenIsStale(
            now.addingTimeInterval(-activeNearbyInterval - 0.001), now: now))
        XCTAssertTrue(lastSeenIsStale(nil, now: now))
    }

    func testSampleRowsDoNotAgeOutOfLiveActivity() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let old = now.addingTimeInterval(-activeNearbyInterval - 1)
        XCTAssertFalse(liveRowIsNearby(old, now: now, isDemoMode: false))
        XCTAssertTrue(liveRowIsNearby(old, now: now, isDemoMode: true))
    }

    func testHereMuteRequiresCurrentNotCachedLocation() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(locationFixIsCurrent(now, now: now))
        XCTAssertTrue(locationFixIsCurrent(
            now.addingTimeInterval(-currentLocationFixMaxAge), now: now))
        XCTAssertFalse(locationFixIsCurrent(
            now.addingTimeInterval(-currentLocationFixMaxAge - 0.001), now: now))
        XCTAssertFalse(locationFixIsCurrent(now.addingTimeInterval(0.001), now: now))
        XCTAssertFalse(locationFixIsCurrent(nil, now: now))
    }

    func testHereMuteRequiresAccuracyWithinItsFiftyMeterRadius() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(locationFixSupportsHere(now, horizontalAccuracy: 50, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: 50.001, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: -1, now: now))
        XCTAssertFalse(locationFixSupportsHere(now, horizontalAccuracy: .infinity, now: now))
        XCTAssertFalse(locationFixSupportsHere(
            now.addingTimeInterval(-currentLocationFixMaxAge - 1),
            horizontalAccuracy: 5, now: now))
    }

    func testBoardListReconcilesFailedNonemptyWritesWithoutAuthorizingEmptyPhone() {
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: 1, clearPending: false), .pushList)
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: 2, clearPending: false), .none)
        XCTAssertEqual(boardListSyncAction(
            localCount: 2, boardCount: nil, clearPending: false), .pushList)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 3, clearPending: false), .none)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 3, clearPending: true), .pushClear)
        XCTAssertEqual(boardListSyncAction(
            localCount: 0, boardCount: 0, clearPending: true), .acknowledgeClear)
    }

    func testBoardOnlyMuteCountIsVisibleWithoutInventingIdentities() {
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 4, localBoardBackedCount: 0), 4)
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 4, localBoardBackedCount: 2), 2)
        XCTAssertEqual(unrepresentedBoardRuleCount(boardCount: 1, localBoardBackedCount: 2), 0)
    }

    func testHistoricalWatchedTypeDoesNotBypassCurrentMute() {
        let mac = "aa:bb:cc:dd:ee:ff"
        XCTAssertFalse(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: false, activeIgnoredMacs: [mac]))
        XCTAssertTrue(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: true, activeIgnoredMacs: [mac]))
        XCTAssertTrue(activeProjectionIncludes(
            mac: mac, isCurrentlyWatched: false, activeIgnoredMacs: []))
    }

    func testLiveModeRequiresReadySessionAndLocationAndRejectsSampleData() {
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: false, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: true, isDemoMode: false, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: false, locationAuthorized: true))
        XCTAssertTrue(liveModeCanRun(
            hasReadySession: true, isDemoMode: false, locationAuthorized: true))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: false, isDemoMode: true, locationAuthorized: false))
        XCTAssertFalse(liveModeCanRun(
            hasReadySession: true, isDemoMode: true, locationAuthorized: true))
    }

    func testSamplePhoneSettingsMutateOnlyThePreviewValue() {
        let real = SamplePhoneSettings(
            liveModeWanted: true, redactLockScreen: true, notificationTypes: [1, 3])
        var preview = real
        preview.liveModeWanted = false
        preview.redactLockScreen = false
        preview.setNotification(false, rawValue: 1)
        preview.setNotification(true, rawValue: 9)

        XCTAssertTrue(real.liveModeWanted)
        XCTAssertTrue(real.redactLockScreen)
        XCTAssertEqual(real.notificationTypes, [1, 3])
        XCTAssertFalse(preview.liveModeWanted)
        XCTAssertFalse(preview.redactLockScreen)
        XCTAssertFalse(preview.notificationEnabled(1))
        XCTAssertTrue(preview.notificationEnabled(9))
    }

    func testSampleLogMutationsCannotReachPersistentEvidenceState() {
        XCTAssertEqual(detectionLogClearAction(isDemoMode: true), .sampleMemoryOnly)
        XCTAssertEqual(detectionLogClearAction(isDemoMode: false), .memoryAndDisk)
        XCTAssertFalse(seenWatermarkWritesAllowed(isDemoMode: true))
        XCTAssertTrue(seenWatermarkWritesAllowed(isDemoMode: false))
    }

    func testDemoTourIsOptInForVisualFixtureLaunches() {
        XCTAssertTrue(shouldPresentSampleTour(isDemoMode: true, tourRequested: true))
        XCTAssertFalse(shouldPresentSampleTour(isDemoMode: true, tourRequested: false))
        XCTAssertFalse(shouldPresentSampleTour(isDemoMode: false, tourRequested: true))
    }

    func testManagedListWritesArePreviewOnlyInSampleMode() {
        XCTAssertTrue(managedListWritesAllowed(isDemoMode: false))
        XCTAssertFalse(managedListWritesAllowed(isDemoMode: true))
    }

    func testLiveModeCategoryFallbackDistinguishesUnknownFromAllOff() {
        let unknownStatus = effectiveLiveModeCategories(nil)
        XCTAssertEqual(unknownStatus, Set([
            WidgetCategory.alpr.rawValue, WidgetCategory.drone.rawValue,
            WidgetCategory.body.rawValue, WidgetCategory.tracker.rawValue,
            WidgetCategory.glasses.rawValue,
        ]))
        XCTAssertTrue(effectiveLiveModeCategories([]).isEmpty)
        XCTAssertEqual(effectiveLiveModeCategories([WidgetCategory.camera.rawValue]),
                       Set([WidgetCategory.camera.rawValue]))
    }
}
