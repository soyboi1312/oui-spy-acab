package tech.acab.app.model

import org.json.JSONObject

/** The things ACAB looks for. Raw values match the firmware "t" field. The retired
 *  police-gear type (t=6) is gone on purpose, same as iOS - the firmware reports
 *  Motorola/LE gear as a body cam now. A live t=6 frame still falls back to UNKNOWN
 *  via from(); a stale t=6 row read back off disk migrates to BODY_CAM via
 *  fromStored(), so upgrading from v1.7 doesn't turn old history into "Unknown". */
enum class DeviceType(val raw: Int) {
    UNKNOWN(0), FLOCK_CAMERA(1), FLOCK_RAVEN(2), BODY_CAM(3), DRONE(4), TRACKER(5), NEARBY_DEVICE(7),
    // A device the user starred (watchlist). The board alerts on its exact MAC every time it's
    // seen, even with no built-in signature match. Synthesized by the firmware (t=8) and shown
    // like any other detection kind. Sits after NEARBY_DEVICE so the raw wire values stay stable.
    WATCHED(8),
    // Smart / recording glasses (Meta Ray-Ban / Oakley, Snap Spectacles, Luxottica frames),
    // matched on the BLE manufacturer company ID so it survives MAC randomization. Its own
    // category, not a tracker and not a body cam. t=9 on the wire.
    GLASSES(9),
    // A branded IP camera (Hikvision/Dahua/Amcrest/Axis/Reolink) seen on the host WiFi. IP cameras
    // don't randomize their MAC, and the 802.11 DATA-frame source MAC is cleartext even under WPA2/3,
    // so a camera streaming on the network is passively OUI-matchable. Opt-in + default off (data-frame
    // capture is off unless the user enables it). NEVER "hidden camera": it could be an NVR, doorbell,
    // or a host-disclosed camera, so we only say the brand is on the network. t=10 on the wire.
    NETWORK_CAMERA(10);

    /**
     * Key into `faq-content.json`'s `relatedHelp` map. These enum names ARE the keys, which is why
     * the shared JSON uses SCREAMING_CASE; iOS maps its own camelCase DeviceType onto them.
     *
     * Every real key now has a relatedHelp entry (BODY_CAM and GLASSES got theirs 2026-08-10;
     * the earlier reserved-on-purpose state is over), and check-signature-drift.py FAILS the
     * build if a real key ever loses its entry, so add the JSON row in the same commit as a new
     * category. NEARBY_DEVICE and UNKNOWN return "", which means NEVER a panel: neither is a
     * category a user can have a question about (NEARBY_DEVICE is Desert mode's firehose,
     * UNKNOWN is a parse fallback). Mirrors iOS DeviceType.faqKey.
     */
    val faqKey: String
        get() = when (this) {
            NEARBY_DEVICE, UNKNOWN -> ""
            else -> name
        }

    val label: String
        get() = when (this) {
            FLOCK_CAMERA -> "ALPR Camera"
            FLOCK_RAVEN  -> "Flock Raven"
            BODY_CAM     -> "Body Camera"
            DRONE        -> "Drone"
            TRACKER      -> "Tracker"
            NEARBY_DEVICE-> "Nearby Device"
            WATCHED      -> "Watched device"
            GLASSES      -> "Recording glasses"
            NETWORK_CAMERA -> "Network camera"
            UNKNOWN      -> "Unknown"
        }

    /** True for the buckets the drive-mode notification speaks: the six counters, and only those.
     *
     *  NETWORK_CAMERA joined 2026-07-31. It was excluded because the surface listed a fixed five
     *  and letting it set the "last ..." line would have named a category with no row. Now that
     *  the breakdown is driven by the board's toggles, network cameras get a row exactly when
     *  the opt-in is on, so the reason no longer holds.
     *
     *  WATCHED left on 2026-08-26. It was here on the reasoning that a star pinging the drive
     *  surface is the point of starring, but no drive surface on either platform ever honored it:
     *  AcabLinkService.DRIVE_CATS has no "WATCHED", so the headline, the breakdown and the "last
     *  ..." line all filter it out, and iOS drops it even earlier for want of a widgetCategoryKey.
     *  All the flag bought was a newestByCategory entry nothing read, and on iOS an escalated Live
     *  Activity push carrying a ContentState that had not changed. A star is not silent: the
     *  firmware gives ACAB_WATCHED its own tone and DetectionNotifier lists it as a push category.
     *  Desert-mode NEARBY still fills no bucket and would make "last ..." meaningless.
     *  Mirrors iOS DeviceType.onDriveSurface. */
    val onDriveSurface: Boolean
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN, DRONE, BODY_CAM, TRACKER, GLASSES,
            NETWORK_CAMERA -> true
            NEARBY_DEVICE, WATCHED, UNKNOWN -> false
        }

    /** Coarse category; ALPR camera + Raven share one, like the iOS app. */
    val category: String
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN -> "ALPR"
            BODY_CAM -> "BODY CAM"
            DRONE    -> "DRONE"
            TRACKER  -> "TRACKER"
            NEARBY_DEVICE -> "NEARBY"
            WATCHED  -> "WATCHED"
            GLASSES  -> "GLASSES"
            NETWORK_CAMERA -> "CAMERA"
            UNKNOWN  -> "UNKNOWN"
        }

    /** Which home-widget strip cell this type feeds, or null when it feeds none. The tokens are
     *  the cross-process contract with BeaconsWidgetProvider (prefs key "w_c_" + token) and match
     *  the iOS App Group keys (DeviceType.widgetCategoryKey / WidgetCategory.defaultsKey), so the
     *  two platforms describe the same breakdown by the same names. Ambient NEARBY rows and the
     *  user's own WATCHED rule fill no cell, matching iOS. */
    val widgetCategoryKey: String?
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN -> "ALPR"
            DRONE -> "DRONE"
            BODY_CAM -> "BODY"
            TRACKER -> "TRACKER"
            GLASSES -> "GLASSES"
            NETWORK_CAMERA -> "CAMERA"
            NEARBY_DEVICE, WATCHED, UNKNOWN -> null
        }

    /** Short label for the detail badge, like the iOS app. */
    val classLabel: String
        get() = when (this) {
            FLOCK_CAMERA -> "PLATE READER"
            FLOCK_RAVEN  -> "AUDIO SENSOR"
            BODY_CAM     -> "BODY CAMERA"
            DRONE        -> "AERIAL · RID"
            TRACKER      -> "ITEM TRACKER"
            NEARBY_DEVICE-> "DEVICE"
            WATCHED      -> "STARRED"
            GLASSES      -> "SMART GLASSES"
            NETWORK_CAMERA -> "NETWORK CAMERA"
            UNKNOWN      -> "UNKNOWN"
        }

    /** Who makes the gear, shown when an ALPR class has a known brand. */
    val brand: String?
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN -> "Flock Safety"
            else -> null
        }

    /** Glasses is the last experimental detector. Body cam graduated on 2026-07-19: its
     *  strongest signature, the Axon "BWCDEVICE" service-data tag at confidence 90, was
     *  field-validated against a visually confirmed scene. Keep this in step with the EXP
     *  counter in DeviceScreen and with iOS DeviceType.isExperimental. */
    val isExperimental: Boolean get() = this == GLASSES

    /** The noun the "experimental detector" banner names, so it can never again describe a
     *  category other than the one on screen. It hardcoded "Body-cam signatures" and kept
     *  saying so after body cam graduated and isExperimental moved to GLASSES, putting a
     *  body-cam warning on every glasses detection (seen in the field 2026-07-31). Mirrors
     *  iOS DeviceType.experimentalNoun. */
    val experimentalNoun: String
        get() = when (this) {
            GLASSES -> "Recording-glasses"
            BODY_CAM -> "Body-cam"
            NETWORK_CAMERA -> "Network-camera"
            FLOCK_CAMERA, FLOCK_RAVEN -> "ALPR"
            DRONE -> "Drone"
            TRACKER -> "Tracker"
            NEARBY_DEVICE, WATCHED, UNKNOWN -> "These"
        }

    /** First line of the "Confirm it" checklist: what to physically look for to verify THIS
     *  kind of device. Was one hardcoded ALPR string ("pole-mounted camera, solar panel,
     *  small antenna"), which is the wrong instruction on every other category and was
     *  showing on glasses detections in the field 2026-07-31. A checklist naming the wrong
     *  object is worse than none: it invites the user to confirm a false negative.
     *  Mirrors iOS DeviceType.confirmPrompt word for word. */
    val confirmPrompt: String
        get() = when (this) {
            FLOCK_CAMERA, FLOCK_RAVEN ->
                "Look around, pole-mounted camera, solar panel, small antenna?"
            BODY_CAM -> "Look around, anyone with a camera worn on the chest or shoulder?"
            GLASSES -> "Look around, anyone in glasses with a lens or LED in the frame?"
            NETWORK_CAMERA -> "Look around, a doorbell camera, or one under an eave or on a wall?"
            DRONE -> "Look up, anything hovering or circling?"
            TRACKER -> "Check your bag, pockets, and car for a tag that isn't yours."
            NEARBY_DEVICE, WATCHED, UNKNOWN ->
                "Look around, anything nearby that could be transmitting?"
        }

    companion object {
        /** The retired police-gear wire type. Firmware <= v1.7 filed the Motorola/LE proxy
         *  under its own "t", before that gear was folded into the body-cam category. Kept
         *  only so [fromStored] can migrate rows persisted by those builds. */
        private const val RETIRED_LE_RAW = 6

        fun from(raw: Int): DeviceType = entries.firstOrNull { it.raw == raw } ?: UNKNOWN

        /** [from] for a row read back off disk. A user upgrading from v1.7 still has t=6 rows
         *  in their log; the gear they describe is what the board now reports as a body cam,
         *  so map them across instead of degrading real history to an unfilterable "Unknown"
         *  with a question-mark icon. The live wire parse deliberately stays strict: no
         *  current firmware emits t=6, so a t=6 frame off the air is genuinely unrecognized. */
        fun fromStored(raw: Int): DeviceType = if (raw == RETIRED_LE_RAW) BODY_CAM else from(raw)
    }
}

/** One detection from the Detections characteristic. */
data class Detection(
    val type: DeviceType,
    val source: Int,
    val method: Int,
    val confidence: Int,
    val mac: String,
    val rssi: Int,
    val name: String?,
    val rid: String?,
    val detail: String?,
    val lat: Double?,
    val lon: Double?,
    val pilotLat: Double?,
    val pilotLon: Double?,
    val altitude: Int?,
    val speedH: Int?,
    val speedV: Int?,
    val heading: Int?,
    val heightAGL: Int?,
    val pilotAlt: Int?,
    val ridStatus: Int?,
    val count: Int,
    val isNew: Boolean,
    // GPS-fix age in seconds for the fix behind lat/lon (json "gage"). Present on any non-drone
    // row whose stamping fix was at least 1 s old, LIVE rows included - it is not a marker for
    // offline or Desert rows. null means a fresh sub-second fix, no coordinate at all, the
    // board's own onboard fix, a drone's broadcast position, or a hist row the replay trim
    // ladder shed the fix from.
    val gpsAgeSec: Int?,
    // ---- offline-buffer replay fields (live detections leave these at defaults) ----
    val hist: Boolean,      // true for a replayed history record
    val seq: Long,          // the board's monotonic sequence number (0 when absent)
    val at: Long,           // absolute unix seconds for the record (0 when absent)
    val approx: Boolean,    // true when the board only knows the order, not the time
    // Board uptime in ms when the record was captured, counted from [boot]. Guaranteed on approx
    // records, where it is the only dating information; on anchored records it is step 2 of the
    // replay trim ladder and is dropped together with [boot] on a small-MTU link when the frame
    // is over cap (see docs/ble-protocol.md "Replay trim ladder"), so treat both as optional.
    // It is a stopwatch reading on the board's own clock, not
    // a wall clock, so it is only comparable to another reading from the SAME boot session.
    val ms: Long = 0L,
    // Which boot session captured the record. The firmware persists and increments this on every
    // power-up, so it is monotonic, which is what lets the app order unanchored boots against
    // anchored ones (see TimeBasis.Bracketed).
    val boot: Long = 0L,
    // true for a record filed off the offline-buffer replay path (the board's "black box"),
    // as opposed to a live sighting. Drives the "OFFLINE" chip on the log row. Set on the
    // history/replay path only, and persisted so a reloaded record keeps its chip.
    val offline: Boolean = false,
    // BLE manufacturer company ID (Bluetooth SIG assigned #); null for WiFi devices or a BLE
    // advert with no manufacturer data. The field the glasses/tracker detectors key on.
    val companyId: Int? = null,
) {
    /** Stable identity. Drones key on UAS-ID, which survives MAC rotation (same as the
     *  firmware's dedup key); everything else uses type + mac. Computed once at construction
     *  (a plain val, not a getter, and NOT a constructor param so it stays out of equals/copy)
     *  so the hot ~3 Hz feed scans don't reallocate this string on every id access. */
    val id: String =
        if (type == DeviceType.DRONE && !rid.isNullOrEmpty()) "${type.raw}:$rid"
        else "${type.raw}:${mac.lowercase()}"

    /** A short "as of" string for the age of the fix behind the row's coordinate (live rows
     *  included, see [gpsAgeSec]): "45s", "5m", "2h", "1d". null when there's no
     *  coordinate, or the fix was fresh (under 30s - treat as now). Tier breakpoints mirror
     *  iOS Detection.gpsFixAgeMagnitude exactly (seconds to 89s, minutes to 89m, hours to
     *  47h, days beyond) so the same fix reads the same on both phones. */
    private val gpsFixAgeMagnitude: String? get() {
        if (lat == null || lon == null) return null
        val age = gpsAgeSec ?: return null
        if (age < 30) return null
        if (age < 90) return "${age}s"
        val m = age / 60
        if (m < 90) return "${m}m"
        val h = m / 60
        return if (h < 48) "${h}h" else "${h / 24}d"
    }

    /** Compact LOC-badge text. A LIVE detection reads "4m ago" (the fix trails roughly now);
     *  an OFFLINE/replayed record was captured at an unknown PAST time, so "ago" would falsely
     *  imply recency - show the fix-to-sighting lag ("fix 4m") instead. null when the fix is
     *  fresh or there's no coordinate. */
    val locationAgeText: String? get() {
        val m = gpsFixAgeMagnitude ?: return null
        return if (offline) "fix $m" else "$m ago"
    }

    /** Longer form for the detail card, same live/offline split as [locationAgeText]. */
    val locationAgeDetail: String? get() {
        val m = gpsFixAgeMagnitude ?: return null
        return if (offline) "location from a fix $m old" else "location as of $m ago"
    }

    /** True when the transmitter address is randomized / locally-administered (a BLE private
     *  address or a randomized WiFi MAC), read off the "locally administered" bit of the first
     *  octet. That is the firmware's byte test too, but since firmware 2.0.7 the single-radio
     *  boards also fold in the BLE controller's address type, which this bit cannot see: a
     *  nearby-device row can read "randomized MAC" while this stays false, because the board
     *  does not send its randomAddr flag ("rnd") on the wire. Twin: iOS addressIsRandomized.
     *  Phones and item trackers rotate these every few minutes, so a starred random MAC may
     *  stop matching. */
    val isRandomAddr: Boolean get() {
        val hex = mac.filter { it != ':' && it != '-' }
        if (hex.length < 2) return false
        val firstOctet = hex.take(2).toIntOrNull(16) ?: return false
        return (firstOctet and 0x02) != 0
    }

    /** Readable ODID operational status (drones). */
    val ridStatusLabel: String? get() = when (ridStatus) {
        1 -> "On ground"; 2 -> "Airborne"; 3 -> "Emergency"; 4 -> "System fault"; else -> null
    }

    /** Maker from a CTA-2063-A Remote ID serial (4-char code + length digit + serial).
     *  Names the codes we know; otherwise just shows the code. */
    val ridManufacturer: String? get() {
        if (type != DeviceType.DRONE) return null
        val s = rid ?: return null
        if (s.length < 5) return null
        val code = s.substring(0, 4)
        val codeOk = code.all { it.isDigit() || (it in 'A'..'Z' && it != 'I' && it != 'O') }
        if (!codeOk || s[4] !in "123456789ABCDEF") return null
        val names = mapOf("1581" to "DJI", "1748" to "Autel", "1588" to "Parrot", "1668" to "Skydio", "1871" to "Aurora")
        return names[code] ?: "Mfr $code"
    }

    companion object {
        /** Decode an already-materialized object. This is the right boundary for app-authored
         * persisted/demo objects, whose wire integers were inserted as integral Numbers. A raw
         * BLE frame must use [fromWireJson]: Android's JSONTokener may already have rounded a
         * decimal token to an integral Double by the time only a JSONObject remains. */
        fun fromJson(o: JSONObject) = fromJson(o, wireFields = null)

        /** Decode a raw BLE detection without trusting Android's precision-losing Number object
         * for the replay/timestamp uint32s or RSSI. [parsed] is the same once-parsed object the
         * ingress uses for dispatch; the exact values come from the original top-level JSON
         * lexemes. */
        internal fun fromWireJson(raw: String, parsed: JSONObject): Detection =
            fromJson(parsed, raw.wireNumericFields() ?: WireNumericFields())

        private fun fromJson(o: JSONObject, wireFields: WireNumericFields?) = Detection(
            type = DeviceType.from(o.optInt("t", 0)),
            source = o.optInt("s", 0),
            method = o.optInt("meth", 0),
            confidence = o.optInt("c", 0),
            mac = o.optString("mac", ""),
            // Clamped to the int16 wire type (the firmware sends an int16 dBm), the same rule as
            // the rssi min/max in iOS Detection.init(from:). The clamp keeps the value inside the
            // range the 3-sample smoothing average and the >= 4 dB closest-approach comparison in
            // AcabBleManager are written for. Raw BLE uses exactInt16ClampedOrAbsent and
            // stored/demo objects use int16Clamped; neither narrows through optInt/optLong before
            // checking type and integrality, because that would test a number the wire never
            // carried.
            rssi = wireFields?.rssi ?: o.int16Clamped("rssi"),
            name = o.stringOrNull("name"),
            rid = o.stringOrNull("id"),
            detail = o.stringOrNull("det"),
            companyId = if (o.has("cid")) o.optInt("cid") else null,
            lat = o.doubleOrNull("lat"),
            lon = o.doubleOrNull("lon"),
            pilotLat = o.doubleOrNull("plat"),
            pilotLon = o.doubleOrNull("plon"),
            altitude = if (o.has("alt")) o.optInt("alt") else null,
            speedH = if (o.has("spd")) o.optInt("spd") else null,
            speedV = if (o.has("vspd")) o.optInt("vspd") else null,
            heading = if (o.has("hdg")) o.optInt("hdg") else null,
            heightAGL = if (o.has("hgt")) o.optInt("hgt") else null,
            pilotAlt = if (o.has("palt")) o.optInt("palt") else null,
            ridStatus = if (o.has("sta")) o.optInt("sta") else null,
            count = o.optInt("n", 1),
            isNew = o.optBoolean("new", false),
            gpsAgeSec = if (o.has("gage")) o.optInt("gage") else null,
            hist = o.optBoolean("hist", false),
            // RANGE-CHECKED against the uint32 wire type (firmware det_log.h). A value outside it
            // reads as ABSENT - 0, already each of these fields' "not sent" value - and never as
            // the nearest legal value, because pinning to a bound MANUFACTURES data instead of
            // dropping it: a negative seq flips fileHistory's pseudo-stamp subtraction into an
            // addition, lifting a timeless record above HIST_PSEUDO_BASE where isApproxTime reads
            // it as a REAL timestamp, and an `at` pinned to 4294967295 is a 2106 stamp that also
            // widens that boot's anchor bounds (bootMinAt/bootMaxAt), which are what bracket the
            // neighbouring unanchored boots. ms/boot ride the same rule: uint32 on the wire, and
            // arithmetic after. iOS drops the same values at the same boundary (a failing UInt32
            // decode for seq/ms/boot, an explicit range test for at) and spells the result nil;
            // the shared fixture table is in AcabBleManagerExportTest and ExportTests.
            //
            // `seq` takes one more step: 0 and 0xFFFFFFFF are the firmware's own EMPTY-SLOT
            // sentinels (det_log.cpp slotValid() rejects both), so a genuine board can never send
            // either and 0xFFFFFFFF is mapped onto this field's existing "no seq" value, 0. Left
            // as the ceiling it rides histHighestContiguous into lastSeq, gets persisted to prefs
            // "lastSeq" by checkpointHistory, and every later connect then writes
            // {"sync":4294967295} - the board never replays another buffered detection, and the
            // poison survives relaunch because it is on disk. The record is still received and
            // still counted toward the drain tally; it just moves no cursor (fileHistory's
            // contiguous test and high-water mark both ignore 0). iOS twin: the seq flatMap in
            // Detection.init(from:), whose "no seq" value is nil, plus the same guard on the
            // undecodable-frame path in BLEManager.ingestDetection.
            seq = (wireFields?.seq ?: o.uint32OrAbsent("seq"))
                .let { if (it == 0xFFFF_FFFFL) 0L else it },
            at = wireFields?.at ?: o.uint32OrAbsent("at"),
            approx = o.optBoolean("approx", false),
            ms = wireFields?.ms ?: o.uint32OrAbsent("ms"),
            boot = wireFields?.boot ?: o.uint32OrAbsent("boot"),
            // Only ever set on the persisted-reload path (detectionToJson writes it); a live
            // wire frame never carries "offline", so live records stay false. The replay path
            // sets it in the manager after fromJson, not off the wire.
            offline = o.optBoolean("offline", false),
        )

        /** [fromJson] for a row reloaded from the persisted store, where a retired t=6
         *  police-gear type migrates to BODY_CAM (see DeviceType.fromStored). copy() rebuilds
         *  the derived [id] off the new type, so the migrated row keys as a body cam and can't
         *  collide with the "6:mac" identity it was filed under. */
        fun fromStoredJson(o: JSONObject): Detection {
            val d = fromJson(o)
            val migrated = DeviceType.fromStored(o.optInt("t", 0))
            return if (migrated == d.type) d else d.copy(type = migrated)
        }
    }
}

/** How a detection's timestamp was arrived at, carried beside the timestamp itself.
 *
 *  The board has no real-time clock. A buffered record stores only board uptime and a boot
 *  counter, so every time an offline record shows is DERIVED, and the derivation is only as good
 *  as the anchor it hangs off. Showing a derived time in the same shape as a clock reading invites
 *  a confidence the method cannot support, and this log is meant to be usable as evidence, so the
 *  quality travels with the value and every renderer has to say which one it is holding.
 *
 *  Mirrors iOS TimeBasis one for one, including the CSV names. */
sealed class TimeBasis {
    /** A live capture, stamped by this phone's own clock as the advert came in. */
    data object Exact : TimeBasis()

    /** A buffered record the board dated from an anchor it kept for that boot session.
     *  [atMs] is that reconstruction and [precisionSec] is how wide it could be off. */
    data class Reconstructed(val atMs: Long, val precisionSec: Int) : TimeBasis()

    /** A buffered record from a boot the app never anchored, bounded by the anchored boots on
     *  either side of it. At least one bound is non-null; both null is [Unknown] instead. There
     *  is no single time here, only an interval, so it must never be rendered as a point. */
    data class Bracketed(val afterMs: Long?, val beforeMs: Long?) : TimeBasis()

    /** Buffered, unanchored, and with no anchored boot on either side to bound it against.
     *  Nothing to say beyond the order it was recorded in. */
    data object Unknown : TimeBasis()

    /** The time_basis CSV token. Byte-identical to iOS. */
    val csvName: String get() = when (this) {
        is Exact -> "exact"
        is Reconstructed -> "reconstructed"
        is Bracketed -> "bracketed"
        is Unknown -> "unknown"
    }
}

/** Friendly per-type vendor guess for when the OUI is unknown, so the detail screen
 *  never falls back to repeating the type label. Mirrors iOS Detection.displayVendor's
 *  fallback steps: body cam consults the signature carried in the wire detail string
 *  first (it survives BLE address randomization, where there is no OUI to look up), and
 *  only an unrecognized signature names the category's makers rather than picking one. */
val Detection.vendor: String
    get() = when (type) {
        DeviceType.FLOCK_CAMERA, DeviceType.FLOCK_RAVEN -> "Flock Safety"
        DeviceType.BODY_CAM -> bodyCamSignature?.vendor ?: "Axon / Utility / Motorola"
        DeviceType.TRACKER  -> "Item tracker"
        DeviceType.DRONE    -> "Drone maker"
        DeviceType.GLASSES  -> "Smart glasses"
        DeviceType.WATCHED  -> "Starred device"
        // Named the specific brand (Hikvision/Dahua/...) off the OUI when known; this is the
        // honest fallback when the exact block isn't in the vendor table.
        DeviceType.NETWORK_CAMERA -> "IP camera"
        else -> "Unknown vendor"
    }

/** The BLE mfg company ID as "0x058E" (+ vendor when known), for the detail screen. null when
 *  there's no company ID (WiFi devices, or a BLE advert with no mfg data). Mirrors iOS. */
val Detection.companyIdText: String?
    get() = companyId?.takeIf { it > 0 }?.let { id ->
        val hex = "0x%04X".format(id)
        bleCompanyName(id)?.let { "$hex · $it" } ?: hex
    }

/** Bare "0x058E" hex, no vendor - used for the CSV column so it stays machine-parseable. */
val Detection.companyIdHex: String?
    get() = companyId?.takeIf { it > 0 }?.let { "0x%04X".format(it) }

/** Short vendor label for the BLE SIG company IDs most relevant here (camera glasses, trackers,
 *  a few common makers). Everything else just shows the raw hex. Mirrors iOS bleCompanyName. */
fun bleCompanyName(id: Int): String? = when (id) {
    0x004C -> "Apple"
    0x0075 -> "Samsung"
    0x00E0 -> "Google"
    0x0006 -> "Microsoft"
    0x0D53 -> "Luxottica (Ray-Ban Meta)"
    0x03C2 -> "Snap (Spectacles)"
    0x060C -> "Vuzix"
    0x058E -> "Meta Platforms Technologies"
    0x01AB -> "Meta Platforms"
    0x0BC6 -> "TCL / RayNeo"
    else   -> null
}

/** Board status from the Status characteristic. */
data class DeviceStatus(
    val firmware: String,
    val uptime: Int,
    val total: Int,
    val ble: Boolean,
    val wifi: Boolean,
    val wifiEco: Int,       // WiFi eco sleep seconds between sweeps (0/3/7/15); 0 = continuous
    val flock: Boolean,
    val drone: Boolean,
    // The drone vendor-OUI fallback (flag a DJI/Parrot OUI as a drone with no Remote ID). A
    // false-positive source - it can't tell a flying drone from a stationary Parrot gadget - so
    // it's opt-in and DEFAULT OFF. The Remote ID path stays always on under the main drone toggle.
    val droui: Boolean,
    val bodyCam: Boolean,
    // The broad Motorola Solutions OUI proxy, a SUB-toggle under the body-cam category:
    // classification needs BOTH. It rides seven Motorola Solutions blocks that also carry
    // radios, docks, and infrastructure, so it's the noisy half of the category; switching it
    // off leaves the field-validated Axon "BWCDEVICE" payload match and Utility BodyWorn
    // running. Absent means pre-split firmware where the proxy is fused to the category and
    // always on, so it reads true (see [motoSupported]).
    val moto: Boolean,
    // Whether the board's firmware actually splits the Motorola proxy out. Firmware that
    // predates the split never sends "moto", and there's nothing to control, so the UI hides
    // the sub-toggle rather than offering a switch that writes into the void.
    val motoSupported: Boolean,
    val tracker: Boolean,
    val glasses: Boolean,
    // Network-camera (branded IP-camera OUI on host WiFi) detector. Opt-in and DEFAULT OFF: it turns
    // on 802.11 DATA-frame source-MAC inspection, which is off by default, so absent = off. Mirrors
    // the drone-OUI (droui) opt-in exactly.
    val ncam: Boolean,
    val buzzer: Boolean,
    val volume: Int,
    val ledOn: Boolean,     // onboard LED / idle heartbeat on ("ledon"; absent = on, the default)
    val gps: Boolean,
    val bufCount: Int,      // records currently held in the board's offline buffer
    val bufOn: Boolean,     // whether offline buffering is enabled on the board
    // Stationary/record-all capture reached the raw-ring capacity. The firmware sends this only
    // while true and keeps it set until a successful clear, so absent must decode as false on
    // every fresh status frame rather than latching an earlier warning in the app.
    val bufferSaturated: Boolean,
    // Latched offline-buffer fault mask ("buferr"). 0x01...0x10 are raw-ring failures, 0x20 is
    // an offline-buffer metadata load/save failure (generation, anchors, privacy lifecycle, and
    // diagnostic state), and 0x40 is a cryptography failure. Firmware retries eligible work, but
    // these HISTORICAL bits remain set until a successful physical clear.
    // uint32 on the wire. Keep this as Long so a future high bit (0x80000000) cannot narrow to a
    // negative Int and disappear from the fail-closed unknown-bit warning policy.
    val bufferFaults: Long,
    // The authenticated phone offered a durable buffer key that does not match the key which
    // protects this nonempty history generation. The firmware preserves the history and denies
    // replay; it emits "keymis":true only for that authenticated session. Absent = false.
    val bufferKeyMismatch: Boolean,
    val desertMode: Boolean,// Desert mode (report every device in range) enabled
    val ignoreCount: Int,   // entries on the board's ignore list (for reconciliation)
    val watchCount: Int,    // entries on the board's watchlist (for reconciliation)
    val battery: Int?,      // battery %, null unless the board has a sense divider ("bat")
    // co-processor (nRF) alive: a nRF UART line was seen within the liveness timeout. only
    // dual-radio boards emit "co"; single-radio omit it, so null = unknown = no warning. false
    // means the nRF radio is faulted and the BLE-detection half is dark ("co").
    val coAlive: Boolean?,
    // The nRF is mid BLE DFU ("nrfup"; the board emits it only while true, so absent = false).
    // It goes quiet while it reboots into its bootloader, which drops coAlive to false for a
    // perfectly good reason, so this is what tells a real radio fault apart from an update in
    // flight: while it's set the UI says "updating" instead of crying fault.
    val nrfUpdating: Boolean,
    // Running nRF co-processor app version ("nrfv"), a small monotonic int (NRF_APP_VERSION);
    // null when absent (single-radio boards, or the co-processor hasn't reported yet). Compared
    // against the manifest's nrf.version to decide whether a co-processor update is available.
    val nrfVersion: Int?,
    val charging: Boolean,  // battery charging: VBAT sustained above ~4200 mV ("chg"); absent = false
    // A deferred flash erase of the offline buffer is still sweeping ("wiping"; absent = idle).
    // While true the bufCount above is stale (mid-wipe), so the UI shows a "clearing" state
    // rather than a leftover count.
    val wiping: Boolean,
    /** Carrier-board revision, "A" or "B" ("rev"). Dual board only; ABSENT on older firmware and
     *  on every single-radio build. Nullable ON PURPOSE: docs/ble-protocol.md is explicit that a
     *  missing value means "not told", never "rev-A", so it must never default. Mirrors iOS
     *  DeviceStatus.boardRev, which Android was missing entirely, along with the OTA revision
     *  gate that reads it. */
    val boardRev: String?,
    /** BLE JSON contract version the board reports; 0 when the firmware predates the key. */
    val protoVersion: Int,
) {
    /** Just the version, e.g. "0.2.3" from "ACAB-ouispy 0.2.3". */
    val version: String get() = firmware.substringAfterLast(' ', firmware)

    /** `fw` with the trailing version stripped ("beacon board 1.7" -> "beacon board"). */
    val firmwareLabel: String get() = firmware.substringBeforeLast(' ', firmware)

    /** True for a Mesh-Detect board (no buzzer; its fw label starts "mesh-detect"). */
    val isMeshDetect: Boolean get() = firmware.startsWith("mesh-detect")

    /** True when the BOARD speaks a newer contract than this app understands. The honest response
     *  is to say so and stop trusting the parse, rather than keep reading fields whose meaning may
     *  have changed underneath. Mirrors iOS DeviceStatus.needsNewerApp. */
    val needsNewerApp: Boolean get() = protoVersion > SUPPORTED_PROTO_VERSION

    companion object {
        /** Newest BLE JSON contract this build can parse. Raise it in the SAME commit that teaches
         *  the app that contract, never ahead of it. Mirrors iOS supportedProtoVersion. */
        const val SUPPORTED_PROTO_VERSION = 2

        fun fromJson(o: JSONObject) = DeviceStatus(
            firmware = o.optString("fw", ""),
            uptime = o.optInt("up", 0),
            total = o.optInt("total", 0),
            ble = o.optBoolean("ble", false),
            wifi = o.optBoolean("wifi", false),
            wifiEco = o.optInt("wifiEco", 0),
            // ALPR (Flock) + drone (Remote ID) detectors; absent = on (default), like glasses
            flock = o.optBoolean("flock", true),
            drone = o.optBoolean("drone", true),
            // drone OUI-fallback state; absent = off (the board only reports it when enabled)
            droui = o.optBoolean("droui", false),
            // accept the new "bodycam" key, fall back to the legacy "axon" one
            bodyCam = o.optBoolean("bodycam", o.optBoolean("axon", false)),
            // Motorola-proxy sub-toggle; absent = pre-split firmware, where the proxy is welded
            // to the body-cam category and always on, so report it on and let motoSupported
            // tell the UI there's no switch to offer.
            moto = o.optBoolean("moto", true),
            motoSupported = o.has("moto"),
            tracker = o.optBoolean("tracker", false),
            // glasses detector defaults ON in the firmware, so absent = on (pre-glasses
            // firmware has nothing to control anyway); matches iOS
            glasses = o.optBoolean("glasses", true),
            // network-camera opt-in state; absent = off (the board only reports it when enabled)
            ncam = o.optBoolean("ncam", false),
            buzzer = o.optBoolean("buzzer", false),
            volume = o.optInt("vol", 80),
            ledOn = o.optBoolean("ledon", true),   // board omits it when on, so absent = on
            gps = o.optBoolean("gps", false),
            bufCount = o.optInt("buf", 0),
            bufOn = o.optBoolean("bufon", false),
            bufferSaturated = o.optBoolean("bufsat", false),
            bufferFaults = o.optLong("buferr", 0L).coerceIn(0L, 0xFFFF_FFFFL),
            bufferKeyMismatch = o.optBoolean("keymis", false),
            desertMode = o.optBoolean("desert", false),
            ignoreCount = o.optInt("ign", 0),
            watchCount = o.optInt("wat", 0),
            battery = if (o.has("bat")) o.optInt("bat") else null,
            // dual-radio only; absent on single-radio boards, so null = unknown = no warning
            coAlive = if (o.has("co")) o.optBoolean("co") else null,
            // nRF mid BLE DFU; the board sends it only while true, so absent = not updating
            nrfUpdating = o.optBoolean("nrfup", false),
            // running nRF co-processor version; absent until the co-proc reports (or single-radio)
            nrfVersion = if (o.has("nrfv")) o.optInt("nrfv") else null,
            charging = o.optBoolean("chg", false),
            // a deferred buffer erase still sweeping; absent = idle
            wiping = o.optBoolean("wiping", false),
            // carrier revision; null when the key is absent. optString would hand back "" for a
            // missing key, which is not the same thing as "not told", so screen it explicitly.
            boardRev = o.optString("rev", "").ifEmpty { null },
            // ABSENT MEANS 0, not unknown. Every firmware shipped before 2026-08-06 omits this key
            // and is fully compatible with this app, so a missing key must read as "fine". Only a
            // board reporting a HIGHER proto than this build understands is a problem.
            protoVersion = o.optInt("proto", 0),
        )
    }
}

/** A user-visible consequence of the board's offline-buffer health fields. These are modelled
 *  rather than assembled ad hoc in each screen because BOTH the Logbook and the board control
 *  must tell the same truth, and the cross-platform tests pin the wording and priority. */
enum class BufferHealthNotice(
    val title: String,
    val detail: String,
    val critical: Boolean,
) {
    KEY_NOT_ACCEPTED(
        "BUFFER KEY NOT ACCEPTED",
        "This phone’s buffer key was not accepted. Existing history was preserved and was not replayed. Sync with the originating phone, or explicitly clear the board buffer to transfer.",
        true,
    ),
    STORAGE_FAILED(
        "OFFLINE LOG INCOMPLETE",
        "Offline logging encountered a storage or encryption failure. Some offline detections may be missing or unavailable. Clear the offline buffer after reviewing or exporting it to reset this warning.",
        true,
    ),
    CAPACITY_REACHED(
        "CAPTURE REACHED CAPACITY",
        "Stationary capture filled the board. Later nearby detections may be missing. Export what synced, then clear the board buffer before another deployment.",
        false,
    ),
    PERSISTENCE_ERROR_RECORDED(
        "BUFFER METADATA ERROR RECORDED",
        "The board recorded an offline-buffer metadata save/load error. Current status may already reflect a successful retry; confirm buffer state and replay timestamps before relying on them. Clear the board buffer to reset this warning.",
        false,
    ),
}

/** Ordered most severe first. Unknown future fault bits are treated as storage-blocking instead
 *  of disappearing from the UI; a newer board can still raise the protocol-version warning too. */
val DeviceStatus.bufferHealthNotices: List<BufferHealthNotice>
    get() = buildList {
        if (bufferKeyMismatch) add(BufferHealthNotice.KEY_NOT_ACCEPTED)
        val nonNvsFaults = bufferFaults and 0x20L.inv()
        if (nonNvsFaults != 0L) add(BufferHealthNotice.STORAGE_FAILED)
        if (bufferSaturated) add(BufferHealthNotice.CAPACITY_REACHED)
        if (bufferFaults and 0x20L != 0L) add(BufferHealthNotice.PERSISTENCE_ERROR_RECORDED)
    }

// org.json hands back "" instead of null for a missing string, so normalize it.
private fun JSONObject.stringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) optString(key).takeIf { it.isNotEmpty() } else null

private fun JSONObject.doubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) optDouble(key).takeIf { it.isFinite() } else null

private data class WireNumericFields(
    val seq: Long = 0L,
    val at: Long = 0L,
    val ms: Long = 0L,
    val boot: Long = 0L,
    val from: Long = 0L,
    val gen: Long = 0L,
    val rssi: Int = 0,
)

private val JSON_NUMBER_LEXEME =
    Regex("-?(?:0|[1-9][0-9]*)(?:\\.[0-9]+)?(?:[eE][+-]?[0-9]+)?")

/** Extract the replay protocol's top-level uint32 fields and RSSI while their source spelling is
 * still available. [Detection.fromWireJson] consumes seq/at/ms/boot/rssi;
 * [historyBeginFromOrAbsent] consumes the begin sentinel's `from` cursor.
 *
 * Android's JSONTokener represents decimal/exponent tokens as Double, so e.g.
 * `1.0000000000000000001` is already indistinguishable from integer 1 in a JSONObject. The BLE
 * boundary therefore gets these values from raw lexemes and uses the JSONObject for every other
 * field. If the outer object cannot be scanned to completion, all values become absent rather than
 * falling back to a rounded Number. Duplicate precision-sensitive numeric keys fail that field
 * closed, including duplicates that use JSON escapes, matching iOS's raw scanner. */
private fun String.wireNumericFields(): WireNumericFields? {
    val cursor = JsonLexemeCursor(this)
    var seenNumeric = 0
    return cursor.readTopLevelObject { key, lexeme, current ->
        val fieldBit = when (key) {
            "seq" -> 1 shl 0
            "at" -> 1 shl 1
            "ms" -> 1 shl 2
            "boot" -> 1 shl 3
            "from" -> 1 shl 4
            "rssi" -> 1 shl 5
            "gen" -> 1 shl 6
            else -> 0
        }
        if (fieldBit == 0) return@readTopLevelObject current

        // Once a key appears twice it remains absent even if a third spelling is valid. JSON
        // leaves duplicate-member semantics undefined, so a cursor, timestamp or RSSI must not
        // depend on whether JSONObject happened to keep the first or last occurrence.
        val duplicate = seenNumeric and fieldBit != 0
        seenNumeric = seenNumeric or fieldBit
        if (key == "rssi") {
            return@readTopLevelObject current.copy(
                rssi = if (duplicate) 0 else lexeme.exactInt16ClampedOrAbsent(),
            )
        }
        val value = if (duplicate) 0L else lexeme.exactUint32OrNull() ?: 0L
        when (key) {
            "seq" -> current.copy(seq = value)
            "at" -> current.copy(at = value)
            "ms" -> current.copy(ms = value)
            "boot" -> current.copy(boot = value)
            "from" -> current.copy(from = value)
            "gen" -> current.copy(gen = value)
            else -> current
        }
    }
}

/** Exact first replay sequence from a raw `hist:begin` sentinel, or 0 when missing/invalid.
 * A real drain starts at seq >= 1; zero is both the uint32 value and this call site's existing
 * "do not rebase" sentinel. The upper bound is enforced by [wireNumericFields] before subtraction,
 * so `from - 1` in the caller always remains inside uint32 as well. */
internal fun historyBeginFromOrAbsent(raw: String): Long =
    (raw.wireNumericFields()?.from ?: 0L).takeIf { it >= 1L } ?: 0L

/** Exact nonzero replay-generation identifier from a raw `hist:begin` sentinel. */
internal fun historyBeginGenerationOrAbsent(raw: String): Long =
    (raw.wireNumericFields()?.gen ?: 0L).takeIf { it >= 1L } ?: 0L

private fun String.exactUint32OrNull(): Long? {
    if (!JSON_NUMBER_LEXEME.matches(this)) return null
    val value = runCatching { java.math.BigDecimal(this).longValueExact() }.getOrNull() ?: return null
    return value.takeIf { it in 0L..0xFFFF_FFFFL }
}

/** An integral JSON number interpreted like iOS's Int decode, then clamped to firmware's int16
 * RSSI type. String/null/fractional/non-finite tokens and integers outside signed 64-bit are
 * absent (0). The raw-wire path calls this before Android's JSONTokener can round a tiny fraction
 * into an integral Double; [JSONObject.int16Clamped] applies the same rule to stored/demo data. */
private fun String.exactInt16ClampedOrAbsent(): Int {
    if (!JSON_NUMBER_LEXEME.matches(this)) return 0
    val value = runCatching { java.math.BigDecimal(this).longValueExact() }.getOrNull() ?: return 0
    return value.coerceIn(-32_768L, 32_767L).toInt()
}

/** Minimal JSON structural cursor for top-level property values. It deliberately does not build a
 * second object tree or validate unrelated scalar grammar: JSONObject remains the syntax/parser
 * authority, while this cursor only retains exact value substrings for the replay protocol's
 * precision-sensitive fields. */
private class JsonLexemeCursor(private val raw: String) {
    private var index = 0

    fun readTopLevelObject(
        consume: (key: String, lexeme: String, current: WireNumericFields) -> WireNumericFields,
    ): WireNumericFields? {
        skipWhitespace()
        if (!take('{')) return null
        skipWhitespace()
        var fields = WireNumericFields()
        if (take('}')) return fields.takeIf { atEnd() }

        while (true) {
            val key = readString() ?: return null
            skipWhitespace()
            if (!take(':')) return null
            skipWhitespace()
            val lexeme = readValueLexeme() ?: return null
            fields = consume(key, lexeme, fields)
            skipWhitespace()
            when {
                take(',') -> skipWhitespace()
                take('}') -> return fields.takeIf { atEnd() }
                else -> return null
            }
        }
    }

    private fun readValueLexeme(): String? {
        if (index >= raw.length) return null
        val start = index
        when (raw[index]) {
            '"' -> if (readString() == null) return null
            '{', '[' -> if (!skipCompound()) return null
            else -> {
                while (index < raw.length && raw[index] != ',' && raw[index] != '}') index++
            }
        }
        var end = index
        while (end > start && raw[end - 1].isJsonWhitespace()) end--
        if (end == start) return null
        return raw.substring(start, end)
    }

    private fun skipCompound(): Boolean {
        val closers = mutableListOf(if (raw[index] == '{') '}' else ']')
        index++
        while (index < raw.length) {
            when (val c = raw[index]) {
                '"' -> if (readString() == null) return false
                '{' -> { closers += '}'; index++ }
                '[' -> { closers += ']'; index++ }
                '}', ']' -> {
                    if (closers.lastOrNull() != c) return false
                    closers.removeAt(closers.lastIndex)
                    index++
                    if (closers.isEmpty()) return true
                }
                else -> index++
            }
        }
        return false
    }

    private fun readString(): String? {
        if (!take('"')) return null
        val out = StringBuilder()
        while (index < raw.length) {
            val c = raw[index++]
            when {
                c == '"' -> return out.toString()
                c == '\\' -> {
                    if (index >= raw.length) return null
                    when (val escaped = raw[index++]) {
                        '"', '\\', '/' -> out.append(escaped)
                        'b' -> out.append('\b')
                        'f' -> out.append('\u000C')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'u' -> {
                            if (index + 4 > raw.length) return null
                            var code = 0
                            repeat(4) {
                                val digit = raw[index++].digitToIntOrNull(16) ?: return null
                                code = code * 16 + digit
                            }
                            out.append(code.toChar())
                        }
                        else -> return null
                    }
                }
                c < ' ' -> return null
                else -> out.append(c)
            }
        }
        return null
    }

    private fun skipWhitespace() {
        while (index < raw.length && raw[index].isJsonWhitespace()) index++
    }

    private fun take(expected: Char): Boolean {
        if (index >= raw.length || raw[index] != expected) return false
        index++
        return true
    }

    private fun atEnd(): Boolean {
        skipWhitespace()
        return index == raw.length
    }
}

private fun Char.isJsonWhitespace(): Boolean = this == ' ' || this == '\t' || this == '\r' || this == '\n'

/** One uint32 field off the wire (firmware det_log.h), or 0 - every one of these fields' own
 *  "not sent" value - when the key is missing, null, not a JSON number, fractional, or outside
 *  the wire type's range. This is the JSONObject-only fallback for app-authored persisted/demo
 *  objects. Raw BLE frames use [wireNumericFields], because no helper can recover precision that
 *  Android's JSONTokener has already rounded away. iOS drops the same values at its own decode
 *  boundary (Detection.init(from:)); the shared fixtures are in AcabBleManagerExportTest and
 *  ExportTests.
 *
 *  Converted with [java.math.BigDecimal.longValueExact], not optLong or an intermediate Double.
 *  Narrowing to Long happens BEFORE a range check inside optLong and is not range-preserving: on
 *  the reference org.json the unit tests run against, `1e30` parses to a BigDecimal and optLong
 *  wraps it modulo 2^64. Double is not exact enough for the integrality check either:
 *  `1.0000000000000000001` rounds to 1.0 before the check and would manufacture a sequence
 *  number the wire did not carry. JSON's integral Number implementations take the direct Long
 *  path. Decimal/exponent Number implementations are checked exactly when they still retain their
 *  spelling; [fromWireJson] handles the Android runtime case where they do not. */
private fun JSONObject.uint32OrAbsent(key: String): Long {
    val number = opt(key) as? Number ?: return 0L
    val value = when (number) {
        is Byte, is Short, is Int, is Long -> number.toLong()
        else -> runCatching {
            java.math.BigDecimal(number.toString()).longValueExact()
        }.getOrNull() ?: return 0L
    }
    return value.takeIf { it in 0L..0xFFFF_FFFFL } ?: 0L
}

/** One int16 dBm from an already-materialized object. Requiring a Number before parsing prevents
 * JSONObject's optDouble coercion from turning a numeric string into trusted wire data. */
private fun JSONObject.int16Clamped(key: String): Int {
    val number = opt(key) as? Number ?: return 0
    return number.toString().exactInt16ClampedOrAbsent()
}

/** True for a finite, in-range, non-null-island coordinate. Rejects the ~214-deg junk a garbled
 *  drone Remote ID can decode to, which would wedge the osmdroid map (mirrors iOS
 *  CLLocationCoordinate2DIsValid + a (0,0) reject). */
fun validCoord(lat: Double?, lon: Double?): Boolean =
    lat != null && lon != null && lat.isFinite() && lon.isFinite() &&
    kotlin.math.abs(lat) <= 90.0 && kotlin.math.abs(lon) <= 180.0 && !(lat == 0.0 && lon == 0.0)
