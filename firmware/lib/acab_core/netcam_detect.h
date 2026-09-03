/*
 * ACAB - Network-camera (branded IP camera on host WiFi) detector.
 *
 * OPT-IN, DEFAULT OFF. Catching a streaming camera means inspecting 802.11 DATA-frame
 * SOURCE MACs, and production WiFi capture is MGMT-frame only (beacons + probe req/resp)
 * because data frames are a firehose (CPU + 2.4GHz coexistence cost on the shared radio).
 * So the data-frame OUI match is gated behind this toggle, exactly like the drone-OUI
 * opt-in:
 *   - OFF (default): the promiscuous filter stays MGMT-only, so the driver never even
 *     delivers data frames. ZERO added load. This is the whole reason it is opt-in.
 *   - ON: the filter is widened to include DATA, and the ONLY per-data-frame work is the
 *     cheap source-MAC OUI compare against the small camera table (netcam_signatures.h);
 *     the frame is dropped immediately and NEVER serial-logged in production.
 *
 * HONESTY: this matches known IP-camera BRANDS (Hikvision/Dahua/Amcrest/Axis/Reolink), not
 * "hidden cameras". A hit could be an NVR, doorbell, or a disclosed camera, and it cannot
 * find every camera. See netcam_signatures.h. Category "Network camera", detail "<Vendor>
 * on wifi".
 *
 * The opt-in flag mirrors the drone-OUI opt-in EXACTLY: persisted to NVS namespace
 * "acab-netcam" key "on", default false; config-write key "netcam", status key "ncam".
 */
#ifndef ACAB_NETCAM_DETECT_H
#define ACAB_NETCAM_DETECT_H

#include "detection.h"
#include <stddef.h>

// Opt-in on/off (default OFF), persisted to NVS "acab-netcam"/"on". netcamSetEnabled ALSO
// refreshes the WiFi promiscuous filter (widen to DATA when on, narrow to MGMT-only when
// off) so the zero-cost-when-off guarantee holds at runtime, not just at boot.
void netcamSetEnabled(bool enabled);
bool netcamIsEnabled();
// Reload the persisted opt-in on boot (NVS); defaultEnabled if never set (callers pass false).
void netcamRestoreEnabled(bool defaultEnabled);

// Match a MAC against the branded IP-camera vendor tables, retaining the registered 24/28-bit
// prefix width. Returns the vendor label on a hit, or nullptr. Skips null and locally-administered
// MACs (no real IEEE assignment). Public so the scanner can reuse it on either radio path.
const char* netcamVendorOui(const uint8_t mac[6]);

// Classify one 802.11 frame as a branded IP camera by its OUI. No-op (returns false) unless
// netcamIsEnabled(). `isDataFrame` selects the source-MAC location:
//   - data frame: the SOURCE address per the ToDS/FromDS bits (a camera uploading its stream
//     transmits with addr2 = its MAC). This is the primary signal.
//   - mgmt frame: the transmitter addr2 (BONUS - catches a camera acting as its own AP, or
//     probing) on the beacon/probe-resp/probe-req path already inspected in production.
// Fills `out` with ACAB_NETCAM and ONE of two results:
//   - SSID match, BEACON / PROBE-RESPONSE ONLY: M_SSID / NETCAM_SSID_CONFIDENCE (88), detail
//     "Arlo base station", name = the matched SSID. Tested FIRST, because it outranks every OUI
//     tier here and would otherwise lose to a weaker OUI hit on the same frame. Probe REQUESTS
//     are excluded on purpose - see the rule at the gate in netcam_detect.cpp.
//   - OUI match: M_OUI / NETCAM_OUI_CONFIDENCE (65, or _VALIDATED 75 for a field-validated
//     block), detail "<Vendor> on wifi".
bool netcamClassifyWiFi(const uint8_t* frame, size_t len, bool isDataFrame,
                        int rssi, AcabDetection* out);

#endif // ACAB_NETCAM_DETECT_H
