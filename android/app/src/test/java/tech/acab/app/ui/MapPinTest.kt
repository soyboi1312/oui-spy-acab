package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test
import androidx.compose.ui.graphics.Color
import tech.acab.app.ui.theme.Acab
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType

/**
 * The two pure decisions behind map pin presentation: which rows share a pin, and how old a pin
 * is allowed to look. Both are shared rules with iOS, so the numbers in here are a cross-platform
 * contract and a change to any of them is a change on both phones.
 *
 * Neither decision needs a map, a bitmap or a device, and both are the part that can quietly go
 * wrong: a priority table in the wrong order buries a body cam under an older nearby device, and
 * a missing-timestamp fallback that lands on FRESH paints yesterday's persisted pin as a live hit.
 */
class MapPinTest {

    private var seq = 0

    private fun row(type: DeviceType, mac: String = "m${seq++}") = Detection(
        type = type,
        source = 0,
        method = 0,
        confidence = 1,
        mac = mac,
        rssi = -50,
        name = null,
        rid = null,
        detail = null,
        lat = null,
        lon = null,
        pilotLat = null,
        pilotLon = null,
        altitude = null,
        speedH = null,
        speedV = null,
        heading = null,
        heightAGL = null,
        pilotAlt = null,
        ridStatus = null,
        count = 1,
        isNew = true,
        gpsAgeSec = null,
        hist = false,
        seq = 0L,
        at = 0L,
        approx = false,
    )

    /** Group [items] with per-row coordinates and stamps supplied by id. */
    private fun group(
        items: List<Detection>,
        coords: Map<String, Pair<Double, Double>>,
        seen: Map<String, Long> = emptyMap(),
    ) = groupPinsBySpot(items, { coords[it.id] }, { seen[it.id] })

    // ---- the shared numbers -------------------------------------------------------------

    /** These three are the cross-platform contract. iOS asserts the same values. */
    @Test
    fun theSharedConstantsAreTheCrossPlatformContract() {
        assertEquals(1e-5, PIN_GROUP_EPSILON_DEG, 0.0)
        assertEquals(5L * 60_000L, PIN_FRESH_MAX_MS)
        assertEquals(60L * 60_000L, PIN_RECENT_MAX_MS)
    }

    // ---- grouping tolerance -------------------------------------------------------------

    /** The case the whole feature exists for: everything logged from one standing position
     *  carries the identical phone fix. */
    @Test
    fun identicalCoordinatesAreOneGroup() {
        val a = row(DeviceType.BODY_CAM)
        val b = row(DeviceType.FLOCK_CAMERA)
        val here = 34.0000053 to -117.0000053
        val groups = group(listOf(a, b), mapOf(a.id to here, b.id to here))

        assertEquals(1, groups.size)
        assertEquals(2, groups.single().members.size)
        assertEquals(here.first, groups.single().lat, 0.0)
        assertEquals(here.second, groups.single().lon, 0.0)
    }

    /** Sub-metre drift inside the tolerance still lands on one pin. */
    @Test
    fun aTinyOffsetInsideTheToleranceStaysInTheGroup() {
        val a = row(DeviceType.BODY_CAM)
        val b = row(DeviceType.BODY_CAM)
        val groups = group(
            listOf(a, b),
            mapOf(
                a.id to (34.0000053 to -117.0000053),
                // +2e-6 degrees on each axis, a fifth of the tolerance
                b.id to (34.0000073 to -117.0000073),
            ),
        )
        assertEquals(1, groups.size)
        assertEquals(2, groups.single().members.size)
    }

    /** Genuinely separate spots stay separate pins, in the order they arrived. */
    @Test
    fun separateSpotsStaySeparatePins() {
        val a = row(DeviceType.BODY_CAM)
        val b = row(DeviceType.BODY_CAM)
        val groups = group(
            listOf(a, b),
            mapOf(
                a.id to (34.0 to -117.0),
                // ~110 m apart, far outside the tolerance
                b.id to (34.001 to -117.0),
            ),
        )
        assertEquals(2, groups.size)
        assertEquals(listOf(a, b), groups.map { it.lead })
    }

    /** A group of one is the untouched single pin: its own member, at its own coordinate. */
    @Test
    fun aGroupOfOneKeepsItsMemberAndItsExactCoordinate() {
        val a = row(DeviceType.FLOCK_RAVEN)
        val at = 32.7157 to -117.1611
        val g = group(listOf(a), mapOf(a.id to at)).single()

        assertEquals(1, g.members.size)
        assertSame(a, g.lead)
        assertEquals(at.first, g.lat, 0.0)
        assertEquals(at.second, g.lon, 0.0)
    }

    /** A row the map cannot place produces no pin at all, and does not join anyone else's. */
    @Test
    fun anUnplaceableRowIsDropped() {
        val placed = row(DeviceType.BODY_CAM)
        val unplaced = row(DeviceType.BODY_CAM)
        val groups = group(
            listOf(unplaced, placed),
            mapOf(placed.id to (34.0 to -117.0)),
        )
        assertEquals(1, groups.size)
        assertEquals(listOf(placed), groups.single().members)
    }

    // ---- which rows reach the grouper at all --------------------------------------------

    /** There are exactly TWO map treatments and the split is [clusterable] alone: a type either
     *  grid-clusters into a count bubble, or it pins individually and therefore takes part in
     *  same-spot grouping. No third set, so no type can fall between them and draw nothing.
     *
     *  DRONE is on the grouped side. A drone PIN anchors nothing: the flight path, tether, launch
     *  glyph and operator marker are drawn from the drone rows themselves, not from whichever pin
     *  won the spot, so absorbing a drone pin costs no artwork. Keeping drones out cost the drone
     *  its tap, because a co-located infra pin simply covered it. */
    @Test
    fun theIndividuallyPinnedTypesIncludingDronesReachTheGrouper() {
        for (t in listOf(DeviceType.WATCHED, DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN,
                         DeviceType.BODY_CAM, DeviceType.DRONE, DeviceType.UNKNOWN)) {
            assertFalse("$t pins individually, so it groups", clusterable(t))
        }
        for (t in listOf(DeviceType.NEARBY_DEVICE, DeviceType.TRACKER, DeviceType.GLASSES,
                         DeviceType.NETWORK_CAMERA)) {
            assertTrue("$t belongs to the clustered mass", clusterable(t))
        }
    }

    /** The reachability fix, end to end: a drone sharing a body cam's spot is a MEMBER of that
     *  pin's group, so the badge sheet lists it and it can be opened. Before this it drew its own
     *  pin, which the body cam's pin was then drawn over, and a covered pin takes no taps. */
    @Test
    fun aDroneJoinsASameSpotGroupAndStaysReachable() {
        val drone = row(DeviceType.DRONE)
        val bodyCam = row(DeviceType.BODY_CAM)
        val here = 34.0000053 to -117.0000053
        val g = group(listOf(drone, bodyCam), mapOf(drone.id to here, bodyCam.id to here)).single()

        assertSame(bodyCam, g.lead)
        assertEquals(listOf(bodyCam, drone), g.members)
    }

    /** A drone outranks the unclassified rest, so it leads a spot it shares with one. */
    @Test
    fun aDroneLeadsAgainstALowerPriorityNeighbour() {
        val drone = row(DeviceType.DRONE)
        val other = row(DeviceType.UNKNOWN)
        val here = 34.0000053 to -117.0000053
        val g = group(listOf(other, drone), mapOf(other.id to here, drone.id to here)).single()

        assertSame(drone, g.lead)
    }

    /** A drone alone at its coordinate is a group of one: its own pin, its own place, no badge,
     *  which is what "a lone drone renders exactly as it did before" means at this layer. */
    @Test
    fun aLoneDroneIsAGroupOfOneAtItsOwnCoordinate() {
        val drone = row(DeviceType.DRONE)
        val at = 32.7157 to -117.1611
        val g = group(listOf(drone), mapOf(drone.id to at)).single()

        assertSame(drone, g.lead)
        assertEquals(1, g.members.size)
        assertEquals(at.first, g.lat, 0.0)
        assertEquals(at.second, g.lon, 0.0)
    }

    // ---- priority -----------------------------------------------------------------------

    /** The stated order: watched device, ALPR, Raven, body cam, drone, then anything else.
     *
     *  DRONE's rank is live, not decorative: drone rows reach the grouper, so this is what decides
     *  whether a drone or its neighbour draws the shared pin. The table is the cross-platform
     *  contract and iOS keeps `.drone` in its copy too. Asserting the ORDER rather than five
     *  numbers keeps renumbering free and reordering caught. */
    @Test
    fun priorityRunsWatchedAlprRavenBodyCamDroneThenTheRest() {
        val order = listOf(
            DeviceType.WATCHED,
            DeviceType.FLOCK_CAMERA,
            DeviceType.FLOCK_RAVEN,
            DeviceType.BODY_CAM,
            DeviceType.DRONE,
        ).map(::infraPinPriority)
        assertEquals(order.sorted(), order)
        assertEquals(order.distinct(), order)
        // Everything outside the named list shares one rank, below all of them.
        val rest = infraPinPriority(DeviceType.UNKNOWN)
        assertEquals(rest, infraPinPriority(DeviceType.NEARBY_DEVICE))
        assertEquals(true, rest > order.max())
    }

    /** The defect this fixes: the pin drawn for a stacked spot is the one that matters, not
     *  whichever row happened to be added last. Every type that reaches the grouper is in this
     *  feed, drone included. */
    @Test
    fun theHighestPriorityMemberLeadsTheGroup() {
        val unknown = row(DeviceType.UNKNOWN)
        val drone = row(DeviceType.DRONE)
        val bodyCam = row(DeviceType.BODY_CAM)
        val raven = row(DeviceType.FLOCK_RAVEN)
        val alpr = row(DeviceType.FLOCK_CAMERA)
        val watched = row(DeviceType.WATCHED)
        val here = 34.0000053 to -117.0000053
        // Deliberately handed over in the worst order: least important first.
        val feed = listOf(unknown, drone, bodyCam, raven, alpr, watched)
        val g = group(feed, feed.associate { it.id to here }).single()

        assertSame(watched, g.lead)
        assertEquals(listOf(watched, alpr, raven, bodyCam, drone, unknown), g.members)
    }

    // ---- recency tie-break --------------------------------------------------------------

    @Test
    fun equalPriorityBreaksOnTheMostRecentSighting() {
        val older = row(DeviceType.BODY_CAM)
        val newer = row(DeviceType.BODY_CAM)
        val here = 34.0000053 to -117.0000053
        val g = group(
            listOf(older, newer),
            mapOf(older.id to here, newer.id to here),
            mapOf(older.id to 1_000L, newer.id to 9_000L),
        ).single()

        assertSame(newer, g.lead)
        assertEquals(listOf(newer, older), g.members)
    }

    /** Recency only ever breaks a tie. A fresher unclassified row does not outrank a body cam. */
    @Test
    fun recencyNeverOverridesPriority() {
        val bodyCam = row(DeviceType.BODY_CAM)
        val freshOther = row(DeviceType.UNKNOWN)
        val here = 34.0000053 to -117.0000053
        val g = group(
            listOf(freshOther, bodyCam),
            mapOf(bodyCam.id to here, freshOther.id to here),
            mapOf(bodyCam.id to 1_000L, freshOther.id to 9_000L),
        ).single()

        assertSame(bodyCam, g.lead)
    }

    /** An undated row sorts last inside its band: it never outranks one we can date. */
    @Test
    fun anUndatedMemberLosesTheTieBreak() {
        val dated = row(DeviceType.BODY_CAM)
        val undated = row(DeviceType.BODY_CAM)
        val here = 34.0000053 to -117.0000053
        val g = group(
            listOf(undated, dated),
            mapOf(dated.id to here, undated.id to here),
            mapOf(dated.id to 1_000L),
        ).single()

        assertSame(dated, g.lead)
        assertEquals(listOf(dated, undated), g.members)
    }

    /** Ties all the way down keep the feed's own newest-first order. */
    @Test
    fun aFullTieKeepsTheFeedOrder() {
        val first = row(DeviceType.BODY_CAM)
        val second = row(DeviceType.BODY_CAM)
        val here = 34.0000053 to -117.0000053
        val g = group(
            listOf(first, second),
            mapOf(first.id to here, second.id to here),
            mapOf(first.id to 5_000L, second.id to 5_000L),
        ).single()

        assertEquals(listOf(first, second), g.members)
    }

    // ---- the three age tiers ------------------------------------------------------------

    @Test
    fun theThreeAgeTiersSplitAtFiveAndSixtyMinutes() {
        val now = 1_700_000_000_000L
        fun ageAt(msAgo: Long) = pinAge(now - msAgo, now)

        assertEquals(PinAge.FRESH, ageAt(0L))
        assertEquals(PinAge.FRESH, ageAt(PIN_FRESH_MAX_MS - 1))
        // The 5-minute mark itself is RECENT: under five minutes is what may animate.
        assertEquals(PinAge.RECENT, ageAt(PIN_FRESH_MAX_MS))
        assertEquals(PinAge.RECENT, ageAt(30L * 60_000L))
        // The 60-minute mark is still RECENT: OVER an hour is what dims.
        assertEquals(PinAge.RECENT, ageAt(PIN_RECENT_MAX_MS))
        assertEquals(PinAge.STALE, ageAt(PIN_RECENT_MAX_MS + 1))
        assertEquals(PinAge.STALE, ageAt(24L * 60L * 60_000L))
    }

    /** No stamp is not evidence of liveness. RECENT, never FRESH, and never STALE either: we
     *  have not established that the row is old, only that we cannot date it. */
    @Test
    fun aMissingOrZeroStampIsRecentAndNeverFresh() {
        val now = 1_700_000_000_000L
        assertEquals(PinAge.RECENT, pinAge(null, now))
        assertEquals(PinAge.RECENT, pinAge(0L, now))
        assertEquals(PinAge.RECENT, pinAge(-1L, now))
    }

    /** A stamp ahead of the clock stays FRESH, matching the one-sided staleness rule the
     *  detection store already uses: a backward wall-clock step must not age live pins. */
    @Test
    fun aStampAheadOfTheClockStaysFresh() {
        val now = 1_700_000_000_000L
        assertEquals(PinAge.FRESH, pinAge(now + 60_000L, now))
        assertEquals(PinAge.FRESH, pinAge(now + PIN_RECENT_MAX_MS * 2, now))
    }

    // ---- what a marker's own text says --------------------------------------------------

    /** A lone pin carries the bare category it has always carried. */
    @Test
    fun aLonePinKeepsItsBareCategory() {
        assertEquals("ALPR", pinTitle("ALPR", 1))
    }

    /** A grouped title names the count and the category it is drawing. */
    @Test
    fun aGroupedPinSaysHowManyRowsItStandsFor() {
        val title = pinTitle("BODY CAM", 4)
        assertTrue(title, title.contains("4"))
        assertTrue(title, title.contains("BODY CAM"))
    }

    /** The title makes NO claim about age, at any size.
     *
     *  A previous round appended "not heard in the last hour." here for the STALE tier. Nothing
     *  ever presented it: a detection marker's click listener returns true, so osmdroid's default
     *  title InfoWindow never opens, and osmdroid publishes no per-marker accessibility node
     *  either. On Android the non-visual route to a pin's age is the dossier the tap opens, whose
     *  "Last seen" row prints it via relativeAgo (DetailScreen.kt). This test keeps an unrendered
     *  sentence from being added back here. */
    @Test
    fun theTitleNeverClaimsAnAge() {
        for (n in listOf(1, 2, 3, 120)) {
            val title = pinTitle("ALPR", n)
            assertFalse(title, title.contains("not heard"))
            assertFalse(title, title.contains("hour"))
        }
    }

    // ---- what the STALE tier is allowed to do to a tone ---------------------------------

    /** Dim it, never hide it. The stale tone has to move enough to read as a different state,
     *  stay away from the background it is drawn on, and keep the hue ordering that makes a
     *  crimson ALPR pin still look like an ALPR pin. */
    @Test
    fun theStaleToneDimsWithoutHidingOrChangingFamily() {
        val flock = Acab.flockTone
        val dim = dimTone(flock)

        fun lum(c: Color) = 0.299f * c.red + 0.587f * c.green + 0.114f * c.blue
        // Visibly quieter than the live tone.
        assertTrue(lum(dim) < lum(flock) - 0.05f)
        // Still well clear of the map's own background, so the pin never vanishes into it.
        assertTrue(lum(dim) > lum(Acab.bg) + 0.15f)
        // Desaturated, not greyed out: red still leads the channels, as it does in the live tone.
        assertTrue(dim.red > dim.green && dim.red > dim.blue)
        // Fully opaque. A stale pin recedes by tone alone; it is never faded toward the tiles.
        assertEquals(flock.alpha, dim.alpha, 0.0f)
    }
}
