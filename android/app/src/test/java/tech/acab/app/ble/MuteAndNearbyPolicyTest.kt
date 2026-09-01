package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MuteAndNearbyPolicyTest {
    private val base = IgnoredDevice(mac = "aa:bb:cc:dd:ee:ff", label = "camera")

    @Test
    fun onlyUnscopedMutesAreBoardBacked() {
        assertTrue(isBoardBackedMute(base))
        assertFalse(isBoardBackedMute(base.copy(expiresAt = 10_000L)))
        assertFalse(isBoardBackedMute(base.copy(latitude = 1.0, longitude = 2.0)))
        // A partially decoded/corrupt location rule must fail closed instead of becoming permanent.
        assertFalse(isBoardBackedMute(base.copy(latitude = 1.0)))
    }

    @Test
    fun nearbyWindowMatchesStatusBoundary() {
        val now = 1_000_000L
        assertTrue(lastSeenIsNearby(now, now))
        assertTrue(lastSeenIsNearby(now - ACTIVE_NEARBY_WINDOW_MS, now))
        assertFalse(lastSeenIsNearby(now - ACTIVE_NEARBY_WINDOW_MS - 1, now))
        assertFalse(lastSeenIsNearby(now + 1, now))
        assertFalse(lastSeenIsNearby(null, now))
    }

    @Test
    fun placeMuteRequiresFreshFixAndDistinguishesOutside() {
        val here = base.copy(latitude = 37.0, longitude = -122.0, radiusMeters = 50.0)
        val accurate = MutePosition(37.0 to -122.0, horizontalAccuracyMeters = 5.0)
        assertEquals(
            MuteRuleStatus.CURRENT_LOCATION_REQUIRED,
            evaluateMuteRule(here, 1_000L, null) { _, _ -> error("distance must not run") },
        )
        assertEquals(
            MuteRuleStatus.ACTIVE,
            evaluateMuteRule(here, 1_000L, accurate) { _, _ -> 49.9 },
        )
        assertEquals(
            MuteRuleStatus.OUTSIDE_RADIUS,
            evaluateMuteRule(here, 1_000L, accurate) { _, _ -> 50.1 },
        )
        assertEquals(
            MuteRuleStatus.INVALID_PLACE,
            evaluateMuteRule(base.copy(latitude = 37.0), 1_000L, accurate) { _, _ -> 0.0 },
        )
    }

    @Test
    fun hereMuteRequiresAccuracyNoWiderThanItsRuleRadius() {
        val coord = 37.0 to -122.0
        assertTrue(positionSupportsHere(MutePosition(coord, 50.0), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, 50.001), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, -1.0), radiusMeters = 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, Double.POSITIVE_INFINITY), 50.0))
        assertFalse(positionSupportsHere(MutePosition(coord, null), radiusMeters = 50.0))

        val rule = base.copy(latitude = coord.first, longitude = coord.second, radiusMeters = 50.0)
        assertEquals(
            MuteRuleStatus.CURRENT_LOCATION_REQUIRED,
            evaluateMuteRule(rule, 1_000L, MutePosition(coord, 50.001)) { _, _ ->
                error("distance must not run for an imprecise fix")
            },
        )
    }

    @Test
    fun historicalWatchedTypeDoesNotBypassCurrentMute() {
        val mac = base.mac
        assertFalse(activeProjectionIncludes(
            mac, isCurrentlyWatched = false, activeIgnoredMacs = setOf(mac)))
        assertTrue(activeProjectionIncludes(
            mac, isCurrentlyWatched = true, activeIgnoredMacs = setOf(mac)))
        assertTrue(activeProjectionIncludes(
            mac, isCurrentlyWatched = false, activeIgnoredMacs = emptySet()))
    }

    @Test
    fun boardOnlyMuteCountDisclosesOnlyTheUnrepresentedRemainder() {
        assertEquals(4, unrepresentedBoardRuleCount(boardCount = 4, localBoardBackedCount = 0))
        assertEquals(2, unrepresentedBoardRuleCount(boardCount = 4, localBoardBackedCount = 2))
        assertEquals(0, unrepresentedBoardRuleCount(boardCount = 1, localBoardBackedCount = 2))
    }

    @Test
    fun sampleModeCannotMutateThePersistedLogOrSeenWatermark() {
        assertFalse(persistedLogMutationAllowed(demoMode = true))
        assertTrue(persistedLogMutationAllowed(demoMode = false))
    }

    @Test
    fun emptyPhoneNeverErasesUnknownBoardWithoutExplicitClear() {
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(0, 4, false))
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(0, null, false))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, 4, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, null, true))
        assertEquals(BoardIgnoreSyncAction.ACK_CLEAR, boardIgnoreSyncAction(0, 0, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_LIST, boardIgnoreSyncAction(2, 4, false))
        assertEquals(BoardIgnoreSyncAction.NONE, boardIgnoreSyncAction(2, 2, false))
    }

    @Test
    fun pendingClearRetriesUntilBoardStatusAcknowledgesZero() {
        // The policy is shared by ignore and watch lists: a nonzero/unknown count means the
        // destructive clear must be retried, while zero is the only acknowledgement.
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, 1, true))
        assertEquals(BoardIgnoreSyncAction.PUSH_CLEAR, boardIgnoreSyncAction(0, null, true))
        assertEquals(BoardIgnoreSyncAction.ACK_CLEAR, boardIgnoreSyncAction(0, 0, true))
    }

    @Test
    fun sampleManagedEditsNeverPersist() {
        assertFalse(managedListPersistenceAllowed(demoMode = true))
        assertTrue(managedListPersistenceAllowed(demoMode = false))
    }

    @Test
    fun exactMacIndexNormalizesOnceForConstantTimeIngestLookup() {
        val rules = (0 until 256).map { i ->
            IgnoredDevice(
                mac = "AA:BB:CC:DD:${(i / 256).toString(16).padStart(2, '0')}:" +
                    (i % 256).toString(16).padStart(2, '0'),
                label = "rule $i",
            )
        }
        val index = indexIgnoredDevices(rules)
        assertEquals(256, index.size)
        assertEquals("rule 255", index["aa:bb:cc:dd:00:ff"]?.label)
    }
}
