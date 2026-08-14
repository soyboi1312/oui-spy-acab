// Host regression test for the Motorola Solutions vendor proxy (police_detect.cpp).
//
// WHY THIS FILE EXISTS: this is the broadest, least-earned match on the board. It flags a whole
// corporate OUI block, and the 2026-07-23 airport ground truth found ALL 27 of its WiFi hits were
// fixed infrastructure, not body cams. What keeps it honest is not the OUI table, it is three
// things that a refactor can silently undo because none of them break the build:
//   1. it is OFF by default and needs BOTH its own sub-toggle and the body-cam category,
//   2. it emits confidence 45, deliberately under the apps' 50 weak-match threshold, so both
//      apps draw the amber "verify this" treatment instead of a calm partial match,
//   3. the detail string says "Motorola Solutions OUI" and nothing stronger.
// Flip any one of those and the product starts telling users a school radio is a body camera.
// The compiler will not notice. These assertions will.
//
// Everything here locks in CURRENT behaviour, including two things worth a second look. Both are
// flagged CONCERN below and both are asserted as-is, not as I think they should be.
#include "police_detect.h"
#include <Preferences.h>   // wipeAll(): the stub stores for real now
#include "police_signatures.h"
#include "axon_detect.h"     // for the axonIsEnabled() declaration this file has to satisfy
#include "desert_detect.h"   // ditto desertIsEnabled()
#include "detection.h"
#include <cstdio>
#include <cstring>
#include <vector>

// ---- the two translation units police_detect.cpp reaches into ----
// run.sh links exactly ONE source file, so the category gate (axon) and the Desert override have
// to be defined here. Making them plain test-driven flags is also what makes the gate matrix
// testable at all. The headers are included above on purpose: if either real signature ever
// changes, this file stops compiling instead of quietly binding to a stale one.
static bool gAxonOn   = true;
static bool gDesertOn = false;
bool axonIsEnabled()          { return gAxonOn; }
void axonSetEnabled(bool e)   { gAxonOn = e; }
bool desertIsEnabled(void)    { return gDesertOn; }
void desertSetEnabled(bool e) { gDesertOn = e; }

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
// Same reporting shape for the scalar fields of the emitted record (type / method / source /
// rssi / toggle state), which downstream code reads just as hard as the confidence does.
static void chkVal(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}

// ---- fixtures ----
// A real Motorola Solutions OUI (4C:CC:34, the one field-observed on 2.4 GHz WiFi) plus an
// arbitrary fixed tail. Nothing here is random or clock-derived: every byte is literal.
static const uint8_t MAC_MOTO[6]     = { 0x4c, 0xcc, 0x34, 0x11, 0x22, 0x33 };
static const uint8_t MAC_MOTO_ALT[6] = { 0x4c, 0xcc, 0x34, 0xaa, 0xbb, 0xcc };   // same OUI, other tail
static const uint8_t MAC_MALAY[6]    = { 0x10, 0x74, 0x6f, 0x01, 0x02, 0x03 };   // Malaysia entity
static const uint8_t MAC_OTHER[6]    = { 0x3c, 0x5a, 0xb4, 0x01, 0x02, 0x03 };   // unrelated vendor
static const uint8_t MAC_AXON[6]     = { 0x00, 0x25, 0xdf, 0x01, 0x02, 0x03 };   // Axon's own OUI

static AcabDetection d;
static bool runBle(const uint8_t mac[6], const uint8_t* adv = nullptr, size_t advLen = 0, int rssi = -70) {
    memset(&d, 0, sizeof(d));
    return policeClassifyBLE(mac, adv, advLen, rssi, &d);
}
static bool runWifi(const uint8_t* frame, size_t len, int rssi = -70) {
    memset(&d, 0, sizeof(d));
    return policeClassifyWiFi(frame, len, rssi, &d);
}
// 802.11 header: [0]=frame control, [4..9]=addr1 dest, [10..15]=addr2 transmitter,
// [16..21]=addr3 BSSID, [22..23]=seq. fc0 0x80 is a beacon (type 0 management, subtype 8).
static std::vector<uint8_t> mgmtFrame(const uint8_t* a2, const uint8_t* a3, uint8_t fc0 = 0x80) {
    std::vector<uint8_t> f(24, 0);
    f[0] = fc0;
    memset(&f[4], 0xff, 6);
    memcpy(&f[10], a2, 6);
    memcpy(&f[16], a3, 6);
    return f;
}
static void setGates(bool sub, bool category, bool desert) {
    policeSetEnabled(sub); gAxonOn = category; gDesertOn = desert;
}

int main() {
    printf("\n=== Motorola vendor-proxy classifier regression ===\n");

    // ---------------------------------------------------------------------------------------
    // 1. THE DEFAULT. This must be the very first thing asserted, before anything calls a
    // setter, because the module-scope default is the whole point: after the airport ground
    // truth the detector was demoted to opt-in on every board. A future "restore the old
    // default" edit is a one-word diff with a real-world cost.
    // ---------------------------------------------------------------------------------------
    chkVal("module default: OFF before any setter runs", policeIsEnabled() ? 1 : 0, 0);
    gAxonOn = true; gDesertOn = false;
    chk("default OFF + category ON -> no hit", runBle(MAC_MOTO), false);

    // Both switches are required. This is a SUB-toggle, not a peer: quieting this broad match
    // must not be the same lever as killing the whole body-cam category (before the split it
    // was, which also silenced the conf-90 Axon signature, the best one on the board).
    setGates(true, false, false);
    chk("sub-toggle ON + category OFF -> no hit", runBle(MAC_MOTO), false);
    setGates(false, true, false);
    chk("sub-toggle OFF + category ON -> no hit", runBle(MAC_MOTO), false);
    setGates(true, true, false);
    { bool got = runBle(MAC_MOTO);
      chk("sub-toggle ON + category ON -> hit", got, true, d.confidence, 45, d.detail); }
    setGates(false, true, false);
    chk("toggled back OFF -> stops matching again", runBle(MAC_MOTO), false);

    // Preferences::wipeAll() is what MAKES "nothing saved" true, and it has to be explicit. The
    // host stub used to discard every write, so this exercised the default-value branch by
    // accident; with real storage the toggles above persist. That branch still matters - it is
    // what decides how a freshly-flashed board behaves - so keep testing it, just on purpose.
    // Per-board defaults live in main.cpp; the module honours them.
    Preferences::wipeAll();
    policeRestoreEnabled(true);
    chkVal("restore(true), nothing saved -> enabled", policeIsEnabled() ? 1 : 0, 1);
    policeRestoreEnabled(false);
    chkVal("restore(false), nothing saved -> disabled", policeIsEnabled() ? 1 : 0, 0);
    chk("after restore(false) -> no hit", runBle(MAC_MOTO), false);

    // CONCERN (locked in as-is, not a bug report): Desert mode forces this on even when the
    // user has explicitly opted OUT of the broad match. Every detector behaves this way, so it
    // is consistent, but it is the one detector where the ground truth says most hits are not
    // what the label claims, and the label it emits is "Body camera", not "Nearby device".
    setGates(false, false, true);
    { bool got = runBle(MAC_MOTO);
      chk("both toggles OFF + Desert ON -> forced hit", got, true, d.confidence, 45, d.detail); }
    gDesertOn = false;

    // ---------------------------------------------------------------------------------------
    // 2. THE EMITTED RECORD. Every field below is consumed downstream (both apps, the mesh
    // line, the offline buffer), so each one is pinned exactly rather than eyeballed.
    // ---------------------------------------------------------------------------------------
    setGates(true, true, false);
    { bool got = runBle(MAC_MOTO, nullptr, 0, -70);
      chk("BLE detail string is exact", got, true, d.confidence, 45, d.detail,
          "Motorola Solutions OUI"); }
    chkVal("confidence is exactly 45", d.confidence, 45);
    chkVal("confidence stays under the 50 weak-match line", d.confidence < 50 ? 1 : 0, 1);
    chkVal("type is ACAB_AXON_BODYCAM (3), not retired 6", (long)d.type, (long)ACAB_AXON_BODYCAM);
    chkVal("renders as \"Body camera\"", strcmp(acabTypeLabel(d.type), "Body camera"), 0);
    chkVal("method is M_OUI", (long)d.method, (long)M_OUI);
    chkVal("source is SRC_BLE", (long)d.src, (long)SRC_BLE);
    chkVal("rssi is passed through", (long)d.rssi, -70);
    chkVal("mac is copied into the detection", memcmp(d.mac, MAC_MOTO, 6), 0);
    chkVal("randomAddr false (public OUI, no conf down-cap)", d.randomAddr ? 1 : 0, 0);
    // The BLE path never reads the advert, so companyId is left at 0. If someone later adds
    // payload parsing here, this is the assertion that says "you changed the contract".
    chkVal("companyId left 0 (payload never parsed)", (long)d.companyId, 0);
    // WORDING RULE: nothing user-facing may carry the p-word. The detail goes on the wire to
    // both apps, so this string is the one most likely to leak it back in.
    chkVal("detail carries no p-word", strstr(d.detail, "olice") == nullptr ? 1 : 0, 1);
    chkVal("detail carries no p-word (capitalised)", strstr(d.detail, "Police") == nullptr ? 1 : 0, 1);

    // ---------------------------------------------------------------------------------------
    // 3. EVERY OUI IN THE TABLE. There is one signature class here (a corporate OUI prefix),
    // so the positive-match coverage is "each of the seven blocks still resolves". A typo in
    // one row of police_signatures.h compiles perfectly and just stops seeing that product line.
    // ---------------------------------------------------------------------------------------
    chkVal("table still holds seven OUI blocks", (long)POLICE_OUI_COUNT, 7);
    for (size_t i = 0; i < POLICE_OUI_COUNT; i++) {
        uint8_t mac[6] = { POLICE_OUI[i][0], POLICE_OUI[i][1], POLICE_OUI[i][2], 0x0a, 0x0b, 0x0c };
        char nm[64];
        snprintf(nm, sizeof(nm), "OUI %02X:%02X:%02X matches", mac[0], mac[1], mac[2]);
        bool got = runBle(mac);
        chk(nm, got, true, d.confidence, 45, d.detail, "Motorola Solutions OUI");
    }
    // Prefix match, not full-MAC: the last three bytes are the device, not the vendor.
    { bool got = runBle(MAC_MOTO_ALT);
      chk("same OUI, different tail -> still matches", got, true, d.confidence, 45, d.detail); }

    // ---------------------------------------------------------------------------------------
    // 4. THE WiFi ENTRY POINT. This is the one that actually fires in the field (the 27
    // ground-truth hits were all WiFi), and it is a completely separate function from the BLE
    // path, so it gets its own gate/shape/confidence coverage.
    // ---------------------------------------------------------------------------------------
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_OTHER);
      bool got = runWifi(f.data(), f.size());
      chk("mgmt frame, Motorola transmitter -> hit", got, true, d.confidence, 45, d.detail,
          "Motorola Solutions OUI"); }
    chkVal("WiFi source is SRC_WIFI", (long)d.src, (long)SRC_WIFI);
    chkVal("WiFi hit reports addr2 (the transmitter)", memcmp(d.mac, MAC_MOTO, 6), 0);
    { std::vector<uint8_t> f = mgmtFrame(MAC_OTHER, MAC_MALAY);
      bool got = runWifi(f.data(), f.size());
      chk("unknown addr2, Motorola BSSID -> hit on addr3", got, true, d.confidence, 45, d.detail);
      chkVal("addr3 fallback reports the BSSID mac", memcmp(d.mac, MAC_MALAY, 6), 0); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_MALAY);
      bool got = runWifi(f.data(), f.size());
      chk("both addresses match -> addr2 wins", got, true, d.confidence, 45, d.detail);
      chkVal("addr2 priority: reported mac is addr2", memcmp(d.mac, MAC_MOTO, 6), 0); }
    // Management frames only. 0x08 is a data frame, 0xB4 an RTS control frame: both carry
    // addresses in different places, so matching them would report garbage MACs.
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_MOTO, 0x08);
      chk("data frame (type 2) -> no hit", runWifi(f.data(), f.size()), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_MOTO, 0xb4);
      chk("control frame (type 1) -> no hit", runWifi(f.data(), f.size()), false); }
    // The type test masks only bits 2-3, so the protocol-version bits are ignored on purpose.
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_OTHER, 0x81);
      bool got = runWifi(f.data(), f.size());
      chk("proto-version bits ignored, still a beacon", got, true, d.confidence, 45, d.detail); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_OTHER);
      bool got = runWifi(f.data(), 24);
      chk("len 24 (exact header) -> hit", got, true, d.confidence, 45, d.detail);
      chk("len 23 (one short) -> no hit", runWifi(f.data(), 23), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_MOTO, MAC_OTHER);
      setGates(false, true, false);
      chk("WiFi path respects the sub-toggle being off", runWifi(f.data(), f.size()), false);
      setGates(true, false, false);
      chk("WiFi path respects the category being off", runWifi(f.data(), f.size()), false);
      setGates(true, true, false); }

    // ---------------------------------------------------------------------------------------
    // 5. ADVERSARIAL INPUT. Nothing here may read out of bounds or crash, and nothing here may
    // match. These are hand-built byte arrays, so a bounds slip shows up as a sanitiser abort
    // or a wrong verdict rather than as a field crash nobody can reproduce.
    // ---------------------------------------------------------------------------------------
    chk("null frame pointer -> no hit", runWifi(nullptr, 24), false);
    { // truncated frame: a real 10-byte buffer with an honest length. The len < 24 guard is the
      // only thing standing between this and a read past the end at frame[10..21].
      std::vector<uint8_t> f(10, 0); f[0] = 0x80;
      chk("truncated frame (10 bytes) -> no hit", runWifi(f.data(), f.size()), false); }
    { std::vector<uint8_t> f; f.push_back(0x80);
      chk("1-byte frame -> no hit", runWifi(f.data(), f.size()), false); }
    chk("zero-length frame -> no hit", runWifi(nullptr, 0), false);

    // The BLE path is MAC-only: it (void)s the advert entirely. These three lock that in, which
    // is what makes the malformed-advert case safe by construction today. If payload parsing is
    // ever added, all three of these are the tests that will change, and they should be read as
    // "this was deliberate", not as an oversight.
    { bool got = runBle(MAC_MOTO, nullptr, 0);
      chk("BLE: null advert + matching MAC -> still hits", got, true, d.confidence, 45, d.detail); }
    { std::vector<uint8_t> a;   // empty buffer, non-null-ish call shape
      chk("BLE: empty advert + non-Motorola MAC -> no hit", runBle(MAC_OTHER, a.data(), a.size()), false); }
    { // AD length field claims 200 bytes inside a 3-byte buffer, the classic overrun advert
      std::vector<uint8_t> a; a.push_back(200); a.push_back(0xff); a.push_back(0xab);
      bool got = runBle(MAC_MOTO, a.data(), a.size());
      chk("BLE: length overruns buffer, MAC matches -> hit", got, true, d.confidence, 45, d.detail);
      chk("BLE: length overruns buffer, MAC does not -> no hit", runBle(MAC_OTHER, a.data(), a.size()), false); }
    { // A well-formed manufacturer-data advert on a non-Motorola MAC. This classifier has no
      // company-ID table at all, so the payload is irrelevant no matter whose ID it carries.
      std::vector<uint8_t> a; a.push_back(0x05); a.push_back(0xff);
      a.push_back(0x8b); a.push_back(0x00); a.push_back(0x01); a.push_back(0x02);
      chk("BLE: mfg data present, wrong MAC -> no hit", runBle(MAC_OTHER, a.data(), a.size()), false); }

    // Near misses. Each of these is one byte away from a real row, or a neighbouring vendor.
    { uint8_t m[6] = { 0x4c, 0xcc, 0x35, 0, 0, 1 };
      chk("neighbouring OUI 4C:CC:35 -> no hit", runBle(m), false); }
    { uint8_t m[6] = { 0x4c, 0xcc, 0x33, 0, 0, 1 };
      chk("neighbouring OUI 4C:CC:33 -> no hit", runBle(m), false); }
    { uint8_t m[6] = { 0x00, 0x04, 0x7c, 0, 0, 1 };
      chk("neighbouring OUI 00:04:7C -> no hit", runBle(m), false); }
    { uint8_t m[6] = { 0x9c, 0x86, 0x2c, 0, 0, 1 };
      chk("neighbouring OUI 9C:86:2C -> no hit", runBle(m), false); }
    chk("Axon 00:25:DF is NOT this table's job", runBle(MAC_AXON), false);
    { uint8_t m[6] = { 0, 0, 0, 0, 0, 0 };
      chk("all-zero MAC -> no hit", runBle(m), false); }
    { uint8_t m[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
      chk("broadcast MAC -> no hit", runBle(m), false); }
    { // Locally-administered twin of 4C:CC:34 (bit 0x02 set). Belt and braces: no row in the
      // table has that bit, so the table lookup would reject it anyway, but the explicit guard
      // is what stops a randomized address from ever earning an OUI-only match.
      uint8_t m[6] = { 0x4e, 0xcc, 0x34, 0x11, 0x22, 0x33 };
      chk("locally-administered 4E:CC:34 -> no hit", runBle(m), false); }
    { std::vector<uint8_t> f = mgmtFrame(MAC_OTHER, MAC_OTHER);
      chk("WiFi frame with no Motorola address -> no hit", runWifi(f.data(), f.size()), false); }

    // CONCERN (not asserted, cannot be from here): policeSetEnabled() early-returns when the
    // new value equals the in-memory one, so it skips the NVS write. On a board whose main.cpp
    // default is ON, a user turning it off before anything ever persisted a value can have that
    // choice not survive a reboot. The host Preferences stub cannot observe writes, so this
    // note is the record of it rather than a test.

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
