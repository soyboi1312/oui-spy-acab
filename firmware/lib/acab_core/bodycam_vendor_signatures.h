/*
 * ACAB - Body-camera-category vendor and accessory research signatures (clean-room).
 *
 * Matching these OUIs flags a Motorola Solutions WiFi/BLE device nearby. Motorola
 * Solutions is the dominant US public-safety comms vendor, but the same corporate
 * block also covers the MOTOTRBO two-way radios, docks, and infrastructure carried by
 * retail, school, and venue staff, so a hit is "Motorola Solutions gear", not proof of
 * a camera. It is NOT ALPR-specific, and NOT their LMR radios (700/800 MHz, off this
 * 2.4 GHz board). Broad by nature, so it sits behind its OWN sub-toggle underneath the
 * body-cam category ({"motorola":bool}, OPT-IN: default OFF on EVERY board, per the
 * 2026-07-23 ground truth recorded below) and emits below the apps' weak-match
 * threshold (<50) so it always renders as "verify this".
 *
 * The sub-toggle exists because this match and the Axon BWCDEVICE tag used to share one
 * switch: a user turning "body cam" off to quiet THIS broad match also silenced the
 * conf-90 field-validated Axon signature, which is the best signature on the board.
 * Now "body cam off" kills the whole category, and "motorola off" quiets only this.
 * Full notes in docs/signatures.md.
 */
#ifndef ACAB_BODYCAM_VENDOR_SIGNATURES_H
#define ACAB_BODYCAM_VENDOR_SIGNATURES_H

#include <stdint.h>
#include <stddef.h>

// Motorola Solutions corporate OUI blocks (IEEE MA-L). This is the COMPLETE set
// registered to the Motorola Solutions entities as of 2026-07-19, cross-checked against
// the IEEE registry via the OUI-Master-Database merge (IEEE+Wireshark+Nmap).
//
// Keep Motorola MOBILITY / Lenovo OUIs OUT - that is the unrelated consumer-phone
// business (122 separate blocks; matching them would flag every Moto handset on the
// street). "Motorola Solutions Malaysia Sdn. Bhd." IS in scope - same corporate group,
// their manufacturing entity, not the phone business.
//
// Why listing all seven is NOT the shared-silicon trap that killed Flock's Liteon
// matching: these are Motorola Solutions' OWN MA-L blocks, so a match correctly
// attributes the device VENDOR. The uncertainty here is what the device IS (radio vs
// dock vs camera vs infrastructure), which confidence=45 and the amber weak-match
// treatment already communicate - not WHO made it. 4C:CC:34 is field-observed on
// 2.4 GHz WiFi (own capture 2026-07-18, 3 distinct MACs at one site), which is what
// establishes this vendor as detectable at all; the siblings are the same product lines.
//
// GROUND TRUTH 2026-07-23 (airport capture, 45 rows): of 30 body-cam rows, the 3 Axon BLE
// hits were confirmed real officers and ALL 27 Motorola WiFi OUI hits were confirmed NOT
// body cams. 4C:CC:34 x15, 10:74:6F x10, B8:E2:8C x2, all fixed ceiling/infrastructure gear.
// Two consequences, neither of which is "the OUIs are wrong" - vendor attribution is still
// correct, and these blocks stay:
//   1. The detector is now OPT-IN on every board (default flipped in beacon-board/main.cpp).
//   2. Read the 2026-07-18 observation above with suspicion. "3 distinct MACs at one site"
//      is the same signature a bank of fixed cameras leaves, so it probably was not evidence
//      of body cams either. It shows the vendor is DETECTABLE, not that it is body-worn.
// If this is ever promoted back to on-by-default, it needs a discriminator that separates
// worn from mounted (a stationary repeat-sighting pattern is the obvious candidate: one row
// in that capture logged 20 sightings from effectively one spot), not just a confidence tweak.
static const uint8_t POLICE_OUI[][3] = {
    // Motorola Solutions, Inc.  (One Motorola Plaza, Holtsville NY US)
    { 0x4c, 0xcc, 0x34 },   // 4C:CC:34  reg 2012-12-30  FIELD-OBSERVED 2026-07-18 (WiFi)
    { 0x00, 0x04, 0x7d },   // 00:04:7D
    { 0x00, 0x18, 0x85 },   // 00:18:85
    { 0x00, 0x1f, 0x92 },   // 00:1F:92
    // Motorola Solutions Malaysia Sdn. Bhd. (same group, manufacturing entity)
    { 0x10, 0x74, 0x6f },   // 10:74:6F
    { 0xb8, 0xe2, 0x8c },   // B8:E2:8C
    { 0x9c, 0x86, 0x2b },   // 9C:86:2B
};
static const size_t POLICE_OUI_COUNT = sizeof(POLICE_OUI) / sizeof(POLICE_OUI[0]);

// FIELD-VALIDATION QUEUE, NOT COMPILED IN. Two in-car/body-video vendors whose own corporate
// MA-L blocks are registry-confirmed (2026-08-07 pull of standards-oui.ieee.org/oui/oui.csv):
//
//   00:1D:96   WatchGuard Video
//   00:23:BD   Digital Ally, Inc.
//
// Both are narrow registrants, so they would pass the no-shared-silicon rule that keeps
// Espressif and TP-Link out of these tables. They are still absent on purpose, for two reasons.
//
// First, an OUI establishes the VENDOR, never the equipment type. Both companies ship in-car
// video, interview-room recorders, evidence storage and fleet hardware alongside anything
// body-worn, so a hit would not mean what the category name says it means. That is the exact
// error the crowdsourced lists reviewed on 2026-08-07 make dozens of times over.
//
// Second, this table has been measured, and the measurement was humbling: the "3 distinct MACs
// at one site" note that once justified it turned out to be 0/27 when properly counted, and the
// field-observed rows above are ceiling and infrastructure gear rather than anything worn. A
// vendor block earns a place here after a capture pins it to a device somebody actually saw,
// not because the registration is real.
//
// To promote either one: capture near a confirmed unit with the capture build
// (pio run -e beacon-board-capture), which now logs every prober and its frame type, then record
// the co-signals the way the netcam table records its own field validations. Bracket the visit
// with {"mark":"digital-ally-near"}, then {"mark":"left"}, then {"mark":"end"} - three commands,
// because a mark only ever prints the window it CLOSES - so the two summaries pair what was there
// against what vanished on departure. The summary is BLE-only; read WiFi evidence from the raw log.
//
// ---------------------------------------------------------------------------------------------
// CONFIDENCE LADDER. What a piece of evidence is allowed to claim. Every table in this project
// that became embarrassing got that way by skipping a rung.
//
//   Validated product payload or name  -> name the DEVICE CLASS. Earned only by a capture that
//                                         ties the value to hardware somebody actually saw.
//   Two independent vendor co-signals  -> "<vendor> equipment", high confidence.
//   One official SIG CID or UUID       -> "<vendor> equipment", moderate. Vendor, never type.
//   Corporate OUI alone                -> diagnostics or an opt-in. Low confidence, nothing more.
//
// DELIBERATELY EXCLUDED, and not reopened without a new argument: generic "police" routers,
// APX-style name matching, emergency-light vendors, shared Axis/Getac OUIs, and P25 radio
// detection. Each is either a false-positive machine or turns this into a different hardware
// project. The boundary is surveillance equipment, recording accessories and public-safety
// drones, evidenced on 2.4 GHz and BLE. Not "police presence" in general.
//
// ---------------------------------------------------------------------------------------------
// CAPTURE QUEUE: ACTIVATION ACCESSORIES. Probably better discovery targets than the cameras,
// because short-range wireless signalling is their entire function. A holster sensor exists to
// tell nearby cameras to start recording, so it MUST transmit, and at a range that puts it well
// inside ours.
//
//   Axon Signal Sidearm, Signal Vehicle   (holster / vehicle activation for Body and Fleet)
//   Motorola Holster Aware
//   Reveal Bluetooth trigger accessories
//   Axis body-camera activation sensors
//   i-PRO IPS-BTS-SENSOR                    (BWC4000 holster activation accessory)
//   Getac TB-02 / TB-03                     (vehicle lightbar/door/weapon triggers)
//   Getac HS-01                             (holster trigger paired through BC-03)
//
// No values here yet, on purpose: nobody has observed one of these adverts. The Axon and Motorola
// SIG identifiers already in the capture build (VENDOR_BLE_ID in acab_scanner.cpp) are the likely
// route to a first sighting, since an accessory carries its vendor's assignment.
//
// LABEL RULE once one is confirmed: "camera activation accessory", NEVER "body camera". A holster
// sensor is not a camera, and calling it one is the same category error this file already spends
// forty lines warning about, with the twist that it would mislabel the MORE interesting finding as
// the less interesting one.
//
// i-PRO / GETAC CAPTURE SUPPORT (2.0.6): the capture build loudly annotates local names containing
// BWC4000, IPS-BTS, BC-02/03/04, TB-02/03 or HS-01. This is diagnostic instrumentation only.
// Official manuals establish that the products use BLE/WLAN and that the trigger boxes connect to
// lightbars, vehicle doors and weapon releases, but publish no passive identifier. Getac's corporate
// OUIs are deliberately excluded: the same blocks cover its rugged laptops and tablets. Bracket a
// confirmed unit with {"mark":"ipro-getac-near"}, {"mark":"left"}, {"mark":"end"}; promote only a
// value that survives that ground-truth comparison.
//
// ---------------------------------------------------------------------------------------------
// PUBLIC-SAFETY DRONES: THERE IS NO OUI TO ADD. SDPD's published technology inventory lists BRINC
// Lemur-S, Acecore Zoe, Fotokite Sigma and Hoverfly Spectre HL alongside DJI aircraft. All four
// non-DJI manufacturers were checked against the IEEE registries on 2026-08-08:
//
//   BRINC, Acecore, Fotokite, Hoverfly  ->  NOT PRESENT in MA-L, MA-M or MA-S.
//
// THE CONCLUSION IS NARROW, and worth stating precisely so it is not over-read: there is no
// REGISTRY-BACKED OUI RULE available for these aircraft. That is not the same as "no diagnostic
// signature could exist". A known flight may still expose a narrow advertised name, a service
// UUID, a manufacturer identifier or a repeatable Remote ID pattern, and any of those would be
// worth having. What is ruled out is the shortcut of adding a corporate OUI, because none of the
// four HAS one, and whatever they transmit therefore rides on some module vendor's block - the
// Liteon problem exactly: a table matching the module maker matches everything else that maker
// sells.
//
// Remote ID stays the primary mechanism, and is the right one: standardised, carries a UAS ID and
// operator ID, and public-safety operators are the population most likely to broadcast it
// correctly. The way to build evidence is a KNOWN FLIGHT - bracket it with
// {"mark":"brinc-lemur-flight"}, {"mark":"landed"}, {"mark":"end"} and read the RAW capture, not
// the marker summary, which is BLE-only and will not contain Remote ID at all. Waiting for that
// capture is the correct bounded choice. The city owning the equipment is not, by itself,
// evidence of anything.

#endif // ACAB_BODYCAM_VENDOR_SIGNATURES_H
