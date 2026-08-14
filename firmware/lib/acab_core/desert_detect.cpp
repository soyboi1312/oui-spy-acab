/*
 * ACAB - "Desert mode" catch-all detector implementation. See desert_detect.h.
 */
#include "desert_detect.h"
#include "acab_scanner.h"   // acabSanitizeAscii: clamp attacker-sourced strings on ingest
#include <Preferences.h>    // persist the Desert toggle across reboots (NVS)
#include <string.h>
#include <stdio.h>

static bool gEnabled = false;   // OFF by default; a special, opt-in mode

// PERSISTED as of 2026-08-08. Desert was the ONLY detector toggle without NVS, so every reboot
// silently turned it off with nothing in the log to say so. That already voided one drive test,
// and it is fatal to the deploy-and-leave case this mode exists for: a board left at a water
// cache for a week stops recording the moment a brownout resets it, and the owner comes back
// unable to tell "nothing came by" from "the mode switched itself off on day two". Mirrors
// flock/axon/tracker/glasses/netcam exactly.
void desertSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-desert", false); p.putBool("on", enabled); p.end();
}
bool desertIsEnabled(void) { return gEnabled; }

void desertRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-desert", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// A locally-administered MAC (bit 1 of the first octet) is a randomized/private
// address - phones rotate these ~every 15 min. A globally-unique OUI means real
// hardware (a vehicle module, IoT device, drone, tag).
static inline bool isRandomMac(const uint8_t* m) { return (m[0] & 0x02) != 0; }

// Pull the advertised local name out of a BLE advert (AD type 0x08 short /
// 0x09 complete) into name[outSz]. Leaves it empty if there is none.
static void bleName(const uint8_t* adv, size_t advLen, char* name, size_t outSz) {
    name[0] = 0;
    for (size_t i = 0; i + 1 < advLen; ) {
        uint8_t l = adv[i];
        if (l == 0 || i + 1 + (size_t)l > advLen) break;
        uint8_t t = adv[i + 1];
        if (t == 0x08 || t == 0x09) {                 // shortened / complete local name
            size_t n = (size_t)l - 1;
            if (n >= outSz) n = outSz - 1;
            acabSanitizeAscii(name, adv + i + 2, n, outSz);   // clamp to printable ASCII on ingest
            return;
        }
        i += (size_t)l + 1;
    }
}

bool desertClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out) {
    if (!gEnabled) return false;
    acabInit(out, ACAB_NEARBY_DEVICE, SRC_BLE, mac, (int16_t)rssi);
    out->method = M_NONE;
    if (adv && advLen) bleName(adv, advLen, out->name, sizeof(out->name));
    snprintf(out->detail, sizeof(out->detail), "%s",
             isRandomMac(mac) ? "randomized MAC" : "hardware OUI");
    return true;   // always matches when enabled - MUST be last in the chain
}

bool desertClassifyWiFi(const uint8_t* frame, size_t len, int rssi, AcabDetection* out) {
    if (!gEnabled || !frame || len < 24) return false;
    uint8_t fc = frame[0];   // frame-control octet (type/subtype)
    // Only the "presence" mgmt frames: beacon (0x80), probe-response (0x50),
    // probe-request (0x40). Skip the rest (acks etc.) to keep it to real devices.
    if (fc != 0x80 && fc != 0x50 && fc != 0x40) return false;
    const uint8_t* addr2 = frame + 10;   // transmitter address
    acabInit(out, ACAB_NEARBY_DEVICE, SRC_WIFI, addr2, (int16_t)rssi);
    out->method = M_SSID;

    // SSID IE: beacons/probe-resp put it after a 36-byte header; probe-req after 24.
    size_t ie = (fc == 0x40) ? 24 : 36;
    if (len >= ie + 2 && frame[ie] == 0x00) {         // tag 0 = SSID
        uint8_t sl = frame[ie + 1];
        if (sl > 0 && sl <= 32 && ie + 2 + (size_t)sl <= len) {
            size_t n = sl < sizeof(out->name) ? sl : sizeof(out->name) - 1;
            acabSanitizeAscii(out->name, frame + ie + 2, n, sizeof(out->name));   // clamp SSID on ingest
        }
    }
    snprintf(out->detail, sizeof(out->detail), "%s",
             isRandomMac(addr2) ? "randomized MAC" : "hardware OUI");
    return true;
}
