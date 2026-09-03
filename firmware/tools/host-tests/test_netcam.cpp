// Host regression test for the network-camera classifier: branded IP-camera vendor prefixes
// matched off an 802.11 source MAC with their registered widths preserved.
//
// WHY THIS FILE EXISTS. Three separate contracts run through netcam_detect.cpp, and none of them is
// checked by the compiler:
//   1. THE DETAIL STRING. Both apps parse "<Vendor> on wifi" and split on the " on wifi" suffix to
//      show the maker. Change the format string, drop the space, capitalise the "W", and the board
//      still detects the camera while the app shows a blank or garbled vendor. "Anker/eufy" keeps
//      its slash on purpose (see netcam_signatures.h): the block is Fantasia Trading's whole
//      catalogue, so the slash is the ambiguity being handed to the user, NOT a typo to clean up.
//   2. THE CONFIDENCE TIER. 65 registry-only vs 75 field-validated. The apps sort and colour by it.
//   3. THE OPT-IN. Default OFF is the zero-cost-when-off promise. A regression that defaults it ON
//      widens the WiFi promiscuous filter to DATA frames on every board that boots.
// Every assertion below locks in what the code does TODAY. Where behaviour looked surprising it is
// still asserted as-is, with the surprise written down next to it rather than "fixed" in the test.
#include "netcam_detect.h"
#include "netcam_signatures.h"
#include <Preferences.h>   // wipeAll(): the stub stores for real now
#include <cstdio>
#include <cstring>
#include <vector>

// The classifier's ONE cross-translation-unit call. netcamSetEnabled() asks the scanner to widen
// the promiscuous filter to DATA frames when it turns on and narrow back to MGMT-only when it turns
// off; acab_scanner.cpp is not part of this build, so the definition lives here exactly as
// test_glasses.cpp defines desertIsEnabled(). Counting the calls is deliberate: "the toggle
// refreshed the filter" and "a redundant set did NOT" are the two halves of the zero-cost promise,
// and both are otherwise invisible from outside the module.
static int gFilterRefreshes = 0;
void acabScannerRefreshWifiFilter() { gFilterRefreshes++; }

static int failures = 0;
static void chk_impl(const char* name, bool got, bool wantHit,
                int gotConf = -1, int wantConf = -1, const char* gotDetail = "", const char* wantDetail = nullptr) {
    bool ok = (got == wantHit);
    if (ok && wantHit && wantConf >= 0) ok = (gotConf == wantConf);
    if (ok && wantHit && wantDetail)    ok = (strcmp(gotDetail, wantDetail) == 0);
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got hit=%d conf=%d detail=\"%s\"", got, gotConf, gotDetail); failures++; }
    printf("\n");
}
// For facts that are not a classify() call: toggle state, table invariants, copied fields.
static void chkBool_impl(const char* name, bool ok, const char* note = "") {
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   %s", note); failures++; }
    printf("\n");
}

// ---- ARGUMENT-EVALUATION SEQUENCING (do not remove) ------------------------------------------
// Every assertion below is written as
//     chk("name", classify(..., &d), true, d.confidence, 90, d.detail, "...");
// so the call that FILLS `d` and the reads of `d` are arguments to the SAME call. C++ leaves the
// evaluation order of function arguments UNSPECIFIED. Clang evaluates left to right, so the
// classifier runs before the reads and every assertion sees fresh values; GCC evaluates right to
// left, so it reads `d` BEFORE the classifier fills it - yielding the PREVIOUS test's values, and
// uninitialised stack on the first assertion (that is where the impossible `conf=153` came from).
// The suite therefore passed on macOS and failed in CI, on identical source.
//
// These macros complete the classifier call in a statement of its own before any argument to the
// reporting function is evaluated, so correctness no longer depends on the compiler. Keep the
// assertions in their current one-line form; the macro is what makes that form safe.
#define chk(name, hitexpr, ...) do { const bool acab_hit_ = (hitexpr); chk_impl((name), acab_hit_, ##__VA_ARGS__); } while (0)
#define chkBool(name, okexpr, ...) do { const bool acab_ok_ = (okexpr); chkBool_impl((name), acab_ok_, ##__VA_ARGS__); } while (0)
static void chkStr(const char* name, const char* got, const char* want) {
    bool ok = got && strcmp(got, want) == 0;
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got \"%s\" want \"%s\"", got ? got : "(null)", want); failures++; }
    printf("\n");
}

// Copied byte-for-byte from acabSanitizeAscii in acab_scanner.cpp (same stub test_axon,
// test_flock and test_drone carry). The SSID path runs the matched name through it, so a
// lazy memcpy stub would let a control-byte SSID pass for the wrong reason. Resync if the
// real one ever changes.
void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap) {
    if (!dst || cap == 0) return;
    size_t m = n;
    if (m > cap - 1) m = cap - 1;
    size_t j = 0;
    for (; j < m; j++) {
        uint8_t c = src ? src[j] : 0;
        dst[j] = (c >= 0x20 && c <= 0x7E) ? (char)c : '.';
    }
    dst[j] = 0;
}

// ---- 802.11 frame builders -------------------------------------------------------------------
// The classifier reads exactly two things: frame[1] (the ToDS/FromDS bits) and the 6 bytes at the
// source-address offset those bits select. Everything else is padding, so the padding is 0x11:
// a well-formed PUBLIC OUI shape (locally-administered bit clear) that is not in the camera table.
// That matters. Padding of 0xAA or 0xFF would be rejected by the randomized-MAC gate, which would
// silently hide an off-by-one that read the wrong offset. 0x11 lets a wrong read fail loudly.
static std::vector<uint8_t> frame(size_t len, uint8_t fc1) {
    std::vector<uint8_t> f(len, 0x11);
    if (len > 0) f[0] = 0x08;   // frame-control byte 0. The CALLER decides data vs mgmt via the
                                // isDataFrame argument. Since 2026-08-05 the classifier DOES read
                                // this byte, but only on the mgmt path and only for the subtype
                                // (SSID rule). 0x08 is subtype 0, which carries no SSID IE, so
                                // every test built here is unaffected - see beacon() for that path.
    if (len > 1) f[1] = fc1;
    return f;
}
static void putMac(std::vector<uint8_t>& f, size_t off, const uint8_t* mac, size_t n = 6) {
    for (size_t i = 0; i < n && off + i < f.size(); i++) f[off + i] = mac[i];
}
static bool run(std::vector<uint8_t>& f, bool isData, AcabDetection* out, int rssi = -57) {
    memset(out, 0, sizeof(*out));
    return netcamClassifyWiFi(f.data(), f.size(), isData, rssi, out);
}
// A 32-byte data frame with ToDS=1/FromDS=0 (a camera uploading its stream to the AP: SA = addr2,
// offset 10). This is the primary real-world shape, so it is the default for the vendor positives.
static std::vector<uint8_t> uplink(const uint8_t* mac) {
    std::vector<uint8_t> f = frame(32, 0x01);
    putMac(f, 10, mac);
    return f;
}
// A beacon (subtype 0x8) carrying one SSID IE. Beacons put a 12-byte fixed body
// (timestamp/interval/capability) before their IEs, so the IEs start at 36, NOT 24. Getting that
// wrong fails silently, which is why the tests below pin both offsets in both directions.
// NOTE: unlike the other builders, this one sets frame[0] - the SSID path reads the subtype from
// it. The other builders leave it at 0x08, whose subtype (0) is not an SSID-bearing type, which is
// why every pre-existing mgmt test is untouched by the SSID rule.
static std::vector<uint8_t> beacon(const char* ssid, const uint8_t* mac) {
    const size_t sl = strlen(ssid);
    std::vector<uint8_t> f = frame(36 + 2 + sl, 0x00);
    f[0] = 0x80;                 // type 00 (mgmt), subtype 1000 (beacon)
    putMac(f, 10, mac);          // addr2 = transmitter
    f[36] = 0x00;                // IE id 0 = SSID
    f[37] = (uint8_t)sl;
    for (size_t i = 0; i < sl; i++) f[38 + i] = (uint8_t)ssid[i];
    return f;
}

// Table OUIs, each with distinct trailing bytes so a copied MAC is checkable.
static const uint8_t MAC_HIK[6]    = { 0x18, 0x68, 0xcb, 0x0a, 0x0b, 0x0c };   // Hikvision, registry-only
static const uint8_t MAC_DAHUA[6]  = { 0x3c, 0xef, 0x8c, 0x11, 0x22, 0x33 };   // Dahua, registry-only
static const uint8_t MAC_DAHUAV[6] = { 0x4c, 0x11, 0xbf, 0xde, 0xad, 0x01 };   // Dahua, FIELD-VALIDATED
static const uint8_t MAC_REOLNK[6] = { 0xec, 0x71, 0xdb, 0x44, 0x55, 0x66 };   // Reolink, FIELD-VALIDATED
static const uint8_t MAC_AMCRST[6] = { 0x9c, 0x8e, 0xcd, 0x01, 0x02, 0x03 };   // Amcrest
static const uint8_t MAC_AXIS[6]   = { 0x00, 0x40, 0x8c, 0x77, 0x88, 0x99 };   // Axis (leading 0x00)
static const uint8_t MAC_RING[6]   = { 0x00, 0xb4, 0x63, 0x0d, 0x0e, 0x0f };   // Ring (leading 0x00)
static const uint8_t MAC_WYZE[6]   = { 0x2c, 0xaa, 0x8e, 0x31, 0x32, 0x33 };   // Wyze
static const uint8_t MAC_ANKER[6]  = { 0xe8, 0xee, 0xcc, 0x5a, 0x5b, 0x5c };   // Anker/eufy
static const uint8_t MAC_ARLO[6]   = { 0xa4, 0x11, 0x62, 0x0b, 0x2d, 0x62 };   // Arlo, from our own 2026-07-24 capture
static const uint8_t MAC_ARLO2[6]  = { 0xfc, 0x9c, 0x98, 0xb4, 0xe5, 0x18 };   // Arlo, ditto
static const uint8_t MAC_ARLO3[6]  = { 0x48, 0x62, 0x64, 0x28, 0xd8, 0x59 };   // Arlo, ditto
// Independently recorded WiFi addresses from camarillo_drive.log. The block was heard,
// but neither device was visually confirmed as a camera, so both remain at the 65 tier.
static const uint8_t MAC_WYZE_CAPTURE1[6] = { 0xa4, 0xda, 0x22, 0x2e, 0xfe, 0x07 };
static const uint8_t MAC_WYZE_CAPTURE2[6] = { 0xa4, 0xda, 0x22, 0x2e, 0xa7, 0xbe };
// Independent capture addresses for the newly covered vendors. Hearing an address does
// not meet the visual-confirmation requirement for the field-validated confidence tier.
struct VendorCase {
    const char* vendor;
    uint8_t mac[6];
};
static const VendorCase CAPTURED_VENDORS[] = {
    { "Blink",     {0x74,0xab,0x93,0xe2,0x93,0xa0} }, // beacon-lvt.log
    { "Night Owl", {0x54,0x2b,0x57,0x55,0x86,0xad} }, // compare-devices-dual.csv
    { "SkyBell",   {0xd0,0xc1,0x93,0x1e,0xdd,0xfe} }, // camarillo_drive.log
    { "Juan OEM",  {0x9c,0xa3,0xa9,0x95,0x15,0x97} }, // camarillo_drive.log
    { "WUUK",      {0xb0,0xb3,0x53,0x7f,0x01,0x23} }, // aug-9-drive2.log
};
// A well-formed PUBLIC MAC in NO vendor table. Used where the test is about the SSID alone, so an
// accidental OUI hit cannot be mistaken for the SSID rule working.
static const uint8_t MAC_PAD[6]    = { 0x11, 0x11, 0x11, 0x11, 0x11, 0x11 };

// The vendor labels the apps are allowed to see. Exact strings: casing, the slash and the
// hyphen are part of the wire contract, not cosmetics. Ezviz/Lorex/Swann added 2026-08-02;
// the six through Samsung Techwin added 2026-08-07 with the registry expansion.
static const char* const KNOWN_VENDORS[] = {
    "Hikvision", "Dahua", "Amcrest", "Axis", "Reolink", "Ring", "Wyze", "Anker/eufy",
    "Ezviz", "Lorex", "Swann", "Arlo",
    "Verkada", "i-PRO", "Vivotek", "Uniview", "Hanwha", "Samsung Techwin",
    "Blink", "Night Owl", "SkyBell", "Juan OEM", "WUUK"
};

int main() {
    AcabDetection d;
    char note[192];
    printf("\n=== network-camera classifier regression ===\n");

    // ---- opt-in: default OFF, and OFF really means no work -----------------------------------
    // NOTE ON THE STUB: the host Preferences stub returns the caller's default from getBool(), so
    // NVS is a pass-through here. These assertions lock the FLAG LOGIC (default, gating, when the
    // filter is refreshed), not the persistence itself, which needs a board.
    chkBool("netcamIsEnabled() defaults OFF at boot", !netcamIsEnabled());
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("OFF: a real Hikvision uplink frame -> no hit", run(f, true, &d), false); }
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("OFF: same frame as a mgmt frame -> no hit", run(f, false, &d), false); }
    { std::vector<uint8_t> f = uplink(MAC_WYZE_CAPTURE1);
      chk("OFF: Wyze MA-M capture -> no hit", run(f, true, &d), false); }
    for (const VendorCase& v : CAPTURED_VENDORS) {
        std::vector<uint8_t> f = uplink(v.mac);
        char label[96];
        snprintf(label, sizeof(label), "OFF: captured %s -> no hit", v.vendor);
        chk(label, run(f, true, &d), false);
    }
    // The OUI table lookup is NOT gated: only the classifier is. The scanner reuses this helper on
    // the BLE path, so gating it would break a caller that has nothing to do with the WiFi filter.
    chkStr("OFF: netcamVendorOui() still resolves (helper is un-gated)",
           netcamVendorOui(MAC_HIK), "Hikvision");
    chkStr("OFF: helper still resolves Wyze MA-M capture",
           netcamVendorOui(MAC_WYZE_CAPTURE1), "Wyze");
    for (const VendorCase& v : CAPTURED_VENDORS) {
        char label[96];
        snprintf(label, sizeof(label), "OFF: helper still resolves captured %s", v.vendor);
        chkStr(label, netcamVendorOui(v.mac), v.vendor);
    }
    chkBool("OFF: no filter refresh has happened yet", gFilterRefreshes == 0);

    netcamSetEnabled(true);
    chkBool("setEnabled(true) flips the flag", netcamIsEnabled());
    chkBool("setEnabled(true) refreshed the WiFi filter exactly once", gFilterRefreshes == 1);
    netcamSetEnabled(true);
    chkBool("redundant setEnabled(true) is a no-op, no 2nd refresh", gFilterRefreshes == 1);

    // ---- one positive per vendor: the detail string and the confidence tier ------------------
    // Both fields are consumed downstream (the app splits the detail on " on wifi" for the maker
    // and sorts/colours by confidence), so both are asserted literally, not against the macro.
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("Hikvision 18:68:cb", run(f, true, &d), true, d.confidence, 65, d.detail, "Hikvision on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_DAHUA);
      chk("Dahua 3c:ef:8c (registry-only tier)", run(f, true, &d), true, d.confidence, 65, d.detail, "Dahua on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("Dahua 4c:11:bf FIELD-VALIDATED -> 75 not 65", run(f, true, &d), true, d.confidence, 75, d.detail, "Dahua on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_REOLNK);
      chk("Reolink ec:71:db FIELD-VALIDATED -> 75", run(f, true, &d), true, d.confidence, 75, d.detail, "Reolink on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_AMCRST);
      chk("Amcrest 9c:8e:cd", run(f, true, &d), true, d.confidence, 65, d.detail, "Amcrest on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_AXIS);
      chk("Axis 00:40:8c (leading 0x00 byte)", run(f, true, &d), true, d.confidence, 65, d.detail, "Axis on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_RING);
      chk("Ring 00:b4:63", run(f, true, &d), true, d.confidence, 65, d.detail, "Ring on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_WYZE);
      chk("Wyze 2c:aa:8e", run(f, true, &d), true, d.confidence, 65, d.detail, "Wyze on wifi"); }
    // THE SLASH IS LOAD-BEARING. "Anker/eufy" says the block is Fantasia Trading's entire catalogue
    // (chargers, speakers, vacuums, cameras), so the hit is "an Anker product" and the user is told
    // so. Anyone tidying this to "Anker" or "eufy" is deleting a deliberate honesty signal.
    { std::vector<uint8_t> f = uplink(MAC_ANKER);
      chk("Anker/eufy e8:ee:cc keeps its slash in the detail", run(f, true, &d), true, d.confidence, 65,
          d.detail, "Anker/eufy on wifi"); }
    chkStr("netcamVendorOui() label keeps the slash too", netcamVendorOui(MAC_ANKER), "Anker/eufy");

    // ---- additional IEEE blocks, with fixtures independent of the production tables ---------
    { const uint8_t mac[6] = { 0x38, 0xf2, 0x5d, 0x12, 0x34, 0x56 };
      std::vector<uint8_t> f = uplink(mac);
      chk("Ezviz 38:f2:5d -> registry tier", run(f, true, &d), true,
          d.confidence, 65, d.detail, "Ezviz on wifi");
      chkStr("helper resolves added Ezviz MA-L", netcamVendorOui(mac), "Ezviz"); }
    { const uint8_t mac[6] = { 0x14, 0xba, 0x88, 0x65, 0x43, 0x21 };
      std::vector<uint8_t> f = uplink(mac);
      chk("Uniview 14:ba:88 -> registry tier", run(f, true, &d), true,
          d.confidence, 65, d.detail, "Uniview on wifi");
      chkStr("helper resolves added Uniview MA-L", netcamVendorOui(mac), "Uniview"); }

    // These fixtures are spelled out independently of CAMERA_VENDOR_OUI: a missing or
    // mistyped registration must fail even if the production table's own sweep still passes.
    const VendorCase additionalOuis[] = {
        { "Blink",     {0x3c,0xa0,0x70,0x12,0x34,0x56} },
        { "Blink",     {0x70,0xad,0x43,0x12,0x34,0x56} },
        { "Blink",     {0xf0,0x74,0xc1,0x12,0x34,0x56} },
        { "Blink",     {0x74,0x13,0x48,0x12,0x34,0x56} },
        { "Blink",     {0xc8,0x19,0xd8,0x12,0x34,0x56} },
        { "Blink",     {0x74,0xab,0x93,0x12,0x34,0x56} },
        { "Night Owl", {0x54,0x2b,0x57,0x12,0x34,0x56} },
        { "SkyBell",   {0xd0,0xc1,0x93,0x12,0x34,0x56} },
        { "Juan OEM",  {0x08,0x3a,0x2f,0x12,0x34,0x56} },
        { "Juan OEM",  {0x9c,0xa3,0xa9,0x12,0x34,0x56} },
        { "Juan OEM",  {0x84,0xd0,0xdb,0x12,0x34,0x56} },
        { "Juan OEM",  {0xa4,0x86,0xdb,0x12,0x34,0x56} },
    };
    for (const VendorCase& v : additionalOuis) {
        std::vector<uint8_t> f = uplink(v.mac);
        char label[96], detail[64];
        snprintf(label, sizeof(label), "%s %02x:%02x:%02x -> registry tier",
                 v.vendor, v.mac[0], v.mac[1], v.mac[2]);
        snprintf(detail, sizeof(detail), "%s on wifi", v.vendor);
        chk(label, run(f, true, &d), true, d.confidence, 65, d.detail, detail);
        snprintf(label, sizeof(label), "helper resolves %s %02x:%02x:%02x",
                 v.vendor, v.mac[0], v.mac[1], v.mac[2]);
        chkStr(label, netcamVendorOui(v.mac), v.vendor);
    }
    for (const VendorCase& v : CAPTURED_VENDORS) {
        std::vector<uint8_t> f = uplink(v.mac);
        char label[96], detail[64];
        snprintf(label, sizeof(label), "captured %s stays at registry tier", v.vendor);
        snprintf(detail, sizeof(detail), "%s on wifi", v.vendor);
        chk(label, run(f, true, &d), true, d.confidence, 65, d.detail, detail);
    }

    // IEEE MA-M assignments 3446632, A4DA222, 0C0EC14 and B0B3537 cover these exact inclusive
    // endpoints. Spell out adjacent addresses rather than deriving them from the table or
    // matcher: truncating to /24 must fail the negatives; narrowing to /32 must fail the highs.
    struct PrefixCase {
        const char* vendor;
        uint8_t low[6], high[6], before[6], after[6];
    };
    const PrefixCase prefixes[] = {
        { "Amcrest",
          {0x34,0x46,0x63,0x20,0x00,0x00}, {0x34,0x46,0x63,0x2f,0xff,0xff},
          {0x34,0x46,0x63,0x1f,0xff,0xff}, {0x34,0x46,0x63,0x30,0x00,0x00} },
        { "Wyze",
          {0xa4,0xda,0x22,0x20,0x00,0x00}, {0xa4,0xda,0x22,0x2f,0xff,0xff},
          {0xa4,0xda,0x22,0x1f,0xff,0xff}, {0xa4,0xda,0x22,0x30,0x00,0x00} },
        { "Swann",
          {0x0c,0x0e,0xc1,0x40,0x00,0x00}, {0x0c,0x0e,0xc1,0x4f,0xff,0xff},
          {0x0c,0x0e,0xc1,0x3f,0xff,0xff}, {0x0c,0x0e,0xc1,0x50,0x00,0x00} },
        { "WUUK",
          {0xb0,0xb3,0x53,0x70,0x00,0x00}, {0xb0,0xb3,0x53,0x7f,0xff,0xff},
          {0xb0,0xb3,0x53,0x6f,0xff,0xff}, {0xb0,0xb3,0x53,0x80,0x00,0x00} },
    };
    for (const PrefixCase& p : prefixes) {
        char label[96], detail[64];
        snprintf(detail, sizeof(detail), "%s on wifi", p.vendor);
        const uint8_t* endpoints[] = { p.low, p.high };
        for (size_t i = 0; i < 2; i++) {
            std::vector<uint8_t> f = uplink(endpoints[i]);
            snprintf(label, sizeof(label), "%s /28 %s endpoint -> 65", p.vendor, i ? "last" : "first");
            chk(label, run(f, true, &d), true, d.confidence, 65, d.detail, detail);
            snprintf(label, sizeof(label), "%s /28 %s endpoint helper label", p.vendor, i ? "last" : "first");
            chkStr(label, netcamVendorOui(endpoints[i]), p.vendor);
        }
        const uint8_t* neighbors[] = { p.before, p.after };
        for (size_t i = 0; i < 2; i++) {
            std::vector<uint8_t> f = uplink(neighbors[i]);
            snprintf(label, sizeof(label), "%s /28 immediately %s -> no hit", p.vendor, i ? "after" : "before");
            chk(label, run(f, true, &d), false);
            snprintf(label, sizeof(label), "%s /28 helper rejects %s neighbor", p.vendor, i ? "upper" : "lower");
            chkBool(label, netcamVendorOui(neighbors[i]) == nullptr);
        }
        uint8_t randomized[6]; memcpy(randomized, p.low, sizeof(randomized));
        randomized[0] |= 0x02;
        std::vector<uint8_t> f = uplink(randomized);
        snprintf(label, sizeof(label), "%s /28 with locally-administered bit -> no hit", p.vendor);
        chk(label, run(f, true, &d), false);
        snprintf(label, sizeof(label), "%s /28 helper rejects locally-administered MAC", p.vendor);
        chkBool(label, netcamVendorOui(randomized) == nullptr);
    }
    { std::vector<uint8_t> f = uplink(MAC_WYZE_CAPTURE1);
      chk("Camarillo Wyze a4:da:22:2e:fe:07 -> 65", run(f, true, &d), true,
          d.confidence, 65, d.detail, "Wyze on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_WYZE_CAPTURE2);
      chk("Camarillo Wyze a4:da:22:2e:a7:be -> 65", run(f, true, &d), true,
          d.confidence, 65, d.detail, "Wyze on wifi");
      chkStr("helper resolves second Camarillo Wyze", netcamVendorOui(MAC_WYZE_CAPTURE2), "Wyze"); }

    // ---- the whole table, in one sweep --------------------------------------------------------
    // Every entry must hit, format identically, and land on the tier its validated flag claims.
    // This is what catches a new OUI pasted in with a typo'd label or a stray validated=1.
    { note[0] = 0; int validated = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++) {
          const NetcamOui& e = CAMERA_VENDOR_OUI[i];
          uint8_t m[6] = { e.oui[0], e.oui[1], e.oui[2], 0x01, 0x02, 0x03 };
          std::vector<uint8_t> f = uplink(m);
          char want[64]; snprintf(want, sizeof(want), "%s on wifi", e.vendor);
          int wantConf = e.validated ? 75 : 65;
          if (e.validated) validated++;
          bool hit = run(f, true, &d);
          if ((!hit || strcmp(d.detail, want) || d.confidence != wantConf) && !note[0])
              snprintf(note, sizeof(note), "idx %zu %02x:%02x:%02x hit=%d conf=%d detail=\"%s\" want=\"%s\"",
                       i, e.oui[0], e.oui[1], e.oui[2], hit, d.confidence, d.detail, want);
      }
      chkBool("all table OUIs hit as \"<Vendor> on wifi\" at 65/75", note[0] == 0, note);
      chkBool("exactly 4 entries are flagged field-validated", validated == 4); }
    // A TRIPWIRE, not a fact: it exists so nobody grows this table without re-confirming the
    // blocks against the IEEE registry and thinking about the false-positive cost. 43 -> 59 on
    // 2026-08-02 (Ezviz 14, Lorex 1, Swann 1), 59 -> 62 on 2026-08-05 (Arlo 3), then 62 -> 180 on
    // 2026-08-07: Hikvision 7 -> 86 and Dahua 6 -> 33 (the vendors' COMPLETE MA-L sets, the table
    // had held under a tenth of what those two companies own), plus Verkada, i-PRO, Vivotek,
    // Uniview x4, Amcrest x2, Hanwha x2 and Samsung Techwin. All re-confirmed against a fresh
    // standards-oui.ieee.org pull. The 2026-09-01 refresh adds Ezviz and Uniview MA-Ls plus
    // three separate MA-M blocks. The capture review then adds twelve MA-L blocks across
    // Blink, Night Owl, SkyBell and Juan OEM, plus WUUK's MA-M. If this failed, read the DELIBERATELY
    // ABSENT block at the bottom of netcam_signatures.h before you bump the number.
    chkBool("table holds exactly 194 MA-L OUIs", CAMERA_VENDOR_OUI_COUNT == 194);
    chkBool("fallback holds exactly 4 narrower prefixes", CAMERA_VENDOR_PREFIX_COUNT == 4);
    { note[0] = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++) {
          bool known = false;
          for (size_t v = 0; v < sizeof(KNOWN_VENDORS)/sizeof(KNOWN_VENDORS[0]); v++)
              if (!strcmp(CAMERA_VENDOR_OUI[i].vendor, KNOWN_VENDORS[v])) known = true;
          if (!known && !note[0]) snprintf(note, sizeof(note), "idx %zu unknown label \"%s\"", i,
                                           CAMERA_VENDOR_OUI[i].vendor);
      }
      for (size_t i = 0; i < CAMERA_VENDOR_PREFIX_COUNT; i++) {
          bool known = false;
          for (size_t v = 0; v < sizeof(KNOWN_VENDORS)/sizeof(KNOWN_VENDORS[0]); v++)
              if (!strcmp(CAMERA_VENDOR_PREFIX[i].vendor, KNOWN_VENDORS[v])) known = true;
          if (!known && !note[0]) snprintf(note, sizeof(note), "prefix idx %zu unknown label \"%s\"", i,
                                           CAMERA_VENDOR_PREFIX[i].vendor);
      }
      chkBool("every label is one of the 23 exact known vendor strings", note[0] == 0, note); }
    // A table OUI with the locally-administered bit set could never match, because netcamEntry()
    // rejects LA addresses before it looks at the table. Such an entry would be dead weight and a
    // sign the block was transcribed wrong, so assert none exists.
    { note[0] = 0;
      for (size_t i = 0; i < CAMERA_VENDOR_OUI_COUNT; i++)
          if ((CAMERA_VENDOR_OUI[i].oui[0] & 0x02) && !note[0])
              snprintf(note, sizeof(note), "idx %zu oui[0]=%02x has the LA bit set (unmatchable)",
                       i, CAMERA_VENDOR_OUI[i].oui[0]);
      chkBool("no table OUI has the locally-administered bit set", note[0] == 0, note); }
    chkBool("confidence macros still read 65 / 75",
            NETCAM_OUI_CONFIDENCE == 65 && NETCAM_OUI_CONFIDENCE_VALIDATED == 75);

    // ---- the rest of the detection record, which the app and the log both read ----------------
    { std::vector<uint8_t> f = uplink(MAC_REOLNK); bool hit = run(f, true, &d, -57);
      chkBool("type/src/method = ACAB_NETCAM / SRC_WIFI / M_OUI",
              hit && d.type == ACAB_NETCAM && d.src == SRC_WIFI && d.method == M_OUI);
      chkBool("MAC copied from the source-address offset, rssi kept",
              hit && !memcmp(d.mac, MAC_REOLNK, 6) && d.rssi == -57);
      chkBool("companyId stays 0 (this is a WiFi path, not BLE)", hit && d.companyId == 0);
      // randomAddr is false because LA addresses never reach here, so the central durability
      // down-cap (M_OUI + randomAddr -> 25) can never touch a netcam hit. Assert that, because a
      // future "match randomized MACs too" change would silently collapse 75 to 25.
      chkBool("randomAddr false, so durability leaves the 75 alone",
              hit && !d.randomAddr && (acabApplyDurability(&d), d.confidence == 75)); }

    // ---- which address the DS bits select ------------------------------------------------------
    // Decoy layout: Hikvision at addr2 (10), Reolink at addr3 (16), Wyze at addr4 (24). Whichever
    // vendor comes back names the offset the classifier actually read.
    { std::vector<uint8_t> f = frame(40, 0x00);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS=0/FromDS=0 (ad-hoc) -> addr2", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x01);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS=1 (camera uploading) -> addr2", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x02);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data FromDS=1 (AP relay) -> addr3, not addr2", run(f, true, &d), true, d.confidence, 75, d.detail,
          "Reolink on wifi"); }
    { std::vector<uint8_t> f = frame(40, 0x03);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("data ToDS+FromDS (WDS 4-address) -> addr4", run(f, true, &d), true, d.confidence, 65, d.detail,
          "Wyze on wifi"); }
    // Mgmt frames have no DS semantics: addr2 is always the transmitter. So the same buffer that
    // resolved to Reolink as a data frame must resolve to Hikvision as a mgmt frame.
    { std::vector<uint8_t> f = frame(40, 0x03);
      putMac(f, 10, MAC_HIK); putMac(f, 16, MAC_REOLNK); putMac(f, 24, MAC_WYZE);
      chk("mgmt frame ignores the DS bits -> always addr2", run(f, false, &d), true, d.confidence, 65,
          d.detail, "Hikvision on wifi"); }
    { std::vector<uint8_t> f = frame(16, 0x00); putMac(f, 10, MAC_RING);
      chk("mgmt frame of exactly 16 bytes (the minimum) still hits", run(f, false, &d), true,
          d.confidence, 65, d.detail, "Ring on wifi"); }

    // ---- Arlo base-station SSID rule (added 2026-08-05) -----------------------------------------
    // The SSID outranks every OUI tier, so these also pin the PRECEDENCE: a frame that could match
    // both must report 88, not the OUI's 65/75.
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_PAD);
      chk("beacon SSID ARLO_VMB_ -> base station at the SSID tier", run(f, false, &d), true,
          d.confidence, 88, d.detail, "Arlo base station"); }
    { std::vector<uint8_t> f = beacon("arlo_vmb_2983159490", MAC_PAD);
      chk("SSID match is case-insensitive", run(f, false, &d), true,
          d.confidence, 88, d.detail, "Arlo base station"); }
    { std::vector<uint8_t> f = beacon("NTGR_VMB_8967923929", MAC_PAD);
      chk("legacy NETGEAR-era NTGR_VMB_ form also hits", run(f, false, &d), true,
          d.confidence, 88, d.detail, "Arlo base station"); }
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1", MAC_ARLO);
      chk("SSID BEATS the Arlo OUI on the same frame (88, not 65)", run(f, false, &d), true,
          d.confidence, 88, d.detail, "Arlo base station"); }
    // Anchoring: the prefix must be at the HEAD. An SSID that merely contains it is somebody
    // else's network name and must fall through to the OUI path (here: no OUI, so no hit).
    { std::vector<uint8_t> f = beacon("MY_ARLO_VMB_1164328298", MAC_PAD);
      chk("prefix is anchored, not a substring -> no SSID hit", run(f, false, &d), false); }
    { std::vector<uint8_t> f = beacon("ARLO", MAC_PAD);
      chk("SSID shorter than the prefix -> no hit, no overrun", run(f, false, &d), false); }
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_HIK);
      chk("non-Arlo OUI still reports the base station when the SSID says so", run(f, false, &d),
          true, d.confidence, 88, d.detail, "Arlo base station"); }
    // THE OFFSET TRAP, pinned. A beacon's IEs start at 36, not 24. Planting the SSID IE at 24
    // (the probe-REQUEST offset) must NOT match: that is the exact silent-failure mode the parse
    // comment in flock_detect.cpp warns about, and the only way to catch it is a negative test.
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_PAD);
      std::vector<uint8_t> g = frame(f.size(), 0x00);
      g[0] = 0x80;
      // rebuild with the IE at the probe-req offset instead of the beacon offset
      g[24] = 0x00; g[25] = 19; for (int i = 0; i < 19; i++) g[26 + i] = "ARLO_VMB_1164328298"[i];
      putMac(g, 10, MAC_PAD);
      chk("beacon with its SSID IE at offset 24 (wrong) -> no hit", run(g, false, &d), false); }
    // PROBE REQUESTS ARE EXCLUDED ON PURPOSE, and this test guards that, not an offset.
    // A probe request's SSID IE is the network being SEARCHED FOR and addr2 is the searching
    // station, so the frame attests NOTHING about the transmitter - which is what the 88 tier is
    // sold on. Admitting 0x4 reported an Arlo CAMERA hunting its hub (or any phone with that SSID
    // saved, on a randomized MAC) as "Arlo base station" at 88: wrong box, top tier, address never
    // seen again. If this ever starts hitting, the tier is lying.
    { std::vector<uint8_t> g = frame(64, 0x00);
      g[0] = 0x40;   // subtype 0x4 = probe request
      g[24] = 0x00; g[25] = 19; for (int i = 0; i < 19; i++) g[26 + i] = "ARLO_VMB_1164328298"[i];
      putMac(g, 10, MAC_PAD);
      chk("probe-request for an ARLO_VMB_ SSID -> NO hit (asks for it, isn't it)",
          run(g, false, &d), false); }
    // PROBE RESPONSE (0x5) shares the beacon's offset-36 body and IS a self-attestation, so it
    // must hit. Without this the 24-vs-36 rule is only half pinned.
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_PAD);
      f[0] = 0x50;   // subtype 0x5 = probe response
      chk("probe-response SSID at offset 36 -> hits", run(f, false, &d), true,
          d.confidence, 88, d.detail, "Arlo base station"); }
    // The SSID itself must survive into the record: it is the evidence for the 88, and the row
    // title falls back to a bare "Network camera" without it.
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_PAD);
      chk("matched SSID is kept as the detection name", run(f, false, &d), true,
          -1, -1, d.name, "ARLO_VMB_1164328298"); }
    // The OUI half of the Arlo add, on the ordinary uplink path.
    { std::vector<uint8_t> f = uplink(MAC_ARLO);
      chk("Arlo a4:11:62 OUI on a data frame -> registry tier", run(f, true, &d), true,
          d.confidence, 65, d.detail, "Arlo on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_ARLO2);
      chk("Arlo fc:9c:98 OUI", run(f, true, &d), true, d.confidence, 65, d.detail, "Arlo on wifi"); }
    { std::vector<uint8_t> f = uplink(MAC_ARLO3);
      chk("Arlo 48:62:64 OUI", run(f, true, &d), true, d.confidence, 65, d.detail, "Arlo on wifi"); }
    // A DATA frame carries no SSID IE. The SSID path must not run on it at all, or a byte sequence
    // in an encrypted payload could be parsed as an IE and matched.
    { std::vector<uint8_t> f = beacon("ARLO_VMB_1164328298", MAC_PAD);
      chk("same bytes as a DATA frame -> SSID path never runs", run(f, true, &d), false); }

    // ---- adversarial input ---------------------------------------------------------------------
    { std::vector<uint8_t> f;
      chk("empty buffer (len 0) -> no hit, no read", run(f, true, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("null frame pointer with a plausible len -> no hit",
          netcamClassifyWiFi(nullptr, 64, true, -50, &d), false); }
    { std::vector<uint8_t> f = frame(15, 0x01); putMac(f, 10, MAC_HIK, 5);
      chk("len 15 truncates the OUI -> below the 16-byte floor", run(f, true, &d), false); }
    // THE OVERRUN CASE: the frame-control bits DECLARE a 4-address WDS frame, so the source MAC is
    // claimed to be at offset 24, but the buffer is only 20 bytes long. The classifier must refuse,
    // and must NOT quietly fall back to the perfectly good Hikvision OUI sitting at offset 10.
    // Reading addr4 out of a 20-byte buffer is the read-past-the-end this test is here to prevent.
    { std::vector<uint8_t> f = frame(20, 0x03); putMac(f, 10, MAC_HIK);
      chk("FC claims addr4 but buffer is 20 bytes -> no hit, no fallback", run(f, true, &d), false); }
    { std::vector<uint8_t> f = frame(20, 0x02); putMac(f, 10, MAC_HIK);
      chk("FC claims addr3 at 16 in a 20-byte buffer -> no hit", run(f, true, &d), false); }
    // Near misses. One byte off a real block must not match: the compare is all three bytes.
    { uint8_t m[6] = { 0x18, 0x68, 0xcc, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("neighbouring OUI 18:68:cc (Hikvision is ..cb) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x4c, 0x11, 0xbe, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("neighbouring OUI 4c:11:be (Dahua is ..bf) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x18, 0x00, 0x00, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("first byte matches Hikvision, rest does not -> no hit", run(f, true, &d), false); }
    // Vendors the signature header EXCLUDES on purpose, because the registrant is too broad. If one
    // of these ever starts matching, someone widened the table past the narrowness rule.
    { uint8_t m[6] = { 0x24, 0x0a, 0xc4, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Espressif 24:0a:c4 (shared silicon, excluded) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x44, 0x65, 0x0d, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Amazon 44:65:0d (shared product block, excluded) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x18, 0xb4, 0x30, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Nest 18:b4:30 (excluded) -> no hit", run(f, true, &d), false); }
    // Randomized / locally-administered source MACs: the OUI means nothing there, so they are
    // dropped before the table is consulted, even when the remaining bytes spell a real block.
    { uint8_t m[6] = { 0x1a, 0x68, 0xcb, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Hikvision block with the LA bit set (1a:68:cb) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x02, 0xb4, 0x63, 0x01, 0x02, 0x03 }; std::vector<uint8_t> f = uplink(m);
      chk("Ring block with the LA bit set (02:b4:63) -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }; std::vector<uint8_t> f = uplink(m);
      chk("broadcast ff:ff:ff:ff:ff:ff -> no hit", run(f, true, &d), false); }
    { uint8_t m[6] = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 }; std::vector<uint8_t> f = uplink(m);
      chk("all-zero MAC -> no hit (3 vendors start with 0x00)", run(f, true, &d), false); }
    { const uint8_t unlisted[6] = { 0x24, 0x0a, 0xc4, 0, 0, 0 };
      chkBool("netcamVendorOui() returns nullptr for an unlisted OUI",
              netcamVendorOui(unlisted) == nullptr); }
    { const uint8_t randomized[6] = { 0x1a, 0x68, 0xcb, 0, 0, 0 };
      chkBool("netcamVendorOui() returns nullptr for a randomized MAC",
              netcamVendorOui(randomized) == nullptr); }
    chkBool("netcamVendorOui() returns nullptr for a null MAC", netcamVendorOui(nullptr) == nullptr);
    // On a miss the output record must be left completely alone: the caller reuses one AcabDetection
    // across every classifier in the chain, so a partial write here would leak a phantom camera
    // detail onto whichever detector matches next.
    { AcabDetection sentinel; memset(&sentinel, 0xEE, sizeof(sentinel));
      uint8_t m[6] = { 0x18, 0x68, 0xcc, 0x01, 0x02, 0x03 };
      std::vector<uint8_t> f = uplink(m);
      bool hit = netcamClassifyWiFi(f.data(), f.size(), true, -50, &sentinel);
      bool untouched = true;
      for (size_t i = 0; i < sizeof(sentinel); i++) if (((const uint8_t*)&sentinel)[i] != 0xEE) untouched = false;
      chkBool("a miss writes NOTHING into the caller's record", !hit && untouched); }

    // ---- turning it back off, and the restore path ---------------------------------------------
    netcamSetEnabled(false);
    chkBool("setEnabled(false) clears the flag", !netcamIsEnabled());
    chkBool("setEnabled(false) refreshed the filter (narrow to mgmt)", gFilterRefreshes == 2);
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("OFF again: field-validated Dahua frame -> no hit", run(f, true, &d), false); }
    netcamSetEnabled(false);
    chkBool("redundant setEnabled(false) is a no-op, still 2 refreshes", gFilterRefreshes == 2);

    // netcamRestoreEnabled() reads NVS on boot and, BY DESIGN, does not refresh the filter: it runs
    // before the scanner starts, and acabScannerBegin() reads netcamIsEnabled() when it installs the
    // filter. Asserted as-is. CONCERN worth knowing: because restore bypasses the setter, a later
    // setEnabled(true) on an already-restored-true flag early-returns and never refreshes either, so
    // anything that restores true AFTER the scanner is up depends on that boot-time read having
    // happened. Only boot calls this today, so it holds.
    // Preferences::wipeAll() is what MAKES "nothing saved" true. The host stub used to discard
    // every write, so these restore cases exercised the default branch by accident; now that it
    // really stores, the netcamSetEnabled(false) above persists and a bare restore would read
    // THAT back instead of the default each case name promises.
    Preferences::wipeAll();
    netcamRestoreEnabled(true);
    chkBool("restoreEnabled(true) sets the flag", netcamIsEnabled());
    chkBool("restoreEnabled() does NOT refresh the filter (by design)", gFilterRefreshes == 2);
    { std::vector<uint8_t> f = uplink(MAC_DAHUAV);
      chk("restored ON: classifier live again at tier 75", run(f, true, &d), true, d.confidence, 75,
          d.detail, "Dahua on wifi"); }
    netcamSetEnabled(true);
    chkBool("setEnabled(true) after restore(true) is a no-op", gFilterRefreshes == 2);
    Preferences::wipeAll();
    netcamRestoreEnabled(false);
    chkBool("restoreEnabled(false) restores the default-OFF state", !netcamIsEnabled());
    { std::vector<uint8_t> f = uplink(MAC_HIK);
      chk("restored OFF: no hit", run(f, true, &d), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
