package tech.acab.app.ble

import java.util.Collections
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManagedListDurabilityTest {
    @Test
    fun newerExitDemoReloadRetiresAnOlderDecodedSnapshot() {
        val gate = ManagedListLoadGate()
        val old = gate.beginLoad()
        val current = gate.beginLoad()
        assertFalse(gate.accepts(old))
        assertTrue(gate.accepts(current))
    }

    @Test
    fun startupAndExitDemoLoadsRejectRealEditsUntilBothListsAreReady() {
        assertEquals(
            ManagedListEditMode.LOADING_FAIL_CLOSED,
            managedListEditMode(demoMode = false, listsReady = false),
        )
        assertEquals(
            ManagedListEditMode.DURABLE,
            managedListEditMode(demoMode = false, listsReady = true),
        )
        assertEquals(
            ManagedListEditMode.PREVIEW_ONLY,
            managedListEditMode(demoMode = true, listsReady = false),
        )
    }

    @Test
    fun absentIsValidEmptyButUnreadableStoredBytesAreNotAuthoritative() {
        assertTrue(storedManagedListIsAuthoritative(
            storedPresent = false,
            decodedSuccessfully = false,
        ))
        assertTrue(storedManagedListIsAuthoritative(
            storedPresent = true,
            decodedSuccessfully = true,
        ))
        assertFalse(storedManagedListIsAuthoritative(
            storedPresent = true,
            decodedSuccessfully = false,
        ))
    }

    @Test
    fun failedClearAcknowledgementRetirementStaysPendingAndRetries() {
        var stored = true
        var writeSucceeds = false
        val intent = ManagedListClearIntent(
            readStored = { stored },
            writeStored = { pending ->
                // SharedPreferences changes its process map before the disk result is known.
                stored = pending
                writeSucceeds
            },
        )
        assertTrue(intent.isPending)
        assertFalse(intent.retire())
        assertTrue("failed commit must remain an in-process retry barrier", intent.isPending)

        writeSucceeds = true
        assertTrue(intent.retire())
        assertFalse(intent.isPending)
    }

    @Test
    fun unreadableClearIntentFailsClosed() {
        val intent = ManagedListClearIntent(
            readStored = { error("preferences unavailable") },
            writeStored = { true },
        )
        assertTrue(intent.isPending)
        assertFalse(intent.retire())
        assertTrue(intent.isPending)
    }

    @Test
    fun pairedIndexesExposeOnlyWholeWatchOrIgnoreGenerations() {
        val mac = "aa:bb:cc:dd:ee:ff"
        val rule = IgnoredDevice(mac, "camera")
        val watchedGeneration = buildManagedListIndexes(
            ignored = emptyList(),
            watched = listOf(WatchedDevice(mac, "camera")),
        )
        val ignoredGeneration = buildManagedListIndexes(
            ignored = listOf(rule),
            watched = emptyList(),
        )
        assertFalse(managedIndexSaysMuted(watchedGeneration, mac) { true })
        assertTrue(managedIndexSaysMuted(ignoredGeneration, mac) { it == rule })
    }


    @Test
    fun visibleInstallAndBoardPushFollowConfirmedPersistence() {
        val events = mutableListOf<String>()
        assertTrue(applyDurableManagedListEdit(
            candidate = "generation-7",
            persist = { events += "persist:$it"; true },
            install = { events += "install:$it" },
            reconcileBoard = { events += "board:$it" },
        ))
        assertEquals(
            listOf("persist:generation-7", "install:generation-7", "board:generation-7"),
            events,
        )
    }

    @Test
    fun failedCommitIsFailClosedForUiAndBoard() {
        val events = mutableListOf<String>()
        assertFalse(applyDurableManagedListEdit(
            candidate = "unsaved",
            persist = { events += "persist"; false },
            install = { events += "install" },
            reconcileBoard = { events += "board" },
        ))
        assertEquals(listOf("persist"), events)
    }

    @Test
    fun supersededGenerationCannotInstallOrPushAfterItsWriteReturns() {
        val events = mutableListOf<String>()
        assertFalse(applyDurableManagedListEdit(
            candidate = "old",
            persist = { events += "persist"; true },
            isStillCurrent = { events += "generation-check"; false },
            install = { events += "install" },
            reconcileBoard = { events += "board" },
        ))
        assertEquals(listOf("persist", "generation-check"), events)
    }

    @Test
    fun emptyClearIntentIsDurableBeforeDestructiveBoardPush() {
        data class Snapshot(val rows: List<String>, val clearPending: Boolean)
        var durable: Snapshot? = null
        var visible = listOf("aa:bb:cc:dd:ee:ff")
        var boardPushes = 0
        val empty = Snapshot(emptyList(), clearPending = true)

        assertTrue(applyDurableManagedListEdit(
            candidate = empty,
            persist = { durable = it; durable == it },
            install = { visible = it.rows },
            reconcileBoard = {
                assertEquals(it, durable)
                assertTrue(it.clearPending)
                boardPushes++
            },
        ))
        assertTrue(visible.isEmpty())
        assertEquals(1, boardPushes)
    }

    @Test
    fun concurrentEditsCannotOverlapOrReverseGenerationOrder() {
        val serializer = ManagedListEditSerializer()
        val firstEntered = CountDownLatch(1)
        val releaseFirst = CountDownLatch(1)
        val secondStarted = CountDownLatch(1)
        val secondEntered = CountDownLatch(1)
        val events = Collections.synchronizedList(mutableListOf<String>())

        val first = Thread {
            serializer.serialized { generation ->
                events += "first:$generation"
                firstEntered.countDown()
                assertTrue(releaseFirst.await(2, TimeUnit.SECONDS))
                events += "first-done"
            }
        }
        val second = Thread {
            secondStarted.countDown()
            serializer.serialized { generation ->
                events += "second:$generation"
                secondEntered.countDown()
            }
        }

        first.start()
        assertTrue(firstEntered.await(2, TimeUnit.SECONDS))
        second.start()
        assertTrue(secondStarted.await(2, TimeUnit.SECONDS))
        try {
            assertFalse("second edit entered while the first write was in flight",
                secondEntered.await(100, TimeUnit.MILLISECONDS))
        } finally {
            releaseFirst.countDown()
        }
        first.join(2_000)
        second.join(2_000)
        assertFalse(first.isAlive)
        assertFalse(second.isAlive)
        assertEquals(listOf("first:1", "first-done", "second:2"), events)
    }

    @Test
    fun boardAcknowledgementCannotRetireWhileAnEditCommitIsInFlight() {
        val serializer = ManagedListEditSerializer()
        val editEntered = CountDownLatch(1)
        val releaseEdit = CountDownLatch(1)
        val acknowledgementEntered = CountDownLatch(1)

        val edit = Thread {
            serializer.serialized {
                editEntered.countDown()
                assertTrue(releaseEdit.await(2, TimeUnit.SECONDS))
            }
        }
        val acknowledgement = Thread {
            serializer.withLock { acknowledgementEntered.countDown() }
        }

        edit.start()
        assertTrue(editEntered.await(2, TimeUnit.SECONDS))
        acknowledgement.start()
        try {
            assertFalse(
                "board acknowledgement overlapped the durable list generation",
                acknowledgementEntered.await(100, TimeUnit.MILLISECONDS),
            )
        } finally {
            releaseEdit.countDown()
        }
        edit.join(2_000)
        acknowledgement.join(2_000)
        assertFalse(edit.isAlive)
        assertFalse(acknowledgement.isAlive)
        assertTrue(acknowledgementEntered.await(0, TimeUnit.MILLISECONDS))
    }
}
