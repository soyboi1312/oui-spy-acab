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
 * and can never look valid; boot also checks that such a slot is fully erased before
 * considering it reusable.
 *
 * At rest the payload (whenMs..name) is AES-CTR encrypted with the app-pushed key;
 * seq/bootCount/crc stay cleartext so the boot scan works without the key. Format 2's
 * CRC covers every clear header field plus the ciphertext, so torn writes are caught
 * before any decrypt and cannot silently alter the nonce/timestamp metadata.
 */
#include "det_log.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_partition.h>
#include <mbedtls/aes.h>
#include <mbedtls/md.h>
#include <esp_random.h>
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
// Format 2 authenticates the cleartext nonce/timestamp header as well as ciphertext. Format 1's
// payload-only CRC cannot distinguish a torn/mutated bootCount or gpsAgeSec. There is no safe dual
// reader for that ambiguity, so an absent/older marker durably condemns and erases the ring before
// format 2 is published; rows are never guessed across the migration boundary.
static const uint8_t  RING_FORMAT = 2;
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
static uint32_t gMaxScannedBoot = 0; // highest valid row boot; guards nonce/anchor ID regression
// Sequence numbers restart after a logical clear, so they are not by themselves a durable replay
// cursor. `loggen` changes only at a logical ring generation boundary (not at every physical boot),
// while `wipegen` is the power-loss tombstone for a not-yet-retired target generation.
static uint32_t gLogGeneration = 0;
static uint32_t gWipeTargetGeneration = 0;
static uint8_t  gCryptoDomain[16] = {};
static uint8_t  gWipeTargetCryptoDomain[16] = {};
static uint32_t gDrain    = 0;     // drain cursor: the next record sent has seq > gDrain
// Queue-admission epoch shared with acab_scanner. Disconnect first advances it into a blocked
// reservation, then admits it only after BLE has torn down link-owned GPS/replay/key state; claimed
// appends compare it while holding gIoMutex, alongside the link/key/wipe checks.
static uint32_t gCaptureAdmissionEpoch = 1;
// Raised at successful authentication before GPS/config preparation AND at disconnect before
// connected=false. It closes both prior-owner queue windows. The disconnect block remains raised
// through teardown and is admitted with the new scanner generation only after key cleanup.
static bool gCaptureAdmissionBlocked = false;
// Set only when the epoch mutex could not be acquired. Accessed atomically because that failure
// path, by definition, cannot use gIoMutex; claimed appends read it after acquiring the mutex.
static bool gCaptureAdmissionInvalid = false;
static bool     gDraining = false;
// Process-local capability epoch for the two-phase replay API. uint64 makes wrap/ABA theoretical
// rather than operational; it is protected by gIoMutex, so 32-bit target accesses cannot tear.
// A reboot cannot retain a DetLogReplay object, therefore this does not belong in NVS.
static uint64_t gDrainGeneration = 0;

// Deferred physical wipe (see detLogClear): the logical clear is instant, then loop()
// (detLogEraseTick, pumped via acabBleDrainTick) erases the ring one 64KB block per pass so
// the NimBLE host task never eats the multi-second full-partition erase. The pending flag is
// ALSO persisted to NVS ("wipe") so a power loss mid-sweep resumes at boot instead of letting
// the boot scan resurrect not-yet-erased old-generation records (their seq/CRC still validate).
static bool              gWipePending = false;
static uint32_t          gWipeNext    = 0;         // next partition offset to erase
static bool              gWipeStalled = false;    // one failed tick waits for an explicit clear or reboot
// The ring erase latch has two NVS commit boundaries. Until `wipe=true` is durable, a requested
// clear must not publish an empty generation that a power loss could resurrect; after the last
// flash block is gone, appends must stay blocked until `wipe=false` is durable, or a later reboot
// would erase the new rows. A boot-time NVS-open failure similarly defers the raw-ring scan rather
// than interpreting an unread latch as false.
static bool              gWipeArmPending = false;
static uint32_t          gWipeArmBoot = 0;
static bool              gWipeLoadPending = false;
static bool              gRingFormatPending = true;
static bool              gRingScanReady = false;
static bool              gAutoWipeCheckPending = false;
// Config, retained key/fingerprint, and the incremented boot nonce generation are one startup
// readiness boundary. A failed NVS open/write leaves this true and blocks append + replay until
// detLogEraseTick reloads everything and durably commits the next boot counter.
static bool              gStartupConfigPending = true;
static bool              gRingClearDeferred = false;
static bool              gExplicitClearPending = false;
static const uint32_t    WIPE_BLOCK   = 64 * 1024; // one flash block erase (~100-250ms) per tick

// A retained IDF core dump is a second sensitive flash surface: its task stacks can contain the
// at-rest key, decrypted rows, and the phone's coordinates. User-driven destructive actions carry
// a SEPARATE, persisted generation token instead of being inferred from gWipePending: that level
// is shared with boot-count auto-wipes, remains high across an in-flight sweep, and is restored
// already-high after a power loss. A generation (rather than a bool) also makes completion safe
// when another explicit request arrives while an erase is waiting or in flight.
static uint32_t          gSensitiveEraseGen = 0;      // 0 = no pending request
static uint32_t          gSensitiveEraseCounter = 0;  // last issued generation; remains after ack
// If NVS temporarily rejects a NEW request, retain the desired generation in RAM and retry it
// from detLogSensitiveErasePending() on the loop task. It is deliberately separate from
// gSensitiveEraseGen: that public value may change only after `cdwipe` is durably stored.
static uint32_t          gSensitiveEraseRetryGen = 0;
// `cdwipe` is the safety-critical token. `cdgen` only prevents generation reuse across completed
// requests, and boot can reconstruct it from a pending token, so a failed counter write does not
// delay a physically safe erase; it is retried independently.
static bool              gSensitiveEraseCounterDirty = false;
// A failed NVS open at boot must not turn an already-durable cdwipe into "no request" for the
// whole session. The loop retries the LOAD before returning any pending generation. A user action
// arriving in that narrow pre-loop window is deferred until the old counter is known, so it cannot
// overwrite generation N with a falsely restarted generation 1.
static bool              gSensitiveEraseLoadPending = false;
static bool              gSensitiveEraseRequestDeferred = false;
// A key pushed for replay while buffering is disabled is intentionally RAM-only, but a panic can
// copy that RAM into the retained core-dump partition. Before such a key is published, pin a fresh
// durable erase generation; its completion is refused until the key (or a staged replacement) is
// gone. This also prevents a loop-side erase racing between token persistence and key publication.
static bool              gDisabledKeyEraseArmed = false;
static bool              gKeyChangeEraseArmed = false;
// Once a replay-only key has touched the BLE callback/det_log stacks, clearing the live buffers
// cannot prove every stale stack byte is gone. Keep the erase generation non-retirable for this
// entire physical boot. A clean reboot drops the RAM hold and can acknowledge an empty probe; a
// panic reboot reloads the durable token and erases the newly retained dump first.
static bool              gSensitiveStackExposedThisBoot = false;

// One mutex owns every raw-flash operation and every cursor transition that describes that
// flash. A spinlock cannot cover erase/write because flash operations may block with the cache
// disabled. The mutex makes both clear/append orderings safe:
//   - append first: its complete record is then condemned by the clear sweep;
//   - clear first: append observes gWipePending after it gets the lock and writes nothing.
// Drain reads use the same lock, so a wipe cannot erase a slot while it is being replayed.
static StaticSemaphore_t gIoMutexStorage;
static SemaphoreHandle_t gIoMutex = nullptr;
// Serializes owner-epoch transitions with the final scanner sink callback. This is deliberately
// separate from gIoMutex: BLE JSON builders take their own pool lock and then snapshot det_log,
// so holding gIoMutex through gSink would invert JsonPoolLock -> gIoMutex and deadlock. No path
// may acquire this mutex while already holding gIoMutex.
static StaticSemaphore_t gCaptureDeliveryMutexStorage;
static SemaphoreHandle_t gCaptureDeliveryMutex = nullptr;

static bool     gEnabled  = false;
static bool     gEnableTransitionPending = false;
static bool     gPendingEnabled = false;
// Public privacy actions are published only after a retained-dump erase token is durable. A
// transient first-token failure keeps the old complete config intact but remembers the action for
// this boot; power loss safely drops the RAM-only request and restores that intact config.
static bool     gDisableAwaitingEraseToken = false;
static bool     gClearKeyAwaitingEraseToken = false;
// Once a disable has begun, later enable intent may not cancel its residual-key/privacy cleanup.
// The off transaction completes first; gPendingEnabled can then request a separate re-enable.
static bool     gDisableCleanupPending = false;
static bool     gKeyPersistencePending = false;
static bool     gKeyRemovalPending = false;
static bool     gBufferAllTransitionPending = false;
static bool     gPendingBufferAll = false;
// volatile: read LOCK-FREE by detLogBufferAll() on the radio hot paths; writes stay under gIoMutex.
static volatile bool gBufferAll = false;   // "record everything" deploy mode; see det_log.h
// Stationary-mode capacity marker. gSaturated is PERSISTED ("bufsat") as soon as a bufall ring
// reaches capacity. It means later nearby rows MAY have been omitted, not that one definitely was;
// gSatDrops is the this-boot count of actual full-ring refusals for the [diag] line.
static bool              gSaturated = false;
static bool              gSaturationPersistencePending = false;
static volatile uint32_t gSatDrops  = 0;
static uint32_t gFaults = DET_LOG_FAULT_NONE;
static bool     gFaultPersistencePending = false;
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
// A key rotation cannot replace gKey until the old-key ring's durable wipe latch lands. If that
// NVS transaction is temporarily refused, retain the incoming key beside the pending arm and
// publish it only with the empty generation; otherwise a power loss can restore old ciphertext
// after its decrypting key/fingerprint has already been overwritten.
static uint8_t  gWipePendingKey[32];
static uint8_t  gWipePendingKeyFp[8];
static bool     gWipePendingKeyValid = false;
static bool     gWipePendingKeyHaveFp = false;
// BLE may come up while the startup NVS/boot transaction is still retrying. Preserve the newest
// app key without comparing it against default-empty RAM; it is applied only after the retained
// key/fingerprint pair has been published, so an actual rotation cannot evade the wipe guard.
static uint8_t  gStartupPendingKey[32];
static uint8_t  gStartupPendingKeyFp[8];
static bool     gStartupPendingKeyValid = false;
static bool     gStartupPendingKeyMayReplace = false;
static uint32_t gEpochUnix = 0;    // app-pushed wall clock for this boot
static uint32_t gEpochAtMs = 0;    // millis() when that epoch arrived
static uint32_t gStartupPendingEpoch = 0;
static uint32_t gStartupPendingEpochAtMs = 0;
static bool     gStartupPendingEpochValid = false;
static uint32_t gLastConnBoot = 0; // loaded at boot; also used if the ring scan is NVS-deferred
static bool     gLastConnWritePending = false;
static bool     gDrainStartPending = false;
static uint32_t gPendingDrainCursor = 0;
static uint32_t gPendingDrainLogGeneration = 0;

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
static bool       gAnchorsReady = false;
static bool       gAnchorsLoadPending = true;
static bool       gAnchorsSavePending = false;
static uint8_t    gAnchorReadFailures = 0;
static uint8_t    gAnchorSaveFailures = 0;

static void latchFaultLocked(uint32_t fault);

static bool anchorsLoadLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, true)) {
        gAnchorsLoadPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    BootAnchor anchors[ANCHOR_SLOTS] = {};
    const size_t n = p.getBytesLength("anch");
    if (n != 0 && n != sizeof(anchors)) {
        p.end();
        // A wrong-length blob can never become valid by retrying the same read. Publish an empty
        // anchor table so sound ring rows remain replayable as approximate, and best-effort retire
        // the malformed metadata. Blob-first removal is power-loss safe: a stale cursor beside an
        // absent blob merely skips an empty slot on the next anchor write.
        bool repaired = false;
        Preferences repair;
        if (repair.begin(NVS_NS, false)) {
            repaired = (!repair.isKey("anch") || repair.remove("anch")) &&
                       (!repair.isKey("anchn") || repair.remove("anchn"));
            repair.end();
        }
        memset(gAnchors, 0, sizeof(gAnchors));
        gAnchorNext = 0;
        gAnchorsReady = true;
        gAnchorsLoadPending = false;
        gAnchorsSavePending = false;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        (void)repaired;  // diagnostic is intentional for the malformed source, repaired or not
        return true;
    }
    const bool loaded = n == 0 ||
        p.getBytes("anch", anchors, sizeof(anchors)) == sizeof(anchors);
    const uint8_t next = p.getUChar("anchn", 0) % ANCHOR_SLOTS;
    p.end();
    if (!loaded) {
        // A short read can be transient, but anchors are optional evidence metadata and may not
        // strand every otherwise-valid replay forever. Retry twice, then quarantine the exact-size
        // blob and publish an empty table so rows replay honestly as approximate.
        if (++gAnchorReadFailures >= 3) {
            Preferences repair;
            if (repair.begin(NVS_NS, false)) {
                if (repair.isKey("anch")) repair.remove("anch");
                if (repair.isKey("anchn")) repair.remove("anchn");
                repair.end();
            }
            memset(gAnchors, 0, sizeof(gAnchors));
            gAnchorNext = 0;
            gAnchorsReady = true;
            gAnchorsLoadPending = false;
            gAnchorsSavePending = false;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return true;
        }
        gAnchorsLoadPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    memcpy(gAnchors, anchors, sizeof(gAnchors));
    gAnchorNext = next;
    gAnchorsReady = true;
    gAnchorsLoadPending = false;
    gAnchorReadFailures = 0;
    return true;
}

static bool anchorsSaveLocked() {
    if (!gAnchorsSavePending) return true;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        if (++gAnchorSaveFailures >= 3) {
            // Anchors are optional. Keep the valid RAM anchor for this session, but stop blocking
            // all replay on permanently unavailable metadata; after reboot affected rows become
            // approximate, which is honest.
            gAnchorsSavePending = false;
            gAnchorSaveFailures = 0;
            return true;
        }
        return false;
    }
    // Cursor first is the power-loss-safe order. If the following blob write fails, reboot skips
    // one slot; blob-first/cursor-failed would point straight back at and overwrite the newest
    // successfully stored anchor on the next connection.
    const bool cursorStored = p.putUChar("anchn", gAnchorNext) == sizeof(gAnchorNext);
    const bool blobStored = cursorStored &&
        p.putBytes("anch", gAnchors, sizeof(gAnchors)) == sizeof(gAnchors);
    p.end();
    if (!cursorStored || !blobStored) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        if (++gAnchorSaveFailures >= 3) {
            gAnchorsSavePending = false;
            gAnchorSaveFailures = 0;
            return true;
        }
        return false;
    }
    gAnchorsSavePending = false;
    gAnchorSaveFailures = 0;
    return true;
}

// Record (or refresh) the anchor for `boot`. Reuses an existing slot for the same boot so one
// long session cannot evict the other seven boots' anchors.
static void anchorPut(uint32_t boot, uint32_t epochUnix, uint32_t atMs) {
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++) {
        if (gAnchors[i].boot == boot && gAnchors[i].epochUnix) {
            gAnchors[i].epochUnix = epochUnix; gAnchors[i].atMs = atMs;
            gAnchorsSavePending = true;
            anchorsSaveLocked();
            return;
        }
    }
    gAnchors[gAnchorNext] = { boot, epochUnix, atMs };
    gAnchorNext = (uint8_t)((gAnchorNext + 1) % ANCHOR_SLOTS);
    gAnchorsSavePending = true;
    anchorsSaveLocked();
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

static bool captureDeliveryLock() {
    return gCaptureDeliveryMutex &&
           xSemaphoreTake(gCaptureDeliveryMutex, portMAX_DELAY) == pdTRUE;
}

static void captureDeliveryUnlock() {
    if (gCaptureDeliveryMutex) xSemaphoreGive(gCaptureDeliveryMutex);
}

static uint32_t countLocked() {
    return (gHead > gOldest) ? (gHead - gOldest) : 0;
}

static void discardPendingKeysLocked() {
    memset(gWipePendingKey, 0, sizeof(gWipePendingKey));
    memset(gWipePendingKeyFp, 0, sizeof(gWipePendingKeyFp));
    gWipePendingKeyValid = false;
    gWipePendingKeyHaveFp = false;
    memset(gStartupPendingKey, 0, sizeof(gStartupPendingKey));
    memset(gStartupPendingKeyFp, 0, sizeof(gStartupPendingKeyFp));
    gStartupPendingKeyValid = false;
    gStartupPendingKeyMayReplace = false;
    gKeyChangeEraseArmed = false;
}

static void invalidateDrainLocked() {
    gDrainGeneration++;
    if (gDrainGeneration == 0) gDrainGeneration = 1;  // zero is never issued as a capability
}

static bool persistFaultsLocked() {
    if (!gFaultPersistencePending) return true;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        // The diagnostic itself could not be made durable. Preserve both the original ring fault
        // and the NVS history in RAM, then retry from the maintenance tick.
        gFaults |= DET_LOG_FAULT_NVS;
        return false;
    }
    const uint32_t target = gFaults;
    const bool stored = p.putUInt("fault", target) == sizeof(uint32_t);
    p.end();
    if (!stored) {
        gFaults |= DET_LOG_FAULT_NVS;
        return false;
    }
    // A failed earlier attempt may have added NVS after `target` was captured. Require one more
    // pass so the durable mask exactly includes every bit visible in RAM.
    gFaultPersistencePending = target != gFaults;
    return !gFaultPersistencePending;
}

static void latchFaultLocked(uint32_t fault) {
    const uint32_t next = gFaults | fault;
    if (next != gFaults) gFaults = next;
    gFaultPersistencePending = true;
    persistFaultsLocked();
}

static bool appendBlockedLocked() {
    // Even a read fault can make a boot scan underestimate gHead and select a slot that
    // is already programmed. Once storage state is uncertain, only a full erase safely
    // establishes a new writable generation. DET_LOG_FAULT_NVS is different: it reports a
    // offline-buffer metadata load/save failure, but says nothing by itself about raw ring
    // geometry. The transaction-specific pending flags block work until required metadata
    // recovers; keeping every later append blocked solely by this historical bit would destroy
    // evidence needlessly.
    static const uint32_t kRingBlockingFaults = DET_LOG_FAULT_READ | DET_LOG_FAULT_ERASE |
                                                 DET_LOG_FAULT_WRITE | DET_LOG_FAULT_CORRUPT |
                                                 DET_LOG_FAULT_LOCK | DET_LOG_FAULT_CRYPTO;
    return (gFaults & kRingBlockingFaults) != 0;
}

static bool destructivePrivacyPendingLocked() {
    // These actions must establish their own durable recovery boundary before a ring clear can
    // publish a fresh boot/log/crypto generation. Otherwise a power loss between the two commits
    // can reload the obsolete retained key or on=true into the already-rebased empty generation.
    return gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken ||
           gDisableCleanupPending || gKeyRemovalPending ||
           (gWipePendingKeyValid && gKeyChangeEraseArmed);
}

static bool clearLocked(bool requestSensitiveErase);
static void beginDisableLocked();
static bool keyFingerprint(const uint8_t key[32], uint8_t out[8]);
static bool retryConfigPersistenceLocked();
static void markSaturatedLocked();
static bool persistSaturationLocked();

// Restore the durable coredump-wipe token without ever interpreting an NVS-open failure as the
// default zero. This is called once during setup and retried from the loop-side pending read.
static bool restoreSensitiveEraseLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gSensitiveEraseLoadPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }

    const uint32_t pending = p.getUInt("cdwipe", 0);
    uint32_t counter = p.getUInt("cdgen", pending);
    bool counterDirty = false;
    // Covers an interrupted first upgrade/write that persisted cdwipe before cdgen.
    if (pending && counter != pending) {
        counter = pending;
        counterDirty = p.putUInt("cdgen", counter) != sizeof(uint32_t);
    }
    p.end();

    gSensitiveEraseGen = pending;
    gSensitiveEraseCounter = counter;
    gSensitiveEraseCounterDirty = counterDirty;
    gSensitiveEraseLoadPending = false;
    if (counterDirty) latchFaultLocked(DET_LOG_FAULT_NVS);
    return true;
}

// Persist one explicit retained-stack wipe request. `cdwipe` is written first and is the commit
// point: until that exact put succeeds, callers must not publish `generation` in RAM and let the
// physical coredump eraser consume it. If `cdgen` then fails, the pending token itself remains a
// complete power-loss-safe request and detLogBegin can reconstruct the counter from it.
static bool persistSensitiveEraseLocked(uint32_t generation) {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const size_t pendingStored = p.putUInt("cdwipe", generation);
    if (pendingStored != sizeof(uint32_t)) {
        p.end();
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }

    const size_t counterStored = p.putUInt("cdgen", generation);
    p.end();

    // Publish only after the durable pending token landed. From this point a power failure before
    // physical erase is safe: boot reloads cdwipe even if the advisory counter write failed.
    gSensitiveEraseGen = generation;
    gSensitiveEraseCounter = generation;
    gSensitiveEraseLoadPending = false;
    gSensitiveEraseCounterDirty = counterStored != sizeof(uint32_t);
    if (gSensitiveEraseCounterDirty) latchFaultLocked(DET_LOG_FAULT_NVS);
    return true;
}

static bool issueSensitiveEraseRequestLocked() {
    // A second explicit action while an earlier one is waiting for NVS still supersedes it with
    // a fresh generation. Coalescing them to one number would reopen the same completion race the
    // generation token was introduced to close.
    const uint32_t base = gSensitiveEraseRetryGen ? gSensitiveEraseRetryGen
                                                   : gSensitiveEraseCounter;
    uint32_t next = base + 1;
    if (next == 0) next = 1;   // zero means "no request", so skip it on uint32 wrap
    if (persistSensitiveEraseLocked(next)) {
        gSensitiveEraseRetryGen = 0;
        return true;
    }
    gSensitiveEraseRetryGen = next;         // loop-task reads retry until NVS accepts cdwipe
    return false;
}

static void retrySensitiveErasePersistenceLocked() {
    if (gSensitiveEraseLoadPending) {
        if (!restoreSensitiveEraseLocked()) return;
        if (gSensitiveEraseRequestDeferred) {
            gSensitiveEraseRequestDeferred = false;
            issueSensitiveEraseRequestLocked();
        }
    }
    if (gSensitiveEraseRetryGen != 0) {
        const uint32_t retry = gSensitiveEraseRetryGen;
        if (!persistSensitiveEraseLocked(retry)) return;
        // Do not clear a request queued by another caller. All access is under gIoMutex today,
        // but comparing makes the ownership rule explicit if persistence is ever made async.
        if (gSensitiveEraseRetryGen == retry) gSensitiveEraseRetryGen = 0;
        return;
    }
    if (!gSensitiveEraseCounterDirty) return;

    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return;
    }
    const size_t stored = p.putUInt("cdgen", gSensitiveEraseCounter);
    p.end();
    if (stored == sizeof(uint32_t)) gSensitiveEraseCounterDirty = false;
    else latchFaultLocked(DET_LOG_FAULT_NVS);
}

static bool requestSensitiveEraseLocked() {
    // An explicit privacy action means sensitive bytes may remain in stale task frames even after
    // the live objects are zeroed. Never retire its token again in this physical boot; a clean
    // reboot can clear an empty probe, while a panic reboot uses the same durable token to erase
    // the newly retained dump. This hold is intentionally reset only by real/static initialization
    // (and detLogHostResetRuntime in tests), not by another detLogBegin call.
    gSensitiveStackExposedThisBoot = true;
    if (gSensitiveEraseLoadPending && !restoreSensitiveEraseLocked()) {
        gSensitiveEraseRequestDeferred = true;
        return false;
    }
    return issueSensitiveEraseRequestLocked();
}

static bool sensitiveEraseDurableLocked() {
    return !gSensitiveEraseLoadPending && gSensitiveEraseGen != 0;
}

static bool ensureDisabledKeyEraseLocked() {
    if (!gDisabledKeyEraseArmed) {
        // Mark the generation as owned before the write attempt. A coredump completion runs under
        // this same mutex and must see the staged-key guard even when NVS makes the first put fail.
        gDisabledKeyEraseArmed = true;
        requestSensitiveEraseLocked();
    }
    // A failed superseding write is still safe when an older nonzero token is already durable:
    // the boot-lifetime hold prevents its completion, so it covers the whole session and any later
    // panic. Only unknown load state or the absence of every durable token requires rejection.
    return sensitiveEraseDurableLocked();
}

static bool disabledSessionKeyPresentLocked() {
    const bool effectivelyDisabled = !gEnabled ||
        (gEnableTransitionPending && !gPendingEnabled);
    return effectivelyDisabled &&
        (gHaveKey || gStartupPendingKeyValid || gWipePendingKeyValid);
}

// Replay generations cross board identities in the mobile store, so a simple counter is not a
// namespace: board A's generation 1/cursor 100 can otherwise suppress board B's first 100 rows.
// Use the ESP hardware RNG and fail closed if it cannot produce a distinct nonzero token.
static bool freshLogGenerationLocked(uint32_t current, uint32_t* out) {
    if (!out) return false;
    for (int i = 0; i < 8; i++) {
        const uint32_t candidate = esp_random();
        if (candidate != 0 && candidate != current) {
            *out = candidate;
            return true;
        }
    }
    latchFaultLocked(DET_LOG_FAULT_CRYPTO);
    return false;
}

static bool domainPresent(const uint8_t value[16]) {
    if (!value) return false;
    uint8_t any = 0;
    for (size_t i = 0; i < 16; i++) any |= value[i];
    return any != 0;
}

static bool freshCryptoDomainLocked(const uint8_t current[16], uint8_t out[16]) {
    if (!out) return false;
    for (int i = 0; i < 8; i++) {
        uint8_t candidate[16];
        for (size_t word = 0; word < 4; word++) {
            const uint32_t randomWord = esp_random();
            memcpy(candidate + word * sizeof(randomWord), &randomWord, sizeof(randomWord));
        }
        if (domainPresent(candidate) &&
            (!current || memcmp(candidate, current, sizeof(candidate)) != 0)) {
            memcpy(out, candidate, sizeof(candidate));
            return true;
        }
    }
    latchFaultLocked(DET_LOG_FAULT_CRYPTO);
    return false;
}

static bool readDomainLocked(Preferences& p, const char* key, uint8_t out[16]) {
    memset(out, 0, 16);
    return p.getBytesLength(key) == 16 && p.getBytes(key, out, 16) == 16 &&
           domainPresent(out);
}

static bool ensureRingFormatLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gRingFormatPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const uint8_t stored = p.getUChar("ringfmt", 0);
    if (stored == RING_FORMAT) {
        p.end();
        gRingFormatPending = false;
        return true;
    }

    uint32_t target = p.getUInt("wipegen", 0);
    if (target == 0) {
        const uint32_t current = p.getUInt("loggen", 0);
        if (!freshLogGenerationLocked(current, &target)) {
            p.end();
            gRingFormatPending = true;
            return false;
        }
    }
    uint8_t cryptoTarget[16];
    if (!readDomainLocked(p, "wipecdom", cryptoTarget)) {
        uint8_t current[16];
        readDomainLocked(p, "cryptdom", current);
        if (!freshCryptoDomainLocked(current, cryptoTarget)) {
            p.end();
            gRingFormatPending = true;
            return false;
        }
    }

    // Generation tombstone first, wipe level second, version last. Power loss at any boundary
    // leaves old-format slots condemned: wipegen alone is sufficient to resume the transaction,
    // missing/old ringfmt retries it, and a new marker can exist only beside a durable condemnation.
    // The ordinary wipe-resume path supplies a fresh boot nonce generation and retires the latch
    // after every byte is erased.
    const bool generationStored = p.putUInt("wipegen", target) == sizeof(uint32_t);
    const bool cryptoTargetStored = generationStored &&
        p.putBytes("wipecdom", cryptoTarget, sizeof(cryptoTarget)) == sizeof(cryptoTarget);
    const bool condemned = cryptoTargetStored && p.putBool("wipe", true) == sizeof(bool);
    const bool versioned = condemned &&
        p.putUChar("ringfmt", RING_FORMAT) == sizeof(RING_FORMAT);
    p.end();
    if (generationStored) gWipeTargetGeneration = target;
    if (cryptoTargetStored)
        memcpy(gWipeTargetCryptoDomain, cryptoTarget, sizeof(gWipeTargetCryptoDomain));
    if (!generationStored || !cryptoTargetStored || !condemned || !versioned) {
        gRingFormatPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    gRingFormatPending = false;
    return true;
}

// Read the ring's power-loss latch only after NVS opened successfully. `Preferences::getBool`
// exposes no per-read status, so begin() is the available read-transaction boundary; an open
// failure is retained as an unknown state and retried from detLogEraseTick instead of defaulting
// to false and scanning records that may already have been condemned.
static bool restoreRingWipeLocked(bool* pending) {
    if (!pending) return false;
    Preferences p;
    if (!p.begin(NVS_NS, true)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const bool wipe = p.getBool("wipe", false);
    const bool generationNeeded = p.getBool("wipeneed", false);
    const uint32_t target = p.getUInt("wipegen", 0);
    uint8_t cryptoTarget[16];
    const bool haveCryptoTarget = readDomainLocked(p, "wipecdom", cryptoTarget);
    p.end();
    gWipeTargetGeneration = target;
    if (haveCryptoTarget) memcpy(gWipeTargetCryptoDomain, cryptoTarget, sizeof(cryptoTarget));
    else memset(gWipeTargetCryptoDomain, 0, sizeof(gWipeTargetCryptoDomain));
    // A target written just before a failed wipe=true write is itself a durable condemnation.
    *pending = wipe || generationNeeded || target != 0 || haveCryptoTarget;
    return true;
}

// Load every value needed to decrypt/admit records into locals, then publish it only after the
// incremented boot counter commits. Falling back to boot 1 after a failed open/put can reuse the
// AES-CTR nonce domain (cryptdom128:bootCount:seq); exposing a scanned ring without its retained
// key can also turn
// ciphertext into a plausible-looking replay. Both paths therefore remain unavailable together.
static bool restoreStartupConfigLocked() {
    const bool runtimeKeyRemovalPending = gKeyRemovalPending;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gStartupConfigPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }

    const bool enabled = p.getBool("on", false);
    const bool keyRemovalCommitted = p.getBool("keydrop", false);
    bool bufferAll = p.getBool("bufall", false);
    bool saturated = p.getBool("bufsat", false);
    bool saturationRepairPending = false;
    const uint32_t storedFaults = p.getUInt("fault", DET_LOG_FAULT_NONE);
    uint8_t keyFp[sizeof(gKeyFp)] = {};
    bool haveKeyFp = p.getBytesLength("keyfp") == sizeof(keyFp) &&
                     p.getBytes("keyfp", keyFp, sizeof(keyFp)) == sizeof(keyFp);
    uint32_t logGeneration = p.getUInt("loggen", 0);
    uint32_t wipeTarget = p.getUInt("wipegen", 0);
    uint8_t cryptoDomain[16];
    bool haveCryptoDomain = readDomainLocked(p, "cryptdom", cryptoDomain);
    uint8_t cryptoTarget[16];
    bool haveCryptoTarget = readDomainLocked(p, "wipecdom", cryptoTarget);
    const bool wipeGenerationNeeded = p.getBool("wipeneed", false);
    const bool durableWipeIntent = p.getBool("wipe", false) || wipeGenerationNeeded ||
                                   wipeTarget != 0 || haveCryptoTarget;
    bool generationRecoveryWipe = false;
    // Durable ring intent is authoritative even if this same runtime had not yet published its RAM
    // flag (for example metadata-recovery writes landed and the later boot-counter put failed).
    // The only `gWipePending` state ignored here is a RAM-only deferred clear whose tombstone write
    // failed completely; durableWipeIntent is false in exactly that case.
    if (durableWipeIntent) {
        // A prior attempt in this same runtime may have committed the durable intent and current
        // metadata, then failed the later boot-counter put before publishing gWipePending/cursors.
        // Preserve that NVS authority through the common publication path below.
        if (!gWipePending) generationRecoveryWipe = true;
        // A partially retired wipe may already have cleared its target markers while wipe=true
        // remains. In that state the current values are the already-published empty generation and
        // must not advance again. A genuinely missing value gets a fresh unpredictable domain.
        if (wipeGenerationNeeded) {
            // A clear whose RNG failed still left a durable raw condemnation. Mint both fresh
            // identities now; reusing current loggen/cryptdom would reset seq under the old mobile
            // cursor authority and nonce namespace.
            if (!freshLogGenerationLocked(logGeneration, &wipeTarget) ||
                !freshCryptoDomainLocked(haveCryptoDomain ? cryptoDomain : nullptr,
                                         cryptoTarget)) {
                p.end();
                gStartupConfigPending = true;
                return false;
            }
            if (p.putUInt("wipegen", wipeTarget) != sizeof(uint32_t) ||
                p.putBytes("wipecdom", cryptoTarget, sizeof(cryptoTarget)) !=
                    sizeof(cryptoTarget) ||
                p.putBool("wipeneed", false) != sizeof(bool)) {
                p.end();
                gStartupConfigPending = true;
                latchFaultLocked(DET_LOG_FAULT_NVS);
                return false;
            }
            haveCryptoTarget = true;
        } else if (wipeTarget == 0) {
            if (logGeneration) {
                wipeTarget = logGeneration;
            } else if (!freshLogGenerationLocked(0, &wipeTarget)) {
                p.end();
                gStartupConfigPending = true;
                return false;
            }
            if (p.putUInt("wipegen", wipeTarget) != sizeof(uint32_t)) {
                p.end();
                gStartupConfigPending = true;
                latchFaultLocked(DET_LOG_FAULT_NVS);
                return false;
            }
        }
        if (!haveCryptoTarget) {
            if (haveCryptoDomain) {
                memcpy(cryptoTarget, cryptoDomain, sizeof(cryptoTarget));
            } else if (!freshCryptoDomainLocked(nullptr, cryptoTarget)) {
                p.end();
                gStartupConfigPending = true;
                return false;
            }
            if (p.putBytes("wipecdom", cryptoTarget, sizeof(cryptoTarget)) !=
                sizeof(cryptoTarget)) {
                p.end();
                gStartupConfigPending = true;
                latchFaultLocked(DET_LOG_FAULT_NVS);
                return false;
            }
            haveCryptoTarget = true;
        }
        if (logGeneration != wipeTarget &&
            p.putUInt("loggen", wipeTarget) != sizeof(uint32_t)) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        logGeneration = wipeTarget;
        if ((!haveCryptoDomain || memcmp(cryptoDomain, cryptoTarget, sizeof(cryptoDomain)) != 0) &&
            p.putBytes("cryptdom", cryptoTarget, sizeof(cryptoTarget)) !=
                sizeof(cryptoTarget)) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        memcpy(cryptoDomain, cryptoTarget, sizeof(cryptoDomain));
        haveCryptoDomain = true;
    } else if (logGeneration == 0 || !haveCryptoDomain) {
        // These values jointly define replay authority and the AES nonce domain. If either is lost
        // while raw rows exist (or scan geometry is uncertain), those rows cannot be safely resumed
        // under replacement metadata. Durably condemn them first. An empty sound ring can publish
        // the fresh values directly.
        uint32_t freshGeneration = 0;
        uint8_t freshDomain[16];
        if (!freshLogGenerationLocked(logGeneration, &freshGeneration) ||
            !freshCryptoDomainLocked(haveCryptoDomain ? cryptoDomain : nullptr, freshDomain)) {
            p.end();
            gStartupConfigPending = true;
            return false;
        }
        const uint32_t rawFaultMask = DET_LOG_FAULT_READ | DET_LOG_FAULT_ERASE |
                                      DET_LOG_FAULT_WRITE | DET_LOG_FAULT_CORRUPT;
        const bool untrustedRaw = ((gFaults | storedFaults) & rawFaultMask) != 0;
        const bool rawStorageUnknown = gPart == nullptr || gSlots == 0;
        generationRecoveryWipe = rawStorageUnknown ||
            (gRingScanReady && (countLocked() != 0 || untrustedRaw));
        if (generationRecoveryWipe) {
            if (p.putUInt("wipegen", freshGeneration) != sizeof(uint32_t) ||
                p.putBytes("wipecdom", freshDomain, sizeof(freshDomain)) !=
                    sizeof(freshDomain) ||
                p.putBool("wipe", true) != sizeof(bool)) {
                p.end();
                gStartupConfigPending = true;
                latchFaultLocked(DET_LOG_FAULT_NVS);
                return false;
            }
            wipeTarget = freshGeneration;
            memcpy(cryptoTarget, freshDomain, sizeof(cryptoTarget));
            haveCryptoTarget = true;
        }
        if (p.putUInt("loggen", freshGeneration) != sizeof(uint32_t) ||
            p.putBytes("cryptdom", freshDomain, sizeof(freshDomain)) != sizeof(freshDomain)) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        logGeneration = freshGeneration;
        memcpy(cryptoDomain, freshDomain, sizeof(cryptoDomain));
        haveCryptoDomain = true;
    }

    // lastconn is itself a previously durable boot identity. If boot/anchors disappear while this
    // marker survives, starting below it makes unsigned auto-wipe arithmetic wrap and can also
    // reuse nonce boot IDs on an otherwise empty ring. Treat every non-sentinel value as a lower
    // bound before selecting the next boot.
    const uint32_t lastConn = p.getUInt("lastconn", 0);
    uint32_t bootBase = p.getUInt("boot", 0);
    if (lastConn != 0xFFFFFFFFu && lastConn > bootBase) bootBase = lastConn;
    if (gMaxScannedBoot > bootBase) bootBase = gMaxScannedBoot;
    for (uint8_t i = 0; i < ANCHOR_SLOTS; i++) {
        if (gAnchors[i].boot > bootBase) bootBase = gAnchors[i].boot;
    }
    if (bootBase == 0xFFFFFFFFu) {
        p.end();
        gStartupConfigPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const uint32_t boot = bootBase + 1;
    // Missing is not "connected this boot". Defaulting to the freshly incremented counter would
    // refresh the seizure timer on every reboot and let an undrained ring live forever. Zero is a
    // conservative monotonic baseline; auto-wipe still requires an actually nonempty ring.
    // In Stationary mode, exact-fill is itself the documented capacity/censoring-risk boundary.
    // Recover a marker whose first write failed immediately before power loss from the persisted
    // mode plus raw geometry. A normally full FIFO ring is not evidence Stationary capture ran.
    if (!saturated && bufferAll && gSlots != 0 && gRingScanReady && !gWipePending &&
        !generationRecoveryWipe &&
        countLocked() >= gSlots) {
        saturated = true;
        saturationRepairPending =
            p.putBool("bufsat", true) != sizeof(bool);
    }
    // `on=false` is the durable disable marker and `keydrop=true` is the equivalent marker for a
    // standalone detLogClearKey(). If power died between either commit and the key removal,
    // finish forgetting the residual key before this boot becomes ready.
    if (!enabled || keyRemovalCommitted) {
        if (!enabled && bufferAll && p.putBool("bufall", false) != sizeof(bool)) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        if (!enabled) bufferAll = false;
        if (p.isKey("key") && !p.remove("key")) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        if (keyRemovalCommitted && p.putBool("keydrop", false) != sizeof(bool)) {
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
    }
    uint8_t key[sizeof(gKey)] = {};
    bool haveKey = enabled && !keyRemovalCommitted &&
                   p.getBytesLength("key") == sizeof(key) &&
                   p.getBytes("key", key, sizeof(key)) == sizeof(key);
    bool keyPairUnverified = false;
    if (runtimeKeyRemovalPending) {
        // A clear-key request made while startup was retrying owns the newer intent. Do not let
        // this retained read republish the key before persistKeyRemovalLocked gets its retry.
        haveKey = false;
    } else if (haveKey) {
        uint8_t derivedFp[sizeof(gKeyFp)] = {};
        if (!keyFingerprint(key, derivedFp)) {
            // This is not an "absent key" result: the retained blob exists but its identity could
            // not be established. Keep the entire startup transaction pending so neither this key
            // nor an app key can be compared against default-empty state; the loop retries.
            p.end();
            gStartupConfigPending = true;
            latchFaultLocked(DET_LOG_FAULT_CRYPTO);
            return false;
        } else if (haveKeyFp) {
            // This is the durable midpoint of a key-first/fingerprint-last update (or corrupted
            // NVS). Do not decrypt or append with either half. Keeping the OLD fingerprint lets
            // the next verified app key conservatively wipe any rows it does not match.
            if (memcmp(keyFp, derivedFp, sizeof(keyFp)) != 0) {
                haveKey = false;
                keyPairUnverified = true;
            }
        } else {
            // Older/incomplete state with a valid retained key can be repaired without guessing:
            // derive its exact fingerprint and require that repair before startup is published.
            if (p.putBytes("keyfp", derivedFp, sizeof(derivedFp)) != sizeof(derivedFp)) {
                p.end();
                gStartupConfigPending = true;
                latchFaultLocked(DET_LOG_FAULT_NVS);
                return false;
            }
            memcpy(keyFp, derivedFp, sizeof(keyFp));
            haveKeyFp = true;
        }
    }
    if (p.putUInt("boot", boot) != sizeof(uint32_t)) {
        p.end();
        gStartupConfigPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    p.end();

    gEnabled = enabled;
    gBufferAll = bufferAll;
    gSaturated = saturated;
    gSaturationPersistencePending = saturationRepairPending;
    gFaults |= storedFaults;
    memset(gKey, 0, sizeof(gKey));
    if (haveKey) memcpy(gKey, key, sizeof(gKey));
    gHaveKey = haveKey;
    memset(gKeyFp, 0, sizeof(gKeyFp));
    if (haveKeyFp) memcpy(gKeyFp, keyFp, sizeof(gKeyFp));
    gHaveKeyFp = haveKeyFp;
    gBoot = boot;
    gLogGeneration = logGeneration;
    memcpy(gCryptoDomain, cryptoDomain, sizeof(gCryptoDomain));
    if (generationRecoveryWipe) {
        gWipePending = true;
        gWipeNext = 0;
        gWipeStalled = false;
        gHead = 1;
        gOldest = 1;
        gMaxScannedBoot = 0;
        gDrain = 0;
        gDraining = false;
        invalidateDrainLocked();
        gRingScanReady = true;
        gAutoWipeCheckPending = false;
    }
    gWipeTargetGeneration = (gWipePending || generationRecoveryWipe) ? wipeTarget : 0;
    if ((gWipePending || generationRecoveryWipe) && haveCryptoTarget)
        memcpy(gWipeTargetCryptoDomain, cryptoTarget, sizeof(gWipeTargetCryptoDomain));
    else
        memset(gWipeTargetCryptoDomain, 0, sizeof(gWipeTargetCryptoDomain));
    gLastConnBoot = lastConn;
    gStartupConfigPending = false;
    if (keyPairUnverified) latchFaultLocked(DET_LOG_FAULT_NVS);
    return true;
}

static bool persistKeyStateLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gKeyPersistencePending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    // The decrypting key lands before its fingerprint. If power fails between them, startup sees
    // the NEW key with the OLD fingerprint; the next app key therefore forces a conservative
    // wipe. The reverse order could expose OLD-key rows under a NEW fingerprint and suppress the
    // only mixed-key guard. `keydrop=false` is last so a partially replaced clear-key request
    // remains fail-closed across reboot.
    bool stored = true;
    if (gEnabled && gHaveKey)
        stored = p.putBytes("key", gKey, sizeof(gKey)) == sizeof(gKey);
    else if (p.isKey("key"))
        stored = p.remove("key");
    if (stored && gHaveKeyFp)
        stored = p.putBytes("keyfp", gKeyFp, sizeof(gKeyFp)) == sizeof(gKeyFp);
    if (stored) stored = p.putBool("keydrop", false) == sizeof(bool);
    p.end();
    gKeyPersistencePending = !stored;
    if (stored) gKeyRemovalPending = false;
    else latchFaultLocked(DET_LOG_FAULT_NVS);
    return stored;
}

static bool persistKeyRemovalLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gKeyRemovalPending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    // keydrop=true is the commit point. Once it lands, boot completes the removal before loading
    // a key or admitting nonce-using work. Clear it only after the blob is actually absent.
    bool stored = p.putBool("keydrop", true) == sizeof(bool);
    if (stored && p.isKey("key")) stored = p.remove("key");
    if (stored) stored = p.putBool("keydrop", false) == sizeof(bool);
    p.end();
    gKeyRemovalPending = !stored;
    if (!stored) latchFaultLocked(DET_LOG_FAULT_NVS);
    return stored;
}

static bool persistEnableTransitionLocked() {
    if (!gEnableTransitionPending && !gDisableCleanupPending) return true;
    // `on=false`/`bufall=false` remove the raw-geometry fallback that can reconstruct an exact-fill
    // Stationary capacity warning after power loss. Land an already-observed warning first.
    if (gSaturationPersistencePending && !persistSaturationLocked()) return false;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }

    bool stored = true;
    if (gDisableCleanupPending) {
        // A later `buffer:true` cannot cancel privacy cleanup that already started. Commit off
        // first, remove any residual key, then leave the newer enable transition staged for a
        // separate transaction below/on the next coordinator iteration.
        stored = p.putBool("on", false) == sizeof(bool);
        if (stored) stored = p.putBool("bufall", false) == sizeof(bool);
        if (stored && p.isKey("key")) stored = p.remove("key");
        if (stored) stored = p.putBool("keydrop", false) == sizeof(bool);
    } else if (gPendingEnabled) {
        // Key material first, `on=true` last. Store the key before its fingerprint for the same
        // conservative mixed-generation rule as persistKeyStateLocked(). A power loss can leave
        // inert extra material, never an enabled buffer whose retained key failed to land.
        if (gHaveKey)
            stored = p.putBytes("key", gKey, sizeof(gKey)) == sizeof(gKey);
        else if (p.isKey("key"))
            stored = p.remove("key");
        if (stored && gHaveKeyFp)
            stored = p.putBytes("keyfp", gKeyFp, sizeof(gKeyFp)) == sizeof(gKeyFp);
        if (stored) stored = p.putBool("keydrop", false) == sizeof(bool);
        if (stored) stored = p.putBool("on", true) == sizeof(bool);
    } else {
        // `on=false` is the durable recovery marker. Startup finishes the key removal if power
        // fails after this first commit but before the following cleanup commits.
        stored = p.putBool("on", false) == sizeof(bool);
        if (stored) stored = p.putBool("bufall", false) == sizeof(bool);
        if (stored && p.isKey("key")) stored = p.remove("key");
        if (stored) stored = p.putBool("keydrop", false) == sizeof(bool);
    }
    p.end();
    if (!stored) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }

    if (gDisableCleanupPending) {
        gDisableCleanupPending = false;
        gEnabled = false;
        gBufferAll = false;
        // A newer buffer:true + bufall intent is applied only after mandatory off/key cleanup.
        // Preserve it across this intermediate transaction; a final/off target still forces false.
        if (!gPendingEnabled) {
            gBufferAllTransitionPending = false;
            gPendingBufferAll = false;
        }
        memset(gKey, 0, sizeof(gKey));
        gHaveKey = false;
        gKeyPersistencePending = false;
        gKeyRemovalPending = false;
        if (!gPendingEnabled) gEnableTransitionPending = false;
        return true;
    }

    gEnabled = gPendingEnabled;
    gEnableTransitionPending = false;
    gDisableCleanupPending = false;
    gKeyPersistencePending = false;
    if (!gEnabled) gKeyRemovalPending = false;
    return true;
}

static bool persistBufferAllLocked() {
    if (!gBufferAllTransitionPending) return true;
    // Turning Stationary mode off must not outrun a failed bufsat=true write. Otherwise a reboot
    // sees bufall=false and cannot infer the warning from an exactly full ring.
    if (!gPendingBufferAll && gSaturationPersistencePending &&
        !persistSaturationLocked()) return false;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const bool stored = p.putBool("bufall", gPendingBufferAll) == sizeof(bool);
    p.end();
    if (!stored) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    gBufferAll = gPendingBufferAll;
    gBufferAllTransitionPending = false;
    // Turning Stationary capture on over an already-full ring crosses the same capacity-risk
    // boundary as writing the exact-fill row while the mode is active.
    if (gBufferAll && gSlots != 0 && countLocked() >= gSlots) markSaturatedLocked();
    return true;
}

static bool persistSaturationLocked() {
    if (!gSaturationPersistencePending) return true;
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const bool stored = p.putBool("bufsat", true) == sizeof(bool);
    p.end();
    if (!stored) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    gSaturationPersistencePending = false;
    return true;
}

static void markSaturatedLocked() {
    if (gSaturated) return;
    gSaturated = true;
    gSaturationPersistencePending = true;
    persistSaturationLocked();
}

static bool persistLastConnectionLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        gLastConnWritePending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const bool stored = p.putUInt("lastconn", gBoot) == sizeof(uint32_t);
    p.end();
    if (!stored) {
        gLastConnWritePending = true;
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    gLastConnBoot = gBoot;
    gLastConnWritePending = false;
    return true;
}

// Startup may know that the user requested a clear before it knows the retained boot counter.
// Persist only the condemnation bit at that point: it is sufficient for a reboot to skip every
// raw slot, while deliberately not touching `boot` until restoreStartupConfigLocked publishes the
// monotonic value. The full arm transaction later supplies the next encryption generation.
static bool persistRingWipeGenerationNeededLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    // `wipeneed` distinguishes this conservative tombstone from a nearly-retired wipe whose
    // current loggen/cryptdom are already the fresh empty generation. Startup must mint new random
    // identities for the former and may reuse current metadata only for the latter.
    const bool stored = p.putBool("wipeneed", true) == sizeof(bool) &&
                        p.putBool("wipe", true) == sizeof(bool);
    p.end();
    if (!stored) latchFaultLocked(DET_LOG_FAULT_NVS);
    return stored;
}

static bool persistRingWipeTombstoneLocked() {
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    uint32_t target = p.getUInt("wipegen", 0);
    if (target == 0) {
        const uint32_t current = p.getUInt("loggen", 0);
        if (!freshLogGenerationLocked(current, &target)) {
            const bool condemned = p.putBool("wipeneed", true) == sizeof(bool) &&
                                    p.putBool("wipe", true) == sizeof(bool);
            p.end();
            if (!condemned) latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
    }
    uint8_t cryptoTarget[16];
    if (!readDomainLocked(p, "wipecdom", cryptoTarget)) {
        uint8_t current[16];
        readDomainLocked(p, "cryptdom", current);
        if (!freshCryptoDomainLocked(current, cryptoTarget)) {
            const bool condemned = p.putBool("wipeneed", true) == sizeof(bool) &&
                                    p.putBool("wipe", true) == sizeof(bool);
            p.end();
            if (!condemned) latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
    }
    // Store the target first. If wipe=true itself is refused and power dies, wipegen still makes
    // restoreRingWipeLocked condemn the old slots; no clear request can evaporate between writes.
    const bool targetStored = p.putUInt("wipegen", target) == sizeof(uint32_t);
    const bool cryptoTargetStored = targetStored &&
        p.putBytes("wipecdom", cryptoTarget, sizeof(cryptoTarget)) == sizeof(cryptoTarget);
    const bool stored = cryptoTargetStored && p.putBool("wipe", true) == sizeof(bool) &&
                        p.putBool("wipeneed", false) == sizeof(bool);
    p.end();
    if (targetStored) gWipeTargetGeneration = target;
    if (cryptoTargetStored)
        memcpy(gWipeTargetCryptoDomain, cryptoTarget, sizeof(gWipeTargetCryptoDomain));
    if (!stored) latchFaultLocked(DET_LOG_FAULT_NVS);
    return stored;
}

// Commit the ring-clear intent before publishing the empty in-RAM generation. `wipe=true` goes
// first: once it lands, every power-loss path skips the boot scan and erases the partition. The
// incremented boot counter must also land before new seqs can be admitted, so a retry keeps the
// ring blocked until both pieces of the new encryption generation are durable.
static bool persistRingWipeArmLocked() {
    if (gWipeTargetGeneration == 0 || !domainPresent(gWipeTargetCryptoDomain) ||
        gWipeArmBoot == 0) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    Preferences p;
    if (!p.begin(NVS_NS, false)) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    const bool generationIntentStored =
        p.putUInt("wipegen", gWipeTargetGeneration) == sizeof(uint32_t);
    const bool cryptoIntentStored = generationIntentStored &&
        p.putBytes("wipecdom", gWipeTargetCryptoDomain,
                   sizeof(gWipeTargetCryptoDomain)) == sizeof(gWipeTargetCryptoDomain);
    const bool wipeStored = cryptoIntentStored &&
                            p.putBool("wipe", true) == sizeof(bool);
    const bool bootStored = wipeStored &&
                            p.putUInt("boot", gWipeArmBoot) == sizeof(uint32_t);
    const bool generationStored = bootStored &&
                                  p.putUInt("loggen", gWipeTargetGeneration) == sizeof(uint32_t);
    const bool cryptoStored = generationStored &&
        p.putBytes("cryptdom", gWipeTargetCryptoDomain,
                   sizeof(gWipeTargetCryptoDomain)) == sizeof(gWipeTargetCryptoDomain);
    const bool lastConnStored = cryptoStored &&
                                p.putUInt("lastconn", gWipeArmBoot) == sizeof(uint32_t);
    const bool saturationStored = lastConnStored &&
                                  p.putBool("bufsat", false) == sizeof(bool);
    const bool generationResolved = saturationStored &&
                                    p.putBool("wipeneed", false) == sizeof(bool);
    p.end();
    if (!generationIntentStored || !cryptoIntentStored || !wipeStored || !bootStored ||
        !generationStored || !cryptoStored ||
        !lastConnStored || !saturationStored || !generationResolved) {
        latchFaultLocked(DET_LOG_FAULT_NVS);
        return false;
    }
    return true;
}

static void publishRingWipeArmLocked() {
    gBoot = gWipeArmBoot;
    gLogGeneration = gWipeTargetGeneration;
    memcpy(gCryptoDomain, gWipeTargetCryptoDomain, sizeof(gCryptoDomain));
    gLastConnBoot = gBoot;
    // A clear is a logical encryption generation, not a physical reboot: millis() and the current
    // app epoch remain in the same clock domain. Clone that anchor to the new boot id so rows
    // written after clear/key rotation do not become approximate for the rest of this power cycle.
    if (gEpochUnix) {
        if (gAnchorsReady) {
            anchorPut(gBoot, gEpochUnix, gEpochAtMs);
        } else {
            gStartupPendingEpoch = gEpochUnix;
            gStartupPendingEpochAtMs = gEpochAtMs;
            gStartupPendingEpochValid = true;
        }
    }
    gWipeArmPending = false;
    gHead = 1;
    gOldest = 1;
    gMaxScannedBoot = 0;
    gDrain = 0;
    gSaturated = false;
    gSaturationPersistencePending = false;
    gSatDrops = 0;
    gWipeNext = 0;
    gWipePending = true;
    gWipeStalled = false;
    gRingScanReady = true;       // the durable latch defines a new, logically empty generation
    gAutoWipeCheckPending = false;
    if (gWipePendingKeyValid) {
        memcpy(gKey, gWipePendingKey, sizeof(gKey));
        gHaveKey = true;
        if (gWipePendingKeyHaveFp) {
            memcpy(gKeyFp, gWipePendingKeyFp, sizeof(gKeyFp));
            gHaveKeyFp = true;
        }
        persistKeyStateLocked();
        memset(gWipePendingKey, 0, sizeof(gWipePendingKey));
        memset(gWipePendingKeyFp, 0, sizeof(gWipePendingKeyFp));
        gWipePendingKeyValid = false;
        gWipePendingKeyHaveFp = false;
    }
}

static bool armRingWipeLocked() {
    if (destructivePrivacyPendingLocked()) {
        // Keep only a RAM-deferred clear here. Persisting even a targetless wipe tombstone would
        // let reboot complete the generation transition before an as-yet-uncommitted clear-key or
        // buffer:false action. The privacy coordinator is retried first from detLogEraseTick().
        gRingClearDeferred = true;
        gWipePending = true;
        return false;
    }
    if (!gWipeArmPending) {
        if (gBoot == 0xFFFFFFFFu) {
            gRingClearDeferred = true;
            gWipePending = true;
            persistRingWipeGenerationNeededLocked();
            latchFaultLocked(DET_LOG_FAULT_NVS);
            return false;
        }
        if (gWipeTargetGeneration == 0) {
            if (!freshLogGenerationLocked(gLogGeneration, &gWipeTargetGeneration)) {
                gRingClearDeferred = true;
                gWipePending = true;
                persistRingWipeGenerationNeededLocked();
                return false;
            }
        }
        if (!domainPresent(gWipeTargetCryptoDomain)) {
            if (!freshCryptoDomainLocked(gCryptoDomain, gWipeTargetCryptoDomain)) {
                gRingClearDeferred = true;
                gWipePending = true;
                persistRingWipeGenerationNeededLocked();
                return false;
            }
        }
        gWipeArmPending = true;
        gWipeArmBoot = gBoot + 1;
    }
    // Block append/start-drain immediately, but leave the old cursors intact until the NVS commit
    // succeeds. If power dies before it does, boot sees the old, still-valid generation rather
    // than resurrecting a generation this runtime had already advertised as empty.
    gWipePending = true;
    gWipeStalled = false;
    if (!persistRingWipeArmLocked()) return false;
    publishRingWipeArmLocked();
    return true;
}

static uint32_t scanRingLocked();
static void maybeAutoWipeLocked(uint32_t maxSeq);

static uint16_t crc16Update(uint16_t c, const uint8_t* p, size_t n) { // CRC-16/CCITT-FALSE
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++) c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

static uint16_t recordCrc(const StoredDet* s) {
    const uint8_t* bytes = (const uint8_t*)s;
    uint16_t c = crc16Update(0xFFFF, bytes, offsetof(StoredDet, crc));
    const size_t afterCrc = offsetof(StoredDet, crc) + sizeof(s->crc);
    return crc16Update(c, bytes + afterCrc, sizeof(*s) - afterCrc);
}

// AES-CTR over the encrypted payload, in place. CTR is symmetric. The buffer key is shared across
// boards, so board-local boot:seq is not a sufficient domain. Hash the fixed-width
// cryptdom128|boot32|seq32 tuple into a 120-bit per-record prefix and reserve nc[15]=0 for CTR's
// block counter. The 52-byte payload consumes only counter values 0..3, so adjacent records can
// never overlap by raw counter increment; prefix collisions retain 120-bit security.
static bool cryptPayload(StoredDet* s) {
    if (!gHaveKey || !domainPresent(gCryptoDomain) || !s) return false;
    uint8_t tuple[24];
    memcpy(tuple,      gCryptoDomain, 16);
    memcpy(tuple + 16, &s->bootCount,  4);
    memcpy(tuple + 20, &s->seq,        4);
    uint8_t digest[32];
    const mbedtls_md_info_t* info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    if (!info || mbedtls_md(info, tuple, sizeof(tuple), digest) != 0) return false;
    uint8_t nc[16];
    memcpy(nc, digest, 15);
    nc[15] = 0;
    mbedtls_aes_context ctx; mbedtls_aes_init(&ctx);
    if (mbedtls_aes_setkey_enc(&ctx, gKey, 256) != 0) {
        mbedtls_aes_free(&ctx);
        return false;
    }
    uint8_t strm[16]; size_t off = 0;
    uint8_t* p = (uint8_t*)s + ENC_OFF;
    const bool ok = mbedtls_aes_crypt_ctr(&ctx, ENC_LEN, &off, nc, strm, p, p) == 0;
    mbedtls_aes_free(&ctx);
    memset(tuple, 0, sizeof(tuple));
    memset(digest, 0, sizeof(digest));
    memset(strm, 0, sizeof(strm));
    return ok;
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

// A slot holds a valid current-generation record iff: seq is set, it maps back to this physical
// slot, and the CRC over every stored byte except the CRC itself matches. The payload remains
// encrypted during this check; cleartext seq/bootCount/gpsAgeSec are included so a torn final
// header cannot silently select the wrong CTR nonce or fabricate exact-time/GPS metadata.
static bool slotValid(const StoredDet* s, uint32_t idx) {
    if (s->seq == 0 || s->seq == 0xFFFFFFFF) return false;
    if (slotOf(s->seq) != idx) return false;
    return recordCrc(s) == s->crc;
}

static bool slotFullyErased(const StoredDet* s) {
    const uint8_t* bytes = (const uint8_t*)s;
    for (size_t i = 0; i < sizeof(*s); i++) {
        if (bytes[i] != 0xFF) return false;
    }
    return true;
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
// the header erased (seq=0xFFFFFFFF), so it cannot masquerade as valid; scanRingLocked also
// condemns the programmed body rather than treating that slot as reusable. Either failed call
// blocks further appends until a successful clear because a non-sector slot cannot be safely
// retried without first erasing other valid records in its sector.
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

// Reconstruct the exact contiguous live window. Kept as a helper because an NVS-open failure at
// boot deliberately postpones this scan: once the erase latch can be read, the loop either resumes
// the condemned sweep or calls this under the same I/O mutex without exposing raw slots in between.
static uint32_t scanRingLocked() {
    uint32_t maxSeq = 0;
    uint32_t maxBoot = 0;
    uint32_t minSeq = 0xFFFFFFFFu;
    uint32_t validCount = 0;
    StoredDet s;
    for (uint32_t i = 0; i < gSlots; i++) {
        if (!readSlot(i, &s)) { latchFaultLocked(DET_LOG_FAULT_READ); continue; }
        if (!slotValid(&s, i)) {
            // Payload is programmed before the header. If power is lost after that first write
            // (and before the best-effort fault marker reaches NVS), seq remains the erased
            // sentinel even though this slot is no longer writable. Treat only an entirely-FF
            // slot as empty; reusing a half-programmed slot could silently AND new ciphertext with
            // old bytes and advance the cursor over an undecryptable record.
            if (!slotFullyErased(&s)) latchFaultLocked(DET_LOG_FAULT_CORRUPT);
            continue;
        }
        if (s.seq > maxSeq) maxSeq = s.seq;
        if (s.bootCount > maxBoot) maxBoot = s.bootCount;
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
    gHead = maxSeq + 1;
    gMaxScannedBoot = maxBoot;
    gOldest = maxSeq ? minSeq : 1;
    gDrain = (gOldest > 0) ? gOldest - 1 : 0;
    gDraining = false;
    invalidateDrainLocked();
    gRingScanReady = true;
    gAutoWipeCheckPending = true;
    return maxSeq;
}

static void maybeAutoWipeLocked(uint32_t maxSeq) {
    const uint32_t wipeAfter = (gEnabled && gBufferAll) ? WIPE_AFTER_BOOTS_DEPLOY
                                                        : WIPE_AFTER_BOOTS;
    if (maxSeq > 0 && (gBoot - gLastConnBoot) >= wipeAfter) {
        // This self-clean is not a new user erase request. Preserve a just-reported crash dump for
        // diagnosis; only explicit clear/key-change/disable actions arm its durable erase token.
        clearLocked(false);
    }
}

static void runAutoWipeCheckLocked() {
    if (!gAutoWipeCheckPending || gStartupConfigPending || !gRingScanReady || gWipePending) return;
    gAutoWipeCheckPending = false;
    maybeAutoWipeLocked(gHead > 1 ? gHead - 1 : 0);
}

// ---- public API ----
void detLogBegin() {
    if (!gIoMutex) gIoMutex = xSemaphoreCreateMutexStatic(&gIoMutexStorage);
    if (!gCaptureDeliveryMutex)
        gCaptureDeliveryMutex = xSemaphoreCreateMutexStatic(&gCaptureDeliveryMutexStorage);
    if (!gIoMutex || !gCaptureDeliveryMutex) {
        gFaults |= DET_LOG_FAULT_LOCK;
        gSlots = 0;
        return;
    }
    gStartupConfigPending = true;
    gLogGeneration = 0;
    gWipeTargetGeneration = 0;
    memset(gCryptoDomain, 0, sizeof(gCryptoDomain));
    memset(gWipeTargetCryptoDomain, 0, sizeof(gWipeTargetCryptoDomain));
    gRingClearDeferred = false;
    gExplicitClearPending = false;
    gRingScanReady = false;
    gAutoWipeCheckPending = false;
    gRingFormatPending = true;
    gMaxScannedBoot = 0;
    gAnchorReadFailures = 0;
    gAnchorSaveFailures = 0;
    gEnableTransitionPending = false;
    gDisableCleanupPending = false;
    gKeyPersistencePending = false;
    gKeyRemovalPending = false;
    gDrainStartPending = false;
    gPendingDrainLogGeneration = 0;
    gLastConnWritePending = false;
    discardPendingKeysLocked();
    gStartupPendingEpochValid = false;
    // Load this BEFORE looking for the ring partition. A board can still have a retained core
    // dump when its data partition is absent or damaged, and an explicit erase promise must not
    // become conditional on mounting an unrelated flash surface.
    gSensitiveEraseLoadPending = true;
    restoreSensitiveEraseLocked();
    gPart = esp_partition_find_first(ESP_PARTITION_TYPE_DATA, ESP_PARTITION_SUBTYPE_ANY, PART_LABEL);
    if (!gPart) {
        gSlots = 0;                                  // no data partition -> buffering unavailable
        gRingScanReady = false;                      // raw existence/contents are unknown, not empty
        latchFaultLocked(DET_LOG_FAULT_READ);
        // NVS wipe metadata remains meaningful even when the raw partition cannot be mounted. A
        // pending clear/domain migration must survive until a later boot can physically sweep it;
        // treating unavailable storage as an empty ring would let old format-2 rows reappear if the
        // partition returns.
        const bool formatKnown = ensureRingFormatLocked();
        bool persistedWipe = false;
        const bool wipeKnown = formatKnown && restoreRingWipeLocked(&persistedWipe);
        gWipeLoadPending = !wipeKnown;
        gWipePending = !wipeKnown || persistedWipe;
        gWipeNext = 0;
        // Key/config persistence is independent NVS state. In particular, an interrupted
        // explicit disable still has to finish removing its key when the raw ring is absent.
        gAnchorsReady = false;
        gAnchorsLoadPending = true;
        gAnchorsSavePending = false;
        if (anchorsLoadLocked() && !gWipeLoadPending) restoreStartupConfigLocked();
        return;
    }
    // Only expose complete erase sectors as slots. This keeps every sector erase inside the
    // partition and makes the ring length an exact multiple of the physical eviction unit.
    gSlots = (uint32_t)(gPart->size / SECTOR) * (uint32_t)PER_SECTOR;
    if (gSlots == 0) {
        // A present-but-too-small/malformed partition is the same safety state as an unavailable
        // one: its raw contents are unknown and destructive/key/domain intents must remain durable
        // until a later valid mount can sweep them.
        gRingScanReady = false;
        latchFaultLocked(DET_LOG_FAULT_READ);
        const bool formatKnown = ensureRingFormatLocked();
        bool persistedWipe = false;
        const bool wipeKnown = formatKnown && restoreRingWipeLocked(&persistedWipe);
        gWipeLoadPending = !wipeKnown;
        gWipePending = !wipeKnown || persistedWipe;
        gWipeNext = 0;
        gAnchorsReady = false;
        gAnchorsLoadPending = true;
        gAnchorsSavePending = false;
        if (anchorsLoadLocked() && !gWipeLoadPending) restoreStartupConfigLocked();
        return;
    }

    // A wipe latched by detLogClear() but cut short by a power loss must be honoured BEFORE
    // trusting the boot scan: not-yet-erased old-generation slots still carry a valid seq/CRC.
    // An NVS-open failure is UNKNOWN, not false. Keep the ring unavailable and retry that read
    // from detLogEraseTick; only a positive false result is permission to scan.
    const bool formatKnown = ensureRingFormatLocked();
    bool persistedWipe = false;
    const bool wipeKnown = formatKnown && restoreRingWipeLocked(&persistedWipe);
    if (!wipeKnown) {
        gWipeLoadPending = true;
        gWipePending = true;      // blocks append/start-drain while raw state is unknown
        gWipeNext = 0;
        gRingScanReady = false;
        gHead = 1; gOldest = 1; gDrain = 0; gDraining = false;
        invalidateDrainLocked();
    } else if (persistedWipe) {
        gWipeLoadPending = false;
        gWipePending = true;
        gWipeNext = 0;
        gRingScanReady = false;
        gHead = 1; gOldest = 1; gDrain = 0; gDraining = false;
        invalidateDrainLocked();
    } else {
        gWipeLoadPending = false;
        gWipePending = false;
        scanRingLocked();
    }

    // Reload the persisted per-boot wall-clock anchors. This is what lets a record captured in an
    // EARLIER boot still replay with an exact time, which is the whole point of persisting them.
    gAnchorsReady = false;
    gAnchorsLoadPending = true;
    gAnchorsSavePending = false;
    gAnchorReadFailures = 0;
    gAnchorSaveFailures = 0;
    // Wipe-load failure is unknown, not a pending clear. Do not let startup manufacture wipegen
    // from that conservative RAM block before the retry has positively read the durable latch.
    if (anchorsLoadLocked() && !gWipeLoadPending) restoreStartupConfigLocked();

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
    if (ioLock()) {
        runAutoWipeCheckLocked();
        ioUnlock();
    }
}

// See the long note in det_log.h. Persisted so a deployed board keeps recording across the
// brownout resets that a week in the field guarantees; without persistence this switch would
// silently revert on the first reset and the deployment would quietly collect nothing.
void detLogSetBufferAll(bool on) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (on) {
        // Config objects are processed in field order, so {"buffer":false,"bufall":true} reaches
        // this API after the off transition. Never persist the weakened Stationary posture while
        // capture is effectively disabled. A staged/failing buffer:true transition may still own a
        // newer bufall:true intent and is explicitly allowed.
        const bool targetEnabled = !gDisableAwaitingEraseToken &&
            (gEnableTransitionPending ? gPendingEnabled : gEnabled);
        if (!targetEnabled) { ioUnlock(); return; }
    }
    if (on == gBufferAll && !gBufferAllTransitionPending) { ioUnlock(); return; }
    gBufferAll = on;
    gPendingBufferAll = on;
    gBufferAllTransitionPending = true;
    // During startup the retained `on=false` cleanup deliberately clears bufall. Persist only
    // after that state is published and any staged enable has committed, or this user write can
    // be silently undone by the restore transaction in the same callback window.
    if (!gStartupConfigPending && !gDisableCleanupPending && !gEnableTransitionPending)
        persistBufferAllLocked();
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

// True once Stationary capture has reached ring capacity. Later nearby rows MAY have been omitted;
// the flag is deliberately raised on exact fill, so it is not proof of an actual refusal. PERSISTED
// across deployment reboots and cleared only by detLogClear; detLogSatDrops is the actual-refusal
// counter for this boot.
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
    gDraining = false;
    gDrainStartPending = false;
    gLastConnWritePending = false;
    invalidateDrainLocked();
    discardPendingKeysLocked();
    memset(gKey, 0, 32);
    gHaveKey = false;
    gKeyPersistencePending = false;
    gKeyRemovalPending = true;
    // gKeyFp deliberately SURVIVES this, in RAM and in NVS. Dropping the key does not drop the
    // records it encrypted, so the fingerprint is the only thing left that can recognise a
    // different phone's key arriving for them (see gKeyFp).
    persistKeyRemovalLocked();
}

static void beginDisableLocked() {
    gDisableAwaitingEraseToken = false;
    // Stop admission and forget the RAM copy immediately. NVS writes `on=false` first, so a power
    // loss after that commit makes startup finish any failed key removal before ready.
    gDraining = false;
    gDrainStartPending = false;
    gLastConnWritePending = false;
    invalidateDrainLocked();
    discardPendingKeysLocked();
    gEnabled = false;
    gBufferAll = false;
    gBufferAllTransitionPending = false;
    gPendingBufferAll = false;
    memset(gKey, 0, sizeof(gKey));
    gHaveKey = false;
    gKeyPersistencePending = false;
    // Repeated disable is still a cleanup transaction: a previous failure or key push while off
    // may have recreated a blob, and a staged rotation must not reinstall it later.
    gDisableCleanupPending = true;
    gEnableTransitionPending = true;
    gPendingEnabled = false;
    if (!gStartupConfigPending) persistEnableTransitionLocked();
}

void detLogSetEnabled(bool on) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    // A written `buffer:false` is itself an explicit request to forget key material that may be
    // retained in a task stack. Honour it even if the persisted master switch was already false:
    // a later panic can create a new dump while buffering remains disabled.
    if (!on) {
        // One non-retirable token covers every disabled config session in this physical boot.
        // Repeated state echoes must not burn several NVS writes per reconnect.
        if (!ensureDisabledKeyEraseLocked()) {
            // Without an older durable token there is no power-loss-safe way to claim that the key
            // was forgotten: a panic before the loop retry could retain the just-parsed key while
            // reboot restored the old config. Reject this transition and let the authenticated
            // session/tick retry establish the privacy boundary first.
            // The privacy command owns a strict age boundary: keys staged before it are part of
            // the state being forgotten. Only a key received after this flag is published may be
            // preserved across the deferred cleanup as a newer app intent.
            discardPendingKeysLocked();
            gDisableAwaitingEraseToken = true;
            ioUnlock();
            return;
        }
        if (gSaturationPersistencePending && !persistSaturationLocked()) {
            // The durable privacy token exists, but the evidence-capacity warning must precede
            // on=false/bufall=false. Keep admission blocked and finish both from the loop tick.
            discardPendingKeysLocked();
            gDisableAwaitingEraseToken = true;
            ioUnlock();
            return;
        }
        beginDisableLocked();
        ioUnlock();
        return;
    }

    // A newer explicit enable cancels an uncommitted RAM-only disable request. The failed token
    // itself still retries and remains held for this boot because sensitive callback bytes existed.
    gDisableAwaitingEraseToken = false;
    if (on == gEnabled && !gEnableTransitionPending) { ioUnlock(); return; }
    gEnableTransitionPending = true;
    gPendingEnabled = true;
    // Do not persist against default-empty startup state. The loop first publishes retained
    // config/key/fingerprint, then applies the newest staged key, then commits this transition.
    if (gStartupConfigPending) { ioUnlock(); return; }
    retryConfigPersistenceLocked();
    ioUnlock();
}
bool detLogEnabled() {
    if (!ioLock()) return gEnabled;
    const bool value = gEnabled;
    ioUnlock();
    return value;
}

static void stageIncomingKeyLocked(const uint8_t key[32], const uint8_t fp[8],
                                   bool allowDestructiveReplacement) {
    memcpy(gStartupPendingKey, key, sizeof(gStartupPendingKey));
    memcpy(gStartupPendingKeyFp, fp, sizeof(gStartupPendingKeyFp));
    gStartupPendingKeyValid = true;
    gStartupPendingKeyMayReplace = allowDestructiveReplacement;
}

static void stageWipePendingKeyLocked(const uint8_t key[32], const uint8_t fp[8]) {
    // A not-yet-published wipe generation owns exactly one eventual key, with ordinary config
    // last-write-wins semantics. Replacing both halves here prevents a later arm publication from
    // reinstalling an older rotation key after a newer app key was already accepted.
    memcpy(gWipePendingKey, key, sizeof(gWipePendingKey));
    memcpy(gWipePendingKeyFp, fp, sizeof(gWipePendingKeyFp));
    gWipePendingKeyValid = true;
    gWipePendingKeyHaveFp = true;
}

static bool keyReplacementNeedsClearLocked(const uint8_t fp[8]) {
    const bool rawStorageUnavailable = gPart == nullptr || gSlots == 0 || !gRingScanReady;
    const bool untrustedGeometry = appendBlockedLocked() || rawStorageUnavailable;
    const bool differs = !gHaveKeyFp || memcmp(gKeyFp, fp, sizeof(gKeyFp)) != 0;
    return differs && (countLocked() > 0 || untrustedGeometry);
}

static DetLogKeyResult installVerifiedKeyLocked(const uint8_t key[32], const uint8_t fp[8],
                                                 bool allowDestructiveReplacement) {
    // While off, the key exists solely to decrypt a same-session replay. A retained panic dump can
    // outlive RAM and NVS cleanup, so do not publish even one byte until a fresh durable coredump
    // erase generation is pinned. If NVS is unavailable the caller keeps the key staged and sync
    // stays deferred; retrying is safer than accepting a key whose cleanup promise never landed.
    if (!gEnabled) {
        if (!ensureDisabledKeyEraseLocked()) return DET_LOG_KEY_PENDING;
        gSensitiveStackExposedThisBoot = true;
    }

    const uint32_t rowCount = countLocked();
    // A failed raw scan can undercount the ring all the way to zero. Missing key identity plus
    // untrusted geometry is therefore just as unknown as a visibly nonempty keyless ring: old
    // ciphertext may reappear on the next clean reboot. Require a full durable generation wipe
    // before publishing the incoming key in either case.
    const bool rawStorageUnavailable = gPart == nullptr || gSlots == 0;
    const bool untrustedGeometry = appendBlockedLocked() || rawStorageUnavailable;
    const bool unknownGeneration = !gHaveKeyFp && (rowCount > 0 || untrustedGeometry);
    const bool changed = unknownGeneration ||
                         (gHaveKeyFp && memcmp(gKeyFp, fp, sizeof(gKeyFp)) != 0);
    if (changed && (rowCount > 0 || untrustedGeometry) && !allowDestructiveReplacement) {
        // A normal handshake is not ownership-transfer consent. Keep the old key and every row so
        // another bonded phone cannot destroy history merely by pushing its own installation key.
        return DET_LOG_KEY_MISMATCH;
    }
    if (changed) {
        // Even an empty ring does not prove the old key is absent from the retained task stacks.
        if (!gKeyChangeEraseArmed) {
            gKeyChangeEraseArmed = true;
            requestSensitiveEraseLocked();
        }
        // A pre-armed authenticated session normally supplies the older durable token here. Direct
        // callers still fail closed: if the first cdwipe write failed, leave the incoming key staged
        // and block sync until the loop retry creates a real power-loss backstop.
        if (!sensitiveEraseDurableLocked()) return DET_LOG_KEY_PENDING;
        if (gEnabled) {
            // Make the old retained key unreloadable BEFORE a new ring/nonce generation or the
            // replacement RAM key is published. If replacement persistence then fails, reboot is
            // keyless (or sees keydrop=true) instead of silently capturing the fresh generation
            // under the obsolete key. The old fingerprint intentionally remains as the conservative
            // identity boundary until the replacement pair lands.
            gKeyRemovalPending = true;
            if (!persistKeyRemovalLocked()) return DET_LOG_KEY_PENDING;
        }
        if (rowCount > 0 || untrustedGeometry) {
            const bool wipePublished = clearLocked(false); // token advanced exactly once above
            if (!wipePublished) {
                // The old-key log is still the published generation. Do not replace its decrypting
                // key until wipe=true plus fresh generation/domain commit; the loop-side publish
                // installs this staged key atomically with the empty generation. This includes
                // pre-arm boot/RNG failures where gWipeArmPending was never able to become true.
                stageWipePendingKeyLocked(key, fp);
                gKeyChangeEraseArmed = false;
                return DET_LOG_KEY_ACCEPTED;
            }
        }
        gKeyChangeEraseArmed = false;
    }
    memcpy(gKey, key, sizeof(gKey));
    gHaveKey = true;
    memcpy(gKeyFp, fp, sizeof(gKeyFp));
    gHaveKeyFp = true;
    // Persist the KEY ITSELF only while buffering is enabled, so it never sits in flash while
    // buffering is off (the app pushes the key on every connect, including when off). When
    // on, this is the deploy-and-leave reboot-survival path; SECURITY TRADEOFF: a seized
    // board's flash then yields the key (see det_log.h). A key that arrives before the
    // enable is re-persisted by detLogSetEnabled(true).
    if (gEnabled) persistKeyStateLocked();
    return DET_LOG_KEY_ACCEPTED;
}

DetLogKeyResult detLogSetKey(const uint8_t key[32], bool allowDestructiveReplacement) {
    // Records are encrypted under whatever key was active when each was written, and the slot CRC
    // is over CIPHERTEXT, so a mismatched key still passes CRC and would decrypt old records to
    // garbage. An ordinary different-key handshake therefore returns MISMATCH while preserving the
    // current key and rows; only an explicitly authorized clear/ownership transfer may enter the
    // wipe-and-replace transaction below. Normal reconnects push the same key and remain a no-op.
    //
    // Compared against the PERSISTED FINGERPRINT, never against gKey: gKey is empty in exactly
    // the cases that matter (buffering turned off, or a reboot while off, both of which keep
    // every record), so a gHaveKey-conditioned guard cannot fire there. See gKeyFp. Erasing on
    // disable instead is NOT the answer: the original phone still holds its key, so its records
    // stay legitimately drainable, and a buffer toggled off mid-drain would silently truncate
    // the user's own replay.
    uint8_t fp[8];
    const bool haveFp = keyFingerprint(key, fp);
    if (!ioLock()) return DET_LOG_KEY_REJECTED;
    if (!haveFp) {
        // An unverified key cannot participate in the old-row identity comparison. Installing it
        // would turn a crypto error into mixed-key ciphertext that still passes the slot CRC.
        latchFaultLocked(DET_LOG_FAULT_CRYPTO);
        ioUnlock();
        return DET_LOG_KEY_REJECTED;
    }
    // Until startup and the raw-ring scan publish authoritative metadata, even a well-formed key
    // cannot be proven equal to the retained generation. Do not stage it for later auto-application:
    // that was the sync-before-key hole in another form, because a later mismatch could silently
    // wipe or authorize replay after this callback had already returned. The app retries/reconnects.
    if (gStartupConfigPending || !gRingScanReady) {
        ioUnlock();
        return DET_LOG_KEY_PENDING;
    }
    if (!allowDestructiveReplacement && keyReplacementNeedsClearLocked(fp)) {
        ioUnlock();
        return DET_LOG_KEY_MISMATCH;
    }
    if (gDisableCleanupPending ||
        gClearKeyAwaitingEraseToken || gDisableAwaitingEraseToken ||
        gEnableTransitionPending) {
        // Privacy/config coordinators own ordering over an unrelated pending ring clear. Their
        // cleanup helpers discard older wipe keys, then preserve/apply this newer staged intent.
        stageIncomingKeyLocked(key, fp, allowDestructiveReplacement);
        ioUnlock();
        return DET_LOG_KEY_ACCEPTED;
    }
    if (gWipePendingKeyValid || gRingClearDeferred || gWipeArmPending) {
        // The raw generation is committed to a pending clear/rotation but has not yet published
        // its final key. Keep last-write-wins, while treating a changed enabled key as a real key
        // rotation: before this wipe may publish it, a dump-erasure token must be durable and the
        // old NVS key must be unreloadable. Otherwise replacement persistence can fail after the
        // new generation publishes and reboot can silently restore the obsolete key.
        const bool changed = !gHaveKeyFp || memcmp(gKeyFp, fp, sizeof(gKeyFp)) != 0;
        stageWipePendingKeyLocked(key, fp);
        if (changed) {
            if (!gKeyChangeEraseArmed) {
                gKeyChangeEraseArmed = true;
                requestSensitiveEraseLocked();
            }
            if (!sensitiveEraseDurableLocked()) {
                ioUnlock();
                return DET_LOG_KEY_ACCEPTED;
            }
            if (gEnabled) {
                gKeyRemovalPending = true;
                if (!persistKeyRemovalLocked()) {
                    ioUnlock();
                    return DET_LOG_KEY_ACCEPTED;
                }
            }
            gKeyChangeEraseArmed = false;
        } else if (!gKeyRemovalPending) {
            // A newer write restored the currently published key before any old-key cleanup
            // started. The already-requested dump token remains safely held, but no rotation
            // prerequisite remains for the wipe publication.
            gKeyChangeEraseArmed = false;
        }
        ioUnlock();
        return DET_LOG_KEY_ACCEPTED;
    }
    if (gKeyRemovalPending) {
        stageIncomingKeyLocked(key, fp, allowDestructiveReplacement);
        ioUnlock();
        return DET_LOG_KEY_ACCEPTED;
    }
    const DetLogKeyResult result =
        installVerifiedKeyLocked(key, fp, allowDestructiveReplacement);
    if (result == DET_LOG_KEY_PENDING)
        stageIncomingKeyLocked(key, fp, allowDestructiveReplacement);
    ioUnlock();
    return result;
}
void detLogClearKey() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (!ensureDisabledKeyEraseLocked()) {
        // Same fail-closed boundary as buffer:false: do not publish a keyless state until a retained
        // dump-erasure token is durable across an immediate panic/reboot.
        // Do not let a key staged before the clear survive merely because the dump-erasure token
        // needed a retry. detLogSetKey stages any genuinely newer key after this flag is visible.
        discardPendingKeysLocked();
        gClearKeyAwaitingEraseToken = true;
        ioUnlock();
        return;
    }
    gClearKeyAwaitingEraseToken = false;
    clearKeyLocked();
    ioUnlock();
}
bool detLogHaveKey() {
    if (!ioLock()) return gHaveKey;
    const bool value = gHaveKey;
    ioUnlock();
    return value;
}

bool detLogPrepareConfigSession() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return false; }
    // Arm before CfgCb is allowed to parse any authenticated config. This covers replay-only keys,
    // enabled-buffer rotations, and clear/disable commands before their decoded JSON or key bytes
    // can reach callback stacks. One boot/session arm is reused, so reconnect churn does not mint a
    // new NVS generation each time. The hold deliberately lasts until reboot.
    const bool ready = ensureDisabledKeyEraseLocked();
    if (ready) gSensitiveStackExposedThisBoot = true;
    ioUnlock();
    return ready;
}

void detLogEndConfigSession() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (!gEnabled && !(gEnableTransitionPending && gPendingEnabled)) {
        // Replay-only keys were never persisted, so ending the session is a RAM scrub, not a
        // keydrop transaction. Keep the config erase arm pinned for this physical boot: the same
        // durable token plus the boot-lifetime exposure hold covers every later authenticated
        // reconnect without four NVS writes per connect/disconnect cycle.
        gDraining = false;
        gDrainStartPending = false;
        gLastConnWritePending = false;
        gPendingDrainLogGeneration = 0;
        invalidateDrainLocked();
        discardPendingKeysLocked();
        memset(gKey, 0, sizeof(gKey));
        gHaveKey = false;
    }
    ioUnlock();
}

void detLogSetEpoch(uint32_t unixSec) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    const uint32_t atMs = millis();
    if (gStartupConfigPending || !gAnchorsReady || gAnchorsLoadPending) {
        // The epoch belongs to the eventual durable gBoot, never reset-value boot 0. Preserve the
        // original receipt uptime so a delayed retry does not shift every reconstructed time.
        gStartupPendingEpoch = unixSec;
        gStartupPendingEpochAtMs = atMs;
        gStartupPendingEpochValid = true;
        ioUnlock();
        return;
    }
    gEpochUnix = unixSec; gEpochAtMs = atMs;
    // Persist it against THIS boot, so records captured in this boot stay datable even if the
    // board reboots before the app next connects.
    anchorPut(gBoot, gEpochUnix, gEpochAtMs);
    ioUnlock();
}

static uint32_t setCaptureAdmissionBoundary(bool blocked) {
    if (!captureDeliveryLock()) {
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        return 0;
    }
    if (!ioLock()) {
        // Never let the scanner publish an unchanged epoch as a successful owner boundary. Zero is
        // not live. The atomic latch blocks queue claims without an unlocked read/modify/write of
        // mutex-owned gFaults; a later successful boundary clears it.
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        captureDeliveryUnlock();
        return 0;
    }
    gCaptureAdmissionEpoch++;
    if (gCaptureAdmissionEpoch == 0) gCaptureAdmissionEpoch = 1;
    gCaptureAdmissionBlocked = blocked;
    __atomic_store_n(&gCaptureAdmissionInvalid, false, __ATOMIC_RELEASE);
    const uint32_t epoch = gCaptureAdmissionEpoch;
    ioUnlock();
    captureDeliveryUnlock();
    return epoch;
}

uint32_t detLogBlockCaptureForOwnerSession() {
    return setCaptureAdmissionBoundary(true);
}

bool detLogAdmitCaptureForOwnerSession(uint32_t epoch) {
    if (epoch == 0) return false;
    if (!captureDeliveryLock()) {
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        return false;
    }
    if (!ioLock()) {
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        captureDeliveryUnlock();
        return false;
    }
    // Do not advance here. The scanner deliberately stamps 0 while authentication is preparing,
    // then publishes this already-reserved epoch only after GPS clearing + privacy pre-arm finish.
    // A stale or duplicated completion must not release a newer owner's block.
    const bool matches = gCaptureAdmissionBlocked && epoch == gCaptureAdmissionEpoch;
    if (matches) {
        gCaptureAdmissionBlocked = false;
        __atomic_store_n(&gCaptureAdmissionInvalid, false, __ATOMIC_RELEASE);
    }
    ioUnlock();
    captureDeliveryUnlock();
    return matches;
}

uint32_t detLogAdvanceCaptureEpoch() {
    return setCaptureAdmissionBoundary(false);
}

bool detLogDeliverIfCaptureEpochCurrent(uint32_t epoch,
                                        DetLogCaptureDelivery deliver,
                                        void* context) {
    if (epoch == 0 || !deliver) return false;
    if (!captureDeliveryLock()) {
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        return false;
    }
    if (!ioLock()) {
        // This path cannot safely update mutex-owned gFaults. The atomic invalid latch makes every
        // later append/delivery fail closed until a successful owner boundary repairs it.
        __atomic_store_n(&gCaptureAdmissionInvalid, true, __ATOMIC_RELEASE);
        captureDeliveryUnlock();
        return false;
    }
    const bool current = !__atomic_load_n(&gCaptureAdmissionInvalid, __ATOMIC_ACQUIRE) &&
                         !gCaptureAdmissionBlocked && epoch == gCaptureAdmissionEpoch;
    // Release gIoMutex before entering BLE/mesh/alerts. The dedicated owner-delivery mutex stays
    // held, so authentication/disconnect cannot advance the epoch between validation and notify,
    // without creating the JsonPoolLock <-> gIoMutex inversion described at its declaration.
    ioUnlock();
    if (current) deliver(context);
    captureDeliveryUnlock();
    return current;
}

static DetLogAppendResult appendLocked(const AcabDetection& d, const DetLogGpsStamp* gps,
                                       bool enforceCaptureEpoch, uint32_t captureEpoch) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return DET_LOG_APPEND_RETRY; }
    // Recheck every admission condition while holding the same lock as clear, key changes,
    // and the wipe tick. A caller that arrived just before one of those transitions cannot
    // commit a stale-key record or write behind an erase that already promised an empty log.
    // Stable admission failures keep the asynchronous scanner claim consumed. Releasing it would
    // make every advert hammer the sink again while buffering is deliberately off, the phone is
    // connected, no key exists, or raw geometry is unavailable/untrusted. Those states are
    // re-armed by the scanner's connection/config capture-generation boundary instead.
    if (__atomic_load_n(&gCaptureAdmissionInvalid, __ATOMIC_ACQUIRE) ||
        gCaptureAdmissionBlocked || acabBleClientConnected() ||
        (enforceCaptureEpoch && captureEpoch != gCaptureAdmissionEpoch) ||
        gSlots == 0 || appendBlockedLocked() ||
        gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken ||
        (gEnableTransitionPending && !gPendingEnabled)) {
        ioUnlock();
        return DET_LOG_APPEND_NOT_ARMED;
    }
    // These transactions can finish from the maintenance tick while the app remains away and
    // without a scanner generation bump, so a refused queued row must be allowed to claim again.
    if (gStartupConfigPending || gStartupPendingKeyValid ||
        gEnableTransitionPending || gKeyPersistencePending || gKeyRemovalPending ||
        gDisableCleanupPending ||
        gBufferAllTransitionPending || gSaturationPersistencePending ||
        gDrainStartPending || gLastConnWritePending || !gRingScanReady ||
        gExplicitClearPending || gRingClearDeferred || gWipeArmPending) {
        ioUnlock();
        return DET_LOG_APPEND_RETRY;
    }
    if (gWipePending) {
        ioUnlock();
        return DET_LOG_APPEND_RETRY;
    }
    if (!gEnabled || !gHaveKey) {
        ioUnlock();
        return DET_LOG_APPEND_NOT_ARMED;
    }
    // 0 and 0xFFFFFFFF are reserved empty-slot sentinels. Once the last usable sequence has
    // committed, advancing gHead reaches the sentinel; allowing one more append would either
    // write an unscannable header or wrap to seq 0 and eventually reuse AES-CTR nonces under the
    // same key/boot. Start a fresh durable boot generation before admitting any more records.
    if (gHead == 0 || gHead == 0xFFFFFFFFu) {
        clearLocked(false);
        ioUnlock();
        return DET_LOG_APPEND_RETRY;
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
        markSaturatedLocked();      // normally already set by the exact-fill transition
        ioUnlock();
        return DET_LOG_APPEND_CAPACITY_DROP;
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
    // ---- the record's position, decided in ONE place ----
    // First the detection's own: a drone's broadcast coordinates, or an onboard/nRF-forwarded fix.
    int32_t  latE7 = (int32_t)(d.lat * 1e7);
    int32_t  lonE7 = (int32_t)(d.lon * 1e7);
    uint32_t ageMs = d.gpsAgeMs;
    // Then the out-of-band stamp (the retained phone fix; see DetLogGpsStamp), which fills in only
    // where the detection carried nothing. The caller already gates on that; repeating it here is
    // what makes "a broadcast drone position is never overwritten" true of the writer itself.
    if (gps && gps->valid && latE7 == 0 && lonE7 == 0) {
        latE7 = gps->lat_e7;
        lonE7 = gps->lon_e7;
        ageMs = (uint32_t)gps->ageSec * 1000u;
    }
    // AGE BOUND, ENFORCED HERE because this is the only place a coordinate reaches storage.
    // Past DET_LOG_GPS_MAX_AGE_MS the age no longer fits gpsAgeSec, and a real coordinate beside a
    // saturated age is a claim the board cannot support: the apps render that age verbatim, so a
    // two-day-old fix would read as "18h12m". The out-of-band stamp is already bounded at its read
    // (acab_scanner passes the constant to acabBleGetLastPhoneGps), but the LIVE stamp is not -
    // handleDetection takes that one at "any age", and such a row reaches this append whenever the
    // link drops between the ingest and the sink task. Drop the position and keep the row: WHAT
    // went by still stands, and only the WHERE is withheld.
    if (ageMs > DET_LOG_GPS_MAX_AGE_MS) { latE7 = 0; lonE7 = 0; ageMs = 0; }
    s.lat_e7 = latE7;
    s.lon_e7 = lonE7;
    s.gpsAgeSec = (uint16_t)(ageMs / 1000);   // bounded above, so this can no longer saturate
    s.count  = d.count;
    strncpy(s.uasid, d.id,   sizeof(s.uasid));       // drone identity (truncated)
    strncpy(s.name,  d.name, sizeof(s.name));

    if (!cryptPayload(&s)) {                         // encrypt payload in place
        latchFaultLocked(DET_LOG_FAULT_CRYPTO);
        ioUnlock();
        return DET_LOG_APPEND_NOT_ARMED;
    }
    s.crc = recordCrc(&s);                 // ciphertext plus every clear header field except crc
    const uint32_t idx = slotOf(seq);
    const bool stored = prepareSlotLocked(seq, idx) && writeSlotLocked(idx, &s);
    if (stored) {
        gHead = seq + 1;
        if (gHead - gOldest > gSlots) gOldest = gHead - gSlots;
        if (gBufferAll && countLocked() >= gSlots) markSaturatedLocked();
    }
    ioUnlock();
    // prepare/write failures latch a raw blocking fault. Releasing the scanner claim would only
    // cause repeated writes against geometry that now requires an explicit physical wipe.
    return stored ? DET_LOG_APPEND_STORED : DET_LOG_APPEND_NOT_ARMED;
}

DetLogAppendResult detLogAppend(const AcabDetection& d, const DetLogGpsStamp* gps) {
    return appendLocked(d, gps, false, 0);
}

DetLogAppendResult detLogAppendClaimed(const AcabDetection& d, const DetLogGpsStamp* gps,
                                       uint32_t captureEpoch) {
    return appendLocked(d, gps, true, captureEpoch);
}

static void armDrainLocked(uint32_t lastSeq, uint32_t clientLogGeneration) {
    // Sequence space overlaps after every clear. A stale cursor can therefore be BELOW the new
    // head after enough new rows arrive, which no cursor-only heuristic can distinguish from an
    // ordinary resume. Only a matching durable log generation authorizes the cursor; old clients
    // and missing/zero generations safely replay the retained window from its floor.
    // Resume only from a cursor that names the retained window. A matching-generation future
    // cursor is not authoritative: accepting it produces an empty replay (and UINT_MAX also wraps
    // cursor+1). Rebase missing, stale, sentinel, and out-of-window cursors to the retained floor.
    const uint32_t floor = (gOldest > 0) ? gOldest - 1 : 0;
    const uint32_t ceiling = (gHead > 0) ? gHead - 1 : 0;
    if (clientLogGeneration == 0 || clientLogGeneration != gLogGeneration ||
        lastSeq < floor || lastSeq > ceiling) {
        lastSeq = floor;
    }
    gDrain = lastSeq;
    gDraining = gDrain < ceiling;
}

DetLogDrainStartResult detLogStartDrain(uint32_t lastSeq, uint32_t clientLogGeneration) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return DET_LOG_DRAIN_REJECTED; }
    // Start is an invalidation even when the partition is unavailable or the resulting drain is
    // empty. A caller holding a peek from the previous drain must never gain authority over a
    // later start merely because both cursors happen to name the same seq.
    invalidateDrainLocked();
    gDraining = false;
    gDrainStartPending = false;
    gLastConnWritePending = false;
    gPendingDrainLogGeneration = 0;
    if (gSlots == 0) {
        ioUnlock();
        return DET_LOG_DRAIN_REJECTED;
    }
    const bool transientReadiness = gStartupConfigPending || gStartupPendingKeyValid ||
        gEnableTransitionPending || gKeyPersistencePending || gKeyRemovalPending ||
        gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken ||
        gRingClearDeferred || gExplicitClearPending || !gRingScanReady ||
        !gAnchorsReady || gAnchorsLoadPending ||
        gAnchorsSavePending || gWipePending || gWipeArmPending || gWipeLoadPending ||
        gLogGeneration == 0;
    if (!gHaveKey || transientReadiness) {
        // Preserve a sync that arrived as part of the startup handshake while its key/config/wipe
        // transaction is still retrying. A genuinely keyless, otherwise-ready board still rejects
        // the request, matching the keyless replay contract.
        if (transientReadiness) {
            gPendingDrainCursor = lastSeq;
            gPendingDrainLogGeneration = clientLogGeneration;
            gDrainStartPending = true;
        }
        ioUnlock();
        return transientReadiness ? DET_LOG_DRAIN_PENDING : DET_LOG_DRAIN_REJECTED;
    }

    // A sync is not accepted until its auto-wipe reset is durable. Otherwise the app can receive
    // a complete replay, reboot the board, and still have the supposedly-drained generation
    // erased because lastconn silently retained an older boot. A transient failure is retried by
    // detLogEraseTick; disconnect/stop cancels the deferred arm.
    gPendingDrainCursor = lastSeq;
    gPendingDrainLogGeneration = clientLogGeneration;
    gDrainStartPending = true;
    gLastConnWritePending = true;
    if (persistLastConnectionLocked()) {
        gDrainStartPending = false;
        armDrainLocked(lastSeq, clientLogGeneration);
        const DetLogDrainStartResult result = gDraining ? DET_LOG_DRAIN_STARTED
                                                        : DET_LOG_DRAIN_EMPTY;
        ioUnlock();
        return result;
    }
    ioUnlock();
    return DET_LOG_DRAIN_PENDING;
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
    gDrainStartPending = false;
    gLastConnWritePending = false;
    gPendingDrainLogGeneration = 0;
    invalidateDrainLocked();
    ioUnlock();
}

bool detLogPeekForDrain(DetLogReplay* out) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return false; }
    if (!out || !gDraining || gSlots == 0 || !gHaveKey || !gAnchorsReady ||
        gAnchorsLoadPending || gAnchorsSavePending || gStartupConfigPending ||
        gEnableTransitionPending || gKeyPersistencePending || gKeyRemovalPending ||
        gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken ||
        gExplicitClearPending ||
        gWipePending || gWipeArmPending || gWipeLoadPending) {
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

    if (!cryptPayload(&s)) {                         // decrypt in place
        latchFaultLocked(DET_LOG_FAULT_CRYPTO);
        gDraining = false;
        ioUnlock();
        return false;
    }
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
    out->drainGeneration = gDrainGeneration;
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

bool detLogCommitDrain(uint32_t seq, uint64_t drainGeneration) {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return false; }
    // The matching peek does not hold the mutex across JSON construction and BLE notification.
    // Revalidate the capability AND cursor relation here so a stop/start ABA at the same seq, a
    // concurrent clear, disconnect, or (in a test) sector eviction cannot commit a stale peek.
    const bool ok = gDraining && drainGeneration != 0 &&
                    drainGeneration == gDrainGeneration && seq != 0 && seq != 0xFFFFFFFFu &&
                    seq == gDrain + 1 && seq >= gOldest && seq < gHead;
    if (ok) gDrain = seq;
    ioUnlock();
    return ok;
}

static bool clearLocked(bool requestSensitiveErase) {
    // Clear invalidates a peek even when the ring partition is absent. Keep this before every
    // early return so the API contract is about the action, not the current mount state.
    gDraining = false;
    gDrainStartPending = false;
    gLastConnWritePending = false;
    invalidateDrainLocked();
    // Persist the coredump intent even when the ring partition is absent. It is independent flash
    // state, and `clearlog` must mean the same thing on a board whose ring failed to mount.
    if (requestSensitiveErase) {
        requestSensitiveEraseLocked();
        if (!sensitiveEraseDurableLocked()) {
            // Do not publish a logical/physical clear while a retained dump containing the same
            // key/rows has no durable erase promise. Keep the old ring intact and unavailable to a
            // staged sync; the loop applies clear(false) only after cdwipe retry succeeds.
            gExplicitClearPending = true;
            return false;
        }
    }
    gExplicitClearPending = false;
    if (destructivePrivacyPendingLocked()) {
        // A disable/clear-key command that has not reached its own durable recovery marker owns
        // ordering over this clear. Do not write wipegen/wipe yet: after a sudden reboot that
        // partial arm could otherwise publish a fresh generation with the obsolete retained key.
        gRingClearDeferred = true;
        gWipePending = true;
        return false;
    }
    if (gStartupConfigPending || gWipeLoadPending) {
        // gBoot is not authoritative until startup publishes the retained counter. Persisting a
        // clear generation from its reset value could overwrite a much newer nonce generation
        // with boot=1. This also covers an unavailable raw partition: persist its tombstone now and
        // keep it pending until a later boot can mount and physically sweep the possibly-present
        // rows. Remember the user action and arm it after startup/prior wipe state are known.
        gRingClearDeferred = true;
        gWipePending = true;
        persistRingWipeTombstoneLocked();
        return false;
    }
    // The flash sweep stays deferred to loop(), but the logical clear is published only after its
    // NVS latch and next encryption generation are durable. On an NVS refusal armRingWipeLocked()
    // leaves the old count/cursors intact, blocks appends and drains, and detLogEraseTick retries;
    // a power loss in that window therefore sees either the intact old log or a durable wipe, never
    // an empty RAM generation whose old slots can reappear.
    return armRingWipeLocked();
}

void detLogClear() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    clearLocked(true);
    ioUnlock();
}

static void applyStartupEpochLocked() {
    if (!gStartupPendingEpochValid) return;
    gEpochUnix = gStartupPendingEpoch;
    gEpochAtMs = gStartupPendingEpochAtMs;
    gStartupPendingEpochValid = false;
    anchorPut(gBoot, gEpochUnix, gEpochAtMs);
}

static bool applyStartupKeyLocked() {
    if (!gStartupPendingKeyValid) return true;
    uint8_t key[sizeof(gStartupPendingKey)];
    uint8_t fp[sizeof(gStartupPendingKeyFp)];
    memcpy(key, gStartupPendingKey, sizeof(key));
    memcpy(fp, gStartupPendingKeyFp, sizeof(fp));
    const DetLogKeyResult result =
        installVerifiedKeyLocked(key, fp, gStartupPendingKeyMayReplace);
    if (result == DET_LOG_KEY_ACCEPTED || result == DET_LOG_KEY_MISMATCH) {
        memset(gStartupPendingKey, 0, sizeof(gStartupPendingKey));
        memset(gStartupPendingKeyFp, 0, sizeof(gStartupPendingKeyFp));
        gStartupPendingKeyValid = false;
        gStartupPendingKeyMayReplace = false;
        if (result == DET_LOG_KEY_MISMATCH) {
            // The state changed while the key was staged. Never let an already-staged sync fall
            // through and use the retained old key after rejecting the offered replacement.
            gDrainStartPending = false;
            gLastConnWritePending = false;
            invalidateDrainLocked();
        }
    }
    memset(key, 0, sizeof(key));
    memset(fp, 0, sizeof(fp));
    return result == DET_LOG_KEY_ACCEPTED || result == DET_LOG_KEY_MISMATCH;
}

static bool retryConfigPersistenceLocked() {
    // A clear-key request is the newer privacy intent. Complete it before an enable transition is
    // allowed to clear keydrop=false; otherwise a residual old blob can survive and reload.
    if (gKeyRemovalPending && !persistKeyRemovalLocked()) return false;
    while (gDisableCleanupPending) {
        if (!persistEnableTransitionLocked()) return false;
    }
    // A key supplied with a newer enable request is persistent configuration, not an ephemeral
    // off-state replay key. Install it before on=true so the enable transaction writes key/fp
    // first. If comparison arms a generation wipe, let the caller commit that boundary before
    // continuing the enable transaction.
    if (gEnableTransitionPending && gPendingEnabled && gStartupPendingKeyValid) {
        if (!applyStartupKeyLocked()) return false;
        if (gWipeArmPending) return false;
    }
    while (gEnableTransitionPending) {
        if (!persistEnableTransitionLocked()) return false;
    }
    if (gKeyPersistencePending && !persistKeyStateLocked()) return false;
    if (gBufferAllTransitionPending && !persistBufferAllLocked()) return false;
    if (gSaturationPersistencePending && !persistSaturationLocked()) return false;
    return true;
}

// One chunk of a latched wipe: erase a single 64KB flash block per call. Runs on the loop
// task (pumped by acabBleDrainTick), NEVER the NimBLE host task - each block erase disables
// the flash cache for ~100-250ms, and chunking with a loop-pass gap between blocks keeps
// GATT, scanning, and the sink task live across the sweep instead of a device-wide stall.
void detLogEraseTick() {
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    if (gFaultPersistencePending) persistFaultsLocked();
    retrySensitiveErasePersistenceLocked();
    if (gAnchorsLoadPending && !anchorsLoadLocked()) { ioUnlock(); return; }

    // Ring-format and wipe intent live in NVS, not the raw partition. Retry them even while the
    // partition is unavailable so a failed clear tombstone/arm can become durable before power
    // loss. Only the physical scan below depends on a mount.
    if (gRingFormatPending && !ensureRingFormatLocked()) { ioUnlock(); return; }
    // Boot could not establish whether a durable wipe was active. Retry the NVS read before a
    // single raw slot is inspected. A true result resumes the sweep; a positively false result
    // performs the deferred scan now, while the mutex still excludes append/drain.
    if (gWipeLoadPending) {
        bool persistedWipe = false;
        if (!restoreRingWipeLocked(&persistedWipe)) { ioUnlock(); return; }
        gWipeLoadPending = false;
        if (persistedWipe) {
            gWipePending = true;
            gWipeNext = 0;
            gWipeStalled = false;
        } else {
            gWipePending = false;
            if (gSlots != 0) scanRingLocked();
            else gRingScanReady = false;
        }
    }
    // Boot identity is selected only after both anchor metadata and any uncondemned raw rows are
    // known, so a lost/regressed boot key cannot collide with either source and mis-date/decrypt
    // new records. A pending wipe makes old raw rows irrelevant by construction.
    if (gStartupConfigPending && !restoreStartupConfigLocked()) {
        ioUnlock();
        return;
    }
    // Privacy/config transitions can durably clear `on`/`bufall`, after which startup can no
    // longer reconstruct a lost exact-fill warning from geometry. Flush the marker before any of
    // those staged actions is allowed to publish.
    if (gSaturationPersistencePending && !persistSaturationLocked()) {
        ioUnlock();
        return;
    }
    // Complete RAM-staged privacy actions only after startup has published the retained config and
    // the retry above has established a power-loss-safe coredump token. A newer key can arrive in
    // the same config handshake while either action waits. Both cleanup helpers deliberately scrub
    // staged keys, so carry that exact newer key across the old-key cleanup and let the normal
    // coordinator install it afterward (RAM-only when the completed target is off).
    uint8_t deferredKey[sizeof(gStartupPendingKey)] = {};
    uint8_t deferredFp[sizeof(gStartupPendingKeyFp)] = {};
    bool deferredKeyMayReplace = false;
    const bool preserveDeferredKey =
        (gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken) &&
        gStartupPendingKeyValid;
    if (preserveDeferredKey) {
        memcpy(deferredKey, gStartupPendingKey, sizeof(deferredKey));
        memcpy(deferredFp, gStartupPendingKeyFp, sizeof(deferredFp));
        deferredKeyMayReplace = gStartupPendingKeyMayReplace;
    }
    if (gDisableAwaitingEraseToken && sensitiveEraseDurableLocked()) beginDisableLocked();
    if (gClearKeyAwaitingEraseToken && sensitiveEraseDurableLocked()) {
        gClearKeyAwaitingEraseToken = false;
        clearKeyLocked();
    }
    if (preserveDeferredKey && !gStartupPendingKeyValid) {
        memcpy(gStartupPendingKey, deferredKey, sizeof(gStartupPendingKey));
        memcpy(gStartupPendingKeyFp, deferredFp, sizeof(gStartupPendingKeyFp));
        gStartupPendingKeyValid = true;
        gStartupPendingKeyMayReplace = deferredKeyMayReplace;
    }
    memset(deferredKey, 0, sizeof(deferredKey));
    memset(deferredFp, 0, sizeof(deferredFp));
    if (gAnchorsReady && gAnchorsSavePending) anchorsSaveLocked();
    if (gAnchorsReady && !gAnchorsSavePending) applyStartupEpochLocked();
    if (gExplicitClearPending && sensitiveEraseDurableLocked()) {
        gExplicitClearPending = false;
        clearLocked(false);
    }
    // Standalone clear-key and buffer:false actions own the privacy boundary even when no
    // replacement key is staged. Complete their durable recovery marker before any pending clear
    // can publish a new boot/log/crypto generation. New enable/key intents remain staged until
    // after the arm, so this does not let later configuration bypass mandatory old-key cleanup.
    if (gDisableAwaitingEraseToken || gClearKeyAwaitingEraseToken) {
        ioUnlock();
        return;
    }
    if (gKeyRemovalPending && !persistKeyRemovalLocked()) {
        ioUnlock();
        return;
    }
    while (gDisableCleanupPending) {
        if (!persistEnableTransitionLocked()) {
            ioUnlock();
            return;
        }
    }
    // A changed key staged behind an already-pending ordinary clear still owns the same privacy
    // prerequisites as a direct rotation. Finish them before the clear can publish the new key.
    if (gWipePendingKeyValid && gKeyChangeEraseArmed) {
        if (!sensitiveEraseDurableLocked()) {
            ioUnlock();
            return;
        }
        if (gEnabled) {
            gKeyRemovalPending = true;
            if (!persistKeyRemovalLocked()) {
                ioUnlock();
                return;
            }
        }
        gKeyChangeEraseArmed = false;
    }
    if (gWipePendingKeyValid && gKeyRemovalPending && !persistKeyRemovalLocked()) {
        ioUnlock();
        return;
    }
    // Apply deferred user/config actions only after both the retained boot counter and prior wipe
    // latch are known. This ordering prevents boot regression, default-empty key comparisons, and
    // a transient startup failure from losing the connection's epoch.
    if (gRingClearDeferred) {
        gRingClearDeferred = false;
        if (!armRingWipeLocked()) {
            // armRingWipeLocked re-latches gRingClearDeferred on every pre-arm failure. Do not
            // fall through to config publication or a physical erase with no published target.
            ioUnlock();
            return;
        }
    }
    // A staged rotation can leave the old-key generation published until wipe=true lands. Commit
    // that boundary before an enable transition is allowed to persist whichever key is in RAM.
    if (gWipeArmPending) {
        if (!persistRingWipeArmLocked()) { ioUnlock(); return; }
        publishRingWipeArmLocked();
    }
    if (gSlots == 0) {
        if (!retryConfigPersistenceLocked() || !applyStartupKeyLocked()) {
            ioUnlock();
            return;
        }
        // A staged key can itself discover an unknown raw/key generation and arm another metadata
        // wipe. Persist it now; physical retirement intentionally waits for a later valid mount.
        if (gWipeArmPending) {
            if (!persistRingWipeArmLocked()) { ioUnlock(); return; }
            publishRingWipeArmLocked();
        }
        retryConfigPersistenceLocked();
        ioUnlock();
        return;
    }
    if (!retryConfigPersistenceLocked()) { ioUnlock(); return; }
    if (!applyStartupKeyLocked()) { ioUnlock(); return; }

    // Applying a deferred key can itself discover an old/unknown encryption generation and arm a
    // wipe. Land that condemnation boundary before persisting or replaying with the replacement.
    if (gWipeArmPending) {
        if (!persistRingWipeArmLocked()) { ioUnlock(); return; }
        publishRingWipeArmLocked();
    }
    if (!retryConfigPersistenceLocked()) { ioUnlock(); return; }

    // Retry the accepted-sync persistence before the deferred auto-wipe decision. Once lastconn
    // commits, this boot is no longer stale and a successful replay cannot be followed by an
    // erase caused solely by the formerly old marker. A disconnect clears the pending arm.
    if (gDrainStartPending && gHaveKey && gAnchorsReady && !gAnchorsSavePending &&
        !gAnchorsLoadPending && !gEnableTransitionPending &&
        !gKeyPersistencePending && !gKeyRemovalPending && gRingScanReady &&
        !gWipePending && !gWipeArmPending && !gWipeLoadPending && gLogGeneration != 0) {
        const uint32_t cursor = gPendingDrainCursor;
        const uint32_t clientGeneration = gPendingDrainLogGeneration;
        gLastConnWritePending = true;
        if (!persistLastConnectionLocked()) { ioUnlock(); return; }
        gDrainStartPending = false;
        gPendingDrainLogGeneration = 0;
        armDrainLocked(cursor, clientGeneration);
    }

    runAutoWipeCheckLocked();

    // A clear whose first NVS transaction failed has not published new cursors yet. Retry its
    // durable arm before erasing; once it lands, publishRingWipeArmLocked starts from offset zero.
    if (gWipeArmPending) {
        if (!persistRingWipeArmLocked()) { ioUnlock(); return; }
        publishRingWipeArmLocked();
    }

    // A conservative RAM block is not permission to erase. Physical retirement begins only after
    // a fresh target generation/domain has been durably armed and published; otherwise an RNG or
    // pre-arm failure could erase old rows, lose the clear on reboot, and later reuse cursor/nonce
    // authority. gRingClearDeferred remains true across every pre-arm failure and is retried above.
    if (gRingClearDeferred || gWipeArmPending ||
        (gWipePending &&
         (gWipeTargetGeneration == 0 || !domainPresent(gWipeTargetCryptoDomain) ||
          gLogGeneration != gWipeTargetGeneration ||
          memcmp(gCryptoDomain, gWipeTargetCryptoDomain, sizeof(gCryptoDomain)) != 0))) {
        ioUnlock();
        return;
    }

    // A boot that resumes an already-durable wipe did not execute publishRingWipeArmLocked in this
    // runtime. Reset the fresh generation's auto-wipe baseline before retirement all the same.
    if (gWipePending && gLastConnBoot != gBoot && !persistLastConnectionLocked()) {
        ioUnlock();
        return;
    }

    if (!gWipePending || gWipeStalled) { ioUnlock(); return; }
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
        // `wipe=false` is the retirement commit. Keep gWipePending high (and therefore appends
        // blocked) until it lands; otherwise new rows can be written while NVS still says true and
        // the next ordinary reboot will erase them as though they belonged to the old generation.
        Preferences p;
        if (!p.begin(NVS_NS, false)) {
            latchFaultLocked(DET_LOG_FAULT_NVS);
            ioUnlock();
            return;
        }
        // Clear stale raw-ring faults while the durable wipe tombstone still blocks appends and
        // boot scans. Retirement is last: once wipe=false lands, every prerequisite for admitting
        // the fresh generation is already durable.
        const bool saturationCleared =
            p.putBool("bufsat", false) == sizeof(bool);
        const bool faultCleared = saturationCleared &&
            p.putUInt("fault", DET_LOG_FAULT_NONE) == sizeof(uint32_t);
        // Retire the pending generation marker while wipe=true still blocks scans/appends. If the
        // final level write then fails, reboot resumes the already-published loggen rather than
        // inventing another generation; no row can have been admitted in between.
        const bool cryptoTargetRetired = faultCleared &&
            (!p.isKey("wipecdom") || p.remove("wipecdom"));
        const bool generationRetired = cryptoTargetRetired &&
            p.putUInt("wipegen", 0) == sizeof(uint32_t);
        const bool retired = generationRetired &&
                             p.putBool("wipe", false) == sizeof(bool);
        p.end();
        if (!saturationCleared || !faultCleared || !cryptoTargetRetired ||
            !generationRetired || !retired) {
            latchFaultLocked(DET_LOG_FAULT_NVS);
            ioUnlock();
            return;
        }
        gWipePending = false;
        gWipeTargetGeneration = 0;
        memset(gWipeTargetCryptoDomain, 0, sizeof(gWipeTargetCryptoDomain));
        gWipeStalled = false;
        gRingScanReady = true;
        gAutoWipeCheckPending = false;
        gSaturated = false;
        gSaturationPersistencePending = false;
        gSatDrops = 0;
        gFaults = DET_LOG_FAULT_NONE;
        gFaultPersistencePending = false;
    }
    ioUnlock();
}

bool detLogWipePending() {
    if (!ioLock()) return gWipePending;
    const bool value = gWipePending;
    ioUnlock();
    return value;
}

uint32_t detLogSensitiveErasePending() {
    if (!ioLock()) return gSensitiveEraseGen;
    // This runs from the loop task on every coredump-wipe pump. A transient NVS refusal during the
    // BLE config write therefore gets retried without another user action, while the public
    // generation remains unchanged until cdwipe is actually durable.
    retrySensitiveErasePersistenceLocked();
    const uint32_t generation = gSensitiveEraseGen;
    ioUnlock();
    return generation;
}

void detLogSensitiveEraseComplete(uint32_t generation) {
    if (generation == 0) return;
    if (!ioLock()) { gFaults |= DET_LOG_FAULT_LOCK; return; }
    // A disabled-session key is RAM-only. Keep its durable erase promise pinned even if the
    // coredump partition was empty (or was erased just before the key reached RAM): a panic later
    // in this same connection can create a new retained dump. Disconnect/disable forgets the key,
    // supersedes the generation, and only then permits completion.
    if (gSensitiveStackExposedThisBoot || disabledSessionKeyPresentLocked()) {
        ioUnlock();
        return;
    }
    // An erase started for generation N also physically covers any immutable retained dump that
    // existed when N+1 was requested, but do not silently consume that newer promise. Let the next
    // tick observe it (and complete it as a no-op once the cached dump is gone).
    if (gSensitiveEraseGen == generation && gSensitiveEraseRetryGen == 0) {
        Preferences p;
        size_t stored = 0;
        if (p.begin(NVS_NS, false)) {
            stored = p.putUInt("cdwipe", 0);
            p.end();
        }
        // Clear RAM only after the durable clear landed. If NVS rejects it, the next loop pass
        // retries rather than allowing a reboot to resurrect an apparently completed request.
        if (stored == sizeof(uint32_t)) gSensitiveEraseGen = 0;
        else latchFaultLocked(DET_LOG_FAULT_NVS);
    }
    ioUnlock();
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
    const uint32_t value = gDraining && gHead > 0 && gDrain < gHead - 1
        ? gHead - 1 - gDrain : 0;
    ioUnlock();
    return value;
}

bool detLogDrainStartPending() {
    if (!ioLock()) return false;
    const bool value = gDrainStartPending;
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

uint32_t detLogGeneration() {
    if (!ioLock()) return 0;
    const uint32_t value = gLogGeneration;
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
    if (!gCaptureDeliveryMutex)
        gCaptureDeliveryMutex = xSemaphoreCreateMutexStatic(&gCaptureDeliveryMutexStorage);
    if (!ioLock()) return;
    gPart = nullptr;
    gSlots = 0;
    gHead = 1;
    gOldest = 1;
    gBoot = 0;
    gMaxScannedBoot = 0;
    gLogGeneration = 0;
    gWipeTargetGeneration = 0;
    memset(gCryptoDomain, 0, sizeof(gCryptoDomain));
    memset(gWipeTargetCryptoDomain, 0, sizeof(gWipeTargetCryptoDomain));
    gDrain = 0;
    gCaptureAdmissionEpoch = 1;
    gCaptureAdmissionBlocked = false;
    __atomic_store_n(&gCaptureAdmissionInvalid, false, __ATOMIC_RELEASE);
    gDraining = false;
    gDrainGeneration = 0;
    gWipePending = false;
    gWipeNext = 0;
    gWipeStalled = false;
    gWipeArmPending = false;
    gWipeArmBoot = 0;
    gWipeLoadPending = false;
    gRingFormatPending = true;
    gRingScanReady = false;
    gAutoWipeCheckPending = false;
    gStartupConfigPending = true;
    gRingClearDeferred = false;
    gExplicitClearPending = false;
    gSensitiveEraseGen = 0;
    gSensitiveEraseCounter = 0;
    gSensitiveEraseRetryGen = 0;
    gSensitiveEraseCounterDirty = false;
    gSensitiveEraseLoadPending = false;
    gSensitiveEraseRequestDeferred = false;
    gDisabledKeyEraseArmed = false;
    gSensitiveStackExposedThisBoot = false;
    gEnabled = false;
    gEnableTransitionPending = false;
    gPendingEnabled = false;
    gDisableAwaitingEraseToken = false;
    gClearKeyAwaitingEraseToken = false;
    gDisableCleanupPending = false;
    gKeyPersistencePending = false;
    gKeyRemovalPending = false;
    gBufferAllTransitionPending = false;
    gPendingBufferAll = false;
    gBufferAll = false;
    gSaturated = false;
    gSaturationPersistencePending = false;
    gSatDrops = 0;
    gFaults = DET_LOG_FAULT_NONE;
    gFaultPersistencePending = false;
    memset(gKey, 0, sizeof(gKey));
    gHaveKey = false;
    memset(gKeyFp, 0, sizeof(gKeyFp));
    gHaveKeyFp = false;
    discardPendingKeysLocked();
    gEpochUnix = 0;
    gEpochAtMs = 0;
    gStartupPendingEpoch = 0;
    gStartupPendingEpochAtMs = 0;
    gStartupPendingEpochValid = false;
    gLastConnBoot = 0;
    gLastConnWritePending = false;
    gDrainStartPending = false;
    gPendingDrainCursor = 0;
    gPendingDrainLogGeneration = 0;
    memset(gAnchors, 0, sizeof(gAnchors));
    gAnchorNext = 0;
    gAnchorsReady = false;
    gAnchorsLoadPending = true;
    gAnchorsSavePending = false;
    gAnchorReadFailures = 0;
    gAnchorSaveFailures = 0;
    ioUnlock();
}
#endif
