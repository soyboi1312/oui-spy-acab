/*
 * ACAB - width-aware IEEE registered-prefix matching, shared by every prefix table.
 *
 * Prefix length is load-bearing. An MA-L assignment covers 24 bits, an MA-M 28, and an
 * MA-S (or legacy IAB) 36. Treating a 28-bit assignment as a three-byte OUI widens it
 * sixteenfold and attributes fifteen unrelated registrants to the watched vendor; a
 * 36-bit assignment widens 4096x.
 *
 * This is the ONE implementation of that rule. The drone vendor-OUI fallback
 * (drone_detect.cpp) and the capture-only ALPR candidate table (alpr_candidates.h) both
 * used to carry private copies, and the copies had already diverged: on an unknown width
 * the drone copy fell back to a 24-bit compare while the ALPR copy rejected. A width bug
 * fixed in one would never have reached the other. Both now call this matcher.
 */
#ifndef ACAB_OUI_PREFIX_H
#define ACAB_OUI_PREFIX_H

#include <stdint.h>

// Initializers for the leading { prefix[5], prefixBits } member pair that every prefix-table
// row struct starts with. The rows stay per-table structs (the ALPR rows also carry a
// registry, capture tag, and registrant label that scanner code reads by name), so these
// macros share the width encoding rather than the whole row: the unused prefix tail is
// zero-filled, and an MA-M/MA-S trailing nibble lands in the HIGH nibble of its byte,
// exactly how acabOuiPrefixMatches() masks it.
#define ACAB_OUI_MAL(a, b, c) \
    { (a), (b), (c), 0x00, 0x00 }, 24
#define ACAB_OUI_MAM(a, b, c, nibble) \
    { (a), (b), (c), (uint8_t)((nibble) << 4), 0x00 }, 28
#define ACAB_OUI_MAS(a, b, c, d, nibble) \
    { (a), (b), (c), (d), (uint8_t)((nibble) << 4) }, 36

// True when `mac` sits inside the registered block `prefix` / `prefixBits`.
//  - A null MAC never matches.
//  - A locally-administered / randomized MAC (mac[0] bit 0x02) never matches: it carries
//    no real IEEE assignment, so a byte coincidence there says nothing about the vendor.
//  - An UNKNOWN width never matches. Falling back to a 24-bit compare would be the silent
//    16x / 4096x widening described above dressed up as a default; refusing to match is
//    the only failure mode that cannot misattribute a bystander's device.
static inline bool acabOuiPrefixMatches(const uint8_t prefix[5], uint8_t prefixBits,
                                        const uint8_t mac[6]) {
    if (!mac || (mac[0] & 0x02)) return false;
    if (mac[0] != prefix[0] || mac[1] != prefix[1] || mac[2] != prefix[2]) return false;
    if (prefixBits == 24) return true;
    if (prefixBits == 28) return (mac[3] & 0xf0) == prefix[3];
    if (prefixBits == 36)
        return mac[3] == prefix[3] && (mac[4] & 0xf0) == prefix[4];
    return false;
}

#endif // ACAB_OUI_PREFIX_H
