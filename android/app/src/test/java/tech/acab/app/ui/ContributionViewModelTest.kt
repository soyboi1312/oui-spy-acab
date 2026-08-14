package tech.acab.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ContributionViewModelTest {
    @Test
    fun frozenRowCountCountsQuotedMultilineRecordOnce() {
        val vm = ContributionViewModel().apply {
            frozenCsv = "a,b\r\n\"line one\r\nline two\",value\r\n"
        }
        assertEquals(1, vm.frozenRowCount)
    }

    @Test
    fun beginExportLocksFlowAndReturnsImmutablePolicySnapshot() {
        val vm = ContributionViewModel().apply {
            phase = CapturePhase.REVIEW
            frozenCsv = "a,b\n1,2"
            kind = "Drone"
            makerModel = "model one"
            includeObserverLocation = false
            includeDroneLocation = true
            includeOperatorLocation = false
            startMs = 10L
            stopMs = 20L
        }

        val spec = requireNotNull(vm.beginExport())
        assertTrue(vm.sharePreparing)
        assertEquals("Drone", spec.kind)
        assertFalse(spec.includeObserverLocation)
        assertTrue(spec.includeDroneLocation)
        assertFalse(spec.includeOperatorLocation)

        // Back/Discard and a duplicate export cannot race a running build.
        vm.requestExit()
        assertNull(vm.confirmDiscard)
        assertNull(vm.beginExport())

        // Even if a future caller mutates a public form field directly, the in-flight request
        // remains the exact values captured before IO.
        vm.kind = "Body camera"
        vm.includeObserverLocation = true
        assertEquals("Drone", spec.kind)
        assertFalse(spec.includeObserverLocation)

        vm.finishExport()
        assertFalse(vm.sharePreparing)
        vm.requestExit()
        assertEquals(DiscardTarget.CLOSE, vm.confirmDiscard)
    }
}
