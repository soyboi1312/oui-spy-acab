/*
 * ACAB - capture-only ALPR vendor-prefix candidates.
 *
 * These IEEE assignments are discovery aids, not production signatures. A corporate
 * registration establishes who owns an address block, but it does not establish that an
 * ALPR product actually transmits from that block. The capture firmware calls these out so a
 * bracketed visit can tie a prefix to visually confirmed hardware and record the frame mode,
 * advertised names, and neighboring signals before anyone proposes a shipping detector.
 *
 * Prefix length is load-bearing. MA-L assignments match 24 bits, MA-M assignments match 28,
 * and MA-S plus legacy IAB assignments match 36. Widening a 28- or 36-bit assignment to an OUI
 * would attribute neighboring registrants to the wrong vendor.
 *
 * Source: IEEE Registration Authority public assignment CSV files, checked 2026-08-23:
 *   MA-L  https://standards-oui.ieee.org/oui/oui.csv
 *   MA-M  https://standards-oui.ieee.org/oui28/mam.csv
 *   MA-S  https://standards-oui.ieee.org/oui36/oui36.csv
 *   IAB   https://standards-oui.ieee.org/iab/iab.csv
 * Full product-scope notes are in docs/signatures.md.
 */
#ifndef ACAB_ALPR_CANDIDATES_H
#define ACAB_ALPR_CANDIDATES_H

#ifndef ACAB_CAPTURE_BUILD
#error "alpr_candidates.h is capture-only and must never be included in a shipping build"
#endif

#include <stdint.h>
#include <stddef.h>
#include "oui_prefix.h"   // shared width-aware matcher; also backs the drone vendor-OUI fallback

enum AcabAlprCandidateRegistry : uint8_t {
    ACAB_ALPR_MA_L = 1,
    ACAB_ALPR_MA_M = 2,
    ACAB_ALPR_MA_S = 3,
    ACAB_ALPR_IAB  = 4,
};

struct AcabAlprCandidate {
    uint8_t     prefix[5];
    uint8_t     prefixBits;
    uint8_t     registry;
    const char* tag;          // compact capture-log token
    const char* vendor;       // exact IEEE registrant label; compact log identity lives in tag
};

// Width encoding comes from oui_prefix.h so this table cannot drift from the matcher.
// A legacy IAB is MA-S-shaped (36 bits); only the registry label differs.
#define ALPR_MAL(a, b, c, tagName, vendorName) \
    { ACAB_OUI_MAL(a, b, c), ACAB_ALPR_MA_L, (tagName), (vendorName) }
#define ALPR_MAM(a, b, c, nibble, tagName, vendorName) \
    { ACAB_OUI_MAM(a, b, c, nibble), ACAB_ALPR_MA_M, (tagName), (vendorName) }
#define ALPR_MAS(a, b, c, d, nibble, tagName, vendorName) \
    { ACAB_OUI_MAS(a, b, c, d, nibble), ACAB_ALPR_MA_S, (tagName), (vendorName) }
#define ALPR_IAB(a, b, c, d, nibble, tagName, vendorName) \
    { ACAB_OUI_MAS(a, b, c, d, nibble), ACAB_ALPR_IAB, (tagName), (vendorName) }

static const AcabAlprCandidate ACAB_ALPR_CANDIDATE[] = {
    // IEEE MA-L registrant: Avigilon Alta.
    ALPR_MAL(0x70, 0x1a, 0xd5, "AVIGILON-ALTA", "Avigilon Alta"),
    // IEEE MA-M registrant: Ekin Teknoloji San ve Tic A.S.
    ALPR_MAM(0x04, 0xc3, 0xe6, 0x09, "EKIN", "Ekin Teknoloji San ve Tic A.S."),

    // IEEE MA-L and IAB registrant: Genetec Inc.
    ALPR_MAL(0x00, 0xbf, 0x15, "GENETEC-A", "Genetec Inc."),
    ALPR_MAL(0x0c, 0xbf, 0x15, "GENETEC-B", "Genetec Inc."),
    ALPR_IAB(0x00, 0x50, 0xc2, 0xbe, 0x07, "GENETEC-IAB", "Genetec Inc."),

    // IEEE MA-L registrants: JENOPTIK and JENOPTIK Advanced Systems GmbH, respectively.
    ALPR_MAL(0x00, 0x04, 0x4c, "JENOPTIK-A", "JENOPTIK"),
    ALPR_MAL(0x48, 0xe3, 0xc3, "JENOPTIK-B", "JENOPTIK Advanced Systems GmbH"),
    // IEEE MA-L registrant: KAPSCH AG.
    ALPR_MAL(0x00, 0xe0, 0x6a, "KAPSCH", "KAPSCH AG"),

    // IEEE MA-L registrant: Elsag Datamat spa. IEEE MA-S registrant: ELSAG.
    ALPR_MAL(0x00, 0x40, 0xde, "ELSAG-LEGACY", "Elsag Datamat spa"),
    ALPR_MAS(0x70, 0xb3, 0xd5, 0x1c, 0x05, "ELSAG-MAS", "ELSAG"),

    // IEEE MA-S registrant: Selex ES Inc. Selex is an ELSAG/Leonardo predecessor. Keep these
    // separately tagged so a capture cannot silently turn corporate history into proof that
    // current ELSAG hardware uses them.
    ALPR_MAS(0x70, 0xb3, 0xd5, 0x52, 0x01, "SELEX-A", "Selex ES Inc."),
    ALPR_MAS(0x70, 0xb3, 0xd5, 0xf5, 0x0e, "SELEX-B", "Selex ES Inc."),

    // IEEE MA-L registrants: Neology and Ubicquia LLC, respectively.
    ALPR_MAL(0x00, 0x17, 0x3d, "NEOLOGY", "Neology"),
    ALPR_MAL(0x94, 0x7b, 0xbe, "UBICQUIA", "Ubicquia LLC"),
};
static const size_t ACAB_ALPR_CANDIDATE_COUNT =
    sizeof(ACAB_ALPR_CANDIDATE) / sizeof(ACAB_ALPR_CANDIDATE[0]);

static inline bool acabAlprCandidatePrefixMatches(const AcabAlprCandidate& candidate,
                                                   const uint8_t mac[6]) {
    // Width dispatch, LAA guard, and unknown-width rejection all live in the shared matcher.
    return acabOuiPrefixMatches(candidate.prefix, candidate.prefixBits, mac);
}

static inline const AcabAlprCandidate* acabAlprCandidateMatch(const uint8_t mac[6]) {
    if (!mac) return nullptr;
    for (size_t i = 0; i < ACAB_ALPR_CANDIDATE_COUNT; i++)
        if (acabAlprCandidatePrefixMatches(ACAB_ALPR_CANDIDATE[i], mac))
            return &ACAB_ALPR_CANDIDATE[i];
    return nullptr;
}

static inline const char* acabAlprCandidateRegistryLabel(uint8_t registry) {
    switch (registry) {
        case ACAB_ALPR_MA_L: return "MA-L";
        case ACAB_ALPR_MA_M: return "MA-M";
        case ACAB_ALPR_MA_S: return "MA-S";
        case ACAB_ALPR_IAB:  return "IAB";
        default:             return "?";
    }
}

#undef ALPR_MAL
#undef ALPR_MAM
#undef ALPR_MAS
#undef ALPR_IAB

#endif // ACAB_ALPR_CANDIDATES_H
