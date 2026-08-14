import Foundation
import MapKit
import Combine
import CryptoKit

/// The "known ALPR cameras" map overlay , community-mapped license-plate-reader
/// locations from OpenStreetMap (the registry the DeFlock project maintains), shown as a
/// quiet reference layer under the live detections.
///
/// PRIVACY: the phone downloads ONE static file from soyboi.tech and renders it locally.
/// It never queries Overpass and never puts its viewport into this dataset request; the fetch
/// happens only after the user opts in. The base map provider still receives ordinary map tile
/// requests, as the privacy disclosure states.
///
/// Wire format is versioned ALP1 through ALP4. ALP4 retains the compact ALP3 coordinate, maker,
/// and attribution blocks, then adds stable OSM identity and freshness metadata per row. Older
/// caches remain readable.
/// Manifest (`alpr-latest.json`): { updated, count, data:{ url, sha256, size } }. We re-download
/// only when date + SHA-256 + wire format match; parsed points are cached for offline redraw.
@MainActor
final class ALPRStore: ObservableObject {
    static let shared = ALPRStore()

    /// Loaded camera coordinates (empty until the layer is enabled + a dataset is present).
    @Published private(set) var nodes: [CLLocationCoordinate2D] = []
    /// Canonical maker name per node ("" = unknown), parallel to `nodes`. Kept as a plain array,
    /// not @Published: it only ever changes in the same assignment as `nodes`, and nothing observes
    /// it directly - the map/detail read it through nodes(in:) and nearest(to:).
    private var nodeMakers: [String] = []
    /// Confidence per node, parallel to `nodes`: true when the mapper picked the manufacturer from
    /// an editor preset (it carries a wikidata id), false when it was typed freehand or left blank.
    /// The false set is small (7-14%) and is where misidentified pins concentrate, so the map draws
    /// it in a different colour and says so. Same lifecycle as nodeMakers: not @Published, only
    /// ever assigned alongside `nodes`.
    private var nodeConfirmed: [Bool] = []
    /// Stable provenance parallel to nodes. Legacy ALP1-3 caches contain nil provenance.
    private var nodeMetadata: [NodeMetadata] = []
    /// Wire format of the loaded cache. This prevents an ALP3 cache from satisfying an ALP4
    /// manifest that happens to carry the same calendar-date version during a channel rollout.
    private var loadedFormat = ""
    /// Hash of the bytes actually loaded from disk or accepted from the network. The manifest's
    /// date is only human-facing metadata: more than one valid generation can be built in a day.
    private var loadedSHA256 = ""
    /// Dataset date string ("YYYY-MM-DD") for the attribution line, or nil.
    @Published private(set) var updated: String?
    /// True while ANY fetch is in flight, including the sub-second manifest freshness check.
    /// Drives the toggle's spinner, and suppresses the "couldn't load camera data" hint so a
    /// first load never flashes a false error before the points arrive.
    @Published private(set) var loading = false
    /// True only while the dataset BINARY is downloading/parsing. Narrower than `loading` on
    /// purpose: enabling an already-cached layer still runs a manifest check, and hanging the
    /// legend's auto-expand off `loading` popped it open and shut across that round-trip with
    /// nothing to show. Auto-expand is worth it for a real download, never for a freshness ping.
    @Published private(set) var downloading = false
    /// User opt-in. Persisted; flipping it on triggers the first download.
    @Published private(set) var enabled: Bool
    /// When the last manifest freshness check COMPLETED (success or already-up-to-date; a dead
    /// network stamps nothing). Persisted so the map settings caption survives relaunch.
    @Published private(set) var lastChecked: Date?
    /// How the most recent fetch ended, for the settings row's inline outcome. nil until a
    /// fetch has run this session.
    @Published private(set) var lastOutcome: RefreshOutcome?

    enum RefreshOutcome: Equatable {
        case updated(count: Int)    // new dataset downloaded + parsed
        case upToDate               // manifest checked, cached version already current
        case failed                 // network/decode/integrity failure; cache left in place
        /// The manifest 404s. NOT a network fault, and worth its own case because it means
        /// something specific and temporary: this build polls its own manifest URL (see
        /// manifestURL), so between an app release and the dataset being published there is a
        /// window where the file legitimately does not exist yet. Telling the user to "check your
        /// connection" in that window sends them to debug a working network.
        case notPublished
    }

    struct NodeMetadata: Equatable, Sendable {
        /// 0 = OSM node, 1 = way, 2 = relation. Legacy caches have no stable identity.
        let osmType: UInt8?
        let osmID: UInt64?
        /// Unix seconds, or nil when the upstream source did not provide a timestamp.
        let sourceEpoch: UInt32?
        /// Hundredths of a degree in 0...35999, or nil.
        let directionCdeg: UInt16?
        /// Days since 1970-01-01, or nil when no survey/check date was available.
        let checkDateDay: UInt32?
        /// 0 = canonical ALPR without a structured maker, 1 = structured maker,
        /// 2 = legacy alias candidate.
        let attributionTier: UInt8
    }

    struct ParsedDataset: @unchecked Sendable {
        let wireFormat: String
        let coords: [CLLocationCoordinate2D]
        let makers: [String]
        let confirmed: [Bool]
        let metadata: [NodeMetadata]
        let rawCount: Int
    }

    /// The V4 manifest is separate from the immutable V3 channel used by installed builds.
    /// alpr-latest.json still serves ALP2 and always will, because an already-installed app
    /// exact-length-checks the binary and REJECTS an ALP3 file outright rather than ignoring the
    /// extra tail , and its reject path returns before it stamps the version key, so it would
    /// re-download and re-fail forever with a map frozen at the last good dataset. Pointing new
    /// builds at their own manifest means the rollout cannot break the installed base, whatever
    /// order the app stores approve things in. Keep BOTH in lockstep with the generator's
    /// dual-publish block (soyboi.tech/tools/build_alpr_dataset.py).
    private struct ManifestEndpoint {
        let url: URL
        let expectedFormat: String
        let allowsMissingDeclaredFormat: Bool
    }

    private let manifestEndpoints = [
        ManifestEndpoint(
            url: URL(string: "https://soyboi.tech/data/alpr-v4-latest.json")!,
            expectedFormat: "ALP4",
            allowsMissingDeclaredFormat: false
        ),
        ManifestEndpoint(
            url: URL(string: "https://soyboi.tech/data/alpr-v3-latest.json")!,
            expectedFormat: "ALP3",
            allowsMissingDeclaredFormat: true
        ),
    ]
    /// Show the community-mapped nodes nobody could name a manufacturer for. DEFAULT OFF.
    ///
    /// These are the pins that get the APP blamed. A node with no manufacturer recorded is
    /// disproportionately a solar panel on a pole that someone marked in passing, and when a user
    /// drives to one and finds nothing there, they conclude the detector is broken , not that an
    /// OSM contributor guessed. That happened to a reporter evaluating the product.
    /// 8.1% of nodes across five metros, and 22% in Chicago, so this is not a rounding error.
    ///
    /// They are still DOWNLOADED and still counted in the manifest. Hiding them is a display
    /// decision; deleting them would make the data-quality problem invisible rather than absent.
    @Published private(set) var showUnverified: Bool
    private let showUnverifiedKey = "acab.alpr.showUnverified"
    /// How many of `nodes` are tier-0. Stored, not computed: the settings caption reads it on every
    /// redraw and the array is six figures long. Only ever assigned alongside `nodeConfirmed`.
    @Published private(set) var unverifiedCount = 0

    private let enabledKey = "acab.alpr.enabled"
    private let versionKey = "acab.alpr.version"      // last-downloaded dataset `updated`
    private let shaKey = "acab.alpr.sha256"           // exact bytes behind the version caption
    private let lastCheckedKey = "acab.alpr.lastChecked"   // epoch seconds of the last completed manifest check
    private var inFlight = false
    private var restartWanted = false

    /// Bumped on every enable/disable. fetch() snapshots it and abandons publication if it changed.
    private var enableGen = 0

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("alpr.bin")
    }

    nonisolated static let allowedDatasetHost = "soyboi.tech"
    nonisolated static let maxManifestBytes = 64 * 1024
    nonisolated static let maxDatasetBytes = 8 * 1024 * 1024

    private init() {
        enabled = UserDefaults.standard.bool(forKey: enabledKey)
        showUnverified = UserDefaults.standard.bool(forKey: showUnverifiedKey)   // default false
        let t = UserDefaults.standard.double(forKey: lastCheckedKey)
        lastChecked = t > 0 ? Date(timeIntervalSince1970: t) : nil
        if enabled {
            Task {
                await loadFromDisk()
                refresh()
            }
        }
    }

    // MARK: opt-in

    /// Turn the layer on (loads cache + refreshes, downloading on first enable) or off
    /// (clears the in-memory points; the cache is kept so re-enabling is instant).
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        UserDefaults.standard.set(on, forKey: enabledKey)
        // Retire any fetch already in the air. Clearing the arrays below does NOT stop a download
        // that is mid-flight, and its publish step would repopulate them seconds after the user
        // switched the layer off - the toggle would visibly undo itself. See fetch()'s gen checks.
        enableGen &+= 1
        if on {
            Task {
                await loadFromDisk()
                refresh()
            }
        } else {
            nodes = []
            nodeMakers = []
            nodeConfirmed = []
            nodeMetadata = []
            loadedFormat = ""
            loadedSHA256 = ""
            unverifiedCount = 0
            loading = false
            downloading = false
            restartWanted = false
        }
    }

    /// Toggle the unverified tier on the map. No refetch , the nodes are already loaded, this only
    /// changes what `nodes(in:)` hands back, so the map redraws immediately.
    func setShowUnverified(_ on: Bool) {
        guard on != showUnverified else { return }
        showUnverified = on
        UserDefaults.standard.set(on, forKey: showUnverifiedKey)
    }

    // MARK: viewport query

    /// The camera points inside `region`, capped so a zoomed-out view never tries to draw the
    /// whole set. Returns [] past the cap (caller shows a "zoom in" hint instead).
    func nodes(in region: MKCoordinateRegion, cap: Int = 500) -> [(id: String, coord: CLLocationCoordinate2D, maker: String, tier: UInt8, confirmed: Bool)] {
        guard !nodes.isEmpty else { return [] }
        let minLat = region.center.latitude - region.span.latitudeDelta / 2
        let maxLat = region.center.latitude + region.span.latitudeDelta / 2
        let minLon = region.center.longitude - region.span.longitudeDelta / 2
        let maxLon = region.center.longitude + region.span.longitudeDelta / 2
        var out: [(id: String, coord: CLLocationCoordinate2D, maker: String, tier: UInt8, confirmed: Bool)] = []
        out.reserveCapacity(min(cap, 64))
        for i in nodes.indices {
            let c = nodes[i]
            if c.latitude >= minLat && c.latitude <= maxLat && c.longitude >= minLon && c.longitude <= maxLon {
                let ok = i < nodeConfirmed.count ? nodeConfirmed[i] : true
                if !ok && !showUnverified { continue }   // hidden by default, see showUnverified
                let meta = i < nodeMetadata.count ? nodeMetadata[i] : nil
                let tier = meta?.attributionTier ?? (ok ? 1 : 0)
                let id = Self.stableNodeID(index: i, coordinate: c, metadata: meta)
                out.append((id, c, i < nodeMakers.count ? nodeMakers[i] : "", tier, ok))
                if out.count > cap { return [] }     // too many in view: signal "zoom in"
            }
        }
        return out
    }

    /// Nearest mapped camera to `coord`, for the detection detail's "matches a mapped camera" line.
    /// A ~2km bounding-box prefilter keeps this cheap over the full ~127k set (a real match is <200m,
    /// so nothing useful is ever outside the box); returns nil when the box is empty. Equirectangular
    /// distance is accurate to well under 1% at these ranges. On-device only - no query leaves the phone.
    func nearest(to coord: CLLocationCoordinate2D) -> (meters: Double, maker: String, tier: UInt8, confirmed: Bool)? {
        guard !nodes.isEmpty else { return nil }
        let box = 0.02                                   // ~2.2 km half-window
        let cosLat = cos(coord.latitude * .pi / 180)
        var bestM = Double.greatestFiniteMagnitude
        var bestMaker = ""
        var bestConfirmed = true
        var bestTier: UInt8 = 1
        for i in nodes.indices {
            let c = nodes[i]
            if abs(c.latitude - coord.latitude) > box || abs(c.longitude - coord.longitude) > box { continue }
            // Never corroborate a detection against a node the user cannot see on the map. Vouching
            // for a hit using evidence we have decided is untrustworthy is worse than staying quiet.
            if !showUnverified, i < nodeConfirmed.count, !nodeConfirmed[i] { continue }
            let dLat = (c.latitude - coord.latitude) * 111_320
            let dLon = (c.longitude - coord.longitude) * 111_320 * cosLat
            let m = (dLat * dLat + dLon * dLon).squareRoot()
            if m < bestM {
                bestM = m
                bestMaker = i < nodeMakers.count ? nodeMakers[i] : ""
                bestConfirmed = i < nodeConfirmed.count ? nodeConfirmed[i] : true
                bestTier = i < nodeMetadata.count ? nodeMetadata[i].attributionTier
                    : (bestConfirmed ? 1 : 0)
            }
        }
        return bestM.isFinite ? (bestM, bestMaker, bestTier, bestConfirmed) : nil
    }

    // MARK: fetch + cache

    /// Freshen the dataset if the layer is on. Non-blocking, failure-tolerant: a bad network or
    /// hash mismatch leaves the cached points in place and never throws into the UI.
    func refresh() {
        guard enabled else { return }
        if inFlight {
            restartWanted = true
            return
        }
        inFlight = true
        Task {
            await fetch()
            inFlight = false
            if restartWanted, enabled {
                restartWanted = false
                refresh()
            }
        }
    }

    /// Awaitable variant for the map settings panel's "check for updates" row: same
    /// single-flight fetch, but the caller can await completion and read `lastOutcome`
    /// to render the result inline. No-ops (like `refresh`) if a fetch is already running.
    func refreshNow() async {
        guard enabled else { return }
        if inFlight {
            restartWanted = true
            return
        }
        inFlight = true
        await fetch()
        inFlight = false
        if restartWanted, enabled {
            restartWanted = false
            refresh()
        }
    }

    private func fetch() async {
        let gen = enableGen
        loading = true
        var outcome: RefreshOutcome = .failed
        defer {
            if gen == enableGen, enabled {
                loading = false
                lastOutcome = outcome
            }
        }
        // Every await below is a window in which the user can switch the layer off. Snapshot the
        // enable generation after each one so a stale fetch cannot publish into a disabled layer.
        // 1) manifest. V4 is preferred; a 404 alone falls back to the installed V3 channel.
        var manifest: ALPRManifest?
        var selectedEndpoint: ManifestEndpoint?
        var allNotPublished = true
        for endpoint in manifestEndpoints {
            let manifestURL = endpoint.url
            guard Self.isAllowedDatasetURL(manifestURL) else { return }
            var req = URLRequest(url: manifestURL)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.timeoutInterval = 15
            guard let payload = try? await Self.boundedData(for: req, limit: Self.maxManifestBytes) else {
                allNotPublished = false
                break
            }
            if payload.response.statusCode == 404 { continue }
            allNotPublished = false
            guard (200..<300).contains(payload.response.statusCode),
                  let decoded = try? JSONDecoder().decode(ALPRManifest.self, from: payload.data),
                  decoded.schema == 1, let d = decoded.data,
                  d.size > 0, d.size <= Self.maxDatasetBytes,
                  Self.isSHA256(d.sha256),
                  let url = URL(string: d.url), Self.isAllowedDatasetURL(url),
                  Self.channelFormatMatches(
                      declaredFormat: d.format,
                      expectedFormat: endpoint.expectedFormat,
                      allowsMissingDeclaredFormat: endpoint.allowsMissingDeclaredFormat,
                      loadedFormat: nil
                  ) else { return }
            manifest = decoded
            selectedEndpoint = endpoint
            break
        }
        guard let manifest, let selectedEndpoint,
              let d = manifest.data, let url = URL(string: d.url) else {
            if allNotPublished { outcome = .notPublished }
            return
        }
        // Manifest check completed (whatever the version says): stamp it for the
        // settings caption's "checked X ago". Failures above deliberately stamp nothing.
        lastChecked = Date()
        UserDefaults.standard.set(lastChecked!.timeIntervalSince1970, forKey: lastCheckedKey)
        // Already have this version cached + loaded? Nothing to do.
        if !nodes.isEmpty,
           Self.cacheIdentityMatches(
               manifestUpdated: manifest.updated,
               manifestSHA: d.sha256,
               manifestFormat: selectedEndpoint.expectedFormat,
               storedUpdated: UserDefaults.standard.string(forKey: versionKey),
               storedSHA: UserDefaults.standard.string(forKey: shaKey),
               loadedSHA: loadedSHA256,
               loadedFormat: loadedFormat
           ) {
            updated = manifest.updated
            outcome = .upToDate
            return
        }
        // Layer switched off while the manifest was in the air: stop before the expensive part.
        guard gen == enableGen, enabled else { return }
        // 2) binary. Past this point we are committed to a real download, so the legend may
        // auto-open to surface the data credit. Everything above was a freshness check.
        downloading = true
        defer { downloading = false }
        var breq = URLRequest(url: url)
        breq.timeoutInterval = 30
        guard let payload = try? await Self.boundedData(for: breq, limit: Self.maxDatasetBytes),
              (200..<300).contains(payload.response.statusCode) else { return }
        let bin = payload.data
        // 3) integrity: size + sha256 must match the manifest, or we discard it
        guard bin.count == d.size,
              Self.sha256(bin) == d.sha256.lowercased() else { return }
        // 4) parse away from the UI actor, then durably cache and verify before committing the
        // version or publishing. A failed cache write leaves the old version authoritative.
        guard let parsed = await Task.detached(priority: .utility, operation: {
            Self.parseDetailed(bin)
        }).value else { return }
        guard Self.channelFormatMatches(
            declaredFormat: d.format,
            expectedFormat: selectedEndpoint.expectedFormat,
            allowsMissingDeclaredFormat: selectedEndpoint.allowsMissingDeclaredFormat,
            loadedFormat: parsed.wireFormat
        ) else { return }
        if let expected = manifest.count, expected != parsed.rawCount { return }
        guard gen == enableGen, enabled else { return }
        let cacheURL = cacheURL
        let expectedHash = d.sha256.lowercased()
        let cached = await Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try bin.write(to: cacheURL, options: [.atomic, .completeFileProtection])
                let check = try Data(contentsOf: cacheURL, options: .mappedIfSafe)
                return check.count == bin.count && Self.sha256(check) == expectedHash
            } catch {
                return false
            }
        }.value
        guard cached, gen == enableGen, enabled else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        nodeConfirmed = parsed.confirmed
        nodeMetadata = parsed.metadata
        loadedFormat = parsed.wireFormat
        loadedSHA256 = expectedHash
        unverifiedCount = parsed.confirmed.reduce(0) { $0 + ($1 ? 0 : 1) }
        updated = manifest.updated
        outcome = .updated(count: parsed.coords.count)
        UserDefaults.standard.set(manifest.updated, forKey: versionKey)
        UserDefaults.standard.set(expectedHash, forKey: shaKey)
    }

    private func loadFromDisk() async {
        let url = cacheURL
        let task = Task.detached(priority: .utility, operation: { () -> (ParsedDataset, String)? in
            guard let bin = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            guard let parsed = Self.parseDetailed(bin) else { return nil }
            return (parsed, Self.sha256(bin))
        })
        guard let (parsed, hash) = await task.value, enabled else { return }
        nodes = parsed.coords
        nodeMakers = parsed.makers
        nodeConfirmed = parsed.confirmed
        nodeMetadata = parsed.metadata
        loadedFormat = parsed.wireFormat
        loadedSHA256 = hash
        unverifiedCount = parsed.confirmed.reduce(0) { $0 + ($1 ? 0 : 1) }
        // The cache IS the version `versionKey` recorded, so a cold start can caption its
        // dataset date before (or without) the next successful manifest round-trip.
        if updated == nil { updated = UserDefaults.standard.string(forKey: versionKey) }
    }

    /// Parse the "ALP3" binary into coordinates + parallel maker and confidence arrays. Also
    /// accepts a legacy "ALP2" (coords + makers) and "ALP1" (coords only), so a cache written by an
    /// older build still loads. Bounds-checked throughout; returns nil on any malformation (a bad
    /// length, a table that runs past the buffer). A maker index past the table is NOT a rejection:
    /// it resolves to "" for that one node, same as Android, because a single unreadable label is a
    /// display fault and blanking a whole city's map over it is not. Out-of-range coords are
    /// dropped WITH their maker and tier, so all three arrays stay in lockstep.
    ///
    /// A pre-ALP3 file defaults every node to CONFIRMED, never unverified. The tier is an
    /// accusation ("nobody picked this manufacturer from a preset, so it may be misidentified"),
    /// and a cache predating the field carries no evidence either way. Defaulting the other way
    /// would paint a whole stale map amber purely because the file is old.
    ///
    /// Internal rather than private so BeaconsTests can drive it directly (@testable raises
    /// internal to public, it does not reach private). This is the one function in the app with a
    /// history of shipping a schema mismatch to BOTH platforms at once, so it is worth the keyword.
    nonisolated static func parse(_ data: Data) -> (coords: [CLLocationCoordinate2D], makers: [String], confirmed: [Bool])? {
        guard let parsed = parseDetailed(data) else { return nil }
        return (parsed.coords, parsed.makers, parsed.confirmed)
    }

    nonisolated static func parseDetailed(_ data: Data) -> ParsedDataset? {
        let isV4 = data.count >= 4 && data.prefix(4).elementsEqual("ALP4".utf8)
        let isV3 = data.count >= 4 && data.prefix(4).elementsEqual("ALP3".utf8)
        let isV2 = data.count >= 4 && data.prefix(4).elementsEqual("ALP2".utf8)
        let isV1 = data.count >= 4 && data.prefix(4).elementsEqual("ALP1".utf8)
        let hasMakers = isV2 || isV3 || isV4
        guard data.count >= 12, isV1 || hasMakers else { return nil }
        let base = data.startIndex
        func u8(_ off: Int) -> Int { Int(data[base + off]) }
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[base + off]) | (UInt32(data[base + off + 1]) << 8)
                | (UInt32(data[base + off + 2]) << 16) | (UInt32(data[base + off + 3]) << 24)
        }
        func i32(_ off: Int) -> Int32 { Int32(bitPattern: u32(off)) }
        func u16(_ off: Int) -> UInt16 {
            UInt16(data[base + off]) | (UInt16(data[base + off + 1]) << 8)
        }
        func u64(_ off: Int) -> UInt64 {
            var value: UInt64 = 0
            for shift in 0..<8 { value |= UInt64(data[base + off + shift]) << UInt64(shift * 8) }
            return value
        }
        let count = Int(u32(8))
        guard count < 5_000_000 else { return nil }

        var table: [String] = [""]
        var off = 12
        if hasMakers {
            guard data.count >= 13 else { return nil }
            let nMakers = u8(12); off = 13
            table = []
            for _ in 0..<nMakers {
                guard off < data.count else { return nil }
                let len = u8(off); off += 1
                let (end, overflow) = off.addingReportingOverflow(len)
                guard !overflow, end <= data.count else { return nil }
                table.append(String(decoding: data[(base + off)..<(base + off + len)], as: UTF8.self))
                off += len
            }
            guard !table.isEmpty else { return nil }               // index 0 must exist
        }
        // coords, then (v2/v3) the parallel maker-index array, then (v3 only) the parallel tier array
        let (coordsBytes, coordsOverflow) = count.multipliedReportingOverflow(by: 8)
        guard !coordsOverflow else { return nil }
        let idxBytes = hasMakers ? count : 0
        let tierBytes = (isV3 || isV4) ? count : 0
        let (metadataBytes, metadataOverflow) = count.multipliedReportingOverflow(by: isV4 ? 19 : 0)
        guard !metadataOverflow else { return nil }
        var expected = off
        for size in [coordsBytes, idxBytes, tierBytes, metadataBytes] {
            let (next, overflow) = expected.addingReportingOverflow(size)
            guard !overflow else { return nil }
            expected = next
        }
        guard data.count == expected else { return nil }
        let idxBase = off + coordsBytes
        let tierBase = idxBase + idxBytes
        let metadataBase = tierBase + tierBytes

        var coords: [CLLocationCoordinate2D] = []; coords.reserveCapacity(count)
        var makers: [String] = []; makers.reserveCapacity(count)
        var confirmed: [Bool] = []; confirmed.reserveCapacity(count)
        var metadata: [NodeMetadata] = []; metadata.reserveCapacity(count)
        for k in 0..<count {
            let tier = (isV3 || isV4) ? UInt8(u8(tierBase + k)) : 1
            if isV4, tier > 2 { return nil }
            let rowMetadata: NodeMetadata
            if isV4 {
                let m = metadataBase + k * 19
                let osmType = UInt8(u8(m))
                let osmID = u64(m + 1)
                let sourceEpoch = u32(m + 9)
                let direction = u16(m + 13)
                let checkDay = u32(m + 15)
                guard osmType <= 2, osmID > 0,
                      direction == UInt16.max || direction <= 35_999 else { return nil }
                rowMetadata = NodeMetadata(
                    osmType: osmType,
                    osmID: osmID,
                    sourceEpoch: sourceEpoch == 0 ? nil : sourceEpoch,
                    directionCdeg: direction == UInt16.max ? nil : direction,
                    checkDateDay: checkDay == 0 ? nil : checkDay,
                    attributionTier: tier
                )
            } else {
                rowMetadata = NodeMetadata(
                    osmType: nil,
                    osmID: nil,
                    sourceEpoch: nil,
                    directionCdeg: nil,
                    checkDateDay: nil,
                    attributionTier: tier
                )
            }
            let o = off + k * 8
            let c = CLLocationCoordinate2D(latitude: Double(i32(o)) / 1e7, longitude: Double(i32(o + 4)) / 1e7)
            guard CLLocationCoordinate2DIsValid(c) else { continue }  // drop corrupt coords, and their maker + tier
            coords.append(c)
            if hasMakers {
                let mi = u8(idxBase + k)
                makers.append(mi < table.count ? table[mi] : "")
            } else {
                makers.append("")
            }
            confirmed.append((isV3 || isV4) ? tier == 1 : true)     // pre-v3: no evidence, so no accusation
            metadata.append(rowMetadata)
        }
        let wireFormat = isV4 ? "ALP4" : (isV3 ? "ALP3" : (isV2 ? "ALP2" : "ALP1"))
        return ParsedDataset(wireFormat: wireFormat, coords: coords, makers: makers, confirmed: confirmed,
                             metadata: metadata, rawCount: count)
    }

    /// A matching date alone is insufficient during a wire-format channel migration. Old
    /// manifests did not publish `format`, so absence preserves their historical date-only rule.
    nonisolated static func cacheFormatMatches(manifestFormat: String?, loadedFormat: String) -> Bool {
        guard let requested = manifestFormat?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else { return true }
        return requested.uppercased() == loadedFormat.uppercased()
    }

    /// A manifest channel owns one exact wire format. The legacy V3 channel historically omitted
    /// `data.format`, so it may omit that declaration, but its downloaded bytes must still parse as
    /// ALP3. The V4 channel must explicitly declare and parse as ALP4.
    nonisolated static func channelFormatMatches(
        declaredFormat: String?,
        expectedFormat: String,
        allowsMissingDeclaredFormat: Bool,
        loadedFormat: String?
    ) -> Bool {
        let expected = expectedFormat.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !expected.isEmpty else { return false }
        let declared = declaredFormat?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let declared, !declared.isEmpty {
            guard declared.uppercased() == expected else { return false }
        } else if !allowsMissingDeclaredFormat {
            return false
        }
        if let loadedFormat {
            guard loadedFormat.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == expected else {
                return false
            }
        }
        return true
    }

    nonisolated static func cacheIdentityMatches(
        manifestUpdated: String,
        manifestSHA: String,
        manifestFormat: String?,
        storedUpdated: String?,
        storedSHA: String?,
        loadedSHA: String,
        loadedFormat: String
    ) -> Bool {
        let expectedSHA = manifestSHA.lowercased()
        return storedUpdated == manifestUpdated
            && storedSHA?.lowercased() == expectedSHA
            && loadedSHA.lowercased() == expectedSHA
            && cacheFormatMatches(manifestFormat: manifestFormat, loadedFormat: loadedFormat)
    }

    nonisolated static func stableNodeID(
        index: Int,
        coordinate: CLLocationCoordinate2D,
        metadata: NodeMetadata?
    ) -> String {
        if let type = metadata?.osmType, let id = metadata?.osmID {
            return "osm:\(type):\(id)"
        }
        return "legacy:\(index):\(coordinate.latitude),\(coordinate.longitude)"
    }

    nonisolated static func isAllowedDatasetURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == allowedDatasetHost,
              url.user == nil, url.password == nil else { return false }
        return url.port == nil || url.port == 443
    }

    nonisolated static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }

    nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func boundedData(
        for request: URLRequest,
        limit: Int
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard isAllowedDatasetURL(request.url) else { throw ALPRFetchError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: ALPRRejectRedirectsDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              isAllowedDatasetURL(http.url) else { throw ALPRFetchError.invalidResponse }
        if http.expectedContentLength > Int64(limit) { throw ALPRFetchError.tooLarge }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(limit, Int(http.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < limit else { throw ALPRFetchError.tooLarge }
            data.append(byte)
        }
        return (data, http)
    }
}

private enum ALPRFetchError: Error {
    case invalidResponse
    case tooLarge
}

/// The dataset contract permits direct HTTPS requests to soyboi.tech only. Reject redirects at
/// the URL loading boundary so an intermediate host is never contacted before the final URL is
/// validated.
private final class ALPRRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// User-facing meaning of the ALP3/ALP4 attribution byte. Tier 1 is structured maker
/// attribution, tier 0 is the canonical ALPR tag without one, and tier 2 is an alternate or
/// legacy ALPR tag. Keeping this in one pure helper prevents map, callout, and VoiceOver copy
/// from turning a tier-2 row with a maker into the contradictory "no manufacturer recorded".
enum ALPRAttribution {
    static func headline(tier: UInt8, maker: String) -> String {
        switch tier {
        case 1:
            return maker.isEmpty ? "mapped ALPR · sourced from DeFlock"
                : "\(maker) · mapped ALPR, via DeFlock"
        case 2:
            return maker.isEmpty ? "ALPR candidate · legacy OSM tag"
                : "\(maker)? · legacy-tag ALPR candidate"
        default:
            return maker.isEmpty ? "mapped ALPR · canonical OSM tag"
                : "\(maker)? · canonical OSM ALPR"
        }
    }

    static func detail(tier: UInt8, maker: String) -> String {
        switch tier {
        case 1:
            return "a mapped location, not a live detection"
        case 2:
            return maker.isEmpty
                ? "legacy or alternate tagging; verify the camera and location"
                : "legacy or alternate tagging; the maker attribution is not confirmed"
        default:
            return maker.isEmpty
                ? "canonical ALPR tag, but no structured manufacturer is recorded"
                : "canonical ALPR tag; the manufacturer text is not structured"
        }
    }

    static func accessibilityLabel(tier: UInt8, maker: String) -> String {
        let suffix = maker.isEmpty ? "" : " by \(maker)"
        switch tier {
        case 1: return "manufacturer-attributed mapped automatic license plate reader camera\(suffix)"
        case 2: return "legacy-tag community automatic license plate reader candidate\(suffix)"
        default: return "canonical community-mapped automatic license plate reader camera without structured manufacturer attribution\(suffix)"
        }
    }
}

/// Manifest shape published at soyboi.tech/data/alpr-latest.json.
private struct ALPRManifest: Codable {
    var schema: Int
    var updated: String
    var count: Int?
    var data: DataRef?
    struct DataRef: Codable {
        var url: String
        var sha256: String
        var size: Int
        var format: String?
    }
}
