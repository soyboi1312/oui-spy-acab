package tech.acab.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.compose.material3.LocalTextStyle
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.Lifecycle
import tech.acab.app.ble.ConnState
import tech.acab.app.ui.AcabApp
import tech.acab.app.ui.theme.Acab

class MainActivity : ComponentActivity() {
    private val vm: AcabViewModel by viewModels()
    private var permissionsGranted by mutableStateOf(false)
    private var startDriveRequested = false

    private val requestPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { syncPermissionState() }

    private val requestDriveNotification = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { /* Drive mode stays usable when declined; the app surfaces the missing-counter state. */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        syncPermissionState()
        handleDeepLink(intent)
        // The permission prompt is NOT fired here anymore. The connect screen shows a
        // "before the system asks" rationale first, and its CTA calls onRequestPermissions,
        // so the OS prompt only appears after the user has seen why we ask.
        setContent {
            // Space Grotesk is the default face for any non-mono Text, like the iOS
            // app. Doesn't touch component colors.
            CompositionLocalProvider(
                LocalTextStyle provides LocalTextStyle.current.copy(fontFamily = Acab.display)
            ) {
                AcabApp(
                    ble = vm.ble,
                    permissionsGranted = permissionsGranted,
                    onRequestPermissions = { requestPermissions.launch(requestedPermissions()) },
                )
            }
        }
    }

    // Re-sync when returning from system Settings, so granting there updates the UI without
    // needing a relaunch (previously the onCreate auto-request covered this path).
    override fun onResume() {
        super.onResume()
        syncPermissionState()
        maybeStartRequestedDrive()
    }

    // launchMode=singleTask: a drive-mode notification tap lands here when the activity
    // already exists, instead of relaunching it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    /** Drive-mode notification tap: raise the "open the Log tab, NEW filter" signal that
     *  MainScreen consumes once it's on screen. The extra is stripped after reading so a
     *  recreation replaying the same intent doesn't re-trigger the jump; a launch from
     *  recents after process death re-delivers the original intent (extra intact), so the
     *  HISTORY flag guards that replay too. */
    private fun handleDeepLink(intent: Intent?) {
        if (intent == null) return
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.getBooleanExtra(EXTRA_OPEN_LOG_NEW, false)) {
            openLogNew.value = true
            intent.removeExtra(EXTRA_OPEN_LOG_NEW)
        }
        if (intent.getBooleanExtra(EXTRA_START_DRIVE, false)) {
            startDriveRequested = true
            intent.removeExtra(EXTRA_START_DRIVE)
            maybeStartRequestedDrive()
        }
    }

    /** A Quick Settings tile is a background service on Android 14 and newer, so it cannot start
     * a location foreground service under while-in-use permission. Apply its request only after
     * this activity is actually visible. */
    private fun maybeStartRequestedDrive() {
        if (!startDriveRequested ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        startDriveRequested = false
        if (vm.ble.state.value != ConnState.READY) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
            requestDriveNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        vm.ble.startDriveMode()
    }

    /** Recheck whether we can scan/connect, and kick off location if allowed. */
    private fun syncPermissionState() {
        permissionsGranted = requiredPermissions().all { hasPermission(it) }
        vm.onPermissionsChanged(permissionsGranted, hasLocationPermission())
    }

    // Everything we ask for in one prompt: BLE plus location for the map. On Android
    // 12+ you have to request COARSE alongside FINE or the FINE request is ignored -
    // that's why the location prompt used to never show up.
    private fun requestedPermissions(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_CONNECT)
        }
        add(Manifest.permission.ACCESS_FINE_LOCATION)
        add(Manifest.permission.ACCESS_COARSE_LOCATION)
        // Notifications are requested at the Drive-mode / alert feature boundary. They are not
        // needed to scan, so including them in this first-run prompt made the rationale dishonest.
    }.toTypedArray()

    // What we actually need to scan and connect. On 12+ location is just for the
    // map, but pre-12 BLE scanning needs it too.
    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        else
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasLocationPermission() =
        hasPermission(Manifest.permission.ACCESS_FINE_LOCATION) ||
            hasPermission(Manifest.permission.ACCESS_COARSE_LOCATION)

    private fun hasPermission(p: String) =
        checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    companion object {
        /** Intent extra set by the drive-mode notification's contentIntent (AcabLinkService). */
        const val EXTRA_OPEN_LOG_NEW = "open_log_new"

        /** Quick Settings intent consumed only after the activity is visible. */
        const val EXTRA_START_DRIVE = "start_drive"

        /** Pending deep link, as observable state rather than a MainScreen parameter:
         *  AcabApp sits between the activity and the tab shell, and the tap can arrive while
         *  the app is already composed. It stays raised until MainScreen is actually on
         *  screen (READY link) to consume it. */
        val openLogNew = mutableStateOf(false)
    }
}
