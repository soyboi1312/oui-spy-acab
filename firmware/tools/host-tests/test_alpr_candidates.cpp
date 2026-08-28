// Host regression test for the capture-only ALPR registered-prefix watchlist.
//
// This suite tests the exact bit width as much as the positive rows. Treating Ekin's MA-M or
// the Genetec/ELSAG/Selex 36-bit assignments as ordinary 24-bit OUIs would be a silent 16x or
// 4096x widening, which is precisely what this capture-first table is meant to prevent.
#define ACAB_CAPTURE_BUILD 1
#include "alpr_candidates.h"

#include <stdio.h>
#include <string.h>

static int failures = 0;

static void chk(const char* name, bool ok) {
    printf("  %-70s %s\n", name, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
}

static bool misses(const uint8_t mac[6]) { return acabAlprCandidateMatch(mac) == nullptr; }

struct ExpectedRange {
    const char* tag;
    uint8_t registry;
    uint8_t bits;
    uint8_t first[6];
    uint8_t last[6];
    uint8_t below[6];
    uint8_t above[6];
};

// Independent boundary fixtures. Keep all four addresses literal: computing these from the table
// under test would let a widened prefix change both the implementation and its expected answer.
static const ExpectedRange EXPECTED[] = {
    { "AVIGILON-ALTA", ACAB_ALPR_MA_L, 24,
      {0x70,0x1a,0xd5,0x00,0x00,0x00}, {0x70,0x1a,0xd5,0xff,0xff,0xff},
      {0x70,0x1a,0xd4,0xff,0xff,0xff}, {0x70,0x1a,0xd6,0x00,0x00,0x00} },
    { "EKIN", ACAB_ALPR_MA_M, 28,
      {0x04,0xc3,0xe6,0x90,0x00,0x00}, {0x04,0xc3,0xe6,0x9f,0xff,0xff},
      {0x04,0xc3,0xe6,0x8f,0xff,0xff}, {0x04,0xc3,0xe6,0xa0,0x00,0x00} },
    { "GENETEC-A", ACAB_ALPR_MA_L, 24,
      {0x00,0xbf,0x15,0x00,0x00,0x00}, {0x00,0xbf,0x15,0xff,0xff,0xff},
      {0x00,0xbf,0x14,0xff,0xff,0xff}, {0x00,0xbf,0x16,0x00,0x00,0x00} },
    { "GENETEC-B", ACAB_ALPR_MA_L, 24,
      {0x0c,0xbf,0x15,0x00,0x00,0x00}, {0x0c,0xbf,0x15,0xff,0xff,0xff},
      {0x0c,0xbf,0x14,0xff,0xff,0xff}, {0x0c,0xbf,0x16,0x00,0x00,0x00} },
    { "GENETEC-IAB", ACAB_ALPR_IAB, 36,
      {0x00,0x50,0xc2,0xbe,0x70,0x00}, {0x00,0x50,0xc2,0xbe,0x7f,0xff},
      {0x00,0x50,0xc2,0xbe,0x6f,0xff}, {0x00,0x50,0xc2,0xbe,0x80,0x00} },
    { "JENOPTIK-A", ACAB_ALPR_MA_L, 24,
      {0x00,0x04,0x4c,0x00,0x00,0x00}, {0x00,0x04,0x4c,0xff,0xff,0xff},
      {0x00,0x04,0x4b,0xff,0xff,0xff}, {0x00,0x04,0x4d,0x00,0x00,0x00} },
    { "JENOPTIK-B", ACAB_ALPR_MA_L, 24,
      {0x48,0xe3,0xc3,0x00,0x00,0x00}, {0x48,0xe3,0xc3,0xff,0xff,0xff},
      {0x48,0xe3,0xc2,0xff,0xff,0xff}, {0x48,0xe3,0xc4,0x00,0x00,0x00} },
    { "KAPSCH", ACAB_ALPR_MA_L, 24,
      {0x00,0xe0,0x6a,0x00,0x00,0x00}, {0x00,0xe0,0x6a,0xff,0xff,0xff},
      {0x00,0xe0,0x69,0xff,0xff,0xff}, {0x00,0xe0,0x6b,0x00,0x00,0x00} },
    { "ELSAG-LEGACY", ACAB_ALPR_MA_L, 24,
      {0x00,0x40,0xde,0x00,0x00,0x00}, {0x00,0x40,0xde,0xff,0xff,0xff},
      {0x00,0x40,0xdd,0xff,0xff,0xff}, {0x00,0x40,0xdf,0x00,0x00,0x00} },
    { "ELSAG-MAS", ACAB_ALPR_MA_S, 36,
      {0x70,0xb3,0xd5,0x1c,0x50,0x00}, {0x70,0xb3,0xd5,0x1c,0x5f,0xff},
      {0x70,0xb3,0xd5,0x1c,0x4f,0xff}, {0x70,0xb3,0xd5,0x1c,0x60,0x00} },
    { "SELEX-A", ACAB_ALPR_MA_S, 36,
      {0x70,0xb3,0xd5,0x52,0x10,0x00}, {0x70,0xb3,0xd5,0x52,0x1f,0xff},
      {0x70,0xb3,0xd5,0x52,0x0f,0xff}, {0x70,0xb3,0xd5,0x52,0x20,0x00} },
    { "SELEX-B", ACAB_ALPR_MA_S, 36,
      {0x70,0xb3,0xd5,0xf5,0xe0,0x00}, {0x70,0xb3,0xd5,0xf5,0xef,0xff},
      {0x70,0xb3,0xd5,0xf5,0xdf,0xff}, {0x70,0xb3,0xd5,0xf5,0xf0,0x00} },
    { "NEOLOGY", ACAB_ALPR_MA_L, 24,
      {0x00,0x17,0x3d,0x00,0x00,0x00}, {0x00,0x17,0x3d,0xff,0xff,0xff},
      {0x00,0x17,0x3c,0xff,0xff,0xff}, {0x00,0x17,0x3e,0x00,0x00,0x00} },
    { "UBICQUIA", ACAB_ALPR_MA_L, 24,
      {0x94,0x7b,0xbe,0x00,0x00,0x00}, {0x94,0x7b,0xbe,0xff,0xff,0xff},
      {0x94,0x7b,0xbd,0xff,0xff,0xff}, {0x94,0x7b,0xbf,0x00,0x00,0x00} },
};
static const size_t EXPECTED_COUNT = sizeof(EXPECTED) / sizeof(EXPECTED[0]);
static const char* EXPECTED_REGISTRANT[] = {
    "Avigilon Alta",
    "Ekin Teknoloji San ve Tic A.S.",
    "Genetec Inc.",
    "Genetec Inc.",
    "Genetec Inc.",
    "JENOPTIK",
    "JENOPTIK Advanced Systems GmbH",
    "KAPSCH AG",
    "Elsag Datamat spa",
    "ELSAG",
    "Selex ES Inc.",
    "Selex ES Inc.",
    "Neology",
    "Ubicquia LLC",
};
static const size_t EXPECTED_REGISTRANT_COUNT =
    sizeof(EXPECTED_REGISTRANT) / sizeof(EXPECTED_REGISTRANT[0]);

int main() {
    printf("\n=== capture-only ALPR prefix regression ===\n");

    chk("table has exactly 14 sourced assignments", ACAB_ALPR_CANDIDATE_COUNT == 14);
    chk("independent boundary fixture covers every table row",
        EXPECTED_COUNT == ACAB_ALPR_CANDIDATE_COUNT);
    chk("registrant fixture covers every table row",
        EXPECTED_REGISTRANT_COUNT == ACAB_ALPR_CANDIDATE_COUNT);
    chk("null MAC is rejected", acabAlprCandidateMatch(nullptr) == nullptr);
    const uint8_t locallyAdministered[6] = { 0x72,0x1a,0xd5,0x01,0x02,0x03 };
    chk("locally administered MAC is rejected even beside a listed prefix",
        misses(locallyAdministered));

    // Pin the explicit LAA guard itself. Flipping a real prefix from 70 to 72 would already make
    // the table lookup miss, so it cannot prove the guard exists. This synthetic candidate and
    // matching synthetic MAC would match byte-for-byte if the `(mac[0] & 0x02)` check vanished.
    const AcabAlprCandidate syntheticLaa = {
        {0x72,0x1a,0xd5,0x00,0x00}, 24, ACAB_ALPR_MA_L, "TEST-LAA", "test only"
    };
    chk("prefix matcher independently rejects a matching locally administered range",
        !acabAlprCandidatePrefixMatches(syntheticLaa, locallyAdministered));

    // Width dispatch lives in the shared matcher (oui_prefix.h), which also backs the drone
    // vendor-OUI fallback, so these pins defend BOTH paths. An unrecognized width must REJECT,
    // never quietly fall back to a 24-bit compare - that fallback is exactly the silent 16x
    // widening this suite exists to prevent, and it is the direction the drone path's private
    // copy had drifted before the matcher was unified.
    const uint8_t widthPrefix[5] = { 0x70, 0x1a, 0xd5, 0x00, 0x00 };
    const uint8_t widthMac[6]    = { 0x70, 0x1a, 0xd5, 0x01, 0x02, 0x03 };
    chk("shared matcher accepts the declared 24-bit width",
        acabOuiPrefixMatches(widthPrefix, 24, widthMac));
    chk("shared matcher rejects unknown widths instead of widening to 24 bits",
        !acabOuiPrefixMatches(widthPrefix, 0, widthMac) &&
        !acabOuiPrefixMatches(widthPrefix, 27, widthMac) &&
        !acabOuiPrefixMatches(widthPrefix, 32, widthMac) &&
        !acabOuiPrefixMatches(widthPrefix, 48, widthMac));
    chk("shared matcher rejects a null MAC at any width",
        !acabOuiPrefixMatches(widthPrefix, 24, nullptr));

    size_t mal = 0, mam = 0, mas = 0, iab = 0;
    for (size_t i = 0; i < ACAB_ALPR_CANDIDATE_COUNT; i++) {
        const AcabAlprCandidate& c = ACAB_ALPR_CANDIDATE[i];
        const ExpectedRange& e = EXPECTED[i];
        char name[128];
        snprintf(name, sizeof(name), "%s identity, registrant, registry and width stay pinned", e.tag);
        chk(name, !strcmp(c.tag, e.tag) && c.registry == e.registry && c.prefixBits == e.bits &&
                  !strcmp(c.vendor, EXPECTED_REGISTRANT[i]) &&
                  !memcmp(c.prefix, e.first, sizeof(c.prefix)));
        snprintf(name, sizeof(name), "%s inclusive first address matches", e.tag);
        chk(name, acabAlprCandidateMatch(e.first) == &c);
        snprintf(name, sizeof(name), "%s inclusive last address matches", e.tag);
        chk(name, acabAlprCandidateMatch(e.last) == &c);
        snprintf(name, sizeof(name), "%s immediate lower boundary misses", e.tag);
        chk(name, misses(e.below));
        snprintf(name, sizeof(name), "%s immediate upper boundary misses", e.tag);
        chk(name, misses(e.above));
        const bool canonical =
            (c.prefixBits == 24 && c.prefix[3] == 0 && c.prefix[4] == 0) ||
            (c.prefixBits == 28 && (c.prefix[3] & 0x0f) == 0 && c.prefix[4] == 0) ||
            (c.prefixBits == 36 && (c.prefix[4] & 0x0f) == 0);
        snprintf(name, sizeof(name), "%s stores every unmasked bit as zero", e.tag);
        chk(name, canonical);
        if (c.registry == ACAB_ALPR_MA_L) mal++;
        if (c.registry == ACAB_ALPR_MA_M) mam++;
        if (c.registry == ACAB_ALPR_MA_S) mas++;
        if (c.registry == ACAB_ALPR_IAB)  iab++;
    }
    chk("registry split remains 9 MA-L, 1 MA-M, 3 MA-S, 1 IAB",
        mal == 9 && mam == 1 && mas == 3 && iab == 1);

    bool uniqueTags = true;
    bool nonOverlapping = true;
    for (size_t i = 0; i < ACAB_ALPR_CANDIDATE_COUNT; i++) {
        for (size_t j = i + 1; j < ACAB_ALPR_CANDIDATE_COUNT; j++) {
            if (!strcmp(ACAB_ALPR_CANDIDATE[i].tag, ACAB_ALPR_CANDIDATE[j].tag))
                uniqueTags = false;
            if (acabAlprCandidatePrefixMatches(ACAB_ALPR_CANDIDATE[i], EXPECTED[j].first) ||
                acabAlprCandidatePrefixMatches(ACAB_ALPR_CANDIDATE[i], EXPECTED[j].last) ||
                acabAlprCandidatePrefixMatches(ACAB_ALPR_CANDIDATE[j], EXPECTED[i].first) ||
                acabAlprCandidatePrefixMatches(ACAB_ALPR_CANDIDATE[j], EXPECTED[i].last))
                nonOverlapping = false;
        }
    }
    chk("every compact capture tag is unique", uniqueTags);
    chk("candidate prefix ranges are pairwise non-overlapping", nonOverlapping);

    // Ekin 04:C3:E6:9/28. The low nibble is device space; either neighboring high nibble misses.
    const uint8_t ekinLo[6] = { 0x04,0xc3,0xe6,0x9f,0xaa,0x01 };
    const uint8_t ekinPrev[6] = { 0x04,0xc3,0xe6,0x8f,0xaa,0x01 };
    const uint8_t ekinNext[6] = { 0x04,0xc3,0xe6,0xaf,0xaa,0x01 };
    chk("Ekin MA-M accepts any low fourth-byte nibble", acabAlprCandidateMatch(ekinLo) != nullptr);
    chk("Ekin MA-M does not widen into preceding /28", misses(ekinPrev));
    chk("Ekin MA-M does not widen into following /28", misses(ekinNext));

    // Genetec legacy IAB 00:50:C2:BE:7/36. The final low nibble is device space only.
    const uint8_t genIab[6] = { 0x00,0x50,0xc2,0xbe,0x7f,0x02 };
    const uint8_t genIabPrev[6] = { 0x00,0x50,0xc2,0xbe,0x6f,0x02 };
    const uint8_t genIabNext[6] = { 0x00,0x50,0xc2,0xbe,0x8f,0x02 };
    const AcabAlprCandidate* gen = acabAlprCandidateMatch(genIab);
    chk("Genetec IAB exact /36 matches", gen && gen->registry == ACAB_ALPR_IAB);
    chk("Genetec IAB does not widen into preceding /36", misses(genIabPrev));
    chk("Genetec IAB does not widen into following /36", misses(genIabNext));

    // The three ELSAG/Selex rows share 70:B3:D5. A three-byte match would claim thousands of
    // unrelated assignments, so an unlisted member of that base must miss.
    const uint8_t elsag[6] = { 0x70,0xb3,0xd5,0x1c,0x5a,0x03 };
    const uint8_t selex1[6] = { 0x70,0xb3,0xd5,0x52,0x1b,0x04 };
    const uint8_t selex2[6] = { 0x70,0xb3,0xd5,0xf5,0xef,0x05 };
    const uint8_t sharedBaseOnly[6] = { 0x70,0xb3,0xd5,0x00,0x00,0x06 };
    const uint8_t elsagNeighbor[6] = { 0x70,0xb3,0xd5,0x1c,0x4f,0x07 };
    chk("direct ELSAG MA-S matches", acabAlprCandidateMatch(elsag) != nullptr);
    chk("first Selex predecessor MA-S matches", acabAlprCandidateMatch(selex1) != nullptr);
    chk("second Selex predecessor MA-S matches", acabAlprCandidateMatch(selex2) != nullptr);
    chk("shared 70:B3:D5 base alone never matches", misses(sharedBaseOnly));
    chk("ELSAG neighboring MA-S assignment never matches", misses(elsagNeighbor));

    // Deliberate exclusions. App-side display lookups or parent-company ownership are not capture
    // evidence for an ALPR product, and Ava Security is held out pending direct Avigilon evidence.
    const uint8_t ubiquiti1[6] = { 0x94,0x2a,0x6f,0x01,0x02,0x03 };
    const uint8_t ubiquiti2[6] = { 0xf4,0xe2,0xc6,0x01,0x02,0x03 };
    const uint8_t motorola[6]  = { 0x4c,0xcc,0x34,0x01,0x02,0x03 };
    const uint8_t avaSecurity[6] = { 0xd0,0x3d,0x52,0x01,0x02,0x03 };
    chk("Ubiquiti display OUI 94:2A:6F is excluded", misses(ubiquiti1));
    chk("Ubiquiti display OUI F4:E2:C6 is excluded", misses(ubiquiti2));
    chk("Motorola parent OUI is excluded", misses(motorola));
    chk("Ava Security D0:3D:52 is held out", misses(avaSecurity));

    chk("registry labels are exact",
        !strcmp(acabAlprCandidateRegistryLabel(ACAB_ALPR_MA_L), "MA-L") &&
        !strcmp(acabAlprCandidateRegistryLabel(ACAB_ALPR_MA_M), "MA-M") &&
        !strcmp(acabAlprCandidateRegistryLabel(ACAB_ALPR_MA_S), "MA-S") &&
        !strcmp(acabAlprCandidateRegistryLabel(ACAB_ALPR_IAB), "IAB") &&
        !strcmp(acabAlprCandidateRegistryLabel(0xff), "?"));

    printf("\n%s (%d failure%s)\n", failures ? "FAIL" : "ALL PASS", failures,
           failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
