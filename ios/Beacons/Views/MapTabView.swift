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
    @EnvironmentObject var alpr: ALPRStore        // known-ALPR reference layer (opt-in, OSM/DeFlock)
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
        let next = alpr.nodes(in: region, cap: 500).map {
            ALPRPoint(id: $0.id, coord: $0.coord, maker: $0.maker, tier: $0.tier)
        }
        // ALPRPoint is Equatable: an unchanged viewport costs zero @State writes / zero invalidations.
        if next != alprVisible { alprVisible = next }
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

    /// Hard cap on individually-pinned infra annotations, newest-first so a fresh sighting
    /// always draws. Android's MapScreen.kt caps all markers at 600; infra is the only
    /// unbounded set left here after the viewport cull (a city-wide zoom can legitimately
    /// hold the whole persisted store).
    private static let infraPinCap = 300
    /// Above this many visible pins the per-pin repeatForever ping animation is dropped:
    /// hundreds of independent Core Animation loops with shadows peg older devices on
    /// their own, cull or no cull.
    private static let animatedPinCap = 40

    /// A located detection with its map coordinate resolved once. `id` forwards the row's
    /// stored id (ForEach reads it per row; see the ALPRPoint note on computed-id cost).
    private struct LocatedPin: Identifiable {
        let detection: Detection
        let coord: CLLocationCoordinate2D
        var id: String { detection.id }
    }

    /// Everything one body eval needs from the store, computed in a SINGLE pass. located /
    /// totalLocated / count(cat) / the per-layer splits used to be independent computed
    /// properties, each an O(store) filter resolving mapCoord per row, and body read them
    /// ~17x per eval at the ~3 Hz publish cadence. Infra pins also get the viewport cull +
    /// cap the cluster path and ALPR layer already had.
    private struct MapSnapshot {
        let totalLocated: Int
        let counts: [String: Int]   // located per category, unfiltered (feeds the chips)
        let drones: [Detection]
        let infra: [LocatedPin]     // viewport-culled, capped newest-first
        let clusters: [Cluster]
        let trackerTrails: [Detection]   // trackers with >= 2 crumbs; trail geometry, NOT viewport-culled
        let pinsAnimated: Bool      // ping rings only under animatedPinCap
    }

    private func makeSnapshot() -> MapSnapshot {
        var total = 0
        var counts: [String: Int] = [:]
        var drones: [Detection] = []
        var infra: [LocatedPin] = []
        var trackerTrails: [Detection] = []
        var clusterPoints: [(d: Detection, c: CLLocationCoordinate2D)] = []
        for d in ble.detections {
            guard let c = mapCoord(for: d) else { continue }
            total += 1
            counts[d.type.category, default: 0] += 1
            guard filter == nil || d.type.category == filter else { continue }
            if d.type == .drone {
                // NOT viewport-culled: droneOverlay draws flight-path polylines and operator
                // tethers whose geometry can cross the viewport while the pin itself is
                // outside it, and drone counts are tiny.
                drones.append(d)
            } else if clusterable(d) {
                // A tracker that has walked with us gets a breadcrumb trail. NOT viewport-culled
                // (same reasoning as drones: the trail can cross the viewport while the pin is
                // outside it); the set is tiny since crumbs need real movement to accumulate.
                if d.type == .tracker, ble.crumbTrail(for: d.id).count >= 2 { trackerTrails.append(d) }
                if inViewport(c) { clusterPoints.append((d, c)) }
            } else if inViewport(c) {
                infra.append(LocatedPin(detection: d, coord: c))
            }
        }
        if infra.count > Self.infraPinCap {
            infra.sort {
                (ble.lastSeenDate(for: $0.id) ?? .distantPast) > (ble.lastSeenDate(for: $1.id) ?? .distantPast)
            }
            infra.removeSubrange(Self.infraPinCap...)
        }
        let clusters = buildClusters(clusterPoints)
        let pins = drones.count + infra.count + clusters.count
        return MapSnapshot(totalLocated: total, counts: counts, drones: drones, infra: infra,
                           clusters: clusters, trackerTrails: trackerTrails,
                           pinsAnimated: pins <= Self.animatedPinCap)
    }

    /// Inside the current viewport (plus a 20% margin so bubbles don't pop at the edges while panning).
    private func inViewport(_ c: CLLocationCoordinate2D) -> Bool {
        abs(c.latitude  - region.center.latitude)  <= region.span.latitudeDelta  * 0.6 &&
        abs(c.longitude - region.center.longitude) <= region.span.longitudeDelta * 0.6
    }

    /// Grid-clustered bubbles for ONLY the clusterable hits. Cell size scales with the
    /// current zoom (span / 14), so zooming in splits dense Desert-mode clumps apart and
    /// zooming out merges them.
    private func buildClusters(_ points: [(d: Detection, c: CLLocationCoordinate2D)]) -> [Cluster] {
        // Points arrive VIEWPORT-CULLED from the snapshot pass. Without that cull every located
        // point in the whole store becomes a bucket, so a deep Desert-mode log hands MapKit
        // thousands of Annotations rebuilt on every publish (~3 Hz) and pegs the main thread.
        // Same culling refreshALPRVisible already does for the ALPR dots.
        guard !points.isEmpty else { return [] }
        let cell = max(span.latitudeDelta, span.longitudeDelta) / 14
        guard cell > 0 else { return points.map { Cluster(coord: $0.c, members: [$0.d]) } }
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
                           members: members.map(\.d))
        }
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
                legend.padding(ACABTheme.pad).padding(.bottom, 6)
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
                            VStack(alignment: .leading, spacing: 2) {
                                // TIER FIRST, then maker. Testing maker first printed "known
                                // ALPR" for a hand-typed name, contradicting the second line
                                // directly beneath it. The maker is still shown when we have one:
                                // an unverified node's NAME is the doubtful part, not its presence.
                                Text(ALPRAttribution.headline(
                                    tier: tappedALPRTier, maker: tappedALPRMaker))
                                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.dim)
                                Text(ALPRAttribution.detail(
                                    tier: tappedALPRTier, maker: tappedALPRMaker))
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
            .onChange(of: ble.detections) { _, _ in
                guard ble.demoMode else { return }
                didFitToDetections = false
                fitToDetections()
            }
            .onReceive(NotificationCenter.default.publisher(for: MapFocus.notification)) { _ in
                selected = nil
                consumePendingFocus()
            }
        }
    }

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
            // Known ALPR cameras (opt-in reference layer), drawn UNDER the live pins so a
            // live hit always sits on top. Quiet hollow rings, not the animated detection pins.
            // Tap one for the shared DeFlock credit callout: a Button (cheap) flips ONE @State
            // that a single bottom overlay reads - never a per-dot popover (see ALPRDot).
            ForEach(alprVisible) { p in
                Annotation("", coordinate: p.coord) {
                    Button {
                        tappedALPRMaker = p.maker
                        tappedALPRTier = p.tier
                        withAnimation(.easeOut(duration: 0.15)) { showALPRInfo = true }
                    } label: { ALPRDot(confirmed: p.confirmed) }
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
            // Drones: their own pins, flight paths, and operator tethers.
            ForEach(snap.drones) { d in
                droneOverlay(d)
                if let coord = mapCoord(for: d) {
                    Annotation(showLabels ? d.type.shortTag : "", coordinate: coord) {
                        Button { selected = d } label: { MapPin(type: d.type, animated: snap.pinsAnimated) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(pinAccessibilityLabel(d))
                            .accessibilityHint("Opens detection details")
                    }
                }
                if let pilot = d.pilotCoordinate {
                    Annotation(showLabels ? "OP" : "", coordinate: pilot) { OperatorPin() }
                }
            }
            // Surveillance infrastructure: always an individual marker, never bubbled.
            ForEach(snap.infra) { p in
                Annotation(showLabels ? p.detection.type.shortTag : "", coordinate: p.coord) {
                    Button { selected = p.detection } label: {
                        MapPin(type: p.detection.type, animated: snap.pinsAnimated)
                    }
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityLabel(pinAccessibilityLabel(p.detection))
                    .accessibilityHint("Opens detection details")
                }
            }
            // Clusterable hits: grid-clustered bubbles. A lone member renders as a normal
            // pin; a clump renders one count bubble so a dense log stays legible.
            ForEach(snap.clusters) { c in
                Annotation(showLabels ? c.shortTag : "", coordinate: c.coord) {
                    if let only = c.single {
                        Button { selected = only } label: { MapPin(type: only.type, animated: snap.pinsAnimated) }
                            .buttonStyle(.plain)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityLabel(pinAccessibilityLabel(only))
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
        // its (opt-in) load. nodes.count is a cheap Equatable proxy for "the dataset changed".
        .onChange(of: alpr.enabled) { _, _ in refreshALPRVisible() }
        .onChange(of: alpr.showUnverified) { _, _ in refreshALPRVisible() }
        .onChange(of: alpr.nodes.count) { _, _ in refreshALPRVisible() }
        .onAppear { refreshALPRVisible() }
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
                return "Map. Your phone cannot add observer locations while Location is off. Drones that broadcast Remote ID coordinates can still appear."
            }
            return "Map. No located detections yet."
        }
        let shown = displayedLocatedCount(snap)
        let filtered = filter.map { " filtered to \($0.lowercased())" } ?? ""
        return "Map showing \(shown) located detection\(shown == 1 ? "" : "s")\(filtered)."
    }

    private func pinAccessibilityLabel(_ d: Detection) -> String {
        let type = spokenType(d.type)
        let name = d.displayName == d.type.label ? type : "\(d.displayName), \(type)"
        return "\(name). Signal strength \(d.rssi) decibels relative to one milliwatt."
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
        ALPRAttribution.accessibilityLabel(tier: point.tier, maker: point.maker)
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
    /// the filter row and looked like a seventh filter while actually opting into a dataset
    /// download - a category of action the row's other chips never take. Same capsule anatomy,
    /// but named for what it holds, and the toggle inside the popover says what enabling costs
    /// (an offline download) before anything is fetched. Fill tracks the layer being on so the
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

    /// The LAYERS popover: the known-ALPR toggle plus the one line explaining that turning it
    /// on downloads an offline dataset. The map-settings panel keeps its own toggle; both
    /// drive the same store, so they can never disagree.
    private var layersPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker("LAYERS")
            Toggle(isOn: Binding(get: { alpr.enabled },
                                 set: { alpr.setEnabled($0); if $0 { alpr.refresh() } })) {
                Text("known ALPR cameras").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.text)
            }
            .tint(ACABTheme.accent)
            Text("Draws mapped camera locations on the map. Turning it on downloads an offline dataset once; pins are mapped locations, not live detections.")
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
    private var legend: some View {
        Group {
            if legendOpen {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { legendExpanded = false }
                } label: { legendPanel }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse map legend")
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

    private var legendPanel: some View {
        VStack(alignment: .leading, spacing: 7) {
            legendRow(ACABTheme.flockTone, "ALPR")
            legendRow(ACABTheme.droneTone, "Drone")
            legendRow(ACABTheme.axonTone,  "Body cam")
            legendRow(ACABTheme.trackerTone, "Tracker")
            legendRow(ACABTheme.glassesTone, "Glasses")
            HStack(spacing: 7) {
                Image(systemName: "web.camera.fill")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(ACABTheme.netcamTone)
                    .frame(width: 8, height: 8)
                Text("Network camera").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
            }
            if alpr.enabled {
                // NOT a bare Divider: dividers are width-greedy and would balloon the
                // panel to the full overlay width. The hairline rides the row instead.
                HStack(spacing: 7) {
                    Circle().strokeBorder(ACABTheme.flockTone.opacity(0.95), lineWidth: 2)
                        .frame(width: 9, height: 9)
                    Text("Known ALPR").font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
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
                        Circle().strokeBorder(ACABTheme.warn.opacity(0.95),
                                              style: StrokeStyle(lineWidth: 2, dash: [2, 1.8]))
                            .frame(width: 9, height: 9)
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
            Circle().fill(c).frame(width: 8, height: 8).shadow(color: c.opacity(0.6), radius: 3)
            Text(t).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
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
                Text("Location is off, so beacons can't add your phone's observer position. Drones that broadcast Remote ID coordinates can still appear on the map.")
                    .font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.dim)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
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

/// Animated category pin: filled dot with a glyph and a slow ping ring. `animated: false`
/// (set once per body pass when the visible pin count crosses animatedPinCap) drops the
/// repeatForever ping entirely, so hundreds of independent Core Animation loops never
/// coexist on a dense map.
private struct MapPin: View {
    let type: DeviceType
    var animated = true
    @State private var ping = false
    // Reduce Motion drops the looping ping ring entirely, same as the dense-map cap does.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            if animated && !reduceMotion {
                Circle().stroke(type.tint, lineWidth: 2).frame(width: 28, height: 28)
                    .scaleEffect(ping ? 1.9 : 0.9).opacity(ping ? 0 : 0.7)
            }
            Circle().fill(type.tint).frame(width: 28, height: 28)
                .overlay(Circle().strokeBorder(ACABTheme.bg, lineWidth: 2.5))
                .shadow(color: type.tint.opacity(0.7), radius: 6)
            Image(systemName: type.symbol).font(.system(size: 12, weight: .bold))
                .foregroundStyle(ACABTheme.bg)
        }
        .onAppear(perform: updateAnimation)
        .onChange(of: reduceMotion) { _, _ in updateAnimation() }
        .onChange(of: animated) { _, _ in updateAnimation() }
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

/// A known-ALPR camera point (opt-in reference layer). ALP4 identity is stable OSM type + ID, so
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
    }
}

/// Quiet hollow ring for a known/mapped ALPR camera (opt-in reference layer). Deliberately
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
    private var tone: Color { confirmed ? ACABTheme.flockTone : ACABTheme.warn }
    var body: some View {
        Circle()
            .fill(tone.opacity(confirmed ? 0.20 : 0.10))
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(tone.opacity(0.95),
                                           style: StrokeStyle(lineWidth: 2.2,
                                                              dash: confirmed ? [] : [2.6, 2.2])))
            .accessibilityLabel(confirmed ? "Known ALPR camera, manufacturer attributed"
                                          : "Community ALPR candidate, attribution not structured")
        // Bolder 2026-07-29 (user: rings washed out on the map). Still a HOLLOW STATIC ring -
        // the "never reads as a live detection" rule holds because detections are filled +
        // animated, not because this was faint. Keep in lockstep with Android rememberAlprMarker
        // and the legend swatch below.
    }
}

// MARK: - Clustering

/// A group of located detections that fall in the same grid cell at the current zoom.
/// A single-member cluster is drawn as a normal pin; multi-member as a count bubble.
struct Cluster: Identifiable {
    var id: String
    let coord: CLLocationCoordinate2D
    let members: [Detection]

    init(id: String = UUID().uuidString, coord: CLLocationCoordinate2D, members: [Detection]) {
        self.id = id; self.coord = coord; self.members = members
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

    private var members: [Detection] {
        cluster.members.sorted {
            (ble.lastSeenDate(for: $0.id) ?? .distantPast) > (ble.lastSeenDate(for: $1.id) ?? .distantPast)
        }
    }

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
                        ForEach(Array(members.enumerated()), id: \.element.id) { i, d in
                            Button { onPick(d) } label: {
                                DetectionRow(detection: d, timeBasis: ble.timeBasis(for: d.id))
                            }
                                .buttonStyle(.plain)
                            if i < members.count - 1 { Divider().overlay(ACABTheme.line) }
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
