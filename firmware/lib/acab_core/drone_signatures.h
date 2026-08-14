/*
 * ACAB - Drone vendor MAC OUIs (clean-room) - a fallback UNDER Remote ID.
 *
 * Primary drone detection is OpenDroneID / ASTM F3411 Remote ID (drone_detect.cpp),
 * a standardised self-declared broadcast. This table is a SECONDARY, lower-confidence
 * signal: a device transmitting from one of a drone vendor's OWN corporate IEEE OUI
 * blocks when NO Remote ID was decoded. It catches that vendor's drones / controllers /
 * goggles that don't broadcast RID (older units, RID disabled, non-US firmware). The
 * vendor randomises its MAC in some Wi-Fi modes, so an OUI hit is a bonus "vendor gear
 * nearby" signal layered under RID, never a replacement for it.
 *
 * Every block below is the vendor's own corporate MA-L, MA-M, or MA-S registration in the IEEE
 * registry - not commodity module silicon, so it passes the no-shared-silicon rule the
 * rest of the OUI tables follow. Prefix length is part of the signature: treating an
 * MA-M as a three-byte MA-L widens it sixteenfold and attributes fifteen unrelated
 * neighboring assignments to the drone vendor.
 *   src: IEEE OUI registries, cross-checked against standards-oui.ieee.org.
 *        See docs/signatures.md.
 */
#ifndef ACAB_DRONE_SIGNATURES_H
#define ACAB_DRONE_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// One drone-vendor IEEE assignment. MA-L uses 24 prefix bits, MA-M uses 28, and MA-S
// uses 36. The unused tail is zero-filled by each macro.
struct DroneOui {
    uint8_t     prefix[5];
    uint8_t     prefixBits;
    const char* vendor;
};

#define DRONE_MAL(a, b, c, vendorName) \
    { { (a), (b), (c), 0x00, 0x00 }, 24, (vendorName) }
#define DRONE_MAM(a, b, c, nibble, vendorName) \
    { { (a), (b), (c), (uint8_t)((nibble) << 4), 0x00 }, 28, (vendorName) }
#define DRONE_MAS(a, b, c, d, nibble, vendorName) \
    { { (a), (b), (c), (d), (uint8_t)((nibble) << 4) }, 36, (vendorName) }

// The drone vendors' own corporate IEEE blocks. Every block is the vendor's OWN
// registration, not commodity module silicon, so it passes the no-shared-silicon rule.
// (DJI registration dates in comments; the newest are on the latest hardware only.)
static const DroneOui DRONE_VENDOR_OUI[] = {
    // DJI (registrant "SZ DJI Technology Co.,Ltd").
    DRONE_MAL(0x60, 0x60, 0x1f, "DJI"),   // 2013-03-11  FIELD-OBSERVED 2026-07-23: a live airborne
                                       //   DJI broadcast Remote ID from this block (San Diego).
                                       //   Confirms the block is real DJI hardware; does NOT
                                       //   confirm the OUI path is safe to enable by default.
    DRONE_MAL(0x34, 0xd2, 0x62, "DJI"),   // 2019-08-13
    DRONE_MAL(0x48, 0x1c, 0xb9, "DJI"),   // 2022-05-07
    DRONE_MAL(0xe4, 0x7a, 0x2c, "DJI"),   // 2023-10-19
    DRONE_MAL(0x58, 0xb8, 0x58, "DJI"),   // 2024-07-26
    DRONE_MAL(0x04, 0xa8, 0x5a, "DJI"),   // 2025-01-09
    DRONE_MAL(0x8c, 0x58, 0x23, "DJI"),   // 2025-05-27
    DRONE_MAL(0x0c, 0x9a, 0xe6, "DJI"),   // 2025-08-14
    DRONE_MAL(0x88, 0x29, 0x85, "DJI"),   // 2025-10-29
    DRONE_MAL(0x4c, 0x43, 0xf6, "DJI"),   // 2025-12-01

    // DJI Baiwang Technology, DJI's wholly owned UAV manufacturing subsidiary. These are
    // separate IEEE registrations, so a lookup restricted to the exact SZ DJI registrant misses
    // them even though the registrant is part of the same drone manufacturer.
    DRONE_MAL(0x9c, 0x5a, 0x8a, "DJI"),
    DRONE_MAL(0xec, 0x72, 0xf7, "DJI"),
    DRONE_MAL(0x34, 0x91, 0xf0, "DJI"),

    // Parrot SA (ANAFI line, incl. the ANAFI USA carried by US agencies). NOTE: 90:3A:E6 is
    //   also the OUI the OpenDroneID WiFi beacon vendor IE rides (see droneRidWiFi); that is
    //   an IE match, not a transmitter-MAC match, and RID is decoded FIRST, so this fallback
    //   only fires on non-RID Parrot gear. src: IEEE ("Parrot SA / Parrot Drones").
    DRONE_MAL(0x00, 0x12, 0x1c, "Parrot"),
    DRONE_MAL(0x00, 0x26, 0x7e, "Parrot"),
    DRONE_MAL(0x90, 0x03, 0xb7, "Parrot"),
    DRONE_MAL(0x90, 0x3a, 0xe6, "Parrot"),
    DRONE_MAL(0xa0, 0x14, 0x3d, "Parrot"),

    // Skydio Inc (the most-deployed US-agency drone; Skydio 2/X2/X10). src: IEEE ("Skydio Inc").
    DRONE_MAL(0x38, 0x1d, 0x14, "Skydio"),

    // Autel Robotics (EVO line). src: IEEE ("Autel Robotics USA LLC"). Not to be confused
    //   with Beijing Autelan or the separate Autel Intelligent Technology automotive-
    //   diagnostics registrant, which are deliberately NOT matched.
    DRONE_MAM(0xec, 0x5b, 0xcd, 0x0e, "Autel"),

    // Yuneec (Typhoon / H520). src: IEEE ("Yuneec Technology" / "Yuneec International").
    DRONE_MAM(0xe0, 0xb6, 0xf5, 0x08, "Yuneec"),

    // Narrow US aircraft manufacturers used in public-safety, industrial, or government
    // fleets. These are each the aircraft vendor's own IEEE assignment, not module silicon.
    DRONE_MAL(0xec, 0x71, 0x5e, "Freefly"),
    DRONE_MAL(0xb0, 0x30, 0xc8, "Teal"),
    DRONE_MAL(0x00, 0x1a, 0xf9, "AeroVironment"),
    DRONE_MAS(0x8c, 0x1f, 0x64, 0xb0, 0x07, "AeroVironment"),
    DRONE_MAM(0x34, 0xb5, 0xf3, 0x02, "Inspired Flight"),
    DRONE_MAM(0xac, 0x86, 0xd1, 0x07, "Quantum Systems"),
    DRONE_MAS(0x8c, 0x1f, 0x64, 0x0f, 0x01, "ideaForge"),
    DRONE_MAS(0x8c, 0x1f, 0x64, 0xa2, 0x0d, "ACSL"),
    DRONE_MAL(0x74, 0xb8, 0x0f, "Zipline"),
    DRONE_MAM(0x24, 0xa1, 0x0d, 0x07, "Cyon Drones"),
    DRONE_MAM(0xb4, 0x4d, 0x43, 0x0a, "UAV Navigation"),
    DRONE_MAL(0x14, 0xdd, 0x48, "Shield AI"),
    DRONE_MAM(0xe8, 0xb4, 0x70, 0x0c, "Anduril"),
};
static const size_t DRONE_VENDOR_OUI_COUNT = sizeof(DRONE_VENDOR_OUI) / sizeof(DRONE_VENDOR_OUI[0]);

// Confidence for an OUI-only drone-vendor match (no Remote ID). Deliberately low:
// it means "vendor hardware nearby", not "an airborne drone", and it isn't RID.
#define DRONE_OUI_CONFIDENCE  60

#undef DRONE_MAL
#undef DRONE_MAM
#undef DRONE_MAS

#endif // ACAB_DRONE_SIGNATURES_H
