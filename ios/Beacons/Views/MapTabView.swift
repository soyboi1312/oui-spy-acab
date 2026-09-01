import SwiftUI
import MapKit

/// One-shot handoff from a detection dossier's location thumbnail to the full map tab.
/// The tap stashes the coordinate here and posts the notification; MainTabView switches
/// tabs on it and MapTabView consumes the slot exactly once (onAppear when the tab was
/// cold, the notification when it is already alive). A static slot rather than the
/// UserDefaults channel the Live Activity deep link uses: this handoff never outlives
/// the session, and a stale persisted coordinate must not hijack a later launch's
/// first map open.
enum MapFocus {
    static var pending: CLLocationCoordinate2D?
    static let notification = Notification.Name("acabFocusMap")
}

/// Located detections on a dark map, filterable by category. Fixed installs
/// (Flock/body-cam/tracker) sit at our position when we heard them; drones plot
/// their own broadcast position plus the operator's.
struct MapTabView: View {
    @EnvironmentObject var ble: BLEManager
    @EnvironmentObject var alpr: ALPRStore        // known-ALPR reference layer (on by default, OSM/DeFlock)
    @State private var filter: String?           // category key: ALPR / DRONE / BODY CAM / TRACKER
    // NEVER fall back to .automatic: it re-frames the camera to fit the CONTENT, and the ALPR dots are
    // themselves computed FROM the camera region (onMapCameraChange -> refreshALPRVisible -> alprVisible
    // -> Annotations -> content changed -> .automatic re-frames -> camera changed -> ...). That closes an
    // unbounded render loop that pegs the main thread (a cpu_resource spin, not a crash). A fixed fallback
    // region breaks the content->camera edge; the recenter button below drives the camera explicitly.
    @State private var camera: MapCameraPosition = .userLocation(fallback: .region(MapTabView.fallbackRegion))
    static let fallbackRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611),   // San Diego
        span: MKCoordinateSpan(latitudeDelta: 0.08, longitudeDelta: 0.08))
    @State private var selected: Detection?
    @State private var cluster: Cluster?         // tapped multi-member bubble (drives the picker sheet)
    @State private var showALPRInfo = false      // tapped a known-ALPR dot: show the shared credit callout (one overlay, never a per-dot popover)
    @State private var tappedALPRMaker = ""      // the maker of the last-tapped dot ("" = unknown), shown in that callout
    @State private var tappedALPRTier: UInt8 = 1  // raw ALP tier; drives the callout's wording + tone
    @State private var tappedALPRPeek = false    // was that dot's ring peeking? the callout must not deny a live hit
    @State private var span: MKCoordinateSpan = .init(latitudeDelta: 0.02, longitudeDelta: 0.02)
    @State private var region = MKCoordinateRegion(center: .init(latitude: 0, longitude: 0),
                                                   span: .init(latitudeDelta: 0.02, longitudeDelta: 0.02))
    @State private var emptyDismissed = false
    @State private var legendExpanded = false     // F18: legend rests as a small info chip
    @State private var showLayersPanel = false    // the LAYERS popover (known-ALPR dataset layer)
    // One-shot camera fit to the located detections' bounding region (see fitToDetections).
    // Also set when a dossier handoff places the camera, so the fit never yanks it away.
    @State private var didFitToDetections = false
    @AppStorage("map.showBreadcrumbs") private var showBreadcrumbs = true    // tracker trails on the map (persisted)
    @AppStorage("map.showLabels") private var showLabels = false             // pin captions, off for a cleaner map (persisted)
    @State private var mapSettingsOpen = false    // the on-map settings dropdown
    @State private var alprChecking = false       // manual "check for updates" in flight (double-tap guard)
    @State private var alprJustChecked = false    // brief window after a manual check: row shows the outcome
    @Environment(\.horizontalSizeClass) private var hSize   // T5: dossier as inspector on regular width

    /// Known ALPR camera points to draw right now: only when the layer is on and the map is
    /// zoomed in enough to be useful, culled to the viewport and capped for performance.
    /// Held in @State (not recomputed in body): body re-evaluates ~3 Hz off every detection
    /// publish, and the underlying nodes(in:) is a linear scan of the whole dataset. We refresh
    /// it only where its inputs actually change (camera move, layer toggle, dataset load).
    @State private var alprVisible: [ALPRPoint] = []

    /// Recompute the viewport-culled ALPR points. Called on the events that change its inputs,
    /// never in body. Clears out when the layer is off or the map is zoomed too far out.
    private func refreshALPRVisible() {
        // HYSTERESIS, not a single cliff. A lone 0.35 threshold can flip-flop across the boundary
        // (dots appear -> content grows -> zoom crosses back -> dots vanish -> ...), re-invalidating
        // body forever. Separate on/off thresholds make that physically impossible.
        let limit = alprVisible.isEmpty ? 0.30 : 0.40
        guard alpr.enabled, span.latitudeDelta < limit else {
            if !alprVisible.isEmpty { alprVisible = [] }   // only WRITE when it actually changes
            return
        }
        var next = alpr.nodes(in: region, cap: 500).map {
            ALPRPoint(id: $0.id, coord: $0.coord, maker: $0.maker, tier: $0.tier)
        }
        applyPeek(&next)   // stamp "a live pin is standing on this camera" HERE, in the cull pass
        // ALPRPoint is Equatable: an unchanged viewport costs zero @State writes / zero invalidations.
        if next != alprVisible { alprVisible = next }
    }

    /// Rendered pin coordinates carried over from the last body pass, plus the throttle state for
    /// re-stamping the ring-peek flags. A REFERENCE box held in @State, with no @State of its own:
    /// it is written from the map's pin-set change handler, which runs at pin-arrival cadence, and
    /// a @State write there would invalidate body (and so re-run makeSnapshot) for nothing.
    private final class PeekState {
        /// The pins the map actually drew last pass, from MapSnapshot.pins - so the peek match
        /// reads the SAME store pass that fed the map instead of taking a second one of its own.
        var pins: [CLLocationCoordinate2D] = []
        /// MONOTONIC uptime, not a Date: a wall-clock stamp goes backwards whenever the phone's
        /// clock is corrected or crosses a DST boundary, and the throttle would then compute an
        /// enormous wait and park the trailing run for hours - a permanently missed update.
        var lastStamp: TimeInterval = -.greatestFiniteMagnitude
        var pending: DispatchWorkItem?
    }
    @State private var peekState = PeekState()

    /// Minimum spacing between two ring-peek stamps. THROTTLED, not debounced: the first change in
    /// a quiet period stamps immediately, and a burst behind it collapses into ONE trailing run at
    /// the end of the window. A debounce would starve here - detections publish at roughly 3 Hz on
    /// a busy drive and every arrival moves the pin set, so its timer would be cancelled forever
    /// and the ring would never light up, which is the whole feature failing silently.
    private static let peekThrottle: TimeInterval = 0.5

    /// Re-stamp the ring-peek flags now, without re-culling. NO store pass: the rings are the
    /// already-culled, already-capped alprVisible, and the pins came from the body pass that drew
    /// them. Free while the layer is drawing no rings (switched off, or zoomed out past the
    /// threshold), which is also why the throttle clock only advances when there was work to do.
    private func stampPeek() {
        peekState.pending?.cancel()
        peekState.pending = nil
        guard !alprVisible.isEmpty else { return }
        peekState.lastStamp = ProcessInfo.processInfo.systemUptime
        var next = alprVisible
        applyPeek(&next)
        if next != alprVisible { alprVisible = next }
    }

    /// Coalesced entry point for "the drawn pins changed, re-match the rings". The leading edge
    /// runs immediately, so a filter tap or a lone new sighting lights its ring at once; anything
    /// inside the throttle window queues exactly one trailing run, so a stream of arriving
    /// detections can never become a stream of match passes - and, because that run is QUEUED
    /// rather than dropped, never a permanently missed update either.
    private func schedulePeekStamp() {
        guard !alprVisible.isEmpty else { return }   // no rings drawn: nothing to stamp
        let wait = Self.peekThrottle - (ProcessInfo.processInfo.systemUptime - peekState.lastStamp)
        guard wait > 0 else { stampPeek(); return }
        guard peekState.pending == nil else { return }   // a trailing run is already queued
        let work = DispatchWorkItem { stampPeek() }
        peekState.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: work)
    }

    /// Mark every ring one of the last-drawn pins is standing on. One banded proximity sweep over
    /// the culled, capped ring set, and no store pass of its own (see PeekState.pins).
    private func applyPeek(_ points: inout [ALPRPoint]) {
        guard !points.isEmpty else { return }
        let flags = ALPRRingPeek.matches(rings: points.map(\.coord), pins: peekState.pins)
        for i in points.indices { points[i].peek = flags[i] }
    }

    /// A one-line hint when the ALPR layer is on but drawing nothing, so "off" is never confused
    /// with "failed to load" or "zoomed out too far". Keyed to the ACTUAL draw state plus the
    /// hysteresis "appear" threshold (0.30) rather than a third cutoff: a lone 0.35 here both
    /// showed the hint while dots were still drawn ([0.35, 0.40)) and went silent in the dead
    /// band where nothing drew yet ([0.30, 0.35)).
    private var alprHint: String? {
        guard alpr.enabled, !alpr.loading else { return nil }
        if alpr.nodes.isEmpty {
            // A 404 is not a connectivity problem and must not be reported as one: this build
            // polls its own manifest, so there is a legitimate window before the dataset is
            // published where the file simply is not there yet.
            if alpr.lastOutcome == .notPublished {
                return "camera data not published yet \u{00B7} try again later"
            }
            return "couldn't load camera data \u{00B7} check your connection"
        }
        if alprVisible.isEmpty && span.latitudeDelta >= 0.30 { return "zoom in to see mapped cameras" }
        return nil
    }

    /// Where the pin goes: a drone's own broadcast coordinate if it has one, else
    /// the phone's position at our closest pass to it (strongest signal we got);
    /// Flock / body-cam / tracker, the board has no GPS.
    private func mapCoord(for d: Detection) -> CLLocationCoordinate2D? {
        d.coordinate ?? ble.capturedLocation(for: d.id)
    }

    /// Nearby devices, item trackers, and the rotating-MAC accumulators (recording glasses,
    /// network cameras, which can mint hundreds of same-spot rows over days) accumulate into
    /// count bubbles. Surveillance infrastructure (Flock ALPR, Raven, drone, body cam, watched)
    /// ALWAYS renders as an individual marker, so a camera is never lost inside a clump. (A
    /// tracker later flagged as "following" will promote back to an individual marker.)
    private func clusterable(_ d: Detection) -> Bool {
        d.type == .nearbyDevice || d.type == .tracker
            || d.type == .recordingGlasses || d.type == .networkCamera
    }

    /// Hard cap on infra ANNOTATIONS, newest-first so a fresh sighting always draws. Counted
    /// AFTER same-spot grouping, which is the number that matters here: the cap exists to bound
    /// how many annotations MapKit is handed, and a whole standing position now costs one.
    /// Infra is the set that can still be huge once the viewport cull has run, because a
    /// city-wide zoom can legitimately hold the whole persisted store. (Drone rows skip the
    /// viewport cull, and a group holding one sorts to the front of this cut - see the snapshot
    /// loop for why - as does a trailed tracker's trail geometry, though that tracker's own pin
    /// is culled with the rest of the clusterable mass. Neither escaping set is ever more than a
    /// handful of rows.)
    ///
    /// NOT the same shape as Android, and the difference is deliberate on both sides. Android
    /// caps ROWS, taken from the mixed newest-first feed BEFORE anything splits infra from the
    /// clusterable mass, so its grouping only reduces how many markers the surviving rows draw
    /// (MapScreen.kt's MAP_MARKER_CAP; its own comment states that grouping does not widen that
    /// cap). iOS caps ANNOTATIONS after grouping. So the cap POINT, the quantity counted, and
    /// the number are each platform's own; what the two sides do share is the grouping rule
    /// itself (MapPinRules), not this.
    private static let infraPinCap = 300
    /// Above this many visible pins the per-pin repeatForever ping animation is dropped:
    /// hundreds of independent Core Animation loops with shadows peg older devices on
    /// their own, cull or no cull.
    private static let animatedPinCap = 40

    /// One store row inside a same-spot bucket, with its `lastSeen` stamp resolved once during
    /// the store walk. A named type rather than a tuple so `InfraPin` can hold the bucket exactly
    /// as it was filled, with no repacking.
    private struct SpotRow {
        let detection: Detection
        let seen: Date?
    }

    /// ONE rendered infrastructure annotation, which may stand for several sightings.
    ///
    /// Every detection heard from one standing position is stamped with the SAME phone
    /// coordinate, so infra pins land exactly on top of each other: only the topmost was
    /// tappable, nothing said how many were under it, and because the row list is newest-first
    /// the OLDEST sighting drew last and took every tap. So the snapshot groups them and picks
    /// which one draws (see MapPinRules).
    ///
    /// DRONE ROWS ARE IN HERE TOO. A drone used to draw its own pin from a separate set, laid
    /// down BEFORE these, so an infra pin sharing its coordinate covered it and the drone took
    /// no taps at all - with no badge sheet to reach it by, because it was never in a group.
    /// Its overlays (flight path, operator tether, launch glyph, operator marker) do not hang
    /// off this pin: they are emitted by their own pass over every located drone row, whether or
    /// not that row led its group, so folding the pin in loses none of them.
    ///
    /// `lead` is the pin that draws, chosen in one allocation-free scan. `group` is the bucket
    /// the store walk filled, kept UNORDERED: putting it in draw order belongs to the tap, not
    /// to the snapshot pass, so it happens in `orderedMembers()` (see the note there).
    private struct InfraPin: Identifiable {
        /// Stable across passes: the grid cell, not the lead's id. Keying on the lead would
        /// change identity the moment a more important sighting arrives, and MapKit pops an
        /// annotation whose identity changed.
        let id: String
        let coord: CLLocationCoordinate2D
        let lead: Detection
        /// The whole bucket in store order (newest-first, as the feed hands it over), held by
        /// reference: the snapshot pass never copies it and never re-orders it.
        let group: [SpotRow]
        /// The LEAD's age tier. The badge count is a group size, never an age.
        let age: MapPinRules.Age
        /// The lead's raw stamp, kept only so the over-cap sort does not re-resolve it.
        let leadSeen: Date?
        /// At least one member is a drone. Set while the bucket is filled, so the over-cap sort
        /// never has to look inside a group. Its only job is to sort these pins to the FRONT of
        /// the cut: a drone row escapes the viewport cull (its overlays can cross the viewport
        /// while it sits outside), so dropping its pin would leave a flight path drawn under
        /// nothing. That is a ranking, not an exemption - past the cap's worth of drone-bearing
        /// spots the cut reaches them too, and nothing here pretends otherwise.
        let holdsDrone: Bool

        /// How many sightings this one pin stands for: the badge number, and what decides
        /// whether a tap opens a dossier or the member sheet.
        var count: Int { group.count }

        /// The group in draw order, lead first. Resolved ON DEMAND - at a tap, and nowhere else.
        /// The snapshot runs at publish and camera-move cadence and this list is read at most
        /// once per tap, for the ONE pin the finger landed on; ordering every group in the
        /// snapshot instead ran a sort, and the arrays that sort builds, per pin per pass for a
        /// list almost nothing ever read. Same order `MapPinRules.ordered` has always produced,
        /// from the same function, so what the sheet gets is unchanged.
        func orderedMembers() -> [Detection] {
            guard count > 1 else { return [lead] }
            return MapPinRules.ordered(group, type: { $0.detection.type }, lastSeen: { $0.seen })
                .map(\.detection)
        }
    }

    /// Everything one body eval needs from the store, computed in a SINGLE pass. located /
    /// totalLocated / count(cat) / the per-layer splits used to be independent computed
    /// properties, each an O(store) filter resolving mapCoord per row, and body read them
    /// ~17x per eval at the ~3 Hz publish cadence. Infra pins also get the viewport cull +
    /// cap the cluster path and ALPR layer already had.
    /// The coordinates of the pins a snapshot actually DRAWS, wrapped so `.onChange` can watch
    /// them: CLLocationCoordinate2D is not Equatable, and the map needs to know when the pin set
    /// moved rather than re-stamping the ring peek on every ~3 Hz publish. One array compare per
    /// body pass. Every coordinate in here is an infra pin or a lone-member bubble: infra is
    /// bounded by the viewport cull and the 300-pin cap (drone-bearing groups escape the cull and
    /// sort to the FRONT of the cut, which is a ranking and not an exemption - see holdsDrone -
    /// so past a cap's worth of them the cut reaches those too), and the bubbles by the cull.
    private struct PinSet: Equatable {
        let coords: [CLLocationCoordinate2D]
        static func == (a: PinSet, b: PinSet) -> Bool {
            a.coords.count == b.coords.count
                && !zip(a.coords, b.coords).contains {
                    $0.latitude != $1.latitude || $0.longitude != $1.longitude
                }
        }
    }

    private struct MapSnapshot {
        let totalLocated: Int
        let counts: [String: Int]   // located per category, unfiltered (feeds the chips)
        /// Every LOCATED drone row that passed the filter, in store order and NOT viewport-culled.
        /// This is the overlay feed only - flight path, launch glyph, operator tether, operator
        /// marker - and it is deliberately independent of which row won its same-spot group. The
        /// drone's PIN comes out of `infra` like every other grouped row.
        let drones: [Detection]
        let infra: [InfraPin]       // same-spot grouped, capped newest-first; culled except for drone rows
        let clusters: [Cluster]
        let trackerTrails: [Detection]   // trackers with >= 2 crumbs; trail geometry, NOT viewport-culled
        let pinsAnimated: Bool      // ping rings only under animatedPinCap
        let pins: PinSet            // the drawn pins' coordinates; feeds the ring-peek match
        /// At least one drawn pin is in the STALE tier, so the legend explains the dim treatment.
        /// Gated for the same reason the ring-peek and lower-confidence rows are: a legend that
        /// names a treatment nothing on screen is using reads as a rendering bug.
        let hasStalePins: Bool
    }

    private func makeSnapshot() -> MapSnapshot {
        // ONE clock reading for the whole pass, so two pins built microseconds apart can never
        // land in different age tiers. The tier is re-derived on the passes that already rebuild
        // the map (a publish, a camera move, a filter tap); there is no timer behind it, so a pin
        // holds its tier until the next rebuild.
        let now = Date()
        var total = 0
        var counts: [String: Int] = [:]
        var drones: [Detection] = []
        var trackerTrails: [Detection] = []
        var clusterPoints: [(d: Detection, c: CLLocationCoordinate2D)] = []
        // Same-spot buckets, filled IN THIS PASS: grouping costs one hash per grouped row and no
        // second walk of the store. Held as an ARRAY plus an index map, not as a dictionary of
        // members: the groups have to come out in a fixed order (first appearance in the store's
        // newest-first feed), because `pins` below is compared element by element to decide
        // whether the drawn pin set moved. Dictionary iteration order is not part of that
        // contract, and a set that reshuffled for free would re-run the ring-peek match on every
        // publish that changed nothing.
        var spotIndex: [MapPinRules.SpotKey: Int] = [:]
        var spots: [(key: MapPinRules.SpotKey, coord: CLLocationCoordinate2D,
                     rows: [SpotRow], drone: Bool)] = []
        // Rows whose coordinate cannot be bucketed at all (a corrupt cache, a garbled fix).
        // They render exactly as they do today: one pin each, ungrouped.
        var unbucketed: [(d: Detection, c: CLLocationCoordinate2D, seen: Date?)] = []
        for d in ble.detections {
            guard let c = mapCoord(for: d) else { continue }
            total += 1
            counts[d.type.category, default: 0] += 1
            guard filter == nil || d.type.category == filter else { continue }
            let isDrone = d.type == .drone
            if isDrone {
                // The OVERLAY feed, taken before anything decides which pin draws: droneOverlay
                // and the operator marker below run off THIS list, once per located drone row,
                // so a drone whose pin was absorbed into a group led by another sighting still
                // draws its full flight path, tether, launch glyph and operator pin. NOT
                // viewport-culled either, because that geometry can cross the viewport while the
                // drone's own coordinate sits outside it, and drone counts are tiny.
                drones.append(d)
            }
            if clusterable(d) {
                // A tracker that has walked with us gets a breadcrumb trail. NOT viewport-culled
                // (same reasoning as drones: the trail can cross the viewport while the pin is
                // outside it); the set is tiny since crumbs need real movement to accumulate.
                if d.type == .tracker, ble.crumbTrail(for: d.id).count >= 2 { trackerTrails.append(d) }
                if inViewport(c) { clusterPoints.append((d, c)) }
            } else if isDrone || inViewport(c) {
                // Drones group with the infra rows rather than drawing from a set of their own.
                // Two pins at one coordinate means one of them takes every tap and the covered
                // one takes none; grouped, the coordinate draws ONE badged pin whose sheet
                // reaches every member, drone included. The drone keeps its viewport exemption
                // here so a pin that draws today still draws: outside the viewport the infra rows
                // were culled, so its group holds drone rows only and the pin is the drone's.
                let seen = ble.lastSeenDate(for: d.id)
                guard let key = MapPinRules.spotKey(c) else {
                    unbucketed.append((d, c, seen)); continue
                }
                if let i = spotIndex[key] {
                    spots[i].rows.append(SpotRow(detection: d, seen: seen))
                    if isDrone { spots[i].drone = true }
                } else {
                    // The first row in a cell fixes where its pin draws. Deliberately NOT an
                    // average of the members: these coordinates are one standing position, and
                    // averaging them would move the pin off a real recorded fix for no gain.
                    spotIndex[key] = spots.count
                    spots.append((key, c, [SpotRow(detection: d, seen: seen)], isDrone))
                }
            }
        }
        var infra: [InfraPin] = []
        infra.reserveCapacity(spots.count + unbucketed.count)
        // What this pass costs per pin, honestly: ONE call to MapPinRules.lead. That is a single
        // linear scan of the bucket with no sort and no intermediate array, and it returns the
        // lone row immediately for a bucket of one, which is nearly all of them. The bucket
        // itself is handed to the pin as-is (an array retain, not a copy), and the ordered
        // member list is built later, at the tap, for one pin. Sorting every bucket here and
        // materialising its members - which is what this did - ran a sort, its arrays, and one
        // more array per pin on every publish (~3 Hz) and every camera move, all of it BEFORE
        // the 300-pin cap below could throw any of it away.
        for spot in spots {
            guard let lead = MapPinRules.lead(spot.rows,
                                              type: { $0.detection.type },
                                              lastSeen: { $0.seen }) else { continue }
            infra.append(InfraPin(id: spot.key.id, coord: spot.coord, lead: lead.detection,
                                  group: spot.rows,
                                  age: MapPinRules.age(lastSeen: lead.seen, now: now),
                                  leadSeen: lead.seen, holdsDrone: spot.drone))
        }
        for r in unbucketed {
            infra.append(InfraPin(id: r.d.id, coord: r.c, lead: r.d,
                                  group: [SpotRow(detection: r.d, seen: r.seen)],
                                  age: MapPinRules.age(lastSeen: r.seen, now: now),
                                  leadSeen: r.seen, holdsDrone: r.d.type == .drone))
        }
        if infra.count > Self.infraPinCap {
            // Drone-bearing groups first, then newest lead. Drones are the one set that skipped
            // the viewport cull, so cutting one here would delete a pin that draws today and
            // strand the flight path the overlay pass still emits for that row. The id tie-break
            // is what makes the surviving set the SAME set pass to pass when stamps are equal:
            // sort is not stable, and a cut list that reshuffled would move the drawn pin set
            // for free (see the `pins` note below).
            infra.sort {
                if $0.holdsDrone != $1.holdsDrone { return $0.holdsDrone }
                let a = $0.leadSeen ?? .distantPast, b = $1.leadSeen ?? .distantPast
                return a == b ? $0.id < $1.id : a > b
            }
            infra.removeSubrange(Self.infraPinCap...)
        }
        let clusters = buildClusters(clusterPoints, now: now)
        // Drones are NOT added on top: their pins are inside `infra` now, so adding the overlay
        // feed would count those rows a second time and trip the animation cap early. (The
        // operator marker has never been counted either - it carries no ping to drop.)
        let pinCount = infra.count + clusters.count
        // Where the pins that ACTUALLY draw are, collected in THIS pass so the ring-peek match
        // never has to take a second one. Count bubbles are deliberately excluded: a bubble already
        // says "several things here" and opens a list naming them, so it never leaves the user
        // guessing the way a lone pin sitting on a hidden ring does. Infra is read AFTER the cap,
        // so a pin the map dropped can never light a ring.
        var pinCoords: [CLLocationCoordinate2D] = []
        pinCoords.reserveCapacity(pinCount)
        for p in infra { pinCoords.append(p.coord) }
        for c in clusters where c.single != nil { pinCoords.append(c.coord) }
        // Reads the tiers already resolved above, and stops at the first STALE pin it meets:
        // `contains` short-circuits and the `||` is lazy, so this is a search and not a tally,
        // and it never walks past the answer. Only a pass with NO stale pin anywhere reads both
        // sets in full, and both are bounded - infra by the viewport cull and the cap above, the
        // lone-member bubbles by the cull. The overlay feed is deliberately NOT consulted: the
        // legend explains a dim PIN, and a drone whose pin was absorbed into another row's group
        // is not drawing one. What that group DOES draw is its lead's age, which `infra` already
        // reports. Note the lead is chosen by priority first and only tie-breaks on recency, so
        // the absorbing row can be older than the drone it covers; the legend still matches the
        // screen either way, because it describes the pin that drew.
        let stale = infra.contains { $0.age == .stale }
            || clusters.contains { $0.age == .stale }
        return MapSnapshot(totalLocated: total, counts: counts, drones: drones, infra: infra,
                           clusters: clusters, trackerTrails: trackerTrails,
                           pinsAnimated: pinCount <= Self.animatedPinCap,
                           pins: PinSet(coords: pinCoords),
                           hasStalePins: stale)
    }

    /// Inside the current viewport (plus a 20% margin so bubbles don't pop at the edges while panning).
    private func inViewport(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude  - region.center.latitude)  <= region.span.latitudeDelta  * 0.6 &&
        abs(c.longitude - region.center.longitude) <= region.span.longitudeDelta * 0.6
    }

    /// Grid-clustered bubbles for ONLY the clusterable hits. Cell size scales with the
    /// current zoom (span / 14), so zooming in splits dense Desert-mode clumps apart and
    /// zooming out merges them.
    private func buildClusters(_ points: [(d: Detection, c: CLLocationCoordinate2D)],
                               now: Date) -> [Cluster] {
        // Points arrive VIEWPORT-CULLED from the snapshot pass. Without that cull every located
        // point in the whole store becomes a bucket, so a deep Desert-mode log hands MapKit
        // thousands of Annotations rebuilt on every publish (~3 Hz) and pegs the main thread.
        // Same culling refreshALPRVisible already does for the ALPR dots.
        guard !points.isEmpty else { return [] }
        let cell = max(span.latitudeDelta, span.longitudeDelta) / 14
        guard cell > 0 else {
            return points.map { Cluster(coord: $0.c, members: [$0.d], age: singleAge($0.d, now: now)) }
        }
        var buckets: [String: [(d: Detection, c: CLLocationCoordinate2D)]] = [:]
        for p in points {
            let gx = (p.c.latitude / cell).rounded(.down)
            let gy = (p.c.longitude / cell).rounded(.down)
            buckets["\(gx):\(gy)", default: []].append(p)
        }
        return buckets.map { key, members in
            // Average the members so the bubble sits in the middle of the clump.
            let lat = members.reduce(0) { $0 + $1.c.latitude } / Double(members.count)
            let lon = members.reduce(0) { $0 + $1.c.longitude } / Double(members.count)
            return Cluster(id: key, coord: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                           members: members.map(\.d),
                           // Only a LONE member draws a pin, so only a lone member needs an age.
                           // A count bubble already aggregates rows of mixed ages and carries no
                           // age cue, and resolving a stamp per member would put a lookup on every
                           // row of a dense Desert clump for something nothing draws.
                           age: members.count == 1 ? singleAge(members[0].d, now: now) : .recent)
        }
    }

    private func singleAge(_ d: Detection, now: Date) -> MapPinRules.Age {
        MapPinRules.age(lastSeen: ble.lastSeenDate(for: d.id), now: now)
    }

    var body: some View {
        let snap = makeSnapshot()   // ONE store pass per body eval; every layer below reads this
        NavigationStack {
            ZStack(alignment: .top) {
                map(snap)
                VStack(spacing: 12) {
                    header(snap)
                    filterBar(snap)
                }
                .padding(.horizontal, ACABTheme.pad)
                .padding(.top, 8)
                .background(
                    LinearGradient(colors: [ACABTheme.bg, ACABTheme.bg.opacity(0)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .top)
                )
                if snap.totalLocated == 0 && !emptyDismissed {
                    emptyBanner.transition(.opacity)
                }
            }
            .overlay(alignment: .bottomLeading) {
                legend(snap).padding(ACABTheme.pad).padding(.bottom, 6)
            }
            // Tap-away scrim: present ONLY while the settings menu is open. Layered above the
            // map (and the legend) but below the controls VStack that follows, so a tap anywhere
            // off the dropdown closes the menu (true tap-away, unlike the legend's tap-the-panel).
            .overlay {
                if mapSettingsOpen {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { mapSettingsOpen = false } }
                        .ignoresSafeArea()
                }
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 10) {
                    if mapSettingsOpen {
                        mapSettingsPanel
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    settingsButton
                    recenterButton
                }
                .padding(ACABTheme.pad).padding(.bottom, 6)
                .animation(.easeOut(duration: 0.2), value: mapSettingsOpen)
            }
            .overlay(alignment: .bottom) {
                if let hint = alprHint {
                    Text(hint)
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .padding(.bottom, 26)
                        .transition(.opacity)
                }
            }
            // Tapped a known-ALPR dot: one shared credit callout (tap it to dismiss). Sits above
            // the alprHint slot so the two never collide in the narrow zoom band where both apply.
            .overlay(alignment: .bottom) {
                if showALPRInfo {
                    Button { withAnimation(.easeOut(duration: 0.15)) { showALPRInfo = false } } label: {
                        HStack(spacing: 6) {
                            Circle().strokeBorder((tappedALPRTier == 1 ? ACABTheme.flockTone : ACABTheme.warn).opacity(0.95),
                                                  style: StrokeStyle(lineWidth: 2,
                                                                     dash: tappedALPRTier == 1 ? [] : [2, 1.8]))
                                .frame(width: 9, height: 9)
                            // The line the journalist needed: a pin is a MAPPED LOCATION, not a
                            // live detection, and most fixed ALPRs backhaul over cellular so they
                            // are silent to this hardware whether or not one is standing there.
                            // The unverified tier says so more softly still: nobody recorded a
                            // manufacturer for it, which is the shape a misidentified pole takes.
                            // On a PEEKING ring that denial is the one thing it must not say; see
                            // alprCalloutDetail.
                            VStack(alignment: .leading, spacing: 2) {
                                // TIER FIRST, then maker. Testing maker first printed "known
                                // ALPR" for a hand-typed name, contradicting the second line
                                // directly beneath it. The maker is still shown when we have one:
                                // an unverified node's NAME is the doubtful part, not its presence.
                                Text(ALPRAttribution.headline(
                                    tier: tappedALPRTier, maker: tappedALPRMaker))
                                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                                Text(alprCalloutDetail(tier: tappedALPRTier,
                                                       maker: tappedALPRMaker,
                                                       peek: tappedALPRPeek))
                                    .font(ACABTheme.mono(9)).foregroundStyle(ACABTheme.faint)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 60)
                    .transition(.opacity)
                }
            }
            .navigationBarHidden(true)
            // T5: regular width shows the tapped dossier in a trailing inspector (pin stays
            // visible); compact keeps today's full sheet. Exactly one is active per size class.
            .modifier(DossierPresentation(selected: $selected, regular: hSize == .regular))
            .sheet(item: $cluster) { c in
                ClusterListSheet(cluster: c) { d in
                    cluster = nil
                    // Defer so the picker sheet finishes dismissing before the detail one
                    // presents (two sheets can't transition at the same instant).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { selected = d }
                }
                .environmentObject(ble)
                .presentationDetents([.medium, .large])
            }
            // Dossier "OPEN IN MAP" handoff. Cold tab: the stash is consumed on first
            // compose. Warm tab (including a dossier opened from this very map): drop
            // our own presented dossier so it isn't in the way, then fly. The sheet
            // dismisses itself, but the regular-width inspector has no dismiss of its
            // own, so the clear here is what closes it.
            // Focus is consumed BEFORE the detections fit so an explicit handoff always wins.
            .onAppear {
                // Location is optional for pairing. Ask only when the user opens the one
                // surface that needs observer coordinates; existing grants simply resume fixes.
                if !ble.demoMode { ble.requestLocationAccessIfNeeded() }
                consumePendingFocus()
                fitToDetections()
            }
            // Late first fix: the tab opened before anything was locatable. One-shot, so it
            // can never fight a user pan after it has fired once.
            .onChange(of: ble.detections.count) { _, _ in fitToDetections() }
            // Demo seeds re-place around the user when the first GPS fix arrives - same COUNT,
            // new coordinates - so the hook above never fires and a one-shot fit taken on the
            // authored-city coords would strand the camera over six invisible pins (the exact
            // "5 sightings, no pins" bug). Demo only: live detections never teleport, and the
            // demo store is six rows, so re-arming the fit there is cheap and safe.
            //
            // Keyed on demoSeedKey, NOT on `ble.detections`: the rule the pin-set handler below
            // spells out. The store republishes a freshly built array at ~3 Hz, so Array `==` has
            // no buffer-identity shortcut and SwiftUI ran an element-by-element compare on every
            // body pass of a REAL session - walking the entire store on any pass where it found
            // no difference at all - purely to reach a handler that returns at the guard.
            // Outside demo the key is a constant empty array, which compares on count alone.
            .onChange(of: demoSeedKey) { _, _ in
                guard ble.demoMode else { return }
                didFitToDetections = false
                fitToDetections()
                // The re-placed seeds are new PIN COORDINATES, so the map's pin-set handler
                // re-matches the rings on the body pass this very change triggers. Nothing to do
                // here: stamping now would only match the pins from before they moved.
            }
            .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
                selected = nil
                consumePendingFocus()
            }
        }
    }

    /// What the demo re-fit watches: the six seeded rows while the tour is running, and a
    /// constant empty array otherwise. The re-fit only ever cares about seeds being re-placed,
    /// so a live session should not be comparing the live store to notice that nothing happened.
    private var demoSeedKey: [Detection] { ble.demoMode ? ble.detections : [] }

    /// Frame the camera to the located detections' bounding region, exactly once per tab life.
    /// This runs BEFORE the hard-coded city fallback can matter, which is the fix for the demo
    /// bug where the header said "5 sightings" over an empty viewport: the seeds sat in one city
    /// while .userLocation's fallback framed another, and nothing ever reconciled them. The 40%
    /// margin plus a 0.01-degree floor keeps a tight clump (the demo seeds span ~0.005 degrees)
    /// comfortably inside the frame, single points get a neighborhood-scale view. A history that
    /// spans more than 1 degree on either axis (a road trip, weeks of driving) gets the OPPOSITE
    /// treatment: a full-bbox fit would open on a useless continent-scale wash of pins, so frame
    /// the MOST RECENT located detection at street scale instead - the newest sighting is what
    /// the user opened the tab to see.
    private func fitToDetections() {
        guard !didFitToDetections, MapFocus.pending == nil else { return }
        let coords = ble.detections.compactMap { mapCoord(for: $0) }
        guard let first = coords.first else { return }
        didFitToDetections = true
        var minLat = first.latitude,  maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude);  maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        // Continent-wide history: `first` IS the most recent located detection (detections is
        // sorted newest-first and compactMap preserves order), so center on it at 0.02 degrees
        // (~2 km, a recognizable neighborhood) rather than fitting the whole bbox.
        if maxLat - minLat > 1.0 || maxLon - minLon > 1.0 {
            withAnimation(.easeInOut(duration: 0.5)) {
                camera = .region(MKCoordinateRegion(
                    center: first,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)))
            }
            return
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2,
                                            longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
                                    longitudeDelta: max((maxLon - minLon) * 1.4, 0.01))
        withAnimation(.easeInOut(duration: 0.5)) {
            camera = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    /// City-block zoom for the dossier handoff, roughly 600 m across.
    private static let focusSpan = MKCoordinateSpan(latitudeDelta: 0.006, longitudeDelta: 0.006)

    /// Consume the one-shot dossier handoff, if any: fly the camera to the stashed
    /// coordinate at city-block zoom. Called from onAppear (cold tab) and the MapFocus
    /// notification (warm tab); the nil-out makes it exactly-once. Also retires the
    /// detections fit: an explicit handoff placed the camera deliberately.
    private func consumePendingFocus() {
        guard let coord = MapFocus.pending else { return }
        MapFocus.pending = nil
        didFitToDetections = true
        withAnimation(.easeInOut(duration: 0.6)) {
            camera = .region(MKCoordinateRegion(center: coord, span: Self.focusSpan))
        }
    }

    private func map(_ snap: MapSnapshot) -> some View {
        Map(position: $camera) {
            UserAnnotation()                       // the phone's live position
            // Known ALPR cameras (default-on reference layer), drawn UNDER the live pins so a
            // live hit always sits on top. Quiet hollow rings, not the animated detection pins.
            // Tap one for the shared DeFlock credit callout: a Button (cheap) flips ONE @State
            // that a single bottom overlay reads - never a per-dot popover (see ALPRDot).
            ForEach(alprVisible) { p in
                Annotation("", coordinate: p.coord) {
                    Button {
                        tappedALPRMaker = p.maker
                        tappedALPRTier = p.tier
                        // The ring the finger landed on is the only thing that knows whether a
                        // live pin is standing on it; the shared callout below has no other way
                        // to find out, so the flag is recorded here with the maker and tier.
                        tappedALPRPeek = p.peek
                        withAnimation(.easeOut(duration: 0.15)) { showALPRInfo = true }
                    } label: { ALPRDot(confirmed: p.confirmed, peek: p.peek) }
                        .buttonStyle(.plain)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                        .accessibilityLabel(alprAccessibilityLabel(p))
                        .accessibilityHint("Shows information about this mapped camera")
                }
            }
            // Tracker breadcrumb trails: the phone's path while a separated tracker stayed with
            // us. Drawn UNDER the live pins (like the ALPR layer) so the tracker's own pin sits on
            // top, and DASHED teal so it reads distinct from the SOLID amber drone flight paths.
            // Hidden when the "breadcrumb trail" setting is off.
            if showBreadcrumbs {
                ForEach(snap.trackerTrails) { d in
                    trackerTrail(d)
                }
            }
            // Drone flight paths, launch glyphs, operator tethers and operator markers. This
            // pass runs for EVERY located drone row and knows nothing about grouping, so a drone
            // whose pin was absorbed into a group led by another sighting keeps all of it. The
            // drone's own pin is drawn once, by the infra pass below, as that group's member.
            // Z-ORDER, deliberate: the OP marker used to draw just after its drone's pin and so
            // sat above it. The pin moved into the infra pass, so the pin now sits above OP where
            // the two coincide - a grounded drone, or any zoom-out that collapses the tether.
            // That is the better way round: the pin is the tappable thing that opens the dossier,
            // and OP is a non-interactive marker the tether already identifies.
            ForEach(snap.drones) { d in
                droneOverlay(d)
                if let pilot = d.pilotCoordinate {
                    Annotation(showLabels ? "OP" : "", coordinate: pilot) { OperatorPin() }
                }
            }
            // Surveillance infrastructure, drones included: always an individual marker, never
            // bubbled into the count-bubble layer. Sightings stamped at the SAME standing
            // position collapse into one pin carrying a small count badge; the tap opens the same
            // member sheet a count bubble opens, so nothing is left buried under the pin on top.
            ForEach(snap.infra) { p in
                Annotation(showLabels ? p.lead.type.shortTag : "", coordinate: p.coord) {
                    Button {
                        // The member list is put in draw order HERE, on the tap, for this one
                        // pin - never in the snapshot pass for every pin on the map.
                        if p.count == 1 { selected = p.lead }
                        else { cluster = Cluster(id: p.id, coord: p.coord, members: p.orderedMembers()) }
                    } label: {
                        MapPin(type: p.lead.type,
                               animated: snap.pinsAnimated && p.age == .fresh,
                               badge: p.count,
                               dimmed: p.age == .stale)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(infraAccessibilityLabel(p))
                    .accessibilityHint(p.count == 1
                                       ? "Opens detection details"
                                       : "Opens the detections at this spot")
                }
            }
            // Clusterable hits: grid-clustered bubbles. A lone member renders as a normal
            // pin; a clump renders one count bubble so a dense log stays legible.
            ForEach(snap.clusters) { c in
                Annotation(showLabels ? c.shortTag : "", coordinate: c.coord) {
                    if let only = c.single {
                        Button { selected = only } label: {
                            MapPin(type: only.type,
                                   animated: snap.pinsAnimated && c.age == .fresh,
                                   dimmed: c.age == .stale)
                        }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(pinAccessibilityLabel(only, age: c.age))
                            .accessibilityHint("Opens detection details")
                    } else {
                        Button { cluster = c } label: { ClusterBubble(cluster: c) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(clusterAccessibilityLabel(c))
                            .accessibilityHint("Opens the detections in this area")
                    }
                }
            }
        }
        // Captions follow the "icon labels" setting: each Annotation title is empty "" (no
        // caption, cleaner map) unless showLabels is on, when it carries the pin's short tag.
        // (Map has no .annotationTitles modifier; the empty title is the supported way to
        // suppress the caption, same as the ALPR dots, which always stay uncaptioned.)
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        // MapUserLocationButton is deliberately NOT here: .mapControls renders at the map's top-trailing,
        // which on this full-bleed map sits UNDER our own header badge - invisible and untappable. The
        // custom recenterButton (bottom-trailing, styled like the rest of the app) replaces it.
        .mapControls { MapCompass() }
        .preferredColorScheme(.dark)
        .onMapCameraChange(frequency: .onEnd) { ctx in
            // MKCoordinateRegion/MKCoordinateSpan have NO Equatable conformance, so SwiftUI cannot dedupe
            // these @State writes for us: without this guard every callback invalidates body
            // unconditionally, even when the region is bit-identical. Required independently of the
            // .automatic fix above. (Android already does this - MapScreen.kt writes only on a flip.)
            let r = ctx.region, eps = 1e-6
            guard abs(r.center.latitude  - region.center.latitude)  > eps
               || abs(r.center.longitude - region.center.longitude) > eps
               || abs(r.span.latitudeDelta  - region.span.latitudeDelta)  > eps
               || abs(r.span.longitudeDelta - region.span.longitudeDelta) > eps else { return }
            span = r.span; region = r
            refreshALPRVisible()   // viewport changed: re-cull the drawn ALPR points
        }
        // refresh on the other two inputs: the layer toggling on/off, and the dataset finishing
        // its load. nodes.count is a cheap Equatable proxy for "the dataset changed".
        .onChange(of: alpr.enabled) { _, _ in refreshALPRVisible() }
        .onChange(of: alpr.showUnverified) { _, _ in refreshALPRVisible() }
        .onChange(of: alpr.nodes.count) { _, _ in refreshALPRVisible() }
        // The rings do not move when the pins do, but the PEEK does: a filter change hides or
        // reveals pins, a new sighting adds one, and a drone steps along its track, all without
        // touching the viewport. Keyed to the pin SET this pass actually drew - not to a count,
        // and never to `ble.detections` itself, which republishes at ~3 Hz - so a row that was
        // already in the store and only just got a coordinate still lands, while a publish that
        // moved no pin costs one array compare and nothing else. Stashing the pins here (an event
        // handler, not body) is what lets the match skip a store pass; the stamp behind it is
        // throttled, so an arrival stream cannot become a match-pass stream. `initial: true` seeds
        // the pins on the first pass, when there is no previous set to differ from.
        .onChange(of: snap.pins, initial: true) { _, pins in
            peekState.pins = pins.coords
            schedulePeekStamp()
        }
        .onAppear {
            refreshALPRVisible()
            // The first cull can land before the seeding above (SwiftUI does not order two
            // handlers on one view), in which case it stamped against no pins at all. Re-stamping
            // is free when it was not needed: ALPRPoint is Equatable, so an unchanged result is
            // zero @State writes.
            schedulePeekStamp()
        }
        // VoiceOver summary of what the pins carry: a silent map reads as an empty one.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mapAccessibilityLabel(snap))
        .ignoresSafeArea()
    }

    /// One spoken sentence carrying the map's actual state: the pin content for VoiceOver
    /// users, or which of the two empty stories (permission vs nothing located) applies.
    private func mapAccessibilityLabel(_ snap: MapSnapshot) -> String {
        if snap.totalLocated == 0 {
            if ble.locationDenied && !ble.demoMode {
                return "Map. The app cannot record where your phone heard detections while Location is off. Drones that broadcast Remote ID coordinates can still appear."
            }
            return "Map. No located detections yet."
        }
        let shown = displayedLocatedCount(snap)
        let filtered = filter.map { " filtered to \($0.lowercased())" } ?? ""
        return "Map showing \(shown) located detection\(shown == 1 ? "" : "s")\(filtered)."
    }

    private func pinAccessibilityLabel(_ d: Detection, age: MapPinRules.Age) -> String {
        let type = spokenType(d.type)
        let name = d.displayName == d.type.label ? type : "\(d.displayName), \(type)"
        // The dim treatment is a purely visual cue, so VoiceOver is told the same fact in words.
        let stale = age == .stale ? " Not heard in the last hour." : ""
        return "\(name). Signal strength \(d.rssi) decibels relative to one milliwatt.\(stale)"
    }

    /// A grouped infra pin speaks the sighting it DRAWS plus how many it stands for, because the
    /// count badge is the only thing on screen saying the other members exist.
    private func infraAccessibilityLabel(_ p: InfraPin) -> String {
        let base = pinAccessibilityLabel(p.lead, age: p.age)
        guard p.count > 1 else { return base }
        return "\(base) This pin represents \(p.count) detections at the same spot."
    }

    private func spokenType(_ type: DeviceType) -> String {
        switch type {
        case .flockCamera:      return "automatic license plate reader camera"
        case .flockRaven:       return "Flock Raven audio sensor"
        case .axonBodyCam:      return "body camera"
        case .drone:            return "drone with remote identification"
        case .tracker:          return "item tracker"
        case .nearbyDevice:     return "nearby device"
        case .watched:          return "watched device"
        case .recordingGlasses: return "recording glasses"
        case .networkCamera:    return "network camera"
        case .unknown:          return "unknown device"
        }
    }

    private func alprAccessibilityLabel(_ point: ALPRPoint) -> String {
        let base = ALPRAttribution.accessibilityLabel(tier: point.tier, maker: point.maker)
        // The enlarged ring is a purely visual cue, so VoiceOver is told the same fact in words.
        guard point.peek else { return base }
        return "\(base). A live detection is sitting on this mapped camera."
    }

    /// The clause a resting tier-1 ring ends on. Byte-identical to the tail of
    /// ALPRAttribution.detail(tier: 1, maker:) - the only tier whose wording denies a detection.
    private static let alprNotLiveClause = ", not a live detection"
    /// The ring-peek fact, in the callout's own words. Byte-identical to Android's
    /// ALPR_PEEK_SNIPPET (MapAlpr.kt), so the two platforms say the same sentence about the same
    /// ring. Says what was HEARD here, never that the mapped camera is the thing we heard.
    private static let alprPeekSentence = "wide ring: a live detection was heard at this mapped location"

    /// The tap callout's second line. `ALPRAttribution.detail` describes the RECORD, and its
    /// tier-1 wording ends "a mapped location, not a live detection" - true of a resting ring, a
    /// flat denial on one a live pin is standing on, which is the single case the ring-peek cue
    /// exists to show. The legend row and the VoiceOver label already tell the truth about that
    /// ring, so a sighted user was the only one being told otherwise. On a peeking ring the
    /// denial drops and the peek sentence carries the claim instead, matching Android's
    /// alprMarkerText(peek:). Nothing else moves: the tier body stays byte-identical, because the
    /// peek says something about the DETECTION, not about this row's attribution.
    private func alprCalloutDetail(tier: UInt8, maker: String, peek: Bool) -> String {
        let base = ALPRAttribution.detail(tier: tier, maker: maker)
        guard peek else { return base }
        let body = base.hasSuffix(Self.alprNotLiveClause)
            ? String(base.dropLast(Self.alprNotLiveClause.count)) : base
        return "\(body) \u{00B7} \(Self.alprPeekSentence)"
    }

    private func clusterAccessibilityLabel(_ cluster: Cluster) -> String {
        let groups = Dictionary(grouping: cluster.members, by: { spokenType($0.type) })
            .map { type, rows in
                rows.count == 1 ? "one \(type)" : "\(rows.count) detections of type \(type)"
            }
            .sorted()
            .joined(separator: ", ")
        return "\(cluster.members.count) detections in this area: \(groups)"
    }

    /// Drone-only overlays: the flight-path line, a launch marker at the first fix,
    /// and a dashed tether to the operator.
    @MapContentBuilder
    private func droneOverlay(_ d: Detection) -> some MapContent {
        let track = ble.track(for: d.id)
        if track.count >= 2 {
            MapPolyline(coordinates: track)
                .stroke(ACABTheme.droneTone.opacity(0.85), lineWidth: 2.5)
        }
        if let launch = track.first {
            Annotation(showLabels ? "LAUNCH" : "", coordinate: launch) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(ACABTheme.droneTone)
                    .background(Circle().fill(.black.opacity(0.5)))
            }
        }
        if let drone = d.coordinate, let pilot = d.pilotCoordinate {
            MapPolyline(coordinates: [drone, pilot])
                .stroke(ACABTheme.droneTone.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        }
        if d.coordinate == nil, let me = ble.selfCoord {   // no GPS fix: draw an RSSI ring around us instead
            MapCircle(center: me, radius: rssiRadiusMeters(d.rssi))
                .foregroundStyle(ACABTheme.droneTone.opacity(0.08))
                .stroke(ACABTheme.droneTone.opacity(0.5), lineWidth: 1.5)
        }
    }

    /// A tracker's breadcrumb trail: the phone's path while a separated tag stayed with us.
    /// Dashed teal, distinct from the solid amber drone flight paths that use the same MapPolyline.
    @MapContentBuilder
    private func trackerTrail(_ d: Detection) -> some MapContent {
        let crumbs = ble.crumbTrail(for: d.id)
        if crumbs.count >= 2 {
            MapPolyline(coordinates: crumbs)
                .stroke(ACABTheme.trackerTone.opacity(0.85),
                        style: StrokeStyle(lineWidth: 3, dash: [6, 6]))
        }
    }

    /// Rough RSSI → distance in metres for the no-GPS ring. Log-distance path-loss
    /// model, deliberately fuzzy, just a "somewhere around here" hint.
    private func rssiRadiusMeters(_ rssi: Int) -> Double {
        let d = pow(10.0, (-50.0 - Double(rssi)) / 25.0)   // assumes TxPower -50 dBm, path-loss n ~ 2.5
        return min(max(d, 5), 600)
    }

    private func header(_ snap: MapSnapshot) -> some View {
        let shown = displayedLocatedCount(snap)
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Map").font(ACABTheme.display(26, weight: .semibold)).foregroundStyle(ACABTheme.text)
                Kicker("\(shown) SIGHTING\(shown == 1 ? "" : "S")")
            }
            Spacer()
            LinkChip(version: ble.status?.version, connected: ble.connectionState == .connected, demo: ble.demoMode)
        }
    }

    /// The header and spoken map summary describe the active filter, not the all-category total
    /// hidden behind it. Filter chips retain unfiltered counts so switching remains informative.
    private func displayedLocatedCount(_ snap: MapSnapshot) -> Int {
        guard let filter else { return snap.totalLocated }
        return snap.counts[filter] ?? 0
    }

    /// Scrolling category chips; tap one to narrow the pins. The ALL chip, the LAYERS control,
    /// and their divider are ALWAYS present; the category chips after them are dynamic (see
    /// `shownCategories`).
    private func filterBar(_ snap: MapSnapshot) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "ALL", snap.totalLocated)
                layersChip   // reference layers sit up front (after ALL) so they are found without scrolling
                Rectangle().fill(ACABTheme.line).frame(width: 1, height: 18).padding(.horizontal, 2)   // divider: layers vs category filters
                ForEach(shownCategories(snap)) { c in
                    chip(c.key, c.chipLabel, snap.counts[c.key] ?? 0)
                }
            }
            .padding(.bottom, 2)
        }
    }

    /// Which category chips to actually render: a category with at least one LOCATED detection
    /// this session, OR the currently-active filter even at count 0. The active-filter exception
    /// is REQUIRED: if the user has filtered to a category and its located count momentarily drops
    /// to 0 (eviction / staleness), the chip must NOT vanish out from under them, or the filter
    /// breaks silently with no visible way back to ALL.
    private func shownCategories(_ snap: MapSnapshot) -> [DetectionCategory] {
        detectionCategories.filter { (snap.counts[$0.key] ?? 0) > 0 || filter == $0.key }
    }

    /// Recenter on the phone's position. Replaces Apple's MapUserLocationButton, which lands under our
    /// header badge on this full-bleed map. Drives the camera EXPLICITLY, which is also why the fallback
    /// above can stay a fixed region instead of .automatic (see the loop note on `camera`).
    private var recenterButton: some View {
        Button {
            // The tap-away scrim sits BELOW this control (it has to, or the buttons stop taking
            // taps), so a tap here never reaches it and the open menu would stay up while the map
            // flew away under it. Close it here too.
            if mapSettingsOpen { withAnimation(.easeOut(duration: 0.2)) { mapSettingsOpen = false } }
            withAnimation(.easeInOut(duration: 0.35)) {
                camera = .userLocation(fallback: .region(MapTabView.fallbackRegion))
            }
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 38pt chip.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Center on my location")
    }

    /// Cog companion to the recenter/legend controls: opens the map settings dropdown. Its
    /// collapsed look matches the legend's info chip (small dark circular chip).
    private var settingsButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { mapSettingsOpen.toggle() }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(mapSettingsOpen ? ACABTheme.text : ACABTheme.dim)
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                // 44pt hit target around the 34pt chip.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map settings")
        .accessibilityValue(mapSettingsOpen ? "expanded" : "collapsed")
    }

    /// The map settings dropdown: persisted toggles plus the known-ALPR layer row, styled like
    /// `legendPanel`. Opened by `settingsButton`; the tap-away scrim in `body` closes it on a
    /// tap off the card. The ALPR toggle here and the filter-bar chip drive the same store, so
    /// they can never disagree.
    private var mapSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $showBreadcrumbs) {
                Text("breadcrumb trail").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            // Same sentence the SEEN WITH YOU panel ends on, deliberately word for word. This
            // toggle is the other tracker-only surface a user will assume covers everything, and a
            // trail that quietly skips body cams while claiming nothing is the kind of silence
            // that gets read as "nothing was there".
            Text(FollowEvidence.scopeLine)
                .font(ACABTheme.mono(8.5)).foregroundStyle(ACABTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: $showLabels) {
                Text("icon labels").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            Toggle(isOn: Binding(get: { alpr.enabled }, set: { alpr.setEnabled($0) })) {
                Text("known ALPR").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            if alpr.enabled {
                VStack(alignment: .leading, spacing: 7) {
                    Text(alprStatusLine)
                        .font(ACABTheme.mono(8.5)).foregroundStyle(ACABTheme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    // Opt-in for the tier nobody could name a manufacturer for. Off by default
                    // because those pins are where "your app is wrong" reports come from: the user
                    // drives to one, finds an empty pole, and blames the detector rather than the
                    // stranger who mapped it. Kept as a row instead of dropped from the dataset so
                    // the mappers who want to see and fix them still can.
                    if alpr.unverifiedCount > 0 {
                        Toggle(isOn: Binding(get: { alpr.showUnverified },
                                             set: { alpr.setShowUnverified($0) })) {
                            Text("lower-confidence pins").font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.faint)
                        }
                        Text(alprUnverifiedLine)
                            .font(ACABTheme.mono(8.5)).foregroundStyle(ACABTheme.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    alprCheckRow
                }
            }
        }
        .tint(ACABTheme.accent)
        .frame(width: 172, alignment: .leading)   // constrain so the switch and label separate cleanly
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    /// Status caption under the known-ALPR toggle: how many cameras we hold, the dataset's
    /// publish date, and when the manifest was last checked. Same middle-dot separators as
    /// the rest of the map overlays.
    private var alprStatusLine: String {
        let checked = alpr.lastChecked.map { "checked \(checkedAgo($0))" } ?? "never checked"
        guard !alpr.nodes.isEmpty else { return "no dataset yet \u{00B7} \(checked)" }
        // Count what the map DRAWS. Captioning the full dataset while hiding a chunk of it makes
        // the toggle below look broken (number never moves) and overstates the coverage.
        let shown = alpr.showUnverified ? alpr.nodes.count : alpr.nodes.count - alpr.unverifiedCount
        var parts = ["\(shown.formatted()) camera\(shown == 1 ? "" : "s")"]
        if let u = alpr.updated { parts.append("dataset \(datasetDate(u))") }
        parts.append(checked)
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Caption under the unconfirmed-pins toggle. Says what the tier MEANS rather than naming it,
    /// because "unverified" invites the reading that we checked and it failed. Nobody checked.
    private var alprUnverifiedLine: String {
        let n = alpr.unverifiedCount.formatted()
        return alpr.showUnverified
            ? "showing \(n) pin\(alpr.unverifiedCount == 1 ? "" : "s") without structured manufacturer attribution or from legacy aliases, drawn hollow. some are not cameras."
            : "\(n) lower-confidence pin\(alpr.unverifiedCount == 1 ? "" : "s") are hidden. some are not cameras."
    }

    /// Manual dataset refresh, mirroring the firmware "check for updates" row in Settings at
    /// panel scale: spinner while the manifest check + conditional download run, then a brief
    /// inline outcome before the label resets. Disabled while any fetch is in flight.
    private var alprCheckRow: some View {
        Button {
            guard !alprChecking else { return }
            Task {
                alprChecking = true
                alprJustChecked = false
                await alpr.refreshNow()
                alprChecking = false
                alprJustChecked = true
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                alprJustChecked = false
            }
        } label: {
            HStack(spacing: 6) {
                if alprChecking || alpr.loading {
                    ProgressView().controlSize(.mini).tint(ACABTheme.dim)
                } else {
                    Image(systemName: alprCheckSucceeded ? "checkmark" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(alprCheckLabel).font(ACABTheme.mono(10, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(alprCheckSucceeded ? ACABTheme.accent : ACABTheme.dim)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .disabled(alprChecking || alpr.loading)
        .accessibilityLabel("Check automatic license plate reader map data for updates")
    }

    /// True in the brief post-check window when the check actually completed (fresh data or
    /// confirmed current), coloring the row; a failed check keeps the resting look.
    private var alprCheckSucceeded: Bool {
        guard alprJustChecked, let o = alpr.lastOutcome else { return false }
        return o != .failed
    }

    private var alprCheckLabel: String {
        if alprChecking || alpr.loading { return "checking" }   // store-driven too, so an automatic on-enable refresh reads the same as a tap (parity with Android)
        if alprJustChecked {
            switch alpr.lastOutcome {
            case .updated(let n): return "updated \u{00B7} \(n.formatted()) camera\(n == 1 ? "" : "s")"
            case .upToDate:       return "up to date"
            default:              return "couldn't check"
            }
        }
        return "check for updates"
    }

    /// Short "checked X ago" tail, same buckets the detail screen's relativeAgo speaks in.
    private func checkedAgo(_ date: Date) -> String {
        // Non-trapping, same as relativeAgo: a bad persisted Date degrades, never crashes.
        let secs = max(0, Int(exactly: Date().timeIntervalSince(date).rounded(.down)) ?? Int.max)
        switch secs {
        case ..<60:       return "just now"
        case ..<3600:     return "\(secs / 60)m ago"
        case ..<86_400:   return "\(secs / 3600)h ago"
        default:          return "\(secs / 86_400)d ago"
        }
    }

    /// "2026-07-27" (the manifest's `updated`) -> "Jul 27", with the year kept only when it
    /// isn't this year. Fixed POSIX formats, per the TimeBasisCopy rule.
    private func datasetDate(_ ymd: String) -> String {
        let inFmt = DateFormatter()
        inFmt.locale = Locale(identifier: "en_US_POSIX")
        inFmt.dateFormat = "yyyy-MM-dd"
        guard let d = inFmt.date(from: ymd) else { return ymd }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX")
        out.dateFormat = Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        return out.string(from: d)
    }

    /// Entry to the map's reference LAYERS. This replaced the old "ALPR MAP" chip, which sat in
    /// the filter row and looked like a seventh filter while actually toggling a dataset
    /// download - a category of action the row's other chips never take. Same capsule anatomy,
    /// but named for what it holds; the popover explains the one-time offline download and is
    /// where a default-on layer gets turned off. Fill tracks the layer being on so the
    /// collapsed chip still shows the state at a glance.
    private var layersChip: some View {
        Button { showLayersPanel = true } label: {
            HStack(spacing: 5) {
                if alpr.loading {
                    ProgressView().controlSize(.mini).tint(alpr.enabled ? ACABTheme.onAccent : ACABTheme.dim)
                } else {
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 11, weight: .bold))
                }
                Text("LAYERS").font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
            }
            .foregroundStyle(alpr.enabled ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(alpr.enabled ? ACABTheme.flockTone : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(alpr.enabled ? .clear : ACABTheme.line, lineWidth: 1))
            // 44pt hit target; drawn capsule unchanged.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Map layers")
        .accessibilityValue(alpr.enabled ? "known automatic license plate reader cameras layer on" : "no layers on")
        .popover(isPresented: $showLayersPanel) {
            layersPanel.presentationCompactAdaptation(.popover)
        }
    }

    /// The LAYERS popover: the known-ALPR toggle (on by default) plus the one line explaining
    /// the one-time offline dataset download. The map-settings panel keeps its own toggle; both
    /// drive the same store, so they can never disagree.
    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker("LAYERS")
            Toggle(isOn: Binding(get: { alpr.enabled },
                                 set: { alpr.setEnabled($0); if $0 { alpr.refresh() } })) {
                Text("known ALPR cameras").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.text)
            }
            .tint(ACABTheme.accent)
            // Kept inside the guarantee the privacy page makes for this layer (web/privacy.html,
            // "Known-ALPR map layer"): no viewport, no location, no detections, no per-view
            // lookups - and a plain file download that the site host sees the way any web server
            // sees a request. The old wording promised "nothing about you or your map view is
            // ever sent", a stronger claim than the privacy page or the store's own comment
            // makes, and this app's users are the last people who should be told a fetch is
            // unobservable when it is not.
            Text("draws community-mapped camera locations, on by default. the dataset is one offline download; no location, viewport, or detection data is attached, and the site host sees an ordinary web request. pins are mapped locations, not live detections.")
                .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.dim)
                .fixedSize(horizontal: false, vertical: true)
            if alpr.enabled {
                Text(alprStatusLine)
                    .font(ACABTheme.mono(8.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 250)
        .presentationBackground(ACABTheme.bg2)
    }

    private func chip(_ cat: String?, _ label: String, _ n: Int) -> some View {
        let active = filter == cat
        let tint = catTint(cat)
        return Button { filter = cat } label: {
            HStack(spacing: 5) {
                Text(label).font(ACABTheme.mono(10.5, weight: .bold)).tracking(0.5)
                Text("\(n)").font(ACABTheme.mono(10))
                    .foregroundStyle(active ? ACABTheme.onAccent.opacity(0.7) : ACABTheme.faint)
            }
            .foregroundStyle(active ? ACABTheme.onAccent : ACABTheme.dim)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(active ? tint : ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? .clear : ACABTheme.line, lineWidth: 1))
            // 44pt hit target; drawn capsule unchanged.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(spokenCategory(label)), \(n) located")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func catTint(_ cat: String?) -> Color {
        switch cat {
        case "ALPR":     return ACABTheme.flockTone
        case "DRONE":    return ACABTheme.droneTone
        case "BODY CAM": return ACABTheme.axonTone
        case "TRACKER":  return ACABTheme.trackerTone
        case "GLASSES":  return ACABTheme.glassesTone
        case "CAMERA":   return ACABTheme.netcamTone
        default:         return ACABTheme.accent
        }
    }

    private func spokenCategory(_ label: String) -> String {
        switch label {
        case "ALPR": return "automatic license plate readers"
        case "DRONE": return "drones"
        case "BODY CAM": return "body cameras"
        case "CAMERA", "NETCAM", "NETWORK CAM": return "network cameras"
        case "TRKR", "TRACKER": return "item trackers"
        case "GLAS", "GLASSES": return "recording glasses"
        case "ALL": return "all categories"
        default: return label.lowercased()
        }
    }

    /// F18: whether the legend is open. Manual expansion aside, it auto-expands while the
    /// ALPR layer is downloading so the data credit is visible during the first load.
    /// Keyed to `downloading`, NOT `loading`: `loading` also covers the manifest freshness
    /// check that runs on every enable, so binding to it flashed the panel open and shut
    /// for a network round-trip that usually early-returns with the cache already drawn.
    private var legendOpen: Bool { legendExpanded || alpr.downloading }

    /// Collapsed by default: a small circular info chip. Tap to expand the full legend;
    /// tap the panel to tuck it away again.
    private func legend(_ snap: MapSnapshot) -> some View {
        Group {
            if legendOpen {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { legendExpanded = false }
                } label: { legendPanel(snap) }
                .buttonStyle(.plain)
                // NO .accessibilityLabel here, deliberately. A Button merges its label subtree
                // into ONE element, and an explicit label REPLACES the string SwiftUI synthesises
                // from that subtree's Texts - so "Collapse map legend" was the whole panel to
                // VoiceOver: no category rows, no dim-pin rule, no ring-peek row, and none of the
                // "cameras: OpenStreetMap ODbL · DeFlock" credit this panel auto-expands during
                // the first download to show. Value + hint say what the control does WITHOUT
                // standing in for the content, and the value keeps both legend states naming
                // which side they are on: the collapsed chip below carries
                // .accessibilityValue("collapsed"), and Android sets stateDescription
                // "expanded"/"collapsed" across that same pair (MapScreen.kt).
                .accessibilityValue("expanded")
                .accessibilityHint("Collapses the map legend")
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { legendExpanded = true }
                } label: {
                    Image(systemName: "info")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(ACABTheme.dim)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                        // 44pt hit target around the 34pt chip.
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Map legend")
                .accessibilityValue("collapsed")
            }
        }
        .animation(.easeOut(duration: 0.2), value: legendOpen)
    }

    private func legendPanel(_ snap: MapSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            legendRow(ACABTheme.flockTone, "ALPR")
            legendRow(ACABTheme.droneTone, "Drone")
            legendRow(ACABTheme.axonTone,  "Body cam")
            legendRow(ACABTheme.trackerTone, "Tracker")
            legendRow(ACABTheme.glassesTone, "Glasses")
            HStack(spacing: 7) {
                legendSwatch {
                    Image(systemName: "web.camera.fill")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(ACABTheme.netcamTone)
                        .frame(width: 8, height: 8)
                }
                Text("Network camera").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            // The dim treatment, named. A pin persisted from yesterday used to look exactly like a
            // live hit, so the cue only works if the panel says what it means. The swatch is the
            // ALPR tone at the very alpha a stale pin draws at, so it reads as a colour already in
            // the panel at lower strength rather than as another category; the hairline above it
            // is what separates the treatment from the category rows, the same way the
            // lower-confidence row below is separated. Gated on a stale pin actually being drawn,
            // for the same reason that row is gated on its tier being shown.
            if snap.hasStalePins {
                HStack(spacing: 7) {
                    legendSwatch {
                        Circle().fill(ACABTheme.flockTone.opacity(MapPinRules.staleTintAlpha))
                            .frame(width: 8, height: 8)
                    }
                    Text("Dimmed: last heard over an hour ago")
                        .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                }
                .padding(.top, 6)
                .overlay(alignment: .top) {
                    Rectangle().fill(ACABTheme.line).frame(height: 1)
                }
            }
            if alpr.enabled {
                // NOT a bare Divider: dividers are width-greedy and would balloon the
                // panel to the full overlay width. The hairline rides the row instead.
                HStack(spacing: 7) {
                    legendSwatch {
                        Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 2)
                            .frame(width: 9, height: 9)
                    }
                    Text("Known ALPR").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                }
                // The ring-peek cue, named. Gated on a ring actually peeking right now, the same
                // rule the lower-confidence row below follows: a legend that explains a treatment
                // nothing on screen is using reads as a rendering bug. The scan is only ever run
                // while the panel is expanded, over the capped culled set.
                if alprVisible.contains(where: \.peek) {
                    HStack(spacing: 7) {
                        // The widest swatch in the panel, and the reason the slot exists: the
                        // whole cue is "this ring is bigger", so the swatch has to be bigger too.
                        legendSwatch {
                            ZStack {
                                Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 1.6)
                                    .frame(width: 13, height: 13)
                                Circle().fill(ACABTheme.text).frame(width: 7.5, height: 7.5)
                            }
                        }
                        Text("Live hit on a mapped camera")
                            .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                }
                // Unverified tier. Hollow + DASHED, matching ALPRDot: the swatch has to be the
                // shape you actually see on the map, and it cannot be a filled amber dot because
                // ACABTheme.warn IS droneTone (both 0xF2B53C) - a filled one is pixel-identical to
                // the Drone row above.
                //
                // Gated on showUnverified for the same reason it is gated on alpr.enabled: a legend
                // that names a colour nothing on screen is using reads as a rendering bug.
                if alpr.showUnverified {
                    HStack(spacing: 7) {
                        legendSwatch {
                            Circle().strokeBorder(ACABTheme.warn.opacity(0.95),
                                                  style: StrokeStyle(lineWidth: 2, dash: [2, 1.8]))
                                .frame(width: 9, height: 9)
                        }
                        Text("ALPR (lower confidence)").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    }
                    .padding(.top, 6)
                    .overlay(alignment: .top) {
                        Rectangle().fill(ACABTheme.line).frame(height: 1)
                    }
                }
                Text("cameras: OpenStreetMap ODbL · DeFlock")
                    .font(ACABTheme.mono(8.5)).foregroundStyle(ACABTheme.faint)
            }
        }
        // Hug the content, but never past the screen. fixedSize(horizontal:) alone means "take my
        // ideal width" with no upper bound, which was safe only while the fonts ignored Dynamic
        // Type; once ACABTheme.mono started scaling, a large-text legend could run off the map.
        // The frame caps it so it still hugs when small and wraps when it cannot.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 260, alignment: .leading)
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    private func legendRow(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 7) {
            legendSwatch { Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.6), radius: 3) }
            Text(t).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
    }

    /// Width of the legend's swatch column. Every swatch sits centred in this SAME fixed slot, so a
    /// row whose swatch is bigger - the ring-peek one, which has to be bigger, that IS the cue -
    /// cannot push its label out of line with the rest of the column. Sized to the widest swatch.
    /// Android's LegendRow does the same with a 12dp box.
    private static let legendSwatchSlot: CGFloat = 13

    private func legendSwatch<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content().frame(width: Self.legendSwatchSlot, height: Self.legendSwatchSlot)
    }

    /// True when the "empty" story is a permission problem, not a data one. Demo mode exempts
    /// itself: its seeds carry coordinates regardless of the phone's location permission.
    private var emptyBecausePermission: Bool { ble.locationDenied && !ble.demoMode }

    /// Two distinct empty stories over the same slot. Permission off gets the actionable one
    /// (Open Settings); otherwise it is the honest "nothing located yet". Detections existing
    /// is the third state: the banner never mounts (see body) and the camera fits to them.
    private var emptyBanner: some View {
        VStack(spacing: 9) {
            Image(systemName: emptyBecausePermission ? "location.slash" : "mappin.slash")
                .font(.system(size: 28)).foregroundStyle(ACABTheme.faint)
            if emptyBecausePermission {
                Text("Location is off, so the app can't record where your phone heard detections. Drones that broadcast Remote ID coordinates can still appear on the map.")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openAppSettings) {
                    Text("OPEN SETTINGS")
                        .font(ACABTheme.mono(11, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.accent)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)   // 44pt target
                        .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text("No located detections yet")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                Text("Detections appear here once they're heard with location available.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
                Text("ALPR, body cam, glasses, network camera and tracker hits use your phone's position; drones report their own.")
                    .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                    .multilineTextAlignment(.center).frame(maxWidth: 250)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
            .strokeBorder(ACABTheme.line, lineWidth: 1))
        // Hit-testing stays ON when the Open Settings button is present (it has to be tappable);
        // the informational variant lets touches fall through so the map still pans behind it.
        .allowsHitTesting(emptyBecausePermission)
        .overlay(alignment: .topTrailing) {
            // Dismiss (x) on BOTH variants (the informational one used to have none). It lives in
            // this overlay, layered OVER the card AFTER the .allowsHitTesting above, so it stays
            // tappable even on the informational variant whose card passes gestures through to the
            // map: only the small x region intercepts touches, the rest still pans the map behind.
            Button {
                withAnimation(.easeOut(duration: 0.2)) { emptyDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold)).foregroundStyle(ACABTheme.dim)
                    .frame(width: 26, height: 26)
                    .background(ACABTheme.bg2, in: Circle())
                    .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                    // 44pt hit target around the 26pt chip.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// T5: on regular width the tapped dossier rides in a trailing `.inspector` (the map + pin
/// stay on screen); on compact it stays the full-height `.sheet`. Only one is ever active.
/// SwiftUI ships only `inspector(isPresented:)`, so presentation is derived from the item.
private struct DossierPresentation: ViewModifier {
    @Binding var selected: Detection?
    let regular: Bool
    @EnvironmentObject private var ble: BLEManager

    func body(content: Content) -> some View {
        if regular {
            content.inspector(isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            )) {
                if let d = selected {
                    DetectionDetailView(detection: d)
                        .environmentObject(ble)
                        .inspectorColumnWidth(min: 320, ideal: 380, max: 480)
                }
            }
        } else {
            content.sheet(item: $selected) { DetectionDetailView(detection: $0).environmentObject(ble) }
        }
    }
}

// MARK: - Shared map-pin rules

/// The two rules that decide what a map pin stands for and how old it is allowed to look.
///
/// Pure value logic: no CoreBluetooth, no SwiftUI, no store. That is what lets the tests pin the
/// rules down directly, and it is why every caller here reads the same answer instead of each
/// annotation re-deriving one.
///
/// SHARED WITH ANDROID on the RULE and on the thresholds below: the same-spot tolerance, the
/// priority order, "break ties by most recent", the three age boundaries, and "a missing stamp is
/// RECENT, never FRESH". What is deliberately NOT shared is artwork. Each platform draws its own
/// badge and its own dimmed marker with numbers derived from its own pin, so neither side may
/// "fix" the other's to match.
enum MapPinRules {

    // MARK: Same-coordinate grouping

    /// Grid cell for "the same standing position", in degrees. About 1.1 m of latitude.
    ///
    /// Every detection logged from one spot is stamped with the SAME phone coordinate, so infra
    /// pins land exactly on top of each other: only the topmost took a tap, nothing said how many
    /// were underneath, and the row list being newest-first meant the OLDEST sighting drew last
    /// and stole every one of those taps.
    ///
    /// QUANTIZED, not a pairwise radius sweep. The case this exists for is coordinates that are
    /// EQUAL, and a grid costs one hash per pin instead of comparing every pin to every other
    /// pin. The cost is a cell edge: two sightings a metre apart that straddle one stay separate,
    /// which is the safe direction to be wrong, because separate is exactly what the map draws
    /// today.
    static let sameSpotDegrees = 1e-5

    /// Which grid cell a coordinate falls in. Hashable and allocation-free; the group's string
    /// identity is built once per GROUP, never per row.
    struct SpotKey: Hashable {
        let lat: Int
        let lon: Int
        var id: String { "\(lat):\(lon)" }
    }

    /// The cell `c` falls in, or nil for a coordinate that cannot be bucketed without trapping
    /// (a NaN or a wild value out of a corrupt cache or a garbled Remote ID fix). A nil key is
    /// rendered ungrouped, i.e. exactly as it renders today.
    static func spotKey(_ c: CLLocationCoordinate2D) -> SpotKey? {
        let lat = (c.latitude / sameSpotDegrees).rounded(.down)
        let lon = (c.longitude / sameSpotDegrees).rounded(.down)
        // isFinite first: NaN fails every comparison, so an ordering test alone would let it
        // through to a trapping Int conversion.
        guard lat.isFinite, lon.isFinite, abs(lat) <= 1e12, abs(lon) <= 1e12 else { return nil }
        return SpotKey(lat: Int(lat), lon: Int(lon))
    }

    /// Which sighting a stack of same-spot pins draws AS. Lower is more important.
    ///
    /// This order IS the feature. The map's job is to say "a body camera was here", and a body
    /// camera must never end up hidden under an older, less important sighting that happens to
    /// share its coordinate.
    static func priority(_ type: DeviceType) -> Int {
        switch type {
        case .watched:      return 0   // the user named this exact device; nothing outranks that
        case .flockCamera:  return 1
        case .flockRaven:   return 2
        case .axonBodyCam:  return 3
        case .drone:        return 4
        default:            return 5   // everything else, in one bucket
        }
    }

    /// Same-spot members ordered so the pin that draws is element 0: priority first, then MOST
    /// RECENT, then the order they arrived in. That last step is not decoration. Swift's sort is
    /// not stable, so without it two members tied on both keys could swap between passes, and an
    /// annotation whose identity or artwork flickers pops on the map.
    static func ordered<T>(_ members: [T],
                           type: (T) -> DeviceType,
                           lastSeen: (T) -> Date?) -> [T] {
        guard members.count > 1 else { return members }
        return members.enumerated()
            .map { (i: $0.offset,
                    p: priority(type($0.element)),
                    t: (lastSeen($0.element) ?? .distantPast).timeIntervalSinceReferenceDate,
                    m: $0.element) }
            .sorted {
                if $0.p != $1.p { return $0.p < $1.p }
                if $0.t != $1.t { return $0.t > $1.t }
                return $0.i < $1.i
            }
            .map(\.m)
    }

    /// The one member a same-spot group DRAWS as, i.e. exactly what `ordered(_:)` puts first,
    /// found in a single linear scan with no sort and no intermediate array.
    ///
    /// This is the map's hot path: it runs once per infra pin on every publish and every camera
    /// move, while the full ordering runs once per tap. The two must never disagree, so the
    /// tie-break here is the same one by construction - a later member replaces the incumbent
    /// ONLY when it strictly wins on priority, or, at equal priority, strictly wins on recency -
    /// which leaves the earliest arrival holding a full tie, exactly as `ordered`'s index
    /// tie-break does. A group of one comes straight back out without resolving anything.
    static func lead<T>(_ members: [T],
                        type: (T) -> DeviceType,
                        lastSeen: (T) -> Date?) -> T? {
        guard let first = members.first else { return nil }
        guard members.count > 1 else { return first }
        var best = first
        var bestPriority = priority(type(first))
        var bestSeen = (lastSeen(first) ?? .distantPast).timeIntervalSinceReferenceDate
        for m in members.dropFirst() {
            let p = priority(type(m))
            if p > bestPriority { continue }   // outranked: its stamp never has to be resolved
            let t = (lastSeen(m) ?? .distantPast).timeIntervalSinceReferenceDate
            guard p < bestPriority || t > bestSeen else { continue }
            best = m
            bestPriority = p
            bestSeen = t
        }
        return best
    }

    // MARK: Age

    /// How old the sighting behind a pin is, in the three tiers the map draws.
    ///
    /// Without this a pin persisted from yesterday looked exactly like a live hit, and the ping
    /// animation was gated only on how many pins were on screen, so old pins pulsed like alerts.
    enum Age {
        /// Under `freshSeconds`. Full colour, and the ping may run (still subject to the pin-count
        /// cap and Reduce Motion).
        case fresh
        /// `freshSeconds` to `staleSeconds`, and the tier a pin with no usable stamp lands in.
        /// Full colour, no ping.
        case recent
        /// Past `staleSeconds`. Dimmed, no ping, and otherwise untouched: same size, same glyph,
        /// same colour family, still tappable.
        case stale
    }

    static let freshSeconds: TimeInterval = 5 * 60
    static let staleSeconds: TimeInterval = 60 * 60

    /// The tier for a row's lastSeen stamp, the same stamp the log and the cluster sheet order by.
    ///
    /// A missing or zeroed stamp resolves to RECENT, never FRESH. A row we cannot date is a row we
    /// cannot call live, and the whole point of the tier is that FRESH means something.
    static func age(lastSeen: Date?, now: Date) -> Age {
        // A zeroed stamp is 1970, which would otherwise read as the oldest thing on the map. It
        // means "unknown", so it takes the unknown tier.
        guard let lastSeen, lastSeen.timeIntervalSince1970 > 0 else { return .recent }
        let elapsed = now.timeIntervalSince(lastSeen)
        guard elapsed.isFinite else { return .recent }
        // Clamped, not trusted: a stamp ahead of the clock is a clock correction, not the future.
        let secs = max(0, elapsed)
        if secs < freshSeconds { return .fresh }
        if secs <= staleSeconds { return .recent }
        return .stale
    }

    /// Alpha a STALE pin draws its own tone at. See MapPin.tone for why this is alpha rather than
    /// a saturation filter.
    static let staleTintAlpha: Double = 0.45
}

/// Animated category pin: filled dot with a glyph and a slow ping ring. `animated: false`
/// (set once per body pass when the visible pin count crosses animatedPinCap, or when the
/// sighting behind the pin is not FRESH) drops the repeatForever ping entirely, so hundreds of
/// independent Core Animation loops never coexist on a dense map and an old sighting never
/// pulses like a live alert.
private struct MapPin: View {
    let type: DeviceType
    var animated = true
    /// How many detections this ONE pin stands for. 1 (or nil) draws today's artwork exactly:
    /// a group of one has to be visually unchanged.
    var badge: Int? = nil
    /// STALE tier: the pin keeps its size, its glyph and its colour family, and only its
    /// intensity drops. Never a hide, never a shrink, never a shared "old" colour.
    var dimmed = false
    @State private var ping = false
    // Reduce Motion drops the looping ping ring entirely, same as the dense-map cap does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The pin's tone at the current age. Dimming is done with COLOUR ALPHA rather than a
    /// .saturation / .grayscale modifier: those install a layer colour filter on every pin that
    /// carries one, and this map draws pins up to its own cap. Over the map's near-black ground
    /// a lowered alpha reads as the same hue, washed out, which is the cue.
    private var tone: Color { dimmed ? type.tint.opacity(MapPinRules.staleTintAlpha) : type.tint }

    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle().stroke(tone, lineWidth: 2).frame(width: 28, height: 28)
                    .scaleEffect(ping ? 1.9 : 0.9).opacity(ping ? 0 : 0.7)
            }
            Circle().fill(tone).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2.5))
                // The glow goes with the colour: a stale pin that still bloomed would keep
                // drawing the eye, which is the exact thing the tier exists to stop.
                .shadow(color: type.tint.opacity(dimmed ? 0 : 0.7), radius: 6)
            Image(systemName: type.symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
            if let badge, badge > 1 { countBadge(badge) }
        }
        .onAppear(perform: updateAnimation)
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
        .onChange(of: animated) { _, _ in updateAnimation() }
    }

    /// Small corner badge for a same-spot group: "this one pin is several sightings".
    ///
    /// Deliberately NOT ClusterBubble's shape. A count bubble is a large tint-ringed disc sitting
    /// ON the coordinate INSTEAD of a pin, and it means "several things somewhere in this area";
    /// this is a small capsule clipped to the shoulder of an ordinary pin, and it means "several
    /// things at exactly this point". Keeping the pin artwork whole is what keeps the two apart.
    private func countBadge(_ n: Int) -> some View {
        // Three digits would be wider than the pin it hangs off. The exact size stops mattering
        // long before that; the sheet behind the tap still lists every member.
        Text(n < 100 ? "\(n)" : "99+")
            .font(ACABTheme.mono(9, weight: .bold)).monospacedDigit()
            // The count stays at full strength on a dimmed pin: the age is the pin's business,
            // the number still has to be readable.
            .foregroundStyle(ACABTheme.text)
            .padding(.horizontal, 3)
            .frame(minWidth: 15, minHeight: 15)
            .background(ACABTheme.bg2, in: Capsule())
            .overlay(Capsule().strokeBorder(tone, lineWidth: 1))
            .offset(x: 14, y: -12)
    }

    private func updateAnimation() {
        var parked = Transaction(animation: nil)
        parked.disablesAnimations = true
        withTransaction(parked) { ping = false }
        guard animated, !reduceMotion else { return }
        withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { ping = true }
    }
}

/// Muted person icon for a drone's operator, kept distinct from the device pin.
/// Tap it for a one-line explanation: remote ID broadcasts the pilot's location.
private struct OperatorPin: View {
    @State private var showInfo = false
    var body: some View {
        Button { showInfo = true } label: {
            Image(systemName: "person.fill").font(.system(size: 11, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                .padding(6)
                .background(ACABTheme.bg3, in: Circle())
                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .frame(minWidth: 44, minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Drone operator")
        .accessibilityHint("Explains this Remote ID operator position")
        .popover(isPresented: $showInfo) {
            Text("operator. this drone broadcasts its pilot's location in its remote ID, so this pin is roughly where it's being flown from.")
                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(width: 230)
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// A known-ALPR camera point (default-on reference layer). ALP4 identity is stable OSM type + ID, so
/// two cameras mapped at the same coordinate remain distinct; legacy caches add their row index.
/// Equatable so refreshALPRVisible can early-out when the culled set is unchanged: without it every
/// camera callback rewrites @State and invalidates body even when nothing moved. `id` is stored, not
/// computed - it's read per-row by ForEach, and interpolating a String there is the same trap that
/// made Detection.id expensive.
private struct ALPRPoint: Identifiable, Equatable {
    let coord: CLLocationCoordinate2D
    let maker: String
    /// Raw attribution tier from ALP3/ALP4. Tier 1 gets the stronger solid treatment; tier 0 and
    /// tier 2 remain distinguishable in copy even though both use the lower-confidence ring.
    let tier: UInt8
    var confirmed: Bool { tier == 1 }
    /// A rendered detection pin is standing on this camera, so the ring draws enlarged and its rim
    /// peeks out around the pin. Stamped by applyPeek - on the cull pass, and on the throttled
    /// pin-set pass - NEVER in body. Part of `==` on purpose: a peek that appears or clears has to
    /// reach the map. See ALPRRingPeek.
    var peek = false
    let id: String
    init(id: String, coord: CLLocationCoordinate2D, maker: String, tier: UInt8) {
        self.id = id
        self.coord = coord
        self.maker = maker
        self.tier = tier
    }
    // Stable identity plus every display field keeps an unchanged viewport at zero @State churn.
    static func == (a: ALPRPoint, b: ALPRPoint) -> Bool {
        a.id == b.id && a.coord.latitude == b.coord.latitude
            && a.coord.longitude == b.coord.longitude && a.maker == b.maker && a.tier == b.tier
            && a.peek == b.peek
    }
}

/// Geometry for the "live hit AT a mapped camera" cue.
///
/// A filled detection pin - a 28pt disc inside its own tinted glow - completely covers a 14pt
/// known-ALPR ring, so at map level a hit standing on a mapped camera looked exactly like a hit
/// somewhere nobody has ever mapped. That is the single most useful sentence this map can say, and
/// it was invisible. A ring with a rendered pin on it draws at `diameter` instead of 14pt, so its
/// rim stands clear of the pin's artwork with a readable gap between the two.
/// The ring still draws UNDER the pins and keeps its confirmed/unverified stroke, so a peeking
/// ring is still a hollow static ring and can never be read as a detection of its own.
///
/// Keep in lockstep with Android (MapMarkers.kt rememberAlprMarker + the MapScreen.kt match pass)
/// on the RULE, not on every number: same match radius, same "rendered PINS only, never count
/// bubbles" rule, same "the rim visibly clears the pin's own artwork" requirement. The enlarged
/// DIAMETER is deliberately platform-specific - the two pin artworks are different sizes, so each
/// side derives its own number from its own pin (Android: 49dp, off a pin whose outermost ink is a
/// 41dp pulse ring). Neither side may "fix" the other's number to match.
enum ALPRRingPeek {
    /// A pin this close to a mapped camera is treated as standing ON it. Wide enough to absorb GPS
    /// scatter on both our own fix and the mapper's point, tight enough that the next camera down
    /// the block never claims the hit. SHARED WITH ANDROID - this one IS the same number.
    static let radiusMeters: Double = 25

    /// Outer diameter of a matched ring, derived from THIS platform's pin artwork.
    ///
    /// MapPin is not just its 28pt disc: it draws that disc under `.shadow(radius: 6)` in the pin's
    /// own tint, so the pin occupies a ~40pt tinted footprint (radius 14 + 6). The rim has to clear
    /// ALL of it. That is not a nicety in the headline case - an ALPR detection tints its pin
    /// ACABTheme.flockTone, the exact tone of a confirmed ring, so a rim landing inside that glow
    /// is not merely tight, it is invisible. (The 36pt first cut did exactly that: its rim sat at
    /// radius 18, a full 2pt INSIDE the glow.)
    ///
    /// ALPRDot strokes with `strokeBorder`, which draws INSIDE the frame, so a 48pt ring puts the
    /// rim's inner edge at radius 24 - 2.2 = 21.8pt: a ~1.8pt band of clean map between the edge of
    /// the glow and the start of the rim, which at 2x/3x is 3.6-5.4 device pixels of gap. Readable,
    /// and still comfortably inside a 44pt touch target's neighbourhood on the map.
    ///
    /// The pin's ping ring (the 28pt circle scaled to 1.9 = ~53pt, animated, dropped above 40 pins
    /// and under Reduce Motion) sweeps PAST this rim and fades to zero opacity as it goes, so the
    /// static rim stays readable between pulses. The ping is deliberately NOT resized: it belongs
    /// to the detection, not to the reference layer.
    static let diameter: CGFloat = 48

    /// Which of `rings` has at least one of `pins` within `radiusMeters`, as an array parallel to
    /// `rings`. Cheap by construction and never per frame. It runs on the cull path, and on a
    /// throttled pin-set change (see schedulePeekStamp) so an arriving pin lights its ring: both inputs
    /// are already viewport-culled and capped (500 rings, a few hundred pins), and the pins are
    /// bucketed into `radiusMeters`-tall latitude bands so each ring only tests the three bands
    /// that could possibly hold a match. Equirectangular distance, same model as
    /// ALPRStore.nearest(to:) - well under 1% error at this range.
    static func matches(rings: [CLLocationCoordinate2D], pins: [CLLocationCoordinate2D]) -> [Bool] {
        var out = [Bool](repeating: false, count: rings.count)
        guard !rings.isEmpty, !pins.isEmpty else { return out }
        let bandDeg = radiusMeters / 111_320.0     // metres -> degrees of latitude (uniform)
        var bands: [Int: [CLLocationCoordinate2D]] = [:]
        for p in pins where usable(p) {
            bands[Int((p.latitude / bandDeg).rounded(.down)), default: []].append(p)
        }
        guard !bands.isEmpty else { return out }
        let r2 = radiusMeters * radiusMeters
        for (i, ring) in rings.enumerated() where usable(ring) {
            // Longitude degrees shrink with latitude. Take the scale from the RING: anything close
            // enough to match is within 25 m of it, where the difference is far below the noise.
            let lonScale = 111_320.0 * cos(ring.latitude * .pi / 180)
            let band = Int((ring.latitude / bandDeg).rounded(.down))
            search: for b in (band - 1)...(band + 1) {
                guard let candidates = bands[b] else { continue }
                for p in candidates {
                    let dLat = (ring.latitude - p.latitude) * 111_320.0
                    let dLon = (ring.longitude - p.longitude) * lonScale
                    if dLat * dLat + dLon * dLon <= r2 { out[i] = true; break search }
                }
            }
        }
        return out
    }

    /// A coordinate that can be bucketed without trapping. A garbage lat/lon reaches the map only
    /// through a corrupt cache or a bad fix, and it must degrade to "no match", never to a crash
    /// converting a NaN or a wild Double to Int.
    private static func usable(_ c: CLLocationCoordinate2D) -> Bool {
        c.latitude.isFinite && c.longitude.isFinite && abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }
}

/// Quiet hollow ring for a known/mapped ALPR camera (default-on reference layer). Deliberately
/// un-animated and low-contrast so a mapped location never reads as a live detection.
/// The dot itself stays a plain shape with NO @State and NO .popover of its own: up to 500 are
/// on screen and the Map content closure rebuilds ~3 Hz off every detection publish, so a per-dot
/// popover would mean up to 500 presentation hosts torn down and rebuilt 3x a second - a main-thread
/// stall on its own, independent of any camera loop. Tapping is handled ONE level up: the call site
/// wraps this in a Button that flips a single shared @State (showALPRInfo), and one bottom overlay
/// renders the DeFlock credit callout. (The provenance is also credited permanently in the legend.)
private struct ALPRDot: View {
    /// Confirmed rings stay the established red. Unverified ones go amber and DASHED: colour alone
    /// is not a distinction for a red/green-deficient viewer, and this is a map where the whole
    /// point of the second tier is that you can tell it apart. Same shape and weight otherwise, so
    /// neither tier reads as a live detection.
    var confirmed: Bool = true
    /// A live detection pin is standing on this camera: draw the ring wide enough that its rim
    /// clears the pin's whole visual footprint - the 28pt disc AND the tinted shadow around it -
    /// which would otherwise swallow the ring completely. Same tone, same stroke, same hollow
    /// shape; the diameter moves AND the resting wash is dropped - the fill below says why.
    /// See ALPRRingPeek.diameter for the derivation. OPEN DIVERGENCE: Android's rememberAlprMarker
    /// keeps its wash at the peek size, so its standoff band is tinted where this one is bare map.
    var peek: Bool = false
    private var tone: Color { confirmed ? ACABTheme.flockTone : ACABTheme.warn }
    private var size: CGFloat { peek ? ALPRRingPeek.diameter : 14 }
    var body: some View {
        Circle()
            // The resting 14pt dot needs its wash to read at all. The peek ring must NOT have one:
            // the pin already fills the middle, and a wash would tint the very band of clean map
            // that ALPRRingPeek.diameter exists to open up between the pin's glow and this rim.
            .fill(peek ? Color.clear : tone.opacity(confirmed ? 0.20 : 0.10))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(tone.opacity(0.95),
                                           style: StrokeStyle(lineWidth: 2.2,
                                                              dash: confirmed ? [] : [2.6, 2.2])))
            .accessibilityLabel(confirmed ? "Known ALPR camera, manufacturer attributed"
                                          : "Community ALPR candidate, attribution not structured")
        // Bolder 2026-07-29 (user: rings washed out on the map). Still a HOLLOW STATIC ring -
        // the "never reads as a live detection" rule holds because detections are filled +
        // animated, not because this was faint. Keep in lockstep with Android rememberAlprMarker
        // and the legend swatch below - INCLUDING the peek size, which is the only thing that
        // tells a live hit at a mapped camera apart from a live hit nobody has mapped.
    }
}

// MARK: - Clustering

/// A group of located detections that fall in the same grid cell at the current zoom.
/// A single-member cluster is drawn as a normal pin; multi-member as a count bubble.
struct Cluster: Identifiable {
    var id: String
    let coord: CLLocationCoordinate2D
    let members: [Detection]
    /// Age tier of the LONE member, when there is one. A multi-member bubble is not a pin and
    /// carries no age cue, so it stays .recent (full colour, no ping) whatever its rows hold.
    let age: MapPinRules.Age

    init(id: String = UUID().uuidString, coord: CLLocationCoordinate2D, members: [Detection],
         age: MapPinRules.Age = .recent) {
        self.id = id; self.coord = coord; self.members = members; self.age = age
    }

    /// The lone member when this isn't really a cluster (count == 1).
    var single: Detection? { members.count == 1 ? members.first : nil }

    /// The category tint for the whole bubble: a uniform clump keeps its category tint,
    /// a mixed clump goes neutral.
    var tint: Color {
        let cats = Set(members.map { $0.type.category })
        return cats.count == 1 ? (members.first?.type.tint ?? ACABTheme.accent) : ACABTheme.text
    }

    var shortTag: String { members.count == 1 ? (members.first?.type.shortTag ?? "") : "\(members.count)" }
}

/// A count bubble for a multi-member cluster, sized up a touch for bigger clumps.
private struct ClusterBubble: View {
    let cluster: Cluster
    private var n: Int { cluster.members.count }
    private var diameter: CGFloat {
        switch n {
        case ..<10:  return 34
        case ..<50:  return 40
        case ..<200: return 46
        default:     return 52
        }
    }
    var body: some View {
        ZStack {
            Circle().fill(cluster.tint.opacity(0.22)).frame(width: diameter + 10, height: diameter + 10)
            Circle().fill(ACABTheme.bg2).frame(width: diameter, height: diameter)
                .overlay(Circle().strokeBorder(cluster.tint, lineWidth: 2))
                .shadow(color: cluster.tint.opacity(0.5), radius: 5)
            Text("\(n)")
                .font(ACABTheme.display(n < 100 ? 15 : 13, weight: .bold))
                .foregroundStyle(ACABTheme.text).monospacedDigit()
        }
    }
}

/// Bottom sheet listing the detections inside a tapped cluster; pick one to open it.
private struct ClusterListSheet: View {
    let cluster: Cluster
    let onPick: (Detection) -> Void
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss

    /// Rows render in the order the CALLER built, never re-sorted here. An infra pin hands over
    /// `InfraPin.orderedMembers()` - priority first, then most recent - which is the same rule
    /// that chose the pin the finger landed on, so that row is the one on top; a count bubble
    /// hands over store order (the feed's newest-first). Re-sorting by lastSeen alone threw the
    /// priority half away, so a tap on a body-cam pin could open a sheet led by a fresher
    /// unknown row, and Android's twin sheet renders `PinGroup.members` untouched (MapScreen.kt),
    /// so the same tap read differently on the two phones. It was also a sort per body eval - two
    /// `lastSeenDate` lookups per comparison - inside a view that holds `ble` and therefore
    /// re-runs at the ~3 Hz publish, for a list that cannot change while the sheet is open.
    var body: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(cluster.members.count) here")
                                .font(ACABTheme.display(20, weight: .semibold)).foregroundStyle(ACABTheme.text)
                            Kicker("CLUSTERED AT THIS SPOT")
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                                .foregroundStyle(ACABTheme.dim)
                                .frame(width: 32, height: 32)
                                .background(ACABTheme.bg2, in: Circle())
                                .overlay(Circle().strokeBorder(ACABTheme.line, lineWidth: 1))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close cluster")
                    }
                    .padding(.bottom, 12)
                    VStack(spacing: 0) {
                        ForEach(Array(cluster.members.enumerated()), id: \.element.id) { i, d in
                            Button { onPick(d) } label: {
                                DetectionRow(detection: d, timeBasis: ble.timeBasis(for: d.id))
                            }
                                .buttonStyle(.plain)
                            if i < cluster.members.count - 1 { Divider().overlay(ACABTheme.line) }
                        }
                    }
                    .panel()
                }
                .padding(ACABTheme.pad)
            }
        }
        .preferredColorScheme(.dark)
    }
}
