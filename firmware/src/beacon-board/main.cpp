/*
 * ACAB - All Cameras Are Beacons
 * OUI-Spy build (Colonel Panic OUI-Spy / XIAO ESP32-S3).
 *
 * App-controlled counter-surveillance scanner. Runs Flock (BLE + WiFi), drone
 * Remote ID, and Axon detection at once; streams every hit to the
 * ACAB iOS app over BLE and beeps a per-class signature.
 *
 * Passive detect-and-report only - no transmit beyond BLE advertising, no
 * jamming, no spoofing.
 */
#include <Arduino.h>
#include "esp_task_wdt.h"   // task watchdog: catch a wedged loop() (both single- and dual-radio)
#include "acab_scanner.h"
#include "coredump_report.h"
#include "pair_window.h"   // acabPhysicalStart: the host-tested rule production must CALL, not restate
#include "axon_detect.h"
#include "police_detect.h"
#include "tracker_detect.h"
#include "glasses_detect.h"
#include "flock_detect.h"
#include "drone_detect.h"
#include "netcam_detect.h"
#include "desert_detect.h"   // desertRestoreEnabled: persisted Desert toggle
#include "acab_ble_service.h"
#include "alerts.h"
#include "det_log.h"
#include "ota_update.h"   // S3 self-update over BLE + boot-attempt rollback
#include "acab_banner.h"
#ifdef ACAB_DUAL_RADIO
#include <Preferences.h>   // board-revision latch (NVS)
#include "esp_sleep.h"    // soft power: the slide switch parks us in deep sleep instead of cutting the cell
#include "driver/rtc_io.h"
// The companion nRF updates itself over BLE DFU (its Adafruit bootloader speaks native Nordic
// OTA); the S3 only forwards the "DFU" trigger over UART. No SWD, no embedded nRF image.
static const int kNrfResetPin = 6;   // S3 D5 -> nRF RESET (soft-power wake; the SWRST access link)
// setup() primes the first advertised BLE status with a battery reading after the operating radio
// load is running. Keep the implementation beside the periodic sampler below; these declarations
// make the startup ordering explicit in this .cpp file (unlike an Arduino .ino, prototypes are
// not generated for us).
static int readBatteryPct();
static bool readBatteryCharging();
// WiFi.mode()/promiscuous startup returns with the radio enabled, but leave one short electrical
// settling interval before the first ADC seed. This is far below the nRF's ~2 s boot time, so it
// does not create a meaningful unpolled-UART window.
static const uint32_t kBatteryStartupSettleMs = 100;
#endif

// Scanner sink: send each detection to the app, the buzzer, and serial.
// In Desert mode the classifiers run regardless of their toggle (so real types still show), but
// the toggle keeps gating whether we ALERT.
// (Motorola/LE-gear OUI hits report as ACAB_AXON_BODYCAM, so the body-cam case
// gates them too - there is no separate police type.)
//
// EVERY DESERT-FORCED CLASSIFIER NEEDS AN ARM HERE. flock, drone, glasses, tracker and axon all
// self-gate with `if (!gEnabled && !desertIsEnabled()) return false;`, so with Desert on they
// emit with their category toggle OFF and this gate is the toggle's only remaining job. Until
// 2026-08-25 the switch covered 3 of the 7 toggle-bearing types, so ACAB_FLOCK_CAMERA /
// ACAB_FLOCK_RAVEN / ACAB_DRONE / ACAB_GLASSES fell through to `default: return true` and a board
// whose owner had switched "ALPR cameras" (or drones, or glasses) off still cawed at every Flock
// camera it passed: exactly the "why is it beeping" failure the netcam note below says this layer
// must not leave to the detector. ACAB_NEARBY_DEVICE and ACAB_WATCHED stay on the default on
// purpose - Desert itself and starring a MAC ARE the opt-in, so there is no separate toggle to
// honour.
static bool alertTypeEnabled(AcabDeviceType t) {
    // A new device class must be considered here, not silently inherit "alert anyway". This trips
    // the build rather than letting the next type ship as a muted-category beep.
    static_assert(ACAB_TYPE_COUNT == 11,
                  "new AcabDeviceType: give it an arm in alertTypeEnabled, or confirm that "
                  "alerting regardless of any toggle is right for it, then bump this count");
    switch (t) {
        case ACAB_TRACKER:      return trackerIsEnabled();
        case ACAB_AXON_BODYCAM: return axonIsEnabled();
        case ACAB_FLOCK_CAMERA:                       // one "ALPR cameras" toggle covers both
        case ACAB_FLOCK_RAVEN:  return flockIsEnabled();
        case ACAB_DRONE:        return droneIsEnabled();
        case ACAB_GLASSES:      return glassesIsEnabled();
        // Network cameras are opt-in like the categories above, so the BUZZER honours the same
        // toggle. The detector self-gates upstream, so nothing should reach here with the opt-in
        // off, but this layer should not depend on that: an alert path that beeps for a category
        // the user switched off is the kind of thing that only shows up as "why is it beeping at
        // my house".
        case ACAB_NETCAM:       return netcamIsEnabled();
        default:                return true;
    }
}

static void onDetection(const AcabDetection& d, bool isNew) {
    acabBleNotifyDetection(d, isNew);
    // Replayed black-box records reach the app but must NOT beep (a silent evidence pull
    // shouldn't fire the piezo for every stored hit) - see AcabDetection::replay.
    if (!d.replay && alertTypeEnabled(d.type)) alertsSignal(d.type, isNew);

    if (isNew) {
        char mac[18];
        acabFormatMac(d.mac, mac);
        Serial.printf("[ACAB] %-16s %-4s %s rssi=%d conf=%d %s%s\n",
                      acabTypeLabel(d.type), acabSourceLabel(d.src), mac,
                      d.rssi, d.confidence,
                      d.name[0] ? d.name : "", d.detail[0] ? d.detail : "");
    }

#ifdef ACAB_BENCH_NO_SLEEP
    // BENCH-ONLY drone-track echo. The operator (pilot) position rides the ODID System message,
    // which arrives on a SEPARATE advert from BasicID/Location and merges into the track over
    // several adverts, so onDetection's isNew line (once per dedup window) usually prints BEFORE
    // haveOp is set. On the bench there is no phone subscribed to read plat/plon over GATT, so we
    // echo the assembled track here on EVERY drone detection: this is how we confirm the System
    // message survived the nRF -> UART -> ESP32 assembly on v2 hardware. Never in a shipped build.
    if (d.type == ACAB_DRONE) {
        Serial.printf("[bench] drone id=\"%s\" pos=%.5f,%.5f OP=%.5f,%.5f opAlt=%d sta=%u\n",
                      d.id[0] ? d.id : "(none)", d.lat, d.lon,
                      d.pilotLat, d.pilotLon, (int)d.pilotAlt, (unsigned)d.ridStatus);
    }
#endif
}

#ifdef ACAB_DUAL_RADIO
// --- Dual-radio (v2 two-board prototype) -----------------------------------
// A companion XIAO nRF52840 scans BLE at full duty and forwards each advert to
// us over UART as ASCII: "A <mac12hex> <rssi> <payloadhex>\n". We re-run the
// normal BLE classifier chain on each one, so all detection logic stays on this
// ESP32-S3, which keeps WiFi + the app GATT. Wiring (v2 board, straightened): nRF
// D6/TX -> our D6 (RX, GPIO43), our D7 (TX, GPIO44) -> nRF D7/RX (the command
// channel: radio toggle, ignore list, black box, and the soft power-off), GND <-> GND.
static int hexNib(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

// The nRF's app version, learned from its "V<n>" line (-1 = not heard yet). Reported to the app
// (status "nrfv") so it can tell whether the co-processor has a BLE DFU update available.
static volatile int gNrfVersion = -1;

// Read the nRF's last-reported app version (-1 until it first announces "V<n>").
int acabNrfVersion() { return gNrfVersion; }

// millis() when a BLE DFU was last triggered (0 = never). During the window after a trigger the
// nRF is rebooting into its bootloader and stops speaking the UART protocol, so co-proc liveness
// legitimately reads false. acabNrfDfuActive() lets the status doc flag that (status "nrfup") so
// the app shows "updating co-processor" instead of the "nRF radio fault" banner. The mute closes
// two ways: event-driven, the instant the nRF reports a fresh "V<n>" version (its new app booted =
// success, so we clear gNrfDfuMs in parseAdvLine and drop the banner immediately instead of letting
// a fast success linger for the full ceiling); or by the 5-min ceiling below, a backstop so a
// legitimately retried DFU never un-mutes mid-flight while the higher-level flow is still working.
static volatile uint32_t gNrfDfuMs = 0;
bool acabNrfDfuActive() { return gNrfDfuMs != 0 && (millis() - gNrfDfuMs) < 300000UL; }  // 5-min ceiling; normally cleared early on version report

static void parseAdvLine(const char* s) {
    if (s[0] == 'V') {                          // nRF app version: "V<n>" (boot banner + 'V' reply)
        // Clamp at the untrusted boundary: this is atoi of whatever the UART delivered, and the
        // real domain is a small monotonic int (NRF_APP_VERSION, currently 2). Anything negative
        // (garbled line) normalizes to -1 = "not heard", which keeps the 2 s re-query below alive
        // and the status "nrfv" emit suppressed, exactly as if the line never arrived; anything
        // past 9999 saturates. The 4-digit cap is what the status budget
        // (test_acab_ble_service.cpp) declares for "nrfv", and the emit site re-caps it too.
        int v = atoi(s + 1);
        gNrfVersion = v < 0 ? -1 : (v > 9999 ? 9999 : v);
        Serial.printf("[nrf] co-processor app version %d\n", gNrfVersion);
        // A fresh version report means the co-processor's new app booted and is speaking again, so
        // any in-flight BLE DFU just succeeded. Close the fault-mute window now (event-driven) so
        // the "detection paused / co-processor updating" banner drops immediately on a fast success
        // instead of lingering until the 5-min ceiling. Only clear the mute timestamp here.
        gNrfDfuMs = 0;
        // The banner means the co-processor just booted, so its scan state and ignore-list mirror
        // are back at defaults (empty). We used to push both exactly once and never again, so
        // every nRF reset - a BLE DFU most of all - silently left it scanning at its default with
        // no ignore list. Re-assert them here; the mirror streams from the loop task, paced.
        acabScannerResyncCoProc();
        return;
    }
    if (s[0] == 'D' && s[1] == ' ') {          // co-processor stats: "D <adv> <fwd> <scan> <bb>"
        char* p = (char*)(s + 2);
        uint32_t adv = strtoul(p, &p, 10);
        uint32_t fwd = strtoul(p, &p, 10);
        int scn = (int)strtol(p, &p, 10);
        // Clamp at the UART boundary, exactly like the "V" line's version above: BB_SLOTS is
        // enforced on the FAR side of this link (nrf-ble-scan's own ring), so the S3 cannot
        // treat it as a bound on what it just read. A garbled or hostile D line would otherwise
        // emit up to 10 digits for "nbb" against the 5-digit width the status budget declares
        // (test_acab_ble_service.cpp), spending spare bytes the budget proves it does not need.
        // 65535 saturates: it is above any real BB_SLOTS value and stays inside 5 digits.
        uint32_t bb = strtoul(p, &p, 10);
        if (bb > 65535) bb = 65535;
        acabScannerSetCoProcStats(adv, fwd, scn != 0, bb);
        return;
    }
    if (s[0] == 'B' && s[1] == ' ') {          // a black-box record the nRF replayed: "B <seq> <ts> <mac> <rssi> <payload>"
        char* p = (char*)(s + 2);
        strtoul(p, &p, 10);                    // skip seq
        strtoul(p, &p, 10);                    // skip ts
        while (*p == ' ') p++;
        uint8_t mac[6];
        for (int i = 0; i < 6; i++) {
            if (!p[0] || !p[1]) return;   // stop at the line's NUL before reading the 2nd nibble (OOB guard: p can reach the terminator here after the seq/ts skips)
            int hi = hexNib(p[0]), lo = hexNib(p[1]);
            if (hi < 0 || lo < 0) return;
            mac[i] = (uint8_t)((hi << 4) | lo); p += 2;
        }
        int rssi = (int)strtol(p, &p, 10);
        while (*p == ' ') p++;
        static uint8_t bpl[64];
        size_t blen = 0;
        while (p[0] && p[1] && blen < sizeof(bpl)) {
            int hi = hexNib(p[0]), lo = hexNib(p[1]);
            if (hi < 0 || lo < 0) break;
            bpl[blen++] = (uint8_t)((hi << 4) | lo); p += 2;
        }
        acabScannerIngestBLE(mac, bpl, blen, rssi, /*isReplay=*/true);   // recover to the app: no beep, no live-table pollution
        return;
    }
    if (s[0] != 'A' || s[1] != ' ') return;   // ignore the nRF's heartbeats / boot noise
    const char* p = s + 2;
    uint8_t mac[6];
    for (int i = 0; i < 6; i++) {
        int hi = hexNib(p[0]), lo = hexNib(p[1]);
        if (hi < 0 || lo < 0) return;
        mac[i] = (uint8_t)((hi << 4) | lo);
        p += 2;
    }
    if (*p++ != ' ') return;
    int rssi = atoi(p);
    while (*p && *p != ' ') p++;
    if (*p++ != ' ') return;
    // 256-byte payload so a BLE 5 extended/coded advert (bucket B1, up to 255 bytes when the
    // nRF is built with ACAB_BLE5_EXT) fits. Harmless when the flag is off - short legacy
    // adverts (<=31 bytes) still land in the same buffer.
    static uint8_t payload[256];
    size_t plen = 0;
    while (p[0] && p[1] && plen < sizeof(payload)) {
        int hi = hexNib(p[0]), lo = hexNib(p[1]);
        if (hi < 0 || lo < 0) break;
        payload[plen++] = (uint8_t)((hi << 4) | lo);
        p += 2;
    }
    acabScannerIngestBLE(mac, payload, plen, rssi);
}

static void uartIngestPoll() {
    // >=600 so a full 255-byte extended advert ("A <mac> <rssi> <510 hex>") fits without an
    // overrun-resync dropping it. Wide enough for legacy lines too, so it costs nothing off.
    static char line[600];
    static int  pos = 0;
    while (Serial1.available()) {
        char c = (char)Serial1.read();
        if (c == '\n' || c == '\r') {
            if (pos > 0) {
                line[pos] = '\0';
                acabScannerNoteCoProcRx();   // ANY nRF line = the co-processor is alive (A1 liveness)
                parseAdvLine(line);
                pos = 0;
            }
        } else if (pos < (int)sizeof(line) - 1) {
            line[pos++] = c;
        } else {
            pos = 0;   // overrun: drop, resync on the next newline
        }
    }
}

// Mirror radio commands (BLE on/off, ignore list) to the nRF over Serial1 TX (D7).
static void nrfCmdSink(const char* line) { Serial1.println(line); }

// Ask the companion nRF to reboot into BLE OTA DFU. It self-updates over the air (its Adafruit
// bootloader speaks native Nordic legacy DFU); we just forward the "DFU" trigger over the UART.
// The nRF stops scanning, flushes, sets GPREGRET, and soft-resets into its bootloader, which then
// advertises for DFU as a SEPARATE device. The app verifies the .zip's sha256 + ECDSA signature
// BEFORE arming (legacy DFU itself is CRC-only), then runs the transfer with a Nordic DFU lib.
// The shared BLE gate also requires this secure session to be inside the physical-start window.
// The app is responsible for pausing auto-reconnect and re-reading "nrfv" once the nRF is back.
static void nrfEnterDfu() {
    Serial.println("[nrf] forwarding DFU trigger -> co-processor reboots into BLE OTA DFU");
    gNrfDfuMs = millis();          // open the "nRF updating" status window (see acabNrfDfuActive)
    // Route through the mutex-protected sink, NOT nrfCmdSink directly. This runs on the loop task
    // while the NimBLE host task may be writing scan/ignore lines to the same Serial1 (the app
    // sends config on connect and on every toggle). A bare Serial1.println here interleaves with
    // those bytes mid-line, so the nRF never parses a clean "DFU\n" and silently stays in the app.
    // That is exactly why it worked when triggered from the USB console (no app, no concurrent
    // writer) but failed over BLE with the app connected. Confirmed on hardware 2026-07-23.
    //
    // Belt-and-suspenders for a marginal 1 Mbaud link: the nRF's handler needs an EXACT "DFU\0"
    // token, so a single corrupted byte makes it silently ignore the line and stay in the app.
    // Send a bare newline first to flush any half-received line out of the nRF's parser, then send
    // "DFU" a few times, spaced so a burst error can't corrupt every copy. The repeats are
    // idempotent: the nRF resets into its bootloader on the first clean copy, and any later copies
    // land in the bootloader (which ignores the UART). Runs off the NimBLE host task (drained from
    // loop()), so the short delays sit on the loop task and are safe.
    acabScannerSendCoProcCmd("");            // flush any partial line in the nRF's RX parser
    for (int i = 0; i < 3; i++) {
        acabScannerSendCoProcCmd("DFU");
        delay(4);                            // decorrelate the copies against UART burst errors
    }
}

// --- Soft power switch ------------------------------------------------------
// The v2 board hard-wires the LiPo to BAT+ (so USB charging works with the unit off)
// and repurposes SW1 as a sense line: common -> D10 (GPIO9, INPUT_PULLUP), other
// throw -> GND. Knob at 'on' = pin LOW = run; at 'off' = pin floats HIGH = we park
// the nRF in System OFF and deep-sleep (~tens of uA total), waking on the pin
// going LOW again. A JST unplug stays the hard disconnect.
static const gpio_num_t kSwSensePin = GPIO_NUM_9;   // XIAO D10 (RTC-capable, non-strapping)

// ---- BOARD REVISION AUTO-DETECT (2026-07-28) -------------------------------------------------
// One firmware image serves BOTH carrier revisions, so the web flasher stays a single button and a
// user can never pick wrong (they do not know which board they own; esp-web-tools only knows the
// chip family, which is ESP32-S3 on both).
//   rev-A (the first 250): SS12D00G4 slide switch, D0/GPIO1 UNCONNECTED.
//   rev-B: EVQ-P7 momentary button, and R3/R4 (100k/100k off the S3's 5V/USB-VBUS castellation)
//          drive D0. That divider is the ONLY electrical difference we can see from firmware, so
//          it is the revision tell.
// PROBE: enable the internal pulldown on D0 and read the ADC. With USB present rev-B's divider
// fights the ~45k pulldown to a steady ~1.2V; an unconnected rev-A pin collapses to ~0 (and if the
// ADC init drops the pulldown, a floating pin reads NOISY, which the stability test below rejects).
// We demand BOTH an in-band mean AND a tight spread, because "floating pin happened to sit in
// range" is the only way this can go wrong.
// LATCH POLICY , deliberately asymmetric: only a POSITIVE rev-B detect is written to NVS, and it is
// permanent. A negative result is NOT latched, because it is ambiguous: a rev-B board booting on
// battery with no USB looks exactly like a rev-A board (the 5V pad floats, R4 pulls the node down).
// So false-negative = transient, self-corrects the first time the unit sees USB (flashing, bring-up
// or any charge); false-positive = permanent, and therefore the case we make hard to reach.
// CONSEQUENCE TO KNOW: a rev-B unit that has NEVER been plugged into USB runs slide semantics, so
// its momentary button reads as "off" and it parks. Every board is USB-flashed at build time, so the
// latch happens in the factory - but if a rev-B board ever acts dead on battery, plug it in once.
// OVERRIDE: -DACAB_FORCE_REV_B=1 (or =0) at build time. THAT IS THE ONLY OVERRIDE.
// This line used to also offer "revb 1" / "revb 0" on USB serial, and there was never a parser for
// it: nrfConsolePoll() has a 16-byte buffer and recognises exactly one token, "nrfdfu". The
// setter it named had no declaration in any header and no caller anywhere in the repo. Documenting
// a recovery that silently does nothing is worse than documenting none, because this block is what
// someone reads when a board "looks bricked" - so the clause and the unreachable setter both went
// (2026-08-25). Nothing needs them today: ACAB_REV_DETECT is defined by no env, so boardProbeRevB
// never runs and the #else branch below already heals a stale latch on every boot. If the probe is
// ever enabled for real rev-B boards, add a serial escape back AT THE SAME TIME, with a parser.
static const int kVbusSensePin = 1;      // D0 / GPIO1 / ADC1_CH0 , rev-B VBUS divider node
static int8_t gBoardRevB = -1;           // -1 unknown, 0 rev-A, 1 rev-B

static bool boardProbeOnce(int* meanOut, int* spreadOut) {
    // ACTIVE probe. The first cut just enabled the internal pulldown and read the ADC, and a real
    // rev-A board measured mean=689mV spread=2678mV (2026-07-28 bench): the ADC init drops the pull
    // resistor, so the floating pin wandered the full range and its MEAN landed above a 600mV
    // threshold. Only the stability test caught it - one heuristic away from permanently latching a
    // rev-A board as rev-B. So: discharge the pin first, then let the divider (if any) re-establish.
    pinMode(kVbusSensePin, OUTPUT);      // drive LOW: dump whatever charge is sitting on a floating pin
    digitalWrite(kVbusSensePin, LOW);
    delay(3);
    pinMode(kVbusSensePin, INPUT);       // release, no internal pull (the ADC would drop it anyway)
    delay(20);                           // rev-B's 100k/100k snaps back in ~us; a float has nothing to pull it
    int lo = 4096, hi = 0; long sum = 0;
    for (int i = 0; i < 16; i++) {
        int mv = (int)analogReadMilliVolts(kVbusSensePin);
        sum += mv; if (mv < lo) lo = mv; if (mv > hi) hi = mv;
        delay(2);
    }
    int mean = (int)(sum / 16), spread = hi - lo;
    if (meanOut) *meanOut = mean;
    if (spreadOut) *spreadOut = spread;
    // rev-B with USB present parks at ~2500mV (5V halved) and holds it dead steady. A discharged
    // floating pin sits near 0 and, if it drifts, drifts noisily. 1500mV is deliberately far above
    // anything a float produced on the bench, and 120mV of spread is generous for ADC noise but
    // impossible for a high-impedance pin.
    return (mean > 1500 && spread < 120);
}

// Three independent rounds must ALL agree before we latch anything permanent. A single wandering
// sample set cannot reach the threshold three times in a row after three separate discharges.
static bool boardProbeRevB() {
    int mean = 0, spread = 0, agree = 0;
    for (int r = 0; r < 3; r++) {
        int m = 0, sp = 0;
        if (boardProbeOnce(&m, &sp)) agree++;
        mean = m; spread = sp;
    }
    Serial.printf("[board] D0 probe: mean=%dmV spread=%dmV rounds=%d/3 -> %s\n",
                  mean, spread, agree,
                  (agree == 3) ? "rev-B divider present" : "no divider (rev-A, or rev-B on battery)");
    return agree == 3;
}

// Resolve the revision once at boot.
// PRECEDENCE: -DACAB_FORCE_REV_B (explicit) > -DACAB_REV_DETECT (probe+latch) > rev-A (default).
//
// DETECTION IS OPT-IN AS OF 2026-07-28, and that is deliberate. No rev-B board exists yet, so on
// every board that physically exists today a rev-B verdict is WRONG BY DEFINITION - there is no
// upside to guessing and a very real downside. It bit for real: a board whose SW1 pads were bridged
// GND<->D10 (the documented slim always-on mod) held D10 LOW forever, the probe had latched rev-B,
// and the rev-B off-hold read that permanent LOW as "button held" and parked the unit ~1.5s after
// every boot. The unit looked bricked and the correct hardware mod was what exposed it.
// When rev-B boards arrive, build them with -DACAB_REV_DETECT and the probe/latch below runs again.
static void boardRevDetect() {
#if defined(ACAB_FORCE_REV_B)
    gBoardRevB = (ACAB_FORCE_REV_B) ? 1 : 0;
    Serial.printf("[board] revision FORCED by build flag: rev-%s\n", gBoardRevB ? "B" : "A");
    // Forcing rev-A must ALSO heal a stale latch, exactly like the detection-off path below.
    // Without this, -DACAB_FORCE_REV_B=0 (the documented way to declare a board rev-A) left a
    // poisoned revb=1 in NVS, and a later -DACAB_REV_DETECT build would hit the stored==1 early
    // return and resurrect the mis-latch WITHOUT ever running the probe.
    if (!gBoardRevB) {
        Preferences p; p.begin("acab-board", false);
        if ((int8_t)p.getChar("revb", -1) == 1) { p.remove("revb"); Serial.println("[board] cleared a stale rev-B latch from NVS"); }
        p.end();
    }
#elif defined(ACAB_REV_DETECT)
    Preferences p;
    p.begin("acab-board", true);
    int8_t stored = (int8_t)p.getChar("revb", -1);
    p.end();
    if (stored == 1) { gBoardRevB = 1; Serial.println("[board] revision: rev-B (latched in NVS)"); return; }
    if (boardProbeRevB()) {
        gBoardRevB = 1;
        Preferences w; w.begin("acab-board", false); w.putChar("revb", 1); w.end();
        Serial.println("[board] revision: rev-B DETECTED and latched (button power + VBUS sense)");
    } else {
        gBoardRevB = 0;   // not latched on purpose , see LATCH POLICY above
        Serial.println("[board] revision: rev-A (slide switch); will re-probe next boot");
    }
#else
    gBoardRevB = 0;
    // HEAL a poisoned latch written by an earlier build that probed by default. Without this, simply
    // rebuilding with detection off would leave the bad NVS key sitting there to bite again the next
    // time detection is enabled.
    { Preferences p; p.begin("acab-board", false);
      if ((int8_t)p.getChar("revb", -1) == 1) { p.remove("revb"); Serial.println("[board] cleared a stale rev-B latch from NVS"); }
      p.end(); }
    Serial.println("[board] revision: rev-A (detection off; build -DACAB_REV_DETECT once rev-B boards exist)");
#endif
}

// Public: true when this carrier is rev-B (momentary button + real VBUS sense).
bool acabBoardIsRevB() { return gBoardRevB == 1; }

static void nrfResetPulse();   // defined below; powerOffDeepSleep uses it for DFU-bootloader rescue

// COMMITTED POWER STATE, persisted in NVS. The boot gate used to infer "was the unit on?" from
// esp_reset_reason(), and reset causes lie in both directions: a brownout on a running battery
// unit read as "cold power-up" and silently parked a detector its owner believed was covering
// them, while a crash inside a bump-wake boot read as "software reset" and fully powered on a
// unit that was deliberately off (both confirmed by the 2026-07-29 adversarial review). So the
// decision is now RECORDED at the moment it is made - set when the gate commits to ON (hold
// passed, or battery-less auto-on), cleared in powerOffDeepSleep - and the next boot reads the
// record instead of guessing. NVS, not RTC memory, because it must survive total power loss
// (that is exactly the brownout case). Writes only happen on on/off TRANSITIONS, so flash wear
// is a non-issue.
static bool pwrCommittedOn() {
    Preferences p; p.begin("acab-pwr", true);
    bool on = p.getUChar("on", 0) == 1;   // absent = OFF: first-ever boot ships parked
    p.end(); return on;
}
static void pwrCommit(bool on) {
    Preferences p; p.begin("acab-pwr", false);
    if ((p.getUChar("on", 0) == 1) != on) p.putUChar("on", on ? 1 : 0);
    p.end();
}
static void btnWaitRelease(uint32_t capMs);   // defined below; powerOffDeepSleep must wait out the off-press before arming ext0
static bool btnHeldFor(uint32_t holdMs);

// announce = play the power-down cue first. Only the RUNNING->off call sites pass true (the loop
// off-poll and the app power-off drain); the boot-gate re-sleeps (a bump-wake that fails the hold)
// pass false and stay SILENT, the same reason the boot jingle now sits below the gate - a pocket
// bump must never make a sound.
static void powerOffDeepSleep(bool announce = false) {
    Serial.println("[pwr] switch OFF -> parking nRF + deep sleep (flip to 'on' to wake)");
    pwrCommit(false);   // record the decision FIRST: if anything below crashes, the next boot
                        // must still know the unit chose OFF (see pwrCommittedOn)
    if (announce) {
        // A real running->off (button-hold or app request), not a boot-gate re-sleep. Tell a
        // connected app FIRST so it flags the coming drop as a clean shutdown (the app arms its
        // intent on this notify, never on the bare request - so an old board that ignores the key
        // never mis-arms it), then play the mirror-of-boot power-down cue. Both are skipped on the
        // silent boot-gate paths so a pocket bump makes no sound and tells no app anything.
        acabBleNotifyPoweringOff();
        alertsPowerDown();
    }
    // Resend 'P' until the nRF acks, capped at 3s. A blind single send races the nRF's boot:
    // if the switch is flipped off within ~2s of power-on the co-processor hasn't started its
    // UART command loop yet, drops the 'P', and keeps scanning while we sleep. The nRF echoes
    // "# ACAB-nRF powering off" right before System OFF, so we retry until we hear it (or give
    // up and sleep anyway if the nRF is absent/broken - the degenerate no-co-processor case).
    static char line[96]; int pos = 0; bool acked = false;
    uint32_t start = millis();
    while (!acked && millis() - start < 3000) {
        // Mutex-routed like the DFU trigger: if the app is still connected the NimBLE host task can
        // be writing to the same Serial1, and a bare println would interleave mid-line. Flush after
        // so TX drains before we listen for the "powering off" ack below.
        acabScannerSendCoProcCmd("P");
        Serial1.flush();
        uint32_t t = millis();
        while (!acked && millis() - t < 250) {
            while (Serial1.available()) {
                char ch = (char)Serial1.read();
                if (ch == '\n' || ch == '\r') {
                    line[pos] = 0;
                    if (strstr(line, "powering off")) acked = true;
                    pos = 0;
                } else if (pos < (int)sizeof(line) - 1) {
                    line[pos++] = ch;
                } else {
                    pos = 0;
                }
            }
        }
    }
    if (!acked) {
        // No ack: the nRF may be in its DFU bootloader (which ignores the UART protocol - e.g. the
        // switch was flipped off mid co-processor update). Left alone it would advertise DFU at mA
        // draw all night while the product reads "off". Pulse its reset (GPREGRET was consumed at
        // bootloader entry, so this boots the app), give it a moment, then one more 'P' round.
        Serial.println("[pwr] no ack - pulsing nRF reset (DFU bootloader / already parked?) and retrying 'P'");
        nrfResetPulse();
        // RETRY LOOP, not a single shot. This branch is not exotic any more: on rev-B EVERY
        // bump-wake re-park lands here, because the nRF is already in System OFF (only the reset
        // line wakes it), so phase 1 above can never ack. The old fixed delay(2000) + ONE 'P' with
        // a 1s listen raced the nRF's boot - its command loop comes up at ~2s by this file's own
        // phase-1 comment - and losing that race left the nRF scanning at mA forever while the
        // product read "off". Same resend-until-ack pattern as phase 1: start sending early
        // (harmless while the UART is still down), 250ms rounds until ack or 5s.
        uint32_t t2 = millis(); pos = 0;
        while (!acked && millis() - t2 < 5000) {
            acabScannerSendCoProcCmd("P");
            Serial1.flush();
            uint32_t t3 = millis();
            while (!acked && millis() - t3 < 250) {
                while (Serial1.available()) {
                    char ch = (char)Serial1.read();
                    if (ch == '\n' || ch == '\r') {
                        line[pos] = 0;
                        if (strstr(line, "powering off")) acked = true;
                        pos = 0;
                    } else if (pos < (int)sizeof(line) - 1) { line[pos++] = ch; } else { pos = 0; }
                }
            }
        }
    }
    Serial.printf("[pwr] nRF %s; sleeping\n", acked ? "acked" : "no ack (sleeping anyway)");
    if (acabBoardIsRevB()) {
        // rev-B: the off-press is very likely STILL HELD right now. ext0 wakes on LOW, so arming it
        // against a held button would wake us instantly, forever. Wait for release first.
        Serial.println("[pwr] waiting for button release before arming wake");
        btnWaitRelease(10000);
    }
    rtc_gpio_pullup_en(kSwSensePin);       // keep the pull alive through deep sleep
    rtc_gpio_pulldown_dis(kSwSensePin);
    esp_sleep_enable_ext0_wakeup(kSwSensePin, 0);   // wake when the switch pulls it LOW again
    esp_deep_sleep_start();          // does not return; wake = fresh boot
}

// Wake the nRF from System OFF (or just cleanly reboot it) by pulsing its RESET
// line, which the carrier wires to our D5/GPIO6 (the SWRST solder-access link).
// Open-drain style: drive low, then release to input so its internal pull-up
// (and any attached J-Link) owns the line again.
static void nrfResetPulse() {
    pinMode(kNrfResetPin, OUTPUT);
    digitalWrite(kNrfResetPin, LOW);
    delay(5);
    pinMode(kNrfResetPin, INPUT);
}

// ---- rev-B power BUTTON (EVQ-P7 side tact) on the same D10 sense line -------------------------
// rev-A used an SS12D00G4 SLIDE: knob at 'on' held D10 LOW forever, 'off' let it float HIGH, so
// "is it on" was just a level read. rev-B swaps in a MOMENTARY button (pressed = LOW), which needs
// timing semantics instead, and buys two things: nothing in a pocket or a shipping box can nudge it
// on (the ship-drain audit's #1 kill mode), and the case loses the knob well + funnel + glyphs.
//   OFF while running : hold ~1.5s
//   ON  after a wake  : the press wakes us (ext0 LOW), then it must be HELD ~1s or we re-sleep
//   cold boot         : nothing held -> sleeps immediately, i.e. a freshly connected cell ships OFF
static const uint32_t kBtnOffHoldMs = 1500;
static const uint32_t kBtnOnHoldMs  = 1000;

// True only if the button stays down for the WHOLE window (returns the moment it is released).
static bool btnHeldFor(uint32_t holdMs) {
    uint32_t t0 = millis();
    while (millis() - t0 < holdMs) {
        if (digitalRead(kSwSensePin) == HIGH) return false;
        delay(10);
    }
    return true;
}
// Block until the button is released (debounced) or the cap expires. MUST run before arming ext0:
// ext0 wakes on LOW, so sleeping while the off-press is still held would wake us right back up in
// an endless press-sleep-wake loop. The cap keeps a shorted/stuck line from hanging us forever -
// we sleep anyway and the ext0 arm simply re-wakes, which is the honest degenerate case.
static void btnWaitRelease(uint32_t capMs) {
    uint32_t t0 = millis(), highRun = 0;
    while (millis() - t0 < capMs) {
        if (digitalRead(kSwSensePin) == HIGH) { if (++highRun >= 3) return; }
        else                                   { highRun = 0; }
        delay(10);
    }
}

// OFF detection. rev-A slide: ~10 consecutive HIGH reads over the 20ms loop cadence.
// rev-B button: LOW held continuously for kBtnOffHoldMs, timed off millis() rather than loop
// counts so a slow tick (OTA, dense scan) can't shorten the hold the user has to make.
static bool swSensePollOff() {
#ifdef ACAB_BENCH_NO_SLEEP
    // The bench flag is documented as "ignores SW1 entirely", but it only ever skipped the BOOT
    // gate - this loop poll kept running, so on a rig with D10 floating HIGH the board decided the
    // switch was off ~200ms after boot and called powerOffDeepSleep(), which PARKS THE nRF ('P')
    // on its way out. Symptom on the bench: the S3 appears to stay up while the co-processor goes
    // dark and never comes back. Make the flag mean what it says. (2026-07-28, found on hardware.)
    return false;
#else
  if (acabBoardIsRevB()) {
    // ARMING GUARD: the off-hold only counts once we have seen the line RELEASED at least once.
    // A line that is LOW continuously from boot is not a 1.5s press, it is hardware holding it down
    // (a slide switch at 'on', or the SW1 GND<->D10 bridge the slim build calls for). Without this,
    // such a board parks itself ~1.5s after every boot, forever - observed on real hardware.
    static uint32_t downSince = 0;
    static bool sawRelease = false;
    if (digitalRead(kSwSensePin) == HIGH) { sawRelease = true; downSince = 0; return false; }
    if (!sawRelease) return false;                    // never released since boot -> tied low, ignore
    if (downSince == 0) downSince = millis();
    else if (millis() - downSince >= kBtnOffHoldMs) { downSince = 0; return true; }
    return false;
  }
    static int highRuns = 0;
    if (digitalRead(kSwSensePin) == HIGH) {
        if (++highRuns >= 10) return true;
    } else {
        highRuns = 0;
    }
    return false;
#endif
}

// Poll the USB console for the newline-terminated "nrfdfu" bench command: forwards the DFU
// trigger so the nRF reboots into its BLE OTA bootloader (then update it from a phone / nRF Connect).
static void nrfConsolePoll() {
    static char buf[16];
    static int  n = 0;
    while (Serial.available()) {
        char ch = (char)Serial.read();
        if (ch == '\n' || ch == '\r') {
            buf[n] = 0;
            if (n && strcmp(buf, "nrfdfu") == 0) nrfEnterDfu();
            n = 0;
        } else if (n < (int)sizeof(buf) - 1) {
            buf[n++] = ch;
        } else {
            n = 0;
        }
    }
}
#endif // ACAB_DUAL_RADIO

// Is THIS S3 image good enough to keep? Wired into ota_update as the health check, so it decides
// whether a freshly-flashed trial image is confirmed or rolled back.
//
// THE CO-PROCESSOR IS A PREFERRED SIGNAL, NOT A VETO (2026-08-25). This used to end in
// `return gNrfVersion >= 0 && acabScannerCoProcAlive()`, which an nRF that is dead, absent, or
// parked in its bootloader with its app erased - the documented outcome of a failed Android BLE
// DFU - can never satisfy. On such a board otaMarkHealthy() never succeeded, loop() hit its 60 s
// deadline and called ESP.restart(), and the NEXT boot's otaBootCheck reached tries==2 and
// switched back to the previous slot: roughly a minute plus a boot after an update that reported
// success. {"ota":{"confirm":true}} could not rescue it either - that also runs through
// otaHealthReady and answered "health-wait" forever. So the boards most in need of an
// over-the-air fix, the ones whose radio half is broken, were the only boards that could not
// receive one. The co-processor's state belongs in the diagnostics the status doc already
// publishes ("co", "nrfup"), not in the gate that decides whether the S3's own image survives.
//
// So: confirm immediately once BOTH radios are up (the good case, and the common one), keep
// waiting while there is real room before loop()'s 60 s rollback deadline, and past that confirm
// on the S3's own evidence and let the app show the co-processor fault it already surfaces. A
// co-processor that is mid-BLE-DFU never blocks at all - it is SUPPOSED to be silent then, and
// acabNrfDfuActive() is the same signal the status doc uses to suppress the nRF-fault banner.
//
// WHAT THAT COSTS, STATED PLAINLY. The UART evidence was the only automatic detection that a new
// image can still TALK to the co-processor, so an S3 image that regresses the link itself (a
// changed pin or baud, a broken "V<n>" parse in parseAdvLine) now confirms on its own uptime
// instead of being reverted on the next boot, and BLE detection - which is entirely the nRF's on
// this board, cfg.enableBLE is false below - stays dead until someone pushes another OTA or
// reflashes over USB. That trade is deliberate (a dead nRF must not be able to revert a good S3
// image), so what is owed is EVIDENCE, not silence: the fallthrough says so on the console once
// per boot, and the status doc still carries the fact for the app to surface ("co":false, with
// "nrfv" simply absent for as long as no version has been heard).
static bool otaRuntimeHealthy() {
    if (millis() < 20000 || !acabScannerHealthy()) return false;
#ifdef ACAB_DUAL_RADIO
    // The version proves the parser/link path end to end, and liveness rejects a co-processor that
    // spoke once and then died before confirmation.
    if (gNrfVersion >= 0 && acabScannerCoProcAlive()) return true;
    if (acabNrfDfuActive()) return true;   // legitimately silent: rebooting into/out of its bootloader
    // Deadline for a co-processor that simply is not coming back. 30 s is deliberate on both
    // sides: loop() makes its first otaMarkHealthy() attempt at 20 s, which is already past
    // acabScannerCoProcAlive()'s own 20 s boot grace, so ten more seconds is a genuine extra
    // chance rather than a token one - and it leaves 30 s before loop()'s 60 s ESP.restart(),
    // so the confirmation lands well inside the bounded confirm-retry window both apps run and
    // the user sees "updated", not an unexplained "the board did not confirm".
    static const uint32_t kOtaCoProcWaitMs = 30000;
    if (millis() < kOtaCoProcWaitMs) return false;
    // Past the bound: confirm, but SAY WHAT WAS MISSING, and say it precisely enough to act on.
    // Confirming silently is what makes an image that broke the UART link look identical on the
    // console to a healthy board with no co-processor fitted, and loop()'s next line prints "trial
    // image healthy" either way. The two values printed split the causes, because uartIngestPoll()
    // calls acabScannerNoteCoProcRx() for ANY complete line, BEFORE parseAdvLine sees it:
    // BOTH values are needed to split the causes: acabScannerCoProcAlive() is false until a "D "
    // stats line has PARSED (it gates on gHasCo), so it cannot on its own tell a silent nRF from a
    // broken parser in this image. acabScannerHasCoProc() is that parse latch:
    //   hasco=1, alive=1, nrfv=-1  stats parse, no "V<n>" does -> suspect THIS image's V parser
    //   hasco=1, alive=0           it spoke and then went silent (a reboot outside a DFU window)
    //   hasco=0, nrfv>=0           a version arrived but no stats line -> suspect the "D " parser
    //   hasco=0, nrfv=-1           nothing parsed at all -> dead/absent nRF, wrong pins or baud,
    //                              or an image whose UART ingest regressed wholesale
    // Latched, so this costs one line per boot rather than one per otaMarkHealthy() retry.
    static bool sSaidNoCoProc = false;
    if (!sSaidNoCoProc) {
        sSaidNoCoProc = true;
        Serial.printf("[ota] co-processor gave no evidence in %lus (nrfv=%d alive=%d); confirming "
                      "on the S3's own health anyway, so a dead or absent nRF cannot revert a good "
                      "image. BLE detection is DOWN until it answers, and this line is the only "
                      "automatic notice of it. hasco=1 means a stats line parsed, so the link "
                      "works and the gap is narrower; hasco=0 with nrfv=-1 means nothing parsed "
                      "at all (dead or absent nRF, wrong pins or baud, or this image's UART "
                      "ingest).\n",
                      (unsigned long)(kOtaCoProcWaitMs / 1000), gNrfVersion,
                      (int)acabScannerCoProcAlive(), (int)acabScannerHasCoProc());
    }
    return true;
#else
    return true;
#endif
}

void setup() {
    Serial.begin(115200);
    delay(200);
    Serial.print(acabBanner());
    // Read the retained core dump BEFORE anything else can panic, and report it. The board has
    // been capturing these to flash all along (the partition and IDF's espcoredump are already in
    // the shipped image); nothing ever read them, so every field panic wrote a full post-mortem
    // and then sat invisible until the next erase. Prints nothing on a clean boot.
    acabCoredumpProbe();
    acabCoredumpPrint();
#ifdef ACAB_BENCH_COREDUMP_PANIC
    // BENCH ONLY, USB serial only, and deliberately NOT reachable over BLE: a remotely triggerable
    // abort() is risk with no upside. Panics ~2 s after boot so the dump can be captured and
    // decoded against a known ELF, which is the only way to measure whether a real dump fits in
    // the 64 KB partition. Sits in the same capture-build guard family as ACAB_BENCH_NO_SLEEP.
    Serial.println("[bench] ACAB_BENCH_COREDUMP_PANIC set - forcing a panic in 2s");
    delay(2000);
    abort();
#endif
    // Banner follows the BUILD, like the BLE fw label below it does. This used to be hardcoded
    // "ACAB OUI-Spy" from the original single-radio project, so a dual-radio beacon board booted
    // announcing itself as a Colonel Panic OUI-Spy. Cosmetic, but it is the first thing anyone
    // sees on a serial console and it contradicted the fw label the same setup() sets.
    // NOTE this is the HUMAN-READABLE banner only. The fw LABEL below ("beacon board" /
    // "ACAB-ouispy") is a WIRE CONTRACT: the apps and firmware-latest.json resolve a manifest
    // entry from it, so it must not be "fixed" to match this string.
#ifdef ACAB_DUAL_RADIO
    Serial.println("=== All Cameras Are Beacons " ACAB_FW_VERSION " ===");
#else
    Serial.println("=== ACAB OUI-Spy " ACAB_FW_VERSION " ===");
#endif

    // Rollback gate: if a prior OTA image booted without confirming health, revert now
    // (may esp_restart()). Must run before heavy init so a bad image can't wedge here first.
    otaSetHealthCheck(otaRuntimeHealthy);
    otaBootCheck();
    if (otaOnTrial()) Serial.println("[ota] running a freshly-updated image (trial boot)");

    alertsInit();
    // Boot jingle MOVED to after the soft-power gate (below). The sound now plays only once the
    // board commits to staying on, so a too-short button hold parks SILENTLY instead of beeping a
    // boot it then abandons. See the hold-time note at the gate.

    // ---- SOFT-POWER GATE FIRST (moved up 2026-08-14) --------------------------------------------
    // The gate used to sit BELOW NimBLE init, the flash-ring mount and the NVS restores, and a
    // timed boot capture measured that stack at ~4s - so "hold to power on" felt like 5 seconds
    // because the hold timer could not even START until the heavy init finished. The gate needs
    // none of it: the chirp needs alertsInit, the park path needs Serial1 (for the nRF 'P'
    // handshake), and the decision needs one GPIO and two NVS reads. Run it here and the hold
    // starts ~0.5s after the press; the radios and restores initialize AFTER commit, while the
    // user's finger is already off the button. A failed hold also parks ~4s sooner, which is
    // exactly what a pocket bump wants. The OTA rollback check above deliberately stays ahead of
    // this gate (it is cheap, and a bad trial image must be able to revert before anything else).
    //
    // INPUTS to acabPhysicalStart, collected by the power gate. Production must COLLECT and CALL,
    // not hand-assign the answer: a helper that is tested but never invoked is not coverage, and
    // a mutation to any hand-written assignment would have failed no test at all. Declared outside
    // the dual-radio guard because the pairing decision below is outside it too; targets with no
    // soft-power gate never reach a branch that could set these, and for them booting IS starting.
    bool pwrCellAbsent = false;  // USB-only board seeing fresh power
    bool pwrButtonHeld = false;  // hold-to-start, i.e. the ext0 wake after a hold-to-off
    bool pwrSwitchLow  = false;  // slide-switch SKU reading ON at boot
#ifdef ACAB_BENCH_NO_SLEEP
    const bool pwrBenchBuild = true;
#else
    const bool pwrBenchBuild = false;
#endif

#ifdef ACAB_DUAL_RADIO
    // UART to the companion nRF52840, brought up BEFORE the gate because powerOffDeepSleep's nRF
    // park handshake writes it on every park path. 1000000 baud to match the nRF (exact divisor
    // both ends); setRxBufferSize BEFORE begin, the core refuses to resize a started UART, and the
    // 8192-byte ring absorbs forwarded-advert bursts without dropping lines.
    Serial1.setRxBufferSize(8192);
    // UART PIN ORDER IS BOARD-REVISION DEPENDENT. Default = REV-A = the 250 production boards.
    //   rev-A (nRF rot 180): the TX/RX crossover is ALREADY IN COPPER, so the S3 keeps its pins
    //       STRAIGHT: RX = D7 (GPIO44) fed by the nRF's TX, TX = D6 (GPIO43) into the nRF's RX.
    //       This is the DEFAULT precisely because it is what ships - an OTA that quietly reverted
    //       to the other order would kill BLE on every fielded unit while WiFi kept working.
    //   flipped layout (nRF rot 0 - rev-B as build_pcb.py draws it): copper runs straight, so the
    //       S3 crosses in SOFTWARE. Build those with -DACAB_UART_SOFT_CROSS.
    // Symptom of getting this wrong: wifi_seen climbs normally while nRF adv=0 fwd=0 scan=0, with
    // a co-processor that is provably fine on its own USB console. Both ends end up listening.
#ifdef ACAB_UART_SOFT_CROSS
    Serial1.begin(1000000, SERIAL_8N1, 43, 44);   // flipped board: cross in software (RX=D6, TX=D7)
    Serial.println("[ACAB] dual-radio: BLE via companion nRF52840 (UART RX=D6/GPIO43, TX=D7/GPIO44 - software cross, flipped board)");
#else
    Serial1.begin(1000000, SERIAL_8N1, 44, 43);   // rev-A: copper already crossed (RX=D7, TX=D6)
    Serial.println("[ACAB] dual-radio: BLE via companion nRF52840 (UART RX=D7/GPIO44, TX=D6/GPIO43 - copper cross, rev-A)");
#endif
    acabScannerSetCmdSink(nrfCmdSink);   // app radio toggles + ignore list -> nRF (our D7 TX)

    // Soft power switch: if SW1 is at 'off' when power arrives (battery plugged in, or USB
    // attached for charge-while-off), park everything now , the charger keeps working while
    // we sleep. 3s grace so a bench module with no carrier (floating D10 reads HIGH) can be
    // rescued by grounding D10, and so the message is visible on a serial monitor.
    //
    // ACAB_BENCH_NO_SLEEP: on a loose-jumper breadboard rig there is no SW1 and D10 floats HIGH,
    // so the board deep-sleeps 3s after every boot and never comes up for bring-up. This flag
    // skips the soft-power park so the S3 always runs on the bench. It is a BENCH-ONLY flag,
    // never set on a shipped build (the real carrier drives D10 through SW1). DEFAULT OFF.
    // Resolve the carrier revision FIRST: the power-gate below and swSensePollOff() both branch on
    // it, so it has to be known before we look at D10.
    boardRevDetect();
#ifndef ACAB_BENCH_NO_SLEEP
    pinMode(kSwSensePin, INPUT_PULLUP);
    delay(10);
    if (acabBoardIsRevB()) {
    // rev-B button: this boot is either a cold power-up (cell just connected -> nothing held ->
    // park immediately, so a unit going into a shipping box is OFF) or an ext0 wake from a press
    // (-> the user must KEEP holding for kBtnOnHoldMs, which is what makes a bump-in-a-pocket
    // unable to switch it on). Either way, no hold = straight back to sleep.
    //
    // EXCEPT after a SOFTWARE reset. An OTA finishing calls ESP.restart() (handleOtaControl's end
    // branch in acab_ble_service.cpp; otaWrite's deferred finish and otaBootCheck's rollback in
    // ota_update.cpp) with nobody touching the button, so the hold test would fail and the
    // unit would park itself the instant it booted the new image - it would read as "the update
    // bricked it". A software reset means the unit was already ON and chose to reboot, so the power
    // decision was made long ago; honour it and skip the gate. Only the genuine power-on and
    // deep-sleep-wake causes below arrive with the power state actually undecided.
    const esp_reset_reason_t rr = esp_reset_reason();
    // NOTE: no reset-cause taxonomy here any more. The old softReset list (SW/PANIC/WDTs) was
    // wrong in both directions - ESP_RST_BROWNOUT on a running battery unit fell through to the
    // hold gate and parked it (jingle, then silence, no coverage for the rest of the drive), and
    // a panic inside a bump-wake boot LOOKED like a soft reset and powered on a boxed unit. The
    // persisted marker (pwrCommittedOn) answers the actual question directly.
    // AND EXCEPT on a battery-less build getting fresh power. rev-A slim ties D10 low so USB
    // presence = running; a rev-B slim must keep that plug-and-forget behaviour or a car-dash unit
    // stays dead every time the ignition cycles. Cell detect = the same D9 divider readBatteryPct()
    // uses: on the slim build the BP1 flow-up is deliberately absent, so the carrier's VBAT net is
    // an ISLAND and R2 holds the sense node hard at GND -> a few mV, deterministic (this is also
    // why R1/R2 MUST be populated on rev-B slim - without them D9 floats and this read is garbage).
    // Any real cell, even a protected one at cutoff, reads >= ~2.5 V. Threshold 2.0 V splits the
    // two by a wide margin on both sides.
    // Scope: auto-on applies to FRESH POWER only (plug-in, brownout recovery), NOT to an ext0 wake
    // - after a deliberate hold-to-off, a pocket bump must not re-light the unit; turning it back
    // on stays hold-gated. Unplug/replug also turns it on, which matches what "USB power = intent
    // to run" means on a device with no battery.
    bool cellAbsent = false;
    if (rr != ESP_RST_DEEPSLEEP) {
        uint32_t vs = 0;
        for (int i = 0; i < 8; i++) vs += analogReadMilliVolts(8);   // XIAO D9 = GPIO8, VBAT/2
        cellAbsent = ((int)(vs / 8) * 2) < 2000;
    }
    if (pwrCommittedOn()) {
        // The unit was ON and never chose otherwise: OTA restart, panic, watchdog, brownout on a
        // sagging cell - whatever rebooted us, the user's last decision was "on", so honour it.
        Serial.printf("[pwr] committed ON in NVS (reset reason %d) -> staying on\n", (int)rr);
    } else if (cellAbsent) {
        Serial.println("[pwr] no cell detected (USB-only build) + fresh power -> auto-on, button = hold-to-off");
        pwrCommit(true);
        pwrCellAbsent = true;    // applying power to a USB-only board IS the intent to start it
    } else {
        // HOLD TIME: kBtnOnHoldMs is measured from HERE, and since the 2026-08-14 reorder "here"
        // is ~0.5s after the press (Serial + coredump probe + OTA rollback check + alertsInit +
        // Serial1), not the ~4s of radio/flash init that used to run first. Press-to-chirp is now
        // about 1.5s total; the heavy init runs after commit, while the finger is already off.
        if (!btnHeldFor(kBtnOnHoldMs)) {
            Serial.println("[pwr] button not held at boot -> parking (hold ~1s to power on)");
            powerOffDeepSleep();
        }
        Serial.println("[pwr] button held -> powering on");
        pwrCommit(true);
        // ACK CHIRP at the commit (2026-08-12, from a real build: power-on "took 5-8s"). Without it
        // the user's only feedback is the boot jingle, which plays after the release-wait below
        // plus the radio bring-up - so they held the whole time and the board felt slow. One short
        // beep the instant the hold passes says "on - let go now". Queued/non-blocking, bypasses
        // detection-alert mute at the saved nonzero volume, and can never fire on a pocket bump
        // (the hold above already passed).
        alertsPowerOnAck();
        // THE RECOVERY PATH the apps instruct. Soft-off is deep sleep, so this wakes with
        // ESP_RST_DEEPSLEEP, never ESP_RST_POWERON - which is exactly why the old reset-reason
        // test never opened a window here and "turn it off and on" did not work.
        pwrButtonHeld = true;
        btnWaitRelease(3000);   // don't let the same press immediately read as an off-hold in loop()
    }
    } else {
    if (digitalRead(kSwSensePin) == HIGH) {
        Serial.println("[pwr] switch is OFF at boot -> sleeping in 3s (ground D10 to run)");
        delay(3000);
        if (digitalRead(kSwSensePin) == HIGH) powerOffDeepSleep();
    }
    // Records only that the switch READS ON. It does NOT mean a person just flipped it: the switch
    // is still on after an OTA restart too, which is why this alone made every reflash open a
    // window. acabPhysicalStart pairs it with the reset reason.
    pwrSwitchLow = true;
    }
#else
    Serial.println("[pwr] ACAB_BENCH_NO_SLEEP: soft-power park skipped (bench build, D10 ignored)");
#endif
#endif
    // ---- end soft-power gate; everything below runs only on a boot that is staying up ----------
    // The nRF reset pulse deliberately does NOT happen here, even though the UART is up. An early
    // pulse looked like a free parallel-boot win, but review caught the cost: the co-processor
    // comes up ~2s later and forwards adverts at full duty into the 8192-byte Serial1 ring while
    // our heavy init still has ~2s to run with nothing draining it - in dense RF the ring overflows
    // and a mid-line byte drop can splice two forwarded adverts into one chimeric line. So the pulse
    // stays BELOW init (just before the jingle), where loop() is moments from draining, exactly as
    // it was before the 2026-08-14 gate reorder.
    //
    // AUTO-WIPE DELTA, reviewed + ACCEPTED 2026-08-14: detLogBegin (the offline buffer's boot
    // counter, which drives the N-reboots-without-app-contact seizure wipe) now runs only on boots
    // that COMMIT to staying on. Parked boots - pocket bumps, failed holds, charge-while-off
    // plug-ins - no longer advance the wipe countdown. Deliberate: the old order let a bag jostle a
    // battery unit through enough bump-wake boots to wipe the owner's OWN evidence buffer, which is
    // worse than a seized unit needing its parks to be real boots before the count advances. The
    // accepted seizure posture already concedes flash imaging defeats the wipe. See det_log.cpp.

    // BLE identity. The dual-radio build advertises as "beacon" + reports the "beacon board"
    // fw label; the single-radio oui-spy stays "ACAB" / "ACAB-ouispy".
    // The LABEL is the OTA discriminator, not the version: the app resolves a manifest entry from
    // fwLabel alone, so two revisions sharing one label share one update channel. env:beacon-board
    // -revb overrides it via ACAB_FW_LABEL so a rev-A board is never handed a rev-B image (which
    // would park it after every boot, USB-recovery only). The BLE ADVERTISED name stays "beacon"
    // for both - it is what the app scans for, and splitting it would break pairing.
#ifdef ACAB_DUAL_RADIO
    const char* kBleName = "beacon";
#ifdef ACAB_FW_LABEL
    // 23 chars is the label bound the status "fw" budget is built on: fwbuf in acabBleUpdateStatus
    // is sized for label(<=23) + ' ' + version(<=8), and this build flag (platformio.ini) is the
    // one label the compiler can't see the length of at that site. Growing it past 23 would
    // silently truncate the VERSION off the end of "fw", which both apps parse.
    static_assert(sizeof(ACAB_FW_LABEL) <= 24, "ACAB_FW_LABEL longer than 23 chars - resize fwbuf "
                  "and the host-test fw width (test_acab_ble_service.cpp) together");
    const char* kFwLabel = ACAB_FW_LABEL;
#else
    const char* kFwLabel = "beacon board";
#endif
#else
    const char* kBleName = "ACAB";
    const char* kFwLabel = "ACAB-ouispy";
#endif
    // BLE service inits NimBLE + starts advertising for the app.
    // Advertising DEFERRED: the pairing gate is configured after this call, so going on air here
    // would let a phone connect before it settles, with enforcement still off. acabBleStartAdvertising()
    // runs once the pairing decision below is made. (The soft-power gate already ran ABOVE this since
    // the 2026-08-14 reorder, so a parking boot never reaches here at all - this defer is now purely
    // about the pairing gate, not the power decision.)
    acabBleBegin(kBleName, kFwLabel, /*startAdvertising=*/false);

    // Offline detection buffer: mount the flash ring + bump the boot counter. Stays
    // inert (no capture) until the app enables it and pushes an at-rest key.
    detLogBegin();

    // Scanner reuses the NimBLE stack we just inited (initNimBLE=false) and adds
    // WiFi promiscuous on top.
    AcabScannerConfig cfg = acabScannerDefaults();
    cfg.initNimBLE = false;
    cfg.bleDeviceName = kBleName;

    // Axon body-cam detection on OUI 00:25:DF. Field-validated 2026-06-17: real
    // Axon body cams advertise this public OUI (payload reads "...BWC DEVICE").
    // See axon_detect.cpp.
    axonUseRegistryCandidate();
    // Restore the persisted body-cam CATEGORY toggle (default ON). Covers Axon (OUI +
    // the conf-90 BWCDEVICE tag) and Utility BodyWorn.
    axonRestoreEnabled(true);

    // Broad Motorola Solutions OUI proxy (see police_detect.cpp), folded into the body-cam
    // category but on its OWN persisted sub-toggle (default OFF, same as mesh-detect).
    // It no longer mirrors axon: a user quieting this broad match keeps the conf-90 Axon
    // tag, and toggling the category no longer overwrites their choice. Classification
    // still requires BOTH switches, so category-off silences this too.
    //
    // DEFAULT FLIPPED TO OFF 2026-07-23 on field ground truth. An airport capture returned
    // 30 body-cam rows: the 3 Axon BLE hits (00:25:DF, two via the conf-90 service-data tag)
    // were confirmed real officers, and ALL 27 Motorola WiFi OUI hits were confirmed NOT
    // body cams (fixed ceiling/infrastructure gear). 0/27 precision on a detector that ships
    // on by default drowns the true positives it sits next to, so it now joins netcam as an
    // opt-in vendor proxy. The signature list itself is correct and stays: this is a default,
    // not a removal. NOTE: the toggle is NVS-persisted, so boards that already stored "on"
    // keep it until the user turns it off in the app.
    policeRestoreEnabled(false);

    // Item-tracker detection: restore the persisted app toggle, DEFAULT OFF (reverted
    // 2026-07-25). It was briefly flipped ON (2026-07-24) on the theory that flagging only
    // SEPARATED Apple tags avoids the "AirTags everywhere" flood - but the 2026-07-25 downtown
    // SD drive disproved that: separated/offline Find My is ambient in a dense area, 175 of 201
    // rows, and it buried the 13 body cams + drone + ALPR under Apple noise. Separated-only
    // gating is correct and working (tracker_detect.cpp: type 0x12 len 0x19); the volume is just
    // real. So it goes back to opt-in: the user turns it on in the app when they specifically want
    // the "is someone tracking me" feature, which is the right time to accept the noise. Desert
    // still overrides off. (NVS-persisted, so already-flashed boards keep their current setting
    // until toggled; this default only affects fresh boards.)
    trackerRestoreEnabled(false);

    // Recording-glasses detection (BLE mfg company ID): restore the persisted app toggle,
    // default ON. The company-ID match is specific, so it does not flood like the tracker
    // scan, and it earns its spot by default. See glasses_detect.cpp.
    glassesRestoreEnabled(true);

    // Flock/ALPR + drone Remote ID detection: restore the persisted app toggles,
    // default ON (both are specific signatures, not floods). See flock_detect.cpp /
    // drone_detect.cpp. Desert mode still overrides the off state.
    flockRestoreEnabled(true);
    droneRestoreEnabled(true);
    // Drone vendor-OUI fallback: default OFF. It cannot tell a flying drone from a
    // stationary drone-vendor gadget (e.g. a Parrot device on a shelf), so it stays
    // off unless the user opts in - the choice then persists across reboots.
    droneOuiRestoreEnabled(false);
    // Network-camera detection (branded IP camera on host WiFi): default OFF. It requires
    // inspecting 802.11 DATA-frame source MACs, a CPU + 2.4GHz-coexistence cost we refuse
    // to pay unless the user opts in; when off the data-frame path is never enabled (zero
    // load). Restored BEFORE acabScannerBegin so the promiscuous filter is installed to match
    // the persisted choice from the first frame. See netcam_detect.cpp.
    netcamRestoreEnabled(false);

    // Desert mode. Persisted as of 2026-08-08 (it was the only detector toggle that was not),
    // because a board deployed unattended must not silently stop recording after a brownout
    // reset - the owner comes back unable to tell "nothing came by" from "it turned itself off".
    // Default OFF: it is a deliberate, high-volume mode, not something to inherit by accident.
    desertRestoreEnabled(false);

    // (The acabPhysicalStart INPUTS - pwrCellAbsent / pwrButtonHeld / pwrSwitchLow - and the
    // soft-power gate that collects them moved ABOVE the heavy init on 2026-08-14; see the
    // SOFT-POWER GATE FIRST block. The reset reason stays load-bearing there: without it the
    // switch SKU reopens a pairing window on every OTA and every panic, and soft-off wakes report
    // ESP_RST_DEEPSLEEP rather than ESP_RST_POWERON. Both inputs, one rule, one call below.)

#ifdef ACAB_DUAL_RADIO
    // BLE detection comes from the companion nRF52840; its UART was brought up at the
    // soft-power gate near the top of setup() (moved 2026-08-14), so this radio only
    // needs to skip its own BLE scan and stay on WiFi + the app GATT.
    cfg.enableBLE = false;
#endif

#ifdef ACAB_DUAL_RADIO
    // Pulse the nRF's RESET so it comes back from System OFF (harmless if it was never asleep - it
    // just reboots into a known-fresh co-processor state with us). Its fresh boot prints "V<n>";
    // also ask explicitly in case it was already up. Kept HERE, below the heavy init (not up at the
    // gate), so the co-processor's advert forwarding starts only moments before loop() begins
    // draining Serial1 - avoids the unpolled-ring-overflow window an early reset would open.
    nrfResetPulse();
    delay(30);
    acabScannerSendCoProcCmd("V");   // mutex sink, same interleave class as the DFU relay fix
#endif

    // Compute the physical-start decision before the boot motif as well as the pairing gate, so
    // both consume the one tested rule. NOTE (2026-08-24): the jingle no longer varies its AUDIO on
    // it - mute always wins there, because POWERON on a button-less deploy can be an unattended
    // power restore rather than a hand on the plug (see alertsBootJingle).
    const esp_reset_reason_t rr2 = esp_reset_reason();
    const bool physicalStart = acabPhysicalStart(rr2 == ESP_RST_POWERON,
                                                 rr2 == ESP_RST_DEEPSLEEP,
                                                 pwrCellAbsent, pwrButtonHeld,
                                                 pwrSwitchLow, pwrBenchBuild);

    // Boot jingle. Since the 2026-08-14 gate reorder the soft-power gate runs FIRST (near the top of
    // setup), so a parked boot deep-sleeps long before here and never reaches this - the jingle no
    // longer gates or shortens the turn-on hold (the 2026-08-12 note about that is history). It now
    // simply marks "committed, radios up"; the ack chirp at the gate's commit is the fast feedback.
    // The jingle honors detection-alert mute on EVERY boot, physical or warm; the mute-bypassing
    // confirmation of a deliberate start is the gate's ack chirp, which cannot fire unattended.
    alertsBootJingle(physicalStart);

    // Open the new-phone pairing window, ONCE, and only now: every path above this line can still
    // decide the board should be off (switch off at boot, button not held, cell absent), and a
    // board that boots merely to conclude it should sleep must never advertise itself as pairable.
    // Already-bonded phones are unaffected and reconnect whenever they like; this governs FIRST
    // contact only. RAM-only, so a power cycle is exactly how a user reopens it, which is also the
    // entire recovery instruction. See ACAB_PAIR_WINDOW_MS in acab_ble_service.h.
    //
    // ONLY ON A REAL POWER-ON. The user-facing promise is "turn it off and on", i.e. PHYSICAL
    // presence. A warm reboot is not that: pwrCommittedOn() keeps the board up through an OTA
    // restart, a task-watchdog panic (panic=true, so it reboots), a brownout on a sagging cell, and
    // any crash loop. Arming on those would mean every update reopens pairing for two minutes, and
    // worse, that anything able to induce a crash from radio range gets a pairing window handed to
    // it.
    //
    // THE RESET REASON IS NECESSARY BUT NOT SUFFICIENT, AND NEITHER IS THE SWITCH. An earlier
    // version of this comment claimed "ESP_RST_POWERON covers the cold paths that matter: first
    // power-up, the button-held start, the switch-on start". That is FALSE for the button-held
    // start, which is a deep-sleep wake and reports ESP_RST_DEEPSLEEP (see the recovery-path note
    // above, at the pwrButtonHeld assignment). The sentence read as an argument that the reset
    // reason alone decides, and a reviewer following it proposed DELETING the reset inputs
    // entirely. That would have reopened a 2-minute pairing window on every OTA and every panic
    // reboot for the switch SKU, because the switch still reads ON after a warm restart - which is
    // the exact hole this gate was written to close.
    //
    // The rule is POWERON *or* DEEPSLEEP, combined with evidence of INTENT: the button was held,
    // the switch reads on, the cell is absent (USB-only SKU), or this is a bench build. Neither
    // half decides alone, and a warm cause stays closed whatever the switch reads. acabPhysicalStart
    // owns that combination and is host-tested; the branches above only collect the inputs.
    // ENFORCEMENT IS UNCONDITIONAL. It used to be switched on only inside the window opener, and
    // the opener only ran on a physical start, so every OTA restart, panic, watchdog and brownout
    // came back with the gate OFF and admitted any phone indefinitely. Enforcement and "a person
    // just turned this on" are separate questions and are now separate calls.
    // ONE call, ONE decision. The branches above only record what happened; the rule for turning
    // that into "did a person start this board" lives in acabPhysicalStart and is host-tested.
    // The reset reason is one INPUT here, not the whole answer. See acabPhysicalStart for the two
    // wrong versions this replaced and why each failed.
    // `physicalStart` was calculated before the boot cue so this gate and the sound cannot drift
    // into two different definitions of a deliberate power-on.
    acabBlePairGateEnable();
    if (physicalStart) {
        acabBleOpenPairingWindow();
    } else {
        Serial.println("[pair] warm continuation (not a physical start) - window NOT opened; "
                       "enforcement is ON, bonded phones still reconnect");
    }
    // The board may go on air now that it has committed to staying powered and the pairing gate is
    // configured; the dual-radio path first performs its loaded battery prime immediately below.
#ifdef ACAB_DUAL_RADIO
    // Start the real operating load BEFORE seeding readBatteryPct's voltage EMA and percent slew
    // state. The first 2.0.6 implementation sampled up near the BLE identity block, while WiFi was
    // still off and the companion nRF was still parked. That unloaded rail read high; because the
    // display deliberately falls by only 1 point per six 5-second ticks, the false-high seed then
    // survived for minutes. Bring up WiFi/promiscuous RX, let the rail settle briefly, rebuild the
    // Status characteristic with that loaded reading, and only then advertise. This preserves the
    // original fix: the first phone read still contains `bat`, rather than waiting for loop's first
    // periodic status. A USB-only SKU returns -1 and continues to omit the key.
    acabScannerBegin(cfg, onDetection);
    delay(kBatteryStartupSettleMs);
    acabBleSetBatteryPct(readBatteryPct());
    acabBleSetCharging(readBatteryCharging());
    acabBleUpdateStatus();
    acabBleStartAdvertising();
#else
    // Keep the established single-radio ordering: it has no battery rail to prime.
    acabBleStartAdvertising();
    acabScannerBegin(cfg, onDetection);
#endif

    // Task watchdog on the loop task. 30s timeout with panic=true so a genuine wedge reboots into
    // a clean image. loop() never blocks for long - the companion nRF self-updates over BLE DFU,
    // off the S3 - so the loop always feeds the WDT well inside the window.
    esp_task_wdt_init(30, true);
    esp_task_wdt_add(NULL);

    Serial.println("[ACAB] scanning: Flock BLE/WiFi + drone RID + Axon (OUI 00:25:DF)");
}

#ifdef ACAB_DUAL_RADIO
// Charging state, set as a side effect of readBatteryPct (below) and read into the "chg" status
// flag. A discharging cell under load never sustains > ~4200 mV, so a smoothed rail held there
// means USB is charging. Can't perfectly tell a fully-topped-off battery from active charge -
// acceptable, the app just shows a charging indicator instead of a draining %.
static bool gBatCharging = false;
static bool readBatteryCharging() { return gBatCharging; }
// Last smoothed VBAT reading (millivolts), surfaced on the [diag] line. ~0 means no cell is
// present: the slim/USB SKU depopulates the battery, so the sense node floats to ground.
static int  gBatMv = 0;

// Battery %: the beacon board taps VBAT/2 via a 100k/100k divider on D9 (GPIO8). Read
// the calibrated ADC (x2 for the divider), EMA-smooth it, map the loaded LiPo curve.
static int readBatteryPct() {
    const int PIN = 8;                       // XIAO D9 = GPIO8 (ADC1_CH7)
    uint32_t sum = 0;
    for (int i = 0; i < 32; i++) sum += analogReadMilliVolts(PIN);
    int raw = (int)(sum / 32) * 2;           // battery millivolts
    static int mv = 0;
    mv = mv ? (mv * 3 + raw) / 4 : raw;      // smooth (WiFi TX bursts sag the rail)
    gBatMv = mv;
    // No cell present: the slim/USB SKU (and any bench rig with no battery) leaves the VBAT sense
    // node floating to ~0 (measured ~20 mV on the bench). A real cell powering or charging the board
    // never sits below ~3.0 V, so a smoothed reading this low means there is nothing to report. The
    // 2.0 V floor sits far above the ~20 mV absent reading and far below any real (even near-dead)
    // cell, so it can never hide a genuine battery. Return -1 so the status JSON OMITS "bat" (emitted
    // only when >= 0, see acab_ble_service) and both apps hide the gauge - the same path the
    // single-radio oui-spy boards already take. This is what lets ONE firmware drive both the battery
    // SKU and the battery-less slim SKU, with no phantom 0% on USB power.
    if (mv < 2000) { gBatCharging = false; return -1; }
    if (acabBoardIsRevB()) {
    // rev-B carrier ONLY: a real VBUS divider (USB 5V halved by a 100k/100k pair) lands on this ADC
    // pin, giving an AUTHORITATIVE plug state - no more inferring "charging" from the rail slope
    // (which genuinely cannot tell a plugged-at-partial cell from a rested fuller one; that
    // ambiguity is the whole reason the plugged/unplugged % disagreed). Node ~2.5 V plugged, ~0 V
    // unplugged (the XIAO 5V pad floats when unplugged and R4 pulls the node to GND); the *2 undoes
    // the divider so vbus ~5000 mV plugged. rev-A boards (the first 250) leave this pad unconnected,
    // so this whole branch is compiled out for them via the build flag and the slope heuristic runs.
    { uint32_t vs = 0; for (int i = 0; i < 8; i++) vs += analogReadMilliVolts(kVbusSensePin);
      int vbus = (int)(vs / 8) * 2;
      gBatCharging = (vbus > 3000); }          // 3.0 V threshold: clean gap between ~5000 and ~0
    } else {
    // Top-of-charge float rule, with hysteresis: assert charging above ~4250 mV held a few reads
    // (this runs every 5 s, so a brief WiFi-TX spike cannot false-positive), and do not deassert
    // until the rail drops below ~4150 mV, so a rail parked near the threshold cannot flap the
    // flag. DEAD ON THIS HARDWARE, and left in place deliberately: the 2026-07-24 calibration
    // below measured a full cell at ~4008 mV PLUGGED, so `mv` never reaches 4250 and `hi` never
    // reaches 3. The thresholds are kept rather than re-guessed downward (see the note on the
    // rise-rate rule); what actually covers the boot-on-a-charger case is the USB-host test below.
    static int hi = 0;
    if (mv > 4250) { if (hi < 3) hi++; } else { hi = 0; }
    // Rise-rate charging detect (in addition to the top-of-charge float rule above): mid-charge at
    // 3.9-4.1 V the rail never reaches 4250, so the old float-only rule left chg=false and the app
    // showed a charge-inflated % as if it were a resting number (observed: plug-in stepped 62->76).
    // A resting/draining cell only ever drifts DOWN; only a charger steps the smoothed rail up
    // ~80-150 mV in seconds. Track a recent-min that creeps up 2 mV/tick (fast enough to follow the
    // ~30-50 mV post-load rebound so it can't false-trip), and assert charging on a >=60 mV jump
    // above it. Deassert on the unplug sag: >=25 mV drop from the charging peak.
    //
    // BE CLEAR ABOUT THE SHAPE OF THIS RULE: it is TRANSITION-TRIGGERED, not a plug-state test. The
    // creep is 2 mV/tick = 24 mV/min while a real CC charge moves the rail about 5 mV/min, so the
    // 60 mV gap can only open on the STEP of a plug-in seen while running. The float rule above
    // cannot stand in for it either - its 4250 mV threshold is unreachable on this hardware, whose
    // own calibration note below says a full cell reads ~4008 mV plugged. Retuning that threshold
    // downward is NOT done here: the gap between a charger-held rail and a rested full cell under
    // scan load is only ~65 mV, measured on one cell, and a false assert would strip 90 mV off a
    // full RESTING cell - about 34 points the other way, on the reading users check most. That
    // wants a bench measurement, not a guess.
    // Which leaves a board that BOOTS already on a charger with no step to observe - handled by the
    // USB-host test below. NOTE: all of this is a best-effort proxy; the rev-B VBUS pin above
    // replaces it with a real signal.
    static int minMv = 0, peakMv = 0;
    if (minMv == 0) minMv = mv;
    if (!gBatCharging) {
        if (mv < minMv) minMv = mv; else minMv += 2;
        if (mv - minMv >= 60 || hi >= 3) { gBatCharging = true; peakMv = mv; }
    } else {
        if (mv > peakMv) peakMv = mv;
        // 25, not 40 (2026-07-24): the unplug sag is gradual through the smoothing, and every tick
        // spent still flagged charging applies the WRONG-SIGN offset to a falling rail (the 74->62
        // unplug dip). 25 exits ~2x sooner and still clears CV-taper ripple by a wide margin.
        if (peakMv - mv >= 25 && mv < 4150) { gBatCharging = false; minMv = mv; }
    }
    // USB HOST ATTACHED: the one plug signal rev-A hardware can read, and the answer to the
    // boot-on-the-charger hole the transition rules leave. The S3's USB Serial/JTAG block watches
    // for host SOF packets, so HWCDC::isPlugged() is true while a USB host is driving the bus -
    // VBUS present, therefore charging - with no voltage inference and no threshold to calibrate.
    // It already reads true at setup()'s battery prime, which is what stops the boot seed from
    // being biased the wrong way: without it a board booted on USB kept gBatCharging false all
    // session and ADDED the resting sag instead of stripping the charger push, a 160 mV error
    // worth up to ~34 points, straight into the first advertised status with chg reported false
    // beside it. (Keep that prime where it is. HWCDC seeds this flag TRUE at system init and only
    // clears it after ALLOWED_NO_SOF_TICKS - 5 ms - without a SOF, so a sample taken in the first
    // few milliseconds of boot would read plugged on a battery-only board. The prime runs after
    // the radio bring-up, far past that window.)
    //
    // IT ONLY EVER ASSERTS, AND THAT IS THE WHOLE RULE. isPlugged() is a SOF-liveness test, not a
    // VBUS test, so false does NOT mean unplugged; it means no host is talking, and three
    // physically different states share that one reading: a real unplug, a dumb wall brick or
    // power bank that supplies VBUS without ever enumerating, and a host that SUSPENDED the bus
    // while still supplying VBUS (the laptop the board is charging from goes to sleep). Only the
    // first is an unplug, and rev-A has nothing that can tell them apart, so a host that went
    // quiet is UNKNOWN, not unplugged: the rail rules above take the state back, and their 25 mV
    // sag off the charge peak is what ends a charge - the same release for all three, and the
    // release this board used before there was a host test at all.
    //
    // DEASSERTING HERE INSTEAD IS THE ORIGINAL BUG WITH ITS SIGN FLIPPED, which is why it is not
    // done: a sleeping laptop keeps charging while SOF stops, so cancelling on that reading ADDS
    // BAT_REST_OFFSET_MV to a charger-held rail (the same 160 mV / ~34 points, biased high this
    // time) on a board that IS charging, with no plug-in step left for the rise-rate rule to
    // re-detect. It would also clear chgPeak below and restart the 3-minute "terminated" timer
    // under a cell that is already full, dropping a settled 100% that then crawls back at the
    // asymmetric -1 per six ticks. Waiting for the sag is not free - it is the same latency the
    // 25 mV threshold above is justified against - but it is the exit a wall-brick unplug has
    // always taken, and paying it on a real unplug is the cheaper error than cancelling a live
    // charge every time a host sleeps.
    //
    // NOT REV-B PARITY, AND CANNOT BE: rev-B reads the real VBUS divider above, so it sees plug
    // state directly and a suspended host never registers there. The revisions agree on plug-in,
    // and on an already-full cell waiting out the "terminated" 3 minutes before releasing 100%.
    // They do NOT agree on boot-on-a-charger: rev-B sees any powered rail, while rev-A only
    // reports it when the source ENUMERATES as a USB host, so booting on a dumb wall brick or a
    // power bank still waits for the rise-rate rule. rev-A also leans on the rail rules for the
    // release rev-B reads straight off the pin.
    if (HWCDC::isPlugged()) {
        if (!gBatCharging) peakMv = mv;   // start the sag reference at the rail we begin holding
        gBatCharging = true;
    }
    }
    // Resting-vs-rail compensation, CHARGE-STATE AWARE, BOTH directions - so the displayed % tracks
    // the cell's RESTING state of charge, not the instantaneous rail. The rail lies two ways: it
    // SAGS under load when unplugged, and the charger PUSHES it up when plugged. The curve is
    // calibrated to the charged rail (full cell reads ~4008 mV plugged - compressed range, measured
    // 2026-07-24).
    //   DISCHARGING: add the load-sag back (a rested full cell settles ~65 mV low, which the raw
    //   curve calls 86%); tapered, full near 3.9 V, fading to 0 by 3.6 V so the empty cutoff is
    //   untouched. Validated on hardware (held 100% unplugged).
    //   CHARGING: subtract the charger push, UNLESS the charge has terminated. Without this a
    //   half-charged cell on the cable reads its ~4.0 V charge rail as near-100%, then CLIFFS ~40
    //   points the instant you unplug (observed: 99% plugged -> 56% rested overnight, with a CLEAN
    //   deep-sleep in between, so the cell barely moved - the 99% was the lie). Biasing the charging
    //   read LOW is deliberate: unplugging then steps the number UP a little (reads fine) instead of
    //   down a cliff (reads broken). "Terminated" = the rail plateaued at its peak near full with no
    //   further rise for 3 min (CV done), so a genuinely topped-off cell on the cable still shows
    //   100%. millis() resets to 0 on the deep-sleep wake boot, so a boot-while-charging just waits
    //   out the 3 min fresh - conservative, never a false full.
    const int BAT_REST_OFFSET_MV = 70;    // discharge: rail sags this far under load near full
    const int BAT_CHG_OFFSET_MV  = 90;    // charge: charger holds the rail this far above resting OCV
    static int      chgPeak   = 0;        // running peak of the charge rail this session
    static uint32_t plateauMs = 0;        // when the rail last stopped climbing (CV-done proxy)
    int mapMv = mv;
    if (!gBatCharging) {
        chgPeak = 0;   // reset the charge tracker so the NEXT plug-in re-detects termination fresh
        if (mv > 3600) {
            int frac = (mv >= 3900) ? 100 : (mv - 3600) * 100 / 300;   // 100 above 3.9 V, ramps to 0 at 3.6 V
            mapMv += BAT_REST_OFFSET_MV * frac / 100;
        }
    } else {
        if (mv > chgPeak + 3) { chgPeak = mv; plateauMs = millis(); }   // still climbing -> not full yet
        bool terminated = (chgPeak >= 3985) && (millis() - plateauMs >= 180000UL);
        if (!terminated) {
            int frac = (mv >= 3900) ? 100 : (mv > 3600 ? (mv - 3600) * 100 / 300 : 0);
            mapMv -= BAT_CHG_OFFSET_MV * frac / 100;   // strip the charger push -> resting-SoC estimate
        }
    }
    // Curve calibrated to THIS hardware's actual readings (XIAO ESP32-S3 VBAT tap): a fully-charged
    // cell reads ~4.0V, NOT 4.2, so 100% anchors at 4000 - the old 4150 anchor was unreachable and
    // capped the gauge at 85%. The <=3900 tail is the original loaded curve, unchanged.
    static const int curve[][2] = {          // loaded LiPo (this board): {millivolts, percent}
        {4000,100},{3950,88},{3900,72},{3800,58},{3700,45},
        {3600,30},{3500,18},{3400,9},{3300,3},{3000,0} };
    const int N = sizeof(curve) / sizeof(curve[0]);
    int pct = 0;
    if (mapMv >= curve[0][0]) pct = 100;
    else for (int i = 1; i < N; i++)
        if (mapMv >= curve[i][0]) {
            pct = curve[i][1] + (mapMv - curve[i][0]) * (curve[i-1][1] - curve[i][1]) /
                                (curve[i-1][0] - curve[i][0]);
            break;
        }
    // Slew-limit what we report (max +/-2 per 5s tick, ~24%/min): state transitions (plug, unplug,
    // load spikes) step the raw map, but a battery's true % never moves that fast. First reading
    // snaps so boot shows truth immediately.
    // ASYMMETRIC slew (2026-07-24, after the 71->62-in-45s unplug drop proved plug-state can't be
    // equalized in software): this board has no VBUS sense pin (BAT_SENSE only), a dumb wall brick
    // never enumerates USB, and at partial charge the charger-held rail is simply a different number
    // than the rested rail, so the plugged and unplugged estimates WILL disagree by a handful of
    // points. What users notice is not the gap, it's the cliff. So: climbs stay quick (+2 per 5 s
    // tick, ~24%/min, tracks a real charge fine), but drops crawl (-1 per SIX ticks = -2%/min).
    // A real discharge under scan load is ~0.42%/min (~4 h measured runtime, eco off), well under the
    // 2%/min slew cap, so the crawl NEVER lags a true discharge; it only stretches the unplug re-estimate over a few
    // quiet minutes instead of a 45-second on-screen slide.
    static int shown = -1;
    static uint8_t dropTick = 0;
    if (shown < 0) shown = pct;
    else if (pct > shown) { shown += (pct - shown > 2) ? 2 : (pct - shown); dropTick = 0; }
    else if (pct < shown) { if (++dropTick >= 6) { shown--; dropTick = 0; } }
    else dropTick = 0;
    return shown;
}

// The shared BLE service holds its link-action lease across these callbacks. Keep every policy
// check that precedes the physical side effect inside the callback too: returning a bool and then
// checking OTA/revision in loop() would reopen the exact check->action boundary race the lease
// exists to close.
static void runRequestedNrfDfu(void*) {
    if (!otaInProgress()) nrfEnterDfu();
}

static void runRequestedPowerOff(void*) {
    if (acabBoardIsRevB() && !otaInProgress()) powerOffDeepSleep(true);
}
#endif

void loop() {
    esp_task_wdt_reset();   // pet the task WDT each pass
    // Re-arm offline capture on a timer while "record everything" is on, so a board left
    // unattended records a REVISIT instead of collapsing a week into one row per device.
    // Self-throttling and a no-op when the mode is off or a phone is connected.
    acabScannerBufferAllTick();

    // "App linked" chirp on the rising edge of a client connection (and arm the
    // first-catch reveal for the session). Polled here because the core BLE service
    // can't reach up into the app's alert code.
    static bool sWasConnected = false;
    bool nowConnected = acabBleClientConnected();
    if (nowConnected && !sWasConnected) alertsConnected();
    sWasConnected = nowConnected;

    // OTA self-heal: a freshly-updated image that reaches a stable uptime is presumed good,
    // so disarm the rollback even if the app never sends {"ota":{"confirm":true}}. Rollback
    // then only fires if the new image fails to run this long. (No-op once confirmed/healthy.)
    if (otaOnTrial() && millis() > 20000) {
        if (otaMarkHealthy()) {
            Serial.println("[ota] trial image healthy: scanner pipeline ready; rollback disarmed");
        } else if (millis() > 60000) {
            Serial.println("[ota] trial health deadline missed; rebooting to trigger rollback");
            delay(50);
            ESP.restart();
        }
    }

#ifdef ACAB_DUAL_RADIO
    if (swSensePollOff()) powerOffDeepSleep(true);   // rev-A: slide flipped to 'off'; rev-B: button held ~1.5s (announce: real running->off)
    uartIngestPoll();   // pull BLE adverts forwarded by the companion nRF52840
    nrfConsolePoll();   // bench: type "nrfdfu" on USB serial to boot the nRF into BLE OTA DFU
    // App-requested BLE DFU ({"nrfdfu":true}) - drain the latch here, off the NimBLE host task.
    // Drain UNCONDITIONALLY so a request written mid-OTA is consumed now, not left to fire when the
    // OTA later ends or aborts. Gated on OTA: if the S3 is mid self-update, drop it (the user
    // re-taps) rather than kick the co-processor into DFU. Once triggered, the nRF reboots into its
    // bootloader and the app drives the transfer. The lease re-checks the secure link and
    // physical-start window, and stays held through this callback, so a queued request cannot fire
    // after that authorizing session ends.
    acabBleRunNrfDfuRequest(runRequestedNrfDfu);
    // App-requested power-off ({"poweroff":true}) - SAME deferred-latch discipline as the nrfdfu
    // drain above, and for the same reason: powerOffDeepSleep blocks on the multi-second nRF park
    // handshake and then NEVER RETURNS, so running it on the NimBLE host task (the write callback)
    // would freeze the whole BLE stack and kill the link with no clean disconnect. The callback only
    // sets the latch; the real shutdown happens HERE on the loop task. rev-B ONLY: on a rev-A slide
    // board the wake line is held LOW by the slide, so deep sleep would re-wake instantly - drop the
    // request there (the app never offers the button on rev-A anyway). Dropped mid-OTA too, so a
    // self-update is not interrupted (the user re-taps). announce=true: this is a real running->off,
    // so the power-down cue plays, unlike a boot-gate re-sleep.
    acabBleRunPowerOffRequest(runRequestedPowerOff);
    // Keep asking the nRF its version until we actually have one. It announces the version at its
    // own boot AND replies to a "V" query, but a single boot-time query (setup) can be lost to the
    // advert flood or the S3-boot reset race - leaving gNrfVersion == -1, so the status doc omits
    // "nrfv" and the app can NEVER offer the co-processor update (the offer is gated on a known nRF
    // version). Re-query until we have it, then stop: no steady-state UART noise, and the single
    // config re-assert triggered by the first reply is correct. A later nRF reboot/DFU re-announces
    // its version unprompted, so freshness after this point does not depend on us polling.
    { static uint32_t lastNrfVerQ = 0;
      if (gNrfVersion < 0 && millis() - lastNrfVerQ > 2000) { lastNrfVerQ = millis(); acabScannerSendCoProcCmd("V"); } }
    static uint32_t lastDiag = 0;
    if (millis() - lastDiag > 5000) {
        lastDiag = millis();
        // bonds + pairw make the pairing window observable from a USB console: bonds is how many
        // phones the BOARD still has stored (a phone forgetting its side does NOT remove ours), and
        // pairw is seconds left in the new-phone window, 0 once closed.
        Serial.printf("[diag] wifi_seen=%lu ble_seen=%lu | nRF adv=%lu fwd=%lu scan=%d bb=%lu bat_mv=%d"
                      " | bonds=%d pairw=%lus\n",
                      (unsigned long)acabScannerWifiSeen(), (unsigned long)acabScannerBleSeen(),
                      (unsigned long)acabScannerCoProcAdvSeen(), (unsigned long)acabScannerCoProcForwarded(),
                      (int)acabScannerCoProcScanning(), (unsigned long)acabScannerCoProcBbCount(), gBatMv,
                      acabBleBondCount(),
                      (unsigned long)(acabBlePairWindowRemainingMs() / 1000));
#ifdef ACAB_DIAG_WIFI
        // Capture builds only. diag_drop>0 means the promiscuous callback outran the serial
        // task and records were thrown away, so the capture is INCOMPLETE: an absent signal in
        // that log proves nothing. Printed on its own line so a grep for it is unambiguous.
        // app=1 means a phone is CONNECTED right now, which is the difference between "the
        // firmware never detected it" and "the firmware detected it and the app never saw it".
        // bufen/buf say whether the offline buffer would have caught it while the app was away.
        // The 2026-08-08 drive could not tell those apart: bonds=2 only proves bonds exist.
        // falcon_data / falcon_mgmt / falcon_macs are the Falcon-OUI mode accounting (see
        // FalconRec in acab_scanner.cpp). They answer, on any drive, the question the app's
        // exported history raised: every WiFi ALPR hit this project ever recorded matched on a
        // wildcard PROBE, and a unit that associates to its backhaul stops probing. A drive that
        // returns falcon_mgmt=0 with falcon_data>0 says the hardware is present and associated,
        // which no shipping rule can currently see. falcon_full>0 means FALCON_MAX overflowed and
        // falcon_macs is a floor, not a count.
        Serial.printf("[diag] wifi_diag sent=%lu dropped=%lu app=%d bufen=%d buf=%lu"
#ifdef ACAB_CAPTURE_BUILD
                      " watch_data=%lu falcon_data=%lu falcon_mgmt=%lu falcon_macs=%lu falcon_full=%lu"
                      " axon_ble=%lu moto_ble=%lu vendor_macs=%lu vendor_full=%lu"
                      " alpr_ble=%lu alpr_wifi=%lu alpr_macs=%lu alpr_full=%lu"
#endif
                      "\n",
                      (unsigned long)acabScannerWifiDiagSent(),
                      (unsigned long)acabScannerWifiDiagDropped(),
                      acabBleClientConnected() ? 1 : 0,
                      detLogEnabled() ? 1 : 0,
                      (unsigned long)detLogCount()
#ifdef ACAB_CAPTURE_BUILD
                      , (unsigned long)acabScannerWatchDataSeen()
                      , (unsigned long)acabScannerFalconData()
                      , (unsigned long)acabScannerFalconMgmt()
                      , (unsigned long)acabScannerFalconMacs()
                      , (unsigned long)acabScannerFalconTableFull()
                      , (unsigned long)acabScannerVendorAxon()
                      , (unsigned long)acabScannerVendorMoto()
                      , (unsigned long)acabScannerVendorMacs()
                      , (unsigned long)acabScannerVendorFull()
                      , (unsigned long)acabScannerAlprCandidateBleSeen()
                      , (unsigned long)acabScannerAlprCandidateWifiSeen()
                      , (unsigned long)acabScannerAlprCandidateMacs()
                      , (unsigned long)acabScannerAlprCandidateTableFull()
#endif
                      );
#endif
    }
#endif
    // push a status notify every 5s to keep the app's uptime/count current
    static uint32_t lastStatus = 0;
    uint32_t now = millis();
    if (now - lastStatus > 5000) {
        lastStatus = now;
#ifdef ACAB_DUAL_RADIO
        acabBleSetBatteryPct(readBatteryPct());   // fresh battery % into the status notify
        acabBleSetCharging(readBatteryCharging()); // ...and the charging flag (readBatteryPct set it)
#endif
        acabBleUpdateStatus();
    }
    // SECOND AT-REST SURFACE. det_log's wipe covers its own ring and nothing else, and the
    // retained ESP-IDF core dump at 0x7F0000 is a separate flash region no path has ever erased.
    // An ELF dump holds each task's live stack, so a panic on the NimBLE host task can leave an
    // in-flight detection (MAC plus the phone-pushed lat/lon) or a just-decoded at-rest key in
    // flash on a board that never opted into the buffer at all, and it would outlive both
    // {"clearlog"} and the boot-count self-clean while each reported success. See
    // coredump_report.h.
    //
    // Ride the SAME explicit user intent, so "erase what this board stored" means both regions.
    // clearlog, a key change, and buffer:false persist a separate erase-generation token; this
    // tick consumes it even when the ring sweep was already pending or the token was restored
    // after power loss. A boot auto-wipe with NO explicit token still preserves the dump setup()
    // has just printed decode instructions for. The rule lives in acabCoredumpWipeTick() rather
    // than here because mesh-detect needs the identical behaviour, and the 64 KB cache-off erase
    // must run on this loop task. It defers past the ring sweep that acabBleDrainTick pumps below
    // so a normal pass never takes two block erases back to back. Free on a clean boot.
    acabCoredumpWipeTick();
    acabBleDrainTick();   // stream buffered detections back on the app's sync request
    acabBleOtaWatchdog(); // abort + un-quiesce a stalled OTA session (missed link drop)
    delay(20);
}
