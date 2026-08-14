/*
 * ACAB - ESP32-S3 self-update over BLE (implementation). See ota_update.h.
 */
#include "ota_update.h"
#include "acab_version.h"
#include "ota_pubkey.h"
#include "ota_policy.h"

#include <Arduino.h>
#include <Update.h>
#include <esp_ota_ops.h>
#include <esp_partition.h>
#include <esp_sleep.h>
#include <Preferences.h>
#include <mbedtls/pk.h>
#include <mbedtls/md.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

// Fail closed: a build with no baked-in OTA public key would skip verification and accept
// UNSIGNED firmware. Refuse to compile such a build , the signature check in otaFinish is
// mandatory and never conditional on the key being present.
static_assert(ACAB_OTA_PUBKEY_DER_LEN > 0,
              "OTA public key missing; a keyless build would accept unsigned firmware");

static void (*gNotify)(const char*) = nullptr;
static bool     gActive   = false;
static uint32_t gExpect   = 0;         // declared total size
static uint32_t gExpCrc   = 0;         // declared CRC32 (0 = skip)
static uint32_t gRecv     = 0;         // bytes written this session
static uint32_t gCrc      = 0;         // running CRC32 accumulator
static uint32_t gLastMark = 0;         // last progress-notify byte count
static bool     gOnTrial  = false;
static bool     gForce    = false;     // this session's force flag (from otaBegin), re-checked in otaFinish
static uint32_t gDeclaredVersion = 0;  // client declaration, later bound to the signed descriptor
static uint32_t gLastActivity = 0;     // millis of the last otaBegin/otaWrite (stall watchdog)
static OtaHealthCheck gHealthCheck = nullptr;

// Pending detached ECDSA signature (DER), pushed by the app before begin. A P-256 DER
// ECDSA signature is ~70-72 bytes; 80 leaves headroom. Verified in otaFinish.
static uint8_t  gSig[80];
static size_t   gSigLen  = 0;
static bool     gHasSig  = false;

// Running SHA-256 over every otaWrite byte, using the version-stable generic mbedtls_md
// API so it builds on whatever mbedTLS arduino-esp32 ships. Set up in otaBegin, updated in
// otaWrite, finished in otaFinish.
static mbedtls_md_context_t gMd;
static bool                 gMdActive = false;

// Serializes the gMd / Update critical sections across tasks. otaWrite + otaFinish run on the
// NimBLE host task; otaAbort + otaPendingFinishExpired can run from the loop watchdog. Without
// this an abort (loop) could mbedtls_md_free / Update.abort a gMd that an in-flight write (host)
// is still using. Created lazily in the first otaBegin; every section that touches gMd/Update
// takes it, so it exists before any write/finish/abort does real work (all gated on gActive,
// which only otaBegin sets after creating the mutex).
static SemaphoreHandle_t gOtaMux = nullptr;
struct OtaLock {
    bool held = false;
    OtaLock() { if (gOtaMux && xSemaphoreTake(gOtaMux, portMAX_DELAY) == pdTRUE) held = true; }
    ~OtaLock() { if (held) xSemaphoreGive(gOtaMux); }
};

// Deferred-finish grace (needs-hw): an `end` control can arrive on the host task just before the
// last data chunk (which is queued behind it on the SAME task). Rather than fail OTA_ERR_SIZE, we
// arm this window and let the trailing otaWrite complete the image; the loop watchdog fails it if
// the window lapses. See otaFinish / otaWrite / otaPendingFinishExpired.
static bool     gAwaitingFinish   = false;
static uint32_t gFinishDeadlineMs = 0;

static void mdReset() {
    if (gMdActive) { mbedtls_md_free(&gMd); gMdActive = false; }
}

void otaSetNotifier(void (*fn)(const char*)) { gNotify = fn; }
static void notify(const char* j) { if (gNotify) gNotify(j); }
void otaEmitNotify(const char* json) { notify(json); }

// The real finish: size + CRC + signature + version-floor + Update.end. Reachable two ways -
// the `end` control when the image is already complete, or a trailing otaWrite that completes a
// deferred finish. Defined below alongside otaFinish; forward-declared for otaWrite.
static OtaResult otaDoFinish();

const char* otaResultStr(OtaResult r) {
    switch (r) {
        case OTA_OK:          return "ok";
        case OTA_ERR_BUSY:    return "busy";
        case OTA_ERR_VERSION: return "not-newer";
        case OTA_ERR_SIZE:    return "size";
        case OTA_ERR_BEGIN:   return "begin";
        case OTA_ERR_WRITE:   return "write";
        case OTA_ERR_CRC:     return "crc";
        case OTA_ERR_IMAGE:   return "image";
        case OTA_ERR_STATE:   return "state";
        case OTA_ERR_SIG:     return "sig";
        case OTA_PENDING:     return "pending";
    }
    return "?";
}

// Standard reflected zlib/PKZIP CRC-32 (poly 0xEDB88420), computed incrementally. Bitwise
// (table-less) - fine for a one-time ~1MB image, and unambiguous for the app to match.
static uint32_t crc32_update(uint32_t crc, const uint8_t* d, size_t n) {
    crc = ~crc;
    for (size_t i = 0; i < n; i++) {
        crc ^= d[i];
        for (int b = 0; b < 8; b++)
            crc = (crc >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(crc & 1)));  // reversed CRC-32 poly
    }
    return ~crc;
}

// Read the authenticated pending image descriptor from the inactive update partition. Both its
// version and project name ride under the whole-image signature checked before this helper is
// trusted. The project name is the hardware/product identity, including the distinct rev-B image.
static bool pendingImageDescription(esp_app_desc_t* desc) {
    const esp_partition_t* upd = esp_ota_get_next_update_partition(NULL);
    return upd && desc && esp_ota_get_partition_description(upd, desc) == ESP_OK;
}

#ifdef ACAB_OTA_VERSION_FLOOR
// NVS-persisted anti-rollback floor: the lowest packed version this board accepts over BLE.
// Raised to the running version on each confirmed-healthy boot (otaMarkHealthy). 0 until the
// first healthy boot writes it, so a fresh board falls back to the running-version compare.
static bool otaVersionFloor(uint32_t* floor) {
    Preferences p;
    // Open read-write so a fresh board creates the namespace and legitimately returns floor 0.
    // A real NVS failure is different and must fail closed rather than skip an existing floor.
    if (!p.begin("ota", false)) return false;
    *floor = p.getUInt("floor", 0);
    p.end();
    return true;
}
#endif  // ACAB_OTA_VERSION_FLOOR

void otaSetHealthCheck(OtaHealthCheck fn) { gHealthCheck = fn; }
bool otaHealthReady() { return gHealthCheck && gHealthCheck(); }

static bool putU8(Preferences& p, const char* key, uint8_t value) {
    return p.putUChar(key, value) == sizeof(value);
}
static bool putU32(Preferences& p, const char* key, uint32_t value) {
    return p.putUInt(key, value) == sizeof(value);
}

// State is written last. A power loss during the metadata writes therefore leaves state 0 and the
// old image remains authoritative. The target address lets boot distinguish a real trial from a
// prepared record left behind when Update.end failed or power was lost before the slot switch.
static bool armTrialRecord(uint32_t targetAddress, uint32_t targetVersion) {
    Preferences p;
    if (!p.begin("ota", false)) return false;
    bool ok = putU8(p, "state", 0) &&
              putU8(p, "tries", 0) &&
              putU32(p, "target", targetAddress) &&
              putU32(p, "trialver", targetVersion) &&
              putU8(p, "state", 1);
    p.end();
    return ok;
}

static bool clearTrialRecord(Preferences& p) {
    // State first makes a partial cleanup safe. The remaining fields are zeroed so later
    // diagnostics cannot mistake stale metadata for an armed update.
    bool ok = putU8(p, "state", 0);
    ok = putU8(p, "tries", 0) && ok;
    ok = putU32(p, "target", 0) && ok;
    ok = putU32(p, "trialver", 0) && ok;
    return ok;
}

static void clearPreparedTrialBestEffort() {
    Preferences p;
    if (!p.begin("ota", false)) return;
    clearTrialRecord(p);
    p.end();
}

// Store the pending image signature the app pushes before begin. Do NOT clear it in
// otaBegin (the sig legitimately arrives first); it is cleared in otaFinish/otaAbort.
void otaSetSignature(const uint8_t* der, size_t len) {
    if (!der || len == 0 || len > sizeof(gSig)) { gHasSig = false; gSigLen = 0; return; }
    memcpy(gSig, der, len);
    gSigLen = len;
    gHasSig = true;
}

uint32_t otaIdleMs() { return gActive ? (millis() - gLastActivity) : 0; }

OtaResult otaBegin(uint32_t size, uint32_t crc, const char* newVer, bool force) {
    if (!gOtaMux) gOtaMux = xSemaphoreCreateMutex();   // guards the gMd/Update critical sections
    if (gActive) return OTA_ERR_BUSY;
    if (size == 0) return OTA_ERR_SIZE;
    gAwaitingFinish = false;   // fresh session: never inherit a stale deferred-finish window
    // Version gate. Normally the image must be strictly newer. `force` relaxes that to allow
    // re-flashing the SAME version (recovery / re-push) but NEVER an older one over BLE:
    // honoring force for a downgrade would let a bonded client roll the board back to an old
    // signed build with a since-patched bug (a rollback attack). Downgrades need a USB re-flash.
    {
        uint32_t nv = acabOtaVersionPack(newVer), cur = acabOtaVersionPack(ACAB_FW_VERSION);
        if (force ? (nv < cur) : (nv <= cur)) return OTA_ERR_VERSION;
        gDeclaredVersion = nv;
    }
    if (!Update.begin(size)) return OTA_ERR_BEGIN;   // checks the target slot has room
    // Start a fresh running SHA-256 over the incoming image (generic mbedtls_md API).
    mdReset();
    mbedtls_md_init(&gMd);
    if (mbedtls_md_setup(&gMd, mbedtls_md_info_from_type(MBEDTLS_MD_SHA256), 0) != 0 ||
        mbedtls_md_starts(&gMd) != 0) {
        mbedtls_md_free(&gMd);
        Update.abort();
        return OTA_ERR_BEGIN;
    }
    gMdActive = true;
    gForce  = force;   // remembered so otaFinish can re-apply the same rule to the AUTHENTICATED version
    gActive = true; gExpect = size; gExpCrc = crc;
    gRecv = 0; gCrc = 0; gLastMark = 0;
    gLastActivity = millis();
    char j[64]; snprintf(j, sizeof(j), "{\"ota\":\"ready\",\"size\":%u}", (unsigned)size);
    notify(j);
    return OTA_OK;
}

OtaResult otaWrite(const uint8_t* d, size_t n) {
    if (!gActive) return OTA_ERR_STATE;
    {
        OtaLock lk;   // small section: keep an abort (loop) from freeing gMd / Update mid-write
        if (Update.write((uint8_t*)d, n) != n) { Update.abort(); mdReset(); gActive = false; gAwaitingFinish = false; return OTA_ERR_WRITE; }
        gCrc = crc32_update(gCrc, d, n);
        if (gMdActive) mbedtls_md_update(&gMd, d, n);
    }
    gRecv += n;
    gLastActivity = millis();
    // A deferred finish was armed (end arrived early) and this write completed the image: run the
    // real finish now, on this same host task. Done OUTSIDE the OtaLock above so otaDoFinish can take
    // it without re-entering. On success the caller does not reboot from here (parity with the end
    // handler), so we reboot here; a finish error is reported to the caller to un-quiesce.
    if (gAwaitingFinish && gRecv >= gExpect) {
        gAwaitingFinish = false;
        OtaResult fr = otaDoFinish();
        if (fr == OTA_OK) { delay(250); ESP.restart(); }   // boot the new image
        return fr;
    }
    if (gRecv - gLastMark >= 65536 || gRecv >= gExpect) {
        gLastMark = gRecv;
        char j[80];
        snprintf(j, sizeof(j), "{\"ota\":\"prog\",\"rx\":%u,\"pct\":%u}",
                 (unsigned)gRecv, (unsigned)(gExpect ? (uint64_t)gRecv * 100 / gExpect : 0));
        notify(j);
    }
    return OTA_OK;
}

// Public finish entry (the `end` control). If the last chunk has not landed yet, arm a brief grace
// window and defer instead of failing OTA_ERR_SIZE (the trailing otaWrite or the watchdog resolves
// it). When the image is already complete, finish immediately as before.
OtaResult otaFinish() {
    if (!gActive) return OTA_ERR_STATE;
    if (gRecv < gExpect) {
        gAwaitingFinish   = true;
        gFinishDeadlineMs = millis() + 1500;   // let a straggler chunk (same host task) complete it
        return OTA_PENDING;
    }
    return otaDoFinish();
}

// Loop-watchdog hook: a deferred finish that never got its last chunk. Fails it once past the
// deadline. Runs on the loop task, so the gMd/Update teardown is under the OTA mutex.
bool otaPendingFinishExpired() {
    OtaLock lk;
    if (gAwaitingFinish && (int32_t)(millis() - gFinishDeadlineMs) > 0) {
        gAwaitingFinish = false;
        if (gActive) { Update.abort(); mdReset(); gActive = false; }
        gHasSig = false; gSigLen = 0;
        return true;
    }
    return false;
}

static OtaResult otaDoFinish() {
    if (!gActive) return OTA_ERR_STATE;
    OtaLock lk;   // serialize the gMd/Update teardown against a concurrent abort
    if (gRecv != gExpect)               { Update.abort(); mdReset(); gActive = false; return OTA_ERR_SIZE; }
    if (gExpCrc != 0 && gCrc != gExpCrc){ Update.abort(); mdReset(); gActive = false; return OTA_ERR_CRC; }

    // Finish the running digest, then verify the app's detached ECDSA-P256/SHA-256
    // signature over it against the baked-in public key. Refuse a missing/invalid sig so
    // only an image signed by the offline key holder can ever be committed. This runs
    // AFTER size + CRC and BEFORE Update.end(true), so an unsigned image never boots.
    uint8_t digest[32];
    bool haveDigest = false;
    if (gMdActive && mbedtls_md_finish(&gMd, digest) == 0) haveDigest = true;
    mdReset();

    // Verify the app's detached ECDSA-P256/SHA-256 signature over the digest against the
    // baked-in public key. FAIL CLOSED and UNCONDITIONAL: a missing signature, a failed digest,
    // or a bad signature all abort, so only an image signed by the offline key holder is ever
    // committed. (A keyless build is a compile error , see the static_assert above.)
    if (!gHasSig || !haveDigest) {
        Update.abort(); gActive = false; gHasSig = false; gSigLen = 0;
        return OTA_ERR_SIG;
    }
    // ECDSA-P256/SHA-256 verify of the app's detached signature. Runs on the NimBLE host task; the
    // host-task stack was bumped to 12288 B (CONFIG_BT_NIMBLE_HOST_TASK_STACK_SIZE) so this ECP math
    // has headroom (bench-measured ~7.6 KB free at the low-water mark). Keep NO blocking Serial I/O
    // in here - this is the host task, and a full USB-CDC TX ring would stall it mid-finish.
    {
        mbedtls_pk_context pk;
        mbedtls_pk_init(&pk);
        int rc = mbedtls_pk_parse_public_key(&pk, ACAB_OTA_PUBKEY_DER, ACAB_OTA_PUBKEY_DER_LEN);
        if (rc == 0) rc = mbedtls_pk_verify(&pk, MBEDTLS_MD_SHA256, digest, 32, gSig, gSigLen);
        mbedtls_pk_free(&pk);
        if (rc != 0) {
            Update.abort(); gActive = false; gHasSig = false; gSigLen = 0;
            return OTA_ERR_SIG;
        }
    }
    gHasSig = false; gSigLen = 0;   // signature consumed

    // Bind both version and product identity to the authenticated pending descriptor. All ACAB
    // images share one signing key, so a valid signature alone cannot distinguish rev-A, rev-B,
    // Mesh, or OUI-Spy artifacts. Refuse a cross-product image before Update.end can select it.
    esp_app_desc_t pendingDesc;
    const esp_app_desc_t* runningPtr = esp_ota_get_app_description();
    if (!pendingImageDescription(&pendingDesc) || !runningPtr) {
        Update.abort(); gActive = false; return OTA_ERR_IMAGE;
    }
    esp_app_desc_t runningDesc = *runningPtr;
    pendingDesc.version[sizeof(pendingDesc.version) - 1] = '\0';
    pendingDesc.project_name[sizeof(pendingDesc.project_name) - 1] = '\0';
    runningDesc.version[sizeof(runningDesc.version) - 1] = '\0';
    runningDesc.project_name[sizeof(runningDesc.project_name) - 1] = '\0';
    if (!acabOtaProjectMatches(runningDesc.project_name, pendingDesc.project_name)) {
        Update.abort(); gActive = false; return OTA_ERR_IMAGE;
    }
    const uint32_t authenticatedVersion = acabOtaVersionPack(pendingDesc.version);
    if (authenticatedVersion == 0 || authenticatedVersion != gDeclaredVersion) {
        Update.abort(); gActive = false; return OTA_ERR_VERSION;
    }

    // SEC-2: anti-rollback bound to the AUTHENTICATED image version, not the client's "ver".
    // otaBegin already screened the client-supplied "ver", but a bonded/MITM client can lie there
    // to install a since-patched but validly-signed OLDER build. The real version lives in the
    // pending image's esp_app_desc_t (under the whole-image signature we just verified), so read it
    // back and gate against a value the attacker cannot forge.
    //
    // stamp_app_desc.py stamps ACAB_FW_VERSION into esp_app_desc_t before the image is signed, and
    // the release verifier checks the raw descriptor bytes. Therefore an unreadable, zero, or
    // declaration-mismatched authenticated version is a hard rejection, never a skipped check.
#ifdef ACAB_OTA_VERSION_FLOOR
    {
        uint32_t floor = 0;
        const uint32_t cur = acabOtaVersionPack(ACAB_FW_VERSION);
        if (!otaVersionFloor(&floor) ||
            !acabOtaAuthenticatedVersionAllowed(gDeclaredVersion, authenticatedVersion,
                                                 cur, floor, gForce)) {
            Update.abort(); gActive = false; return OTA_ERR_VERSION;
        }
    }
#endif

    const esp_partition_t* target = esp_ota_get_next_update_partition(NULL);
    if (!target || !armTrialRecord(target->address, authenticatedVersion)) {
        Update.abort(); gActive = false; return OTA_ERR_STATE;
    }
    // The trial record is durable before the boot-slot switch. If Update.end fails, clear it best
    // effort; if cleanup also fails, otaBootCheck sees that the running address is not `target` and
    // clears the stale prepared record instead of condemning the old image.
    if (!Update.end(true)) {
        gActive = false;
        clearPreparedTrialBestEffort();
        return OTA_ERR_IMAGE;
    }
    gActive = false;
    notify("{\"ota\":\"done\"}");
    return OTA_OK;
}

void otaAbort() {
    OtaLock lk;   // serialize the gMd/Update teardown against an in-flight write/finish
    gAwaitingFinish = false;   // any deferred finish is void once the session is torn down
    if (gActive) { Update.abort(); gActive = false; notify("{\"ota\":\"abort\"}"); }
    mdReset();
    gHasSig = false; gSigLen = 0;   // drop any pending signature
}

bool     otaInProgress() { return gActive; }
uint32_t otaReceived()   { return gRecv; }
bool     otaOnTrial()    { return gOnTrial; }

void otaBootCheck() {
    Preferences p;
    if (!p.begin("ota", false)) return;
    uint8_t state = p.getUChar("state", 0);
    if (state != 1) { p.end(); return; }
    const esp_partition_t* running = esp_ota_get_running_partition();
    const uint32_t targetAddress = p.getUInt("target", 0);
    const uint32_t targetVersion = p.getUInt("trialver", 0);
    const esp_app_desc_t* runningDesc = esp_ota_get_app_description();
    const uint32_t runningVersion = runningDesc
        ? acabOtaVersionPack(runningDesc->version) : 0;
    if (!running || !acabOtaTrialMatches(running->address, targetAddress) ||
        targetVersion == 0 || runningVersion != targetVersion) {
        // Prepared but never switched, Update.end failure, or corrupt/stale metadata. This running
        // image is not the trial the record names, so clear it rather than rolling back good code.
        // KNOWN ONE-HOP GAP: an OTA taken FROM firmware that predates the "target"/"trialver"
        // keys (2.0.4 and earlier arm only state=1) lands here on its first boot, so that single
        // upgrade hop runs without boot-loop rollback. Unavoidable - the old image cannot write
        // keys it does not know - and it fails open in the safe direction only.
        clearTrialRecord(p);
        p.end();
        return;
    }
    // m8: an ext0-wake boot (device toggled back on within the trial window) is NOT a failed
    // trial. deep sleep never disarmed the counter, so counting the wake boot would silently
    // roll back a user's update. only count non-ext0 boots (a genuinely wedged post-wake image
    // still trips this because a WDT/panic reboot is not an ext0 wake). single-radio oui-spy has
    // no ext0 wake, so its behavior is unchanged.
    uint8_t tries = p.getUChar("tries", 0) +
                    (esp_sleep_get_wakeup_cause() == ESP_SLEEP_WAKEUP_EXT0 ? 0 : 1);
    if (tries >= 2) {
        // The freshly-OTA'd image already booted once without confirming health -> revert to
        // the previous slot (the "next update" partition is the one we are NOT running).
        const esp_partition_t* prev = esp_ota_get_next_update_partition(NULL);
        if (prev && esp_ota_set_boot_partition(prev) == ESP_OK) {
            clearTrialRecord(p);   // best effort; address mismatch also clears it on the old slot
            p.end();
            esp_restart();   // does not return
        }
        p.end();
        return;
    }
    if (!putU8(p, "tries", tries)) {
        // Keep the trial armed. A later health check cannot clear it unless NVS recovers, and a
        // reboot retries this accounting instead of silently losing the rollback state.
        p.end();
        gOnTrial = true;
        return;
    }
    p.end();
    gOnTrial = true;   // first trial boot: run, but stay armed until marked healthy
}

bool otaMarkHealthy() {
    Preferences p;
    // If NVS is momentarily unavailable, LEAVE gOnTrial set and return: loop()'s otaOnTrial() gate
    // then retries this on the next tick. Clearing gOnTrial while the persisted "state" stayed 1
    // would strand a genuinely-healthy image one unlucky reboot away from otaBootCheck reverting it.
    if (!p.begin("ota", false)) return false;
    const uint8_t state = p.getUChar("state", 0);
    if (state == 1 && !otaHealthReady()) { p.end(); return false; }
    bool ok = true;
    if (state == 1) ok = clearTrialRecord(p);
#ifdef ACAB_OTA_VERSION_FLOOR
    // SEC-2: a confirmed-healthy image raises the anti-rollback floor, so a later OTA can
    // never be talked back below the version we KNOW booted cleanly on this hardware. Gated
    // with the floor enforcement so the floor is only written when it will actually be honored.
    uint32_t cur = acabOtaVersionPack(ACAB_FW_VERSION);
    if (p.getUInt("floor", 0) < cur) ok = putU32(p, "floor", cur) && ok;
#endif
    p.end();
    if (!ok) return false;
    gOnTrial = false;   // only after the persisted state clear is committed
    return true;
}
