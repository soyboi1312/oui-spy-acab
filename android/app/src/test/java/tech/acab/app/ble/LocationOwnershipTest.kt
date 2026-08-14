package tech.acab.app.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LocationOwnershipTest {

    @Test
    fun visibleReadyLinkOwnsLocationOnlyWithPermission() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(false, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.CONNECTING, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, false))
    }

    @Test
    fun backgroundDriveRequiresActualForegroundService() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.CONNECTING, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, true, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, true))
        assertFalse(shouldOwnLocation(false, ConnState.READY, false, true, true))
    }

    @Test
    fun foregroundReadyAndDriveAreIndependentReasons() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, true, false))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, false, true, true))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, true, false, false))
    }

    @Test
    fun demoReadyAndExitUseTheSameOwnershipTransitionsAsARealLink() {
        assertTrue(shouldOwnLocation(true, ConnState.READY, true, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.DISCONNECTED, true, false, false))
    }

    @Test
    fun backgroundCallbacksCannotOwnLocationWithoutDriveService() {
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, false, false))
        assertFalse(shouldOwnLocation(true, ConnState.READY, false, true, false))
        assertTrue(shouldOwnLocation(true, ConnState.READY, false, true, true))
    }
}
