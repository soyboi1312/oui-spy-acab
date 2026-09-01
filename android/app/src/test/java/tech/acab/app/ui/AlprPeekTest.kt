package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT

/** Ring-peek proximity: which mapped-ALPR rings draw wide because a live detection pin is
 *  standing on them. The rendering side needs a device, but the decision does not, and it is the
 *  part that can quietly go wrong (a missing cos(lat) makes every ring at high latitude peek, and
 *  a band index that only searches its own bucket drops matches that straddle a band edge).
 *
 *  WHAT IS SHARED WITH iOS: the 25 m match radius, and the "rendered pins only, never count
 *  bubbles" rule. The enlarged ring's SIZE is not shared, on purpose (see rememberAlprMarker):
 *  each platform derives it from its own pin artwork. See AlprRingPeekTests.swift. */
class AlprPeekTest {

    /** Metres to degrees of latitude, the same constant the helper uses. */
    private fun deg(meters: Double) = meters / 111_320.0

    private fun bands(vararg pins: Double) = AlprPeekBands(pins)

    /** The one number that has to be identical on both platforms. A change here is a
     *  cross-platform change: iOS asserts the same 25 in ALPRRingPeek.radiusMeters. */
    @Test
    fun matchRadiusIsTheCrossPlatformContract() {
        assertEquals(25.0, ALPR_PEEK_RADIUS_M, 0.0)
    }

    @Test
    fun noPinsMeansNoPeek() {
        val empty = bands()
        assertTrue(empty.isEmpty)
        assertFalse(empty.matches(34.0, -118.0))
    }

    @Test
    fun aPinOnTheNodePeeks() {
        assertTrue(bands(34.0, -118.0).matches(34.0, -118.0))
    }

    @Test
    fun latitudeOffsetsRespectTheRadius() {
        // ~16.7 m north: the sighting and the pole it is on.
        assertTrue(bands(34.0 + deg(16.7), -118.0).matches(34.0, -118.0))
        // ~33.4 m north: far enough that claiming this camera would be a guess.
        assertFalse(bands(34.0 + deg(33.4), -118.0).matches(34.0, -118.0))
        // Symmetric: south of the node reads the same as north of it.
        assertTrue(bands(34.0 - deg(16.7), -118.0).matches(34.0, -118.0))
        assertFalse(bands(34.0 - deg(33.4), -118.0).matches(34.0, -118.0))
    }

    @Test
    fun longitudeOffsetsShrinkWithLatitude() {
        // The SAME longitude delta is 33.4 m at the equator and half that at 60 degrees, because
        // meridians converge. Without the cos(lat) factor the second case would read as 33.4 m
        // too and a real match at high latitude would be dropped.
        val dLon = deg(33.4)
        assertFalse(bands(0.0, 10.0 + dLon).matches(0.0, 10.0))
        assertTrue(bands(60.0, 10.0 + dLon).matches(60.0, 10.0))
    }

    @Test
    fun anyPinInTheSetCounts() {
        val pins = bands(
            35.0, -118.0,                       // far north, a band the ring never looks in
            34.0, -117.5,                       // same latitude band, far east
            34.0 + deg(10.0), -118.0,           // the match
        )
        assertTrue(pins.matches(34.0, -118.0))
        assertFalse(pins.matches(34.0, -119.0))
    }

    /** The pins are bucketed into radius-tall latitude bands to keep the pass cheap, so the search
     *  has to read the neighbouring bands too. A ring and the pin standing on it landing either
     *  side of a band edge is not an edge case: the edge falls wherever it falls. Mirrors iOS
     *  testMatchSurvivesABandBoundary. */
    @Test
    fun matchSurvivesABandBoundary() {
        val edge = deg(25.0) * 1_000            // an exact band boundary, 1000 bands up
        val pin = bands(edge + deg(0.5), 0.0)
        assertTrue(pin.matches(edge - deg(0.5), 0.0))     // 1 m apart, one band apart
        assertTrue(pin.matches(edge - deg(20.0), 0.0))    // 20.5 m apart, still inside the radius
        assertFalse(pin.matches(edge - deg(30.0), 0.0))   // 30.5 m: outside, band edge or not
    }

    /** A corrupt cache row or a bad fix must degrade to "no match", never blow up turning a NaN or
     *  a wild double into a band index. Mirrors iOS testNonFiniteCoordinatesDegradeToNoMatch. */
    @Test
    fun unusableCoordinatesDegradeToNoMatch() {
        val pin = bands(34.0, -118.0)
        assertFalse(pin.matches(Double.NaN, Double.NaN))
        assertFalse(pin.matches(9_999.0, 9_999.0))
        assertTrue(pin.matches(34.0, -118.0))             // the good ring still matches

        // Same on the pin side: garbage pins are dropped, and a good one beside them still counts.
        assertTrue(bands(Double.NaN, 0.0, 9_999.0, 9_999.0).isEmpty)
        assertFalse(bands(Double.NaN, 0.0).matches(34.0, -118.0))
        assertTrue(bands(Double.POSITIVE_INFINITY, 0.0, 34.0, -118.0).matches(34.0, -118.0))
    }

    @Test
    fun aTrailingHalfPairIsIgnoredNotRead() {
        // The array is built by the map's pin pass; a truncated one must not read past its end.
        assertTrue(bands(34.0, -118.0, 34.0).matches(34.0, -118.0))
        assertTrue(bands(34.0).isEmpty)
        assertFalse(bands(34.0).matches(34.0, -118.0))
    }

    /** The enlarged rim is a sighted-only cue, so the info window (and TalkBack reading it out)
     *  has to carry the same fact in words. iOS appends the equivalent sentence to the ring's
     *  VoiceOver label. */
    @Test
    fun peekCopySaysWhatWasHeardWithoutClaimingVerification() {
        val resting = alprMarkerText(1, "Flock Safety")
        val peeked = alprMarkerText(1, "Flock Safety", peek = true)

        // The TITLE describes the dataset row, which a live detection nearby does not change.
        assertEquals(resting.first, peeked.first)
        // The tier body and the source credit both survive; the peek sentence lands between them.
        // The body sheds its "not a live detection" clause, which would contradict that sentence.
        assertTrue(peeked.second, peeked.second.startsWith("a mapped location ·"))
        assertTrue(peeked.second, peeked.second.endsWith("DeFlock / OSM ODbL"))
        assertTrue(peeked.second, peeked.second.contains(ALPR_PEEK_SNIPPET))
        // ...and a resting ring says none of it.
        assertFalse(resting.second, resting.second.contains(ALPR_PEEK_SNIPPET))
        assertEquals("a mapped location, not a live detection · DeFlock / OSM ODbL", resting.second)

        // A live detection at a mapped location is not proof that the mapped camera is really
        // there, that anybody checked it, or that the device we heard is it. Same contract the
        // resting copy has always had.
        for (tier in listOf(0, 1, 2, ALPR_TIER_LEGACY_FORMAT, 255)) {
            val wide = alprMarkerText(tier, "Flock Safety", peek = true)
            for (part in listOf(wide.first, wide.second)) {
                assertFalse(part, part.contains("verified", ignoreCase = true))
                assertFalse(part, part.contains("confirmed", ignoreCase = true))
                assertFalse(part, part.contains("proof", ignoreCase = true))
            }
            // A peeking ring must never carry both claims at once. The resting body denies a live
            // detection; the peek sentence reports one. Emitting both in one string reads as a
            // contradiction to anyone who tapped the ring, and to TalkBack that reads it aloud.
            assertTrue(wide.second, wide.second.contains(ALPR_PEEK_SNIPPET))
            assertFalse(wide.second, wide.second.contains("not a live detection"))

            // Dropping that clause is the ONLY body change the peek makes. The title, the credit,
            // and every other tier word stay put.
            val rest = alprMarkerText(tier, "Flock Safety")
            assertEquals(rest.first, wide.first)
            assertEquals(
                rest.second.replace(", not a live detection", "").replace("unknown attribution tier, ", "unknown attribution tier "),
                wide.second.replace(" · $ALPR_PEEK_SNIPPET", ""),
            )
        }
    }
}
