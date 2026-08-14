package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.ConnState

class AcabAppStateTest {
    @Test
    fun onlyAnEstablishedLiveSessionGetsTheUsableReconnectShell() {
        assertTrue(shouldUseReconnectShell(true, true, ConnState.CONNECTING, false))
        // Intentional disconnect then a fresh board connection: shell may stay mounted beneath
        // the opaque connect surface, but it must not be described or exposed as auto-reconnect.
        assertFalse(shouldUseReconnectShell(true, false, ConnState.CONNECTING, false))
        assertFalse(shouldUseReconnectShell(false, true, ConnState.CONNECTING, false))
        assertFalse(shouldUseReconnectShell(true, true, ConnState.BONDING, false))
        assertFalse(shouldUseReconnectShell(true, true, ConnState.CONNECTING, true))
    }
}
