package tech.acab.app.model

import android.content.Context
import org.json.JSONObject

/**
 * The bundled Help + FAQ content: an offline copy of soyboi.tech/faq that ships inside the APK.
 * No webview, no fetch, no analytics on any help surface, which is the same no-cloud stance as the
 * rest of the product: opening Help must not tell anyone that you opened Help.
 *
 * WHY THIS PARSES JSON INSTEAD OF BEING A KOTLIN LITERAL. The answers have to
 * read identically on iOS and Android. Transcribing them into a Swift enum and a Kotlin object is
 * two hand-maintained copies of the same prose, and cross-platform copy drift is the single most
 * recurring defect class in this repo. So one file, `faq-content.json`, is copied verbatim into
 * both app resource trees and parsed at runtime, and `check-signature-drift.py` asserts the two
 * copies are byte-identical , the same guard the vendored opendroneid decoder already uses.
 *
 * Mirrors iOS FAQContent.swift: same JSON, same field names, same lookup semantics. Parsed with
 * org.json rather than a serialization library because it is one small file read once and the
 * project already avoids adding dependencies for things the platform does.
 *
 * Content updates ride app releases. That is deliberate: an answer that can change under you
 * without a release is an answer nobody can audit, and "FAQ online" in the support card is the
 * escape hatch for anything newer.
 */
data class FaqQuestion(val id: String, val q: String, val a: String)

data class FaqSection(val kicker: String, val questions: List<FaqQuestion>)

/**
 * A row in the SUPPORT card. Exactly one of [url] / [action] is non-null: [url] opens outward
 * (browser or mail), [action] is an in-app route. Both nullable keeps the JSON the source of truth
 * for which rows exist, so adding one is a content edit, not a code edit.
 */
data class FaqSupportRow(
    val title: String,
    val sub: String,
    val url: String?,
    val action: String?,
    val external: Boolean,
)

class FaqContent private constructor(
    val sections: List<FaqSection>,
    /**
     * DeviceType name -> question ids, for the dossier's RELATED HELP panel. Keyed by the
     * SCREAMING_CASE names this enum already uses; iOS maps its own DeviceType onto the same keys.
     */
    private val relatedHelp: Map<String, List<String>>,
    val support: List<FaqSupportRow>,
) {
    /** Every question, flattened, paired with its section kicker , the search index and the
     *  deep-link resolver. Order follows the sections so results read in page order. */
    val allQuestions: List<Pair<String, FaqQuestion>> =
        sections.flatMap { s -> s.questions.map { s.kicker to it } }

    fun question(id: String): FaqQuestion? = allQuestions.firstOrNull { it.second.id == id }?.second

    /**
     * Case-insensitive substring over question AND answer. Deliberately not fuzzy and not ranked:
     * This set is small enough that a plain contains() never surprises anyone, and a clever
     * matcher that silently drops a result is worse than a dumb one that does not.
     */
    fun search(query: String): List<Pair<String, FaqQuestion>> {
        val q = query.trim().lowercase()
        if (q.isEmpty()) return emptyList()
        return allQuestions.filter {
            it.second.q.lowercase().contains(q) || it.second.a.lowercase().contains(q)
        }
    }

    /**
     * Question ids worth surfacing on a dossier for this device type, or [] for the two types
     * with no faqKey (NEARBY_DEVICE and UNKNOWN, whose faqKey is ""). Every real key has an
     * entry, enforced by check-signature-drift.py; see [DeviceType.faqKey].
     */
    fun related(type: DeviceType): List<FaqQuestion> =
        (relatedHelp[type.faqKey] ?: emptyList()).mapNotNull { question(it) }

    companion object {
        @Volatile private var INSTANCE: FaqContent? = null

        /**
         * Parsed once. A failure here is a build/packaging mistake (the JSON is an asset, not a
         * fetch), so it degrades to empty rather than throwing: a Help screen with no answers is
         * bad, an app that crashes opening Help is worse, and the SUPPORT card still gets the user
         * to a human. Matches the iOS fallback exactly.
         */
        fun get(context: Context): FaqContent =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: load(context.applicationContext).also { INSTANCE = it }
            }

        private fun load(context: Context): FaqContent = try {
            val raw = context.assets.open("faq-content.json")
                .bufferedReader().use { it.readText() }
            val root = JSONObject(raw)

            val sections = ArrayList<FaqSection>()
            val sArr = root.optJSONArray("sections")
            for (i in 0 until (sArr?.length() ?: 0)) {
                val s = sArr!!.getJSONObject(i)
                val qs = ArrayList<FaqQuestion>()
                val qArr = s.optJSONArray("questions")
                for (j in 0 until (qArr?.length() ?: 0)) {
                    val q = qArr!!.getJSONObject(j)
                    qs.add(FaqQuestion(q.optString("id"), q.optString("q"), q.optString("a")))
                }
                sections.add(FaqSection(s.optString("kicker"), qs))
            }

            val related = HashMap<String, List<String>>()
            val rObj = root.optJSONObject("relatedHelp")
            for (key in rObj?.keys() ?: emptySet<String>().iterator()) {
                val arr = rObj!!.optJSONArray(key) ?: continue
                related[key] = (0 until arr.length()).map { arr.optString(it) }
            }

            val support = ArrayList<FaqSupportRow>()
            val supArr = root.optJSONArray("support")
            for (i in 0 until (supArr?.length() ?: 0)) {
                val r = supArr!!.getJSONObject(i)
                support.add(
                    FaqSupportRow(
                        title = r.optString("title"),
                        sub = r.optString("sub"),
                        // optString returns "" for a missing key, but these two are genuinely
                        // optional and "" would look like a real empty URL to the caller.
                        url = if (r.has("url") && !r.isNull("url")) r.optString("url") else null,
                        action = if (r.has("action") && !r.isNull("action")) r.optString("action") else null,
                        external = r.optBoolean("external", false),
                    )
                )
            }
            FaqContent(sections, related, support)
        } catch (_: Exception) {
            FaqContent(emptyList(), emptyMap(), emptyList())
        }
    }
}
