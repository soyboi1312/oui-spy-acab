/*
 * ACAB - Flock Safety signature tables (clean-room).
 *
 * Every entry here is sourced from a public registry, a published standard, or
 * independent third-party research - NOT from upstream detection code. Full
 * citations are in docs/signatures.md. Drop this into flock_detect.cpp in place
 * of the inline tables; the only logic change is adding the SSID-prefix match
 * to flockClassifyWiFi (see note at FLOCK_SSID_PREFIX).
 */
#ifndef ACAB_FLOCK_SIGNATURES_H
#define ACAB_FLOCK_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// ---------------------------------------------------------------------------
// MAC OUI
// ---------------------------------------------------------------------------
// Only Flock Safety's OWN IEEE block is defensibly Flock-specific. The WiFi/BT
// silicon is a LiteOn WCBN3510A, and Lite-On's OUIs are shared across millions of
// consumer devices, so matching them is a false-positive magnet (in the field they
// flagged a Molekule air purifier and a home camera). The old ~67-OUI "superset"
// is gone on purpose; match the SSID / name / mfg-id below instead.
struct FlockOui { uint8_t b[3]; uint8_t ext; };
static const FlockOui FLOCK_OUI[] = {
    // B4:1E:52  Flock Safety, Inc.  (IEEE MA-L, registered 2024-05-09)
    //   src: IEEE OUI registry -> https://maclookup.app/macaddress/b41e52
    {{0xb4,0x1e,0x52}, 0},
};
static const size_t FLOCK_OUI_COUNT = sizeof(FLOCK_OUI) / sizeof(FLOCK_OUI[0]);

// ---------------------------------------------------------------------------
// WiFi client OUIs (Falcon cameras) - PROBE-REQUEST matched
// ---------------------------------------------------------------------------
// Falcon cams join a network as WiFi clients (no "Flock-" AP of their own) and give
// themselves away with probe requests from a Liteon WiFi module. Liteon is shared
// silicon (one of the biggest laptop WiFi-NIC suppliers), so these are matched on
// PROBE REQUESTS ONLY (see flockClassifyWiFi) - but note that gate distinguishes APs
// from clients, NOT cameras from laptops: probe requests are exactly what a
// not-yet-associated laptop emits, and Windows ships MAC randomization off, so the
// real OUI is on the air. The ship bar (ext=0) is one thing and only that thing: OUR OWN capture
// of the OUI over probe requests at a DeFlock-confirmed Falcon. Nothing weaker has ever cleared
// it - earlier unconfirmed candidates that came from community OUI lists were removed for
// clean-room provenance - so re-add or promote an OUI only after capturing it yourself at a
// Falcon, and cite that capture on its own row.
// ext=1 = NON-SHIPPING candidate: compiled out of every build (gFlockExtendedOui in
// flock_detect.cpp is compile-time false with no setter, NVS restore, or BLE toggle),
// kept only as a provenance record until it clears the bar above.
struct FalconWifiOui { uint8_t b[3]; uint8_t ext; };
static const FalconWifiOui FALCON_WIFI_OUI[] = {
    // Shipped (ext=0). ONE PROVENANCE, SHARED BY ALL FOUR ROWS, and it is the whole story: each
    // was captured by us over probe requests at a DeFlock-confirmed Falcon in 2026-06. All four
    // landed in one commit (ca44071, labelled "Own field captures (deflock-confirmed Falcons,
    // 2026-06)") with no ext field at all. Read that for exactly what it says: the capture ties
    // the OUI to a site where a Falcon is mapped, not to that camera's own radio, which is why
    // the probe-request gate above stays on and why these ride at conf 72 in flockClassifyWiFi
    // rather than as proof.
    //
    // NO ROW HERE WAS EVER HELD BACK OR PROMOTED. The note this block used to carry said
    // D8:F3:BC / C0:35:32 were held-out candidates promoted on 2026-07-24 after a drive recaptured
    // both broadcasting "PROBE-FALCON" / "DATA-FALCON" SSIDs. Neither half happened: git shows both
    // rows shipping unconditionally since the table was written, so there was nothing to promote,
    // and those two strings are this firmware's OWN diagnostic labels, printed into the ssid= field
    // of the [wifi] line only AFTER falconOui() had already matched, so they attest to nothing but
    // this table. They are spelled "fwnote:falcon-oui-*" in acab_scanner.cpp now, precisely so the
    // round trip cannot be made again. Behaviour of these rows is unchanged, and always was; only
    // the story above them was wrong. Do not re-split the four on the strength of that story - the
    // evidence behind them is one batch, so grade them together or not at all.
    {{0xD8,0xF3,0xBC}, 0},  // D8:F3:BC:7D:D4:CF               own capture at a DeFlock-confirmed Falcon
    {{0xC0,0x35,0x32}, 0},  // C0:35:32:AF:A3:7D               own capture at a DeFlock-confirmed Falcon
    {{0x24,0xB2,0xB9}, 0},  // 24:B2:B9:F5:D0:43               own capture at a DeFlock-confirmed Falcon
    {{0xF4,0x6A,0xDD}, 0},  // F4:6A:DD:62:38:5D / :5E:3A:F3   own capture at a DeFlock-confirmed Falcon
};
static const size_t FALCON_WIFI_OUI_COUNT = sizeof(FALCON_WIFI_OUI) / sizeof(FALCON_WIFI_OUI[0]);

// ---------------------------------------------------------------------------
// WiFi SSID prefix
// ---------------------------------------------------------------------------
// Falcon cameras stand up a setup/health AP named "Flock-<partial MAC>". This is
// the strong WiFi signature (far better than an OUI). Add a prefix test on the
// SSID IE in flockClassifyWiFi; it replaces the dropped OUI-superset matches.
//   src: ryanohoro "Spotting Flock Safety's Falcon Cameras"; GainSec WiFi research.
#define FLOCK_SSID_PREFIX  "Flock-"

// NON-SHIPPING CANDIDATE (ext=1), retired 2026-08-25. Same tier as an ext=1 OUI row: kept as a
// provenance record, compiled out of every build. falconSsidSuffix() in flock_detect.cpp is the
// gate, and it shares gFlockExtendedOui with the tables above.
//
// WHY IT WAS RETIRED. The rule said Falcon cameras stand up per-function networks named
// "PROBE-FALCON" and "DATA-FALCON", cited to a 2026-07-24 drive. They do not, and it was not.
// Those two strings are labels THIS FIRMWARE writes into the ssid= field of its own [wifi]
// diagnostic line, and only after falconOui() has already matched - so a capture containing them
// is our OUI table talking to itself. Two independent confirmations: a data frame carries no SSID
// element at all, so "DATA-FALCON" could not have come off the air; and the one capture in the
// repo that holds the string shows the label immediately followed by a conf=72 "Falcon probe
// (OUI)" verdict, which is the verdict the classifier gives when the frame's own SSID does NOT
// end in "-FALCON". The labels also predate the drive they were credited to by five weeks.
//
// WHAT IT COST WHILE IT SHIPPED: any AP or probe-response whose SSID ends case-insensitively in
// "-FALCON" was reported as an ALPR camera at confidence 85 - above the field-validated Axon OUI
// at 75 - on evidence that does not exist. The suffix anchor keeps "Atlanta-Falcons" out, but
// not "NET-FALCON" or a router someone renamed.
//
// TO SHIP IT: a capture showing a real beacon (0x8) or probe-response (0x5) SSID IE ending in
// "-FALCON", from a unit confirmed to be a Falcon by something other than this table. Then flip
// FLOCK_SSID_FALCON_SUFFIX_EXT to 0 and cite the capture here.
#define FLOCK_SSID_FALCON_SUFFIX  "-FALCON"
static const uint8_t FLOCK_SSID_FALCON_SUFFIX_EXT = 1;

// ---------------------------------------------------------------------------
// BLE advertised-name patterns  (ANCHORED - see nameMatch in flock_detect.cpp)
// ---------------------------------------------------------------------------
// Substring-anywhere matching false-positives on consumer gear ("FS-" is a generic
// white-label model prefix; any name containing "penguin"/"flock" matched), so each
// pattern is anchored to the form the sources actually document:
//   FLOCK_NAME_LITERAL       case-insensitive substring; specific enough to rank
//                            strong (80) on its own
//   FLOCK_NAME_PREFIX_DIGITS name starts with the pattern + a 1+ decimal-digit tail
//   FLOCK_NAME_PREFIX_HEX    name starts with the pattern + a 1+ hex-digit tail
//   FLOCK_NAME_PREFIX        name starts with the pattern (no structural tail)
// The PREFIX forms rank strong (80) only with the 0x09C8 mfg co-signal and stay
// hint-grade (70) otherwise, regardless of address bytes. A public address adds
// no Flock-specific evidence. 0x09C8 is shared XUNTONG silicon; this preserves
// the existing name+mfg tier. See flockClassifyBLE in flock_detect.cpp.
//   "FS Ext Battery"             -> ryanohoro (external-battery health beacons)
//   "Penguin-" + digits          -> ryanohoro (Penguin-##########)
//   "FS-" + hex                  -> own field capture (FS-BEC46A, 2026-06; one capture,
//                                   so the tail requires hex but not a fixed length)
//   "Flock" prefix               -> brand string, public; loosest of the four
// (A bare 10-digit name is a documented post-Mar-2025 Flock pattern but is NOT
// matched here: in the field it false-positived on phones broadcasting placeholder
// numeric names like "0102000000". Reconsider only with independent Flock-specific
// evidence; a public BLE address alone cannot establish that identity.)
enum FlockNameForm : uint8_t {
    FLOCK_NAME_LITERAL,
    FLOCK_NAME_PREFIX_DIGITS,
    FLOCK_NAME_PREFIX_HEX,
    FLOCK_NAME_PREFIX,
};
struct FlockNamePat { const char* pat; uint8_t form; };
static const FlockNamePat FLOCK_NAME_PATTERNS[] = {
    { "FS Ext Battery", FLOCK_NAME_LITERAL },
    { "Penguin-",       FLOCK_NAME_PREFIX_DIGITS },
    { "FS-",            FLOCK_NAME_PREFIX_HEX },
    { "Flock",          FLOCK_NAME_PREFIX },
};
static const size_t FLOCK_NAME_COUNT =
    sizeof(FLOCK_NAME_PATTERNS) / sizeof(FLOCK_NAME_PATTERNS[0]);

// ---------------------------------------------------------------------------
// BLE manufacturer company ID
// ---------------------------------------------------------------------------
// 0x09C8 on Flock BT health beacons; ryanohoro attributes it to "XUNTONG" (a silicon/module
// vendor, not Flock), so it's SHARED and unverified. It's matched at a deliberately low
// confidence (45, see flock_detect.cpp) - below the apps' weak-match threshold (50), so a
// hit renders as "weak match, verify" rather than a calm partial match - because a hit is
// a hint, not an assertion, until a field capture confirms it. TODO before trusting it
// higher: confirm 0x09C8's registrant + exclusivity in the current Bluetooth SIG
// assigned-numbers company-identifier list.
static const uint16_t FLOCK_MFG_IDS[] = { 0x09C8 };
static const size_t FLOCK_MFG_COUNT = sizeof(FLOCK_MFG_IDS) / sizeof(FLOCK_MFG_IDS[0]);

// ---------------------------------------------------------------------------
// Raven (audio sensor) service UUIDs - 16-bit shorts on the Bluetooth base UUID,
// advertised in 128-bit form. The 0x31xx-0x35xx are Raven-specific and come from
// field captures (not a registry) - confirm against your own capture. The 0x18xx
// are standard Bluetooth SIG profile UUIDs (public) used only as weak backup.
// ---------------------------------------------------------------------------
#define RAVEN_SVC_GPS       0x3100  // Raven-specific  (own capture)
#define RAVEN_SVC_POWER     0x3200  // Raven-specific  (own capture)
#define RAVEN_SVC_NETWORK   0x3300  // Raven-specific  (own capture)
#define RAVEN_SVC_UPLOAD    0x3400  // Raven-specific  (own capture)
#define RAVEN_SVC_ERROR     0x3500  // Raven-specific  (own capture)
#define RAVEN_SVC_DEVINFO   0x180a  // std Bluetooth SIG: Device Information
#define RAVEN_SVC_OLDHEALTH 0x1809  // std Bluetooth SIG: Health Thermometer
#define RAVEN_SVC_OLDLOC    0x1819  // std Bluetooth SIG: Location and Navigation

#endif // ACAB_FLOCK_SIGNATURES_H
