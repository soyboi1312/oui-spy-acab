package tech.acab.app.ble

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import tech.acab.app.MainActivity
import tech.acab.app.R
import tech.acab.app.model.Detection
import tech.acab.app.model.DeviceType
import tech.acab.app.model.displayName
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Per-category phone notifications for detections. Mirrors iOS DetectionNotifier rule for rule.
 *
 * WHY THIS IS SEPARATE FROM AlertMode: AlertMode governs the BOARD's buzzer (and, in VIBRATE, an
 * in-app haptic). Silencing the board is not the same decision as silencing your phone.
 *
 * ITS OWN CHANNEL, NOT the foreground-service one. AcabLinkService's channel is IMPORTANCE_LOW by
 * design (a persistent status line must never buzz). Detection alerts need HIGH, and the user must
 * be able to tune or mute one without losing the other, which a shared channel forbids.
 *
 * DESIGN RULES:
 *  - Per CATEGORY, opt-in, every one default OFF.
 *  - THE COOLDOWN IS THE EDGE, not the caller's first-sighting flag. The first version gated on
 *    AcabBleManager's `firstTime`, but the detection store is PERSISTED across launches, so a
 *    device seen in any earlier session was never "first" again and could never notify.
 *  - Never for ignored devices (dropped before the hook), never for Desert-mode NEARBY_DEVICE.
 *  - POST_NOTIFICATIONS (API 33+) requested lazily on the first enable.
 *
 * THREADING: the detection path runs on a BINDER thread. BluetoothGattCallback.onCharacteristicChanged
 * -> ingest() -> fileLive() -> here, none of which hops to main. The rate-limit state is therefore
 * concurrent-safe by construction (ConcurrentHashMap + AtomicLong) rather than by assumption; the
 * first version used a plain HashMap and a plain Long, which is a genuine data race next to
 * AcabBleManager's own synchronized(storeLock) neighbours.
 */
class DetectionNotifier(private val ctx: Context) {

    companion object {
        const val CHANNEL_ID = "acab_detections"
        private const val PREFS = "acab"
        private const val KEY_PREFIX = "notify_"

        /** The real rate limit, matching iOS and the settings copy. */
        private const val PER_DEVICE_COOLDOWN_MS = 600_000L    // 10 minutes

        /**
         * Floor between notifications for DIFFERENT devices. Small on purpose: it suppresses one
         * alert, and because the cooldown (not a first-sighting flag) is the edge, the device is
         * offered again on its next sighting rather than lost.
         */
        private const val GLOBAL_MIN_GAP_MS = 4_000L

        /** Prune the cooldown map past this size so a long drive cannot grow it without bound. */
        private const val COOLDOWN_PRUNE_AT = 256

        /**
         * Categories a user can switch on. ONE ALPR row: everywhere else in both apps FLOCK_CAMERA
         * and FLOCK_RAVEN are a single "ALPR" category, and Raven is an acoustic sensor rather than
         * a plate reader, so a separate row subtitled "plate readers" was both a duplicate-looking
         * row and factually wrong. NEARBY_DEVICE is excluded (Desert is ambient, not an event).
         */
        val NOTIFIABLE = listOf(
            DeviceType.FLOCK_CAMERA, DeviceType.BODY_CAM, DeviceType.GLASSES,
            DeviceType.NETWORK_CAMERA, DeviceType.DRONE, DeviceType.TRACKER, DeviceType.WATCHED,
        )

        private fun key(t: DeviceType) = "$KEY_PREFIX${t.raw}"

        /** Cached: the detection path consults this per record, and it used to be up to 8 prefs
         *  reads (each taking a lock) on every one. */
        @Volatile private var enabledCache: Set<Int>? = null

        private fun rebuildCache(ctx: Context) {
            val p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val s = HashSet<Int>()
            NOTIFIABLE.forEach { t ->
                if (p.getBoolean(key(t), false)) {
                    s.add(t.raw)
                    // ALPR is one category; RAVEN has no row and follows FLOCK_CAMERA's switch.
                    if (t == DeviceType.FLOCK_CAMERA) s.add(DeviceType.FLOCK_RAVEN.raw)
                }
            }
            enabledCache = s
        }

        fun isEnabled(ctx: Context, t: DeviceType): Boolean {
            val c = enabledCache ?: run { rebuildCache(ctx); enabledCache }
            return c?.contains(t.raw) == true
        }

        fun setEnabled(ctx: Context, t: DeviceType, on: Boolean) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putBoolean(key(t), on).apply()
            rebuildCache(ctx)
        }

        fun anyEnabled(ctx: Context): Boolean {
            val c = enabledCache ?: run { rebuildCache(ctx); enabledCache }
            return c?.isNotEmpty() == true
        }

        /** API 33+ gates posting behind a runtime permission; below that it is implicit. */
        fun hasPostPermission(ctx: Context): Boolean =
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED

        /** True when a category is on but the system will not deliver, so the UI can say so
         *  instead of showing a green toggle over a dead feature. */
        fun mutedBySystem(ctx: Context): Boolean {
            if (!anyEnabled(ctx)) return false
            if (!hasPostPermission(ctx)) return true
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return true
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return false
            val ch = nm.getNotificationChannel(CHANNEL_ID) ?: return false
            return ch.importance == NotificationManager.IMPORTANCE_NONE
        }

        /** True when the Live Mode foreground notification can actually reach the shade:
         *  runtime permission held, app-level notifications on, and the drive channel not
         *  muted. THE single owner of this rule: MainActivity's automatic Live Mode start and
         *  the Beacon readiness surface both read it, so they can never disagree about the
         *  same phone. A null channel passes (it is created on the first service start). */
        fun liveChannelDeliverable(ctx: Context): Boolean {
            if (!hasPostPermission(ctx) ||
                !NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return false
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            return nm?.getNotificationChannel(AcabLinkService.CHANNEL_ID)?.importance !=
                NotificationManager.IMPORTANCE_NONE
        }
    }

    private val lastByMac = ConcurrentHashMap<String, Long>()
    private val lastAt = AtomicLong(0L)

    init {
        // Created up front, not on first post, so the channel exists in system settings for the
        // user to tune BEFORE anything is ever detected.
        ensureChannel()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "Detections", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Alerts for the detection categories you switched on."
                enableVibration(true)
            }
        )
    }

    /** Same target as the drive-mode notification: open the app on the new-detections log. */
    private fun tapIntent(): PendingIntent = PendingIntent.getActivity(
        ctx, 1,
        Intent(ctx, MainActivity::class.java).putExtra(MainActivity.EXTRA_OPEN_LOG_NEW, true),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * Post for a detection if its category is on and the rate limits allow.
     *
     * REDACTION: [redact] is the app's LOCK-SCREEN setting, so it is applied the way Android
     * actually models that, via setPublicVersion, exactly as AcabLinkService.buildPublic already
     * does for drive mode. The first version redacted the main content instead, which hid the
     * category on an UNLOCKED phone too, i.e. in the state the feature exists for. (Redaction
     * itself now defaults OFF; this path only runs for users who turned it on.)
     */
    fun notifyIfNeeded(d: Detection, redact: Boolean) {
        if (d.hist) return                             // an offline replay is not a live event
        if (d.type == DeviceType.NEARBY_DEVICE) return // Desert rows are ambient, never an alert
        if (!isEnabled(ctx, d.type)) return
        if (!hasPostPermission(ctx)) return

        val now = System.currentTimeMillis()
        val prev = lastByMac[d.mac]
        if (prev != null && now - prev < PER_DEVICE_COOLDOWN_MS) return
        // Burst floor for DIFFERENT devices. Safe to drop: the device is not marked, so its next
        // sighting is offered again.
        if (now - lastAt.get() < GLOBAL_MIN_GAP_MS) return

        lastByMac[d.mac] = now
        lastAt.set(now)
        pruneCooldowns(now)

        val who = d.displayName.ifBlank { d.type.label }
        val body = if (who == d.type.label) "Detected nearby, ${d.confidence}% confidence."
                   else "$who detected, ${d.confidence}% confidence."

        val b = NotificationCompat.Builder(ctx, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_stat_beacons)
            .setContentTitle(d.type.label)
            .setContentText(body)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            // STATUS, not ALARM. CATEGORY_ALARM punches through Do Not Disturb, which contradicts
            // the sibling haptic path that deliberately honours DND via focusSuppressed(), and is
            // not a promise this feature should be making on the user's behalf.
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(tapIntent())
        if (redact) {
            b.setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            b.setPublicVersion(
                NotificationCompat.Builder(ctx, CHANNEL_ID)
                    .setSmallIcon(R.drawable.ic_stat_beacons)
                    .setContentTitle("beacons")
                    .setContentText("Something was detected nearby.")
                    .setContentIntent(tapIntent())
                    .build()
            )
        } else {
            b.setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        }
        try {
            // Per-MAC id so a repeat REPLACES rather than stacks. Tagged so it cannot collide with
            // the foreground-service notification's own id space.
            NotificationManagerCompat.from(ctx).notify("acab.det", d.mac.hashCode(), b.build())
        } catch (_: SecurityException) {
            // Permission revoked between the check above and the post. The next enable re-requests.
        }
    }

    private fun pruneCooldowns(now: Long) {
        if (lastByMac.size <= COOLDOWN_PRUNE_AT) return
        lastByMac.entries.removeAll { now - it.value >= PER_DEVICE_COOLDOWN_MS }
    }

    /** Drop cooldown state so a genuinely new session can alert on the same devices again. */
    fun reset() {
        lastByMac.clear()
        lastAt.set(0L)
    }
}
