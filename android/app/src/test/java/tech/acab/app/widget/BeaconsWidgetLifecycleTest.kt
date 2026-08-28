package tech.acab.app.widget

import org.junit.Assert.assertEquals
import org.junit.Test

class BeaconsWidgetLifecycleTest {
    @Test
    fun lastRemovalAndColdReAddBothChoosePrivacySafeReset() {
        assertEquals(
            WidgetSummaryLifecycleAction.RESET_SAFE,
            widgetSummaryLifecycleAction(enabled = false, managerAvailable = true),
        )
        assertEquals(
            WidgetSummaryLifecycleAction.RESET_SAFE,
            widgetSummaryLifecycleAction(enabled = true, managerAvailable = false),
        )
    }

    @Test
    fun warmReAddUsesTheAuthoritativeManagerSnapshot() {
        assertEquals(
            WidgetSummaryLifecycleAction.SEED_AUTHORITATIVE,
            widgetSummaryLifecycleAction(enabled = true, managerAvailable = true),
        )
    }

    @Test
    fun coldProcessAndOldProcessSnapshotsAlwaysRenderSafe() {
        assertEquals(false, widgetPersistedSummaryMayRender(
            managerAvailable = false,
            processMarkedReadable = true,
            storedGeneration = "current",
            currentGeneration = "current",
        ))
        assertEquals(false, widgetPersistedSummaryMayRender(
            managerAvailable = true,
            processMarkedReadable = true,
            storedGeneration = "old",
            currentGeneration = "new",
        ))
        assertEquals(true, widgetPersistedSummaryMayRender(
            managerAvailable = true,
            processMarkedReadable = true,
            storedGeneration = "current",
            currentGeneration = "current",
        ))
    }
}
