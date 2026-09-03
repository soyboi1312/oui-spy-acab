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
| **Detections** | `acab0101-6f75-6973-7079-000000000000` | `NOTIFY` (encrypted) |
| **Config** | `acab0102-6f75-6973-7079-000000000000` | `WRITE` (encrypted) |
| **Status** | `acab0103-6f75-6973-7079-000000000000` | `READ`, `NOTIFY` (encrypted) |
| **OTA** | `acab0104-6f75-6973-7079-000000000000` | `WRITE_NR` (encrypted), `NOTIFY` |

**Config takes WRITE, not write-without-response.** The board creates it as
`WRITE | WRITE_ENC` (`acab_ble_service.cpp`), so a client that issues WRITE_NO_RESPONSE has its
config writes rejected by the peripheral. This table used to list `WRITE_NR` here as well; the
firmware does not set that property on Config. Write-without-response belongs to the OTA
characteristic, and only for the image stream.

**Encryption is not an OTA-only property.** Detections and Status carry `READ_ENC` and Config
carries `WRITE_ENC`, alongside OTA's, so an unbonded peer cannot read Status or write a setting
at all. The notify streams are gated in firmware rather than by the descriptor: NimBLE registers
the CCCD as plain read/write, so a subscribe can complete before bonding, but the board emits no
detection and no status frame until `onAuthenticationComplete` has reported an encrypted bond.
Pairing is Just Works, no passkey, because the board has no display or keypad - so the bond buys
encryption and a persistent identity, not MITM protection at the one-time pairing.

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
sub-threshold hint instead (`meth:3`, `c:45`, `det:"mfg 0x09C8"`).

| Key | Meaning | Values |
|---|---|---|
| `t` | device type | `1` Flock camera · `2` Flock Raven · `3` Body camera (Axon, Utility, or the broad Motorola Solutions OUI proxy; read `det` for which) · `4` Drone · `5` BLE item tracker · `7` Nearby device (Desert mode) · `8` Watched device (user watchlist) · `9` Recording glasses · `10` Network camera (branded IP camera on Wi-Fi; opt-in, see `netcam`) |
| `s` | source | `0` BLE · `1` WiFi · `2` Remote ID |
| `meth` | match method | `1` oui · `2` name · `3` mfg-id · `4` svc-uuid · `5` ssid · `6` probe · `7` remote-id · `8` svc-data tag · `9` mfg-subtype · `10` watchlist (exact-MAC user rule) |
| `c` | confidence | `0`-`100` |
| `mac` | transmitter MAC | string |
| `rssi` | signal strength | dBm |
| `name` | advertised name | optional. Also the THIRD rung of the replay trim ladder, so an absent `name` on a `hist:true` row can mean the frame was too big rather than that the device advertised none |
| `id` | RID serial / operator id | optional (drones), and the FINAL last-resort replay trim rung. An absent `id` on `hist:true` can therefore mean transport-bounded, not "the aircraft broadcast none" |
| `det` | detail (raven fw, ssid, drone op-id…) | optional. On `t:3` it names the source, which is how the app tells the four body-cam signals apart: `"BWC DEVICE"` (Axon service-data payload, conf 90, MAC-independent), `"Axon OUI"` (conf 75 BLE / 65 from the Wi-Fi management-frame path, `s:1`), `"Utility BodyWorn"` (name 85 / OUI 70 on BLE, 65 on Wi-Fi), `"Motorola Solutions OUI"` (broad proxy, conf 45). **Live-notify only**, same limit as `cid`: the offline buffer's fixed 64-byte record stores no detail, so a replay frame never carries `det` - an absent `det` on a `hist:true` row means "not stored", never "no detail existed" |
| `cid` | BLE manufacturer company ID (Bluetooth SIG assigned #, integer) | optional; BLE only, present when the advert carried manufacturer-specific data. The field the glasses/tracker detectors key on; the app surfaces it in the detail screen + CSV so a miss is diagnosable. **Live-notify only, and first field elided** on a tight-MTU link (it is diagnostics, not alert content, see `detect_elide.h`). Replay frames NEVER carry it: the offline buffer's fixed 64-byte record does not store the company ID, so an elided `cid` is lost, not deferred - do not wait for a drain to recover it |
| `lat`,`lon` | subject location | **OVERLOADED, read carefully:** drones = the aircraft's own
broadcast position; everything else = the DETECTOR's GPS. Consumers must branch on the type.
Exporting it as a device position on a non-drone row, or as an observer position on a drone
row, are both wrong and both have shipped as bugs. Also the position rung of the replay trim ladder,
which sheds the pair together with `gage`, so an absent position on a `hist:true` row can mean the
frame was too big rather than that the board had no fix. |
| `gage` | age (s) of the GPS fix behind `lat`,`lon` | optional. The board emits it whenever it recorded a nonzero fix age in **milliseconds**, so on a non-drone row it is present nearly always, LIVE rows included - it is not a marker for offline or Desert rows, and the live stamp is taken at any age. The value truncates to whole seconds, so a sub-second fix emits `gage: 0`. Absent means either the position is the device's own (a drone's broadcast coordinates) or the board recorded no age beside it at all - on a replay row, an age that was under a second when it was stored. On a `hist:true` row `gage` is shed by the position rung of the replay trim ladder, the same rung that sheds `lat`/`lon`, so a replayed coordinate always arrives with its age: the two never come apart |
| `plat`,`plon` | drone operator location | optional |
| `alt` | altitude (m MSL) | optional (drones) |
| `spd` | horizontal speed (m/s) | optional (drones), int |
| `vspd` | vertical speed (m/s) | optional (drones), int |
| `hdg` | track direction (deg, `0`-`360`) | optional (drones), int |
| `hgt` | height above takeoff (m) | optional (drones), int |
| `palt` | operator altitude (m MSL) | optional (drones), int |
| `sta` | ODID operational status: `1` ground · `2` airborne · `3` emergency · `4` fault | optional (drones), int |
| `n` | sighting count this session | integer |
| `new` | first sighting in window | bool on a live notify. FIRST rung of the replay trim ladder, so treat it as optional: absent means `false`, which is what it always is on a replayed record anyway. **One type reads differently:** on a `t:5` tracker row it is additionally held `false` for the whole 60 s debounce, then forced `true` once as that window closes, after which the ordinary dedup rule applies again. See *Tracker delivery and the 60 s capture debounce* below |

**An absent optional key can mean "not sent" rather than "not broadcast", so never report it as
an absence of evidence.** On a tight-MTU link (an iPhone that negotiates 185 leaves ~182 usable
bytes) a full drone record does not fit, so the board sheds optional fields
least-meaningful-first rather than dropping the sighting. The order is the contract and lives in
`detect_elide.h`:

`cid` → `palt` → `hgt` → `vspd` → `spd` → `hdg` → `sta` → `plat`/`plon`

Each level suppresses that field and every field before it, so `plat`/`plon` go LAST: a missing
operator position on a drone row can mean the board squeezed it out, and reading it as "the
aircraft broadcast no operator location" is a wrong conclusion about where a pilot is standing.
On a **live** notify nothing outside that ladder is elided: every other key in the table is
emitted whenever the board has it, `alt` included. An elided field is lost, not deferred: the
offline buffer's fixed 64-byte record stores none of them, so a replay cannot restore what the
live notify gave up.

**A replayed record sheds a DIFFERENT set of keys, on a second ladder.** A `hist:true` frame
carries none of the elidable RID fields above (the buffer never stored them), so when it still
exceeds the peer's notify capacity the board gives up envelope and quality keys instead, cheapest
first (the `HIST_TRIM` ladder in `acab_ble_service.cpp`):

`new` → `ms`/`boot` (**only** when `at` resolved) → `name` → `lat`+`lon`+`gage` → `id`

It fires only when the fully built frame is over the cap, so an Android link (MTU 512) replays
every field untouched while an iPhone at MTU 185 trims most GPS-stamped rows. The record still
goes out, short, instead of being skipped. So on a replay row a missing `name` or position means
"squeezed out" at least as often as "the board had none", and a missing `new` means `false`.

**The position rung sheds `lat`, `lon` and `gage` as ONE step**, so a replayed coordinate is never
emitted without the age that qualifies it. That matters because a buffered non-drone position is
always a stale phone fix (up to about 18h12m) and `gage` is the only key that says so: both apps
gate their staleness wording on it, so a coordinate arriving alone would read as a pin taken on
the spot. It follows cheaper metadata loss; only the final last-resort `id` rung comes after it.
The anchor pair is a cross-check on a time the app already holds, and `name` is a 6-char
truncation whose class is already in `t` and whose radio identity is already in `mac`. See
*Replay records* below for the per-key rule and the `hTrim` / `hOver` counters that report it.
The final `id` rung is a last-resort transport bound: it costs a drone's rotation-stable identity,
but leaves the observation keyed by `t`/`mac`/`seq`. With every variable-length field gone, the
widest unanchored core is 159 bytes, so it fits an iPhone-class 182-byte notify payload.

### Suggested Swift model

```swift
struct Detection: Decodable {
    enum Kind: Int { case unknown = 0, flockCamera = 1, flockRaven, axonBodyCam, drone, tracker, nearbyDevice = 7, watched = 8, recordingGlasses = 9, networkCamera = 10 }
    let t: Int, s: Int, meth: Int, c: Int
    let mac: String, rssi: Int
    let name: String?, id: String?, det: String?
    let cid: Int?, gage: Int?
    let lat: Double?, lon: Double?, plat: Double?, plon: Double?, alt: Int?
    let spd: Int?, vspd: Int?, hdg: Int?, hgt: Int?, palt: Int?, sta: Int?
    let n: Int
    let new: Bool?   // OPTIONAL: the replay trim ladder drops it first. Absent means false
    var kind: Kind { Kind(rawValue: t) ?? .unknown }
}
```

`new` is the one key here that reads as mandatory and is not. It is dropped from an over-cap
replay frame, and a synthesized `Decodable` that requires it throws away the whole record on the
first trimmed row of a drain. `name` is already optional above and stays that way for the same
reason. Both shipped apps decode every key above with a default rather than a requirement, so no
one missing field discards a record.

**File an unrecognized `t` as a generic row, never coerce it into a known category.** OTA ships
board firmware independently of app releases, so a client WILL meet a `t` it has never seen: a
type added by newer firmware, or the retired `t:6` off a v1.7 board still in the field. The old
`?? .flockCamera` fallback in this snippet rendered every one of them as an ALPR camera, the
loudest category in the product. Both shipped apps do the reverse (`case unknown = 0` on iOS,
`UNKNOWN(0)` on Android) so that no unknown type is mislabelled and none is silently dropped
either. Same rule as *Fail closed on an unknown combination* further down: emit the observation
without inventing an interpretation.

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
| `motorola` | enable/disable the broad **Motorola Solutions OUI** proxy, a sub-toggle underneath the body-cam category. **Default off on every target.** Flipped from on to off 2026-07-23 on field ground truth: an airport capture returned 30 body-cam rows, and while the 3 Axon BLE hits were confirmed real, all 27 Motorola Wi-Fi OUI hits were confirmed NOT body cams (fixed ceiling / infrastructure gear). 0/27 precision on a detector shipping on by default drowns the true positives beside it, so it joined `netcam` as an opt-in vendor proxy. The signature list itself is correct and stays; this is a default, not a removal. Mesh-detect was always off (a broad OUI match would flood the rate-limited LoRa uplink). NVS-persisted, so the choice survives a reboot - which also means a **fresh** board boots off, while a board that stored "on" before the flip keeps it until the user turns it off in the app. Lets a user quiet the noisy corporate-OUI match (conf 45, reports as a body cam with detail "Motorola Solutions OUI") while keeping the field-validated Axon `BWCDEVICE` tag (conf 90) and Utility BodyWorn running |
| `tracker` | enable/disable the BLE item-tracker (Find My, offline form) detector (default off). The detection is delivered to the app on the **first** sighting; what the first **60 s** holds back (`TRACKER_ALERT_DEBOUNCE_MS`) is the wire `new` flag and the offline-buffer write, so a tag you walk past does not spend the board's capture. The board never beeps for a tracker at all, inside the window or after it. See *Tracker delivery and the 60 s capture debounce* below |
| `glasses` | enable/disable the smart/recording-glasses detector (Ray-Ban/Oakley Meta, Snap Spectacles, Vuzix; on by default). Scores three BLE payload surfaces (manufacturer-data company ID, 16-bit SIG member UUIDs, the HeyCyan service UUID) and keeps the best. See [docs/glasses.md](glasses.md) |
| `netcam` | enable/disable the **network-camera** detector (default **off**, opt-in). Matches branded IP-camera OUIs (Hikvision/Dahua/Amcrest/Axis/Reolink/Ring/Wyze/eufy/Ezviz/Lorex/Swann/Arlo) on the host Wi-Fi and emits `t:10` at confidence 65 (or 75 for a field-validated block), detail "<Vendor> on wifi". Since 2.0.4 it ALSO matches a base-station SSID prefix ("ARLO_VMB_"/"NTGR_VMB_") on beacon/probe-response frames, emitting `t:10` with method `M_SSID` at confidence **88**, detail "Arlo base station" and the matched SSID in `name` - a self-attested match outranks any OUI inference. Probe REQUESTS are deliberately excluded: they name the network sought, not the transmitter. Turning it on widens Wi-Fi capture to 802.11 **data** frames so a streaming camera's cleartext source MAC can be OUI-matched; off (default) keeps capture management-frame-only for zero added CPU / 2.4GHz load. Honest scope: it matches known camera BRANDS on the network (could be an NVR/doorbell/disclosed camera) and cannot find every camera - never a "hidden camera" claim |
| `diag` | write `{"diag":true}` to request a ONE-SHOT expanded diagnostic. The reply arrives on the **Status** characteristic (Config is write-only, so there is no command-response channel) carrying `diag:true`, `wseen`, `bseen` (the radio ingest counters, HERE and not in the periodic Status since 2026-08-26; on the dual board `bseen` counts the nRF's forwards, so a flat `bseen` with `co:true` means the co-processor is up but hearing nothing), `sdrop`, `sdDeliv`, `sdBuf`, `sdRepl`, `sqHigh`, `nElide`, `nOver`, `hTrim`, `hOver`, `up`, plus `buferr` when the buffer holds a latched storage fault, plus a retained-core-dump block (`cd:true` + `cdTask` + `cdPc` + `cdSize` + `cdElf`, or `cd:false` + `cdSize` when the dump is unreadable/invalid and therefore still erase-required). Metadata only: the dump image itself is never shipped on this path. Not a setting - nothing is persisted, and it is safe to send at any time. **This reply is a DIFFERENT SHAPE from the periodic Status frame** and is notified without touching the stored Status value, so a client that adds a diagnostics button must early-out on `diag == true` BEFORE its Status decode; an all-defaults status parse of this frame reads `buzzer:false`, `desert:false`, `ign:0`, `wat:0` off keys it does not carry and un-mutes the board. Nothing under `ios/`, `android/` or `web/` writes this key today, so the reply is bench-only for now |
| `desert` | **Desert mode**: report EVERY device in range, not just known signatures (default off). See *Desert mode* below |
| `buzzer` | detection/session alert audio on/off. `false` mutes detection, connect, reveal, and preview sounds AND the boot jingle; the only cues that still play are the ones that always follow an explicit user action - the rev-B hold-to-start acknowledgment and the deliberate shutdown cue - at the saved nonzero volume (volume `0` silences those too) |
| `volume` | buzzer loudness, integer `0` to `100` (`0` is silent) |
| `led` | onboard status LED on/off (default **on**). `false` = "lights out": no idle heartbeat, no detection flashes, no boot sweep, for covert/stationary deploys. Persists across boots |
| `ble` | enable/disable the BLE detection scan. `false` stops scanning only - the GATT link to the app stays up |
| `wifi` | enable/disable the Wi-Fi (promiscuous) detection scan |
| `wifiEco` | Wi-Fi eco mode: integer seconds of Wi-Fi RX sleep between sweeps, `0` (off) / `3` / `7` / `15`. Battery-SKU power saver; BLE capture is untouched. The board reports the active value back in Status under the same key |
| `beep` | `true` plays one preview beep at the current volume (pair with `volume` to audition a level) |
| `buffer` | enable/disable the offline detection buffer (default **off**, opt-in). Every explicit `false` removes the at-rest key from RAM/NVS and durably requests erasure of any retained core dump whose task stacks may contain the key, a decrypted row, or phone coordinates. It does **not** erase the ring records themselves; drain first. See *Offline detection buffer* below |
| `bufall` | **record everything**: also buffer uncategorized nearby devices, and re-arm capture every 15 min so a revisit writes a second record (default **off**). Deploy-and-leave only, presented as one experimental **Stationary capture** switch that writes `{"buffer":true,"bufall":true,"desert":true,"buzzer":false}` in a single object after pushing the key. `bufall` without `desert` gets revisit resolution but never classifies an uncategorized device. Cleared automatically when `buffer` is set false. External USB-C power required. Widens the undrained-reboot auto-wipe threshold, which weakens the self-clean guarantee, so the client must say so where the user turns it on. **Not implemented in either app today**: the firmware honours the key, but no shipped app writes it or presents the Stationary capture switch. The disclosure requirement here and the disarm ordering below bind whichever app ships it first, as test assertions, not prose. See *Offline detection buffer* |
| `key` | 64 lowercase hex chars = the 32-byte at-rest encryption key; the app generates + persists it and pushes it on **every authenticated connection**. `sync` is refused until a valid key write has been accepted on that same session; a retained RAM key from another bonded phone never authorizes replay by itself. **The board holds the accepted key in RAM AND persists it to NVS while buffering is enabled** (`det_log.cpp` `detLogSetEnabled`), so a board left deployed keeps encrypting across reboots instead of going keyless. **TRADEOFF, state it plainly: a seized board's flash yields the key, so the at-rest buffer is decryptable and is NOT ciphertext-only.** Turning buffering off erases the key from both RAM and NVS and schedules the retained-core-dump wipe described above. If a different phone key meets a nonempty or untrusted generation, the board preserves the existing rows/key, reports session-only Status `keymis:true`, and refuses sync. Ownership transfer must be explicit: send `clearlog:true`, then re-send the replacement key (they may share one Config object; clear is processed first). A safely accepted different key still schedules the dump wipe even when the ring is empty, because old key bytes can remain in a retained stack. Flash encryption / encrypted NVS is what would restore seized-board protection. See the SECURITY block at the top of `det_log.h`. |
| `lat`,`lon` | **the phone's own GPS fix, pushed to the board.** Doubles, written as a pair and range-checked (±90 / ±180); an out-of-range pair is discarded silently. This is the only write in the protocol that carries the user's position. It is RAM-only, not NVS, but the encrypted offline ring may store the retained copy described here. The board keeps TWO copies. **The LIVE copy** (`acabBleGetPhoneGps`) belongs only to the current authenticated connection and is zeroed on disconnect. Status `gps`, live non-drone detections, BLE notify, and mesh use only this copy (an onboard/forwarded fix wins when present). **The RETAINED copy** (`acabBleGetLastPhoneGps`) may survive disconnect only when that same session supplied a key accepted for the currently published log generation; a no-key or `keymis` session clears both copies. Every successful authentication also starts by clearing both copies before Config is admitted, so two bonded phones never inherit one another's fix. The retained copy has ONE reader: `handleDetection` may put a fix younger than `DET_LOG_GPS_MAX_AGE_MS` (`0xFFFF` s, about 18h12m) into a `DetLogGpsStamp` only while no app is admitted and the row is actually bound for the encrypted ring. That stamp rides BESIDE `AcabDetection`, is read only by `detLogAppend`, and never becomes live `d.lat`/`d.lon`; a Desert row that is delivered but not buffered does not read it. The asynchronous sink additionally validates each queued row's owner-admission epoch at the final callback boundary, serialized with authentication/disconnect, so an A-era row cannot notify B or escape over mesh after a link handoff. Disconnect is a two-phase boundary: it first blocks admission and publishes the zero scanner token, then clears link-owned GPS/replay/key state, and only afterward publishes the away-session epoch together with a fresh capture generation. A sighting in that teardown window therefore cannot consume the generation intended to record the away session. Thus the retained fix reaches an AES-CTR record as `lat_e7`/`lon_e7` and no live output. It does not survive reboot. **The intended exception:** a stored record is later replayed to a session that supplies the exact accepted generation key. A different-key phone gets `keymis:true` and no replay unless it explicitly clears those rows; a phone that legitimately shares the accepted key can decrypt/replay the prior supplier's stored fix, which is the offline buffer's documented purpose. Mesh-detect separately requires a current fix newer than 60 s for LoRa and re-zeroes non-drone position at its transmission boundary. Both apps push location on connect and refresh it as the phone moves |
| `epoch` | unix seconds (the phone's wall clock). The board has no RTC, so this is the only wall clock it ever sees: it stores an *anchor* for the current boot and reconstructs capture times from it later. Persisted, so it dates records from earlier boots too. See *How replay times are derived* below |
| `sync` | start a replay drain: stream stored records with `seq` greater than this value (`0` = everything). Refused unless this authenticated session has already supplied a valid `key` that the record layer accepted |
| `clearlog` | `true` logically clears the ring immediately, then performs its real flash-sector erase in chunks (one block per loop pass, so scanning and the GATT link stay live); Status reports `wiping:true` until it finishes. It also persists an independent retained-core-dump erase generation. That intent survives power loss and a ring sweep that was already pending, and is acknowledged only after the dump partition is erased or found empty. It is also the explicit ownership-transfer authorization required before a different `key` may replace a nonempty/unknown generation |
| `ignore` | the user ignore list: an array of MAC strings (`"aa:bb:cc:dd:ee:ff"`, up to 256, unparseable entries skipped). A listed MAC is dropped where both radios converge, before anything alerts, notifies, or buffers (the synthesized `t:8` watchlist row is the one exception, see `watch`). Persists across boots; same chunked `more` protocol and same `clr` clear rule as `watch`. A half-staged chunk sequence is discarded on link drop |
| `more` | `true` on a write carrying `ignore` or `watch` **stages** those MACs without committing the list; the chunk that omits it (or sends `false`) appends and then commits the whole staged set. For lists too long for one write. Per-write, not persisted, and a chunked write carries at most one of the two lists, so the flag is unambiguous |
| `watch` | the user watchlist: an array of MAC strings (same format as `ignore`, up to 256). A watched device alerts as `t:8` every time it's seen, even with no built-in signature. Persists across boots; the app pushes its list on connect, but **only when it has something to say** (see `clr`). A MAC on both `watch` and `ignore` still alerts: on the dual-radio board the co-processor's ignore mirror is published as *ignore minus watch*, so a starred MAC is never dropped before it reaches the S3. The apps keep the two lists exclusive anyway |
| `clr` | `true` marks an accompanying **empty** `ignore`/`watch` array as a deliberate clear. **A bare `{"watch":[]}` or `{"ignore":[]}` is REFUSED** and the stored list is kept, unless this peer already committed a non-empty list for that key on this connection. Without this, any app with an empty list wiped the board the moment it connected (a reinstall, or a second phone that had never starred anything), and a starred MAC plus its label exists nowhere else. The second clause is what keeps older apps working: boards update over the air, so the board is routinely newer than the app, and an app that has already replaced the list is not granted any new destructive power by then emptying it. Per-write like `more`; a chunked write carries at most one list, so one flag serves both |
| `ota` | firmware-update control object (`sig` / `begin` / `end` / `abort` / `confirm`). `sig` is not optional: an image with no signature held is refused at `end`. See *Firmware update (OTA)* below |
| `nrfdfu` | `true` requests a **co-processor (nRF) BLE DFU** (dual board and protocol 2 only). The encrypted Config session and the two-minute physical-start window must both be live. The loop-task request is stamped to that physical link and expires across connect/disconnect; its final policy/token check and UART trigger execute under the same link-boundary lease, so a disconnect/new owner cannot land between check and action. The board replies `nrf-ready` or `nrf-denied` on OTA, then sets Status `nrfup:true` only after the loop actually forwards the trigger. The app baseline-scans first, waits for `nrfup`, then drives the signed, version-bound, application-only `.zip`. **Trust asymmetry, stated plainly** (mirrors `pair_window.h`): the S3 image is signature-verified ON the board; the nRF image is not. The nRF's stock legacy bootloader is CRC-only and cannot authenticate an image, and its UART trigger accepts a bare token, so the nRF leg's protection is entirely the session + physical-window gate on the S3 side (plus the app's own signature check on the downloaded `.zip`). Migrating the bootloader to signed Secure DFU is what would close it. See *Firmware update (OTA)* below |
| `poweroff` | `true` asks the board to power itself off (deep sleep). **v2 beacon board, rev-B only** (Status `rev`): on a rev-A slide board the wake line is held low by the slide, so deep sleep would re-wake instantly and the request is dropped; single-radio builds do not implement it at all, and on both the key is simply ignored. The write only sets a link-stamped latch; connect/disconnect expires it, and the final token check through the shutdown callback shares the same boundary lease, so phone A cannot pass the check and then power off after phone B becomes owner. Shutdown runs on the loop task because it blocks for seconds on the co-processor park handshake and then never returns, which on the BLE host task would freeze the whole stack. The latch is also dropped while an OTA is in progress, so a self-update is never interrupted (the user re-taps). There is deliberately no physical-pairing-window gate as `nrfdfu` has: powering a board off is low-risk and `WRITE_ENC` already means only a bonded peer reaches the write. **The board answers on the OTA notify channel with `{"pwr":"off"}` before it sleeps** - see *Shutdown heads-up* below, and arm your intentional-disconnect state on that notify, never on this write |

Phone-fix time and age are stamped in ESP-IDF's 64-bit monotonic microsecond domain, not uint32
`millis()`. This is load-bearing for the disconnect-retained copy: after it exceeds the finite
18h12m buffer bound it remains expired across one or many 49.7-day millis wraps, so a continuously
powered stationary board cannot revive an old owner location as fresh.

Sub-GHz (433/915 MHz) is not present on the OUI-Spy XIAO, so there is no key for it.

**The firmware re-notifies Status only after a config write that moves a field Status actually
reports.** A write that changes nothing it reports is deliberately not echoed, so never block
waiting for a Status notify after one of these: `diag` (it answers on its own frame), `beep` (a
sound, not a setting), `epoch`, `sync` (which fires at the exact moment a drain starts, the worst
moment to spend a notify), `mark`, `bbdump`, `bbclear`, `nrfdfu`, `poweroff`, any `"more":true`
staging chunk (nothing is committed yet, and echoing the stale `ign`/`wat` count made both apps
re-push the whole list), and a `key` write that re-pushes the SAME key (no records are wiped, so
`buf` does not move). Whatever those change shows up in the ~5 s periodic Status instead. Every
other key in the table echoes when the board ACCEPTS it, including `lat`/`lon`, which flips `gps`;
a write the board refuses changes nothing and so echoes nothing either. An out-of-range fix is
always refused. A bare `{"watch":[]}` without `clr` is refused only while the board has taken no
non-empty watch push on this connection, which is what protects a stored list from an app that
opens with an empty one; after any non-empty push the same write COMMITS an empty watchlist. Send
`clr` when you mean to clear.

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

### Tracker delivery and the 60 s capture debounce

`TRACKER_ALERT_DEBOUNCE_MS` (60 s) is a **capture debounce, not a detection filter**. It
used to be a 5 s dwell that suppressed the whole detection, which blinded the app for the
window and was sold as a follow-me test it was never able to make. The constant keeps the
`ALERT` in its name from that era; what it gates today is the wire `new` flag and the
offline-buffer write, and nothing else.

- **Delivery is immediate.** A tracker notifies on **Detections** from the first sighting,
  GPS stamp and all, exactly like every other type. The app has the record from second
  zero and can show and log it.
- **Nothing sounds for a tracker, at 1 s or at 61 s.** `ACAB_TRACKER`'s entry in the
  firmware's alert-pattern switch (`alerts.cpp`) is an empty case, and `alertsSignal`
  excludes the type from the first-hit reveal sting as well, so a tracker produces no beep
  and no alert LED flash at any point in its life, in every alert mode. That is deliberate:
  the category is opt-in and a stranger's tag riding past would otherwise sound all day.
  Starring the MAC is the way to get a sound, but only for a device no built-in signature
  claimed - the `ACAB_WATCHED` row is synthesized only when nothing else matched the
  advert, so a starred tag the tracker detector already matched stays `t:5` and stays
  silent.
- **`new` is what waits.** For the first 60 s the board clears the detection's `new` flag,
  so a tracker's opening minute arrives as `new:false` on every frame; the first sighting
  past 60 s is forced to `new:true` once, and from then on the ordinary dedup-window rule
  applies. Read `new` on a `t:5` row against this section rather than against the general
  "first sighting in window" rule.
- **The offline buffer waits with it.** A sighting inside the window is delivered but not
  written to the encrypted flash ring, so a tag you merely walk past does not spend the
  board's capture. `bufall` (record everything) relaxes this term on purpose: a tag that
  came by once and left is exactly what a deploy-and-leave capture exists to catch.
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
{"fw":"ACAB-ouispy 2.0.5","proto":2,"up":1234,"total":42,
 "ble":true,"wifi":true,"wifiEco":0,"axon":true,"moto":false,"tracker":false,"glasses":true,
 "flock":true,"drone":true,"droui":false,"ncam":false,"buzzer":true,"vol":80,"gps":false,
 "buf":0,"bufon":false,"desert":false,"ign":0,"wat":0}
```

Every key in that frame is emitted on every Status update. The conditional keys (`pairw`,
`bufall`, `bufsat`, `buferr`, `wiping`, `ledon`, `nbb`, `bat`, and the dual-radio
block) are absent here on purpose: each is emitted only when it has something to say, and
absent means the default.

The radio ingest counters `wseen` / `bseen` and the sink-drop total `sdrop` are **not in this
frame any more**: they moved to the `{"diag":true}` reply on 2026-08-26. Neither app parsed them
(this document's own receipts section records that), the receipts contract consumes them as
deltas between a *start* diagnostic and an *end* diagnostic - which is that reply - and their
three full-uint32 slots are what brought the worst-case Status frame back under the firmware's
512-byte publish guard. The host-test budget (`test_acab_ble_service.cpp`) now holds every
reachable Status document strictly under that guard as a hard ceiling.

| Key | Meaning |
|---|---|
| `proto` | BLE JSON contract version, integer. Bumped ONLY on a BREAKING change to this contract; additive keys never move it, because both apps ignore keys they do not know. **ABSENT MEANS 0**, which means fully compatible: every firmware before 2026-08-06 omits it. An app whose supported version is LOWER than the board's must say "this board needs a newer app" rather than keep parsing fields whose meaning may have changed |
| `fw` | firmware build + version, `"<label> <version>"`, at most 32 chars (the builder's buffer is sized so the longest real label, mesh-detect's 23 chars, plus a version up to 8 chars fits without truncation - load-bearing because both apps parse the version off the END of this string) |
| `up` | uptime (seconds) |
| `total` | detections emitted this session |
| `ble` / `wifi` | detection scan active for that radio (reflects the `ble` / `wifi` config toggles) |
| `wifiEco` | active Wi-Fi eco value: seconds of Wi-Fi RX sleep between sweeps, `0` (off) / `3` / `7` / `15`. Mirrors the `wifiEco` config key; both apps read it to drive the eco picker |
| `pairw` | seconds left in the new-phone pairing window. **Emitted only while the window is open**; absent = closed (the normal steady state). Lets an app show a setup countdown; neither app parses it today |
| `buferr` | latched storage-fault bitmask for the offline buffer, **emitted only when nonzero**. Bits `0x01` read, `0x02` erase, `0x04` write, `0x08` corruption, `0x10` lock, and `0x40` cryptography (random generation, nonce/key hashing, or AES) mean the ring stopped accepting evidence rather than pretending it was stored. Bit `0x20` means NVS rejected an offline-buffer metadata load or save, including generation, anchor, connection/privacy lifecycle, saturation, and diagnostic-fault state; eligible work is retried from the loop task, and this bit alone does not condemn sound raw-ring geometry. The mask is historical: recovered faults remain visible until a fully successful physical wipe clears it. Both apps treat every non-`0x20` bit, including unknown future bits, as `OFFLINE LOG INCOMPLETE`; `0x20` additionally shows `BUFFER METADATA ERROR RECORDED`, says current status may already include a successful retry, asks the user to confirm buffer state and replay timestamps, and explains that a clear resets the warning |
| `flock` | Flock/ALPR detector enabled. A missing key (older firmware) is treated as on |
| `drone` | drone Remote ID detector enabled. A missing key (older firmware) is treated as on |
| `droui` | drone vendor-OUI fallback enabled. A missing key (older firmware) is treated as off (opt-in, default off) |
| `axon` | body-cam category enabled (Axon plus Utility BodyWorn plus, gated by `moto`, the broad Motorola OUI) |
| `moto` | broad Motorola Solutions OUI sub-toggle enabled. **An absent key means pre-split firmware**, where the broad match rode the body-cam toggle with no separate switch: treat absent as `true` and hide or disable the sub-toggle in the UI, since writing `{"motorola":...}` to that board does nothing. Present means the board honours the sub-toggle. Note this reports the sub-toggle's own value, so `"axon":false,"moto":true` is normal and still means no Motorola hits (both switches are required) |
| `buzzer` | detection/session alert audio enabled. `false` also mutes the boot jingle; only the explicit-user-action cues (rev-B hold-to-start ack, deliberate shutdown) are independent of it |
| `vol` | buzzer volume, `0` to `100` |
| `gps` | a GPS fix is being applied to fixed-device detections |
| `buf` | number of detections currently held in the offline buffer |
| `bufon` | offline buffering is enabled |
| `keymis` | present + `true` only when this authenticated session offered a different key for a nonempty or untrusted log generation. The board preserved the existing key/rows and denied sync; surface an ownership-conflict notice requiring explicit log clear before replacement. Absent = false. Session-only and rebuilt at authentication, so it cannot carry from phone B into phone A's next link |
| `bufall` | record-everything mode is on. **Sent only when true**; absent means off (saves MTU, same idiom as `ledon`). Not parsed by either app today (the feature has no app-side switch yet) |
| `bufsat` | Stationary/record-all mode reached ring capacity, so later uncategorized nearby rows **may have been omitted**. Set on the exact transition to full (and when `bufall` is enabled on an already-full ring), sent only when true, persisted across reboots, and cleared by `clearlog`. It is a capacity/censoring-risk flag, not proof that a refusal already happened; `bufdrops` is the current boot's actual-refusal counter. Both apps surface it beside the evidence in Logbook and repeat it at the Offline Buffer control: a full capture cannot prove whether power stopped immediately after the exact-fill row or listening continued after capacity |
| `wiping` | present + `true` **only while** a deferred buffer erase is still sweeping (an explicit `clearlog`/authorized ownership transfer or an automatic lifecycle wipe runs the flash erase one block per pass so the radios stay live). While set, the board writes no new records; absent = idle. The app can gate a "clearing…" state on it and knows a fresh `sync` won't capture anything until it clears |
| `ledon` | onboard LED enabled. **Omitted when on** (the default), so an absent key means on; sent as `false` only in lights-out mode |
| `tracker` | BLE item-tracker detector enabled |
| `glasses` | smart/recording-glasses detector enabled |
| `ncam` | network-camera detector enabled. A missing key (older firmware) is treated as off (opt-in, default off) |
| `desert` | Desert mode enabled (reporting every device in range) |
| `ign` | number of MACs on the board's ignore list (for app reconciliation) |
| `wat` | number of MACs on the board's watchlist (for app reconciliation) |

For `buferr`, the `0x01` read bit also covers an unavailable or invalid raw-ring partition. Both
shipping targets require that partition, so absent/too-small geometry is a storage failure, not an
empty buffer or a normal long-running `wiping` state.

**`bufall` and `bufsat` are sent only when true, so ABSENT MEANS FALSE, in every fresh
status frame, not just the first.** Latch them per frame, never cumulatively, or a stale
saturation warning survives a `clearlog` forever and tells the user a complete log is truncated.

**Disarming Stationary capture is an ordered sequence and the order is load-bearing.** Writing
`buffer:false` clears the at-rest key from RAM and NVS, so doing it before the replay finishes
leaves the remaining records undecryptable while still occupying the ring: the deployment is
destroyed by the act of collecting it. On collection:

1. Connect and let the replay run to completion.
2. Confirm it ended cleanly, and compare all three numbers rather than two: `hist:begin.n`, the
   `{"hist":"end","n":N}` sentinel, and the count actually received. `received < end.n` is a gap,
   so re-sync, not proceed. `end.n < begin.n` means this attempt stopped before every promised row
   was queued; re-sync too. The board's two-phase replay leaves an over-cap row uncommitted in the
   ring, so a larger-MTU peer or corrected schema can retry it. Do not disable buffering or erase
   the log until all three match. See *Why the replay check needs all three numbers*.
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
| `nbb` | nRF black-box record count (the co-processor's own diagnostic ring). Present only when a co-processor is attached. The board saturates it at 65535 when reading the co-processor's `D` line, so a garbled UART frame cannot widen the field |
| `nrfv` | the co-processor's last-reported app version (integer), learned from its `V<n>` line. Emitted only once the nRF has announced a version; the app gates the "co-processor update available" offer on a known `nrfv`. Clamped to `0..9999` at the firmware's UART boundary (the line is untrusted input; the real domain is a small monotonic int, currently 2), so the value is never more than 4 digits |
| `nrfup` | present + `true` **only while** a co-processor BLE DFU is in flight (the fault-mute window is open). Absent otherwise. While set, the app shows "updating co-processor" and mutes the nRF fault banner even though `co` reads `false` (the nRF is in its bootloader). The window clears event-driven the instant the nRF reports a fresh version, or after a 5-minute ceiling. See *Firmware update (OTA)* / the combined one-click update |
| `rev` | carrier-board revision, `"A"` or `"B"` (dual board only; absent on older firmware and single-radio builds). `"A"` = the first 250 boards (slide switch, copper-crossed UART); `"B"` = button power + VBUS sense. Shown next to the fw label on the device screen so support can identify the board without opening the case, and used as a belt-and-braces OTA gate: if the board reports a revision, the manifest entry about to be flashed must agree (the PRIMARY defence is that the two revisions carry distinct fw labels, `beacon board` vs `beacon board rev-B`, and the manifest is keyed by label). Apps must treat ABSENT as "not told", never as rev-A |

## Desert mode

Off by default. When enabled (`{"desert":true}`), the board reports **every** device
it sees - not just the known surveillance signatures - as a `Nearby device` detection
(`t=7`). The specific detectors still run first, so known gear keeps its real type;
Desert mode only labels the leftovers. Each nearby device is tagged hardware-OUI vs
randomized-MAC (phones rotate theirs). On Wi-Fi that is the locally-administered
bit. On BLE it is the controller's reported address type, which only the native
single-radio scan can see; on the dual-radio board a BLE address with the bit clear
is tagged "OUI unknown" rather than claimed as hardware. Rows carry the
BLE advert name or Wi-Fi SSID when
present. Built for low-RF / remote areas (the desert) where anything new on the air is
worth knowing about. It reuses the dedup and alert pipeline, so it shows, logs, and alerts on new
devices like any other detection. **The offline buffer is the one part it does NOT reuse:**
`shouldBuffer` in `handleDetection` refuses `t=7` outright, because the ring is append-only with no
type filter of its own and a dense area's phones would wrap it and evict the ALPR / body-cam hits
the owner synced to get. Only the firmware-only `bufall` switch (`detLogSetBufferAll`, unreachable
from either app today) relaxes that. So a Desert row is delivered live and is never replayed.

## Offline detection buffer

The board can record detections to encrypted flash while the app is disconnected,
then replay them when the app reconnects, so a walk with the app closed isn't lost.

**A buffered NON-DRONE row may carry a position, and it is always stale.** The board has no GPS, so
that position is the retained phone fix described under the `lat`,`lon` config key: it is stamped
only within the boot the fix was pushed in, and `gage` carries its age.

**No stored record carries a real coordinate beside a saturated `gpsAgeSec`**, and the read-side
bound on the retained fix is not what guarantees it. There are two ways a coordinate reaches this
ring, and only one of them is bounded at its read. The retained-fix stamp asks for a fix younger
than `DET_LOG_GPS_MAX_AGE_MS` (`0xFFFF` s, about 18h12m, which is `gpsAgeSec`'s own uint16 range).
The LIVE stamp does not: `handleDetection` takes that one at ANY age, and such a row reaches the
ring whenever the link drops between ingest and `sinkTask`. `detLogAppend` therefore enforces the
bound at the WRITE, where both paths converge, and drops `lat_e7`, `lon_e7` and `gpsAgeSec`
together on any record over it. A board left out longer than that keeps recording WHAT went by and
stops claiming WHERE.

A record with no position under those rules is stored with `lat_e7 = lon_e7 = 0` and replays with
no `lat`/`lon` keys at all, exactly like a live row heard with no fix. So render a replayed
non-drone position as where the PHONE last was, never as where the board or the detected device
was. Drone rows are unaffected by any of this: `lat`/`lon` there is the aircraft's own broadcast
position, kept ahead of any offered stamp by `detLogAppend` itself, on the replay path exactly as
on the live one.

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

AES-CTR's counter domain is separate from the phone-visible replay token. Each initialized ring
namespace holds an unpredictable durable 128-bit `cryptdom`; for every record the firmware hashes
the fixed-width `cryptdom || boot(uint32) || seq(uint32)` tuple with SHA-256, uses the first 15
digest bytes as the per-record prefix, and reserves the final counter byte at zero. The 52-byte
encrypted payload consumes counters 0 through 3. This keeps boards and post-wipe namespaces from
reusing a keystream even though the app's buffer key is shared across boards. A logical wipe
rotates both the replay generation and crypto domain through the same power-loss-safe transaction;
missing generation/domain metadata condemns retained rows to a physical wipe instead of guessing,
and a nonce-hash failure refuses append/replay rather than encrypting under a zero or partial nonce.

The IDF core-dump partition is a second at-rest surface. A panic can retain live task-stack copies
of the key, a decrypted record, or phone coordinates outside the encrypted ring. `clearlog`, every
safely accepted key replacement, and every explicit `buffer:false` therefore advance an independent NVS
erase generation. `acabCoredumpWipeTick()` clears that generation only after the dump partition is
erased or found empty. The request survives a power loss and remains distinguishable from the
ring's shared auto-wipe/resume state; completing an older generation cannot acknowledge a newer
request. A boot-count auto-wipe without explicit intent deliberately preserves the just-reported
post-mortem for diagnosis.

### Connect handshake

After subscribing to Detections, the app writes to Config, in order:

```json
{"key":"3f9a...<64 hex>"}
{"epoch":1718900000}
{"sync":1503,"syncgen":2846150937}
```

- `key` 32-byte at-rest key (generate once, persist in the Keychain / Keystore). It must be accepted
  on this authenticated session before `sync`; merely retaining a prior session's key is not proof
  that the current bonded phone owns it. If Status reports `keymis:true`, preserve the notice and
  require explicit user confirmation before sending `clearlog:true` plus the replacement key.
- `epoch` current unix time. The board anchors this boot to it (and persists the anchor), which is what lets it reconstruct absolute times on replay. It does not stamp records at capture; nothing absolute is ever written to flash.
- `sync` the highest `seq` the app has durably filed (`0` on the first ever sync).
- `syncgen` the nonzero uint32 generation token that gives `sync` its meaning (`0` when
  unknown). The app persists the two as one logical tuple, only after the corresponding
  detection-store checkpoint succeeds. Older apps omit this field; the board treats an absent
  or zero token as unknown and safely offers its full retained window.

The board processes `clearlog` before `key` when both are in one Config object, so an explicitly
confirmed ownership transfer may be sent atomically as `{"clearlog":true,"key":"..."}`. Without
that explicit clear, a mismatched phone key never silently wipes another bonded phone's history.

### Replay records

The board streams a **begin** sentinel carrying the pending count, then each stored
record over **Detections** as the normal detection JSON plus a few keys, then an **end**
sentinel:

```json
{"hist":"begin","n":12,"from":1504,"gen":2846150937}
{"t":1,"s":0,"meth":3,"c":45,"mac":"d4:ad:..","rssi":-71,"n":1,"new":false,"hist":true,"seq":1504,"at":1718899820,"ms":412553,"boot":37}
{"hist":"end","n":12}
```

A replayed record carries only what the fixed 64-byte stored record holds. `det` and `cid`
are live-notify only (see their rows in the key table), as are the drone kinematics (`alt`,
`spd`, `vspd`, `hdg`, `hgt`, `palt`, `plat`, `plon`, `sta`); `name` replays truncated to
6 characters. An absent `det` on a `hist:true` row means "not stored", never "no detail
existed".

| Key | Meaning |
|---|---|
| `hist` | `"begin"` on the lead-in sentinel, `true` on a replayed record, `"end"` on the closing sentinel |
| `seq` | monotonic record id; the app persists the highest contiguous value as its sync cursor |
| `at` | unix seconds, uint32. **Reconstructed, never a clock reading** (the board has no RTC). Present only when the record's own boot had an anchor AND the uptime span between record and anchor is inside the 7-day acceptance window. See *How replay times are derived* |
| `approx` | present + `true` **instead of** `at`, when the record's boot was never anchored, or when it was anchored but the span between record and anchor falls outside the 7-day window (a possible `millis()` wrap alias, so the board declines to date it). Not "roughly right": it means the board declines to state a time at all |
| `ms` | uint32, `millis()` uptime at capture, relative to the boot named in `boot`. **Guaranteed alongside `approx`**, because there it is the only dating information that exists. On an `at`-bearing record it is droppable: see *Replay trim ladder* below |
| `boot` | uint32, which boot session captured the record. Same rule as `ms` - guaranteed on an `approx` record, droppable on an anchored one. The two always travel together, so a record carries both or neither |
| `n` (begin) | records the board is about to replay, so the app can show a determinate "X of N". This is the pending-drain count, **not** Status `buf` (which is total ring occupancy) |
| `from` (begin) | first `seq` this drain will send (integer). It is normally `<sync>+1` only when `syncgen` matches; otherwise the board starts at its retained ring floor. See *Generation-safe cursors* below |
| `gen` (begin) | the board's current nonzero uint32 record-generation token. It is unpredictable, changes on every completed ring wipe, and is never intentionally reused across boards or NVS loss |
| `n` (end) | total records the board actually sent this drain |

The **begin** sentinel only precedes a non-empty drain (a bare reconnect with nothing
buffered sends neither sentinel). The app files history records the same way as live ones
(dedup by id), takes its timestamp from *How replay times are derived* below, and does
**not** alert on them. The begin `n` seeds a determinate progress indicator; on the
**end** sentinel the app checks it received `n` records and re-issues
`{"sync":<lastGoodSeq>,"syncgen":<gen>}` to fill any gap (re-delivery is idempotent
via dedup).

### Replay trim ladder

A replay frame that will not fit the peer is **degraded, not dropped**. This is the opposite
trade from the live path and for a sharper reason: a live sighting that does not fit is one
missed alert from a device that is usually still transmitting, while a replay record that does
not fit may be the only retained evidence. The record layer therefore peeks without advancing;
the BLE layer commits that exact `seq` only after NimBLE's host queue accepts a fitting notify.
An MTU, serialization, queue, clear, or disconnect race can cause a duplicate on re-sync, but
cannot advance past a frame the stack rejected.

The board builds the full frame first. Only if it exceeds the peer's notify capacity does it
rebuild down this ladder, one step at a time, stopping the moment the frame fits:

| Step | Drops | Why it is cheap |
|---|---|---|
| 1 | `new` | always `false` on a replay row; both apps default the absent key to false, so nothing is lost |
| 2 | `ms` + `boot`, and **only when `at` resolved** | on an anchored row they are a cross-check on a time the app already has. An `approx` row keeps them, because for an unanchored boot they are the only dating information there is |
| 3 | `name` | the buffer's truncated 6-char label. `t` still carries the class and `mac` the identity |
| 4 | `lat` + `lon` + `gage`, as ONE step | WHERE something was heard is half of what a deploy-and-leave capture was left to recover, and the three keys leave together so a stale coordinate can never outlive the age that qualifies it |
| 5 | `id` | last-resort bounded core. A drone loses its rotation-stable UAS identity but remains an ordered observation keyed by `t`/`mac`/`seq`; losing which drone is bad, losing the row is worse |

Each step suppresses that field and every field above it. Steps that cannot shrink **this**
record (no `at`, no `name`, no position at all) are skipped without a rebuild but still count as
reached.

Two properties of step 4 are load-bearing, and neither is an accident of ordering. **The three
keys are bound together** because a buffered non-drone position is always a stale phone fix and
`gage` is the only key that says so; both apps gate their staleness wording on it, so a coordinate
emitted without it reads as a pin taken on the spot. There is no trim value at which the
coordinate ships and `gage` does not. **And it is ordered after metadata but before the final ID
sacrifice**: steps 2 and 3 shed a cross-check on a time the app already holds and a 6-char
truncation whose class is in `t`; position and then UAS identity are progressively more expensive.
A drone row carries no `gage`, so the position step can still shrink it, and only if that remains
too wide does the last rung remove its long ID.

Scope, so nobody over-reads it: the ladder applies **only** to `hist:true` records, and only when
the full frame is over the cap. An Android link (MTU 512, so `notifyCap()` 500) never reaches step
1 in practice, because the largest replay frame measured is ~212 B. An iPhone at MTU 185
(`notifyCap()` 182) trims most GPS-stamped rows: a measured ALPR row with a GPS stamp is 211 B
full, and a drone row with a 19-char UAS id is 212 B full. Both were lost outright before the
ladder existed. Per-step byte figures used to be quoted here; they were measured against an older
step order that shed different keys and have not been re-measured, so they are deliberately not
restated rather than carried forward wrong. The live `detect_elide.h` ladder never applies here,
because the buffer's fixed 64-byte record persists none of the fields that ladder sheds.

The last rung uses a fixed-format JSON builder with no variable-length value (the MAC string is
always 17 characters). At the widest legal value for every retained integer, an unanchored frame
is 159 bytes; the anchored form is shorter. The host budget independently reconstructs that exact
envelope and pins it below the iPhone-class 182-byte payload. This is the supported-peer guarantee,
not a measurement from one sample record.

Two counters in the `{"diag":true}` reply report it. **`hTrim`** counts records that went out
short. **`hOver`** counts a fully trimmed attempt that still exceeded the peer's capacity. That is
unreachable at the normal iPhone cap under the 159-byte bound, but a smaller peer or future schema
fault is handled safely: the board does not commit the row, stops that drain, and sends an end
sentinel whose count is short. The named `seq` remains in the ring for a later sync; `hOver` means
"blocked attempt", not permanent evidence loss. The USB serial warning names the blocked seq and
is rate-limited to one line per 5 seconds.

### How replay times are derived

These records are meant to be usable as evidence, so the contract is not "show a time", it
is "show a time together with how it was derived and how precise it is". A reconstructed
time displayed as if it were a clock reading is worse than no time at all, because it
invites confidence the method cannot support.

**The board has no real-time clock.** A buffered record stores exactly two time facts,
`whenMs` (uptime at capture) and `bootCount`. Nothing absolute is ever written to flash.
So `at` is **always** computed, never read from a clock:

```
deltaMs = signed(whenMs - anchor.atMs)       // valid on EITHER side of the anchor
at      = anchor.epochUnix + deltaMs / 1000  // accepted only when |deltaMs| < 7 days
```

looked up by the **record's own `bootCount`**, not by the current boot. A record captured
three power cycles ago still resolves, as long as its own boot was anchored.

Note the sign and the acceptance window (`det_log.cpp`). A capture can sit on either side
of its anchor: **before** it for the boot being drained right now (the app pushes a fresh
epoch on connect, so that refreshed anchor is newer than everything buffered), and **after**
it for every prior boot (the board only buffers while disconnected and only anchors on a
sync push, so a prior boot's records were necessarily captured after that boot's last sync).
Uptime is monotonic within a boot, so forward reconstruction is exactly as sound as backward.
The unsigned-subtract-then-cast signed difference stays wrap-correct across a `millis()`
rollover, but beyond `ANCHOR_SPAN_MAX_MS` (7 days) a wrap cannot be told from a genuinely
huge gap, so the board declines to date the record and sends `approx:true` even though the
boot was anchored. An app re-deriving `at` from `ms` and `boot` must use the same signed
delta and the same 7-day acceptance window.

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
| **Reconstructed** | `hist:true` + `at`, with `ms` + `boot` present unless step 2 of the *Replay trim ladder* dropped them | Derived from that boot's anchor. Honest to within crystal drift (below). Present it as derived, not as a reading |
| **Bracketed** | `hist:true` + `approx:true` + `ms` + `boot`, and the app can bound it on **at least one** side | A range only. Render as a range, never as an instant |
| **Unknown** | `hist:true` + `approx:true` + `ms` + `boot`, no bound available on either side | Order only, via `seq` and `boot`. No time. Current copy is "time unknown · offline buffer" |

Bracketed covers the **one-sided** cases too, not just the both-sides one. A boot with an
anchored predecessor but no anchored successor bounds as "after X"; the reverse bounds as
"before Y". Only a record with neither bound falls to Unknown. Note also that the newest
unanchored boot always lacks an anchored successor, yet is still bounded above: every
buffered record was necessarily captured before the sync that collected it, so the sync's own
start time is a sound upper bound and the apps use it.

`ms` and `boot` are sent on **both** `approx` cases without exception, and on the Reconstructed
case whenever the frame fits: they are step 2 of the *Replay trim ladder*, given up early on a
small-MTU peer precisely because an anchored row already carries the time they would verify. On
the board's side they are what makes verification and re-derivation possible; on the app's side,
ordering records within a boot is implemented today, while re-deriving against an app-held anchor
history deeper than the board's eight entries is a **design intent, not shipped behaviour**. Do
not read this table as a description of app features.

One consequence worth designing for: over an iPhone-class link step 2 fires on most anchored
rows, so a drain can arrive carrying `boot` values only on its `approx` records. An app that
brackets an unanchored boot against its anchored neighbours may therefore find no neighbours in
that drain and fall back to Unknown. Those rows were dropped entirely before the ladder existed,
so this is a demotion from a shape that never arrived, not a regression - but do not assume a
drain always names its anchored boots.

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

### Generation-safe cursors

`seq` is monotonic only **within one record generation**. A wipe resets it to 1, and the same
app can connect to multiple boards, so sequence numbers alone cannot identify already-filed
records. Each generation therefore has an unpredictable nonzero uint32 `gen` token. Randomness
is a correctness requirement, not secrecy: starting every board at 1, or merely incrementing a
counter, would let board A's saved cursor match fresh board B or a board whose NVS was reset and
silently skip B's early records.

The app sends its durable `{syncgen,sync}` tuple. The board honors `sync` only when `syncgen`
exactly matches its current token. A missing, zero, malformed, or different generation means
"unknown cursor": the board drains from its retained ring floor and announces the authoritative
`{gen,from}` in the begin sentinel. The app then rebases its in-memory cursor to `from - 1`, files
the rows idempotently, and persists the new generation+cursor only after the same detection-store
checkpoint succeeds. A crash before that checkpoint leaves the old generation durable, causing a
safe replay rather than an omission. Legacy firmware without `gen` retains the older downward
`from` rebase as a compatibility fallback.

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

1. `{"ota":{"sig":"<hex DER>"}}`. **Required, and easy to miss because it is a separate control
   message.** The detached ECDSA P-256/SHA-256 signature over the whole image, hex-encoded DER,
   at most 80 bytes decoded. The board holds it and verifies it at `end` against a public key
   baked into the firmware. It is handled independently of `begin`/`end`/`abort`/`confirm`, so
   its order on the wire is free and `begin` does not clear a signature already held; both
   shipped apps send it immediately before `begin`. A client that never sends it streams the
   entire image and then loses the whole transfer at step 4 with `{"ota":"err","e":"sig"}`,
   because the finish path fails closed on a missing, unverifiable or bad signature. `abort` and
   a completed `end` both drop any held signature, so each session must send its own.
2. `{"ota":{"begin":true,"size":<bytes>,"crc":"<hex32>","ver":"<x.y.z>"}}`. `crc` is a
   standard zlib CRC-32 of the whole image, hex. `ver` must be strictly newer than the
   running firmware (add `"force":true` to override for a rebuild/beta). The board
   answers `{"ota":"ready","size":N}` or `{"ota":"err","e":"..."}`. Scanning pauses for
   the transfer.
3. Stream the raw image bytes to the OTA characteristic with write-without-response, in
   chunks of at most (negotiated MTU - 3). Pace against the platform's write-queue
   back-pressure; the board notifies `{"ota":"prog","rx":<bytes>,"pct":<n>}` every 64 KB.
4. `{"ota":{"end":true}}`. The board verifies size + CRC + image signature, points the
   bootloader at the new slot, arms rollback, notifies `{"ota":"done"}`, and reboots.
   On any failure it notifies `{"ota":"err","e":"crc|size|image|sig|..."}` and stays on the
   current firmware.
5. Reconnect after the reboot (same bond). Read Status: `fw` should show the new
   version. Send `{"ota":{"confirm":true}}` to mark the image healthy. Before its durable
   product-health gate is ready the board answers `{"ota":"health-wait"}`; after it has
   durably disarmed rollback it answers `{"ota":"ok"}`. If the app never confirms, the board self-confirms after 20 s of
   healthy uptime; if the new image fails to reach a healthy state at all, the next boot
   rolls back to the previous firmware, and the app should surface that the update was
   rolled back.

`{"ota":{"abort":true}}` cancels an in-flight session (the board answers
`{"ota":"abort"}` and resumes scanning). A dropped link mid-transfer aborts the session
server-side; start over from `sig`, not from `begin`; an abort clears the held signature
along with the session.

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
the stock nRF bootloader validates CRC rather than the package signature; signature verification
for that leg happens on the phone. the ESP32-S3 separately verifies its image signature on the board.
After Nordic reports completion, the initiating S3 must report the target `nrfv`; only then does
the combined coordinator begin S3 OTA. If the connected board still runs protocol 0 or 1, the app
offers only the S3 update. The user must then physically power-cycle, reconnect on protocol 2, and
start the separately authorized nRF update.

### Shutdown heads-up: `{"pwr":"off"}`

The OTA characteristic carries one notify that has nothing to do with firmware. It has no `ota`
key, so route on the key rather than assuming every frame on this channel is an OTA reply:

```json
{"pwr":"off"}
```

The v2 beacon board sends it immediately before it deep-sleeps, on **both** shutdown paths: the
app's `{"poweroff":true}` write (rev-B only), **and** a physical power-off (a ~1.5 s button hold
on rev-B, the slide switch flipped to "off" on rev-A). It means the link is about to drop on
purpose. Single-radio builds never send it, and neither does the silent boot-gate re-sleep that
parks a boxed unit.

**Arm your intentional-disconnect state on this notify, never on the write.** The board sends it
only when it is genuinely about to drop, so a board that ignores `poweroff` (older firmware, or a
write lost on the wire) never says "off" and never leaves a stale flag armed to mis-classify some
later unrelated disconnect. Arming on the write instead is what produces a spurious "connection
lost" error on a clean, user-requested shutdown, or swallows a real one afterwards. Both shipped
apps do it this way (iOS `handlePwrNotify`, Android `handleOtaNotify`), and the button-hold path
is exactly why the rule is "on the notify": that shutdown has no write to arm on at all.

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
- no new `hOver`, the per-record account of a fully trimmed replay attempt that blocked
- clean replay: `hist:begin.n == hist:end.n == records actually received`, no sequence gaps, no
  accepted-after-retry-cap state
- live-notify drops are **not** relevant here; nothing was being delivered live

### Radio health cannot validate every receipt

Health is **per-radio**, never both. A BLE receipt needs `bseen` to have advanced; a WiFi receipt
needs `wseen`. Both counters ride the `{"diag":true}` reply (since 2026-08-26 they are no longer
in the periodic Status frame), which is exactly where a start/end-delta contract wants them: the
client requests a diagnostic at each endpoint rather than fishing values out of whichever
periodic frame happened to arrive. A radio that is disabled or irrelevant to this detection is
**"not evaluated"**, never "healthy" and never a failure.

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

`hist:begin.n` is the number promised. `hist:end.n` is the active BLE replay session's `sent`
counter, which counts records that were accepted by NimBLE's host queue and committed for that
exact transport generation. The app's received count is what actually crossed the unacknowledged
air link. Replay therefore peeks and sizes outside the transport lock, then binds the final queue,
record-layer commit and count update to one generation transaction:

```c
if (detLogPeekForDrain(&r)) {                          // cursor has NOT advanced
    while (len > notifyCap() && trim + 1 < HIST_TRIM_MAX) { trim++; /* rebuild shorter */ }
    if (len > 0 && len <= notifyCap()) {
        ReplayLock lock;
        if (!replay.mayQueueRecord(sessionToken)) return; // sync/disconnect invalidated this burst
        if (!queueDetNotify(...)) return;              // same peek retries next tick
        if (!detLogCommitDrain(r.seq, r.drainGeneration)) return;
        replay.noteRecordCommitted(sessionToken);      // end.n belongs to this generation only
        if (trim != HIST_TRIM_NONE) gDrainTrimmed++;   // ships as `hTrim`: delivered, short
    } else {
        gDrainOverCap++;                               // blocked attempt; seq remains in the ring
        detLogStopDrain();
    }
}
```

The same transport generation owns the begin and end sentinels. A new `sync`, disconnect,
`clearlog`, key install/rotation, or buffer disable invalidates it; the burst revalidates before
every queue and before every subsequent record, so replacement data cannot precede its own begin
and a stale completion cannot increment or close the replacement envelope.

`begin.n = 100, end.n = 99, received = 99` remains a meaningful incomplete attempt: comparing
only received to end would miss the promised row. When `hOver` advanced, that row was not consumed;
it can be retried from the app's last good cursor on a larger-MTU peer or corrected firmware.
Separately, `begin.n = end.n = 100, received = 99` is an on-air notify gap; re-sync is also safe
because the app cursor rebases the board's per-drain cursor and duplicate delivery is idempotent.
Compare all three and do not erase or disable until they match.

Both apps now do: `received == end.n` drives a bounded gap/resync loop, and a
`begin.n > end.n` shortfall is surfaced in the reconnect banner as records that could not be
replayed in that attempt. Reaching the per-connection retry cap stops the immediate radio loop but
does **not** advance the durable cursor past a gap; the next connection or user retry starts again
from the last contiguous sequence. Client comments that call a shortfall permanent describe the
old consume-before-size firmware and must not be used as the protocol contract.

This is **replay completeness**, unrelated to `nOver`, which counts oversized *live* notifications.
Replay oversize has its own pair: `hOver` counts blocked fully-trimmed attempts and `hTrim` counts
the records delivered only by shedding keys. Both ride the `{"diag":true}` reply, which no shipped
client requests yet, so today the `begin.n` minus `end.n` shortfall is still the only signal an
app has - it says how many, never which or why.

### Drop counters: what each one actually means

| field | meaning | evidence impact |
|---|---|---|
| `sdBuf` | buffer-bearing enqueue failed | **permanent loss** of a record the user asked to keep |
| `sdDeliv` | live notify dropped | **possible** loss, usually re-arrives on the next sighting, but a one-time advert never does |
| `sdRepl` | replay/black-box dump attempt dropped | none, the source ring still holds it |
| `nElide` | live record fit only after shedding optional RID fields (`detect_elide.h`) | the alert went out, SHORT. Absent drone fields are "not sent", not "not broadcast" |
| `nOver` | live record exceeded negotiated notify capacity even fully elided | live observation lost |
| `hTrim` | replay record fit only after the *Replay trim ladder* shed `new`/`ms`+`boot`/`name`/`lat`+`lon`+`gage`/`id` | the record went out, SHORT. Read an absent key as withheld, not as absent from the buffer |
| `hOver` | replay record exceeded that capacity even at the fixed 159-byte core | drain attempt blocked; the row was **not committed** and remains retryable. Indicates a sub-159-byte peer cap or schema/budget regression, not permanent loss |

`sdDeliv` is not benign in the opportunistic case. A Falcon probe request or a single BLE advert
that never repeats is exactly what this product exists to catch.

`sdrop` is the sum of the first three, and of those three only. `sdrop == 0` does correctly imply
`sdBuf == 0` **for the current boot**, but it says nothing about the four MTU counters below it,
which are tracked separately. `sdrop`'s problems are that a nonzero value is ambiguous between
outcomes with very different meanings, and that it resets across reboots. Read the individual
counters. All of these are since-boot, none is per-drain.

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
- **Neither app parses `sdrop`, `sdBuf`, `sdDeliv`, `nElide`, `nOver`, `hTrim` or `hOver`
  today.** The apps do parse and prominently surface the two evidence-integrity fields that reach
  periodic Status, `bufsat` and `buferr`. `sdrop`, `wseen` and `bseen` moved wholly into the
  `{"diag":true}` reply on 2026-08-26 (that verification of non-consumption is what made the move
  safe), and the rest were always visible solely there, a reply no shipped client requests. That
  ingestion is a prerequisite for version 2, not a follow-up.

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
