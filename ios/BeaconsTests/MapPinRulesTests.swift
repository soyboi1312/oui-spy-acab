import XCTest
import CoreLocation
@testable import Beacons

/// The two rules behind what a map pin stands for and how old it is allowed to look.
///
/// WHY THIS HAS A TEST. Both rules fail silently. A grouping tolerance that drifts either merges
/// two genuinely different poles into one pin or leaves a body camera buried under the sighting
/// drawn on top of it, and neither shows up in a screenshot. An age boundary that drifts makes
/// yesterday's persisted pin pulse like a live alert, which is the single most misleading thing
/// this map can do.
///
/// EXACTLY WHAT IS SHARED WITH ANDROID: the tolerance, the priority order, the most-recent
/// tie-break, the three age boundaries, and "a missing stamp is RECENT, never FRESH". The Android
/// suite asserts the same rules against its own implementation.
///
/// WHAT IS NOT SHARED: artwork, and how each platform gets to the answer. The badge and the
/// dimmed marker are drawn per platform off each platform's own pin, so the numbers behind them
/// are each side's own and must not be matched up. `MapPinRules.lead` is likewise iOS's own: it
/// exists because the iOS map resolves a group's winner on every publish, and it is asserted
/// below against `ordered` on this platform, never against anything Android does.
final class MapPinRulesTests: XCTestCase {

    // MARK: - Fixtures

    /// A stand-in for a stored row. The rules take the two fields they actually use through
    /// closures, so nothing here needs a Detection, a store, or CoreBluetooth.
    private struct Row {
        let tag: String
        let type: DeviceType
        let seen: Date?
    }

    private func ordered(_ rows: [Row]) -> [String] {
        MapPinRules.ordered(rows, type: { $0.type }, lastSeen: { $0.seen }).map(\.tag)
    }

    private func lead(_ rows: [Row]) -> String? {
        MapPinRules.lead(rows, type: { $0.type }, lastSeen: { $0.seen })?.tag
    }

    /// San Diego, the app's own fallback region centre.
    private let base = CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)

    private func offset(lat: Double = 0, lon: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + lat, longitude: base.longitude + lon)
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ secs: TimeInterval) -> Date { now.addingTimeInterval(-secs) }

    // MARK: - Grouping tolerance

    /// The cross-platform tolerance. A change here is a cross-platform change.
    func testSameSpotToleranceIsTheCrossPlatformContract() {
        XCTAssertEqual(MapPinRules.sameSpotDegrees, 1e-5)
        // ~1.1 m of latitude, which is the number the tolerance is chosen against: wide enough to
        // cover one standing position, far tighter than the gap between two real installs.
        XCTAssertEqual(MapPinRules.sameSpotDegrees * 111_320, 1.1, accuracy: 0.05)
    }

    /// The case the whole feature exists for: several rows stamped with the SAME phone coordinate.
    func testIdenticalCoordinatesAlwaysShareAKey() {
        let c = offset()
        XCTAssertEqual(MapPinRules.spotKey(c), MapPinRules.spotKey(c))
        XCTAssertNotNil(MapPinRules.spotKey(c))
    }

    /// Well inside the tolerance: GPS jitter on a single standing position still groups.
    func testCoordinatesInsideToleranceGroup() {
        // A tenth of a cell, taken from the middle of one so the pair cannot straddle an edge.
        let cell = MapPinRules.sameSpotDegrees
        let anchor = CLLocationCoordinate2D(latitude: (base.latitude / cell).rounded(.down) * cell + cell / 2,
                                            longitude: (base.longitude / cell).rounded(.down) * cell + cell / 2)
        let nudged = CLLocationCoordinate2D(latitude: anchor.latitude + cell / 10,
                                            longitude: anchor.longitude - cell / 10)
        XCTAssertEqual(MapPinRules.spotKey(anchor), MapPinRules.spotKey(nudged))
    }

    /// Two separate installs down the block never merge. 1e-3 degrees is ~111 m.
    func testDistinctPositionsDoNotGroup() {
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lat: 1e-3)))
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lon: 1e-3)))
    }

    /// An order of magnitude past the tolerance is unambiguously a different spot on both axes.
    func testTenCellsApartDoNotGroup() {
        let ten = MapPinRules.sameSpotDegrees * 10
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lat: ten)))
        XCTAssertNotEqual(MapPinRules.spotKey(offset()), MapPinRules.spotKey(offset(lon: ten)))
    }

    /// A coordinate that cannot be bucketed degrades to "no key", never to a trap. It reaches the
    /// map only through a corrupt cache or a garbled fix, and it then renders ungrouped, which is
    /// what the map drew before grouping existed.
    func testUnbucketableCoordinatesReturnNoKey() {
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: .nan, longitude: 0)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: 0, longitude: .nan)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: .infinity, longitude: 0)))
        XCTAssertNil(MapPinRules.spotKey(CLLocationCoordinate2D(latitude: 0, longitude: 1e300)))
    }

    // MARK: - Priority order

    /// The shared order, asserted as an order rather than as five separate numbers so renumbering
    /// the buckets stays free and reordering them does not.
    func testPriorityOrderIsWatchedAlprRavenBodyCamDroneThenEverythingElse() {
        let order: [DeviceType] = [.watched, .flockCamera, .flockRaven, .axonBodyCam, .drone]
        for (a, b) in zip(order, order.dropFirst()) {
            XCTAssertLessThan(MapPinRules.priority(a), MapPinRules.priority(b),
                              "\(a) must outrank \(b)")
        }
        for other: DeviceType in [.tracker, .recordingGlasses, .networkCamera, .nearbyDevice, .unknown] {
            XCTAssertGreaterThan(MapPinRules.priority(other), MapPinRules.priority(.drone),
                                 "\(other) must sit below every named category")
        }
    }

    /// The headline case, stated as the outcome and not as a comparison of two integers: a body
    /// camera stamped at the same spot as an older nearby device draws, and it is what the tap
    /// lands on.
    func testBodyCamNeverHidesUnderAnOlderLessImportantSighting() {
        let rows = [Row(tag: "nearby", type: .nearbyDevice, seen: ago(30)),
                    Row(tag: "bodycam", type: .axonBodyCam, seen: ago(9_000))]
        XCTAssertEqual(ordered(rows).first, "bodycam")
    }

    /// Priority beats recency in both input orders, so the answer never depends on how the store
    /// happened to hand the rows over.
    func testPriorityBeatsRecencyRegardlessOfInputOrder() {
        let watched = Row(tag: "watched", type: .watched, seen: ago(50_000))
        let alpr = Row(tag: "alpr", type: .flockCamera, seen: ago(5))
        XCTAssertEqual(ordered([watched, alpr]), ["watched", "alpr"])
        XCTAssertEqual(ordered([alpr, watched]), ["watched", "alpr"])
    }

    /// Every member survives the ordering; the group's job is to make all of them reachable.
    func testOrderingKeepsEveryMember() {
        let rows = [Row(tag: "a", type: .nearbyDevice, seen: ago(10)),
                    Row(tag: "b", type: .flockRaven, seen: ago(10)),
                    Row(tag: "c", type: .watched, seen: ago(10)),
                    Row(tag: "d", type: .axonBodyCam, seen: ago(10))]
        XCTAssertEqual(ordered(rows), ["c", "b", "d", "a"])
    }

    // MARK: - Tie-break by recency

    func testEqualPriorityBreaksTieByMostRecent() {
        let rows = [Row(tag: "old", type: .flockCamera, seen: ago(3_000)),
                    Row(tag: "new", type: .flockCamera, seen: ago(10)),
                    Row(tag: "middle", type: .flockCamera, seen: ago(600))]
        XCTAssertEqual(ordered(rows), ["new", "middle", "old"])
    }

    /// A member with no stamp at all loses the tie-break to one that has any stamp, rather than
    /// winning it by accident.
    func testMissingStampLosesTheRecencyTieBreak() {
        let rows = [Row(tag: "undated", type: .flockCamera, seen: nil),
                    Row(tag: "dated", type: .flockCamera, seen: ago(90_000))]
        XCTAssertEqual(ordered(rows), ["dated", "undated"])
    }

    /// Tied on BOTH keys, the order is the order they arrived in, in both directions. Swift's sort
    /// is not stable, so this is what stops a pin's identity flickering between passes.
    func testFullTieIsDeterministic() {
        let stamp = ago(120)
        let a = Row(tag: "a", type: .flockCamera, seen: stamp)
        let b = Row(tag: "b", type: .flockCamera, seen: stamp)
        XCTAssertEqual(ordered([a, b]), ["a", "b"])
        XCTAssertEqual(ordered([b, a]), ["b", "a"])
    }

    /// A group of one comes back untouched: it has to render exactly as it does today.
    func testSingleMemberGroupIsUnchanged() {
        XCTAssertEqual(ordered([Row(tag: "only", type: .nearbyDevice, seen: nil)]), ["only"])
    }

    // MARK: - Winner scan

    /// The map does NOT order a group to find out what it draws as. `ordered` sorts and allocates,
    /// and it would run for every pin on the map on every publish; `lead` answers the same
    /// question in one scan, and the tap keeps `ordered` for the member list. So the pin that
    /// DRAWS and the pin the member sheet opens on come from two different functions, and this is
    /// the test that stops them from ever disagreeing.
    func testLeadIsAlwaysTheFirstElementOfTheFullOrder() {
        let groups: [[Row]] = [
            [],
            [Row(tag: "only", type: .nearbyDevice, seen: nil)],
            // A body camera under a fresher nearby device: the headline case.
            [Row(tag: "nearby", type: .nearbyDevice, seen: ago(30)),
             Row(tag: "bodycam", type: .axonBodyCam, seen: ago(9_000))],
            // Priority beats recency by a wide margin in both directions.
            [Row(tag: "alpr", type: .flockCamera, seen: ago(5)),
             Row(tag: "watched", type: .watched, seen: ago(50_000))],
            // Equal priority: the tie-break alone decides.
            [Row(tag: "old", type: .flockCamera, seen: ago(3_000)),
             Row(tag: "new", type: .flockCamera, seen: ago(10)),
             Row(tag: "middle", type: .flockCamera, seen: ago(600))],
            // An undated row must not win a tie-break by accident.
            [Row(tag: "undated", type: .flockCamera, seen: nil),
             Row(tag: "dated", type: .flockCamera, seen: ago(90_000))],
            // Every rank at once, arriving in the worst possible order.
            [Row(tag: "unknown", type: .unknown, seen: ago(1)),
             Row(tag: "drone", type: .drone, seen: ago(2)),
             Row(tag: "bodycam", type: .axonBodyCam, seen: ago(3)),
             Row(tag: "raven", type: .flockRaven, seen: ago(4)),
             Row(tag: "alpr", type: .flockCamera, seen: ago(5)),
             Row(tag: "watched", type: .watched, seen: ago(6))],
        ]
        for rows in groups {
            let tags = rows.map(\.tag)
            XCTAssertEqual(lead(rows), ordered(rows).first, "lead disagrees with ordered for \(tags)")
            let flipped = Array(rows.reversed())
            XCTAssertEqual(lead(flipped), ordered(flipped).first,
                           "lead disagrees with ordered for reversed \(tags)")
        }
    }

    /// Tied on BOTH keys, the scan keeps the FIRST arrival, which is the same answer `ordered`'s
    /// index tie-break gives. Without this the drawn pin could swap identity between two passes
    /// over an unchanged store.
    func testLeadHoldsAFullTieOnTheEarliestArrival() {
        let stamp = ago(120)
        let a = Row(tag: "a", type: .flockCamera, seen: stamp)
        let b = Row(tag: "b", type: .flockCamera, seen: stamp)
        XCTAssertEqual(lead([a, b]), "a")
        XCTAssertEqual(lead([b, a]), "b")
    }

    /// An empty group has no winner rather than a placeholder one.
    func testLeadOfAnEmptyGroupIsNil() {
        XCTAssertNil(lead([]))
    }

    // MARK: - Age tiers

    /// The three boundaries Android has to match.
    func testAgeBoundariesAreTheCrossPlatformContract() {
        XCTAssertEqual(MapPinRules.freshSeconds, 300)
        XCTAssertEqual(MapPinRules.staleSeconds, 3_600)
    }

    func testFreshTierIsUnderFiveMinutes() {
        XCTAssertEqual(MapPinRules.age(lastSeen: now, now: now), .fresh)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(1), now: now), .fresh)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(299), now: now), .fresh)
    }

    func testRecentTierRunsFromFiveMinutesToOneHour() {
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(300), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(1_800), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(3_600), now: now), .recent)
    }

    func testStaleTierIsPastOneHour() {
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(3_601), now: now), .stale)
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(86_400), now: now), .stale)
        // The case that started this: a pin persisted from a previous day.
        XCTAssertEqual(MapPinRules.age(lastSeen: ago(5 * 86_400), now: now), .stale)
    }

    /// A stamp ahead of the clock is a clock correction, not the future, so it clamps to zero
    /// elapsed rather than computing a negative age or landing in some other tier.
    func testStampAheadOfTheClockClampsToFresh() {
        XCTAssertEqual(MapPinRules.age(lastSeen: now.addingTimeInterval(45), now: now), .fresh)
    }

    // MARK: - Missing timestamp

    /// The rule that must never invert: an undated row is RECENT. FRESH is a claim about liveness,
    /// and a row we cannot date is a row we cannot make that claim about. STALE would be the
    /// opposite lie, dimming something that may well be live.
    func testMissingTimestampIsRecentNeverFresh() {
        XCTAssertEqual(MapPinRules.age(lastSeen: nil, now: now), .recent)
    }

    /// A zeroed stamp means "unknown", not 1970. Left alone it would resolve to the oldest thing
    /// on the map and dim a row nobody ever dated.
    func testZeroTimestampIsRecent() {
        XCTAssertEqual(MapPinRules.age(lastSeen: Date(timeIntervalSince1970: 0), now: now), .recent)
        XCTAssertEqual(MapPinRules.age(lastSeen: Date(timeIntervalSince1970: -1), now: now), .recent)
    }

    // MARK: - Known coverage gap: the demo seed's placement stamp
    //
    // NOT TESTED HERE, ON PURPOSE, AND NOT BECAUSE THE RULE DOES NOT MATTER. The guarantee is
    // that BLEManager.placeDemoDetections writes a lastSeen stamp for every sample row at the
    // moment it places it: drop that one line and every sample pin on the tour falls to RECENT
    // and stops pinging, which no other test in this file would catch.
    //
    // The test that covered it built a real BLEManager and called seedDemoData(showTour: false).
    // That reaches publishDetections -> writeWidgetSummary, which writes today's count, the last
    // detection, the connected flag and the per-category breakdown into the SHARED APP GROUP
    // defaults (suite group.tech.beacons.app) that the home-screen widget reads. So running the
    // unit suite left sample numbers on the user's real widget. exitDemo() does not undo that
    // reliably either: it is a restore driven off state the manager reloads asynchronously, and
    // it is dropped outright once the manager deallocates. A test must not be able to change
    // what a home screen displays, and it must not depend on a race to clean up after itself.
    //
    // The two clean ways to test it without that side effect are both changes to BLEManager
    // rather than to this file (there may be others; these are the ones that keep the guarantee
    // asserted at its source):
    //   * the sample rows and their stamping factored out into a pure builder (rows in, rows +
    //     stamps out) that the seed then installs, so the guarantee can be asserted with no
    //     manager at all; or
    //   * the widget sink behind writeWidgetSummary made injectable, so a test can hand the
    //     manager one that goes nowhere.
    // Neither exists yet, so the honest state is: this rule currently has no automated test.
    // Restoring `age(Date(), Date()) == .fresh` in its place would NOT close the gap - it only
    // re-states the fresh boundary testFreshTierIsUnderFiveMinutes already owns, and it would go
    // on passing with the seed's stamping deleted, which is worse than an admitted gap.
}
