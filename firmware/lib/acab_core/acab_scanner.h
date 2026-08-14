/*
 * ACAB - Unified scanner.
 *
 * Owns the radios and runs every detector at once:
 *   - NimBLE active scan            -> drone (RID) + Flock + Axon, per advert
 *   - 802.11 promiscuous + hopping  -> drone (RID) + Flock, per mgmt frame
 *
 * De-dupes by (type, MAC) and calls the firmware-supplied sink once per new
 * sighting (and again on refresh after the dedup window). The two builds
 * (OUI-Spy, Mesh-Detect) differ only in the sink they register.
 */
// Capture-build guard for the ESP32 side, mirroring the one in nrf-ble-scan/src/main.cpp.
// This header is pulled in by acab_scanner.cpp, which every ESP32 env compiles, so the guard
// covers oui-spy, mesh-detect, mesh-detect-ch1 and beacon-board alike.
//
// ACAB_ACTIVE_SCAN makes the scanner send requests to nearby targets instead of passively hearing
// their broadcasts. The encrypted phone control link is separate. ACAB_BENCH_NO_SLEEP skips the
// soft-power park so the board ignores SW1 entirely. Both are bench-only. They previously compiled
// clean into a signed release image: the commented
// -DACAB_ACTIVE_SCAN sits in the shared [env] build_flags block every env inherits, one
// uncommented line away from shipping, and neither release script inspects the image before
// signing it. Refuse to compile instead unless the capture intent is explicit.
#if (defined(ACAB_ACTIVE_SCAN) || defined(ACAB_BENCH_NO_SLEEP)) && !defined(ACAB_CAPTURE_BUILD)
#error "ACAB_ACTIVE_SCAN / ACAB_BENCH_NO_SLEEP are bench-only. Set -DACAB_CAPTURE_BUILD to build one on purpose; NEVER ship it."
#endif

#ifndef ACAB_SCANNER_H
#define ACAB_SCANNER_H

#include "detection.h"

struct AcabScannerConfig {
    bool        enableBLE;          // scan BLE advertisements
    bool        enableWiFi;         // 802.11 promiscuous capture
    bool        initNimBLE;         // false if the firmware already inited NimBLE
    const char* bleDeviceName;      // only used when initNimBLE == true
    bool        wifiChannelHop;     // hop 1..13, or sit on a fixed channel
    uint8_t     wifiFixedChannel;   // used when wifiChannelHop == false
    uint32_t    wifiHopIntervalMs;  // dwell time per channel
    uint32_t    dedupWindowMs;      // re-emit a device as "new" after this gap
};

// Sensible defaults: both radios on, NimBLE self-init, channel hopping, 60 s dedup.
AcabScannerConfig acabScannerDefaults();

// Start scanning. `sink` fires from scanner task context for each detection.
void acabScannerBegin(const AcabScannerConfig& cfg, AcabDetectionSink sink);

// Clamp an attacker-sourced byte string to printable ASCII (0x20..0x7E) as it is
// copied into dst: any other byte (control chars, high bytes) becomes '.'. Copies
// min(n, cap-1) bytes then null-terminates. Keeps a crafted advert name / WiFi SSID /
// drone ODID id from injecting control bytes that would make the detection JSON
// invalid (iOS silently drops invalid JSON, suppressing the live alert). Shared so
// every ingest path sanitizes identically.
void acabSanitizeAscii(char* dst, const uint8_t* src, size_t n, size_t cap);

// Feed in our own GPS fix; fixed-device detections (Flock/Axon) get stamped
// with it. Drones carry their own broadcast coordinates, so they don't.
void acabScannerSetSelfGPS(double lat, double lon, bool valid);

// Run the full BLE classifier chain on a single advert and funnel any match
// into the detection pipeline. The NimBLE scan callback calls this for the
// board's own radio; a dual-radio build also calls it for adverts a companion
// nRF52840 forwards over UART. Counts toward acabScannerBleSeen(). mac is in
// human order (mac[0] = OUI first byte); payload is the raw advert AD bytes.
// isReplay=true routes a recovered black-box record to the app WITHOUT beeping or
// polluting the live dedup table / gTotal / offline buffer (see AcabDetection::replay).
void acabScannerIngestBLE(const uint8_t mac[6], const uint8_t* payload, size_t plen, int rssi, bool isReplay = false);

// Re-arm offline-buffer capture (call when the app disconnects): the first sighting of
// each device after this buffers once more, so capture isn't a single per-boot event.
void acabScannerReArmCapture();

// Periodic re-arm while "record everything" is on (detLogBufferAll, det_log.h). Call once per
// main-loop tick; it self-throttles to REBUFFER_AFTER_MS and no-ops when the mode is off or a
// phone is connected. Without it a week-long deployment writes ONE record per device for the
// whole week, because the generation counter only advances on an app disconnect and no app is
// coming - the log would say "this MAC existed" and never "something came by on Thursday".
void acabScannerBufferAllTick();

// Whitelist: silently drop detections from these MACs (no report/beep/mesh).
// App-pushed over config; held in RAM (the app re-sends on reconnect).
void acabScannerSetIgnoreList(const uint8_t macs[][6], int count);

// How many MACs are currently on the ignore list (for app reconciliation).
uint32_t acabScannerIgnoreCount();

// Watchlist (app-pushed): the inverse of the ignore list. The user stars a specific
// device by exact MAC; from then on the board alerts every time that MAC is seen (normal
// dedup cadence) even when no built-in signature matches it. Held in RAM + persisted to
// NVS across boots (the app also re-sends on reconnect).
void acabScannerSetWatchList(const uint8_t macs[][6], int count);

// How many MACs are currently on the watchlist (for app reconciliation).
uint32_t acabScannerWatchCount();

// Total detections emitted this session (for status/heartbeat reporting).
uint32_t acabScannerTotalDetections();

// Diagnostics: raw BLE adverts and 802.11 mgmt frames seen since boot, matched
// or not. Lets a field test tell "radio alive, nothing matched" from "radio
// seeing nothing at all."
uint32_t acabScannerBleSeen();
uint32_t acabScannerWifiSeen();
// Sink-queue drop accounting. A nonzero buffered-drop count means the offline ring missed records
// it was asked to keep (the claim was rolled back, so the device re-arms, but that sighting is
// gone); a nonzero deliver-only count is benign, since a missed live notify simply re-arrives.
// Reported as `sdrop` (the total) in periodic status, and individually in the {"diag":true} reply.
uint32_t acabScannerSinkDropDeliverOnly();
uint32_t acabScannerSinkDropBuffered();
uint32_t acabScannerSinkDropReplay();
uint32_t acabScannerSinkHighWater();
uint32_t acabScannerSinkDropTotal();

// Co-processor (dual-radio nRF) stats, mirrored up over UART for the two-radio
// "is it working?" diagnostic. hasCoProc stays false on a single-board build.
void     acabScannerSetCoProcStats(uint32_t advSeen, uint32_t forwarded, bool scanning, uint32_t bbCount);
bool     acabScannerHasCoProc();
// Timestamp the last byte-line heard from the co-processor. The dual-radio UART path calls
// this on EVERY ingested nRF line (adverts, the 5s "D" heartbeat, version/black-box replies)
// so liveness can decay. No-op effect on single-board builds (nothing calls it).
void     acabScannerNoteCoProcRx();
// Co-processor liveness: true only if we have heard a line from the nRF within the timeout.
// false = never seen OR gone silent (nRF radio fault -> the BLE detection half is dark). Drives
// the status "co" flag and the A1 recovery reflash. Always false on a single-board build.
bool     acabScannerCoProcAlive();
uint32_t acabScannerCoProcAdvSeen();
uint32_t acabScannerCoProcForwarded();
bool     acabScannerCoProcScanning();
uint32_t acabScannerCoProcBbCount();   // black-box records stored on the nRF's flash
// Send a command line to the co-processor (e.g. black-box "DUMP" / "BCLR") via the
// registered cmd sink. No-op if no co-processor link is set.
void     acabScannerSendCoProcCmd(const char* cmd);
// Re-push the co-processor state that lives only in its RAM: the BLE scan on/off line and the
// ignore-list mirror. The nRF drops both on ANY reset (power blip, WDT, and most visibly a BLE
// DFU), so the dual-radio UART parser calls this every time the nRF announces its version
// ("V<n>") on boot. Safe to call repeatedly; no-op when no cmd sink is registered, so a
// single-radio build pays one null test.
void     acabScannerResyncCoProc();

// Turn each detection radio on/off at runtime (app-controllable). Disabling BLE
// only stops the *scan* - a GATT link to the app stays up. Both start enabled in
// acabScannerBegin().
void acabScannerSetBLE(bool on);
void acabScannerSetWiFi(bool on);
bool acabScannerBLEEnabled();
bool acabScannerWiFiEnabled();
// True only after the sink and every configured radio task were created successfully. Used by
// OTA trial confirmation so stable uptime cannot bless an image with a missing scanner pipeline.
bool acabScannerHealthy();

// WiFi eco mode (battery SKU): seconds of promiscuous-RX sleep inserted AFTER each full channel
// sweep. 0 = continuous (off). The app offers 0/3/7/15; the setter snaps to that ladder. Persisted
// to NVS. Trades battery for WiFi-only coverage (Flock APs, network cameras) during the gaps; BLE
// is never throttled. No effect while the WiFi radio toggle is off, or in fixed-channel mode.
void acabScannerSetWifiEco(int sec);
int  acabScannerWifiEco();

// Recompute + reinstall the 802.11 promiscuous frame filter. Production is MGMT-only, but
// the network-camera opt-in (netcamIsEnabled) widens it to also deliver DATA frames so their
// source-MAC can be OUI-matched; turning that toggle off narrows it back so no data-frame
// firehose is delivered at all (zero cost). netcamSetEnabled() calls this on every flip.
// No-op until WiFi is up / when WiFi is disabled in the config.
void acabScannerRefreshWifiFilter();

// Optional out-of-band command sink for a co-processor. A dual-radio build sets
// this so radio commands are mirrored to a companion nRF52840 over UART: it is
// called with a short ASCII line when the BLE radio is toggled ("S1" / "S0") or
// the ignore list changes ("IC" to clear, then "IA <mac12hex>" per entry).
// Default null = no-op, so single-board builds are unaffected.
typedef void (*AcabCmdSink)(const char* line);
void acabScannerSetCmdSink(AcabCmdSink sink);


#ifdef ACAB_DIAG_WIFI
// Diagnostic-queue accounting (capture builds). dropped>0 means the promiscuous callback
// produced diag records faster than the serial task drained them, so the log is INCOMPLETE and
// an absent signal proves nothing. Reported on the [diag] line.
uint32_t acabScannerWifiDiagSent();
uint32_t acabScannerWifiDiagDropped();
#ifdef ACAB_CAPTURE_BUILD
// Every watched DATA frame seen, counted even when the rate limiter printed no line for it.
uint32_t acabScannerWatchDataSeen();
// Falcon-OUI mode accounting. Measures whether a data-frame rule for falconWifiOui() could ever
// be safe, BEFORE one is written: how much Falcon-OUI traffic is data vs management, how many
// distinct devices carry those OUIs on a normal drive, and whether FALCON_MAX was big enough to
// believe the answer. falcon_full > 0 invalidates the device count.
uint32_t acabScannerFalconData();
uint32_t acabScannerFalconMgmt();
uint32_t acabScannerFalconMacs();
uint32_t acabScannerFalconTableFull();
// Official vendor BLE identifiers (Bluetooth SIG assigned numbers), counted per advert. Axon/TASER
// and Motorola Solutions are tallied separately because they are on different tracks: Axon is the
// first field-validation target, Motorola rides along in capture only. vendor_full > 0 means the
// per-MAC table overflowed and vendor_macs is a floor, not a count.
uint32_t acabScannerVendorAxon();
uint32_t acabScannerVendorMoto();
uint32_t acabScannerVendorMacs();
uint32_t acabScannerVendorFull();

// Ground-truth marker window. {"mark":"<label>"} over config calls this: it CLOSES the open window
// and prints its per-device summary, then opens a new one under the new label.
//
// Bracketing a visit therefore takes THREE commands, not two, because a mark only ever prints the
// window it is closing:
//     {"mark":"axon-near"}   opens `axon-near`                (prints nothing yet)
//     {"mark":"left"}        prints `axon-near`, opens `left`
//     {"mark":"end"}         prints `left`
// Comparing the two summaries is what answers "did the signal disappear when I walked away",
// i.e. device-on-person versus device-on-building.
//
// SCOPE: the summary is BLE ONLY - it is fed from the BLE ingest funnel, so WiFi frames and Remote
// ID never reach it. Those must be read from the RAW capture, which is where a drone or Falcon
// conclusion has to come from. An empty summary means no BLE advert qualified, NOT that nothing
// was there.
//
// BOUNDARIES ARE READ FROM at_ms ON THE [mark] SWITCH LINE, not from where that line sits in the
// serial stream. Diagnostics are printed by several tasks without a shared queue, so a line can
// interleave; at_ms is sampled inside the same lock that closes the window, so it is exact.
//
// Capture builds only; produces no detection and never reaches the apps.
void acabScannerMark(const char* label);
#endif
#endif

#endif // ACAB_SCANNER_H
