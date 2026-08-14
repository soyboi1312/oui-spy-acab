// Host regression test for ble_adv16.h - structural decoding of 16-bit identifiers out of a BLE
// advertisement.
//
// WHY THIS EXISTS. The detectors used to reach service-UUID evidence by concatenating several AD
// structures' payloads into one flat buffer and SEARCHING it. For an ASCII tag like "BWCDEVICE"
// that is fine. For a 16-bit UUID it is not: a two-byte needle hits anywhere those bytes land -
// inside vendor payload, inside a 128-bit UUID, or straddling the boundary between two structures -
// and the result reads as "this vendor's equipment" on a coincidence. These identifiers are
// Bluetooth SIG assignments issued to the PRODUCT VENDOR, so a false hit is not a cosmetic bug: it
// is the firmware naming a company that was never there.
//
// The cases below are therefore weighted toward what must NOT match. Anyone tempted to "simplify"
// this back into a memmem over concatenated bytes should read the three false-positive cases first.
#include "ble_adv16.h"
#include <cstdio>
#include <cstring>
#include <vector>

static int failures = 0;
static void chk(const char* name, bool got, bool want) {
    bool ok = (got == want);
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %d want %d", (int)got, (int)want); failures++; }
    printf("\n");
}
static void chkInt(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-58s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}

// ---- advert builders: [len][type][data...] ----
static void addAd(std::vector<uint8_t>& a, uint8_t type, const std::vector<uint8_t>& data) {
    a.push_back((uint8_t)(1 + data.size()));
    a.push_back(type);
    for (uint8_t b : data) a.push_back(b);
}
static std::vector<uint8_t> le(uint16_t v) { return { (uint8_t)(v & 0xFF), (uint8_t)(v >> 8) }; }

// Real Bluetooth SIG assignments, used as the needles so the test exercises the values the
// firmware actually looks for.
static const uint16_t AXON_SVC  = 0xFC81;   // Axon Enterprise
static const uint16_t TASER_SVC = 0xFE6B;   // TASER International
static const uint16_t MOTO_SVC  = 0xFD8E;   // Motorola Solutions
static const uint16_t TASER_CID = 0x034D;   // TASER International, company ID
static const uint16_t MOTO_CID  = 0x04EC;   // Motorola Solutions, company ID

static size_t gCount = 0;
static void countCb(uint16_t, uint8_t, void*) { gCount++; }

int main() {
    printf("\n=== BLE 16-bit identifier decoding (ble_adv16) ===\n\n");

    printf("-- the AD types the old parser missed entirely --\n");
    { std::vector<uint8_t> a; addAd(a, 0x03, le(AXON_SVC));         // COMPLETE 16-bit UUID list
      chk("0x03 complete list carrying FC81 -> found", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), true); }
    { std::vector<uint8_t> a; addAd(a, 0x02, le(AXON_SVC));         // INCOMPLETE list
      chk("0x02 incomplete list carrying FC81 -> found", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), true); }
    { std::vector<uint8_t> a; addAd(a, 0x14, le(TASER_SVC));        // solicitation
      uint8_t where = 0;
      chk("0x14 solicitation list carrying FE6B -> found", acabAdvHasUuid16(a.data(), a.size(), TASER_SVC, &where), true);
      // The caller MUST be able to tell solicitation apart from the confirming AD types. 0x14 is a
      // peripheral asking for centrals that PROVIDE the service, so an Axon UUID there is a device
      // looking FOR Axon gear (a phone running their app), not Axon-made hardware. vendorScanAdv
      // routes on exactly this value; if it stopped being reported, a bystander's handset would
      // silently start counting as vendor-confirmed equipment.
      chkInt("  ^ reports adType 0x14 so callers can refuse to treat it as confirmation",
             where, ACAB_AD_UUID16_SOLICIT); }
    { std::vector<uint8_t> a; addAd(a, 0x03, le(TASER_SVC));
      uint8_t where = 0; acabAdvHasUuid16(a.data(), a.size(), TASER_SVC, &where);
      chkInt("  ^ the same UUID in 0x03 reports as CONFIRMATION, not solicitation",
             where, ACAB_AD_UUID16_COMPLETE); }

    printf("\n-- service data: the UUID is the FIRST TWO BYTES, the rest is payload --\n");
    { std::vector<uint8_t> d = le(AXON_SVC); d.push_back(0x11); d.push_back(0x22);
      std::vector<uint8_t> a; addAd(a, 0x16, d);
      uint8_t where = 0;
      chk("0x16 service data, UUID in the leading pair -> found",
          acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, &where), true);
      chkInt("  ^ reports which AD type carried it", where, ACAB_AD_SERVICE_DATA_16); }

    printf("\n-- FALSE POSITIVES the flat-buffer search allowed. These must NOT match. --\n");
    { // The target's bytes sitting in the vendor PAYLOAD of unrelated service data. A byte search
      // hits this; a structural decode reads only the leading pair and does not.
      std::vector<uint8_t> d = le(0x1234); for (uint8_t b : le(AXON_SVC)) d.push_back(b);
      std::vector<uint8_t> a; addAd(a, 0x16, d);
      chk("FC81 inside service-data PAYLOAD -> no match", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { // Straddling two structures: 0x81 ends one AD, 0xFC begins the next. Only concatenation
      // can produce this, which is exactly why concatenation was the wrong shape.
      std::vector<uint8_t> a;
      addAd(a, 0x16, { 0x34, 0x12, 0x81 });
      addAd(a, 0x16, { 0xFC, 0x00 });
      chk("FC81 straddling two AD structures -> no match", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { // Inside a 128-bit UUID list. Those are 16 bytes per entry and are not 16-bit UUIDs.
      std::vector<uint8_t> d(16, 0x00); d[4] = 0x81; d[5] = 0xFC;
      std::vector<uint8_t> a; addAd(a, 0x07, d);
      chk("FC81 bytes inside a 128-bit UUID entry -> no match", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { // The advertised NAME happening to contain the bytes.
      std::vector<uint8_t> a; addAd(a, 0x09, { 'x', 0x81, 0xFC, 'y' });
      chk("FC81 bytes inside the local name -> no match", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }

    printf("\n-- lists with several entries --\n");
    { std::vector<uint8_t> d; for (uint16_t u : { (uint16_t)0x180F, (uint16_t)0x180A, TASER_SVC })
        for (uint8_t b : le(u)) d.push_back(b);
      std::vector<uint8_t> a; addAd(a, 0x03, d);
      chk("third entry of a 3-UUID list -> found", acabAdvHasUuid16(a.data(), a.size(), TASER_SVC, nullptr), true);
      chk("a UUID not in that list -> no match", acabAdvHasUuid16(a.data(), a.size(), MOTO_SVC, nullptr), false);
      gCount = 0; acabAdvForEachUuid16(a.data(), a.size(), countCb, nullptr);
      chkInt("  ^ visits every entry, not just the first", (long)gCount, 3); }

    printf("\n-- company IDs: EVERY manufacturer structure, not just the first --\n");
    { std::vector<uint8_t> a; addAd(a, 0xFF, le(TASER_CID));
      chk("single manufacturer structure -> found", acabAdvHasCompanyId(a.data(), a.size(), TASER_CID), true); }
    { // detection.h's acabBleCompanyId returns only the FIRST. An identifier in a later structure
      // is exactly the case that silently went missing.
      std::vector<uint8_t> a; addAd(a, 0xFF, le(0x004C)); addAd(a, 0xFF, le(MOTO_CID));
      chk("company ID in the SECOND 0xFF structure -> found", acabAdvHasCompanyId(a.data(), a.size(), MOTO_CID), true);
      chk("  ^ the first one is still found too", acabAdvHasCompanyId(a.data(), a.size(), 0x004C), true); }
    { std::vector<uint8_t> a; addAd(a, 0xFF, { 0x4D });   // one byte: no complete company ID
      chk("truncated manufacturer structure -> no match", acabAdvHasCompanyId(a.data(), a.size(), TASER_CID), false); }

    printf("\n-- malformed adverts must terminate, never over-read --\n");
    { std::vector<uint8_t> a = { 0x00, 0x03, 0x81, 0xFC };            // zero length ends the walk
      chk("adLen == 0 stops the walk", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { std::vector<uint8_t> a = { 0x40, 0x03, 0x81, 0xFC };            // claims 64 bytes, has 2
      chk("adLen running past the buffer stops the walk", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { std::vector<uint8_t> a; addAd(a, 0x03, { 0x81 });               // odd trailing byte
      chk("odd trailing byte in a list is not half-read", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), false); }
    { chk("null advert", acabAdvHasUuid16(nullptr, 0, AXON_SVC, nullptr), false);
      std::vector<uint8_t> a;
      chk("empty advert", acabAdvHasUuid16(a.data(), 0, AXON_SVC, nullptr), false); }

    printf("\n-- a realistic mixed advert --\n");
    { std::vector<uint8_t> a;
      addAd(a, 0x01, { 0x06 });                          // flags
      addAd(a, 0x03, le(AXON_SVC));                      // the assignment we care about
      addAd(a, 0x09, { 'A','X','-','1' });               // local name
      addAd(a, 0xFF, le(TASER_CID));                     // and the company ID
      chk("mixed advert: service UUID found", acabAdvHasUuid16(a.data(), a.size(), AXON_SVC, nullptr), true);
      chk("mixed advert: company ID found", acabAdvHasCompanyId(a.data(), a.size(), TASER_CID), true);
      chk("mixed advert: an absent vendor is still absent", acabAdvHasCompanyId(a.data(), a.size(), MOTO_CID), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
