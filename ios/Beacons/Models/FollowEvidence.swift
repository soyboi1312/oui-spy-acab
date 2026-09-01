import CoreLocation

/// Turns a tracker's breadcrumb trail into a sentence a person can judge, and nothing more.
///
/// The firmware has always refused this call on purpose (the TRACKER_ALERT_DEBOUNCE_MS banner in
/// acab_scanner.cpp, and the note beside that debounce in handleDetection - named rather than
/// line-cited, because that file's line numbers move): the board sees one advertisement at a time
/// and has no idea where the phone was standing, so "is this thing FOLLOWING me" can only be
/// answered here, from location over time. This file is that answer, and it is deliberately the
/// smallest one that is defensible.
///
/// The evidence is ALREADY gathered and already filtered. BLEManager appends a crumb of THE
/// PHONE's own position for a separated tracker only when the record is live, the type is
/// .tracker, a fresh fix exists, at least 60 s have passed since that device's last crumb, AND the
/// phone has moved at least 25 m from it (BLEManager.swift, the tracker block in ingestDetection).
/// So n crumbs is not n sightings: it means the tag stayed in radio range across n-1 independent
/// 60 s AND 25 m gates. That is the whole continuity signal, and this scorer NEVER re-applies
/// those two tests. Filtering the same thing twice would silently move the effective thresholds
/// somewhere nobody wrote down, and the numbers below are only meaningful against the gate that
/// actually ran.
///
/// What this file will not do, and why:
///  - It never raises an alarm. The output is evidence the user weighs ("near you at 4 places over
///    2 hours"), never a verdict. A false positive here costs more than a miss, because it teaches
///    the user to discount every other thing the product says.
///  - It never touches d.count, bestRssi, or rssiHistory. Sighting count is dominated by
///    advertising rate and scan luck, so it would reward chatty tags for being chatty. bestRssi is
///    a single 1-of-N extreme, so every device that ever passed close would clear an RSSI floor.
///    rssiHistory is capped at the last 48 samples and is not time-aligned with the crumbs, so a
///    "median RSSI over the run" is simply not computable from what is on disk, and standing in
///    bestRssi for it biases every device toward passing.
///  - It is pure. No manager, no @Published, no clock reads of its own, so the SECTION 8 parity
///    fixtures below can pin it exactly and Android's FollowEvidence.kt can be held to the same
///    arithmetic byte for byte.
///
/// PARITY IS THE POINT. Android implements this same document. Every constant, every comparison,
/// every string is duplicated there on purpose, so a change here that is not made there is a bug
/// even if both sides still compile.
enum FollowEvidence {

    // MARK: - Distance
    //
    // One haversine, ours, used ONLY by this scorer. NOT CLLocation.distance: Core Location and
    // Android's Location.distanceBetween run different geodesic algorithms (Vincenty-family vs a
    // spherical approximation) and disagree by metres over kilometre scales. Metres of disagreement
    // are invisible everywhere else in the app and fatal here, because the bands turn on exact
    // comparisons at 250 / 500 / 1000 m and the two platforms would land on different sides of them
    // for the same journey. The crumb-APPEND gate in BLEManager keeps its platform call: that is the
    // hot ingest path, its 25 m test has no band boundary hanging off it, and it is out of scope.

    /// IUGG mean Earth radius. A literal, spelled identically in Kotlin, because deriving it from
    /// any platform constant reintroduces exactly the divergence this exists to remove.
    static let earthRadiusM = 6371008.8

    /// Great-circle distance, floored to whole metres.
    ///
    /// The floor is not cosmetic. Two libm implementations can differ in the last ulp of sin/atan2,
    /// so a device sitting exactly on a boundary could band differently on the two platforms
    /// forever. Truncating to an integer before any comparison makes that unobservable, and every
    /// threshold below is therefore Int vs Int. Flooring is also the conservative direction: we
    /// under-state distance rather than over-state it.
    static func metres(_ aLat: Double, _ aLon: Double, _ bLat: Double, _ bLon: Double) -> Int {
        let toRad = 3.141592653589793 / 180.0
        let p1 = aLat * toRad, p2 = bLat * toRad
        let dp = (bLat - aLat) * toRad, dl = (bLon - aLon) * toRad
        let s1 = sin(dp / 2.0), s2 = sin(dl / 2.0)
        let h = s1 * s1 + cos(p1) * cos(p2) * s2 * s2
        // max(0, 1 - h) guards the antipodal rounding case where h creeps just past 1 and sqrt
        // would return NaN. It cannot trigger on real crumbs; it is here so it can never trigger.
        let c = 2.0 * atan2(sqrt(h), sqrt(max(0.0, 1.0 - h)))
        return Int(floor(earthRadiusM * c))
    }

    static func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Int {
        metres(a.latitude, a.longitude, b.latitude, b.longitude)
    }

    // MARK: - Constants
    //
    // Single source of truth, same names on both platforms. Nothing below may inline a literal.

    /// Three crumbs, not two. Two points is a there-and-back coincidence; three means the tag
    /// survived two separate 60 s plus 25 m gates while staying in range.
    static let minCrumbs = 3
    /// A crumb joins an existing anchor when it is STRICTLY inside this radius. Sized well above
    /// any plausible stack of urban GPS error so drift cannot manufacture a second "place", and
    /// wide enough that a market, a mall floor, or an office collapses to one anchor no matter how
    /// many crumbs pile up inside it.
    static let placeRadiusM = 250
    static let spanNearbyM = 500
    static let spanAcrossM = 1000
    static let elapsedNearbyS = 900        // 15 min: above a single trip leg, a lift to the shops
    static let elapsedAcrossS = 1800       // 30 min
    /// Mean seconds per crumb interval. This is what kills the commonest coincidence in the app:
    /// the same tag near home in the morning and near work at noon, which is two crumbs 10 km apart
    /// and would otherwise read as the strongest evidence on the screen.
    static let maxMeanGapS = 1200          // 20 min
    /// A separated tracker holds one address for about a day (IETF DULT), so a longer run is not
    /// one device and must not be narrated as one.
    static let maxElapsedS = 86400         // 24 h
    /// Slack on the clock-sanity test, absorbing sub-second rounding at each end of the window.
    static let clockSlackS = 5

    // MARK: - Places

    /// How many distinct places this tag was near us, by greedy anchoring.
    ///
    /// Order-dependent by construction: iterate the crumbs in STORED APPEND ORDER and stop at the
    /// first anchor within range. Both platforms must walk the same order and break the same way,
    /// or a route that doubles back can produce a different count on each phone.
    ///
    /// Kept separate from the span pass rather than derived from it, because the two numbers say
    /// different things. A diameter alone cannot tell a there-and-back between two points from a
    /// route through five, and "at 5 places" is the part a human can actually act on.
    static func places(_ crumbs: [CLLocationCoordinate2D]) -> Int {
        var anchors: [CLLocationCoordinate2D] = []
        for c in crumbs {
            var isNew = true
            for a in anchors where metres(a, c) < placeRadiusM { isNew = false; break }
            if isNew { anchors.append(c) }
        }
        return anchors.count
    }

    // MARK: - Span

    /// The DIAMETER of the crumb set: the largest distance between any two crumbs.
    ///
    /// Explicitly not the summed path length. Path length answers "how far did I walk while this
    /// was in range", which is a question about the user, not about the tag. The two split hard on
    /// exactly the cases that matter: an hour wandering a festival with a stranger's tag nearby
    /// drops a crumb every 25 m and totals kilometres of path while never leaving a 300 m circle.
    /// Path length calls that following. Diameter calls it one place, which is what it is.
    /// Someone who drives to work and back has a 16 km path and an 8 km diameter, so diameter
    /// loses nothing on the genuine round trip.
    ///
    /// Diameter is also invariant to crumb cadence, so a tag that advertised more often cannot
    /// out-score a quieter one on the same journey, and it degrades safely at the 120-crumb cap:
    /// dropping the oldest crumbs can only SHRINK a diameter, so a long run under-reports.
    ///
    /// O(n^2) with n <= 120 is 7140 flat haversines. That is nothing, but it must not land on the
    /// publish path anyway; see the throttle at the call site.
    static func span(_ crumbs: [CLLocationCoordinate2D]) -> Int {
        var best = 0
        guard crumbs.count >= 2 else { return best }
        for i in 0..<(crumbs.count - 1) {
            for j in (i + 1)..<crumbs.count {
                best = max(best, metres(crumbs[i], crumbs[j]))
            }
        }
        return best
    }

    // MARK: - Bands

    /// What the panel says. Four states, and the top one is still not an accusation.
    enum Band: Equatable {
        /// Scored, and the ground covered is not enough to read anything into. Also where a demo
        /// tracker lives forever, and where a run under minCrumbs lands.
        case none
        /// NOT scored, because the time record could not be trusted (see the refusals in `score`).
        /// Kept apart from `none` because they are opposite claims: none is a finding, this is the
        /// absence of one, and reporting a refusal as a finding states something the scorer never
        /// computed and sometimes the reverse of the truth. A device whose stamps are nonsense can
        /// perfectly well have been across five places with you.
        case notMeasured
        /// "near you more than once".
        case nearby
        /// "near you in several places".
        case across
    }

    /// The scored result. Carries the intermediates as well as the band so the parity fixtures can
    /// pin the arithmetic and not just its conclusion: a band that comes out right off two wrong
    /// numbers is the failure mode a same-value assertion would sail straight past.
    struct Score: Equatable {
        /// False when the device could not be scored at all (wrong type, derived time, too few
        /// crumbs, clock jump, absurd window). Kept distinct from `band == .none` because those
        /// are different claims: none means "scored, nothing to say", ineligible means "not
        /// scored". The BAND is now what the UI reads: an ineligible row is either .none, which
        /// still carries the honest "not across enough ground yet" sentence, or .notMeasured,
        /// which must not. This flag stays because the fixtures assert it and because "was this
        /// arithmetic actually run" is a different question from "what does the panel say".
        let eligible: Bool
        let band: Band
        let places: Int
        let span: Int
        let elapsedS: Int
        let meanGapS: Int

        static let unscored = Score(eligible: false, band: .none, places: 0, span: 0,
                                    elapsedS: 0, meanGapS: 0)
        /// A refusal. Every intermediate is zero deliberately: nothing was measured, so publishing
        /// a half-computed elapsed or span would invite exactly the sentence this state exists to
        /// prevent.
        static let notMeasured = Score(eligible: false, band: .notMeasured, places: 0, span: 0,
                                       elapsedS: 0, meanGapS: 0)
    }

    /// Score one device from data that already exists. No side effects, no clock read: `elapsed` is
    /// derived from the two stamps handed in, so the same inputs always produce the same answer.
    ///
    /// BOTH STAMPS ARE CRUMB STAMPS. The opening one used to be firstSeenDate(for:), i.e. when the
    /// device was first HEARD, and that was wrong in a way the panel could not walk back: crumbs
    /// begin at the first fresh fix after the sighting and die with the session, while firstSeenAt
    /// is persisted across launches. The sentence therefore narrated a duration the trail did not
    /// cover, and the band time floors (900 s / 1800 s) could be cleared entirely by time with no
    /// crumbs in it - a tag heard yesterday and crumbed three times in one minute today read as a
    /// day-long run. The parameter is RENAMED rather than quietly repointed so no call site can
    /// keep passing the old instant unnoticed.
    ///
    /// - Parameters:
    ///   - crumbs: snapshot copy from BLEManager.crumbTrail(for:), in stored append order.
    ///   - firstCrumbAt: BLEManager.firstCrumbAt(for:). The start of the CRUMB window.
    ///   - lastCrumbAt: BLEManager.lastCrumbAt(for:). The end of the crumb window.
    ///   - basis: BLEManager.timeBasis(for:). Must be .exact.
    ///   - type: the row's type. Must be .tracker.
    static func score(crumbs: [CLLocationCoordinate2D],
                      firstCrumbAt: Date?,
                      lastCrumbAt: Date?,
                      basis: TimeBasis,
                      type: DeviceType) -> Score {
        let n = crumbs.count

        // THE GUARD ORDER BELOW IS PART OF THE CONTRACT, not an implementation detail, and Kotlin's
        // evaluate() runs it in exactly this sequence. Several of these can hold at once and they
        // return different sentences, so a reordering is a silent parity break: the tour's sample
        // tracker has zero crumbs AND no stamps, and it must land on none (a demo is not a broken
        // record), which only happens while the crumb floor is tested before the stamps.

        // Stated even though the crumb gate already guarantees it. This reads as a scorer on its
        // own, and if a later change ever widens crumb collection past trackers, that change has to
        // come through here and argue with this line rather than quietly start scoring body cams.
        // .notMeasured: a body cam was never compared against anything, so it has no finding.
        guard type == .tracker else { return .notMeasured }
        // STALE RATIONALE CORRECTED. This used to be arithmetic self-defence: the opening stamp was
        // firstSeenDate, and a row first heard off the board's offline buffer carries a firstSeen
        // on the HIST_PSEUDO_BASE pseudo-time axis just above the epoch, so `elapsed` came out in
        // decades. Both stamps are crumb stamps now, and crumbs are only ever appended on the LIVE
        // filing path, so that arithmetic hazard is gone. The guard stays for a different and still
        // good reason: a replayed row's crumbs are not its own, so scoring it would narrate ground
        // this device was never observed covering. Accepted miss: a tag
        // that was replayed AND THEN rode with us live is never scored. A wrong duration is worse
        // than no duration in a product whose entire discipline is under-claiming.
        // .notMeasured, not .unscored: nothing was compared here, and saying "not across enough
        // ground" about a comparison that never ran is a claim, not a hedge, and for a tag that
        // really did ride along for an hour it is the exact opposite of the truth.
        guard basis == .exact else { return .notMeasured }
        // The ONE refusal that keeps the none sentence, because there it is literally true: the
        // crumbs are real, the comparison did run over them, there are simply fewer than three.
        guard n >= minCrumbs else { return .unscored }
        // Unreachable in practice (the manager writes both stamps in the branch that appends a
        // crumb, so n >= 3 implies both exist), which is exactly why a missing one is a broken
        // record rather than an empty result.
        guard let first = firstCrumbAt, let last = lastCrumbAt else { return .notMeasured }

        let elapsed = Int(last.timeIntervalSince(first))
        // Both stamps come off the wall clock, and a wall clock jumps (NTP correction, manual set,
        // timezone-less date change). The append gate guarantees at least 60 s between crumbs, so
        // an elapsed shorter than (n-1) * 60 is not a fast tag, it is a moved clock. Refusing to
        // score is the only honest response: the geometry may be real but the duration in the
        // sentence would be a fiction. So the panel must say the clock was unusable, NOT that
        // nothing was found.
        //
        // Measured from the FIRST CRUMB this bound is exact rather than merely safe: the window now
        // spans precisely the n-1 intervals the gate enforced. (At the manager's 120-crumb cap it
        // loosens again, because firstCrumbAt outlives the oldest crumbs that get trimmed. Stated
        // limit, accepted: it can only make this test easier to pass, never harder, and a trimmed
        // run is at least two hours long.)
        guard elapsed + clockSlackS >= (n - 1) * 60 else { return .notMeasured }
        guard elapsed <= maxElapsedS else { return .notMeasured }

        let p = places(crumbs)
        let s = span(crumbs)
        // A MEAN, not a max, because there are no per-crumb timestamps and this feature adds no
        // storage. Known limit, accepted: one long silence inside an otherwise dense run still
        // passes. A dense run really is alongside you, and the case the mean DOES catch is the
        // important one, two encounters hours apart with nothing between them.
        // n >= minCrumbs, so the divisor is at least 2.
        let gap = elapsed / (n - 1)

        // First match wins, strongest first.
        if p >= 3 && s >= spanAcrossM && elapsed >= elapsedAcrossS && gap <= maxMeanGapS {
            return Score(eligible: true, band: .across, places: p, span: s,
                         elapsedS: elapsed, meanGapS: gap)
        }
        if p >= 2 && s >= spanNearbyM && elapsed >= elapsedNearbyS && gap <= maxMeanGapS {
            return Score(eligible: true, band: .nearby, places: p, span: s,
                         elapsedS: elapsed, meanGapS: gap)
        }
        return Score(eligible: true, band: .none, places: p, span: s,
                     elapsedS: elapsed, meanGapS: gap)
    }

    // MARK: - Numbers to words
    //
    // All integer arithmetic, built by hand. NOT String(format:) and no float rendering anywhere:
    // Kotlin's String.format is locale-sensitive and prints "2,2 km" in de-DE while iOS prints
    // "2.2 km", which is a parity break that no test on either platform alone would ever show.
    // Int division truncates toward zero in both languages and every value here is non-negative,
    // so truncation and floor agree.

    /// "650 m" under a kilometre (nearest 50 m), "2.2 km" over it (nearest 100 m).
    /// The rounding is coarse because the underlying quantity is: these are GPS fixes taken from a
    /// pocket, and printing a span to the metre would dress an estimate up as a measurement.
    static func spanText(_ m: Int) -> String {
        if m < 1000 {
            let r = max(50, ((m + 25) / 50) * 50)
            return "\(r) m"
        }
        let t = (m + 50) / 100          // tenths of a km, half up
        let whole = t / 10, tenth = t % 10
        return tenth == 0 ? "\(whole) km" : "\(whole).\(tenth) km"
    }

    /// "20 minutes" under 90, "2.5 hours" over it. Both band floors are 900 s, so the minutes form
    /// can never come out singular and there is no pluralization branch to get wrong. Half hours
    /// are FLOORED so the sentence never overstates how long the tag was around.
    static func durationText(_ s: Int) -> String {
        if s < 5400 { return "\(s / 60) minutes" }
        let h2 = s / 1800               // half hours
        let whole = h2 / 2, half = h2 % 2
        return half == 0 ? "\(whole) hours" : "\(whole).5 hours"
    }

    /// The evidence fragment shared by both firing bands: "3 places, about 650 m apart, over 20
    /// minutes". Both bands require places >= 2, so "places" is always plural.
    static func detailText(_ s: Score) -> String {
        "\(s.places) places, about \(spanText(s.span)) apart, over \(durationText(s.elapsedS))"
    }

    // MARK: - Copy
    //
    // Every string the panel can show lives here, so the two platforms diff as data rather than as
    // view code. No em-dashes anywhere, per the house style.

    /// Header above a firing band, and ONLY there. Never over none, never over not-measured, never
    /// over the two no-crumb states: a header that asserts something the body then walks back is
    /// worse than no header, and over a refusal it would be a header over nothing at all.
    static let kicker = "SEEN WITH YOU"

    /// The last line of EVERY state, bands and no-crumb states alike. Crumbs are session-only and
    /// never persisted (both apps drop them on reset), so the panel must not imply a longer memory
    /// than the app actually has, and it must not let its absence from a body cam screen read as
    /// "checked, nothing found there either".
    ///
    /// It used to be printed only where a band had fired, on the reasoning that the empty states
    /// had nothing to scope. That was backwards. The no-crumb states are exactly where the user
    /// needs to be told the memory is session-scoped: after a restart the crumbs are gone while the
    /// row is not, so the panel is standing in front of a tag it genuinely cannot speak about, and
    /// the one sentence that explains why was the one being withheld.
    static let scopeLine = "Counted this session only, and only for trackers. "
        + "Nothing about this is kept when the session ends."

    /// Band label, plain body text at the call site. Deliberately NOT routed through Kicker: a
    /// casing transform is one more thing that can drift between the platforms.
    static func label(_ band: Band) -> String? {
        switch band {
        case .none:        return nil
        case .notMeasured: return nil   // a refusal gets no header; there is nothing to head
        case .nearby:      return "near you more than once"
        case .across:      return "near you in several places"
        }
    }

    /// The sentence under the label. Each firing band names its own innocent explanations in the
    /// same breath as its numbers, because that is the only defence this feature has: no threshold
    /// can separate a stalker from a fellow commuter carrying a Tile, and pretending otherwise is
    /// how a safety product loses the user's trust in everything else it says.
    static func body(_ s: Score) -> String {
        switch s.band {
        case .none:
            return "It has been near you, but not across enough ground to read anything into yet."
        case .notMeasured:
            // Single-sourced with the state the panel renders directly, so the two can never drift
            // into two different sentences for one situation.
            return notMeasuredLine
        case .nearby:
            return "It was near you at \(detailText(s)). "
                + "That also fits a neighbour, a shared ride, or a tag of your own."
        case .across:
            return "It was near you at \(detailText(s)). Worth knowing what it is. "
                + "Someone travelling the same way looks exactly like this from here."
        }
    }

    /// Shown instead of a band when there are no crumbs because location is not running. Naming
    /// the reason matters: an empty panel would read as "we looked and found nothing".
    static let noLocationLine =
        "beacons is not using location, so it cannot tell whether this tag moved with you."

    /// Shown instead of a band when location IS authorized but the app holds no position for this
    /// tag: no fix was ever fresh enough while it was around (both platforms require a fix under
    /// 2 minutes old), OR the crumbs existed and the session ended.
    ///
    /// The wording describes THE APP'S OWN LEDGER, not the world, and that is the whole point. The
    /// old line said there was no usable position while the tag was around, which is a claim about
    /// what happened. After a restart it was false: the row is persisted and the crumbs are not, so
    /// every tracker on the screen asserted that no position had existed when in fact one had and
    /// the app had simply dropped it. "No position was recorded" is true in the genuine stale-fix
    /// case and true in the restored-row case, and the scope line under it now says which.
    static let noFixLine =
        "No position was recorded alongside this tag this session, so there is nothing to compare."

    /// Shown for the refusals: a derived time basis, a clock that jumped, or a window longer than
    /// an address lives. Says what was NOT DONE rather than what was not found, in the same
    /// register as the two no-crumb lines above, because that is the honest shape of it. The old
    /// behaviour printed the none sentence here, so a device the scorer had explicitly declined to
    /// score came back as a device it had scored and cleared.
    static let notMeasuredLine =
        "There is no reliable time record for this tag, so it was not compared against where you "
        + "have been."
}
