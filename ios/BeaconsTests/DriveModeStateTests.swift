import XCTest
@testable import Beacons

final class DriveModeStateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "tech.beacons.tests.drive-mode.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingChoiceIsEnabledByDefault() {
        XCTAssertNil(DriveModeState.storedChoice(in: defaults))
        XCTAssertTrue(DriveModeState.wanted(in: defaults))
    }

    func testExplicitOffOverridesDefault() {
        DriveModeState.setWanted(false, in: defaults)
        XCTAssertFalse(DriveModeState.wanted(in: defaults))
    }
}
