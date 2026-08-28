import XCTest
import CoreLocation
@testable import Beacons

/// Geometry for the map's ring-peek cue: which known-ALPR rings a rendered detection pin is
/// standing on, so those rings draw large enough to peek out from under the pin.
///
/// WHY THIS HAS A TEST. The cue carries one fact and it is the most useful one the map can state:
/// "this live hit is at a camera somebody already mapped" versus "this live hit is somewhere
/// nobody has mapped". Both readings look identical if the threshold drifts - too tight and a real
/// match never peeks, too loose and the camera down the block claims the hit - and neither failure
/// is visible in a screenshot. The threshold also has to be the SAME NUMBER on Android, which is
/// exactly the shape of divergence this project has been bitten by before (see ALPRDatasetTests).
///
/// EXACTLY WHAT IS SHARED WITH ANDROID: the 25 m match radius below, and the "rendered pins only,
/// never count bubbles" rule. The vectors are built in code from metres-per-degree, so the Android
/// suite can carry the same offsets without a data file.
///
/// WHAT IS NOT SHARED: the enlarged DIAMETER. The rule is shared - the rim has to visibly clear the
/// pin's own artwork, glow included, with a readable gap - but the two platforms draw different
/// pins, so each derives its own number from its own artwork (iOS 48pt off a 28pt disc in a 6pt
/// shadow; Android 49dp off a 41dp pulse ring). Do NOT "fix" one to match the
/// other: a matched number here would mean one of the two rims is wrong on screen.
final class AlprRingPeekTests: XCTestCase {

    // San Diego, the app's own fallback region centre.
    private let base = CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)
    private var mPerDegLat: Double { 111_320 }
    private var mPerDegLon: Double { 111_320 * cos(32.7157 * .pi / 180) }

    private func north(_ metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude + metres / mPerDegLat, longitude: base.longitude)
    }

    private func east(_ metres: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: base.latitude, longitude: base.longitude + metres / mPerDegLon)
    }

    /// The match radius Android has to match. A change here is a cross-platform change.
    func testMatchRadiusIsTheCrossPlatformContract() {
        XCTAssertEqual(ALPRRingPeek.radiusMeters, 25)
    }

    /// The enlarged diameter is iOS's OWN number, not a shared one, so what is asserted here is the
    /// RULE it has to satisfy: the rim must clear the pin's whole visual footprint with a readable
    /// gap. MapPin is a 28pt disc under .shadow(radius: 6), so the pin's tinted glow reaches
    /// radius 14 + 6 = 20pt - and in the headline case (a live ALPR hit) that glow is flockTone,
    /// the very tone of a confirmed ring, so a rim inside it is not tight, it is invisible.
    /// ALPRDot strokes with strokeBorder (inside the frame), so the rim's INNER edge sits at
    /// diameter/2 - 2.2. The 36pt first cut put that at 15.8pt, more than 4pt inside the glow.
    func testPeekDiameterClearsTheWholePinFootprint() {
        let pinGlowRadius: CGFloat = 28 / 2 + 6       // disc radius + shadow spread
        let rimInnerEdge = ALPRRingPeek.diameter / 2 - 2.2   // ALPRDot's strokeBorder line width
        XCTAssertGreaterThan(rimInnerEdge, pinGlowRadius + 1.5,
                             "the peek rim has to stand off the pin's glow by a readable gap")
        // And it stays a ring around a pin, not a second blob: comfortably under the ping ring's
        // full extent (28pt scaled to 1.9), which sweeps past it and fades out.
        XCTAssertLessThan(ALPRRingPeek.diameter, 28 * 1.9)
    }

    /// A pin at the mapped coordinate, and a pin inside the radius, both peek. The band bucketing
    /// must not lose either one.
    func testPinOnOrNearACameraPeeks() {
        let rings = [base, north(20), east(20)]
        XCTAssertEqual(ALPRRingPeek.matches(rings: rings, pins: [base]), [true, true, true])
    }

    /// The next camera down the block does NOT get to claim the hit.
    func testPinBeyondTheRadiusDoesNotPeek() {
        let rings = [north(30), east(40), CLLocationCoordinate2D(latitude: 0, longitude: 0)]
        XCTAssertEqual(ALPRRingPeek.matches(rings: rings, pins: [base]), [false, false, false])
    }

    /// Only the matched ring grows: the unmatched ones stay at their resting size.
    func testOnlyMatchedRingsAreFlagged() {
        let rings = [north(300), base, east(300)]
        XCTAssertEqual(ALPRRingPeek.matches(rings: rings, pins: [base]), [false, true, false])
    }

    /// Longitude degrees shrink towards the poles. A 20 m offset EAST has to keep matching at high
    /// latitude, where a naive degrees-only comparison would silently stop finding anything.
    func testLongitudeScalingHoldsAtHighLatitude() {
        let anchorage = CLLocationCoordinate2D(latitude: 61.2181, longitude: -149.9003)
        let mPerDegLonHere = 111_320 * cos(anchorage.latitude * .pi / 180)
        let near = CLLocationCoordinate2D(latitude: anchorage.latitude,
                                          longitude: anchorage.longitude + 20 / mPerDegLonHere)
        let far = CLLocationCoordinate2D(latitude: anchorage.latitude,
                                         longitude: anchorage.longitude + 40 / mPerDegLonHere)
        XCTAssertEqual(ALPRRingPeek.matches(rings: [near, far], pins: [anchorage]), [true, false])
    }

    /// The pins are bucketed into latitude bands to keep the pass cheap. A ring and its pin
    /// landing in ADJACENT bands is the case that a one-band-only search would drop, and it is
    /// the common case: the band edge falls wherever it falls.
    func testMatchSurvivesABandBoundary() {
        // Put the pin just above a band edge and the rings just below it, still well inside 25 m.
        let edge = (ALPRRingPeek.radiusMeters / 111_320) * 1_000
        let pin = CLLocationCoordinate2D(latitude: edge + 0.5 / 111_320, longitude: 0)
        let rings = [CLLocationCoordinate2D(latitude: edge - 0.5 / 111_320, longitude: 0),
                     CLLocationCoordinate2D(latitude: edge - 20.0 / 111_320, longitude: 0)]
        XCTAssertEqual(ALPRRingPeek.matches(rings: rings, pins: [pin]), [true, true])
    }

    /// Both sides of the match are optional layers: the ALPR layer can be off and the map can hold
    /// no located pins. Neither is an error, and the result stays parallel to `rings`.
    func testEmptyInputsAreNotAnError() {
        XCTAssertEqual(ALPRRingPeek.matches(rings: [], pins: [base]), [])
        XCTAssertEqual(ALPRRingPeek.matches(rings: [base, north(20)], pins: []), [false, false])
    }

    /// A corrupt cache row or a bad fix must degrade to "no match", never trap converting a NaN or
    /// an out-of-range double into a band index.
    func testNonFiniteCoordinatesDegradeToNoMatch() {
        let bad = CLLocationCoordinate2D(latitude: .nan, longitude: .nan)
        let wild = CLLocationCoordinate2D(latitude: 9_999, longitude: 9_999)
        XCTAssertEqual(ALPRRingPeek.matches(rings: [bad, wild, base], pins: [base]),
                       [false, false, true])
        XCTAssertEqual(ALPRRingPeek.matches(rings: [base], pins: [bad, wild]), [false])
    }
}
