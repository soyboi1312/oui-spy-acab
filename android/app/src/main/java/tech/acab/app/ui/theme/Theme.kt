package tech.acab.app.ui.theme

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import tech.acab.app.R
import tech.acab.app.model.DeviceType

/** Display face (Space Grotesk) and data face (JetBrains Mono), the same TTFs the
 *  iOS app bundles. Space Grotesk only ships three weights, so SemiBold reuses Bold. */
val SpaceGrotesk = FontFamily(
    Font(R.font.space_grotesk_regular, FontWeight.Normal),
    Font(R.font.space_grotesk_medium, FontWeight.Medium),
    Font(R.font.space_grotesk_bold, FontWeight.SemiBold),
    Font(R.font.space_grotesk_bold, FontWeight.Bold),
)
val JetBrainsMono = FontFamily(
    Font(R.font.jetbrains_mono_regular, FontWeight.Normal),
    Font(R.font.jetbrains_mono_medium, FontWeight.Medium),
    Font(R.font.jetbrains_mono_semibold, FontWeight.SemiBold),
    Font(R.font.jetbrains_mono_bold, FontWeight.Bold),
)

/** The complete colour token set for ONE contrast level. Two instances exist: [Normal] (the
 *  Crimson cyber-noir look, ported from the iOS ACABTheme) and [High] (what a request for more
 *  contrast resolves to). [Acab] exposes whichever is in force; nothing else reads these directly.
 *
 *  iOS twin: ACABPalette in Theme.swift. Shared hex values are identical; the alpha tint for
 *  `faint` differs per platform and each side documents its own measurement. The ratios quoted
 *  below are composited onto the surface named and are locked in by AcabPaletteTest. */
data class AcabPalette(
    val bg: Color, val bg2: Color, val bg3: Color,
    val line: Color, val lineStrong: Color,
    val text: Color, val dim: Color, val faint: Color,
    val accent: Color, val accentText: Color, val accentGlow: Color, val onAccent: Color,
    val warn: Color,
    val flockTone: Color, val droneTone: Color, val bodyCamTone: Color, val trackerTone: Color,
    val glassesTone: Color, val watchTone: Color, val netcamTone: Color, val sandTone: Color,
) {
    companion object {
        val Normal = AcabPalette(
            bg = Color(0xFF0C0A0B),
            bg2 = Color(0xFF161214),
            bg3 = Color(0xFF201A1D),
            line = Color(0x1CEC968C),        // rgb(236,150,140) @ 11%, matches iOS
            lineStrong = Color(0x4DEE4034),  // crimson @ 30%
            text = Color(0xFFF4EEF0),
            dim = Color(0x99F0E0E2),         // @ 60%
            // faint @ 54%, up from 33%. At 33% it measured ~2.5:1 against bg and this token carries
            // real instructions and privacy copy, not just ornament; 54% lands 4.98:1 on bg, 4.95:1
            // on bg2, 4.80:1 on bg3 (WCAG AA for body text on every surface it sits on) while
            // staying a visible step quieter than dim. Same base tint, so the palette reads unchanged.
            faint = Color(0x8AF0E0E2),       // @ 54%
            accent = Color(0xFFEE4034),      // crimson
            // Crimson AS TEXT. The fill accent measures 4.42:1 on bg3, under AA for text, and it
            // was used for 9sp version tags and 8sp category captions. This lighter cut clears 6:1
            // on every surface while reading as the same crimson next to a fill. Same hex as iOS.
            accentText = Color(0xFFFF6A5E),
            accentGlow = Color(0x8CEE4034),  // @ 55%
            onAccent = Color(0xFF120A0A),
            warn = Color(0xFFF2B53C),        // amber
            flockTone = Color(0xFFEE4034),
            droneTone = Color(0xFFF2B53C),
            bodyCamTone = Color(0xFFCDC1C3),
            trackerTone = Color(0xFF49C5B1),
            glassesTone = Color(0xFFB07CFF),     // violet, matches iOS glassesTone
            watchTone = Color(0xFFE0A84B),       // gold, user-starred (watched) devices, matches iOS
            netcamTone = Color(0xFF3D8BFF),      // blue, network cameras (IP-camera OUI on wifi), distinct from the teal tracker + violet glasses, matches iOS
            sandTone = Color(0xFFD1AB66),        // desert sand, nearby devices
        )

        /** Surfaces are untouched so the bg < bg2 < bg3 hierarchy still reads; what changes is
         *  everything drawn ON them. Secondary text clears 7:1 (AAA) on all three surfaces,
         *  crimson text clears 7:1, and the strong line (control boundaries, selected states)
         *  clears the 3:1 non-text minimum. The plain hairline stays a decorative divider:
         *  brighter than default, deliberately short of a control edge so a page of cards does
         *  not turn into a grid. */
        val High = AcabPalette(
            bg = Color(0xFF0C0A0B),
            bg2 = Color(0xFF161214),
            bg3 = Color(0xFF201A1D),
            line = Color(0x4DEC968C),        // @ 30%
            lineStrong = Color(0xB8FF5A4E),  // lighter crimson @ 72%: >= 3:1 on every surface
            text = Color(0xFFFFFFFF),
            dim = Color(0xD9F0E0E2),         // @ 85%
            faint = Color(0xBFF0E0E2),       // @ 75%
            accent = Color(0xFFFF5A4E),      // lighter crimson: dark-on-accent text still 6:1
            accentText = Color(0xFFFF8C82),
            accentGlow = Color(0xA6FF5A4E),  // @ 65%
            onAccent = Color(0xFF120A0A),
            warn = Color(0xFFF7C24E),
            flockTone = Color(0xFFFF5A4E),
            droneTone = Color(0xFFF7C24E),
            bodyCamTone = Color(0xFFE4DADC),
            trackerTone = Color(0xFF6FE0CE),
            glassesTone = Color(0xFFC9A6FF),
            watchTone = Color(0xFFF0BE5E),
            netcamTone = Color(0xFF74ACFF),
            sandTone = Color(0xFFE0BE7A),
        )
    }
}

/** The "Crimson" palette in force, plus type and shape tokens.
 *
 *  Every colour is a getter over [palette], a Compose snapshot state. A composable that reads
 *  `Acab.text` therefore recomposes when ContrastMode swaps the palette, with no plumbing at the
 *  ~500 call sites. Anything that CACHES a rendered colour (map marker bitmaps) must key its
 *  cache on [highContrast]; see MapMarkers.kt. */
object Acab {
    /** Set only by ContrastMode. */
    var palette: AcabPalette by mutableStateOf(AcabPalette.Normal)
        internal set

    /** True while the higher-contrast palette is in force. Use as a remember() key. */
    val highContrast: Boolean get() = palette === AcabPalette.High

    val bg: Color get() = palette.bg
    val bg2: Color get() = palette.bg2
    val bg3: Color get() = palette.bg3
    val line: Color get() = palette.line
    val lineStrong: Color get() = palette.lineStrong

    val text: Color get() = palette.text
    val dim: Color get() = palette.dim
    val faint: Color get() = palette.faint

    val accent: Color get() = palette.accent
    /** Crimson for TEXT and digits. Use [accent] for fills, bars, strokes and tints of things a
     *  user does not have to read; use this for words drawn in crimson. */
    val accentText: Color get() = palette.accentText
    val accentGlow: Color get() = palette.accentGlow
    val onAccent: Color get() = palette.onAccent
    val warn: Color get() = palette.warn

    val flockTone: Color get() = palette.flockTone
    val droneTone: Color get() = palette.droneTone
    val bodyCamTone: Color get() = palette.bodyCamTone
    val trackerTone: Color get() = palette.trackerTone
    val glassesTone: Color get() = palette.glassesTone
    val watchTone: Color get() = palette.watchTone
    val netcamTone: Color get() = palette.netcamTone
    val sandTone: Color get() = palette.sandTone

    val display = SpaceGrotesk          // default non-mono face
    val mono = JetBrainsMono            // data and label face

    val radius = 18.dp
    val radiusSm = 12.dp
    val pad = 20.dp         // screen insets, matches the iOS 20pt spec
    val padCard = 16.dp     // card interiors keep the tighter padding
}

/** The tone color for a detection type: fills, pins, bars, icons. */
fun DeviceType.tone(): Color = when (this) {
    DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> Acab.flockTone
    DeviceType.DRONE -> Acab.droneTone
    DeviceType.BODY_CAM -> Acab.bodyCamTone
    DeviceType.TRACKER -> Acab.trackerTone
    DeviceType.GLASSES -> Acab.glassesTone
    DeviceType.NEARBY_DEVICE -> Acab.sandTone          // desert sand
    DeviceType.WATCHED -> Acab.watchTone            // gold star, the user's own rule
    DeviceType.NETWORK_CAMERA -> Acab.netcamTone    // blue, IP camera on wifi
    DeviceType.UNKNOWN -> Acab.dim
}

/** The tone color for TEXT in a detection type's colour. Only crimson differs from [tone]: the
 *  fill accent measures under AA as text on the raised surface, so words in the Flock colour use
 *  [Acab.accentText]. iOS twin: DeviceType.textTint. */
fun DeviceType.textTone(): Color = when (this) {
    DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> Acab.accentText
    else -> tone()
}
