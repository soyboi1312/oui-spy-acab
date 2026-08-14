/*
 * ACAB - Offline detection buffer (det_log) implementation. See det_log.h.
 *
 * Storage: a raw esp_partition ring over the 1.5MB "spiffs" data partition (NOT a
 * LittleFS file - LittleFS's copy-on-write fights fixed-offset slots). 64B slots,
 * slot index = (seq-1) % gSlots. APPEND-ONLY: each device is captured once per boot
 * (its true first sighting), so slots are never rewritten in place.
 *
 * Erase granularity is a 4KB sector (64 slots). When the write cursor enters a new
 * sector it erases it, evicting the oldest 64 records at once - acceptable for a
 * ring. Write order is payload-then-header so a torn write leaves seq=0xFFFFFFFF
 * (an empty slot), never a half-valid record.
 *
 * At rest the payload (whenMs..name) is AES-CTR encrypted with the app-pushed key;
 * seq/bootCount/crc stay cleartext so the boot scan works without the key. The CRC
 * is computed over the CIPHERTEXT, so torn writes are caught before any decrypt.
 */
#include "det_log.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_partition.h>
#include <mbedtls/aes.h>
#include <mbedtls/md.h>
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>
#include <string.h>
#include <stddef.h>
#include "acab_ble_service.h"   // acabBleClientConnected()

static_assert(sizeof(StoredDet) == 64, "StoredDet must pack to exactly 64 bytes");

// ---- config ----
static const char*    NVS_NS     = "acab-buf";
static const char*    PART_LABEL = "spiffs";                 // reuse the 1.5MB data slot (v1)
static const size_t   SLOT       = sizeof(StoredDet);        // 64
static const size_t   SECTOR     = 4096;
static const size_t   PER_SECTOR = SECTOR / SLOT;            // 64 slots / sector
static const size_t   ENC_OFF    = offsetof(StoredDet, whenMs);
static const size_t   ENC_LEN    = SLOT - ENC_OFF;           // 52 encrypted bytes
// Boot-based auto-wipe: if the buffer sits across this many reboots without the app
// ever connecting to drain it, erase it (a board out of its owner's hands self-cleans).
// This is a no-RTC proxy for the "N hours" decision; an epoch-time refinement is a TODO.
static const uint32_t WIPE_AFTER_BOOTS = 6;
// ...and the threshold used while "record everything" is on (see detLogSetBufferAll in det_log.h).
// 6 reboots is the right proxy for "seized" when the board rides in a pocket and reconnects to a
// phone daily. It is the WRONG proxy once the owner has explicitly said they are leaving it
// unattended for days: a discharging battery brownout-looping six times would erase the entire
// deployment, which is precisely the data the mode exists to collect, and the owner would never
// know it happened. Still finite, so a genuinely abandoned board self-cleans eventually.
//
// DO NOT read this as "wide enough to survive a week of resets". A boot counter cannot bound a
// brownout loop: gBoot increments unconditionally below, so a cell sitting at the brownout knee
// at ~2 s per cycle burns 64 counts in about two minutes. 64 is a real and monotonic improvement
// over 6 - there is no input where the wider threshold loses records the narrower one keeps - and
// that is the whole claim. A time or epoch gate would be the honest fix and is future work.
static const uint32_t WIPE_AFTER_BOOTS_DEPLOY = 64;

// ---- state ----
static const esp_partition_t* gPart = nullptr;
static uint32_t gSlots    = 0;     // total slots in the partition
static uint32_t gHead     = 1;     // next seq to write (seq starts at 1; 0/0xFFFFFFFF = empty slot)
static uint32_t gOldest   = 1;     // oldest live seq still in the ring
static uint32_t gBoot     = 0;     // persisted monotonic boot counter
static uint32_t gDrain    = 0;     // drain cursor: the next record sent has seq > gDrain
static bool     gDraining = false;

// Deferred physical wipe (see detLogClear): the logical clear is instant, then loop()
// (detLogEraseTick, pumped via acabBleDrainTick) erases the ring one 64KB block per pass so
// the NimBLE host task never eats the multi-second full-partition erase. The pending flag is
// ALSO persisted to NVS ("wipe") so a power loss mid-sweep resumes at boot instead of letting
// the boot scan resurrect not-yet-erased old-generation records (their seq/CRC still validate).
static bool              gWipePending = false;
static uint32_t          gWipeNext    = 0;         // next partition offset to erase
static bool              gWipeStalled = false;    // one failed tick waits for an explicit clear or reboot
static const uint32_t    WIPE_BLOCK   = 64 * 1024; // one flash block erase (~100-250ms) per tick

// One mutex owns every raw-flash operation and every cursor transition that describes that
// flash. A spinlock cannot cover erase/write because flash operations may block with the cache
// disabled. The mutex makes both clear/append orderings safe:
//   - append first: its complete record is then condemned by the clear sweep;
//   - clear first: append observes gWipePending after it gets the lock and writes nothing.
// Drain reads use the same lock, so a wipe cannot erase a slot while it is being replayed.
static StaticSemaphore_t gIoMutexStorage;
static SemaphoreHandle_t gIoMutex = nullptr;

static bool     gEnabled  = false;
// volatile: read LOCK-FREE by detLogBufferAll() on the radio hot paths; writes stay under gIoMutex.
static volatile bool gBufferAll = false;   // "record everything" deploy mode; see det_log.h
// Ring-saturation marker. gSaturated is PERSISTED ("bufsat"): it has to outlive the reboots a
// week-long deployment guarantees, or the owner reconnects to a full-looking log with no way to
// know its tail was censored. gSatDrops is this boot only, for the [diag] line.
static bool              gSaturated = false;
static volatile uint32_t gSatDrops  = 0;
static uint32_t gFaults = DET_LOG_FAULT_NONE;
static uint8_t  gKey[32];
static bool     gHaveKey  = false;

// Truncated SHA-256 of the at-rest key, persisted to NVS INDEPENDENT of both gEnabled and the
// key itself, because the key-change wipe guard (detLogSetKey) has to fire in exactly the state
// where no key is held. Turning buffering off drops the key from RAM AND NVS but leaves every
// record in the ring, and a reboot reloads the key only while enabled - so a guard that compares
// against gKey is disarmed precisely when records outlive their key. A second or reinstalled
// phone then arrives with a NEW key, and since the slot CRC covers the CIPHERTEXT its records
// decrypt to noise that still validates. The fingerprint outlives both the disable and the
// reboot, and being a preimage-resistant hash that never leaves the board it discloses nothing
// a seized flash does not already have.
static uint8_t  gKeyFp[8];
static bool     gHaveKeyFp = false;
static uint32_t gEpochUnix = 0;    // app-pushed wall clock for this boot
static uint32_t gEpochAtMs = 0;    // millis() when that epoch arrived

// --- per-boot wall-clock anchors, PERSISTED ---------------------------------------------
// A buffered record stores whenMs (uptime at capture) + bootCount, never absolute time: the
// board has no RTC. Absolute time is reconstructed as anchor.epochUnix - (anchor.atMs - whenMs).
//
// The anchor used to live only in RAM, so it died at every reboot and EVERY record from a prior
// boot replayed as "time unknown". That is exactly the case that matters for evidence: a board
// left running unattended, whose battery dies or which power-cycles before you collect it.
// Persisting a small ring of anchors makes any boot the app ever connected during exactly
// datable, across any number of reboots in between.
//
// One anchor per boot, newest wins (a later connect in the same boot has accumulated less
// crystal drift, so overwriting is strictly better). Written once per connect, so NVS wear is
// a non-issue. 8 entries x 12 bytes = 96 bytes.
#define ANCHOR_SLOTS 8
// Largest anchor-to-capture span we will still date. Deliberately TIGHT, at 7 days.
//
// millis() wraps every 49.7 days and the unsigned-subtract-then-cast below recovers the true signed
// delta only inside the +/-24.85-day signed range. Past that, a long POSITIVE span aliases to a
// negative one: +30 days reads as -19.7 days, which a loose bound would happily accept and date
// nineteen days before the anchor. A tight bound rejects those aliases, because their magnitude
// still lands outside the window even after wrapping.
//
// 7 days is far past any realistic collect-it-later interval, and erring tight is the safe
// direction: rejecting a legitimate long span merely drops the record to approx and lets the app
// BRACKET it, which is honest, whereas accepting an aliased one prints a wrong time and calls it
// measured. For an evidence log those two failures are not remotely equal.
//
// RESIDUAL, unfixable here: a span of very nearly a full 49.7-day wrap aliases to approximately
// zero and is indistinguishable from a fresh capture. No bound catches that. It needs a board up
// for seven straight weeks with undrained records, and the app-side bracketing is the backstop.
#define ANCHOR_SPAN_MAX_MS (7L * 24L * 60L * 60L * 1000L)
struct BootAnchor { uint32_t boot; uint32_t epochUnix; uint32_t atMs; };
static BootAnchor gAnchors[ANCHOR_SLOTS];
static uint8_t    gAnchorNext = 0;   // round-robin write cursor

static void anchorsLoad() {
    Preferences p; p.begin(NVS_NS, true);
    if (p.getBytesLength("anch") == sizeof(gAnchors)) p.getBytes("anch", gAnchors, sizeof(gAnchors));
    gAnchorNext = p.getUChar("anchn", 0) % ANCHOR_SLOTS;
    p.end();
}

static void anchorsSave() {
    Preferences p; p.begin(NVS_NS, false);
    p.putBytes("anch", gAnchors, sizeof(gAnchors));
    p.putUChar("anchn", gAnchorNext);
    p.end();
}

// Record (or refresh) the anchor for `boot`. Reuses an existing slot for the same boot so one
// long session cannot evict the other seven boots' anchors.
static void anchorPut(uint32_t boot, uint32_t epochUnix, uint32_t atMs) {
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++) {
        if (gAnchors[i].boot == boot && gAnchors[i].epochUnix) {
            gAnchors[i].epochUnix = epochUnix; gAnchors[i].atMs = atMs;
            anchorsSave(); return;
        }
    }
    gAnchors[gAnchorNext] = { boot, epochUnix, atMs };
    gAnchorNext = (uint8_t)((gAnchorNext + 1) % ANCHOR_SLOTS);
    anchorsSave();
}

static const BootAnchor* anchorFor(uint32_t boot) {
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++)
        if (gAnchors[i].boot == boot && gAnchors[i].epochUnix) return &gAnchors[i];
    return nullptr;
}

// ---- low-level helpers ----
static bool ioLock() {
    return gIoMutex && xSemaphoreTake(gIoMutex, portMAX_DELAY) == pdTRUE;
}

static void ioUnlock() {
    if (gIoMutex) xSemaphoreGive(gIoMutex);
}

static uint32_t countLocked() {
    return (gHead > gOldest) ? (gHead - gOldest) : 0;
}

static void latchFaultLocked(uint32_t fault) {
    const uint32_t next = gFaults | fault;
    if (next == gFaults) return;
    gFaults = next;
    Preferences p; p.begin(NVS_NS, false); p.putUInt("fault", gFaults); p.end();
}

static bool appendBlockedLocked() {
    // Even a read fault can make a boot scan underestimate gHead and select a slot that
    // is already programmed. Once storage state is uncertain, only a full erase safely
    // establishes a new writable generation.
    return gFaults != DET_LOG_FAULT_NONE;
}

static void clearLocked();

static uint16_t crc16(const uint8_t* p, size_t n) {       // CRC-16/CCITT-FALSE
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++) c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

// AES-CTR over the encrypted payload, in place. CTR is symmetric, so the same call
// encrypts and decrypts. Nonce = bootCount(4):seq(4):0(8), unique per record.
static void cryptPayload(StoredDet* s) {
    if (!gHaveKey) return;
    uint8_t nc[16]; memset(nc, 0, sizeof(nc));
    memcpy(nc,     &s->bootCount, 4);
    memcpy(nc + 4, &s->seq,       4);
    mbedtls_aes_context ctx; mbedtls_aes_init(&ctx);
    mbedtls_aes_setkey_enc(&ctx, gKey, 256);   // CTR always uses the encrypt key
    uint8_t strm[16]; size_t off = 0;
    uint8_t* p = (uint8_t*)s + ENC_OFF;
    mbedtls_aes_crypt_ctr(&ctx, ENC_LEN, &off, nc, strm, p, p);
    mbedtls_aes_free(&ctx);
}

// SHA-256 of the key, truncated to gKeyFp. Uses the generic mbedtls_md API, which is stable
// across the mbedtls 2.x/3.x rename the ESP32 cores straddle (same reason ota_update.cpp does).
// False on a crypto failure, in which case the caller leaves the stored fingerprint alone
// rather than overwriting a good one with nothing.
static bool keyFingerprint(const uint8_t key[32], uint8_t out[8]) {
    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    uint8_t digest[32];
    if (!info || mbedtls_md(info, key, 32, digest) != 0) return false;
    memcpy(out, digest, 8);
    return true;
}

// Last line of defence on the drain. The slot CRC is over the CIPHERTEXT, so a record written
// under a DIFFERENT key passes validation and only turns to noise after cryptPayload. The
// fingerprint wipe in detLogSetKey should have erased those already; if anything ever slips
// through, noise must not reach the app, which files and maps whatever it is handed (random
// MACs, +/-214 degrees). So drop records whose decrypted fields cannot be real. Free on a good
// record, and it catches garbage with probability ~1 - 1e-6.
static bool plausibleRecord(const StoredDet* s) {
    if (s->type >= ACAB_TYPE_COUNT) return false;
    if (s->src > SRC_REMOTEID) return false;
    if (s->method > M_WATCHLIST) return false;
    if (s->conf > 100) return false;
    if (s->lat_e7 < -900000000  || s->lat_e7 > 900000000)  return false;
    if (s->lon_e7 < -1800000000 || s->lon_e7 > 1800000000) return false;
    return true;
}

static inline uint32_t slotOf(uint32_t seq) { return (seq - 1) % gSlots; }

static bool readSlot(uint32_t idx, StoredDet* s) {
    return esp_partition_read(gPart, (size_t)idx * SLOT, s, SLOT) == ESP_OK;
}

// A slot holds a valid current-generation record iff: seq is set, it maps back to
// this physical slot, and the CRC over the (still-encrypted) payload matches.
static bool slotValid(const StoredDet* s, uint32_t idx) {
    if (s->seq == 0 || s->seq == 0xFFFFFFFF) return false;
    if (slotOf(s->seq) != idx) return false;
    return crc16((const uint8_t*)s + ENC_OFF, ENC_LEN) == s->crc;
}

// Entering a sector physically evicts every old slot in it. Move the logical floor at the
// same moment the erase succeeds, even if the following record write fails. Otherwise status
// counts records that no longer exist until the remaining 63 slots are rewritten.
static bool prepareSlotLocked(uint32_t seq, uint32_t idx) {
    if (idx % PER_SECTOR != 0) return true;
    if (esp_partition_erase_range(gPart, (size_t)idx * SLOT, SECTOR) != ESP_OK) {
        latchFaultLocked(DET_LOG_FAULT_ERASE);
        return false;
    }
    if (seq > gSlots) {
        const uint32_t afterErasedSector = seq - gSlots + (uint32_t)PER_SECTOR;
        if (afterErasedSector > gOldest) gOldest = afterErasedSector;
    }
    return true;
}

// Payload first, then the 12B header (seq/bootCount/crc/pad). A torn write normally leaves
// the header erased (seq=0xFFFFFFFF), so the slot reads as empty rather than half-valid. Either
// failed call blocks further appends until a successful clear because a non-sector slot cannot
// be safely retried without first erasing other valid records in its sector.
static bool writeSlotLocked(uint32_t idx, const StoredDet* s) {
    if (esp_partition_write(gPart, (size_t)idx * SLOT + ENC_OFF,
                            (const uint8_t*)s + ENC_OFF, ENC_LEN) != ESP_OK) {
        latchFaultLocked(DET_LOG_FAULT_WRITE);
        return false;
    }
    if (esp_partition_write(gPart, (size_t)idx * SLOT, s, ENC_OFF) != ESP_OK) {
        latchFaultLocked(DET_LOG_FAULT_WRITE);
        return false;
    }
    return true;
}

// Decrypt-in-place must already have happened; map the stored fields back to a live
// detection so the BLE layer can serialize it exactly like a fresh hit.
static void unpackToDetection(const StoredDet* s, AcabDetection* d) {
    acabInit(d, (AcabDeviceType)s->type, (AcabSource)s->src, s->mac, s->rssi);
    d->method     = (AcabMethod)s->method;
    d->confidence = s->conf;
    d->lat   = (double)s->lat_e7 / 1e7;
    d->lon   = (double)s->lon_e7 / 1e7;
    d->count = s->count;
    d->gpsAgeMs = (uint32_t)s->gpsAgeSec * 1000;
    d->lastSeen = s->whenMs;
    memcpy(d->id,   s->uasid, sizeof(s->uasid)); d->id[sizeof(s->uasid)]   = '\0';
    memcpy(d->name, s->name,  sizeof(s->name));  d->name[sizeof(s->name)]  = '\0';
}

// ---- public API ----
void detLogBegin() {
    if (!gIoMutex) gIoMutex = xSemaphoreCreateMutexStatic(&gIoMutexStorage);
    if (!gIoMutex) {
        gFaults |= DET_LOG_FAULT_LOCK;
        gSlots = 0;
        return;
    }
    gPart = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, PART_LABEL);
    if (!gPart) { gSlots = 0; return; }              // no data partition -> buffering unavailable
    // Only expose complete erase sectors as slots. This keeps every sector erase inside the
    // partition and makes the ring length an exact multiple of the physical eviction unit.
    gSlots = (uint32_t)(gPart->size / SECTOR) * (uint32_t)PER_SECTOR;
    if (gSlots == 0) return;

    // A wipe latched by detLogClear() but cut short by a power loss must be honoured BEFORE
    // trusting the boot scan: not-yet-erased old-generation slots still carry a valid seq/CRC,
    // so the scan would resurrect exactly the records the wipe promised to destroy (the
    // seizure posture in det_log.h). Re-arm the deferred sweep and skip the scan - the ring's
    // contents are condemned either way, and detLogAppend holds off until the sweep completes.
    {
        Preferences p; p.begin(NVS_NS, true);
        gFaults = p.getUInt("fault", DET_LOG_FAULT_NONE);
        if (p.getBool("wipe", false)) { gWipeNext = 0; gWipePending = true; }
        p.end();
    }

    // Boot scan: find the exact contiguous live window. Using maxSeq-gSlots as the floor is
    // wrong for a sector-erased ring: the first write after wrap erases 64 old records at once,
    // so the valid floor jumps by 64 while maxSeq advances by only one. minSeq reconstructs that
    // physical fact after reboot. A damaged internal hole falls back to the newest contiguous
    // suffix so count and drain never advertise records that are not actually readable.
    uint32_t maxSeq = 0;
    uint32_t minSeq = 0xFFFFFFFFu;
    uint32_t validCount = 0;
    if (!gWipePending) {
        StoredDet s;
        for (uint32_t i = 0; i < gSlots; i++) {
            if (!readSlot(i, &s)) { latchFaultLocked(DET_LOG_FAULT_READ); continue; }
            if (!slotValid(&s, i)) {
                if (s.seq != 0 && s.seq != 0xFFFFFFFFu) latchFaultLocked(DET_LOG_FAULT_CORRUPT);
                continue;
            }
            if (s.seq > maxSeq) maxSeq = s.seq;
            if (s.seq < minSeq) minSeq = s.seq;
            validCount++;
        }
        if (maxSeq && (minSeq == 0xFFFFFFFFu || validCount != maxSeq - minSeq + 1)) {
            latchFaultLocked(DET_LOG_FAULT_CORRUPT);
            uint32_t suffixOldest = maxSeq;
            for (uint32_t n = 0; n < gSlots && maxSeq > n; n++) {
                const uint32_t seq = maxSeq - n;
                if (!readSlot(slotOf(seq), &s)) {
                    latchFaultLocked(DET_LOG_FAULT_READ);
                    break;
                }
                if (!slotValid(&s, slotOf(seq)) || s.seq != seq) break;
                suffixOldest = seq;
            }
            minSeq = suffixOldest;
        }
    }
    gHead   = maxSeq + 1;
    gOldest = maxSeq ? minSeq : 1;
    gDrain  = (gOldest > 0) ? gOldest - 1 : 0;
    gDraining = false;

    // Persisted opt-in flag + monotonic boot counter, and the last-connect boot for auto-wipe.
    Preferences p; p.begin(NVS_NS, false);
    gEnabled = p.getBool("on", false);
    gBufferAll = p.getBool("bufall", false);
    gSaturated = p.getBool("bufsat", false);   // survives the reboots a deployment guarantees
    gFaults |= p.getUInt("fault", DET_LOG_FAULT_NONE);
    // Reload a persisted at-rest key so deploy-and-leave buffering survives a reboot
    // instead of going keyless until the app reconnects (see the SECURITY note in det_log.h).
    if (gEnabled && p.getBytesLength("key") == 32) { p.getBytes("key", gKey, 32); gHaveKey = true; }
    // The fingerprint reload is deliberately NOT gated on gEnabled or on the key above: the
    // records it protects survive a disable and a reboot, so the guard must too (see gKeyFp).
    if (p.getBytesLength("keyfp") == sizeof(gKeyFp)) {
        p.getBytes("keyfp", gKeyFp, sizeof(gKeyFp));
        gHaveKeyFp = true;
    }
    gBoot    = p.getUInt("boot", 0) + 1;
    p.putUInt("boot", gBoot);
    uint32_t lastConn = p.getUInt("lastconn", gBoot);
    p.end();
    // Reload the persisted per-boot wall-clock anchors. This is what lets a record captured in an
    // EARLIER boot still replay with an exact time, which is the whole point of persisting them.
    anchorsLoad();

    // Auto-wipe: undrained across too many reboots -> erase. The threshold widens while
    // "record everything" is on, because the owner has declared the board is deliberately
    // unattended and boot count stops meaning "seized" (see WIPE_AFTER_BOOTS_DEPLOY).
    //
    // gEnabled is in the test ON PURPOSE. The three switches (buffer / bufall / desert) persist
    // INDEPENDENTLY, so "buffering off, bufall still true" is reachable, and in that state a
    // board that is not recording anything would otherwise keep the weakened self-clean posture
    // indefinitely. Weakened seizure protection must never outlive the feature that asked for it.
    // detLogSetEnabled below also clears bufall, so this is belt-and-braces against an NVS write
    // that failed to land; the read is free and the failure it covers is silent.
    const uint32_t wipeAfter = (gEnabled && gBufferAll) ? WIPE_AFTER_BOOTS_DEPLOY : WIPE_AFTER_BOOTS;
    if (maxSeq > 0 && (gBoot - lastConn) >= wipeAfter) detLogClear();
}

// See the long note in det_log.h. Persisted so a deployed board keeps recording across the
// brownout resets that a week in the field guarantees; without persistence this switch would
// silently revert on the first reset and the deployment would quietly collect nothing.
void detLogSetBufferAll(bool on) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (on == gBufferAll) { ioUnlock(); return; }
    gBufferAll = on;
    Preferences p; p.begin(NVS_NS, false);
    p.putBool("bufall", on);
    p.end();
    ioUnlock();
}
bool detLogBufferAll() {
    // Deliberately LOCK-FREE. Callers include the radio hot paths (handleDetection runs inside
    // the promiscuous RX callback and the BLE ingest path), and gIoMutex is held across multi-ms
    // flash erases (a 4 KB sector every 64 appends, 64 KB blocks during a wipe), so taking it
    // here stalled frame RX for the duration of every erase. An aligned bool read is atomic on
    // this core, the value only changes on an app config write, and the old lock-timeout
    // fallback already returned the unlocked read - one-advert staleness is harmless.
    return gBufferAll;
}

// True once the ring has refused at least one uncategorized record because it was full, i.e. the
// tail of this log is censored. PERSISTED, so it survives the deployment's reboots. Cleared only
// by detLogClear, because a wipe starts a genuinely fresh log.
bool detLogSaturated() {
    if (!ioLock()) return gSaturated;
    const bool value = gSaturated;
    ioUnlock();
    return value;
}
uint32_t detLogSatDrops() {
    if (!ioLock()) return gSatDrops;
    const uint32_t value = gSatDrops;
    ioUnlock();
    return value;
}

static void clearKeyLocked() {
    memset(gKey, 0, 32);
    gHaveKey = false;
    // gKeyFp deliberately SURVIVES this, in RAM and in NVS. Dropping the key does not drop the
    // records it encrypted, so the fingerprint is the only thing left that can recognise a
    // different phone's key arriving for them (see gKeyFp).
    Preferences p; p.begin(NVS_NS, false); p.remove("key"); p.end();
}

void detLogSetEnabled(bool on) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (on == gEnabled) { ioUnlock(); return; }
    gEnabled = on;
    Preferences p; p.begin(NVS_NS, false);
    p.putBool("on", on);
    if (on && gHaveKey) p.putBytes("key", gKey, 32);   // persist a key that arrived before enable
    // Turning the MASTER switch off ends the deployment, so the deploy-only sub-mode goes with it
    // rather than lingering as orphaned state that still selects the weakened wipe threshold and
    // still admits nearby devices the moment buffering is re-enabled for ordinary use.
    //
    // The counter-argument, recorded so it is not re-litigated from scratch: this snaps the wipe
    // threshold back to 6, so brownouts could erase a ring the owner had not drained yet. It does
    // not bite in practice, because the natural end-of-deployment action is CONNECTING, which
    // refreshes "lastconn" and resets the timer; and a board merely collected and driven home is
    // untouched here, since nobody flipped this switch. Reaching this path takes a deliberate act.
    if (!on) { gBufferAll = false; p.putBool("bufall", false); }
    p.end();
    if (!on) clearKeyLocked();                         // stop capturing; forget the key (RAM + NVS)
    ioUnlock();
}
bool detLogEnabled() {
    if (!ioLock()) return gEnabled;
    const bool value = gEnabled;
    ioUnlock();
    return value;
}

void detLogSetKey(const uint8_t key[32]) {
    // Records are encrypted under whatever key was active when each was written, and the
    // slot CRC is over CIPHERTEXT, so a mismatched key still passes the CRC and would
    // decrypt old records to GARBAGE on drain. If a DIFFERENT key arrives while records
    // are buffered, those records are no longer decryptable, so wipe them rather than
    // ship garbage. Normal reconnects push the same per-device key (no-op); this fires
    // on a genuine key change (a new / reinstalled phone re-bonding a deployed board).
    //
    // Compared against the PERSISTED FINGERPRINT, never against gKey: gKey is empty in exactly
    // the cases that matter (buffering turned off, or a reboot while off, both of which keep
    // every record), so a gHaveKey-conditioned guard cannot fire there. See gKeyFp. Erasing on
    // disable instead is NOT the answer: the original phone still holds its key, so its records
    // stay legitimately drainable, and a buffer toggled off mid-drain would silently truncate
    // the user's own replay.
    uint8_t fp[8];
    bool haveFp = keyFingerprint(key, fp);
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (haveFp && gHaveKeyFp && memcmp(gKeyFp, fp, sizeof(fp)) != 0 && countLocked() > 0) clearLocked();
    memcpy(gKey, key, 32);
    gHaveKey = true;
    Preferences p; p.begin(NVS_NS, false);
    if (haveFp) { memcpy(gKeyFp, fp, sizeof(fp)); gHaveKeyFp = true; p.putBytes("keyfp", gKeyFp, sizeof(gKeyFp)); }
    // Persist the KEY ITSELF only while buffering is enabled, so it never sits in flash while
    // buffering is off (the app pushes the key on every connect, including when off). When
    // on, this is the deploy-and-leave reboot-survival path; SECURITY TRADEOFF: a seized
    // board's flash then yields the key (see det_log.h). A key that arrives before the
    // enable is re-persisted by detLogSetEnabled(true).
    if (gEnabled) p.putBytes("key", gKey, 32);
    p.end();
    ioUnlock();
}
void detLogClearKey() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    clearKeyLocked();
    ioUnlock();
}
bool detLogHaveKey() {
    if (!ioLock()) return gHaveKey;
    const bool value = gHaveKey;
    ioUnlock();
    return value;
}

void detLogSetEpoch(uint32_t unixSec) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    gEpochUnix = unixSec; gEpochAtMs = millis();
    // Persist it against THIS boot, so records captured in this boot stay datable even if the
    // board reboots before the app next connects.
    anchorPut(gBoot, gEpochUnix, gEpochAtMs);
    ioUnlock();
}

void detLogAppend(const AcabDetection& d) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    // Recheck every admission condition while holding the same lock as clear, key changes,
    // and the wipe tick. A caller that arrived just before one of those transitions cannot
    // commit a stale-key record or write behind an erase that already promised an empty log.
    if (!gEnabled || !gHaveKey || gSlots == 0 || acabBleClientConnected()) {
        ioUnlock();
        return;                                      // only buffer while the app is away
    }
    // ONCE THE RING IS FULL, UNCATEGORIZED ROWS STOP APPENDING. Signature hits still append and
    // still evict oldest-first as always; only ACAB_NEARBY_DEVICE is capped.
    //
    // The ring is strictly FIFO and type-blind (see the gOldest advance below), unlike the dedup
    // table, which deliberately evicts the oldest NEARBY_DEVICE first. acab_scanner.cpp says both
    // halves are what make Desert safe: "the eviction priority in dedupFind() plus the type gate
    // on buffering, NOT the size". detLogBufferAll relaxes the type gate, which leaves the ring
    // with no type protection at all.
    //
    // The failure that closes: the owner collects a deployed board and drives home with it still
    // powered and still armed. The app is disconnected - that is the mode's own premise - so the
    // guard above never fires, and both bufall and desert now survive the reboot. The 2026-07-24
    // drive logged 9,795 unique BLE + 10,296 unique WiFi devices in ~104 minutes against 24,576
    // slots. That is ~82% of the ring on first sightings, and dedup thrash re-buffering the same
    // devices (see the REBUFFER note in acab_scanner.cpp) carries it the rest of the way, so one
    // drive home wraps it and silently overwrites the
    // week the board was left there to record.
    //
    // TRADEOFF, deliberate: on a genuinely saturated deployment this drops the TAIL of nearby
    // devices instead of the head. For "did anything come by while I was gone" that is the right
    // end to lose, and it is strictly better than losing the whole deployment on the way home.
    //
    // AND IT MUST NOT BE SILENT. A dropped tail with no marker hands the owner a full-looking log
    // whose last hours or days are censored, with nothing to distinguish "nothing came by after
    // Tuesday" from "we stopped writing on Tuesday". That is the same class of unfalsifiable
    // absence this project has already been bitten by twice. gSatDrops counts this boot; the
    // persisted flag survives the reboots a week in the field guarantees, and is what the app
    // must surface beside the log.
    if (d.type == ACAB_NEARBY_DEVICE && countLocked() >= gSlots) {
        gSatDrops++;
        if (!gSaturated) {          // ONE NVS write per deployment, not one per dropped record
            gSaturated = true;
            Preferences p; p.begin(NVS_NS, false); p.putBool("bufsat", true); p.end();
        }
        ioUnlock();
        return;
    }
    if (gWipePending || appendBlockedLocked()) {
        ioUnlock();
        return;
    }

    // gHead is only a candidate until every flash operation succeeds. Advancing it first makes
    // a failed write look like a stored record in count/status and creates a hole in replay.
    const uint32_t seq = gHead;

    StoredDet s; memset(&s, 0, sizeof(s));
    s.seq       = seq;
    s.bootCount = gBoot;
    s.whenMs    = d.lastSeen ? d.lastSeen : millis();
    s.type = (uint8_t)d.type; s.src = (uint8_t)d.src;
    s.method = (uint8_t)d.method; s.conf = d.confidence;
    memcpy(s.mac, d.mac, 6);
    s.rssi   = d.rssi;
    s.lat_e7 = (int32_t)(d.lat * 1e7);
    s.lon_e7 = (int32_t)(d.lon * 1e7);
    s.gpsAgeSec = (d.gpsAgeMs / 1000 > 0xFFFF) ? 0xFFFF : (uint16_t)(d.gpsAgeMs / 1000);
    s.count  = d.count;
    strncpy(s.uasid, d.id,   sizeof(s.uasid));       // drone identity (truncated)
    strncpy(s.name,  d.name, sizeof(s.name));

    cryptPayload(&s);                                // encrypt payload in place
    s.crc = crc16((const uint8_t*)&s + ENC_OFF, ENC_LEN);   // CRC over ciphertext
    const uint32_t idx = slotOf(seq);
    if (prepareSlotLocked(seq, idx) && writeSlotLocked(idx, &s)) {
        gHead = seq + 1;
        if (gHead - gOldest > gSlots) gOldest = gHead - gSlots;
    }
    ioUnlock();
}

void detLogStartDrain(uint32_t lastSeq) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (gSlots == 0) { ioUnlock(); return; }
    // A cursor at/above gHead is exact proof of a generation reset (the board only ever issues
    // seqs < gHead): a board-side wipe the phone never saw (auto-wipe after undrained reboots,
    // or the key-change wipe) restarted seq at 1 while the app kept its old cursor. Without
    // this clamp gDrain = lastSeq arms nothing - no begin/end sentinel, no error - and new
    // records stay undeliverable until the new generation climbs past the stale cursor
    // (months), with status "buf" growing the whole time. Rebase to the ring floor instead;
    // the {"hist":"begin"} sentinel carries "from" so the app can rebase its own cursor.
    if (lastSeq >= gHead) lastSeq = 0;
    // Resume from the app's cursor, but never before the oldest record still in the ring.
    uint32_t floor = (gOldest > 0) ? gOldest - 1 : 0;
    gDrain    = (lastSeq > floor) ? lastSeq : floor;
    gDraining = (gDrain + 1 < gHead);
    Preferences p; p.begin(NVS_NS, false); p.putUInt("lastconn", gBoot); p.end();  // reset auto-wipe timer
    ioUnlock();
}

bool detLogDraining() {
    if (!ioLock()) return false;
    const bool value = gDraining;
    ioUnlock();
    return value;
}

// Abort an in-flight drain (link dropped mid-replay). The next reconnect must re-arm via
// detLogStartDrain (the app's {sync}) rather than resume from a stale cursor with no
// {"hist":"begin"} lead-in. Idempotent; leaves gDrain where it was (the {sync} rebases it).
void detLogStopDrain() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    gDraining = false;
    ioUnlock();
}

bool detLogNextForDrain(DetLogReplay* out) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return false; }
    if (!out || !gDraining || gSlots == 0) {
        gDraining = false;
        ioUnlock();
        return false;
    }
    if (gDrain + 1 < gOldest) gDrain = gOldest - 1;  // sector erase advanced the floor
    if (gDrain + 1 >= gHead) {
        gDraining = false;
        ioUnlock();
        return false;
    }

    const uint32_t seq = gDrain + 1;
    StoredDet s;
    if (!readSlot(slotOf(seq), &s)) {
        latchFaultLocked(DET_LOG_FAULT_READ);
        gDraining = false;
        ioUnlock();
        return false;
    }
    if (!slotValid(&s, slotOf(seq)) || s.seq != seq) {
        latchFaultLocked(DET_LOG_FAULT_CORRUPT);
        // Keep only the newer contiguous suffix. This record and everything older can no
        // longer be represented by an exact count, while newer records remain independently
        // valid. The current drain aborts so the client sees the short transfer and resyncs.
        gOldest = seq + 1;
        if (gOldest > gHead) gOldest = gHead;
        gDrain = seq;
        gDraining = false;
        ioUnlock();
        return false;
    }

    cryptPayload(&s);                                // decrypt in place
    if (!plausibleRecord(&s)) {
        latchFaultLocked(DET_LOG_FAULT_CORRUPT);
        gOldest = seq + 1;
        if (gOldest > gHead) gOldest = gHead;
        gDrain = seq;
        gDraining = false;
        ioUnlock();
        return false;
    }
    unpackToDetection(&s, &out->d);
    out->seq = seq;
    gDrain = seq;                                    // commit cursor only after a valid replay record
    // Absolute time from THIS RECORD'S boot anchor, not just the current boot's. Anchors are
    // persisted (see anchorPut), so a record survives any number of reboots between capture and
    // collection and stays exactly datable, as long as the app connected at least once during
    // the boot that captured it. That is the evidence case: a board left running, whose battery
    // dies before you come back for it.
    // Always hand up whenMs + bootCount regardless, so the app can BRACKET a record from a boot
    // that was never anchored ("after the last anchored time of boot N, before the first of
    // boot N+1") instead of showing a bare "time unknown".
    out->whenMs    = s.whenMs;
    out->bootCount = s.bootCount;
    const BootAnchor* a = anchorFor(s.bootCount);
    if (a) {
        // SIGNED both ways. A capture can sit on EITHER side of its anchor:
        //   BEFORE it, for the boot being drained right now, because the app pushes a fresh
        //     epoch on connect and that refreshed anchor is newer than everything buffered.
        //   AFTER it, for every PRIOR boot. The board only buffers while disconnected, and it
        //     only anchors on a sync push, so a prior boot's records were necessarily captured
        //     after that boot's last sync. This is not the rare case, it is ALL of them.
        // The first version of this only handled the backward direction and clamped the other
        // to zero, which silently dated every prior-boot record AT its anchor and still called
        // it non-approx. A board that collected for eight hours after you walked away and then
        // lost power replayed those eight hours all stamped with the moment you last synced,
        // presented as measured. Strictly worse than the pre-anchor behaviour, which at least
        // reported approx and let the app bracket it.
        // Uptime is monotonic within a boot, so forward reconstruction is exactly as sound as
        // backward; there is no reboot between the anchor and the capture, that is what the
        // bootCount match guarantees.
        // Unsigned subtract then cast is the wrap-correct signed difference, so a millis()
        // rollover between anchor and capture still yields the right delta as long as the true
        // span is under the 24.85-day signed range. Beyond ANCHOR_SPAN_MAX_MS we cannot tell a
        // wrap from a genuinely huge gap, so we decline to date it rather than guess.
        int32_t deltaMs = (int32_t)(s.whenMs - a->atMs);
        if (deltaMs > -ANCHOR_SPAN_MAX_MS && deltaMs < ANCHOR_SPAN_MAX_MS) {
            out->atUnix = (uint32_t)((int64_t)a->epochUnix + (int64_t)deltaMs / 1000);
            out->approx = false;
        } else {
            out->atUnix = 0;
            out->approx = true;                      // uptime span implausible -> let the app bracket
        }
    } else {
        out->atUnix = 0;
        out->approx = true;                          // unanchored boot -> app brackets it by seq/boot
    }
    ioUnlock();
    return true;
}

static void clearLocked() {
    if (gSlots == 0) return;
    // LOGICAL clear now, PHYSICAL erase deferred. This runs on the NimBLE host task (the
    // {"clearlog"} config write and detLogSetKey's key-change wipe), where the old synchronous
    // full-partition erase (~24 64KB block erases, each a cache-off stall for BOTH cores) froze
    // GATT and scanning for seconds. Resetting the cursors is microseconds and immediately
    // restores the guarantees that matter: detLogCount() reads 0, and a {"sync"} later in the
    // same handshake arms nothing over the condemned records.
    // Advance the generation so post-clear records (which restart at seq=1) never reuse an
    // AES-CTR nonce (bootCount:seq) from the records being erased - reuse would XOR two
    // plaintexts under one keystream. Each record stores its own bootCount cleartext, so
    // replay still decrypts. Matters for the runtime {clearlog} command; harmless on the
    // boot-time auto-wipe path (no key/records present yet).
    gBoot++;
    // Persist the wipe latch BEFORE arming the in-RAM sweep: once this NVS commit lands, a
    // power loss resumes the erase in detLogBegin instead of resurrecting the ring.
    Preferences p; p.begin(NVS_NS, false);
    p.putUInt("boot", gBoot);
    p.putBool("wipe", true);
    p.putBool("bufsat", false);   // the censored-tail marker is per-log; this is a new log
    p.end();
    // Publish the empty logical generation only after the persistent wipe latch has been
    // attempted. The mutex keeps append and drain out across both transitions.
    gHead = 1; gOldest = 1; gDrain = 0; gDraining = false;
    // A wipe starts a genuinely fresh log, so the censored-tail marker clears with it. Left set,
    // it would permanently mark every future log as truncated and the warning would stop meaning
    // anything, which is worse than not having it.
    gSaturated = false; gSatDrops = 0;
    gWipeNext = 0;
    gWipePending = true;
    gWipeStalled = false;
}

void detLogClear() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    clearLocked();
    ioUnlock();
}

// One chunk of a latched wipe: erase a single 64KB flash block per call. Runs on the loop
// task (pumped by acabBleDrainTick), NEVER the NimBLE host task - each block erase disables
// the flash cache for ~100-250ms, and chunking with a loop-pass gap between blocks keeps
// GATT, scanning, and the sink task live across the sweep instead of a device-wide stall.
void detLogEraseTick() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (!gWipePending || gWipeStalled || gSlots == 0) { ioUnlock(); return; }
    const uint32_t off = gWipeNext;
    const uint32_t ringBytes = gSlots * (uint32_t)SLOT;
    uint32_t n = ringBytes - off;
    if (n > WIPE_BLOCK) n = WIPE_BLOCK;
    if (n && esp_partition_erase_range(gPart, off, n) != ESP_OK) {
        latchFaultLocked(DET_LOG_FAULT_ERASE);
        // Do not hammer a failing flash block on every loop pass. The persisted wipe latch
        // remains set and appends remain blocked. Another explicit clear or a reboot retries.
        gWipeStalled = true;
        ioUnlock();
        return;
    }
    gWipeNext = off + n;
    if (gWipeNext >= ringBytes) {
        gWipePending = false;
        gWipeStalled = false;
        gFaults = DET_LOG_FAULT_NONE;
        Preferences p; p.begin(NVS_NS, false);
        p.putBool("wipe", false);
        p.putUInt("fault", DET_LOG_FAULT_NONE);
        p.end();
    }
    ioUnlock();
}

bool detLogWipePending() {
    if (!ioLock()) return gWipePending;
    const bool value = gWipePending;
    ioUnlock();
    return value;
}

uint32_t detLogCount() {
    if (!ioLock()) return 0;
    const uint32_t value = countLocked();
    ioUnlock();
    return value;
}

// Records still queued for the current drain (seq in (gDrain, gHead)). Valid after
// detLogStartDrain, which clamps gDrain to >= gOldest-1, so none of these are evicted and this
// equals exactly what the replay will send. 0 when no drain is armed / nothing is queued.
uint32_t detLogPendingDrain() {
    if (!ioLock()) return 0;
    const uint32_t value = gDraining && gHead > gDrain + 1 ? gHead - 1 - gDrain : 0;
    ioUnlock();
    return value;
}

// Next seq the armed drain will send (gDrain + 1). Carried as "from" in the {"hist":"begin"}
// sentinel so the app can rebase its persisted cursor after a board-side wipe reset the seq
// generation (see the clamp in detLogStartDrain) - otherwise every reconnect re-replays the
// whole ring until the new generation climbs past the stale cursor.
uint32_t detLogDrainFrom() {
    if (!ioLock()) return 0;
    const uint32_t value = gDrain + 1;
    ioUnlock();
    return value;
}

uint32_t detLogFaults() {
    if (!ioLock()) return gFaults | DET_LOG_FAULT_LOCK;
    const uint32_t value = gFaults;
    ioUnlock();
    return value;
}

#ifdef ACAB_HOST_TEST
void detLogHostResetRuntime() {
    if (!gIoMutex) gIoMutex = xSemaphoreCreateMutexStatic(&gIoMutexStorage);
    if (!ioLock()) return;
    gPart = nullptr;
    gSlots = 0;
    gHead = 1;
    gOldest = 1;
    gBoot = 0;
    gDrain = 0;
    gDraining = false;
    gWipePending = false;
    gWipeNext = 0;
    gWipeStalled = false;
    gEnabled = false;
    gBufferAll = false;
    gSaturated = false;
    gSatDrops = 0;
    gFaults = DET_LOG_FAULT_NONE;
    memset(gKey, 0, sizeof(gKey));
    gHaveKey = false;
    memset(gKeyFp, 0, sizeof(gKeyFp));
    gHaveKeyFp = false;
    gEpochUnix = 0;
    gEpochAtMs = 0;
    memset(gAnchors, 0, sizeof(gAnchors));
    gAnchorNext = 0;
    ioUnlock();
}
#endif
