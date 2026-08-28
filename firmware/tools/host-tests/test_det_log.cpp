// Host regression tests for the real offline flash ring implementation.
#include "det_log.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_partition.h>
#include <esp_random.h>
#include <freertos/semphr.h>
#include <mbedtls/aes.h>
#include <mbedtls/md.h>
#include <atomic>
#include <condition_variable>
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

static int failures = 0;
static bool hostBleConnected = false;

static void countCaptureDelivery(void* raw) {
    int* count = static_cast<int*>(raw);
    (*count)++;
    // Ordinary sink callbacks may build BLE status/diagnostic JSON that snapshots det_log. This
    // would deadlock immediately if the delivery guard held gIoMutex through the callback.
    (void)detLogCount();
}

// Link seam for det_log.cpp. The subsystem buffers only while the app is away.
bool acabBleClientConnected() { return hostBleConnected; }

static void check(const char* label, bool ok) {
    std::printf("  %-68s %s\n", label, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
}

static AcabDetection detection(uint32_t n, AcabDeviceType type = ACAB_TRACKER) {
    AcabDetection d;
    const uint8_t mac[6] = {
        0x00, 0x25, 0xDF, (uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n
    };
    acabInit(&d, type, SRC_BLE, mac, (int16_t)(-30 - (n % 50)));
    d.method = M_MFG_ID;
    d.confidence = 90;
    d.lastSeen = 1000 + n;
    d.count = (uint16_t)n;
    std::snprintf(d.name, sizeof(d.name), "d%u", (unsigned)n);
    return d;
}

// The window det_log.cpp encrypts. Derived from the PUBLIC StoredDet rather than copied from the
// file-private ENC_OFF/ENC_LEN, so a layout change moves both together instead of silently
// pointing these tests at the wrong bytes.
static const size_t ENC_OFF = offsetof(StoredDet, whenMs);
static const size_t ENC_LEN = sizeof(StoredDet) - ENC_OFF;

static void keyOfByte(uint8_t key[32], uint8_t first) {
    for (size_t i = 0; i < 32; i++) key[i] = (uint8_t)(first + i);
}

// Is `needle` anywhere in the raw partition image? The seizure posture is about what a lab
// reading the flash can recover, so this searches the WHOLE partition, not one slot.
static bool flashContains(const uint8_t* needle, size_t n) {
    if (acabHostFlash.size() < n) return false;
    for (size_t i = 0; i + n <= acabHostFlash.size(); i++)
        if (std::memcmp(acabHostFlash.data() + i, needle, n) == 0) return true;
    return false;
}

static void fresh(size_t partitionBytes = 8192) {
    Preferences::wipeAll();
    acabHostSemaphoreTakeFailures = 0;
    acabHostMdFailures = 0;
    acabHostRandomZeroCalls = 0;
    acabHostRandomCallsBeforeZero = 0;
    acabHostPartitionReset(partitionBytes);
    detLogHostResetRuntime();
    hostBleConnected = false;
    acabHostSetMillis(1000);
    detLogBegin();
    // A blank Preferences store has no ring-format marker. Production treats that as an
    // old/unknown on-flash format, durably condemns it, and completes the migration from loop().
    // Ordinary fixtures need a ready current-format ring, so finish that one-time sweep here;
    // dedicated migration/power-loss cases below call detLogBegin() directly instead.
    for (int i = 0; i < 32 && detLogWipePending(); i++) detLogEraseTick();
    if (detLogWipePending()) {
        std::printf("  fresh: format migration did not retire\n");
        failures++;
    }
    uint8_t key[32];
    keyOfByte(key, 1);
    detLogSetEnabled(true);
    detLogSetKey(key);
}

static void appendRange(uint32_t first, uint32_t last) {
    for (uint32_t n = first; n <= last; n++) detLogAppend(detection(n));
}

static uint32_t savedUInt(const char* key) {
    Preferences p;
    if (!p.begin("acab-buf", true)) return 0;
    const uint32_t value = p.getUInt(key, 0);
    p.end();
    return value;
}

static bool savedBool(const char* key, bool dflt = false) {
    Preferences p;
    if (!p.begin("acab-buf", true)) return dflt;
    const bool value = p.getBool(key, dflt);
    p.end();
    return value;
}

static bool savedKeyExists(const char* key) {
    Preferences p;
    if (!p.begin("acab-buf", true)) return false;
    const bool exists = p.isKey(key);
    p.end();
    return exists;
}

static std::vector<uint8_t> savedBlob(const char* key) {
    Preferences p;
    if (!p.begin("acab-buf", true)) return {};
    const size_t n = p.getBytesLength(key);
    std::vector<uint8_t> value(n);
    if (n != 0 && p.getBytes(key, value.data(), n) != n) value.clear();
    p.end();
    return value;
}

static void seedUInt(const char* key, uint32_t value) {
    Preferences p;
    if (!p.begin("acab-buf", false) || p.putUInt(key, value) != sizeof(value)) {
        std::printf("  seedUInt: failed to seed %s\n", key);
        failures++;
    }
    p.end();
}

static void seedBlob(const char* key, const void* value, size_t n) {
    Preferences p;
    if (!p.begin("acab-buf", false) || p.putBytes(key, value, n) != n) {
        std::printf("  seedBlob: failed to seed %s\n", key);
        failures++;
    }
    p.end();
}

static void removeSaved(const char* key) {
    Preferences p;
    if (!p.begin("acab-buf", false)) {
        std::printf("  removeSaved: failed to open %s\n", key);
        failures++;
    } else if (p.isKey(key) && !p.remove(key)) {
        std::printf("  removeSaved: failed to remove %s\n", key);
        failures++;
    }
    p.end();
}

static uint16_t testCrcUpdate(uint16_t c, const uint8_t* p, size_t n) {
    for (size_t i = 0; i < n; i++) {
        c ^= (uint16_t)p[i] << 8;
        for (int b = 0; b < 8; b++)
            c = (c & 0x8000) ? (uint16_t)((c << 1) ^ 0x1021) : (uint16_t)(c << 1);
    }
    return c;
}

static uint16_t testRecordCrc(const StoredDet& s) {
    const uint8_t* bytes = (const uint8_t*)&s;
    uint16_t c = testCrcUpdate(0xFFFF, bytes, offsetof(StoredDet, crc));
    const size_t after = offsetof(StoredDet, crc) + sizeof(s.crc);
    return testCrcUpdate(c, bytes + after, sizeof(s) - after);
}

static std::vector<uint32_t> drainAll(uint32_t cursor = 0) {
    std::vector<uint32_t> seqs;
    detLogStartDrain(cursor);
    DetLogReplay replay;
    while (detLogPeekForDrain(&replay)) {
        seqs.push_back(replay.seq);
        if (!detLogCommitDrain(replay.seq, replay.drainGeneration)) {
            std::printf("  drainAll: commit unexpectedly rejected seq %u\n", (unsigned)replay.seq);
            failures++;
            break;
        }
    }
    return seqs;
}

static std::mutex gateMutex;
static std::condition_variable gateCv;
static bool gateWrite = false;
static bool gateEntered = false;
static bool gateRelease = false;
static int hookWriteNumber = 0;
static int failWriteNumber = 0;

static void flashHook(AcabHostFlashOp op, size_t, size_t) {
    if (op != ACAB_HOST_FLASH_WRITE) return;
    hookWriteNumber++;
    if (failWriteNumber && hookWriteNumber == failWriteNumber) acabHostFailWrites = 1;
    std::unique_lock<std::mutex> lock(gateMutex);
    if (!gateWrite) return;
    gateWrite = false;
    gateEntered = true;
    gateCv.notify_all();
    gateCv.wait(lock, [] { return gateRelease; });
}

static void resetHook() {
    std::lock_guard<std::mutex> lock(gateMutex);
    gateWrite = false;
    gateEntered = false;
    gateRelease = false;
    hookWriteNumber = 0;
    failWriteNumber = 0;
    acabHostFlashHook = nullptr;
}

int main() {
    std::printf("\n=== offline detection flash ring regression ===\n");

    // HARNESS SELF-TEST, first, because everything the at-rest section asserts depends on it.
    // The host mbedtls stub used to be an identity copy, which made "no plaintext in flash" a
    // claim no test could have falsified. NIST SP 800-38A F.5.5, first block of
    // CTR-AES256.Encrypt: if this row fails, read every at-rest row below as unproven.
    {
        static const uint8_t katKey[32] = {
            0x60,0x3d,0xeb,0x10,0x15,0xca,0x71,0xbe,0x2b,0x73,0xae,0xf0,0x85,0x7d,0x77,0x81,
            0x1f,0x35,0x2c,0x07,0x3b,0x61,0x08,0xd7,0x2d,0x98,0x10,0xa3,0x09,0x14,0xdf,0xf4};
        static const uint8_t katIn[16] = {
            0x6b,0xc1,0xbe,0xe2,0x2e,0x40,0x9f,0x96,0xe9,0x3d,0x7e,0x11,0x73,0x93,0x17,0x2a};
        static const uint8_t katWant[16] = {
            0x60,0x1e,0xc3,0x13,0x77,0x57,0x89,0xa5,0xb7,0xa7,0xf5,0x04,0xbb,0xf3,0xd2,0x28};
        uint8_t ctr[16] = {
            0xf0,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa,0xfb,0xfc,0xfd,0xfe,0xff};
        uint8_t got[16], strm[16];
        size_t off = 0;
        mbedtls_aes_context ctx;
        mbedtls_aes_init(&ctx);
        const bool kat = mbedtls_aes_setkey_enc(&ctx, katKey, 256) == 0 &&
                         mbedtls_aes_crypt_ctr(&ctx, sizeof(katIn), &off, ctr, strm,
                                               katIn, got) == 0 &&
                         std::memcmp(got, katWant, sizeof(katWant)) == 0;
        mbedtls_aes_free(&ctx);
        check("host AES-256-CTR matches NIST SP 800-38A F.5.5", kat);
    }

    // Two sectors, 128 slots. The 129th append erases all 64 records in sector 0.
    fresh();
    appendRange(1, 128);
    check("two sectors fill to exactly 128 live records", detLogCount() == 128);
    detLogAppend(detection(129));
    check("first wrapped append accounts for all 64 sector evictions", detLogCount() == 65);
    std::vector<uint32_t> seqs = drainAll();
    check("wrapped drain contains exactly the advertised 65 records", seqs.size() == 65);
    check("wrapped drain starts at seq 65 and ends at seq 129",
          !seqs.empty() && seqs.front() == 65 && seqs.back() == 129);
    check("clean wrapped ring reports no storage fault", detLogFaults() == DET_LOG_FAULT_NONE);

    // A reboot must reconstruct the sector-sized floor from flash, not maxSeq-gSlots.
    detLogHostResetRuntime();
    detLogBegin();
    check("boot scan reconstructs the wrapped floor exactly", detLogCount() == 65);
    seqs = drainAll();
    check("post-reboot drain preserves seq 65 through seq 129",
          seqs.size() == 65 && seqs.front() == 65 && seqs.back() == 129);
    appendRange(130, 192);
    check("rewriting the erased sector returns ring to full", detLogCount() == 128);
    detLogAppend(detection(193));
    check("next sector boundary again evicts exactly 64 records", detLogCount() == 65);
    seqs = drainAll();
    check("second wrap exposes only seq 129 through seq 193",
          seqs.size() == 65 && seqs.front() == 129 && seqs.back() == 193);

    // Replay is explicitly two phase: sizing/queueing a frame must not make its flash row
    // irretrievable. Repeated peeks return the same seq, and only an exact commit advances.
    fresh();
    appendRange(1, 2);
    detLogStartDrain(0);
    DetLogReplay replay;
    check("first replay peek exposes seq 1", detLogPeekForDrain(&replay) && replay.seq == 1);
    check("peek alone leaves both records pending", detLogPendingDrain() == 2);
    check("a repeated peek returns the same uncommitted seq",
          detLogPeekForDrain(&replay) && replay.seq == 1);
    check("a mismatched replay commit is rejected",
          !detLogCommitDrain(2, replay.drainGeneration));
    check("rejected commit leaves the cursor parked", detLogPendingDrain() == 2);
    check("the matching replay commit advances exactly once",
          detLogCommitDrain(1, replay.drainGeneration));
    check("one record remains after commit", detLogPendingDrain() == 1);
    check("the next peek advances to seq 2", detLogPeekForDrain(&replay) && replay.seq == 2);
    detLogStopDrain();
    check("a stopped drain rejects a formerly peeked seq",
          !detLogCommitDrain(2, replay.drainGeneration));

    // Exact ABA regression: stopping and restarting from the same app cursor can put a NEW drain
    // on the same seq. The old accepted-notify callback must not advance that replacement drain.
    fresh();
    appendRange(1, 2);
    detLogStartDrain(0);
    DetLogReplay staleReplay;
    check("ABA setup peeks seq 1 from the first drain",
          detLogPeekForDrain(&staleReplay) && staleReplay.seq == 1);
    detLogStopDrain();
    detLogStartDrain(0);
    DetLogReplay replacementReplay;
    check("restart can legitimately return the same seq under a fresh generation",
          detLogPeekForDrain(&replacementReplay) && replacementReplay.seq == staleReplay.seq &&
          replacementReplay.drainGeneration != staleReplay.drainGeneration);
    check("stale same-seq commit cannot advance the replacement drain",
          !detLogCommitDrain(staleReplay.seq, staleReplay.drainGeneration) &&
          detLogPendingDrain() == 2);
    check("replacement generation can commit its own peek",
          detLogCommitDrain(replacementReplay.seq, replacementReplay.drainGeneration) &&
          detLogPendingDrain() == 1);

    // An erase failure must not advance either cursor or attempt a write.
    fresh();
    appendRange(1, 128);
    const uint32_t writesBeforeEraseFailure = acabHostWriteCalls;
    acabHostFailErases = 1;
    detLogAppend(detection(129));
    check("failed wrap erase leaves all previously live records counted", detLogCount() == 128);
    check("failed wrap erase never writes into the unerased sector",
          acabHostWriteCalls == writesBeforeEraseFailure);
    check("failed wrap erase latches the erase fault",
          (detLogFaults() & DET_LOG_FAULT_ERASE) != 0);
    detLogAppend(detection(130));
    check("latched erase fault blocks later appends", acabHostWriteCalls == writesBeforeEraseFailure);

    // A payload write failure does not publish a phantom row and persists across reboot.
    fresh();
    acabHostFailWrites = 1;
    detLogAppend(detection(1));
    check("failed payload write leaves count at zero", detLogCount() == 0);
    check("failed payload write latches the write fault",
          (detLogFaults() & DET_LOG_FAULT_WRITE) != 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("write fault survives reboot", (detLogFaults() & DET_LOG_FAULT_WRITE) != 0);
    const uint32_t writesAfterReboot = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("persisted write fault blocks appends after reboot", acabHostWriteCalls == writesAfterReboot);

    // Fault reporting is itself durable metadata. Losing the first fault-mask write may never
    // make a raw geometry failure disappear after reboot; the maintenance tick retries the exact
    // combined mask, and a successful physical wipe atomically cancels the pending old value.
    fresh();
    Preferences::failNextPutUInt("acab-buf", "fault");
    acabHostFailWrites = 1;
    check("raw failure with rejected fault put blocks immediately",
          detLogAppend(detection(1)) == DET_LOG_APPEND_NOT_ARMED &&
          (detLogFaults() & DET_LOG_FAULT_WRITE) &&
          (detLogFaults() & DET_LOG_FAULT_NVS) && savedUInt("fault") == 0);
    detLogEraseTick();
    check("maintenance retry durably stores raw and diagnostic fault bits",
          (savedUInt("fault") & (DET_LOG_FAULT_WRITE | DET_LOG_FAULT_NVS)) ==
              (DET_LOG_FAULT_WRITE | DET_LOG_FAULT_NVS));
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot restores the blocking raw fault after failed first persistence",
          (detLogFaults() & DET_LOG_FAULT_WRITE) &&
          detLogAppend(detection(2)) == DET_LOG_APPEND_NOT_ARMED);
    detLogClear();
    detLogEraseTick();
    check("physical wipe clears durable fault and cancels stale retry intent",
          detLogFaults() == DET_LOG_FAULT_NONE && savedUInt("fault") == 0);
    detLogEraseTick();
    check("later maintenance cannot resurrect a pre-wipe fault mask",
          detLogFaults() == DET_LOG_FAULT_NONE && savedUInt("fault") == 0);

    fresh();
    Preferences::failNextBegin();
    acabHostFailWrites = 1;
    detLogAppend(detection(1));
    check("fault-mask NVS-open failure preserves raw fault in RAM",
          (detLogFaults() & DET_LOG_FAULT_WRITE) && (detLogFaults() & DET_LOG_FAULT_NVS));
    detLogEraseTick();
    check("fault-mask open failure is retryable without another raw operation",
          (savedUInt("fault") & DET_LOG_FAULT_WRITE) != 0);

    // A header failure is distinct from the first write and must also leave head uncommitted.
    fresh();
    resetHook();
    failWriteNumber = 2;
    acabHostFlashHook = flashHook;
    detLogAppend(detection(1));
    acabHostFlashHook = nullptr;
    check("failed header write leaves count at zero", detLogCount() == 0);
    check("failed header write latches the write fault",
          (detLogFaults() & DET_LOG_FAULT_WRITE) != 0);

    // If the sector erase succeeded before a wrapped header write failed, the 64
    // evicted records are gone and the count must reflect that even with no new row.
    fresh();
    appendRange(1, 128);
    resetHook();
    failWriteNumber = 2;
    acabHostFlashHook = flashHook;
    detLogAppend(detection(129));
    acabHostFlashHook = nullptr;
    check("wrapped header failure accounts for the successful sector erase", detLogCount() == 64);
    check("wrapped header failure still publishes no seq 129 row",
          (detLogFaults() & DET_LOG_FAULT_WRITE) != 0);

    // A transient read failure stops rather than skipping a sequence, and retry starts there.
    fresh();
    appendRange(1, 2);
    detLogStartDrain(0);
    check("two valid records are advertised before drain", detLogPendingDrain() == 2);
    acabHostFailReads = 1;
    check("read failure aborts the drain", !detLogPeekForDrain(&replay) && !detLogDraining());
    check("read failure is visible in the fault API", (detLogFaults() & DET_LOG_FAULT_READ) != 0);
    detLogStartDrain(0);
    check("retry does not skip the failed seq", detLogPeekForDrain(&replay) && replay.seq == 1);
    const uint32_t writesBeforeReadFaultAppend = acabHostWriteCalls;
    detLogAppend(detection(3));
    check("read fault blocks appends while storage state is uncertain",
          acabHostWriteCalls == writesBeforeReadFaultAppend);

    // Corrupt data is not skipped inside a supposedly exact window. The drain aborts,
    // latches the fault, and trims the logical floor to the newer contiguous suffix.
    fresh();
    detLogAppend(detection(1));
    acabHostPartitionCorrupt(12, 0x00);               // first payload byte, CRC no longer matches
    detLogStartDrain(0);
    check("corrupt record aborts instead of being silently skipped", !detLogPeekForDrain(&replay));
    check("corrupt record latches the corruption fault",
          (detLogFaults() & DET_LOG_FAULT_CORRUPT) != 0);
    check("corrupt record is removed from exact logical occupancy", detLogCount() == 0);
    const uint32_t writesBeforeCorruptAppend = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("corruption fault blocks new appends until a clear",
          acabHostWriteCalls == writesBeforeCorruptAppend);

    // Failed wipe ticks remain latched and do not hammer flash. An explicit retry that
    // completes is the only operation that clears the persistent fault status.
    fresh();
    detLogAppend(detection(1));
    detLogClear();
    acabHostFailErases = 1;
    const uint32_t erasesBeforeTick = acabHostEraseCalls;
    detLogEraseTick();
    check("failed wipe stays pending", detLogWipePending());
    check("failed wipe reports erase fault", (detLogFaults() & DET_LOG_FAULT_ERASE) != 0);
    const uint32_t erasesAfterFailure = acabHostEraseCalls;
    detLogEraseTick();
    check("stalled wipe is not retried every loop pass",
          acabHostEraseCalls == erasesAfterFailure && erasesAfterFailure == erasesBeforeTick + 1);
    detLogClear();
    detLogEraseTick();
    check("successful explicit wipe retry finishes", !detLogWipePending());
    check("successful full wipe clears fault status", detLogFaults() == DET_LOG_FAULT_NONE);
    check("successful full wipe leaves no programmed flash", acabHostPartitionAllErased());

    // The wipe bool is a transaction, not a hint. Until `wipe=true` and the new boot generation
    // are durable, clear keeps the old cursors, blocks all new I/O, and retries from the loop.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNthBegin(2);   // cdwipe open succeeds; the following ring-arm open fails
    detLogClear();
    check("failed ring-arm begin does not publish a phantom logical clear",
          detLogCount() == 1 && detLogWipePending() && !savedBool("wipe"));
    const uint32_t writesWhileArmPending = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("an uncommitted clear blocks appends while preserving the old generation",
          detLogCount() == 1 && acabHostWriteCalls == writesWhileArmPending);
    detLogEraseTick();
    check("loop retry commits, erases, and durably retires the failed arm",
          detLogCount() == 0 && !detLogWipePending() && !savedBool("wipe") &&
          acabHostPartitionAllErased());

    // RNG is part of the wipe transaction: failure cannot permit an erase/replay-generation reset
    // under old identity. Persist wipeneed+wipe as a targetless condemnation, retry generation
    // selection later, and never physically touch the ring in a tick whose pre-arm still failed.
    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeRngClear = detLogGeneration();
    acabHostRandomZeroCalls = 8;                    // exhaust freshLogGenerationLocked attempts
    detLogClear();
    check("RNG-failed clear durably condemns rows without publishing old generation as empty",
          detLogCount() == 1 && detLogWipePending() && savedBool("wipe") &&
          savedBool("wipeneed") && detLogGeneration() == generationBeforeRngClear);
    detLogHostResetRuntime();
    detLogBegin();                                  // healthy RNG resolves the durable tombstone
    check("reboot resolves targetless clear to a fresh generation before scan",
          detLogWipePending() && detLogCount() == 0 &&
          detLogGeneration() != generationBeforeRngClear && !savedBool("wipeneed"));
    detLogEraseTick();

    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutBool("acab-buf", "wipeneed", 2);
    acabHostRandomZeroCalls = 16;                   // clear attempt plus same-tick retry both fail
    const uint32_t erasesBeforeUnarmedRngRetry = acabHostEraseCalls;
    detLogClear();
    detLogEraseTick();
    check("failed RNG plus failed tombstone never falls through to physical erase",
          detLogWipePending() && detLogCount() == 1 &&
          acabHostEraseCalls == erasesBeforeUnarmedRngRetry);

    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeDomainFailure = detLogGeneration();
    acabHostRandomCallsBeforeZero = 1;              // fresh loggen succeeds
    acabHostRandomZeroCalls = 32;                   // all eight 128-bit domain candidates are zero
    detLogClear();
    check("crypto-domain RNG failure also leaves a durable targetless condemnation",
          detLogCount() == 1 && detLogWipePending() && savedBool("wipe") &&
          savedBool("wipeneed") && detLogGeneration() == generationBeforeDomainFailure);
    detLogHostResetRuntime();
    detLogBegin();
    check("domain-failure reboot mints fresh replay and nonce identities before erase",
          detLogWipePending() && detLogCount() == 0 &&
          detLogGeneration() != generationBeforeDomainFailure);
    detLogEraseTick();

    // wipegen is the first commit point. Even if wipe=true itself is refused, a power loss must
    // treat that durable target as condemnation and never rescan the old generation.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutBool("acab-buf", "wipe");
    detLogClear();
    check("failed wipe=true write leaves the old runtime generation blocked",
          detLogCount() == 1 && detLogWipePending() && !savedBool("wipe") &&
          savedUInt("wipegen") != 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after generation intent never resurrects the old log",
          detLogCount() == 0 && detLogWipePending());
    detLogEraseTick();

    // Once wipe=true lands, later fields may fail without reopening the resurrection window.
    // A reboot sees the durable latch and must skip every raw slot even though RAM never published
    // the empty generation before power failed.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutUInt("acab-buf", "boot");
    detLogClear();
    check("wipe=true is already durable when the boot-generation write fails",
          detLogCount() == 1 && detLogWipePending() && savedBool("wipe"));
    const uint32_t readsBeforePartialArmReboot = acabHostReadCalls;
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot after a partial arm never scans or resurrects condemned slots",
          detLogCount() == 0 && detLogWipePending() &&
          acabHostReadCalls == readsBeforePartialArmReboot);
    detLogEraseTick();
    check("the rebooted partial arm completes and retires", !detLogWipePending());

    // An NVS-open failure while loading the boot latch is UNKNOWN. It may not default false and
    // scan. The loop retries: a true latch erases, while a positively false one then performs the
    // deferred scan and preserves an ordinary uncondemned log.
    fresh();
    detLogAppend(detection(1));
    detLogClear();
    const uint32_t readsBeforeFailedWipeLoad = acabHostReadCalls;
    detLogHostResetRuntime();
    Preferences::failNthBegin(3);   // sensitive-token, ring-format, then ring-wipe load
    detLogBegin();
    check("failed boot wipe read exposes no condemned record and performs no raw scan",
          detLogCount() == 0 && detLogWipePending() &&
          acabHostReadCalls == readsBeforeFailedWipeLoad);
    detLogEraseTick();
    check("retrying a durable true latch erases instead of scanning",
          !detLogWipePending() && acabHostPartitionAllErased());

    fresh();
    detLogAppend(detection(1));
    const uint32_t readsBeforeOrdinaryLoadFailure = acabHostReadCalls;
    detLogHostResetRuntime();
    Preferences::failNthBegin(3);
    detLogBegin();
    check("unknown boot latch also blocks an ordinary log without erasing it",
          detLogCount() == 0 && detLogWipePending() &&
          acabHostReadCalls == readsBeforeOrdinaryLoadFailure);
    detLogEraseTick();
    check("a later positive false result performs the deferred scan and keeps the row",
          detLogCount() == 1 && !detLogWipePending() && !acabHostPartitionAllErased());

    // Retirement is the other commit boundary. Physical erase alone is not enough: while NVS
    // still says wipe=true, appends must remain blocked or the next reboot will erase the new rows.
    fresh();
    detLogAppend(detection(1));
    detLogClear();
    Preferences::failNextPutBool("acab-buf", "wipe");
    detLogEraseTick();
    check("failed wipe=false retirement keeps the empty ring latched and blocked",
          acabHostPartitionAllErased() && detLogWipePending() && savedBool("wipe"));
    const uint32_t writesBeforeRetire = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("no new row is admitted before durable retirement",
          detLogCount() == 0 && acabHostWriteCalls == writesBeforeRetire);
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after erase but before retirement still skips the boot scan",
          detLogCount() == 0 && detLogWipePending());
    detLogEraseTick();
    detLogAppend(detection(2));
    check("append resumes only after wipe=false commits", detLogCount() == 1);
    detLogHostResetRuntime();
    detLogBegin();
    check("a later reboot keeps the post-retirement row instead of re-erasing it",
          detLogCount() == 1 && !detLogWipePending());

    fresh();
    detLogAppend(detection(1));
    detLogClear();
    Preferences::failNextBegin();   // final-retirement transaction, after the flash erase
    const uint32_t erasesBeforeRetireBeginFailure = acabHostEraseCalls;
    detLogEraseTick();
    check("failed retirement begin keeps the latch without repeating the physical erase",
          detLogWipePending() && savedBool("wipe") &&
          acabHostEraseCalls == erasesBeforeRetireBeginFailure + 1);
    detLogEraseTick();
    check("a later retirement retry succeeds without a second erase",
          !detLogWipePending() && acabHostEraseCalls == erasesBeforeRetireBeginFailure + 1);

    // Startup config and the boot counter are a single readiness boundary. A failed open or
    // boot-generation commit may scan for geometry, but it cannot decrypt, drain, append, or make
    // an auto-wipe decision until the retained key/config are loaded and the nonce generation is
    // durable.
    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);   // cdwipe, format, wipe, anchors, then startup config
    detLogBegin();
    const uint32_t writesBeforeConfigRetry = acabHostWriteCalls;
    detLogStartDrain(0);
    const DetLogAppendResult startupRejectedAppend = detLogAppend(detection(2));
    check("failed startup-config open blocks replay and append",
          startupRejectedAppend == DET_LOG_APPEND_RETRY &&
          !detLogDraining() && detLogCount() == 1 &&
          acabHostWriteCalls == writesBeforeConfigRetry);
    detLogEraseTick();
    check("loop retry durably advances the boot generation", savedUInt("boot") == 2);
    const DetLogAppendResult startupRetriedAppend = detLogAppend(detection(2));
    check("append resumes with the recovered retained key",
          startupRetriedAppend == DET_LOG_APPEND_STORED && detLogCount() == 2);

    fresh();
    hostBleConnected = true;
    check("connected-state append refusal is stable and keeps scanner claim consumed",
          detLogAppend(detection(1)) == DET_LOG_APPEND_NOT_ARMED);
    hostBleConnected = false;
    detLogSetEnabled(false);
    check("disabled-state append refusal is non-retryable within this capture generation",
          detLogAppend(detection(1)) == DET_LOG_APPEND_NOT_ARMED);

    // Stationary mode periodically advances only the scanner's dedup capture generation. It does
    // not represent an owner/link handoff, so a legitimate already-queued row keeps the same
    // det_log admission epoch and remains appendable.
    fresh();
    check("periodic dedup rearm does not invalidate a queued owner-era row",
          detLogAppendClaimed(detection(1), nullptr, 1) == DET_LOG_APPEND_STORED &&
          detLogCount() == 1);

    // Successful authentication has a pre-ready window: GPS is cleared and a durable privacy
    // token may touch NVS before gConnected can become true. Reserve + block at that boundary and
    // publish no scanner token until the explicit admit step succeeds.
    fresh();
    int delivered = 0;
    check("current away-session delivery runs under the owner guard",
          detLogDeliverIfCaptureEpochCurrent(1, countCaptureDelivery, &delivered) && delivered == 1);
    const uint32_t authBlockedEpoch = detLogBlockCaptureForOwnerSession();
    check("authenticated owner boundary advances before config preparation",
          authBlockedEpoch != 0 && authBlockedEpoch != 1);
    check("pre-auth queued claim is rejected during owner preparation",
          detLogAppendClaimed(detection(1), nullptr, 1) == DET_LOG_APPEND_NOT_ARMED &&
          detLogCount() == 0);
    check("old and zero-stamped delivery cannot cross authentication preparation",
          !detLogDeliverIfCaptureEpochCurrent(1, countCaptureDelivery, &delivered) &&
          !detLogDeliverIfCaptureEpochCurrent(0, countCaptureDelivery, &delivered) &&
          delivered == 1);
    check("reserved owner token also stays blocked until explicit admission",
          detLogAppendClaimed(detection(2), nullptr, authBlockedEpoch) ==
              DET_LOG_APPEND_NOT_ARMED &&
          detLogAppend(detection(3)) == DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);
    hostBleConnected = true;
    check("successful preparation admits only the reserved current-owner delivery token",
          detLogAdmitCaptureForOwnerSession(authBlockedEpoch) &&
          detLogDeliverIfCaptureEpochCurrent(authBlockedEpoch,
                                             countCaptureDelivery, &delivered) &&
          delivered == 2 &&
          !detLogDeliverIfCaptureEpochCurrent(1, countCaptureDelivery, &delivered));
    // Disconnect uses the same boundary in two phases. Block while the owner is still publicly
    // connected, keep the service gate raised through GPS/replay/key teardown, and admit only at
    // the final away publication. This models the exact gap in which a radio item used to claim
    // the new scanner generation while append still observed connected=true.
    const uint32_t awayEpoch = detLogBlockCaptureForOwnerSession();
    check("disconnect block rejects old queued delivery and claims throughout teardown",
          awayEpoch != 0 && awayEpoch != authBlockedEpoch &&
          !detLogDeliverIfCaptureEpochCurrent(authBlockedEpoch,
                                              countCaptureDelivery, &delivered) &&
          detLogAppendClaimed(detection(4), nullptr, authBlockedEpoch) ==
              DET_LOG_APPEND_NOT_ARMED &&
          detLogAppendClaimed(detection(5), nullptr, awayEpoch) ==
              DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);
    check("disconnect completion admits only its reserved away epoch",
          detLogAdmitCaptureForOwnerSession(awayEpoch));
    check("service owner gate still blocks the admitted epoch until teardown publication",
          detLogAppendClaimed(detection(6), nullptr, awayEpoch) ==
              DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);
    hostBleConnected = false;
    check("disconnect releases capture only under a fresh away-session epoch",
          detLogAppendClaimed(detection(7), nullptr, awayEpoch) == DET_LOG_APPEND_STORED &&
          detLogCount() == 1);
    check("prior-owner live delivery is rejected after disconnect while away delivery remains",
          !detLogDeliverIfCaptureEpochCurrent(authBlockedEpoch,
                                              countCaptureDelivery, &delivered) &&
          detLogDeliverIfCaptureEpochCurrent(awayEpoch, countCaptureDelivery, &delivered) &&
          delivered == 3);

    // A SinkItem snapshots the prior owner's retained GPS before it enters the asynchronous queue.
    // Phone B can authenticate, rotate/clear the key generation, then disconnect while that item is
    // backlogged. Disconnect blocks det_log before connected=false and admits the reserved away
    // epoch only after teardown; the old claim must be rejected inside the same locked admission
    // check, while a B-era claim remains admissible.
    fresh();
    const uint32_t ownerAQueueEpoch = 1;
    DetLogGpsStamp ownerAQueuedGps{ 377749000, -1224194000, 1, true };
    hostBleConnected = true;
    uint8_t ownerBKey[32];
    keyOfByte(ownerBKey, 100);
    detLogSetKey(ownerBKey, true);  // test setup explicitly transfers the generation to owner B
    detLogClear();
    detLogEraseTick();
    const uint32_t ownerBQueueEpoch = detLogAdvanceCaptureEpoch();
    hostBleConnected = false;
    check("prior-owner queued GPS is rejected after the disconnect admission epoch",
          detLogAppendClaimed(detection(1), &ownerAQueuedGps, ownerAQueueEpoch) ==
              DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);
    check("new-owner capture resumes only under the current admission epoch",
          detLogAppendClaimed(detection(2), nullptr, ownerBQueueEpoch) ==
              DET_LOG_APPEND_STORED && detLogCount() == 1);
    detLogStartDrain(0);
    DetLogReplay ownerBoundaryReplay;
    check("replayed new-owner row inherited none of the stale queued GPS",
          detLogPeekForDrain(&ownerBoundaryReplay) &&
          ownerBoundaryReplay.d.lat == 0 && ownerBoundaryReplay.d.lon == 0);

    fresh();
    acabHostSemaphoreTakeFailures = 1;
    const uint32_t failedAdmissionEpoch = detLogAdvanceCaptureEpoch();
    check("capture-epoch lock failure returns no publishable scanner generation",
          failedAdmissionEpoch == 0);
    check("capture-epoch lock failure blocks an old queued claim fail closed",
          detLogAppendClaimed(detection(1), nullptr, 1) == DET_LOG_APPEND_NOT_ARMED &&
          detLogCount() == 0);
    const uint32_t recoveredAdmissionEpoch = detLogAdvanceCaptureEpoch();
    check("successful epoch retry clears the latch and re-arms only the new generation",
          recoveredAdmissionEpoch != 0 &&
          detLogAppendClaimed(detection(2), nullptr, recoveredAdmissionEpoch) ==
              DET_LOG_APPEND_STORED && detLogCount() == 1);

    fresh();
    detLogClearKey();
    check("ready-but-keyless append and sync are explicitly rejected",
          detLogAppend(detection(1)) == DET_LOG_APPEND_NOT_ARMED &&
          detLogStartDrain(0, detLogGeneration()) == DET_LOG_DRAIN_REJECTED);

    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    Preferences::failNextPutUInt("acab-buf", "boot");
    detLogBegin();
    const uint32_t writesBeforeBootCommitRetry = acabHostWriteCalls;
    detLogStartDrain(0);
    detLogAppend(detection(2));
    check("failed boot-counter commit admits no nonce-using operation",
          !detLogDraining() && detLogCount() == 1 && savedUInt("boot") == 1 &&
          acabHostWriteCalls == writesBeforeBootCommitRetry);
    detLogEraseTick();
    detLogAppend(detection(2));
    DetLogReplay bootReplay;
    detLogStartDrain(0);
    const bool firstBootRow = detLogPeekForDrain(&bootReplay) && bootReplay.seq == 1 &&
                              bootReplay.bootCount == 1 &&
                              detLogCommitDrain(bootReplay.seq, bootReplay.drainGeneration);
    const bool secondBootRow = detLogPeekForDrain(&bootReplay) && bootReplay.seq == 2 &&
                               bootReplay.bootCount == 2;
    check("retry preserves distinct persisted boot nonces across the reboot",
          firstBootRow && secondBootRow && savedUInt("boot") == 2);

    // The BLE handshake can arrive while startup NVS/boot metadata is retrying. A retained RAM key
    // must not make that offered key look accepted before the durable fingerprint and raw geometry
    // are authoritative. The service therefore denies this sync and the app retries its key; the
    // record layer independently stays pending/hidden until startup finishes.
    fresh();
    detLogAppend(detection(1));
    uint8_t startupSameKey[32], startupOtherKey[32];
    keyOfByte(startupSameKey, 1);
    keyOfByte(startupOtherKey, 100);
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    const DetLogKeyResult startupSameResult = detLogSetKey(startupSameKey);
    detLogStartDrain(0);
    check("startup-pending key is not accepted from reset-value metadata",
          startupSameResult == DET_LOG_KEY_PENDING && !detLogDraining() &&
          detLogPendingDrain() == 0);
    detLogEraseTick();
    DetLogReplay startupHandshakeReplay;
    check("startup recovery keeps the retained row available for an authenticated retry",
          detLogPeekForDrain(&startupHandshakeReplay) && startupHandshakeReplay.seq == 1);

    // A genuinely different key in that window is not staged for a later surprise wipe. Startup
    // recovers A unchanged; only an explicit clear followed by an authorized B offer may replace it.
    fresh();
    detLogAppend(detection(1));
    const std::vector<uint8_t> startupOldKeyBlob = savedBlob("key");
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    const DetLogKeyResult startupOtherResult = detLogSetKey(startupOtherKey);
    check("startup-pending rotation is rejected without mutating retained identity",
          startupOtherResult == DET_LOG_KEY_PENDING && detLogCount() == 1 &&
          savedBlob("key") == startupOldKeyBlob);
    detLogEraseTick();
    check("startup retry cannot auto-wipe from an unconfirmed offered key",
          detLogCount() == 1 && savedBlob("key") == startupOldKeyBlob &&
          !detLogWipePending());

    // Fresh-board setup is the complementary case: key + enable + Stationary-capture writes all
    // arrive while startup is pending and must commit in dependency order rather than having the
    // retained on=false cleanup silently erase bufall.
    Preferences::wipeAll();
    acabHostPartitionReset(8192);
    detLogHostResetRuntime();
    hostBleConnected = false;
    acabHostSetMillis(1000);
    Preferences::failNthBegin(5);
    detLogBegin();
    const DetLogKeyResult freshStartupKeyResult = detLogSetKey(startupSameKey);
    detLogSetEnabled(true);
    detLogSetBufferAll(true);
    check("fresh startup leaves an unconfirmed key unstaged while config waits",
          freshStartupKeyResult == DET_LOG_KEY_PENDING && !savedBool("on") &&
          !savedKeyExists("key") && !savedBool("bufall"));
    detLogEraseTick();
    check("startup can publish requested settings without fabricating key acceptance",
          detLogEnabled() && !detLogHaveKey() && detLogBufferAll() && savedBool("on") &&
          savedBool("bufall") && !savedKeyExists("key"));
    check("fresh-board key retry is accepted after metadata publication",
          detLogSetKey(startupSameKey) == DET_LOG_KEY_ACCEPTED);
    detLogAppend(detection(1));
    check("confirmed key retry completes Stationary capture before append",
          detLogEnabled() && detLogHaveKey() && detLogBufferAll() && savedBool("on") &&
          savedBool("bufall") && savedKeyExists("key") && detLogCount() == 1);
    detLogHostResetRuntime();
    detLogBegin();
    check("confirmed fresh-board Stationary capture survives reboot",
          detLogEnabled() && detLogHaveKey() && detLogBufferAll() && detLogCount() == 1);

    // clearlog must not derive a new encryption generation from reset-value gBoot=0. Defer the
    // ring arm until startup reads and increments the retained high counter.
    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    seedUInt("boot", 41);
    Preferences::failNthBegin(5);
    detLogBegin();
    detLogClear();
    check("clear during startup failure does not regress the durable boot counter",
          savedUInt("boot") == 41 && detLogCount() == 1 && detLogWipePending());
    detLogEraseTick();
    check("deferred clear uses a generation newer than the retained counter",
          savedUInt("boot") > 41 && detLogCount() == 0 && !detLogWipePending() &&
          acabHostPartitionAllErased());

    // A failed clear-key begin is also a newer runtime intent than the retained config read. The
    // restore may not republish the old blob and clear its retry flag.
    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    Preferences::failNextBegin();
    detLogClearKey();
    check("startup-pending clear-key remains keyless after its first NVS failure",
          !detLogHaveKey() && savedKeyExists("key"));
    detLogEraseTick();
    check("startup restore preserves and completes the explicit clear-key retry",
          !detLogHaveKey() && !savedKeyExists("key"));

    // Epoch belongs to the durable boot selected by startup, not boot 0. Preserve its original
    // receipt uptime across the retry so the first row after recovery remains exact.
    fresh();
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    acabHostSetMillis(5000);
    detLogSetEpoch(1700000000u);
    detLogEraseTick();
    AcabDetection epochRow = detection(1);
    epochRow.lastSeen = 5000;
    detLogAppend(epochRow);
    detLogStartDrain(0);
    DetLogReplay epochReplay;
    check("startup-pending epoch anchors the recovered durable boot exactly",
          detLogPeekForDrain(&epochReplay) && !epochReplay.approx &&
          epochReplay.atUnix == 1700000000u && epochReplay.bootCount == savedUInt("boot"));

    // Even a fully loaded config may legitimately have no retained key (buffering was disabled,
    // or key removal completed). A sync must not expose ciphertext or advance its cursor while
    // cryptPayload would be a no-op; pushing the key later replays the untouched first row.
    fresh();
    detLogAppend(detection(1));
    detLogClearKey();
    detLogStartDrain(0);
    DetLogReplay keylessReplay;
    check("keyless sync exposes no replay and advances nothing",
          !detLogDraining() && !detLogPeekForDrain(&keylessReplay) && detLogCount() == 1);
    uint8_t restoredKey[32];
    keyOfByte(restoredKey, 1);
    detLogSetKey(restoredKey);
    detLogStartDrain(0);
    check("restoring the key replays the untouched first sequence",
          detLogPeekForDrain(&keylessReplay) && keylessReplay.seq == 1);

    // A sync also resets the undrained-reboot timer. That write is part of accepting the sync,
    // not advisory bookkeeping: if it silently fails one boot before the threshold, a fully sent
    // row is condemned on the next reboot. Keep the drain unarmed until lastconn is durable, then
    // prove the following boot retains the row instead of auto-wiping it.
    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    seedUInt("boot", 5);
    seedUInt("lastconn", 1);
    detLogBegin();                       // boot 6: still one short of the six-boot wipe threshold
    check("lastconn regression begins one boot short without erasing the row",
          detLogCount() == 1 && !detLogWipePending());
    Preferences::failNextPutUInt("acab-buf", "lastconn");
    detLogStartDrain(0);
    check("failed lastconn write exposes no replay as successfully accepted",
          !detLogDraining() && detLogPendingDrain() == 0 && savedUInt("lastconn") == 1);
    detLogEraseTick();
    DetLogReplay durableDrain;
    const bool durableDrainAccepted = detLogPeekForDrain(&durableDrain) &&
                                      durableDrain.seq == 1 &&
                                      detLogCommitDrain(durableDrain.seq,
                                                        durableDrain.drainGeneration);
    check("loop retry arms replay only after the current boot marker commits",
          durableDrainAccepted && savedUInt("lastconn") == 6);
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot after the accepted replay cannot auto-wipe from the stale marker",
          detLogCount() == 1 && !detLogWipePending());

    // A deferred start belongs to the connection that requested it. Disconnect/stop must cancel
    // both the cursor and the lastconn retry; a later loop pass may not resurrect a drain whose
    // history-begin envelope was never sent.
    fresh();
    detLogAppend(detection(1));
    const uint32_t lastConnBeforeCancelledSync = savedUInt("lastconn");
    Preferences::failNextPutUInt("acab-buf", "lastconn");
    detLogStartDrain(0);
    detLogStopDrain();
    detLogEraseTick();
    check("stopping a failed sync cancels its deferred marker and drain arm",
          !detLogDraining() && savedUInt("lastconn") == lastConnBeforeCancelledSync);

    // Orchestrate the old resurrection race: clear starts while append is paused inside
    // its first flash write. The shared I/O mutex forces clear to wait for the complete
    // append, then condemn that record from offset zero.
    fresh();
    resetHook();
    {
        std::lock_guard<std::mutex> lock(gateMutex);
        gateWrite = true;
    }
    acabHostFlashHook = flashHook;
    std::thread appendThread([] { detLogAppend(detection(1)); });
    {
        std::unique_lock<std::mutex> lock(gateMutex);
        gateCv.wait(lock, [] { return gateEntered; });
    }
    std::atomic<bool> clearStarted(false);
    std::atomic<bool> clearDone(false);
    std::thread clearThread([&] {
        clearStarted.store(true);
        detLogClear();
        clearDone.store(true);
    });
    while (!clearStarted.load()) std::this_thread::yield();
    for (int i = 0; i < 100; i++) std::this_thread::yield();
    check("clear cannot finish while append owns the flash transaction", !clearDone.load());
    {
        std::lock_guard<std::mutex> lock(gateMutex);
        gateRelease = true;
    }
    gateCv.notify_all();
    appendThread.join();
    clearThread.join();
    acabHostFlashHook = nullptr;
    check("clear after in-flight append reports zero records", detLogCount() == 0);
    check("clear after in-flight append starts a physical wipe", detLogWipePending());
    detLogEraseTick();
    check("completed race wipe erases the appended record", acabHostPartitionAllErased());
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot after raced clear cannot resurrect the record", detLogCount() == 0);

    // ---- encrypt at rest -------------------------------------------------------------------
    // det_log.h's seizure posture is that a pulled flash yields ciphertext, and cryptPayload() is
    // the only thing making that true. NONE of the ring tests above can see it: the slot CRC is
    // computed over the ciphertext, so an identity cipher satisfies every one of them. These read
    // the raw partition instead, which is the only place the guarantee is observable.
    fresh();
    detLogAppend(detection(1));
    const uint8_t plainMac[6] = { 0x00, 0x25, 0xDF, 0x00, 0x00, 0x01 };
    check("a buffered record's MAC appears nowhere in the raw partition",
          !flashContains(plainMac, sizeof(plainMac)));
    check("the trailing name field is not stored in the clear",
          std::memcmp(acabHostFlash.data() + offsetof(StoredDet, name), "d1", 2) != 0);
    uint32_t rawWhenMs = 0;
    std::memcpy(&rawWhenMs, acabHostFlash.data() + ENC_OFF, sizeof(rawWhenMs));
    check("the leading whenMs field is not stored in the clear", rawWhenMs != 1001);
    // The other half of the contract, so nobody "fixes" the above by encrypting the whole slot:
    // seq stays cleartext or the boot scan cannot find the head without the key.
    uint32_t rawSeq = 0;
    std::memcpy(&rawSeq, acabHostFlash.data() + offsetof(StoredDet, seq), sizeof(rawSeq));
    check("seq stays CLEARTEXT so the boot scan still works with no key", rawSeq == 1);

    // Nonce is bootCount:seq, so two records with a BYTE-IDENTICAL payload must still come out
    // different. Reusing a nonce XORs two plaintexts under one keystream - the hazard clearLocked()
    // bumps gBoot to avoid - and nothing exercised it.
    fresh();
    detLogAppend(detection(7));
    detLogAppend(detection(7));
    check("identical payloads at different seqs never share a keystream",
          std::memcmp(acabHostFlash.data() + ENC_OFF,
                      acabHostFlash.data() + sizeof(StoredDet) + ENC_OFF, ENC_LEN) != 0);

    // ---- at-rest key lifecycle -------------------------------------------------------------
    // A record written under a dead key still passes ciphertext CRC and decrypts to noise. But a
    // second bonded phone's ordinary key handshake is not consent to destroy that history: preserve
    // A's key/rows and report MISMATCH. Explicit clear/ownership transfer authorizes the existing
    // fail-closed rotation transaction exercised throughout the crash-boundary cases below.
    uint8_t sameKey[32], otherKey[32];
    keyOfByte(sameKey, 1);            // exactly what fresh() installs
    keyOfByte(otherKey, 100);

    fresh();
    appendRange(1, 3);
    const std::vector<uint8_t> mismatchRetainedKey = savedBlob("key");
    const DetLogKeyResult mismatchResult = detLogSetKey(otherKey);
    check("a different session key reports mismatch without erasing history",
          mismatchResult == DET_LOG_KEY_MISMATCH && detLogCount() == 3 &&
          !detLogWipePending() && savedBlob("key") == mismatchRetainedKey);
    const DetLogKeyResult explicitTransferResult = detLogSetKey(otherKey, true);
    check("explicit ownership transfer accepts B only behind an empty generation",
          explicitTransferResult == DET_LOG_KEY_ACCEPTED && detLogCount() == 0);
    check("that key-change wipe is physical, not merely logical", detLogWipePending());
    check("a key change requests retained sensitive-stack erasure",
          detLogSensitiveErasePending() != 0);
    detLogEraseTick();
    check("authorized B session sees an empty fresh generation after wipe retirement",
          !detLogWipePending() && detLogCount() == 0 &&
          detLogStartDrain(0, detLogGeneration()) == DET_LOG_DRAIN_EMPTY);

    fresh();
    appendRange(1, 3);
    const DetLogKeyResult sameKeyResult =
        detLogSetKey(sameKey);        // an ordinary reconnect re-pushes the same per-device key
    check("re-pushing the SAME key is accepted and keeps every buffered record",
          sameKeyResult == DET_LOG_KEY_ACCEPTED && detLogCount() == 3);
    check("re-pushing the same key starts no wipe", !detLogWipePending());

    // Disable drops the key from RAM and from NVS while keeping the records themselves.
    fresh();
    appendRange(1, 3);
    detLogSetEnabled(false);
    check("disabling buffering forgets the at-rest key", !detLogHaveKey());
    check("disabling buffering keeps the records already written", detLogCount() == 3);
    check("disabling buffering requests retained sensitive-stack erasure",
          detLogSensitiveErasePending() != 0);
    detLogSetEnabled(true);           // re-enabled with no phone present: nothing to re-persist
    detLogHostResetRuntime();
    detLogBegin();
    check("the key was erased from NVS too, so a reboot cannot reload it", !detLogHaveKey());

    // `on=false` is the commit point for privacy cleanup. If the following blob removal fails,
    // RAM is already disabled and the next boot must finish deleting the key before it becomes
    // ready for append or replay.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextRemove("acab-buf", "key", 2);
    detLogSetEnabled(false);
    check("failed disable cleanup still commits off and forgets the RAM key",
          !detLogEnabled() && !detLogHaveKey() && !savedBool("on", true) &&
          savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();                         // consumes the second injected removal failure
    detLogStartDrain(0);
    const uint32_t writesBeforeDisableCleanup = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("reboot blocks key use while committed disable cleanup is incomplete",
          !detLogHaveKey() && !detLogDraining() && detLogCount() == 1 &&
          acabHostWriteCalls == writesBeforeDisableCleanup && savedKeyExists("key"));
    detLogEraseTick();
    check("loop retry removes the residual key before startup becomes ready",
          !detLogHaveKey() && !savedKeyExists("key") && !savedBool("on", true));

    // Standalone clear-key keeps the master switch but needs its own durable recovery marker.
    // Once keydrop=true lands, a power loss between it and remove() may not reload the old key.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextRemove("acab-buf", "key");
    detLogClearKey();
    check("failed standalone key removal leaves a durable boot cleanup marker",
          !detLogHaveKey() && savedBool("keydrop") && savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot honors keydrop before loading the retained key",
          !detLogHaveKey() && !savedKeyExists("key") && !savedBool("keydrop"));

    // A key update writes the decrypting key before its fingerprint. If the first write fails,
    // neither half of the retained pair changes and appends remain blocked until the retry; this
    // prevents rows from being admitted under a RAM key the reboot path cannot recover.
    fresh();
    const std::vector<uint8_t> retainedOldKey = savedBlob("key");
    const std::vector<uint8_t> retainedOldFp = savedBlob("keyfp");
    Preferences::failNextPutBytes("acab-buf", "key");
    detLogSetKey(otherKey, true);
    const uint32_t writesBeforeKeyRetry = acabHostWriteCalls;
    detLogAppend(detection(1));
    check("failed replacement write removes obsolete key, preserves identity, and blocks append",
          !savedKeyExists("key") && savedBlob("keyfp") == retainedOldFp &&
          detLogCount() == 0 && acabHostWriteCalls == writesBeforeKeyRetry);
    detLogEraseTick();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    detLogBegin();
    seqs = drainAll();
    check("key persistence retry survives reboot and decrypts the admitted row",
          seqs.size() == 1 && seqs.front() == 1 &&
          savedBlob("key") != retainedOldKey && savedBlob("keyfp") != retainedOldFp);

    // A verified key change first makes the old retained key unreloadable. If persistence of the
    // replacement fails, an immediate reboot must be keyless rather than capture a new nonce/log
    // generation under the obsolete key. Cover both the empty-ring and generation-wipe paths.
    fresh();
    Preferences::failNextPutBytes("acab-buf", "key");
    detLogSetKey(otherKey, true);
    check("empty-ring rotation removes the old retained key before replacement write",
          detLogHaveKey() && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot after empty-ring replacement failure cannot reload obsolete key",
          detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutBytes("acab-buf", "key");
    detLogSetKey(otherKey, true);
    check("nonempty rotation condemns rows before failed replacement publication",
          detLogWipePending() && detLogCount() == 0 && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("rebooted rotation sweep remains keyless until replacement is re-supplied",
          detLogWipePending() && !detLogHaveKey() && !savedKeyExists("key"));
    detLogEraseTick();
    check("obsolete key cannot capture in the retired replacement generation",
          detLogAppend(detection(2)) == DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);

    // wipegen lands before wipe=true. If the latter write fails during rotation, reboot still
    // condemns the old-key rows instead of ever exposing them under either key.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutBool("acab-buf", "wipe");
    detLogSetKey(otherKey, true);
    check("failed rotation arm retains old row but makes obsolete key unreloadable",
          detLogCount() == 1 && detLogWipePending() &&
          !savedKeyExists("key") && !savedBool("wipe") &&
          savedUInt("wipegen") != 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after rotation intent never restores old-key rows",
          detLogWipePending() && detLogCount() == 0);
    detLogEraseTick();

    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeRngRotation = detLogGeneration();
    acabHostRandomZeroCalls = 8;
    detLogSetKey(otherKey, true);
    check("RNG-failed rotation stages replacement behind durable targetless wipe",
          detLogWipePending() && detLogCount() == 1 && savedBool("wipe") &&
          savedBool("wipeneed") && !savedKeyExists("key") &&
          detLogGeneration() == generationBeforeRngRotation);
    detLogHostResetRuntime();
    detLogBegin();
    check("immediate reboot after RNG-failed rotation exposes neither old rows nor old key",
          detLogWipePending() && detLogCount() == 0 && !detLogHaveKey() &&
          !savedKeyExists("key") && detLogGeneration() != generationBeforeRngRotation);
    detLogEraseTick();

    // Pending rotation keys are last-write-wins. B is staged when its pre-arm RNG fails; a newer A
    // (which matches the surviving old fingerprint) must replace B rather than taking the normal
    // unchanged-key path and then being overwritten when the deferred wipe finally publishes.
    fresh();
    detLogAppend(detection(1));
    acabHostRandomZeroCalls = 8;
    detLogSetKey(otherKey, true);                   // explicit B transfer stages behind wipe
    detLogSetKey(sameKey);                          // newer A must replace staged B
    detLogEraseTick();
    const std::vector<uint8_t> sameKeyBlob(sameKey, sameKey + sizeof(sameKey));
    check("newest key replaces an older pre-arm rotation key before wipe publication",
          !detLogWipePending() && detLogHaveKey() && savedBlob("key") == sameKeyBlob);
    check("capture resumes under the final last-write-wins key",
          detLogAppend(detection(2)) == DET_LOG_APPEND_STORED && detLogCount() == 1);
    detLogHostResetRuntime();
    detLogBegin();
    seqs = drainAll();
    check("last-write-wins rotation key survives reboot and decrypts fresh rows",
          detLogHaveKey() && savedBlob("key") == sameKeyBlob &&
          seqs.size() == 1 && seqs.front() == 1);

    // A changed key can arrive while an ordinary clear already owns the generation arm. It still
    // must remove the old retained key before the wipe publishes it: if both replacement-key puts
    // then fail, reboot must be keyless rather than restore A under B's fresh empty generation.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogClear();                                  // durable wipe intent, publication still pending
    detLogSetKey(otherKey, true);                   // explicit B transfer removes A before staging
    Preferences::failNextPutBytes("acab-buf", "key", 2);
    detLogEraseTick();                              // publish B; both inline and coordinator puts fail
    check("pending-clear key change makes obsolete retained key unreloadable",
          detLogWipePending() && detLogCount() == 0 && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("replacement-put failure after pending-clear publication reboots keyless",
          detLogWipePending() && detLogEnabled() && !detLogHaveKey() &&
          !savedKeyExists("key"));
    detLogEraseTick();
    detLogSetKey(otherKey, true);
    check("re-supplied replacement key restores capture after safe wipe retirement",
          detLogAppend(detection(2)) == DET_LOG_APPEND_STORED && detLogCount() == 1);

    // Exercise the same pending-wipe key transaction without an authenticated-session pre-arm or
    // any older cdwipe token. Sequence exhaustion starts a ring wipe with clearLocked(false); the
    // first replacement-key token write then fails. The maintenance tick must retry that token and
    // remove A before it can publish B, even when both attempts to persist B subsequently fail.
    fresh();
    {
        StoredDet terminal = {};
        terminal.seq = 0xFFFFFFFEu;
        terminal.bootCount = savedUInt("boot");
        terminal.crc = testRecordCrc(terminal);
        const uint32_t slots = (uint32_t)(acabHostFlash.size() / sizeof(StoredDet));
        const uint32_t idx = (terminal.seq - 1) % slots;
        std::memcpy(acabHostFlash.data() + idx * sizeof(StoredDet), &terminal, sizeof(terminal));
    }
    detLogHostResetRuntime();
    detLogBegin();
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogAppend(detection(1));                     // target durable, publication still pending
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetKey(otherKey, true);                   // explicit B transfer; first token put fails
    check("pending-wipe rotation waits when its first erase-token write fails",
          detLogWipePending() && savedUInt("cdwipe") == 0 &&
          savedBlob("key") == sameKeyBlob);
    Preferences::failNextPutBytes("acab-buf", "key", 2);
    detLogEraseTick();                              // token + A removal precede B publication
    check("token retry makes old key unreloadable before pending-wipe publication",
          detLogWipePending() && savedUInt("cdwipe") != 0 && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot after token retry and replacement-put failure remains keyless",
          detLogWipePending() && detLogEnabled() && !detLogHaveKey() &&
          !savedKeyExists("key"));

    // A repeated clear can mint the token that an in-flight pending-wipe rotation was missing, but
    // it must not use that fact to bypass the rotation's still-uncommitted old-key removal. Only
    // the maintenance coordinator may finish that prerequisite and publish the staged key.
    fresh();
    {
        StoredDet terminal = {};
        terminal.seq = 0xFFFFFFFEu;
        terminal.bootCount = savedUInt("boot");
        terminal.crc = testRecordCrc(terminal);
        const uint32_t slots = (uint32_t)(acabHostFlash.size() / sizeof(StoredDet));
        const uint32_t idx = (terminal.seq - 1) % slots;
        std::memcpy(acabHostFlash.data() + idx * sizeof(StoredDet), &terminal, sizeof(terminal));
    }
    detLogHostResetRuntime();
    detLogBegin();
    const uint32_t generationBeforeRepeatedClearRotation = detLogGeneration();
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogAppend(detection(1));                     // auto-wipe arm has no coredump token
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetKey(otherKey, true);
    detLogClear();                                  // new token lands; arm must remain deferred
    check("repeated clear cannot bypass pending rotation key cleanup",
          savedUInt("loggen") == generationBeforeRepeatedClearRotation && savedKeyExists("key"));
    Preferences::failNextPutBytes("acab-buf", "key", 2);
    detLogEraseTick();
    check("rotation cleanup removes old key before repeated-clear arm publication",
          savedUInt("loggen") != generationBeforeRepeatedClearRotation &&
          !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("repeated-clear replacement failure cannot reload the obsolete key",
          detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    // Disable/clear-key coordinators take precedence over a pending ordinary wipe. A handshake key
    // arriving after buffer:false remains a replay-only RAM intent; the wipe publication must not
    // persist it before mandatory off/key cleanup, and reboot remains durably off and keyless.
    fresh();
    detLogAppend(detection(1));
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogClear();
    Preferences::failNextRemove("acab-buf", "key");
    detLogSetEnabled(false);
    detLogSetKey(otherKey, true);
    detLogEraseTick();
    check("pending wipe cannot steal key ownership from disable cleanup",
          !detLogEnabled() && detLogHaveKey() && !savedKeyExists("key") &&
          !savedBool("on", true));
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after deferred-clear/disable/key ordering stays off and keyless",
          !detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    // A standalone privacy cleanup has the same priority even when no replacement key is waiting.
    // Hold a clear arm at its loggen publication boundary, fail the first two cleanup commits, and
    // prove the arm cannot advance until a later tick establishes the clear-key recovery boundary.
    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforePendingClearKey = detLogGeneration();
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogClear();
    Preferences::failNextPutBool("acab-buf", "keydrop", 2);
    detLogClearKey();
    detLogEraseTick();
    check("pending clear cannot publish ahead of standalone clear-key cleanup",
          savedUInt("loggen") == generationBeforePendingClearKey && savedKeyExists("key"));
    detLogEraseTick();
    check("clear-key recovery commits before the pending generation can publish",
          savedUInt("loggen") != generationBeforePendingClearKey && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after ordered clear-key/arm commit reboots keyless",
          detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforePendingDisable = detLogGeneration();
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogClear();
    Preferences::failNextPutBool("acab-buf", "on", 2);
    detLogSetEnabled(false);
    detLogEraseTick();
    check("pending clear cannot publish ahead of standalone disable cleanup",
          savedUInt("loggen") == generationBeforePendingDisable && savedBool("on"));
    detLogEraseTick();
    check("disable recovery commits before the pending generation can publish",
          savedUInt("loggen") != generationBeforePendingDisable &&
          !savedBool("on", true) && !savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss after ordered disable/arm commit stays off and keyless",
          !detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    // The reverse production ordering is synchronous: buffer:false/ClearKey can fail, then a
    // clearlog field arrives in the same config object. clearLocked must remain RAM-deferred and
    // write no wipe target until the older privacy transaction reaches its durable marker.
    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeDisableThenClear = detLogGeneration();
    Preferences::failNextPutBool("acab-buf", "on", 2);
    detLogSetEnabled(false);
    detLogClear();
    check("disable-first clear writes no ring arm before off cleanup",
          !savedBool("wipe") && savedUInt("loggen") == generationBeforeDisableThenClear);
    detLogEraseTick();
    check("failed disable retry continues to hold the deferred clear in RAM",
          !savedBool("wipe") && savedUInt("loggen") == generationBeforeDisableThenClear);
    detLogEraseTick();
    detLogHostResetRuntime();
    detLogBegin();
    check("disable-first clear publishes only after reboot-safe off cleanup",
          !detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key") &&
          detLogGeneration() != generationBeforeDisableThenClear);

    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeClearKeyThenClear = detLogGeneration();
    Preferences::failNextPutBool("acab-buf", "keydrop", 2);
    detLogClearKey();
    detLogClear();
    check("clear-key-first clear writes no ring arm before key cleanup",
          !savedBool("wipe") && savedUInt("loggen") == generationBeforeClearKeyThenClear);
    detLogEraseTick();
    check("failed clear-key retry continues to hold the deferred clear in RAM",
          !savedBool("wipe") && savedUInt("loggen") == generationBeforeClearKeyThenClear);
    detLogEraseTick();
    detLogHostResetRuntime();
    detLogBegin();
    check("clear-key-first clear publishes only after reboot-safe key removal",
          detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key") &&
          detLogGeneration() != generationBeforeClearKeyThenClear);

    // The exact state a gKey-conditioned guard would MISS: records outlived their key, so nothing
    // but the persisted fingerprint can recognise the new phone.
    fresh();
    appendRange(1, 3);
    detLogSetEnabled(false);
    detLogHostResetRuntime();
    detLogBegin();
    check("records survive a disable plus a reboot", detLogCount() == 3);
    check("...and the board holds no key at that point", !detLogHaveKey());
    detLogSetKey(otherKey, true);
    check("the persisted fingerprint fires the wipe with no key in hand", detLogCount() == 0);
    check("keyless fingerprint wipe is physical too", detLogWipePending());

    // ---- retained-coredump erase intent ----------------------------------------------------
    // The core dump is a separate partition and the ring's `wipe` bit is shared with auto-wipe.
    // Explicit intent therefore has its own generation token, durable across a power failure and
    // acknowledged only by the exact generation that was physically handled.
    fresh();
    detLogAppend(detection(1));
    check("a fresh log has no sensitive erase request", detLogSensitiveErasePending() == 0);
    detLogClear();
    const uint32_t eraseGen1 = detLogSensitiveErasePending();
    check("explicit clear creates a nonzero sensitive erase generation", eraseGen1 != 0);
    check("explicit clear also starts the independent ring sweep", detLogWipePending());
    detLogHostResetRuntime();
    detLogBegin();
    check("sensitive erase generation survives power loss", detLogSensitiveErasePending() == eraseGen1);
    detLogSensitiveEraseComplete(eraseGen1 + 1);
    check("wrong-generation completion cannot clear the request",
          detLogSensitiveErasePending() == eraseGen1);
    detLogSensitiveEraseComplete(eraseGen1);
    check("matching completion clears the request", detLogSensitiveErasePending() == 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("completed request stays clear after reboot", detLogSensitiveErasePending() == 0);

    // A second explicit clear while the ring's shared pending LEVEL is already true used to be
    // invisible to the coredump edge detector. A new generation makes that state unambiguous.
    fresh();
    detLogAppend(detection(1));
    detLogClear();
    const uint32_t eraseGen2 = detLogSensitiveErasePending();
    detLogClear();
    const uint32_t eraseGen3 = detLogSensitiveErasePending();
    check("clear during an already-pending ring sweep advances the erase generation",
          eraseGen2 != 0 && eraseGen3 != 0 && eraseGen3 != eraseGen2 && detLogWipePending());
    detLogSensitiveEraseComplete(eraseGen2);
    check("old completion cannot acknowledge a newer explicit clear",
          detLogSensitiveErasePending() == eraseGen3);
    detLogSensitiveEraseComplete(eraseGen3);
    check("same-boot completion remains pinned by sensitive stack exposure",
          detLogSensitiveErasePending() == eraseGen3);
    detLogHostResetRuntime();
    detLogBegin();
    detLogSensitiveEraseComplete(eraseGen3);
    check("clean reboot releases the hold and clears the matching request",
          detLogSensitiveErasePending() == 0);

    // `buffer:false` remains a privacy action even when the switch was already false: a crash can
    // create a new retained stack dump after the original disable was completed.
    fresh();
    detLogSetEnabled(false);
    const uint32_t disableGen1 = detLogSensitiveErasePending();
    detLogSensitiveEraseComplete(disableGen1);
    detLogSetEnabled(false);
    const uint32_t disableGen2 = detLogSensitiveErasePending();
    check("repeated disabled-state echoes reuse the boot-pinned erase request",
          disableGen1 != 0 && disableGen2 == disableGen1);

    // Key rotation must clean retained stack copies even when the ring happens to be empty, so it
    // cannot be conditional on countLocked() as the physical ring wipe is.
    fresh();
    detLogSetKey(otherKey, true);
    check("key change with an empty ring still requests coredump erasure",
          detLogCount() == 0 && !detLogWipePending() && detLogSensitiveErasePending() != 0);

    // A privacy request exists only after `cdwipe` is durable. Exercise both failure modes that
    // the old code ignored, then prove the loop-side pending read retries them without another
    // user action. The diagnostic bit is sticky so the app/operator can see that NVS was unwell.
    fresh();
    Preferences::failNextBegin();
    detLogClear();
    check("failed NVS begin does not pretend a coredump wipe token was stored",
          savedUInt("cdwipe") == 0);
    check("failed coredump-token begin latches the NVS diagnostic",
          (detLogFaults() & DET_LOG_FAULT_NVS) != 0);
    const uint32_t retryAfterBegin = detLogSensitiveErasePending();
    check("loop-side pending read retries a failed begin",
          retryAfterBegin != 0 && savedUInt("cdwipe") == retryAfterBegin);

    // Boot restore is a separate failure boundary from creating a request. The token is already
    // durable here; a failed open must leave it hidden only until the loop can retry, never for
    // the whole running session and never by replacing it with the default zero.
    fresh();
    detLogClear();
    const uint32_t durableAcrossBootOpenFailure = detLogSensitiveErasePending();
    detLogHostResetRuntime();
    Preferences::failNextBegin();
    detLogBegin();
    check("failed boot-time cdwipe load latches the NVS diagnostic",
          durableAcrossBootOpenFailure != 0 &&
          (detLogFaults() & DET_LOG_FAULT_NVS) != 0 &&
          savedUInt("cdwipe") == durableAcrossBootOpenFailure);
    Preferences::failNextBegin();
    check("a failed first loop retry does not fabricate a pending generation",
          detLogSensitiveErasePending() == 0 &&
          savedUInt("cdwipe") == durableAcrossBootOpenFailure);
    check("a later loop retry restores the already-durable generation",
          detLogSensitiveErasePending() == durableAcrossBootOpenFailure);

    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetEnabled(false);
    check("failed cdwipe put does not publish a phantom durable generation",
          savedUInt("cdwipe") == 0 && detLogEnabled() && detLogHaveKey() &&
          savedBool("on") && savedKeyExists("key") &&
          (detLogFaults() & DET_LOG_FAULT_NVS) != 0);
    const uint32_t retryAfterPut = detLogSensitiveErasePending();
    check("loop-side pending read retries a failed cdwipe put",
          retryAfterPut != 0 && savedUInt("cdwipe") == retryAfterPut);
    detLogEraseTick();
    check("staged disable completes only after the dump-erasure token is durable",
          !detLogEnabled() && !detLogHaveKey() && !savedBool("on", true));

    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetEnabled(false);
    detLogSetKey(otherKey);            // newer replay key arrives while privacy token is pending
    detLogEraseTick();
    check("deferred disable cleanup preserves the newer RAM-only replay key",
          !detLogEnabled() && detLogHaveKey() && !savedKeyExists("key") &&
          savedBlob("keyfp") != savedBlob("key"));

    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogClearKey();
    detLogSetKey(otherKey);            // replacement must apply after old-key removal
    detLogEraseTick();
    check("deferred clear-key cleanup installs the newer enabled key afterward",
          detLogEnabled() && detLogHaveKey() && savedKeyExists("key") &&
          savedBlob("key") != std::vector<uint8_t>(sameKey, sameKey + sizeof(sameKey)));

    // The inverse ordering is a privacy boundary: a key staged before ClearKey/buffer:false is
    // part of the state being forgotten. A failed coredump-token write may preserve only keys that
    // arrive after the action was queued, never resurrect an older staged key on retry.
    fresh();
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);                  // keep retained startup publication pending
    detLogBegin();
    detLogSetKey(otherKey);                         // staged before the privacy action
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogClearKey();
    detLogEraseTick();
    check("failed-token clear discards a key staged before the clear",
          detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    fresh();
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    detLogSetKey(otherKey);                         // staged before buffer:false
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetEnabled(false);
    detLogEraseTick();
    check("failed-token disable discards a key staged before buffer:false",
          !detLogEnabled() && !detLogHaveKey() && !savedKeyExists("key"));

    // If power fails before that loop retry, the public API must have rejected the disable rather
    // than publishing a keyless/off state with no durable dump-erasure obligation. Reboot therefore
    // restores the old complete config; the authenticated client can retry the command later.
    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogSetEnabled(false);
    detLogHostResetRuntime();
    detLogBegin();
    check("failed disable pre-arm plus immediate reboot restores the intact protected config",
          savedUInt("cdwipe") == 0 && detLogEnabled() && detLogHaveKey() &&
          savedBool("on") && savedKeyExists("key"));

    // Standalone clear-key uses the same fail-closed privacy boundary. A failed first token cannot
    // erase either RAM or NVS identity and then leave a panic dump uncondemned across power loss.
    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogClearKey();
    check("failed clear-key pre-arm keeps the live and retained key intact",
          detLogHaveKey() && savedKeyExists("key") && !savedBool("keydrop") &&
          savedUInt("cdwipe") == 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("clear-key token failure cannot become a keyless unprotected reboot state",
          detLogEnabled() && detLogHaveKey() && savedKeyExists("key"));

    // If generation N was already durable when N+1 failed to persist, completion of N must leave
    // its token in place. That old durable token is the reboot backstop for the newer RAM-only
    // intent until retry succeeds; clearing it would recreate the power-loss hole.
    fresh();
    detLogClear();
    const uint32_t durableOldGeneration = detLogSensitiveErasePending();
    Preferences::failNextPutUInt("acab-buf", "cdwipe");
    detLogClear();
    detLogSensitiveEraseComplete(durableOldGeneration);
    check("older completion retains its durable token while a newer request awaits NVS",
          durableOldGeneration != 0 && savedUInt("cdwipe") == durableOldGeneration);
    const uint32_t supersedingGeneration = detLogSensitiveErasePending();
    check("retry durably supersedes the retained old generation",
          supersedingGeneration != 0 && supersedingGeneration != durableOldGeneration &&
          savedUInt("cdwipe") == supersedingGeneration);

    // The counter is advisory once cdwipe has committed: erase immediately, report the failed
    // write, and repair cdgen in the background. A reboot can also recover it from cdwipe.
    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdgen");
    detLogClear();
    const uint32_t durableWithoutCounter = savedUInt("cdwipe");
    check("a durable cdwipe remains actionable when only cdgen fails",
          durableWithoutCounter != 0 && (detLogFaults() & DET_LOG_FAULT_NVS) != 0 &&
          detLogSensitiveErasePending() == durableWithoutCounter);
    check("loop-side retry repairs the advisory generation counter",
          savedUInt("cdgen") == durableWithoutCounter);

    // A recovered coredump-token write reports its historical fault but must not poison unrelated
    // raw-ring geometry. Otherwise a transient cdgen failure with an empty ring disables every
    // future capture until the user performs a full clear.
    fresh();
    Preferences::failNextPutUInt("acab-buf", "cdgen");
    detLogSetEnabled(false);                  // creates the token without starting a ring sweep
    const uint32_t disableWithNvsFault = detLogSensitiveErasePending();
    detLogSetEnabled(true);
    detLogSetKey(sameKey);                    // disable deliberately forgot the RAM/NVS key
    detLogAppend(detection(1));
    check("a non-ring NVS diagnostic does not block future evidence appends",
          disableWithNvsFault != 0 && (detLogFaults() & DET_LOG_FAULT_NVS) != 0 &&
          detLogCount() == 1);

    // ---- format-2 integrity and durable replay generation -----------------------------------
    // A blank/old namespace cannot be interpreted with the stronger header CRC or nonce domain.
    // It is condemned without one raw-slot read and migrated asynchronously before first capture.
    Preferences::wipeAll();
    acabHostPartitionReset(8192);
    acabHostPartitionCorrupt(20, 0x00);             // stand-in for one programmed format-1 byte
    detLogHostResetRuntime();
    const uint32_t readsBeforeFormatMigration = acabHostReadCalls;
    detLogBegin();
    check("missing ring format condemns legacy bytes before scan",
          detLogWipePending() && detLogCount() == 0 &&
          acabHostReadCalls == readsBeforeFormatMigration && savedUInt("wipegen") != 0);
    detLogEraseTick();
    check("format migration retires only after erase and random generation persistence",
          !detLogWipePending() && acabHostPartitionAllErased() &&
          savedUInt("ringfmt") == 2 && savedUInt("loggen") != 0 &&
          savedUInt("wipegen") == 0);

    // Cleartext boot/gps fields select the CTR nonce and evidence metadata. Format 2's CRC covers
    // them: mutating either must reject the slot, rather than decrypt under a wrong nonce or claim
    // a fabricated fix age.
    fresh();
    detLogAppend(detection(1));
    acabHostPartitionCorrupt(offsetof(StoredDet, bootCount),
                             (uint8_t)(acabHostFlash[offsetof(StoredDet, bootCount)] ^ 0x01));
    detLogStartDrain(0);
    check("mutated cleartext boot header is rejected by the format-2 CRC",
          !detLogPeekForDrain(&replay) && (detLogFaults() & DET_LOG_FAULT_CORRUPT));

    fresh();
    detLogAppend(detection(1));
    acabHostPartitionCorrupt(offsetof(StoredDet, gpsAgeSec),
                             (uint8_t)(acabHostFlash[offsetof(StoredDet, gpsAgeSec)] ^ 0x01));
    detLogStartDrain(0);
    check("mutated cleartext GPS-age header is rejected by the format-2 CRC",
          !detLogPeekForDrain(&replay) && (detLogFaults() & DET_LOG_FAULT_CORRUPT));

    // If payload programming succeeds but the final header and its best-effort fault write are
    // both lost to power failure, reboot must see programmed-body+erased-seq as corruption and
    // refuse to reuse the non-erased slot.
    fresh();
    resetHook();
    Preferences::failNextPutUInt("acab-buf", "fault");
    failWriteNumber = 2;
    acabHostFlashHook = flashHook;
    detLogAppend(detection(1));
    resetHook();
    check("torn payload with lost fault marker publishes no record", detLogCount() == 0);
    detLogHostResetRuntime();
    detLogBegin();
    const uint32_t writesBeforeTornReuse = acabHostWriteCalls;
    detLogAppend(detection(2));
    check("reboot condemns programmed-body erased-header slot and blocks reuse",
          detLogCount() == 0 && (detLogFaults() & DET_LOG_FAULT_CORRUPT) &&
          acabHostWriteCalls == writesBeforeTornReuse);

    // Sequence sentinels are not usable record IDs. Seed the last valid seq at its mapped slot,
    // reboot-scan it, and prove the next append creates a fresh nonce/log generation instead of
    // emitting 0xFFFFFFFF or wrapping to zero.
    fresh();
    {
        StoredDet terminal = {};
        terminal.seq = 0xFFFFFFFEu;
        terminal.bootCount = savedUInt("boot");
        terminal.crc = testRecordCrc(terminal);
        const uint32_t slots = (uint32_t)(acabHostFlash.size() / sizeof(StoredDet));
        const uint32_t idx = (terminal.seq - 1) % slots;
        std::memcpy(acabHostFlash.data() + idx * sizeof(StoredDet), &terminal, sizeof(terminal));
    }
    const uint32_t generationBeforeSeqExhaustion = detLogGeneration();
    detLogHostResetRuntime();
    detLogBegin();
    detLogAppend(detection(1));
    check("sequence exhaustion arms a new random generation without writing a sentinel",
          detLogWipePending() && detLogCount() == 0 &&
          detLogGeneration() != 0 && detLogGeneration() != generationBeforeSeqExhaustion);
    detLogEraseTick();
    detLogAppend(detection(1));
    seqs = drainAll();
    check("capture resumes at seq 1 only after exhausted generation retirement",
          seqs.size() == 1 && seqs.front() == 1);

    // Cursor authority is generation-scoped. After a clear, grow the new log beyond the phone's
    // old cursor; mismatch/missing/foreign tokens still replay seq 1 rather than silently skipping
    // the overlapping prefix. A matching token may resume normally.
    fresh();
    const uint32_t oldLogGeneration = detLogGeneration();
    detLogClear();
    detLogEraseTick();
    const uint32_t newLogGeneration = detLogGeneration();
    appendRange(1, 110);
    detLogStartDrain(100, oldLogGeneration);
    check("stale generation rebases even when its cursor is below the new head",
          oldLogGeneration != 0 && newLogGeneration != 0 &&
          oldLogGeneration != newLogGeneration && detLogDrainFrom() == 1 &&
          detLogPendingDrain() == 110);
    detLogStopDrain();
    detLogStartDrain(100, 0);
    check("legacy sync without generation safely replays the retained window",
          detLogDrainFrom() == 1 && detLogPendingDrain() == 110);
    detLogStopDrain();
    uint32_t foreignGeneration = newLogGeneration ^ 0x80000000u;
    if (foreignGeneration == 0) foreignGeneration = 1;
    detLogStartDrain(100, foreignGeneration);
    check("another board's generation token cannot authorize this cursor",
          detLogDrainFrom() == 1 && detLogPendingDrain() == 110);
    detLogStopDrain();
    detLogStartDrain(100, newLogGeneration);
    check("matching generation resumes at the supplied cursor",
          detLogDrainFrom() == 101 && detLogPendingDrain() == 10);
    detLogStopDrain();
    check("matching-generation future cursor rebases to retained floor",
          detLogStartDrain(1000, newLogGeneration) == DET_LOG_DRAIN_STARTED &&
          detLogDrainFrom() == 1 && detLogPendingDrain() == 110);
    detLogStopDrain();
    check("matching-generation UINT_MAX cursor cannot wrap or suppress replay",
          detLogStartDrain(0xFFFFFFFFu, newLogGeneration) == DET_LOG_DRAIN_STARTED &&
          detLogDrainFrom() == 1 && detLogPendingDrain() == 110);
    detLogStopDrain();

    fresh();
    check("accepted empty sync is distinguished from pending or rejected startup",
          detLogStartDrain(0, detLogGeneration()) == DET_LOG_DRAIN_EMPTY &&
          !detLogDrainStartPending() && !detLogDraining() && detLogPendingDrain() == 0);

    // The same app key is shared across boards. A separate random 128-bit crypto domain is part of
    // every CTR nonce, so two fresh namespaces at boot1/seq1 must not reuse a keystream, while both
    // remain decryptable. The 32-bit loggen is only replay cursor authority.
    fresh();
    AcabDetection samePlaintext = detection(77);
    samePlaintext.lastSeen = 4242;
    detLogAppend(samePlaintext);
    const uint32_t firstBoardGeneration = detLogGeneration();
    const std::vector<uint8_t> firstBoardCryptoDomain = savedBlob("cryptdom");
    std::vector<uint8_t> firstCipher(acabHostFlash.begin() + ENC_OFF,
                                     acabHostFlash.begin() + ENC_OFF + ENC_LEN);
    seqs = drainAll();
    const bool firstBoardDecrypts = seqs.size() == 1 && seqs.front() == 1;
    fresh();
    detLogAppend(samePlaintext);
    const uint32_t secondBoardGeneration = detLogGeneration();
    const std::vector<uint8_t> secondBoardCryptoDomain = savedBlob("cryptdom");
    std::vector<uint8_t> secondCipher(acabHostFlash.begin() + ENC_OFF,
                                      acabHostFlash.begin() + ENC_OFF + ENC_LEN);
    seqs = drainAll();
    check("fresh-board random generations prevent shared-key CTR keystream reuse",
          firstBoardGeneration != 0 && secondBoardGeneration != 0 &&
          firstBoardGeneration != secondBoardGeneration &&
          firstBoardCryptoDomain.size() == 16 && secondBoardCryptoDomain.size() == 16 &&
          firstBoardCryptoDomain != secondBoardCryptoDomain && firstCipher != secondCipher);
    check("generation-domain ciphertext decrypts on both originating boards",
          firstBoardDecrypts && seqs.size() == 1 && seqs.front() == 1);

    // wipegen is durable before the other arm fields and is retired before wipe=false. Exercise
    // both interior power-loss boundaries explicitly.
    fresh();
    detLogAppend(detection(1));
    const uint32_t logBeforePartialArm = detLogGeneration();
    Preferences::failNextPutUInt("acab-buf", "loggen");
    detLogClear();
    const uint32_t targetAfterPartialArm = savedUInt("wipegen");
    check("failed loggen publication keeps the old runtime blocked behind durable wipe intent",
          detLogCount() == 1 && detLogWipePending() && savedBool("wipe") &&
          savedUInt("loggen") == logBeforePartialArm && targetAfterPartialArm != 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot completes pending generation publication before any replay",
          detLogWipePending() && detLogCount() == 0 &&
          detLogGeneration() == targetAfterPartialArm);
    detLogEraseTick();

    fresh();
    detLogAppend(detection(1));
    detLogClear();
    Preferences::failNextPutUInt("acab-buf", "wipegen");
    detLogEraseTick();
    check("failed final generation retirement keeps the erased ring blocked",
          detLogWipePending() && savedBool("wipe") && acabHostPartitionAllErased());
    detLogHostResetRuntime();
    detLogBegin();
    detLogEraseTick();
    check("reboot safely resumes and retires a partial generation finalization",
          !detLogWipePending() && savedUInt("wipegen") == 0);

    // bufsat is a Stationary-mode capacity/censoring-risk flag, not proof a refusal happened. Raise
    // it on exact fill, recover a failed marker from persisted bufall + geometry after power loss,
    // and keep the actual-refusal counter separate.
    fresh();
    detLogSetBufferAll(true);
    Preferences::failNextPutBool("acab-buf", "bufsat");
    appendRange(1, 128);
    check("exact fill raises capacity risk without claiming an actual refusal",
          detLogSaturated() && detLogSatDrops() == 0 && !savedBool("bufsat"));
    const uint32_t writesBeforeUnmarkedWrap = acabHostWriteCalls;
    const DetLogAppendResult unmarkedWrap = detLogAppend(detection(129, ACAB_TRACKER));
    check("failed capacity-marker persistence blocks signature wrap until durable",
          unmarkedWrap == DET_LOG_APPEND_RETRY && detLogCount() == 128 &&
          acabHostWriteCalls == writesBeforeUnmarkedWrap);
    detLogHostResetRuntime();
    detLogBegin();
    check("Stationary full-ring reboot recovers and persists a lost capacity warning",
          detLogBufferAll() && detLogSaturated() && detLogSatDrops() == 0 &&
          savedBool("bufsat") && detLogCount() == 128);
    detLogAppend(detection(129, ACAB_NEARBY_DEVICE));
    check("bufdrops separately counts a real post-capacity refusal",
          detLogSaturated() && detLogSatDrops() == 1 && detLogCount() == 128);

    fresh();
    detLogSetBufferAll(true);
    Preferences::failNextPutBool("acab-buf", "bufsat", 2); // exact-fill + transition flush
    appendRange(1, 128);
    detLogSetBufferAll(false);
    check("bufall=false cannot outrun a failed exact-fill warning",
          !savedBool("bufsat") && savedBool("bufall"));
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss during bufall-off preserves recoverable capacity warning",
          detLogBufferAll() && detLogSaturated() && savedBool("bufsat"));

    fresh();
    detLogSetBufferAll(true);
    Preferences::failNextPutBool("acab-buf", "bufsat", 2); // exact-fill + disable flush
    appendRange(1, 128);
    detLogSetEnabled(false);
    check("buffer:false cannot commit before the lost capacity warning",
          !savedBool("bufsat") && savedBool("on") && savedBool("bufall"));
    detLogHostResetRuntime();
    detLogBegin();
    check("power loss during disable still reconstructs the Stationary warning",
          detLogEnabled() && detLogBufferAll() && detLogSaturated() && savedBool("bufsat"));

    fresh();
    appendRange(1, 128);
    detLogHostResetRuntime();
    detLogBegin();
    check("an ordinary full FIFO ring does not fabricate Stationary saturation",
          !detLogBufferAll() && !detLogSaturated() && detLogSatDrops() == 0);
    detLogSetBufferAll(true);
    check("enabling Stationary capture on an already-full ring marks capacity",
          detLogSaturated() && savedBool("bufsat"));

    fresh();
    detLogSetEnabled(false);
    detLogSetBufferAll(true);          // contradictory {buffer:false,bufall:true} field ordering
    check("disabled config cannot persist a contradictory Stationary-capture posture",
          !detLogEnabled() && !detLogBufferAll() && !savedBool("bufall"));

    // Optional anchors retry transient exact-size read failures, but a permanently unreadable blob
    // is quarantined after a bound so valid rows replay honestly as approximate rather than hanging
    // the BLE history session forever.
    fresh();
    acabHostSetMillis(5000);
    detLogSetEpoch(1700000000u);
    AcabDetection anchored = detection(1);
    anchored.lastSeen = 5000;
    detLogAppend(anchored);
    detLogHostResetRuntime();
    Preferences::failNextGetBytes("acab-buf", "anch", 3);
    detLogBegin();
    detLogStartDrain(0);
    check("unreadable exact-size anchors initially block replay for bounded retry",
          !detLogDraining());
    detLogEraseTick();
    detLogEraseTick();
    detLogStartDrain(0);
    DetLogReplay quarantinedAnchorReplay;
    check("persistently unreadable anchors quarantine to honest approximate replay",
          detLogPeekForDrain(&quarantinedAnchorReplay) && quarantinedAnchorReplay.approx &&
          !savedKeyExists("anch") && (detLogFaults() & DET_LOG_FAULT_NVS));

    // Anchor persistence is optional evidence metadata. Permanent cursor/blob write failures get a
    // bounded retry, then replay proceeds with the valid RAM anchor for this session rather than
    // stranding sound rows forever. A later reboot honestly loses exactness.
    fresh();
    Preferences::failNextPutUChar("acab-buf", "anchn", 3);
    acabHostSetMillis(6000);
    detLogSetEpoch(1700000500u);
    AcabDetection cursorSaveFailureRow = detection(1);
    cursorSaveFailureRow.lastSeen = 6000;
    detLogAppend(cursorSaveFailureRow);
    detLogStartDrain(0);
    detLogEraseTick();
    detLogEraseTick();
    DetLogReplay anchorSaveReplay;
    check("permanent anchor-cursor write failure fails open with exact RAM replay",
          detLogPeekForDrain(&anchorSaveReplay) && !anchorSaveReplay.approx &&
          anchorSaveReplay.atUnix == 1700000500u &&
          (detLogFaults() & DET_LOG_FAULT_NVS));
    detLogHostResetRuntime();
    detLogBegin();
    detLogStartDrain(0);
    check("reboot after discarded cursor save replays honestly approximate",
          detLogPeekForDrain(&anchorSaveReplay) && anchorSaveReplay.approx);

    fresh();
    Preferences::failNextPutBytes("acab-buf", "anch", 3);
    acabHostSetMillis(6500);
    detLogSetEpoch(1700000750u);
    AcabDetection blobSaveFailureRow = detection(1);
    blobSaveFailureRow.lastSeen = 6500;
    detLogAppend(blobSaveFailureRow);
    detLogStartDrain(0);
    detLogEraseTick();
    detLogEraseTick();
    check("permanent anchor-blob write failure cannot strand valid replay",
          detLogPeekForDrain(&anchorSaveReplay) && !anchorSaveReplay.approx &&
          anchorSaveReplay.atUnix == 1700000750u &&
          (detLogFaults() & DET_LOG_FAULT_NVS));

    fresh();
    detLogAppend(detection(1));
    const uint8_t malformedAnchor = 0xA5;
    seedBlob("anch", &malformedAnchor, sizeof(malformedAnchor));
    detLogHostResetRuntime();
    detLogBegin();
    detLogStartDrain(0);
    check("wrong-length anchor metadata is permanently quarantined without blocking rows",
          detLogPeekForDrain(&quarantinedAnchorReplay) && quarantinedAnchorReplay.approx &&
          !savedKeyExists("anch"));

    // A clear changes encryption/log generations but not the physical uptime clock. Clone the
    // current anchor to the fresh boot ID so same-boot post-clear records remain exactly datable.
    fresh();
    acabHostSetMillis(7000);
    detLogSetEpoch(1700001000u);
    detLogClear();
    detLogEraseTick();
    AcabDetection afterClearEpoch = detection(1);
    afterClearEpoch.lastSeen = 7000;
    detLogAppend(afterClearEpoch);
    detLogStartDrain(0);
    DetLogReplay afterClearReplay;
    check("logical clear clones the valid uptime anchor to its new boot generation",
          detLogPeekForDrain(&afterClearReplay) && !afterClearReplay.approx &&
          afterClearReplay.atUnix == 1700001000u);

    // Losing the boot key while anchors survive must select a boot strictly above every retained
    // anchor. Otherwise a pre-epoch capture in the new physical boot can collide with an old boot ID
    // and be stamped exact at the stale Unix time.
    fresh();
    acabHostSetMillis(9000);
    detLogSetEpoch(1700002000u);
    const uint32_t anchoredBoot = savedUInt("boot");
    removeSaved("boot");
    detLogHostResetRuntime();
    detLogBegin();
    AcabDetection collisionProbe = detection(1);
    collisionProbe.lastSeen = 1000;
    detLogAppend(collisionProbe);
    detLogStartDrain(0);
    DetLogReplay collisionReplay;
    check("boot recovery advances beyond retained anchor IDs",
          savedUInt("boot") > anchoredBoot && detLogPeekForDrain(&collisionReplay) &&
          collisionReplay.approx);

    // lastconn is also a durable prior boot ID. When boot and anchors are lost on an empty ring,
    // use it as a lower bound or unsigned age arithmetic can condemn the first new row next reboot.
    fresh();
    removeSaved("boot");
    removeSaved("anch");
    removeSaved("anchn");
    seedUInt("lastconn", 100);
    detLogHostResetRuntime();
    detLogBegin();
    check("startup boot identity is newer than surviving lastconn metadata",
          savedUInt("boot") == 101);
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    detLogBegin();
    check("lastconn lower bound prevents wrapped-age auto-wipe of a fresh row",
          detLogCount() == 1 && !detLogWipePending() && savedUInt("boot") == 102);

    // Missing loggen in an otherwise current-format namespace makes existing rows' replay/crypto
    // generation unverifiable. Condemn them under a fresh random tuple before admitting traffic.
    fresh();
    appendRange(1, 110);
    removeSaved("loggen");
    detLogHostResetRuntime();
    detLogBegin();
    const uint32_t repairedGeneration = detLogGeneration();
    detLogStartDrain(100, 1);
    check("missing current-format loggen condemns rows before random repair",
          repairedGeneration != 0 && savedUInt("loggen") == repairedGeneration &&
          detLogWipePending() && detLogCount() == 0 && !detLogDraining());
    detLogEraseTick();

    // Disabled-session setup is boot-scoped. Repeated handshakes reuse one token and disconnect is
    // a RAM-only scrub; no replay key or staged copy survives, and no keydrop transaction churns NVS.
    fresh();
    detLogSetEnabled(false);
    const uint32_t pinnedSessionErase = detLogSensitiveErasePending();
    check("disabled authenticated session reuses the existing durable privacy token",
          detLogPrepareConfigSession() && detLogSensitiveErasePending() == pinnedSessionErase);
    detLogSetKey(sameKey, true);
    detLogEndConfigSession();
    const uint32_t cdgenAfterFirstSession = savedUInt("cdgen");
    check("ending disabled replay session scrubs RAM without retiring its boot token",
          !detLogHaveKey() && detLogSensitiveErasePending() == pinnedSessionErase);
    check("second disabled session reuses the same boot-pinned generation",
          detLogPrepareConfigSession());
    detLogSetKey(sameKey, true);
    detLogEndConfigSession();
    check("reconnect churn neither retains key nor advances coredump generation",
          !detLogHaveKey() && detLogSensitiveErasePending() == pinnedSessionErase &&
          savedUInt("cdgen") == cdgenAfterFirstSession);

    // The service's latest key result is replay authorization, not a cleanup latch. If KA was
    // accepted while buffering is off and a later KB offer mismatches the retained generation,
    // unconditional session teardown must still scrub KA without touching rows/fingerprint.
    fresh();
    detLogAppend(detection(1));
    detLogSetEnabled(false);
    const std::vector<uint8_t> acceptedThenMismatchFp = savedBlob("keyfp");
    check("disabled session accepts the retained generation key before mismatch",
          detLogPrepareConfigSession() &&
          detLogSetKey(sameKey) == DET_LOG_KEY_ACCEPTED && detLogHaveKey());
    check("later different key is a non-destructive session mismatch",
          detLogSetKey(otherKey) == DET_LOG_KEY_MISMATCH && detLogCount() == 1);
    detLogEndConfigSession();
    check("accepted-then-mismatched disabled session scrubs RAM but preserves evidence identity",
          !detLogHaveKey() && detLogCount() == 1 &&
          savedBlob("keyfp") == acceptedThenMismatchFp);

    // If enable persistence is pending, its staged key is configuration, not an ephemeral replay
    // key. Disconnect must preserve it; loop commits key/fp before on=true and reboot reloads it.
    fresh();
    detLogSetEnabled(false);
    Preferences::failNextPutBool("acab-buf", "on");
    detLogSetEnabled(true);
    detLogSetKey(sameKey);
    detLogEndConfigSession();
    detLogEraseTick();
    check("disconnect preserves staged key owned by a pending enable transition",
          detLogEnabled() && detLogHaveKey() && savedBool("on") && savedKeyExists("key"));
    detLogHostResetRuntime();
    detLogBegin();
    check("pending-enable key ordering survives reboot without resurrecting an old key",
          detLogEnabled() && detLogHaveKey());

    // Mandatory disable cleanup cannot be canceled by a newer enable/bufall/key handshake. Preserve
    // the later intents, finish residual-key removal first, then commit key -> enable -> bufall.
    fresh();
    Preferences::failNextRemove("acab-buf", "key", 2);
    detLogSetEnabled(false);                       // first cleanup removal fails
    detLogSetEnabled(true);                        // second coordinator removal fails
    detLogSetKey(sameKey);                         // staged behind mandatory cleanup
    detLogSetBufferAll(true);                      // staged behind cleanup/enable
    detLogEndConfigSession();                      // must preserve enable-owned staged state
    detLogEraseTick();
    check("disable cleanup orders newer key/enable/bufall intents without losing them",
          detLogEnabled() && detLogHaveKey() && detLogBufferAll() &&
          savedBool("on") && savedBool("bufall") && savedKeyExists("key"));

    // Conversely, power loss before a queued re-enable completes may lose that newer RAM intent,
    // but the committed off cleanup must never let the residual old key resurrect.
    fresh();
    Preferences::failNextRemove("acab-buf", "key", 2);
    detLogSetEnabled(false);
    detLogSetEnabled(true);
    detLogHostResetRuntime();
    detLogBegin();
    detLogEraseTick();
    check("immediate reboot during disable/re-enable cleanup never reloads residual key",
          !detLogHaveKey() && !savedKeyExists("key") && !savedBool("on"));

    // A clear requested during failed startup is durable immediately through wipegen, before the
    // loop knows the retained boot counter. Reboot-before-tick must skip the old row, then advance
    // the boot monotonically and finish the sweep.
    fresh();
    detLogAppend(detection(1));
    seedUInt("boot", 77);
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);
    detLogBegin();
    detLogClear();
    check("startup-deferred clear persists immediate generation condemnation",
          savedUInt("boot") == 77 && savedUInt("wipegen") != 0);
    detLogHostResetRuntime();
    detLogBegin();
    check("reboot before deferred-clear tick never scans the condemned row",
          detLogWipePending() && detLogCount() == 0 && savedUInt("boot") > 77);
    detLogEraseTick();

    // A startup-deferred clear whose immediate tombstone transaction cannot even open has only a
    // conservative RAM block, not a durable resumed-wipe generation. Startup must not mistake that
    // block for a partially retired wipe and reuse the old loggen/cryptdom. The later arm mints a
    // fresh generation, so even an old cursor below the new head rebases to seq 1.
    fresh();
    appendRange(1, 110);
    const uint32_t generationBeforeFailedDeferredTombstone = detLogGeneration();
    detLogHostResetRuntime();
    Preferences::failNthBegin(5);                 // startup config transaction
    detLogBegin();
    Preferences::failNthBegin(2);                 // cdwipe lands; ring tombstone begin fails
    detLogClear();
    check("failed startup-clear tombstone does not fabricate a durable target",
          savedUInt("wipegen") == 0 &&
          savedUInt("loggen") == generationBeforeFailedDeferredTombstone);
    detLogEraseTick();
    const uint32_t generationAfterFailedDeferredTombstone = detLogGeneration();
    appendRange(1, 110);
    detLogStartDrain(100, generationBeforeFailedDeferredTombstone);
    check("startup-clear retry mints a fresh generation and stale cursor rebases",
          generationAfterFailedDeferredTombstone != 0 &&
          generationAfterFailedDeferredTombstone != generationBeforeFailedDeferredTombstone &&
          detLogDrainFrom() == 1 && detLogPendingDrain() == 110);

    // Nonce derivation itself is a fail-closed crypto boundary. A hash failure must neither write a
    // zero/partial nonce record nor consume a replay cursor; retry with healthy SHA returns the row.
    fresh();
    const uint32_t writesBeforeNonceHashFailure = acabHostWriteCalls;
    acabHostMdFailures = 1;
    const DetLogAppendResult nonceHashAppend = detLogAppend(detection(1));
    check("nonce hash failure refuses append before any raw flash write",
          nonceHashAppend == DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0 &&
          acabHostWriteCalls == writesBeforeNonceHashFailure &&
          (detLogFaults() & DET_LOG_FAULT_CRYPTO) &&
          !(detLogFaults() & DET_LOG_FAULT_NVS));
    check("latched crypto fault blocks later append until physical clear",
          detLogAppend(detection(1)) == DET_LOG_APPEND_NOT_ARMED && detLogCount() == 0);
    detLogClear();
    detLogEraseTick();
    check("physical clear retires the crypto fault before healthy capture",
          detLogFaults() == DET_LOG_FAULT_NONE &&
          detLogAppend(detection(1)) == DET_LOG_APPEND_STORED);
    detLogStartDrain(0);
    acabHostMdFailures = 1;
    DetLogReplay nonceHashReplay;
    check("nonce hash failure exposes no replay and consumes no row",
          !detLogPeekForDrain(&nonceHashReplay) && detLogCount() == 1 &&
          (detLogFaults() & DET_LOG_FAULT_CRYPTO));
    detLogStartDrain(0);
    check("healthy nonce retry decrypts the untouched first row",
          detLogPeekForDrain(&nonceHashReplay) && nonceHashReplay.seq == 1);

    // Current-format rows without their 128-bit nonce domain cannot be guessed. Startup condemns
    // them and persists a fresh generation/domain before any key can append or replay.
    fresh();
    detLogAppend(detection(1));
    const std::vector<uint8_t> cryptoDomainBeforeLoss = savedBlob("cryptdom");
    removeSaved("cryptdom");
    detLogHostResetRuntime();
    detLogBegin();
    check("missing current-format cryptdom condemns rows before random repair",
          detLogWipePending() && detLogCount() == 0 && savedBlob("cryptdom").size() == 16 &&
          savedBlob("cryptdom") != cryptoDomainBeforeLoss);

    // Metadata recovery commits wipegen/wipecdom/wipe before the boot-counter publication. If that
    // later put fails, the same runtime must treat the durable tombstone as authoritative on retry;
    // it may not see now-valid metadata, skip recovery, and expose the old raw row under it.
    fresh();
    detLogAppend(detection(1));
    removeSaved("cryptdom");
    detLogHostResetRuntime();
    Preferences::failNextPutUInt("acab-buf", "boot");
    detLogBegin();
    check("partial metadata recovery leaves a durable wipe intent despite boot-put failure",
          savedUInt("wipegen") != 0 && savedBool("wipe") && detLogCount() == 1);
    acabHostFailErases = 1;      // hold the recovered logical boundary for inspection this runtime
    detLogEraseTick();
    const uint32_t writesBeforeAuthoritativeRecoveryAppend = acabHostWriteCalls;
    detLogStartDrain(0);
    check("same-runtime retry publishes durable recovery intent before erase",
          detLogWipePending() && detLogCount() == 0 && !detLogDraining() &&
          detLogAppend(detection(2)) == DET_LOG_APPEND_NOT_ARMED &&
          acabHostWriteCalls == writesBeforeAuthoritativeRecoveryAppend);

    // An unavailable raw partition is UNKNOWN, never an empty-ring proof. Metadata repair, clear,
    // and key rotation must leave a durable wipe target that a later mount physically sweeps before
    // any old format-2 row can be scanned under replacement identity.
    fresh();
    detLogAppend(detection(1));
    const std::vector<uint8_t> unavailableOldDomain = savedBlob("cryptdom");
    removeSaved("cryptdom");
    detLogHostResetRuntime();
    acabHostPartitionAvailable = false;
    detLogBegin();
    check("missing cryptdom with unavailable storage arms durable condemnation",
          detLogWipePending() && savedBool("wipe") && savedUInt("wipegen") != 0 &&
          savedBlob("cryptdom").size() == 16 && savedBlob("cryptdom") != unavailableOldDomain &&
          (detLogFaults() & DET_LOG_FAULT_READ));
    detLogHostResetRuntime();
    acabHostPartitionAvailable = true;
    const uint32_t readsBeforeUnavailableRepairSweep = acabHostReadCalls;
    detLogBegin();
    detLogStartDrain(0);
    check("returned partition skips old-row scan until metadata-repair wipe",
          detLogWipePending() && detLogCount() == 0 && !detLogDraining() &&
          acabHostReadCalls == readsBeforeUnavailableRepairSweep);
    detLogEraseTick();
    check("returned partition physically retires metadata-repair rows",
          !detLogWipePending() && acabHostPartitionAllErased() &&
          detLogFaults() == DET_LOG_FAULT_NONE);

    fresh();
    detLogAppend(detection(1));
    const uint32_t generationBeforeUnavailableClear = detLogGeneration();
    detLogHostResetRuntime();
    acabHostPartitionAvailable = false;
    detLogBegin();
    detLogClear();
    check("clearlog with unavailable storage durably condemns possible rows",
          detLogWipePending() && savedBool("wipe") && savedUInt("wipegen") != 0 &&
          detLogGeneration() != generationBeforeUnavailableClear);
    detLogHostResetRuntime();
    acabHostPartitionAvailable = true;
    detLogBegin();
    check("returned partition cannot replay rows from unavailable-storage clear",
          detLogWipePending() && detLogCount() == 0);
    detLogEraseTick();
    check("unavailable-storage clear completes only after physical sweep",
          !detLogWipePending() && acabHostPartitionAllErased());

    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    acabHostPartitionAvailable = false;
    detLogBegin();
    Preferences::failNthBegin(2);                 // cdwipe lands; first full wipe-arm open fails
    detLogClear();
    check("unavailable-storage clear with failed first arm stays blocked in RAM",
          detLogWipePending() && savedUInt("wipegen") == 0 && detLogCount() == 0);
    detLogEraseTick();
    check("metadata-only tick retries unavailable-storage wipe arm durably",
          detLogWipePending() && savedBool("wipe") && savedUInt("wipegen") != 0);
    detLogHostResetRuntime();
    acabHostPartitionAvailable = true;
    detLogBegin();
    check("reboot after metadata-only retry skips the returned raw rows",
          detLogWipePending() && detLogCount() == 0);
    detLogEraseTick();
    check("retried unavailable-storage clear resets the latched mount fault after sweep",
          !detLogWipePending() && detLogFaults() == DET_LOG_FAULT_NONE &&
          acabHostPartitionAllErased());

    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    acabHostPartition.size = 2048;                 // present, but no complete erase sector
    detLogBegin();
    check("too-small raw partition latches the same persistent storage fault",
          (detLogFaults() & DET_LOG_FAULT_READ) && detLogCount() == 0);
    acabHostPartition.size = acabHostFlash.size();
    detLogClear();
    detLogHostResetRuntime();
    detLogBegin();
    detLogEraseTick();
    check("physical clear after valid remount retires too-small-partition fault",
          !detLogWipePending() && detLogFaults() == DET_LOG_FAULT_NONE &&
          acabHostPartitionAllErased());

    fresh();
    detLogAppend(detection(1));
    detLogHostResetRuntime();
    acabHostPartitionAvailable = false;
    detLogBegin();
    const std::vector<uint8_t> unavailableOldKey = savedBlob("key");
    const DetLogKeyResult unavailableKeyResult = detLogSetKey(otherKey, true);
    check("unavailable raw storage cannot confirm or stage an offered replacement key",
          unavailableKeyResult == DET_LOG_KEY_PENDING &&
          savedBlob("key") == unavailableOldKey);
    detLogHostResetRuntime();
    acabHostPartitionAvailable = true;
    detLogBegin();
    check("returned partition still preserves the old-key generation for explicit disposition",
          detLogCount() == 1 && savedBlob("key") == unavailableOldKey);
    detLogClear();
    check("explicit clear authorizes the replacement after raw geometry is known",
          detLogSetKey(otherKey, true) == DET_LOG_KEY_ACCEPTED &&
          detLogWipePending() && detLogCount() == 0);
    detLogEraseTick();
    check("replacement key survives explicit unavailable-partition wipe retirement",
          !detLogWipePending() && detLogEnabled() && detLogHaveKey());
    check("explicit replacement capture resumes after unavailable storage is swept",
          detLogAppend(detection(2)) == DET_LOG_APPEND_STORED && detLogCount() == 1);

    // Fingerprint failures reject the incoming key without changing either retained half. Missing
    // identity with rows, and missing identity plus a failed raw scan, both force a full wipe before
    // a replacement key can ever expose old ciphertext.
    fresh();
    const std::vector<uint8_t> beforeHashFailureKey = savedBlob("key");
    const std::vector<uint8_t> beforeHashFailureFp = savedBlob("keyfp");
    acabHostMdFailures = 1;
    const DetLogKeyResult fingerprintFailureResult = detLogSetKey(otherKey);
    check("key fingerprint failure rejects the new key and preserves retained identity",
          fingerprintFailureResult == DET_LOG_KEY_REJECTED &&
          savedBlob("key") == beforeHashFailureKey && savedBlob("keyfp") == beforeHashFailureFp &&
          (detLogFaults() & DET_LOG_FAULT_CRYPTO) &&
          !(detLogFaults() & DET_LOG_FAULT_NVS));

    fresh();
    detLogAppend(detection(1));
    detLogSetEnabled(false);
    removeSaved("keyfp");
    detLogHostResetRuntime();
    detLogBegin();
    detLogSetKey(sameKey, true);
    check("keyless rows with missing fingerprint are condemned before key publication",
          detLogWipePending() && detLogCount() == 0);

    fresh();
    detLogAppend(detection(1));
    detLogSetEnabled(false);
    removeSaved("keyfp");
    detLogHostResetRuntime();
    acabHostFailReads = 1;
    detLogBegin();
    detLogSetKey(sameKey, true);
    check("missing fingerprint plus untrusted scan geometry also forces durable wipe",
          detLogWipePending());
    detLogHostResetRuntime();
    detLogBegin();
    check("old row cannot reappear under replacement key after scan-read recovery",
          detLogWipePending() && detLogCount() == 0);

    resetHook();
    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
