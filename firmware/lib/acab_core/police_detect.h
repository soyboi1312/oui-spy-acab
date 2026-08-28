/*
 * ACAB - Police / Motorola Solutions gear detector.
 *
 * OUI-only match on Motorola Solutions blocks (see bodycam_vendor_signatures.h). Flags "a
 * Motorola Solutions device nearby", a useful body-worn-equipment hint, but broad (it
 * catches any of their WiFi/BLE gear), so it is folded into the body-cam category and
 * sits behind its OWN sub-toggle underneath it: {"motorola":bool}, NVS-persisted,
 * OPT-IN: default OFF on EVERY board. Every target passes policeRestoreEnabled(false),
 * on the 2026-07-23 airport ground truth (all 27 Motorola WiFi OUI hits confirmed NOT
 * body cams); that capture is written up in bodycam_vendor_signatures.h. A stored NVS
 * value still wins over the default, so a board that already saved "on" keeps it until
 * the user turns it off in the app.
 *
 * SUB-toggle, not a peer: classification needs BOTH axonIsEnabled() (the category) and
 * policeIsEnabled() (this broad-match opt-out). Turning the body-cam category off kills
 * every body-cam signature; turning only this off leaves the conf-90 field-validated
 * Axon BWCDEVICE tag and Utility BodyWorn running. Before the split these shared one
 * switch, so quieting this broad match also silenced the best signature on the board.
 */
#ifndef ACAB_POLICE_DETECT_H
#define ACAB_POLICE_DETECT_H

#include "detection.h"
#include <stddef.h>

// Broad-match sub-toggle (NVS-persisted). Module default OFF; main.cpp restores the
// persisted value at boot. Gated by the body-cam category on top of this - see above.
void policeSetEnabled(bool enabled);
bool policeIsEnabled();
// Reload the persisted sub-toggle on boot (NVS); defaultEnabled if never set.
void policeRestoreEnabled(bool defaultEnabled);

// Match a Motorola Solutions OUI on a BLE advertiser's MAC.
bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out);

// Match a Motorola Solutions OUI on an 802.11 management frame (transmitter / BSSID).
bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out);

#endif // ACAB_POLICE_DETECT_H
