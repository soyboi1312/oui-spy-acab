// Host regression tests for the real offline flash ring implementation.
#include "det_log.h"
#include <Arduino.h>
#include <Preferences.h>
#include <esp_partition.h>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

static int failures = 0;
static bool hostBleConnected = false;

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

static void fresh(size_t partitionBytes = 8192) {
    Preferences::wipeAll();
    acabHostPartitionReset(partitionBytes);
    detLogHostResetRuntime();
    hostBleConnected = false;
    acabHostSetMillis(1000);
    detLogBegin();
    uint8_t key[32];
    for (size_t i = 0; i < sizeof(key); i++) key[i] = (uint8_t)(i + 1);
    detLogSetKey(key);
    detLogSetEnabled(true);
}

static void appendRange(uint32_t first, uint32_t last) {
    for (uint32_t n = first; n <= last; n++) detLogAppend(detection(n));
}

static std::vector<uint32_t> drainAll(uint32_t cursor = 0) {
    std::vector<uint32_t> seqs;
    detLogStartDrain(cursor);
    DetLogReplay replay;
    while (detLogNextForDrain(&replay)) seqs.push_back(replay.seq);
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
    DetLogReplay replay;
    check("read failure aborts the drain", !detLogNextForDrain(&replay) && !detLogDraining());
    check("read failure is visible in the fault API", (detLogFaults() & DET_LOG_FAULT_READ) != 0);
    detLogStartDrain(0);
    check("retry does not skip the failed seq", detLogNextForDrain(&replay) && replay.seq == 1);
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
    check("corrupt record aborts instead of being silently skipped", !detLogNextForDrain(&replay));
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

    resetHook();
    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
