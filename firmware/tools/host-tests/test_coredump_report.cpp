// Host regression tests for the real retained-coredump probe/erase state machine.
#include "coredump_report.h"
#include <Arduino.h>
#include <esp_core_dump.h>
#include <cstdio>

static int failures = 0;
static uint32_t pendingGeneration = 0;
static uint32_t completedGeneration = 0;
static bool ringWipePending = false;

// Link seams consumed by coredump_report.cpp. The det_log token's own persistence behavior is
// covered by test_det_log.cpp; this suite proves the physical consumer never acknowledges an
// unreadable or failed erase.
uint32_t detLogSensitiveErasePending() { return pendingGeneration; }
void detLogSensitiveEraseComplete(uint32_t generation) {
    completedGeneration = generation;
    if (pendingGeneration == generation) pendingGeneration = 0;
}
bool detLogWipePending() { return ringWipePending; }

static void check(const char* label, bool ok) {
    std::printf("  %-72s %s\n", label, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
}

static void resetCase() {
    acabHostCoreDumpReset();
    acabHostSetMillis(1000);
    pendingGeneration = 0;
    completedGeneration = 0;
    ringWipePending = false;
}

int main() {
    std::printf("coredump_report host tests\n");

    resetCase();
    acabCoredumpProbe();
    const AcabCoredumpInfo& empty = acabCoredumpInfo();
    check("ESP_ERR_NOT_FOUND is the one positively empty state",
          !empty.present && !empty.corrupt && acabHostCoreGetCalls == 0);
    check("positively empty erase is a no-op success",
          acabCoredumpErase() && acabHostCoreEraseCalls == 0);

    resetCase();
    acabHostCoreCheckResult = ESP_OK;
    acabHostCoreGetResult = ESP_FAIL;
    acabCoredumpProbe();
    check("metadata access failure remains erase-required",
          !acabCoredumpInfo().present && acabCoredumpInfo().corrupt);
    acabHostCoreEraseResult = ESP_FAIL;
    check("failed erase leaves unreadable state intact",
          !acabCoredumpErase() && acabCoredumpInfo().corrupt && acabHostCoreEraseCalls == 1);
    acabHostCoreEraseResult = ESP_OK;
    check("successful erase clears the unreadable cache",
          acabCoredumpErase() && !acabCoredumpInfo().present && !acabCoredumpInfo().corrupt);

    resetCase();
    acabHostCoreCheckResult = ESP_OK;
    acabHostCoreGetResult = ESP_OK;
    acabHostCoreSize = 0;
    acabCoredumpProbe();
    check("zero-size metadata is not mistaken for an empty partition",
          !acabCoredumpInfo().present && acabCoredumpInfo().corrupt);

    resetCase();
    acabHostCoreCheckResult = ESP_FAIL;
    acabHostCoreGetResult = ESP_FAIL;
    acabCoredumpProbe();
    check("integrity-check failure plus unreadable metadata remains erase-required",
          !acabCoredumpInfo().present && acabCoredumpInfo().corrupt);

    resetCase();
    acabHostCoreCheckResult = ESP_OK;
    acabHostCoreGetResult = ESP_OK;
    acabHostCoreSize = 4096;
    acabHostCoreSummaryResult = ESP_OK;
    acabHostCoreSummary.exc_pc = 0x12345678;
    acabHostCoreSummary.core_dump_version = 7;
    acabCoredumpProbe();
    check("valid nonempty image remains reportable",
          acabCoredumpInfo().present && !acabCoredumpInfo().corrupt &&
          acabCoredumpInfo().sizeBytes == 4096 && acabCoredumpInfo().pc == 0x12345678);

    // Explicit wipe completion is the security boundary: a failed erase must leave the durable
    // token untouched. A newer generation may retry immediately without rebooting.
    pendingGeneration = 101;
    acabHostCoreEraseResult = ESP_FAIL;
    acabCoredumpWipeTick();
    check("failed explicit erase retains its generation",
          pendingGeneration == 101 && completedGeneration == 0);
    pendingGeneration = 102;
    acabHostCoreEraseResult = ESP_OK;
    acabCoredumpWipeTick();
    check("successful erase acknowledges only the generation it handled",
          pendingGeneration == 0 && completedGeneration == 102 &&
          !acabCoredumpInfo().present && !acabCoredumpInfo().corrupt);

    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
