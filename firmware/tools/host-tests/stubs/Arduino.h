#pragma once
// Minimal Arduino.h stub so the WiFi-side classifiers compile on the host.
//
// WHY THIS EXISTS: netcam_detect.cpp and drone_detect.cpp include <Arduino.h>. On the ESP32 that
// header drags in the whole core (clock, FreeRTOS, the radio). On a laptop we only need the two
// things those two translation units actually touch: millis() and the portMUX critical section.
// Everything here is deliberately the SMALLEST surface that lets them build - if a classifier
// starts needing more Arduino, add it here rather than weakening the test.
//
// Kept in sync by construction: the harness compiles the real _detect.cpp against this header, so
// if the firmware grows a new Arduino dependency the host build breaks loudly instead of silently
// diverging from the board.
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ---------------------------------------------------------------------------
// Deterministic clock
// ---------------------------------------------------------------------------
// millis() is NEVER the wall clock here. drone_detect.cpp uses millis() for its sighting-dedup
// window, so a real clock would make dedup tests flaky: the same test would pass or fail depending
// on how long the machine took to get to the assertion. Instead the counter is a plain variable
// that the test drives, which makes "advance 4 seconds" an exact, repeatable operation.
//
// C++17 inline variable, so multiple translation units share ONE counter without anyone having to
// provide a definition in a .cpp. The test and the classifier under test therefore agree on time.
inline uint32_t acabHostMillisCounter = 0;

inline uint32_t millis() { return acabHostMillisCounter; }
inline uint32_t micros() { return acabHostMillisCounter * 1000u; }

// Test-side controls. Use these, never a sleep.
inline void acabHostSetMillis(uint32_t ms)     { acabHostMillisCounter = ms; }
inline void acabHostAdvanceMillis(uint32_t ms) { acabHostMillisCounter += ms; }

// delay() must not actually sleep: host tests are meant to run in well under a second, and a real
// sleep would also fail to move millis(), which is the opposite of what a caller expects.
inline void delay(uint32_t ms)                 { acabHostMillisCounter += ms; }

// Minimal serial sink for target modules whose behavior is host-testable but whose error path
// also reports to the console. Tests assert state, not log text; forwarding keeps diagnostics
// visible when a case fails without modeling Arduino Stream/String.
struct AcabHostSerialSink {
    template <typename... Args>
    int printf(const char* format, Args... args) { return ::printf(format, args...); }
    void println(const char* line) { ::printf("%s\n", line ? line : ""); }
};
inline AcabHostSerialSink Serial;

// ---------------------------------------------------------------------------
// GPIO + LEDC output spies
// ---------------------------------------------------------------------------
// alerts.cpp is host-tested against its real tone implementation. A tone is audible only after a
// nonzero PWM duty write, so count those separately from the terminal ledcWrite(..., 0) that every
// cue uses to stop. GPIO LOW is the beacon board's inverted onboard-LED "on" level.
#define LOW 0
#define HIGH 1
#define OUTPUT 1

inline uint32_t acabHostNonzeroPwmWrites = 0;
inline uint32_t acabHostLedLowWrites = 0;
inline uint32_t acabHostLedHighWrites = 0;
inline uint32_t acabHostLastPwmDuty = 0;

inline void acabHostResetOutputs() {
    acabHostNonzeroPwmWrites = 0;
    acabHostLedLowWrites = 0;
    acabHostLedHighWrites = 0;
    acabHostLastPwmDuty = 0;
}

inline void pinMode(uint8_t, uint8_t) {}
inline void digitalWrite(uint8_t, uint8_t value) {
    if (value == LOW) acabHostLedLowWrites++;
    else acabHostLedHighWrites++;
}
inline double ledcSetup(uint8_t, double frequency, uint8_t) { return frequency; }
inline void ledcAttachPin(uint8_t, uint8_t) {}
inline double ledcWriteTone(uint8_t, double frequency) { return frequency; }
inline void ledcWrite(uint8_t, uint32_t duty) {
    acabHostLastPwmDuty = duty;
    if (duty != 0) acabHostNonzeroPwmWrites++;
}

// ---------------------------------------------------------------------------
// FreeRTOS critical sections
// ---------------------------------------------------------------------------
// drone_detect.cpp guards its shared sighting table with a portMUX spinlock because the BLE and
// WiFi radio tasks both decode Remote ID. Host tests are single-threaded, so the lock is a no-op -
// but it still has to EXIST with the right shape, otherwise the guarded code cannot be compiled at
// all and the dedup logic never gets tested.
typedef struct { uint32_t owner; uint32_t count; } portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED { 0, 0 }

inline void portENTER_CRITICAL(portMUX_TYPE*)      {}
inline void portEXIT_CRITICAL(portMUX_TYPE*)       {}
inline void portENTER_CRITICAL_ISR(portMUX_TYPE*)  {}
inline void portEXIT_CRITICAL_ISR(portMUX_TYPE*)   {}

// ---------------------------------------------------------------------------
// DELIBERATELY ABSENT
// ---------------------------------------------------------------------------
// No min/max/constrain macros. The real Arduino.h defines them as macros, which collide with
// std::min / std::max the moment a test includes <algorithm> or <vector>. Nothing in the
// classifiers uses them, so leaving them out is both minimal and safer.
//
// No String or WiFi. Serial is only the printf/println sink above. The 802.11 unwrapping
// (wifi_promiscuous_pkt_t -> payload
// pointer + rssi) happens in acab_scanner.cpp, which the harness never compiles. Every WiFi-side
// classifier takes a plain (const uint8_t* frame, size_t len, int rssi) instead, so a host test
// hands it a hand-built byte array and no 802.11 driver type is ever required. If that signature
// ever changes, this comment is the thing that should be revisited.
