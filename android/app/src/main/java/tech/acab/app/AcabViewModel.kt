package tech.acab.app

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import tech.acab.app.ble.AcabBleManager
import tech.acab.app.net.FirmwareManifest

/** Keeps the BLE manager alive across config changes (so the connection survives),
 *  and feeds it the phone's location for geotagging non-drone detections. */
class AcabViewModel(app: Application) : AndroidViewModel(app) {
    // Process singleton, so the Drive-mode foreground service and this ViewModel share one
    // link (the service keeps it alive when the app is backgrounded mid-drive).
    val ble = AcabBleManager.getInstance(app)

    // The firmware manifest drives the "update available" nudge and the in-app OTA gate.
    // Kick a background refresh on launch; it's non-blocking and no-ops if the cache is fresh.
    val firmware = FirmwareManifest.getInstance(app).also { it.refresh() }

    /** Feed runtime permission changes into the process-wide manager. Location has to be owned
     *  there, not by this Activity ViewModel: Drive mode deliberately keeps the manager and its
     *  foreground service alive after the Activity task is dismissed. */
    fun onPermissionsChanged(bluetoothGranted: Boolean, locationGranted: Boolean) {
        ble.onPermissionsChanged(bluetoothGranted, locationGranted)
    }

    override fun onCleared() {
        // AcabBleManager is process-wide so Drive mode can keep the radio link alive after this
        // Activity task is dismissed. A contribution capture is Activity-owned, though: leaving
        // its ledger armed here would keep accumulating sightings invisibly and without a bound.
        // onCleared is not called for configuration changes, so rotation still preserves capture.
        ble.cancelContributionCapture()
        // Keep the link if Drive mode's foreground service is holding it; else disconnect.
        if (!ble.driveModeOn) ble.disconnect()
        super.onCleared()
    }
}
