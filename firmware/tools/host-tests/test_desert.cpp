// Host regression test for Desert mode, the catch-all classifier.
//
// WHY THIS ONE MATTERS: desert is the LAST link in the scan chain and it matches EVERYTHING, so
// it has no signature table to protect it. Two things are all that stand between it and garbage:
//   1. the enable toggle (OFF by default). If that ever defaults on, every phone, laptop and
//      fridge in range becomes an alert row, which is indistinguishable from "the product is
//      broken" to a user who is not in the desert.
//   2. the randomized-MAC vs hardware-OUI call. On WiFi that is one bit; on BLE it is that bit
//      OR the controller's address type, and with no type the row must say "OUI unknown" rather
//      than claim hardware. That label is the ONLY thing that tells a real device apart from
//      phone-MAC churn, and the whole point of the mode is "something arrived". Get it
//      backwards and every rotating phone address looks like new hardware.
// Both are one-line behaviours that compile fine when wrong, and neither shows up on the bench:
// the mode is opt-in, so a regression here ships silently and only surfaces in the field.
//
// Also locks the exact detail strings ("randomized MAC" / "hardware OUI" / "OUI unknown")
// and the field stamping, because the apps consume both verbatim on the detection row.
#include "desert_detect.h"
#include <Preferences.h>   // the stub now really stores; see the persistence block at the end
#include <cstdio>
#include <cstring>
#include <vector>

// LINK STUB: desert_detect.cpp calls acabSanitizeAscii() from acab_scanner.cpp, and the harness
// compiles exactly one source file next to the test. Mirrored byte-for-byte from
// acab_scanner.cpp so the name/SSID clamping tests below assert the real behaviour: printable
// ASCII (0x20..0x7E) passes, anything else becomes '.', truncate at cap-1, always NUL-terminate.
// If the real one ever changes, this copy has to change with it.
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
// Same shape as test_glasses.cpp's helper, but desert always hits when enabled, so the
// interesting assertions are the strings it reports rather than the hit/no-hit verdict.
static void chk_impl(const char* label, bool got, bool wantHit,
                const char* gotDetail = "", const char* wantDetail = nullptr,
                const char* gotName = "", const char* wantName = nullptr) {
    bool ok = (got == wantHit);
    if (ok && wantHit && wantDetail) ok = (strcmp(gotDetail, wantDetail) == 0);
    if (ok && wantHit && wantName)   ok = (strcmp(gotName, wantName) == 0);
    printf("  %-52s %s", label, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got hit=%d detail=\"%s\" name=\"%s\"", got, gotDetail, gotName); failures++; }
    printf("\n");
}
// For plain field assertions (type/method/confidence/rssi/mac) where there is no string to show.
static void chkTrue_impl(const char* label, bool ok) {
    printf("  %-52s %s\n", label, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
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
#define chkTrue(label, okexpr) do { const bool acab_ok_ = (okexpr); chkTrue_impl((label), acab_ok_); } while (0)

// ---- BLE advert builders (AD structures: [len][type][data...]) ----
static void addFlags(std::vector<uint8_t>& a) {
    a.push_back(2); a.push_back(0x01); a.push_back(0x06);
}
static void addName(std::vector<uint8_t>& a, uint8_t adType, const char* s) {
    size_t n = strlen(s);
    a.push_back((uint8_t)(1 + n)); a.push_back(adType);
    for (size_t i = 0; i < n; i++) a.push_back((uint8_t)s[i]);
}
// Default = ACAB_BLE_ADDR_UNKNOWN, which is what the dual-radio UART path and replays deliver.
static bool runBle(const uint8_t mac[6], std::vector<uint8_t>& a, AcabDetection* out,
                   AcabBleAddrType t = ACAB_BLE_ADDR_UNKNOWN) {
    memset(out, 0, sizeof(*out));
    return desertClassifyBLE(mac, a.data(), a.size(), -84, out, t);
}

// ---- 802.11 mgmt frame builder ----
// Header layout: [0]=frame control, [1]=flags, [2..3]=duration, [4..9]=addr1 (destination),
// [10..15]=addr2 (TRANSMITTER, the one desert reports), [16..21]=addr3, [22..23]=seq.
// Beacons / probe-responses then carry 12 bytes of fixed params (timestamp + interval + caps),
// so their IEs start at 36; a probe-request has no fixed params and starts at 24.
//
// addr1 is DELIBERATELY a locally-administered (randomized-looking) address in every frame while
// addr2 is a real OUI. If the classifier ever reads the wrong address field, every "hardware OUI"
// assertion below flips to "randomized MAC" at once.
static const uint8_t WIFI_A1_RANDOM[6] = {0x02, 0xde, 0xad, 0xbe, 0xef, 0x01};
static std::vector<uint8_t> wifiHdr(uint8_t fc, const uint8_t addr2[6]) {
    std::vector<uint8_t> f(24, 0x00);
    f[0] = fc;
    memcpy(&f[4],  WIFI_A1_RANDOM, 6);
    memcpy(&f[10], addr2, 6);
    if (fc != 0x40) f.resize(36, 0x00);   // beacon / probe-response fixed params
    return f;
}
static void addSsid(std::vector<uint8_t>& f, const char* s, int lenField = -1) {
    size_t n = strlen(s);
    f.push_back(0x00);                                                   // tag 0 = SSID
    f.push_back(lenField >= 0 ? (uint8_t)lenField : (uint8_t)n);
    for (size_t i = 0; i < n; i++) f.push_back((uint8_t)s[i]);
}
static bool runWifi(std::vector<uint8_t>& f, AcabDetection* out) {
    memset(out, 0, sizeof(*out));
    return desertClassifyWiFi(f.data(), f.size(), -60, out);
}

int main() {
    AcabDetection d;
    // Real hardware OUI (globally unique) vs a locally-administered / randomized address.
    const uint8_t macOui[6]  = {0x00, 0x25, 0xdf, 0x11, 0x22, 0x33};
    const uint8_t macRand[6] = {0xc2, 0x4a, 0x90, 0x11, 0x22, 0x33};
    printf("\n=== desert classifier regression ===\n");

    // ---------------------------------------------------------------- toggle
    // FIRST assertion in the file on purpose: this reads the static initialiser before anything
    // in this test has touched it. Desert alerts on every device in range, so shipping it on by
    // default would be the single loudest possible regression.
    chkTrue("default state is OFF (never on by accident)", desertIsEnabled() == false);
    { std::vector<uint8_t> a; addName(a, 0x09, "PIXEL-7");
      chk("disabled: BLE catch-all does NOT fire", runBle(macOui, a, &d), false); }
    { // Disabled must return BEFORE acabInit, i.e. it must not clobber the caller's buffer. The
      // scanner passes ONE detection struct down the whole classifier chain, so a desert that
      // scribbled on it while disabled would corrupt the real match that came before it.
      memset(&d, 0, sizeof(d)); d.type = ACAB_FLOCK_CAMERA; d.confidence = 99;
      strcpy(d.detail, "sentinel");
      std::vector<uint8_t> a; addName(a, 0x09, "PIXEL-7");
      bool hit = desertClassifyBLE(macOui, a.data(), a.size(), -84, &d, ACAB_BLE_ADDR_UNKNOWN);
      chkTrue("disabled: caller's detection left untouched",
              !hit && d.type == ACAB_FLOCK_CAMERA && d.confidence == 99 &&
              strcmp(d.detail, "sentinel") == 0); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui); addSsid(f, "CoffeeShop");
      chk("disabled: WiFi catch-all does NOT fire", runWifi(f, &d), false); }

    desertSetEnabled(true);
    chkTrue("desertSetEnabled(true) reflected by desertIsEnabled()", desertIsEnabled() == true);

    // ------------------------------------------------------- BLE, enabled
    { // No address type (dual-radio UART path): the bytes alone cannot prove an OUI, so the
      // row says so instead of claiming one. This used to read "hardware OUI" for every BLE
      // address with the 0x02 bit clear, which filed about half of all rotating phone
      // addresses under real hardware.
      std::vector<uint8_t> a;
      chk("BLE: OUI-shaped MAC, type UNKNOWN -> OUI unknown", runBle(macOui, a, &d), true,
          d.detail, "OUI unknown", d.name, ""); }
    { std::vector<uint8_t> a;
      chk("BLE: OUI-shaped MAC, type PUBLIC -> hardware OUI",
          runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true, d.detail, "hardware OUI", d.name, ""); }
    { // Every field the app reads off a desert row. type 7 = ACAB_NEARBY_DEVICE is the wire value
      // in the BLE t= field, so a renumber here silently retypes rows in both apps.
      chkTrue("BLE: type=NEARBY src=BLE method=M_NONE",
              d.type == ACAB_NEARBY_DEVICE && d.src == SRC_BLE && d.method == M_NONE); }
    { // Desert reports confidence 0 BY DESIGN: nothing matched, it is just "a device is there".
      // Locked in because any downstream filter of the form `confidence > 0` would drop every
      // desert row on the floor and make the mode look dead.
      chkTrue("BLE: confidence is 0 (no signature matched)", d.confidence == 0); }
    { chkTrue("BLE: rssi + MAC copied through verbatim",
              d.rssi == -84 && memcmp(d.mac, macOui, 6) == 0); }
    { chkTrue("BLE: companyId left 0 (scanner stamps it later)", d.companyId == 0); }
    { chkTrue("BLE: randomAddr=false agrees with the detail string",
              d.randomAddr == false && strcmp(d.detail, "hardware OUI") == 0); }
    { // The controller's word beats the bytes: a public-LOOKING address reported RANDOM is a
      // resolvable private address, and both the label and randomAddr must say so.
      std::vector<uint8_t> a;
      chk("BLE: OUI-shaped MAC, type RANDOM -> randomized MAC",
          runBle(macOui, a, &d, ACAB_BLE_ADDR_RANDOM), true, d.detail, "randomized MAC");
      chkTrue("BLE: type RANDOM sets randomAddr even with the 0x02 bit clear", d.randomAddr == true); }

    { std::vector<uint8_t> a;
      chk("BLE: locally-administered MAC c2: -> randomized", runBle(macRand, a, &d), true,
          d.detail, "randomized MAC"); }
    { chkTrue("BLE: randomAddr=true agrees with the detail string",
              d.randomAddr == true && strcmp(d.detail, "randomized MAC") == 0); }
    { const uint8_t m[6] = {0x02, 0x00, 0x00, 0x00, 0x00, 0x01};   // lowest possible LAA
      std::vector<uint8_t> a;
      chk("BLE: 02: (bit 1 only) -> randomized", runBle(m, a, &d), true, d.detail, "randomized MAC"); }
    { // NEAR MISS, the whole reason this pair of tests exists. Bit 0 of octet 0 is the
      // MULTICAST bit; bit 1 is the locally-administered bit. Only bit 1 means randomized.
      // Testing the wrong bit is the classic version of this bug and it still "works" on half
      // the addresses you happen to try by hand.
      const uint8_t m[6] = {0x01, 0x25, 0xdf, 0x11, 0x22, 0x33};
      std::vector<uint8_t> a;
      chk("BLE: 01: multicast bit is NOT randomized", runBle(m, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI"); }
    { // A set 0x02 bit is conclusive on its own: no IEEE OUI has it, so even a PUBLIC report
      // (a locally-administered public address) must not promote it to "hardware OUI".
      std::vector<uint8_t> a;
      chk("BLE: LAA bit set + type PUBLIC stays randomized", runBle(macRand, a, &d, ACAB_BLE_ADDR_PUBLIC),
          true, d.detail, "randomized MAC"); }
    { const uint8_t m[6] = {0x03, 0x25, 0xdf, 0x11, 0x22, 0x33};   // both bits
      std::vector<uint8_t> a;
      chk("BLE: 03: multicast + LAA -> randomized", runBle(m, a, &d), true, d.detail, "randomized MAC"); }
    { // A real captured BLE resolvable private address (top two bits 01, 0x02 bit clear). With
      // the type plumbed from the radio it is labelled correctly; without a type (dual-radio
      // UART path) it is no longer misfiled as hardware, it is reported as unknowable. The
      // former "locked in as-is" assertion here recorded the old misfiling.
      const uint8_t rpa[6] = {0x41, 0xbc, 0xbc, 0x7d, 0xe0, 0x53};
      std::vector<uint8_t> a;
      chk("BLE: RPA 41: type RANDOM -> randomized MAC", runBle(rpa, a, &d, ACAB_BLE_ADDR_RANDOM), true,
          d.detail, "randomized MAC");
      chk("BLE: RPA 41: type UNKNOWN -> OUI unknown (never hardware OUI)", runBle(rpa, a, &d), true,
          d.detail, "OUI unknown"); }

    // ------------------------------------------------- label width is a WIRE CONTRACT
    { // The live BLE notify can only elide RID fields, which a Nearby row never carries, so a row
      // that outgrows the iPhone-class 182-byte notify cap is a LOST live sighting. The three
      // BLE labels are held to the widths that shipped before 2.0.7: "randomized MAC" is the
      // 14-byte worst case, and the two labels that stand in for the old "hardware OUI" stay at
      // its 12 bytes, so no row's name budget moves. A 20-byte draft of the third label once cut
      // the deliverable name length on GPS-stamped rows from 24 to 16 chars.
      std::vector<uint8_t> a;
      runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC);  size_t lp = strlen(d.detail);
      runBle(macOui, a, &d, ACAB_BLE_ADDR_RANDOM);  size_t lr = strlen(d.detail);
      runBle(macOui, a, &d, ACAB_BLE_ADDR_UNKNOWN); size_t lu = strlen(d.detail);
      chkTrue("BLE: desert labels hold their pre-2.0.7 widths (<=12 / <=14 / <=12 bytes)",
              lp <= 12 && lr <= 14 && lu <= 12); }
    { // The rule's single owner, pinned directly: RANDOM sets, PUBLIC and UNKNOWN never clear.
      AcabDetection x; memset(&x, 0, sizeof(x));
      acabNoteBleAddrType(&x, ACAB_BLE_ADDR_UNKNOWN); bool u = x.randomAddr;
      acabNoteBleAddrType(&x, ACAB_BLE_ADDR_PUBLIC);  bool p = x.randomAddr;
      acabNoteBleAddrType(&x, ACAB_BLE_ADDR_RANDOM);  bool r = x.randomAddr;
      acabNoteBleAddrType(&x, ACAB_BLE_ADDR_PUBLIC);  bool p2 = x.randomAddr;
      chkTrue("acabNoteBleAddrType: UNKNOWN/PUBLIC leave false, RANDOM sets, PUBLIC never clears",
              !u && !p && r && p2); }

    // ------------------------------------------------- BLE name decoding
    { std::vector<uint8_t> a; addName(a, 0x09, "PIXEL-7");
      chk("BLE: complete local name (AD 0x09) decoded", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, "PIXEL-7"); }
    { std::vector<uint8_t> a; addFlags(a); addName(a, 0x08, "abc");
      chk("BLE: shortened name (AD 0x08) after flags", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, "abc"); }
    { std::vector<uint8_t> a; addFlags(a);
      chk("BLE: flags only, no name AD -> empty name", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // Sanitizer on ingest: a crafted name full of control bytes must not reach the app, because
      // raw control chars break the detection JSON and iOS silently drops invalid JSON.
      std::vector<uint8_t> a;
      a.push_back(4); a.push_back(0x09); a.push_back('h'); a.push_back(0x00); a.push_back(0x1b);
      chk("BLE: control bytes in name become dots", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, "h.."); }
    { // 50-char name into a 40-byte field: must truncate to 39 chars + NUL, never overrun.
      std::vector<uint8_t> a; a.push_back(51); a.push_back(0x09);
      char want[40];
      for (int i = 0; i < 50; i++) { uint8_t c = (uint8_t)('A' + (i % 26)); a.push_back(c);
                                     if (i < 39) want[i] = (char)c; }
      want[39] = 0;
      bool hit = runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC);
      chk("BLE: 50-char name truncated to the 39-char field", hit, true,
          d.detail, "hardware OUI", d.name, want); }

    // ------------------------------------------- BLE adversarial adverts
    { // Catch-all MUST still fire with nothing to parse: a device that advertises no AD data at
      // all is exactly the "something arrived" case desert exists for.
      memset(&d, 0, sizeof(d));
      chk("BLE: null advert pointer still hits, empty name",
          desertClassifyBLE(macOui, nullptr, 0, -84, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }
    { std::vector<uint8_t> a;
      chk("BLE: empty buffer (len 0) still hits, empty name", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // Hostile length field: claims 200 bytes inside a 3-byte buffer. Must stop, not read past
      // the end, and still report the device.
      std::vector<uint8_t> a = {200, 0x09, 'A'};
      chk("BLE: AD length overruns buffer -> no name, no read", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // Zero length field would advance the cursor by 1 forever: the loop must break out.
      std::vector<uint8_t> a = {0, 0x09, 'A', 'B'};
      chk("BLE: zero AD length -> breaks, no infinite loop", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }
    { std::vector<uint8_t> a = {0x09};   // single dangling byte
      chk("BLE: 1-byte truncated advert", runBle(macOui, a, &d, ACAB_BLE_ADDR_PUBLIC), true,
          d.detail, "hardware OUI", d.name, ""); }

    // ------------------------------------------------------ WiFi, enabled
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui); addSsid(f, "CoffeeShop");
      chk("WiFi: beacon 0x80, SSID at offset 36", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, "CoffeeShop"); }
    { chkTrue("WiFi: type=NEARBY src=WIFI method=M_SSID conf=0",
              d.type == ACAB_NEARBY_DEVICE && d.src == SRC_WIFI && d.method == M_SSID &&
              d.confidence == 0); }
    { // The reported MAC is addr2 (transmitter), NOT addr1. Every frame here has a randomized
      // addr1, so reading the wrong field would show up as both a wrong MAC and a wrong detail.
      chkTrue("WiFi: reports addr2 (transmitter), not addr1",
              memcmp(d.mac, macOui, 6) == 0 && d.rssi == -60); }
    { std::vector<uint8_t> f = wifiHdr(0x50, macOui); addSsid(f, "CoffeeShop");
      chk("WiFi: probe-response 0x50, SSID at offset 36", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, "CoffeeShop"); }
    { // Probe-requests have no fixed-parameter block, so their IEs start 12 bytes earlier. Using
      // one offset for all three frame types is the easy regression, and it would silently stop
      // decoding the SSID of every passing phone.
      std::vector<uint8_t> f = wifiHdr(0x40, macOui); addSsid(f, "HomeNet");
      chk("WiFi: probe-request 0x40, SSID at offset 24", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, "HomeNet"); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macRand); addSsid(f, "CoffeeShop");
      chk("WiFi: randomized transmitter address", runWifi(f, &d), true, d.detail, "randomized MAC"); }
    { chkTrue("WiFi: randomAddr=true agrees with the detail string", d.randomAddr == true); }

    // ------------------------------------------ WiFi negatives / adversarial
    { // NEAR MISS: 0x88 (QoS data) sits one bit away from the accepted beacon 0x80. Desert is
      // deliberately limited to presence mgmt frames; widening it to data frames would turn every
      // packet of an active session into a detection row.
      std::vector<uint8_t> f = wifiHdr(0x88, macOui);
      chk("WiFi: data frame 0x88 -> no hit", runWifi(f, &d), false); }
    { // NEAR MISS: same subtype nibble as a beacon but with the protocol-version bits set. The
      // comparison is an exact byte match, not a masked subtype test.
      std::vector<uint8_t> f = wifiHdr(0x80, macOui); f[0] = 0x81;
      chk("WiFi: 0x81 (beacon + version bits) -> no hit", runWifi(f, &d), false); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui); f[0] = 0xb0;   // authentication
      chk("WiFi: auth frame 0xb0 -> no hit", runWifi(f, &d), false); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui); f.resize(23);
      chk("WiFi: frame shorter than the 24-byte header", runWifi(f, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("WiFi: null frame pointer with a large length",
          desertClassifyWiFi(nullptr, 100, -60, &d), false); }
    { // Wildcard probe-request: SSID present but zero-length. Still a device, just nameless.
      std::vector<uint8_t> f = wifiHdr(0x40, macOui); addSsid(f, "");
      chk("WiFi: wildcard (0-length) SSID -> hit, empty name", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, ""); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui);   // header only, no IEs at all
      chk("WiFi: beacon with no IEs -> hit, empty name", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // Hostile SSID length: claims 32 bytes with 2 in the buffer. Must refuse to copy rather
      // than read past the frame.
      std::vector<uint8_t> f = wifiHdr(0x80, macOui); addSsid(f, "xy", 32);
      chk("WiFi: SSID length overruns frame -> no name, no read", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // 33 is one over the 802.11 maximum: rejected outright even though the bytes are present.
      std::vector<uint8_t> f = wifiHdr(0x80, macOui);
      addSsid(f, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", 33);
      chk("WiFi: SSID length 33 (over the 32 max) -> no name", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, ""); }
    { // Only tag 0 at the head of the IE list is read; desert does not walk the IE chain, so a
      // frame that leads with supported-rates reports no SSID. Current behaviour, locked in.
      std::vector<uint8_t> f = wifiHdr(0x80, macOui);
      f.push_back(0x01); f.push_back(2); f.push_back(0x82); f.push_back(0x84);
      addSsid(f, "CoffeeShop");
      chk("WiFi: SSID not first IE -> not decoded (as-is)", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, ""); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui);
      f.push_back(0x00); f.push_back(5);
      f.push_back('h'); f.push_back(0x00); f.push_back(0x1b); f.push_back(0xff); f.push_back('i');
      chk("WiFi: control bytes in SSID become dots", runWifi(f, &d), true,
          d.detail, "hardware OUI", d.name, "h...i"); }

    // ---------------------------------------------------- toggle back off
    // The app flips this at runtime, so turning it off has to take effect immediately: no latch,
    // no "still reporting until reboot". A user who turns desert off in a city expects the flood
    // to stop that second.
    desertSetEnabled(false);
    chkTrue("desertSetEnabled(false) reflected by desertIsEnabled()", desertIsEnabled() == false);
    { std::vector<uint8_t> a; addName(a, 0x09, "PIXEL-7");
      chk("re-disabled: BLE stops matching immediately", runBle(macOui, a, &d), false); }
    { std::vector<uint8_t> f = wifiHdr(0x80, macOui); addSsid(f, "CoffeeShop");
      chk("re-disabled: WiFi stops matching immediately", runWifi(f, &d), false); }

    // ------------------------------------------------ persistence across a reboot
    // Desert was the ONLY detector toggle without NVS until 2026-08-08, so every reset silently
    // turned it off. On a handheld that voided one drive test. On a board deployed unattended for
    // a week it is fatal AND undetectable: the owner returns to an empty log with no way to tell
    // "nothing came by" from "the mode switched itself off on day two".
    //
    // This only became testable when the host Preferences stub stopped discarding writes. Before
    // that, a toggle that never reached NVS and one that round-tripped correctly produced
    // byte-identical passing runs, so the suite was blind to exactly the property that matters.
    // Both halves are checked separately, because either one alone is a silent failure:
    //   (a) the setter actually reaches NVS, and
    //   (b) the restore path reads it back and BEATS the compiled-in default.
    {
        // (a) writes land
        desertSetEnabled(true);
        { Preferences p; p.begin("acab-desert", true);
          chkTrue("desertSetEnabled(true) reaches NVS", p.getBool("on", false) == true); p.end(); }
        desertSetEnabled(false);
        { Preferences p; p.begin("acab-desert", true);
          chkTrue("desertSetEnabled(false) reaches NVS", p.getBool("on", true) == false); p.end(); }

        // (b) the reboot path. Seed NVS directly, then restore: this is what setup() does after a
        // power cycle, and the persisted value has to win over whatever default is passed.
        { Preferences p; p.begin("acab-desert", false); p.putBool("on", true); p.end(); }
        desertRestoreEnabled(false);
        chkTrue("reboot: persisted ON beats a false default", desertIsEnabled() == true);

        { Preferences p; p.begin("acab-desert", false); p.putBool("on", false); p.end(); }
        desertRestoreEnabled(true);
        chkTrue("reboot: persisted OFF beats a true default", desertIsEnabled() == false);

        // First ever boot / factory reset: nothing stored, so the default must govern both ways.
        Preferences::wipeAll();
        desertRestoreEnabled(false);
        chkTrue("empty NVS falls back to the default (off)", desertIsEnabled() == false);
        desertRestoreEnabled(true);
        chkTrue("empty NVS honours a true default", desertIsEnabled() == true);
        desertSetEnabled(false);
    }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
