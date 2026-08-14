/*
 * ACAB - Offline detection buffer (det_log).
 *
 * Captures detections to a raw-flash ring while the app is disconnected, then
 * replays them (unacknowledged NOTIFY; seq + hist:end count let the app spot drops
 * and re-sync) when the app reconnects. Locked design
 * decisions (2026-06-20, after a full validation pass - see docs/ble-protocol.md):
 *
 *   - OPT-IN: default OFF, master switch persisted to NVS. The app turns it on.
 *     The project's posture is "collects nothing"; a flash of geotagged sightings is
 *     a new at-rest exposure, so it is off until the user opts in.
 *   - ENCRYPTED AT REST: the sensitive payload is AES-CTR encrypted with a 32-byte key
 *     the app pushes on connect. The key is PERSISTED to NVS while buffering is enabled
 *     (and erased when it's turned off), so a deploy-and-leave board keeps buffering
 *     across reboots instead of going keyless. TRADEOFF: a seized board's flash now
 *     yields the key, so the at-rest buffer is decryptable - it is NOT ciphertext-only.
 *     The remaining guards are the opt-in default (off) + the auto-wipe of records left
 *     undrained across reboots; flash-encryption / encrypted NVS would restore the
 *     seized-board protection.
 *   - AUTO-WIPE: records left undrained past a threshold are really erased, so a
 *     board out of its owner's hands self-cleans (clearlog needs the bonded phone in
 *     hand, which you do not have during a seizure).
 *   - RAW esp_partition RING (not a LittleFS file - LittleFS's copy-on-write fights
 *     fixed-offset slots): fixed 64B slots, slot = seq % N, APPEND-ONLY (one record
 *     per device per boot, gated on true first sighting, not on isNew which re-fires
 *     every 60s dedup gap).
 *
 * The append hook lives in the shared scanner funnel (acab_scanner.cpp
 * handleDetection), NOT in either build's onDetection, so it covers oui-spy AND
 * mesh-detect from one place. Both builds run the GATT service and are connectable.
 */
#ifndef ACAB_DET_LOG_H
#define ACAB_DET_LOG_H

#include "detection.h"
#include <stdint.h>
#include <stddef.h>

// One ring slot, fixed 64 bytes (static_assert enforced in det_log.cpp). seq,
// bootCount, and crc are CLEARTEXT so the boot scan can find the head and validate
// torn writes without the key; everything from whenMs down is the AES-CTR encrypted
// payload (nonce = bootCount:seq, unique per record).
struct __attribute__((packed)) StoredDet {
    uint32_t seq;          // monotonic: ring order + the app's sync cursor (cleartext)
    uint32_t bootCount;    // persisted monotonic boot counter, NOT random (cleartext)
    uint16_t crc;          // CRC16 over the encrypted payload; written LAST (cleartext)
    uint16_t gpsAgeSec;    // age (s) of the GPS fix used for lat/lon (cleartext; 0 = fresh/none)
    // ---- encrypted payload (52 bytes) ----
    uint32_t whenMs;       // millis() at last sighting, this boot
    uint8_t  type, src, method, conf;
    uint8_t  mac[6];
    int16_t  rssi;
    int32_t  lat_e7, lon_e7;   // lat/lon * 1e7 (compact vs the live double)
    uint16_t count;
    char     uasid[20];        // drone UAS-ID: preserves drone identity on replay
    char     name[6];          // truncated label for non-drones (type carries the class)
};

// A decrypted record handed back to the BLE layer for one replay frame.
struct DetLogReplay {
    AcabDetection d;       // unpacked back into the live detection shape
    uint32_t seq;          // wire "seq"
    uint32_t atUnix;       // absolute capture time (unix seconds), or 0 when approx
    bool     approx;       // true => this boot was never anchored; the app brackets it
    // Always populated, even when approx. The board has no RTC, so an absolute time is ALWAYS
    // reconstructed as anchor.epochUnix - (anchor.atMs - whenMs). Sending the raw inputs lets the
    // app verify that reconstruction, redo it against its own anchor history (which survives board
    // reboots and factory resets), and bracket an unanchored boot between the neighbouring
    // anchored ones instead of showing a bare "time unknown".
    uint32_t whenMs;       // millis() at capture, relative to bootCount's boot
    uint32_t bootCount;    // which boot session captured it
};

// Latched storage faults. These are a bitmask so one status value can report every
// failure observed since the last fully successful clear. Faults survive reboot and
// storage-integrity faults stop new appends. A complete physical wipe clears them;
// merely starting a clear does not claim the storage is healthy again.
enum DetLogFault : uint32_t {
    DET_LOG_FAULT_NONE    = 0,
    DET_LOG_FAULT_READ    = 1u << 0,
    DET_LOG_FAULT_ERASE   = 1u << 1,
    DET_LOG_FAULT_WRITE   = 1u << 2,
    DET_LOG_FAULT_CORRUPT = 1u << 3,
    DET_LOG_FAULT_LOCK    = 1u << 4,
};

// --- lifecycle ---
void     detLogBegin();             // mount ring, scan for head (generation window),
                                    // bump+persist bootCount, run auto-wipe of stale records
void     detLogSetEnabled(bool on); // opt-in master switch (persisted to NVS)
bool     detLogEnabled();

// --- RECORD EVERYTHING (deploy-and-leave). Persisted to NVS, default OFF. ---
// Normally the ring REFUSES ACAB_NEARBY_DEVICE (shouldBuffer in acab_scanner.cpp): it is
// append-only with no type filter of its own, so in a dense area a flood of re-admitted phone
// records wraps it and evicts the real ALPR / body-cam hits the owner synced to get.
//
// That reasoning INVERTS for the case this switch exists for: a board left unattended for days
// in a low-RF area, where the question is whether anything came by at all and an uncategorized
// device IS the finding. There is nothing to crowd out, because almost nothing transmits there.
//
// Turning it on also changes two things that are otherwise wrong for a week-long deployment:
//      1. Re-arm becomes TIME-based (REBUFFER_AFTER_MS in acab_scanner.cpp) instead of firing
//      once per capture generation. Without it a vehicle that passes Monday and again Thursday
//      writes ONE record, because gCaptureGen only advances on an app disconnect and no app is
//      coming. The log would say "this MAC existed" and never "something came by twice".
//      TWO LIMITS ON THAT, both real, and neither may be papered over in user-facing copy:
//        - The interval is BEST EFFORT. Dedup eviction resets loggedGen, so a busy site
//          re-buffers the same device far more often than the interval implies. It governs at a
//          quiet, stationary site, which is the only place this mode belongs.
//        - "Monday and Thursday" needs a CLOCK. The board has no RTC. Times are millis() plus an
//          app-pushed epoch anchor, so a boot that follows an unattended power loss is never
//          anchored and its records replay as approx, bracketed between neighbouring anchored
//          boots (see DetLogReplay.approx). Exact wall-clock is only guaranteed while the board
//          stays powered or that boot received an anchor. Ordering within a boot is always sound.
//   2. The undrained-reboot auto-wipe threshold rises (WIPE_AFTER_BOOTS_DEPLOY). Boot count is a
//      poor proxy for "seized" once the owner has explicitly said they are leaving it unattended,
//      and a discharging battery browning out six times would otherwise erase the whole week.
//      SECURITY TRADEOFF, STATED PLAINLY: this weakens the self-clean guarantee. It does not
//      remove it (the threshold stays finite), but a board recovered inside that window yields
//      more than it would with the switch off. Say so where the user turns it on.
//
// THIS SWITCH ALONE DOES NOT GIVE YOU "DID ANYTHING COME BY". DESERT MODE MUST ALSO BE ON.
// ACAB_NEARBY_DEVICE has exactly two producers, both in desert_detect.cpp and both behind that
// mode's own enable. With Desert off, bufall still buys the revisit/dwell half (the tick re-arms
// EVERY type, so a Flock or body-cam hit gets a record per window instead of one for the whole
// deployment) and the wider wipe threshold, but nothing uncategorized is ever classified, so the
// uncategorized half of the feature produces nothing. The app must turn both on together, and
// firmware deliberately does NOT auto-enable Desert here: the iOS client forces Silent when
// Desert goes on, and bypassing that would arm the buzzer into a firehose.
//
// Once the ring is full, detLogAppend stops accepting ACAB_NEARBY_DEVICE rather than letting
// them evict signature hits. See the guard there for why (a drive home with the board still
// armed will otherwise overwrite the deployment it just collected).
void     detLogSetBufferAll(bool on);
bool     detLogBufferAll();

// --- ring saturation: is the TAIL of this log censored? ---
// Once the ring is full, detLogAppend refuses further ACAB_NEARBY_DEVICE records rather than let
// them evict signature hits. That is the right trade, but it must not be silent: without a marker
// the owner reconnects to a full-looking log and cannot tell "nothing came by after Tuesday" from
// "we stopped writing on Tuesday". detLogSaturated() is PERSISTED, so it survives the reboots a
// week in the field guarantees, and is cleared only by detLogClear (a wipe starts a fresh log).
// detLogSatDrops() counts THIS BOOT only and is for the diag line. The app must surface the flag
// beside the log itself, not in a settings screen.
bool     detLogSaturated();
uint32_t detLogSatDrops();

// --- CLIENT CONTRACT for this mode. Not yet implemented in either app, ON PURPOSE. ---
// Firmware-only until the UI below exists: nothing in ios/ or android/ writes "bufall", so the
// mode is currently unreachable and cannot be armed by accident.
//
// Present it as ONE experimental switch called "Stationary capture". Do NOT call it "record
// everything": that names the mechanism, invites use as a general logging mode, and buries the
// one thing the user has to understand, which is that this is for a board that STAYS PUT.
//
// Arming it pushes the at-rest key first, then a SINGLE config object:
//     {"buffer":true, "bufall":true, "desert":true, "buzzer":false}
// All four together, in one write. buffer alone records nothing new; bufall without desert gets
// revisit resolution but never classifies an uncategorized device, which is the half the user
// actually wants; and buzzer:false because Desert on a live board is a firehose.
//
// The screen must state, in the user's own terms:
//   1. EXTERNAL USB-C POWER IS REQUIRED. The battery SKU runs ~7h15m quiet against 168h in a
//      week. Without this the deployment simply stops, and the log looks identical to "nothing
//      came by".
//   2. It records nearby radios, INCLUDING BYSTANDERS' PHONES. Say it plainly; this is the
//      disclosure that distinguishes the mode from the rest of the product.
//   3. Storage used, and whether it SATURATED (status "bufsat"). A saturated log is censored at
//      the tail and the user must not read it as a complete record. Show this next to the log.
//   4. Whether capture times are EXACT or APPROXIMATE. Any boot after an unattended power loss
//      is unanchored and replays as approx (DetLogReplay.approx). "Monday and Thursday" is only
//      guaranteed while the board stays powered or that boot received an epoch anchor.
//   5. The weakened auto-wipe, in one sentence, at the switch itself and not in a help page.
//
// DISARMING IS AN ORDERED SEQUENCE, and the order is load-bearing. Setting "buffer":false calls
// detLogClearKey(), which drops the at-rest key from RAM and NVS. Do that before the replay has
// finished and the remaining records become undecryptable while still occupying the ring: the
// deployment is destroyed by the act of collecting it. So, on collection:
//   1. Connect and let the replay run to completion.
//   2. Confirm it ended CLEANLY - the {"hist":"end","n":N} sentinel, with N matching the record
//      count received. A gap means re-sync, not proceed.
//   3. Only then write {"bufall":false, "desert":false, "buffer":false}.
//   4. Restore the user's prior alert mode through the existing Desert reconciliation path
//      (reconcileDesert on both platforms). Do NOT blindly re-enable the buzzer: the mode forced
//      Silent, and a mode the user hand-picked while Desert ran has to survive.
//   5. Let the user ERASE the stored log explicitly ({"clearlog":true}). Never automatic. They
//      just collected a week of bystander movements; deleting it is their call and their timing.
//
// STATUS SEMANTICS THE CLIENT MUST IMPLEMENT: "bufall" and "bufsat" are sent ONLY when true, so
// ABSENT MEANS FALSE, and it means false in EVERY fresh status frame, not just the first. Latch
// them per frame, never cumulatively. Get this wrong and a stale saturation warning survives a
// clearlog forever, telling the user their complete log is truncated when it is not.
//
// HARDWARE ACCEPTANCE PASS, required before the switch is exposed in either app. The host suite
// covers the persistence LOGIC; none of it proves the flash ring, the NVS writes and the drain
// behave on a real board across a real power cycle, which is the entire premise of the mode:
//   1. Arm Stationary capture, then disconnect.
//   2. Confirm UNCATEGORIZED and TRACKER records are actually stored (both are new admissions
//      under this mode; the tracker one only works because the debounce term is relaxed).
//   3. Power-cycle the board. Confirm desert, buffer and bufall all come back ARMED.
//   4. Drain, and verify exact vs approximate timestamps behave as documented above: records from
//      an anchored boot exact, records from a boot that followed an unattended power loss approx.
//   5. Force saturation with a TEST BUILD using a tiny slot count, and confirm bufsat persists
//      through a reboot. Do not wait for a real 24576-record ring to fill.
//   6. clearlog, and confirm bufsat disappears from the status frame.

// --- at-rest key: app-pushed on connect. Held in RAM, and persisted to NVS while buffering
// is enabled so a deploy-and-leave board survives a reboot (the TRADEOFF above). A truncated
// SHA-256 of it is persisted UNCONDITIONALLY: buffered records outlive the key (a disable
// erases the key but not the ring), and the fingerprint is what detects a different phone's
// key arriving for them, which would otherwise decrypt them to noise that passes the CRC. ---
void     detLogSetKey(const uint8_t key[32]);
void     detLogClearKey();          // forget the key (e.g. when buffering is disabled); keeps the fingerprint
bool     detLogHaveKey();

// --- wall-clock anchor: app-pushed epoch for this boot (mirrors the GPS push) ---
void     detLogSetEpoch(uint32_t unixSec);

// --- capture: called from acab_scanner.cpp handleDetection while disconnected.
// No-op unless enabled AND a key is present AND this is the device's first sighting
// this boot (e->count == 0). ---
void     detLogAppend(const AcabDetection& d);

// --- replay: the BLE service owns the NOTIFY stream and pulls records from here.
// Delivery is UNACKNOWLEDGED notify; reliability is the per-record seq plus the {"hist":"end","n"}
// count, which let the app spot a gap and re-sync (it is NOT an acknowledged INDICATE stream).
// detLogStartDrain sets the cursor to the app's lastSeq; detLogNextForDrain decrypts
// and unpacks the next record (returns false when the drain is complete). ---
void     detLogStartDrain(uint32_t lastSeq);
bool     detLogDraining();
void     detLogStopDrain();   // abort an in-flight drain on a link drop; next {sync} re-arms it
bool     detLogNextForDrain(DetLogReplay* out);

// --- maintenance ---
void     detLogClear();             // logical clear now; REAL erase of the whole ring deferred, chunked across loop ticks
uint32_t detLogCount();             // stored record count (surfaced as status "buf")
uint32_t detLogPendingDrain();      // records queued for the CURRENT drain (valid after
                                    // detLogStartDrain; = what the replay will actually send)
uint32_t detLogFaults();            // latched DetLogFault bitmask; 0 means no known storage fault

// Internal loop/BLE helpers. Declared here so the implementation and its host tests share
// one contract; application mains should continue to reach them through acabBleDrainTick.
void     detLogEraseTick();
bool     detLogWipePending();
uint32_t detLogDrainFrom();

#ifdef ACAB_HOST_TEST
// Drops only process-local state. The host partition and Preferences stores survive,
// which models a reboot without adding production-only reset behavior.
void     detLogHostResetRuntime();
#endif

#endif // ACAB_DET_LOG_H
