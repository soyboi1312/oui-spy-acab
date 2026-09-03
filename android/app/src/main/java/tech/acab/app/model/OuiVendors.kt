package tech.acab.app.model

/** The IEEE-registered vendor for each Flock OUI the detector watches. Flock uses
 *  off-the-shelf modules, so most of these are chipset makers (Liteon, Espressif, USI,
 *  Silicon Labs) or consumer brands, not Flock itself. Shown on the detail screen to
 *  keep an OUI match honest - only b41e52 is actually Flock's. */
val OUI_VENDORS: Map<String, String> = mapOf(
    // Motorola Solutions' own MA-L blocks. All seven that the firmware's broad vendor proxy
    // watches are in this map, but it is sorted by OUI, so they read scattered rather than
    // grouped: 00047d, 001885, 001f92, 4ccc34, plus the Malaysia manufacturing entity 10746f,
    // 9c862b, b8e28c. Motorola MOBILITY / Lenovo blocks are deliberately absent, that is the
    // unrelated consumer phone business. A match here names the VENDOR honestly; what the device
    // IS (radio, dock, camera, infrastructure) stays open, which is why the proxy scores only 45.
    "00047d" to "Motorola Solutions",
    // Utility Inc. "BodyWorn" body cams. Both blocks are MA-L, registrant "Utility, Inc." /
    // "Utility Inc". Weak on their own - Utility makes other gear too - so the advertised
    // "BodyWorn Remote" name is the strong match and the OUI is only the fallback.
    "0009bc" to "Utility Inc",
    "0016ed" to "Utility Inc",
    "00180a" to "Cisco Meraki",
    "001885" to "Motorola Solutions",
    "001f92" to "Motorola Solutions",
    "00236c" to "Apple",
    // Axon's sole IEEE block. Named here so an Axon OUI hit reads the real vendor instead
    // of falling back to the body-cam category's three-maker guess.
    "0025df" to "Axon Enterprise",
    "00f48d" to "Liteon",
    "040d84" to "Silicon Labs",
    "083a88" to "USI",
    // Motorola Solutions Malaysia Sdn. Bhd., their manufacturing entity, same corporate group.
    "10746f" to "Motorola Solutions",
    "145afc" to "Liteon",
    "14b5cd" to "Liteon",
    "1c34f1" to "Silicon Labs",
    "1cb72c" to "ASUSTek",
    "240ac4" to "Espressif",
    "246f28" to "Espressif",
    "24b2b9" to "Liteon",
    "2cf432" to "Espressif",
    "30aea4" to "Espressif",
    "385b44" to "Silicon Labs",
    "3c6105" to "Espressif",
    "3c71bf" to "Espressif",
    "3c9180" to "Liteon",
    "4827ea" to "Samsung",
    // Shared Motorola Solutions block (body cams, radios, and other LE/enterprise gear ride it),
    // so a match here names the vendor, not a specific device. The one block that is actually
    // field-observed on 2.4 GHz WiFi (own capture 2026-07-18), which is what establishes this
    // vendor as detectable at all; the six siblings are the same product lines.
    "4ccc34" to "Motorola Solutions",
    "5800e3" to "Liteon",
    "588e81" to "Silicon Labs",
    "5c93a2" to "Liteon",
    "646e69" to "Liteon",
    "700894" to "Liteon",
    "70c94e" to "Liteon",
    "744ca1" to "Liteon",
    "803049" to "Liteon",
    "840d8e" to "Espressif",
    "84f3eb" to "Espressif",
    "8caab5" to "Espressif",
    "9035ea" to "Silicon Labs",
    "940853" to "Liteon",
    "942a6f" to "Ubiquiti",
    "943469" to "Silicon Labs",
    "98f4ab" to "Espressif",
    "9c2f9d" to "Liteon",
    "9c862b" to "Motorola Solutions",   // Motorola Solutions Malaysia Sdn. Bhd.
    "9c9c1f" to "Espressif",
    "a0c9a0" to "Murata",
    "a4cf12" to "Espressif",
    "ac67b2" to "Espressif",
    "b41e52" to "Flock Safety",
    "b4e3f9" to "Silicon Labs",
    "b81ea4" to "Liteon",
    "b8e28c" to "Motorola Solutions",   // Motorola Solutions Malaysia Sdn. Bhd.
    "bcddc2" to "Espressif",
    "c03532" to "Liteon",
    "c82b96" to "Espressif",
    "cc50e3" to "Espressif",
    "d03957" to "Liteon",
    "d411d6" to "ShotSpotter",
    "d8a01d" to "Espressif",
    "d8f3bc" to "Liteon",
    "dc5475" to "Espressif",
    "e00af6" to "Liteon",
    "e04f43" to "USI",
    "e4aaea" to "Liteon",
    "e8d0fc" to "Liteon",
    "ec1bbd" to "Silicon Labs",
    "ec6260" to "Espressif",
    "f082c0" to "Silicon Labs",
    "f46add" to "Liteon",
    "f4cfa2" to "Espressif",
    "f4e2c6" to "Ubiquiti",
    "f8a2d6" to "Liteon",
    "fcf5c4" to "Espressif",
)

/** Registered vendor for the MAC's OUI prefix, if we know it. */
val Detection.ouiVendor: String?
    get() {
        val hex = mac.lowercase().filter { it != ':' && it != '-' }
        return if (hex.length >= 6) OUI_VENDORS[hex.take(6)] else null
    }

/** Readable "matched on" label for the firmware's `meth` int. */
val Detection.methodLabel: String
    get() = when (method) {
        1 -> "OUI match"
        2 -> "device name"
        3 -> "manufacturer ID"
        4 -> "service UUID"
        5 -> "SSID"
        6 -> "wildcard probe"
        7 -> "Remote ID"
        8 -> "service data"
        9 -> "manufacturer subtype"
        10 -> "watchlist"
        else -> "unknown"
    }

/** Readable radio-source label for the firmware's `s` int. */
val Detection.sourceLabel: String
    get() = when (source) {
        0 -> "BLE"
        1 -> "WiFi"
        2 -> "Remote ID"
        else -> "?"
    }

/** True when only the OUI matched - the case that's prone to false positives. */
val Detection.isOuiMatch: Boolean get() = method == 1

/** User-assigned names for specific MACs, shared so [displayName] can consult them WITHOUT every
 *  composable threading the BLE manager down to the row that draws the label.
 *
 *  WHY A REGISTRY: a Detection is a value type built from a BLE notify; it has no idea the user
 *  starred or muted that MAC. Resolving here means the custom name reaches the log row, the detail
 *  screen, the map pin, the CSV export and notifications from one place. Rebuilt only when the
 *  watched/ignored lists change (a tap), so a plain map is plenty.
 *  Keys are ALWAYS lowercased MACs, matching how both lists store them. Mirrors iOS DeviceNames. */
object DeviceNames {
    @Volatile private var byMac: Map<String, String> = emptyMap()
    fun label(mac: String): String? = byMac[mac.lowercase()]?.takeIf { it.isNotEmpty() }
    /** Watched wins over ignored if a MAC somehow lands on both list files. */
    fun rebuild(watchedPairs: List<Pair<String, String>>, ignoredPairs: List<Pair<String, String>>) {
        val m = HashMap<String, String>(watchedPairs.size + ignoredPairs.size)
        ignoredPairs.forEach { (mac, l) -> if (l.isNotEmpty()) m[mac.lowercase()] = l }
        watchedPairs.forEach { (mac, l) -> if (l.isNotEmpty()) m[mac.lowercase()] = l }
        byMac = m
    }
}

/** A name the USER assigned to this exact MAC on the managed-devices screen (watched or ignored). */
val Detection.customName: String? get() = DeviceNames.label(mac)

/** Best label we have: the user's own name, else advertised name, else UAS serial, else the
 *  manufacturer the device broadcast, else device class. Feeds the log row, the ignore list, and
 *  CSV export. Mirrors iOS Detection.displayName exactly so the same record leads with the same
 *  label on both platforms.
 *
 *  The `maker` rung is why a log full of network cameras no longer reads "Network camera" twelve
 *  times beside a glyph that already said so. It sits BELOW the UAS serial (a drone's serial is a
 *  unique handle and beats a maker shared by every DJI in the sky) and ABOVE type.label. */
val Detection.displayName: String
    get() = customName
        ?: name?.takeIf { it.isNotEmpty() }
        ?: rid?.takeIf { it.isNotEmpty() }
        ?: maker
        ?: type.label

/** True when the row leads with something other than the bare device class. Derived FROM
 *  displayName rather than re-listing its steps, so the two cannot drift: a row that leads with
 *  "Hikvision" while hasName reports false would render the category in NEITHER the title nor the
 *  subtitle. Mirrors iOS Detection.hasName. */
val Detection.hasName: Boolean get() = displayName != type.label

/** Which body-cam signature actually fired. Body cam is the one category that carries
 *  several makers' signatures at once, so the category alone cannot name a vendor: an Axon
 *  payload tag and the broad Motorola proxy both arrive as t=3. The firmware distinguishes
 *  them in the detail string, so that string is what we read. Raw values MUST match the
 *  strings set in axon_detect.cpp and police_detect.cpp. Mirrors iOS BodyCamSignature. */
enum class BodyCamSignature(val raw: String) {
    AXON_PAYLOAD("BWC DEVICE"),
    AXON_OUI("Axon OUI"),
    UTILITY("Utility BodyWorn"),
    MOTOROLA("Motorola Solutions OUI");

    /** Who makes the device this signature fired on. Known exactly in every case, which
     *  is the point: the category's guess would name three makers for all four. */
    val vendor: String
        get() = when (this) {
            AXON_PAYLOAD, AXON_OUI -> "Axon Enterprise"
            UTILITY                -> "Utility Inc"
            MOTOROLA               -> "Motorola Solutions"
        }

    companion object {
        fun from(raw: String): BodyCamSignature? = entries.firstOrNull { it.raw == raw }
    }
}

/** The body-cam signature behind this hit, when the board reported one. null for every
 *  other category, and for a pre-split board that sent no detail string. */
val Detection.bodyCamSignature: BodyCamSignature?
    get() {
        if (type != DeviceType.BODY_CAM) return null
        return detail?.let { BodyCamSignature.from(it) }
    }

/** Names that identify the radio module rather than the product. Backstop only, see [maker]. */
private val NOT_A_MAKER = setOf(
    "espressif", "liteon", "lite-on", "silicon labs", "silabs", "usi",
    "murata", "jieli", "realtek", "asustek", "heycyan", "unknown",
)

/** Trims, and refuses any name that identifies SILICON rather than a product. Nothing the
 *  firmware can currently emit hits the deny-list (the glasses colon rule already self-excludes
 *  Jieli and HeyCyan, neither of which contains a colon). It exists so a FUTURE firmware string
 *  cannot: glasses_signatures.h calls Jieli "the Espressif problem in miniature - the ID
 *  identifies the SILICON, not the product". */
private fun cleanMaker(s: String?): String? {
    val t = s?.trim().orEmpty()
    return if (t.isEmpty() || t.lowercase() in NOT_A_MAKER) null else t   // "Anker/eufy" verbatim
}

/** True when an OUI registrant is a chipset or module vendor rather than the product's maker.
 *  Annotates the dossier's OUI row, because a reader cannot be expected to know that Liteon is a
 *  WiFi module house. Mirrors iOS isChipsetRegistrant. */
fun isChipsetRegistrant(vendor: String): Boolean = vendor in setOf(
    "Espressif", "Liteon", "Silicon Labs", "USI", "Murata", "Realtek", "ASUSTek",
)

/** The company that MADE this exact device, read ONLY off the device's own payload. Mirrors iOS
 *  Detection.maker step for step, string for string, so the same record leads with the same label
 *  on both platforms.
 *
 *  WHY THIS EXISTS: an unnamed detection used to lead its log row with the category label, so
 *  twelve cameras in a row all read "Network camera" beside a glyph that already said network
 *  camera. The manufacturer was on the wire the whole time and both apps threw it away:
 *  netcam_detect.cpp writes "<vendor> on wifi" from its camera-vendor prefix tables;
 *  those vendors are absent from OUI_VENDORS, so [ouiVendor] cannot supply these labels.
 *
 *  READ THIS BEFORE ADDING A STEP: the maker is a WEAKER claim than the category label it
 *  replaces, not a stronger one. "Hikvision" could be an NVR or a doorbell; "Network camera"
 *  asserts the product class. That is the whole justification for promoting it to the title, and
 *  it only holds while every step below names a company the DEVICE ITSELF broadcast.
 *
 *  NEVER reads [ouiVendor]. Not as a fallback, not as a last resort. 56 of the 74 entries in
 *  OUI_VENDORS are silicon or module vendors, and all four SHIPPING Falcon probe OUIs are Liteon
 *  blocks, so an OUI-fed title prints the WiFi module on a genuine plate reader. Desert mode and
 *  the watchlist pass arbitrary MACs, which is how the 21 Espressif blocks become reachable, and
 *  our own board is an ESP32-S3 that other boards detect. Also never [DeviceType.brand] (a 1:1
 *  function of the category, so it would rebuild the same wall of identical rows in different
 *  words) and never bleCompanyName (would title every passing iPhone "Apple").
 *
 *  null for ALPR, Raven, Desert, watchlist, unknown, and every row replayed from the offline
 *  buffer: StoredDet carries no detail field, so a replayed row has no vendor route at all and
 *  correctly degrades to the category. Do not fill that gap with a guess. */
val Detection.maker: String?
    get() {
        // 1. Body cam: the four-string wire contract both apps already match on exactly.
        bodyCamSignature?.let { return cleanMaker(it.vendor) }
        // 2. Drone Remote ID. ridManufacturer passes an unrecognised CTA-2063 code straight
        //    through as "Mfr 7A3C", which must never become a row title.
        ridManufacturer?.takeIf { !it.startsWith("Mfr ") }?.let { return cleanMaker(it) }
        val det = detail?.takeIf { it.isNotEmpty() } ?: return null
        // 3. TYPE-GATED, AFFIX-ANCHORED parsing. Deliberately not a generic "first token" rule:
        //    that would turn "Axon OUI" into "Axon" (erasing that this is the WEAK variant, not
        //    the conf-90 payload tag) and "Motorola Solutions OUI" into "Motorola", which reads
        //    as Motorola MOBILITY, a different company. The suffix anchors are safe against the
        //    body-cam contract precisely because the WiFi body-cam path omits " on wifi" to stay
        //    byte-identical to its BLE strings.
        return when (type) {
            DeviceType.NETWORK_CAMERA ->
                cleanMaker(det.removeSuffix(" on wifi").takeIf { it != det })
            // METHOD GATE, and it is load-bearing. Drone is the ONE parsed type whose detail can
            // contain REMOTE-DEVICE TEXT: on the Remote ID path the firmware writes "op %s" from
            // the broadcaster's 20-byte ODID Operator ID (drone_detect.cpp), so a crafted
            // Operator ID whose last 19 bytes are exactly this anchor would make the row title,
            // the dossier Maker row and the CSV read "op". The vendor-OUI fallback that actually
            // emits this string sets method = OUI, while the attacker-reachable "op ..." detail
            // only ever arrives as Remote ID, so requiring OUI here closes it. The deny-list
            // cannot: it screens silicon vendor names, not arbitrary broadcast text.
            DeviceType.DRONE ->
                if (!isOuiMatch) null
                else cleanMaker(det.removeSuffix(" gear, no Remote ID").takeIf { it != det })
            // The firmware encodes confidence as ":" and hedging as "?", so the colon rule admits
            // "Ray-Ban Meta: ..." and "Meta: ..." while self-excluding "HeyCyan glasses UUID",
            // "Jieli chipset? ..." and "TCL/RayNeo? ...". Do not relax this to a prefix match.
            DeviceType.GLASSES ->
                cleanMaker(det.substringBefore(':', "").takeIf { it.isNotEmpty() })
            // Exact map, no parsing. "Apple Find My" rather than "Apple" on purpose: Chipolo and
            // Pebblebee tags advertise the same offline Find My payload, so the NETWORK is what
            // was proved, not the manufacturer. "(offline)" is dropped from the title only
            // because it would read as the row's OFFLINE buffer-replay tag, which it is not.
            DeviceType.TRACKER -> when (det) {
                "Apple Find My (offline)" -> "Apple Find My"
                "Tile"                    -> "Tile"
                "Samsung SmartTag"        -> "Samsung SmartTag"
                // "(separated)" dropped for the same reason "(offline)" is above: it describes the
                // tag's STATE, not its maker, and the row already conveys the state.
                "Google Find Hub (separated)" -> "Google Find Hub"
                else                      -> null
            }
            else -> null
        }
    }
