package tech.acab.app.ui

import android.graphics.drawable.BitmapDrawable
import android.os.Handler
import android.os.Looper
import org.osmdroid.events.MapListener
import org.osmdroid.events.ScrollEvent
import org.osmdroid.events.ZoomEvent
import org.osmdroid.util.GeoPoint
import org.osmdroid.views.MapView
import org.osmdroid.views.overlay.FolderOverlay
import org.osmdroid.views.overlay.Marker
import tech.acab.app.net.ALPR_TIER_LEGACY_FORMAT

/** Source credit, one copy, tail of every reference-ring snippet. */
private const val ALPR_CREDIT = "DeFlock / OSM ODbL"

/** RING-PEEK, in words. The wide rim is a purely visual cue, so the info window (and TalkBack
 *  reading it out) carries the same fact, the way iOS appends it to the ring's VoiceOver label.
 *  Says what was HEARD, not what was verified: a wide ring means a live detection landed on this
 *  mapped location, never that the mapped camera is confirmed or that the heard device is it. */
internal const val ALPR_PEEK_SNIPPET = "wide ring: a live detection was heard at this mapped location"

/** User-visible attribution copy for one dataset row. These tiers describe source structure, not
 * external verification, so the words confirmed/unverified deliberately never appear. [peek] adds
 * the ring-peek sentence for a ring a live detection pin is standing on, and nothing else: the
 * title and the tier body stay byte-identical, because the peek says something about the DETECTION,
 * not about this row's attribution. */
internal fun alprMarkerText(rawTier: Int, maker: String, peek: Boolean = false): Pair<String, String> {
    val title = when {
        rawTier == 0 -> "ALPR camera, no structured manufacturer"
        rawTier == 2 && maker.isNotEmpty() -> "$maker legacy ALPR candidate"
        rawTier == 2 -> "Legacy ALPR candidate"
        rawTier == ALPR_TIER_LEGACY_FORMAT && maker.isNotEmpty() ->
            "$maker ALPR camera, legacy dataset format"
        rawTier == ALPR_TIER_LEGACY_FORMAT -> "ALPR camera, legacy dataset format"
        rawTier == 1 && maker.isNotEmpty() -> "$maker ALPR camera, manufacturer attributed"
        rawTier == 1 -> "ALPR camera, manufacturer attributed"
        maker.isNotEmpty() -> "$maker ALPR record, unknown attribution tier"
        else -> "ALPR record, unknown attribution tier"
    }
    // The resting body says "not a live detection" because a ring is a mapped RECORD, not proof
    // that anything transmitted. On a peeking ring that clause would contradict the peek sentence
    // in the same string, so it drops out: the peek sentence then carries the whole claim, and it
    // still only says what the beacon HEARD here, never that this camera is verified.
    val body = when (rawTier) {
        0 -> "canonical mapped ALPR, no structured manufacturer"
        2 -> if (peek) "legacy alias candidate" else "legacy alias candidate, not a live detection"
        ALPR_TIER_LEGACY_FORMAT -> "mapped by a legacy dataset without attribution tiers"
        1 -> if (peek) "a mapped location" else "a mapped location, not a live detection"
        else -> if (peek) "unknown attribution tier" else "unknown attribution tier, not a live detection"
    }
    val snippet = if (peek) "$body · $ALPR_PEEK_SNIPPET · $ALPR_CREDIT" else "$body · $ALPR_CREDIT"
    return title to snippet
}

/** How close a rendered detection pin has to be to a mapped-ALPR node before that node's ring
 *  draws WIDE (see rememberAlprMarker's peek variant). 25 m is about the spread between a
 *  phone-positioned sighting and the pole the camera is actually bolted to; wider starts claiming
 *  cameras the hit had nothing to do with, tighter misses the match that matters.
 *  THE SHARED NUMBER: iOS ALPRRingPeek.radiusMeters is the same 25 and both suites assert it. The
 *  enlarged ring's SIZE is deliberately not shared (each platform's pin artwork differs, so each
 *  derives its own; see rememberAlprMarker), but the match radius is one contract. */
internal const val ALPR_PEEK_RADIUS_M = 25.0

private const val METERS_PER_DEG_LAT = 111_320.0

/**
 * The detection pins of one map pass, bucketed into [ALPR_PEEK_RADIUS_M]-tall latitude bands so a
 * ring can ask "is any pin standing on me?" without walking the whole pin list.
 *
 * COST, honestly. Building this is one pass over the pins. Each [matches] call then reads at most
 * three buckets (the ring's own band and its two neighbours, which are the only bands that can
 * hold a point within the radius), so the common "no pin anywhere near this ring" case costs three
 * failed map lookups rather than one compare PER PIN. The plain linear version this replaced was
 * O(rings x pins): 500 rings against a few hundred pins is up to ~300k iterations for a pass that
 * usually matches nothing. Mirrors iOS ALPRRingPeek.matches, which bands the same way.
 *
 * Distances are equirectangular, exact to well under a metre at this range, with the longitude
 * scale taken from the RING: anything close enough to match is within 25 m, where the difference
 * between the two latitudes is far below GPS noise.
 */
internal class AlprPeekBands(pins: DoubleArray) {
    /** band index -> that band's pins, interleaved lat/lon. */
    private val bands: Map<Int, DoubleArray>

    init {
        // Transient boxing in the accumulator, then one flat DoubleArray per band: this runs once
        // per pin-set change over a few hundred points, never per ring and never per frame.
        val acc = HashMap<Int, MutableList<Double>>()
        var i = 0
        while (i + 1 < pins.size) {   // a truncated trailing half-pair is ignored, never read past
            val lat = pins[i]
            val lon = pins[i + 1]
            i += 2
            if (!usable(lat, lon)) continue
            acc.getOrPut(band(lat)) { ArrayList() }.apply { add(lat); add(lon) }
        }
        bands = if (acc.isEmpty()) emptyMap()
                else acc.mapValues { (_, v) -> v.toDoubleArray() }
    }

    /** No usable pins at all, so nothing can peek. Lets callers skip the per-ring loop entirely. */
    val isEmpty: Boolean get() = bands.isEmpty()

    /** True when a pin sits within [ALPR_PEEK_RADIUS_M] of [lat]/[lon]. */
    fun matches(lat: Double, lon: Double): Boolean {
        if (bands.isEmpty() || !usable(lat, lon)) return false
        val mPerDegLon = METERS_PER_DEG_LAT * Math.cos(Math.toRadians(lat))
        val home = band(lat)
        // Neighbours included on purpose: a band edge falls wherever it falls, so a ring and the
        // pin standing on it routinely land either side of one. Bands are radius-tall, so two
        // neighbours are enough; nothing further out can be within the radius.
        for (b in home - 1..home + 1) {
            val pins = bands[b] ?: continue
            var i = 0
            while (i + 1 < pins.size) {
                val y = (pins[i] - lat) * METERS_PER_DEG_LAT
                val x = (pins[i + 1] - lon) * mPerDegLon
                i += 2
                if (x * x + y * y <= ALPR_PEEK_RADIUS_M * ALPR_PEEK_RADIUS_M) return true
            }
        }
        return false
    }

    private companion object {
        private const val BAND_DEG = ALPR_PEEK_RADIUS_M / METERS_PER_DEG_LAT

        private fun band(lat: Double): Int = Math.floor(lat / BAND_DEG).toInt()

        /** A coordinate that can be bucketed without trapping. A corrupt cache row or a bad fix
         *  must degrade to "no match", never to a NaN or an out-of-range Double turning into a
         *  garbage band index. Mirrors iOS ALPRRingPeek.usable. */
        private fun usable(lat: Double, lon: Double): Boolean =
            !lat.isNaN() && !lon.isNaN() && !lat.isInfinite() && !lon.isInfinite() &&
                Math.abs(lat) <= 90.0 && Math.abs(lon) <= 180.0
    }
}

/** The four ring bitmaps the reference layer can draw: two attribution tiers, each in its normal
 *  and its ring-peek size. Bundled so the layer's update call keeps one identity check per input
 *  instead of four. */
class AlprRingIcons(
    val primary: BitmapDrawable,
    val unverified: BitmapDrawable,
    val primaryPeek: BitmapDrawable,
    val unverifiedPeek: BitmapDrawable,
)

/**
 * Manages the known-ALPR reference layer as its own osmdroid overlay, separate from the
 * Compose-driven detection markers. osmdroid doesn't recompose on pan/zoom, so this attaches a
 * debounced map listener that re-culls the (potentially large) camera set to the current viewport
 * without rebuilding the detection markers. Rendering only kicks in past a zoom threshold, and the
 * per-view count is capped, so the map stays responsive even with a big dataset.
 *
 * TWO SEPARATE JOBS, on purpose. [update] culls the whole dataset to the viewport and builds
 * markers; [setPeekPins] only re-stamps icons on the markers that cull already produced. The two
 * run at completely different cadences (viewport changes are gestures; the pin set changes every
 * time a new device is heard), and folding them together is what made a drive test rebuild the
 * layer continuously.
 */
class AlprOverlayHolder {
    private val folder = FolderOverlay()
    private val handler = Handler(Looper.getMainLooper())
    private var attachedTo: MapView? = null
    private var mapListener: MapListener? = null   // kept so detach() can remove it (no post-detach rebuilds)

    // Latest inputs, pushed from the Compose update pass.
    private var nodes: IntArray = IntArray(0)   // interleaved latE7, lonE7
    private var makerIdx: IntArray = IntArray(0)   // per-node maker index (parallel to nodes/2)
    private var makerTable: Array<String> = arrayOf("")
    private var confirmed: BooleanArray = BooleanArray(0)   // per-node tier, parallel to nodes/2
    private var rawTier: IntArray = IntArray(0)   // 0 no structured maker, 1 attributed, 2 legacy candidate
    private var enabled = false
    private var showUnverified = false   // draw the no-manufacturer tier at all (default off)
    private var icons: AlprRingIcons? = null
    // RING-PEEK: coordinates of the detection pins drawn by the Compose pass, interleaved lat/lon,
    // plus the latitude-band index built from them. A ring within ALPR_PEEK_RADIUS_M of one of
    // these draws wide so its rim clears the pin.
    private var peekPins: DoubleArray = DoubleArray(0)
    private var peekBands = AlprPeekBands(DoubleArray(0))

    /** One drawn ring, kept so the peek pass can restyle it without re-culling: the coordinate to
     *  test, the copy to rewrite, and the marker to restyle. At most [CAP] of these exist. */
    private class RingMarker(
        val lat: Double,
        val lon: Double,
        val tier: Int,
        val maker: String,
        val primary: Boolean,
        val marker: Marker,
    ) {
        var peek = false
    }

    /** The rings this viewport cull drew, in folder order. */
    private val rings = ArrayList<RingMarker>()

    /** Reports how many rings are currently drawn wide, so the legend can explain the wide ring
     *  only while one is actually on screen (a legend row naming something nothing on screen is
     *  using reads as a rendering bug). Fired from [applyPeek], and only when the number changes. */
    var onPeekCount: ((Int) -> Unit)? = null
    private var lastPeekCount = -1

    companion object {
        const val MIN_ZOOM = 11.0     // don't draw cameras zoomed further out than ~city level
        private const val CAP = 500           // max markers drawn in one viewport (matches iOS ALPRDataset)
        private const val DEBOUNCE_MS = 140L
    }

    /** Add our folder to the map (once) and start listening for pan/zoom. */
    fun attach(map: MapView) {
        if (attachedTo === map) return
        attachedTo = map
        if (!map.overlays.contains(folder)) map.overlays.add(folder)
        mapListener = object : MapListener {
            override fun onScroll(event: ScrollEvent?): Boolean { scheduleRebuild(map); return false }
            override fun onZoom(event: ZoomEvent?): Boolean { scheduleRebuild(map); return false }
        }.also { map.addMapListener(it) }
    }

    /** Push the current dataset + layer state from Compose and redraw now. Early-outs when nothing
     *  changed: the ~3 Hz detection publishes re-run the Compose update pass, and without this gate
     *  every publish re-scanned the full node array (119k nodes) and re-alloc'd up to CAP markers
     *  on the main thread. All the inputs are stable references (StateFlow value / remember), so
     *  identity checks are sound; viewport changes are covered by the debounced pan/zoom listener
     *  attach() installs, which re-culls without coming through here.
     *  The detection pins are NOT an input here on purpose: see [setPeekPins]. */
    fun update(map: MapView, nodes: IntArray, makerIdx: IntArray, makerTable: Array<String>,
               confirmed: BooleanArray, rawTier: IntArray, icons: AlprRingIcons,
               enabled: Boolean, showUnverified: Boolean) {
        if (nodes === this.nodes && makerIdx === this.makerIdx && enabled == this.enabled &&
            makerTable === this.makerTable && confirmed === this.confirmed &&
            rawTier === this.rawTier && showUnverified == this.showUnverified &&
            icons === this.icons) return
        this.nodes = nodes
        this.makerIdx = makerIdx
        this.makerTable = makerTable
        this.confirmed = confirmed
        this.rawTier = rawTier
        this.enabled = enabled
        this.showUnverified = showUnverified
        this.icons = icons
        rebuild(map)
    }

    /** RING-PEEK: hand over the coordinates of the detection pins the Compose pass just drew,
     *  interleaved lat/lon.
     *
     *  DELIBERATELY NOT PART OF [update]. The pin set changes whenever any new device is heard,
     *  which on a drive test is thousands of times a session, while the rings themselves only
     *  change when the viewport or the dataset does. Feeding the pins into [update] defeated its
     *  identity early-out and put the full 119k-node cull plus up to CAP Marker allocations on the
     *  main thread at detection-arrival cadence. This path never touches the node array and never
     *  allocates a Marker: it indexes the pins once and swaps icons on the <= CAP rings already
     *  drawn.
     *
     *  Identity, not contents: the caller keeps the SAME array instance while the pins it drew are
     *  unchanged, so the ~3 Hz publishes and the 1 Hz staleness rebuilds cost nothing at all. */
    fun setPeekPins(map: MapView, pins: DoubleArray) {
        if (pins === peekPins) return
        peekPins = pins
        peekBands = AlprPeekBands(pins)
        applyPeek(map)
    }

    private fun scheduleRebuild(map: MapView) {
        handler.removeCallbacksAndMessages(null)
        handler.postDelayed({ rebuild(map) }, DEBOUNCE_MS)
    }

    /** Repopulate the folder from the viewport. Cheap: a bounds check per node + capped markers. */
    private fun rebuild(map: MapView) {
        // A still-pending debounced rebuild can fire after the MapView left the window (tab switch),
        // by which point osmdroid has nulled the FolderOverlay's item list. Bail rather than NPE.
        if (folder.items == null) return
        folder.items.clear()
        rings.clear()
        val ic = icons
        if (!enabled || ic == null || nodes.isEmpty() || map.zoomLevelDouble < MIN_ZOOM) {
            map.invalidate(); reportPeekCount(0); return
        }
        val box = map.boundingBox
        val nLat = box.latNorth; val sLat = box.latSouth
        val eLon = box.lonEast; val wLon = box.lonWest
        var drawn = 0
        var i = 0
        val n = nodes.size
        while (i + 1 < n) {
            val lat = nodes[i] / 1e7
            val lon = nodes[i + 1] / 1e7
            i += 2
            if (lat in sLat..nLat && lon in wLon..eLon) {
                val node = i / 2 - 1                    // i was already advanced by 2 above
                val maker = if (node < makerIdx.size) makerTable.getOrElse(makerIdx[node]) { "" } else ""
                val tier = rawTier.getOrElse(node) {
                    if (node < confirmed.size && confirmed[node]) 1 else 0
                }
                val attributed = tier == 1
                val primary = attributed || tier == ALPR_TIER_LEGACY_FORMAT
                // Hidden by default: a pin with no manufacturer recorded is the one users drive to,
                // find nothing at, and blame the app for. Skipped BEFORE the drawn++ so hiding them
                // buys headroom under CAP rather than silently costing it.
                if (!primary && !showUnverified) continue
                // too many visible in view: draw none, wait for zoom-in
                if (drawn >= CAP) { folder.items.clear(); rings.clear(); break }
                val marker = Marker(map).apply {
                    position = GeoPoint(lat, lon)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    // Resting size here; applyPeek below is the ONLY place the wide variant is
                    // chosen, so the peek decision lives in one pass whether it runs with this
                    // cull or on its own after a pin arrives.
                    this.icon = if (primary) ic.primary else ic.unverified
                    // Tapping a reference camera names the maker (when OSM has it) + credits the
                    // source. The snippet also has to say what a pin IS: a mapped location, not a
                    // live detection. Most fixed ALPRs backhaul over cellular and are silent to
                    // this hardware whether or not one is standing there, and a user who reads a
                    // pin as a detection concludes the device is broken.
                    // The two BODY lines below are word-identical to iOS. The TITLES are not, and
                    // deliberately: this is an osmdroid info-window title, iOS is a floating
                    // capsule, so they carry the same fact in the form each affordance wants.
                    // TIER FIRST, then maker. Testing maker first titled a hand-typed node
                    // "Flock Safety ALPR camera" while the snippet underneath said no
                    // manufacturer was recorded. Mirrors iOS MapTabView.
                    alprMarkerText(tier, maker).let { (markerTitle, markerSnippet) ->
                        title = markerTitle
                        snippet = markerSnippet
                    }
                    setOnMarkerClickListener { m, _ -> m.showInfoWindow(); true }
                }
                folder.add(marker)
                rings.add(RingMarker(lat, lon, tier, maker, primary, marker))
                drawn++
            }
        }
        // RING-PEEK, stamped once over the set just drawn rather than inside the loop: the pin
        // index is shared across every ring, and this is the same pass a later pin change re-runs
        // on its own.
        applyPeek(map)
        map.invalidate()
    }

    /** Restyle the rings this cull already drew for the current pin set: wide where a rendered
     *  detection pin is standing on the camera, resting size everywhere else.
     *
     *  Bounded by what is ON SCREEN, never by the dataset: at most [CAP] rings, each testing three
     *  latitude bands of pins (see [AlprPeekBands]). No node scan, no Marker allocation, and no
     *  repaint at all unless a ring actually changed state. */
    private fun applyPeek(map: MapView) {
        if (rings.isEmpty()) { reportPeekCount(0); return }
        val ic = icons ?: return
        val anyPins = !peekBands.isEmpty
        var peeking = 0
        var changed = false
        for (r in rings) {
            val peek = anyPins && peekBands.matches(r.lat, r.lon)
            if (peek) peeking++
            if (peek == r.peek) continue
            r.peek = peek
            changed = true
            r.marker.icon = when {
                r.primary && peek -> ic.primaryPeek
                r.primary -> ic.primary
                peek -> ic.unverifiedPeek
                else -> ic.unverified
            }
            // The enlarged rim is a sighted-only cue, so the copy carries the same fact for the
            // info window and TalkBack. Re-show an OPEN bubble: it renders title/snippet at open
            // time, so without this the one ring the user is actually reading keeps stale copy.
            alprMarkerText(r.tier, r.maker, peek).let { (markerTitle, markerSnippet) ->
                r.marker.title = markerTitle
                r.marker.snippet = markerSnippet
            }
            if (r.marker.isInfoWindowShown) r.marker.showInfoWindow()
        }
        if (changed) map.invalidate()
        reportPeekCount(peeking)
    }

    private fun reportPeekCount(n: Int) {
        if (n == lastPeekCount) return
        lastPeekCount = n
        onPeekCount?.invoke(n)
    }

    fun detach() {
        handler.removeCallbacksAndMessages(null)
        mapListener?.let { attachedTo?.removeMapListener(it) }   // no pan/zoom rebuilds after teardown
        mapListener = null
        // THE map->log CRASH: osmdroid's MapView.onDetachedFromWindow() (fired when the tab switches
        // away) runs BEFORE Compose's onRelease calls this, and it can already have torn the
        // FolderOverlay's item list down to null - so a bare .clear() here NPE'd. Guard it; the
        // folder is going away regardless.
        folder.items?.clear()
        rings.clear()
        attachedTo = null
        // Drop the cached inputs so a (theoretical) re-attach can't early-out of the first
        // update against the now-empty folder.
        nodes = IntArray(0)
        makerIdx = IntArray(0)
        makerTable = arrayOf("")
        confirmed = BooleanArray(0)
        rawTier = IntArray(0)
        enabled = false
        showUnverified = false
        icons = null
        peekPins = DoubleArray(0)
        peekBands = AlprPeekBands(DoubleArray(0))
        // Nothing is drawn any more, so say so before the callback goes: a legend row left
        // explaining a wide ring that no longer exists is exactly the rendering-bug read this
        // count exists to prevent.
        reportPeekCount(0)
        onPeekCount = null
        lastPeekCount = -1
    }
}
