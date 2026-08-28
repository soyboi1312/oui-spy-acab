package tech.acab.app.model

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The BLE JSON contract version (`proto`) and, more importantly, the ABSENCE rule.
 *
 * Absence must mean 0 and must read as fully compatible. Every firmware shipped before 2026-08-06
 * omits the key, so a bug here would put a "your firmware needs a newer app" warning in front of
 * every existing user on the day this ships. Kept as a fixture rather than a code read, because the
 * failure is silent and lands on people who did nothing wrong.
 *
 * Mirrors the iOS DeviceStatusProtoTests fixtures; both sides parse the same JSON fixture
 * strings, verbatim.
 */
class DeviceStatusProtoTest {

    private fun status(json: String) = DeviceStatus.fromJson(JSONObject(json))

    @Test
    fun `missing proto reads as 0 and is compatible`() {
        val s = status("""{"fw":"beacon board 2.0.3","up":10,"total":0}""")
        assertEquals(0, s.protoVersion)
        assertFalse("older firmware must never demand a newer app", s.needsNewerApp)
    }

    @Test
    fun `proto below supported is compatible`() {
        val s = status("""{"fw":"beacon board 2.0.4","proto":1}""")
        assertEquals(1, s.protoVersion)
        assertFalse(s.needsNewerApp)
    }

    @Test
    fun `proto equal to supported is compatible`() {
        val s = status("""{"fw":"beacon board 2.0.5","proto":2,"bodycam":true}""")
        assertEquals(2, s.protoVersion)
        assertFalse(s.needsNewerApp)
        assertTrue("the v2 bodycam alias must land on the body-cam field", s.bodyCam)
    }

    @Test
    fun `proto greater than supported asks for a newer app`() {
        val s = status("""{"fw":"beacon board 9.9.9","proto":99}""")
        assertEquals(99, s.protoVersion)
        assertTrue("a board on a newer contract must not be silently misparsed", s.needsNewerApp)
    }

    /** Unknown keys must stay harmless: that is what makes an ADDITIVE contract change safe and is
     *  why `proto` should only ever move for a BREAKING one. */
    @Test
    fun `unknown keys are ignored`() {
        val s = status("""{"fw":"x","proto":1,"somethingNew":true,"sdrop":4,"nElide":2}""")
        assertEquals(1, s.protoVersion)
        assertFalse(s.needsNewerApp)
        assertEquals("x", s.firmware)
    }

    @Test
    fun `buffer health fields default off on every fresh status`() {
        val s = status("""{"fw":"x","buf":9,"bufon":true}""")
        assertFalse(s.bufferSaturated)
        assertEquals(0L, s.bufferFaults)
        assertFalse(s.bufferKeyMismatch)
        assertEquals(emptyList<BufferHealthNotice>(), s.bufferHealthNotices)
    }

    @Test
    fun `key mismatch preserves history and becomes a persistent transfer warning`() {
        val s = status("""{"fw":"x","buf":9,"keymis":true}""")
        assertTrue(s.bufferKeyMismatch)
        assertEquals(listOf(BufferHealthNotice.KEY_NOT_ACCEPTED), s.bufferHealthNotices)
        assertEquals(
            "This phone’s buffer key was not accepted. Existing history was preserved and was not replayed. Sync with the originating phone, or explicitly clear the board buffer to transfer.",
            s.bufferHealthNotices.single().detail,
        )
        assertTrue(s.bufferHealthNotices.single().critical)
    }

    @Test
    fun `buffer faults and saturation become ordered user-visible warnings`() {
        // WRITE (0x04) and CRYPTO (0x40) make evidence incomplete; NVS (0x20) is historical.
        val s = status("""{"fw":"x","bufsat":true,"buferr":100}""")
        assertTrue(s.bufferSaturated)
        assertEquals(100L, s.bufferFaults)
        assertEquals(
            listOf(
                BufferHealthNotice.STORAGE_FAILED,
                BufferHealthNotice.CAPACITY_REACHED,
                BufferHealthNotice.PERSISTENCE_ERROR_RECORDED,
            ),
            s.bufferHealthNotices,
        )
        assertTrue(s.bufferHealthNotices[0].detail.contains("storage or encryption failure"))
        assertTrue(s.bufferHealthNotices[0].detail.contains("may be missing or unavailable"))
        assertTrue(s.bufferHealthNotices[1].detail.contains("may be missing"))
        assertTrue(s.bufferHealthNotices[2].detail.contains("metadata save/load error"))
        assertTrue(s.bufferHealthNotices[2].detail.contains("may already reflect a successful retry"))
        assertTrue(s.bufferHealthNotices[2].detail.contains("replay timestamps"))
        assertTrue(s.bufferHealthNotices[2].detail.contains("Clear the board buffer"))
    }

    @Test
    fun `future uint32 high fault bit remains fail closed`() {
        val s = status("""{"fw":"x","buferr":2147483648}""")
        assertEquals(0x8000_0000L, s.bufferFaults)
        assertEquals(listOf(BufferHealthNotice.STORAGE_FAILED), s.bufferHealthNotices)
    }

    @Test
    fun `nvs retry alone is not mislabeled as raw storage failure`() {
        val s = status("""{"fw":"x","buferr":32}""")
        assertEquals(listOf(BufferHealthNotice.PERSISTENCE_ERROR_RECORDED), s.bufferHealthNotices)
    }
}
