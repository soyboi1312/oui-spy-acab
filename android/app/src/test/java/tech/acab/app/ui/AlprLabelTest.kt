package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT

class AlprLabelTest {

    @Test
    fun attributionTiersDescribeStructureWithoutVerificationClaims() {
        val tier0 = alprMarkerText(0, "")
        val tier1 = alprMarkerText(1, "Flock Safety")
        val tier2 = alprMarkerText(2, "Legacy name")
        val old = alprMarkerText(ALPR_TIER_LEGACY_FORMAT, "")
        val unknown = alprMarkerText(255, "Older value")

        assertEquals("ALPR camera, no structured manufacturer", tier0.first)
        assertEquals("Flock Safety ALPR camera, manufacturer attributed", tier1.first)
        assertEquals("Legacy name legacy ALPR candidate", tier2.first)
        assertEquals("ALPR camera, legacy dataset format", old.first)
        assertEquals("Older value ALPR record, unknown attribution tier", unknown.first)

        for (text in listOf(tier0, tier1, tier2, old, unknown)
            .flatMap { listOf(it.first, it.second) }) {
            assertFalse(text, text.contains("verified", ignoreCase = true))
            assertFalse(text, text.contains("confirmed", ignoreCase = true))
        }
    }
}
