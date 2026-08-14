package tech.acab.app.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import tech.acab.app.model.DeviceType

class MapLocationTest {
    @Test
    fun operatorOnlyCoordinatesAreKeptOnlyForDroneRows() {
        assertTrue(hasMapRepresentation(
            DeviceType.DRONE, primary = null, pilotLat = 32.7, pilotLon = -117.1))
        assertFalse(hasMapRepresentation(
            DeviceType.NEARBY_DEVICE, primary = null, pilotLat = 32.7, pilotLon = -117.1))
        assertFalse(hasMapRepresentation(
            DeviceType.DRONE, primary = null, pilotLat = 0.0, pilotLon = 0.0))
        assertTrue(hasMapRepresentation(
            DeviceType.NEARBY_DEVICE, primary = 32.7 to -117.1,
            pilotLat = null, pilotLon = null))

        // Initial camera fitting must use the same operator fallback. Merely retaining the row
        // would still strand its only marker outside the default viewport.
        assertEquals(
            32.7 to -117.1,
            mapRepresentationCoord(
                DeviceType.DRONE, primary = null, pilotLat = 32.7, pilotLon = -117.1),
        )
        assertEquals(
            40.0 to -73.0,
            mapRepresentationCoord(
                DeviceType.DRONE, primary = 40.0 to -73.0,
                pilotLat = 32.7, pilotLon = -117.1),
        )
    }
}
