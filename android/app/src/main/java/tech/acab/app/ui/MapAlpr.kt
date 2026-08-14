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

/** User-visible attribution copy for one dataset row. These tiers describe source structure, not
 * external verification, so the words confirmed/unverified deliberately never appear. */
internal fun alprMarkerText(rawTier: Int, maker: String): Pair<String, String> {
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
    val snippet = when (rawTier) {
        0 -> "canonical mapped ALPR, no structured manufacturer · DeFlock / OSM ODbL"
        2 -> "legacy alias candidate, not a live detection · DeFlock / OSM ODbL"
        ALPR_TIER_LEGACY_FORMAT ->
            "mapped by a legacy dataset without attribution tiers · DeFlock / OSM ODbL"
        1 -> "a mapped location, not a live detection · DeFlock / OSM ODbL"
        else -> "unknown attribution tier, not a live detection · DeFlock / OSM ODbL"
    }
    return title to snippet
}

/**
 * Manages the known-ALPR reference layer as its own osmdroid overlay, separate from the
 * Compose-driven detection markers. osmdroid doesn't recompose on pan/zoom, so this attaches a
 * debounced map listener that re-culls the (potentially large) camera set to the current viewport
 * without rebuilding the detection markers. Rendering only kicks in past a zoom threshold, and the
 * per-view count is capped, so the map stays responsive even with a big dataset.
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
    private var icon: BitmapDrawable? = null
    private var iconUnverified: BitmapDrawable? = null   // amber dashed ring for the unverified tier

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

    /** Push the current state from Compose and redraw now. Early-outs when nothing changed:
     *  the ~3 Hz detection publishes re-run the Compose update pass, and without this gate every
     *  publish re-scanned the full node array (119k nodes) and re-alloc'd up to CAP markers on
     *  the main thread. All three inputs are stable references (StateFlow value / remember), so
     *  identity checks are sound; viewport changes are covered by the debounced pan/zoom
     *  listener attach() installs, which re-culls without coming through here. */
    fun update(map: MapView, nodes: IntArray, makerIdx: IntArray, makerTable: Array<String>,
               confirmed: BooleanArray, rawTier: IntArray, icUnverified: BitmapDrawable,
               enabled: Boolean, showUnverified: Boolean, icon: BitmapDrawable) {
        if (nodes === this.nodes && makerIdx === this.makerIdx && enabled == this.enabled &&
            makerTable === this.makerTable && confirmed === this.confirmed &&
            rawTier === this.rawTier && showUnverified == this.showUnverified &&
            icon === this.icon && icUnverified === this.iconUnverified) return
        this.nodes = nodes
        this.makerIdx = makerIdx
        this.makerTable = makerTable
        this.confirmed = confirmed
        this.rawTier = rawTier
        this.enabled = enabled
        this.showUnverified = showUnverified
        this.icon = icon
        this.iconUnverified = icUnverified
        rebuild(map)
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
        val ic = icon
        val icUnver = iconUnverified ?: ic
        if (!enabled || ic == null || nodes.isEmpty() || map.zoomLevelDouble < MIN_ZOOM) {
            map.invalidate(); return
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
                if (drawn >= CAP) { folder.items.clear(); break }   // too many visible in view: draw none, wait for zoom-in
                folder.add(Marker(map).apply {
                    position = GeoPoint(lat, lon)
                    setAnchor(Marker.ANCHOR_CENTER, Marker.ANCHOR_CENTER)
                    this.icon = if (primary) ic else icUnver
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
                })
                drawn++
            }
        }
        map.invalidate()
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
        icon = null
    }
}
