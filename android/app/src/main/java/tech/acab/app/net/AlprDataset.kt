package tech.acab.app.net

import android.content.Context
import android.util.AtomicFile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sqrt

private const val ALPR_TRUSTED_HOST = "soyboi.tech"
internal const val ALPR_TIER_LEGACY_FORMAT = 3
internal const val ALPR_MAX_DATASET_BYTES = 8L * 1024 * 1024

/** The privacy disclosure promises one static soyboi.tech download. Validate a parsed URL rather
 * than a string prefix, which accepts lookalikes such as soyboi.tech.evil.example. */
internal fun isTrustedAlprUrl(raw: String): Boolean = runCatching {
    val url = URL(raw)
    url.protocol.equals("https", ignoreCase = true) &&
        url.host.equals(ALPR_TRUSTED_HOST, ignoreCase = true) &&
        (url.port == -1 || url.port == 443) && url.userInfo == null
}.getOrDefault(false)

/** Resolve a relative or absolute redirect and apply the same host rule to the destination. */
internal fun trustedAlprRedirect(current: String, location: String): String? = runCatching {
    URL(URL(current), location).toString()
}.getOrNull()?.takeIf(::isTrustedAlprUrl)

/** Dataset freshness includes the content digest and parsed wire format, not only the display
 * date. ALP3 and ALP4 may be published on the same day; comparing only `updated` would strand an
 * installed ALP3 cache after the ALP4 manifest appears. */
internal fun alprCacheIsCurrent(
    manifestUpdated: String,
    manifestSha: String,
    expectedFormat: String,
    manifestFormat: String?,
    cachedUpdated: String?,
    cachedSha: String?,
    loadedFormat: String,
    hasNodes: Boolean,
): Boolean = hasNodes && manifestUpdated == cachedUpdated && manifestSha == cachedSha &&
    alprFormatMatches(expectedFormat, manifestFormat, loadedFormat)

/** Bind the parsed bytes to the selected versioned channel. V4 is a new contract and must declare
 * ALP4. The legacy V3 manifest may predate its optional format field, but may never declare a
 * different format. */
internal fun alprFormatMatches(
    expectedFormat: String,
    manifestFormat: String?,
    parsedFormat: String,
): Boolean {
    val declared = manifestFormat?.trim().orEmpty()
    if (!parsedFormat.equals(expectedFormat, ignoreCase = true)) return false
    return when {
        expectedFormat.equals("ALP4", ignoreCase = true) ->
            declared.equals("ALP4", ignoreCase = true)
        expectedFormat.equals("ALP3", ignoreCase = true) ->
            declared.isEmpty() || declared.equals("ALP3", ignoreCase = true)
        else -> false
    }
}

/** One atomic gate for load/fetch work. A request arriving as the active run releases the gate
 * must either reserve the next run or become that next run, never disappear between two atomics. */
internal class RestartableFetchGate {
    private var active = false
    private var restartRequested = false

    @Synchronized
    fun tryStart(rememberRestartIfBusy: Boolean): Boolean {
        if (!active) {
            active = true
            return true
        }
        if (rememberRestartIfBusy) restartRequested = true
        return false
    }

    /** Release the current run. A true result reserves the gate for exactly one immediate restart. */
    @Synchronized
    fun finish(restartAllowed: Boolean): Boolean {
        active = false
        val restart = restartRequested && restartAllowed
        restartRequested = false
        if (restart) active = true
        return restart
    }
}

/** The one blocking HttpURLConnection currently owned by [AlprStore]'s fetch gate.
 *
 * HttpURLConnection reads are not coroutine suspension points, so retiring a generation prevents
 * publication but does not stop bytes already crossing the network. The store removes this exact
 * connection/stream pair and aborts it on Dispatchers.IO when the layer is disabled.
 * Identity-aware [clear] matters for OFF -> ON: an old transfer's finally block must not clear a
 * replacement that has already registered after the restart handoff. */
internal class AbortableAlprTransfer {
    internal data class Active(
        val connection: HttpURLConnection,
        val stream: java.io.InputStream?,
    ) {
        /** disconnect first: some HttpURLConnection streams try to drain on close for socket
         * reuse, which is the opposite of a prompt user-requested abort. Closing afterwards still
         * wakes a custom/provider stream whose disconnect implementation does not own it. */
        fun abort() {
            runCatching { connection.disconnect() }
            runCatching { stream?.close() }
        }
    }

    private var active: Active? = null

    @Synchronized
    fun register(connection: HttpURLConnection): Boolean {
        if (active != null) return false
        active = Active(connection, null)
        return true
    }

    /** Attach the input stream after response headers arrive. False means disable already took
     * the connection; the caller must close the just-created stream and do no reading. */
    @Synchronized
    fun attachStream(connection: HttpURLConnection, stream: java.io.InputStream): Boolean {
        val current = active ?: return false
        if (current.connection !== connection) return false
        active = current.copy(stream = stream)
        return true
    }

    @Synchronized
    fun clear(connection: HttpURLConnection) {
        if (active?.connection === connection) active = null
    }

    @Synchronized
    fun takeForAbort(): Active? = active.also { active = null }
}

/** Optional manifest count, bounded to the parser's own row ceiling. */
internal fun parseAlprManifestCount(raw: Any): Int? {
    val number = raw as? Number ?: return null
    val value = number.toLong()
    if (number.toDouble() != value.toDouble()) return null
    return value.takeIf { it in 0 until 5_000_000L }?.toInt()
}

internal fun shouldFallbackToAlprV3(httpStatus: Int): Boolean =
    httpStatus == HttpURLConnection.HTTP_NOT_FOUND

internal fun isValidAlprManifestData(url: String, lowercaseSha256: String, size: Long): Boolean =
    isTrustedAlprUrl(url) && lowercaseSha256.length == 64 &&
        lowercaseSha256.all { it in "0123456789abcdef" } && size in 1..ALPR_MAX_DATASET_BYTES

/**
 * The "known ALPR cameras" map overlay , community-mapped license-plate-reader locations from
 * OpenStreetMap (the registry the DeFlock project maintains), shown as a quiet reference layer.
 *
 * PRIVACY: the phone downloads ONE static file from soyboi.tech and renders it locally. It never
 * queries Overpass, and the request contains no viewport or phone coordinate. The layer is ON by
 * default (most users would never find the toggle), and turning it off stops the fetch; a user's
 * explicit choice, either way, is stored and always wins over the default. This is scoped to the
 * optional dataset; map-tile requests go to their named provider separately.
 *
 * Wire format, little-endian. Four versions are accepted; the magic's last byte selects:
 *   "ALP1"  epochDay:u32 | count:u32 | count*(latE7:i32, lonE7:i32)
 *   "ALP2"  ...plus nMakers:u8 | nMakers*(len:u8, utf8) | count*(makerIdx:u8)
 *   "ALP3"  ...plus count*(tier:u8)
 *   "ALP4"  ...plus count*(osmType:u8, osmId:u64, sourceEpoch:u32,
 *                         directionCdeg:u16, checkDateDay:u32)
 * Each version is a strict prefix of the next, so the parser shares the coord and maker paths and
 * only appends a read. Maker table index 0 is always "" (unknown). A pre-ALP3 cache remains visible
 * under a distinct legacy-format sentinel rather than being assigned an attribution it never had.
 *
 * This build polls the V4 manifest first and falls back to V3 only while V4 is unpublished (404).
 * `alpr-latest.json` still serves ALP2 to the installed base and always will; see the manifest
 * constants below for why that split exists and cannot be collapsed.
 *
 * We hold coords as an interleaved IntArray [latE7, lonE7, ...] plus parallel makerIdx and
 * confirmed arrays, and the self-describing table. Cached to files/ for instant, offline redraw.
 */
class AlprStore private constructor(context: Context) {

    private val appContext = context.applicationContext
    private val prefs = appContext.getSharedPreferences("acab.alpr", Context.MODE_PRIVATE)
    private val cacheFile = File(appContext.filesDir, "alpr.bin")
    private val atomicCache = AtomicFile(cacheFile)

    /** ON by default. getBoolean's default only applies when no stored value exists, so a user
     *  who ever flipped the toggle keeps their choice; only fresh installs (and users who never
     *  touched it) pick up the new default. Mirrors iOS ALPRStore.enabled. */
    private val _enabled = MutableStateFlow(prefs.getBoolean(KEY_ENABLED, true))
    val enabled: StateFlow<Boolean> = _enabled.asStateFlow()

    /** Show non-tier-1 records, including tier 0, tier 2, and unknown legacy tier bytes. DEFAULT OFF.
     *
     *  These are the pins that get the APP blamed. A node with no manufacturer recorded is
     *  disproportionately a solar panel on a pole that someone marked in passing, and when a user
     *  drives to one and finds nothing there they conclude the detector is broken, not that an OSM
     *  contributor guessed. 8.1% of nodes across five metros, 22% in Chicago, so not a rounding
     *  error. Still DOWNLOADED and still counted in the manifest: hiding them is a display
     *  decision, deleting them would make the data-quality problem invisible rather than absent.
     *  Mirrors iOS ALPRStore.showUnverified. */
    private val _showUnverified = MutableStateFlow(prefs.getBoolean(KEY_SHOW_UNVERIFIED, false))
    val showUnverified: StateFlow<Boolean> = _showUnverified.asStateFlow()

    /** How many records are not tier 1 or the pre-tier legacy sentinel. A flow, not a scan: the
     * settings caption reads it on every recomposition and the array is six figures long. */
    private val _unverifiedCount = MutableStateFlow(0)
    val unverifiedCount: StateFlow<Int> = _unverifiedCount.asStateFlow()

    /** Interleaved latE7,lonE7 pairs. Empty until enabled + a dataset is present. */
    private val _nodes = MutableStateFlow(IntArray(0))
    val nodes: StateFlow<IntArray> = _nodes.asStateFlow()

    /** Per-node maker index into [makerTable] (0 = unknown), parallel to node count (= nodes.size/2).
     *  Plain @Volatile, not a flow: it only ever changes in the same parse as [_nodes], and the map
     *  overlay / detail screen read it right after observing a new nodes emission. */
    @Volatile var makerIdx: IntArray = IntArray(0); private set
    /** Self-describing maker names; index 0 is always "" (unknown). */
    @Volatile var makerTable: Array<String> = arrayOf(""); private set
    /** Compatibility display bit, parallel to the node count: true for tier 1 and for old formats
     * that had no tier block, false for ALP3/4 tiers 0 and 2. User-visible copy reads [rawTier],
     * because this Boolean cannot describe what the source actually encoded. */
    @Volatile var confirmed: BooleanArray = BooleanArray(0); private set
    /** Raw attribution tier, parallel to [confirmed]. ALP4 defines 0 as canonical without a
     * structured manufacturer, 1 as structured manufacturer attribution, and 2 as a legacy alias
     * candidate. The UI reads this rather than inventing an external verification claim. */
    @Volatile var rawTier: IntArray = IntArray(0); private set
    /** Wire format parsed from the cache currently backing [_nodes]. */
    @Volatile private var loadedFormat: String = ""

    /** True while ANY fetch is in flight, including the sub-second manifest freshness check.
     *  Drives the toggle's spinner, and suppresses the "couldn't load" hint so a first load
     *  never flashes a false error before the points arrive. */
    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()

    /** True only while the dataset BINARY is downloading/parsing. Narrower than [loading] on
     *  purpose: enabling an already-cached layer still runs a manifest check, so keying the
     *  legend's auto-expand off [loading] force-opened it on every enable and every launch. */
    private val _downloading = MutableStateFlow(false)
    val downloading: StateFlow<Boolean> = _downloading.asStateFlow()

    /** Manifest `updated` stamp of the dataset in hand. Seeded from prefs so the settings
     *  caption can show the cached dataset's date offline, before (or without) a fetch. */
    private val _updated = MutableStateFlow(prefs.getString(KEY_VERSION, null))
    val updated: StateFlow<String?> = _updated.asStateFlow()

    /** Epoch millis of the last COMPLETED manifest check (fresh download or confirmed-current),
     *  persisted so "checked 2h ago" survives relaunch. Null = never checked. */
    private val _lastChecked = MutableStateFlow(prefs.getLong(KEY_LAST_CHECKED, 0L).takeIf { it > 0L })
    val lastChecked: StateFlow<Long?> = _lastChecked.asStateFlow()

    /** How the most recent fetch ended, for the settings menu's transient outcome line. */
    private val _lastOutcome = MutableStateFlow<RefreshOutcome?>(null)
    val lastOutcome: StateFlow<RefreshOutcome?> = _lastOutcome.asStateFlow()

    /**
     * NOT_PUBLISHED is a 404 on the manifest, and it is deliberately NOT folded into FAILED. This
     * build polls its own manifest URL (see MANIFEST_URL), so between an app release and the
     * dataset being published there is a legitimate window where the file does not exist yet.
     * Reporting that as "check your connection" sends the user to debug a working network.
     * Mirrors iOS ALPRStore.RefreshOutcome.notPublished.
     */
    enum class RefreshOutcome { UPDATED, UP_TO_DATE, FAILED, NOT_PUBLISHED }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val fetchGate = RestartableFetchGate()
    private val activeTransfer = AbortableAlprTransfer()
    private val enableLock = Any()

    /** Last HTTP status seen by httpGet, so the manifest fetch can tell a 404 ("not published
     *  yet") from a dead network. Only read immediately after a failed manifest request; the
     *  one-fetch gate makes this instance field single-writer. */
    @Volatile private var lastStatus: Int = 0

    /** Bumped on every enable/disable. Work already in the air snapshots it and abandons itself if
     *  it moved, so a download that started before a disable can't spend the bandwidth, publish the
     *  points, or make a disabled layer visible again. Mirrors ALPRDataset.swift's enableGen. */
    @Volatile private var enableGen = 0

    /** True when [gen]'s work no longer speaks for the current enabled state. */
    private fun stale(gen: Int) = gen != enableGen || !_enabled.value

    init {
        if (_enabled.value) loadThenRefresh()
    }

    /** Turn the layer on (loads cache + downloads/freshens) or off (drops the in-memory points;
     *  the cache is kept so re-enabling is instant). Persists the choice, which from then on
     *  wins over the default. */
    fun setEnabled(on: Boolean) {
        var transferToAbort: AbortableAlprTransfer.Active? = null
        synchronized(enableLock) {
            if (on == _enabled.value) return
            _enabled.value = on
            prefs.edit().putBoolean(KEY_ENABLED, on).apply()
            enableGen++   // retire any load/fetch already running for the previous state
            if (on) {
                loadThenRefresh()
            } else {
                _nodes.value = IntArray(0)
                makerIdx = IntArray(0)
                makerTable = arrayOf("")
                confirmed = BooleanArray(0)
                rawTier = IntArray(0)
                loadedFormat = ""
                _unverifiedCount.value = 0
                // Remove the exact old connection while generation changes are still serialized.
                // The abort runs on IO after the lock: stream close can block, and the fetch
                // coroutine's finally path needs this lock to release the gate and honor a rapid
                // re-enable. Capturing the pair here means that re-enable can never retarget the
                // pending abort at its replacement connection.
                transferToAbort = activeTransfer.takeForAbort()
            }
        }
        transferToAbort?.let { transfer -> scope.launch { transfer.abort() } }
    }

    /** Toggle the unverified tier on the map. No refetch: the nodes are already loaded, this only
     *  changes what the overlay and [nearest] are willing to hand back. */
    fun setShowUnverified(on: Boolean) {
        if (on == _showUnverified.value) return
        _showUnverified.value = on
        prefs.edit().putBoolean(KEY_SHOW_UNVERIFIED, on).apply()
    }

    /** Freshen if the layer is on. Non-blocking, failure-tolerant. */
    fun refresh(force: Boolean = false) {
        val gen = synchronized(enableLock) {
            if (!_enabled.value) return
            if (!fetchGate.tryStart(rememberRestartIfBusy = false)) return
            // Flip loading SYNCHRONOUSLY on the caller's thread: the settings menu's "check for
            // updates" row keys its disabled/spinner state (and its wait-for-outcome effect) off
            // this flow, so it must read in-flight before the tap handler returns, not whenever
            // the IO coroutine gets scheduled.
            _loading.value = true
            enableGen
        }
        scope.launch {
            try {
                doFetch(gen)
            } finally {
                finishFetchAndRestartIfNeeded()
            }
        }
    }

    /** Disk load + network freshen, sequenced in ONE IO coroutine. Off the caller's thread:
     *  this is called from composition / a chip tap, and the synchronous ~1 MB readBytes +
     *  238k-int parse was a guaranteed main-thread hitch (and StrictMode DiskReadViolation)
     *  right on the Map tab transition. Sequencing load before fetch under the one [fetchGate]
     *  gate means doFetch's freshness check can never observe a not-yet-loaded empty array
     *  (and re-download a fresh cache), and a slow disk load can never land after, and
     *  clobber, a just-downloaded newer dataset. */
    private fun loadThenRefresh() {
        // A fetch already running is a real case, not a no-op: toggling the layer OFF and back ON
        // quickly bumps enableGen twice, so the in-flight run abandons itself (correctly) - but it
        // still holds [fetchGate], so this call used to return having done NOTHING, leaving the
        // layer switched on with an empty map and no retry until the next app launch. Remember the
        // request and let the finishing run honour it.
        val gen = synchronized(enableLock) {
            if (!_enabled.value) return
            if (!fetchGate.tryStart(rememberRestartIfBusy = true)) return
            enableGen
        }
        launchLoadThenRefresh(gen)
    }

    /** Launch after [fetchGate] has already been reserved, including a handoff restart. */
    private fun launchLoadThenRefresh(gen: Int) {
        scope.launch {
            try {
                loadFromDisk(gen)
                doFetch(gen)
            } finally {
                finishFetchAndRestartIfNeeded()
            }
        }
    }

    /** Release the one fetch gate and honor a re-enable that arrived during either kind of run.
     * This must be shared by refresh() and loadThenRefresh(): otherwise OFF then ON during a manual
     * refresh records a restart, but the manual path never consumes it and leaves an enabled,
     * empty layer until relaunch. */
    private fun finishFetchAndRestartIfNeeded() {
        // The eligibility read, gate release, and generation capture must be atomic with
        // setEnabled(), which records a busy-gate restart while holding this same lock. Otherwise
        // OFF -> ON can place restartRequested after a stale false read but before finish(false),
        // and finish would erase the only retry.
        val restartGen = synchronized(enableLock) {
            if (fetchGate.finish(restartAllowed = _enabled.value)) enableGen else null
        }
        restartGen?.let(::launchLoadThenRefresh)
    }

    private fun doFetch(gen: Int) {
        _loading.value = true
        var outcome = RefreshOutcome.FAILED
        try {
            // A reserved restart can be retired after it leaves the gate but before this IO
            // coroutine is scheduled. Do not make even the manifest request for that old state.
            if (stale(gen)) return
            // ALP4 rolls out on its own manifest so installed ALP3-only builds never receive a
            // body they reject. During the publish seam, fall back on 404 only; a transport or
            // integrity failure must not be hidden by silently switching datasets.
            var expectedFormat = "ALP4"
            var manifestRaw = httpGetText(MANIFEST_V4_URL, gen)
            if (manifestRaw == null && shouldFallbackToAlprV3(lastStatus)) {
                expectedFormat = "ALP3"
                manifestRaw = httpGetText(MANIFEST_V3_URL, gen)
            }
            if (manifestRaw == null) {
                // 404 means the dataset has not been published for this build's manifest yet,
                // which is a rollout state, not a fault. Anything else stays FAILED.
                if (lastStatus == HttpURLConnection.HTTP_NOT_FOUND) outcome = RefreshOutcome.NOT_PUBLISHED
                return
            }
            val m = JSONObject(manifestRaw)
            if (m.optInt("schema", 0) != 1) return
            val data = m.optJSONObject("data") ?: return
            val url = data.optString("url", "")
            val sha = data.optString("sha256", "").lowercase()
            val size = data.optLong("size", 0L)
            val manifestFormat = data.optString("format", "").trim().ifEmpty { null }
            val updated = m.optString("updated", "")
            if (!isValidAlprManifestData(url, sha, size)) return
            if (!alprFormatMatches(expectedFormat, manifestFormat, expectedFormat)) return
            val expectedCount = if (m.has("count") && !m.isNull("count")) {
                parseAlprManifestCount(m.get("count")) ?: return
            } else null
            // A valid manifest in hand = the freshness check completed; stamp it now so
            // "checked 2h ago" stays honest even if the download below fails.
            markChecked()
            // Already have this version loaded? Nothing to do.
            if (alprCacheIsCurrent(
                    updated,
                    sha,
                    expectedFormat,
                    manifestFormat,
                    prefs.getString(KEY_VERSION, null),
                    prefs.getString(KEY_SHA, null),
                    loadedFormat,
                    _nodes.value.isNotEmpty(),
                )) {
                _updated.value = updated
                outcome = RefreshOutcome.UP_TO_DATE
                return
            }
            // Disabled while the manifest was in the air: stop before the expensive part.
            if (stale(gen)) return
            // Past here we are committed to a real download, so the legend may auto-open to
            // surface the data credit. Everything above was a freshness check.
            _downloading.value = true
            try {
                val bytes = httpGetBytes(url, size, gen) ?: return
                if (bytes.size.toLong() != size) return
                if (sha256Hex(bytes) != sha) return
                val parsed = parse(bytes) ?: return
                if (!alprFormatMatches(expectedFormat, manifestFormat, parsed.wireFormat)) return
                if (expectedCount != null && expectedCount != parsed.rawCount) return
                // Catch a disable before the durable write. Publication gets another atomic
                // generation check below because the flush itself can take time.
                if (stale(gen)) return
                writeCacheAtomically(bytes)
                // AtomicFile can still spend time flushing after the check above. The cache is
                // intentionally retained across a disable, but never republish it into a disabled
                // map if the user switched the layer off during that write.
                synchronized(enableLock) {
                    if (stale(gen)) return
                    prefs.edit().putString(KEY_VERSION, updated).putString(KEY_SHA, sha).apply()
                    makerIdx = parsed.makerIdx         // set BEFORE the nodes emit so a collector
                    makerTable = parsed.table          // waking on new nodes sees matching makers
                    rawTier = parsed.rawTier            // raw semantics before the nodes emission
                    confirmed = parsed.confirmed       // same ordering rule: tiers land before nodes
                    loadedFormat = parsed.wireFormat   // format belongs to this publication
                    _unverifiedCount.value = parsed.confirmed.count { !it }
                    _nodes.value = parsed.coords
                    _updated.value = updated
                }
                outcome = RefreshOutcome.UPDATED
            } finally {
                _downloading.value = false
            }
        } catch (_: Exception) {
            // keep whatever we already have
        } finally {
            // outcome BEFORE loading, so an observer waking on loading=false reads the
            // verdict of THIS fetch, never the previous one's
            _lastOutcome.value = outcome
            _loading.value = false
        }
    }

    private fun markChecked() {
        val now = System.currentTimeMillis()
        prefs.edit().putLong(KEY_LAST_CHECKED, now).apply()
        _lastChecked.value = now
    }

    private fun loadFromDisk(gen: Int) {
        val bytes = runCatching {
            atomicCache.openRead().use { input ->
                if (input.channel.size() !in 1..ALPR_MAX_DATASET_BYTES) {
                    throw java.io.IOException("ALPR cache is outside the byte limit")
                }
                readBounded(input, ALPR_MAX_DATASET_BYTES, "ALPR cache")
            }
        }.getOrNull() ?: return
        val parsed = parse(bytes) ?: return
        // Re-check after the read: the load is async now, and a quick toggle-on/off must not
        // leave ~1 MB of nodes resident while the layer is off (turning off drops the points).
        synchronized(enableLock) {
            if (stale(gen)) return
            makerIdx = parsed.makerIdx
            makerTable = parsed.table
            rawTier = parsed.rawTier
            confirmed = parsed.confirmed
            loadedFormat = parsed.wireFormat
            _unverifiedCount.value = parsed.confirmed.count { !it }
            _nodes.value = parsed.coords
        }
    }

    /** A process death must leave either the old complete cache or the new complete cache, never a
     * truncated base file that is mistaken for a durable download. */
    private fun writeCacheAtomically(bytes: ByteArray) {
        val output = atomicCache.startWrite()
        try {
            output.write(bytes)
            atomicCache.finishWrite(output)
        } catch (e: Exception) {
            atomicCache.failWrite(output)
            throw e
        }
    }

    private fun httpGetText(url: String, gen: Int): String? = httpGet(url, gen) {
        readBounded(it, MAX_MANIFEST_BYTES, "ALPR manifest").decodeToString()
    }

    /** Stream-read with a bounded loop (AND-SEC-2), aborting once the total exceeds the
     * manifest-declared size (hard-capped at 8 MB), so a misconfigured/compromised server cannot
     * OOM the app before the size + SHA gate runs. */
    private fun httpGetBytes(url: String, declaredSize: Long, gen: Int): ByteArray? {
        if (declaredSize !in 1..ALPR_MAX_DATASET_BYTES) return null
        return httpGet(url, gen) { input ->
            readBounded(input, declaredSize, "ALPR dataset")
        }
    }

    /** One trusted, redirect-bounded HTTP read belonging to [gen]. Registration and disable are
     * serialized by [enableLock], closing the race where a connection could be created just after
     * setEnabled(false) looked for one to abort. The blocking input-stream read is deliberately
     * outside the lock; disable takes this exact connection/stream pair out of [activeTransfer]
     * and aborts it on IO, which wakes the read and lets the fetch gate perform its normal restart
     * handoff. */
    private fun <T> httpGet(url: String, gen: Int, read: (java.io.InputStream) -> T): T? {
        if (!isTrustedAlprUrl(url)) return null
        var current = url
        var redirects = 0
        while (true) {
            var conn: HttpURLConnection? = null
            try {
                val connection = (URL(current).openConnection() as HttpURLConnection).apply {
                    requestMethod = "GET"
                    connectTimeout = 8_000
                    readTimeout = 30_000
                    instanceFollowRedirects = false
                }
                conn = connection
                val registered = synchronized(enableLock) {
                    !stale(gen) && activeTransfer.register(connection)
                }
                if (!registered) return null

                val status = connection.responseCode
                lastStatus = status
                if (status in setOf(
                        HttpURLConnection.HTTP_MOVED_PERM,
                        HttpURLConnection.HTTP_MOVED_TEMP,
                        HttpURLConnection.HTTP_SEE_OTHER,
                        307, 308)) {
                    if (redirects++ >= MAX_REDIRECTS) return null
                    val location = connection.getHeaderField("Location") ?: return null
                    current = trustedAlprRedirect(current, location) ?: return null
                    continue
                }
                if (status != HttpURLConnection.HTTP_OK) return null
                val input = connection.inputStream
                if (!activeTransfer.attachStream(connection, input)) {
                    // Disable won the race after inputStream was obtained but before attachment.
                    runCatching { input.close() }
                    return null
                }
                return input.use(read)
            } catch (_: Exception) {
                lastStatus = 0          // transport/validation failure, not an HTTP status
                return null
            } finally {
                conn?.let {
                    activeTransfer.clear(it)
                    it.disconnect()
                }
            }
        }
    }

    /** Nearest mapped camera to (lat, lon) for the detail screen's "matches a mapped camera" line.
     *  ~2km bounding-box prefilter keeps it cheap over the full set; equirectangular distance is
     *  accurate to well under 1% at these ranges. On-device only. null when the box is empty. */
    // Coordinates here are range-guaranteed: parse() drops anything outside +/-90 / +/-180
    // before it ever reaches this array, so no consumer re-checks. If a SECOND ingest path is
    // ever added (bundled seed data, an import), it has to apply the same gate.
    data class NearestMatch(val meters: Double, val maker: String, val rawTier: Int)

    fun nearest(lat: Double, lon: Double): NearestMatch? {
        val nd = _nodes.value; if (nd.isEmpty()) return null
        val idx = makerIdx; val tbl = makerTable; val conf = confirmed; val tiers = rawTier
        // Never corroborate a detection against a node the user cannot see on the map. Vouching for
        // a hit using evidence we have decided is untrustworthy is worse than staying quiet.
        val skipUnverified = !_showUnverified.value
        val box = 0.02; val cosLat = cos(lat * PI / 180)
        var bestM = Double.MAX_VALUE; var bestMaker = ""; var bestTier = 1
        var i = 0
        while (i + 1 < nd.size) {
            val la = nd[i] / 1e7; val lo = nd[i + 1] / 1e7
            val node = i / 2; i += 2
            if (abs(la - lat) > box || abs(lo - lon) > box) continue
            val tier = tiers.getOrElse(node) { if (node < conf.size && conf[node]) 1 else 0 }
            if (skipUnverified && tier != 1 && tier != ALPR_TIER_LEGACY_FORMAT) continue
            val dLat = (la - lat) * 111_320; val dLon = (lo - lon) * 111_320 * cosLat
            val m = sqrt(dLat * dLat + dLon * dLon)
            if (m < bestM) {
                bestM = m
                bestMaker = if (node < idx.size) tbl.getOrElse(idx[node]) { "" } else ""
                bestTier = tier
            }
        }
        return if (bestM < Double.MAX_VALUE) NearestMatch(bestM, bestMaker, bestTier) else null
    }

    companion object {
        /** Versioned manifests are deliberately separate. An older exact-length parser must never
         * receive a newer body; this build tries V4, then falls back to V3 only while V4 is 404.
         *
         * The V3 manifest is itself separate from the original ALP2 URL:
         *  alpr-latest.json still serves ALP2 and always will: an already-installed app
         *  exact-length-checks the binary and REJECTS an ALP3 file outright rather than ignoring
         *  the tail, and its reject path returns before it stamps KEY_VERSION, so it would
         *  re-download and re-fail forever with a map frozen at the last good dataset. Pointing new
         *  builds at their own manifest means the rollout cannot break the installed base whatever
         *  order the stores approve things in. Keep in lockstep with iOS ALPRStore.manifestURL and
         *  the generator's dual-publish block (soyboi.tech/tools/build_alpr_dataset.py). */
        private const val MANIFEST_V4_URL = "https://soyboi.tech/data/alpr-v4-latest.json"
        private const val MANIFEST_V3_URL = "https://soyboi.tech/data/alpr-v3-latest.json"
        private const val KEY_ENABLED = "enabled"
        private const val KEY_SHOW_UNVERIFIED = "show_unverified"
        private const val KEY_VERSION = "version"
        private const val KEY_SHA = "sha256"
        private const val KEY_LAST_CHECKED = "last_checked"

        @Volatile private var INSTANCE: AlprStore? = null
        fun getInstance(context: Context): AlprStore =
            INSTANCE ?: synchronized(this) {
                INSTANCE ?: AlprStore(context.applicationContext).also { INSTANCE = it }
            }

        /** ALP4 source metadata retained in row order even though the current map does not render
         * it yet. Unsigned wire fields stay unsigned so a future consumer never inherits a signed
         * reinterpretation from this parser boundary. */
        internal data class SourceMetadata(
            val osmType: Int,
            val osmId: ULong,
            val sourceEpoch: Long?,
            val directionCdeg: Int?,
            val checkDateDay: Long?,
        )

        /** Parsed dataset: coordinates and every parallel block. rawTier preserves ALP4 tier 2
         * and the pre-tier legacy sentinel; confirmed is only a compatibility display bit. */
        internal class Parsed(val wireFormat: String, val rawCount: Int, val coords: IntArray,
                            val makerIdx: IntArray, val table: Array<String>,
                            val confirmed: BooleanArray, val rawTier: IntArray,
                            val metadata: Array<SourceMetadata?>)

        /** Parse ALP4 (coords + maker + tier + stable source metadata). Also accepts legacy ALP3,
         *  ALP2 and ALP1, so a cache from an
         *  older build still loads. Bounds-checked throughout; returns null on any malformation
         *  (bad length, a table that runs past the buffer, etc.). A maker index past the table
         *  resolves to "" at read time.
         *
         *  A pre-ALP3 file stays visible as legacy format, but does not borrow tier 1's structured
         *  manufacturer-attribution label. A cache predating the field carries no evidence either
         *  way, so assigning it either modern tier would be a fabricated claim.
         *
         *  Mirrors iOS ALPRStore.parse constant for constant on the header, the table, the length
         *  arithmetic and the coordinate range gate. Pinned on both sides in AlprDatasetTest /
         *  ALPRDatasetTests off the same fixtures.
         *
         *  RESOLVED 2026-08-05, was a real divergence: iOS dropped an out-of-range coordinate and
         *  this side kept it, so the same corrupt file gave the two apps a different node count and
         *  a different unverifiedCount caption. Both now drop, together with the maker and tier. See
         *  the WHY-DROP note on the range gate itself, ~40 lines below.
         *
         *  Internal rather than private so the unit tests can drive it on raw bytes instead of
         *  through the network path. It is the one function in the app with a history of shipping a
         *  schema mismatch to BOTH platforms at once, so it is worth the keyword. */
        internal fun parse(bytes: ByteArray): Parsed? {
            if (bytes.size < 12) return null
            val a = 'A'.code.toByte(); val l = 'L'.code.toByte(); val pC = 'P'.code.toByte()
            if (bytes[0] != a || bytes[1] != l || bytes[2] != pC) return null
            val v3 = bytes[3] == '3'.code.toByte()
            val v2 = bytes[3] == '2'.code.toByte()
            val v1 = bytes[3] == '1'.code.toByte()
            val v4 = bytes[3] == '4'.code.toByte()
            val hasMakers = v2 || v3 || v4
            val hasTier = v3 || v4
            if (!v1 && !hasMakers) return null
            val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
            buf.position(4)
            buf.int                                  // epochDay (unused here)
            val count = buf.int
            if (count < 0 || count >= 5_000_000) return null   // >= to match iOS's `count < 5_000_000`

            var table = arrayOf("")
            if (hasMakers) {
                if (buf.remaining() < 1) return null
                val nMakers = buf.get().toInt() and 0xFF
                val list = ArrayList<String>(nMakers)
                repeat(nMakers) {
                    if (buf.remaining() < 1) return null
                    val len = buf.get().toInt() and 0xFF
                    if (buf.remaining() < len) return null
                    val sb = ByteArray(len); buf.get(sb)
                    val text = runCatching {
                        sb.decodeToString(throwOnInvalidSequence = true)
                    }.getOrNull() ?: return null
                    list.add(text)
                }
                if (list.isEmpty()) return null       // index 0 must exist
                table = list.toTypedArray()
            }
            val coordStart = buf.position()
            val idxBytes = if (hasMakers) count.toLong() else 0L
            val tierBytes = if (hasTier) count.toLong() else 0L
            val metadataBytes = if (v4) {
                runCatching { Math.multiplyExact(count.toLong(), ALP4_METADATA_BYTES) }
                    .getOrNull() ?: return null
            } else 0L
            val expected = runCatching {
                Math.addExact(
                    Math.addExact(
                        Math.addExact(coordStart.toLong(), Math.multiplyExact(count.toLong(), 8L)),
                        idxBytes,
                    ),
                    Math.addExact(tierBytes, metadataBytes),
                )
            }.getOrNull() ?: return null
            if (bytes.size.toLong() != expected) return null
            // Read the three parallel blocks, then DROP any node whose coordinate is out of range,
            // together with its maker and tier so all three arrays stay in lockstep.
            //
            // WHY DROP RATHER THAN KEEP (aligned with iOS 2026-08-05, ALPRDataset.swift's
            // CLLocationCoordinate2DIsValid guard). A latitude past +/-90 is not a camera in an
            // odd place, it is corrupt bytes. It can never satisfy a viewport bounding box, so the
            // map can never draw it, and nearest() can never meaningfully match it. Keeping it
            // only inflates the "N cameras" caption with a node no surface can show. This is NOT
            // the same call as the unverified-tier one, where the pin is a real location with
            // uncertain attribution and staying counted keeps the data-quality problem visible.
            // There is nothing to keep visible here.
            //
            // The parsers used to disagree: iOS dropped, Android kept, so the same corrupt file
            // gave the two apps different node counts and different captions. The parity test
            // suite added 2026-08-05 is what surfaced it. Keep both sides in step.
            val rawLat = IntArray(count); val rawLon = IntArray(count)
            for (i in 0 until count) { rawLat[i] = buf.int; rawLon[i] = buf.int }
            val rawIdx = IntArray(count)
            if (hasMakers) for (i in 0 until count) rawIdx[i] = buf.get().toInt() and 0xFF
            // ALP1/2 have no tier byte. Preserve their old default-visible behavior, but carry a
            // sentinel so the UI says "legacy dataset format" instead of falsely claiming a
            // structured manufacturer attribution that the file never encoded.
            val rawTier = IntArray(count) { if (hasTier) 1 else ALPR_TIER_LEGACY_FORMAT }
            if (hasTier) for (i in 0 until count) rawTier[i] = buf.get().toInt() and 0xFF
            if (v4 && rawTier.any { it !in 0..2 }) return null
            val rawMetadata = arrayOfNulls<SourceMetadata>(count)
            if (v4) for (i in 0 until count) {
                val osmType = buf.get().toInt() and 0xFF
                val osmId = buf.long.toULong()
                val sourceEpoch = buf.int.toLong() and 0xFFFF_FFFFL
                val directionRaw = buf.short.toInt() and 0xFFFF
                val checkDayRaw = buf.int.toLong() and 0xFFFF_FFFFL
                if (osmType !in 0..2 || osmId == 0uL ||
                    (directionRaw != 0xFFFF && directionRaw !in 0..35_999)) return null
                rawMetadata[i] = SourceMetadata(
                    osmType = osmType,
                    osmId = osmId,
                    sourceEpoch = sourceEpoch.takeUnless { it == 0L },
                    directionCdeg = directionRaw.takeUnless { it == 0xFFFF },
                    checkDateDay = checkDayRaw.takeUnless { it == 0L },
                )
            }

            val keep = ArrayList<Int>(count)
            for (i in 0 until count)
                if (rawLat[i] in -900_000_000..900_000_000 && rawLon[i] in -1_800_000_000..1_800_000_000)
                    keep.add(i)
            val n = keep.size
            val coords = IntArray(n * 2); val makerIdx = IntArray(n)
            val confirmed = BooleanArray(n); val tiers = IntArray(n)
            val metadata = arrayOfNulls<SourceMetadata>(n)
            for (k in 0 until n) {
                val i = keep[k]
                coords[k * 2] = rawLat[i]; coords[k * 2 + 1] = rawLon[i]
                makerIdx[k] = rawIdx[i]
                tiers[k] = rawTier[i]
                confirmed[k] = rawTier[i] == 1 || rawTier[i] == ALPR_TIER_LEGACY_FORMAT
                metadata[k] = rawMetadata[i]
            }
            val wireFormat = when {
                v4 -> "ALP4"
                v3 -> "ALP3"
                v2 -> "ALP2"
                else -> "ALP1"
            }
            return Parsed(wireFormat, count, coords, makerIdx, table, confirmed, tiers, metadata)
        }

        private fun sha256Hex(bytes: ByteArray): String {
            val d = MessageDigest.getInstance("SHA-256").digest(bytes)
            val sb = StringBuilder(d.size * 2)
            for (b in d) sb.append("%02x".format(b.toInt() and 0xFF))
            return sb.toString()
        }

        private fun readBounded(input: java.io.InputStream, cap: Long, label: String): ByteArray {
            val out = java.io.ByteArrayOutputStream(minOf(cap, 64L * 1024L).toInt())
            val tmp = ByteArray(16 * 1024)
            var total = 0L
            while (true) {
                val r = input.read(tmp)
                if (r < 0) break
                total += r
                if (total > cap) throw java.io.IOException("$label exceeds byte limit")
                out.write(tmp, 0, r)
            }
            return out.toByteArray()
        }

        private const val MAX_MANIFEST_BYTES = 64L * 1024L
        private const val MAX_REDIRECTS = 3
        private const val ALP4_METADATA_BYTES = 19L
    }
}
