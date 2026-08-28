#include <cstdio>
#include "gps_age.h"

static int failures = 0;

static void check(const char* label, bool ok) {
    std::printf("  %-68s %s\n", label, ok ? "PASS" : "**FAIL**");
    if (!ok) failures++;
}

int main() {
    std::printf("\n=== monotonic phone-GPS age regression ===\n");

    uint32_t age = 0;
    const uint64_t fix = 5'000'000u;
    check("a young fix reports its exact millisecond age",
          acabGpsAgeMs(fix + 12'345'000u, fix, 20'000u, &age) && age == 12'345u);
    check("a fix past a finite privacy bound is rejected",
          !acabGpsAgeMs(fix + 20'001'000u, fix, 20'000u, &age));

    // The old uint32 millis subtraction returned 60,000 here: exactly one full wrap disappeared
    // from the subtraction and a ~49.7-day-old retained location became fresh again.
    const uint64_t oneMillisWrapUs = (uint64_t{1} << 32) * 1000u;
    check("one full millis wrap can never revive a retained fix",
          !acabGpsAgeMs(fix + oneMillisWrapUs + 60'000'000u, fix,
                        0xFFFFu * 1000u, &age));

    check("the any-age contract saturates instead of wrapping its uint32 output",
          acabGpsAgeMs(fix + oneMillisWrapUs + 60'000'000u, fix, 0xFFFFFFFFu, &age) &&
              age == 0xFFFFFFFFu);
    check("a reversed monotonic clock is rejected",
          !acabGpsAgeMs(fix - 1u, fix, 0xFFFFFFFFu, &age));

    std::printf("\n%d failure(s)\n", failures);
    return failures ? 1 : 0;
}
