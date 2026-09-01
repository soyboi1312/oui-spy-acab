package tech.acab.app.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.roundToInt

/**
 * Wire-format fixtures for the ALPR dataset parser, the Android half of a two-platform pair.
 *
 * This parser produced the project's only cross-platform incident. A manifest schema mismatch made
 * BOTH apps reject the binary, and the reject path returns before it stamps KEY_VERSION, so every
 * launch re-downloaded the same file and re-failed with a map frozen at the last good dataset. It
 * was then changed again to carry the ALP3 tier byte. Until now it had no test, which means the
 * only thing that has ever checked its length arithmetic is a phone in someone's pocket.
 *
 * EXACTLY WHAT IS SHARED WITH iOS, stated precisely because a header that overstates its reach is
 * worse than none:
 *   - The fixtures are BUILT IN CODE, not loaded from data files, same as FollowEvidenceTest. So
 *     there is nothing on disk for the two suites to share; what crosses the platform boundary is
 *     the builder plus the vectors. [alp] below is the whole contract, and
 *     ios/BeaconsTests/ALPRDatasetTests.swift carries a byte-for-byte equivalent writing the same
 *     little-endian layout in the same order.
 *   - Every fixture uses the SAME VECTORS as that file: same magics, same maker table, same
 *     coordinates, same maker indices, same tier bytes, same byte surgery at the same offsets, and
 *     the same expected coords / makers / confirmed.
 *   - The test methods carry iOS's names verbatim, `test` prefix and all, against this module's own
 *     convention (FollowEvidenceTest needs no prefix). The prefix is the price of the two files
 *     diffing side by side, which is the only way a human ever notices a fixture that exists on one
 *     platform and not the other.
 *
  * COORDINATE RANGE, resolved 2026-08-05 and the reason this suite exists: both parsers DROP an out-of-range coordinate together with its maker and tier. They used to
 * disagree: iOS dropped, this side kept every node the length check accounted for, so the same
 * corrupt file gave the two apps a different node COUNT and a different unverifiedCount caption.
 * The parity fixtures below are what surfaced it. Settled 2026-08-05 in favour of dropping,
 * because a latitude past +/-90 is corrupt bytes rather than a camera in an odd place: no
 * viewport box can contain it and nearest() cannot meaningfully match it, so keeping it only
 * inflates a caption with a node no surface can draw. Deliberately NOT the same call as the
 * unverified tier, where the pin is a real location with uncertain attribution and staying
 * counted keeps the data-quality problem visible. Both published datasets carried zero such
 * nodes when this landed, so nothing user-visible moved.
 *
 * Every malformed fixture is a VALID file with exactly one byte range changed. That is the whole
 * method: when one fails, the guard that moved is named by the fixture, not guessed at.
 */
class AlprDatasetTest {

    private class FakeHttpConnection : HttpURLConnection(URL("https://soyboi.tech/test")) {
        var disconnectCount = 0
        override fun connect() = Unit
        override fun disconnect() { disconnectCount++ }
        override fun usingProxy(): Boolean = false
    }

    private class BlockingInputStream : InputStream() {
        val readStarted = CountDownLatch(1)
        private val closed = CountDownLatch(1)
        @Volatile var closeCount = 0

        override fun read(): Int {
            readStarted.countDown()
            if (!closed.await(5, TimeUnit.SECONDS)) error("blocking transfer was not aborted")
            return -1
        }

        override fun close() {
            closeCount++
            closed.countDown()
        }
    }

    @Test
    fun testDatasetUrlTrust_isExactHostHttpsAndDefaultPortOnly() {
        assertTrue(isTrustedAlprUrl("https://soyboi.tech/data/alpr-v3.bin"))
        assertTrue(isTrustedAlprUrl("https://SOYBOI.TECH:443/data/alpr-v3.bin"))
        for (url in listOf(
                "http://soyboi.tech/data/alpr-v3.bin",
                "https://soyboi.tech.evil.example/data/alpr-v3.bin",
                "https://evil.example/data/alpr-v3.bin",
                "https://soyboi.tech:444/data/alpr-v3.bin",
                "https://user@soyboi.tech/data/alpr-v3.bin",
            )) assertTrue(url, !isTrustedAlprUrl(url))
    }

    @Test
    fun testDatasetRedirect_resolvesRelativeAndRejectsHostEscape() {
        val current = "https://soyboi.tech/data/alpr-v3-latest.json"
        assertEquals(
            "https://soyboi.tech/files/alpr-v3.bin",
            trustedAlprRedirect(current, "../files/alpr-v3.bin"),
        )
        assertNull(trustedAlprRedirect(current, "https://cdn.example/alpr-v3.bin"))
        assertNull(trustedAlprRedirect(current, "//soyboi.tech.evil.example/alpr-v3.bin"))
    }

    @Test
    fun testCacheFreshnessRequiresDigestAndParsedFormatAsWellAsDisplayDate() {
        assertTrue(alprCacheIsCurrent(
            "2026-08-10", "same-sha", "ALP4", "ALP4",
            "2026-08-10", "same-sha", "ALP4", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "same-sha", "ALP4", "ALP4",
            "2026-08-10", "same-sha", "ALP3", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "same-sha", "ALP4", null,
            "2026-08-10", "same-sha", "ALP3", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "same-sha", "ALP4", "ALP3",
            "2026-08-10", "same-sha", "ALP3", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "v4sha", "ALP4", "ALP4",
            "2026-08-10", "v3sha", "ALP4", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "v4sha", "ALP4", "ALP4",
            "2026-08-10", null, "ALP4", true))
        assertTrue(!alprCacheIsCurrent(
            "2026-08-10", "v4sha", "ALP4", "ALP4",
            "2026-08-10", "v4sha", "ALP4", false))
        assertTrue(alprCacheIsCurrent(
            "2026-08-10", "v3sha", "ALP3", " alp3 ",
            "2026-08-10", "v3sha", "ALP3", true))
        assertTrue(alprCacheIsCurrent(
            "2026-08-10", "v3sha", "ALP3", null,
            "2026-08-10", "v3sha", "ALP3", true))
        assertTrue(alprFormatMatches("ALP4", " alp4 ", "ALP4"))
        assertTrue(!alprFormatMatches("ALP4", null, "ALP4"))
        assertTrue(!alprFormatMatches("ALP4", "ALP3", "ALP3"))
        assertTrue(alprFormatMatches("ALP3", null, "ALP3"))
        assertTrue(!alprFormatMatches("ALP3", "ALP4", "ALP3"))
    }

    @Test
    fun testRestartableFetchGateCannotLoseBusyRequestAtHandoff() {
        val gate = RestartableFetchGate()
        assertTrue(gate.tryStart(rememberRestartIfBusy = true))
        assertTrue(!gate.tryStart(rememberRestartIfBusy = true))
        assertTrue(gate.finish(restartAllowed = true))

        // finish() reserved the next run before releasing its monitor. A request at the handoff
        // therefore sees an active run and becomes a subsequent restart instead of disappearing.
        assertTrue(!gate.tryStart(rememberRestartIfBusy = true))
        assertTrue(gate.finish(restartAllowed = true))
        assertTrue(!gate.finish(restartAllowed = false))
        assertTrue(gate.tryStart(rememberRestartIfBusy = false))
        assertTrue(!gate.finish(restartAllowed = false))
    }

    @Test
    fun testDisableAbortsActiveTransferWithoutLosingReenableRestart() {
        val gate = RestartableFetchGate()
        val transfer = AbortableAlprTransfer()
        val old = FakeHttpConnection()
        val oldStream = BlockingInputStream()

        assertTrue(gate.tryStart(rememberRestartIfBusy = true))
        assertTrue(transfer.register(old))
        assertTrue(transfer.attachStream(old, oldStream))
        val readFailure = AtomicReference<Throwable?>(null)
        val readFinished = CountDownLatch(1)
        val reader = Thread {
            try {
                oldStream.read()
            } catch (t: Throwable) {
                readFailure.set(t)
            } finally {
                readFinished.countDown()
            }
        }.also { it.start() }
        assertTrue("fixture never entered its blocking read", oldStream.readStarted.await(5, TimeUnit.SECONDS))

        // OFF takes the exact blocking connection/stream pair out before aborting both. Closing
        // the stream as well covers providers whose disconnect() does not own an obtained stream.
        val aborted = transfer.takeForAbort()
        assertTrue(aborted?.connection === old)
        assertTrue(aborted?.stream === oldStream)

        // ON arrives immediately, while the old read is still blocked and its IO abort is only
        // queued. The request must remain a restart rather than disappearing at gate handoff.
        assertTrue(!gate.tryStart(rememberRestartIfBusy = true))
        val aborter = Thread { aborted!!.abort() }.also { it.start() }
        assertTrue("closing the active stream did not wake its read", readFinished.await(5, TimeUnit.SECONDS))
        aborter.join(5_000)
        reader.join(5_000)
        assertNull(readFailure.get())
        assertEquals(1, old.disconnectCount)
        assertEquals(1, oldStream.closeCount)

        // The old run's finally releases directly into the remembered replacement.
        assertTrue(gate.finish(restartAllowed = true))

        val replacement = FakeHttpConnection()
        assertTrue(transfer.register(replacement))
        // A delayed finally from the old request cannot clear the replacement (identity/ABA guard).
        transfer.clear(old)
        assertTrue(transfer.takeForAbort()?.connection === replacement)
        assertTrue(!gate.finish(restartAllowed = false))
    }

    @Test
    fun testManifestCountIsIntegralAndBounded() {
        assertEquals(0, parseAlprManifestCount(0))
        assertEquals(42, parseAlprManifestCount(42L))
        assertEquals(42, parseAlprManifestCount(42.0))
        assertNull(parseAlprManifestCount(42.5))
        assertNull(parseAlprManifestCount(-1))
        assertNull(parseAlprManifestCount(5_000_000))
        assertNull(parseAlprManifestCount("42"))
    }

    @Test
    fun testV4ManifestFallsBackToV3On404Only() {
        assertTrue(shouldFallbackToAlprV3(404))
        for (status in listOf(0, 200, 301, 403, 410, 500, 503)) {
            assertTrue(status.toString(), !shouldFallbackToAlprV3(status))
        }
    }

    @Test
    fun testManifestDataRequiresTrustedHostDigestAndBoundedBinary() {
        val sha = "ab".repeat(32)
        assertTrue(isValidAlprManifestData(
            "https://soyboi.tech/data/alpr-v4.bin", sha, ALPR_MAX_DATASET_BYTES))
        assertTrue(!isValidAlprManifestData("https://cdn.example/alpr-v4.bin", sha, 1))
        assertTrue(!isValidAlprManifestData("https://soyboi.tech/data/alpr-v4.bin", "xyz", 1))
        assertTrue(!isValidAlprManifestData("https://soyboi.tech/data/alpr-v4.bin", sha, 0))
        assertTrue(!isValidAlprManifestData(
            "https://soyboi.tech/data/alpr-v4.bin", sha, ALPR_MAX_DATASET_BYTES + 1))
    }

    // ---- The builder ----
    //
    // Assembles a file the way soyboi.tech/tools/build_alpr_dataset.py assembles one:
    // magic | epochDay:u32 | count:u32 | [nMakers:u8 | nMakers*(len:u8, utf8)]
    //   | count*(latE7:i32, lonE7:i32) | [count*(makerIdx:u8)] | [count*(tier:u8)]
    // all little-endian. ALP1 omits both bracketed blocks, ALP2 omits the tier block.

    /** One node as the generator emits it. [maker] indexes the file's own table, [tier] is 1 when
     *  the OSM mapper picked the manufacturer from an editor preset. */
    private class Node(
        val lat: Double,
        val lon: Double,
        val maker: Int = 0,
        val tier: Int = 1,
        val osmType: Int = 0,
        val osmId: ULong = 1uL,
        val sourceEpoch: Long = 0,
        val directionCdeg: Int? = null,
        val checkDateDay: Long? = null,
    )

    /** The table every fixture uses unless it says otherwise. Index 0 is "" (unknown) because the
     *  generator always emits it there; a node with no manufacturer recorded points at 0. */
    private val table = listOf("", "Flock Safety", "Genetec", "Neology")

    /** Degrees to the wire's fixed point, ROUNDED rather than truncated: 32.7157 * 1e7 lands a hair
     *  under 327157000 in binary floating point, and truncating would put every fixture one
     *  ten-millionth of a degree south of where it reads here. iOS's `e7`. */
    private fun e7(d: Double): Int = (d * 1e7).roundToInt()

    private fun alp(magic: String, makers: List<String> = table, nodes: List<Node>): ByteArray {
        // The builder keys off the magic string exactly as the parser does, so a fixture that
        // relabels the magic gets a body that no longer matches it. Several tests below depend on
        // that: it is how the original incident is reproduced.
        val hasMakers = magic != "ALP1"
        val out = ByteArrayOutputStream()
        out.write(magic.toByteArray(Charsets.UTF_8))
        out.le32(20_285)                       // epochDay, read by nothing, present in every file
        out.le32(nodes.size)
        if (hasMakers) {
            out.write(makers.size)
            for (m in makers) {
                val utf8 = m.toByteArray(Charsets.UTF_8)
                out.write(utf8.size)
                out.write(utf8)
            }
        }
        for (n in nodes) { out.le32(e7(n.lat)); out.le32(e7(n.lon)) }
        if (hasMakers) for (n in nodes) out.write(n.maker)
        if (magic == "ALP3" || magic == "ALP4") for (n in nodes) out.write(n.tier)
        if (magic == "ALP4") for (n in nodes) {
            out.write(n.osmType)
            out.le64(n.osmId)
            out.le32(n.sourceEpoch.toInt())
            out.le16(n.directionCdeg ?: 0xFFFF)
            out.le32((n.checkDateDay ?: 0L).toInt())
        }
        return out.toByteArray()
    }

    /** Little-endian 32-bit writer, hand-rolled for the same reason iOS's is rather than reaching
     *  for ByteBuffer: the format is defined as bytes on a wire, and a fixture that inherited the
     *  host's byte order would agree with a parser that had done the same thing wrong. One writer
     *  covers both the unsigned count and the signed coords, because a Kotlin Int already IS the
     *  two's-complement pattern iOS builds with UInt32(bitPattern:). */
    private fun ByteArrayOutputStream.le32(v: Int) {
        write(v and 0xFF); write((v ushr 8) and 0xFF)
        write((v ushr 16) and 0xFF); write((v ushr 24) and 0xFF)
    }

    private fun ByteArrayOutputStream.le16(v: Int) {
        write(v and 0xFF); write((v ushr 8) and 0xFF)
    }

    private fun ByteArrayOutputStream.le64(v: ULong) {
        for (shift in 0 until 64 step 8) write(((v shr shift) and 0xFFu).toInt())
    }

    /** Three real San Diego-ish coordinates, reused so a fixture that differs from another differs
     *  in ONE way. Node 1 is the only unverified one and the only one with a table index of 2. */
    private val threeNodes = listOf(
        Node(lat = 32.7157, lon = -117.1611, maker = 1, tier = 1),
        Node(lat = 32.7200, lon = -117.1700, maker = 2, tier = 0),
        Node(lat = 32.7300, lon = -117.1800, maker = 0, tier = 1),
    )

    /** parse() and insist it succeeded, [why] naming what the fixture was proving. */
    private fun parsed(bytes: ByteArray, why: String) =
        AlprStore.parse(bytes).also { assertNotNull(why, it) }!!

    /** Resolve the parsed maker indices into the names iOS's parser returns directly.
     *
     *  This is the ONE shape difference between the two parsers, and it is not a behaviour
     *  difference: Android hands back the raw index plus the self-describing table and resolves at
     *  read time, iOS resolves inside parse. Copied from the two read sites (AlprStore.nearest and
     *  MapAlpr's `makerTable.getOrElse(makerIdx[node]) { "" }`) rather than reimplemented, so a
     *  fixture cannot pass on a label the map would never actually draw. */
    private fun makers(idx: IntArray, table: Array<String>): List<String> =
        idx.map { table.getOrElse(it) { "" } }

    /** Assert a coordinate at the wire's own resolution (1e-7 degrees, about 1 cm). Looser and a
     *  fixture would still pass on a coordinate that had been read out of the wrong node. */
    private fun assertCoord(coords: IntArray, i: Int, lat: Double, lon: Double) {
        assertEquals(lat, coords[i * 2] / 1e7, 5e-8)
        assertEquals(lon, coords[i * 2 + 1] / 1e7, 5e-8)
    }

    // ---- The four magics ----

    @Test
    fun testValidALP4RetainsTierAndSourceMetadata() {
        val nodes = listOf(
            Node(32.7157, -117.1611, maker = 1, tier = 1, osmType = 0,
                osmId = 9_223_372_036_854_775_808uL, sourceEpoch = 1_786_320_000,
                directionCdeg = 27_050, checkDateDay = 20_310),
            Node(32.7200, -117.1700, maker = 2, tier = 2, osmType = 2,
                osmId = 42uL, sourceEpoch = 0, directionCdeg = null, checkDateDay = null),
        )
        val p = parsed(alp("ALP4", nodes = nodes), "a well-formed ALP4 file was rejected")
        assertEquals("ALP4", p.wireFormat)
        assertEquals(2, p.rawCount)
        assertEquals(listOf(1, 2), p.rawTier.toList())
        assertEquals(listOf(true, false), p.confirmed.toList())
        val first = requireNotNull(p.metadata[0])
        assertEquals(0, first.osmType)
        assertEquals(9_223_372_036_854_775_808uL, first.osmId)
        assertEquals(1_786_320_000L, first.sourceEpoch)
        assertEquals(27_050, first.directionCdeg)
        assertEquals(20_310L, first.checkDateDay)
        val second = requireNotNull(p.metadata[1])
        assertEquals(2, second.osmType)
        assertEquals(42uL, second.osmId)
        assertEquals(null, second.sourceEpoch)
        assertEquals(null, second.directionCdeg)
        assertEquals(null, second.checkDateDay)
    }

    @Test
    fun testALP4RejectsInvalidMetadata() {
        assertNull(AlprStore.parse(alp("ALP4", nodes = listOf(Node(1.0, 1.0, osmType = 3)))))
        assertNull(AlprStore.parse(alp("ALP4", nodes = listOf(Node(1.0, 1.0, osmId = 0uL)))))
        assertNull(AlprStore.parse(alp("ALP4", nodes = listOf(Node(1.0, 1.0, directionCdeg = 36_000)))))
        assertNull(AlprStore.parse(alp("ALP4", nodes = listOf(Node(1.0, 1.0, tier = 3)))))
    }

    @Test
    fun testALP4CoordinateDropKeepsEveryParallelBlockAligned() {
        val p = parsed(alp("ALP4", nodes = listOf(
            Node(91.0, 1.0, maker = 1, tier = 1, osmId = 11uL),
            Node(32.0, -117.0, maker = 2, tier = 2, osmType = 1, osmId = 22uL),
        )), "one invalid coordinate should not reject valid ALP4 siblings")
        assertEquals(1, p.coords.size / 2)
        assertEquals(listOf(2), p.makerIdx.toList())
        assertEquals(listOf(2), p.rawTier.toList())
        assertEquals(22uL, p.metadata.single()!!.osmId)
    }

    @Test
    fun testValidALP3RoundTrip() {
        val p = parsed(alp("ALP3", nodes = threeNodes), "a well-formed ALP3 file was rejected")
        assertEquals("ALP3", p.wireFormat)
        assertEquals(3, p.coords.size / 2)
        assertCoord(p.coords, 0, 32.7157, -117.1611)
        assertCoord(p.coords, 1, 32.7200, -117.1700)
        assertCoord(p.coords, 2, 32.7300, -117.1800)
        // Resolved through the file's own table, in node order. The table is self-describing on
        // purpose, so this is also the assertion that fails if anyone hardcodes a maker list.
        assertEquals(listOf("Flock Safety", "Genetec", ""), makers(p.makerIdx, p.table))
        assertEquals(listOf(true, false, true), p.confirmed.toList())
    }

    @Test
    fun testALP2DefaultsEveryNodeToConfirmed() {
        // Same nodes, same tier bytes in the fixture, but ALP2 carries no tier block at all so the
        // parser never sees them. Node 1 is unverified in the ALP3 fixture above and confirmed
        // here, which is the entire point: a pre-ALP3 cache carries no evidence either way, and the
        // tier is an accusation. Defaulting the other way would paint a whole stale map amber
        // purely because the file is old.
        val p = parsed(alp("ALP2", nodes = threeNodes), "a well-formed ALP2 file was rejected")
        assertEquals("ALP2", p.wireFormat)
        assertEquals(3, p.coords.size / 2)
        assertCoord(p.coords, 1, 32.7200, -117.1700)
        assertEquals(listOf("Flock Safety", "Genetec", ""), makers(p.makerIdx, p.table))
        assertEquals(listOf(true, true, true), p.confirmed.toList())
        assertEquals(listOf(3, 3, 3), p.rawTier.toList())
    }

    @Test
    fun testALP1HasNoMakersAndIsAllConfirmed() {
        // The coord block is byte-identical across all three versions, which is the whole reason a
        // cache written by a 2024 build still draws today.
        val p = parsed(alp("ALP1", nodes = threeNodes), "a well-formed ALP1 file was rejected")
        assertEquals("ALP1", p.wireFormat)
        assertEquals(3, p.coords.size / 2)
        assertCoord(p.coords, 0, 32.7157, -117.1611)
        assertCoord(p.coords, 2, 32.7300, -117.1800)
        assertEquals(listOf("", "", ""), makers(p.makerIdx, p.table))
        assertEquals(listOf(true, true, true), p.confirmed.toList())
        assertEquals(listOf(3, 3, 3), p.rawTier.toList())
    }

    @Test
    fun testUnknownTierByteIsNotConfirmed() {
        // Only the byte 1 vouches for a node. If the generator ever grows a tier 2, an old build
        // must read it as "not vouched for" rather than waving it through, because confirmed is the
        // flag that decides whether a pin is allowed to corroborate a live detection.
        val odd = listOf(
            Node(lat = 32.7157, lon = -117.1611, maker = 1, tier = 2),
            Node(lat = 32.7200, lon = -117.1700, maker = 1, tier = 255),
        )
        val p = parsed(alp("ALP3", nodes = odd), "an unknown tier byte must not reject the dataset")
        assertEquals(listOf(false, false), p.confirmed.toList())
    }

    // ---- The empty dataset ----

    @Test
    fun testEmptyDatasetIsEmptyArraysNotNil() {
        // A zero-node file is legal, not a malformation. It has to stay distinguishable from a
        // reject: a reject returns before KEY_VERSION is stamped and re-downloads forever, whereas
        // an empty dataset is simply a region with nothing mapped in it.
        for (magic in listOf("ALP1", "ALP2", "ALP3", "ALP4")) {
            val p = parsed(alp(magic, nodes = emptyList()), "$magic with count 0 was rejected")
            assertTrue(magic, p.coords.isEmpty())
            assertTrue(magic, p.makerIdx.isEmpty())
            assertTrue(magic, p.confirmed.isEmpty())
        }
    }

    // ---- The header ----

    @Test
    fun testBadMagicIsRejected() {
        // ALP5 is the one that matters: it is what a future format looks like arriving at today's
        // build, and rejecting it is correct. The lowercase and empty cases pin that the check is
        // on bytes, not on a case-insensitive string compare someone might "tidy" it into.
        for (magic in listOf("ALP5", "ALP0", "alp3", "XXXX", "APL3")) {
            assertNull(magic, AlprStore.parse(alp(magic, nodes = threeNodes)))
        }
        assertNull(AlprStore.parse(ByteArray(0)))
        assertNull(AlprStore.parse(ByteArray(64)))
    }

    @Test
    fun testTruncatedHeaderIsRejected() {
        // 12 bytes is the floor: magic + epochDay + count. Every prefix under it must be null
        // rather than an index crash, because this runs on a file that came off the network.
        val valid = alp("ALP3", nodes = threeNodes)
        for (n in 0 until 12) {
            assertNull("$n-byte prefix", AlprStore.parse(valid.copyOfRange(0, n)))
        }
        // 12 bytes clears the header floor and stops exactly where the maker-table count byte would
        // be. ALP2/ALP3 need one more byte than ALP1 does, and this is that boundary.
        assertNull(AlprStore.parse(valid.copyOfRange(0, 12)))
    }

    // ---- The maker table ----

    @Test
    fun testEmptyMakerTableIsRejected() {
        // Index 0 must exist. A table with no entries cannot resolve the index every unknown node
        // points at, so the file is not readable even though its length arithmetic works out.
        assertNull(AlprStore.parse(alp("ALP2", makers = emptyList(), nodes = emptyList())))
        assertNull(AlprStore.parse(alp("ALP3", makers = emptyList(), nodes = threeNodes)))
    }

    @Test
    fun testMakerTableRunningPastTheBufferIsRejected() {
        // Byte map of a valid ALP2 with this table: 0-3 magic, 4-7 epochDay, 8-11 count,
        // 12 nMakers, 13 len("")=0, 14 len("Flock Safety")=12, 15.. the string. Byte 14 is the only
        // one touched, so a failure here is the length guard and nothing else.
        val overrun = alp("ALP2", nodes = threeNodes)
        overrun[14] = 200.toByte()
        assertNull(AlprStore.parse(overrun))
        // The other way a table can run off the end: the count byte promises more entries than the
        // buffer holds, so the loop walks past the last one rather than past a single string.
        val tooManyEntries = alp("ALP2", nodes = threeNodes)
        tooManyEntries[12] = 200.toByte()
        assertNull(AlprStore.parse(tooManyEntries))
    }

    @Test
    fun testInvalidUtf8MakerIsRejected() {
        val invalid = alp("ALP4", nodes = threeNodes)
        // First byte of "Flock Safety" becomes a two-byte prefix, followed by ASCII "l" rather
        // than a continuation byte. Length and every other field remain valid.
        //
        // NO iOS TWIN, and the divergence is real rather than a coverage gap: iOS decodes maker
        // names with `String(decoding:as: UTF8.self)`, which is lossy, so the same bytes parse
        // there with U+FFFD in the name while this side rejects the whole file. Do not add the
        // twin fixture until one verdict is settled for both parsers - see the header of
        // ios/BeaconsTests/ALPRDatasetTests.swift, which names this as the one open exception.
        invalid[15] = 0xC3.toByte()
        assertNull(AlprStore.parse(invalid))
    }

    @Test
    fun testMakerIndexPastTheTableResolvesToUnknown() {
        // NOT a rejection, deliberately, and matching iOS. The coordinate is intact and only its
        // label is unreadable, so this degrades one pin to "unknown maker" instead of blanking the
        // map. The dataset is community-mapped, and one bad label is not a reason to show a user
        // nothing. Node 1 points at index 7 of a four-entry table.
        val nodes = listOf(
            Node(lat = 32.7157, lon = -117.1611, maker = 1, tier = 1),
            Node(lat = 32.7200, lon = -117.1700, maker = 7, tier = 0),
            Node(lat = 32.7300, lon = -117.1800, maker = 3, tier = 1),
        )
        val p = parsed(alp("ALP3", nodes = nodes), "one bad maker index must not reject the dataset")
        assertEquals("the coordinate is fine, only its label is not", 3, p.coords.size / 2)
        assertEquals(listOf("Flock Safety", "", "Neology"), makers(p.makerIdx, p.table))
        assertEquals(listOf(true, false, true), p.confirmed.toList())
    }

    // ---- Count against length ----

    @Test
    fun testOversizeCountIsRejected() {
        // Same three-node body, count field (bytes 8-11) rewritten to claim 1000 nodes. The parser
        // must not believe the header over the buffer: 1000 * 8 coord bytes is not there, and a
        // parser that trusted the count would read 8 KB off the end of a 36-byte file.
        val lying = alp("ALP1", nodes = threeNodes)
        lying[8] = 0xE8.toByte(); lying[9] = 0x03; lying[10] = 0; lying[11] = 0   // 1000, LE
        assertNull(AlprStore.parse(lying))
        // 0xFFFFFFFF is the case the 5 million cap exists for. Note WHICH guard fires here differs
        // from iOS by necessity: a Kotlin Int is signed, so these bytes arrive as -1 and the
        // negative half of the guard catches them, while iOS reads 4294967295 and the cap does. The
        // cap is still what keeps count * 8 away from a four-billion-element array for everything
        // between 5 million and 2^31, which no length check would reach in time.
        val absurd = alp("ALP1", nodes = threeNodes)
        for (i in 8..11) absurd[i] = 0xFF.toByte()
        assertNull(AlprStore.parse(absurd))
    }

    // ---- The incident itself ----
    //
    // Both directions of the version skew that froze the map, pinned as tests. This is why the V3
    // manifest is a separate URL from the one shipped builds poll: the length check is exact on
    // both sides, so neither reader tolerates the other's file, and the reject path returns before
    // stamping KEY_VERSION. Serving one file to both readers means one of them re-downloads and
    // re-fails on every launch, forever.

    @Test
    fun testALP3WithAShortTierBlockIsRejected() {
        // An ALP3 body one byte short of its own tier block. Truncation is what a half-written
        // cache file looks like.
        val valid = alp("ALP3", nodes = threeNodes)
        assertNull(AlprStore.parse(valid.copyOfRange(0, valid.size - 1)))
        // The sharper case: an ALP2 body wearing the ALP3 magic, so the tier block is missing
        // ENTIRELY rather than clipped. This is a generator that bumped its version string without
        // emitting the new field, which is the exact shape of the original incident.
        val relabelled = alp("ALP2", nodes = threeNodes)
        relabelled[3] = '3'.code.toByte()
        assertNull(AlprStore.parse(relabelled))
    }

    @Test
    fun testTrailingGarbageIsRejected() {
        // A valid payload plus one stray byte. The length check is equality, not a minimum, so a
        // reader never quietly ignores a tail it does not understand.
        val padded = alp("ALP3", nodes = threeNodes) + byteArrayOf(0xFF.toByte())
        assertNull(AlprStore.parse(padded))
        val v4 = alp("ALP4", nodes = threeNodes)
        assertNull(AlprStore.parse(v4.copyOf(v4.size - 1)))
        assertNull(AlprStore.parse(v4 + byteArrayOf(0)))
        // The incident from the installed base's side: an ALP3 file arriving at an ALP2 reader
        // reads as a valid payload with an unexplained count-byte tail. Pinned so nobody "fixes"
        // the equality into a >= without understanding that the strictness is the reason the two
        // manifests have to stay separate.
        val v3BodyAsV2 = alp("ALP3", nodes = threeNodes)
        v3BodyAsV2[3] = '2'.code.toByte()
        assertNull(AlprStore.parse(v3BodyAsV2))
    }

    // ---- Coordinates: the one place the two platforms disagree ----
    //
    // iOS runs these same two vectors as testOutOfRangeCoordIsDroppedWithItsMakerAndTier and
    // testCoordinateLimitsAreInclusive, and gets DIFFERENT answers: it drops an out-of-range
    // coordinate together with its maker and tier, so it reads 2 nodes and then 2-and-0 where this
    // side reads 3 and then 2-and-2. The names below are deliberately not iOS's, so nobody diffing
    // the two files mistakes a matching name for a matching expectation.
    //
    // These assert what this parser DOES, not what it should do. Which side is right is a product
    // decision nobody has taken yet: dropping is defensible (a node at latitude 91 cannot be drawn
    // and will not match a detection), keeping is defensible (the length check already proved the
    // file is intact, and silently shrinking the dataset hides corruption from the count the
    // RESOLVED 2026-08-05: Android now drops out-of-range coordinates exactly as iOS does, so
    // these two fixtures assert one shared behaviour instead of pinning a disagreement. The live
    // dataset had zero out-of-range nodes when this landed, so nothing user-visible moved.

    @Test
    fun testOutOfRangeCoordIsDroppedWithItsMakerAndTier() {
        // The subtle one, and the reason all three arrays are asserted rather than just the count:
        // whichever way the disagreement above is settled, dropping a coordinate without dropping
        // its maker and tier leaves three arrays of different lengths indexed by the same integer
        // everywhere else in the app, which does not crash, it just relabels every pin after the
        // bad one. Node 1 is the out-of-range one AND the only node with maker index 2 and tier 0,
        // so a half-done drop shows up as "Genetec" landing in a slot that should read "Neology".
        val nodes = listOf(
            Node(lat = 32.7157, lon = -117.1611, maker = 1, tier = 1),
            Node(lat = 91.0, lon = -117.0, maker = 2, tier = 0),
            Node(lat = 32.7300, lon = -117.1800, maker = 3, tier = 1),
        )
        val p = parsed(alp("ALP3", nodes = nodes), "one corrupt coordinate must not reject the dataset")
        assertEquals(2, p.coords.size / 2)                       // the lat-91 node is gone
        assertCoord(p.coords, 0, 32.7157, -117.1611)
        assertCoord(p.coords, 1, 32.7300, -117.1800)             // node 2 shifts up into slot 1
        assertEquals(listOf("Flock Safety", "Neology"), makers(p.makerIdx, p.table))
        assertEquals(listOf(true, true), p.confirmed.toList())    // tier 0 left with its node
        // Longitude, and on ALP2, where the tier block does not exist to keep in step but the maker
        // array still does. Same divergence, asserted separately so a partial fix cannot hide.
        val lonOut = listOf(
            Node(lat = 32.7157, lon = -117.1611, maker = 1),
            Node(lat = 32.7200, lon = 181.0, maker = 2),
            Node(lat = 32.7300, lon = -117.1800, maker = 3),
        )
        val q = parsed(alp("ALP2", nodes = lonOut), "one corrupt longitude must not reject the dataset")
        assertEquals(2, q.coords.size / 2)
        assertEquals(listOf("Flock Safety", "Neology"), makers(q.makerIdx, q.table))
        assertEquals(listOf(true, true), q.confirmed.toList())
    }

    @Test
    fun testCoordinateLimitsAreInclusive() {
        // The poles and the antimeridian are real places, so the bound is INCLUSIVE and one
        // ten-millionth of a degree past it is not. Both sides now enforce this (the preceding
        // test pins the drop); the pair is asserted together because the boundary itself is the
        // contract - a future range check must land exactly here, not one unit either side.
        val onTheLimit = listOf(Node(lat = 90.0, lon = 180.0), Node(lat = -90.0, lon = -180.0))
        assertEquals(2, parsed(alp("ALP3", nodes = onTheLimit), "the limits are real places").coords.size / 2)
        val justPast = listOf(Node(lat = 90.0000001, lon = 180.0), Node(lat = -90.0, lon = -180.0000001))
        assertEquals(0, parsed(alp("ALP3", nodes = justPast), "one unit past the limit is corrupt").coords.size / 2)
    }
}
