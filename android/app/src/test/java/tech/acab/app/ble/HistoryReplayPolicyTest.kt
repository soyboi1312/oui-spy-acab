package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class HistoryReplayPolicyTest {
    @Test fun cleanDrainMayCheckpointItsHighestReceivedSequence() {
        assertEquals(
            HistoryEndDisposition.COMPLETE,
            historyEndDisposition(received = 100, expected = 100, resyncAttempts = 0, resyncCap = 2),
        )
    }

    @Test fun aWireGapRetriesOnlyWithinThisConnectionsBudget() {
        assertEquals(
            HistoryEndDisposition.RETRY_NOW,
            historyEndDisposition(received = 99, expected = 100, resyncAttempts = 1, resyncCap = 2),
        )
        assertEquals(
            HistoryEndDisposition.DEFER_INCOMPLETE,
            historyEndDisposition(received = 99, expected = 100, resyncAttempts = 2, resyncCap = 2),
        )
    }

    @Test fun lostBeginNeverFinalizesAStaleGenerationEvenForAnEmptyDrain() {
        // A board wipe can change generation while the begin notify is lost. end(n=0) matching
        // received=0 is therefore NOT proof that the old tuple may be checkpointed.
        assertEquals(
            HistoryEndDisposition.RETRY_NOW,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 0, resyncCap = 2,
                beginSeen = false,
            ),
        )
        assertEquals(
            HistoryEndDisposition.DEFER_INCOMPLETE,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 2, resyncCap = 2,
                beginSeen = false,
            ),
        )
        assertFalse(historyEnvelopeAuthorizesCheckpoint(beginSeen = false))
    }

    @Test fun matchingEmptyDrainWithItsBeginMayFinalize() {
        assertEquals(
            HistoryEndDisposition.COMPLETE,
            historyEndDisposition(
                received = 0, expected = 0, resyncAttempts = 0, resyncCap = 2,
                beginSeen = true,
            ),
        )
        assertTrue(historyEnvelopeAuthorizesCheckpoint(beginSeen = true))
    }

    @Test fun incompleteAttemptDisclosesAllObservableShortfall() {
        assertEquals(1, replayUnreplayedCount(100, 100, 99, transportComplete = false))
        assertEquals(1, replayUnreplayedCount(100, 99, 99, transportComplete = true))
        assertEquals(2, replayUnreplayedCount(100, 99, 98, transportComplete = false))
        // A duplicate can balance or exceed the count without identifying which seq was missed.
        assertEquals(1, replayUnreplayedCount(100, 100, 101, transportComplete = false))
    }

    @Test fun disconnectBeforeCheckpointReconnectsFromDurableTuple() {
        val volatile = ReplayCursorTuple(sequence = 900, generation = 71)
        val durable = ReplayCursorTuple(sequence = 600, generation = 71)
        assertEquals(durable, replayCursorForReconnect(volatile, durable))

        // Generation is part of the same decision; never pair a volatile generation with a
        // durable sequence after switching boards or surviving a wipe.
        val oldDurable = ReplayCursorTuple(sequence = 100, generation = 7)
        val newVolatile = ReplayCursorTuple(sequence = 20, generation = 99)
        assertEquals(oldDurable, replayCursorForReconnect(newVolatile, oldDurable))
    }
}
