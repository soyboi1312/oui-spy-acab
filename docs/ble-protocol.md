# ACAB BLE GATT Protocol (oui-spy ↔ iOS & Android apps)

This is the contract between the ACAB firmware and the native apps (the
SwiftUI iOS app and the Android app). Every build exposes one service.

**Advertised name.** The v2 beacon board advertises as **`beacon`** and reports the
`fw` label **`beacon board`**; the legacy Colonel Panic oui-spy build advertises as
**`ACAB`** and reports `ACAB-ouispy`. Do not match on the name: both are found by
scanning for the service UUID below, so the app pairs with either board the same way.

## Service & characteristics

| Role | UUID | Properties |
|---|---|---|
| **Service** | `acab0100-6f75-6973-7079-000000000000` | - |
| **Detections** | `acab0101-6f75-6973-7079-000000000000` | `NOTIFY` |
| **Config** | `acab0102-6f75-6973-7079-000000000000` | `WRITE`, `WRITE_NR` |
| **Status** | `acab0103-6f75-6973-7079-000000000000` | `READ`, `NOTIFY` |
| **OTA** | `acab0104-6f75-6973-7079-000000000000` | `WRITE_NR` (encrypted), `NOTIFY` |

The OTA characteristic is present on OTA-capable firmware only (not on the released
v1.7 builds); its absence tells the app to point users at the browser flasher instead.
See *Firmware update (OTA)* below.

> The low 4 bytes spell `ouispy` (`6f 75 69 73 70 79`). The app should subscribe
> to **Detections** and **Status** on connect, and request an MTU of 512 so each
> detection record and the fuller status frame fit in a single notification (the
> board negotiates 512; iOS auto-negotiates, Android calls `requestMtu(512)`).

## Peripheral address, bonding and privacy

**The board advertises from its fixed factory address.** Address privacy (a rotating
Resolvable Private Address) is implemented in the firmware and is **off by default**;
`ACAB_BLE_PRIVACY` in `acab_ble_service.h` carries the full bench note. The short version,
from a controlled A/B on one board on 2026-08-02:

- the rotation itself works, confirmed on air by the companion nRF52840 capturing `AdvA`;
- **Android is fine**, re-pairing and reconnecting across a board reboot in about 4 s;
- **iOS cannot connect**. The board appears in the picker and the link opens at the
  controller, but `onConnect` never fires, so the GATT server never sees the peer.

A detector that cannot pair with an iPhone is not shippable, so the feature is off. Do not
re-enable it without reproducing that A/B first.

**For app authors this changes nothing about how you should identify a board.** Match on the
service UUID, never on the address:

- iOS never sees a peripheral MAC at all. CoreBluetooth substitutes a per-host `UUID`, so the
  same board shows a different identifier on a different phone. That is expected, and it is
  why the iOS picker labels a board `beacon 6971c790` where Android labels the same board
  `beacon 4b:ae:b1:20:5b:6f`.
- Android does see the address. Treat it as a display detail, not an identity: if privacy is
  ever enabled, an *unbonded* board's rotation mints a second entry in the picker, while a
  *bonded* board's rotation resolves through the IRK and stays stable.

**Bond budget.** The board keeps up to 8 bonds. Because the apps subscribe to all three
NOTIFY characteristics on connect, each fully-subscribed bond costs 3 CCCD records, and the
CCCD store is sized to match. Both limits are set in `firmware/platformio.ini`; the comment
there explains why they are not independent of each other.

## Detections (notify)

One compact-JSON object per sighting. Emitted on first detection and again each
time the device is re-seen after the 60 s dedup window (`new` distinguishes them).

```json
{"t":1,"s":0,"meth":2,"c":80,"mac":"d4:ad:fc:11:22:33","rssi":-67,
 "name":"FS Ext Battery","n":3,"new":true}
```

The `"FS Ext Battery"` name is the one Flock literal that ranks strong on its own, so
it reports the name method (`meth:2`) at confidence 80. A bare manufacturer-ID hit is a
sub-threshold hint instead (`meth:3`, `c:45`, `det:"mfg 0x09C8"`); see the replay example
below.

| Key | Meaning | Values |
|---|---|---|
| `t` | device type | `1` Flock camera · `2` Flock Raven · `3` Body camera (Axon, Utility, or the broad Motorola Solutions OUI proxy; read `det` for which) · `4` Drone · `5` BLE item tracker · `7` Nearby device (Desert mode) · `8` Watched device (user watchlist) · `9` Recording glasses · `10` Network camera (branded IP camera on Wi-Fi; opt-in, see `netcam`) |
| `s` | source | `0` BLE · `1` WiFi · `2` Remote ID |
| `meth` | match method | `1` oui · `2` name · `3` mfg-id · `4` svc-uuid · `5` ssid · `6` probe · `7` remote-id · `8` svc-data tag · `9` mfg-subtype · `10` watchlist (exact-MAC user rule) |
| `c` | confidence | `0`-`100` |
| `mac` | transmitter MAC | string |
| `rssi` | signal strength | dBm |
| `name` | advertised name | optional |
| `id` | RID serial / operator id | optional (drones) |
| `det` | detail (raven fw, ssid, drone op-id…) | optional. On `t:3` it names the source, which is how the app tells the four body-cam signals apart: `"BWC DEVICE"` (Axon service-data payload, conf 90, MAC-independent), `"Axon OUI"` (conf 75), `"Utility BodyWorn"` (name 85 / OUI 70), `"Motorola Solutions OUI"` (broad proxy, conf 45) |
| `cid` | BLE manufacturer company ID (Bluetooth SIG assigned #, integer) | optional; BLE only, present when the advert carried manufacturer-specific data. The field the glasses/tracker detectors key on; the app surfaces it in the detail screen + CSV so a miss is diagnosable. **Live-notify only, and first field elided** on a tight-MTU link (it is diagnostics, not alert content, see `detect_elide.h`). Replay frames NEVER carry it: the offline buffer's fixed 64-byte record does not store the company ID, so an elided `cid` is lost, not deferred - do not wait for a drain to recover it |
| `lat`,`lon` | subject location | **OVERLOADED, read carefully:** drones = the aircraft's own
broadcast position; everything else = the DETECTOR's GPS. Consumers must branch on the type.
Exporting it as a device position on a non-drone row, or as an observer position on a drone
row, are both wrong and both have shipped as bugs. |
| `gage` | age (s) of the GPS fix used for `lat`,`lon` | optional; set when stamped from a stale phone fix (offline / Desert) |
| `plat`,`plon` | drone operator location | optional |
| `alt` | altitude (m MSL) | optional (drones) |
| `n` | sighting count this session | integer |
| `new` | first sighting in window | bool |

### Suggested Swift model

```swift
struct Detection: Decodable {
    enum Kind: Int { case flockCamera = 1, flockRaven, axonBodyCam, drone, tracker, nearbyDevice = 7, watched = 8, recordingGlasses = 9, networkCamera = 10 }
    let t: Int, s: Int, meth: Int, c: Int
    let mac: String, rssi: Int
    let name: String?, id: String?, det: String?
    let lat: Double?, lon: Double?, plat: Double?, plon: Double?, alt: Int?
    let n: Int, new: Bool
    var kind: Kind { Kind(rawValue: t) ?? .flockCamera }
}
```

## Config (write)

Write a JSON object with any subset of keys:

```json
{"axon": true, "buzzer": false, "volume": 60, "ble": true, "wifi": true, "beep": true}
```

| Key | Effect |
|---|---|
| `flock` | enable/disable the Flock/ALPR detector (BLE + Wi-Fi signatures, on by default). Desert mode still reports these even when the toggle is off |
| `drone` | enable/disable the drone Remote ID detector (BLE + Wi-Fi, on by default). Desert mode still reports these even when the toggle is off |
| `droneoui` | enable/disable the drone **vendor-OUI fallback** (default **off**, opt-in). Layered under Remote ID: matches a device's MAC against known drone-vendor IEEE blocks (DJI/Parrot/...) and flags it at low confidence. It cannot tell a flying drone from a stationary drone-vendor gadget, so it may false-positive - hence off by default. Only meaningful while `drone` is on; Desert mode forces it on |
| `axon` | enable/disable the body-cam **category** (field-validated, on by default). `bodycam` is the same switch under a clearer name; the board accepts either key, so older app builds keep working. Off means every body-cam signature is off (Axon `BWCDEVICE` tag, Axon OUI, Utility BodyWorn, and the broad Motorola Solutions OUI). It no longer touches the `motorola` sub-toggle, so flipping the category off and back on restores the user's broad-match choice |
| `motorola` | enable/disable the broad **Motorola Solutions OUI** proxy, a sub-toggle underneath the body-cam category (default **on** on the beacon board and oui-spy, **off** on mesh-detect, where a broad OUI match would flood the rate-limited LoRa uplink). NVS-persisted, so the choice survives a reboot. Lets a user quiet the noisy corporate-OUI match (conf 45, reports as a body cam with detail "Motorola Solutions OUI") while keeping the field-validated Axon `BWCDEVICE` tag (conf 90) and Utility BodyWorn running |
| `tracker` | enable/disable the BLE item-tracker (Find My, offline form) detector (default off). The detection is delivered to the app on the **first** sighting; only the buzzer is held, for the first **60 s** a tracker is in range (`TRACKER_ALERT_DEBOUNCE_MS`), so a tag you walk past stays quiet. See *Tracker alerts and the buzzer debounce* below |
| `glasses` | enable/disable the smart/recording-glasses detector (Ray-Ban/Oakley Meta, Snap Spectacles, Vuzix; on by default). Keys off the BLE manufacturer-data company ID. See [docs/glasses.md](glasses.md) |
| `netcam` | enable/disable the **network-camera** detector (default **off**, opt-in). Matches branded IP-camera OUIs (Hikvision/Dahua/Amcrest/Axis/Reolink/Ring/Wyze/eufy/Ezviz/Lorex/Swann/Arlo) on the host Wi-Fi and emits `t:10` at confidence 65 (or 75 for a field-validated block), detail "<Vendor> on wifi". Since 2.0.4 it ALSO matches a base-station SSID prefix ("ARLO_VMB_"/"NTGR_VMB_") on beacon/probe-response frames, emitting `t:10` with method `M_SSID` at confidence **88**, detail "Arlo base station" and the matched SSID in `name` - a self-attested match outranks any OUI inference. Probe REQUESTS are deliberately excluded: they name the network sought, not the transmitter. Turning it on widens Wi-Fi capture to 802.11 **data** frames so a streaming camera's cleartext source MAC can be OUI-matched; off (default) keeps capture management-frame-only for zero added CPU / 2.4GHz load. Honest scope: it matches known camera BRANDS on the network (could be an NVR/doorbell/disclosed camera) and cannot find every camera - never a "hidden camera" claim |
| `diag` | write `{"diag":true}` to request a ONE-SHOT expanded diagnostic. The reply arrives on the **Status** characteristic (Config is write-only, so there is no command-response channel) carrying `diag:true`, `sdrop`, `sdDeliv`, `sdBuf`, `sdRepl`, `sqHigh`, `up`. Not a setting - nothing is persisted, and it is safe to send at any time |
| `desert` | **Desert mode**: report EVERY device in range, not just known signatures (default off). See *Desert mode* below |
| `buzzer` | master audio on/off (`false` disables sound entirely) |
| `volume` | buzzer loudness, integer `0` to `100` (`0` is silent) |
| `led` | onboard status LED on/off (default **on**). `false` = "lights out": no idle heartbeat, no detection flashes, no boot sweep, for covert/stationary deploys. Persists across boots |
| `ble` | enable/disable the BLE detection scan. `false` stops scanning only - the GATT link to the app stays up |
| `wifi` | enable/disable the Wi-Fi (promiscuous) detection scan |
| `wifiEco` | Wi-Fi eco mode: integer seconds of Wi-Fi RX sleep between sweeps, `0` (off) / `3` / `7` / `15`. Battery-SKU power saver; BLE capture is untouched. The board reports the active value back in Status under the same key |
| `beep` | `true` plays one preview beep at the current volume (pair with `volume` to audition a level) |
| `buffer` | enable/disable the offline detection buffer (default **off**, opt-in). See *Offline detection buffer* below |
| `bufall` | **record everything**: also buffer uncategorized nearby devices, and re-arm capture every 15 min so a revisit writes a second record (default **off**). Deploy-and-leave only, presented as one experimental **Stationary capture** switch that writes `{"buffer":true,"bufall":true,"desert":true,"buzzer":false}` in a single object after pushing the key. `bufall` without `desert` gets revisit resolution but never classifies an uncategorized device. Cleared automatically when `buffer` is set false. External USB-C power required. Widens the undrained-reboot auto-wipe threshold, which weakens the self-clean guarantee, so the client must say so where the user turns it on. **Not implemented in either app today**: the firmware honours the key, but no shipped app writes it or presents the Stationary capture switch. The disclosure requirement here and the disarm ordering below bind whichever app ships it first, as test assertions, not prose. See *Offline detection buffer* |
| `key` | 64 lowercase hex chars = the 32-byte at-rest encryption key; the app generates + persists it and pushes it on connect. **The board holds it in RAM AND persists it to NVS while buffering is enabled** (`det_log.cpp` `detLogSetEnabled`), so a board left deployed keeps encrypting across reboots instead of going keyless. **TRADEOFF, state it plainly: a seized board's flash yields the key, so the at-rest buffer is decryptable and is NOT ciphertext-only.** Turning buffering off erases the key from both RAM and NVS. Flash encryption / encrypted NVS is what would restore seized-board protection. See the SECURITY block at the top of `det_log.h`. |
| `epoch` | unix seconds (the phone's wall clock). The board has no RTC, so this is the only wall clock it ever sees: it stores an *anchor* for the current boot and reconstructs capture times from it later. Persisted, so it dates records from earlier boots too. See *How replay times are derived* below |
| `sync` | start a replay drain: stream stored records with `seq` greater than this value (`0` = everything) |
| `clearlog` | `true` performs a real flash-sector erase of the buffer. The erase is chunked (one block per loop pass, so scanning and the GATT link stay live) and runs in the background; Status reports `wiping:true` until it finishes |
| `watch` | the user watchlist: an array of MAC strings (same format as `ignore`, up to 256). A watched device alerts as `t:8` every time it's seen, even with no built-in signature. Persists across boots; the app pushes its list on connect, but **only when it has something to say** (see `clr`). A MAC on both `watch` and `ignore` still alerts: on the dual-radio board the co-processor's ignore mirror is published as *ignore minus watch*, so a starred MAC is never dropped before it reaches the S3. The apps keep the two lists exclusive anyway |
| `clr` | `true` marks an accompanying **empty** `ignore`/`watch` array as a deliberate clear. **A bare `{"watch":[]}` or `{"ignore":[]}` is REFUSED** and the stored list is kept, unless this peer already committed a non-empty list for that key on this connection. Without this, any app with an empty list wiped the board the moment it connected (a reinstall, or a second phone that had never starred anything), and a starred MAC plus its label exists nowhere else. The second clause is what keeps older apps working: boards update over the air, so the board is routinely newer than the app, and an app that has already replaced the list is not granted any new destructive power by then emptying it. Per-write like `more`; a chunked write carries at most one list, so one flag serves both |
| `ota` | firmware-update control object (`begin` / `end` / `abort` / `confirm`). See *Firmware update (OTA)* below |
| `nrfdfu` | `true` requests a **co-processor (nRF) BLE DFU** (dual board and protocol 2 only). The encrypted Config session and the two-minute physical-start window must both be live. The board replies `nrf-ready` or `nrf-denied` on OTA, then sets Status `nrfup:true` only after the loop actually forwards the trigger. The app baseline-scans first, waits for `nrfup`, then drives the signed, version-bound, application-only `.zip`. **Trust asymmetry, stated plainly** (mirrors `pair_window.h`): the S3 image is signature-verified ON the board; the nRF image is not. The nRF's stock legacy bootloader is CRC-only and cannot authenticate an image, and its UART trigger accepts a bare token, so the nRF leg's protection is entirely the session + physical-window gate on the S3 side (plus the app's own signature check on the downloaded `.zip`). Migrating the bootloader to signed Secure DFU is what would close it. See *Firmware update (OTA)* below |

Sub-GHz (433/915 MHz) is not present on the OUI-Spy XIAO, so there is no key for it.

The firmware re-notifies Status after applying a config write.

### Body-cam category and the Motorola sub-toggle

The broad Motorola Solutions OUI match and the Axon signatures used to share one switch,
so a user turning body cams off to quiet the noisy Motorola proxy also silenced the
conf-90 field-validated `BWCDEVICE` payload match, the strongest signature on the board.
They are now two switches:

- **Classification requires BOTH.** A Motorola OUI hit is reported only when the body-cam
  category (`axon` / `bodycam`) is on **and** `motorola` is on.
- **Category off = the whole category off.** Every body-cam signature goes quiet,
  including Motorola, regardless of the sub-toggle's stored value.
- **Category on, `motorola` off** leaves the Axon `BWCDEVICE` tag (conf 90) and Utility
  BodyWorn running while the broad OUI proxy stays silent.
- **Desert mode overrides both**, exactly as it does for every other detector: with
  `{"desert":true}` the specific detectors still classify first, so a Motorola OUI hit
  reports as a body cam even with either switch off.
- **`{"axon"}` / `{"bodycam"}` no longer touches the Motorola setting.** It used to clobber
  it, which silently discarded the user's broad-match preference every time the category
  was toggled. Apps must write `{"motorola":...}` explicitly to change it.

Both toggles are NVS-persisted independently, so each survives a reboot on its own.

### Tracker alerts and the buzzer debounce

`TRACKER_ALERT_DEBOUNCE_MS` (60 s) is a **buzzer debounce, not a detection filter**. It
used to be a 5 s dwell that suppressed the whole detection, which blinded the app for the
window and was sold as a follow-me test it was never able to make.

- **Delivery is immediate.** A tracker notifies on **Detections** from the first sighting,
  GPS stamp and all, exactly like every other type. The app has the record from second
  zero and can show, log, and buffer it.
- **Only the piezo waits.** The audible alert is held for the first 60 s a tracker is in
  range, so a tag you walk past stays quiet while one still in range a minute later sounds.
- **The board does not decide whether a tracker is following you, and cannot.** That
  judgement needs location over time; the board has no GPS of its own (its stamps come
  from the phone) and no wall clock. Follow-me logic belongs in the app, which has both.
- **Detection never looks at the address.** A tracker is matched on its broadcast payload,
  so address rotation has no bearing on whether it is found. A separated Find My tag
  rotates its address and key once per ~24 h, rolling around 04:00 local (the IETF DULT
  interval, deliberately long so trackers can be accumulated against one identifier); the
  commonly-quoted 15 minutes is the near-owner state and does not apply here. Rotation
  only affects features keyed on a MAC, such as the watchlist (`watch`), where a star on a
  separated tracker holds until the next rollover.

## Status (read / notify)

```json
{"fw":"ACAB-ouispy 2.0.5","up":1234,"total":42,
 "ble":true,"wifi":true,"flock":true,"drone":true,"axon":true,"moto":true,"tracker":false,"glasses":true,"buzzer":true,"vol":80,"gps":false,"bufon":false,"desert":false}
```

| Key | Meaning |
|---|---|
| `proto` | BLE JSON contract version, integer. Bumped ONLY on a BREAKING change to this contract; additive keys never move it, because both apps ignore keys they do not know. **ABSENT MEANS 0**, which means fully compatible: every firmware before 2026-08-06 omits it. An app whose supported version is LOWER than the board's must say "this board needs a newer app" rather than keep parsing fields whose meaning may have changed |
| `fw` | firmware build + version |
| `up` | uptime (seconds) |
| `total` | detections emitted this session |
| `ble` / `wifi` | detection scan active for that radio (reflects the `ble` / `wifi` config toggles) |
| `wifiEco` | active Wi-Fi eco value: seconds of Wi-Fi RX sleep between sweeps, `0` (off) / `3` / `7` / `15`. Mirrors the `wifiEco` config key; both apps read it to drive the eco picker |
| `pairw` | seconds left in the new-phone pairing window. **Emitted only while the window is open**; absent = closed (the normal steady state). Lets an app show a setup countdown; neither app parses it today |
| `sdrop` | sink-queue drops, total, **emitted only when nonzero**. A nonzero value means the detection sink overflowed and rows were lost before delivery or buffering; the per-category split rides the `{"diag":true}` reply. Neither app parses it today (see the receipts section below) |
| `buferr` | latched flash-fault bitmask for the offline buffer, **emitted only when nonzero**. Nonzero means the ring stopped accepting writes rather than pretending evidence was stored; only a fully successful physical wipe clears it. Neither app parses it today |
| `flock` | Flock/ALPR detector enabled. A missing key (older firmware) is treated as on |
| `drone` | drone Remote ID detector enabled. A missing key (older firmware) is treated as on |
| `droui` | drone vendor-OUI fallback enabled. A missing key (older firmware) is treated as off (opt-in, default off) |
| `axon` | body-cam category enabled (Axon plus Utility BodyWorn plus, gated by `moto`, the broad Motorola OUI) |
| `moto` | broad Motorola Solutions OUI sub-toggle enabled. **An absent key means pre-split firmware**, where the broad match rode the body-cam toggle with no separate switch: treat absent as `true` and hide or disable the sub-toggle in the UI, since writing `{"motorola":...}` to that board does nothing. Present means the board honours the sub-toggle. Note this reports the sub-toggle's own value, so `"axon":false,"moto":true` is normal and still means no Motorola hits (both switches are required) |
| `buzzer` | master audio enabled |
| `vol` | buzzer volume, `0` to `100` |
| `gps` | a GPS fix is being applied to fixed-device detections |
| `buf` | number of detections currently held in the offline buffer |
| `bufon` | offline buffering is enabled |
| `bufall` | record-everything mode is on. **Sent only when true**; absent means off (saves MTU, same idiom as `ledon`). Not parsed by either app today (the feature has no app-side switch yet) |
| `bufsat` | the ring filled and refused further uncategorized records, so the **tail of the stored log is censored**. Sent only when true. Persisted across reboots, cleared by `clearlog`. Surface it beside the log, not in settings: without it a full-looking replay cannot be told apart from one that stopped days early |
| `wiping` | present + `true` **only while** a deferred buffer erase is still sweeping (a `clearlog`, key-change wipe, or auto-wipe runs the flash erase one block per pass so the radios stay live). While set, the board writes no new records; absent = idle. The app can gate a "clearing…" state on it and knows a fresh `sync` won't capture anything until it clears |
| `ledon` | onboard LED enabled. **Omitted when on** (the default), so an absent key means on; sent as `false` only in lights-out mode |
| `tracker` | BLE item-tracker detector enabled |
| `glasses` | smart/recording-glasses detector enabled |
| `ncam` | network-camera detector enabled. A missing key (older firmware) is treated as off (opt-in, default off) |
| `desert` | Desert mode enabled (reporting every device in range) |
| `ign` | number of MACs on the board's ignore list (for app reconciliation) |
| `wat` | number of MACs on the board's watchlist (for app reconciliation) |
| `wseen` | 802.11 management frames seen (two-radio diagnostic; present on all builds) |
| `bseen` | BLE adverts ingested this session. On the dual board this counts the nRF's forwards, so a flat `bseen` with `co:true` means the co-processor is up but hearing nothing |


**`bufall` and `bufsat` are sent only when true, so ABSENT MEANS FALSE, in every fresh
status frame, not just the first.** Latch them per frame, never cumulatively, or a stale
saturation warning survives a `clearlog` forever and tells the user a complete log is truncated.

**Disarming Stationary capture is an ordered sequence and the order is load-bearing.** Writing
`buffer:false` clears the at-rest key from RAM and NVS, so doing it before the replay finishes
leaves the remaining records undecryptable while still occupying the ring: the deployment is
destroyed by the act of collecting it. On collection:

1. Connect and let the replay run to completion.
2. Confirm it ended cleanly, the `{"hist":"end","n":N}` sentinel, with `N` matching the count
   received. A gap means re-sync, not proceed.
3. Only then write `{"bufall":false,"desert":false,"buffer":false}`.
4. Restore the user's prior alert mode through the existing Desert reconciliation path, not by
   blindly re-enabling the buzzer. The mode forced Silent, and a mode the user hand-picked while
   Desert ran has to survive.
5. Let the user erase the log explicitly with `{"clearlog":true}`. Never automatic, they just
   collected a week of bystander movements, and deleting it is their call and their timing.

### Dual-radio / battery boards only

These keys appear only on the v2 beacon board (dual-radio and, on the battery SKU, a
sense divider). A single-radio oui-spy / mesh-detect board omits them, so an absent key
always reads as the safe default and never trips a warning.

| Key | Meaning |
|---|---|
| `co` | co-processor (nRF) liveness. Emitted only on the dual board; the app shows "bluetooth detection offline" only when it is present **and** `false`, so an absent key (single-radio / older firmware) never warns |
| `bat` | battery percentage, `0` to `100`. Present only on boards with a VBAT sense divider; absent on USB-only boards, so the app hides the battery gauge |
| `chg` | battery charging. Emitted **only when `true`** (on the dual board); absent = draining or unknown = normal battery UI |
| `nbb` | nRF black-box record count (the co-processor's own diagnostic ring). Present only when a co-processor is attached |
| `nrfv` | the co-processor's last-reported app version (integer), learned from its `V<n>` line. Emitted only once the nRF has announced a version; the app gates the "co-processor update available" offer on a known `nrfv` |
| `nrfup` | present + `true` **only while** a co-processor BLE DFU is in flight (the fault-mute window is open). Absent otherwise. While set, the app shows "updating co-processor" and mutes the nRF fault banner even though `co` reads `false` (the nRF is in its bootloader). The window clears event-driven the instant the nRF reports a fresh version, or after a 5-minute ceiling. See *Firmware update (OTA)* / the combined one-click update |
| `rev` | carrier-board revision, `"A"` or `"B"` (dual board only; absent on older firmware and single-radio builds). `"A"` = the first 250 boards (slide switch, copper-crossed UART); `"B"` = button power + VBUS sense. Shown next to the fw label on the device screen so support can identify the board without opening the case, and used as a belt-and-braces OTA gate: if the board reports a revision, the manifest entry about to be flashed must agree (the PRIMARY defence is that the two revisions carry distinct fw labels, `beacon board` vs `beacon board rev-B`, and the manifest is keyed by label). Apps must treat ABSENT as "not told", never as rev-A |

## Desert mode

Off by default. When enabled (`{"desert":true}`), the board reports **every** device
it sees - not just the known surveillance signatures - as a `Nearby device` detection
(`t=7`). The specific detectors still run first, so known gear keeps its real type;
Desert mode only labels the leftovers. Each nearby device is tagged hardware-OUI vs
randomized-MAC (phones rotate theirs), with the BLE advert name or Wi-Fi SSID when
present. Built for low-RF / remote areas (the desert) where anything new on the air is
worth knowing about. It reuses the dedup, offline-buffer, and alert pipeline, so it
shows, logs, and alerts on new devices like any other detection.

## Offline detection buffer

The board can record detections to encrypted flash while the app is disconnected,
then replay them when the app reconnects, so a walk with the app closed isn't lost.

**Opt-in and sensitive.** Buffering is **off by default**. Records are encrypted at
rest (AES-CTR) with a key the app supplies.

**The board DOES persist that key** to NVS while buffering is enabled, so a
deploy-and-leave board keeps recording across a reboot instead of going keyless. The
tradeoff is deliberate and is documented at the top of `det_log.h`: a seized board's
flash yields the key, so the at-rest buffer is decryptable and **not** ciphertext-only.
(An earlier version of this section claimed the key was never persisted. It was wrong;
`detLogSetKey` writes it whenever buffering is on.) What remains is the opt-in default,
the auto-wipe of records left undrained across reboots, and `{"clearlog":true}` for a
real sector erase. Flash encryption / encrypted NVS would restore the seized-board
property.

### Connect handshake

After subscribing to Detections, the app writes to Config, in order:

```json
{"key":"3f9a...<64 hex>"}
{"epoch":1718900000}
{"sync":1503}
```

- `key` 32-byte at-rest key (generate once, persist in the Keychain / Keystore).
- `epoch` current unix time. The board anchors this boot to it (and persists the anchor), which is what lets it reconstruct absolute times on replay. It does not stamp records at capture; nothing absolute is ever written to flash.
- `sync` the highest `seq` the app has already filed (`0` on the first ever sync).

### Replay records

The board streams a **begin** sentinel carrying the pending count, then each stored
record over **Detections** as the normal detection JSON plus a few keys, then an **end**
sentinel:

```json
{"hist":"begin","n":12,"from":1504}
{"t":1,"s":0,"meth":3,"c":45,"mac":"d4:ad:..","rssi":-71,"det":"mfg 0x09C8","n":1,"new":true,"hist":true,"seq":1504,"at":1718899820,"ms":412553,"boot":37}
{"hist":"end","n":12}
```

| Key | Meaning |
|---|---|
| `hist` | `"begin"` on the lead-in sentinel, `true` on a replayed record, `"end"` on the closing sentinel |
| `seq` | monotonic record id; the app persists the highest contiguous value as its sync cursor |
| `at` | unix seconds, uint32. **Reconstructed, never a clock reading** (the board has no RTC). Present only when the record's own boot had an anchor. See *How replay times are derived* |
| `approx` | present + `true` **instead of** `at`, when the record's boot was never anchored. Not "roughly right": it means the board has no basis for a time at all |
| `ms` | uint32, `millis()` uptime at capture, relative to the boot named in `boot`. **Always present** on a replayed record, including alongside `approx` |
| `boot` | uint32, which boot session captured the record. **Always present** on a replayed record, including alongside `approx` |
| `n` (begin) | records the board is about to replay, so the app can show a determinate "X of N". This is the pending-drain count, **not** Status `buf` (which is total ring occupancy) |
| `from` (begin) | first `seq` this drain will send (integer). Normally `<lastSync>+1`, but after a board-side wipe or key-change reset the record generation, the board rebases the drain to the ring floor and `from` jumps below the cursor the app sent. See *Cursor rebase* below |
| `n` (end) | total records the board actually sent this drain |

The **begin** sentinel only precedes a non-empty drain (a bare reconnect with nothing
buffered sends neither sentinel). The app files history records the same way as live ones
(dedup by id), takes its timestamp from *How replay times are derived* below, and does
**not** alert on them. The begin `n` seeds a determinate progress indicator; on the
**end** sentinel the app checks it received `n` records and re-issues `{"sync":<lastGoodSeq>}`
to fill any gap (re-delivery is idempotent via dedup).

### How replay times are derived

These records are meant to be usable as evidence, so the contract is not "show a time", it
is "show a time together with how it was derived and how precise it is". A reconstructed
time displayed as if it were a clock reading is worse than no time at all, because it
invites confidence the method cannot support.

**The board has no real-time clock.** A buffered record stores exactly two time facts,
`whenMs` (uptime at capture) and `bootCount`. Nothing absolute is ever written to flash.
So `at` is **always** computed, never read from a clock:

```
agoMs = (anchor.atMs > whenMs) ? (anchor.atMs - whenMs) : 0     // clamped, see below
at    = anchor.epochUnix - agoMs / 1000
```

looked up by the **record's own `bootCount`**, not by the current boot. A record captured
three power cycles ago still resolves, as long as its own boot was anchored.

Note the clamp (`det_log.cpp`). If a record's `whenMs` is at or after its anchor's `atMs`,
`agoMs` is forced to 0 and `at` collapses onto the anchor's own epoch rather than running
forward past it. This is not a normal path: the board only buffers while disconnected and the
anchor is written on connect, so a capture precedes its anchor. It exists because the
unsigned subtraction would otherwise wrap to a roughly 49-day interval and throw the
timestamp decades out. An app re-deriving `at` from `ms` and `boot` must clamp the same way.

**The anchor ring.** Every `{"epoch":...}` push records `{boot, epochUnix, atMs}` into an
8-entry ring persisted in NVS. A boot that already holds a slot has that slot **reused and
refreshed** rather than consuming a new one, so one long session cannot evict the other
seven boots, and a later connect within a boot (less accumulated drift) wins. Eight distinct
anchored boots are retained; older ones fall off the ring and their records degrade from
*reconstructed* to *unanchored*.

**Four time qualities.** Each has a distinct wire shape, and the app must render them
distinctly:

| Quality | Wire shape | What the app may claim |
|---|---|---|
| **Observed** | live detection, no `hist` | The phone's own clock at receipt. A real reading, precise to the second |
| **Reconstructed** | `hist:true` + `at` + `ms` + `boot` | Derived from that boot's anchor. Honest to within crystal drift (below). Present it as derived, not as a reading |
| **Bracketed** | `hist:true` + `approx:true` + `ms` + `boot`, and the app can bound it on **at least one** side | A range only. Render as a range, never as an instant |
| **Unknown** | `hist:true` + `approx:true` + `ms` + `boot`, no bound available on either side | Order only, via `seq` and `boot`. No time. Current copy is "time unknown · offline buffer" |

Bracketed covers the **one-sided** cases too, not just the both-sides one. A boot with an
anchored predecessor but no anchored successor bounds as "after X"; the reverse bounds as
"before Y". Only a record with neither bound falls to Unknown. Note also that the newest
unanchored boot always lacks an anchored successor, yet is still bounded above: every
buffered record was necessarily captured before the sync that collected it, so the sync's own
start time is a sound upper bound and the apps use it.

`ms` and `boot` are sent in all three `hist` cases. On the board's side that is what makes
verification and re-derivation possible; on the app's side, ordering records within a boot is
implemented today, while re-deriving against an app-held anchor history deeper than the
board's eight entries is a **design intent, not shipped behaviour**. Do not read this table as
a description of app features.

**The irreducible limit.** A boot the app never connected during has no anchor and never
will. Those records can be bracketed between neighbouring anchored boots, or ordered by
`seq`, but they **cannot be dated**. The app must not invent a time for them: not the drain
time, not the connect time, not an interpolation presented as a reading. `approx:true` means
the board is declining to guess, and the app inheriting that record must decline too.

**The error budget.** Three terms stack, and drift is only the one that grows:

| Term | Size | Grows with |
|---|---|---|
| Crystal drift | ±20 ppm, ~1.7 s/day. A week disconnected lands within ~12 s | elapsed time |
| Epoch quantization | up to 1 s. `{"epoch":...}` is whole unix seconds on the wire (a `uint32`), so every anchor is rounded | fixed |
| Anchor transport | the BLE round trip carrying the push, before the board stamps `millis()` against it | fixed |

The apps therefore floor the reported precision at **2 s** and widen it by drift above that:
`max(2, elapsed × 20e-6)`. The floor is what covers the two fixed terms, so no reconstruction
is ever presented as better than a couple of seconds however short the interval. Quoting
drift alone would understate a short-interval reconstruction, which is the wrong direction to
be wrong in for a number read as evidence.

One approximation the apps make and should say so in code: they are never told `anchor.atMs`,
so they estimate the drifting interval as (this sync's epoch push → the reconstructed time).
That errs **wide**, because the board writes an anchor at the moment it receives a push, so
the newest anchor it can hold is the one from this very push, never newer. Erring wide is the
only acceptable direction here.

### Cursor rebase

`seq` is monotonic **within one record generation**. A board-side wipe the phone never
saw - the auto-wipe after undrained reboots, or the key-change wipe when a new phone
re-bonds - resets the generation and restarts `seq` at 1. The app's persisted cursor is
now stranded above the board's live seqs, so a plain `{"sync":<oldCursor>}` would arm
nothing and buffered records would stay undeliverable until the fresh generation climbed
past the stale cursor (potentially months). The board detects this (the cursor sits at or
above the ring head), rebases the drain to the ring floor, and reports the true resume
point in the begin sentinel's **`from`**. When `from` is at or below the cursor the app
sent, treat it as a generation reset: rebase the persisted cursor to `from - 1` before
filing the drain, so the end-of-drain checkpoint lands in the new generation instead of
re-replaying the whole ring on every reconnect. On a normal drain `from` is just
`<lastSync>+1` and no rebase is needed.

### Threat model

This buffer defends against a passive RF eavesdropper (the link is bonded + encrypted)
and a casual finder (opt-in, encrypted at rest, auto-wipe, easy erase). It does **not**
on its own defend against a forensic adversary with physical possession beyond the
encryption: ESP32 flash dumps over USB/JTAG, and `clearlog` needs the bonded phone in
hand. Treat a board that buffered sensitive locations as sensitive until it's drained
and wiped.

## Firmware update (OTA)

OTA-capable firmware exposes the **OTA** characteristic (`acab0104...`). The app streams
a new app image to it and the board installs the image into its spare slot, verifies it,
and reboots into it. All writes ride the bonded, encrypted link, so only a paired phone
can push firmware.

**Where images come from.** The app polls
`https://soyboi.tech/firmware/firmware-latest.json`, keyed by the board's `fw` label
(`beacon board`, `ACAB-ouispy`, `mesh-detect-ACAB`). Each entry carries the latest
`version` (drives the "update available" nudge without an app-store release), the image
`url` + `sha256` + `size`, and a `flasher` URL for boards without the OTA characteristic.
The app must verify the downloaded image's size and SHA-256 against the manifest before
sending a byte.

**Flow.** Control messages are `{"ota":{...}}` objects written to **Config**; progress
and results notify on the **OTA** characteristic.

1. `{"ota":{"begin":true,"size":<bytes>,"crc":"<hex32>","ver":"<x.y.z>"}}`. `crc` is a
   standard zlib CRC-32 of the whole image, hex. `ver` must be strictly newer than the
   running firmware (add `"force":true` to override for a rebuild/beta). The board
   answers `{"ota":"ready","size":N}` or `{"ota":"err","e":"..."}`. Scanning pauses for
   the transfer.
2. Stream the raw image bytes to the OTA characteristic with write-without-response, in
   chunks of at most (negotiated MTU - 3). Pace against the platform's write-queue
   back-pressure; the board notifies `{"ota":"prog","rx":<bytes>,"pct":<n>}` every 64 KB.
3. `{"ota":{"end":true}}`. The board verifies size + CRC + image signature, points the
   bootloader at the new slot, arms rollback, notifies `{"ota":"done"}`, and reboots.
   On any failure it notifies `{"ota":"err","e":"crc|size|image|..."}` and stays on the
   current firmware.
4. Reconnect after the reboot (same bond). Read Status: `fw` should show the new
   version. Send `{"ota":{"confirm":true}}` to mark the image healthy. Before its durable
   product-health gate is ready the board answers `{"ota":"health-wait"}`; after it has
   durably disarmed rollback it answers `{"ota":"ok"}`. If the app never confirms, the board self-confirms after 20 s of
   healthy uptime; if the new image fails to reach a healthy state at all, the next boot
   rolls back to the previous firmware, and the app should surface that the update was
   rolled back.

`{"ota":{"abort":true}}` cancels an in-flight session (the board answers
`{"ota":"abort"}` and resumes scanning). A dropped link mid-transfer aborts the session
server-side; start over from `begin`.

**Combined update (dual board).** When both radios are stale and protocol 2 is already running,
the app uses a fixed order: **nRF first, then S3.** The nRF leg must use the short authorization
window opened by the user's physical power-on. An S3 OTA warm reboot deliberately does not reopen
that window, so S3-first ordering would make the following nRF request fail by design. The app
baseline-scans for an already-present AdaDFU device, writes `{"nrfdfu":true}`, requires
`nrf-ready` and Status `nrfup:true` from this S3, then accepts exactly one newly appearing,
very-close bootloader candidate. The S3 reboots the nRF into its bootloader and opens a fault-mute window (Status
`nrfup:true`) so the app shows "updating co-processor" instead of the `co:false` fault
banner. That window clears event-driven the moment the nRF reports its new version (fast
success), or after a 5-minute ceiling.

The phone verifies the ZIP's SHA-256, detached signature, application-only layout, and inner
`application_version` before it sends the trigger. It never retries legacy DFU automatically.
After Nordic reports completion, the initiating S3 must report the target `nrfv`; only then does
the combined coordinator begin S3 OTA. If the connected board still runs protocol 0 or 1, the app
offers only the S3 update. The user must then physically power-cycle, reconnect on protocol 2, and
start the separately authorized nRF update.

## Notes for the app

- **Dedup is on the device.** You still get periodic refreshes; treat `new:false`
  as "still here," update `lastSeen`, don't double-count.
- **Confidence drives UI weight.** Show low-confidence hits distinctly. A
  `BWCDEVICE`-confirmed Axon body cam reports high confidence (`c≈90`); an
  OUI-only Axon hit on a randomized address is capped low.
- **Map layers** map cleanly to `t`: fixed pins for Flock/Axon, moving track for
  drones (use `lat/lon` + `plat/plon`).



---

## Detection Receipt: production telemetry contract

A receipt is a document a user shows to somebody else. Every hedge it drops becomes a stronger
claim than the evidence supports, so what it may assert is defined here rather than composed
per-screen.

### Two versions

**Version 1 requires app-only implementation. It needs no new production telemetry.** The board
already emits everything the mapping needs. What is missing is entirely app side:

- **Persistent user notes.** Neither app has them today.
- **Durable visual confirmation.** The confirmation checkboxes are local UI state and are lost.
- **A provenance mapping.** `meth` says *how* something matched; it does not encode
  "registry-sourced" vs "field-validated" vs "vendor identifier". Prefer a **tested app-side
  mapping** rather than a new firmware field, it avoids enlarging every BLE record for a
  presentation concern.

The mapper's input is the detection wire tuple, which is **`(t, s, meth, c)` plus `det` as a
discriminator**. Those are the actual JSON keys: `t` type, `s` source, `meth` method, `c`
confidence, `det` detail. (`conf` and `detail` are the C struct field names and do not appear on
the wire.)

**Map on typed values, never on display strings.** `det` in particular is a wire contract the apps
already resolve by exact match, and a mapper keyed on prose breaks the moment a string is reworded.

**Fail closed on an unknown combination.** Newer firmware will produce tuples this app version has
never seen, and inventing provenance for them is exactly the failure this contract exists to
prevent. Emit the observation without an interpretation:

> Detection recorded. Evidence interpretation is unavailable in this app version.

The receipt survives; the claim does not get fabricated.

Version 1's footer reads:

> Session completeness was not assessed. This receipt documents this observation, not every device
> that may have been nearby.

That phrasing matters: the recorded observation is valid. What is unknown is whether *other*
observations were missed.

**Version 2 adds a coverage line**, and only after the apps ingest telemetry.

### Four separate statements, never merged

1. **What was observed**, the raw fact. `Axon service UUID FC81 over BLE, 47 times over 3m 12s,
   strongest -52 dBm.`
2. **What that evidence supports**, the conclusion, at its actual strength.
3. **What it does not prove**, stated explicitly, not implied by omission.
4. **Whether the capture had integrity warnings**, in v1, always "not assessed".

### Controlled vocabulary

Receipt text is **selected, never generated**: one evidence statement, **plus every applicable
caveat and user attestation**. Several rows are cumulative by design, a vendor identifier is
always accompanied by the product-type caveat, and a user attestation stacks on top of whatever
the machine concluded.

| Row | Applies when | Sentence |
|---|---|---|
| evidence | SIG company ID, manufacturer AD `0xFF` | "Axon vendor identifier observed." |
| evidence | SIG service UUID, AD `0x02` / `0x03` / `0x16` | "Axon vendor identifier observed." |
| evidence | corporate OUI match | "MAC registrant association only." |
| evidence | validated product payload or name | "Field-validated product signature." |
| caveat | with any vendor identifier | "The product type is unknown." |
| caveat | with an OUI match | "This association does not identify a product type." |
| caveat | with a field-validated signature | "A matching signature does not constitute visual confirmation of this device." |
| caveat | with any Remote ID detection | "Remote ID is a self-declared broadcast." |
| caveat | SIG UUID seen only in solicitation AD `0x14` | "Solicitation observed; this may be another device looking for Axon equipment." |
| attestation | user marked it confirmed | "Visually confirmed by the user." |

A company ID rides in manufacturer data (`0xFF`); `0x02`/`0x03`/`0x16` are the UUID-bearing
structures. An OUI establishes a **registry association**, not the product manufacturer, hence
"MAC registrant association only".

**Every caveat required by the selected evidence class must be included.** The earlier phrasing
("an evidence row with no applicable caveat is a bug") contradicted the table, which then listed no
caveat for the OUI or field-validated rows, making valid receipts unconstructible. The caveats
above now cover every evidence class, and the rule is a completeness requirement rather than an
existence one.

### Version 2 coverage: two contracts, not one

Live and buffered receipts have different failure modes, so they get different gates. **Both are
evaluated as DELTAS between a start diagnostic and an end diagnostic**, never as absolute zero: a
counter that was already nonzero from an earlier session must not contaminate a clean one, and
requiring lifetime zero is stronger than the claim needs.

Permitted phrasing either way:

> No evidence-loss indicators observed

**Live session** (app connected throughout):

- no new `sdDeliv`, a dropped live notify usually re-arrives, but a one-time advert never does
- no new `nOver`
- radio health for the relevant radio (below)
- co-processor liveness sampled healthy throughout, on a dual-radio board

**Buffered deployment** (replayed after the app was away):

- no new `sdBuf`
- `bufsat == false`
- clean replay: `hist:begin.n == hist:end.n == records actually received`, no sequence gaps, no
  accepted-after-retry-cap state
- live-notify drops are **not** relevant here; nothing was being delivered live

### Radio health cannot validate every receipt

Health is **per-radio**, never both. A BLE receipt needs `bseen` to have advanced; a WiFi receipt
needs `wseen`. A radio that is disabled or irrelevant to this detection is **"not evaluated"**,
never "healthy" and never a failure.

Two structural limits:

**`wseen` counts management frames only.** The increment sits *after* the mgmt gate:

```c
netcamClassifyWiFi(payload, len, /*isDataFrame=*/true, ...);   // data-frame detection happens
if (type == WIFI_PKT_DATA) { ...netcam data-frame detection...; return; }  // data frames exit HERE
if (type != WIFI_PKT_MGMT) return;                             // and any other non-mgmt too
gWifiSeen++;                                                    // never reached for them
```

So a network-camera detection produced from an associated **data** frame is real while `wseen`
never moves. Until that is addressed, `wseen`'s coverage claim is limited to **management-frame
detections**. Fixing it properly means either counting all WiFi frames before the split, or adding
a separate `wdata` counter.

**Remote ID loses its bearer.** `SRC_REMOTEID = 2` is documented in `detection.h` as "OpenDroneID
payload (over BLE or WiFi)", so a drone receipt cannot tell which radio carried it and therefore
cannot select the relevant health counter. Version 2 must report drone coverage as **not
evaluated** unless the bearer is retained.

### Unattended captures cannot claim integrity yet

For a replayed deployment the footer must read:

> Capture integrity across unattended reboots was not assessed.

Three structural reasons:

- **`bootCount` is not in Status.** It appears only on replayed records (`boot`), so a quiet
  session may contain no record from which the current boot can be inferred.
- **`sdBuf` resets in `acabScannerBegin()`**, so after an unattended reboot `sdBuf == 0` says
  nothing about the boot that mattered.
- **`co` is current sampled liveness**, not "healthy throughout", least of all while the phone was
  disconnected.

Honest coverage for unattended capture needs **persisted, deployment-scoped latches**: a
buffer-bearing enqueue loss occurred, a co-processor or radio-health gap occurred, the buffer
saturated (`bufsat` already is one), and the boot changed during the deployment.

### Why the replay check needs all three numbers

`hist:begin.n` is the number promised. `hist:end.n` is `gHistSent`, which counts records that were
**sent**. A record exceeding `notifyCap()` is consumed from the drain and then skipped:

```c
if (detLogNextForDrain(&r)) {              // consumed from the ring
    if (len > 0 && len <= notifyCap()) {   // counted only if it fits
        ...notify...; gHistSent++;
    }                                       // else: gone, and never counted
}
```

`begin.n = 100, end.n = 99, received = 99` is reachable with one stored record silently skipped,
and a `received == end.n` check passes. Compare all three.

Both apps now do: `received == end.n` drives the gap/resync loop as before, and a
`begin.n > end.n` shortfall is surfaced in the reconnect banner as records that could not be
replayed. It is a disclosure, not a resync: the skipped record was consumed from the ring, so no
retry can refill it.

This is **replay completeness**, unrelated to `nOver`, which counts oversized *live* notifications.
Replay oversize has no counter of its own.

### Drop counters: what each one actually means

| field | meaning | evidence impact |
|---|---|---|
| `sdBuf` | buffer-bearing enqueue failed | **permanent loss** of a record the user asked to keep |
| `sdDeliv` | live notify dropped | **possible** loss, usually re-arrives on the next sighting, but a one-time advert never does |
| `sdRepl` | replay/black-box dump attempt dropped | none, the source ring still holds it |
| `nOver` | live record exceeded negotiated notify capacity | live observation lost |

`sdDeliv` is not benign in the opportunistic case. A Falcon probe request or a single BLE advert
that never repeats is exactly what this product exists to catch.

`sdrop` is the sum of the first three. `sdrop == 0` does correctly imply `sdBuf == 0` **for the
current boot**. Its problems are that a nonzero value is ambiguous between outcomes with very
different meanings, and that it resets across reboots. Read the individual counters.

### `buf` is storage used, NOT "records waiting for you"

Observed 2026-08-08: a board reporting `buf=166` replayed 37 records, and the app correctly showed
"37 detections recorded while you were away". Both numbers are right, and they answer different
questions:

| value | meaning |
|---|---|
| `buf` (`detLogCount`) = `gHead - gOldest` | **total ring occupancy**, everything stored, including records the phone has already replayed |
| `detLogPendingDrain()` = `gHead - 1 - gDrain` | what a sync would actually deliver |

Use `buf` for **storage used** and saturation context. Never label it "pending", "waiting" or
"new". There is no status field for the pending count, `detLogPendingDrain()` is exposed **only**
as `hist:begin.n`, so it can only be learned by starting a drain. The Stationary Capture "verify
the final record count" step must compare against `hist:begin.n`, not `buf`.

### What is NOT a receipt input

- **`accounted=` is capture-build only**, and covers only the BLE marker table. It says nothing
  about whether the radio heard everything, the nRF forwarded everything, or the shipping pipeline
  lost anything.
- **Vendor-confirmed vs solicited is capture instrumentation**, not a shipping classifier result.
  Until that ships, no receipt can carry those two sentences.
- **Neither app parses `bufsat`, `sdrop`, `sdBuf`, `sdDeliv` or `nOver` today.** The firmware emits
  them; nothing consumes them. That ingestion is a prerequisite for version 2, not a follow-up.

### Review checklist for any user-facing claim

This section found four defects that were invisible from the UI side: `wseen` counting something
other than its name, `buf` meaning something other than its label, `sdrop` conflating three
outcomes, and `accounted=` being capture-only. None of those are rendering bugs. All of them would
have shipped as confident text.

Run this against every claim the product makes, not just receipts:

| | |
|---|---|
| **Claim** | the exact sentence a user will read |
| **Inputs** | which fields it is computed from, by wire key |
| **Measurement scope** | what those fields actually count, which is often narrower than the name |
| **Reset/persistence scope** | per boot, per session, per deployment, or lifetime |
| **Unavailable-state wording** | what is said when an input is missing, never silence |
| **App/firmware version compatibility** | behaviour when the board is newer than the app |

The product's differentiator is not detection. It is the boundary between measurement and claim,
and that boundary is only maintained by writing the claim contract before the screen.
