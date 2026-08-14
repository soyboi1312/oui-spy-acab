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
 * Mirrors the iOS DeviceStatusProtoTests fixtures; both sides parse the same three JSON strings.
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
}
