/*
 * ACAB - new-phone pairing window (pure decision, no platform deps).
 *
 * A phone that has never bonded may only pair during a short window after power-on. Already-bonded
 * phones reconnect whenever they like; this governs FIRST contact only. Recovery is one sentence:
 * turn the beacon off and on, then connect within two minutes.
 *
 * WHY THIS AND NOT AN OWNERSHIP SCHEME. A QR secret / challenge-response design was considered and
 * rejected: it needs a secret the user can lose, per-device provisioning, and a transfer story when
 * the board changes hands. This costs the user one sentence and the firmware one timestamp, and it
 * closes the actual threat, which is someone in radio range pairing to an unattended board and
 * reading the log.
 *
 * WHY THE DECISION LIVES HERE. The runtime check is a millis() comparison, and millis() ROLLS OVER
 * every ~49.7 days. A naive `millis() < until` reads as OPEN for another 49 days after a rollover,
 * i.e. the security property silently evaporates on a board left running. That is not reproducible
 * on hardware in any practical time, so the comparison is a pure function tested at the boundary
 * instead (test_pair_window.cpp).
 *
 * THE LATCH, AND WHY THE SIGNED COMPARISON IS NOT ENOUGH ON ITS OWN. A signed difference is only
 * correct while the two timestamps are within 2^31 ms (~24.8 days) of each other. A board left
 * powered longer than that would see the difference flip sign and read the window as OPEN AGAIN,
 * silently reopening pairing on exactly the long-running unattended board this feature protects.
 * The host test caught this. So closure is LATCHED: once the window has been observed closed it
 * stays closed until the latch is cleared, and the only thing that clears it is a power cycle,
 * which is already the documented way to reopen the window. The latch makes the arithmetic hazard
 * unreachable, because the accessor runs on every connect and every ~5 s status build, so the latch
 * trips within seconds of expiry rather than 24 days later.
 */
#ifndef ACAB_PAIR_WINDOW_H
#define ACAB_PAIR_WINDOW_H

#include <stdint.h>
#include <stdbool.h>

/// True while a new phone may bond.
///
/// `armed` is false until the board has committed itself ON (a board that boots only to decide it
/// should sleep must never be pairable). The comparison is deliberately SIGNED: casting the
/// difference to int32_t makes "now is past until" correct across the millis() rollover, where an
/// unsigned `now < until` would report the window as open for another ~49 days.
inline bool acabPairWindowOpenAt(uint32_t nowMs, uint32_t untilMs, bool armed, bool latchedClosed) {
    if (!armed || latchedClosed) return false;
    return (int32_t)(nowMs - untilMs) < 0;
}

/// Milliseconds remaining, 0 when closed. Same signed-difference reasoning as above.
inline uint32_t acabPairWindowRemainingAt(uint32_t nowMs, uint32_t untilMs, bool armed,
                                          bool latchedClosed) {
    if (!acabPairWindowOpenAt(nowMs, untilMs, armed, latchedClosed)) return 0;
    return untilMs - nowMs;
}

/// Should this peer be allowed past the connect gate?
///
/// Four inputs, and each rejection reason is a distinct product decision:
///
///   gateEnabled  - does this TARGET enforce at all. Every GATT-serving production target now
///                  enables it (beacon-board from its power-gate signals, mesh-detect from the
///                  reset reason with cellAbsent=true); false remains the pre-feature behaviour
///                  for any build that never arms a window, which must not inherit a rejection
///                  it can never open a window to satisfy.
///   boardHasBond - does the board already have an owner. A board with ZERO bonds pairs freely,
///                  which is the whole out-of-box experience: a unit that shipped weeks ago, or sat
///                  in a drawer, must connect on the customer's first try with no ritual. There is
///                  also nothing to protect yet - an unowned board holds no log worth stealing.
///   known        - is this peer already bonded to the board. Owners reconnect whenever they like;
///                  the window governs FIRST contact only.
///   windowOpen   - the post-power-on window.
///
/// So the ONLY rejection is: an owned board, a stranger, outside the window. That is exactly the
/// threat (someone in radio range pairing to an unattended board that already has a log on it) and
/// nothing else.
inline bool acabPairAdmit(bool gateEnabled, bool boardHasBond, bool known, bool windowOpen) {
    if (!gateEnabled)  return true;   // target does not enforce
    if (!boardHasBond) return true;   // unowned board: first pairing always works
    if (known)         return true;   // the owner, reconnecting
    return windowOpen;                // a stranger: only during the window
}

/// May a connected peer remain on the link while security is still being established?
///
/// Admission is re-evaluated because a stranger can connect during the physical pairing window
/// and then deliberately stall SMP until after it closes. The elapsed-time check is deliberately
/// subtraction based, so it remains correct when millis() rolls over.
inline bool acabPairPreAuthMayContinue(bool gateEnabled, bool boardHadBondAtConnect,
                                       bool knownAtConnect, bool windowOpen,
                                       uint32_t elapsedMs, uint32_t timeoutMs) {
    if (elapsedMs >= timeoutMs) return false;
    return acabPairAdmit(gateEnabled, boardHadBondAtConnect, knownAtConnect, windowOpen);
}

/// May this session arm the legacy nRF bootloader?
///
/// The stock legacy DFU bootloader cannot authenticate an image itself. Firmware can at least
/// require both a secure bonded app session and the short RAM-only window proving a person just
/// power-cycled the board. This is a physical/session gate, not a substitute for migrating the
/// bootloader to signed Secure DFU.
inline bool acabLegacyDfuMayArm(bool secureReady, bool physicalWindowOpen) {
    return secureReady && physicalWindowOpen;
}

/// Was this boot a PHYSICAL start, i.e. did a person just apply power or deliberately switch it on?
///
/// TWO WRONG ANSWERS PRECEDED THIS ONE, and both are worth keeping written down.
///
/// 1. `esp_reset_reason() == ESP_RST_POWERON` ALONE. Soft-off is esp_deep_sleep_start(), so the
///    recovery the apps instruct ("turn the beacon off and on") wakes as ESP_RST_DEEPSLEEP and
///    opened no window at all. The documented fix did not work; only unplugging power did.
///
/// 2. The power gate's own signals alone (committedOn / switchLow / cellAbsent), with the reset
///    reason removed entirely. This looked cleaner and was worse: NEITHER signal can tell a power
///    cycle from a warm reboot. The NVS "committed ON" marker survives loss of power, and a slide
///    switch is still ON after an OTA restart. On a rev-A board that meant `switchLow` was true on
///    EVERY boot, so the window opened after every reflash, panic and OTA - caught on hardware one
///    boot after it shipped into the tree, reading `pairw=108s` right after a flash.
///
/// So the reset reason is NECESSARY but not SUFFICIENT, and this is the combination:
///   powerOnReset  - power was physically applied. Physical on any SKU, whatever the NVS marker
///                   says, because unplug/replug of a board that was ON still reports POWERON.
///   deepSleepWake - the board parked itself and something woke it. Physical ONLY if the user did
///                   it: held the button, or the slide switch reads ON. This is the P1-2 recovery.
///   anything else - ESP_RST_SW (OTA), PANIC, TASK_WDT, BROWNOUT: the board restarted itself while
///                   already running. Nobody touched it, so nothing becomes pairable.
///
/// `cellAbsent` (a USB-only board seeing fresh power) needs no separate case: fresh power IS a
/// POWERON, so it is already covered, and it is kept as an accepted deep-sleep waker for the slim
/// SKU where plugging in is the only "switch" there is.
inline bool acabPhysicalStart(bool powerOnReset, bool deepSleepWake, bool cellAbsent,
                              bool buttonHeld, bool switchLow, bool benchBuild) {
    if (benchBuild)    return true;    // bench boards must stay pairable or bring-up cannot connect
    if (powerOnReset)  return true;    // someone plugged it in / connected the cell
    if (deepSleepWake) return buttonHeld || switchLow || cellAbsent;
    return false;                      // warm restart the user never asked for
}

#endif // ACAB_PAIR_WINDOW_H
