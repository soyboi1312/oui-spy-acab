package tech.acab.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraOutdoor
import androidx.compose.material.icons.filled.Flight
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.Radar
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import tech.acab.app.model.DeviceType
import tech.acab.app.model.TimeBasis
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import kotlin.math.pow
import kotlin.math.roundToInt

/** True when the user has zeroed the system animator duration scale (the OS-level "remove
 *  animations" accessibility setting). Looping ornaments (radar sweep, breathing dots) key off
 *  this so a motion-sensitive user's screen holds still. Read FRESH on every call, no remember:
 *  the old cache rested on "changing the setting recreates activities", which is false - it is
 *  not a configuration change, so a cached read held the stale verdict until process death and
 *  a user who just turned animations off kept getting them. Settings.Global.getFloat is one
 *  cheap provider read, and this runs on composition of the ornament, not per frame. */
@Composable
fun rememberReduceMotion(): Boolean {
    val context = androidx.compose.ui.platform.LocalContext.current
    return android.provider.Settings.Global.getFloat(
        context.contentResolver,
        android.provider.Settings.Global.ANIMATOR_DURATION_SCALE, 1f,
    ) == 0f
}

/** Small uppercase mono label, for section headers and data captions.
 *  Deliberately NOT lowercased at the component: the caps + 1.6 tracking is what separates
 *  instrument chrome (labels) from content (device names, prose). 10.5/1.6 are the iOS
 *  Kicker metrics; the two platforms share the same JetBrains Mono face, so they match.
 *  [pinned] divides the metrics by fontScale for the rare kicker that is an ORNAMENT beside a
 *  number that already scales (iOS pins those with a fixed size): the information is in the
 *  number, and letting both grow blows the composition apart at large font scales. */
@Composable
fun Kicker(text: String, color: androidx.compose.ui.graphics.Color = Acab.faint, pinned: Boolean = false) {
    val fs = if (pinned) LocalDensity.current.fontScale else 1f
    Text(
        text,
        color = color,
        fontSize = 10.5.sp / fs,
        letterSpacing = 1.6.sp / fs,
        fontWeight = FontWeight.Medium,
        fontFamily = Acab.mono,
    )
}

/** Card look: bg2 fill, hairline border, rounded corners. Interior padding is the
 *  card token [Acab.padCard]; screen insets use the larger [Acab.pad]. */
fun Modifier.panel(strong: Boolean = false): Modifier = this
    .background(Acab.bg2, RoundedCornerShape(Acab.radius))
    .border(1.dp, if (strong) Acab.lineStrong else Acab.line, RoundedCornerShape(Acab.radius))
    .padding(Acab.padCard)

/** The one EXP tag for experimental detectors: tinted amber, matching on both platforms.
 *  Amber text on amber 14% fill with an amber 40% border, radius 4. */
@Composable
fun ExpTag() {
    Text(
        "EXP",
        color = Acab.warn,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.warn.copy(alpha = 0.14f), RoundedCornerShape(4.dp))
            .border(1.dp, Acab.warn.copy(alpha = 0.4f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** The RECON tag: this row's time was reconstructed from board uptime, not read off a clock.
 *  Same small-badge anatomy as [ExpTag], on the neutral palette, because it is provenance rather
 *  than an alert. In a dense list the tag is the whole story; the dossier spells it out. */
@Composable
fun ReconTag() {
    Text(
        "RECON",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** Sibling of [ReconTag] for a record the app could only bound between two boots. Says RANGE,
 *  not a time, because there is no time here to shorten. */
@Composable
fun RangeTag() {
    Text(
        "RANGE",
        color = Acab.dim,
        fontSize = 9.sp,
        letterSpacing = 1.sp,
        fontWeight = FontWeight.Bold,
        fontFamily = Acab.mono,
        modifier = Modifier
            .background(Acab.bg3, RoundedCornerShape(4.dp))
            .border(1.dp, Acab.line, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    )
}

/** What a buffered row says instead of an age when the board recorded only the order of a
 *  sighting and nothing bounds it. Never fabricate the pseudo-stamp into "24 years ago". */
const val APPROX_TIME = "time unknown · offline buffer"

/** Within the last six days, a weekday or bare clock reading is unambiguous and much easier
 *  to read than a full date. Past that it isn't, so the date comes back. The same window as
 *  iOS TimeBasisCopy.isRecent, so both platforms flip format on the same record. */
private fun isRecentStamp(atMs: Long): Boolean {
    val age = System.currentTimeMillis() - atMs
    return age >= 0 && age < 6 * 86_400_000L
}

/** Clock for a reconstructed stamp, e.g. "~14:32:07", or "~Mar 4, 14:32:07" once it's older
 *  than the recency window. The tilde is the dense shorthand for "derived"; the qualifier
 *  line under the value spells it out. Format mirrors iOS TimeBasisCopy.value. Locale.US
 *  pins the month names and 24-hour clock the way iOS's en_US_POSIX formatter does. */
fun reconTimeText(atMs: Long): String =
    "~" + DateTimeFormatter.ofPattern(if (isRecentStamp(atMs)) "HH:mm:ss" else "MMM d, HH:mm:ss", Locale.US)
        .format(Instant.ofEpochMilli(atMs).atZone(ZoneId.systemDefault()))

/** Day + clock at minute resolution for a bracket endpoint, e.g. "Tue 14:00", falling back to
 *  "Mar 4, 14:00" past the recency window (a bare weekday stops being unambiguous). Minutes,
 *  not seconds: the endpoints are bounds, and printing them to the second would dress a bound
 *  up as a measurement. */
fun bracketTimeText(atMs: Long): String =
    DateTimeFormatter.ofPattern(if (isRecentStamp(atMs)) "EEE HH:mm" else "MMM d, HH:mm", Locale.US)
        .format(Instant.ofEpochMilli(atMs).atZone(ZoneId.systemDefault()))

/** The one-line time a row shows, with its qualification built in. [TimeBasis.Exact] returns
 *  null: a live stamp renders exactly as it always has, and this model adds nothing to it. */
fun TimeBasis.primaryText(): String? = when (this) {
    is TimeBasis.Exact -> null
    is TimeBasis.Reconstructed -> reconTimeText(atMs)
    is TimeBasis.Bracketed -> {
        val a = afterMs; val z = beforeMs
        when {
            a != null && z != null -> "between ${bracketTimeText(a)} and ${bracketTimeText(z)}"
            a != null -> "after ${bracketTimeText(a)}"
            else -> "before ${bracketTimeText(z!!)}"
        }
    }
    is TimeBasis.Unknown -> APPROX_TIME
}

/** The secondary line under [primaryText]: how the number was arrived at, in plain words.
 *  Null where the primary line already says everything there is to say. */
fun TimeBasis.qualifierText(): String? = when (this) {
    is TimeBasis.Exact -> null
    is TimeBasis.Reconstructed -> "reconstructed from device uptime, +/-${precisionSec}s"
    is TimeBasis.Bracketed -> "the beacon restarted, so this is bounded, not measured"
    // The primary line already says "time unknown", but not WHY; iOS spells it out and an
    // evidence reader deserves the reason on both platforms.
    is TimeBasis.Unknown -> "the beacon had no clock reference for this record"
}

internal fun DeviceType.icon(): ImageVector = when (this) {
    DeviceType.FLOCK_CAMERA -> Icons.Filled.PhotoCamera
    DeviceType.FLOCK_RAVEN -> Icons.Filled.GraphicEq
    DeviceType.BODY_CAM -> Icons.Filled.Videocam
    DeviceType.DRONE -> Icons.Filled.Flight
    DeviceType.TRACKER -> Icons.Filled.Sensors
    DeviceType.GLASSES -> Icons.Filled.RemoveRedEye
    DeviceType.NEARBY_DEVICE -> Icons.Filled.Radar
    DeviceType.WATCHED -> Icons.Filled.Star
    // wall-mounted surveillance-camera glyph, distinct from the flock PhotoCamera + body-cam Videocam
    DeviceType.NETWORK_CAMERA -> Icons.Filled.CameraOutdoor
    DeviceType.UNKNOWN -> Icons.AutoMirrored.Filled.HelpOutline
}

/** Category glyph sitting in a tinted rounded tile. [filled] swaps the neutral bg3
 *  fill for the type's tone at 16%, for hero placements like the strongest-signal card. */
@Composable
fun CatGlyph(type: DeviceType, size: Int = 34, filled: Boolean = false) {
    Box(
        modifier = Modifier
            .size(size.dp)
            .background(if (filled) type.tone().copy(alpha = 0.16f) else Acab.bg3,
                RoundedCornerShape((size * 0.32f).dp))
            .border(1.dp, Acab.line, RoundedCornerShape((size * 0.32f).dp)),
        contentAlignment = Alignment.Center,
    ) {
        // Always decorative: every CatGlyph sits beside text that names the category/device.
        // Announcing both produced duplicate TalkBack nodes ("Drone, Drone").
        Icon(type.icon(), contentDescription = null, tint = type.tone(),
            modifier = Modifier.size((size * 0.5f).dp))
    }
}

/** Four rising bars for signal strength (0..4). */
@Composable
fun SignalBars(bars: Int, tint: androidx.compose.ui.graphics.Color = Acab.accent) {
    Row(verticalAlignment = Alignment.Bottom) {
        for (i in 0 until 4) {
            Box(
                Modifier
                    .padding(end = 2.dp)
                    .width(3.dp)
                    .height((5 + i * 3).dp)
                    .background(if (i < bars) tint else Acab.line, RoundedCornerShape(1.dp))
            )
        }
    }
}

/** RSSI to a 0..4 bar count. */
fun rssiBars(rssi: Int): Int = when {
    rssi < -90 -> 1
    rssi < -80 -> 2
    rssi < -67 -> 3
    else -> 4
}

/** Rough RSSI-to-distance in meters, the same log-distance model the map uses
 *  (10^((-50 - rssi) / 25)), clamped to a sane 5..600 m so the number stays honest. */
fun approxMeters(rssi: Int): Int =
    10.0.pow((-50.0 - rssi) / 25.0).roundToInt().coerceIn(5, 600)

/** Status pill: amber DEMO in sample-data mode, crimson LINKED + version when
 *  connected, or faint OFFLINE otherwise. Shared by the Status and Map headers. */
@Composable
fun LinkChip(version: String?, demo: Boolean = false) {
    val connected = version != null
    val tone = when {
        demo -> Acab.warn
        connected -> Acab.accent
        else -> Acab.faint
    }
    val label = when {
        demo -> "DEMO"
        connected -> "CONNECTED"
        else -> "OFFLINE"
    }
    val labelTone = when {
        demo -> Acab.warn
        connected -> Acab.dim
        else -> Acab.faint
    }
    Row(
        Modifier
            .background(Acab.bg2, CircleShape)
            .border(1.dp, if (demo) Acab.warn.copy(alpha = 0.4f) else Acab.line, CircleShape)
            .padding(horizontal = 11.dp, vertical = 7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(7.dp).background(tone, CircleShape))
        Spacer(Modifier.size(6.dp))
        Kicker(label, color = labelTone)
    }
}
