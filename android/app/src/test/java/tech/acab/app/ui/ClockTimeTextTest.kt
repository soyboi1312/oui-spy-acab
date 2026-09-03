package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.Locale

/** The contribution-window clock is a fixed 24-hour ASCII string on every phone. iOS twin:
 *  TimeBasisClockTests. */
class ClockTimeTextTest {
    private fun localMillis(hour: Int, minute: Int): Long =
        LocalDate.of(2026, 9, 2).atTime(hour, minute).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()

    @Test
    fun clockIsTwentyFourHourAsciiRegardlessOfDefaultLocale() {
        val before = Locale.getDefault()
        try {
            for (tag in listOf("en-US", "es-ES", "pl-PL", "ro-RO", "sv-SE", "ar-EG")) {
                Locale.setDefault(Locale.forLanguageTag(tag))
                assertEquals(tag, "14:05", clockTimeText(localMillis(14, 5)))
                assertEquals(tag, "02:05", clockTimeText(localMillis(2, 5)))
            }
        } finally {
            Locale.setDefault(before)
        }
    }
}
