/*
 * ACAB OUI-Spy - local alert feedback (buzzer + onboard LED).
 * Each target class gets its own audible signature, so you can tell what was
 * detected without looking at the phone. Buzzer volume and on/off come from the
 * app and persist across reboots.
 */
#ifndef ACAB_ALERTS_H
#define ACAB_ALERTS_H

#include "detection.h"

// XIAO ESP32-S3 pins (override via build flags if your board differs).
#ifndef ACAB_BUZZER_PIN
#define ACAB_BUZZER_PIN 3
#endif
#ifndef ACAB_LED_PIN
#define ACAB_LED_PIN 21      // onboard orange LED, inverted (LOW = on)
#endif

void alertsInit();
void alertsBootJingle();

// The mirror image of the boot jingle: a short DESCENDING "powering down" motif that ENDS LOW,
// where boot rises and ends high ("...alive?"). Play it on a real running->off transition so the
// user can HEAR off from on - the faint 25ms heartbeat LED never made that legible, and the red
// light is the charger's, not ours. Blocking (~0.7s), safe to call right before deep sleep, and
// honors the buzzer/LED master flags (a "lights out" board stays silent+dark; its off signal is
// the app dropping the BLE link instead).
void alertsPowerDown();

// Play the "app linked" chirp once when the BLE connection comes up, and arm the
// first-contact "reveal" sting for this session. Call on the rising edge of a link.
void alertsConnected();

// Queue a non-blocking alert for a detection. Only `isNew` hits beep.
void alertsSignal(AcabDeviceType type, bool isNew);

// Master audio on/off. Persisted to NVS.
void alertsSetBuzzerEnabled(bool on);
bool alertsBuzzerEnabled();

// Buzzer loudness, 0..100. 0 is silent (LED still flashes). Persisted to NVS.
void alertsSetVolume(uint8_t volume);
uint8_t alertsVolume();

// Short preview beep at the current volume, so you can hear the level (the app
// fires this when the volume slider is released). Silent while muted.
void alertsBeepTest();

// Onboard LED master on/off. On (default) = a slow idle "alive" heartbeat + the
// detection flashes + the boot sweep, so a first-time board never looks dead. Off
// ("lights out") = fully dark, for covert/stationary deploys. Persisted to NVS.
void alertsSetLedEnabled(bool on);
bool alertsLedEnabled();

#endif // ACAB_ALERTS_H
