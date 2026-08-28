/*
 * ACAB - body-worn camera signatures, two vendors (clean-room).
 *
 * Provenance is PER VALUE, not per file. This banner used to say "both values are public /
 * own-capture, not ported", which stopped being true when the Utility BodyWorn signature
 * landed. Read the citation on each value:
 *   - Axon OUI 00:25:DF and the "BWCDEVICE" tag: public IEEE registry and our own field
 *     capture. Not ported from anyone.
 *   - Utility Inc. "BodyWorn Remote" NAME: third-party field observation, taken from the
 *     community nite-oui-collection (nitekry) and credited in CREDITS.md.
 *   - Utility Inc. OUIs 00:09:BC / 00:16:ED: public IEEE registry.
 * See docs/signatures.md.
 */
#ifndef ACAB_AXON_SIGNATURES_H
#define ACAB_AXON_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// MAC OUI: Axon Enterprise, Inc. (formerly TASER International) - their sole IEEE
// block (MA-L, 2010). Used literally as {0x00,0x25,0xdf} in axon_detect.cpp.
//   src: IEEE OUI registry -> https://maclookup.app/macaddress/0025DF

// ASCII tag a real Axon body cam self-identifies with in its BLE service data. In
// the field capture it rode inside a 128-bit service-UUID (AD 0x21) which, being
// little-endian, only reads as "AXJANUSBWCDEVICE" when the bytes are reversed - so
// the matcher searches both byte orders (see acabBytesContainAscii in ascii_match.h).
// The tag is a STANDALONE match (MAC-independent, so it survives BLE MAC
// randomization); the OUI is the weaker fallback for un-tagged / other Axon gear.
//   src: own field capture, 2026-06.
#define AXON_BWC_PAYLOAD  "BWCDEVICE"

// ---------------------------------------------------------------------------
// Utility Inc. "BodyWorn" police body-cam system (a different brand, same body-cam
// category as Axon). Field-observed BLE signature: the system's activation remote
// advertises a Complete Local Name containing "BodyWorn Remote" on Utility's public
// OUI 00:09:BC (Utility also holds 00:16:ED). The advertised NAME is the strong,
// MAC-independent signal (like Axon's BWCDEVICE tag); the OUI is the weaker fallback.
// A vendor 128-bit UUID (0cf1640c-1c36-4c68-b411-08f344e1d6d1) exists but only appears
// post-connect, so it is NOT usable in passive scanning.
//   src: nite-oui-collection (nitekry), nRF-Connect capture 2025-08 ->
//        https://github.com/nitekry/nite-oui-collection (groups/le, capture_filters)
#define UTIL_BWC_NAME  "BodyWorn Remote"

// Utility Inc. public OUI blocks, the WEAK fallback behind the name match above. Kept
// here rather than inline in axon_detect.cpp so every OUI in the project lives in a
// signatures header next to its citation, matching the clean-room provenance discipline
// used by flock_signatures.h and bodycam_vendor_signatures.h. Weak on purpose: Utility makes
// other gear on these blocks, so an OUI-only hit is confidence 70 vs 85 for the name.
//   src: IEEE OUI registry (both MA-L, registrant "Utility, Inc." / "Utility Inc")
static const uint8_t UTIL_BWC_OUI[][3] = {
    { 0x00, 0x09, 0xbc },   // 00:09:BC  Utility Inc.
    { 0x00, 0x16, 0xed },   // 00:16:ED  Utility Inc.
};
static const size_t UTIL_BWC_OUI_COUNT = sizeof(UTIL_BWC_OUI) / sizeof(UTIL_BWC_OUI[0]);

#endif // ACAB_AXON_SIGNATURES_H
