package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.ble.ConnState

class AcabAppStateTest {
    @Test
    fun keyMismatchKeepsBoardClearActionAvailableWhenBufferingIsOff() {
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 0,
            keyMismatch = true, wiping = false,
        ))
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 3,
            keyMismatch = false, wiping = false,
        ))
        assertTrue(shouldOfferBufferClear(
            isDemoMode = false, bufferOn = false, bufferedCount = 0,
            keyMismatch = false, wiping = true,
        ))
        assertFalse(shouldOfferBufferClear(
            isDemoMode = true, bufferOn = true, bufferedCount = 3,
            keyMismatch = true, wiping = true,
        ))
    }

    @Test
    fun keyMismatchClearConfirmationNeverClaimsZeroMeansNothingIsRetained() {
        val mismatch = bufferClearConfirmationCopy(bufferedCount = 0, keyMismatch = true)
        assertTrue(mismatch.title.contains("retained offline history"))
        assertFalse(mismatch.title.contains("0 buffered"))
        assertTrue(mismatch.message.contains("only readable by the originating phone"))
        assertTrue(mismatch.message.contains("permanently lost"))

        val ordinary = bufferClearConfirmationCopy(bufferedCount = 3, keyMismatch = false)
        assertEquals("Erase 3 buffered detections on the board?", ordinary.title)
        assertTrue(ordinary.message.contains("already synced to this phone stay"))
    }

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

    @Test
    fun consumedNavigationTokenDoesNotReopenOnTabReentry() {
        assertTrue(shouldHandleOpenToken(token = 1, handledWatermark = 0))
        assertFalse(shouldHandleOpenToken(token = 1, handledWatermark = 1))
        assertTrue(shouldHandleOpenToken(token = 2, handledWatermark = 1))
    }

    @Test
    fun nearbyPermissionRecoveryIsImmediateAndRetained() {
        assertEquals(
            NearbyPermissionDenial.NONE,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = false, canAskAgain = false),
        )
        assertEquals(
            NearbyPermissionDenial.RETRYABLE,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = true, canAskAgain = true),
        )
        assertEquals(
            NearbyPermissionDenial.SETTINGS,
            resolveNearbyPermissionDenial(granted = false, requestedBefore = true, canAskAgain = false),
        )
        assertEquals(
            NearbyPermissionDenial.NONE,
            resolveNearbyPermissionDenial(granted = true, requestedBefore = true, canAskAgain = false),
        )
        assertTrue(canRetryAllMissingPermissions(listOf(true, true)))
        assertFalse(canRetryAllMissingPermissions(listOf(true, false)))
        assertFalse(canRetryAllMissingPermissions(emptyList()))
    }

    @Test
    fun androidBackDefersTourWithoutSpendingFirstRunMarker() {
        // The whole truth table, four distinct inputs. The last row used to be a byte-identical
        // repeat of the first, captioned "a new session clears the deferred flag while the
        // persistent seen flag remains false" - a LIFECYCLE claim about where the two flags are
        // stored, which a pure predicate cannot make and this file does not test. The rule is
        // real: deferred is rememberSaveable composition state in AcabApp, seen is the
        // "first_run_tour_seen" preference owned by FirstRunTour. Promote deferred to that same
        // preference and every assertion here still passes.
        assertTrue(shouldPresentFirstRunTour(seen = false, deferred = false))
        assertFalse(shouldPresentFirstRunTour(seen = false, deferred = true))
        assertFalse(shouldPresentFirstRunTour(seen = true, deferred = false))
        assertFalse(shouldPresentFirstRunTour(seen = true, deferred = true))
    }

    @Test
    fun readyStateOpensTourBeforeShellEffectAndTourMustBeSpentBeforeDefaultLive() {
        assertTrue(shouldOpenRealFirstRunTour(ConnState.READY, false, false, false))
        assertFalse(shouldOpenRealFirstRunTour(ConnState.CONNECTING, false, false, false))
        assertFalse(shouldOpenRealFirstRunTour(ConnState.READY, true, false, false))

        // Back defers the visible tour, but unseen onboarding still blocks both Live surfaces.
        assertFalse(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = false,
            promptDeferred = false,
            wanted = true,
            active = false,
            attempted = false,
        ))
        assertTrue(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = true,
            promptDeferred = false,
            wanted = true,
            active = false,
            attempted = false,
        ))
        assertFalse(shouldAttemptDefaultLive(
            state = ConnState.READY,
            demoMode = false,
            tourSeen = true,
            promptDeferred = true,
            wanted = true,
            active = false,
            attempted = false,
        ))
    }

    @Test
    fun finishSetupCardIsRealModeOnlyAndDismissible() {
        assertTrue(shouldShowFinishSetupCard(demo = false, dismissed = false))
        assertFalse(shouldShowFinishSetupCard(demo = true, dismissed = false))
        assertFalse(shouldShowFinishSetupCard(demo = false, dismissed = true))
    }

    @Test
    fun finishSetupLiveStateNeverCallsBlockedOrPendingLiveActive() {
        assertEquals(FinishSetupLiveState.OFF,
            finishSetupLiveState(wanted = false, active = false, notificationsAvailable = false))
        assertEquals(FinishSetupLiveState.BLOCKED,
            finishSetupLiveState(wanted = true, active = true, notificationsAvailable = false))
        assertEquals(FinishSetupLiveState.WAITING,
            finishSetupLiveState(wanted = true, active = false, notificationsAvailable = true))
        assertEquals(FinishSetupLiveState.ACTIVE,
            finishSetupLiveState(wanted = true, active = true, notificationsAvailable = true))
        assertEquals("OFF",
            finishSetupPhoneAlertsLabel(enabled = false, notificationsAvailable = false))
        assertEquals("BLOCKED",
            finishSetupPhoneAlertsLabel(enabled = true, notificationsAvailable = false))
        assertEquals("ON",
            finishSetupPhoneAlertsLabel(enabled = true, notificationsAvailable = true))
    }
}
