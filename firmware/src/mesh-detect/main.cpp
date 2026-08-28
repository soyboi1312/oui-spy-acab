/*
 * ACAB - All Cameras Are Beacons
 * Mesh-Detect build (Colonel Panic Mesh-Detect: XIAO ESP32-S3 + Heltec V3).
 *
 * The XIAO scans for Flock (BLE + WiFi), drone Remote ID, and
 * Axon body cams, then sends labelled alerts over the wired Heltec V3 Meshtastic
 * node - on a channel index of your choosing, not just the public channel.
 *
 * Passive detect-and-report only.
 */
#include <Arduino.h>
#include "acab_scanner.h"
#include "axon_detect.h"
#include "tracker_detect.h"
#include "police_detect.h"
#include "glasses_detect.h"
#include "flock_detect.h"
#include "drone_detect.h"
#include "netcam_detect.h"
#include "desert_detect.h"   // desertRestoreEnabled: persisted Desert toggle
#include "acab_version.h"
#include "acab_banner.h"
#include "acab_ble_service.h"
#include "pair_window.h"   // acabPhysicalStart: the host-tested rule production must CALL, not restate
#include "mesh_link.h"
#include "det_log.h"
#include "coredump_report.h"   // the retained IDF panic dump: report it, and erase it with the buffer
#include "ota_update.h"
#include "esp_task_wdt.h"   // task watchdog: catch a wedged loop(), same as beacon-board/oui-spy
#include <Preferences.h>

// Onboard LED (XIAO S3, inverted: LOW = on) - brief blink on each new detection, plus a slow
// idle heartbeat (see loop) so a running board never looks dead.
#ifndef ACAB_LED_PIN
#define ACAB_LED_PIN 21
#endif

// LED master switch (mirrors oui-spy's alerts.cpp). On (default) = detection blinks + idle
// heartbeat; "lights out" = fully dark. Persisted to NVS, pushed from the app via the shared
// {"led":bool} config key. These strong symbols override the BLE service's weak stubs.
static bool gLedEnabled = true;
bool alertsLedEnabled() { return gLedEnabled; }
void alertsSetLedEnabled(bool on) {
    gLedEnabled = on;
    if (!on) digitalWrite(ACAB_LED_PIN, HIGH);   // dark immediately
    Preferences p; p.begin("acab-led", false); p.putBool("led", on); p.end();
}

// Meshtastic channel we transmit on. 0 = primary/public, sent as a TextMessage
// (matches the stock Mesh-Detect Heltec config, so your node stays on the public
// LongFast mesh). Set a secondary index (e.g. -DACAB_MESH_CHANNEL=1) to send
// detections privately over PROTO instead.
#ifndef ACAB_MESH_CHANNEL
#define ACAB_MESH_CHANNEL 0
#endif

// How often the diagnostic heartbeat fires. With -DACAB_DIAG, the unit pushes a
// radio-health line to the mesh this often, so a drive test is readable without a
// serial cable. ACAB_DIAG also turns on a chatty per-advert serial log (see
// acab_scanner).
#ifndef ACAB_HEARTBEAT_MS
#define ACAB_HEARTBEAT_MS 120000
#endif

// Detection blink request: millis() of the newest first sighting, stamped by onDetection
// (which runs on the scanner sink task) and consumed by loop()'s LED state machine. The sink
// task must never sleep in a blink (a Desert-mode burst of 20 new devices/s would park it in
// delay(40) for 800ms of every second, overflowing gSinkQ and dropping live notifies), and
// only loop() may drive the pin so the blink and the idle heartbeat cannot fight. 0 = none.
static volatile uint32_t gBlinkReqMs = 0;

static bool otaRuntimeHealthy() {
    return millis() >= 20000 && acabScannerHealthy();
}

// Scanner sink: forward every hit to the app (if connected) and the mesh, blink the
// LED on first sighting.
static void onDetection(const AcabDetection& d0, bool isNew) {
    AcabDetection d = d0;
    // Final privacy gate at the transmission boundary. Shared scanner rows may have
    // been queued with an older phone fix before a disconnect, so do not trust a
    // pre-populated non-drone coordinate here. Re-acquire a fix that is both attached
    // to the current connection and at most 60 seconds old. Drone coordinates remain
    // untouched because they are broadcast by the aircraft, not supplied by the phone.
    if (d.type != ACAB_DRONE) {
        d.lat = 0; d.lon = 0; d.gpsAgeMs = 0;
        if (acabBleClientConnected())
            acabBleGetPhoneGps(&d.lat, &d.lon, 60000, &d.gpsAgeMs);
    }

    acabBleNotifyDetection(d, isNew);   // stream to the app over BLE, same as oui-spy
    meshLinkSend(d, isNew);             // and over the Meshtastic uplink
    if (isNew) {
        char mac[18];
        acabFormatMac(d.mac, mac);
        Serial.printf("[ACAB] %-16s %-4s %s rssi=%d conf=%d\n",
                      acabTypeLabel(d.type), acabSourceLabel(d.src), mac,
                      d.rssi, d.confidence);
        if (gLedEnabled) gBlinkReqMs = millis();   // loop()'s LED state machine services it; never sleep here
    }
}

void setup() {
    // Rollback gate: if a prior OTA image booted without confirming health, revert now
    // (may esp_restart()). Must run first so a bad image can't wedge in later init.
    otaSetHealthCheck(otaRuntimeHealthy);
    otaBootCheck();

    Serial.begin(115200);
    delay(200);
    Serial.print(acabBanner());
    Serial.println("=== ACAB Mesh-Detect " ACAB_FW_VERSION " ===");

    // Read the retained core dump BEFORE the heavy init that could panic, and report it. Same
    // reason as beacon-board: the coredump partition is in this build's partition table too, the
    // shared {"diag":true} reply already carries the cd* fields, and without this probe they are
    // permanently absent - a mesh board that has been panicking looks clean. Prints nothing on a
    // clean boot. See coredump_report.h.
    acabCoredumpProbe();
    acabCoredumpPrint();

    pinMode(ACAB_LED_PIN, OUTPUT);
    digitalWrite(ACAB_LED_PIN, HIGH);
    { Preferences p; p.begin("acab-led", true); gLedEnabled = p.getBool("led", true); p.end(); }

    MeshLinkConfig mesh = meshLinkDefaults();
    mesh.channelIndex = ACAB_MESH_CHANNEL;
    // Channel 0 = public -> TextMessage (matches the stock Heltec Serial Module
    // config); any other channel needs PROTO to target that specific index.
    mesh.transport = (ACAB_MESH_CHANNEL == 0) ? MESH_TEXT : MESH_PROTO;
    meshLinkBegin(mesh);

    // Run the same GATT service oui-spy does, so the app can connect to a Mesh-Detect
    // board too: see detections, configure it, and push the phone's GPS (which we tag
    // onto the mesh uplink). acabBleBegin inits NimBLE; the scanner then reuses it.
    //
    // The fw label is channel-specific so an OTA can't cross-flash the public build onto a
    // private-channel board: the app matches the manifest OTA entry by exact fw label, and the
    // ch1 build is a separate entry. Channel 0 keeps the shared "mesh-detect-ACAB"; any other
    // channel appends "-ch<N>" (e.g. "mesh-detect-ACAB-ch1"). Still hasPrefix("mesh-detect") so
    // the app's board-type check holds. acabBleBegin stores the pointer (no copy), so the
    // buffer MUST outlive setup() -> static.
    static char fwLabel[24];
    if (ACAB_MESH_CHANNEL == 0)
        snprintf(fwLabel, sizeof(fwLabel), "mesh-detect-ACAB");
    else
        snprintf(fwLabel, sizeof(fwLabel), "mesh-detect-ACAB-ch%d", ACAB_MESH_CHANNEL);
    // startAdvertising=false: configure the pairing gate BEFORE going on air, so no phone can
    // reach a board that has not decided (same ordering as beacon-board).
    acabBleBegin("ACAB-mesh", fwLabel, false);

    // Pairing gate. Without it acabPairAdmit admits any stranger in radio range, and a bonded
    // stranger reaches the whole config surface: {"clearlog":true} erases the offline buffer,
    // a new {"key":...} triggers the mismatch wipe, and every detector toggle can be switched
    // off. Enforcement is unconditional on every boot; the window only opens on a PHYSICAL
    // start. This build has no slide switch, button, or battery cell (XIAO on USB power), so
    // the inputs mirror the slim SKU: cellAbsent=true makes plugging in the only "switch",
    // and unplug/replug is the documented recovery ("turn it off and on, then connect within
    // two minutes"). A warm restart (OTA, panic, watchdog) opens no window; bonded phones
    // still reconnect.
    acabBlePairGateEnable();
    const esp_reset_reason_t meshRr = esp_reset_reason();
    if (acabPhysicalStart(meshRr == ESP_RST_POWERON, meshRr == ESP_RST_DEEPSLEEP,
                          /*cellAbsent=*/true, /*buttonHeld=*/false,
                          /*switchLow=*/false, /*benchBuild=*/false)) {
        acabBleOpenPairingWindow();
    } else {
        Serial.println("[pair] warm continuation (not a physical start) - window NOT opened; "
                       "enforcement is ON, bonded phones still reconnect");
    }
    // Offline detection buffer: mount the flash ring + bump the boot counter. Stays
    // inert (no capture) until the app enables it and pushes an at-rest key. Finish the initial
    // ring scan/config publication before advertising: otherwise a fast phone can enter config
    // callbacks concurrently with the 24k-slot scan and observe default startup state.
    detLogBegin();

    acabBleStartAdvertising();

    AcabScannerConfig cfg = acabScannerDefaults();
    cfg.initNimBLE = false;            // the GATT service already inited NimBLE
    cfg.bleDeviceName = "ACAB-mesh";

    // Axon body-cam detection on OUI 00:25:DF (field-validated 2026-06-17: real
    // Axon body cams advertise this public OUI). See axon_detect.cpp. Restore the
    // persisted app toggle (default ON) so the user's choice survives a reboot,
    // same as the beacon build.
    axonUseRegistryCandidate();
    axonRestoreEnabled(true);

    // Item-tracker detection: restore the persisted app toggle (default OFF). AirTags
    // / Tiles / SmartTags are everywhere and flooding them over the rate-limited LoRa
    // uplink buries surveillance hits, so it stays off unless you turn it on in the
    // app - and now that choice survives a reboot instead of reverting every boot.
    trackerRestoreEnabled(false);

    // Recording-glasses detection (BLE mfg company ID): restore the persisted app toggle,
    // default ON. The company-ID match is specific, so it does not flood the rate-limited
    // LoRa uplink the way the tracker scan would. See glasses_detect.cpp.
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
    // Network-camera detection (branded IP camera on host WiFi): default OFF. Inspecting
    // 802.11 DATA-frame source MACs is a CPU + 2.4GHz-coexistence cost we only pay on opt-in;
    // when off the data-frame path is never enabled (zero load). Restored BEFORE
    // acabScannerBegin so the promiscuous filter matches the persisted choice. See netcam_detect.cpp.
    netcamRestoreEnabled(false);

    // Desert mode. Persisted as of 2026-08-08 (it was the only detector toggle that was not),
    // because a board deployed unattended must not silently stop recording after a brownout
    // reset - the owner comes back unable to tell "nothing came by" from "it turned itself off".
    // Default OFF: it is a deliberate, high-volume mode, not something to inherit by accident.
    desertRestoreEnabled(false);

    // Broad Motorola Solutions OUI proxy: default OFF on the mesh build - it would add
    // chatter to the rate-limited LoRa uplink. Now its own persisted sub-toggle of the
    // body-cam category rather than a hard false, so a mesh operator who deliberately
    // turns it on in the app keeps it across reboots. Previously this was a flat
    // policeSetEnabled(false) while the app still showed "body cams ON", which made the
    // UI claim coverage the board was not actually providing.
    policeRestoreEnabled(false);

    acabScannerBegin(cfg, onDetection);

    // Task watchdog on the loop task, mirroring beacon-board/oui-spy. 30s timeout, panic=true so a
    // genuinely wedged loop reboots into a clean image. Nothing in this loop blocks long: the
    // OTA image write lands in the BLE host task, not this one, and loop() only polls (delay 50ms),
    // so this loop always feeds well inside the window.
    esp_task_wdt_init(30, true);
    esp_task_wdt_add(NULL);

    Serial.printf("[ACAB] scanning + meshing on channel %u "
                  "(Flock BLE/WiFi + drone RID + Axon OUI 00:25:DF)\n",
                  meshLinkChannel());
}

void loop() {
    esp_task_wdt_reset();   // pet the task WDT each pass; loop() never blocks long on this build
    // Re-arm offline capture on a timer while "record everything" is on, so a board left
    // unattended records a REVISIT instead of collapsing a week into one row per device.
    // Self-throttling and a no-op when the mode is off or a phone is connected.
    acabScannerBufferAllTick();

    static uint32_t lastBeat = 0;
    static uint32_t lastMeshBeat = 0;
    static bool bootPinged = false;
    uint32_t now = millis();

    // Idle LED heartbeat + detection blinks: a brief flash every ~2s so a running board never
    // looks dead, plus a flash per gBlinkReqMs request from the sink task. Two-step state
    // machine (loop ticks ~every 50ms); silent under lights out. One shared lit/timestamp
    // state means the two patterns can't fight over the pin, and a Desert-mode burst of
    // requests naturally coalesces into discrete >=40ms blinks instead of sink-task sleeps.
    static uint32_t lastLedBeat = 0;
    static bool ledBeatLit = false;
    static uint32_t servicedBlinkMs = 0;
    uint32_t blinkReq = gBlinkReqMs;
    if (gLedEnabled && !ledBeatLit && (blinkReq != servicedBlinkMs || now - lastLedBeat >= 2000)) {
        servicedBlinkMs = blinkReq;
        digitalWrite(ACAB_LED_PIN, LOW); ledBeatLit = true; lastLedBeat = now;
    } else if (ledBeatLit && now - lastLedBeat >= 40) {
        digitalWrite(ACAB_LED_PIN, HIGH); ledBeatLit = false;
    }

    // OTA self-heal: a freshly-updated image that reaches a stable uptime is presumed good,
    // so disarm rollback even if the app never sends {"ota":{"confirm":true}}.
    if (otaOnTrial() && millis() > 20000) {
        if (!otaMarkHealthy() && millis() > 60000) {
            Serial.println("[ota] trial health deadline missed; rebooting to trigger rollback");
            delay(50);
            ESP.restart();
        }
    }

    // One-time boot self-test: announce on the mesh ~10s after power-up, once the
    // Heltec is up, to check the send path without waiting for a detection.
    if (!bootPinged && now > 10000) {
        bootPinged = true;
        meshLinkSendText("mesh-detect ACAB online");
        lastMeshBeat = now;
    }

    if (now - lastBeat > 60000) {
        lastBeat = now;
        acabBleUpdateStatus();        // refresh the connected app's status view
        Serial.printf("[ACAB] alive | ble=%lu wifi=%lu det=%lu\n",
                      (unsigned long)acabScannerBleSeen(),
                      (unsigned long)acabScannerWifiSeen(),
                      (unsigned long)acabScannerTotalDetections());
    }

#ifdef ACAB_DIAG
    // Push radio-health counts to the mesh so a drive test is readable without a
    // serial cable. Next to a known camera: rising ble/wifi with det=0 means a
    // signature or range miss; flat ble/wifi means a dead radio or antenna.
    if (bootPinged && now - lastMeshBeat > ACAB_HEARTBEAT_MS) {
        lastMeshBeat = now;
        char hb[96];
        snprintf(hb, sizeof(hb), "ACAB diag | ble=%lu wifi=%lu det=%lu",
                 (unsigned long)acabScannerBleSeen(),
                 (unsigned long)acabScannerWifiSeen(),
                 (unsigned long)acabScannerTotalDetections());
        meshLinkSendText(hb);
    }
#endif

    // SECOND AT-REST SURFACE, and this build reaches it exactly like beacon-board does: same
    // {"clearlog"} handler, same det_log ring, same NimBLE host task parsing the phone's
    // {"lat","lon"} onto a stack an ELF dump would capture. Without this call {"clearlog"} would
    // report success with the panic dump still in flash. Consumes the explicit NVS-backed erase
    // generation even after power loss or while a shared ring sweep is already pending. A plain
    // boot auto-wipe with no explicit token preserves the dump. The physical erase defers past
    // the ring sweep that acabBleDrainTick pumps below - see coredump_report.h.
    acabCoredumpWipeTick();
    acabBleDrainTick();   // stream buffered detections back on the app's sync request
    acabBleOtaWatchdog(); // abort + un-quiesce a stalled OTA session (missed link drop)
    delay(50);
}
