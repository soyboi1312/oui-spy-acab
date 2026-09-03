import Foundation

/// The IEEE-registered vendor for each OUI the detector watches. Flock uses
/// off-the-shelf modules, so most of these are chipset makers (Liteon, Espressif, USI,
/// Silicon Labs) or consumer brands. Only b41e52 is actually Flock's. We show this on
/// the detail screen so an OUI match reads honestly.
///
/// The body-cam blocks at the front of the table are the opposite case: they are the
/// makers' OWN registrations, so a hit there does name the real vendor, and leaving them
/// out made the detail screen fall back to the category's assumed maker and print the
/// wrong company on a Motorola or Utility hit.
enum OUIVendors {
    static let table: [String: String] = [
        "00047d": "Motorola Solutions",
        "0009bc": "Utility Inc",
        "0016ed": "Utility Inc",
        "00180a": "Cisco Meraki",
        "001885": "Motorola Solutions",
        "001f92": "Motorola Solutions",
        "00236c": "Apple",
        // Axon's sole IEEE block. Named here so the honest per-signature vendor below
        // never has to guess on an Axon OUI hit.
        "0025df": "Axon Enterprise",
        "00f48d": "Liteon",
        "040d84": "Silicon Labs",
        "083a88": "USI",
        // 10746f, b8e28c and 9c862b are registered to Motorola Solutions Malaysia Sdn.
        // Bhd., the group's manufacturing entity, so they read as the parent brand here.
        "10746f": "Motorola Solutions",
        "145afc": "Liteon",
        "14b5cd": "Liteon",
        "1c34f1": "Silicon Labs",
        "1cb72c": "ASUSTek",
        "240ac4": "Espressif",
        "246f28": "Espressif",
        "24b2b9": "Liteon",
        "2cf432": "Espressif",
        "30aea4": "Espressif",
        "385b44": "Silicon Labs",
        "3c6105": "Espressif",
        "3c71bf": "Espressif",
        "3c9180": "Liteon",
        "4827ea": "Samsung",
        "4ccc34": "Motorola Solutions",
        "5800e3": "Liteon",
        "588e81": "Silicon Labs",
        "5c93a2": "Liteon",
        "646e69": "Liteon",
        "700894": "Liteon",
        "70c94e": "Liteon",
        "744ca1": "Liteon",
        "803049": "Liteon",
        "840d8e": "Espressif",
        "84f3eb": "Espressif",
        "8caab5": "Espressif",
        "9035ea": "Silicon Labs",
        "940853": "Liteon",
        "942a6f": "Ubiquiti",
        "943469": "Silicon Labs",
        "98f4ab": "Espressif",
        "9c2f9d": "Liteon",
        "9c862b": "Motorola Solutions",
        "9c9c1f": "Espressif",
        "a0c9a0": "Murata",
        "a4cf12": "Espressif",
        "ac67b2": "Espressif",
        "b41e52": "Flock Safety",
        "b4e3f9": "Silicon Labs",
        "b81ea4": "Liteon",
        "b8e28c": "Motorola Solutions",
        "bcddc2": "Espressif",
        "c03532": "Liteon",
        "c82b96": "Espressif",
        "cc50e3": "Espressif",
        "d03957": "Liteon",
        "d411d6": "ShotSpotter",
        "d8a01d": "Espressif",
        "d8f3bc": "Liteon",
        "dc5475": "Espressif",
        "e00af6": "Liteon",
        "e04f43": "USI",
        "e4aaea": "Liteon",
        "e8d0fc": "Liteon",
        "ec1bbd": "Silicon Labs",
        "ec6260": "Espressif",
        "f082c0": "Silicon Labs",
        "f46add": "Liteon",
        "f4cfa2": "Espressif",
        "f4e2c6": "Ubiquiti",
        "f8a2d6": "Liteon",
        "fcf5c4": "Espressif",
    ]
}

extension Detection {
    /// Registered vendor for the MAC's OUI prefix, if we know it.
    var ouiVendor: String? {
        let hex = mac.lowercased().filter { $0 != ":" && $0 != "-" }
        guard hex.count >= 6 else { return nil }
        return OUIVendors.table[String(hex.prefix(6))]
    }
}

/// Which body-cam signature actually fired. Body cam is the one category that carries
/// several makers' signatures at once, so the category alone cannot name a vendor or a
/// strength: an Axon payload tag and the broad Motorola proxy both arrive as t=3. The
/// firmware distinguishes them in the detail string, so that string is what we read.
/// Raw values MUST match the strings set in axon_detect.cpp and police_detect.cpp.
enum BodyCamSignature: String {
    case axonPayload = "BWC DEVICE"
    case axonOUI     = "Axon OUI"
    case utility     = "Utility BodyWorn"
    case motorola    = "Motorola Solutions OUI"

    /// Who makes the device this signature fired on. Known exactly in every case, which
    /// is the point: the category's guess would name Axon for all four.
    var vendor: String {
        switch self {
        case .axonPayload, .axonOUI: return "Axon Enterprise"
        case .utility:               return "Utility Inc"
        case .motorola:              return "Motorola Solutions"
        }
    }
}

extension Detection {
    /// The body-cam signature behind this hit, when the board reported one. nil for every
    /// other category, and for a pre-split board that sent no detail string.
    var bodyCamSignature: BodyCamSignature? {
        guard type == .axonBodyCam, let det = detail else { return nil }
        return BodyCamSignature(rawValue: det)
    }

    /// The company that MADE this exact device, read ONLY off the device's own payload.
    ///
    /// WHY THIS EXISTS: an unnamed detection used to lead its log row with the category label, so
    /// twelve cameras in a row all read "Network camera" beside a glyph that already said network
    /// camera. The manufacturer was on the wire the whole time and both apps threw it away:
    /// netcam_detect.cpp writes "<vendor> on wifi" from its camera-vendor prefix tables;
    /// those vendors are absent from OUIVendors.table, so `ouiVendor` cannot supply these labels.
    ///
    /// READ THIS BEFORE ADDING A STEP: the maker is a WEAKER claim than the category label it
    /// replaces, not a stronger one. "Hikvision" could be an NVR or a doorbell; "Network camera"
    /// asserts the product class. That is the whole justification for promoting it to the title,
    /// and it only holds while every step below names a company the DEVICE ITSELF broadcast.
    ///
    /// NEVER consults `ouiVendor`. Not as a fallback, not as a last resort. 56 of the 74 entries
    /// in OUIVendors.table are silicon or module vendors, and all four SHIPPING Falcon probe OUIs
    /// (flock_signatures.h) are Liteon blocks, so an OUI-fed title prints the WiFi module on a
    /// genuine plate reader. Desert mode and the watchlist pass arbitrary MACs, which is how the
    /// 21 Espressif blocks become reachable, and our own board is an ESP32-S3 that other boards
    /// detect. The dossier subtitle already made this exact call (see the "NEITHER branch may
    /// consult the OUI lookup" comment in DetectionDetailView.headerBlock, which is why the old
    /// OUI-first `displayVendor` was deleted rather than reused); this extends that decision
    /// rather than reopening it.
    ///
    /// Also never `type.brand` (a 1:1 function of the category, so it would rebuild the same wall
    /// of identical rows in different words) and never `bleCompanyName` (would title every passing
    /// iPhone "Apple").
    ///
    /// nil for ALPR, Raven, Desert, watchlist, unknown, and every row replayed from the offline
    /// buffer: StoredDet carries no detail field, so a replayed row has no vendor route at all and
    /// correctly degrades to the category. Do not fill that gap with a guess.
    var maker: String? {
        // Trims, and refuses any name that identifies SILICON rather than a product. Nothing the
        // firmware can currently emit hits the deny-list (the glasses colon rule already
        // self-excludes Jieli and HeyCyan, neither of which contains a colon). It exists so a
        // FUTURE firmware string cannot: glasses_signatures.h calls Jieli "the Espressif problem
        // in miniature - the ID identifies the SILICON, not the product".
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
                  !Self.notAMaker.contains(t.lowercased()) else { return nil }
            return t   // verbatim: "Anker/eufy" keeps its slash, see below
        }

        // 1. Body cam: the four-string wire contract both apps already match on exactly.
        if let sig = bodyCamSignature { return clean(sig.vendor) }

        // 2. Drone Remote ID. `ridManufacturer` passes an unrecognised CTA-2063 code straight
        //    through as "Mfr 7A3C", which must never become a row title.
        if let m = ridManufacturer, !m.hasPrefix("Mfr ") { return clean(m) }

        guard let det = detail, !det.isEmpty else { return nil }

        // 3. TYPE-GATED, AFFIX-ANCHORED parsing of the detail string. Deliberately not a generic
        //    "first token" rule: that would turn "Axon OUI" into "Axon" (erasing that this is the
        //    WEAK variant, not the conf-90 payload tag) and "Motorola Solutions OUI" into
        //    "Motorola", which reads as Motorola MOBILITY, a different company. The suffix anchors
        //    are safe against the body-cam contract precisely because the WiFi body-cam path omits
        //    " on wifi" to stay byte-identical to its BLE strings.
        switch type {
        case .networkCamera:
            guard det.hasSuffix(" on wifi") else { return nil }
            return clean(String(det.dropLast(" on wifi".count)))
        case .drone:
            // METHOD GATE, and it is load-bearing. Drone is the ONE parsed type whose detail can
            // contain REMOTE-DEVICE TEXT: on the Remote ID path the firmware writes "op %s" from
            // the broadcaster's 20-byte ODID Operator ID (drone_detect.cpp), so a crafted
            // Operator ID whose last 19 bytes are exactly this anchor would make the row title,
            // the dossier Maker row and the CSV read "op". The vendor-OUI fallback that actually
            // emits this string sets method = OUI, while the attacker-reachable "op ..." detail
            // only ever arrives as Remote ID, so requiring OUI here closes it. The deny-list
            // cannot: it screens silicon vendor names, not arbitrary broadcast text.
            guard method == .oui, det.hasSuffix(" gear, no Remote ID") else { return nil }
            return clean(String(det.dropLast(" gear, no Remote ID".count)))
        case .recordingGlasses:
            // The firmware encodes confidence as ":" and hedging as "?", so the colon rule admits
            // "Ray-Ban Meta: ..." and "Meta: ..." while self-excluding "HeyCyan glasses UUID",
            // "Jieli chipset? ..." and "TCL/RayNeo? ...". Do not relax this to a prefix match.
            guard let c = det.firstIndex(of: ":") else { return nil }
            return clean(String(det[det.startIndex..<c]))
        case .tracker:
            // Exact map, no parsing. "Apple Find My" rather than "Apple" on purpose: Chipolo and
            // Pebblebee tags advertise the same offline Find My payload, so the NETWORK is what
            // was proved, not the manufacturer. "(offline)" is dropped from the title only
            // because it would read as the row's OFFLINE buffer-replay tag, which it is not.
            switch det {
            case "Apple Find My (offline)": return "Apple Find My"
            case "Tile":                    return "Tile"
            case "Samsung SmartTag":        return "Samsung SmartTag"
            // "(separated)" is dropped for the same reason "(offline)" is above: it describes the
            // tag's STATE, not its maker, and the row already conveys the state.
            case "Google Find Hub (separated)": return "Google Find Hub"
            default:                        return nil
            }
        default:
            return nil
        }
    }

    /// Names that identify the radio module rather than the product. Backstop only, see `maker`.
    private static let notAMaker: Set<String> = [
        "espressif", "liteon", "lite-on", "silicon labs", "silabs", "usi",
        "murata", "jieli", "realtek", "asustek", "heycyan", "unknown",
    ]
}

/// True when an OUI registrant is a chipset or module vendor rather than the product's maker.
/// Used to annotate the dossier's OUI row, because a reader cannot be expected to know that
/// Liteon is a WiFi module house. This makes the weakness legible instead of leaving it to the
/// label, which is what OUIVendors.table says it exists for.
func isChipsetRegistrant(_ vendor: String) -> Bool {
    ["Espressif", "Liteon", "Silicon Labs", "USI", "Murata", "Realtek", "ASUSTek"].contains(vendor)
}
