/*
 * ACAB - Motorola Solutions gear detector (a law-enforcement-equipment proxy).
 * Matches are reported under the BODY-CAM device type, so the apps fold them into the
 * "Body cam" category (the separate police-gear category is merged into body cam).
 * Signatures in bodycam_vendor_signatures.h, sourced from the IEEE OUI registry.
 */
#include "police_detect.h"
#include "bodycam_vendor_signatures.h"
#include "axon_detect.h"     // parent category switch: this is a SUB-toggle of body cam
#include "desert_detect.h"   // Desert mode forces classification even when toggled off
#include <Preferences.h>     // persist the Motorola sub-toggle across reboots (NVS)
#include <string.h>
#include <stdio.h>

static bool gEnabled = false;   // module default off; main.cpp restores the persisted
                                // value at boot, and EVERY board passes false - both
                                // beacon-board and mesh-detect call
                                // policeRestoreEnabled(false). Opt-in since the
                                // 2026-07-23 ground truth; see the banner in
                                // bodycam_vendor_signatures.h.

void policeSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-moto", false); p.putBool("on", enabled); p.end();
}
bool policeIsEnabled() { return gEnabled; }

// Reload the persisted sub-toggle on boot; if none saved yet, use defaultEnabled.
void policeRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-moto", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// This match is a SUB-TOGGLE of the body-cam category, so it needs BOTH switches:
// the category (axon) must be on, and this broad-match opt-out must not be set.
// Turning the category off kills every body-cam signature; turning only this off
// leaves the conf-90 Axon BWCDEVICE tag and Utility BodyWorn running. Desert mode
// forces classification regardless, as it does for every other detector.
static inline bool active() {
    if (desertIsEnabled()) return true;
    return gEnabled && axonIsEnabled();
}

static bool ouiMatch(const uint8_t mac[6]) {
    if (mac[0] & 0x02) return false;   // skip locally-administered / random MACs (no real OUI)
    for (size_t i = 0; i < POLICE_OUI_COUNT; i++)
        if (mac[0] == POLICE_OUI[i][0] && mac[1] == POLICE_OUI[i][1] &&
            mac[2] == POLICE_OUI[i][2]) return true;
    return false;
}

static bool emit(AcabDetection* out, const uint8_t mac[6], int rssi, AcabSource src) {
    // Reported under the body-cam type so the apps bucket it in the "Body cam" category.
    // The detail names the real source; no "police" wording goes on the wire, which keeps
    // the iOS build App-Store-safe (iOS no longer has to special-case a police category).
    acabInit(out, ACAB_AXON_BODYCAM, src, mac, (int16_t)rssi);
    out->method = M_OUI;
    // Confidence grades the TYPE claim ("body camera"), not the vendor read: the device
    // IS Motorola Solutions, but their dominant 2.4 GHz products are two-way radios,
    // docks, and infrastructure carried by retail/school/venue staff, so "body camera"
    // is more often wrong than right. Held below 50 so both apps draw the amber
    // weak-match "verify this" treatment instead of a calm partial match.
    out->confidence = 45;
    snprintf(out->detail, sizeof(out->detail), "Motorola Solutions OUI");
    return true;
}

bool policeClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out) {
    (void)adv; (void)advLen;
    if (!active()) return false;
    if (!ouiMatch(mac)) return false;
    return emit(out, mac, rssi, SRC_BLE);
}

bool policeClassifyWiFi(const uint8_t* frame, size_t len, int rssi,
                        AcabDetection* out) {
    if (!active() || !frame || len < 24) return false;
    uint8_t ftype = (frame[0] >> 2) & 0x3;   // management frames only
    if (ftype != 0x0) return false;
    const uint8_t* addr2 = &frame[10];   // transmitter
    const uint8_t* addr3 = &frame[16];   // BSSID
    if (ouiMatch(addr2)) return emit(out, addr2, rssi, SRC_WIFI);
    if (ouiMatch(addr3)) return emit(out, addr3, rssi, SRC_WIFI);
    return false;
}
