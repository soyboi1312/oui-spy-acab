package tech.acab.app.ble

import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class OnboardingRecoveryPolicyTest {
    @Test
    fun scanStartFailureIsNotReportedAsAnEmptyScan() {
        val ordinary = scanStartFailureHint(featureUnsupported = false)
        val unsupported = scanStartFailureHint(featureUnsupported = true)

        assertTrue(ordinary.contains("could not start Bluetooth scanning"))
        assertTrue(unsupported.contains("does not support"))
        assertNotEquals(ordinary, unsupported)
        assertTrue(!ordinary.contains("No beacons found"))
    }

    @Test
    fun eachPairingTerminalCauseHasDistinctRecoveryCopy() {
        val start = pairingFailureHint(PairingFailure.START_REJECTED)
        val failed = pairingFailureHint(PairingFailure.CANCELED_OR_FAILED)
        val timeout = pairingFailureHint(PairingFailure.TIMED_OUT)
        val secureReady = pairingFailureHint(PairingFailure.SECURE_LINK_NOT_READY)

        assertTrue(start.contains("could not start pairing"))
        assertTrue(failed.contains("canceled or failed"))
        assertTrue(timeout.contains("took too long"))
        assertTrue(secureReady.contains("secure link did not become ready"))
        assertTrue(failed.contains("approve Android's pairing request"))
        assertNotEquals(start, failed)
        assertNotEquals(failed, timeout)
        assertNotEquals(timeout, secureReady)
    }

    @Test
    fun bondNoneRequiresCurrentAttemptBondingWatermarkAndStateRecheck() {
        assertTrue(shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 3L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = false,
        ))
        assertTrue(!shouldAcceptCurrentBondNone(
            state = ConnState.BONDING,
            userInitiatedDisconnect = true,
            activeAttemptGeneration = 4L,
            observedBondingGeneration = 4L,
            previousStateWasBonding = true,
            platformStateIsNone = true,
        ))

        assertTrue(shouldHandleCurrentBonded(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            handledBondedGeneration = 3L,
            platformStateIsBonded = true,
        ))
        assertTrue(!shouldHandleCurrentBonded(
            state = ConnState.BONDING,
            userInitiatedDisconnect = false,
            activeAttemptGeneration = 4L,
            handledBondedGeneration = 4L,
            platformStateIsBonded = true,
        ))
    }

    @Test
    fun demoEntryStopsOnlyAnActiveScan() {
        assertTrue(shouldStopScanBeforeDemo(ConnState.SCANNING))
        assertTrue(!shouldStopScanBeforeDemo(ConnState.DISCONNECTED))
        assertTrue(!shouldStopScanBeforeDemo(ConnState.READY))
    }

    @Test
    fun secureReadinessCoversAlreadyBondedAndFreshBondPaths() {
        assertTrue(awaitingSecureReadiness(ConnState.CONNECTING))
        assertTrue(awaitingSecureReadiness(ConnState.BONDING))
        assertTrue(!awaitingSecureReadiness(ConnState.READY))
        assertTrue(!awaitingSecureReadiness(ConnState.SCANNING))
    }
}
