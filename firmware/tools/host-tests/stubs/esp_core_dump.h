#pragma once
// ESP-IDF coredump seam for coredump_report.cpp's fail-closed state machine. Inline state lets
// the test and the separately compiled real source drive the same deterministic API results.
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef int esp_err_t;
static const esp_err_t ESP_OK = 0;
static const esp_err_t ESP_FAIL = -1;
static const esp_err_t ESP_ERR_NOT_FOUND = 0x105;

struct esp_core_dump_summary_t {
    uint32_t exc_pc;
    uint32_t core_dump_version;
    char exc_task[24];
    char app_elf_sha256[65];
};

inline esp_err_t acabHostCoreCheckResult = ESP_ERR_NOT_FOUND;
inline esp_err_t acabHostCoreGetResult = ESP_ERR_NOT_FOUND;
inline esp_err_t acabHostCoreSummaryResult = ESP_FAIL;
inline esp_err_t acabHostCoreEraseResult = ESP_OK;
inline size_t acabHostCoreAddress = 0;
inline size_t acabHostCoreSize = 0;
inline uint32_t acabHostCoreGetCalls = 0;
inline uint32_t acabHostCoreEraseCalls = 0;
inline esp_core_dump_summary_t acabHostCoreSummary{};

inline void acabHostCoreDumpReset() {
    acabHostCoreCheckResult = ESP_ERR_NOT_FOUND;
    acabHostCoreGetResult = ESP_ERR_NOT_FOUND;
    acabHostCoreSummaryResult = ESP_FAIL;
    acabHostCoreEraseResult = ESP_OK;
    acabHostCoreAddress = 0;
    acabHostCoreSize = 0;
    acabHostCoreGetCalls = 0;
    acabHostCoreEraseCalls = 0;
    memset(&acabHostCoreSummary, 0, sizeof(acabHostCoreSummary));
}

inline esp_err_t esp_core_dump_image_check() { return acabHostCoreCheckResult; }
inline esp_err_t esp_core_dump_image_get(size_t* address, size_t* size) {
    acabHostCoreGetCalls++;
    if (address) *address = acabHostCoreAddress;
    if (size) *size = acabHostCoreSize;
    return acabHostCoreGetResult;
}
inline esp_err_t esp_core_dump_get_summary(esp_core_dump_summary_t* out) {
    if (out && acabHostCoreSummaryResult == ESP_OK) *out = acabHostCoreSummary;
    return acabHostCoreSummaryResult;
}
inline esp_err_t esp_core_dump_image_erase() {
    acabHostCoreEraseCalls++;
    return acabHostCoreEraseResult;
}
