/*
 * ACAB - Network-camera detector implementation.
 *
 * Branded IP camera on the host WiFi, matched by its non-randomized vendor OUI on an
 * 802.11 frame. OPT-IN / default OFF - mirrors the drone-OUI opt-in exactly (persisted to
 * NVS "acab-netcam"/"on"). See netcam_detect.h for the why, netcam_signatures.h for the
 * table and the honesty rules.
 */
#include "netcam_detect.h"
#include "netcam_signatures.h"
#include "acab_scanner.h"   // acabScannerRefreshWifiFilter: widen/narrow the promiscuous filter on toggle
#include <Arduino.h>
#include <Preferences.h>    // persist the opt-in across reboots (NVS)
#include <string.h>
#include <stdio.h>
#include <ctype.h>          // tolower, for the case-insensitive SSID prefix test

// Opt-in flag (default OFF). NVS-backed in namespace "acab-netcam" key "on" so an app-set
// toggle survives a reboot. Mirrors the drone-OUI opt-in (gEnabledOui) exactly.
static bool gEnabled = false;

void netcamSetEnabled(bool enabled) {
    if (enabled == gEnabled) return;
    gEnabled = enabled;
    Preferences p; p.begin("acab-netcam", false); p.putBool("on", enabled); p.end();
    // Widen the WiFi promiscuous filter to DATA frames when turning ON, narrow back to
    // MGMT-only when turning OFF, so the OFF path truly delivers no data frames (zero cost).
    // Safe to call before the scanner starts (it no-ops until WiFi is up).
    acabScannerRefreshWifiFilter();
}
bool netcamIsEnabled() { return gEnabled; }

// Reload the persisted opt-in on boot; if none saved yet, use defaultEnabled (callers pass
// false so it stays off by default). Does NOT touch the promiscuous filter - it runs before
// the scanner starts, and acabScannerBegin reads netcamIsEnabled() when it installs the
// filter, so the restored state is applied there.
void netcamRestoreEnabled(bool defaultEnabled) {
    Preferences p; p.begin("acab-netcam", true);
    gEnabled = p.getBool("on", defaultEnabled);
    p.end();
}

// Branded IP-camera OUI match. Skip randomized / locally-administered MACs (the OUI is
// meaningless there), like the flock/drone OUI matchers. This is the ONLY per-data-frame work
// in production when the toggle is on. Both table shapes return the same metadata so the
// classifier grades a field-validated block above a registry-only one on either path.
struct NetcamMatch {
    const char* vendor;
    uint8_t validated;
};
static NetcamMatch netcamEntry(const uint8_t mac[6]) {
    if (!mac || (mac[0] & 0x02)) return { nullptr, 0 };   // no real IEEE assignment
    // BINARY SEARCH over the sorted table. This runs on EVERY data frame while the
    // network-camera opt-in is on, which is the busiest path in the firmware: that opt-in is
    // what widens the promiscuous filter to the data-frame firehose. The sort order is enforced
    // by netcamOuiSorted(). A miss checks only the small CAMERA_VENDOR_PREFIX fallback with
    // the shared width-aware matcher, rather than scanning the MA-L table.
    const uint32_t key = ((uint32_t)mac[0] << 16) | ((uint32_t)mac[1] << 8) | (uint32_t)mac[2];
    size_t lo = 0, hi = CAMERA_VENDOR_OUI_COUNT;
    while (lo < hi) {
        const size_t mid = lo + (hi - lo) / 2;
        const uint32_t k = netcamOuiKey(CAMERA_VENDOR_OUI[mid]);
        if (k == key) {
            const NetcamOui& e = CAMERA_VENDOR_OUI[mid];
            return { e.vendor, e.validated };
        }
        if (k < key) lo = mid + 1; else hi = mid;
    }
    for (const NetcamPrefix& e : CAMERA_VENDOR_PREFIX)
        if (acabOuiPrefixMatches(e.prefix, e.prefixBits, mac))
            return { e.vendor, e.validated };
    return { nullptr, 0 };
}

// Case-insensitive prefix test for the base-station SSID rule. Mirrors ciEndsWith in
// flock_detect.cpp (that one anchors at the tail, this one at the head). Case-insensitive
// because an SSID is user-visible text and vendors have shipped both cases of their own
// prefix before; anchored at the head so a network merely CONTAINING the string cannot match.
static bool netcamSsidPrefix(const char* ssid, const char* pfx) {
    if (!ssid || !pfx) return false;
    while (*pfx) {
        if (tolower((unsigned char)*ssid) != tolower((unsigned char)*pfx)) return false;
        ssid++; pfx++;
    }
    return true;
}

const char* netcamVendorOui(const uint8_t mac[6]) {
    return netcamEntry(mac).vendor;
}

bool netcamClassifyWiFi(const uint8_t* frame, size_t len, bool isDataFrame,
                        int rssi, AcabDetection* out) {
    if (!gEnabled) return false;             // opt-in: zero work when off
    if (!frame || len < 16) return false;

    // Where the SOURCE MAC lives.
    size_t saOff;
    if (isDataFrame) {
        // 802.11 data-frame source address depends on the ToDS/FromDS bits (frame-control
        // byte 1). A camera uploading its stream to the AP is ToDS=1/FromDS=0 -> SA = addr2.
        const uint8_t fc1 = frame[1];
        const bool toDS   = fc1 & 0x01;
        const bool fromDS = fc1 & 0x02;
        if (!fromDS)      saOff = 10;        // SA = addr2 (station->AP, or ad-hoc): the streaming-camera case
        else if (!toDS)   saOff = 16;        // SA = addr3 (AP->station relay of the camera's frames)
        else              saOff = 24;        // SA = addr4 (WDS 4-address)
    } else {
        // Mgmt frame (bonus): match the transmitter addr2 - a camera acting as its own AP
        // (beacon/probe-resp BSSID) or probing (probe-req prober) gives itself away here.
        saOff = 10;
    }
    if (saOff + 6 > len) return false;

    // SSID first: it outranks every OUI tier here, so checking it second would let a weaker
    // OUI hit on the same frame win and report 65 where 88 was available.
    //
    // The IE offset differs by subtype and getting it wrong FAILS SILENTLY - walking a beacon
    // from 24 parses the free-running TSF timestamp as an IE header and random-walks the frame.
    // The full explanation lives at the SSID parse in flock_detect.cpp; it is deliberately NOT
    // restated here, so there is one place to correct if it is ever found to be wrong. Keep
    // these offsets identical to that one (and to desert_detect.cpp, which splits the same way).
    if (!isDataFrame && len >= 24) {
        const uint8_t subtype = (frame[0] >> 4) & 0x0F;
        // BEACON (0x8) and PROBE-RESPONSE (0x5) ONLY. Probe REQUESTS (0x4) are deliberately
        // excluded, and this is a correctness rule, not an oversight - do not "restore" 0x4 for
        // symmetry with flock_detect.cpp.
        //
        // The 88 tier is justified in netcam_signatures.h by "this does not infer the vendor - the
        // vendor STATES it". That holds for a beacon or probe-response, where the SSID IE is the
        // transmitter's OWN network name. In a probe REQUEST the SSID is the network being SEARCHED
        // FOR and addr2 is the searching station, so the frame attests nothing about the
        // transmitter. Admitting 0x4 made an Arlo CAMERA hunting for its hub - or any phone with
        // that SSID saved, on a randomized MAC - get reported as "Arlo base station" at confidence
        // 88: the wrong box, at the highest non-watchlist tier, on an address never seen again.
        // The codebase already grades that inference separately (M_PROBE, used by flock at 72/78).
        if (subtype == 0x5 || subtype == 0x8) {
            for (size_t ie = 36; ie + 2 <= len; ) {
                const uint8_t id = frame[ie], ilen = frame[ie + 1];
                if (ie + 2 + ilen > len) break;
                if (id == 0x00) {                      // SSID IE
                    if (ilen > 0 && ilen <= 32) {
                        char ssid[33];
                        memcpy(ssid, frame + ie + 2, ilen);
                        ssid[ilen] = 0;
                        if (netcamSsidPrefix(ssid, NETCAM_SSID_ARLO_PREFIX) ||
                            netcamSsidPrefix(ssid, NETCAM_SSID_ARLO_LEGACY_PREFIX)) {
                            // addr2 = the transmitter. On a beacon/probe-response that is the AP
                            // itself, which is why only those two subtypes reach here.
                            acabInit(out, ACAB_NETCAM, SRC_WIFI, frame + 10, (int16_t)rssi);
                            out->method     = M_SSID;
                            out->confidence = NETCAM_SSID_CONFIDENCE;
                            // KEEP THE SSID. It is the entire justification for ranking this above
                            // the eyeball-validated 75 tier, so discarding it would leave the log
                            // with no way to check the claim - and no way to tell an ARLO_VMB_
                            // hit from the rarer NTGR_VMB_ legacy form (both field-captured). It
                            // also gives the row a real title: with name empty both apps fall all
                            // the way back to the bare type label "Network camera". Same as
                            // flock_detect.cpp and desert_detect.cpp do with their SSID matches.
                            // Straight off the frame, not via ssid[]: this is attacker-sourced
                            // text and acabSanitizeAscii is the ingest clamp for exactly that.
                            acabSanitizeAscii(out->name, frame + ie + 2, ilen, sizeof(out->name));
                            // Names the box, not a lens: a base station serves cameras, but
                            // saying "camera" here would claim more than the SSID proves.
                            snprintf(out->detail, sizeof(out->detail), "Arlo base station");
                            return true;
                        }
                    }
                    break;                             // SSID IE is unique; stop either way
                }
                ie += 2 + ilen;
            }
        }
    }

    const NetcamMatch e = netcamEntry(frame + saOff);
    if (!e.vendor) return false;

    acabInit(out, ACAB_NETCAM, SRC_WIFI, frame + saOff, (int16_t)rssi);
    out->method     = M_OUI;
    out->confidence = e.validated ? NETCAM_OUI_CONFIDENCE_VALIDATED : NETCAM_OUI_CONFIDENCE;
    // HONEST label: names the vendor + that it is on the network. NOT "hidden camera".
    snprintf(out->detail, sizeof(out->detail), "%s on wifi", e.vendor);
    return true;
}
