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
 * can tell a real device from phone-MAC churn. The advert name / WiFi SSID is
 * decoded into the detection for display. OFF by default; toggled via the app
 * {desert} config key. Reuses the scanner's existing dedup + "new device" + alert
 * + offline-buffer pipeline, so show/log/alert-on-new all come for free.
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
bool desertClassifyBLE(const uint8_t mac[6], const uint8_t* adv, size_t advLen,
                       int rssi, AcabDetection* out);
bool desertClassifyWiFi(const uint8_t* frame, size_t len, int rssi, AcabDetection* out);

#endif // ACAB_DESERT_DETECT_H
