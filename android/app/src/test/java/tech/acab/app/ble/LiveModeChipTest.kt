package tech.acab.app.ble

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * What the Android 16 promoted-ongoing chip may put in the status bar.
 *
 * The chip is a lock-screen surface, and setVisibility/setPublicVersion do not reach it: SystemUI
 * renders shortCriticalText off the notification itself. So the "keep counts private on lock
 * screen" toggle has to be honoured here too, or a user who turned it on still gets a live
 * surveillance-detection tally on a locked phone - the exact glance the setting exists to deny.
 * This table is the guard against the two paths drifting apart again.
 */
class LiveModeChipTest {

    @Test fun redactionWithholdsTheCount_whileTheChipItselfStays() {
        assertNull("a redacting user must not get a tally on the lock screen",
            shortCriticalText(total = 7, connected = true, redact = true))
        assertNull(shortCriticalText(total = 1, connected = true, redact = true))
    }

    @Test fun countShowsOnlyWhileLinkedAndNonZero() {
        assertEquals("7", shortCriticalText(total = 7, connected = true, redact = false))
        // A disconnected board's last tally is stale, not live; the body already says Reconnecting.
        assertNull(shortCriticalText(total = 7, connected = false, redact = false))
        // Nothing nearby: no number, rather than a chip reading "0".
        assertNull(shortCriticalText(total = 0, connected = true, redact = false))
    }
}
