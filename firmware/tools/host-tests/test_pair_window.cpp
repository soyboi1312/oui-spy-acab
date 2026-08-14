// Host regression test for the new-phone pairing window (pair_window.h).
//
// The window is a millis() comparison, and millis() ROLLS OVER every ~49.7 days. A naive unsigned
// `now < until` reads as OPEN for another 49 days after a rollover, so the security property would
// silently evaporate on a board left powered. That is untestable on hardware in any practical time,
// which is exactly why the comparison is a pure function and why these boundary cases exist.
#include "../../lib/acab_core/pair_window.h"
#include <cstdio>

static int gFail = 0, gRun = 0;
static void chk(const char* name, bool got, bool want) {
    gRun++; if (got != want) gFail++;
    printf("  %-58s %s\n", name, got == want ? "PASS" : "**FAIL**");
}
static void chkU(const char* name, uint32_t got, uint32_t want) {
    gRun++; if (got != want) gFail++;
    printf("  %-58s %s\n", name, got == want ? "PASS" : "**FAIL**");
    if (got != want) printf("      got %u, wanted %u\n", got, want);
}

int main() {
    printf("\n=== new-phone pairing window ===\n");
    const uint32_t W = 120000;   // ACAB_PAIR_WINDOW_MS

    // Not armed = closed, whatever the clock says. A board that boots only to decide it should
    // sleep must never be pairable, and that is enforced by never arming rather than by timing.
    chk("unarmed is closed even at t=0", acabPairWindowOpenAt(0, W, false, false), false);
    chk("unarmed is closed mid-window",  acabPairWindowOpenAt(1000, W, false, false), false);

    // Ordinary life.
    chk("open immediately after arming",       acabPairWindowOpenAt(0, W, true, false), true);
    chk("open one ms before expiry",           acabPairWindowOpenAt(W - 1, W, true, false), true);
    chk("CLOSED exactly at expiry",            acabPairWindowOpenAt(W, W, true, false), false);
    chk("closed one ms after expiry",          acabPairWindowOpenAt(W + 1, W, true, false), false);
    chk("closed long after expiry",            acabPairWindowOpenAt(W + 86400000UL, W, true, false), false);

    // THE ROLLOVER. Board armed just before millis() wraps: `until` wraps too, so the naive
    // unsigned test would say "now (huge) < until (tiny)" is false -> closed early, and once now
    // wraps it would say open again for 49 days. The signed difference gets both right.
    {
        const uint32_t armAt = 0xFFFFFF00UL;      // ~256 ms before the wrap
        const uint32_t until = armAt + W;          // wraps around to a small number
        chk("armed just before rollover: open right after arming",
            acabPairWindowOpenAt(armAt, until, true, false), true);
        chk("armed just before rollover: open ACROSS the wrap",
            acabPairWindowOpenAt(0x00000100UL, until, true, false), true);
        chk("armed just before rollover: closed after the wrapped expiry",
            acabPairWindowOpenAt(until + 1, until, true, false), false);
        chk("armed just before rollover: still closed much later",
            acabPairWindowOpenAt(until + 3600000UL, until, true, false), false);
    }

    // THE 24-DAY HAZARD, and the latch that closes it. This pair is the reason the latch exists:
    // the first assertion documents that the signed comparison ALONE is wrong past 2^31 ms, and the
    // second proves the latch makes that unreachable. Written as a passing test of the real
    // behaviour rather than a disabled one, so nobody "fixes" the comparison and deletes the latch.
    chk("comparison alone WRONGLY reads open ~24 days past expiry (why the latch exists)",
        acabPairWindowOpenAt(0x80000000UL + 1000, 1000, true, false), true);
    chk("latched closed -> stays closed ~24 days past expiry",
        acabPairWindowOpenAt(0x80000000UL + 1000, 1000, true, true), false);
    chk("latched closed -> closed even mid-window",
        acabPairWindowOpenAt(1000, W, true, true), false);

    // Remaining time, including that it is 0 rather than a huge number once closed.
    chkU("remaining at arming is the full window", acabPairWindowRemainingAt(0, W, true, false), W);
    chkU("remaining halfway",                      acabPairWindowRemainingAt(W / 2, W, true, false), W / 2);
    chkU("remaining at expiry is 0",               acabPairWindowRemainingAt(W, W, true, false), 0);
    chkU("remaining past expiry is 0, not huge",   acabPairWindowRemainingAt(W + 5000, W, true, false), 0);
    chkU("remaining when unarmed is 0",            acabPairWindowRemainingAt(0, W, false, false), 0);

    // ---- admission decision (acabPairAdmit) --------------------------------------------------
    printf("\n  -- connect-gate admission --\n");
    // The ONLY rejection there is. Every other combination admits.
    chk("owned board + stranger + window closed -> REJECT",
        acabPairAdmit(true, true, false, false), false);
    chk("owned board + stranger + window OPEN -> admit",
        acabPairAdmit(true, true, false, true), true);
    // The owner, always. This is the property that means an existing user never has to re-pair.
    chk("owned board + the owner + window closed -> admit",
        acabPairAdmit(true, true, true, false), true);
    // Out of the box: a unit that shipped weeks ago must connect on the first try, no ritual.
    chk("UNOWNED board + new phone + window closed -> admit (out-of-box)",
        acabPairAdmit(true, false, false, false), true);
    chk("UNOWNED board + new phone + window open -> admit",
        acabPairAdmit(true, false, false, true), true);
    // A target that never arms a window (mesh-detect) keeps its pre-feature behaviour. Without
    // this it would inherit the rejection with no way to ever open a window: permanently unpairable.
    chk("gate disabled (mesh-detect) + stranger + closed -> admit",
        acabPairAdmit(false, true, false, false), true);
    chk("gate disabled + unowned + closed -> admit",
        acabPairAdmit(false, false, false, false), true);

    // A raw GAP link is not an authenticated app session. A stranger admitted while the physical
    // window is open must finish encrypted bonding before either the window or the auth deadline
    // closes. Otherwise it could keep a pre-auth link alive indefinitely and suppress offline
    // logging without ever proving possession of a bond.
    printf("\n  -- pre-auth link --\n");
    chk("stranger may authenticate while physical window remains open",
        acabPairPreAuthMayContinue(true, true, false, true, 1000, 30000), true);
    chk("stranger is dropped when physical window closes before auth",
        acabPairPreAuthMayContinue(true, true, false, false, 1000, 30000), false);
    chk("known owner may authenticate after physical window closes",
        acabPairPreAuthMayContinue(true, true, true, false, 1000, 30000), true);
    chk("unowned first pairing is not tied to a physical window",
        acabPairPreAuthMayContinue(true, false, false, false, 1000, 30000), true);
    chk("every pre-auth link is dropped at the timeout boundary",
        acabPairPreAuthMayContinue(false, false, false, false, 30000, 30000), false);
    chk("elapsed subtraction remains valid across millis rollover",
        acabPairPreAuthMayContinue(true, true, true, false,
                                   (uint32_t)(0x00000010UL - 0xfffffff0UL), 30000), true);

    printf("\n  -- legacy nRF DFU physical/session gate --\n");
    chk("secure session during physical window may arm DFU",
        acabLegacyDfuMayArm(true, true), true);
    chk("pre-auth link cannot arm DFU",
        acabLegacyDfuMayArm(false, true), false);
    chk("remote session outside physical window cannot arm DFU",
        acabLegacyDfuMayArm(true, false), false);

    // ---- physical start (boot sequencing) -----------------------------------------------------
    // Args: (powerOnReset, deepSleepWake, cellAbsent, buttonHeld, switchLow, benchBuild)
    printf("\n  -- physical start --\n");

    // Power physically applied. True on any SKU regardless of what the switch or the NVS marker
    // says, because unplug/replug of a board that was ON still reports POWERON.
    chk("POWERON -> physical", acabPhysicalStart(true, false, false, false, false, false), true);
    chk("POWERON with the switch also on -> physical",
        acabPhysicalStart(true, false, false, false, true, false), true);

    // THE REGRESSION HARDWARE CAUGHT. A reflash / OTA / panic is neither POWERON nor a deep-sleep
    // wake, and on rev-A the slide switch still reads ON. Before the reset reason came back as an
    // input, switchLow alone made this true and the window opened after every flash (pairw=108s
    // observed on the board). It must be FALSE.
    chk("warm restart (OTA/panic/WDT) with the switch still ON -> NOT physical",
        acabPhysicalStart(false, false, false, false, true, false), false);
    chk("warm restart on a USB-only board (cellAbsent still true) -> NOT physical",
        acabPhysicalStart(false, false, true, false, false, false), false);
    chk("warm restart, nothing asserted -> NOT physical",
        acabPhysicalStart(false, false, false, false, false, false), false);

    // THE P1-2 CASE. Soft-off is deep sleep, so button-off then button-on wakes as
    // ESP_RST_DEEPSLEEP. The reset-reason-only version called that a warm boot and opened no
    // window, which meant the recovery the apps instruct did not work.
    chk("deep-sleep wake + button held -> physical (the documented recovery)",
        acabPhysicalStart(false, true, false, true, false, false), true);
    chk("deep-sleep wake + switch ON -> physical",
        acabPhysicalStart(false, true, false, false, true, false), true);
    chk("deep-sleep wake + USB-only board seeing power -> physical",
        acabPhysicalStart(false, true, true, false, false, false), true);
    // A wake nobody asked for (a stray ext0 bump with nothing held) must NOT arm.
    chk("deep-sleep wake with nothing held -> NOT physical",
        acabPhysicalStart(false, true, false, false, false, false), false);

    // Bench builds skip the power gate entirely; they must stay pairable or bring-up cannot connect.
    chk("bench build -> physical even on a warm restart",
        acabPhysicalStart(false, false, false, false, false, true), true);

    // ---- warm-boot enforcement (the P1-1 regression) -------------------------------------------
    printf("\n  -- warm boot: enforced but closed --\n");
    // The state a warm reboot now produces: gate ENABLED, window CLOSED. Enforcement used to be
    // switched on only inside the window opener, so this combination was unreachable and every
    // warm boot admitted any phone indefinitely.
    chk("warm boot: enabled + owned + stranger + closed -> REJECT",
        acabPairAdmit(true, true, false, false), false);
    chk("warm boot: the owner still reconnects",
        acabPairAdmit(true, true, true, false), true);
    // And the opt-in property stays load-bearing: a target that enables neither is unaffected.
    chk("mesh target (gate never enabled) -> admitted regardless of window",
        acabPairAdmit(false, true, false, false), true);

    printf(gFail ? "\n  REGRESSION DETECTED (%d of %d)\n\n" : "\n  all good (0 failures of %d)\n\n",
           gFail ? gFail : gRun, gFail ? gRun : 0);
    return gFail ? 1 : 0;
}
