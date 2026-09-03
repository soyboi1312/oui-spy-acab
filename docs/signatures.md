# ACAB detection signatures (clean-room reference)

Every signature in this file is sourced from a public registry, a published standard,
or independent third-party research, **not** from the colonelpanichacks/oui-spy code.
Rebuild the firmware's detection tables from here and write your own parser.

## Why this is clean

Each entry cites the registry, standard, or observed radio signature used to build
these tables. The classifiers implement the matching independently. Reusing upstream
code or curated datasets requires following their respective licenses; see
`CREDITS.md` for project lineage and the current `flock-you` MIT license.

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
| WiFi SSID | suffix | `-FALCON` **NOT SHIPPING** (`ext=1`, retired 2026-08-25): compiled out of every build, matches nothing, carries no confidence. See the retirement note below | none. the capture it was cited to holds this firmware's own diagnostic label, not a broadcast SSID |
| BLE name | prefix + digits-only tail | `Penguin-` + digits (research form: 10 digits) | ryanohoro |
| BLE name | substring (literal) | `FS Ext Battery` | ryanohoro |
| BLE name | prefix + hex-only tail | `FS-` + hex (e.g. `FS-BEC46A`) | own field capture (2026-06) |
| BLE name | prefix, loose | `Flock` | brand string, public |
| BLE mfg data | company ID | `0x09C8` (Flock's BT module; ryanohoro attributes to XUNTONG; shared silicon, conf 45 = weak-match band) | ryanohoro |
| MAC OUI | exact | `B4:1E:52` (Flock Safety, MA-L, reg. 2024-05-09) | IEEE / maclookup.app |
| WiFi probe-req | OUI, probe-req only | Liteon `24:B2:B9` `F4:6A:DD` `D8:F3:BC` `C0:35:32` (caught over probe requests at a DeFlock-confirmed Falcon site; the capture ties the OUI to the site, not to that camera's radio) | own field capture (2026-06) |

BLE names are matched ANCHORED, not substring-anywhere (except the specific
`FS Ext Battery` literal): `FS-` is a generic white-label model prefix and bare
`penguin`/`flock` substrings match phones and novelty gadgets. Only the
`FS Ext Battery` literal ranks strong (80) on its own. The prefix forms rank 80 only
when the `0x09C8` manufacturer ID backs them, and stay hint-grade (70) otherwise,
regardless of address bytes. This preserves the existing name-plus-manufacturer
tier; `0x09C8` identifies shared XUNTONG silicon and is not exclusive to Flock.
The public-address confidence boost was removed on 2026-09-01: a public address
provides no Flock-specific evidence, and the WiFi local-address bit cannot determine
BLE address type. A name-only `FS-100` hit therefore stays at 70 for every address.
The bare 10-decimal-digit name ryanohoro documents as the post-Mar-2025
pattern is deliberately NOT matched: it false-positived in the field on a phone
advertising the placeholder name `0102000000` (removed 2026-06-18). Reconsider it
only with independent Flock-specific evidence.

**Detection-quality notes (read before you copy the old tables):**
- The WiFi/BT chip is a LiteOn WCBN3510A. Lite-On's OUIs are shared across millions of
  consumer devices, so matching them on *any* frame is a false-positive magnet, and the old
  ~67-OUI "superset" (ported curation + the source of the field false positives) stays dropped.
  `B4:1E:52` (Flock's own block) is the only OUI defensibly Flock-specific on its own.
- **Probe-request exception (Falcon as WiFi client):** Falcon cams join a network as WiFi
  clients (no `Flock-` AP of their own) and emit probe requests from a Liteon module. Four
  Liteon OUIs ship (`ext=0`): `24:B2:B9`, `F4:6A:DD`, `D8:F3:BC` and `C0:35:32`, each caught by us
  over probe requests at a DeFlock-confirmed Falcon site in 2026-06. **That is the whole of the
  evidence, and it is weaker than "validated at a live Falcon", which this file used to claim.** The
  capture ties the OUI to a place where a Falcon is mapped, not to that camera's own radio - nothing
  in it demonstrates the probes came from the camera rather than from something else at the site.
  All four also came out of ONE capture batch (`ca44071`), so the evidence behind them is one
  observation, not four independent ones: grade them together or not at all.
  They are matched on PROBE REQUESTS ONLY, but note the honest limit of
  that gate: it distinguishes APs from clients, not cameras from laptops - probe requests are
  exactly what a powered-on, not-yet-associated laptop emits, and Windows ships MAC
  randomization off, so consumer Liteon NICs (Dell/HP/Acer) probe with their real OUI. That is
  why it ships as a medium-confidence signal (conf 72), not proof. **The 2026-07-24 promotion this
  file used to describe never happened.** It said `D8:F3:BC` and `C0:35:32` were held-out candidates
  promoted after a drive recaptured both broadcasting `PROBE-FALCON` / `DATA-FALCON` SSIDs. Git says
  otherwise: all four rows landed in one 2026-06-19 commit with no `ext` field at all, so they have
  shipped unconditionally since the day the table was written, and there was nothing to promote. The
  two SSIDs were never on the air either; see the retirement note below. Behaviour of these rows is
  unchanged, and always was. Only the note about them was wrong. Earlier unconfirmed candidates lifted from community
  OUI lists (a set that tracked an upstream's curated selection) were removed for clean-room
  provenance, since a curated third-party OUI list is not ours to distribute and those entries
  were off by default and detected nothing anyway. Deliberately NOT matching `08:3A:88` (USI;
  our Molekule air-purifier FP) or its SiLabs "FS Ext Battery" OUI blocks, which the BLE name
  match already covers.
- **`-FALCON` SSID suffix: RETIRED to the non-shipping tier 2026-08-25.** The rule said Falcon
  cameras stand up per-function networks named `PROBE-FALCON` and `DATA-FALCON`, and it reported any
  SSID ending case-insensitively in `-FALCON` as an ALPR camera at conf 85 when the frame attested
  its own SSID, or conf 72 on the probe-borne half. Conf 85 sat above the field-validated Axon OUI
  at 75, and the suffix anchor keeps `Atlanta-Falcons` out but not `NET-FALCON` or a renamed router.
  The evidence was circular: those two strings are labels this firmware writes into the `ssid=`
  field of its own `[wifi]` diagnostic line, and only after `falconOui()` has already matched, so a
  capture containing them is our OUI table quoting itself. Two independent confirmations. A data
  frame carries no SSID element at all, so `DATA-FALCON` could not have come off the air. And the
  one capture in this repo holding the string (`docs/captures/lvt-2026-08-03-summary.txt`) shows
  `ssid="PROBE-FALCON"` followed immediately by a conf-72 `Falcon probe (OUI)` verdict, which is the
  verdict the classifier gives when the frame's own SSID does NOT end in `-FALCON`. Git dates the
  labels to 2026-06-19, five weeks before the drive they were credited to. The rule now sits behind
  the same `ext=1` gate as an unvalidated OUI row (`FLOCK_SSID_FALCON_SUFFIX_EXT`, read by
  `falconSsidSuffix()`), which is compile-time false with no runtime toggle, so both the conf-85 and
  the conf-72 half fold away in every build and no shipped firmware reports a `-FALCON` name as
  anything. The labels are now spelled `fwnote:falcon-oui-data` / `fwnote:falcon-oui-probe` so the
  round trip cannot be made again. The `Flock-` prefix rules are untouched. To ship it: a capture of
  a real beacon (`0x8`) or probe-response (`0x5`) SSID IE ending in `-FALCON`, from a unit confirmed
  to be a Falcon by something other than this table.
- **Watchlist (diag only):** the BLE name `Pigvision` is a candidate Flock signature carried ONLY in
  the `ACAB_DIAG` build (it logs `*** PIGVISION CANDIDATE ***`), never in production. A confirmed
  field sighting is the trigger to promote it into `FLOCK_NAME_PATTERNS`.
- The bare 10-digit BLE name is inherently ambiguous (any device with a 10-digit name
  matches, including phones) and is NOT in the shipped tables. Reconsidering it requires
  independent Flock-specific evidence; neither public address type nor RSSI establishes
  what the device is.

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

### Capture-only ALPR vendor-prefix candidates (2.0.6)

The field-capture firmware now calls out the exact IEEE assignments below. Every runtime line says
`vendor prefix candidate` and `product unknown`. A registration ties an address range to a company;
it does not prove that an ALPR product uses that range. These rows never enter a detector, never
create an `AcabDetection`, and never reach either phone app. Shipping firmware does not compile the
table at all.

| Related ALPR brand | Exact IEEE registrant | Registry | Canonical value / exact mask |
|---|---|---|---|
| Avigilon Alta | Avigilon Alta | MA-L | `70:1A:D5:00:00:00 / FF:FF:FF:00:00:00` |
| Ekin | Ekin Teknoloji San ve Tic A.S. | MA-M | `04:C3:E6:90:00:00 / FF:FF:FF:F0:00:00` |
| Genetec | Genetec Inc. | MA-L | `00:BF:15:00:00:00 / FF:FF:FF:00:00:00` |
| Genetec | Genetec Inc. | MA-L | `0C:BF:15:00:00:00 / FF:FF:FF:00:00:00` |
| Genetec | Genetec Inc. | IAB | `00:50:C2:BE:70:00 / FF:FF:FF:FF:F0:00` |
| Jenoptik | JENOPTIK | MA-L | `00:04:4C:00:00:00 / FF:FF:FF:00:00:00` |
| Jenoptik | JENOPTIK Advanced Systems GmbH | MA-L | `48:E3:C3:00:00:00 / FF:FF:FF:00:00:00` |
| Kapsch | KAPSCH AG | MA-L | `00:E0:6A:00:00:00 / FF:FF:FF:00:00:00` |
| Leonardo / ELSAG | Elsag Datamat spa | MA-L | `00:40:DE:00:00:00 / FF:FF:FF:00:00:00` |
| Leonardo / ELSAG | ELSAG | MA-S | `70:B3:D5:1C:50:00 / FF:FF:FF:FF:F0:00` |
| Leonardo / ELSAG predecessor | Selex ES Inc. | MA-S | `70:B3:D5:52:10:00 / FF:FF:FF:FF:F0:00` |
| Leonardo / ELSAG predecessor | Selex ES Inc. | MA-S | `70:B3:D5:F5:E0:00 / FF:FF:FF:FF:F0:00` |
| Neology | Neology | MA-L | `00:17:3D:00:00:00 / FF:FF:FF:00:00:00` |
| Ubicquia | Ubicquia LLC | MA-L | `94:7B:BE:00:00:00 / FF:FF:FF:00:00:00` |

Prefix length is part of the evidence. Ekin is one `/28`, not the whole `04:C3:E6/24`.
Genetec's IAB and the ELSAG/Selex MA-S rows are `/36`, not their shared first three bytes. The
matcher also rejects locally administered addresses.

The capture build checks the advertiser address on BLE and every address field present in a WiFi
management or data header. BLE ingest does not retain whether the scanner reported a public or
random address, so those lines explicitly say `addr_type=unknown`. A globally shaped BLE
address is still only a lead. WiFi summaries use `a=` as a bitmask for address fields 1 through 4,
and report total, data, management, management-subtype, and best-RSSI evidence. Output is throttled;
the raw capture and counters remain the evidence.

The Selex rows are related candidates, not direct proof. Leonardo's public ELSAG Plate Hunter price
list names Selex ES Inc as manufacturer, and its current LPR contact uses the same Greensboro
location as the Selex assignments. That supports collecting the prefixes next to visible ELSAG
hardware, but it does not promote them to product signatures.

Deliberate exclusions are just as important. Motorola parent assignments, Ubiquiti network-device
assignments, Ava Security `D0:3D:52`, broad Leonardo parent assignments, and unrelated ELSAG/Selex
corporate siblings are not included. PlateSmart, RedSpeed, and Rekor had no direct public assignment
under those registrant names in the checked data, so they remain documented gaps. Do not substitute
an integrator, parent company, or shared radio-module block.

Sources checked 2026-08-23: [IEEE MA-L](https://standards-oui.ieee.org/oui/oui.csv),
[IEEE MA-M](https://standards-oui.ieee.org/oui28/mam.csv),
[IEEE MA-S](https://standards-oui.ieee.org/oui36/oui36.csv),
[IEEE IAB](https://standards-oui.ieee.org/iab/iab.csv), and
[IEEE registry semantics](https://standards.ieee.org/faqs/regauth/). Relationship context:
[Leonardo ELSAG price list](https://www.leonardocompany-us.com/hubfs/DIR-CPO-4756%20Price%20List%203-26-21.pdf)
and [Leonardo US contact](https://www.leonardocompany-us.com/leonardo-contact-us).

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

Proposed as rows in `bodycam_vendor_signatures.h`, on the reasoning that both vendors dominate
US cruiser connectivity and run WiFi APs from marked vehicles. The OUIs are real and the registrants narrow,
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

### Vendor-prefix additions (2026-09-01)

The following assignments extend vendors already supported by the opt-in network-camera
detector. OUI-Master-Database supplied the leads; each assignment was independently checked
against the [IEEE MA-L registry](https://standards-oui.ieee.org/oui/oui.csv) or
[IEEE MA-M registry](https://standards-oui.ieee.org/oui28/mam.csv).

| Vendor label | Exact IEEE registrant | Registered prefix |
|---|---|---|
| Ezviz | Hangzhou Ezviz Software Co.,Ltd. | `38:F2:5D:00:00:00/24` |
| Uniview | Zhejiang Uniview Technologies Co.,Ltd. | `14:BA:88:00:00:00/24` |
| Amcrest | Amcrest Technologies | `34:46:63:20:00:00/28` |
| Wyze | Wyze Labs Inc | `A4:DA:22:20:00:00/28` |
| Swann | SWANN COMMUNICATIONS PTY LTD | `0C:0E:C1:40:00:00/28` |

The MA-L rows join `CAMERA_VENDOR_OUI`; the MA-M rows live in `CAMERA_VENDOR_PREFIX`
and use `acabOuiPrefixMatches` to retain all 28 registered bits. The existing MA-L binary
search stays in place. A three-byte comparison of an MA-M entry would include fifteen
neighboring blocks outside the vendor's assignment.

All five entries keep `validated=0` and the existing confidence of 65. The local
`firmware/tools/detection logs/camarillo_drive.log` contains two addresses in the Wyze assignment:
`A4:DA:22:2E:FE:07` and `A4:DA:22:2E:A7:BE`. These establish that the block was heard;
neither was visually confirmed as a camera. A vendor match can also identify a hub,
recorder, or another product from that company. The detector remains opt-in and reports
the existing `<Vendor> on wifi` detail.

### Captured vendor additions (2026-09-01)

These 13 assignments add five vendor labels to the opt-in WiFi detector. Each was checked
against the [IEEE MA-L registry](https://standards-oui.ieee.org/oui/oui.csv) or
[IEEE MA-M registry](https://standards-oui.ieee.org/oui28/mam.csv); OUI-Master-Database
and local captures supplied the leads.

| Vendor label | Exact IEEE registrant | Registered prefixes |
|---|---|---|
| Blink | Blink by Amazon | `3C:A0:70:00:00:00/24`, `70:AD:43:00:00:00/24`, `74:13:48:00:00:00/24`, `74:AB:93:00:00:00/24`, `C8:19:D8:00:00:00/24`, `F0:74:C1:00:00:00/24` |
| Night Owl | Night Owl SP | `54:2B:57:00:00:00/24` |
| SkyBell | SKYBELL, INC | `D0:C1:93:00:00:00/24` |
| Juan OEM | Guangzhou Juan Intelligent Tech Joint Stock Co.,Ltd | `08:3A:2F:00:00:00/24` |
| Juan OEM | Guangzhou Juan Optical and Electronical Tech Joint Stock Co., Ltd | `9C:A3:A9:00:00:00/24` |
| Juan OEM | Guangdong Juan Intelligent Technology Joint Stock Co., Ltd. | `84:D0:DB:00:00:00/24`, `A4:86:DB:00:00:00/24` |
| WUUK | WUUK LABS CORP. | `B0:B3:53:70:00:00/28` |

The review covered all 23 files under `firmware/tools/detection logs/`, including ignored
captures and CSV exports. Counts below deduplicate full WiFi MAC addresses across that
collection; they are observed addresses, not physical-device counts or visual confirmations.

| Vendor | Distinct WiFi addresses | Product evidence and limits |
|---|---:|---|
| Blink | 7 | [Blink documents](https://support.blinkforhome.com/wi-fi-or-network-issues/what-is-the-blink-wifi-connection) temporary `BLINK-XXXX` networks from both Sync Modules and cameras. Captures include `BLINK-5AJB`. |
| Night Owl | 14 | [Night Owl documents](https://nightowlsp.com/pages/fwip2-series-camera-features-and-specifications) 2.4 GHz cameras and compatible recorders. Captured names include `NVR542b5707c2a1`, so a hit may identify a recorder. |
| SkyBell | 1 | [SkyBell's network requirements](https://support.skybell.com/hc/en-us/articles/360003105312-Network-Requirements) cover both doorbells and the SkyBell Chime. The capture includes `SkybellHD_2151974911`; the OUI alone does not establish a model. |
| Juan OEM | 64 | [Juan's catalogue](https://www.juancloud.com/products/) includes WiFi cameras, NVRs, and DVRs. Captured names include `NVR083a2f4cc78b`. The label names the manufacturer, not a retail brand or camera model. |
| WUUK | 3 | [WUUK documents](https://support.wuuklabs.com/hc/en-us/articles/7702681660185-Introducing-WUUK-Base-Station) a base station that creates a 2.4 GHz network for cameras and doorbells, so the transmitting device may be the base station. |

Only Blink's `3C:A0:70/24` and `74:AB:93/24` appear in these captures; its other four
assignments are registry additions. The earlier Blink exclusion overlooked its separate
`Blink by Amazon` registrations. Generic Amazon Technologies blocks still cover unrelated
products and remain excluded.

All 13 entries have `validated=0` and use `NETCAM_OUI_CONFIDENCE` (65). The WUUK entry
uses `CAMERA_VENDOR_PREFIX` and preserves its full /28 assignment; the adjacent blocks
are not WUUK matches. Network-camera detection remains off by default, with the existing
`<Vendor> on wifi` detail. A captured name supports further review but does not earn the
visually validated OUI tier of 75. No new SSID rule is added; the existing Arlo base-station
SSID rules remain at `NETCAM_SSID_CONFIDENCE` (88).

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
  `NTGR_VMB_` covers that legacy case and earns its keep: across our drive logs from 2026-07-24 to
  2026-09-02 it caught 33 hubs, 15 of them on NETGEAR blocks that no OUI row could have reached.
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

Neither is added. A registered OUI establishes the assigned vendor, not whether a product will
be heard or whether it is a camera. The table admits unvalidated vendor hints at confidence 65;
visual confirmation is required for the validated OUI tier of 75. These candidates still need
captures that establish which product line transmits.

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

## Body cams and activation accessories (Axon, Utility, i-PRO, Getac)

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
clean-room provenance discipline `flock_signatures.h` and `bodycam_vendor_signatures.h`
follow.

### i-PRO and Getac capture candidates (2.0.6)

i-PRO BWC4000 cameras and IPS-BTS holster sensors, plus Getac BC-02/BC-03/BC-04 cameras,
TB-02/TB-03 vehicle trigger boxes and HS-01 holster sensors, are now first-class capture targets.
The capture build annotates advertised local names containing `BWC4000`, `IPS-BTS`, `BC-02`,
`BC-03`, `BC-04`, `TB-02`, `TB-03`, or `HS-01` as `BODYCAM CAPTURE CANDIDATE` while preserving
the full raw advert. These annotations never reach the apps and do not classify a device.

That boundary is intentional. Vendor documentation confirms BLE/WLAN operation and confirms that
Getac trigger boxes can be wired to lightbars, doors and weapon releases, but neither vendor
publishes a stable passive advertising value. Getac corporate OUIs are shared with rugged laptops
and tablets, so an OUI rule would create a large and misleading body-camera false-positive set.
Promote a candidate only after a bracketed near/left capture ties a stable payload, UUID or name
to visually confirmed hardware; label a trigger as `camera activation accessory`, not `body camera`.

**Body-cam decoy deliberately NOT matched.** `00:01:21` and `00:90:7F` are **WatchGuard
Technologies** (a network-firewall vendor), a different company from WatchGuard Video (the
in-car / body camera brand now folded into Motorola Solutions), so they are not body-cam
signals and stay off the table.

## BLE trackers

| Tracker | Match on | Value | Public source |
|---|---|---|---|
| Apple AirTag / Find My | mfg company ID + type + length | `0x004C` + payload type `0x12` + length `0x19` (separated form only; the shorter near-owner form is skipped) | Bluetooth SIG + arXiv 2501.17452 |
| Samsung SmartTag | 16-bit service data (AD 0x16 with a real payload; a bare UUID-list entry is deliberately not matched) | `0xFD5A` | arXiv 2501.17452 + Bluetooth SIG |
| Tile | 16-bit service data (AD 0x16 with a real payload; a bare UUID-list entry is deliberately not matched) | `0xFEED` | Bluetooth SIG |
| Google Find Hub / FMDN (separated) | service data UUID + frame type | `0xFEAA` + frame type `0x41` **only** | Google Find Hub Network Accessory Spec, tables 15/16 |

**Find Hub covers the whole Android ecosystem, not one brand.** The `0xFEAA` + `0x41` match is
network-wide, so Moto Tag, Chipolo Point and the compatible Pebblebee tags are already detected
with no per-manufacturer signature. Do not add brand rows for them. The same holds on the Apple
side: third-party Find My accessories ride the existing Find My offline frame above.

**Frame type `0x40` is deliberately NOT matched.** `0x41` is the *separated* state, a tag away
from its owner, which is the only state that means anything for following. `0x40` is the
near-owner state and would fire on every pair of earbuds sitting beside their owner. Same rule,
and the same reason, as the Apple length byte `0x19` above, which is what selects the separated
form (the `0x12` payload type is common to both forms). The implementation and the
accepted-miss note are in `firmware/lib/acab_core/tracker_detect.cpp`.

## Smart / recording glasses

Its own category (`t=9`, not trackers, not body cam). **Three match surfaces**, all
payload-borne so they survive the MAC randomization these devices do. Every surface is scored and
the HIGHEST-confidence hit wins, never the first hit. They are listed here in the firmware's own
evaluation order (`glasses_detect.cpp`), and that order is part of the contract because it decides
**ties**: the comparison is `<=`, so an equal-confidence later surface does not displace an
earlier one. First-listed wins a tie, deliberately.

1. the HeyCyan SDK's 128-bit service UUID, read out of the AD `0x06`/`0x07` 128-bit UUID lists or
   AD `0x21` service data (method `M_SERVICE_DATA`, `meth:8`);
2. 16-bit SIG **member** service UUIDs, a separate namespace from company IDs, read out of the
   AD `0x02`/`0x03` UUID lists and the first two bytes of an AD `0x16` service-data record
   (method `M_SERVICE_UUID`, `meth:4`);
3. the BLE manufacturer-specific data (AD type `0xFF`) company ID, first two payload bytes,
   little-endian (method `M_MFG_ID`, `meth:3`) - the first table below.

Surfaces 1 and 2 are the second table below, and they need no manufacturer data at all, which is
why they run first: an advert can carry a UUID list and no `0xFF` record whatsoever. A detector
that reads only manufacturer data is blind to two of the three, which is what the firmware was
until 2026-07-31.

**Get the tie rule wrong and you emit the wrong `meth`.** A Snap Spectacles advert carrying both
member UUID `0xFE45` (conf 70) and company ID `0x03C2` (conf 70) reports `meth:4`, not `meth:3`,
because surface 2 set the best score first. Same for `0xFEB7` (45) beside `0x01AB` (45). The
detail strings are identical on both paths, so `meth` is the only field that shows which surface
fired, and it is the field someone triaging a hit reads.

A 2026-07-31 field capture confirmed advertise-while-worn (`0x01AB` fired twice during the
worn window, and nowhere else in the 1568-row capture, while three Meta glasses were
worn); the Quest discriminator token's byte framing is still
capture-pending, so most rows stay at "possible recording glasses." Background and provenance in
[docs/glasses.md](glasses.md); the tables here are the shipped ones.

| Product | Match on | Value | Registrant | Eyewear-only? | Shipped? | Public source |
|---|---|---|---|---|---|---|
| Ray-Ban Meta frames | mfg company ID | `0x0D53` (conf 70) | Luxottica Group S.p.A | yes | on by default | Bluetooth SIG |
| Snap Spectacles | mfg company ID | `0x03C2` (conf 70) | Snapchat Inc | yes (Snap's only BLE hardware) | on by default | Bluetooth SIG |
| Vuzix camera AR glasses (Blade/M400/Shield/Z100) | mfg company ID | `0x060C` (conf 70) | Vuzix Corporation | yes (AR-eyewear-only maker) | on by default | Bluetooth SIG |
| Ray-Ban / Oakley Meta glasses | mfg company ID | `0x058E` (conf 49 if ever enabled) | Meta Platforms Technologies, LLC | **no**, shared with Meta Quest VR | **gated OFF** (token-confirmed hits only) | Bluetooth SIG |
| Meta hardware (corporate ID) | mfg company ID | `0x01AB` (conf 45) | Meta Platforms, Inc. | **no**, corporate/parent ID | **on** (weak match, un-gated 2026-07-31) | Bluetooth SIG |
| RayNeo AR/smart glasses | mfg company ID | `0x0BC6` (conf 45 if ever enabled) | TCL COMMUNICATION EQUIPMENT CO.,LTD. | **no**, TCL phones/tablets/TVs | **gated OFF** (no token to rescue it) | Bluetooth SIG |
| Rogbird VisionPro / Rollme VistaView camera glasses | mfg company ID | `0x05D6` (conf 40 if ever enabled) | Zhuhai Jieli Technology Co. | **no**, a Bluetooth AUDIO SoC vendor | **gated OFF** (no token to rescue it) | Bluetooth SIG |
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
  `0x01AB` fired twice during the worn window (and nowhere else in the 1568-row capture)
  while three Ray-Ban/Oakley Meta glasses were worn, and Luxottica `0x0D53`
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
  distinguishing 16-bit service UUID has been documented: the member UUIDs in the
  service-UUID table below are split by REGISTRANT, which is an inference about who ships what,
  not a glasses-versus-Quest discriminator.
- **Name is pairing-only.** A device name identifies the glasses but is generally exposed
  only during pairing, so it is rarely visible against a covert user who paired in advance.
  Continuous field detection scores the three payload surfaces above, never the name.
- `0x03C2`'s authoritative registry string is **"Snapchat Inc"** (not "Snap Inc" as sometimes
  reported).
- **Glasses decoys deliberately NOT matched.** `0x0820` is **Brilliant Home Technology** (a
  smart-home hub vendor), a different company from the Brilliant Labs AR-glasses startup, so it
  is not a glasses signal. `0x00A3` is **Meta Watch Ltd**, a defunct smartwatch company
  unrelated to today's Meta Platforms, so it is not a Ray-Ban/Oakley Meta glasses signal.

### Glasses: service-UUID signatures

The other half of the detector, and a **separate namespace** from the company IDs above: the SIG
allocates 16-bit "member UUIDs" in the `0xFDxx`/`0xFExx` range independently of company
identifiers, so `0xFEB7` is not company ID `0xFEB7`. A vendor can expose itself through either
namespace, so a device that advertises no manufacturer data at all can still be matched here.

| Product | Match on | Value | Registrant | Shipped? | Public source |
|---|---|---|---|---|---|
| Meta hardware (corporate registrant, same as `0x01AB`) | 16-bit SIG member service UUID | `0xFEB7` (conf 45) | Meta Platforms, Inc. | on by default | Bluetooth SIG `member_uuids.yaml` |
| Meta hardware (corporate registrant, same as `0x01AB`) | 16-bit SIG member service UUID | `0xFEB8` (conf 45) | Meta Platforms, Inc. | on by default | Bluetooth SIG `member_uuids.yaml` |
| Meta hardware (Quest registrant, same as `0x058E`) | 16-bit SIG member service UUID | `0xFD5F` (conf 49 if ever enabled) | Meta Platforms Technologies, LLC | **gated OFF** | Bluetooth SIG `member_uuids.yaml` |
| Snap Spectacles | 16-bit SIG member service UUID | `0xFE45` (conf 70) | Snapchat Inc | on by default | Bluetooth SIG `member_uuids.yaml` |
| HeyCyan-SDK glasses (Nilox Smart AI Glasses and rebrands) | 128-bit service UUID, **full 16 bytes**, both byte orders | `7905FFF0-B5CE-4E99-A40F-4B1E122D00D0` (conf 68) | n/a, a vendor SDK UUID rather than a SIG allocation | on by default | yj_nearbyglasses README; HeyCyanSmartGlassesSDK |

**Notes:**
- **All four 16-bit UUIDs were verified 2026-07-31 against the SIG's own `member_uuids.yaml`**
  (708 entries, pulled from bitbucket.org/bluetooth-SIG/public), not taken on trust from a
  third-party repo. That list contains exactly these Meta/Snap allocations and no others. The
  third-party source that supplied `0xFD5F`/`0xFEB7`/`0xFEB8` missed Snap's `0xFE45` and cited
  nothing.
- **The gate follows the registrant, exactly as it does for the company IDs.** "Meta Platforms,
  Inc." is the registrant of `0x01AB`, the ID confirmed on real worn glasses, so `0xFEB7`/`0xFEB8`
  ship un-gated at the same weak-match confidence (45). "Meta Platforms Technologies, LLC" is the
  registrant of `0x058E`, the documented Quest ID, so `0xFD5F` is gated off for the same Quest
  false-positive reason. This is an inference by registrant, **not** a capture of these UUIDs:
  none of them has been observed in any capture here, and the CSV export carries no service
  UUIDs, so the 2026-07-31 capture could neither confirm nor refute them.
- **The HeyCyan UUID's base is Apple's ANCS, and that is why it must only ever match on the full
  16 bytes.** Apple's Notification Center Service is `7905F431-B5CE-4E99-A40F-4B1E122D00D0`: the
  same entire 96-bit base and the same leading `7905`, differing only `F431` to `FFF0` (`0xFFF0`
  being the stock "cheap BLE module" service). A prefix or partial match would fire on every
  device that consumes Apple notifications, which is a huge slice of all wearables. Verified
  against the published ANCS UUID 2026-07-31 precisely because the near-collision looked like a
  transcription error. Both byte orders are matched, since advertisers have been seen to get the
  order wrong and a full 16-byte match carries no realistic collision risk either way.
- **HeyCyan is the best-shaped signal in the whole glasses section**, which is why it sits above
  the corporate-ID tier at 68: it identifies the glasses SOFTWARE rather than a corporate
  registrant, so it has neither the Quest ambiguity nor the earbud ambiguity. It stays below the
  field-validated tier (Axon OUI at 75) because, unlike the `0x01AB` un-gate, no capture here has
  ever seen it.

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
- Bluetooth SIG 16-bit member UUIDs, `member_uuids.yaml` (the glasses service-UUID surface): https://bitbucket.org/bluetooth-SIG/public
- Apple Notification Center Service UUID `7905F431-B5CE-4E99-A40F-4B1E122D00D0` (the near-collision the HeyCyan full-16-byte rule exists for): Apple's published ANCS specification
- HeyCyan SDK service UUID and the glasses service-UUID surface: yj_nearbyglasses README; HeyCyanSmartGlassesSDK
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

1. **The phone pushes its GPS fix to the board over BLE.** On connect, iOS runs
   `sendPhoneLocation()` in `BLEManager.swift`; Android's `setLocation()` in
   `AcabBleManager.kt` writes `{"lat","lon"}` to Config. That automatic path is a LOCAL, encrypted
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
