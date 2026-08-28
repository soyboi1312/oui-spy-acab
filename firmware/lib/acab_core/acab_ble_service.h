/*
 * ACAB OUI-Spy - BLE GATT service (the contract the iOS app codes against).
 *
 *   Service        acab0100-6f75-6973-7079-000000000000   ("...ouispy")
 *   ├─ Detections  acab0101-...   NOTIFY        one compact-JSON record per hit
 *   ├─ Config      acab0102-...   WRITE         JSON commands from the app
 *   ├─ Status      acab0103-...   READ | NOTIFY periodic device status JSON
 *   └─ OTA         acab0104-...   WRITE_NR | NOTIFY   firmware bytes up / progress down
 *
 * OTA (firmware update, all writes require the bonded/encrypted link):
 *   control rides the Config characteristic as an {"ota":{...}} object -
 *     {"ota":{"begin":true,"size":1069573,"crc":"a1b2c3d4","ver":"2.0.1"}}  open a session
 *     ...then stream the raw image bytes to the OTA characteristic (write-no-response)...
 *     {"ota":{"end":true}}     finalize + reboot into the new image
 *     {"ota":{"abort":true}}   cancel
 *     {"ota":{"confirm":true}} after reboot: mark the new image healthy (disarms rollback)
 *   the board notifies progress/results on the OTA characteristic:
 *     {"ota":"ready","size":N} {"ota":"prog","rx":B,"pct":P} {"ota":"done"}
 *     {"ota":"ok"} {"ota":"err","e":"crc"}
 *   crc is a standard zlib CRC-32 (hex) over the whole image; ver must be newer than the
 *   running firmware (send "force":true to override). On the dual board the S3 image carries NO
 *   nRF payload and there is no SWD path (that was abandoned 2026-07-21 and the code deleted):
 *   the S3 only forwards a "DFU" trigger over UART, the nRF reboots into its Adafruit/Seeed
 *   bootloader, and the PHONE drives the nRF update over Nordic BLE DFU. See main.cpp's header
 *   and nrf-ble-scan/src/main.cpp for the trigger handling.
 *
 * Detection record (one BLE notify, fits the negotiated ATT MTU; we negotiate 512):
 *   {"t":1,"s":0,"meth":1,"c":85,"mac":"aa:bb:..","rssi":-67,"name":"Flock",
 *    "det":"mfg 0x09C8","lat":0,"lon":0,"plat":0,"plon":0,"alt":0,"n":3,"new":true}
 *   t   = device type   (1 Flock cam, 2 Flock Raven, 3 Axon body cam, 4 Drone, 5 tracker,
 *                        7 nearby/Desert, 8 watchlist, 9 glasses, 10 network camera)
 *   s   = source        (0 BLE, 1 WiFi, 2 RemoteID)
 *   meth= match method, c = confidence 0-100, n = sighting count
 *
 * Config commands (send any subset). The surface has grown well past this sample:
 * per-detector toggles (flock/drone/droneoui/axon/motorola/tracker/glasses/netcam),
 * desert mode, led, the encrypted offline buffer (key/epoch/sync/clearlog/buffer), the
 * watchlist (watch), and OTA ({"ota":{...}}). Examples:
 *   {"axon":true}      enable the body-cam category (Axon + Utility BodyWorn)
 *   {"motorola":false} quiet ONLY the broad Motorola-Solutions OUI proxy - a SUB-toggle
 *                      of the body-cam category, so the conf-90 Axon BWCDEVICE tag keeps
 *                      running. Absent key on old firmware = the two were one switch.
 *   {"buzzer":false}   mute detection/session sounds (physical power cues remain)
 *   {"lat":32.79,"lon":-116.94}  push the phone's GPS (Mesh-Detect tags its uplink)
 *
 * Status record (fw string is "<label> <version>", e.g. beacon board reports "beacon board"):
 *   {"fw":"ACAB-ouispy 2.0.0","up":12345,"total":42,"ble":true,"wifi":true,
 *    "axon":false,"buzzer":true,"gps":false, ...}
 *   bat appears only on battery-sense boards; co/chg/nbb only on the dual-radio beacon
 *   board. The radio ingest counters (wseen/bseen) and the sink-drop total (sdrop) ride
 *   the one-shot {"diag":true} reply, NOT the periodic status - moved 2026-08-26 to keep
 *   the periodic frame's worst case under STATUS_JSON_MAX.
 *
 * The full, current key list for all three characteristics lives in docs/ble-protocol.md;
 * treat that doc as the source of truth and this header as a quick orientation.
 */
#ifndef ACAB_BLE_SERVICE_H
#define ACAB_BLE_SERVICE_H

#include "detection.h"
#include "acab_version.h"  // the one place ACAB_FW_VERSION lives

// ---- RF privacy defaults -------------------------------------------------------------------
// The detector used to be the most conspicuous beacon in the room: a fixed service UUID, a literal
// name, a custom company ID, an exact firmware version, and a stable MAC, broadcast continuously.
// The detection path was always passive; the leak was in the phone link nobody audited.
//
// ACAB_BLE_PRIVACY      1 = advertise a rotating Resolvable Private Address.
//                       OFF, AND IT STAYS OFF: IT BREAKS iOS. Bench-proven 2026-08-02, controlled
//                       A/B on one board. Read the rest of this block before touching the flag.
// ACAB_ADVERTISE_VERSION 1 = put the exact firmware version in the scan response. OFF by default:
//                       it told every passive listener which signature set a unit carries, i.e.
//                       what it can and cannot see, to save its owner one tap. The version still
//                       reaches the app over the Status characteristic, post-connect and post-bond.
//                       This one is off for a PRIVACY reason. Nothing about it is broken and it has
//                       nothing to do with the iOS failure described below.
//
// The rotation itself works. Two independent proofs stand:
//   1. ON AIR. The companion nRF52840, a separate receiver on the same PCB, captured AdvA = the
//      rotating RPA at rssi -17 while the S3 reported that exact value. The public address never
//      appeared. A board cannot observe its own AdvA and iOS/macOS substitute a per-host UUID, so
//      the co-processor was the only way to see the truth.
//   2. ANDROID IS FINE. Paired, rebooted the board (new RPA), and it reconnected unprompted in 4 s
//      with enc_change status=0, encrypted=1 bonded=1.
//
// BUT iOS CANNOT CONNECT. Same board, same firmware, only this flag changed:
//   ACAB_BLE_PRIVACY=1 -> the board appears in the picker, tapping it opens a link (the board even
//                         sounds its connect chirp), and then NOTHING. onConnect never fires, so
//                         the GATT server never sees the peer. Never recovers.
//   ACAB_BLE_PRIVACY=0 -> connected in 7 s, encrypted=1 bonded=1 at t=18 s.
// So the link reaches the controller and dies before the host hands it up. Not yet root-caused.
//
// A detector that cannot pair with an iPhone is not shippable, and that outweighs the leak this
// setting closes. Everything the feature needs is still here and still correct: the address type
// (BLE_OWN_ADDR_RANDOM, not RPA_PUBLIC_DEFAULT, see the .cpp), the explicit ENC|ID key
// distribution, the build guard, the advertising re-arm after rotation preempts GAP, and the
// serial diagnostics that made all of the above visible.
//
// Anyone resuming this: reproduce the A/B above FIRST, then instrument the iOS side. The board
// tells you almost nothing because the failure is above the controller and below the host
// callback. A sniffer on the CONNECT_IND / connection-request exchange is the next real step.
#ifndef ACAB_BLE_PRIVACY
#define ACAB_BLE_PRIVACY 0
#endif
#ifndef ACAB_ADVERTISE_VERSION
#define ACAB_ADVERTISE_VERSION 0
#endif

#define ACAB_BLE_SVC_UUID    "acab0100-6f75-6973-7079-000000000000"
#define ACAB_BLE_DET_UUID    "acab0101-6f75-6973-7079-000000000000"
#define ACAB_BLE_CFG_UUID    "acab0102-6f75-6973-7079-000000000000"
#define ACAB_BLE_STAT_UUID   "acab0103-6f75-6973-7079-000000000000"
#define ACAB_BLE_OTA_UUID    "acab0104-6f75-6973-7079-000000000000"

// The companion nRF's app version for the status doc (dual-radio boards). Weakly defined as -1
// here; the beacon-board app provides the real one (the last "V<n>" it heard from the nRF).
int acabNrfVersion();
// Carrier revision, auto-detected at boot (true = rev-B: momentary power button + real VBUS sense).
// Defined in the beacon-board build; weakly defaulted false elsewhere so the shared core links.
bool acabBoardIsRevB() __attribute__((weak));

// True while the companion nRF is mid BLE DFU (dual-radio boards; weakly false elsewhere). Drives
// the status "nrfup" flag so the app mutes the co-proc fault banner during a legitimate update.
bool acabNrfDfuActive();

// Execute a deferred physical action on the loop task while retaining the authenticated link that
// authorized it. The callback runs synchronously under a lease also taken by connect/disconnect;
// phone B therefore cannot become the published owner after phone A's final token check but before
// A's DFU/power-off action begins. Requests remain one-shot and expire across either boundary.
// The callback must not recursively enter a BLE link boundary. False means no current authorized
// request (or lease failure); in that case it is never invoked. Power-off may deliberately not
// return because deep sleep ends the runtime.
typedef void (*AcabBleDeferredLinkAction)(void* context);
bool acabBleRunNrfDfuRequest(AcabBleDeferredLinkAction action, void* context = nullptr);
bool acabBleRunPowerOffRequest(AcabBleDeferredLinkAction action, void* context = nullptr);

// Notify a connected app that the board is powering off on purpose (button-hold or app request), so
// it treats the imminent link drop as a clean shutdown. Called by the beacon-board power-off path
// only when it is really about to deep-sleep; a no-op with no subscriber and on non-dual builds.
void acabBleNotifyPoweringOff();

// Init NimBLE, build the service, and start advertising as `deviceName`. `fwLabel`
// is this build's name in the status "fw" string (e.g. "mesh-detect-ACAB").
// `startAdvertising = false` brings the GATT service up WITHOUT going on air, so a target can
// finish deciding whether it is even staying powered, and configure the pairing gate, before any
// phone can reach it. Call acabBleStartAdvertising() once those decisions are made. Default true
// preserves every existing call site.
void acabBleBegin(const char* deviceName, const char* fwLabel = "ACAB-ouispy",
                  bool startAdvertising = true);

// Go on air. Idempotent, and safe to call even if acabBleBegin already started advertising.
void acabBleStartAdvertising();

// Push one detection to subscribed clients (call from the scanner sink).
void acabBleNotifyDetection(const AcabDetection& d, bool isNew);

// Refresh + notify the Status characteristic. Call periodically from loop().
// BLE JSON contract version, emitted as `proto` in the status JSON. Bump ONLY on a BREAKING change
// to the wire contract (a field changing meaning or type, a mandatory field removed) - never for an
// additive one, because both apps already ignore keys they do not know.
//
// ABSENCE MEANS 0, NOT UNKNOWN. Firmware older than 2026-08-06 omits the key entirely, and that
// firmware is fully compatible with every app shipped to date, so an app that sees no `proto` must
// behave exactly as it does today. An app should refuse to interpret a board whose proto EXCEEDS
// the version it was built against, and say so, rather than silently misparse.
#define ACAB_BLE_PROTO_VERSION 2

// ---------------------------------------------------------------------------
// Pairing window
// ---------------------------------------------------------------------------
// A NEW phone may only bond during a short window after the board powers on. Already-bonded
// phones reconnect whenever they like; the window governs FIRST contact only.
//
// The threat this closes: without it, anyone within radio range of an unattended board can pair to
// it and read the log. The recovery is deliberately something a user can be told in one sentence
// ("turn it off and on, then connect within two minutes"), which is why this shipped and the
// QR-secret / challenge-response ownership scheme did not: no secret to lose, no server, nothing
// per-device to provision, and nothing to transfer when the board changes hands.
//
// WHY THE GATE IS AT CONNECT AND NOT AT PAIRING. NimBLE-Arduino 1.4.3 has onSecurityRequest
// commented out (NimBLEServer.h), so there is no hook to refuse an SMP request once it starts, and
// this version can DELETE an existing bond while servicing a repeat pairing. Rejecting at connect,
// before any SMP traffic, is therefore the only placement that cannot cost the legitimate owner
// their bond. See ServerCb::onConnect.
#define ACAB_PAIR_WINDOW_MS 120000UL

// Open the window. Call ONCE, only after the soft-power gate has committed the board ON, so a
// board that boots merely to decide it should be off never becomes pairable. Touches no NVS: the
// window is RAM-only and a power cycle is exactly how a user reopens it.
// Turn ON enforcement without opening a window: strangers refused, already-bonded phones still
// reconnect. Call unconditionally on every boot of a target that wants the gate. Separate from
// acabBleOpenPairingWindow because enforcement and "a person just turned this on" are different
// questions, and folding them together left every warm reboot (OTA, panic, watchdog, brownout)
// running with enforcement OFF, admitting any phone indefinitely.
void acabBlePairGateEnable();

// Calling this ALSO opts the target into enforcement. A target that never calls it keeps the
// pre-feature behaviour (any phone may pair, any time). Every GATT-serving production target now
// opts in: beacon-board arms the window from its power-gate signals, mesh-detect from the reset
// reason with cellAbsent=true (USB power is its only "switch"), so unplug/replug is the recovery
// on both. The old worry, inheriting the rejection without ever arming a window and becoming
// permanently unpairable, is exactly why enabling the gate without a window-arming signal is
// wrong; do not copy the enable call without the acabPhysicalStart call beside it.
void acabBleOpenPairingWindow();
// True while a new phone may bond. False before the window opens and after it expires.
bool acabBlePairWindowOpen();
// Milliseconds left, 0 when closed. For the status JSON so the app can say how long is left.
uint32_t acabBlePairWindowRemainingMs();
// How many phones the BOARD still has bonded. A phone forgetting its side of the pairing does NOT
// remove ours, which is why a previously-bonded phone can still reconnect (and re-pair) outside the
// window: the connect gate sees a known address. Surfaced on the [diag] serial line.
int acabBleBondCount();

void acabBleUpdateStatus();
// One-shot expanded diagnostic pushed through the STATUS characteristic, in response to a
// {"diag":true} write on Config. Config is WRITE-only, so this is the only shape a
// request/response can take on this profile. See the implementation for what it carries.
void acabBleSendDiag();
// Live-notify MTU accounting, surfaced in the {"diag":true} reply. Elided = the alert still went
// out with optional RID enrichment trimmed (see detect_elide.h); over-cap = the record could not
// be made to fit at all, i.e. a genuinely lost live sighting.
uint32_t acabBleNotifyElidedCount();
uint32_t acabBleNotifyOverCapCount();

// Report battery percentage (0-100) in the status JSON. Boards with no sense divider
// never call this, so "bat" stays out of the JSON (pass -1 for unknown).
void acabBleSetBatteryPct(int pct);

// Report whether the battery is charging (VBAT held above the discharge ceiling on USB). The
// status "chg" flag only appears on the dual-radio build; an absent key = draining/unknown, so
// the app shows a normal battery. No-op storage on other builds.
void acabBleSetCharging(bool charging);

// True after the link is authenticated, including the short GPS/privacy preparation boundary
// before config admission. A raw/stalled pre-auth GAP link returns false, so it cannot suppress
// offline logging; once authentication succeeds the temporary true closes prior-owner queue races.
bool acabBleClientConnected();

// Drive the offline-buffer replay drain (a bounded burst of records per call, paced by the
// notify mbuf pool) and pump the acab_core deferred work that must stay off the NimBLE host
// task (chunked buffer wipe, nRF ignore-list mirror). Call from loop() every pass.
void acabBleDrainTick();

// OTA stall watchdog: abort + un-quiesce an OTA session that has gone idle > 30s (e.g. a
// link drop the disconnect callback did not catch). Cheap; call periodically from loop().
void acabBleOtaWatchdog();

// Latest phone GPS the app pushed via the Config characteristic, if fresher than
// maxAgeMs (use 0xFFFFFFFF for "any age"). Returns false (outputs untouched) when
// there's no fix. Age is measured from 64-bit monotonic esp_timer stamps, so a stale fix cannot
// become fresh again at the 49.7-day uint32 millis wrap. When ageMs is non-null, it gets the fix's
// age in millis, saturated at UINT32_MAX for an "any age" request rather than wrapped.
// CLEARED ON DISCONNECT: this always fails while no phone is connected, which is what keeps an
// outward-facing path (mesh-detect's transmission boundary) from attaching the owner's position
// to traffic seen after they left.
bool acabBleGetPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs = nullptr);

// OFFLINE BUFFER ONLY - the same fix, retained across a disconnect only when that authenticated
// session supplied the key accepted for the current log generation. A no-key/mismatched session
// clears both GPS copies, and every authentication begins empty. Identical monotonic age contract,
// including permanent finite expiry across any number of millis wraps.
// The offline buffer exists to record what passed a board its owner walked away from, and
// det_log only accepts rows while the phone is away, so this is the only position a buffered
// record can carry.
//
// WHAT THE CODE GUARANTEES, exactly: the value this returns reaches the AES-CTR encrypted det_log
// ring and nothing else on the board. It is never attached to a live detection notify, never sent
// over the mesh, and never placed in the status document. The one caller (the offline-buffer stamp
// in acab_scanner's handleDetection) puts it in a DetLogGpsStamp carried BESIDE the detection, so
// it is not reachable from the AcabDetection the sink hands to acabBleNotifyDetection - a
// structural boundary, not a check that could be forgotten at a new call site.
//
// THE ONE EXCEPTION, and it is the buffer's purpose: the record it was written into is later
// replayed to a session that supplies the exact accepted generation key. A phone sharing that key
// need not be the one that supplied the fix; a different-key phone gets keymis and no replay until
// it explicitly clears the old rows. See docs/ble-protocol.md. The boundary above buys that nothing
// outside authorized replay, and nothing before the owner asked for it, carries the coordinate.
//
// See the banner on the definition in acab_ble_service.cpp before adding a second caller.
bool acabBleGetLastPhoneGps(double* lat, double* lon, uint32_t maxAgeMs, uint32_t* ageMs = nullptr);

#endif // ACAB_BLE_SERVICE_H
