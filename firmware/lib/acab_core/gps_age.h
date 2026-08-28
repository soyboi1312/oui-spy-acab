/*
 * ACAB - monotonic age arithmetic shared by the phone-GPS getters and host tests.
 *
 * `millis()` is a uint32_t and wraps after about 49.7 days. Unsigned subtraction is exactly the
 * right tool for ordinary short deadlines, but it cannot distinguish "one minute old" from
 * "one full wrap plus one minute old". A retained owner location is allowed to live for only
 * DET_LOG_GPS_MAX_AGE_MS, so that ambiguity is a privacy and evidence-integrity bug rather than a
 * harmless timer wrinkle. The BLE service stamps fixes with esp_timer_get_time() instead and uses
 * this helper to keep every comparison in the 64-bit monotonic domain.
 */
#ifndef ACAB_GPS_AGE_H
#define ACAB_GPS_AGE_H

#include <stdint.h>

// Convert a pair of monotonic microsecond stamps to a bounded millisecond age.
//
// `maxAgeMs == 0xFFFFFFFF` means "any age", matching acabBleGetPhoneGps's public contract. The
// output is still uint32_t, so ages beyond its range saturate instead of wrapping back to fresh.
// A reversed clock is rejected; esp_timer is monotonic, so that can only mean corrupt inputs or a
// test harness error and must never manufacture a plausible age.
static inline bool acabGpsAgeMs(uint64_t nowUs, uint64_t fixUs, uint32_t maxAgeMs,
                                uint32_t* ageMs = nullptr) {
    if (nowUs < fixUs) return false;
    const uint64_t elapsedMs = (nowUs - fixUs) / 1000u;
    if (maxAgeMs != 0xFFFFFFFFu && elapsedMs > maxAgeMs) return false;
    if (ageMs) *ageMs = elapsedMs > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)elapsedMs;
    return true;
}

#endif // ACAB_GPS_AGE_H
