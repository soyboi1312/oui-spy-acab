package tech.acab.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.atomic.AtomicBoolean

/** Read an HTTP body with both declared-length and streaming ceilings. Null means refusal. */
internal fun readBoundedManifestBody(
    input: InputStream,
    declaredLength: Long,
    maxBytes: Int,
): ByteArray? {
    if (declaredLength > maxBytes || maxBytes <= 0) return null
    val out = ByteArrayOutputStream(
        if (declaredLength in 1..maxBytes.toLong()) declaredLength.toInt() else minOf(maxBytes, 16 * 1024),
    )
    val buf = ByteArray(8 * 1024)
    var total = 0
    while (true) {
        val read = input.read(buf)
        if (read < 0) break
        total += read
        if (total > maxBytes) return null
        out.write(buf, 0, read)
    }
    return out.toByteArray()
}

/** Firmware artifacts are intentionally confined to the product's exact HTTPS origin. */
internal fun trustedFirmwareArtifactUrl(raw: String): URL? = runCatching {
    URL(raw).takeIf { url ->
        url.protocol.equals("https", ignoreCase = true) &&
            url.host.equals("soyboi.tech", ignoreCase = true) &&
            url.userInfo == null && url.ref == null && url.port in setOf(-1, 443)
    }
}.getOrNull()

/** Redirects are refused even when their destination would otherwise be trusted. */
internal fun firmwareArtifactResponseAllowed(initial: URL, final: URL, statusCode: Int): Boolean =
    statusCode == HttpURLConnection.HTTP_OK &&
        trustedFirmwareArtifactUrl(initial.toExternalForm()) != null &&
        trustedFirmwareArtifactUrl(final.toExternalForm()) != null &&
        initial.toExternalForm() == final.toExternalForm()

/**
 * The co-processor half of a build entry, from builds[<label>].nrf. The nRF52840 runs the
 * Adafruit/Seeed bootloader, which speaks LEGACY Nordic DFU (service 0x1530), so what the
 * manifest publishes is an adafruit-nrfutil DFU .zip rather than a raw image. [version] is a
 * small monotonic int (NRF_APP_VERSION in the nRF firmware), NOT a semver string: the S3
 * reports the running value as "nrfv" and an update is offered when the manifest's is higher.
 */
data class NrfBuild(
    val version: Int,
    val ota: Boolean,
    val zipUrl: String,
    val sha256: String,
    val size: Long,
    val sig: String,
) {
    /** Same publication bar as the S3 image: a download URL, a published hash, a bounded size,
     *  and a signature. The app verifies the detached signature because the stock nRF bootloader
     *  cannot, so an unsigned package must never reach the hardware. */
    val hasVerifiableImage: Boolean get() =
        zipUrl.isNotEmpty() && sha256.isNotEmpty() && size in 1L..MAX_PACKAGE_BYTES && sig.isNotEmpty()

    companion object {
        const val MAX_PACKAGE_BYTES = 4L * 1024 * 1024
    }
}

/**
 * One firmware build's entry from the manifest. Keys mirror the JSON at
 * https://soyboi.tech/firmware/firmware-latest.json under builds[<fw label>].
 */
data class FirmwareBuild(
    val version: String,
    val ota: Boolean,
    val appUrl: String,
    val sha256: String,
    val size: Long,
    val sig: String,
    val flasher: String,
    val notes: String,
    /** null when the entry publishes no co-processor package (every non-beacon board). */
    val nrf: NrfBuild? = null,
    /** Exact builds-map key that selected this image. Empty only for the non-OTA fallback. */
    val manifestLabel: String = "",
) {
    /** True when the entry carries a downloadable, verifiable image: a non-empty download
     *  URL, a non-empty hash, a real size, and a non-empty ECDSA signature (hex DER over the
     *  image's SHA-256). A blank URL or hash, zero size, or a missing signature means "no
     *  verifiable image published yet", so in-app OTA is never offered off this entry even
     *  when ota == true. An unsigned image would be refused by the board's signature gate,
     *  so we never start such an update. */
    val hasVerifiableImage: Boolean get() =
        appUrl.isNotEmpty() && sha256.isNotEmpty() && size > 0 && sig.isNotEmpty()
}

/** The whole parsed manifest: a schema version, a fetched-at stamp, and one entry per fw label. */
data class FirmwareManifestData(
    val schema: Int,
    val updated: String,
    val builds: Map<String, FirmwareBuild>,
) {
    fun build(forFwLabel: String?): FirmwareBuild? =
        forFwLabel?.let { builds[it] }
}

/**
 * Fetches and caches the firmware manifest. The manifest is the source of truth for
 * "which version is current" and "can this board update in-app". Fetching is non-blocking
 * and failure-tolerant: a bad network or malformed JSON leaves the last-good cache (or the
 * baked-in fallback) in place, and never throws to the caller.
 *
 * Process-wide singleton so one fetch backs every screen. Collect [manifest] from the UI.
 */
class FirmwareManifest private constructor(context: Context) {

    private val prefs = context.applicationContext
        .getSharedPreferences("acab.firmware", Context.MODE_PRIVATE)

    private val _manifest = MutableStateFlow(loadCachedOrFallback())
    val manifest: StateFlow<FirmwareManifestData> = _manifest.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val fetching = AtomicBoolean(false)

    /** The current entry for a board's fw label (null when the manifest has none). */
    fun build(forFwLabel: String?): FirmwareBuild? = _manifest.value.build(forFwLabel)

    /** The current published version for a board's fw label, or null when unknown. Callers
     *  compare this to the installed version with their own numeric comparator. */
    fun latestVersion(forFwLabel: String?): String? =
        _manifest.value.build(forFwLabel)?.version

    /**
     * Refresh in the background if the cache is stale (older than [ttlMs]) or forced. Returns
     * immediately; the [manifest] flow updates if a good fetch lands. Safe to call on app
     * start and on every board connect; a fetch already in flight is not duplicated.
     */
    fun refresh(force: Boolean = false) {
        val age = System.currentTimeMillis() - prefs.getLong(KEY_FETCHED_AT, 0L)
        if (!force && age < TTL_MS) return
        if (!fetching.compareAndSet(false, true)) return
        scope.launch {
            try {
                val body = withContext(Dispatchers.IO) { httpGet(MANIFEST_URL) }
                val parsed = body?.let { runCatching { parse(it) }.getOrNull() }
                if (parsed != null) {
                    // Persist the raw body (last-good) and stamp it, then publish.
                    prefs.edit()
                        .putString(KEY_JSON, body)
                        .putLong(KEY_FETCHED_AT, System.currentTimeMillis())
                        .apply()
                    _manifest.value = parsed
                }
                // On any failure we simply keep the existing value: cache or fallback.
            } finally {
                fetching.set(false)
            }
        }
    }

    /**
     * Force a fetch past the TTL and suspend until it resolves, for the manual "check for
     * updates" control. Failure-tolerant like [refresh]: a bad network or malformed JSON
     * leaves the last-good cache (or fallback) in place and never throws. The [manifest] flow
     * updates in place if a good fetch lands, so callers can just re-read it afterward.
     */
    suspend fun refreshNow() {
        // Skip if a background fetch is already in flight; its result lands on the same flow.
        if (!fetching.compareAndSet(false, true)) return
        try {
            val body = withContext(Dispatchers.IO) { httpGet(MANIFEST_URL) }
            val parsed = body?.let { runCatching { parse(it) }.getOrNull() }
            if (parsed != null) {
                prefs.edit()
                    .putString(KEY_JSON, body)
                    .putLong(KEY_FETCHED_AT, System.currentTimeMillis())
                    .apply()
                _manifest.value = parsed
            }
        } finally {
            fetching.set(false)
        }
    }

    private fun loadCachedOrFallback(): FirmwareManifestData {
        val raw = prefs.getString(KEY_JSON, null)
        if (raw != null) runCatching { return parse(raw) }
        return FALLBACK
    }

    companion object {
        private const val MANIFEST_URL = "https://soyboi.tech/firmware/firmware-latest.json"
        private const val KEY_JSON = "manifestJson"
        private const val KEY_FETCHED_AT = "manifestFetchedAt"
        private const val TTL_MS = 6L * 60 * 60 * 1000   // ~6 hours
        private const val MAX_MANIFEST_BYTES = 256 * 1024

        @Volatile private var INSTANCE: FirmwareManifest? = null

        fun getInstance(context: Context): FirmwareManifest =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: FirmwareManifest(context.applicationContext).also { INSTANCE = it }
            }

        /**
         * Baked-in fallback, used only when there is no cache and no network yet. Mirrors the
         * hardcoded LATEST the app shipped with, so the "update available" nudge still works
         * offline. Deliberately marks nothing OTA-capable and carries no image, so a cold,
         * offline start can only ever point at the browser flasher, never at an unverified
         * in-app download.
         */
        private val FALLBACK = FirmwareManifestData(
            schema = 1,
            updated = "",
            builds = mapOf(
                "beacon board" to FirmwareBuild(
                    version = "2.0.5", ota = false, appUrl = "", sha256 = "", size = 0L, sig = "",
                    flasher = "https://soyboi.tech/flash.html", notes = "",
                ),
                // rev-B rides the beacon version line but flashes from its own page: its image
                // must never land on rev-A hardware, so the fallback must not point it at
                // flash.html. Matches the iOS fallback.
                "beacon board rev-B" to FirmwareBuild(
                    version = "2.0.5", ota = false, appUrl = "", sha256 = "", size = 0L, sig = "",
                    flasher = "https://soyboi.tech/flash-revb.html", notes = "",
                ),
                "ACAB-ouispy" to FirmwareBuild(
                    version = "2.0.5", ota = false, appUrl = "", sha256 = "", size = 0L, sig = "",
                    flasher = "https://soyboi1312.github.io/all-cameras-are-beacons/", notes = "",
                ),
                "mesh-detect-ACAB" to FirmwareBuild(
                    version = "2.0.5", ota = false, appUrl = "", sha256 = "", size = 0L, sig = "",
                    flasher = "https://soyboi1312.github.io/all-cameras-are-beacons/", notes = "",
                ),
                "mesh-detect-ACAB-ch1" to FirmwareBuild(
                    version = "2.0.5", ota = false, appUrl = "", sha256 = "", size = 0L, sig = "",
                    flasher = "https://soyboi1312.github.io/all-cameras-are-beacons/", notes = "",
                ),
            ),
        )

        /** Parse the manifest JSON. Throws on structurally-bad input (caught by the caller),
         *  including a schema we don't speak or an empty builds map - mirroring the iOS
         *  adoption gate, so a schema-2 or truncated publish never displaces the last-good
         *  cache here either. */
        private fun parse(raw: String): FirmwareManifestData {
            val root = JSONObject(raw)
            require(root.optInt("schema", 0) == 1) { "unsupported manifest schema" }
            val buildsObj = root.getJSONObject("builds")
            val builds = HashMap<String, FirmwareBuild>()
            val keys = buildsObj.keys()
            while (keys.hasNext()) {
                val label = keys.next()
                val b = buildsObj.getJSONObject(label)
                val app = b.optJSONObject("app")
                builds[label] = FirmwareBuild(
                    version = b.optString("version", ""),
                    ota = b.optBoolean("ota", false),
                    appUrl = app?.optString("url", "") ?: "",
                    sha256 = app?.optString("sha256", "")?.lowercase() ?: "",
                    size = app?.optLong("size", 0L) ?: 0L,
                    sig = app?.optString("sig", "")?.lowercase() ?: "",
                    flasher = b.optString("flasher", ""),
                    notes = b.optString("notes", ""),
                    nrf = b.optJSONObject("nrf")?.let { n ->
                        NrfBuild(
                            version = n.optInt("version", 0),
                            ota     = n.optBoolean("ota", false),
                            zipUrl  = n.optString("url", ""),
                            sha256  = n.optString("sha256", "").lowercase(),
                            size    = n.optLong("size", 0L),
                            sig     = n.optString("sig", "").lowercase(),
                        )
                    },
                    manifestLabel = label,
                )
            }
            require(builds.isNotEmpty()) { "manifest carries no builds" }
            return FirmwareManifestData(
                schema = 1,
                updated = root.optString("updated", ""),
                builds = builds,
            )
        }

        /** Plain HTTPS GET on the caller's thread. Returns the body, or null on any error. */
        private fun httpGet(url: String): String? {
            var conn: HttpURLConnection? = null
            return try {
                conn = (URL(url).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 8_000
                    readTimeout = 8_000
                    setRequestProperty("Accept", "application/json")
                }
                if (conn.responseCode != HttpURLConnection.HTTP_OK) return null
                val bytes = conn.inputStream.use { input ->
                    readBoundedManifestBody(input, conn.contentLengthLong, MAX_MANIFEST_BYTES)
                } ?: return null
                bytes.toString(Charsets.UTF_8)
            } catch (_: Exception) {
                null
            } finally {
                conn?.disconnect()
            }
        }
    }
}
