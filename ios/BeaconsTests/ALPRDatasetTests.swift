import XCTest
import CoreLocation
@testable import Beacons

/// A request that delivers response headers and a small prefix, then stays open until URLSession
/// cancels it. That exercises cancellation while AsyncBytes is waiting for the rest of the body,
/// rather than a request that happened to finish before the layer switch could act.
private final class HangingALPRURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var onStart: (() -> Void)?
    private static var onStop: (() -> Void)?

    static func arm(onStart: @escaping () -> Void, onStop: @escaping () -> Void) {
        lock.lock()
        self.onStart = onStart
        self.onStop = onStop
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        onStart = nil
        onStop = nil
        lock.unlock()
    }

    private static func fireStart() {
        lock.lock()
        let callback = onStart
        onStart = nil
        lock.unlock()
        callback?()
    }

    private static func fireStop() {
        lock.lock()
        let callback = onStop
        onStop = nil
        lock.unlock()
        callback?()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.fireStart()
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "4096"]
              ) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 1024))
        // Deliberately no didFinishLoading: cancellation must call stopLoading().
    }

    override func stopLoading() {
        Self.fireStop()
    }
}

/// Wire-format fixtures for the ALPR dataset parser.
///
/// This parser produced the project's only cross-platform incident. A manifest schema mismatch made
/// BOTH apps reject the binary, and the reject path returns before it stamps the version key, so
/// every launch re-downloaded the same file and re-failed with a map frozen at the last good
/// dataset. It was then changed again to carry the ALP3 tier byte. Until now it had no test, which
/// means the only thing that has ever checked its length arithmetic is a phone in someone's pocket.
///
/// EXACTLY WHAT IS SHARED WITH ANDROID, stated precisely because a header that overstates its reach
/// is worse than none:
///   - The fixtures are BUILT IN CODE, not loaded from data files, same as FollowEvidenceTests. So
///     there is nothing on disk for Android to read; what crosses the platform boundary is the
///     builder plus the vectors. `alp(_:makers:nodes:)` below is the whole contract, and
///     android/../AlprDatasetTest.kt carries a byte-for-byte equivalent writing the same
///     little-endian layout in the same order.
///   - Every fixture uses the SAME VECTORS on both sides: same magics, same maker table, same
///     coordinates, same maker indices, same tier bytes, same byte surgery at the same offsets, and
///     the same expected coords / makers / confirmed.
///   - Both suites assert the same nil-vs-parsed verdict for every malformation they BOTH cover. A
///     guard that exists on one platform only is precisely the shape of the original incident.
///     ONE KNOWN EXCEPTION, still open: an invalid UTF-8 byte inside the maker table. Android
///     rejects the whole file - AlprStore.parse decodes maker names with throwOnInvalidSequence and
///     returns null - and pins that in testInvalidUtf8MakerIsRejected. This parser's
///     `String(decoding:as: UTF8.self)` is lossy, so the same bytes parse with U+FFFD in the maker
///     name, and there is deliberately NO twin fixture here yet: writing one would only freeze the
///     divergence. Settle one verdict for both parsers first, then add the fixture on both sides.
///
/// COORDINATE RANGE, resolved 2026-08-05 and the reason this suite exists: both parsers DROP an out-of-range coordinate together with its maker and tier. They used to
/// disagree: iOS dropped, this side kept every node the length check accounted for, so the same
/// corrupt file gave the two apps a different node COUNT and a different unverifiedCount caption.
/// The parity fixtures below are what surfaced it. Settled 2026-08-05 in favour of dropping,
/// because a latitude past +/-90 is corrupt bytes rather than a camera in an odd place: no
/// viewport box can contain it and nearest() cannot meaningfully match it, so keeping it only
/// inflates a caption with a node no surface can draw. Deliberately NOT the same call as the
/// unverified tier, where the pin is a real location with uncertain attribution and staying
/// counted keeps the data-quality problem visible. Both published datasets carried zero such
/// nodes when this landed, so nothing user-visible moved.
///
/// Every malformed fixture is a VALID file with exactly one byte range changed. That is the whole
/// method: when one fails, the guard that moved is named by the fixture, not guessed at.
@MainActor
final class ALPRDatasetTests: XCTestCase {

    // MARK: The builder
    //
    // Assembles a file the way soyboi.tech/tools/build_alpr_dataset.py assembles one:
    // magic | epochDay:u32 | count:u32 | [nMakers:u8 | nMakers*(len:u8, utf8)]
    //   | count*(latE7:i32, lonE7:i32) | [count*(makerIdx:u8)] | [count*(tier:u8)]
    //   | [count*(osmType:u8, osmID:u64, sourceEpoch:u32, directionCdeg:u16, checkDay:u32)]
    // all little-endian. ALP1 omits all bracketed blocks, ALP2 omits tier and metadata,
    // and ALP3 omits metadata.

    /// One node as the generator emits it. `maker` indexes the file's own table, `tier` is 1 when
    /// the OSM mapper picked the manufacturer from an editor preset.
    private struct Node {
        var lat: Double
        var lon: Double
        var maker: UInt8 = 0
        var tier: UInt8 = 1
        var osmType: UInt8 = 0
        var osmID: UInt64 = 1
        var sourceEpoch: UInt32 = 0
        var directionCdeg: UInt16 = .max
        var checkDateDay: UInt32 = 0
    }

    /// The table every fixture uses unless it says otherwise. Index 0 is "" (unknown) because the
    /// generator always emits it there; a node with no manufacturer recorded points at 0.
    private static let table = ["", "Flock Safety", "Genetec", "Neology"]

    /// Degrees to the wire's fixed point, ROUNDED rather than truncated: 32.7157 * 1e7 lands a hair
    /// under 327157000 in binary floating point, and truncating would put every fixture one
    /// ten-millionth of a degree south of where it reads here.
    private func e7(_ d: Double) -> Int32 { Int32((d * 1e7).rounded()) }

    private func alp(_ magic: String, makers suppliedMakers: [String]? = nil, nodes: [Node]) -> Data {
        // The builder keys off the magic string exactly as the parser does, so a fixture that
        // relabels the magic gets a body that no longer matches it. Several tests below depend on
        // that: it is how the original incident is reproduced.
        let makers = suppliedMakers ?? Self.table
        let hasMakers = magic != "ALP1"
        var d = Data(magic.utf8)
        d.append(u32: 20_285)                  // epochDay, read by nothing, present in every file
        d.append(u32: UInt32(nodes.count))
        if hasMakers {
            d.append(UInt8(makers.count))
            for m in makers {
                let utf8 = Array(m.utf8)
                d.append(UInt8(utf8.count))
                d.append(contentsOf: utf8)
            }
        }
        for n in nodes { d.append(i32: e7(n.lat)); d.append(i32: e7(n.lon)) }
        if hasMakers { for n in nodes { d.append(n.maker) } }
        if magic == "ALP3" || magic == "ALP4" { for n in nodes { d.append(n.tier) } }
        if magic == "ALP4" {
            for n in nodes {
                d.append(n.osmType)
                d.append(u64: n.osmID)
                d.append(u32: n.sourceEpoch)
                d.append(u16: n.directionCdeg)
                d.append(u32: n.checkDateDay)
            }
        }
        return d
    }

    /// Three real San Diego-ish coordinates, reused so a fixture that differs from another differs
    /// in ONE way. Node 1 is the only unverified one and the only one with a table index of 2.
    private static let threeNodes = [
        Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1),
        Node(lat: 32.7200, lon: -117.1700, maker: 2, tier: 0),
        Node(lat: 32.7300, lon: -117.1800, maker: 0, tier: 1),
    ]

    /// Assert a coordinate at the wire's own resolution (1e-7 degrees, about 1 cm). Looser and a
    /// fixture would still pass on a coordinate that had been read out of the wrong node.
    private func assertCoord(_ c: CLLocationCoordinate2D, _ lat: Double, _ lon: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.latitude, lat, accuracy: 5e-8, file: file, line: line)
        XCTAssertEqual(c.longitude, lon, accuracy: 5e-8, file: file, line: line)
    }

    // MARK: The four magics

    func testValidALP4RoundTripAndMetadata() {
        let nodes = [
            Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1,
                 osmType: 0, osmID: 123, sourceEpoch: 1_754_352_000,
                 directionCdeg: 27_050, checkDateDay: 20_305),
            Node(lat: 32.7200, lon: -117.1700, maker: 2, tier: 2,
                 osmType: 1, osmID: 456, sourceEpoch: 0,
                 directionCdeg: .max, checkDateDay: 0),
        ]
        guard let p = ALPRStore.parseDetailed(alp("ALP4", nodes: nodes)) else {
            return XCTFail("a well-formed ALP4 file was rejected")
        }
        XCTAssertEqual(p.rawCount, 2)
        XCTAssertEqual(p.wireFormat, "ALP4")
        XCTAssertEqual(p.makers, ["Flock Safety", "Genetec"])
        XCTAssertEqual(p.confirmed, [true, false])
        XCTAssertEqual(p.metadata[0].osmType, 0)
        XCTAssertEqual(p.metadata[0].osmID, 123)
        XCTAssertEqual(p.metadata[0].sourceEpoch, 1_754_352_000)
        XCTAssertEqual(p.metadata[0].directionCdeg, 27_050)
        XCTAssertEqual(p.metadata[0].checkDateDay, 20_305)
        XCTAssertEqual(p.metadata[0].attributionTier, 1)
        XCTAssertEqual(p.metadata[1].osmType, 1)
        XCTAssertEqual(p.metadata[1].osmID, 456)
        XCTAssertNil(p.metadata[1].sourceEpoch)
        XCTAssertNil(p.metadata[1].directionCdeg)
        XCTAssertNil(p.metadata[1].checkDateDay)
        XCTAssertEqual(p.metadata[1].attributionTier, 2)
    }

    func testSameDateCannotMakeAnALP3CacheSatisfyAnALP4Manifest() {
        XCTAssertFalse(ALPRStore.cacheFormatMatches(manifestFormat: "ALP4", loadedFormat: "ALP3"))
        XCTAssertTrue(ALPRStore.cacheFormatMatches(manifestFormat: "ALP4", loadedFormat: "alp4"))
        XCTAssertTrue(ALPRStore.cacheFormatMatches(manifestFormat: nil, loadedFormat: "ALP3"))

        let old = String(repeating: "a", count: 64)
        let new = String(repeating: "b", count: 64)
        XCTAssertFalse(ALPRStore.cacheIdentityMatches(
            manifestUpdated: "2026-08-10", manifestSHA: new, manifestFormat: "ALP4",
            storedUpdated: "2026-08-10", storedSHA: old, loadedSHA: old, loadedFormat: "ALP4"))
        XCTAssertTrue(ALPRStore.cacheIdentityMatches(
            manifestUpdated: "2026-08-10", manifestSHA: new, manifestFormat: "ALP4",
            storedUpdated: "2026-08-10", storedSHA: new, loadedSHA: new, loadedFormat: "ALP4"))
    }

    func testManifestChannelsRequireTheirOwnWireFormat() {
        XCTAssertTrue(ALPRStore.channelFormatMatches(
            declaredFormat: "ALP4", expectedFormat: "ALP4",
            allowsMissingDeclaredFormat: false, loadedFormat: "ALP4"))
        XCTAssertFalse(ALPRStore.channelFormatMatches(
            declaredFormat: nil, expectedFormat: "ALP4",
            allowsMissingDeclaredFormat: false, loadedFormat: "ALP4"))
        XCTAssertFalse(ALPRStore.channelFormatMatches(
            declaredFormat: "ALP4", expectedFormat: "ALP4",
            allowsMissingDeclaredFormat: false, loadedFormat: "ALP3"))

        // The old V3 publisher omitted data.format, but its bytes must still be ALP3.
        XCTAssertTrue(ALPRStore.channelFormatMatches(
            declaredFormat: nil, expectedFormat: "ALP3",
            allowsMissingDeclaredFormat: true, loadedFormat: "ALP3"))
        XCTAssertFalse(ALPRStore.channelFormatMatches(
            declaredFormat: nil, expectedFormat: "ALP3",
            allowsMissingDeclaredFormat: true, loadedFormat: "ALP2"))
    }

    /// The layer ships ON: a fresh install (no stored value) resolves to enabled, while a user
    /// who ever explicitly flipped the toggle keeps that stored choice, in either direction.
    /// Android's prefs.getBoolean(key, true) carries the same semantics.
    func testLayerShipsEnabledButAnExplicitStoredChoiceAlwaysWins() {
        XCTAssertTrue(ALPRStore.resolveStoredEnabled(nil),
                      "a fresh install must default the mapped-camera layer ON")
        XCTAssertFalse(ALPRStore.resolveStoredEnabled(false),
                       "an explicit OFF choice must survive the default change")
        XCTAssertTrue(ALPRStore.resolveStoredEnabled(true))
        // UserDefaults bridges Bools through NSNumber; the cast must still read them.
        XCTAssertFalse(ALPRStore.resolveStoredEnabled(NSNumber(value: false)))
        // A value of an unexpected type is not an explicit choice; the default applies.
        XCTAssertTrue(ALPRStore.resolveStoredEnabled("off"))
    }

    /// setEnabled(false) calls this slot's cancel() before clearing the layer. The retired task's
    /// completion must not fire after an immediate re-enable, or it can clear/restart the new fetch.
    func testFetchSlotCancelStopsActiveWorkAndAllowsImmediateReplacement() async {
        let slot = ALPRFetchSlot()
        let firstStarted = expectation(description: "first fetch started")
        let firstCancelled = expectation(description: "first fetch observed cancellation")
        var retiredCompletionRan = false

        guard let first = slot.start(operation: {
            firstStarted.fulfill()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                XCTAssertTrue(Task.isCancelled)
                firstCancelled.fulfill()
            }
        }, onFinish: {
            retiredCompletionRan = true
        }) else { return XCTFail("first fetch did not start") }

        await fulfillment(of: [firstStarted], timeout: 1)
        XCTAssertTrue(slot.isRunning)
        slot.cancel()
        XCTAssertFalse(slot.isRunning)

        var replacementFinished = false
        guard let replacement = slot.start(operation: {}, onFinish: {
            replacementFinished = true
        }) else { return XCTFail("cancelled slot did not accept a replacement") }
        await replacement.value
        await fulfillment(of: [firstCancelled], timeout: 1)
        await first.value

        XCTAssertTrue(replacementFinished)
        XCTAssertFalse(retiredCompletionRan,
                       "the cancelled generation must not finish the replacement generation")
        XCTAssertFalse(slot.isRunning)
    }

    /// Cancelling the owned fetch task must reach URLSession itself for both request sizes used by
    /// ALPRStore: the manifest and the up-to-8 MB dataset body. Suppressing publication alone would
    /// leave this protocol open until its 15/30 second request timeout instead of calling stopLoading.
    func testBoundedTransfersAbortTheirURLLoadingTaskOnCancellation() async {
        for (name, limit) in [
            ("manifest", ALPRStore.maxManifestBytes),
            ("dataset", ALPRStore.maxDatasetBytes),
        ] {
            let started = expectation(description: "\(name) transfer started")
            let stopped = expectation(description: "\(name) transfer stopped")
            HangingALPRURLProtocol.arm(
                onStart: { started.fulfill() },
                onStop: { stopped.fulfill() }
            )
            defer { HangingALPRURLProtocol.reset() }

            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [HangingALPRURLProtocol.self]
            var request = URLRequest(url: URL(string: "https://soyboi.tech/data/cancel-test")!)
            request.timeoutInterval = 30
            let transfer = Task {
                try await ALPRStore.boundedData(
                    for: request,
                    limit: limit,
                    configuration: configuration
                )
            }

            await fulfillment(of: [started], timeout: 1)
            transfer.cancel()
            await fulfillment(of: [stopped], timeout: 1)
            do {
                _ = try await transfer.value
                XCTFail("\(name) transfer completed after cancellation")
            } catch {
                XCTAssertTrue(Task.isCancelled || error is CancellationError
                              || (error as? URLError)?.code == .cancelled)
            }
            HangingALPRURLProtocol.reset()
        }
    }

    func testAttributionCopyDistinguishesCanonicalAndLegacyMakerStates() {
        XCTAssertEqual(ALPRAttribution.detail(tier: 0, maker: ""),
                       "canonical ALPR tag, but no structured manufacturer is recorded")
        XCTAssertEqual(ALPRAttribution.detail(tier: 2, maker: "Flock Safety"),
                       "legacy or alternate tagging; the maker attribution is not confirmed")
        XCTAssertFalse(ALPRAttribution.detail(tier: 2, maker: "Flock Safety")
            .contains("no manufacturer"))
        XCTAssertTrue(ALPRAttribution.accessibilityLabel(tier: 2, maker: "Flock Safety")
            .contains("legacy-tag"))
    }

    func testStableOSMIdentityKeepsColocatedCamerasDistinct() {
        let coordinate = CLLocationCoordinate2D(latitude: 32.7157, longitude: -117.1611)
        let first = ALPRStore.NodeMetadata(
            osmType: 0, osmID: 42, sourceEpoch: nil, directionCdeg: nil,
            checkDateDay: nil, attributionTier: 1)
        let second = ALPRStore.NodeMetadata(
            osmType: 1, osmID: 42, sourceEpoch: nil, directionCdeg: nil,
            checkDateDay: nil, attributionTier: 1)
        XCTAssertNotEqual(
            ALPRStore.stableNodeID(index: 0, coordinate: coordinate, metadata: first),
            ALPRStore.stableNodeID(index: 0, coordinate: coordinate, metadata: second))
        XCTAssertNotEqual(
            ALPRStore.stableNodeID(index: 0, coordinate: coordinate, metadata: nil),
            ALPRStore.stableNodeID(index: 1, coordinate: coordinate, metadata: nil))
    }

    func testValidALP3RoundTrip() {
        guard let p = ALPRStore.parse(alp("ALP3", nodes: Self.threeNodes)) else {
            return XCTFail("a well-formed ALP3 file was rejected")
        }
        XCTAssertEqual(p.coords.count, 3)
        assertCoord(p.coords[0], 32.7157, -117.1611)
        assertCoord(p.coords[1], 32.7200, -117.1700)
        assertCoord(p.coords[2], 32.7300, -117.1800)
        // Resolved through the file's own table, in node order. The table is self-describing on
        // purpose, so this is also the assertion that fails if anyone hardcodes a maker list.
        XCTAssertEqual(p.makers, ["Flock Safety", "Genetec", ""])
        XCTAssertEqual(p.confirmed, [true, false, true])
    }

    func testALP2DefaultsEveryNodeToConfirmed() {
        // Same nodes, same tier bytes in the fixture, but ALP2 carries no tier block at all so the
        // parser never sees them. Node 1 is unverified in the ALP3 fixture above and confirmed
        // here, which is the entire point: a pre-ALP3 cache carries no evidence either way, and the
        // tier is an accusation. Defaulting the other way would paint a whole stale map amber
        // purely because the file is old.
        guard let p = ALPRStore.parse(alp("ALP2", nodes: Self.threeNodes)) else {
            return XCTFail("a well-formed ALP2 file was rejected")
        }
        XCTAssertEqual(p.coords.count, 3)
        assertCoord(p.coords[1], 32.7200, -117.1700)
        XCTAssertEqual(p.makers, ["Flock Safety", "Genetec", ""])
        XCTAssertEqual(p.confirmed, [true, true, true])
    }

    func testALP1HasNoMakersAndIsAllConfirmed() {
        // The coord block is byte-identical across all three versions, which is the whole reason a
        // cache written by a 2024 build still draws today.
        guard let p = ALPRStore.parse(alp("ALP1", nodes: Self.threeNodes)) else {
            return XCTFail("a well-formed ALP1 file was rejected")
        }
        XCTAssertEqual(p.coords.count, 3)
        assertCoord(p.coords[0], 32.7157, -117.1611)
        assertCoord(p.coords[2], 32.7300, -117.1800)
        XCTAssertEqual(p.makers, ["", "", ""])
        XCTAssertEqual(p.confirmed, [true, true, true])
    }

    func testUnknownTierByteIsNotConfirmed() {
        // Only the byte 1 vouches for a node. If the generator ever grows a tier 2, an old build
        // must read it as "not vouched for" rather than waving it through, because confirmed is the
        // flag that decides whether a pin is allowed to corroborate a live detection.
        let odd = [Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 2),
                   Node(lat: 32.7200, lon: -117.1700, maker: 1, tier: 255)]
        XCTAssertEqual(ALPRStore.parse(alp("ALP3", nodes: odd))?.confirmed, [false, false])
    }

    // MARK: The empty dataset

    func testEmptyDatasetIsEmptyArraysNotNil() {
        // A zero-node file is legal, not a malformation. It has to stay distinguishable from a
        // reject: a reject returns before the version key is stamped and re-downloads forever,
        // whereas an empty dataset is simply a region with nothing mapped in it.
        for magic in ["ALP1", "ALP2", "ALP3", "ALP4"] {
            guard let p = ALPRStore.parse(alp(magic, nodes: [])) else {
                return XCTFail("\(magic) with count 0 was rejected")
            }
            XCTAssertTrue(p.coords.isEmpty, magic)
            XCTAssertTrue(p.makers.isEmpty, magic)
            XCTAssertTrue(p.confirmed.isEmpty, magic)
        }
    }

    // MARK: The header

    func testBadMagicIsRejected() {
        // ALP5 is the one that matters: it is what a future format looks like arriving at today's
        // build, and rejecting it is correct. The lowercase and empty cases pin that the check is
        // on bytes, not on a case-insensitive string compare someone might "tidy" it into.
        for magic in ["ALP5", "ALP0", "alp3", "XXXX", "APL3"] {
            XCTAssertNil(ALPRStore.parse(alp(magic, nodes: Self.threeNodes)), magic)
        }
        XCTAssertNil(ALPRStore.parse(Data()))
        XCTAssertNil(ALPRStore.parse(Data(repeating: 0, count: 64)))
    }

    func testTruncatedHeaderIsRejected() {
        // 12 bytes is the floor: magic + epochDay + count. Every prefix under it must be nil rather
        // than an index crash, because this runs on a file that came off the network.
        let valid = alp("ALP3", nodes: Self.threeNodes)
        for n in 0..<12 {
            XCTAssertNil(ALPRStore.parse(valid.prefix(n)), "\(n)-byte prefix")
        }
        // 13 bytes clears the header floor but stops exactly where the maker-table count byte would
        // be. ALP2/ALP3 need one more byte than ALP1 does, and this is that boundary.
        XCTAssertNil(ALPRStore.parse(valid.prefix(12)))
    }

    // MARK: The maker table

    func testEmptyMakerTableIsRejected() {
        // Index 0 must exist. A table with no entries cannot resolve the index every unknown node
        // points at, so the file is not readable even though its length arithmetic works out.
        XCTAssertNil(ALPRStore.parse(alp("ALP2", makers: [], nodes: [])))
        XCTAssertNil(ALPRStore.parse(alp("ALP3", makers: [], nodes: Self.threeNodes)))
    }

    func testMakerTableRunningPastTheBufferIsRejected() {
        // Byte map of a valid ALP2 with this table: 0-3 magic, 4-7 epochDay, 8-11 count,
        // 12 nMakers, 13 len("")=0, 14 len("Flock Safety")=12, 15.. the string. Byte 14 is the only
        // one touched, so a failure here is the length guard and nothing else.
        var overrun = alp("ALP2", nodes: Self.threeNodes)
        overrun[14] = 200
        XCTAssertNil(ALPRStore.parse(overrun))
        // The other way a table can run off the end: the count byte promises more entries than the
        // buffer holds, so the loop walks past the last one rather than past a single string.
        var tooManyEntries = alp("ALP2", nodes: Self.threeNodes)
        tooManyEntries[12] = 200
        XCTAssertNil(ALPRStore.parse(tooManyEntries))
    }

    func testMakerIndexPastTheTableResolvesToUnknown() {
        // NOT a rejection, deliberately, and matching Android. The coordinate is intact and only
        // its label is unreadable, so this degrades one pin to "unknown maker" instead of blanking
        // the map. The dataset is community-mapped, and one bad label is not a reason to show a
        // user nothing. Node 1 points at index 7 of a four-entry table.
        let nodes = [Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1),
                     Node(lat: 32.7200, lon: -117.1700, maker: 7, tier: 0),
                     Node(lat: 32.7300, lon: -117.1800, maker: 3, tier: 1)]
        guard let p = ALPRStore.parse(alp("ALP3", nodes: nodes)) else {
            return XCTFail("one bad maker index must not reject the dataset")
        }
        XCTAssertEqual(p.coords.count, 3, "the coordinate is fine, only its label is not")
        XCTAssertEqual(p.makers, ["Flock Safety", "", "Neology"])
        XCTAssertEqual(p.confirmed, [true, false, true])
    }

    // MARK: Count against length

    func testOversizeCountIsRejected() {
        // Same three-node body, count field (bytes 8-11) rewritten to claim 1000 nodes. The parser
        // must not believe the header over the buffer: 1000 * 8 coord bytes is not there, and a
        // parser that trusted the count would read 8 KB off the end of a 60-byte file.
        var lying = alp("ALP1", nodes: Self.threeNodes)
        lying[8] = 0xE8; lying[9] = 0x03; lying[10] = 0; lying[11] = 0     // 1000, little-endian
        XCTAssertNil(ALPRStore.parse(lying))
        // 0xFFFFFFFF is the case the 5 million cap exists for. The length check would also reject
        // it, so this is belt and braces rather than an isolated guard, but the cap runs FIRST and
        // it is what keeps count * 8 and reserveCapacity away from a four-billion-element array.
        var absurd = alp("ALP1", nodes: Self.threeNodes)
        for i in 8...11 { absurd[i] = 0xFF }
        XCTAssertNil(ALPRStore.parse(absurd))
    }

    // MARK: The incident itself
    //
    // Both directions of the version skew that froze the map, pinned as tests. This is why the V3
    // manifest is a separate URL from the one shipped builds poll: the length check is exact on
    // both sides, so neither reader tolerates the other's file, and the reject path returns before
    // stamping the version key. Serving one file to both readers means one of them re-downloads and
    // re-fails on every launch, forever.

    func testALP3WithAShortTierBlockIsRejected() {
        // An ALP3 body one byte short of its own tier block. Truncation is what a half-written
        // cache file looks like.
        let valid = alp("ALP3", nodes: Self.threeNodes)
        XCTAssertNil(ALPRStore.parse(valid.prefix(valid.count - 1)))
        // The sharper case: an ALP2 body wearing the ALP3 magic, so the tier block is missing
        // ENTIRELY rather than clipped. This is a generator that bumped its version string without
        // emitting the new field, which is the exact shape of the original incident.
        var relabelled = alp("ALP2", nodes: Self.threeNodes)
        relabelled[3] = UInt8(ascii: "3")
        XCTAssertNil(ALPRStore.parse(relabelled))
    }

    func testTrailingGarbageIsRejected() {
        // A valid payload plus one stray byte. The length check is equality, not a minimum, so a
        // reader never quietly ignores a tail it does not understand.
        var padded = alp("ALP3", nodes: Self.threeNodes)
        padded.append(0xFF)
        XCTAssertNil(ALPRStore.parse(padded))
        // The incident from the installed base's side: an ALP3 file arriving at an ALP2 reader
        // reads as a valid payload with an unexplained count-byte tail. Pinned so nobody "fixes"
        // the equality into a >= without understanding that the strictness is the reason the two
        // manifests have to stay separate.
        var v3BodyAsV2 = alp("ALP3", nodes: Self.threeNodes)
        v3BodyAsV2[3] = UInt8(ascii: "2")
        XCTAssertNil(ALPRStore.parse(v3BodyAsV2))
    }

    func testALP4RejectsInvalidMetadataAndTruncation() {
        let base = Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1,
                        osmType: 0, osmID: 12, sourceEpoch: 100,
                        directionCdeg: 900, checkDateDay: 20_000)
        var invalidType = base
        invalidType.osmType = 3
        XCTAssertNil(ALPRStore.parseDetailed(alp("ALP4", nodes: [invalidType])))
        var zeroID = base
        zeroID.osmID = 0
        XCTAssertNil(ALPRStore.parseDetailed(alp("ALP4", nodes: [zeroID])))
        var invalidDirection = base
        invalidDirection.directionCdeg = 36_000
        XCTAssertNil(ALPRStore.parseDetailed(alp("ALP4", nodes: [invalidDirection])))
        var invalidTier = base
        invalidTier.tier = 3
        XCTAssertNil(ALPRStore.parseDetailed(alp("ALP4", nodes: [invalidTier])))
        let valid = alp("ALP4", nodes: [base])
        XCTAssertNil(ALPRStore.parseDetailed(valid.prefix(valid.count - 1)))
    }

    // MARK: Coordinates

    func testOutOfRangeCoordIsDroppedWithItsMakerAndTier() {
        // The subtle one. Dropping a coordinate without dropping its maker and tier leaves three
        // arrays of different lengths indexed by the same integer everywhere else in the app, which
        // does not crash, it just relabels every pin after the bad one. All three are asserted
        // because checking the count alone would pass on exactly that bug.
        //
        // Node 1 is out of range, and it is also the only node with maker index 2 and tier 0. So a
        // parser that dropped the coordinate but kept the label would come back with "Genetec" in
        // slot 1 instead of "Neology", and confirmed [true, false] instead of [true, true].
        let nodes = [Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1),
                     Node(lat: 91.0, lon: -117.0, maker: 2, tier: 0),
                     Node(lat: 32.7300, lon: -117.1800, maker: 3, tier: 1)]
        guard let p = ALPRStore.parse(alp("ALP3", nodes: nodes)) else {
            return XCTFail("one corrupt coordinate must not reject the dataset")
        }
        XCTAssertEqual(p.coords.count, 2)
        assertCoord(p.coords[0], 32.7157, -117.1611)
        assertCoord(p.coords[1], 32.7300, -117.1800)
        XCTAssertEqual(p.makers, ["Flock Safety", "Neology"])
        XCTAssertEqual(p.confirmed, [true, true])
        // Longitude is range-checked too, and on ALP2, where the tier block does not exist to keep
        // in step but the maker array still does.
        let lonOut = [Node(lat: 32.7157, lon: -117.1611, maker: 1),
                      Node(lat: 32.7200, lon: 181.0, maker: 2),
                      Node(lat: 32.7300, lon: -117.1800, maker: 3)]
        guard let q = ALPRStore.parse(alp("ALP2", nodes: lonOut)) else {
            return XCTFail("one corrupt longitude must not reject the dataset")
        }
        XCTAssertEqual(q.coords.count, 2)
        XCTAssertEqual(q.makers, ["Flock Safety", "Neology"])
        XCTAssertEqual(q.confirmed, [true, true])
    }

    func testCoordinateLimitsAreInclusive() {
        // The poles and the antimeridian are real places, so the bound is inclusive and one
        // hundred-millionth of a degree past it is not. Pinned as a pair because a lone in-range
        // fixture passes under a `>` that should have been a `>=` and vice versa.
        let onTheLimit = [Node(lat: 90.0, lon: 180.0), Node(lat: -90.0, lon: -180.0)]
        XCTAssertEqual(ALPRStore.parse(alp("ALP3", nodes: onTheLimit))?.coords.count, 2)
        let justPast = [Node(lat: 90.0000001, lon: 180.0), Node(lat: -90.0, lon: -180.0000001)]
        XCTAssertEqual(ALPRStore.parse(alp("ALP3", nodes: justPast))?.coords.count, 0)
    }

    func testALP4DropsInvalidCoordinateAndItsMetadataTogether() {
        let good = Node(lat: 32.7157, lon: -117.1611, maker: 1, tier: 1,
                        osmType: 0, osmID: 10)
        let invalid = Node(lat: 91, lon: -117, maker: 2, tier: 2,
                           osmType: 2, osmID: 20)
        let last = Node(lat: 32.73, lon: -117.18, maker: 3, tier: 0,
                        osmType: 1, osmID: 30)
        let parsed = ALPRStore.parseDetailed(alp("ALP4", nodes: [good, invalid, last]))
        XCTAssertEqual(parsed?.coords.count, 2)
        XCTAssertEqual(parsed?.makers, ["Flock Safety", "Neology"])
        XCTAssertEqual(parsed?.metadata.map(\.osmID), [10, 30])
    }

    func testDatasetURLAllowlistRejectsRedirectAndCredentialEscapes() {
        XCTAssertTrue(ALPRStore.isAllowedDatasetURL(URL(string: "https://soyboi.tech/data/alpr.bin")))
        XCTAssertTrue(ALPRStore.isAllowedDatasetURL(URL(string: "https://soyboi.tech:443/data/alpr.bin")))
        XCTAssertFalse(ALPRStore.isAllowedDatasetURL(URL(string: "http://soyboi.tech/data/alpr.bin")))
        XCTAssertFalse(ALPRStore.isAllowedDatasetURL(URL(string: "https://www.soyboi.tech/data/alpr.bin")))
        XCTAssertFalse(ALPRStore.isAllowedDatasetURL(URL(string: "https://soyboi.tech.evil.test/alpr.bin")))
        XCTAssertFalse(ALPRStore.isAllowedDatasetURL(URL(string: "https://user@soyboi.tech/alpr.bin")))
        XCTAssertFalse(ALPRStore.isAllowedDatasetURL(URL(string: "https://soyboi.tech:444/alpr.bin")))
    }
}

// Little-endian writers for the fixture builder. Deliberately hand-rolled rather than reached for
// via withUnsafeBytes: the file format is defined as bytes on a wire, and a test that inherited the
// host's endianness would agree with a parser that had done the same thing wrong.
private extension Data {
    mutating func append(u16 v: UInt16) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
    }
    mutating func append(u32 v: UInt32) {
        append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
                            UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)])
    }
    mutating func append(u64 v: UInt64) {
        append(contentsOf: (0..<8).map { UInt8((v >> UInt64($0 * 8)) & 0xFF) })
    }
    mutating func append(i32 v: Int32) { append(u32: UInt32(bitPattern: v)) }
}
