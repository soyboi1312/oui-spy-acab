import Foundation

/// The bundled Help + FAQ content: an offline copy of soyboi.tech/faq that ships inside the app
/// binary. No webview, no fetch, no analytics on any help surface, which is the same no-cloud
/// stance as the rest of the product: opening Help must not tell anyone that you opened Help.
///
/// WHY THIS PARSES JSON INSTEAD OF BEING A SWIFT LITERAL. The answers have to
/// read identically on iOS and Android. Transcribing them into a Swift enum and a Kotlin object is
/// two hand-maintained copies of the same prose, and cross-platform copy drift is the single most
/// recurring defect class in this repo. So one file, `faq-content.json`, is copied verbatim into
/// both app resource trees and parsed at runtime, and `check-signature-drift.py` asserts the two
/// copies are byte-identical , the same guard the vendored opendroneid decoder already uses. A
/// content edit is then one file plus one drift check, and the two apps cannot disagree.
///
/// Content updates ride app releases. That is deliberate: an answer that can change under you
/// without a release is an answer nobody can audit, and "FAQ online" in the support card is the
/// escape hatch for anything newer.
struct FAQContent: Decodable {
    struct Question: Decodable, Identifiable, Hashable {
        let id: String          // stable, e.g. "q-airtag" - the deep-link key, do not renumber
        let q: String
        let a: String
    }
    struct Section: Decodable, Identifiable {
        let kicker: String      // already uppercase in the JSON; rendered through Kicker as-is
        let questions: [Question]
        var id: String { kicker }
    }
    /// A row in the SUPPORT card. Exactly one of `url` / `action` is present: `url` opens outward
    /// (browser or mail), `action` is an in-app route. Decoding both as optional keeps the JSON
    /// the source of truth for which rows exist, so adding one is a content edit, not a code edit.
    struct SupportRow: Decodable, Identifiable {
        let title: String
        let sub: String
        let url: String?
        let action: String?
        let external: Bool
        var id: String { title }
    }

    let sections: [Section]
    /// DeviceType raw name -> question ids, for the dossier's RELATED HELP panel. Keyed by the
    /// SCREAMING_CASE names the Android enum uses, because the JSON is shared; the iOS lookup
    /// maps its own DeviceType onto these keys (see `related(for:)`).
    let relatedHelp: [String: [String]]
    let support: [SupportRow]

    // MARK: load

    /// Parsed once. A failure here is a build/packaging mistake (the JSON is bundled, not fetched),
    /// so it degrades to empty rather than trapping: a Help screen with no answers is bad, an app
    /// that crashes opening Help is worse, and the SUPPORT card still gets the user to a human.
    static let shared: FAQContent = {
        guard let url = Bundle.main.url(forResource: "faq-content", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(FAQContent.self, from: data) else {
            return FAQContent(sections: [], relatedHelp: [:], support: [])
        }
        return parsed
    }()

    /// Every question, flattened, with its section kicker , the search index and the deep-link
    /// resolver. Order follows the sections so results read in the same order as the page.
    var allQuestions: [(section: String, question: Question)] {
        sections.flatMap { s in s.questions.map { (s.kicker, $0) } }
    }

    func question(id: String) -> Question? {
        allQuestions.first { $0.question.id == id }?.question
    }

    /// Case-insensitive substring over question AND answer. Deliberately not fuzzy and not ranked:
    /// This set is small enough that a plain contains() never surprises anyone, and a clever
    /// matcher that silently drops a result is worse than a dumb one that does not.
    func search(_ query: String) -> [(section: String, question: Question)] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        return allQuestions.filter {
            $0.question.q.lowercased().contains(q) || $0.question.a.lowercased().contains(q)
        }
    }

    /// Question ids worth surfacing on a dossier for this device type. Every REAL faqKey now has a
    /// relatedHelp entry - GLASSES and BODY_CAM got theirs in the v2.0.5 apps release (3347a04),
    /// ending the earlier reserved-on-purpose state - and check-signature-drift.py derives the key
    /// list from both DeviceType enums and FAILS CI if a key loses its entry, so a new category's
    /// JSON row lands in the same commit as its enum case. [] comes back only for nearbyDevice
    /// and unknown, whose faqKey is "": neither is a category a user has a question about.
    func related(for type: DeviceType) -> [Question] {
        (relatedHelp[type.faqKey] ?? []).compactMap { question(id: $0) }
    }
}
