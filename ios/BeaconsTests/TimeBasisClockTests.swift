import XCTest
@testable import Beacons

/// The contribution-window clock is a fixed 24-hour string. This pins the format against the
/// "h:mm a" DateFormatter the code shipped with until 2026-09-02 (which fails both assertions
/// with "2:05 PM" / "2:05 AM"). It does NOT exercise the device's 12/24-hour preference: the
/// AppleICUForce12HourTime / AppleICUForce24HourTime defaults are ignored by a DateFormatter
/// inside a simulator test process (checked 2026-09-03), so a clock() that kept "HH:mm" but lost
/// its en_US_POSIX pin would pass here and only misbehave on a phone with 12-hour time forced.
/// The pin lives in TimeBasisCopy.fixed, whose doc explains that rewrite. Android twin:
/// ClockTimeTextTest.
final class TimeBasisClockTests: XCTestCase {
    private func local(_ hour: Int, _ minute: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 9; c.day = 2; c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    func testClockIsFixedTwentyFourHour() {
        XCTAssertEqual(TimeBasisCopy.clock(local(14, 5)), "14:05")
        XCTAssertEqual(TimeBasisCopy.clock(local(2, 5)), "02:05")
    }
}
