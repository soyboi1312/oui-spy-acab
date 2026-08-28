/*
 * ACAB OUI-Spy - local alert feedback (buzzer + onboard LED).
 * Each target class gets its own audible signature, so you can tell what was
 * detected without looking at the phone. Detection-alert audio and volume come
 * from the app and persist across reboots. The user-action power cues (hold-to-
 * start ack, app-driven shutdown) remain audible while detection alerts are
 * muted, unless the saved volume is 0; the boot motif honors mute like any alert.
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
// Startup motif. Honors detection-alert mute in EVERY case - a muted board boots silent even on a
// physical start, because on the button-less deploys ESP_RST_POWERON cannot be told apart from an
// unattended power restore (see alertsBootJingle). physicalStart is kept so the call site's single
// host-tested physical-start decision keeps feeding this alongside the pairing gate.
void alertsBootJingle(bool physicalStart);

// Immediate, queued confirmation that the hold-to-start gate committed to ON. Unlike the volume
// preview, this is a power-state cue and bypasses detection-alert mute at nonzero volume.
void alertsPowerOnAck();

// The mirror image of the boot jingle: a short DESCENDING "powering down" motif that ENDS LOW,
// where boot rises and ends high ("...alive?"). Play it on a real running->off transition so the
// user can HEAR off from on - the faint 25ms heartbeat LED never made that legible, and the red
// light is the charger's, not ours. Blocking (~0.7s), safe to call right before deep sleep, and
// bypasses detection-alert mute at the saved nonzero volume. The LED still honors lights out, and
// volume 0 remains fully silent.
void alertsPowerDown();

// Play the "app linked" chirp once when the BLE connection comes up, and arm the
// first-contact "reveal" sting for this session. Call on the rising edge of a link.
void alertsConnected();

// Queue a non-blocking alert for a detection. Only `isNew` hits beep.
void alertsSignal(AcabDeviceType type, bool isNew);

// Detection/session alert audio on/off. Persisted to NVS. Only the explicit-user-action power
// cues (hold-to-start ack, app-driven shutdown) bypass this switch at the saved nonzero volume.
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
