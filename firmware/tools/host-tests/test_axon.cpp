// Host regression test for the body-cam classifier (axon_detect.cpp), covering BOTH entry points:
// axonClassifyBLE and the newer axonClassifyWiFi.
//
// WHY THIS EXISTS: the three detail strings this file emits ("Axon OUI", "BWC DEVICE",
// "Utility BodyWorn") are a WIRE CONTRACT. Both apps resolve the body-cam vendor by EXACT string
// match, so any edit to one of them (a suffix, a case change, a space) silently degrades the
// detail screen instead of failing a build. That contract broke once already when a " on wifi"
// suffix was added to the WiFi path, so every assertion below compares the string VERBATIM rather
// than checking "contains Axon". The confidence tiers (90 tag / 85 name / 75 BLE OUI / 70 Utility
// OUI / 65 WiFi) are consumed downstream too, for alert thresholds and sort order, so they are
// asserted as exact numbers.
//
// These tests lock in what the code does TODAY. Where behaviour looked questionable it is still
// asserted as-is and flagged with a CONCERN comment, never "corrected" here.
#include "axon_detect.h"
#include "axon_signatures.h"
#include <Preferences.h>   // wipeAll(): the stub stores for real now, so "no saved value" must be made true
#include <cstdio>
#include <cstring>
#include <vector>

// ---- stubs for the two symbols axon_detect.cpp calls into other translation units ----------
// Desert mode lives in desert_detect.cpp, which the harness never compiles. It is a real branch
// here (`if (!gEnabled && !desertIsEnabled()) return false;`), so unlike the glasses test this is
// a settable flag, not a hard false: the "off but Desert forces it on" case is tested below.
static bool gDesertOn = false;
bool desertIsEnabled() { return gDesertOn; }

// Copied byte-for-byte from acabSanitizeAscii in acab_scanner.cpp. It has to be a faithful copy,
// not a memcpy: the parser runs advertised names through it BEFORE matching, so a lazy stub would
// make the "control byte in the name breaks the Utility match" test pass for the wrong reason.
// If the real one ever changes, this copy is the thing to resync.
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
// Scalar assert, same output shape. Used for method / source / MAC-byte / table-size checks.
static void chkInt(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}

// ---- advert builders (BLE AD structures: [len][type][data...]) -----------------------------
static void addName(std::vector<uint8_t>& a, const char* s, uint8_t adType = 0x09) {
    size_t n = strlen(s);
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (size_t i = 0; i < n; i++) a.push_back((uint8_t)s[i]);
}
static void addNameRaw(std::vector<uint8_t>& a, const uint8_t* b, size_t n) {
    a.push_back((uint8_t)(1 + n)); a.push_back(0x09);
    for (size_t i = 0; i < n; i++) a.push_back(b[i]);
}
static void addMfg(std::vector<uint8_t>& a, uint16_t cid, const uint8_t* tail = nullptr, size_t tl = 0) {
    a.push_back((uint8_t)(1 + 2 + tl)); a.push_back(0xFF);
    a.push_back(cid & 0xFF); a.push_back(cid >> 8);
    for (size_t i = 0; i < tl; i++) a.push_back(tail[i]);
}
static void addMfgStr(std::vector<uint8_t>& a, uint16_t cid, const char* tail) {
    addMfg(a, cid, (const uint8_t*)tail, strlen(tail));
}
// Service data / 128-bit UUID AD. adType 0x21 is where the real 2026-06 field capture carried the
// tag; 0x16 / 0x07 are the other types parseAdv folds into the same svc buffer.
static void addSvcStr(std::vector<uint8_t>& a, uint8_t adType, const char* s) {
    size_t n = strlen(s);
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (size_t i = 0; i < n; i++) a.push_back((uint8_t)s[i]);
}
static void addSvcFill(std::vector<uint8_t>& a, uint8_t adType, uint8_t byte, uint8_t n) {
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (uint8_t i = 0; i < n; i++) a.push_back(byte);
}

// MACs. Every OUI in both tables starts with 0x00, so all of these are public addresses except
// MAC_RANDOM, whose locally-administered bit is set.
static const uint8_t MAC_AXON[6]      = {0x00,0x25,0xdf,0x11,0x22,0x33};   // Axon Enterprise
static const uint8_t MAC_AXON_LO[6]   = {0x00,0x25,0xde,0x11,0x22,0x33};   // neighbouring block
static const uint8_t MAC_AXON_HI[6]   = {0x00,0x25,0xe0,0x11,0x22,0x33};   // neighbouring block
static const uint8_t MAC_UTIL_A[6]    = {0x00,0x09,0xbc,0x0a,0x0b,0x0c};   // Utility Inc.
static const uint8_t MAC_UTIL_B[6]    = {0x00,0x16,0xed,0x0a,0x0b,0x0c};   // Utility Inc.
static const uint8_t MAC_UTIL_NEAR[6] = {0x00,0x16,0xee,0x0a,0x0b,0x0c};   // one byte off Utility
static const uint8_t MAC_RANDOM[6]    = {0x7a,0x11,0x22,0x33,0x44,0x55};   // BLE private address
static const uint8_t MAC_PHONE[6]     = {0x3c,0x2e,0xf9,0x01,0x02,0x03};   // in no table at all

// run() is split out from the chk() call on purpose: C++ leaves function-argument evaluation order
// unspecified, so passing run(...) and d.confidence as siblings would read the confidence of the
// PREVIOUS detection on a compiler that evaluates right to left. Call first, assert second.
static AcabDetection d;
static bool runBLE(const uint8_t mac[6], std::vector<uint8_t>& a) {
    memset(&d, 0, sizeof(d));
    return axonClassifyBLE(mac, a.data(), a.size(), -71, &d);
}
// 802.11 management frame: [fc0][fc1][dur x2][addr1 x6][addr2 x6][addr3 x6] = 24 bytes.
// fc0 0x80 is a beacon (type bits 00 = management), which is what the classifier accepts.
static std::vector<uint8_t> mgmtFrame(const uint8_t* addr2, const uint8_t* addr3, uint8_t fc0 = 0x80) {
    std::vector<uint8_t> f(24, 0x00);
    f[0] = fc0;
    memcpy(&f[10], addr2, 6);
    memcpy(&f[16], addr3, 6);
    return f;
}
static bool runWiFi(std::vector<uint8_t>& f) {
    memset(&d, 0, sizeof(d));
    return axonClassifyWiFi(f.data(), f.size(), -63, &d);
}

// Custom signatures, to reach the match sources the shipped registry candidate leaves unused.
static const AxonSignature SIG_MFG = {
    /* useMfgId      */ true,  /* mfgId */ 0x1234,
    /* useMfgPrefix  */ true,  /* mfgPrefix */ {0xAA,0xBB}, /* mfgPrefixLen */ 2,
    /* useOui        */ false, /* oui */ {{0}}, /* ouiCount */ 0,
    /* useName       */ false, /* namePatterns */ {nullptr,nullptr,nullptr,nullptr}, /* nameCount */ 0,
    /* usePayload    */ false, /* payload */ nullptr,
    /* baseConfidence*/ 55,
};
static const AxonSignature SIG_NAME = {
    /* useMfgId      */ false, /* mfgId */ 0x0000,
    /* useMfgPrefix  */ false, /* mfgPrefix */ {0}, /* mfgPrefixLen */ 0,
    /* useOui        */ false, /* oui */ {{0}}, /* ouiCount */ 0,
    /* useName       */ true,  /* namePatterns */ {"AB4",nullptr,nullptr,nullptr}, /* nameCount */ 1,
    /* usePayload    */ false, /* payload */ nullptr,
    /* baseConfidence*/ 60,
};
static const AxonSignature SIG_STRICT = {   // the "tightenable" mode the header advertises
    /* useMfgId      */ false, /* mfgId */ 0x0000,
    /* useMfgPrefix  */ false, /* mfgPrefix */ {0}, /* mfgPrefixLen */ 0,
    /* useOui        */ true,  /* oui */ {{0x00,0x25,0xdf}}, /* ouiCount */ 1,
    /* useName       */ false, /* namePatterns */ {nullptr,nullptr,nullptr,nullptr}, /* nameCount */ 0,
    /* usePayload    */ true,  /* payload */ AXON_BWC_PAYLOAD,
    /* baseConfidence*/ 75,
};
static const AxonSignature SIG_HICONF = {   // baseConfidence above the tag floor of 90
    /* useMfgId      */ false, /* mfgId */ 0x0000,
    /* useMfgPrefix  */ false, /* mfgPrefix */ {0}, /* mfgPrefixLen */ 0,
    /* useOui        */ true,  /* oui */ {{0x00,0x25,0xdf}}, /* ouiCount */ 1,
    /* useName       */ false, /* namePatterns */ {nullptr,nullptr,nullptr,nullptr}, /* nameCount */ 0,
    /* usePayload    */ false, /* payload */ nullptr,
    /* baseConfidence*/ 95,
};

int main() {
    printf("\n=== body-cam classifier regression (axon_detect) ===\n");

    // -- defaults, BEFORE any signature is loaded ------------------------------------------
    // The module ships ENABLED (field-validated 2026-06-17) but with the INERT placeholder
    // signature. Both halves matter: firmware that calls axonSetEnabled(true) and forgets
    // axonUseRegistryCandidate() detects nothing by OUI and looks fine on the bench.
    printf("\n-- defaults (placeholder signature) --\n");
    chkInt("enabled by default", axonIsEnabled() ? 1 : 0, 1);
    { std::vector<uint8_t> a;
      chk("placeholder: Axon OUI alone -> NO hit", runBLE(MAC_AXON, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_PHONE, a);
      chk("placeholder: BWCDEVICE tag still hits (standalone)", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_PHONE, a);
      chk("placeholder: Utility name still hits (own path)", h, true, d.confidence, 85, d.detail, "Utility BodyWorn"); }
    // Lock the signature tables themselves. A silent edit here changes what ships.
    chkInt("Utility OUI table still has 2 blocks", (long)UTIL_BWC_OUI_COUNT, 2);
    chkInt("UTIL_BWC_OUI[0] is 00:09:bc", (UTIL_BWC_OUI[0][0]<<16)|(UTIL_BWC_OUI[0][1]<<8)|UTIL_BWC_OUI[0][2], 0x0009bc);
    chkInt("UTIL_BWC_OUI[1] is 00:16:ed", (UTIL_BWC_OUI[1][0]<<16)|(UTIL_BWC_OUI[1][1]<<8)|UTIL_BWC_OUI[1][2], 0x0016ed);
    chkInt("tag constant is exactly \"BWCDEVICE\"", strcmp(AXON_BWC_PAYLOAD, "BWCDEVICE"), 0);

    // -- BLE: the shipped registry candidate (OUI 00:25:DF) ---------------------------------
    printf("\n-- BLE: Axon OUI 00:25:df --\n");
    axonUseRegistryCandidate();
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_AXON, a);
      chk("OUI hit, empty advert (OUI needs no payload)", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ method is M_OUI", d.method, M_OUI);
      chkInt("  ^ source is SRC_BLE", d.src, SRC_BLE);
      chkInt("  ^ type is ACAB_AXON_BODYCAM", d.type, ACAB_AXON_BODYCAM);
      chkInt("  ^ rssi passed through", d.rssi, -71); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI 00:25:de -> NO hit", runBLE(MAC_AXON_LO, a), false); }
    { std::vector<uint8_t> a;
      chk("neighbour OUI 00:25:e0 -> NO hit", runBLE(MAC_AXON_HI, a), false); }
    { std::vector<uint8_t> a; addName(a, "AXON BODY 3");
      // CONCERN (asserted as-is): the advertised name is NOT a match source in the shipped
      // signature, so an Axon-branded name on a foreign MAC is invisible. Deliberate: names are
      // spoofable and the OUI is the field-validated signal.
      chk("\"AXON BODY 3\" name on a foreign MAC -> NO hit", runBLE(MAC_PHONE, a), false); }

    // -- BLE: the BWCDEVICE service-data tag -------------------------------------------------
    printf("\n-- BLE: BWCDEVICE service-data tag --\n");
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_AXON, a);
      chk("tag in AD 0x21 -> \"BWC DEVICE\" at 90", h, true, d.confidence, 90, d.detail, "BWC DEVICE");
      chkInt("  ^ method is M_SERVICE_DATA, not M_OUI", d.method, M_SERVICE_DATA); }
    // The real capture: the tag rode inside a little-endian 128-bit UUID, so it only reads
    // "AXJANUSBWCDEVICE" when the bytes are reversed. This is the exact shape seen in the field.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "ECIVEDCWBSUNAJXA");
      bool h = runBLE(MAC_AXON, a);
      chk("tag reversed (little-endian UUID) -> hit", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x16, "xxBWCDEVICExx");
      chk("tag in 16-bit service data (AD 0x16)", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x07, "bwcdevice");
      chk("tag match is case-insensitive", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    // The tag survives MAC randomization, which is the whole reason it is a standalone match.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      bool h = runBLE(MAC_RANDOM, a);
      chk("tag on a RANDOM MAC -> still hits at 90", h, true, d.confidence, 90, d.detail, "BWC DEVICE");
      chkInt("  ^ randomAddr flagged", d.randomAddr ? 1 : 0, 1);
      AcabDetection dd = d; acabApplyDurability(&dd);
      chkInt("  ^ durability leaves 90 (not an OUI match)", dd.confidence, 90); }
    // Tag beats OUI when both are present: highest-confidence, MAC-independent evidence wins.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE"); addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_AXON, a);
      chk("tag + OUI + Utility name -> tag wins", h, true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    // Near-misses on the tag. Note the emitted detail has a space ("BWC DEVICE") but the matched
    // constant does NOT ("BWCDEVICE"); a spaced payload must not match.
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWC DEVICE");
      chk("\"BWC DEVICE\" (spaced) in svc data -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVIC");
      chk("truncated \"BWCDEVIC\" -> NO hit", runBLE(MAC_PHONE, a), false); }
    // Only 0x06/0x07/0x16/0x20/0x21 are folded into the svc buffer. The tag inside manufacturer
    // data is NOT a service-data tag and must not match.
    { std::vector<uint8_t> a; addMfgStr(a, 0x004C, "BWCDEVICE");
      chk("tag inside mfg data (AD 0xFF) -> NO hit", runBLE(MAC_PHONE, a), false); }

    // -- BLE: Utility Inc. "BodyWorn" -------------------------------------------------------
    printf("\n-- BLE: Utility BodyWorn --\n");
    { std::vector<uint8_t> a; addName(a, "BodyWorn Remote");
      bool h = runBLE(MAC_PHONE, a);
      chk("name \"BodyWorn Remote\" -> 85, M_NAME", h, true, d.confidence, 85, d.detail, "Utility BodyWorn");
      chkInt("  ^ method is M_NAME", d.method, M_NAME);
      chkInt("  ^ advertised name copied out", strcmp(d.name, "BodyWorn Remote"), 0); }
    { std::vector<uint8_t> a; addName(a, "unit 4 bodyworn remote", 0x08);
      chk("name match is case-insensitive + substring", runBLE(MAC_PHONE, a), true, d.confidence, 85, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> a; addName(a, "BodyWorn");
      chk("\"BodyWorn\" alone (no \" Remote\") -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_UTIL_A, a);
      chk("Utility OUI 00:09:bc -> 70, weaker than name", h, true, d.confidence, 70, d.detail, "Utility BodyWorn");
      chkInt("  ^ method is M_OUI", d.method, M_OUI); }
    { std::vector<uint8_t> a;
      chk("Utility OUI 00:16:ed -> 70", runBLE(MAC_UTIL_B, a), true, d.confidence, 70, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> a;
      chk("near-miss OUI 00:16:ee -> NO hit", runBLE(MAC_UTIL_NEAR, a), false); }
    // Axon is checked before Utility, so a device matching both is attributed to Axon.
    { std::vector<uint8_t> a; addName(a, UTIL_BWC_NAME);
      bool h = runBLE(MAC_AXON, a);
      chk("Axon OUI + Utility name -> \"Axon OUI\" wins", h, true, d.confidence, 75, d.detail, "Axon OUI"); }
    // Names are sanitized to printable ASCII on ingest, BEFORE matching. A control byte inside the
    // name therefore breaks the match rather than smuggling raw bytes into the detection JSON.
    { std::vector<uint8_t> a;
      const uint8_t raw[] = {'B','o','d','y',0x01,'W','o','r','n',' ','R','e','m','o','t','e'};
      addNameRaw(a, raw, sizeof(raw));
      chk("control byte inside the name -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a;
      const uint8_t raw[] = {'A',0x01,'B'};
      addNameRaw(a, raw, sizeof(raw));
      bool h = runBLE(MAC_AXON, a);
      chk("name sanitized to \"A.B\" on an Axon OUI hit", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ out->name is \"A.B\"", strcmp(d.name, "A.B"), 0); }
    // Only the FIRST name AD is parsed, so a decoy name in front of the real one suppresses the
    // match. Locked in as-is: first-wins is what keeps a crafted advert from stacking claims.
    { std::vector<uint8_t> a; addName(a, "decoy"); addName(a, UTIL_BWC_NAME);
      chk("second name AD ignored (first wins)", runBLE(MAC_PHONE, a), false); }

    // -- the enable toggle + Desert override -------------------------------------------------
    printf("\n-- toggle + Desert override --\n");
    axonSetEnabled(false);
    chkInt("axonIsEnabled() false after setEnabled(false)", axonIsEnabled() ? 1 : 0, 0);
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      chk("disabled: even a tagged Axon -> NO hit", runBLE(MAC_AXON, a), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      chk("disabled: WiFi path is off too", runWiFi(f), false); }
    gDesertOn = true;
    { std::vector<uint8_t> a;
      bool h = runBLE(MAC_AXON, a);
      chk("disabled + Desert on -> classifies anyway", h, true, d.confidence, 75, d.detail, "Axon OUI"); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      chk("disabled + Desert on -> WiFi classifies too", runWiFi(f), true, d.confidence, 65, d.detail, "Axon OUI"); }
    gDesertOn = false;
    { std::vector<uint8_t> a;
      chk("Desert back off -> silent again", runBLE(MAC_AXON, a), false); }
    // NVS restore, i.e. what setup() does after a power cycle. Preferences::wipeAll() is what
    // MAKES "no saved value" true, and it has to be explicit: the host stub used to discard every
    // write, so this block asserted the default branch by accident rather than by construction.
    // Now that the stub really stores, the axonSetEnabled(false) calls above genuinely persist and
    // a restore reads THAT back instead of the default the case name promises.
    Preferences::wipeAll();
    axonRestoreEnabled(true);
    chkInt("restoreEnabled(true) with no saved value -> on", axonIsEnabled() ? 1 : 0, 1);
    Preferences::wipeAll();
    axonRestoreEnabled(false);
    chkInt("restoreEnabled(false) with no saved value -> off", axonIsEnabled() ? 1 : 0, 0);
    // The other branch, which nothing could observe before: a PERSISTED value beats the
    // compiled-in default. That is the property a deployed board depends on across a brownout,
    // and until the stub stored anything it was untested on every detector in the tree.
    // NOTE the toggle-through: axonSetEnabled early-returns when the value is unchanged, so
    // calling it with the value the flag ALREADY holds writes nothing. After a wipeAll the in-RAM
    // state and NVS have diverged, and only a real transition re-syncs them. Getting this wrong is
    // how the first draft of these two cases asserted the opposite of the truth.
    axonSetEnabled(true); axonSetEnabled(false);          // ends false, and false is now SAVED
    axonRestoreEnabled(true);
    chkInt("restoreEnabled(true) with false SAVED -> stays off", axonIsEnabled() ? 1 : 0, 0);
    axonSetEnabled(true);                                 // transition, so true is SAVED
    axonRestoreEnabled(false);
    chkInt("restoreEnabled(false) with true SAVED -> stays on", axonIsEnabled() ? 1 : 0, 1);
    // Re-enable EXPLICITLY for the signature cases below. This used to be a bare
    // axonRestoreEnabled(true), which only produced "enabled" because writes vanished; with real
    // storage it reads back whatever was last persisted and silently disables every case after
    // it, which is how 22 assertions failed at once the first time the stub was fixed.
    axonSetEnabled(true);

    // -- swappable signatures (the other match sources) --------------------------------------
    printf("\n-- swappable signature fields --\n");
    axonLoadSignature(&SIG_MFG);
    { std::vector<uint8_t> a; const uint8_t tail[] = {0xAA,0xBB,0xCC}; addMfg(a, 0x1234, tail, 3);
      bool h = runBLE(MAC_PHONE, a);
      // CONCERN (asserted as-is): a manufacturer-ID match still reports the detail string
      // "Axon OUI" even though no OUI was involved. It is the wire-contract value the apps know,
      // so it must not be "fixed" without changing both apps.
      chk("mfg id + prefix -> 55, detail still \"Axon OUI\"", h, true, d.confidence, 55, d.detail, "Axon OUI");
      chkInt("  ^ method is M_MFG_ID", d.method, M_MFG_ID);
      chkInt("  ^ companyId not stamped by this detector", d.companyId, 0); }
    { std::vector<uint8_t> a; const uint8_t tail[] = {0xAA,0xCC}; addMfg(a, 0x1234, tail, 2);
      chk("right mfg id, wrong prefix -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; const uint8_t tail[] = {0xAA,0xBB}; addMfg(a, 0x1235, tail, 2);
      chk("neighbouring company id 0x1235 -> NO hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addMfg(a, 0x1234);
      chk("right mfg id, prefix truncated away -> NO hit", runBLE(MAC_PHONE, a), false); }
    axonLoadSignature(&SIG_NAME);
    { std::vector<uint8_t> a; addName(a, "AXON ab4 cam");
      bool h = runBLE(MAC_PHONE, a);
      chk("name pattern \"AB4\" -> 60, detail \"Axon OUI\"", h, true, d.confidence, 60, d.detail, "Axon OUI");
      chkInt("  ^ method is M_NAME", d.method, M_NAME); }
    { std::vector<uint8_t> a; addName(a, "AXON AB3 cam");
      chk("near-miss name \"AB3\" -> NO hit", runBLE(MAC_PHONE, a), false); }
    axonLoadSignature(&SIG_STRICT);
    { std::vector<uint8_t> a;
      chk("usePayload: Axon OUI without the tag -> NO hit", runBLE(MAC_AXON, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      chk("usePayload: Axon OUI WITH the tag -> hit", runBLE(MAC_AXON, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    axonLoadSignature(&SIG_HICONF);
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE");
      // 90 is a FLOOR for the tag, not a fixed value: a signature already above it keeps its own.
      chk("baseConfidence 95 + tag -> keeps 95, not 90", runBLE(MAC_AXON, a), true, d.confidence, 95, d.detail, "BWC DEVICE"); }
    axonLoadSignature(nullptr);
    { std::vector<uint8_t> a;
      chk("loadSignature(nullptr) resets to placeholder", runBLE(MAC_AXON, a), false); }

    // -- WiFi entry point --------------------------------------------------------------------
    printf("\n-- WiFi (802.11 management frames) --\n");
    axonUseRegistryCandidate();
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      bool h = runWiFi(f);
      // 65, NOT the BLE tier's 75: the OUI read is as reliable, but the type claim is weaker and
      // has never been confirmed by a capture in this repo.
      chk("Axon OUI in addr2 -> 65, \"Axon OUI\"", h, true, d.confidence, 65, d.detail, "Axon OUI");
      chkInt("  ^ source is SRC_WIFI", d.src, SRC_WIFI);
      chkInt("  ^ method is M_OUI", d.method, M_OUI);
      chkInt("  ^ reports the transmitter MAC", memcmp(d.mac, MAC_AXON, 6), 0); }
    // THE REGRESSION THIS FILE EXISTS FOR: a " on wifi" suffix was once appended here, which the
    // apps could not match, so the vendor silently vanished from the detail screen. Exact string.
    chkInt("no \" on wifi\" suffix on the WiFi detail", strcmp(d.detail, "Axon OUI"), 0);
    { std::vector<uint8_t> f = mgmtFrame(MAC_PHONE, MAC_AXON);
      bool h = runWiFi(f);
      chk("Axon OUI in addr3 (BSSID) -> hit", h, true, d.confidence, 65, d.detail, "Axon OUI");
      chkInt("  ^ reports the BSSID it matched", memcmp(d.mac, MAC_AXON, 6), 0); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_UTIL_A, MAC_PHONE);
      bool h = runWiFi(f);
      // Attributing Utility hardware to a competitor in the string the user reads was a real bug.
      chk("Utility OUI on WiFi -> \"Utility BodyWorn\"", h, true, d.confidence, 65, d.detail, "Utility BodyWorn"); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_UTIL_B, MAC_AXON);
      bool h = runWiFi(f);
      chk("addr2 Utility beats addr3 Axon (addr2 first)", h, true, d.confidence, 65, d.detail, "Utility BodyWorn");
      chkInt("  ^ reports addr2, not the BSSID", memcmp(d.mac, MAC_UTIL_B, 6), 0); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON_HI, MAC_UTIL_NEAR);
      chk("near-miss OUIs in both address fields -> none", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE, 0x08);   // data frame
      chk("data frame (type 10) -> rejected, mgmt only", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE, 0xB4);   // control frame (RTS)
      chk("control frame (type 01) -> rejected", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE); f.resize(23);
      chk("23-byte runt frame -> rejected before addr2", runWiFi(f), false); }
    { std::vector<uint8_t> f;
      chk("zero-length frame -> no hit", runWiFi(f), false); }
    chkInt("null frame pointer -> no hit", axonClassifyWiFi(nullptr, 64, -50, &d) ? 1 : 0, 0);
    // Asymmetry worth knowing: on WiFi the Axon table is gated on the loaded signature, but the
    // Utility table is checked unconditionally. Placeholder loaded = Axon invisible, Utility not.
    axonLoadSignature(nullptr);
    { std::vector<uint8_t> f = mgmtFrame(MAC_AXON, MAC_PHONE);
      chk("placeholder: Axon OUI on WiFi -> NO hit", runWiFi(f), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_UTIL_A, MAC_PHONE);
      chk("placeholder: Utility OUI on WiFi -> still hits", runWiFi(f), true, d.confidence, 65, d.detail, "Utility BodyWorn"); }
    axonUseRegistryCandidate();

    // -- adversarial adverts -------------------------------------------------------------------
    printf("\n-- adversarial adverts --\n");
    { std::vector<uint8_t> a;
      chk("empty advert on an unknown MAC -> no hit", runBLE(MAC_PHONE, a), false); }
    chkInt("null advert pointer -> no hit", axonClassifyBLE(MAC_PHONE, nullptr, 0, -60, &d) ? 1 : 0, 0);
    { // length field claims 200 bytes in a 12-byte buffer: the parser must bail, not walk off it.
      std::vector<uint8_t> a; a.push_back(200); a.push_back(0x21);
      const char* s = "BWCDEVICE"; for (int i = 0; i < 9; i++) a.push_back((uint8_t)s[i]);
      chk("length overruns buffer -> parse bails, no hit", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; a.push_back(0); a.push_back(0x21); addSvcStr(a, 0x21, "BWCDEVICE");
      chk("zero-length AD stops the walk (tag after it)", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; a.push_back(4);   // dangling length byte, no type, no data
      chk("truncated AD header (length byte only)", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcStr(a, 0x21, "BWCDEVICE"); a.push_back(9);
      chk("valid tag then a dangling length byte", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { std::vector<uint8_t> a; a.push_back(1); a.push_back(0xFF);   // mfg AD with 0 data bytes
      chk("mfg AD too short for a company id -> ignored", runBLE(MAC_PHONE, a), false); }
    { // The svc buffer is 48 bytes; anything past it is dropped, so a late tag is missed. Harmless
      // in practice (a legacy advert is 31 bytes total) but this is the documented edge.
      std::vector<uint8_t> a; addSvcFill(a, 0x16, 'Z', 47); addSvcStr(a, 0x16, "BWCDEVICE");
      chk("tag pushed past the 48-byte svc buffer -> lost", runBLE(MAC_PHONE, a), false); }
    { std::vector<uint8_t> a; addSvcFill(a, 0x16, 'Z', 30); addSvcStr(a, 0x16, "BWCDEVICE");
      chk("tag still inside the 48-byte svc buffer -> hit", runBLE(MAC_PHONE, a), true, d.confidence, 90, d.detail, "BWC DEVICE"); }
    { // Oversized name: sanitize clamps to the 40-byte field instead of overflowing it.
      std::vector<uint8_t> a; std::vector<uint8_t> raw(60, 'A');
      addNameRaw(a, raw.data(), raw.size());
      bool h = runBLE(MAC_AXON, a);
      chk("60-byte name on an Axon OUI hit", h, true, d.confidence, 75, d.detail, "Axon OUI");
      chkInt("  ^ name clamped to 39 chars", (long)strlen(d.name), 39); }
    { std::vector<uint8_t> a; addMfgStr(a, 0x004C, "iPhone");
      chk("ordinary Apple advert -> no hit", runBLE(MAC_PHONE, a), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
