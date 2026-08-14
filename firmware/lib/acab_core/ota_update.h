/*
 * ACAB - ESP32-S3 self-update over BLE.
 *
 * The app streams a new S3 app image (the standard esp-idf OTA .bin) to the OTA
 * characteristic; this module writes it into the inactive app slot, validates it, and
 * (on otaFinish) points the bootloader at it. The caller reboots.
 *
 * On the v2 dual-radio board the S3 and the companion nRF update independently: this OTA
 * updates the S3, and the nRF self-updates over BLE DFU (the app triggers it via {"nrfdfu"},
 * verifies the .zip's signature, then drives the Nordic DFU transfer). See acab_ble_service.cpp.
 *
 * SECURITY: every entry point must be gated on an authenticated, bonded link. The BLE
 * service already requires bonding (WRITE_ENC) for all writes, so a stranger cannot push
 * firmware; first-pair the board in a trusted RF environment (see acab_ble_service.cpp).
 *
 * SAFETY (must-dos from the roadmap):
 *  - build guard: otaBegin rejects an image whose declared version is not newer than the
 *    running one (no accidental downgrade / re-flash), unless force=true.
 *  - integrity: the whole payload is CRC32'd (standard zlib CRC-32) and compared, on top of
 *    the Update library's own image-magic + SHA-256 validation.
 *  - rollback arming: otaFinish arms a boot-attempt counter; if the freshly-flashed image
 *    boots without reaching a healthy state (otaMarkHealthy) it is reverted to the previous
 *    slot on the next boot. This catches a build that boots-then-crashes/hangs; it cannot
 *    catch an image that never runs our code at all (that needs bootloader rollback, which
 *    the stock arduino-esp32 sdkconfig does not enable).
 */
#ifndef ACAB_OTA_UPDATE_H
#define ACAB_OTA_UPDATE_H

#include <stdint.h>
#include <stddef.h>

enum OtaResult {
    OTA_OK = 0,
    OTA_ERR_BUSY,        // a session is already open
    OTA_ERR_VERSION,     // declared version not newer than the running one (build guard)
    OTA_ERR_SIZE,        // size 0, mismatched total, or larger than the target slot
    OTA_ERR_BEGIN,       // Update.begin failed (no OTA slot / no room)
    OTA_ERR_WRITE,       // a flash write failed
    OTA_ERR_CRC,         // whole-image CRC32 mismatch
    OTA_ERR_IMAGE,       // Update.end validation failed (bad magic / SHA)
    OTA_ERR_STATE,       // write/finish with no open session
    OTA_ERR_SIG,         // signature missing or does not verify against the baked-in pubkey
    OTA_PENDING,         // end arrived before the last chunk: finish deferred, not an error (see otaFinish)
};
const char* otaResultStr(OtaResult r);

// Progress/result notifier: the module emits small JSON strings ("{...}") for the app.
// Set by the BLE service; may be null.
void otaSetNotifier(void (*fn)(const char* json));
// Emit one JSON line through that notifier (no-op when unset). For board code that reports
// non-session progress on the same OTA characteristic, e.g. the beacon board's blocking nRF
// SWD reflash ({"nrf":"flashing","pct":N}) while loop()'s status notifies are stalled.
void otaEmitNotify(const char* json);

// Open a session. newVer must be strictly newer than the running ACAB_FW_VERSION unless
// force. expectCrc32 is a standard zlib/PKZIP CRC-32 over the whole image (0 = skip check).
OtaResult otaBegin(uint32_t imageSize, uint32_t expectCrc32, const char* newVer, bool force);
// Feed one chunk in arrival order. A failure aborts the session.
OtaResult otaWrite(const uint8_t* data, size_t len);

// Store the pending detached ECDSA-P256/SHA-256 signature (DER) the app pushes on the
// Config char BEFORE begin. otaFinish verifies it over the running image digest against
// ACAB_OTA_PUBKEY_DER; cleared in otaFinish (after use) and otaAbort. Over-long der is
// ignored (leaves no pending sig, so otaFinish fails closed with OTA_ERR_SIG).
void otaSetSignature(const uint8_t* der, size_t len);

// Millis since the last otaBegin/otaWrite (0 when no session is open). The BLE service's
// stall watchdog uses this to abort a session wedged by a mid-update link drop.
uint32_t otaIdleMs();
// Verify size + CRC + image, set the new slot to boot, arm rollback. On OTA_OK the caller
// should reboot; this does NOT reboot itself. If `end` arrives before the last data chunk
// (gRecv < declared size), this does NOT fail: it arms a brief grace window and returns
// OTA_PENDING; a trailing otaWrite that completes the image finishes it, or otaPendingFinishExpired
// (below) fails it once the window lapses. The caller must treat OTA_PENDING as "wait, do nothing".
OtaResult otaFinish();
// Called from the loop watchdog: if a deferred finish (OTA_PENDING) never received its last chunk
// within the grace window, aborts the session and returns true so the caller can un-quiesce and
// notify the app of the size error. Returns false when there is no expired pending finish.
bool otaPendingFinishExpired();
void otaAbort();
bool otaInProgress();
uint32_t otaReceived();          // bytes written so far this session

// --- rollback / health ---
// Register the target's real health boundary. A trial cannot be confirmed until this returns true.
// Beacon-board includes scanner readiness plus a live/versioned nRF UART; mesh requires its scanner.
typedef bool (*OtaHealthCheck)();
void otaSetHealthCheck(OtaHealthCheck fn);
bool otaHealthReady();
// Call ONCE at the very top of setup(). If a prior OTA image booted without being marked
// healthy, this counts the attempt and, past the limit, reverts to the previous slot.
void otaBootCheck();
// Mark the running image healthy (disarms rollback). Call once the board reaches a known-
// good state and on an explicit app confirm. Returns false while the registered health boundary
// is not met or NVS could not durably clear the trial record.
bool otaMarkHealthy();
// True while the running image is on its unconfirmed trial boot after an OTA.
bool otaOnTrial();

#endif // ACAB_OTA_UPDATE_H
