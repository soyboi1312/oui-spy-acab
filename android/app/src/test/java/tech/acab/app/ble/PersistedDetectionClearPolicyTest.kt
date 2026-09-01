package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PersistedDetectionClearPolicyTest {
    @Test
    fun `reset pending is established before a retry can observe the tombstone`() {
        val events = mutableListOf<String>()
        val armed = beginPersistedDetectionClearBoundary(
            markVisibleResetPending = { events += "reset-pending" },
            invalidateDecodedLoads = { events += "load-invalidated" },
            advanceWriteGeneration = { events += "generation-advanced" },
            armTombstone = { events += "tombstone-visible"; true },
        )

        assertTrue(armed)
        assertEquals(
            listOf("reset-pending", "load-invalidated", "generation-advanced", "tombstone-visible"),
            events,
        )
        assertTrue(events.indexOf("reset-pending") < events.indexOf("tombstone-visible"))
    }

    @Test
    fun `durable clear intent survives process death and blocks a reload`() {
        var storedPending = false
        fun tombstone() = PersistedDetectionClearTombstone(
            readStored = { storedPending },
            storePending = { storedPending = true; true },
            removeStored = { storedPending = false; true },
        )

        assertTrue(tombstone().arm())
        val relaunched = tombstone()
        assertTrue(relaunched.isPending)
        assertTrue(relaunched.retire())
        assertFalse(relaunched.isPending)
    }

    @Test
    fun `visible clear requires a tombstone or confirmed synchronous absence`() {
        assertEquals(
            PersistedDetectionClearCommit.DURABLE_TOMBSTONE,
            preparePersistedDetectionClear(armTombstone = { true }, deleteSynchronously = { false }),
        )
        assertEquals(
            PersistedDetectionClearCommit.CONFIRMED_DELETION,
            preparePersistedDetectionClear(armTombstone = { false }, deleteSynchronously = { true }),
        )
        assertEquals(
            PersistedDetectionClearCommit.UNAVAILABLE,
            preparePersistedDetectionClear(armTombstone = { false }, deleteSynchronously = { false }),
        )

        var visibleRows = 3
        val failed = preparePersistedDetectionClear(
            armTombstone = { false },
            deleteSynchronously = { false },
        )
        if (persistedDetectionClearMayResetMemory(failed)) visibleRows = 0
        assertFalse(persistedDetectionClearMayResetMemory(failed))
        assertEquals(3, visibleRows)
    }

    @Test
    fun `deletion succeeds only after absence is observed`() {
        var exists = true
        assertTrue(performConfirmedPersistedDetectionDeletion(
            fileExists = { exists },
            remove = { exists = false },
        ))

        exists = true
        assertFalse(performConfirmedPersistedDetectionDeletion(
            fileExists = { exists },
            remove = { /* failed no-op */ },
        ))

        exists = true
        assertTrue(performConfirmedPersistedDetectionDeletion(
            fileExists = { exists },
            remove = { exists = false; error("late error after delete") },
        ))
    }

    @Test
    fun `pre-clear snapshot cannot recreate evidence after deletion`() {
        var generation = 7L
        val capturedGeneration = generation
        var fileExists = true

        generation++
        fileExists = false
        if (persistedDetectionSnapshotMayWrite(
                capturedGeneration,
                generation,
                clearPending = false,
            )) fileExists = true

        assertFalse(fileExists)
        assertFalse(persistedDetectionSnapshotMayWrite(generation, generation, clearPending = true))
        assertTrue(persistedDetectionSnapshotMayWrite(generation, generation, clearPending = false))
    }

    @Test
    fun `confirmed deletion cannot retire barrier before visible reset`() {
        assertFalse(persistedDetectionClearMayRetire(
            deletionConfirmed = false,
            visibleResetPending = false,
        ))
        assertFalse(persistedDetectionClearMayRetire(
            deletionConfirmed = true,
            visibleResetPending = true,
        ))
        assertFalse(persistedDetectionClearMayRetire(
            deletionConfirmed = true,
            visibleResetPending = false,
            initiatingResetInProgress = true,
        ))
        assertTrue(persistedDetectionClearMayRetire(
            deletionConfirmed = true,
            visibleResetPending = false,
        ))
        assertFalse(persistedDetectionClearRetryMayOwnCompletion(
            initiatingResetInProgress = true,
        ))
        assertTrue(persistedDetectionClearRetryMayOwnCompletion(
            initiatingResetInProgress = false,
        ))
    }

    @Test
    fun `clear invalidates a decoded load before it can repopulate memory`() {
        val gate = PersistedDetectionLoadGate()
        val decodedLoad = gate.beginLoad()
        gate.invalidate()
        assertFalse(gate.accepts(decodedLoad))

        val replacementLoad = gate.beginLoad()
        assertTrue(gate.accepts(replacementLoad))
        assertFalse(gate.accepts(decodedLoad))
    }

    @Test
    fun `failed tombstone retirement stays pending and is rearmed`() {
        var storedPending = true
        var rearmAttempts = 0
        val tombstone = PersistedDetectionClearTombstone(
            readStored = { storedPending },
            storePending = { rearmAttempts++; storedPending = true; true },
            removeStored = { false },
        )

        assertFalse(tombstone.retire())
        assertTrue(tombstone.isPending)
        assertEquals(1, rearmAttempts)
    }

    @Test
    fun `tombstone storage exceptions fail closed without crashing`() {
        val armFailure = PersistedDetectionClearTombstone(
            readStored = { false },
            storePending = { error("preferences unavailable") },
            removeStored = { error("preferences unavailable") },
        )
        assertFalse(armFailure.arm())
        assertTrue(armFailure.isPending)

        var initiallyStored = true
        val retireFailure = PersistedDetectionClearTombstone(
            readStored = { initiallyStored },
            storePending = { initiallyStored = true; true },
            removeStored = { error("preferences unavailable") },
        )
        assertFalse(retireFailure.retire())
        assertTrue(retireFailure.isPending)
    }
}
