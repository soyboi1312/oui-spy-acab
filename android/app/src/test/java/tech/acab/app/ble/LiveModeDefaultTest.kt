package tech.acab.app.ble

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveModeDefaultTest {
    @Test fun freshInstallDefaultsOn() = assertTrue(liveModeWanted(null))
    @Test fun explicitOffStaysOff() = assertFalse(liveModeWanted(false))
    @Test fun explicitOnStaysOn() = assertTrue(liveModeWanted(true))

    @Test fun automaticStopPreservesWantedOn() =
        assertTrue(liveModeWantedAfterStop(currentWanted = true, userRequestedStop = false))

    @Test fun automaticStopDoesNotInventWantedOn() =
        assertFalse(liveModeWantedAfterStop(currentWanted = false, userRequestedStop = false))

    @Test fun explicitStopStoresOff() =
        assertFalse(liveModeWantedAfterStop(currentWanted = true, userRequestedStop = true))

    @Test fun permissionResultBelowResumedKeepsDefaultStartPending() {
        assertFalse(defaultLiveModeStartReady(
            pending = true,
            activityResumed = false,
            linkReady = true,
            demoMode = false,
            wanted = true,
        ))
        assertTrue(defaultLiveModeStartReady(
            pending = true,
            activityResumed = true,
            linkReady = true,
            demoMode = false,
            wanted = true,
        ))
    }

    @Test fun explicitOffPreventsQueuedDefaultStart() =
        assertFalse(defaultLiveModeStartReady(
            pending = true,
            activityResumed = true,
            linkReady = true,
            demoMode = false,
            wanted = false,
        ))

    @Test fun acceptedServiceRequestDoesNotConsumePendingIntentBeforePromotion() {
        assertFalse(defaultLiveModeStartConfirmed(driveModeOn = true, driveServiceReady = false))
        assertTrue(defaultLiveModeStartConfirmed(driveModeOn = true, driveServiceReady = true))
    }
}
