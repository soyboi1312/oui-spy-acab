/*
 * ACAB OUI-Spy - alert feedback implementation.
 *
 * The buzzer runs off an LEDC PWM channel so loudness is adjustable: tone
 * frequency sets the pitch, PWM duty sets the volume (0 = silent, ~50% duty =
 * loudest for a piezo). A dedicated FreeRTOS task drains the alert queue, so the
 * tone delays never stall the BLE/WiFi scanners.
 */
#include "alerts.h"
#include <Arduino.h>
#include <Preferences.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>

#define BUZZER_LEDC_CHANNEL 0
#define BUZZER_LEDC_RES     8       // 8-bit duty (0..255)
#define BUZZER_DUTY_MAX     128     // ~50% duty = loudest into a piezo
// This constant only started actually reaching the LEDC timer on 2026-08-25, when buzzerTone()
// stopped going through ledcWriteTone (which forced the channel to 10-bit - see the note there).
// Every cue and pattern now drives 4x the duty it did before at the same volume setting, so the
// 60% scalePct the boot and power-down cues pass still wants a bench listen on real hardware.

static QueueHandle_t gAlertQ = nullptr;
static TaskHandle_t  gAlertTask = nullptr;   // kept so shutdown can suspend it and own the buzzer alone
static volatile bool    gBuzzer = true;
static volatile uint8_t gVolume = 80;   // 0..100
// Onboard LED master. On = idle heartbeat + detection flashes + boot sweep; "lights out" = false.
// Default on so a first-time board visibly shows it's alive. Gates ledOn() below, so one flag
// silences every LED path (heartbeat, patterns, jingle) at once.
static volatile bool    gLedEnabled = true;

// How often the idle heartbeat pulses when no alert is queued (the alertTask wakes on this
// timeout to flash the LED briefly, so a running board never looks dead).
#define ACAB_LED_HEARTBEAT_MS 2000

// Queue sentinels: not detection patterns, but "device voice" sounds that ride the
// same non-blocking queue. Values sit well above any real AcabDeviceType (1..9).
static const AcabDeviceType ACAB_ALERT_TEST    = (AcabDeviceType)0xFE;   // volume preview
static const AcabDeviceType ACAB_ALERT_CONNECT = (AcabDeviceType)0xFD;   // app linked
static const AcabDeviceType ACAB_ALERT_REVEAL  = (AcabDeviceType)0xFC;   // first catch of a session
static const AcabDeviceType ACAB_ALERT_POWER_ON = (AcabDeviceType)0xFB;  // button-hold accepted

// Alert mode controls detection/session noise, not deliberate on/off feedback. Keep that choice
// explicit per call instead of temporarily flipping gBuzzer: the alert task runs concurrently,
// and a global override could let a queued detection sound during a power cue.
enum class AudioPurpose : uint8_t { UserAlert, PowerState };

// Armed at boot and on each app connection; the next NEW detection plays the "reveal"
// sting in place of its class pattern, so the first catch of a session lands like the
// They Live moment , the hidden signal surfacing , then re-arms only on the next connect.
static volatile bool gArmReveal = false;

// Burst coalescing: once a class sounds, ignore further NEW hits of that SAME class for
// this window, so a crowd of one type (e.g. 20 body cams at a protest, a Flock-dense
// intersection) is a single alert instead of a back-to-back storm. Buzzer-only , every
// device is still counted, logged, mapped, and buffered upstream. Per-type, so a mixed
// crowd still tells you WHICH kinds are around.
#define ALERT_COALESCE_MS 2500
static uint32_t gLastAlertMs[ACAB_TYPE_COUNT] = {0};   // millis() of the last alert per type (0 = never)

// --- persistence (NVS) ---
static void loadAudio() {
    Preferences p;
    p.begin("acab-audio", true);
    gBuzzer = p.getBool("buzz", true);
    gVolume = p.getUChar("vol", 80);
    gLedEnabled = p.getBool("led", true);   // default on
    p.end();
}
static void saveAudio() {
    Preferences p;
    p.begin("acab-audio", false);
    p.putBool("buzz", gBuzzer);
    p.putUChar("vol", gVolume);
    p.putBool("led", gLedEnabled);
    p.end();
}

void alertsSetBuzzerEnabled(bool on) { gBuzzer = on; saveAudio(); }
bool alertsBuzzerEnabled() { return gBuzzer; }

void alertsSetVolume(uint8_t v) {
    if (v > 100) v = 100;
    gVolume = v;
    saveAudio();
}
uint8_t alertsVolume() { return gVolume; }

// --- low-level output ---
// ledOn honors the master flag, so "lights out" silences every LED path (heartbeat, alert
// patterns, boot sweep) without touching each call site.
static inline void ledOn()  { digitalWrite(ACAB_LED_PIN, gLedEnabled ? LOW : HIGH); }
static inline void ledOff() { digitalWrite(ACAB_LED_PIN, HIGH); }

void alertsSetLedEnabled(bool on) {
    gLedEnabled = on;
    if (!on) ledOff();   // go dark immediately, don't wait for the next pattern to end
    saveAudio();
}
bool alertsLedEnabled() { return gLedEnabled; }

static void buzzerOff() { ledcWrite(BUZZER_LEDC_CHANNEL, 0); }

// Start a tone at `freq`, scaled to the current volume, then by an optional per-call scale
// (0-100%, default full). Power-state cues bypass the detection-alert mute so a battery unit can
// always confirm a deliberate on/off action. Volume 0 remains absolute silence for users who need
// it, and LED output stays independently governed by the lights-out setting.
static void buzzerTone(int freq, int scalePct = 100,
                       AudioPurpose purpose = AudioPurpose::UserAlert) {
    bool mutedAlert = !gBuzzer && purpose == AudioPurpose::UserAlert;
    if (mutedAlert || gVolume == 0 || freq <= 0) { buzzerOff(); return; }
    // ledcSetup, NEVER ledcWriteTone. ledcWriteTone hard-codes duty_resolution = 10 and stamps
    // channels_resolution[chan] = 10 (framework-arduinoespressif32 3.20017,
    // cores/esp32/esp32-hal-ledc.c:118-148), so it silently retimed this channel to 10-bit behind
    // the 8-bit BUZZER_DUTY_MAX below and undid the ledcSetup in alertsInit() before the first
    // note was ever heard: the duty written on the next line landed as 128/1024 = 12.5% instead of
    // the intended 128/256 = 50%, a quarter of the design duty (~8 dB down at the fundamental), so
    // no volume setting could reach the piezo's loud point. It also writes a duty of its own
    // (0x1FF) that we then have to overwrite. ledcSetup programs the same timer frequency at OUR
    // resolution and writes no duty, and costs the same - both are one ledc_timer_config call, so
    // nothing new lands on the per-note path (caw() re-enters here every 8 ms).
    ledcSetup(BUZZER_LEDC_CHANNEL, freq, BUZZER_LEDC_RES);
    uint32_t duty = (uint32_t)gVolume * scalePct / 100 * BUZZER_DUTY_MAX / 100;
    ledcWrite(BUZZER_LEDC_CHANNEL, duty);
}

static void beep(int freq, int durMs, int scalePct = 100,
                 AudioPurpose purpose = AudioPurpose::UserAlert) {
    buzzerTone(freq, scalePct, purpose);
    ledOn();
    vTaskDelay(pdMS_TO_TICKS(durMs));
    ledOff();
    buzzerOff();
}

// Harsh descending sweep - the crow "caw" used for Flock. scalePct softens it for the boot
// whoosh only (Flock passes 100 by default, so its loudness is unchanged).
static void caw(int startF, int endF, int durMs, int scalePct = 100,
                AudioPurpose purpose = AudioPurpose::UserAlert) {
    int steps = durMs / 8;
    if (steps < 1) steps = 1;
    float fStep = (float)(endF - startF) / steps;
    ledOn();
    for (int i = 0; i < steps; i++) {
        int f = startF + (int)(fStep * i);
        if (f < 100) f = 100;
        buzzerTone(f, scalePct, purpose);
        vTaskDelay(pdMS_TO_TICKS(8));
    }
    buzzerOff();
    ledOff();
}

// KITT "voice modulator": wobble the pitch fast around a center. A vibrato the piezo
// can actually voice (one tone, just modulated), LED steady on through the wobble.
static void warble(int centerF, int depth, int cycles, int halfMs, int scalePct = 100,
                   AudioPurpose purpose = AudioPurpose::UserAlert) {
    if (halfMs < 1) halfMs = 1;
    ledOn();
    for (int i = 0; i < cycles; i++) {
        buzzerTone(centerF + depth, scalePct, purpose);
        vTaskDelay(pdMS_TO_TICKS(halfMs));
        buzzerTone(centerF - depth, scalePct, purpose);
        vTaskDelay(pdMS_TO_TICKS(halfMs));
    }
    buzzerOff();
    ledOff();
}

// "app connected" - the board's own voice: a KITT-style warble + a short rising
// "linked" confirm. A device event (rare), so a touch more expressive than a hit.
static void playConnect() {
    warble(3200, 280, 8, 16);            // ~256ms voice-modulator wobble around 3.2 kHz
    vTaskDelay(pdMS_TO_TICKS(40));
    caw(3000, 3800, 120);                // rising "we're linked"
}

// "first contact" - a hidden signal surfacing (the They Live reveal): a fast dissonant
// two-tone stutter, like tuning into a broadcast, resolving up to a clear tone. Only
// the first new hit of a session gets this, so it stays a moment, not a nag.
static void playReveal() {
    for (int i = 0; i < 12; i++) {       // ~360ms of dissonant "transmission"
        buzzerTone((i & 1) ? 3500 : 2550);
        if (i & 1) ledOn(); else ledOff();
        vTaskDelay(pdMS_TO_TICKS(30));
    }
    buzzerOff();
    vTaskDelay(pdMS_TO_TICKS(35));
    caw(2800, 3900, 170);                // resolve: the thing is revealed
    ledOff();
}

// Immediate confirmation that the rev-B hold-to-start gate committed to ON. This is separate from
// the volume-preview beep, which must remain silent when detection alerts are muted.
static void playPowerOnAck() {
    beep(3000, 130, 100, AudioPurpose::PowerState);
}

// A different sound per target class.
static void playPattern(AcabDeviceType type) {
    // Frequencies sit in the PKLCS1212 piezo's loud band (~2.4-3.9 kHz, peak 4 kHz);
    // each class stays distinct by rhythm and sweep contour, not by low pitch.
    switch (type) {
        case ACAB_FLOCK_CAMERA:           // two sharp descending caws
            caw(3800, 2600, 160); vTaskDelay(pdMS_TO_TICKS(60)); caw(3700, 2500, 160);
            break;
        case ACAB_FLOCK_RAVEN:            // rising alarm then caw (audio sensor)
            caw(2500, 3800, 110); vTaskDelay(pdMS_TO_TICKS(40)); caw(3800, 2500, 200);
            break;
        case ACAB_AXON_BODYCAM:           // three quick equal blips
            beep(3100, 90); vTaskDelay(pdMS_TO_TICKS(60));
            beep(3100, 90); vTaskDelay(pdMS_TO_TICKS(60));
            beep(3100, 90);
            break;
        case ACAB_DRONE:                  // five-note motif (up-up-down-down-up)
            beep(3200, 120); beep(3600, 120); beep(2900, 120);
            beep(2500, 120); beep(3000, 180);
            break;
        case ACAB_TRACKER:                // silent: opt-in and can flood, so no beep
            break;
        case ACAB_GLASSES:                // recording glasses: a short KITT voice-modulator
            warble(3400, 220, 6, 14);     // wobble - distinct from the caws/blips of the others
            break;
        case ACAB_NETCAM:                 // network camera: two flat RISING blips.
            // Distinct by rhythm and contour, per the note above: nothing else uses two FLAT
            // tones (body cam is three equal, Flock is two DESCENDING sweeps), and the rise
            // separates it from Flock's fall. It had no case at all until 2026-07-31 and fell to
            // the anonymous default beep, which stopped being acceptable once the Ring/Wyze OUIs
            // made this the category most likely to fire on a residential street.
            beep(2600, 110); vTaskDelay(pdMS_TO_TICKS(70)); beep(3300, 110);
            break;
        case ACAB_WATCHED:                // user-starred: the most attention-grabbing sound we
            playReveal();                 // have (the reveal sting) - the user explicitly asked
            break;                        // to be told about this exact device
        default:
            // Unclassified / future type. Anything with a real category should get its own case
            // above rather than land here, or the user cannot tell it apart from anything else.
            beep(2800, 120);
            break;
    }
}

// FreeRTOS task: drain the alert queue and play patterns, off the callers' path. When the
// queue is idle it wakes on a timeout to pulse the LED, a slow "alive" heartbeat so a running
// board never looks dead (the fix for first-timer "is it even on?"). ledOn respects the master
// flag, so "lights out" leaves the pulse dark.
static void alertTask(void*) {
    AcabDeviceType type;
    for (;;) {
        if (xQueueReceive(gAlertQ, &type, pdMS_TO_TICKS(ACAB_LED_HEARTBEAT_MS)) == pdTRUE) {
            if      (type == ACAB_ALERT_TEST)     beep(3000, 130);   // volume preview (near piezo peak)
            else if (type == ACAB_ALERT_CONNECT)  playConnect();
            else if (type == ACAB_ALERT_REVEAL)   playReveal();
            else if (type == ACAB_ALERT_POWER_ON) playPowerOnAck();
            else                                  playPattern(type);
        } else {
            ledOn();                          // idle heartbeat: a brief flash, then back to dark
            vTaskDelay(pdMS_TO_TICKS(25));
            ledOff();
        }
    }
}

// Set up the LED pin, the LEDC PWM for the buzzer, and the alert task.
void alertsInit() {
    pinMode(ACAB_LED_PIN, OUTPUT);
    ledOff();

    ledcSetup(BUZZER_LEDC_CHANNEL, 2000, BUZZER_LEDC_RES);
    ledcAttachPin(ACAB_BUZZER_PIN, BUZZER_LEDC_CHANNEL);
    buzzerOff();

    loadAudio();

    gAlertQ = xQueueCreate(16, sizeof(AcabDeviceType));
    xTaskCreatePinnedToCore(alertTask, "acabAlert", 4096, nullptr, 1, &gAlertTask, 1);
    gArmReveal = true;   // a standalone (no-app) board still reveals its first catch
}

void alertsBootJingle(bool physicalStart) {
    // "Johnny Five wakes up" (2026-07-26, replaces the KITT whoosh - its symmetric up/down sweep
    // pairs read as a COP SIREN, the one thing this product must never sound like). Johnny Five's
    // voice is the opposite of a siren: asymmetric, bouncy, staccato, ending on a rising
    // "question" inflection - nothing repeats, nothing sweeps back down. The motif:
    //   1. servo spin-up "vwip"          - one quick low rise, the head lifting
    //   2. bouncy ascending "da-da-DEE"  - three staccato steps, wider interval each hop
    //   3. curious trill                  - fast warble, the robot cocking its head
    //   4. rising "...alive?"            - a final upward sweep that ENDS HIGH, unresolved
    // ~0.9s total (the whoosh was ~2.8s - snappier fits the character). Cues at 60% scale
    // (30 -> 60 2026-07-26, user wanted it louder); detection alerts untouched. Band stays
    // 500-2500 Hz, below the piezo's shrieky ~4k resonance - never above ~2500 (whoosh-era rule).
    // MUTE ALWAYS WINS HERE (2026-08-24). An earlier draft let physicalStart bypass alert mute as
    // a PowerState cue, but physicalStart counts EVERY ESP_RST_POWERON as deliberate - and on the
    // button-less deploys (slim always-on SKU, USB wall power, covert installs) an unattended
    // power interruption and restore is indistinguishable from a hand on the plug, so a MUTED
    // board would have announced itself at the saved volume at 3am. A muted board never plays the
    // boot jingle. The PowerState bypass stays reserved for cues that always follow an explicit
    // user action (the hold-to-start ack, the app-driven shutdown). physicalStart still feeds the
    // pairing window in setup(); for audio it is deliberately unused.
    (void)physicalStart;
    constexpr AudioPurpose purpose = AudioPurpose::UserAlert;
    caw(500, 1050, 140, 60, purpose);                 // 1. servo "vwip"
    vTaskDelay(pdMS_TO_TICKS(40));
    beep(1150, 60, 60, purpose); vTaskDelay(pdMS_TO_TICKS(30));   // 2. da
    beep(1450, 60, 60, purpose); vTaskDelay(pdMS_TO_TICKS(30));   //    da
    beep(1850, 95, 60, purpose); vTaskDelay(pdMS_TO_TICKS(50));   //    DEE
    warble(1700, 220, 3, 22, 60, purpose);            // 3. head-cock trill
    caw(1500, 2500, 170, 60, purpose);                // 4. "...alive?" - ends high, never resolves down
}

void alertsPowerDown() {
    // Own the buzzer + LED alone for the shutdown cue. The alertTask time-slices with this (loop) task
    // on core 1, so without this a detection pattern firing at the same instant would overwrite the
    // cue's tone and toggle the LED mid-motif; and detections queued during the multi-second nRF park
    // that follows would keep beeping AFTER the cue, so it would not be the last thing heard. Suspend
    // the alert task and clear whatever it left mid-pattern, so the descending "off" motif plays clean
    // and is the final sound. We only get here on a committed power-off, so the task never resumes.
    if (gAlertTask) vTaskSuspend(gAlertTask);
    buzzerOff();
    ledOff();
    // Johnny Five going back to sleep. The EXACT inverse of the boot jingle above: where boot steps
    // UP (da-da-DEE) and ends on a rising, unresolved "...alive?", this steps DOWN and settles to the
    // floor - the ear reads "off" the moment it resolves low. Same 500-2500 Hz band and 60% scale as
    // boot; and it still obeys the whoosh-era rule that nothing SWEEPS BACK UP (a symmetric up/down
    // pair reads as a siren) - this only ever descends. The LED master still governs the light,
    // but detection-alert mute does not suppress this deliberate off confirmation. Volume 0 is
    // still fully silent. ~0.7s, before the nRF park handshake, so deep sleep never clips it.
    constexpr AudioPurpose purpose = AudioPurpose::PowerState;
    beep(1850, 90, 60, purpose); vTaskDelay(pdMS_TO_TICKS(30));   // DEE   - boot's top note, now the START
    beep(1450, 70, 60, purpose); vTaskDelay(pdMS_TO_TICKS(30));   //  da   - stepping down (boot stepped up)
    beep(1150, 70, 60, purpose); vTaskDelay(pdMS_TO_TICKS(40));   //   da
    warble(950, 160, 3, 26, 60, purpose);                          // slowing "spin-down" wobble, lower + lazier
    caw(1400, 500, 220, 60, purpose);                              // settle: sweep DOWN to the floor, ends low = off
}

void alertsPowerOnAck() {
    if (!gAlertQ) return;
    AcabDeviceType t = ACAB_ALERT_POWER_ON;
    xQueueSend(gAlertQ, &t, 0);
}

// Fire the "app linked" chirp and re-arm the first-catch reveal for this session.
// Enqueue only (called on the BLE link coming up), so it never blocks that path.
void alertsConnected() {
    if (!gAlertQ) return;
    gArmReveal = true;
    AcabDeviceType t = ACAB_ALERT_CONNECT;
    xQueueSend(gAlertQ, &t, 0);
}

void alertsSignal(AcabDeviceType type, bool isNew) {
    if (!isNew || !gAlertQ) return;       // only beep on the first sighting

    // First real infrastructure hit of a session earns the "reveal" sting. Trackers are
    // opt-in and often the user's own AirTag, so they do not spend the reveal: it waits
    // for actual surveillance gear. Desert nearby rows do not spend it either - Desert is
    // the opt-in report-everything mode, and a board that boots into persisted Desert
    // would otherwise burn the session's one sting on the first passing phone.
    // (Called on the single sink task, so no lock needed.)
    if (gArmReveal && type != ACAB_TRACKER && type != ACAB_NEARBY_DEVICE) {
        gArmReveal = false;
        if (type < ACAB_TYPE_COUNT) gLastAlertMs[type] = millis();   // open its coalesce window too
        AcabDeviceType r = ACAB_ALERT_REVEAL;
        xQueueSend(gAlertQ, &r, 0);
        return;
    }

    // Coalesce a same-type burst (see gLastAlertMs): stay quiet if this class alerted
    // within the last ALERT_COALESCE_MS. Silent types (tracker) fall through harmlessly ,
    // their pattern is empty, so suppressing or not makes no sound either way.
    if (type < ACAB_TYPE_COUNT) {
        uint32_t now = millis();
        uint32_t last = gLastAlertMs[type];
        if (last != 0 && (now - last) < ALERT_COALESCE_MS) return;   // inside the window: hold the buzzer
        gLastAlertMs[type] = now;
    }
    xQueueSend(gAlertQ, &type, 0);        // drop if the queue is full, never block
}

void alertsBeepTest() {
    if (!gAlertQ) return;
    AcabDeviceType t = ACAB_ALERT_TEST;
    xQueueSend(gAlertQ, &t, 0);
}
