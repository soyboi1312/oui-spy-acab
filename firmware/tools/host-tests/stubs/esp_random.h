#pragma once
#include <cstdint>

// Deterministic nonzero stand-in for ESP's hardware RNG. It deliberately continues across
// detLogHostResetRuntime(), just as entropy is not restored from the application's RAM image on a
// real reboot. Tests assert only uniqueness/nonzero semantics, never these exact values.
inline uint32_t acabHostRandomZeroCalls = 0;
inline uint32_t acabHostRandomCallsBeforeZero = 0;
inline uint32_t esp_random() {
    if (acabHostRandomZeroCalls && acabHostRandomCallsBeforeZero) {
        acabHostRandomCallsBeforeZero--;
    } else if (acabHostRandomZeroCalls) {
        acabHostRandomZeroCalls--;
        return 0;
    }
    static uint32_t state = 0x6d2b79f5u;
    state ^= state << 13;
    state ^= state >> 17;
    state ^= state << 5;
    return state;
}
