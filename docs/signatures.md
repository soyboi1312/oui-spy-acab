# ACAB detection signatures (clean-room reference)

Every signature in this file is sourced from a public registry, a published standard,
or independent third-party research, **not** from the colonelpanichacks/oui-spy code.
Rebuild the firmware's detection tables from here and write your own parser.

## Why this is clean

Facts are not copyrightable: MAC OUIs, Bluetooth company IDs, service UUIDs, SSID
patterns, and published standards are public facts. Each entry below cites where it
comes from. The only thing you cannot reuse is upstream *code and curation*, so source
the facts here and implement your own matching.

## Public registries (the backbone)

| Registry | What it gives you | URL |
|---|---|---|
| IEEE OUI registry | MAC OUI to manufacturer (free TXT/CSV) | https://regauth.standards.ieee.org/ |
| Bluetooth SIG Assigned Numbers | company IDs + 16-bit service UUIDs | https://www.bluetooth.com/specifications/assigned-numbers/ |

Bulk-OUI mirrors: macaddress.io, maclookup.app, github.com/Ringmast4r/OUI-Master-Database.

---

## Flock Safety (ALPR camera)

| Signature | Match on | Value | Public source |
|---|---|---|---|
| WiFi SSID | prefix | `Flock-` + partial MAC | ryanohoro, GainSec |
| WiFi SSID | suffix | `-FALCON` (e.g. `PROBE-FALCON`, `DATA-FALCON`; self-attested SSID conf 85, probe-borne conf 72) | own field capture (2026-07-24) |
| BLE name | prefix + digits-only tail | `Penguin-` + digits (research form: 10 digits) | ryanohoro |
| BLE name | substring (literal) | `FS Ext Battery` | ryanohoro |
| BLE name | prefix + hex-only tail | `FS-` + hex (e.g. `FS-BEC46A`) | own field capture (2026-06) |
| BLE name | prefix, loose | `Flock` | brand string, public |
| BLE mfg data | company ID | `0x09C8` (Flock's BT module; ryanohoro attributes to XUNTONG; shared silicon, conf 45 = weak-match band) | ryanohoro |
| MAC OUI | exact | `B4:1E:52` (Flock Safety, MA-L, reg. 2024-05-09) | IEEE / maclookup.app |
| WiFi probe-req | OUI, probe-req only | Liteon `24:B2:B9` `F4:6A:DD` `D8:F3:BC` `C0:35:32` (validated at a live Falcon) | own field capture (2026-06, 2026-07-24) |

BLE names are matched ANCHORED, not substring-anywhere (except the specific
`FS Ext Battery` literal): `FS-` is a generic white-label model prefix and bare
`penguin`/`flock` substrings match phones and novelty gadgets. Only the
`FS Ext Battery` literal ranks strong (80) on its own. The prefix forms rank 80 only
when a co-signal backs them - a public (non-random) BLE address (real Flock beacons
do not rotate) or the `0x09C8` mfg id - and stay hint-grade (70) otherwise, so a
consumer gadget named `FS-100` on a rotating address never draws a strong ALPR
verdict. The bare 10-decimal-digit name ryanohoro documents as the post-Mar-2025
pattern is deliberately NOT matched: it false-positived in the field on a phone
advertising the placeholder name `0102000000` (removed 2026-06-18). Re-add it only
behind a public (non-random) BLE-address gate.

**Detection-quality notes (read before you copy the old tables):**
- The WiFi/BT chip is a LiteOn WCBN3510A. Lite-On's OUIs are shared across millions of
  consumer devices, so matching them on *any* frame is a false-positive magnet, and the old
  ~67-OUI "superset" (ported curation + the source of the field false positives) stays dropped.
  `B4:1E:52` (Flock's own block) is the only OUI defensibly Flock-specific on its own.
- **Probe-request exception (Falcon as WiFi client):** Falcon cams join a network as WiFi
  clients (no `Flock-` AP of their own) and emit probe requests from a Liteon module. Four
  Liteon OUIs field-validated AT a live Falcon (`24:B2:B9`, `F4:6A:DD`, `D8:F3:BC`, `C0:35:32`,
  all caught over probe requests) ship (`ext=0`). They are matched on PROBE REQUESTS ONLY, but note the honest limit of
  that gate: it distinguishes APs from clients, not cameras from laptops - probe requests are
  exactly what a powered-on, not-yet-associated laptop emits, and Windows ships MAC
  randomization off, so consumer Liteon NICs (Dell/HP/Acer) probe with their real OUI. That is
  why it ships as a medium-confidence signal (conf 72), not proof. `D8:F3:BC` and `C0:35:32`
  were 2026-06 near-Falcon-only candidates (held out as a bystander-laptop risk), then PROMOTED
  2026-07-24 after our own drive recaptured both broadcasting `PROBE-FALCON` / `DATA-FALCON`
  SSIDs (a Flock-specific name no bystander laptop emits), which pins the OUI to a Falcon; the
  `ext=1` non-shipping candidate tier is now empty. Earlier unconfirmed candidates lifted from community
  OUI lists (a set that tracked an upstream's curated selection) were removed for clean-room
  provenance, since a curated third-party OUI list is not ours to distribute and those entries
  were off by default and detected nothing anyway. Deliberately NOT matching `08:3A:88` (USI;
  our Molekule air-purifier FP) or its SiLabs "FS Ext Battery" OUI blocks, which the BLE name
  match already covers.
- **Watchlist (diag only):** the BLE name `Pigvision` is a candidate Flock signature carried ONLY in
  the `ACAB_DIAG` build (it logs `*** PIGVISION CANDIDATE ***`), never in production. A confirmed
  field sighting is the trigger to promote it into `FLOCK_NAME_PATTERNS`.
- The bare 10-digit BLE name is inherently ambiguous (any device with a 10-digit name
  matches, including phones) and is NOT in the shipped tables. If it is ever re-added, gate
  it on a public (non-random) BLE address - the gate the code itself prescribes - not on
  RSSI, which says nothing about what the device is.

## Flock Raven (audio sensor)

| Signature | Match on | Value | Source |
|---|---|---|---|
| BLE service UUID | 16-bit short on the Bluetooth base UUID, advertised in 128-bit form (parsed from 0x06 / 0x07 AD structures) | `0x3100` (GPS) `0x3200` (power) `0x3300` (network) `0x3400` (upload) `0x3500` (error) | own field capture |
| BLE service UUID | standard Bluetooth SIG profile shorts, weak backup only (never a match on their own) | `0x180A` (Device Information) `0x1809` (Health Thermometer, older fw) `0x1819` (Location and Navigation, older fw) | Bluetooth SIG |

Raven advertises its service UUIDs in 128-bit form on the Bluetooth base UUID
(`0000xxxx-0000-1000-8000-00805f9b34fb`); the parser pulls the 16-bit short back out.
Only the `0x31xx`-`0x35xx` shorts trigger a Raven detection; they are Raven-specific and
come from our own field capture (not a registry), so they are our own data, fully clean.
The `0x18xx` rows are public SIG profiles shared with thousands of devices: `0x1819`
feeds only the firmware-generation estimate on an already-matched Raven, and
`0x180A`/`0x1809` are recorded for reference but drive nothing today.

## Other ALPR brands: mostly NOT passively detectable

Most ALPR vendors backhaul over cellular (or wired) with no BLE/WiFi beacon, so a
2.4 GHz sniffer cannot see them - the same gap as the Ubicquia units we hit in the
field. Flock is the outlier: it beacons over BLE/WiFi for health and setup.

| Brand | Backhaul | Passively detectable on 2.4 GHz? |
|---|---|---|
| Flock Safety | cellular + BLE/WiFi beacons | yes (signatures above) |
| Motorola / Vigilant (L5Q) | cellular | no |
| Leonardo / ELSAG | cellular / wired | no |
| Genetec AutoVu | wired / WiFi / cellular | site-dependent, usually no |
| Neology, Jenoptik, Perceptics, Rekor, Ubicquia, Conduent | cellular / wired | no |

For the cellular ones the detection path is the DeFlock map + optical (IR-illuminator
spotting), not RF. src: DHS ALPR Market Survey (2025); EFF Street-Level Surveillance.

**Motorola Solutions OUIs** are IEEE-confirmed, but they are the company's whole corporate
blocks: they cover any Motorola Solutions WiFi/BLE device (two-way radios, in-car routers,
body-cam docks, APs, infrastructure), NOT just ALPR, and NOT their LMR police radios
(those are 700/800 MHz, off this board's 2.4 GHz band). Their dominant 2.4 GHz product
in the wild is the MOTOTRBO-class two-way radio carried by retail, school, and venue
staff, so a hit usually is NOT a camera of any kind. As shipped, the match reports under
the body-cam type (the apps have no separate Motorola category), with the detail string
naming the honest source ("Motorola Solutions OUI") and confidence held at 45, below the
apps' weak-match threshold (50), so every hit renders as amber "weak match, verify"
rather than a calm partial match. Do not raise it above 50 and do not label it "ALPR
camera": either is a false-certainty bug, not a tuning choice.

### Considered and REJECTED: Sierra Wireless AirLink and Cradlepoint vehicle routers (2026-08-02)

Proposed as rows in `police_signatures.h`, on the reasoning that both vendors dominate US cruiser
connectivity and run WiFi APs from marked vehicles. The OUIs are real and the registrants narrow,
IEEE-confirmed against a fresh `standards-oui.ieee.org` pull:
`Sierra Wireless, ULC` = `50:13:9D 84:DB:2F 64:CE:6E CC:93:4A 00:A0:D5 28:A3:31`;
`CradlePoint, Inc` = `00:30:44 00:E0:1C`. **Rejected anyway**, for three independent reasons:

1. **The table cannot say who it matched.** `POLICE_OUI[][3]` has no per-row vendor field, and
   `police_detect.cpp` hard-codes `"Motorola Solutions OUI"` into the detail string. Appending
   these blocks would report a Sierra AirLink on a transit bus **as a Motorola body cam** , a lie
   about the vendor on every hit. That is why this is not an "add the rows at low confidence"
   situation: the confidence would be honest and the vendor name would not.
2. **Our own field data says what a bare vendor-OUI row of this shape measures.** Of the 30
   body-cam rows in our capture, all **27** Motorola WiFi OUI hits were confirmed NOT body cams.
   These two vendors are broader still: their own marketing leads with transit, EMS, retail SD-WAN,
   utilities and school buses. The installs most likely to have an AP on and beaconing loudly are a
   bus running open passenger WiFi and a storefront failover router, i.e. the opposite of the
   target, and no payload byte, capability bit or IE separates a patrol install from a bus install.
3. **The crux is unresolved and may be fatal on its own.** Nothing published ties either vendor's
   OUI to the BSSID the radio actually transmits. Cradlepoint's own documentation says only that
   "BSSIDs are derived from the hardware MAC address of the broadcasting radio", which is a
   mechanism, not a prefix. The MG90 hardware guide describes the WiFi radios as modules, so the
   BSSID may carry the module maker's block instead , in which case the rows are dead on arrival
   and the tempting "fix" is to add the module block, which is exactly the shared-silicon trap this
   document and `netcam_signatures.h` both already forbid.

Re-proposing these needs a captured BSSID from a marked vehicle, and a per-row vendor field in
`POLICE_OUI` before any hit could be labelled honestly.

**Coverage went from 1 block to 7 (2026-07-19).** The table shipped only `4C:CC:34`, which
left six sibling blocks of the same vendor's gear invisible. This is now the COMPLETE set
registered to the Motorola Solutions entities, cross-checked against the IEEE registry via
the OUI-Master-Database merge (IEEE + Wireshark + Nmap).

| OUI | Registrant | Note | Source |
|---|---|---|---|
| `4C:CC:34` | Motorola Solutions, Inc. | reg. 2012-12-30; **field-observed** | IEEE / maclookup.app |
| `00:04:7D` | Motorola Solutions, Inc. | | IEEE / maclookup.app |
| `00:18:85` | Motorola Solutions, Inc. | | IEEE / maclookup.app |
| `00:1F:92` | Motorola Solutions, Inc. | | IEEE / maclookup.app |
| `10:74:6F` | Motorola Solutions Malaysia Sdn. Bhd. | same corporate group | IEEE / maclookup.app |
| `B8:E2:8C` | Motorola Solutions Malaysia Sdn. Bhd. | same corporate group | IEEE / maclookup.app |
| `9C:86:2B` | Motorola Solutions Malaysia Sdn. Bhd. | same corporate group | IEEE / maclookup.app |

The Malaysia registrant is Motorola Solutions' own manufacturing entity, the same corporate
group as the Holtsville blocks, so it is in scope. Motorola **MOBILITY** (the Lenovo-owned
consumer-phone business, 122 separate blocks) stays OUT: it is an unrelated company selling
handsets, and matching it would flag every Moto phone on the street.

**Why seven blocks is NOT the shared-silicon trap that forced the Flock Liteon reduction.**
The Liteon problem was vendor MISattribution: a Liteon OUI is commodity module silicon
sitting in millions of laptops and consumer gadgets, so the match could not even establish
that you were looking at Flock's supplier's part in a Flock product. These are Motorola
Solutions' OWN MA-L registrations, so a match attributes the device vendor CORRECTLY, and
widening from one block to all seven does not dilute that: every added block belongs to the
same company. The uncertainty here is a different thing, what the device IS (radio vs dock
vs camera vs infrastructure), and confidence 45 plus the apps' amber weak-match treatment
already communicate exactly that. Adding sibling blocks of a correctly attributed vendor is
therefore a coverage fix, not a precision regression.

`4C:CC:34` is field-observed on 2.4 GHz WiFi (own capture 2026-07-18, 3 distinct MACs at one
site), which is what establishes this vendor as detectable on this board at all; the six
siblings are the same product lines from the same registrant.
src: IEEE OUI registry -> https://maclookup.app/macaddress/4CCC34

> **Own toggle, opt-in on every board.** The Motorola OUI match
> is a SUB-TOGGLE of the body-cam category (`{"motorola":bool}` on the wire, `moto` in
> status, NVS-persisted). Classification needs BOTH switches: body cams on AND motorola on.
> Turning the category off silences every body-cam signature including this one; turning
> only `motorola` off leaves the conf-90 Axon `BWCDEVICE` tag and Utility BodyWorn running.
> Desert mode overrides both, as it does for every detector. It exists because the two used
> to share one switch, so quieting this broad match cost the user the best signature on the
> board. Since the 2026-07-23 airport ground truth (all 27 Motorola WiFi OUI hits confirmed
> NOT body cams), the sub-toggle boots **off** on every build. oui-spy, beacon-board, and
> mesh-detect all restore it OFF by default (`policeRestoreEnabled(false)`), so no board flags
> Motorola Solutions gear out of the box until the user opts in. Only an `on` persisted in NVS
> from before that change survives a reflash. Wire details in [docs/ble-protocol.md](ble-protocol.md).

### Considered and REJECTED: LiveView Technologies (LVT) mobile surveillance trailers (2026-08-03)

The solar-and-camera trailers parked in retail lots. Proposed as a detection target because they
are large, obvious, unmistakably surveillance, and sitting where people actually are.

**Rejected on our own field measurement: they emit nothing this hardware can hear.**

The raw capture was 50 minutes / 105,932 lines from `firmware/tools/capture-log.py`, on a
`-DACAB_DIAG -DACAB_DIAG_WIFI` build with Desert mode on. That file is gitignored (`*.log`, 9 MB),
so the evidence is committed distilled instead:
[`docs/captures/lvt-2026-08-03-summary.txt`](captures/lvt-2026-08-03-summary.txt) , every typed
marker, every classifier detection, and every raw sighting inside the three LVT approach windows.
Two different LVT units were approached, one at 15 ft and both at 2 m. Nothing on either trailer produced a BLE advert or a
WiFi frame at any range.

**Why this is a measurement and not an absence of effort.** The same board, on the same drive, in
the same lots, caught every other target within seconds of the marker being typed:

| marker | detection | delta |
|---|---|---|
| `2 flock` 90.8s | ALPR camera, Falcon probe, -70 dBm | -1 s |
| `flock` 1621.1s | ALPR camera, Falcon probe | -10 s |
| `flock` 1701.7s | ALPR camera, Falcon probe | -6 s |
| `bodycam` 2587.9s | Body camera, BLE `BWC DEVICE` conf 90, **and** WiFi Axon OUI | -14 s |
| **`LVT#1 2m` 151.2s** | **nothing** | |
| **`LVT#2 15ft` 299.9s** | **nothing** | |
| **`LVT#2 2m` 341.5s** | **nothing** | |

(Detections precede their markers because the operator typed the note after seeing the alert.)

**The distance calibration, from the same capture, is what makes the negative solid.** RSSI on this
hardware, measured against known distances that day:

```
the board's own beacon          ~0 m    -17 dBm
operator's phone / car gear    ~1-2 m   -30 to -40 dBm
POS terminals inside a store    50+ ft  -65 to -92 dBm   (distance eyeballed on site)
loudest thing beside an LVT       2 m   -30 dBm ... and it was the operator's own gear
```

A transmitter at 2 m reads like the phone did. Nothing at either trailer came close. The four
strongest devices next to the trailers were the same four that followed the operator between both
stops and disappeared 300 s after he left , his own car and pocket.

**One near-miss worth recording so nobody re-chases it.** Thirteen BLE devices with a shared OUI
`CC:4D:74` / `38:3C:9C` and a structured name pattern `51idx0018xxxxxxx` appeared at both LVT stops
and nowhere else in the capture. That is exactly the shape of a vendor signature, and it is not
one: `CC:4D:74` is **Fujian Newland Payment Technology**, i.e. checkout card readers inside the
store, ~50 ft away and reading -65 to -92 dBm accordingly. Structured pattern, mundane cause. Look
the OUI up before believing a cluster.

**Consistent with the vendor material**, which describes cellular uplink with satellite backup and
never mentions WiFi, Bluetooth, or a local hotspot. This is the recording-is-not-transmitting case
from the top of this file, now measured rather than inferred.

**The one gap left.** We sweep 2.4 GHz channels 1-13 only (`WIFI_HOP_SEQ`). A 5 GHz-only service AP
inside the enclosure would be invisible to us regardless. Settling that needs either a phone WiFi
analyser alongside the board, or the FCC ID off the unit's plate, which names every radio in it.
Neither changes the practical answer: **there is nothing here to add a row for.**

### Considered and REJECTED: consumer cellular GPS vehicle trackers (2026-08-05, registry pass)

The under-the-wheel-well class: LandAirSea, Tracki, Spytec, Optimus, Vyncs, Bouncie, and the
OBD-plug trackers. Proposed as the most important gap in the product, and that framing is right:
these are the devices in actual stalking prosecutions, and they are what someone searching their
own car is looking for. The BLE-tracker detector covers all four network ecosystems (Apple, Google
FMDN, Tile, Samsung) and none of them.

**Not rejected as a target. Rejected as an OUI signature, on the registry.** Pulled the
88k-vendor master OUI list (see the Public registries section) and looked up all six brands:

| brand | IEEE registration |
|---|---|
| LandAirSea | none |
| Spytec | none |
| Optimus | none |
| Vyncs | none |
| Bouncie | none |
| Tracki | none (the three name-matches are Katch Asset Tracking, Broadband Antenna Tracking Systems and Advanced Realtime Tracking GmbH, all unrelated companies) |

Not one of them holds a block. So any BLE these devices do emit for their setup app carries the
**module vendor's** OUI (a Nordic, TI or SIMCom part), which is the shared-prefix trap that already
killed OUI matching for Flock's Liteon modules and for Quercus/ELSAG/Selex on `70:B3:D5`. A 3-byte
match there is a false-positive bomb, not a signature.

**What that leaves, and what a field session should therefore look for.** If these are ever to be
detected it has to be an advertised **local name** or a **service UUID** captured off a real
device, not a MAC prefix. That is a weaker and more FP-prone class of signature than this project
normally accepts (see the Flock name-pattern rules and the `FS-100` consumer-gadget collision), so
the bar for admitting one should be high. The honest experiment is still worth running, roughly
$100 of hardware and a bench day next to the nRF sniffer, but it should be scoped as **"harvest a
name or a UUID, or write the not-detectable finding"**, and nobody should expect an OUI out of it.

Until that capture happens, the honest public line is that cellular GPS trackers are **not
detectable** by this hardware, for the same reason as the cellular-backhaul ALPRs above: their
uplink is LTE, and LTE is not a band this device listens to.

## Network cameras

### ADMITTED 2026-08-05: Arlo, and the base-station SSID rule

The first netcam vendor admitted on **our own field capture** rather than on a registry pull.

- **3 blocks, `A4:11:62` / `FC:9C:98` / `48:62:64`, registrant "Arlo Technology".** Narrower than
  Wyze: nothing with a radio in their catalogue but cameras, doorbells and the hubs that serve
  them. Arlo had been named in `netcam_signatures.h`'s "why not" line with no reason given while
  Nest and Blink each got one, i.e. swept in by association. That was wrong and is corrected.
- **The evidence.** The 2026-07-24 A/B drive logged **12 distinct Arlo devices** across the route,
  all three blocks firing, and three of them broadcast an `ARLO_VMB_<digits>` SSID naming
  themselves. Until now every one of those fell through to a bare "Nearby device", confidence 0.
- **`ARLO_VMB_` SSID prefix, confidence 88, same tier as the Flock SSID.** An SSID is a vendor
  self-attestation, so it beats an OUI on both halves: it names the vendor *and* says what the box
  is. It also reaches what the OUI cannot. The hub is mains-powered and beacons constantly while
  the battery cameras sleep, which is why 11 of the 12 drive hits were single sightings; and
  pre-2018 Arlo broadcasts the same SSID form while its MAC sits in NETGEAR's 76 unusable blocks.
  `NTGR_VMB_` is listed for that legacy case but has never been captured by us, so it is a
  potential miss, never a false positive.
- **The label is "Arlo base station", not "camera".** A hub serves cameras and has no other
  purpose, but the SSID does not prove a lens is pointed at anyone.
- **Stated misses**, so nobody reads this as complete: 5GHz-only installs (Ultra on a VMB5000 hub,
  dual-band Pro 5S/6), the LTE-only Arlo Go 1st gen, and all pre-spinoff hardware by OUI. The
  discontinued Arlo Security Light talks BLE to a bridge, so this match stays **WiFi-only** or a
  porch light gets labelled a camera.

### Registry-checked, NOT yet admitted: SimpliSafe and Vivint outdoor cameras (2026-08-05)

Both proposed as netcam rows on the Lorex/Swann pattern. Registry pull, for the record, so the next
person starts from data rather than from the proposal:

- **SimpliSafe: 1 block, `F8:51:28`, registrant "SimpliSafe".** Passes the narrow-registrant test
  as cleanly as Lorex did. A camera-centric company with a single block is exactly the shape the
  netcam table admits.
- **Vivint: 4 blocks, and they are NOT all one product line.** `84:EB:3E` (Vivint Smart Home) and
  `84:EB:3F` (Vivint Inc) are plausibly the smart-home/camera side. `A0:FE:61` and `5C:2B:F5` are
  **Vivint Wireless Inc**, which was the fixed-wireless ISP business, i.e. home internet CPE rather
  than cameras. Admitting those two would flag a router as a camera, which is the TP-Link rejection
  in miniature.

Neither is added. Registered OUI is not detectability, and this table's rule is field validation
before confidence: nothing goes in on a registry lookup alone. For comparison, the rejected TP-Link
registrant holds **263** blocks, every one tagged Router.

If either is pursued, SimpliSafe is the clean one and needs a single capture of a real unit
broadcasting. For Vivint, take `84:EB:3E`/`84:EB:3F` only, and only after a capture proves which
line actually transmits.

## Drone (Remote ID primary, vendor-OUI fallback)

Vendor in **opendroneid-core-c (Apache-2.0)** and call its decoder. It is ASTM F3411
compliant and covers BLE legacy/extended plus WiFi NAN/beacon Remote ID.
- Library: https://github.com/opendroneid/opendroneid-core-c  (Apache-2.0, commercial-OK with attribution)
- Spec: https://github.com/opendroneid/specs  (standard: ASTM F3411)
- nRF52 reference for Chip B: https://github.com/sxjack/remote_id_bt5  (check its license first)

**Vendor-OUI fallback (secondary, lower confidence).** Remote ID is the primary path; a
craft that doesn't broadcast RID (older units, RID disabled, non-US firmware) can still be
flagged by its MAC OUI. These are each vendor's OWN corporate IEEE blocks, not commodity
module silicon, so they pass the no-shared-silicon rule. Matched only when the RID decode
finds nothing, at low confidence (60), on either radio, and the detail string names the
vendor. These makers randomise their MAC in some Wi-Fi modes, so treat an OUI hit as
"vendor gear nearby", not a guaranteed airborne drone. `90:3A:E6` is also the OUI the
OpenDroneID Wi-Fi beacon vendor IE rides, but that is an information-element match decoded
as RID first, not a transmitter-MAC match, so it does not double-count.

Deliberately NOT matched: Beijing Autelan (`4C:48:DA` / `00:1F:64`, a WLAN vendor, not
Autel Robotics the drone maker). The WatchGuard exclusion is a body-cam question, not a
drone one, so it lives in the body-cam section below.

| Vendor | Match on | Value | Source |
|---|---|---|---|
| DJI | MAC OUI (BLE, or WiFi addr2), no RID decoded | `60:60:1F` `34:D2:62` `48:1C:B9` `E4:7A:2C` `58:B8:58` `04:A8:5A` `8C:58:23` `0C:9A:E6` `88:29:85` `4C:43:F6` plus DJI Baiwang `9C:5A:8A` `EC:72:F7` `34:91:F0` | IEEE (SZ DJI Technology and wholly owned UAV manufacturer DJI Baiwang Technology) |
| Parrot | MAC OUI, no RID decoded | `00:12:1C` `00:26:7E` `90:03:B7` `90:3A:E6` `A0:14:3D` | IEEE (Parrot SA) |
| Skydio | MAC OUI, no RID decoded | `38:1D:14` | IEEE (Skydio Inc) |
| Autel | MAC OUI, no RID decoded | MA-M `EC:5B:CD:E` | IEEE (Autel Robotics USA LLC) |
| Yuneec | MAC OUI, no RID decoded | MA-M `E0:B6:F5:8` | IEEE (Yuneec) |
| Freefly | MAC OUI, no RID decoded | `EC:71:5E` | IEEE (Freefly Systems Inc) |
| Teal | MAC OUI, no RID decoded | `B0:30:C8` | IEEE (Teal Drones, Inc.) |
| AeroVironment | MAC OUI, no RID decoded | `00:1A:F9` and MA-S `8C:1F:64:B0:7` | IEEE (AeroVironment) |
| Inspired Flight | MAC OUI, no RID decoded | MA-M `34:B5:F3:2` | IEEE (Inspired Flight) |
| Quantum Systems | MAC OUI, no RID decoded | MA-M `AC:86:D1:7` | IEEE (Quantum-Systems GmbH) |
| ideaForge | MAC OUI, no RID decoded | MA-S `8C:1F:64:0F:1` | IEEE (ideaForge Technology Limited) |
| ACSL | MAC OUI, no RID decoded | MA-S `8C:1F:64:A2:D` | IEEE (ACSL Ltd.) |
| Zipline | MAC OUI, no RID decoded | `74:B8:0F` | IEEE (Zipline International Inc.) |
| Cyon Drones | MAC OUI, no RID decoded | MA-M `24:A1:0D:7` | IEEE (Cyon Drones) |
| UAV Navigation | MAC OUI, no RID decoded | MA-M `B4:4D:43:A` | IEEE (UAV Navigation) |
| Shield AI | MAC OUI, no RID decoded | `14:DD:48` | IEEE (Shield AI) |
| Anduril | MAC OUI, no RID decoded | MA-M `E8:B4:70:C` | IEEE (Anduril Industries) |

Every block above is the vendor's OWN corporate IEEE registration, not commodity module
silicon, so each passes the no-shared-silicon rule that forced the Falcon Wi-Fi OUI list down
to two entries. Parrot ANAFI and Skydio in particular are the most-deployed US public-safety
craft, which is why they earn a fallback despite the low confidence.

`18:D7:93:6` is deliberately excluded. IEEE assigns it to Autel Intelligent Technology,
whose radio-bearing products include automotive diagnostic equipment, not specifically to
Autel Robotics. It should not return without an aircraft capture that proves the block is used
by an EVO or another Autel aircraft.

## Body cams (Axon, Utility)

| Signature | Match on | Value | Public source |
|---|---|---|---|
| MAC OUI | exact | `00:25:DF` (Axon Enterprise, ex-TASER; sole IEEE block) | IEEE / maclookup.app |
| BLE payload | service bytes contain (no space!) | `BWCDEVICE` (Axon) | own field capture, 2026-06; **field-validated 2026-07-19** |
| BLE name | contains | `BodyWorn Remote` (Utility Inc. BodyWorn) | nite-oui-collection capture, 2025-08 |
| MAC OUI | exact | `00:09:BC` / `00:16:ED` (Utility Inc.; weak fallback) | IEEE / nite-oui-collection |

The Axon payload needle is `BWCDEVICE` with NO space: the on-wire capture is the
little-endian-reversed `AXJANUSBWCDEVICE`, and the matcher (`axon_signatures.h` via
`ascii_match.h`) searches the raw service bytes in both byte orders. `BWC DEVICE` with a
space exists only as the app-facing display string (`axon_detect.cpp`); a table rebuilt
with the spaced form would silently never match a real Axon cam - do not reintroduce it.
FCC teardowns: Axon FCC IDs under `X4G...` (e.g. X4GS01200, Body 3) on fccid.io. OUI alone
cannot separate a body cam from other Axon gear; the `BWCDEVICE` payload narrows it.

**The `BWCDEVICE` tag is FIELD-VALIDATED against a visually confirmed scene** (2026-07-19):
two units fired at confidence 90 from roughly 20 feet, rssi -89 and -85, with the cameras
confirmed by eye at the same location. That moves the tag from "captured once, matched in a
lab sense" to a signature with a real ground truth behind it, and it is why the tag is the
highest-confidence signature on the board. It is also MAC-independent (it lives in the
service data, not the address), so it survives BLE MAC randomization where an OUI match does
not. Two consequences for anything downstream: do not let a category or sub-toggle change
silence it as a side effect (the reason the broad Motorola OUI proxy was split onto its own
sub-toggle, see the Motorola section above), and do not lower its confidence below the
OUI-only tier at 75.

**Utility Inc. "BodyWorn"** is a separate body-worn camera brand (an Axon competitor). Its
activation remote advertises a Complete Local Name containing `BodyWorn Remote` on Utility's
public OUI `00:09:BC` - the NAME is the strong MAC-independent signal, the OUI a weak fallback.
A vendor UUID `0cf1640c-1c36-4c68-b411-08f344e1d6d1` exists but only post-connect, so it is not
passively usable. Rides the same body-cam detector + toggle as Axon, and is unaffected by the
Motorola sub-toggle. Third-party field-observed (not own-captured yet).
src: https://github.com/nitekry/nite-oui-collection

Both Utility OUIs (`00:09:BC`, `00:16:ED`) now live in `axon_signatures.h` as
`UTIL_BWC_OUI[]`; they were previously inline literals in `axon_detect.cpp`. No behaviour
change, this keeps every OUI in a signatures header next to its citation, the same
clean-room provenance discipline `flock_signatures.h` and `police_signatures.h` follow.

**Body-cam decoy deliberately NOT matched.** `00:01:21` and `00:90:7F` are **WatchGuard
Technologies** (a network-firewall vendor), a different company from WatchGuard Video (the
in-car / body camera brand now folded into Motorola Solutions), so they are not body-cam
signals and stay off the table.

## BLE trackers

| Tracker | Match on | Value | Public source |
|---|---|---|---|
| Apple AirTag / Find My | mfg company ID + type | `0x004C` + payload type `0x12` | Bluetooth SIG + arXiv 2501.17452 |
| Samsung SmartTag | service UUID | `0xFD5A` | arXiv 2501.17452 + Bluetooth SIG |
| Tile | service UUID | `0xFEED` | Bluetooth SIG |
| Google Find Hub / FMDN (separated) | service data UUID + frame type | `0xFEAA` + frame type `0x41` **only** | Google Find Hub Network Accessory Spec, tables 15/16 |

**Find Hub covers the whole Android ecosystem, not one brand.** The `0xFEAA` + `0x41` match is
network-wide, so Moto Tag, Chipolo Point and the compatible Pebblebee tags are already detected
with no per-manufacturer signature. Do not add brand rows for them. The same holds on the Apple
side: third-party Find My accessories ride the existing Find My offline frame above.

**Frame type `0x40` is deliberately NOT matched.** `0x41` is the *separated* state, a tag away
from its owner, which is the only state that means anything for following. `0x40` is the
near-owner state and would fire on every pair of earbuds sitting beside their owner. Same rule,
and the same reason, as the Apple `0x12` payload type above. The implementation and the
accepted-miss note are in `firmware/lib/acab_core/tracker_detect.cpp`.

## Smart / recording glasses

Its own category (`t=9`, not trackers, not body cam). Match on the BLE
manufacturer-specific data (AD type `0xFF`) company ID, first two payload bytes,
little-endian. Keying on the payload company ID survives the MAC randomization these
devices do. A 2026-07-31 field capture confirmed advertise-while-worn (three worn Meta
glasses fired `0x01AB`); the Quest discriminator token's byte framing is still
capture-pending, so most rows stay at "possible recording glasses." Full write-up in
[docs/glasses.md](glasses.md).

| Product | Match on | Value | Registrant | Eyewear-only? | Shipped? | Public source |
|---|---|---|---|---|---|---|
| Ray-Ban Meta frames | mfg company ID | `0x0D53` (conf 70) | Luxottica Group S.p.A | yes | on by default | Bluetooth SIG |
| Snap Spectacles | mfg company ID | `0x03C2` (conf 70) | Snapchat Inc | yes (Snap's only BLE hardware) | on by default | Bluetooth SIG |
| Vuzix camera AR glasses (Blade/M400/Shield/Z100) | mfg company ID | `0x060C` (conf 70) | Vuzix Corporation | yes (AR-eyewear-only maker) | on by default | Bluetooth SIG |
| Ray-Ban / Oakley Meta glasses | mfg company ID | `0x058E` (conf 49 if ever enabled) | Meta Platforms Technologies, LLC | **no**, shared with Meta Quest VR | **gated OFF** (token-confirmed hits only) | Bluetooth SIG |
| Meta hardware (corporate ID) | mfg company ID | `0x01AB` (conf 45) | Meta Platforms, Inc. | **no**, corporate/parent ID | **on** (weak match, un-gated 2026-07-31) | Bluetooth SIG |
| RayNeo AR/smart glasses | mfg company ID | `0x0BC6` (conf 45 if ever enabled) | TCL COMMUNICATION EQUIPMENT CO.,LTD. | **no**, TCL phones/tablets/TVs | **gated OFF** (no token to rescue it) | Bluetooth SIG |
| RayNeo (no dedicated ID) | - | none | no SIG entry for "RayNeo" | n/a | n/a | Bluetooth SIG (absence) |

**Notes:**
- **Meta Quest false positive (why the shared IDs are gated off).** `0x058E` (Meta
  Platforms Technologies) is shared across Meta's hardware line including the Quest VR
  headset, and `0x0BC6` covers TCL's phones/tablets/TVs, so a match on either alone
  cannot prove glasses. Worse, a Quest advertises from a rotating private BLE
  address, so a bare shared-ID match re-alerts on every rotation and an exact-MAC Ignore
  can never silence it: a Quest in the living room would beep forever. The shipped
  firmware therefore gates the bare match on `0x058E`, `0x0BC6`, and the Jieli audio-SoC
  ID `0x05D6` (`sharedId` gate in `glasses_signatures.h` / `glasses_detect.cpp`,
  compile-time, no user toggle); a `0x058E` advert still emits when the `META_RB_GLASS`
  token confirms glasses. Their table confidences are held below 50 so that even a build
  that re-enables them lands in the apps' weak-match "verify this" band. The corporate
  parent ID `0x01AB` (Meta Platforms, Inc.) was UN-GATED 2026-07-31 on a field capture:
  three worn Ray-Ban/Oakley Meta glasses fired `0x01AB` cleanly while Luxottica `0x0D53`
  fired ZERO times, so a bare `0x01AB` now emits a conf-45 weak match (Quest caveat kept,
  since it is still a corporate ID). That capture also disproved the old fallback: Ray-Ban
  Meta coverage rides the un-gated `0x01AB`, not `0x0D53`, which never fired against real
  worn frames. Luxottica `0x0D53`, Snapchat `0x03C2`, and Vuzix `0x060C` are
  eyewear-only registrants: on by default, higher confidence, no payload discriminator
  needed.
- **Vuzix `0x060C`.** Vuzix Corporation is an eyewear-only AR maker whose whole line is
  camera-equipped smart glasses (Blade, M400, Shield, Z100). Same `0xFF` manufacturer-data
  company-ID mechanism as the Luxottica and Snap entries, so it survives MAC randomization,
  and it carries the same eyewear-only confidence (70 - deliberately below the
  field-validated Axon OUI at 75, because it is still capture-pending) with no Quest-style
  shared-hardware caveat.
- **Meta Quest discriminator (capture-pending).** The documented way to separate the
  Ray-Ban/Oakley Meta glasses from a Quest under `0x058E` is the manufacturer-data payload,
  not a service UUID: the glasses' payload is reported to carry the ASCII token
  `META_RB_GLASS`. The shipped matcher searches the manufacturer data for it in both byte
  orders (`acabBytesContainAscii`) and, on a hit, emits a confirmed-glasses detection at
  conf 72 (below the field-validated Axon tier at 75, because the token framing is still
  capture-pending); the report stays under the `M_MFG_ID` method. With `0x058E` still gated,
  the token is the only way that Quest-shared ID produces a detection; the parent ID `0x01AB`
  was un-gated 2026-07-31 and now weak-matches on its own (see above). No
  distinguishing 16-bit service UUID has been documented.
- **Name is pairing-only.** A device name identifies the glasses but is generally exposed
  only during pairing, so it is rarely visible against a covert user who paired in advance.
  Continuous field detection relies on the company ID (plus the Meta subtype), not the name.
- `0x03C2`'s authoritative registry string is **"Snapchat Inc"** (not "Snap Inc" as sometimes
  reported).
- **Glasses decoys deliberately NOT matched.** `0x0820` is **Brilliant Home Technology** (a
  smart-home hub vendor), a different company from the Brilliant Labs AR-glasses startup, so it
  is not a glasses signal. `0x00A3` is **Meta Watch Ltd**, a defunct smartwatch company
  unrelated to today's Meta Platforms, so it is not a Ray-Ban/Oakley Meta glasses signal.

---

## Sources

- IEEE OUI registry: https://regauth.standards.ieee.org/
- Bluetooth SIG Assigned Numbers: https://www.bluetooth.com/specifications/assigned-numbers/
- Flock teardown (CEHRP): https://www.cehrp.org/dissection-of-flock-safety-camera/
- Flock RF signatures (ryanohoro): https://www.ryanohoro.com/post/spotting-flock-safety-s-falcon-cameras
- Flock WiFi research (GainSec): https://gainsec.com/2025/09/27/button-presses-to-shell-on-flock-safety-license-plate-cameras-over-wi-fi/
- ALPR Watch wiki: https://wiki.alprwatch.org/index.php/Flock_Safety
- DeFlock map (locations, OSM/ODbL open data): https://deflock.me
- OUI 00:25:DF (Axon Enterprise): https://maclookup.app/macaddress/0025DF
- OUI B4:1E:52 (Flock Safety): https://maclookup.app/macaddress/b41e52
- Motorola Solutions OUI blocks (Motorola Solutions, Inc. + Motorola Solutions Malaysia Sdn. Bhd.): https://maclookup.app/vendors/motorola-solutions-inc
- OUI 00:09:BC / 00:16:ED (Utility, Inc.): https://maclookup.app/macaddress/0009BC
- OpenDroneID core library (Apache-2.0): https://github.com/opendroneid/opendroneid-core-c
- DJI OUI blocks (SZ DJI Technology Co.,Ltd and DJI Baiwang Technology): https://standards-oui.ieee.org/oui/oui.csv
- Parrot OUI blocks (Parrot SA): https://maclookup.app/vendors/parrot-sa
- Skydio OUI block (Skydio, Inc.): https://maclookup.app/vendors/skydio-inc
- Autel Robotics OUI blocks (Autel Robotics Co., Ltd.): https://maclookup.app/vendors/autel-robotics-co-ltd
- Yuneec OUI block (Yuneec): https://maclookup.app/vendors/yuneec
- Current MA-L, MA-M, and MA-S registries for the remaining aircraft vendors: https://standards-oui.ieee.org/
- Vuzix company ID 0x060C (Vuzix Corporation), Bluetooth SIG: https://www.bluetooth.com/specifications/assigned-numbers/
- Tracker research: https://arxiv.org/abs/2501.17452 and https://arxiv.org/pdf/2401.13584
- Nordic company-ID mirror (glasses company IDs): https://github.com/NordicSemiconductor/bluetooth-numbers-database
- Recording-glasses name is pairing-only (Help Net Security): https://www.helpnetsecurity.com/

---

*Drafted 2026-06-18 from public sources; last synced against the shipped firmware tables
2026-07-19. The Raven service UUIDs are field-captured and shipped (see the Raven table
above). Still open: verify Flock's BLE company ID `0x09C8` (registrant + exclusivity)
against the current Bluetooth SIG assigned-numbers list; until then it ships at conf 45,
in the apps' weak-match band.*

---

## Copy truthfulness: the two facts every privacy statement must accommodate

Written down 2026-08-06 after an audit found three separate places claiming location "is never
transmitted" or is "used only on your device". Both statements were false, and one of them was the
iOS permission dialog, i.e. shown by the operating system itself.

Anything written about privacy, in the apps, on the site, in store listings, or in a permission
string, has to be true against these two facts:

1. **The phone pushes its GPS fix to the board over BLE.** `sendPhoneLocation()` runs on connect
   (iOS `BLEManager.swift`, Android `AcabBleManager.kt`). That automatic path is a LOCAL, encrypted
   link to the user's own hardware, but it is still a transmission, so "never transmitted" and
   "used only on your device" are both wrong. A separate user-initiated export or field
   contribution can send selected data off-device. The honest framing is that the automatic
   location path is limited to the user's own beacon over local encrypted Bluetooth; detection or
   location data reaches another recipient only when the user explicitly exports or sends it.
2. **Opening the map fetches tiles from a third party.** Apple Maps on iOS, OpenStreetMap on
   Android. That provider sees an ordinary map request and the user's IP address. It never sees
   detections. This also means the tile fetch belongs in Google's Data Safety form, which treats
   an off-device transmission as collection regardless of what it carries.

The first-run tour should describe DETECTION as passive, not claim the board never transmits. The
board never probes, jams, or spoofs nearby devices; it does use its encrypted BLE link to exchange
results and settings with the user's phone. Keep both halves in the wording so "passive" cannot
drift back into the false absolute "never transmits".

Canonical wording lives in `web/privacy.html`. The FAQ answer (`faq-content.json`, byte-identical
on both platforms and enforced by `check-signature-drift.py`) and the iOS
`NSLocationWhenInUseUsageDescription` in `ios/project.yml` are the two other places that must
agree with it.
