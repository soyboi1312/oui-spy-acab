/*
 * ACAB - Branded IP-camera vendor MAC OUIs (network-camera detection).
 *
 * The ONE honest, buildable "camera on the network" signal: IP cameras from the major
 * surveillance brands do NOT randomize their MAC, and the 802.11 DATA-frame SOURCE MAC
 * is transmitted in the clear even under WPA2/WPA3 (only the frame BODY is encrypted).
 * So a camera streaming on the host WiFi is passively OUI-matchable by its vendor block.
 *
 * HONESTY (this is a safety product - read before you touch a label):
 *   - This matches known IP-camera BRANDS, not "hidden cameras". A hit means a device
 *     from that vendor is on the air (could be an NVR, a doorbell, or a camera the host
 *     openly disclosed), NOT that someone planted a covert camera.
 *   - It CANNOT find every camera: a no-name / white-label cam on a generic Wi-Fi module,
 *     or any camera not transmitting right now, will not match. Never imply completeness.
 *   The category is "Network camera". The detail names the vendor + "on wifi" for an OUI match,
 *   and is "Arlo base station" for the SSID match added 2026-08-05 - that one names the BOX, not a
 *   lens, because a broadcast SSID proves the hardware is there and nothing about what it sees.
 *
 * Every block below is a corporate MA-L or MA-M registration held by the camera vendor or its parent,
 * verified against the live IEEE registry: the original set on 2026-07-17 (api.maclookup.app),
 * the consumer brands on 2026-07-31, and the Hikvision/Dahua expansion plus six new vendors on
 * 2026-08-07 (a direct standards-oui.ieee.org/oui/oui.csv pull). The 2026-09-01 additions
 * were checked against the same MA-L registry and standards-oui.ieee.org/oui28/mam.csv.
 * No commodity-module silicon, so it passes the no-shared-silicon rule the rest of the
 * OUI tables follow.
 *
 * Two precisions, because the wording here used to overstate two things. "The vendor's OWN"
 * is not literally true for every row: Anker/eufy registers as Fantasia Trading LLC, and much
 * Amcrest hardware is Dahua-built and may transmit under a Dahua block instead. And the
 * registrant name is NOT in each row comment any more. The table is now sorted by OUI for the
 * binary search, which breaks per-vendor grouping, so the per-vendor reasoning that used to sit
 * inline lives in VENDOR NOTES immediately below. Read that before adding or trusting a block.
 *
 * WYZE WAS ADDED 2026-07-31, reversing the exclusion this header used to state. The old reason
 * ("Wyze's own OUIs also cover plugs / bulbs / locks") is true but is a reason to LABEL the hit
 * honestly, not to drop the vendor: the same is true of Anker/eufy, which is labelled to say so.
 * The half that still stands is that some Wyze models ride shared Espressif silicon, in which
 * case these blocks simply never fire, which costs nothing. Espressif itself remains excluded,
 * and that rule is untouched: an OUI is only worth having when the REGISTRANT is narrow.
 */
#ifndef ACAB_NETCAM_SIGNATURES_H
#define ACAB_NETCAM_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>
#include "oui_prefix.h"

// One IP-camera vendor OUI: the 3-byte corporate MA-L block plus a short vendor label so
// the detection detail names the maker ("Hikvision on wifi", etc).
struct NetcamOui {
    uint8_t     oui[3];     // vendor's own corporate MA-L block (IEEE), high byte first
    const char* vendor;     // short label for the "<Vendor> on wifi" detail string
    uint8_t     validated;  // 1 = seen in our own capture AND confirmed a real camera by eye
};

// Smaller IEEE assignments keep their full prefix width; truncating an MA-M to three
// bytes would attribute fifteen unrelated neighboring blocks to the same camera vendor.
struct NetcamPrefix {
    uint8_t     prefix[5];
    uint8_t     prefixBits;
    const char* vendor;
    uint8_t     validated;
};

// ---------------------------------------------------------------------------------------
// VENDOR NOTES. Why each vendor is in (or out), preserved from when the table was grouped
// by vendor. The table below is sorted by OUI for the binary search, so this is where the
// reasoning lives now. Nothing here is decorative: several entries exist BECAUSE of a
// caveat recorded here, and the Arlo note is the standard for what validated=1 costs.
// ---------------------------------------------------------------------------------------
// Hangzhou Hikvision Digital Technology Co.,Ltd. - the six blocks research seeded, ALL
// registry-confirmed, plus one more from the same registrant. src: IEEE MA-L.
// Zhejiang Dahua Technology Co., Ltd. src: IEEE MA-L.
// Amcrest Technologies (Houston TX). Amcrest's OWN registration; note much Amcrest
// hardware is Dahua-built and may transmit under a Dahua block above too. src: IEEE MA-L.
// Axis Communications AB (Lund, Sweden). src: IEEE MA-L.
// Reolink Innovation Limited. The registry shows Reolink holds exactly ONE MA-L block.
// src: IEEE MA-L.
// ---- CONSUMER / DOORBELL BRANDS (added 2026-07-31, ALL registry-only) ----------------
// Verified the same day against a fresh 39,880-row pull of the live IEEE registry, matching
// on the EXACT registrant name rather than a substring: a first substring pass on "ring"
// returned 24 blocks because it also matched "ENGINEERING". These are the real ones.
//
// A vendor OUI is useful here when the REGISTRANT identifies a camera-system vendor.
// Generic Google, Amazon Technologies and Espressif blocks also cover unrelated phones,
// speakers, routers and module-based products, so those blocks stay excluded. Blink has
// its own SIX "Blink by Amazon" MA-L registrations, all included below; the former claim
// that Blink only used shared Amazon blocks was wrong. A Blink hit may still be a Sync
// Module rather than a camera, so it keeps the vendor label and registry confidence.
//
// Arlo was incorrectly omitted until 2026-08-05 despite its own narrow registrations.
// Arlo Technology holds THREE blocks and ships nothing with a radio but cameras, doorbells,
// and the hubs that serve them. It passes the narrowness test more cleanly than Wyze does.
// See the Arlo entries below for their capture provenance.
// Ring LLC. Doorbells and security cameras, i.e. the most street-facing camera class there
// is. Camera/doorbell-only registrant, so the OUI is a strong vendor read. src: IEEE MA-L.
// Arlo Technology. These blocks were heard in our own captures, but remain validated=0
// (see below). The 2026-07-24 A/B drive logged TWELVE
// distinct Arlo-OUI devices spread across the route (compare-devices-dual.csv), all three
// blocks firing, and THREE of them named themselves in the SSID: A4:11:62:0B:2D:62,
// A4:11:62:6C:8F:24 and FC:9C:98:B4:E5:18 were beaconing "ARLO_VMB_<digits>" (see
// NETCAM_SSID_ARLO_PREFIX below - that rule is the stronger half of this signature).
// Until now every one of those hits fell through to a bare "Nearby device", conf 0.
//
// WHY validated STAYS 0 DESPITE THE CAPTURE: this flag means "seen in our own capture AND
// confirmed a real camera BY EYE" (see NetcamOui). We have the first half only. The SSID
// proves the hardware is genuinely Arlo; it does not prove anyone stood at that address and
// saw a camera, which is what the Axon 75 tier was earned by. Promote these to 1 only after
// an eyeball pass - the three SSID-named hub MACs above are the ones to go looking for.
//
// WHAT A HIT REALLY IS: usually the SmartHub/base station, not a lens. Arlo base stations are
// mains-powered 802.11 APs that beacon continuously, while the battery cameras sleep with the
// radio down - which is exactly why 11 of the 12 drive hits were single sightings. A hub has
// no purpose except serving Arlo cameras, so "Arlo on wifi" stays honest, but do NOT read it
// as "a camera is pointed at you right now".
//
// STATED MISSES, so nobody thinks this is complete. (1) VINTAGE: all three blocks are
// post-spinoff (A4:11:62 2018, FC:9C:98 2020, 48:62:64 2024). Everything Arlo shipped while
// it was part of NETGEAR - original Wire-Free, Pro, Pro 2, Q, Baby, Go 1st gen, and the
// VMB3000/VMB4000 hubs - rides NETGEAR's 76 blocks and fails the narrowness test the same way
// TP-Link does. Those are reachable ONLY by the NTGR_VMB_ SSID form, never by OUI. (2) BAND:
// Ultra-class cameras on a VMB5000 hub, and dual-band Pro 5S/6 direct to a router, can sit on
// 5GHz where this radio cannot hear them. (3) LINK: Arlo Go 1st gen is LTE-only, never
// detectable. (4) The discontinued Arlo Security Light talks BLE to a bridge - KEEP THIS
// MATCH WIFI-ONLY (netcamClassifyWiFi already is) or a porch light gets labelled a camera.
// src: IEEE MA-L + our own captures.
// Wyze Labs Inc. Camera-dominant, but they also ship plugs, bulbs, locks and scales, so a
// hit is "a Wyze device" first and a camera second. CAVEAT to settle in the field: some
// Wyze models are built on Espressif/Realtek silicon and may transmit under the CHIP
// vendor's OUI instead of Wyze's, in which case these blocks simply never fire.
// src: IEEE MA-L; the separately listed MA-M block uses the same vendor caveat.
// eufy, via Anker. THE WEAKEST ENTRIES IN THIS TABLE, and labelled to say so. There is no
// "eufy" or "Anker" registrant in the IEEE registry at all - Anker registers as Fantasia
// Trading LLC, which covers their ENTIRE catalogue: USB chargers, PowerCore banks,
// Soundcore speakers, Nebula projectors, eufy vacuums and locks, and eufy cameras. So this
// OUI means "an Anker product", NOT "a camera", and plenty of Anker WiFi gear is not one.
// The vendor label deliberately reads "Anker/eufy" so the app's detail string carries that
// ambiguity to the user rather than hiding it behind a camera claim. If a capture shows
// these firing mostly on vacuums and speakers, delete them. src: IEEE MA-L.
// ---- added 2026-08-02, every block re-confirmed against a fresh standards-oui.ieee.org pull --
// Hangzhou Ezviz Software Co.,Ltd. - 14 MA-L blocks at the initial addition, plus
// 38:F2:5D in the 2026-09-01 refresh below.
// Ezviz is Hikvision's CONSUMER brand and holds its OWN registrations, so the Hikvision blocks
// above never catch an Ezviz camera: a real hole, not a duplicate. The registrant is a camera
// company, so the block is narrow in the way this file demands. src: IEEE MA-L.
// Lorex Technology Inc. and Swann communications Pty Ltd - one MA-L block each. Swann's
// separate MA-M block is also included in the refresh below. Both sell driveway/perimeter DVR
// kits, i.e. cameras pointed at a street, which is squarely what this table is for. A hit can
// also be an NVR or a bridge. src: IEEE MA-L and MA-M.
//
// 2026-08-07 EXPANSION. Hikvision 7 -> 86 and Dahua 6 -> 33, i.e. each vendor's COMPLETE
// MA-L set. The table had held under a tenth of the blocks those two companies own, so a
// Hikvision camera could sit on the air and match nothing. Also added, each its own narrow
// registrant, all confirmed in the same pull: Verkada Inc (E0:A7:00), i-PRO Co., Ltd.
// (D4:2D:C5), Vivotek Inc (00:02:D1), Zhejiang Uniview x4, Amcrest x2 (joining the block
// already here), Hanwha Vision Vietnam x2, and SAMSUNG TECHWIN (00:09:18, the legacy name
// Hanwha's camera line shipped under). Prompted by two crowdsourced lists whose OUIs were
// mostly WRONG - 54 of 57 vendor labels in one disagreed with IEEE, and it would have had
// us flag Apple, Nintendo, Dell and GM hardware as cameras - so nothing was imported. Only
// the vendors were taken as leads, and every block re-derived from the registry.
//
// 2026-09-01 REFRESH. Added Ezviz 38:F2:5D and Uniview 14:BA:88 from IEEE MA-L,
// and Amcrest 3446632, Wyze A4DA222, Swann 0C0EC14 from IEEE MA-M. The latter three
// retain all 28 registered bits in CAMERA_VENDOR_PREFIX. All five remain validated=0.
// camarillo_drive.log contains A4:DA:22:2E:FE:07 and A4:DA:22:2E:A7:BE,
// so the Wyze block is field-observed, but the log does not identify a camera model or
// record visual confirmation. An observed address does not earn the validated tier.
//
// 2026-09-01 CAPTURED-VENDOR EXPANSION. IEEE MA-L confirms all six "Blink by Amazon"
// assignments, Night Owl SP (542B57), SKYBELL, INC (D0C193), and the four Juan assignments:
//   083A2F  Guangzhou Juan Intelligent Tech Joint Stock Co.,Ltd
//   9CA3A9  Guangzhou Juan Optical and Electronical Tech Joint Stock Co., Ltd
//   84D0DB, A486DB  Guangdong Juan Intelligent Technology Joint Stock Co., Ltd.
// IEEE MA-M confirms WUUK LABS CORP. (B0B3537). Its fourth-byte high nibble stays 7.
// Juan is a surveillance OEM serving multiple retail brands; "Juan OEM" names that
// manufacturer without inventing a retail brand or camera model. Night Owl may be an NVR,
// WUUK a base station, and SkyBell a chime. The capture collection contains addresses from
// each vendor, but no visual confirmation; every added row therefore has validated=0.
// Representative names include BLINK-5AJB, NVR542b5707c2a1, SkybellHD_2151974911 and
// NVR083a2f4cc78b. These support the vendor attribution without changing the OUI tier or
// adding an SSID rule. Exact assignments, source links and capture counts: docs/signatures.md.
// ---------------------------------------------------------------------------------------

// Registry-confirmed camera-brand OUIs (IEEE MA-L). The original 19 were verified 2026-07-17
// and the 24 consumer blocks (Ring/Wyze/Anker-eufy) on 2026-07-31, both against the live
// IEEE registry (see file header). Add only blocks you re-confirm against the registry.
// constexpr (not just const) so the sortedness static_assert below can actually read it.
static constexpr NetcamOui CAMERA_VENDOR_OUI[] = {
    // SORTED BY 24-BIT OUI, ASCENDING. netcamEntry() binary-searches this, so the order is
    // load-bearing, not cosmetic: an out-of-order row is not a style problem, it silently makes
    // that vendor (and possibly its neighbours) undetectable. A static_assert below fails the
    // build if the order is ever broken, so add entries anywhere and let the check catch you.
    //
    // Hikvision and Dahua are the vendor's COMPLETE MA-L set as of the 2026-08-07 registry pull
    // (86 and 33 blocks). They were 7 and 6, which is why a Hikvision camera could sit on the air
    // and match nothing: the table held under a tenth of the blocks the company actually owns.
    // Vivotek
    { { 0x00, 0x02, 0xd1 }, "Vivotek", 0 },
    // Samsung Techwin
    { { 0x00, 0x09, 0x18 }, "Samsung Techwin", 0 },
    // Lorex
    { { 0x00, 0x1f, 0x54 }, "Lorex", 0 },
    // Axis
    { { 0x00, 0x40, 0x8c }, "Axis", 0 },
    // Amcrest
    { { 0x00, 0x65, 0x1e }, "Amcrest", 0 },
    // Anker/eufy
    { { 0x00, 0x7f, 0x1d }, "Anker/eufy", 0 },
    // Ring
    { { 0x00, 0xb4, 0x63 }, "Ring", 0 },
    // Hikvision
    { { 0x00, 0xbc, 0x99 }, "Hikvision", 0 },
    { { 0x04, 0x03, 0x12 }, "Hikvision", 0 },
    { { 0x04, 0xee, 0xcd }, "Hikvision", 0 },
    // Juan OEM
    { { 0x08, 0x3a, 0x2f }, "Juan OEM", 0 },
    // Hikvision
    { { 0x08, 0x3b, 0xc1 }, "Hikvision", 0 },
    { { 0x08, 0x54, 0x11 }, "Hikvision", 0 },
    { { 0x08, 0xa1, 0x89 }, "Hikvision", 0 },
    { { 0x08, 0xcc, 0x81 }, "Hikvision", 0 },
    // Dahua
    { { 0x08, 0xed, 0xed }, "Dahua", 0 },
    // Hikvision
    { { 0x0c, 0x75, 0xd2 }, "Hikvision", 0 },
    // Ezviz
    { { 0x0c, 0xa6, 0x4c }, "Ezviz", 0 },
    // Hikvision
    { { 0x10, 0x12, 0xfb }, "Hikvision", 0 },
    // Dahua
    { { 0x14, 0xa7, 0x8b }, "Dahua", 0 },
    // Uniview
    { { 0x14, 0xba, 0x88 }, "Uniview", 0 },
    // Hikvision
    { { 0x18, 0x68, 0xcb }, "Hikvision", 0 },
    // Ring
    { { 0x18, 0x7f, 0x88 }, "Ring", 0 },
    // Hikvision
    { { 0x18, 0x80, 0x25 }, "Hikvision", 0 },
    // Dahua
    { { 0x20, 0x2c, 0x05 }, "Dahua", 0 },
    // Ezviz
    { { 0x20, 0xbb, 0xbc }, "Ezviz", 0 },
    // Hikvision
    { { 0x24, 0x0f, 0x9b }, "Hikvision", 0 },
    { { 0x24, 0x28, 0xfd }, "Hikvision", 0 },
    // Ring
    { { 0x24, 0x2b, 0xd6 }, "Ring", 0 },
    // Hikvision
    { { 0x24, 0x32, 0xae }, "Hikvision", 0 },
    { { 0x24, 0x48, 0x45 }, "Hikvision", 0 },
    // Dahua
    { { 0x24, 0x52, 0x6a }, "Dahua", 0 },
    // Hikvision
    { { 0x24, 0xb1, 0x05 }, "Hikvision", 0 },
    { { 0x28, 0x57, 0xbe }, "Hikvision", 0 },
    { { 0x2c, 0xa5, 0x9c }, "Hikvision", 0 },
    // Wyze
    { { 0x2c, 0xaa, 0x8e }, "Wyze", 0 },
    // Dahua
    { { 0x30, 0xdd, 0xaa }, "Dahua", 0 },
    // Hikvision
    { { 0x34, 0x09, 0x62 }, "Hikvision", 0 },
    // Ring
    { { 0x34, 0x3e, 0xa4 }, "Ring", 0 },
    // Ezviz
    { { 0x34, 0xc6, 0xdd }, "Ezviz", 0 },
    // Dahua
    { { 0x38, 0xaf, 0x29 }, "Dahua", 0 },
    // Ezviz
    { { 0x38, 0xf2, 0x5d }, "Ezviz", 0 },
    // Hikvision
    { { 0x3c, 0x1b, 0xf8 }, "Hikvision", 0 },
    // Blink
    { { 0x3c, 0xa0, 0x70 }, "Blink", 0 },
    // Dahua
    { { 0x3c, 0xe3, 0x6b }, "Dahua", 0 },
    { { 0x3c, 0xef, 0x8c }, "Dahua", 0 },
    { { 0x40, 0x7a, 0xa4 }, "Dahua", 0 },
    // Hikvision
    { { 0x40, 0xac, 0xbf }, "Hikvision", 0 },
    { { 0x40, 0xb5, 0x70 }, "Hikvision", 0 },
    { { 0x44, 0x19, 0xb6 }, "Hikvision", 0 },
    { { 0x44, 0x47, 0xcc }, "Hikvision", 0 },
    { { 0x44, 0xa6, 0x42 }, "Hikvision", 0 },
    // Hanwha
    { { 0x44, 0xb4, 0x23 }, "Hanwha", 0 },
    // Arlo
    { { 0x48, 0x62, 0x64 }, "Arlo", 0 },
    // Hikvision
    { { 0x48, 0x78, 0x5b }, "Hikvision", 0 },
    // Uniview
    { { 0x48, 0xea, 0x63 }, "Uniview", 0 },
    // Dahua
    { { 0x4c, 0x11, 0xbf }, "Dahua", 1 },
    // Hikvision
    { { 0x4c, 0x1f, 0x86 }, "Hikvision", 0 },
    { { 0x4c, 0x62, 0xdf }, "Hikvision", 0 },
    // Dahua
    { { 0x4c, 0x99, 0xe8 }, "Dahua", 0 },
    // Hikvision
    { { 0x4c, 0xbd, 0x8f }, "Hikvision", 0 },
    { { 0x4c, 0xf5, 0xdc }, "Hikvision", 0 },
    // Ring
    { { 0x50, 0xe4, 0x67 }, "Ring", 0 },
    // Hikvision
    { { 0x50, 0xe5, 0x38 }, "Hikvision", 0 },
    // Night Owl
    { { 0x54, 0x2b, 0x57 }, "Night Owl", 0 },
    // Hikvision
    { { 0x54, 0x8c, 0x81 }, "Hikvision", 0 },
    { { 0x54, 0xc4, 0x15 }, "Hikvision", 0 },
    // Ezviz
    { { 0x54, 0xd6, 0x0d }, "Ezviz", 0 },
    // Ring
    { { 0x54, 0xe0, 0x19 }, "Ring", 0 },
    // Hikvision
    { { 0x58, 0x03, 0xfb }, "Hikvision", 0 },
    { { 0x58, 0x50, 0xed }, "Hikvision", 0 },
    // Ezviz
    { { 0x58, 0x8f, 0xcf }, "Ezviz", 0 },
    // Hikvision
    { { 0x5c, 0x34, 0x5b }, "Hikvision", 0 },
    // Ring
    { { 0x5c, 0x47, 0x5e }, "Ring", 0 },
    // Dahua
    { { 0x5c, 0xf5, 0x1a }, "Dahua", 0 },
    // Ezviz
    { { 0x64, 0x24, 0x4d }, "Ezviz", 0 },
    // Ring
    { { 0x64, 0x9a, 0x63 }, "Ring", 0 },
    // Hikvision
    { { 0x64, 0xdb, 0x8b }, "Hikvision", 0 },
    // Ezviz
    { { 0x64, 0xf2, 0xfb }, "Ezviz", 0 },
    // Dahua
    { { 0x64, 0xfd, 0x29 }, "Dahua", 0 },
    // Hikvision
    { { 0x68, 0x6d, 0xbc }, "Hikvision", 0 },
    // Dahua
    { { 0x6c, 0x1c, 0x71 }, "Dahua", 0 },
    // Uniview
    { { 0x6c, 0xf1, 0x7e }, "Uniview", 0 },
    // Blink
    { { 0x70, 0xad, 0x43 }, "Blink", 0 },
    { { 0x74, 0x13, 0x48 }, "Blink", 0 },
    // Hikvision
    { { 0x74, 0x3f, 0xc2 }, "Hikvision", 0 },
    // Blink
    { { 0x74, 0xab, 0x93 }, "Blink", 0 },
    // Dahua
    { { 0x74, 0xc9, 0x29 }, "Dahua", 0 },
    // Ezviz
    { { 0x78, 0xa6, 0xa0 }, "Ezviz", 0 },
    { { 0x78, 0xc1, 0xae }, "Ezviz", 0 },
    // Wyze
    { { 0x7c, 0x78, 0xb2 }, "Wyze", 0 },
    // Anker/eufy
    { { 0x7c, 0xe9, 0x13 }, "Anker/eufy", 0 },
    // Wyze
    { { 0x80, 0x48, 0x2c }, "Wyze", 0 },
    // Hikvision
    { { 0x80, 0x48, 0x9f }, "Hikvision", 0 },
    { { 0x80, 0x7c, 0x62 }, "Hikvision", 0 },
    { { 0x80, 0xbe, 0xaf }, "Hikvision", 0 },
    { { 0x80, 0xf5, 0xae }, "Hikvision", 0 },
    { { 0x84, 0x94, 0x59 }, "Hikvision", 0 },
    { { 0x84, 0x9a, 0x40 }, "Hikvision", 0 },
    // Juan OEM
    { { 0x84, 0xd0, 0xdb }, "Juan OEM", 0 },
    // Uniview
    { { 0x88, 0x26, 0x3f }, "Uniview", 0 },
    // Hikvision
    { { 0x88, 0xde, 0x39 }, "Hikvision", 0 },
    { { 0x8c, 0x22, 0xd2 }, "Hikvision", 0 },
    { { 0x8c, 0xe7, 0x48 }, "Hikvision", 0 },
    // Dahua
    { { 0x8c, 0xe9, 0xb4 }, "Dahua", 0 },
    { { 0x90, 0x02, 0xa9 }, "Dahua", 0 },
    // Ring
    { { 0x90, 0x48, 0x6c }, "Ring", 0 },
    // Hikvision
    { { 0x94, 0xe1, 0xac }, "Hikvision", 0 },
    // Ezviz
    { { 0x94, 0xec, 0x13 }, "Ezviz", 0 },
    // Hikvision
    { { 0x98, 0x8b, 0x0a }, "Hikvision", 0 },
    { { 0x98, 0x9d, 0xe5 }, "Hikvision", 0 },
    { { 0x98, 0xdf, 0x82 }, "Hikvision", 0 },
    { { 0x98, 0xf1, 0x12 }, "Hikvision", 0 },
    // Dahua
    { { 0x98, 0xf9, 0xcc }, "Dahua", 0 },
    { { 0x9c, 0x14, 0x63 }, "Dahua", 0 },
    // Ring
    { { 0x9c, 0x76, 0x13 }, "Ring", 0 },
    // Amcrest
    { { 0x9c, 0x8e, 0xcd }, "Amcrest", 0 },
    // Juan OEM
    { { 0x9c, 0xa3, 0xa9 }, "Juan OEM", 0 },
    // Amcrest
    { { 0xa0, 0x60, 0x32 }, "Amcrest", 0 },
    // Dahua
    { { 0xa0, 0xbd, 0x1d }, "Dahua", 0 },
    // Hikvision
    { { 0xa0, 0xff, 0x0c }, "Hikvision", 0 },
    // Arlo
    { { 0xa4, 0x11, 0x62 }, "Arlo", 0 },
    // Hikvision
    { { 0xa4, 0x14, 0x37 }, "Hikvision", 0 },
    { { 0xa4, 0x29, 0x02 }, "Hikvision", 0 },
    { { 0xa4, 0x4b, 0xd9 }, "Hikvision", 0 },
    // Juan OEM
    { { 0xa4, 0x86, 0xdb }, "Juan OEM", 0 },
    // Hikvision
    { { 0xa4, 0xa4, 0x59 }, "Hikvision", 0 },
    { { 0xa4, 0xd5, 0xc2 }, "Hikvision", 0 },
    // Dahua
    { { 0xa8, 0xca, 0x87 }, "Dahua", 0 },
    // Anker/eufy
    { { 0xac, 0x12, 0x2f }, "Anker/eufy", 0 },
    // Ezviz
    { { 0xac, 0x1c, 0x26 }, "Ezviz", 0 },
    // Ring
    { { 0xac, 0x9f, 0xc3 }, "Ring", 0 },
    // Hikvision
    { { 0xac, 0xb9, 0x2f }, "Hikvision", 0 },
    { { 0xac, 0xcb, 0x51 }, "Hikvision", 0 },
    // Axis
    { { 0xac, 0xcc, 0x8e }, "Axis", 0 },
    // Ring
    { { 0xb0, 0x09, 0xda }, "Ring", 0 },
    // Hikvision
    { { 0xb0, 0xff, 0x0d }, "Hikvision", 0 },
    // Dahua
    { { 0xb4, 0x4c, 0x3b }, "Dahua", 0 },
    // Hikvision
    { { 0xb4, 0xa3, 0x82 }, "Hikvision", 0 },
    // Axis
    { { 0xb8, 0xa4, 0x4f }, "Axis", 0 },
    // Hikvision
    { { 0xbc, 0x29, 0x78 }, "Hikvision", 0 },
    // Dahua
    { { 0xbc, 0x32, 0x5f }, "Dahua", 1 },
    // Swann
    { { 0xbc, 0x51, 0xfe }, "Swann", 0 },
    // Hikvision
    { { 0xbc, 0x5e, 0x33 }, "Hikvision", 0 },
    { { 0xbc, 0x9b, 0x5e }, "Hikvision", 0 },
    { { 0xbc, 0xad, 0x28 }, "Hikvision", 0 },
    { { 0xbc, 0xba, 0xc2 }, "Hikvision", 0 },
    // Dahua
    { { 0xc0, 0x39, 0x5a }, "Dahua", 0 },
    // Hikvision
    { { 0xc0, 0x51, 0x7e }, "Hikvision", 0 },
    { { 0xc0, 0x56, 0xe3 }, "Hikvision", 0 },
    { { 0xc0, 0x6d, 0xed }, "Hikvision", 0 },
    { { 0xc4, 0x2f, 0x90 }, "Hikvision", 0 },
    // Uniview
    { { 0xc4, 0x79, 0x05 }, "Uniview", 0 },
    // Dahua
    { { 0xc4, 0xaa, 0xc4 }, "Dahua", 0 },
    // Ring
    { { 0xc4, 0xdb, 0xad }, "Ring", 0 },
    // Blink
    { { 0xc8, 0x19, 0xd8 }, "Blink", 0 },
    // Hikvision
    { { 0xc8, 0xa7, 0x02 }, "Hikvision", 0 },
    { { 0xcc, 0x13, 0xf3 }, "Hikvision", 0 },
    // Ring
    { { 0xcc, 0x3b, 0xfb }, "Ring", 0 },
    // Wyze
    { { 0xd0, 0x3f, 0x27 }, "Wyze", 0 },
    // SkyBell
    { { 0xd0, 0xc1, 0x93 }, "SkyBell", 0 },
    // i-PRO
    { { 0xd4, 0x2d, 0xc5 }, "i-PRO", 0 },
    // Dahua
    { { 0xd4, 0x43, 0x0e }, "Dahua", 0 },
    // Hikvision
    { { 0xd4, 0xe8, 0x53 }, "Hikvision", 0 },
    { { 0xdc, 0x07, 0xf8 }, "Hikvision", 0 },
    { { 0xdc, 0xd2, 0x6a }, "Hikvision", 0 },
    // Dahua
    { { 0xe0, 0x2e, 0xfe }, "Dahua", 0 },
    { { 0xe0, 0x50, 0x8b }, "Dahua", 1 },
    // Verkada
    { { 0xe0, 0xa7, 0x00 }, "Verkada", 0 },
    // Hikvision
    { { 0xe0, 0xba, 0xad }, "Hikvision", 0 },
    { { 0xe0, 0xca, 0x3c }, "Hikvision", 0 },
    { { 0xe0, 0xdf, 0x13 }, "Hikvision", 0 },
    // Dahua
    { { 0xe4, 0x24, 0x6c }, "Dahua", 0 },
    // Hanwha
    { { 0xe4, 0x30, 0x22 }, "Hanwha", 0 },
    // Hikvision
    { { 0xe4, 0xd5, 0x8b }, "Hikvision", 0 },
    // Axis
    { { 0xe8, 0x27, 0x25 }, "Axis", 0 },
    // Hikvision
    { { 0xe8, 0xa0, 0xed }, "Hikvision", 0 },
    // Anker/eufy
    { { 0xe8, 0xee, 0xcc }, "Anker/eufy", 0 },
    // Reolink
    { { 0xec, 0x71, 0xdb }, "Reolink", 1 },
    // Ezviz
    { { 0xec, 0x97, 0xe0 }, "Ezviz", 0 },
    // Hikvision
    { { 0xec, 0xa9, 0x71 }, "Hikvision", 0 },
    { { 0xec, 0xc8, 0x9c }, "Hikvision", 0 },
    // Blink
    { { 0xf0, 0x74, 0xc1 }, "Blink", 0 },
    // Wyze
    { { 0xf0, 0xc8, 0x8b }, "Wyze", 0 },
    // Ezviz
    { { 0xf4, 0x70, 0x18 }, "Ezviz", 0 },
    // Anker/eufy
    { { 0xf4, 0x9d, 0x8a }, "Anker/eufy", 0 },
    // Dahua
    { { 0xf4, 0xb1, 0xc2 }, "Dahua", 0 },
    // Hikvision
    { { 0xf8, 0x4d, 0xfc }, "Hikvision", 0 },
    // Dahua
    { { 0xf8, 0xce, 0x07 }, "Dahua", 0 },
    // Ezviz
    { { 0xfc, 0x24, 0x22 }, "Ezviz", 0 },
    // Dahua
    { { 0xfc, 0x5f, 0x49 }, "Dahua", 0 },
    // Arlo
    { { 0xfc, 0x9c, 0x98 }, "Arlo", 0 },
    // Hikvision
    { { 0xfc, 0x9f, 0xfd }, "Hikvision", 0 },
    // Dahua
    { { 0xfc, 0xb6, 0x9d }, "Dahua", 0 },
    // DELIBERATELY ABSENT, checked 2026-08-02 against that same pull. Do not "fix" these:
    //   TP-Link (Tapo / Kasa) - proposed as the biggest remaining consumer hole, and by installed
    //     base it is. But there is NO Tapo or Kasa registrant: the cameras ride TP-LINK
    //     TECHNOLOGIES CO.,LTD., which holds 263 MA-L blocks spanning routers, switches, range
    //     extenders, plugs and bulbs. Matching those would label a home router a camera in most
    //     houses in the country. That is exactly the test Espressif fails in this file's header,
    //     and TP-Link fails it 263 times over. Not addable at the OUI layer.
    //   Foscam - ZERO registrations under any spelling (foscam / fos cam / Shenzhen variants).
    //     Their gear runs other people's silicon, so there is nothing narrow to match.
};
static constexpr size_t CAMERA_VENDOR_OUI_COUNT = sizeof(CAMERA_VENDOR_OUI) / sizeof(CAMERA_VENDOR_OUI[0]);

// IEEE MA-M assignments, checked against standards-oui.ieee.org/oui28/mam.csv.
// Keep these separate so MA-L matching retains its binary search on the data-frame path.
static constexpr NetcamPrefix CAMERA_VENDOR_PREFIX[] = {
    { ACAB_OUI_MAM(0x34, 0x46, 0x63, 0x2), "Amcrest", 0 },
    { ACAB_OUI_MAM(0xa4, 0xda, 0x22, 0x2), "Wyze", 0 },
    { ACAB_OUI_MAM(0x0c, 0x0e, 0xc1, 0x4), "Swann", 0 },
    { ACAB_OUI_MAM(0xb0, 0xb3, 0x53, 0x7), "WUUK", 0 },
};
static constexpr size_t CAMERA_VENDOR_PREFIX_COUNT =
    sizeof(CAMERA_VENDOR_PREFIX) / sizeof(CAMERA_VENDOR_PREFIX[0]);

// The table's 24-bit sort key, and a COMPILE-TIME guard that it really is sorted.
//
// netcamEntry() binary-searches CAMERA_VENDOR_OUI, which is only correct while the rows are in
// ascending order. A row added in the wrong place would not fail loudly: the search would simply
// miss that vendor, and possibly its neighbours, while the table still looked right on review.
// That is the worst failure shape for a detection table, so the build refuses it instead. Add
// rows wherever is readable and let this catch the ordering. It also rejects duplicates, since
// the comparison is strict.
static constexpr uint32_t netcamOuiKey(const NetcamOui& e) {
    return ((uint32_t)e.oui[0] << 16) | ((uint32_t)e.oui[1] << 8) | (uint32_t)e.oui[2];
}
static constexpr bool netcamOuiSorted(size_t i = 1) {
    return i >= CAMERA_VENDOR_OUI_COUNT
        || (netcamOuiKey(CAMERA_VENDOR_OUI[i - 1]) < netcamOuiKey(CAMERA_VENDOR_OUI[i])
            && netcamOuiSorted(i + 1));
}
static_assert(netcamOuiSorted(),
              "CAMERA_VENDOR_OUI must stay sorted ascending by OUI and hold no duplicates: "
              "netcamEntry() binary-searches it");

// FIRST FIELD VALIDATION 2026-07-23. An airport capture returned 8 network-camera rows across
// four OUIs (Dahua 4C:11:BF x2, BC:32:5F x2, E0:50:8B x1; Reolink EC:71:DB x3) and the user
// confirmed all 8 were real network cameras. So both halves held: the OUI named the vendor
// correctly AND the device really was a camera. Every other prefix remains at the
// registry tier; observing the Wyze MA-M addresses does not establish their product type.
//
// The confidence below is deliberately NOT raised on that result, and this is the important
// part: 8 hits at ONE site is exactly the evidence shape that made POLICE_OUI's "3 distinct
// MACs at one site" comment overstate its case, and that vendor turned out to be 0/27 when it
// was finally measured (see bodycam_vendor_signatures.h). One venue's ceiling cameras do not
// establish what a Dahua OUI means in a house, an office, or a parking garage. Raise this only on
// captures from materially different environments.
//
// Confidence for a network-camera OUI match. Moderate: the OUI reliably names the vendor
// (these brands use public, non-randomized MACs), but a match is "a <vendor> device is on
// the network", NOT "a hidden camera" - it could be an NVR / doorbell / disclosed camera.
// Below the field-validated Axon tier (75) and Flock SSID (88); above the raw drone-OUI
// fallback (60). Honesty over alarm.
#define NETCAM_OUI_CONFIDENCE  65
// A field-validated block earns the same tier as the field-validated Axon OUI (75). Only the
// four entries flagged validated=1 get it; every other prefix stays at 65.
#define NETCAM_OUI_CONFIDENCE_VALIDATED  75

// ---------------------------------------------------------------------------
// WiFi SSID prefix (added 2026-08-05) - the strongest network-camera signal we have.
// ---------------------------------------------------------------------------
// An Arlo SmartHub / Base Station broadcasts an SSID of the literal form "ARLO_VMB_<digits>"
// (VMB is Arlo's own base-station model prefix). We have three in our own logs:
// ARLO_VMB_1164328298, ARLO_VMB_2983159490, ARLO_VMB_8967923929. Same shape and same reasoning
// as FLOCK_SSID_PREFIX in flock_signatures.h: an SSID is a VENDOR SELF-ATTESTATION, so it beats
// an OUI on both halves of the question - it names the vendor AND says what the box is.
//
// It also catches what the OUI structurally cannot. The hub is mains-powered and beacons ~10x a
// second, where the battery cameras sleep with their radios down; and PRE-SPINOFF Arlo hardware
// broadcasts this same SSID form while its MAC sits in NETGEAR's 76 unusable blocks. That gear
// is reachable ONLY here.
//
// Deliberately matched case-insensitively and as a PREFIX, not an exact string, because the
// numeric tail is per-unit. FP risk is negligible: nothing else names an AP "ARLO_VMB_".
#define NETCAM_SSID_ARLO_PREFIX  "ARLO_VMB_"
// The NETGEAR-era form of the same box, listed because it is the only route to pre-2018 Arlo
// (the downside of an SSID literal is a MISS, never a false positive). CAPTURED, repeatedly: our
// own drive logs (firmware/tools/detection logs, gitignored) carry NTGR_VMB_ hubs in nine captures
// from 2026-07-24 (compare-dual) to 2026-09-02 (Santa Barbara), 33 distinct hubs in all, 18 on Arlo's
// A4:11:62 and 15 on nine NETGEAR blocks (2C:30:33, CC:40:D0, B0:39:56, A0:40:A0, A0:04:60,
// 9C:3D:CF, 78:D2:94, 50:6A:03, 14:59:C0) that no OUI row here reaches, exactly the case above.
// Observed, not eyeballed, so the 88 tier rests on the self-attesting SSID as before, not on a
// validated=1 sighting. The "not yet captured" note that stood here was stale from August on.
#define NETCAM_SSID_ARLO_LEGACY_PREFIX  "NTGR_VMB_"
// Same tier as the Flock SSID match (88) and for the identical reason: the device broadcast its
// own vendor and model class in the clear. Above every OUI tier in this file, including the
// eyeball-validated 75, because this does not infer the vendor - the vendor states it.
#define NETCAM_SSID_CONFIDENCE  88

#endif // ACAB_NETCAM_SIGNATURES_H
