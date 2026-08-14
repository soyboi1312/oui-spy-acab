#pragma once

// In-memory NOR flash for det_log host tests. Writes may only clear bits, erases
// restore complete sectors to 0xFF, and each operation can be failed or paused by
// the test. This exercises the production det_log.cpp rather than a ring model.
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <mutex>
#include <vector>

typedef int esp_err_t;
static const esp_err_t ESP_OK = 0;
static const esp_err_t ESP_FAIL = -1;
static const int ESP_PARTITION_TYPE_DATA = 1;
static const int ESP_PARTITION_SUBTYPE_ANY = 0;

struct esp_partition_t {
    size_t size;
};

enum AcabHostFlashOp {
    ACAB_HOST_FLASH_READ,
    ACAB_HOST_FLASH_ERASE,
    ACAB_HOST_FLASH_WRITE,
};

typedef void (*AcabHostFlashHook)(AcabHostFlashOp op, size_t offset, size_t size);

inline esp_partition_t acabHostPartition = { 8192 };
inline std::vector<uint8_t> acabHostFlash(8192, 0xFF);
inline std::mutex acabHostFlashMutex;
inline bool acabHostPartitionAvailable = true;
inline uint32_t acabHostFailReads = 0;
inline uint32_t acabHostFailErases = 0;
inline uint32_t acabHostFailWrites = 0;
inline uint32_t acabHostReadCalls = 0;
inline uint32_t acabHostEraseCalls = 0;
inline uint32_t acabHostWriteCalls = 0;
inline AcabHostFlashHook acabHostFlashHook = nullptr;

inline void acabHostPartitionReset(size_t bytes) {
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    acabHostPartition.size = bytes;
    acabHostFlash.assign(bytes, 0xFF);
    acabHostPartitionAvailable = true;
    acabHostFailReads = 0;
    acabHostFailErases = 0;
    acabHostFailWrites = 0;
    acabHostReadCalls = 0;
    acabHostEraseCalls = 0;
    acabHostWriteCalls = 0;
    acabHostFlashHook = nullptr;
}

inline const esp_partition_t* esp_partition_find_first(int, int, const char*) {
    return acabHostPartitionAvailable ? &acabHostPartition : nullptr;
}

inline esp_err_t esp_partition_read(const esp_partition_t*, size_t offset,
                                    void* out, size_t size) {
    AcabHostFlashHook hook = acabHostFlashHook;
    if (hook) hook(ACAB_HOST_FLASH_READ, offset, size);
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    acabHostReadCalls++;
    if (acabHostFailReads) { acabHostFailReads--; return ESP_FAIL; }
    if (!out || offset > acabHostFlash.size() || size > acabHostFlash.size() - offset) return ESP_FAIL;
    memcpy(out, acabHostFlash.data() + offset, size);
    return ESP_OK;
}

inline esp_err_t esp_partition_erase_range(const esp_partition_t*, size_t offset, size_t size) {
    AcabHostFlashHook hook = acabHostFlashHook;
    if (hook) hook(ACAB_HOST_FLASH_ERASE, offset, size);
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    acabHostEraseCalls++;
    if (acabHostFailErases) { acabHostFailErases--; return ESP_FAIL; }
    if ((offset % 4096) != 0 || (size % 4096) != 0 ||
        offset > acabHostFlash.size() || size > acabHostFlash.size() - offset) return ESP_FAIL;
    memset(acabHostFlash.data() + offset, 0xFF, size);
    return ESP_OK;
}

inline esp_err_t esp_partition_write(const esp_partition_t*, size_t offset,
                                     const void* in, size_t size) {
    AcabHostFlashHook hook = acabHostFlashHook;
    if (hook) hook(ACAB_HOST_FLASH_WRITE, offset, size);
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    acabHostWriteCalls++;
    if (acabHostFailWrites) { acabHostFailWrites--; return ESP_FAIL; }
    if (!in || offset > acabHostFlash.size() || size > acabHostFlash.size() - offset) return ESP_FAIL;
    const uint8_t* src = static_cast<const uint8_t*>(in);
    for (size_t i = 0; i < size; i++) {
        if ((uint8_t)(acabHostFlash[offset + i] | src[i]) != acabHostFlash[offset + i]) return ESP_FAIL;
    }
    for (size_t i = 0; i < size; i++) acabHostFlash[offset + i] &= src[i];
    return ESP_OK;
}

inline void acabHostPartitionCorrupt(size_t offset, uint8_t value) {
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    if (offset < acabHostFlash.size()) acabHostFlash[offset] = value;
}

inline bool acabHostPartitionAllErased() {
    std::lock_guard<std::mutex> lock(acabHostFlashMutex);
    for (uint8_t b : acabHostFlash) if (b != 0xFF) return false;
    return true;
}
