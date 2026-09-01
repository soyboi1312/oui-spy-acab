package tech.acab.app.ble

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.Manifest
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.sample
import kotlinx.coroutines.launch
import tech.acab.app.MainActivity
import tech.acab.app.R

/**
 * What the Android 16 promoted-ongoing chip is allowed to say, as one pure decision.
 *
 * Null means "no number on the chip", which leaves it in the plain Live Mode state. The count is
 * withheld for two independent reasons: the user asked for counts to stay off the lock screen
 * (the chip is a lock-screen surface that setPublicVersion does not cover), or the board is not
 * linked, so the tally is stale rather than live. Top-level and pure so the two paths can be
 * pinned in a JVM test and cannot drift apart again.
 */
internal fun shortCriticalText(total: Int, connected: Boolean, redact: Boolean): String? =
    if (redact || !connected || total <= 0) null else total.toString()

/**
 * Drive-mode foreground service. Keeps the BLE link alive in the background (the manager
 * is a process singleton) and posts an ongoing "glanceable counter" notification , a live
 * ALPR / drone / body-cam / tracker tally on the lock screen and in the shade. The phone
 * analog of the iOS Live Activity. On Android 16+ it promotes to a Live Update status-bar
 * chip (see promoteIfSupported). An in-flight OTA also holds it (HOLD_OTA) so the cached-app
 * freezer can't halt the chunk stream mid-flash; that face is a plain keep-alive line.
 */
class AcabLinkService : Service() {

    // Default, not Main: every render walks the feed and crosses the NotificationManager
    // binder, and at drive-length durations that must not ride the main thread alongside
    // Map/Log recomposition. notify() is thread-safe and build() touches only immutable data
    // + NotificationCompat builders. The Service callbacks themselves (onStartCommand, onDestroy)
    // are main-thread, and onStartCommand has to startForeground synchronously, so the FIRST face
    // is built there; renderInput() is what bounds that, since an OTA-only start walks no feed.
    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val ble by lazy { AcabBleManager.getInstance(this) }
    private var renderJob: Job? = null
    // Fingerprint of the last face actually posted: an unchanged tick skips the build and the
    // notification IPC outright (the collector otherwise re-renders for hours with the screen
    // off). The quiet tick still lands whenever a nearby row expires or "ago" text changes.
    private var lastFace: String? = null
    // Which start this instance is serving. A stop immediately followed by a start (the Live Mode
    // switch or the QS tile toggled off and straight back on) can leave the outgoing instance's
    // onDestroy queued BEHIND the incoming instance's onStartCommand: ActivityManager brings the
    // old record down and lets a fresh one be created, so both exist for a moment. Comparing this
    // against the companion's counters is how onDestroy tells "the service is gone" from "a newer
    // start already replaced me", so it cannot retract bookkeeping the new instance just set up.
    // -1 until onStartCommand runs, which never matches a real start, so a created-but-never-
    // started instance retracts nothing either.
    private var servedStartGeneration = -1L

    private data class RenderInput(
        val nearby: NearbySnapshot, val state: ConnState, val redact: Boolean, val drive: Boolean,
    )

    /** What the collector needs to know a render is due, and nothing that costs anything to
     *  compute. The nearby snapshot is taken per RENDER, not per trigger; see onStartCommand. */
    private data class RenderTrigger(
        val state: ConnState, val redact: Boolean, val drive: Boolean,
    )

    /** Values consumed by both fingerprinting and NotificationCompat. Computing this once avoids
     * a second full grouping/newest pass whenever a sampled update actually changes the face. */
    private data class RenderedFace(
        val drive: Boolean,
        val connected: Boolean,
        val total: Int,
        val redact: Boolean,
        val text: String,
        val breakdown: String,
    ) {
        fun fingerprint(): String = if (!drive) "ota|$redact"
        else "$connected|$total|$redact|$text|$breakdown"
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @OptIn(FlowPreview::class)
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Claim the newest start before anything else, so a destroy racing this one can see that
        // it has been superseded.
        servedStartGeneration = startGeneration
        // Publish it too, so onDestroy can tell "a newer instance is really serving" from "a newer
        // start was merely claimed". Monotonic: an out-of-order callback cannot walk it backwards.
        if (servedStartGeneration > servedGeneration) servedGeneration = servedStartGeneration
        createChannel()
        val initialFace = render(renderInput(
            ble.state.value, ble.redactLockScreen.value, ble.driveModeOn,
        ))
        val foreground = startForegroundCompat(build(initialFace))
        if (!foreground) return START_NOT_STICKY
        lastFace = initialFace.fingerprint()
        // The process-wide manager, not MainActivity, owns Drive fixes. Start only after the FGS
        // promotion succeeds so Android's while-in-use location rules see a real location service.
        ble.onLinkServiceStarted()
        // onStartCommand can run again on a repeat start; cancel the previous collector
        // so re-renders never stack up.
        renderJob?.cancel()
        renderJob = scope.launch {
            // Re-render on detections / connection-state / redaction / hold changes, sampled so
            // a burst of hits can't hammer NotificationManager (it drops excess updates anyway).
            // A short quiet tick expires rows at the same 45-second boundary as Status. The
            // fingerprint below skips notification IPC unless the displayed face changed.
            val nearbyTick = flow { while (true) { emit(Unit); delay(NEARBY_REFRESH_MS) } }
            // The transform carries only the cheap trigger values. combine() runs it on EVERY
            // emission of ANY source, and ble.detections publishes at ~3 Hz while driving
            // (PUBLISH_INTERVAL_MS = 300 ms), so taking the nearby snapshot here walked the whole
            // store - up to STORE_CAP rows, under storeLock, the same monitor the BLE ingest
            // thread takes for every arriving detection - several times per sample window, and
            // sample() then threw most of those snapshots away. Same empty-transform-then-sample
            // shape startWidgetFeed uses; the snapshot is taken once per render instead, in the
            // collector, where it is also fresher.
            //
            // ble.status is in the combine ON PURPOSE. The breakdown became toggle-derived
            // (enabledDriveCats reads status), so without status as a render INPUT a detector
            // toggle only reached the notification on the next detection or minute tick, up to
            // ~60 s late, while iOS repaints immediately. It is read inside render() either way;
            // being in the combine is what makes a change to it TRIGGER a render.
            combine(ble.detections, ble.state, ble.redactLockScreen, ble.driveMode, nearbyTick) {
                    _, s, r, drv, _ ->
                RenderTrigger(s, r, drv)
            }
                // Chained rather than a sixth argument: Kotlin's typed combine() tops out at five
                // flows and a sixth silently selects the vararg Array<*> overload, which does not
                // compile against this lambda. status carries no data into RenderTrigger, it is
                // here purely as a render TRIGGER.
                .combine(ble.status) { trigger, _ -> trigger }
                .sample(RENDER_SAMPLE_MS)
                .collect { renderIfChanged(renderInput(it.state, it.redact, it.drive)) }
        }
        // NOT_STICKY: if the system kills us under memory pressure, don't get recreated with a
        // null intent into a disconnected, device-less "Reconnecting…" zombie. Drive mode just
        // ends; the user re-enables it. (The connectedDevice FGS needs a live link anyway.)
        return START_NOT_STICKY
    }

    private fun renderIfChanged(inp: RenderInput) {
        val rendered = render(inp)
        val fingerprint = rendered.fingerprint()
        if (fingerprint == lastFace) return
        lastFace = fingerprint
        runCatching { nm()?.notify(NOTIF_ID, build(rendered)) }
    }

    /** Gather one render's inputs, and NOTHING the face will not use.
     *
     *  The snapshot is skipped outright when Live Mode is off, because render() returns the plain
     *  keep-alive face on its first line and never reads it. nearbySnapshot() is a whole-store pass
     *  under storeLock - the monitor the BLE thread takes for every arriving detection - and for a
     *  user holding a HERE mute it first asks LocationManager for two last-known fixes. An OTA or
     *  combined-update hold with drive off paid all of that and threw the result away: on the
     *  collector every RENDER_SAMPLE_MS for the length of the flash, and in onStartCommand on the
     *  MAIN thread, which is the thread driving the OTA progress UI. */
    private fun renderInput(state: ConnState, redact: Boolean, drive: Boolean): RenderInput =
        RenderInput(
            if (drive) ble.nearbySnapshot() else EMPTY_NEARBY, state, redact, drive,
        )

    private fun render(inp: RenderInput): RenderedFace {
        if (!inp.drive) return RenderedFace(false, false, 0, inp.redact, "", "")
        val cats = enabledDriveCats()
        val counts = inp.nearby.detections.groupingBy { it.type.category }.eachCount()
        val total = driveTotal(counts, cats)
        val connected = inp.state == ConnState.READY
        val breakdown = breakdownOf(counts, cats)
        val text = textOf(connected, total, inp.nearby.newestByCategory, cats)
        return RenderedFace(true, connected, total, inp.redact, text, breakdown)
    }

    /** Headline count: the sum over the buckets this surface actually lists. Was dets.size,
     *  which folded in NEARBY / WATCHED rows and categories disabled on the board,
     *  so the title disagreed with its own expanded row and with iOS. */
    private fun driveTotal(counts: Map<String, Int>, cats: List<String>): Int =
        cats.sumOf { counts[it] ?: 0 }

    /** Category tally for the expanded shade. Lists every detector the BOARD has switched ON,
     *  INCLUDING at zero, and nothing that is off.
     *
     *  It used to list only buckets with hits, which made a missing row ambiguous: "found none"
     *  and "not looking" rendered identically. A zero under an enabled detector is real
     *  information; a row for a disabled one implies coverage that is not running. Mirrors the
     *  iOS Live Activity's visibleCats(). Falls back to the historical five when no status has
     *  arrived, so the row is never empty. */
    private fun breakdownOf(counts: Map<String, Int>, cats: List<String>): String {
        // Every detector off: say so, rather than emitting an empty line that reads as a render
        // glitch. build() only attaches the BigText style when this is non-blank, so returning ""
        // would silently drop the row entirely.
        if (cats.isEmpty()) return "all detectors off"
        return cats.joinToString("  ") { c -> "$c ${counts[c] ?: 0}" }
    }

    /** DRIVE_CATS filtered to the detectors the board reports on. */
    private fun enabledDriveCats(): List<String> {
        // No status yet -> the historical five, so the row is never blank before the first frame.
        // Named explicitly rather than DRIVE_CATS.dropLast(1), which silently depended on CAMERA
        // being last and would have changed meaning the moment anyone reordered the list.
        val st = ble.status.value ?: return PRE_STATUS_CATS
        // Derived from DRIVE_CATS rather than rebuilt as a parallel list: a category added to
        // DRIVE_CATS but forgotten here would silently never appear, and the two lists drifting
        // is exactly the class of bug this file already carries scars from.
        return DRIVE_CATS.filter { c ->
            when (c) {
                "ALPR" -> st.flock
                "DRONE" -> st.drone
                "BODY CAM" -> st.bodyCam
                "TRACKER" -> st.tracker
                "GLASSES" -> st.glasses
                "CAMERA" -> st.ncam
                else -> false   // in DRIVE_CATS with no toggle mapping: never claim coverage
            }
        }
        // Deliberately NOT falling back when the result is empty: an empty list means every
        // detector really is off, and listing five rows then would advertise coverage that is not
        // running, which is the exact bug this change exists to fix. Mirrors iOS visibleCats().
    }

    private fun textOf(
        connected: Boolean,
        total: Int,
        newestByCategory: Map<String, NewestLive>,
        cats: List<String>,
    ): String = when {
        !connected -> "Reconnecting…"
        total == 0 -> "no detections"
        else -> lastLine(newestByCategory, cats)
    }

    override fun onDestroy() {
        // Only the CURRENT instance may say "the service is gone". A newer start bumped the
        // generation, so a superseded predecessor stops here and leaves the live instance's
        // bookkeeping alone: retracting it would wipe the hold the new start just added (leaving a
        // running service with an empty holder set, whose next hold-release then tears down a live
        // drive), and clear _driveMode - and with it the QS tile and the in-app switch - under a
        // drive the user is still in. Its own coroutines still have to go, either way.
        // BOTH counters, because a replacement can be in either half of its start. servedGeneration
        // catches the successor that has already STAMPED itself in onStartCommand. startGeneration
        // catches the one whose start the framework ACCEPTED but whose callback has not landed yet:
        // a destroy queued for the outgoing instance can be delivered inside that window, and
        // against servedGeneration alone it still looked like the live instance and retracted the
        // replacement's bookkeeping before it could be used. A claim that never
        // produces an instance would retire this instance's right to clean up after itself, which
        // is why start() hands the counter back whenever the framework refuses a start - so an
        // outstanding claim always has an instance coming.
        if (servedStartGeneration >= servedGeneration && servedStartGeneration >= startGeneration) {
            // The static holder set must not outlive the Service instance it describes. A destroy
            // that nobody asked for - an OEM battery manager, `am stopservice` - leaves HOLD_DRIVE
            // in the set, and nothing ever takes it out: onLinkServiceStopped below clears
            // _driveMode, so stopDriveMode's `if (!_driveMode.value) return` fires before it
            // reaches stop(). The next OTA then restarts the service and, when it releases
            // HOLD_OTA, finds the set still non-empty, so stopService is never called and the
            // "FIRMWARE UPDATE" ongoing notification plus a connectedDevice foreground service
            // stay pinned. HOLD_DRIVE only, not clear(): an OTA or combined-update hold is
            // released by its own leg. Removing the drive hold is exactly consistent with the
            // drive flag this method already clears.
            holders.remove(HOLD_DRIVE)
            ble.onLinkServiceStopped()
        }
        scope.cancel()
        super.onDestroy()
    }

    private fun build(face: RenderedFace): Notification {
        // Only an in-flight firmware update is holding the service (Drive mode off): show a
        // plain keep-alive face, no counters.
        if (!face.drive) return buildOtaHold()
        val tap = tapIntent()
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("LIVE MODE")
            .setContentText(face.text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
        // The expanded shade keeps the per-category tally, the analog of the iOS tile row.
        if (face.connected && face.breakdown.isNotEmpty()) {
            b.setStyle(NotificationCompat.BigTextStyle().bigText("${face.text}\n${face.breakdown}"))
        }
        if (face.redact) {
            // Lock-screen privacy (user setting, default OFF so counts are visible unless the
            // user turns redaction on): while on, a locked phone shows only the redacted public
            // version ("Live Mode active"), never the gear breakdown. The full text appears in
            // the shade once unlocked.
            b.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            b.setPublicVersion(buildPublic(tap))
        } else {
            b.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        }
        promoteIfSupported(b, face.total, face.connected, face.redact)
        return b.build()
    }

    /** "last ALPR 2m ago" from the six-entry category index derived with the nearby snapshot.
     * History, stale rows and active mutes were already excluded in that one store pass. */
    private fun lastLine(
        newestByCategory: Map<String, NewestLive>,
        cats: List<String>,
    ): String {
        val newest = cats.asSequence()
            .mapNotNull(newestByCategory::get)
            .maxByOrNull { it.at }
            ?: return "no detections"
        return "last ${newest.category} ${relativeAgo(newest.at)}"
    }

    /** The face shown while only a firmware update holds the service: a static keep-alive. */
    private fun buildOtaHold(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("FIRMWARE UPDATE")
            .setContentText("Sending the update to your board.")
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setContentIntent(tapIntent())
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

    /** Short "ago" string, same tiers as the dossier's relativeAgo. */
    private fun relativeAgo(ms: Long?): String {
        if (ms == null) return "now"
        val secs = ((System.currentTimeMillis() - ms) / 1000).coerceAtLeast(0)
        return when {
            secs < 5 -> "now"
            secs < 60 -> "${secs}s ago"
            secs < 3600 -> "${secs / 60}m ago"
            secs < 86_400 -> "${secs / 3600}h ago"
            else -> "${secs / 86_400}d ago"
        }
    }

    /** The redacted lock-screen face: no counts, no breakdown - just "active". */
    private fun buildPublic(tap: PendingIntent): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle("LIVE MODE")
            .setContentText("Active · counts in app")
            .setOngoing(true)
            .setShowWhen(false)
            .setContentIntent(tap)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .build()

    /** Tap opens the app on the Log tab with the NEW filter active (F27 deep link). */
    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        this, 0,
        Intent(this, MainActivity::class.java)
            .putExtra(MainActivity.EXTRA_OPEN_LOG_NEW, true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /** Android 16 (API 36) "Live Update": promote the ongoing notification so the OS shows
     *  a compact status-bar chip with the count. */
    private fun promoteIfSupported(
        b: NotificationCompat.Builder,
        total: Int,
        connected: Boolean,
        redact: Boolean,
    ) {
        // Android 16 (API 36) "Live Update": promote the ongoing notification to a compact
        // status-bar chip showing the count (the Dynamic-Island analog). On API 26-35 these
        // calls are skipped and the plain ongoing notification is the universal fallback.
        if (Build.VERSION.SDK_INT >= 36) {
            b.setRequestPromotedOngoing(true)
            // Two independent reasons to drop the number:
            //
            // REDACTION. setVisibility/setPublicVersion above govern the notification the lock
            // screen LISTS. They say nothing about the promoted chip, which SystemUI renders from
            // shortCriticalText on the notification itself, so the count could still be sitting in
            // the status bar of a locked phone belonging to a user who turned this toggle on
            // precisely to deny that glance. The promotion stays (the chip is still the "Live
            // Mode" state, which is all the redacted face claims); only the tally goes.
            //
            // STALENESS. Only surface the count while the board is actually linked. When it
            // disconnects or powers off, the chip must not keep flashing the last tally as if it
            // were live - drop the number so the chip goes to the plain state (the body already
            // reads "Reconnecting…"). This mirrors the iOS Live Activity fix: no stale count on the
            // glanceable surface once the link is gone. (Drive mode also fully ends on a real
            // disconnect via cleanup(); this covers the brief reconnecting window and any state
            // where connected is false.)
            b.setShortCriticalText(shortCriticalText(total, connected, redact))
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val ch = NotificationChannel(CHANNEL_ID, "Live Mode", NotificationManager.IMPORTANCE_LOW).apply {
            description = "Live proximity detection counter while your beacon is connected"
            setShowBadge(false)
        }
        nm()?.createNotificationChannel(ch)
    }

    private fun startForegroundCompat(n: Notification): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // The location type is what keeps fixes flowing once the activity is gone, so drive
                // mode stops pinning every hit on wherever we last had one. OR it in ONLY when the
                // permission is actually held: location is optional here (the manager owns the
                // process-wide location listener via syncLocationOwnership, gated on permission),
                // and Android 14+ throws SecurityException on a declared type the app
                // has no permission for, which would kill drive mode outright for a user who declined.
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
                // An OTA-only hold never owns location. Adding the location type merely because
                // permission exists would make a valid background connected-device OTA fail the
                // Android 14 while-in-use location gate.
                if (ble.driveModeOn && hasLocationPermission()) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
                }
                startForeground(NOTIF_ID, n, types)
            } else {
                startForeground(NOTIF_ID, n)
            }
            true
        } catch (e: Exception) {
            // Never let a foreground-service start crash the process. Android 14+ throws
            // SecurityException if we assert the connectedDevice type without BLUETOOTH_CONNECT (a
            // store reviewer who denied Bluetooth then triggered Drive mode in the demo), and can
            // throw ForegroundServiceStartNotAllowedException. Degrade: drop the service so Drive
            // mode simply doesn't engage, rather than taking down the app.
            android.util.Log.w("AcabLinkService", "startForeground failed; stopping service", e)
            // The service is going down without anyone calling stop(): keep the bookkeeping in
            // sync with reality. Clear the holder set so a later hold-release (OTA/combined)
            // doesn't find a stale "drive" entry, skip stopService, and resurrect a drive-mode
            // notification the user never re-requested; and reset the manager's drive flag so
            // the in-app switch and the QS tile stop claiming ACTIVE for a service that never
            // engaged. suspendDriveMode() re-enters stop(), which is a no-op on the cleared set,
            // while preserving the user's preference for the next usable link.
            holders.clear()
            runCatching { if (ble.driveModeOn) ble.suspendDriveMode() }
            stopSelf()
            false
        }
    }

    private fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun nm(): NotificationManager? =
        getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager

    companion object {
        /** Public: DetectionNotifier.liveChannelDeliverable checks THIS channel's importance,
         *  so deliverability is always judged against the id the service actually posts on. */
        const val CHANNEL_ID = "acab.drive"
        private const val NOTIF_ID = 1001

        /** The buckets drive mode speaks, in the order the expanded shade lists them. The
         *  headline count, the Android-16 status chip and the breakdown all read this one
         *  list, so the title can never claim more than the rows below it explain. Desert
         *  mode's NEARBY rows and WATCHED re-sightings are excluded deliberately, matching the
         *  iOS Live Activity. Network cameras join only when their board toggle is enabled.
         *  These are DeviceType.category identifiers, not display text. */
        // Canonical order. NETWORK CAMERA joined 2026-07-31 when the breakdown became
        // toggle-driven: it was excluded as an opt-in that would dilute the buckets, but a
        // category that only appears once you enable it dilutes nothing.
        private val DRIVE_CATS =
            listOf("ALPR", "DRONE", "BODY CAM", "TRACKER", "GLASSES", "CAMERA")
        /** Shown before any status frame arrives: the five categories that existed before the
         *  network-camera column, named explicitly so reordering DRIVE_CATS cannot change it. */
        private val PRE_STATUS_CATS =
            listOf("ALPR", "DRONE", "BODY CAM", "TRACKER", "GLASSES")
        /** Stands in for the feed on the OTA keep-alive face, which reads none of it. Shared and
         *  immutable, so skipping the walk costs no allocation of its own. */
        private val EMPTY_NEARBY = NearbySnapshot(emptyList(), emptyMap())
        // Render cadence. The surface is glanceable (relative ages in seconds/minutes), so
        // 2 s is plenty; unchanged faces are skipped before the build + IPC anyway.
        private const val RENDER_SAMPLE_MS = 2_000L
        private const val NEARBY_REFRESH_MS = 5_000L

        /** Start reasons. Drive mode and an in-flight OTA hold the service independently -
         *  endDriveMode used to stop it unconditionally, which would also have killed an OTA's
         *  process keep-alive (and vice versa); stop() only tears the service down when the
         *  last holder releases. */
        const val HOLD_DRIVE = "drive"
        const val HOLD_OTA = "ota"
        // The one-click combined update holds the service across BOTH legs: the S3 OTA releases its
        // own HOLD_OTA on its DONE, so without this independent hold the process could be frozen in
        // the seam between the S3 finishing and the nRF DFU starting (and through the nRF leg, which
        // takes no hold of its own).
        const val HOLD_COMBINED = "combined"
        private val holders = java.util.Collections.synchronizedSet(mutableSetOf<String>())

        /** Bumped once per start request, and handed back if the framework refuses it. An instance
         *  stamps it in onStartCommand and compares it in onDestroy, which is how a stop/restart
         *  race is told apart from a real teardown; see servedStartGeneration. Written under
         *  start()'s monitor, read from the service callbacks, hence @Volatile. */
        @Volatile private var startGeneration = 0L

        /** The highest generation any instance has actually STAMPED in onStartCommand. onDestroy
         *  compares against this AND against startGeneration, because neither alone is enough.
         *  This one alone misses a replacement whose start was accepted but whose callback has not
         *  landed yet. startGeneration alone once made a genuine teardown look superseded by a
         *  claim no instance would ever serve, so it skipped cleanup and left the holder set and
         *  _driveMode standing with no service behind either - which is safe to compare against
         *  now only because start() rolls the counter back when the framework refuses a start. */
        @Volatile private var servedGeneration = -1L

        @Synchronized
        fun start(context: Context, holder: String = HOLD_DRIVE): Boolean {
            val holderAdded = holders.add(holder)
            // Claimed BEFORE the call, not after it: onStartCommand reads this counter, and on a
            // start issued off the main thread the framework could deliver that callback while we
            // were still returning. Rolled back below when the start is refused.
            val generation = ++startGeneration
            val accepted = runCatching {
                ContextCompat.startForegroundService(context, Intent(context, AcabLinkService::class.java))
            }.getOrNull() != null
            if (!accepted) {
                // A rejected background/permission start never creates a Service callback to clean
                // this holder up. A null ComponentName is also a refusal: callers now rely on this
                // Boolean as the request boundary before they wait for foreground promotion.
                // Roll it back here so a later valid start is not pinned forever.
                if (rejectedForegroundRequestRemovesHolder(holderAdded, accepted)) {
                    holders.remove(holder)
                }
                // Same for the generation: no instance will ever serve it, and leaving it claimed
                // would retire the live instance's right to clean up after itself. Safe to compare
                // and assign because this whole method holds the companion's monitor.
                if (startGeneration == generation) startGeneration = generation - 1
            }
            return accepted
        }

        @Synchronized
        fun stop(context: Context, holder: String = HOLD_DRIVE) {
            holders.remove(holder)
            if (holders.isEmpty()) runCatching {
                context.stopService(Intent(context, AcabLinkService::class.java))
            }
        }
    }
}
