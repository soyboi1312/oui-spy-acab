import Foundation
import Combine

/// The firmware manifest published at soyboi.tech. It tells the app the latest version
/// per board (keyed by the exact "fw" label a board reports), whether that board can take
/// an in-app OTA update, and where to download the verified image (or which browser flasher
/// to send the user to when OTA isn't offered).
///
/// Shape (schema 1):
/// {
///   "schema": 1,
///   "updated": "YYYY-MM-DD",
///   "builds": {
///     "beacon board": {
///       "version": "2.0.0",
///       "ota": true,
///       "app": { "url": "https://...", "sha256": "<hex64 or empty>", "size": <int> },
///       "flasher": "https://...",
///       "notes": ""
///     }, ...
///   }
/// }
///
/// The manifest is advisory: a bad/missing/malformed fetch never blocks the UI or crashes.
/// We fall back to the last-good cache, then to a baked-in default that mirrors
/// DeviceStatus.latestVersion, so the "update available" nudge always has an answer.
struct FirmwareManifest: Codable, Equatable {
    var schema: Int
    var updated: String?
    var builds: [String: Build]

    struct Build: Codable, Equatable {
        var version: String
        var ota: Bool
        var app: AppImage
        var flasher: String?
        var notes: String?
        /// Absent on every non-beacon board: only the dual-radio build ships a co-processor.
        var nrf: NrfImage?
    }

    /// The co-processor half of a build entry. The nRF52840 runs the Adafruit/Seeed bootloader,
    /// which speaks LEGACY Nordic DFU (service 0x1530), so what ships is an adafruit-nrfutil DFU
    /// .zip, not a raw image. `version` is a small monotonic Int (NRF_APP_VERSION in the nRF
    /// firmware), NOT a semver string: the S3 reports the running value as "nrfv" and an update
    /// is offered when the manifest's is higher.
    struct NrfImage: Codable, Equatable {
        var version: Int
        var ota: Bool
        var url: String
        var sha256: String
        var size: Int
        /// Same rule as AppImage.sig: empty/absent means unsigned, so the update must be refused.
        var sig: String?
    }

    struct AppImage: Codable, Equatable {
        var url: String
        var sha256: String
        var size: Int
        // Detached ECDSA P-256/SHA-256 signature over the whole image, lowercase hex DER.
        // Empty/absent = unsigned = OTA must be refused (the board gate rejects it too).
        var sig: String?
    }
}

extension FirmwareManifest.Build {
    /// True when this entry carries a complete, verifiable image: an integrity hash, a real
    /// size, a URL, and a non-empty image signature. Part of the OTA gate; without all four
    /// we can't verify a download, and an unsigned image would be rejected by the board anyway.
    var hasVerifiableImage: Bool {
        !app.sha256.isEmpty && app.size > 0 && !app.url.isEmpty && !(app.sig ?? "").isEmpty
    }

    /// Same bar for the co-processor package. nil `nrf` (every non-beacon board) is false, so a
    /// caller can ask without checking for the sub-entry first.
    var hasVerifiableNrfImage: Bool {
        guard let n = nrf else { return false }
        return !n.sha256.isEmpty && n.size > 0 && !n.url.isEmpty && !(n.sig ?? "").isEmpty
    }
}

extension FirmwareManifest {
    /// The build entry for a board's fw label ("beacon board", "ACAB-ouispy",
    /// "mesh-detect-ACAB"), or nil if the manifest doesn't list it.
    func build(forFwLabel label: String) -> Build? { builds[label] }

    /// Baked-in fallback used when we've never fetched a manifest and have nothing cached.
    /// Mirrors the app's per-board ship targets (DeviceStatus.latestVersion for the beacon board,
    /// colonelLatestVersion for the single-board builds) so the offline nudge matches.
    /// OTA is off here on purpose: with no verified image details we only ever point the
    /// user at the browser flasher until a real manifest arrives.
    static var fallback: FirmwareManifest {
        let img = AppImage(url: "", sha256: "", size: 0, sig: nil)
        // Per-board flasher pages (matches the Android fallback): the beacon board flashes
        // from soyboi.tech, the Colonel Panic boards from the ACAB repo's flasher.
        let acabFlasher = "https://soyboi1312.github.io/all-cameras-are-beacons/"
        func build(_ version: String, _ flasher: String) -> Build {
            Build(version: version, ota: false, app: img,
                  flasher: flasher, notes: nil)
        }
        // The beacon board has moved ahead of the Colonel Panic single-board builds, so each
        // label carries its own offline baseline (matches the Android per-board fallback).
        return FirmwareManifest(schema: 1, updated: nil, builds: [
            "beacon board": build(DeviceStatus.latestVersion, "https://soyboi.tech/flash.html"),
            // rev-B rides the beacon version line but flashes from its own page: its image must
            // never land on rev-A hardware, so the fallback must not point it at flash.html.
            "beacon board rev-B": build(DeviceStatus.latestVersion, "https://soyboi.tech/flash-revb.html"),
            "ACAB-ouispy": build(DeviceStatus.colonelLatestVersion, acabFlasher),
            "mesh-detect-ACAB": build(DeviceStatus.colonelLatestVersion, acabFlasher),
            "mesh-detect-ACAB-ch1": build(DeviceStatus.colonelLatestVersion, acabFlasher),
        ])
    }
}

/// Fetches, caches, and serves the firmware manifest. Injected as an environment object so
/// the Device screen can ask "what's the latest for this board, and can it self-update?".
///
/// Fetch policy: non-blocking background refresh on app start and on board connect, with a
/// ~6 h TTL. The last-good JSON is persisted to UserDefaults with its fetch timestamp and
/// used verbatim when offline. Nothing here ever blocks the UI or throws into it.
@MainActor
final class FirmwareManifestStore: ObservableObject {
    static let shared = FirmwareManifestStore()

    /// The manifest the UI should read. Starts from cache (or the baked-in fallback) and is
    /// replaced in place by a successful refresh.
    @Published private(set) var manifest: FirmwareManifest

    private let manifestURL = URL(string: "https://soyboi.tech/firmware/firmware-latest.json")!
    private let cacheKey = "acab.firmwareManifest"       // last-good JSON
    private let cacheTimeKey = "acab.firmwareManifestAt" // when we fetched it (epoch seconds)
    private let ttl: TimeInterval = 6 * 60 * 60          // refresh at most once per ~6 h
    private nonisolated static let maxManifestBytes = 256 * 1024
    private var inFlight = false

    private init() {
        // Seed from the last-good cache, else the baked-in fallback. Either way the UI has a
        // usable answer before any network call finishes.
        if let cached = Self.readCache(key: cacheKey) {
            manifest = cached
        } else {
            manifest = .fallback
        }
    }

    // MARK: Accessors the UI consumes

    /// Latest known version for a board's fw label. Falls back to DeviceStatus.latestVersion
    /// when the manifest doesn't list the board.
    func latestVersion(forFwLabel label: String) -> String {
        manifest.build(forFwLabel: label)?.version ?? DeviceStatus.latestVersion
    }

    /// The full manifest entry for a board's fw label, or nil when unlisted.
    func entry(forFwLabel label: String) -> FirmwareManifest.Build? {
        manifest.build(forFwLabel: label)
    }

    // MARK: Refresh

    /// Kick a background refresh if the cache is stale (or forced). Safe to call often: it
    /// no-ops when a fetch is in flight or the cache is still fresh, and it never blocks or
    /// surfaces an error to the caller.
    func refreshIfNeeded(force: Bool = false) {
        guard !inFlight else { return }
        if !force, let at = UserDefaults.standard.object(forKey: cacheTimeKey) as? Double,
           Date().timeIntervalSince1970 - at < ttl {
            return   // cache still within TTL
        }
        inFlight = true
        Task { await self.fetch() }
    }

    /// Force an immediate refresh and await it, bypassing the TTL. Backs the manual
    /// "check for updates" control so the UI can show a spinner until it resolves and then
    /// re-evaluate update availability off the freshly-published manifest. No-ops (and
    /// returns right away) when a background refresh is already in flight.
    func refreshNow() async {
        guard !inFlight else { return }
        inFlight = true
        await fetch()
    }

    private func fetch() async {
        defer { inFlight = false }
        var req = URLRequest(url: manifestURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // we do our own TTL/caching
        req.timeoutInterval = 15
        guard let payload = try? await Self.boundedManifestData(for: req),
              (200..<300).contains(payload.response.statusCode),
              let fetched = try? JSONDecoder().decode(FirmwareManifest.self, from: payload.data),
              fetched.schema == 1, !fetched.builds.isEmpty else {
            // Bad network, non-2xx, or malformed/unsupported JSON: keep serving whatever we
            // already have. Never clobber a good cache with garbage.
            return
        }
        let data = payload.data
        UserDefaults.standard.set(data, forKey: cacheKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: cacheTimeKey)
        manifest = fetched
    }

    private nonisolated static func boundedManifestData(
        for request: URLRequest
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = request.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "soyboi.tech", url.user == nil,
              url.password == nil, url.port == nil || url.port == 443 else {
            throw FirmwareManifestFetchError.invalidResponse
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(
            configuration: configuration,
            delegate: FirmwareManifestRejectRedirectsDelegate(),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == "soyboi.tech",
              http.expectedContentLength <= Int64(maxManifestBytes) else {
            throw FirmwareManifestFetchError.invalidResponse
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(min(maxManifestBytes, Int(http.expectedContentLength)))
        }
        for try await byte in bytes {
            guard data.count < maxManifestBytes else {
                throw FirmwareManifestFetchError.tooLarge
            }
            data.append(byte)
        }
        return (data, http)
    }

    private static func readCache(key: String) -> FirmwareManifest? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode(FirmwareManifest.self, from: data) else { return nil }
        return m
    }
}

private enum FirmwareManifestFetchError: Error {
    case invalidResponse
    case tooLarge
}

private final class FirmwareManifestRejectRedirectsDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable {
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
