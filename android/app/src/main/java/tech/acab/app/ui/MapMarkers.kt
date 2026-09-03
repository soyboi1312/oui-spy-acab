package tech.acab.app.ui

import android.graphics.Paint
import android.graphics.drawable.BitmapDrawable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Person
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Canvas
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.ColorFilter
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.drawscope.CanvasDrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.dp
import tech.acab.app.model.DeviceType
import tech.acab.app.ui.theme.Acab
import tech.acab.app.ui.theme.tone

/** Map marker icons, one per detection type, like the iOS pins: a filled dot in the
 *  category tone, with a dark ring and the category glyph. Built once per type and
 *  reused across all of that type's markers. */
@Composable
fun rememberCategoryMarkers(): Map<DeviceType, BitmapDrawable> = categoryMarkers(dim = false)

/** The same pin set drawn in the STALE recency tier (see PinAge in MapScreen.kt): the tone is
 *  desaturated and pulled toward the background, the geometry is untouched. A separate bitmap set
 *  rather than a draw-time tint, because these markers are static bitmaps handed to osmdroid once
 *  and then reused, and a per-draw colour filter would run on the map's draw path instead of the
 *  gated rebuild that picks the tier. Same size and same anchor as the full-colour set, so a pin
 *  that goes stale never moves or shrinks. */
@Composable
fun rememberDimCategoryMarkers(): Map<DeviceType, BitmapDrawable> = categoryMarkers(dim = true)

@Composable
private fun categoryMarkers(dim: Boolean): Map<DeviceType, BitmapDrawable> = mapOf(
    DeviceType.FLOCK_CAMERA to rememberCategoryMarker(DeviceType.FLOCK_CAMERA, dim),
    DeviceType.FLOCK_RAVEN to rememberCategoryMarker(DeviceType.FLOCK_RAVEN, dim),
    DeviceType.BODY_CAM to rememberCategoryMarker(DeviceType.BODY_CAM, dim),
    DeviceType.DRONE to rememberCategoryMarker(DeviceType.DRONE, dim),
    DeviceType.TRACKER to rememberCategoryMarker(DeviceType.TRACKER, dim),
    DeviceType.GLASSES to rememberCategoryMarker(DeviceType.GLASSES, dim),
    // Network cameras grid-cluster with the other high-volume types, but a lone member still
    // renders as an individual pin via markers.getValue(d.type); without this entry a located
    // NETWORK_CAMERA would throw NoSuchElementException the moment that pin is drawn.
    DeviceType.NETWORK_CAMERA to rememberCategoryMarker(DeviceType.NETWORK_CAMERA, dim),
    DeviceType.NEARBY_DEVICE to rememberCategoryMarker(DeviceType.NEARBY_DEVICE, dim),
    DeviceType.WATCHED to rememberCategoryMarker(DeviceType.WATCHED, dim),
    DeviceType.UNKNOWN to rememberCategoryMarker(DeviceType.UNKNOWN, dim),
)

/** The STALE tier's version of a category tone: pulled part-way toward its own luminance grey so
 *  it desaturates, then part-way toward the map's own background so it recedes. Both moves are
 *  deliberately partial. A stale pin is still a sighting the user may want, so it has to stay in
 *  its colour family and stay legible over the tiles; a tone taken all the way to grey, or all the
 *  way to the background, would have hidden the pin instead of dating it. Full alpha throughout,
 *  for the same reason. The RULE (desaturate + recede, never hide, never resize) is shared with
 *  iOS; each platform mixes in its own colour space against its own background. */
internal fun dimTone(tone: Color): Color {
    fun mix(a: Float, b: Float, k: Float) = a + (b - a) * k
    val lum = 0.299f * tone.red + 0.587f * tone.green + 0.114f * tone.blue
    fun channel(c: Float, bg: Float) = mix(mix(c, lum, 0.55f), bg, 0.30f)
    return Color(
        red = channel(tone.red, Acab.bg.red),
        green = channel(tone.green, Acab.bg.green),
        blue = channel(tone.blue, Acab.bg.blue),
        alpha = tone.alpha,
    )
}

/** A quiet hollow ring for a known/mapped ALPR camera (the on-by-default reference layer). Un-animated
 *  and low-contrast on purpose, so a mapped location never reads as a live detection.
 *
 *  RING-PEEK: [peek] draws the same ring WIDE, for the one case where a live detection pin lands on
 *  a mapped camera. A full-size pin covers the normal ring completely, so "live hit at a camera we
 *  already have on the map" looked exactly like "live hit somewhere unmapped". The wide rim shows
 *  around the pin instead. The radius moves and the FILL DROPS: tone, dash and stroke weight stay
 *  identical to the resting ring, but the peek variant is drawn hollow, because a wash across the
 *  peek radius would tint the exact standoff band the wide size exists to keep clear of ink. That
 *  is the settled shared rule - iOS ALPRDot drops its fill at the peek size for the same reason
 *  (`.fill(peek ? Color.clear : ...)`); the resting ring keeps its wash on both platforms. */
@Composable
fun rememberAlprMarker(confirmed: Boolean = true, peek: Boolean = false): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    // Confirmed rings stay the established red; unverified ones go amber AND DASHED. Colour alone
    // is not a distinction for a red/green-deficient viewer, and telling the two tiers apart is the
    // entire point of the second one. Mirrors iOS ALPRDot.
    val tone = if (confirmed) Acab.flockTone else Acab.warn
    return remember(density, confirmed, peek, Acab.highContrast) {
        with(density) {
            // Bolder 2026-07-29 (rings washed out on the map); keep in lockstep with iOS ALPRDot.
            // PEEK SIZE, derived from THIS platform's pin. The RULE is shared with iOS: the rim
            // clears the pin's own artwork, glow included, and leaves a readable gap. The NUMBER
            // is not, because the two pins are not the same size, and neither side gets to "fix"
            // the other's arithmetic to match.
            //   Android pin (rememberCategoryMarker, below): 15dp dot + 2dp dark border = 17dp
            //   radius, wrapped in the frozen pulse ring, stroked 1.5dp about a 19.75dp
            //   centreline. Its outermost ink is therefore at 20.5dp radius, 41dp across.
            //   Peek ring: 1.8dp of standoff, then the 2.2dp stroke. drawCircle straddles the
            //   radius it is given, so a 23.4dp centreline puts the rim at 22.3..24.5dp: 4dp of
            //   ring showing all the way round a 41dp pin, outer diameter 49dp. That 20.5..22.3dp
            //   standoff is bare map: the peek variant draws no fill (see the function doc), so
            //   the only ink inside the rim is the pin's own.
            // iOS reaches its 48pt off a 40pt pin footprint (28pt disc + 6pt shadow spread) by
            // the same construction. The RULE is shared; the numbers are each platform's own.
            // KNOWN, and accepted: with the optional "icon labels" setting on, the label pill
            // hangs 23dp below the pin centre and hides the rim's bottom chord (it draws over the
            // ring, because the detection markers are added after the reference folder). The top
            // and both sides still read, and clearing the PIN is what the cue is for.
            val r = if (peek) 23.4.dp.toPx() else 7.0.dp.toPx()
            // NOT thickened for the peek variant. 2.2dp reads at the resting 7dp radius, so it
            // reads at 23.4dp too, and a heavier rim would make the wide ring look like a stronger
            // claim than the ring it replaces instead of the same ring, larger. iOS holds 2.2pt
            // across both sizes for the same reason.
            val stroke = 2.2.dp.toPx()
            val full = (r + stroke) * 2f + 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                // The resting ring keeps its wash; the peek ring is hollow (see the function doc).
                if (!peek) {
                    drawCircle(tone, radius = r, center = center,
                               alpha = if (confirmed) 0.20f else 0.10f)
                }
                drawCircle(tone, radius = r, center = center, alpha = 0.95f,
                           style = if (confirmed) Stroke(width = stroke)
                                   else Stroke(width = stroke,
                                               pathEffect = PathEffect.dashPathEffect(
                                                   floatArrayOf(2.6.dp.toPx(), 2.2.dp.toPx()), 0f)))
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

/** The drone flight path's launch point, in both flavors: a plain small glyph and a
 *  "LAUNCH"-captioned variant for the "icon labels" map setting. [labeledAnchorV] keeps the
 *  glyph (not the taller glyph+caption box) centered on the launch coordinate. */
class LaunchMarker(
    val plain: BitmapDrawable,
    val labeled: BitmapDrawable,
    val labeledAnchorV: Float,
)

/** A small up-arrow disc for a drone track's launch point, mirroring the iOS 13pt
 *  arrow.up.circle.fill: droneTone disc, dark arrow, half-dark backing so it reads over
 *  the tiles. Deliberately about half the category-pin size so the launch point can never
 *  be mistaken for a second live drone pin. */
@Composable
fun rememberLaunchMarker(): LaunchMarker {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(Icons.Filled.ArrowUpward)
    val tone = Acab.droneTone
    return remember(density, Acab.highContrast) {
        with(density) {
            val discR = 6.5.dp.toPx()
            val backing = 1.5.dp.toPx()
            val full = (discR + backing) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 8.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                // dark backing halo (iOS: black-at-50% circle behind the glyph)
                drawCircle(Color.Black, radius = discR + backing, center = center, alpha = 0.5f)
                // droneTone disc with a dark up arrow = arrow.up.circle.fill in droneTone
                drawCircle(tone, radius = discR, center = center)
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Color(0xFF14100F)))
                    }
                }
            }
            val plain = BitmapDrawable(context.resources, image.asAndroidBitmap())
            val (labeled, anchorV) = buildLabeledMarker(
                context.resources, density.density, plain, "LAUNCH")
            LaunchMarker(plain, labeled, anchorV)
        }
    }
}

/** A muted person marker for a drone's operator, so it reads apart from the
 *  bright category dots. */
@Composable
fun rememberOperatorMarker(): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(Icons.Filled.Person)
    return remember(density, Acab.highContrast) {
        with(density) {
            val dotR = 12.dp.toPx()
            val border = 2.dp.toPx()
            val full = (dotR + border) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 14.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                drawCircle(Acab.bg, radius = dotR + border, center = center)
                drawCircle(Acab.bg3, radius = dotR, center = center)
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Acab.text))
                    }
                }
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

@Composable
private fun rememberCategoryMarker(type: DeviceType, dim: Boolean): BitmapDrawable {
    val context = LocalContext.current
    val density = LocalDensity.current
    val painter = rememberVectorPainter(type.icon())
    val tone = if (dim) dimTone(type.tone()) else type.tone()
    return remember(type, density, dim, Acab.highContrast) {
        with(density) {
            val dotR = 15.dp.toPx()
            val border = 2.dp.toPx()
            val ringReach = 5.dp.toPx()
            val full = (dotR + border + ringReach) * 2f
            val side = full.toInt().coerceAtLeast(1)
            val center = Offset(full / 2f, full / 2f)
            val glyphPx = 16.dp.toPx()
            val image = ImageBitmap(side, side)
            CanvasDrawScope().draw(density, LayoutDirection.Ltr, Canvas(image), Size(full, full)) {
                // Faint static ring. It is the iOS pin's pulse drawn frozen, not an animation, so
                // this platform has no ping to gate on the recency tier: FRESH and RECENT reach
                // the same bitmap here, and the tier boundary that changes pixels on Android is
                // the stale one. The ring quiets down with the rest of the pin when it does.
                drawCircle(tone, radius = dotR + border + ringReach * 0.55f, center = center,
                    alpha = if (dim) 0.25f else 0.4f, style = Stroke(width = 1.5.dp.toPx()))
                // dark border ring, then the colored dot
                drawCircle(Acab.bg, radius = dotR + border, center = center)
                drawCircle(tone, radius = dotR, center = center)
                // category glyph, dark, centered
                translate(center.x - glyphPx / 2f, center.y - glyphPx / 2f) {
                    with(painter) {
                        draw(Size(glyphPx, glyphPx), colorFilter = ColorFilter.tint(Color(0xFF14100F)))
                    }
                }
            }
            BitmapDrawable(context.resources, image.asAndroidBitmap())
        }
    }
}

/** A clustered-detections bubble: a tone-colored disc with a dark ring and the count,
 *  growing with the cluster size so a dense Desert-mode log reads at a glance. Built on
 *  demand from the map's update pass (the count varies), so it's a plain function rather
 *  than a @Composable. Caches per (rendered count, tone) so repeated rebuilds are cheap.
 *
 *  BOUNDED, the same way [PinBadgeFactory] is and for the same reason. A bubble's count is
 *  whatever a grid cell happens to hold, and the cells re-bucket on every zoom step and every
 *  pan, so a drive or a few minutes of panning walks through a lot of distinct counts. Each one
 *  is a whole ARGB disc bitmap whose side grows with the count (see the radius below), and an
 *  unbounded map held every one of them for as long as the Map tab stayed composed. Past
 *  [CACHE_MAX] entries the map is dropped whole and refills from the bubbles actually on screen.
 *  Dropping is safe at any moment, because a drawable already handed to a Marker is held by that
 *  Marker, so eviction costs a rebuild and never a blank bubble. */
class ClusterMarkerFactory(
    private val resources: android.content.res.Resources,
    private val densityPx: Float,
) {
    private companion object {
        /** The largest count drawn as digits; anything above it would render one shared "999+"
         *  bubble instead of a bitmap apiece.
         *
         *  UNREACHABLE today, and worth saying so rather than crediting it with a saving it never
         *  makes: MapScreen truncates a pass at MAP_MARKER_CAP rows (600) before it clusters, so
         *  a cluster cannot hold more members than that and `rendered` always equals `count`. The
         *  clamp stays because it is what stops the cache KEY space from following the cap if the
         *  cap ever rises. The bound that actually holds this cache down is [CACHE_MAX]. */
        const val COUNT_MAX = 999
        /** How many bubbles are held at once. A pass wanting more rebuilds the surplus, at
         *  exactly what an uncached call costs, so the ceiling buys a bounded footprint for
         *  nothing worse than no cache at all. */
        const val CACHE_MAX = 32
    }

    private val cache = HashMap<Long, BitmapDrawable>()

    private fun dp(v: Float) = v * densityPx

    fun marker(count: Int, tone: Color): BitmapDrawable {
        // The KEY, and everything drawn below, comes from this rather than from the raw count,
        // so a cached bubble and the digits on it can never disagree.
        val rendered = count.coerceAtMost(COUNT_MAX + 1)
        val key = (rendered.toLong() shl 32) or (tone.toArgb().toLong() and 0xFFFFFFFFL)
        cache[key]?.let { return it }

        // Radius scales gently with the log of the count so big clusters don't dwarf the map.
        val baseR = dp(16f) + dp(7f) * Math.log10((rendered + 1).toDouble()).toFloat()
        val border = dp(2f)
        val full = (baseR + border) * 2f
        val side = full.toInt().coerceAtLeast(1)
        val cx = full / 2f

        val image = ImageBitmap(side, side)
        val androidBitmap = image.asAndroidBitmap()
        val canvas = android.graphics.Canvas(androidBitmap)
        val fill = Paint(Paint.ANTI_ALIAS_FLAG)

        // dark border ring, then the colored disc
        fill.color = Acab.bg.toArgb()
        canvas.drawCircle(cx, cx, baseR + border, fill)
        fill.color = tone.toArgb()
        canvas.drawCircle(cx, cx, baseR, fill)

        // count, dark and centered
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFF14100F.toInt()
            textAlign = Paint.Align.CENTER
            textSize = dp(13f)
            isFakeBoldText = true
        }
        val label = if (rendered > COUNT_MAX) "$COUNT_MAX+" else rendered.toString()
        val textY = cx - (textPaint.descent() + textPaint.ascent()) / 2f
        canvas.drawText(label, cx, textY, textPaint)

        if (cache.size >= CACHE_MAX) cache.clear()
        return BitmapDrawable(resources, androidBitmap).also { cache[key] = it }
    }
}

/** Build a cluster-marker factory bound to the current resources + density. */
@Composable
// Keyed on Acab.highContrast as well as density: the factory bakes Acab.bg into every bubble
// it caches, so a palette swap gets a fresh factory (and an empty cache) rather than stale bitmaps.
// The same key sits on every other remember() in this file for the same reason.
fun rememberClusterMarkerFactory(): ClusterMarkerFactory {
    val context = LocalContext.current
    val density = LocalDensity.current
    return remember(density, Acab.highContrast) { ClusterMarkerFactory(context.resources, density.density) }
}

/** The category pins from [rememberCategoryMarkers], each with a short type tag drawn in a
 *  pill beneath the icon, for the map's "icon labels" setting. [anchorV] is the vertical
 *  anchor that keeps the ICON (not the label) centered on the geo point; it is the same for
 *  every type because all category pins share one bitmap size. */
class LabeledMarkers(
    val icons: Map<DeviceType, BitmapDrawable>,
    val anchorV: Float,
)

/** Build labeled variants of the category pins once. Keyed on density only: the base pins are
 *  stable instances (each is remembered per type), so the labels never need rebuilding on a
 *  plain recomposition even though [base] is a fresh map wrapper each time. */
@Composable
fun rememberLabeledCategoryMarkers(base: Map<DeviceType, BitmapDrawable>): LabeledMarkers {
    val context = LocalContext.current
    val density = LocalDensity.current
    return remember(density, Acab.highContrast) {
        var anchorV = 0.5f
        val icons = base.mapValues { (type, drawable) ->
            val (labeled, av) = buildLabeledMarker(
                context.resources, density.density, drawable, type.category)
            anchorV = av
            labeled
        }
        LabeledMarkers(icons, anchorV)
    }
}

/** Compose the base pin bitmap with a short label pill under it. Returns the drawable plus the
 *  vertical anchor ratio that lands the icon's center (not the taller icon+label box) on the
 *  point. */
private fun buildLabeledMarker(
    resources: android.content.res.Resources,
    densityPx: Float,
    base: BitmapDrawable,
    label: String,
): Pair<BitmapDrawable, Float> {
    fun dp(v: Float) = v * densityPx
    val icon = base.bitmap
    val iconW = icon.width.toFloat()
    val iconH = icon.height.toFloat()

    val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = Acab.text.toArgb()
        textAlign = Paint.Align.CENTER
        textSize = dp(8.5f)
        isFakeBoldText = true
    }
    val fm = textPaint.fontMetrics
    val padH = dp(5f)
    val padV = dp(2.5f)
    val gap = dp(1f)
    val bandW = textPaint.measureText(label) + padH * 2f
    val bandH = (fm.descent - fm.ascent) + padV * 2f
    val fullW = maxOf(iconW, bandW)
    val fullH = iconH + gap + bandH

    val bmp = android.graphics.Bitmap.createBitmap(
        fullW.toInt().coerceAtLeast(1), fullH.toInt().coerceAtLeast(1),
        android.graphics.Bitmap.Config.ARGB_8888)
    val canvas = android.graphics.Canvas(bmp)
    val cx = fullW / 2f
    // icon, centered horizontally at the top
    canvas.drawBitmap(icon, cx - iconW / 2f, 0f, null)
    // label pill: dark, faint border, matching the chip styling
    val bandTop = iconH + gap
    val rect = android.graphics.RectF(cx - bandW / 2f, bandTop, cx + bandW / 2f, bandTop + bandH)
    canvas.drawRoundRect(rect, dp(4f), dp(4f),
        Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Acab.bg2.toArgb(); alpha = 235 })
    canvas.drawRoundRect(rect, dp(4f), dp(4f),
        Paint(Paint.ANTI_ALIAS_FLAG).apply {
            style = Paint.Style.STROKE
            strokeWidth = dp(1f)
            color = Acab.line.toArgb()
        })
    canvas.drawText(label, cx, bandTop + padV - fm.ascent, textPaint)

    return BitmapDrawable(resources, bmp) to (iconH / 2f) / fullH
}

/** A pin bitmap with its count badge composited on, plus the vertical anchor that still lands the
 *  PIN's centre (not the badge, and not the taller composite's centre) on the geo point. */
class BadgedPin(
    val icon: BitmapDrawable,
    val anchorV: Float,
)

/** Composites a small count badge onto a category pin, for a same-coordinate pin group (see
 *  PinGroup in MapScreen.kt). Deliberately NOT the cluster bubble: a bubble replaces the artwork
 *  with a tone-filled disc carrying dark digits, and it means "several things somewhere in this
 *  grid cell". This keeps the category pin exactly as it draws alone and hangs a dark pill with
 *  light digits off its shoulder, so the two read as different objects at a glance and by their
 *  inverted fill.
 *
 *  Built on demand from the map's update pass (the count varies), so it is a plain class rather
 *  than a @Composable.
 *
 *  CACHED ON WHAT IT DRAWS, NOT ON WHAT IT WAS ASKED FOR. The key is the base pin plus the
 *  RENDERED count, and every count past [BADGE_MAX] renders the same "99+" pill, so they all
 *  share one entry instead of each retaining a byte-identical bitmap of its own. The base pins
 *  are stable remembered instances, one per type per variant, and Drawable does not override
 *  equals, so the outer map keys on the instance and never merges two different pins.
 *
 *  BOUNDED. A stationary session whose group size keeps drifting would otherwise mint a fresh
 *  full-size ARGB bitmap per distinct count and hold every one of them for the life of the
 *  screen. Past [CACHE_MAX] entries the cache is dropped whole and refills from the pins actually
 *  on screen. Dropping is safe at any moment: a composite already handed to a Marker is held by
 *  that Marker, so eviction only ever costs a rebuild, never a blank pin. */
class PinBadgeFactory(
    private val resources: android.content.res.Resources,
    private val densityPx: Float,
) {
    private companion object {
        /** The largest count drawn as digits; anything above renders "99+". */
        const val BADGE_MAX = 99
        /** How many composites are held at once. Every entry is a whole pin-sized ARGB bitmap,
         *  so the ceiling is counted in entries; the bytes behind one move with screen density.
         *  A pass wanting more than this rebuilds the surplus, at exactly what an uncached call
         *  costs, so the ceiling buys a bounded footprint for nothing worse than no cache. */
        const val CACHE_MAX = 24
    }

    /** base pin -> rendered count -> composite. Two levels so a lookup allocates nothing: the
     *  outer key is the drawable itself, and the inner key is capped at [BADGE_MAX] + 1, which
     *  is inside the range java.lang.Integer interns, so boxing it allocates nothing either. */
    private val cache = HashMap<BitmapDrawable, HashMap<Int, BadgedPin>>()
    private var cached = 0

    private fun dp(v: Float) = v * densityPx

    fun badged(base: BitmapDrawable, baseAnchorV: Float, count: Int): BadgedPin {
        // What the badge will actually say. BADGE_MAX + 1 stands for the whole "99+" range.
        val rendered = count.coerceAtMost(BADGE_MAX + 1)
        cache[base]?.get(rendered)?.let { return it }

        val src = base.bitmap
        val w = src.width.toFloat()
        val h = src.height.toFloat()
        // The pin's own square, derived from the base anchor instead of assumed. On a plain pin
        // the anchor is dead centre and the square is the whole bitmap; on the "icon labels"
        // variant the anchor is raised and the square is the icon sitting above the label pill.
        // One formula covers both, so the badge cannot drift off the icon when labels are on.
        val iconCyIn = baseAnchorV * h
        val iconHalf = iconCyIn

        // Grow the canvas by the SAME margin on all four sides. That keeps the pin's centre at
        // the composite's centre horizontally (so the horizontal anchor stays dead centre) and
        // makes the new vertical anchor a straight shift of the old one, and it gives the badge
        // room to sit clear of the dot instead of over the category glyph.
        val pad = dp(7f)
        val fullW = w + pad * 2f
        val fullH = h + pad * 2f
        val iconCx = fullW / 2f
        val iconCy = pad + iconCyIn

        val badgeH = dp(14f)
        val padH = dp(4.5f)
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Acab.text.toArgb()
            textAlign = Paint.Align.CENTER
            textSize = dp(9f)
            isFakeBoldText = true
        }
        // Drawn from the KEY, never from the raw count, so the cached entry and the label it
        // carries can never disagree.
        val label = if (rendered > BADGE_MAX) "$BADGE_MAX+" else rendered.toString()
        val bandW = maxOf(badgeH, textPaint.measureText(label) + padH * 2f)
        // Pinned by its RIGHT edge just inside the new margin, so a wider count grows leftward
        // and can never run off the bitmap.
        val right = iconCx + iconHalf + pad - dp(2f)
        val cy = iconCy - iconHalf + dp(2f)

        val bmp = android.graphics.Bitmap.createBitmap(
            fullW.toInt().coerceAtLeast(1), fullH.toInt().coerceAtLeast(1),
            android.graphics.Bitmap.Config.ARGB_8888)
        val canvas = android.graphics.Canvas(bmp)
        canvas.drawBitmap(src, pad, pad, null)
        val rect = android.graphics.RectF(right - bandW, cy - badgeH / 2f, right, cy + badgeH / 2f)
        val r = badgeH / 2f
        // Same dark-pill-with-a-faint-border anatomy as the "icon labels" caption, so the two
        // things that hang off a pin read as one family. Dark fill under light digits is also the
        // exact inverse of the cluster bubble's tone fill under dark digits.
        canvas.drawRoundRect(rect, r, r,
            Paint(Paint.ANTI_ALIAS_FLAG).apply { color = Acab.bg2.toArgb() })
        canvas.drawRoundRect(rect, r, r,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                style = Paint.Style.STROKE
                strokeWidth = dp(1f)
                color = Acab.line.toArgb()
            })
        canvas.drawText(label, (rect.left + rect.right) / 2f,
            cy - (textPaint.descent() + textPaint.ascent()) / 2f, textPaint)

        val pin = BadgedPin(BitmapDrawable(resources, bmp), iconCy / fullH)
        if (cached >= CACHE_MAX) {
            cache.clear()
            cached = 0
        }
        cache.getOrPut(base) { HashMap(4) }[rendered] = pin
        cached++
        return pin
    }
}

/** Build a badge factory bound to the current resources + density. */
@Composable
fun rememberPinBadgeFactory(): PinBadgeFactory {
    val context = LocalContext.current
    val density = LocalDensity.current
    return remember(density, Acab.highContrast) { PinBadgeFactory(context.resources, density.density) }
}
