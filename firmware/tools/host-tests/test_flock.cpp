// Host regression test for the Flock/ALPR classifier - the detector this product is named for.
//
// WHY THIS EXISTS: flock_detect.cpp is the one file where a silent regression costs the most. It
// has ranked match branches on both radios (today: Raven svc-UUID / name / mfg-ID / OUI on BLE,
// and six written WiFi branches - "Flock-" SSID, "*-FALCON" SSID, probe-SSID regrade, Falcon-OUI
// probe, wildcard probe, OUI - with the "*-FALCON" SSID forms ext=1-gated out of shipping
// builds), and these branches keep getting narrowed after field false positives (the OUI
// superset was deleted, name matching went from
// substring-anywhere to anchored, the beacon IE offset was split off from the probe-request one).
// Every one of those narrowings is invisible to the compiler: widen a pattern by accident and the
// field failure is a false alert, narrow one by accident and the field failure is SILENCE.
//
// The exact detail string and confidence are asserted on purpose, not just "did it hit": both
// cross the BLE GATT link into the apps, where confidence drives the weak-match ("verify this")
// treatment at the 50 threshold and detail is rendered verbatim.
//
// These tests lock in what the code does TODAY. Where today's behaviour looks questionable it is
// still asserted as-is, with the concern written down next to it.
#include "flock_detect.h"
#include "flock_signatures.h"
#include <cstdio>
#include <cstring>
#include <vector>

// ---- stubs for the two symbols flock_detect.cpp pulls from other translation units ----
// The harness compiles exactly one _detect.cpp, so anything else flock calls has to live here.
//
// Desert mode is a runtime override inside both classifiers ("classify even when toggled off"),
// so unlike test_glasses.cpp this stub is settable - that override is a behaviour worth locking,
// and it is still fully deterministic because only the test moves it.
static bool gDesert = false;
bool desertIsEnabled() { return gDesert; }

// Byte-for-byte copy of acab_scanner.cpp's implementation. It has to match, not merely exist:
// parseAdv runs every advertised name through it, so a divergence here would let a name pattern
// pass in the test that the firmware would never see (or the reverse).
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

static int failures = 0;
static void chk_impl(const char* name, bool got, bool wantHit,
                int gotConf = -1, int wantConf = -1, const char* gotDetail = "", const char* wantDetail = nullptr) {
    bool ok = (got == wantHit);
    if (ok && wantHit && wantConf >= 0) ok = (gotConf == wantConf);
    if (ok && wantHit && wantDetail)    ok = (strcmp(gotDetail, wantDetail) == 0);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got hit=%d conf=%d detail=\"%s\"", got, gotConf, gotDetail); failures++; }
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
// method / type / mac are consumed downstream too (acabApplyDurability keys on M_OUI, the apps
// route on type), so they get their own assertions on one representative case per branch.
static void chkInt(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}
static void chkStr(const char* name, const char* got, const char* want) {
    bool ok = (strcmp(got, want) == 0);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got \"%s\" want \"%s\"", got, want); failures++; }
    printf("\n");
}

// ---------------------------------------------------------------------------
// MACs. The PUBLIC/RANDOM fixture names describe the WiFi U/L bit, which the existing
// OUI guards also inspect. BLE address type cannot be inferred from this bit and is not
// passed to the classifier. No name-match confidence may depend on these address bytes.
// ---------------------------------------------------------------------------
static const uint8_t MAC_FLOCK[6]   = {0xb4,0x1e,0x52,0x11,0x22,0x33};  // Flock Safety MA-L bytes
static const uint8_t MAC_NEARMISS[6]= {0xb4,0x1e,0x53,0x11,0x22,0x33};  // one byte off the real OUI
static const uint8_t MAC_FLOCKLA[6] = {0xb6,0x1e,0x52,0x11,0x22,0x33};  // same OUI + local bit set
static const uint8_t MAC_PUBLIC[6]  = {0x00,0x11,0x22,0x33,0x44,0x55};  // U/L bit clear, no table hit
static const uint8_t MAC_RANDOM[6]  = {0xc2,0x33,0x44,0x55,0x66,0x77};  // local bit set, no table hit
static const uint8_t MAC_FALCON[6]  = {0xd8,0xf3,0xbc,0xaa,0xbb,0xcc};  // Liteon/Falcon WiFi module
static const uint8_t MAC_FALCONNM[6]= {0xd8,0xf3,0xbd,0xaa,0xbb,0xcc};  // neighbouring Liteon OUI

// ---- BLE advert builders (AD structures: [len][type][data...]) ----
static void addName(std::vector<uint8_t>& a, const char* n, uint8_t type = 0x09) {
    size_t l = strlen(n);
    a.push_back((uint8_t)(1 + l)); a.push_back(type);
    for (size_t i = 0; i < l; i++) a.push_back((uint8_t)n[i]);
}
static void addRawName(std::vector<uint8_t>& a, const uint8_t* d, size_t l) {
    a.push_back((uint8_t)(1 + l)); a.push_back(0x09);
    for (size_t i = 0; i < l; i++) a.push_back(d[i]);
}
static void addMfg(std::vector<uint8_t>& a, uint16_t cid) {
    a.push_back(3); a.push_back(0xFF);
    a.push_back(cid & 0xFF); a.push_back(cid >> 8);
}
static void addU16Svc(std::vector<uint8_t>& a, uint16_t uuid) {
    a.push_back(3); a.push_back(0x03); a.push_back(uuid & 0xFF); a.push_back(uuid >> 8);
}
// Raven advertises its services as 128-bit UUIDs on the Bluetooth base UUID, which is the whole
// reason parseAdv grew an 0x06/0x07 walk. onBase=false flips the base bytes to prove the guard.
static void add128Svc(std::vector<uint8_t>& a, uint16_t shortUuid, bool onBase = true) {
    static const uint8_t BASE_LE[12] = {0xfb,0x34,0x9b,0x5f,0x80,0x00,0x00,0x80,0x00,0x10,0x00,0x00};
    a.push_back(17); a.push_back(0x07);
    for (int i = 0; i < 12; i++) a.push_back(onBase ? BASE_LE[i] : (uint8_t)(BASE_LE[i] ^ 0xFF));
    a.push_back(shortUuid & 0xFF); a.push_back(shortUuid >> 8);
    a.push_back(0x00); a.push_back(0x00);
}
static bool runBLE(const uint8_t mac[6], std::vector<uint8_t>& a, AcabDetection* out) {
    memset(out, 0, sizeof(*out));
    return flockClassifyBLE(mac, a.empty() ? nullptr : a.data(), a.size(), -71, out);
}

// ---- 802.11 management frame builders ----
// [fc(2)][dur(2)][addr1(6)][addr2(6)][addr3(6)][seq(2)] = 24, then a 12-byte fixed body for
// beacon (0x8) and probe-response (0x5) only. Getting that split wrong is the documented silent
// failure, so the builder reproduces the real layout rather than a flat offset.
static const uint8_t BCAST[6] = {0xff,0xff,0xff,0xff,0xff,0xff};
static std::vector<uint8_t> mgmt(uint8_t subtype, const uint8_t a2[6], const uint8_t a3[6]) {
    std::vector<uint8_t> f;
    f.push_back((uint8_t)(subtype << 4));      // ftype bits stay 0 = management
    f.push_back(0x00);
    f.push_back(0x00); f.push_back(0x00);      // duration
    for (int i = 0; i < 6; i++) f.push_back(BCAST[i]);
    for (int i = 0; i < 6; i++) f.push_back(a2[i]);
    for (int i = 0; i < 6; i++) f.push_back(a3[i]);
    f.push_back(0x00); f.push_back(0x00);      // sequence control -> header ends at 24
    if (subtype == 0x5 || subtype == 0x8) {
        // TSF timestamp is deliberately 0x77 filler: 0x77 is a non-zero element id with a
        // 119-byte length, so a parser that (wrongly) starts at 24 walks off the end and finds
        // no SSID at all. That is what makes the beacon tests below a real offset assertion.
        for (int i = 0; i < 8; i++) f.push_back(0x77);
        f.push_back(0x64); f.push_back(0x00);  // beacon interval
        f.push_back(0x11); f.push_back(0x04);  // capability info
    }
    return f;
}
static void addSSID(std::vector<uint8_t>& f, const char* ssid) {
    size_t n = strlen(ssid);
    f.push_back(0x00); f.push_back((uint8_t)n);
    for (size_t i = 0; i < n; i++) f.push_back((uint8_t)ssid[i]);
}
static bool runWiFi(std::vector<uint8_t>& f, AcabDetection* out) {
    memset(out, 0, sizeof(*out));
    return flockClassifyWiFi(f.data(), f.size(), -63, out);
}
static const char* macStr(const AcabDetection& d) {
    static char buf[18]; acabFormatMac(d.mac, buf); return buf;
}

int main() {
    AcabDetection d;
    printf("\n=== flock (ALPR) classifier regression ===\n");

    // -- toggle entry points -------------------------------------------------
    // Default ON is load-bearing: this is the headline detector, and a board that boots with it
    // off looks identical to a board that is simply not near a camera.
    printf("\n  -- toggle --\n");
    chkInt("flockIsEnabled() defaults to ON", flockIsEnabled() ? 1 : 0, 1);
    // The Preferences stub DOES persist now (it backs test_axon/test_desert's persistence
    // assertions), but this binary never writes the flock key, so the store is genuinely empty
    // here and this asserts the boot path: "no key saved yet -> use defaultEnabled".
    flockRestoreEnabled(false);
    chkInt("flockRestoreEnabled(false), nothing in NVS", flockIsEnabled() ? 1 : 0, 0);
    flockRestoreEnabled(true);
    chkInt("flockRestoreEnabled(true), nothing in NVS", flockIsEnabled() ? 1 : 0, 1);

    flockSetEnabled(false);
    chkInt("flockSetEnabled(false) reads back", flockIsEnabled() ? 1 : 0, 0);
    { std::vector<uint8_t> a; addName(a, "Penguin-0123456789");
      chk("disabled: matching BLE name still no hit", runBLE(MAC_FLOCK, a, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      chk("disabled: strongest WiFi SSID still no hit", runWiFi(f, &d), false); }
    // Desert mode overrides the toggle inside both classifiers (it force-classifies everything),
    // so an off Flock toggle must NOT suppress a real ALPR hit while Desert is on.
    gDesert = true;
    { std::vector<uint8_t> a; addName(a, "Penguin-0123456789");
      chk("disabled + Desert on: BLE classifies anyway", runBLE(MAC_FLOCK, a, &d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      chk("disabled + Desert on: WiFi classifies anyway", runWiFi(f, &d), true, d.confidence, 88, d.detail); }
    gDesert = false;
    flockSetEnabled(true);
    chkInt("flockSetEnabled(true) restores", flockIsEnabled() ? 1 : 0, 1);

    // -- BLE: Raven (checked first, most specific) ---------------------------
    // The fw-family guess is a hint derived purely from WHICH services are present, so each combo
    // is pinned. If someone re-orders the ifs in estimateRavenFW these are the only tripwire.
    printf("\n  -- BLE: Raven --\n");
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_GPS);
      chk("Raven GPS svc only -> fw 1.2.x", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.2.x"); }
    chkInt("  ...type is ACAB_FLOCK_RAVEN", d.type, ACAB_FLOCK_RAVEN);
    chkInt("  ...method is M_SERVICE_UUID", d.method, M_SERVICE_UUID);
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_GPS); addU16Svc(a, RAVEN_SVC_POWER);
      chk("Raven GPS + POWER -> fw 1.3.x", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.3.x"); }
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_OLDLOC); addU16Svc(a, RAVEN_SVC_NETWORK);
      chk("Raven old LOC + NETWORK -> fw 1.1.x", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.1.x"); }
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_UPLOAD);
      chk("Raven UPLOAD only -> fw unknown", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw ?"); }
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_ERROR);
      chk("Raven ERROR svc alone still fires", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw ?"); }
    // The 128-bit walk exists because real Ravens advertise this way; before it existed they fell
    // through to the camera branches and were reported as cameras.
    { std::vector<uint8_t> a; add128Svc(a, RAVEN_SVC_GPS);
      chk("Raven GPS as a 128-bit UUID on the BT base", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.2.x"); }
    { std::vector<uint8_t> a; add128Svc(a, RAVEN_SVC_GPS, false);
      chk("same short, NOT on the BT base -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    // The std BT SIG profile UUIDs are backup context only. On their own they are a thermometer
    // or a Device Information service, i.e. half the BLE gadgets on earth.
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_OLDLOC);
      chk("std SIG 0x1819 alone -> NOT a Raven", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addU16Svc(a, RAVEN_SVC_DEVINFO); addU16Svc(a, RAVEN_SVC_OLDHEALTH);
      chk("std SIG 0x180a+0x1809 -> NOT a Raven", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addU16Svc(a, 0x3101);
      chk("near-miss vendor svc 0x3101 -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    // Raven outranks every camera signal, including a name that would otherwise score 70.
    { std::vector<uint8_t> a; addName(a, "Flock Sensor"); addU16Svc(a, RAVEN_SVC_GPS);
      chk("Raven svc + Flock name -> Raven, not camera", runBLE(MAC_FLOCK, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.2.x"); }
    chkStr("  ...name still carried through", d.name, "Flock Sensor");

    // -- BLE: advertised-name patterns --------------------------------------
    // The anchoring here is the fix for "any name containing flock/penguin/FS- is an ALPR camera".
    // 80 vs 70 is not cosmetic: 70 is hint-grade in the apps, 80 draws the strong verdict.
    printf("\n  -- BLE: name patterns --\n");
    { std::vector<uint8_t> a; addName(a, "FS Ext Battery");
      chk("literal 'FS Ext Battery' needs no co-signal = 80", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 80, d.detail, ""); }
    chkInt("  ...type is ACAB_FLOCK_CAMERA", d.type, ACAB_FLOCK_CAMERA);
    chkInt("  ...method is M_NAME", d.method, M_NAME);
    { std::vector<uint8_t> a; addName(a, "beacon FS Ext Battery 3");
      chk("literal matches as a substring, anywhere", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 80, d.detail); }
    { std::vector<uint8_t> a; addName(a, "Penguin-0123456789");
      chk("'Penguin-'+digits with MAC bit clear = 70", runBLE(MAC_PUBLIC, a, &d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> a; addName(a, "Penguin-0123456789");
      chk("'Penguin-'+digits with MAC bit set = 70", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> a; addName(a, "FS-BEC46A");
      chk("'FS-'+hex without mfg = 70 (hint grade)", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    // The retained co-signal: the 0x09C8 mfg id promotes an anchored name independently of MAC.
    { std::vector<uint8_t> a; addName(a, "FS-BEC46A"); addMfg(a, 0x09C8);
      chk("'FS-'+hex + 0x09C8 co-signal = 80", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 80, d.detail); }
    { std::vector<uint8_t> a; addName(a, "Flock Beacon 4");
      chk("loose 'Flock' prefix without mfg = 70", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    { std::vector<uint8_t> a; addName(a, "flocking gadget");
      chk("loose prefix is case-insensitive (70)", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }

    // The removed boost mistook bit 0x02 for BLE address type: 44:... + FS-100 scored 80,
    // while 46:... scored 70. The controller type is absent here, and a generic address
    // supplies no Flock evidence. Exercise both bit states and 00:... for each name form;
    // only the supported manufacturer co-signal may promote a non-literal name.
    const uint8_t nameMacs[][6] = {
        {0x44,0x33,0x44,0x55,0x66,0x77},
        {0x46,0x33,0x44,0x55,0x66,0x77},
        {0x00,0x11,0x22,0x33,0x44,0x55},
    };
    const char* names[] = { "FS-100", "Penguin-0123456789", "FS-BEC46A", "Flock Beacon" };
    for (const auto& mac : nameMacs) {
        char label[112];
        for (const char* name : names) {
            std::vector<uint8_t> a; addName(a, name);
            snprintf(label, sizeof(label), "%s on %02x:... without mfg -> 70", name, mac[0]);
            chk(label, runBLE(mac, a, &d), true, d.confidence, 70, d.detail, "");

            addMfg(a, 0x09C7);
            snprintf(label, sizeof(label), "%s on %02x:... + unrelated mfg -> 70", name, mac[0]);
            chk(label, runBLE(mac, a, &d), true, d.confidence, 70, d.detail, "");

            a.clear(); addName(a, name); addMfg(a, 0x09C8);
            snprintf(label, sizeof(label), "%s on %02x:... + 0x09C8 -> 80", name, mac[0]);
            chk(label, runBLE(mac, a, &d), true, d.confidence, 80, d.detail, "");
        }
        std::vector<uint8_t> a; addName(a, "FS Ext Battery");
        snprintf(label, sizeof(label), "FS Ext Battery on %02x:... without mfg -> 80", mac[0]);
        chk(label, runBLE(mac, a, &d), true, d.confidence, 80, d.detail, "");
    }
    // The exact false positives the anchoring was written to kill. Each of these matched before.
    { std::vector<uint8_t> a; addName(a, "penguins fan");
      chk("'penguins fan' -> NO hit (was a match)", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "MyPenguin-123");
      chk("'Penguin-' not at the start -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "Penguin-12a3");
      chk("'Penguin-' + non-digit tail -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "Penguin-");
      chk("'Penguin-' with an empty tail -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "FS-ZZZ");
      chk("'FS-' + non-hex tail -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "0102000000");
      chk("bare 10-digit name -> no hit (removed)", runBLE(MAC_RANDOM, a, &d), false); }
    // CONCERN, asserted as-is: "FS-100" is a common white-label speaker/model name and its tail is
    // valid hex, so it still matches at hint grade. The 70 cap is the mitigation, not a fix.
    { std::vector<uint8_t> a; addName(a, "FS-100");
      chk("'FS-100' consumer gadget still hints at 70", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    // Name outranks the mfg-id hint: a named Flock beacon must report the strong signal, not 45.
    { std::vector<uint8_t> a; addMfg(a, 0x09C8); addName(a, "Flock Beacon");
      chk("name beats mfg-id even when mfg parses first", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 80, d.detail); }
    chkInt("  ...method is M_NAME, not M_MFG_ID", d.method, M_NAME);
    // Shortened-name AD (0x08) has to be honoured too; some beacons only ever send the short form.
    { std::vector<uint8_t> a; addName(a, "Flock Beacon", 0x08);
      chk("shortened-name AD type 0x08 is parsed", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    // Names arrive from the air, so they are sanitized on ingest. If the sanitize call is ever
    // dropped, these two assertions are what notices.
    { std::vector<uint8_t> a; const uint8_t raw[9] = {'F','l','o','c','k',0x01,0xFF,'A','P'};
      addRawName(a, raw, 9);
      chk("control/high bytes in a name still match", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    chkStr("  ...non-printables clamped to '.'", d.name, "Flock..AP");
    { std::vector<uint8_t> a; const uint8_t raw[6] = {0xFF,0xFE,0xFD,0xFC,0xFB,0xFA};
      addRawName(a, raw, 6);
      chk("all-high-byte name -> sanitized, no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addName(a, "Flock-01234567890123456789012345678901234567890123456789");
      chk("60-char name still matches", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 70, d.detail); }
    chkInt("  ...name truncated to the 40-byte field", (long)strlen(d.name), 39);

    // -- BLE: manufacturer company id ---------------------------------------
    // 0x09C8 is SHARED silicon (XUNTONG), so it is deliberately pinned BELOW the apps' weak-match
    // threshold of 50. Raising it is a product decision, not a tuning tweak: at >= 50 every
    // XUNTONG-module gadget in range renders as a calm partial ALPR match.
    printf("\n  -- BLE: manufacturer id --\n");
    { std::vector<uint8_t> a; addMfg(a, 0x09C8);
      chk("mfg 0x09C8 alone = 45, below the 50 line", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 45, d.detail, "mfg 0x09C8"); }
    chkInt("  ...method is M_MFG_ID", d.method, M_MFG_ID);
    // CONCERN, asserted as-is: flock never fills companyId, even on the branch that matched on it,
    // so downstream consumers of that field see 0 for every Flock detection.
    chkInt("  ...companyId left at 0 (not populated)", d.companyId, 0);
    { std::vector<uint8_t> a; addMfg(a, 0x09C7);
      chk("neighbouring mfg id 0x09C7 -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x09C9);
      chk("neighbouring mfg id 0x09C9 -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x004C);
      chk("Apple 0x004C -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; addMfg(a, 0xC809);
      chk("byte-swapped 0xC809 -> no hit (LE order)", runBLE(MAC_RANDOM, a, &d), false); }
    // Only the FIRST mfg block is kept, so a crafted advert can hide the real id behind a decoy.
    // Asserted as-is: it is also what keeps a malformed multi-mfg advert from flip-flopping.
    { std::vector<uint8_t> a; addMfg(a, 0x004C); addMfg(a, 0x09C8);
      chk("second mfg block ignored -> no hit", runBLE(MAC_RANDOM, a, &d), false); }

    // -- BLE: OUI ------------------------------------------------------------
    // Weakest BLE signal, and the one the durability policy later caps at 25 on a random address.
    printf("\n  -- BLE: OUI --\n");
    { std::vector<uint8_t> a;
      chk("b4:1e:52 with an empty advert = 65", runBLE(MAC_FLOCK, a, &d), true, d.confidence, 65, d.detail, ""); }
    chkInt("  ...method is M_OUI", d.method, M_OUI);
    { std::vector<uint8_t> a; addName(a, "camera-7");
      chk("OUI hit carries a non-matching name through", runBLE(MAC_FLOCK, a, &d), true, d.confidence, 65, d.detail); }
    chkStr("  ...name field populated from the advert", d.name, "camera-7");
    { std::vector<uint8_t> a;
      chk("neighbouring OUI b4:1e:53 -> no hit", runBLE(MAC_NEARMISS, a, &d), false); }
    // Preserve the existing OUI guard: setting the U/L bit rejects this fixture. This tests
    // that guard's byte rule, not BLE address type, which the classifier does not receive.
    { std::vector<uint8_t> a;
      chk("b6:1e:52 (local bit set) -> no hit", runBLE(MAC_FLOCKLA, a, &d), false); }

    // -- durability down-cap: the POSITIVE case -------------------------------
    // THIS IS THE ASSERTION THAT PINS acabApplyDurability (detection.h). Every other durability
    // check in this suite is a NEGATIVE: they prove the cap leaves M_MFG_ID, M_SERVICE_DATA and
    // fixed-address hits alone. None proved the cap ever FIRES, and the difference is not
    // academic. Deleting the rule outright left all 538 assertions green, so the policy was
    // effectively untested while the suite's silence read as coverage.
    //
    // It is the only thing standing between an OUI-only match on a rotating address and a
    // confident-looking alert, which is exactly the false positive the README's reliability
    // section promises to suppress. Confidence also drives the buzzer, so a regression here is
    // audible in the field before it is visible anywhere else.
    printf("\n  -- durability down-cap --\n");
    {   std::vector<uint8_t> a;
        chk("setup: OUI-only hit at 65", runBLE(MAC_FLOCK, a, &d), true, d.confidence, 65, d.detail);
        AcabDetection dd = d;
        dd.randomAddr = true;               // same hit, now on a rotating address
        acabApplyDurability(&dd);
        chkInt("OUI-only on a rotating MAC caps at 25", dd.confidence, 25);
        chkInt("  ...and the method is untouched by the cap", dd.method, M_OUI);
    }
    {   // Boundary: the cap must never RAISE a confidence already at or below the floor. Guards
        // the `> 25` comparison against being mutated into an unconditional assignment.
        AcabDetection dd{};
        dd.method = M_OUI; dd.randomAddr = true; dd.confidence = 10;
        acabApplyDurability(&dd);
        chkInt("an OUI hit already below the floor is left alone", dd.confidence, 10);
    }

    // -- BLE: adversarial input ---------------------------------------------
    printf("\n  -- BLE: adversarial --\n");
    { std::vector<uint8_t> a;
      chk("empty advert on a neutral MAC -> no hit", runBLE(MAC_PUBLIC, a, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("null advert pointer -> no crash, no hit", flockClassifyBLE(MAC_PUBLIC, nullptr, 0, -71, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("null advert on a Flock MAC -> OUI hit", flockClassifyBLE(MAC_FLOCK, nullptr, 0, -71, &d), true, d.confidence, 65, d.detail); }
    { std::vector<uint8_t> a; a.push_back(200); a.push_back(0x09); a.push_back('F'); a.push_back('S');
      chk("AD length 200 overruns the buffer -> no hit", runBLE(MAC_PUBLIC, a, &d), false); }
    { std::vector<uint8_t> a; a.push_back(0x00); addName(a, "Flock Beacon");
      chk("zero-length AD stops the walk -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; a.push_back(2); a.push_back(0xFF); a.push_back(0xC8);
      chk("mfg block with 1 data byte -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    { std::vector<uint8_t> a; a.push_back(1); a.push_back(0x09);
      chk("name AD with zero data bytes -> no hit", runBLE(MAC_RANDOM, a, &d), false); }
    // svc16[] holds 16 entries, but the Raven checks run on every UUID BEFORE the cap (evidence
    // displaces proximity, mark_table.h), so filler can no longer hide a real Raven. This used to
    // assert the drop as reality; the concern it recorded is now the fixed behaviour.
    { std::vector<uint8_t> a; for (int i = 0; i < 16; i++) addU16Svc(a, 0x1234);
      addU16Svc(a, RAVEN_SVC_GPS);
      chk("Raven svc past the 16-slot cap -> STILL hits", runBLE(MAC_RANDOM, a, &d), true,
          d.confidence, 92, d.detail, "raven fw 1.2.x"); }
    { std::vector<uint8_t> a; for (int i = 0; i < 15; i++) addU16Svc(a, 0x1234);
      addU16Svc(a, RAVEN_SVC_GPS);
      chk("Raven svc in the 16th slot -> still hits", runBLE(MAC_RANDOM, a, &d), true, d.confidence, 92, d.detail, "raven fw 1.2.x"); }
    // A 16-bit UUID list with an odd byte count drops the dangling byte, and the walk never
    // carries it into the next AD structure. So a Raven short (0x3100) split 0x00 | 0x31 across
    // two lists is not reassembled, which is the safe outcome in both directions.
    { std::vector<uint8_t> a;
      a.push_back(4); a.push_back(0x03); a.push_back(0x34); a.push_back(0x12); a.push_back(0x00);
      a.push_back(2); a.push_back(0x03); a.push_back(0x31);
      chk("Raven short split across 2 UUID lists -> no hit", runBLE(MAC_RANDOM, a, &d), false); }

    // -- WiFi: SSID (the primary signature) ----------------------------------
    printf("\n  -- WiFi: SSID --\n");
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      chk("beacon 'Flock-...' (IEs at 36) = 88", runWiFi(f, &d), true, d.confidence, 88, d.detail, ""); }
    chkInt("  ...method is M_SSID", d.method, M_SSID);
    chkInt("  ...src is SRC_WIFI", d.src, SRC_WIFI);
    chkStr("  ...name is the SSID", d.name, "Flock-a1b2c3");
    chkStr("  ...mac is the transmitter (addr2)", macStr(d), "00:11:22:33:44:55");
    { std::vector<uint8_t> f = mgmt(0x5, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      chk("probe-response 'Flock-...' (IEs at 36)", runWiFi(f, &d), true, d.confidence, 88, d.detail); }
    { std::vector<uint8_t> f = mgmt(0x4, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      // REGRADED 2026-08-05: a probe request names the network SOUGHT, not the transmitter, so it
      // cannot carry the 88 self-attestation tier - that reported any phone with a "Flock-" network
      // saved, on a rotating random MAC, as a Flock camera. Still detected, at the probe tier.
      chk("probe-request 'Flock-...' (IEs at 24) -> probe tier, not 88", runWiFi(f, &d), true,
          d.confidence, 72, d.detail, "probing for a Flock network"); }
    // No OUI gate on the SSID path on purpose: the camera's WiFi MAC belongs to the module maker.
    { std::vector<uint8_t> f = mgmt(0x8, MAC_RANDOM, MAC_RANDOM); addSSID(f, "Flock-a1b2c3");
      chk("SSID match needs no OUI (random MAC ok)", runWiFi(f, &d), true, d.confidence, 88, d.detail); }
    // CONCERN, asserted as-is: this prefix test is the only case-SENSITIVE comparison in the file
    // (strncmp, while the Falcon suffix and every BLE name test are case-insensitive).
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "flock-a1b2c3");
      chk("lowercase 'flock-' -> NO hit (case sensitive)", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "MyFlock-a1b2c3");
      chk("'Flock-' not at the start -> no hit", runWiFi(f, &d), false); }
    // The "*-FALCON" SSID rule is RETIRED to ext=1 (2026-08-25) and compiled out: its evidence was
    // the firmware's own "PROBE-FALCON"/"DATA-FALCON" diagnostic label read back out of a capture
    // as though it were a broadcast SSID. These three assert that NOTHING on the air reaches the
    // 85 tier by name alone any more; they are the regression guard against re-shipping it without
    // a real capture. Provenance and the bar to re-ship: FLOCK_SSID_FALCON_SUFFIX.
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "DATA-FALCON");
      chk("'DATA-FALCON' beacon -> no hit (rule is ext=1)", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "probe-falcon");
      chk("lowercase '-falcon' beacon -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x4, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "probe-falcon");
      chk("'-falcon' probe request -> no hit", runWiFi(f, &d), false); }
    // Anchored as a suffix precisely so the sports team and the spaceship do not alert. They stay
    // here because the anchor still has to hold on the day the rule is re-armed with real evidence.
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Atlanta-Falcons");
      chk("'Atlanta-Falcons' -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Millennium Falcon");
      chk("'Millennium Falcon' -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC);
      addSSID(f, "Flock-0123456789012345678901234567890123456789");
      chk("44-char SSID still matches the prefix", runWiFi(f, &d), true, d.confidence, 88, d.detail); }
    chkInt("  ...SSID truncated at 32 bytes", (long)strlen(d.name), 32);

    // -- WiFi: Falcon probe-request OUI --------------------------------------
    // Liteon is shared silicon, so this branch is gated to probe requests only. Removing that gate
    // would flag every not-yet-associated laptop with a Liteon NIC as an ALPR camera.
    printf("\n  -- WiFi: Falcon probe OUI --\n");
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FALCON, BCAST); addSSID(f, "HomeWiFi");
      chk("Falcon OUI on a probe request = 72", runWiFi(f, &d), true, d.confidence, 72, d.detail, "Falcon probe (OUI)"); }
    chkInt("  ...method is M_PROBE", d.method, M_PROBE);
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FALCON, MAC_FALCON); addSSID(f, "HomeWiFi");
      chk("same OUI in a BEACON -> no hit (gate holds)", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x5, MAC_FALCON, MAC_FALCON); addSSID(f, "HomeWiFi");
      chk("same OUI in a probe RESPONSE -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FALCONNM, BCAST); addSSID(f, "HomeWiFi");
      chk("neighbouring OUI d8:f3:bd -> no hit", runWiFi(f, &d), false); }
    // With the "*-FALCON" name rule retired to ext=1, the SSID no longer adds anything to a
    // Falcon-OUI frame: the probe-request gate on the OUI is the whole signal. A beacon from the
    // same OUI still does not report, and a probe request reports at the OUI tier with the OUI's
    // own detail. That is the exact shape the retirement was meant to leave behind - a lone
    // "-FALCON" name can no longer promote anything.
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FALCON, MAC_FALCON); addSSID(f, "PROBE-FALCON");
      chk("Falcon OUI + '-FALCON' SSID in a beacon -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FALCON, BCAST); addSSID(f, "PROBE-FALCON");
      chk("Falcon OUI + '-FALCON' SSID in a probe request -> OUI tier",
          runWiFi(f, &d), true, d.confidence, 72, d.detail, "Falcon probe (OUI)"); }

    // -- WiFi: Flock's own OUI ----------------------------------------------
    printf("\n  -- WiFi: b4:1e:52 OUI --\n");
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FLOCK, BCAST); addSSID(f, "");
      chk("empty-SSID probe from b4:1e:52 = 78", runWiFi(f, &d), true, d.confidence, 78, d.detail, "wildcard probe"); }
    chkInt("  ...method is M_PROBE", d.method, M_PROBE);
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FLOCK, BCAST); addSSID(f, "SomeNetwork");
      chk("named probe from b4:1e:52 = 68 (OUI grade)", runWiFi(f, &d), true, d.confidence, 68, d.detail, ""); }
    chkInt("  ...method is M_OUI", d.method, M_OUI);
    chkStr("  ...name is the SSID", d.name, "SomeNetwork");
    // The 78 upgrade needs an SSID element that is present AND empty. No element at all is not
    // the same thing, and the code deliberately does not treat it as one.
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FLOCK, BCAST);
      chk("probe with NO SSID element = 68, not 78", runWiFi(f, &d), true, d.confidence, 68, d.detail); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FLOCK, MAC_FLOCK); addSSID(f, "");
      chk("empty SSID in a BEACON = 68 (probe-req only)", runWiFi(f, &d), true, d.confidence, 68, d.detail); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_FLOCK); addSSID(f, "SomeAP");
      chk("OUI on the BSSID (addr3) also matches", runWiFi(f, &d), true, d.confidence, 68, d.detail); }
    chkStr("  ...mac reported is addr3, not addr2", macStr(d), "b4:1e:52:11:22:33");
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FLOCKLA, MAC_FLOCKLA); addSSID(f, "SomeAP");
      chk("b6:1e:52 (local bit) on WiFi -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_NEARMISS, MAC_NEARMISS); addSSID(f, "SomeAP");
      chk("neighbouring OUI b4:1e:53 -> no hit", runWiFi(f, &d), false); }

    // -- WiFi: adversarial input ---------------------------------------------
    printf("\n  -- WiFi: adversarial --\n");
    { memset(&d, 0, sizeof(d));
      chk("null frame -> no crash, no hit", flockClassifyWiFi(nullptr, 64, -63, &d), false); }
    { std::vector<uint8_t> f;
      chk("empty frame buffer -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FLOCK, MAC_FLOCK); f.resize(23);
      chk("23-byte runt (header short by 1) -> no hit", runWiFi(f, &d), false); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FLOCK, MAC_FLOCK); f.resize(24);
      chk("beacon truncated to 24 -> OUI hit, no SSID", runWiFi(f, &d), true, d.confidence, 68, d.detail); }
    chkStr("  ...and no name is invented", d.name, "");
    // IE length that runs off the end: the walk breaks, so no SSID is seen. On a Flock probe
    // request that means the wildcard upgrade is NOT granted and it falls back to OUI grade.
    { std::vector<uint8_t> f = mgmt(0x4, MAC_FLOCK, BCAST);
      f.push_back(0x00); f.push_back(200); f.push_back('F'); f.push_back('l');
      chk("SSID IE length 200 overruns -> 68, not 78", runWiFi(f, &d), true, d.confidence, 68, d.detail); }
    { std::vector<uint8_t> f = mgmt(0x8, MAC_PUBLIC, MAC_PUBLIC);
      f.push_back(0x00); f.push_back(200); f.push_back('F'); f.push_back('l');
      chk("same overrun on a neutral MAC -> no hit", runWiFi(f, &d), false); }
    // A data frame (ftype 2) is rejected before any parsing, even from a Flock OUI.
    { std::vector<uint8_t> f = mgmt(0x8, MAC_FLOCK, MAC_FLOCK); f[0] = 0x08;
      chk("data frame from b4:1e:52 -> no hit", runWiFi(f, &d), false); }
    // Subtypes other than 4/5/8 are skipped outright rather than walked at the wrong offset, so an
    // SSID smuggled into an association request is never parsed.
    { std::vector<uint8_t> f = mgmt(0x0, MAC_PUBLIC, MAC_PUBLIC);
      f.push_back(0x11); f.push_back(0x04); f.push_back(0x0a); f.push_back(0x00);  // assoc-req body
      addSSID(f, "Flock-a1b2c3");
      chk("assoc-request carrying 'Flock-...' -> no hit", runWiFi(f, &d), false); }
    // The offset split itself: the same bytes that match as a probe request must NOT match when
    // the frame says beacon, because a beacon's IEs start 12 bytes later.
    { std::vector<uint8_t> f = mgmt(0x4, MAC_PUBLIC, MAC_PUBLIC); addSSID(f, "Flock-a1b2c3");
      f[0] = (uint8_t)(0x8 << 4);
      chk("probe-req bytes relabelled beacon -> no hit", runWiFi(f, &d), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
