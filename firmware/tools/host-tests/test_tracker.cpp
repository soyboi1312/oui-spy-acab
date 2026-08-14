// Host regression test for the item-tracker classifier.
//
// WHY THIS FILE EXISTS: tracker_detect.cpp encodes ONE DELIBERATE ASYMMETRY that reads like a bug
// and is very easy to "fix" wrongly.
//
//   Apple Find My is gated on an exact payload-length byte (0x19), because that is the
//   "separated from owner" form. The short "nearby" form is the user's own phone / earbuds, and
//   matching it would fire on every Apple device in the room.
//
//   Tile (0xFEED) and Samsung (0xFD5A) have NO equivalent separation test. They match on service
//   data with any payload of 2+ bytes, whatever it contains. That is not an oversight: neither
//   signature has been validated against a real tag in the field, which is exactly why their
//   confidences (65 / 60) sit BELOW Apple's 85.
//
// A future reader who "tightens Tile to match Apple" silently kills Tile detection; a reader who
// "loosens Apple for symmetry" turns the product into an AirPods alarm. Both changes compile.
// These tests are the thing that stops them.
//
// SECOND REASON: the detail strings below are matched EXACTLY, character for character, by both
// apps (OUIVendors.swift maker(), OuiVendors.kt) to render the tracker maker name. There is no
// parsing and no fallback: a one-character edit here shows up in the app as a blank maker. The
// confidence values are consumed the same way (row sort + alert threshold). So detail and
// confidence are tested as literal values on every positive, not just "it matched".
#include "tracker_detect.h"
#include <cstdio>
#include <cstring>
#include <vector>

// tracker_detect.cpp consults Desert mode to decide whether to classify while toggled off, but
// desert_detect.cpp is not part of this translation unit (run.sh compiles exactly one _detect.cpp
// beside the test). Same trick as test_glasses.cpp, except this one is drivable: the desert
// override is real behaviour that needs its own assertions.
static bool gHostDesert = false;
bool desertIsEnabled() { return gHostDesert; }

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
// For the non-boolean fields (method, type, src, rssi, randomAddr) that ride downstream.
static void chkInt(const char* name, long got, long want) {
    bool ok = (got == want);
    printf("  %-52s %s", name, ok ? "PASS" : "**FAIL**");
    if (!ok) { printf("   got %ld want %ld", got, want); failures++; }
    printf("\n");
}

// ---- advert builders (BLE AD structures: [len][type][data...]) ----
typedef std::vector<uint8_t> Bytes;
static void addAd(Bytes& a, uint8_t type, const Bytes& data) {
    a.push_back((uint8_t)(1 + data.size()));
    a.push_back(type);
    a.insert(a.end(), data.begin(), data.end());
}
// Manufacturer-specific data (AD 0xFF): company ID little-endian, then payload.
static void addMfg(Bytes& a, uint16_t cid, const Bytes& payload) {
    Bytes d{ (uint8_t)(cid & 0xFF), (uint8_t)((cid >> 8) & 0xFF) };
    d.insert(d.end(), payload.begin(), payload.end());
    addAd(a, 0xFF, d);
}
// 16-bit service DATA (AD 0x16): UUID little-endian, then payload. This is the only path
// Tile/Samsung are allowed to match on.
static void addSvcData(Bytes& a, uint16_t uuid, const Bytes& payload) {
    Bytes d{ (uint8_t)(uuid & 0xFF), (uint8_t)((uuid >> 8) & 0xFF) };
    d.insert(d.end(), payload.begin(), payload.end());
    addAd(a, 0x16, d);
}
// 16-bit service UUID LIST (AD 0x02 incomplete / 0x03 complete). Deliberately NOT harvested by
// the tracker parser: a bare finding UUID here is trivially spoofed.
static void addU16List(Bytes& a, uint16_t uuid, uint8_t adType = 0x03) {
    addAd(a, adType, { (uint8_t)(uuid & 0xFF), (uint8_t)((uuid >> 8) & 0xFF) });
}

// A real separated-from-owner Find My advert: 4C 00 12 19 <status> <22 key bytes> <bits> <hint>.
static Bytes airtagOffline() {
    Bytes payload{ 0x12, 0x19, 0x10 };
    for (int i = 0; i < 22; i++) payload.push_back((uint8_t)(0xA0 + i));   // fixed, never random
    payload.push_back(0x00); payload.push_back(0x00);
    Bytes a; addMfg(a, 0x004C, payload); return a;
}

// AirTags rotate their address, so the classifier must key on payload alone. Two fixed MACs: one
// with the IEEE locally-administered bit set (what acabInit calls randomAddr) and one without.
static const uint8_t MAC_RANDOM[6] = { 0xC6, 0x9A, 0x4D, 0x11, 0x8E, 0x37 };
static const uint8_t MAC_PUBLIC[6] = { 0x04, 0x99, 0xBB, 0x01, 0x02, 0x03 };

static bool run(const Bytes& a, AcabDetection* out, const uint8_t* mac = MAC_RANDOM) {
    memset(out, 0, sizeof(*out));
    return trackerClassifyBLE(mac, a.data(), a.size(), -71, out);
}

int main() {
    AcabDetection d;
    printf("\n=== tracker classifier regression ===\n");

    // -----------------------------------------------------------------------------------------
    // Toggle semantics. Trackers are everywhere (every bag, car, pair of earbuds), so this
    // detector ships OFF and the app turns it on. If the default ever flips to on, the log fills
    // with earbuds and the surveillance hits get buried - which is a product failure, not a crash,
    // so nothing else would catch it.
    // -----------------------------------------------------------------------------------------
    chkInt("default is OFF before anything calls a setter", trackerIsEnabled() ? 1 : 0, 0);
    chk("toggled off: a real AirTag advert is ignored", run(airtagOffline(), &d), false);

    // Desert mode classifies EVERY device, so it forces the specific detectors to run even while
    // toggled off - that way a tracker in the desert still reports as a tracker instead of being
    // downgraded to a generic "nearby device" row.
    gHostDesert = true;
    chk("toggled off + Desert on: still classifies", run(airtagOffline(), &d), true,
        d.confidence, 85, d.detail, "Apple Find My (offline)");
    gHostDesert = false;
    chk("Desert back off: ignored again", run(airtagOffline(), &d), false);

    // trackerRestoreEnabled() is what both firmware images call in setup(). The Preferences stub
    // persists within a binary now, but this one never writes the tracker key, so the store is
    // empty and this pins the never-been-set path: whatever main.cpp passes is what the board
    // boots with. The persisted round-trip is covered by test_axon/test_desert.
    trackerRestoreEnabled(false);
    chkInt("restore(false) with no stored value -> off", trackerIsEnabled() ? 1 : 0, 0);
    trackerRestoreEnabled(true);
    chkInt("restore(true) with no stored value -> on", trackerIsEnabled() ? 1 : 0, 1);
    trackerSetEnabled(false);
    chkInt("setEnabled(false) -> off", trackerIsEnabled() ? 1 : 0, 0);
    trackerSetEnabled(true);
    chkInt("setEnabled(true) -> on", trackerIsEnabled() ? 1 : 0, 1);

    // -----------------------------------------------------------------------------------------
    // Apple Find My. Everything downstream keys off these exact values.
    // -----------------------------------------------------------------------------------------
    printf("\n  -- Apple Find My --\n");
    chk("AirTag offline advert -> 85 / exact detail", run(airtagOffline(), &d), true,
        d.confidence, 85, d.detail, "Apple Find My (offline)");
    chkInt("  method is M_MFG_ID", d.method, M_MFG_ID);
    chkInt("  type is ACAB_TRACKER", d.type, ACAB_TRACKER);
    chkInt("  source is SRC_BLE", d.src, SRC_BLE);
    chkInt("  rssi passed through unmodified", d.rssi, -71);
    chkInt("  mac copied verbatim (rotating, never matched)", memcmp(d.mac, MAC_RANDOM, 6), 0);
    chkInt("  randomAddr set from the LAA bit", d.randomAddr ? 1 : 0, 1);
    // The address is irrelevant to the match, which is the whole point of payload matching: a tag
    // that rotates into a public-looking address must still be caught.
    chk("same payload on a public-looking MAC -> same hit", run(airtagOffline(), &d, MAC_PUBLIC), true,
        d.confidence, 85, d.detail, "Apple Find My (offline)");
    chkInt("  randomAddr clear on that one", d.randomAddr ? 1 : 0, 0);
    // Durability caps OUI-only matches on randomized addresses at 25. Find My is M_MFG_ID, so it
    // must survive that pass at full confidence - otherwise every AirTag (they all rotate) would
    // be down-weighted to below the alert threshold.
    run(airtagOffline(), &d); acabApplyDurability(&d);
    chkInt("  durability leaves M_MFG_ID at 85", d.confidence, 85);

    // CONCERN, LOCKED IN AS-IS: 0x19 is a LENGTH field describing 25 further bytes, and nothing
    // checks that those bytes are actually present. A 4-byte manufacturer block that merely claims
    // to be an offline Find My frame matches at 85. Harmless today (nothing reads past mfg[3]) but
    // it is a length field that overruns its own buffer, and any future code that decodes the key
    // material must bounds-check rather than trusting this byte.
    { Bytes a; addMfg(a, 0x004C, { 0x12, 0x19 });
      chk("declared len 0x19 with 0 bytes present -> STILL hits", run(a, &d), true,
          d.confidence, 85, d.detail, "Apple Find My (offline)"); }
    { Bytes a; addMfg(a, 0x004C, { 0x12 });     // mfgLen 3, one short of the 4 the check needs
      chk("mfg block one byte too short -> no hit", run(a, &d), false); }

    // Near misses. Each of these is a real Apple frame that must NOT fire.
    { Bytes a; addMfg(a, 0x004C, { 0x12, 0x02, 0x00 });
      chk("Find My NEARBY form (0x12 0x02) -> no hit", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x004C, { 0x07, 0x19, 0x01, 0x02 });
      chk("AirPods pairing 0x07 0x19: right len, wrong type", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x004C, { 0x19, 0x12, 0x00 });
      chk("type/len swapped (0x19 0x12) -> no hit", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x004C, { 0x02, 0x15, 0x00 });
      chk("iBeacon (0x02 0x15) -> no hit", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x004D, { 0x12, 0x19, 0x00 });
      chk("neighbouring company ID 0x004D -> no hit", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x004B, { 0x12, 0x19, 0x00 });
      chk("neighbouring company ID 0x004B -> no hit", run(a, &d), false); }
    // Company IDs are little-endian on the wire. Writing them big-endian is the classic regression
    // and it produces 0x4C00, which is not Apple.
    { Bytes a; addAd(a, 0xFF, { 0x00, 0x4C, 0x12, 0x19 });
      chk("company ID byte-swapped (0x4C00) -> no hit", run(a, &d), false); }

    // -----------------------------------------------------------------------------------------
    // Tile / Samsung. THE ASYMMETRY: service data + any 2-byte payload, no separation test, no
    // payload inspection at all, at a confidence below Apple's.
    // -----------------------------------------------------------------------------------------
    printf("\n  -- Tile / Samsung (deliberately looser than Apple) --\n");
    { Bytes a; addSvcData(a, 0xFEED, { 0x02, 0x00, 0x10, 0x20 });
      chk("Tile service data -> 65 / exact detail", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }
    chkInt("  method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);
    chkInt("  type is ACAB_TRACKER", d.type, ACAB_TRACKER);
    { Bytes a; addSvcData(a, 0xFD5A, { 0x01, 0x02, 0x03, 0x04 });
      chk("Samsung SmartTag -> 60 / exact detail", run(a, &d), true, d.confidence, 60, d.detail,
          "Samsung SmartTag"); }
    chkInt("  method is M_SERVICE_DATA", d.method, M_SERVICE_DATA);

    // THE ASYMMETRY ITSELF. Apple needs an exact byte; these two need only that two payload bytes
    // exist. Content is never examined, so all-zero and all-ones payloads both fire. If someone
    // adds an offline/separation test here to "match Apple", these two assertions fail first.
    { Bytes a; addSvcData(a, 0xFEED, { 0x00, 0x00 });
      chk("Tile with an all-zero payload -> still hits", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }
    { Bytes a; addSvcData(a, 0xFD5A, { 0xFF, 0xFF, 0xFF });
      chk("Samsung with an all-ones payload -> still hits", run(a, &d), true, d.confidence, 60, d.detail,
          "Samsung SmartTag"); }
    // The one thing they DO require: a real payload. TRK_MIN_SD is 4 counting the 2 UUID bytes, so
    // this is the exact boundary. It exists to reject a bare/empty entry a spoofer can set for free.
    { Bytes a; addSvcData(a, 0xFEED, { 0x01 });
      chk("Tile with 1 payload byte (len 3) -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEED, {});
      chk("Tile UUID as service data, no payload -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFD5A, { 0x01 });
      chk("Samsung with 1 payload byte -> no hit", run(a, &d), false); }
    // The spoof-prone path, deliberately unmatched: a finding UUID sitting in a plain UUID list
    // costs nothing to fake and collides with random consumer gear.
    { Bytes a; addU16List(a, 0xFEED, 0x03);
      chk("Tile UUID in a COMPLETE list (0x03) -> no hit", run(a, &d), false); }
    { Bytes a; addU16List(a, 0xFEED, 0x02);
      chk("Tile UUID in an INCOMPLETE list (0x02) -> no hit", run(a, &d), false); }
    { Bytes a; addU16List(a, 0xFD5A, 0x03);
      chk("Samsung UUID in a UUID list -> no hit", run(a, &d), false); }
    // Neighbouring service UUIDs. 0xFEEC is also assigned to Tile but is NOT in the table, so it
    // must not fire; that is current behaviour, noted here so a future addition is a deliberate
    // edit to the signature list rather than an accident.
    { Bytes a; addSvcData(a, 0xFEEC, { 0x01, 0x02 });
      chk("neighbouring 0xFEEC service data -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEEE, { 0x01, 0x02 });
      chk("neighbouring 0xFEEE service data -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFD5B, { 0x01, 0x02 });
      chk("neighbouring 0xFD5B service data -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFD59, { 0x01, 0x02 });
      chk("neighbouring 0xFD59 service data -> no hit", run(a, &d), false); }
    { Bytes a; addAd(a, 0x16, { 0xFE, 0xED, 0x01, 0x02 });   // big-endian on the wire = 0xEDFE
      chk("Tile UUID byte-swapped (0xEDFE) -> no hit", run(a, &d), false); }

    // -----------------------------------------------------------------------------------------
    // Match ORDER. Two different rules, and both are load-bearing.
    // -----------------------------------------------------------------------------------------
    printf("\n  -- ordering --\n");
    // Apple is checked before the service-data loop, so the highest-confidence signature wins when
    // an advert somehow carries both.
    { Bytes a = airtagOffline(); addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("Find My + Tile in one advert -> Apple wins", run(a, &d), true, d.confidence, 85, d.detail,
          "Apple Find My (offline)"); }
    // Between Tile and Samsung there is NO vendor ranking: the loop walks service-data elements in
    // advert order and returns the first that matches, so element position decides, not the 65-vs-60
    // confidence. Both directions are asserted so a reordering of the two if-statements is caught.
    { Bytes a; addSvcData(a, 0xFD5A, { 0x01, 0x02 }); addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("Samsung element first -> Samsung, not the 65", run(a, &d), true, d.confidence, 60, d.detail,
          "Samsung SmartTag"); }
    { Bytes a; addSvcData(a, 0xFEED, { 0x01, 0x02 }); addSvcData(a, 0xFD5A, { 0x01, 0x02 });
      chk("Tile element first -> Tile", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }

    // -----------------------------------------------------------------------------------------
    // Adversarial / malformed input. None of these may match, and none may read out of bounds.
    // -----------------------------------------------------------------------------------------
    printf("\n  -- adversarial --\n");
    { Bytes a;
      chk("empty advert -> no hit", run(a, &d), false); }
    { memset(&d, 0, sizeof(d));
      chk("null advert pointer -> no hit", trackerClassifyBLE(MAC_RANDOM, nullptr, 12, -71, &d), false); }
    { Bytes a{ 0xC8, 0x16, 0xED, 0xFE };   // claims 200 bytes, buffer holds 4
      chk("AD length overruns the buffer -> no hit", run(a, &d), false); }
    { Bytes a{ 0xC8, 0xFF, 0x4C, 0x00, 0x12, 0x19 };
      chk("overrunning length on a Find My block -> no hit", run(a, &d), false); }
    // Truncation is order-sensitive: a bad element ABORTS the walk, so anything behind it is never
    // seen. Both halves are pinned because "parse what you can" and "stop at the first bad element"
    // are both defensible and only one of them is what ships.
    { Bytes a{ 0xC8, 0x16, 0xED, 0xFE }; addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("bad element BEFORE a real Tile -> hides it", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEED, { 0x01, 0x02 }); a.push_back(0xC8); a.push_back(0x16);
      chk("bad element AFTER a real Tile -> still hits", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }
    // A zero length byte also ends the walk. Real adverts are zero-padded at the END, so this is
    // fine in practice, but it does mean a leading zero pad blinds the detector.
    { Bytes a{ 0x00 }; addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("leading zero-length AD blinds the parser", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEED, { 0x01, 0x02 }); a.push_back(0x00);
      chk("single trailing pad byte tolerated", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }
    // CONCERN, LOCKED IN AS-IS: only the FIRST manufacturer element is kept, so prepending a junk
    // mfg block hides a genuine AirTag behind it. Cheap for a spoofer, and the fix (scan every 0xFF
    // element) is not what ships today.
    { Bytes a; addMfg(a, 0xFFFF, { 0x00 });
      Bytes real = airtagOffline(); a.insert(a.end(), real.begin(), real.end());
      chk("decoy mfg block hides a real Find My frame", run(a, &d), false); }
    // The service-data table is 12 slots. Both sides of the bound are pinned: an off-by-one in the
    // guard is either a silent detection hole or a stack smash, and neither shows up in a build.
    { Bytes a; for (int i = 0; i < 11; i++) addSvcData(a, 0xFEEC, {});   // len-2 fillers, unmatchable
      addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("Tile in the 12th service-data slot -> hits", run(a, &d), true, d.confidence, 65, d.detail, "Tile"); }
    { Bytes a; for (int i = 0; i < 12; i++) addSvcData(a, 0xFEEC, {});
      addSvcData(a, 0xFEED, { 0x01, 0x02 });
      chk("Tile in the 13th slot -> dropped, no hit", run(a, &d), false); }
    // Ordinary traffic must stay silent.
    { Bytes a; addAd(a, 0x09, { 'P', 'i', 'x', 'e', 'l' }); addU16List(a, 0x180F);
      chk("plain named device with a battery service", run(a, &d), false); }
    { Bytes a; addMfg(a, 0x0075, { 0x42, 0x04, 0x01 });
      chk("Samsung Electronics company ID 0x0075 -> no hit", run(a, &d), false); }

    // ---- Google Find Hub / FMDN (Eddystone UUID 0xFEAA, frame-type discriminated) -------------
    // The NEGATIVE cases here ARE the feature. 0xFEAA is Eddystone's namespace, shared with every
    // retail beacon, and the near-owner 0x40 form comes off provisioned earbuds sitting next to
    // their owner while rotating its MAC every ~17 min. If any of the "no hit" rows below ever
    // flips, this detector has become an unsilenceable false-positive machine inside the feature
    // people use to find out whether they are being followed. See GOOGLE_FHN_SVC in the detector.
    auto fhn = [](uint8_t type, int eidLen) {
        Bytes p; p.push_back(type);
        for (int i = 0; i < eidLen; i++) p.push_back((uint8_t)(0xA0 + i));
        p.push_back(0x00);                     // hashed flags (mandatory in UT mode)
        return p;
    };
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x41, 20));
      chk("FHN 0x41 separated, 20B EID -> hits", run(a, &d), true,
          d.confidence, 65, d.detail, "Google Find Hub (separated)"); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x41, 32));
      chk("FHN 0x41 separated, 32B EID -> hits", run(a, &d), true,
          d.confidence, 65, d.detail, "Google Find Hub (separated)"); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x40, 20));
      chk("FHN 0x40 NEAR-OWNER -> must NOT hit (earbuds beside their owner)", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x40, 32));
      chk("FHN 0x40 near-owner, 32B EID -> must NOT hit", run(a, &d), false); }
    // Every DEFINED Eddystone frame must stay silent: UID 0x00, URL 0x10, TLM 0x20, EID 0x30.
    // These are ordinary retail beacons and the 0x4x high nibble is what separates us from them.
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x00, 20));
      chk("Eddystone UID frame -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x10, 20));
      chk("Eddystone URL frame -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x20, 20));
      chk("Eddystone TLM frame -> no hit", run(a, &d), false); }
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x30, 20));
      chk("Eddystone EID frame -> no hit", run(a, &d), false); }
    // Length is PINNED, not ranged. A 0x41 at any other length is spec-noncompliant; if this row
    // ever fails it means real hardware disagrees with the spec and the gate is costing a hit.
    { Bytes a; addSvcData(a, 0xFEAA, fhn(0x41, 19));
      chk("FHN 0x41 at a non-spec length -> no hit", run(a, &d), false); }
    { Bytes a; Bytes p; p.push_back(0x41); for (int i = 0; i < 20; i++) p.push_back(0xA0);
      addSvcData(a, 0xFEAA, p);   // 20B EID but NO hashed-flags byte -> sdLen 23, not 24
      chk("FHN 0x41 missing the mandatory flags byte -> no hit", run(a, &d), false); }
    // A bare UUID-list entry must never match, same rule the Tile/Samsung rows already follow.
    { Bytes a; addU16List(a, 0xFEAA);
      chk("0xFEAA in a bare UUID list -> no hit", run(a, &d), false); }

    printf("\n  %s (%d failure%s)\n\n", failures ? "REGRESSION DETECTED" : "all good",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
