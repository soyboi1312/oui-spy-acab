package tech.acab.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
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
import tech.acab.app.ble.DetectionNotifier
import tech.acab.app.ble.defaultLiveModeStartConfirmed
import tech.acab.app.ble.defaultLiveModeStartReady
import tech.acab.app.net.AlprStore
import tech.acab.app.ui.AcabApp
import tech.acab.app.ui.NearbyPermissionDenial
import tech.acab.app.ui.canRetryAllMissingPermissions
import tech.acab.app.ui.resolveNearbyPermissionDenial
import tech.acab.app.ui.theme.Acab

class MainActivity : ComponentActivity() {
    private val vm: AcabViewModel by viewModels()
    private var permissionsGranted by mutableStateOf(false)
    private var locationGranted by mutableStateOf(false)
    private var notificationsAvailable by mutableStateOf(false)
    private var nearbyPermissionDenial by mutableStateOf(NearbyPermissionDenial.NONE)
    private var liveNotificationDenied by mutableStateOf(false)
    private var startDriveRequested = false
    private var defaultLiveStartPending = false
    private var scanAfterPermissionGrant = false

    private val requestPermissions = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) {
        syncPermissionState()
        if (scanAfterPermissionGrant) {
            if (permissionsGranted) maybeStartPermissionScan()
            else scanAfterPermissionGrant = false
        }
    }

    private val requestLocation = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { syncPermissionState() }

    private val requestDriveNotification = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        syncPermissionState()
        liveNotificationDenied = !granted
        completeDefaultLiveStartIfPossible()
        // Live Mode stays usable when declined; Beacon settings surfaces the blocked surface.
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        defaultLiveStartPending = savedInstanceState?.getBoolean(KEY_DEFAULT_LIVE_PENDING) == true
        scanAfterPermissionGrant = savedInstanceState?.getBoolean(KEY_SCAN_AFTER_PERMISSION) == true
        liveNotificationDenied = savedInstanceState?.getBoolean(KEY_LIVE_NOTIFICATION_DENIED) == true
        syncPermissionState()
        // Prime the known-ALPR store at launch so a default-on install fetches the dataset
        // before the first Map open, matching iOS (ALPRStore.init refreshes at launch).
        // Construction is inert while the layer is switched off.
        AlprStore.getInstance(applicationContext)
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
                    locationGranted = locationGranted,
                    notificationsAvailable = notificationsAvailable,
                    nearbyPermissionDenial = nearbyPermissionDenial,
                    liveNotificationDenied = liveNotificationDenied,
                    onRequestPermissions = {
                        getSharedPreferences("acab_ui", MODE_PRIVATE).edit()
                            .putBoolean(KEY_NEARBY_PERMISSION_REQUESTED, true).apply()
                        nearbyPermissionDenial = NearbyPermissionDenial.NONE
                        scanAfterPermissionGrant = true
                        requestPermissions.launch(requestedPermissions())
                    },
                    onRequestLocation = ::requestOptionalLocation,
                    onStartDefaultLiveMode = ::startDefaultLiveMode,
                    onLiveNotificationDenialHandled = { liveNotificationDenied = false },
                )
            }
        }
    }

    // Re-sync when returning from system Settings, so granting there updates the UI without
    // needing a relaunch (previously the onCreate auto-request covered this path).
    override fun onResume() {
        super.onResume()
        syncPermissionState()
        maybeStartPermissionScan()
        maybeStartRequestedDrive()
        completeDefaultLiveStartIfPossible()
    }

    override fun onSaveInstanceState(outState: Bundle) {
        outState.putBoolean(KEY_DEFAULT_LIVE_PENDING, defaultLiveStartPending)
        outState.putBoolean(KEY_SCAN_AFTER_PERMISSION, scanAfterPermissionGrant)
        outState.putBoolean(KEY_LIVE_NOTIFICATION_DENIED, liveNotificationDenied)
        super.onSaveInstanceState(outState)
    }

    // launchMode=singleTask: a Live Mode notification tap lands here when the activity
    // already exists, instead of relaunching it.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleDeepLink(intent)
    }

    /** Live Mode notification tap: raise the "open the Log tab, NEW filter" signal that
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
        // Sample data seeds READY too, so the link check alone is not the honesty gate: a tile tap
        // under "Continue without pairing" would otherwise pin a real ongoing Live Mode
        // notification over canned rows, take location ownership into the background, and persist
        // the Live Mode preference from a demo action. Same rule startDefaultLiveMode applies, and
        // the one iOS keeps in liveModeCanRun.
        //
        // DriveModeTileService now greys the tile out under sample data as well, so a demo request
        // should not reach here at all. This stays as the backstop, because the request is applied
        // on a LATER resume: the tap can land on a render one emission stale, and demo can be
        // entered in the gap between the tap and this activity reaching RESUMED.
        if (vm.ble.state.value != ConnState.READY || vm.ble.demoMode.value) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
            requestDriveNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        vm.ble.startDriveMode()
    }

    /** Root-level default startup, invoked only after the real-board tour is no longer covering
     * the app. Keeping this in the activity/root path means it runs regardless of the selected tab.
     * The explanatory UI decides whether this invocation should also trigger the one-time runtime
     * notification request; subsequent sessions simply restore the user's persisted choice. */
    private fun startDefaultLiveMode(requestNotification: Boolean) {
        if (vm.ble.state.value != ConnState.READY || vm.ble.demoMode.value ||
            !vm.ble.driveModeWanted.value) return
        // Treat this as an intent, not a one-shot callback. ActivityResult may deliver while the
        // activity is merely STARTED; consuming the flag there made the default path a no-op after
        // the user tapped Allow. It also has to survive rotation while the system dialog is up.
        defaultLiveStartPending = true
        if (requestNotification && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            !hasPermission(Manifest.permission.POST_NOTIFICATIONS)) {
            requestDriveNotification.launch(Manifest.permission.POST_NOTIFICATIONS)
            return
        }
        completeDefaultLiveStartIfPossible()
    }

    private fun completeDefaultLiveStartIfPossible() {
        if (!defaultLiveStartPending) return
        // An explicit Off or a switch into sample data cancels the queued default. A transient
        // reconnect or STARTED-only permission callback keeps it armed for the next usable edge.
        if (!vm.ble.driveModeWanted.value || vm.ble.demoMode.value) {
            defaultLiveStartPending = false
            return
        }
        // Do not consume the intent merely because startForegroundService accepted the request:
        // the service can still fail its foreground promotion asynchronously. Confirmation comes
        // from onLinkServiceStarted; until then a later resume is a bounded, user-visible retry.
        if (defaultLiveModeStartConfirmed(vm.ble.driveModeOn, vm.ble.driveServiceReady)) {
            defaultLiveStartPending = false
            return
        }
        if (!defaultLiveModeStartReady(
                pending = defaultLiveStartPending,
                activityResumed = lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED),
                linkReady = vm.ble.state.value == ConnState.READY,
                demoMode = vm.ble.demoMode.value,
                wanted = vm.ble.driveModeWanted.value,
            )) return
        if (!vm.ble.driveModeOn) vm.ble.startDriveMode()
    }

    /** The first-run CTA says "Allow & scan", so a successful grant must do both. Permission
     * callbacks may arrive below RESUMED just like the notification result, and a LOW_LATENCY
     * scan must not be started until this activity is actually visible. */
    private fun maybeStartPermissionScan() {
        if (!scanAfterPermissionGrant || !permissionsGranted ||
            !lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        scanAfterPermissionGrant = false
        vm.ble.startScan()
    }

    /** Recheck whether we can scan/connect, and kick off location if allowed. */
    private fun syncPermissionState() {
        permissionsGranted = requiredPermissions().all { hasPermission(it) }
        val permissionAsked = getSharedPreferences("acab_ui", MODE_PRIVATE)
            .getBoolean(KEY_NEARBY_PERMISSION_REQUESTED, false)
        val missingPermissions = requiredPermissions().filterNot(::hasPermission)
        nearbyPermissionDenial = resolveNearbyPermissionDenial(
            granted = permissionsGranted,
            requestedBefore = permissionAsked,
            // One permanently denied member of the required set still blocks scanning. A partial
            // grant must therefore go to Settings instead of re-requesting only the retryable half.
            canAskAgain = canRetryAllMissingPermissions(
                missingPermissions.map(::shouldShowRequestPermissionRationale),
            ),
        )
        locationGranted = hasLocationPermission()
        notificationsAvailable = DetectionNotifier.liveChannelDeliverable(this)
        if (notificationsAvailable) liveNotificationDenied = false
        vm.onPermissionsChanged(permissionsGranted, locationGranted)
    }

    // Android 12+ needs only Nearby Devices to find and pair with the beacon. Location is optional
    // there and is requested later from Map/geotagging surfaces. On older Android, the platform
    // itself gates BLE scanning on fine location, so it remains part of the initial request.
    private fun requestedPermissions(): Array<String> = requiredPermissions()

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

    private fun requestOptionalLocation() {
        if (hasLocationPermission()) {
            syncPermissionState()
            return
        }
        val prefs = getSharedPreferences("acab_ui", MODE_PRIVATE)
        val asked = prefs.getBoolean(KEY_LOCATION_REQUESTED, false)
        val permissions = locationPermissions()
        val permanentlyDenied = asked && permissions.none(::shouldShowRequestPermissionRationale)
        if (permanentlyDenied) {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null))
            )
            return
        }
        prefs.edit().putBoolean(KEY_LOCATION_REQUESTED, true).apply()
        requestLocation.launch(permissions)
    }

    private fun locationPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)
        else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermission(p: String) =
        checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED

    companion object {
        /** Intent extra set by the drive-mode notification's contentIntent (AcabLinkService). */
        const val EXTRA_OPEN_LOG_NEW = "open_log_new"

        /** Quick Settings intent consumed only after the activity is visible. */
        const val EXTRA_START_DRIVE = "start_drive"

        private const val KEY_LOCATION_REQUESTED = "location_requested"
        private const val KEY_NEARBY_PERMISSION_REQUESTED = "perms_requested"
        private const val KEY_DEFAULT_LIVE_PENDING = "default_live_pending"
        private const val KEY_SCAN_AFTER_PERMISSION = "scan_after_permission"
        private const val KEY_LIVE_NOTIFICATION_DENIED = "live_notification_denied"

        /** Pending deep link, as observable state rather than a MainScreen parameter:
         *  AcabApp sits between the activity and the tab shell, and the tap can arrive while
         *  the app is already composed. It stays raised until MainScreen is actually on
         *  screen (READY link) to consume it. */
        val openLogNew = mutableStateOf(false)
    }
}
