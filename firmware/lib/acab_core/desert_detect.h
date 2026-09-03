/*
 * ACAB - "Desert mode" catch-all detector.
 *
 * When enabled, reports EVERY device in range as a generic "nearby device"
 * (ACAB_NEARBY_DEVICE), not just the specific surveillance signatures. Built for
 * wide-open, low-RF areas (the desert) where any new device = something arrived.
 *
 * It is the LAST classifier in the scan chain, so the specific detectors still win
 * for known gear; this only labels whatever is left over. Each device is tagged
 * hardware-OUI vs randomized-MAC (phones rotate theirs ~every 15 min) so the app
 * can tell a real device from phone-MAC churn. On WiFi that is the 802.11
 * locally-administered bit. On BLE it is the controller's address type when the
 * radio reported one; a BLE address with no reported type and the bit clear is
 * labelled "OUI unknown", because the bytes alone cannot tell a public
 * OUI from a resolvable private address. The advert name / WiFi SSID is
 * decoded into the detection for display. OFF by default; toggled via the app
 * {desert} config key. Reuses the scanner's existing dedup + "new device" + alert
 * pipeline, so show/log/alert-on-new all come for free. NOT the offline buffer:
 * shouldBuffer in acab_scanner.cpp refuses ACAB_NEARBY_DEVICE unless "record
 * everything" (bufferAll) is on, see docs/ble-protocol.md.
 */
#ifndef ACAB_DESERT_DETECT_H
#define ACAB_DESERT_DETECT_H

#include "detection.h"
#include <stddef.h>

void desertSetEnabled(bool enabled);
bool desertIsEnabled(void);
// Reload the persisted toggle on boot; if none saved yet, use defaultEnabled. Call from setup()
// beside the other detectors' restores. Without it a deployed board silently stops recording
// after any reset, which is the single failure this mode cannot survive: the owner returns
// unable to distinguish "nothing came by" from "it switched itself off".
void desertRestoreEnabled(bool defaultEnabled);

// Catch-all: returns true for ANY device when Desert mode is on (emits
// ACAB_NEARBY_DEVICE). MUST be tried LAST, after every specific classifier.
// addrType is what the receiving radio reported (ACAB_BLE_ADDR_UNKNOWN on the dual-radio
// UART path and on black-box replays); it selects the detail label, see the header note.
// No default on purpose: the one production caller (acabScannerIngestBLE) always knows.
bool desertClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out, AcabBleAddrType addrType);
bool desertClassifyWiFi(const uint8_t* frame, size_t len, int rssi, AcabDetection* out);

#endif // ACAB_DESERT_DETECT_H
