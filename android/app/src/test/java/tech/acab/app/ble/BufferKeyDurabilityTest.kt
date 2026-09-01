package tech.acab.app.ble

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.ArrayDeque

class BufferKeyDurabilityTest {
    private fun key(fill: Int) = ByteArray(DURABLE_BUFFER_KEY_BYTES) { fill.toByte() }

    @Test fun existingUnwrapFailureFailsClosedWithoutGeneratingOrReplacing() {
        var generated = false
        var persisted = false
        val result = resolveDurableBufferKey(
            stored = "only-durable-copy",
            unwrap = { null },
            generate = { generated = true; key(1) },
            wrap = { "replacement" },
            persist = { persisted = true; true },
        )

        assertNull(result)
        assertFalse("a transient Keystore failure must not rotate evidence keys", generated)
        assertFalse("the unreadable blob must remain untouched", persisted)
    }

    @Test fun generatedKeyIsNotReturnedWhenSynchronousCommitFails() {
        val candidate = key(0x5a)
        var persisted = false
        val result = resolveDurableBufferKey(
            stored = null,
            unwrap = { error("no stored blob") },
            generate = { candidate },
            wrap = { "sealed" },
            persist = { persisted = true; false },
        )

        assertTrue(persisted)
        assertNull("an ephemeral key must never reach the BLE handshake", result)
    }

    @Test fun onlyAUsableDurablyCommittedKeyCanBeReturned() {
        var writes = 0
        assertNull(resolveDurableBufferKey(
            stored = null,
            unwrap = { null },
            generate = { key(0) },
            wrap = { "zero" },
            persist = { writes++; true },
        ))
        assertTrue("all-zero entropy must be rejected before storage", writes == 0)

        val candidate = key(0x33)
        val result = resolveDurableBufferKey(
            stored = null,
            unwrap = { null },
            generate = { candidate },
            wrap = { "sealed" },
            persist = { writes++; true },
        )
        assertArrayEquals(candidate, result)
        assertTrue(writes == 1)
    }

    @Test fun keyFailureEmitsNeitherEpochNorSyncAndSyncFailureIsNotComplete() {
        val keyFailure = bufferHandshakeTransition(BufferHandshakeWrite.KEY, success = false)
        assertNull(keyFailure.next)
        assertTrue(keyFailure.failed)
        assertFalse(keyFailure.complete)

        val syncFailure = bufferHandshakeTransition(BufferHandshakeWrite.SYNC, success = false)
        assertTrue(syncFailure.failed)
        assertFalse(syncFailure.complete)
    }

    @Test fun clearAndDoubleClearStayBehindEveryHandshakeSuccessor() {
        val queue = ArrayDeque(listOf("clear-1", "clear-2"))
        enqueueBufferControlWrite(queue, "epoch", handshakeSuccessor = true)
        assertEquals(listOf("epoch", "clear-1", "clear-2"), queue.toList())
        assertEquals("epoch", queue.removeFirst())
        enqueueBufferControlWrite(queue, "sync", handshakeSuccessor = true)
        assertEquals(listOf("sync", "clear-1", "clear-2"), queue.toList())
    }

    @Test fun rejectedMtuRequestContinuesAtDefaultInsteadOfHanging() {
        assertEquals(
            MtuDiscoveryAction.CONTINUE_AT_DEFAULT,
            mtuDiscoveryAction(serviceDiscoverySucceeded = true, mtuRequestAccepted = false),
        )
        assertEquals(
            MtuDiscoveryAction.WAIT_FOR_CALLBACK,
            mtuDiscoveryAction(serviceDiscoverySucceeded = true, mtuRequestAccepted = true),
        )
    }
}
