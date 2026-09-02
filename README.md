# All Cameras Are Beacons

**All Cameras Are Beacons.** A little gadget that quietly notices when surveillance gear is around you and gives you a heads-up, either on your phone or over a Meshtastic mesh.

It runs on the beacon, our own dual-radio board, and on the **Colonel Panic OUI-Spy** and **Mesh-Detect** boards built around a Seeed XIAO ESP32-S3. Plug it in and it listens for radio signals that cameras, sensors, trackers, and drones already broadcast. When it recognizes one, it tells you.

> **Important:** detection of nearby devices is passive. Shipping firmware does not probe, jam,
> spoof, control, or interfere with the devices it observes. The board uses a bonded, encrypted
> Bluetooth link to exchange detections, status, and settings with the phone app. Mesh-Detect
> separately transmits alerts through its wired Meshtastic node. This is the radio equivalent of
> noticing a camera on a pole and writing it down.
> Mapping surveillance gear in public is a long-standing privacy practice, and the folks at
> [DeFlock](https://deflock.me) have been at it for a while.

## Start here

- **Want to look around without hardware?** Install the [iPhone app](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) or [Android app](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) and tap **See how it works**. It loads six clearly marked fictional detections. Sample settings never configure a board, sample rows never enter your real Log, and leaving the sample restores your saved data.
- **Already have compatible hardware?** Power the beacon, OUI-Spy, or Mesh-Detect board and tap **Scan** in the app. Grant Bluetooth access on iPhone, Nearby devices on Android 12 or newer, or Location on Android 8 through 11. Choose the board and approve the system pairing prompt. The first encrypted connection opens a short walkthrough followed by the relevant permission and readiness prompts.
- **Building your own OUI-Spy or Mesh-Detect?** Use the [one-click DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) or follow the [command-line instructions](#flashing-from-the-command-line).
- **Looking for the beacon?** Retail hardware is coming soon. Current availability and the waitlist are at [soyboi.tech](https://soyboi.tech).
- **Need a hand?** Read the [getting-started guide](https://soyboi.tech/getting-started), check the [FAQ and support page](https://soyboi.tech/faq), or open a [GitHub issue](https://github.com/soyboi1312/all-cameras-are-beacons/issues).

A board is required for live detection. Sample data and an existing saved Log remain available without one.

## the beacon

the beacon is a pocket detector, about the size of an AirPods case, that quietly maps the surveillance gear broadcasting around you. flip it on, drop it in a bag, and everything it recognizes shows up live on your phone.

it listens to Wi-Fi and Bluetooth, two protocols on the 2.4 GHz band. surveillance gear announces itself over the air to do its job; the beacon recognizes supported broadcasts and puts them in your Log. it is a detector, not a weapon.

**the device**

- dual radio: a dedicated nRF52840 scanner listens continuously for Bluetooth while an ESP32-S3 handles Wi-Fi and the app link, so neither job starves the other. the duty-cycle details are in [how much does it actually hear?](#how-much-does-it-actually-hear)
- optional location context from your phone's GPS
- an onboard buzzer, so alerts still work with your phone put away
- optional offline logging that stores detections on the board, encrypted, until you reconnect
- USB-C power, with charging over the same port on the battery model
- app-delivered firmware updates over Bluetooth, with revision-specific USB recovery available when needed

Retail units are designed to arrive pre-flashed. You will still need to power the board, pair it with the app, and choose any optional permissions or detector categories you want.

**free app, paid hardware.** the iPhone and Android apps and the ESP32-S3 firmware in this repository are free and open source. the beacon hardware is what we plan to sell. there are no accounts, analytics, third-party tracking, or automatic detection uploads. detections stay on your board and phone unless you explicitly export or contribute them. the apps do make ordinary network requests for map tiles, update files, and the optional mapped-camera dataset, but those requests do not include your detections. the full policy is in [web/privacy.html](web/privacy.html).

**honest about limits.** silent gear stays invisible. wired cameras and purely optical systems emit no supported radio signal and will not show up. this is not an SDR or a bug sweeper. a quiet screen means the scanner did not recognize a supported broadcast while it was listening, not that you are unwatched.

**privacy limits.** the board currently advertises a fixed factory Bluetooth address so bonded iPhones can reconnect reliably. that means a passive observer can correlate the board itself over time. the offline buffer is encrypted, but its key is stored on the board while buffering is enabled. it protects against casual reads, not forensic access to a captured unit. both tradeoffs are detailed in [docs/ble-protocol.md](docs/ble-protocol.md).

## What it detects

| What | How it is spotted | Default and limits |
|---|---|---|
| **Flock cameras** (automated license-plate readers) | Bluetooth, plus Wi-Fi when a unit advertises or probes | On by default. Product-specific names and SSIDs are the clearest matches; Flock and Lite-On address-prefix paths are supporting leads (the Lite-On evidence grade is documented in docs/signatures.md) |
| **Flock Raven** audio sensors | Bluetooth service UUIDs | On by default; built from field-captured Raven-specific services |
| **Drones broadcasting FAA Remote ID** | Bluetooth + Wi-Fi | Remote ID is on by default and can include aircraft coordinates; a separate vendor-hardware fallback matching drone makers' own address blocks (DJI, Parrot, Skydio, Autel, Yuneec, Anduril, Zipline, and more; the full table is `firmware/lib/acab_core/drone_signatures.h`) is opt-in and may identify a controller rather than an aircraft |
| **Body cameras** (Axon and Utility BodyWorn) | Bluetooth + Wi-Fi | On by default; Axon's device tag is the strongest match. A broad Motorola Solutions vendor proxy has its own opt-in switch, starts off, and is always a weak match to verify |
| **Item trackers** (Apple Find My, Google Find Hub/FMDN in separated state, Tile, Samsung SmartTag) | Bluetooth | Off by default; sightings reach the app immediately. The board never beeps for a tracker in any mode, and it keeps the tracker's first minute out of its offline buffer so a brief pass-by does not spend the capture |
| **Smart or recording glasses** (Ray-Ban and Oakley Meta, Snap Spectacles, Vuzix) | Bluetooth | On by default; eyewear-specific registrations are stronger. Shared Meta identifiers can also belong to a Quest headset, so those results are labeled as possible glasses |
| **Network cameras** | passive 2.4 GHz Wi-Fi frames | Off by default; 180 registered vendor blocks across 18 brands, including Axis, Dahua, Hikvision, i-PRO, Reolink, Ring, Verkada, Vivotek, Wyze, and Anker/eufy. This identifies a vendor family, not necessarily a camera, and is never a hidden-camera claim |

The signature sources, confidence choices, and rejected broad matches are documented in [docs/signatures.md](docs/signatures.md). Drone detection uses the public FAA and ASTM Remote ID broadcast through the open-source [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c) decoder. Axon notes are in [docs/axon.md](docs/axon.md), and the glasses evidence is in [docs/glasses.md](docs/glasses.md).

Diagnostic capture builds also include support for i-PRO BWC4000 cameras and activation accessories, Getac BC-series cameras and vehicle or holster triggers, and exact IEEE address-prefix candidates related to several ALPR manufacturers. These are **capture candidates, not production detections**. Capture firmware marks the i-PRO and Getac names as capture candidates. ALPR prefix lines say `vendor prefix candidate` and `product unknown`. The raw evidence is printed to the serial capture stream, where [firmware/tools/capture-log.py](firmware/tools/capture-log.py) can save it for review. It never reaches either phone app. A company registration alone does not prove which product transmitted. The evidence boundary and deliberate exclusions, including broad Motorola and Ubiquiti blocks, are recorded in [docs/signatures.md](docs/signatures.md).

## How reliable is it?

It depends on how a device matched, and the apps tell you. A self-identifying Remote ID payload, a device-specific service, or a narrow validated name is stronger than a corporate address prefix. An OUI identifies the registered owner or vendor family of a radio address. It does not, by itself, identify the exact product using that address.

The detector excludes many shared chip and module suppliers because their address blocks appear in unrelated laptops, routers, and consumer devices. Where a broader clue is still useful, it is constrained to a relevant frame type, put behind an opt-in switch, or assigned a low confidence. Tap a detection to see the method, confidence, exact reason, and the registered vendor when available. Treat weak results as leads to confirm, not certainties.

## How much does it actually hear?

The limits above are about *what* matches. These are about *how hard it looked*, which is the part a quiet screen depends on and which is easy to leave unsaid.

**2.4 GHz only. There is no 5 GHz radio.** The ESP32-S3 cannot hear 5 GHz, so that entire band is invisible. A growing share of IP cameras and drone control links prefer 5 GHz. This is a hardware limit, not a setting, and it is the largest coverage gap.

**Wi-Fi listens to one channel at a time, and not evenly. This is identical on every board.** The scanner walks a 24-slot sequence that returns to channel 6 between every other step because OpenDroneID uses channel 6 as its Wi-Fi social channel. That channel is also common for other 2.4 GHz traffic.

| Channel | Share of listening time |
|---|---|
| 6 | 50 percent |
| each of 1 to 5 and 7 to 13 | about 4.2 percent |

A camera beaconing on channel 11 as you drive past can be missed. The schedule deliberately improves the chance of hearing brief Wi-Fi Remote ID traffic while still touching all 13 channels. Battery-saver eco mode adds 3, 7, or 15 seconds of Wi-Fi receiver-off time after each full sweep, lowering Wi-Fi coverage in exchange for runtime. Bluetooth scanning is unaffected.

**Bluetooth duty cycle depends on the board.**

- **Single-radio builds** such as OUI-Spy and Mesh-Detect share one antenna between Bluetooth and Wi-Fi, so Bluetooth listens about **51 percent** of the time.
- **The dual-radio beacon** gives Bluetooth its own nRF52840, so it scans **continuously** and does not pause for ESP32-S3 Wi-Fi channel hops.

None of this makes a match less trustworthy. It makes silence less trustworthy.

## The phone apps

There are two native apps, one for iPhone and one for Android, with the same core job: pair with a beacon, OUI-Spy, or Mesh-Detect board and show what it hears. Both provide Status, Map, Log, and Beacon tabs.

- **Status** counts devices heard in roughly the last 45 seconds. Tap a category to open its filtered Log, or its detector setting when that category is off.
- **Log** stays on the phone and remains available while the board is disconnected. Filter it, inspect signal history and match evidence, and export the rows you are viewing as CSV or GPX.
- **Map** adds optional location context. Most live pins show where your phone heard a signal, not the device's exact location. Remote ID drones are the exception because they broadcast their own coordinates. The optional known-camera layer is a separate community dataset, and a missing map pin is never evidence that no camera exists.
- **Beacon** controls detector categories, buzzer or phone alert behavior, radio settings, encrypted offline buffering, firmware updates, and platform status or blockers.

Every detection shows a confidence percentage that describes how specific the matching evidence is. It is not a signal-strength score. Tap a row to see identifiers, first and last sighting, signal history, location context, and why it matched. Tracker details can summarize cautious **Seen with you** evidence from the current app session, but the app does not turn one sighting into a stalking verdict.

Star an exact device to create a watched category. Mute known gear permanently, for 1 hour, for 24 hours, or within 50 meters of a saved place. Permanent mutes are copied to the board and can silence its alerts while the phone is away. Timed and place mutes are enforced by the connected phone, so the board can still sound. Muted history remains in the Log with a **MUTED** label. Stars and mutes follow an exact hardware address, which means devices that rotate addresses can appear again. Managed devices can be renamed, unstarred, or unmuted in one place.

Vibrate mode silences the board and uses category-shaped phone haptics. For example, glasses use a double tap and body cameras use a repeating pattern. On iPhone these haptics fire while the app is open, and both apps respect Focus or Do Not Disturb. Separately, opt-in per-category phone notifications can play sound after notification permission is granted. Every notification category starts off.

Both apps provide VoiceOver or TalkBack descriptions for key status, map, and control surfaces, and their main layouts reflow for larger text.

### Live Mode and widgets

Live Mode is the nearby-now count shown on supported system surfaces. It is enabled by default after first setup, but the operating system decides whether it can appear.

- On iPhone, Live Mode uses a Live Activity on the Lock Screen and Dynamic Island. Location permission is required before the surface can start because Location keeps it reliable in the background.
- On Android, Live Mode uses an ongoing notification or Live Update where supported. Android 13 and newer require notification permission for that surface.

Detection and the Log still work if Live Mode is unavailable or switched off. Counts are visible on the Lock Screen by default and can be hidden under Beacon.

The home-screen widget is separate and must be added by the user. It shows today's detection total and connection state, plus the latest hit and category breakdown where space permits. Live Mode can also be toggled from Control Center on iPhone or Quick Settings on Android. On supported iOS 26 setups, the compact Live Activity can appear in the CarPlay Dashboard and Apple Watch Smart Stack. Compatible Android car hosts may show the standard widget. These are system-provided glances, not dedicated navigation, Apple Watch, or Wear OS apps.

### iPhone

The iPhone app lives in [ios/](ios/) and requires iOS 18 or newer. You can install it on your phone from [Apple's App Store](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861).

### Android

The Android app lives in [android/](android/), is built with Kotlin and Jetpack Compose, and supports Android 8 or newer. It uses OpenStreetMap rather than a Google map dependency. Install it from [Google Play](https://play.google.com/store/apps/details?id=tech.soyboi.beacons), or use the build and release instructions in [android/README.md](android/README.md).

Location is optional on iPhone and on Android 12 or newer. Android 8 through 11 require Location permission for Bluetooth scanning because those system versions gate discovery behind it. Bluetooth access on iPhone or Nearby devices on newer Android versions is needed to connect. Platform-specific prompts cover optional mapping, phone notifications, and offline buffering. On iPhone, Location is also required before Live Mode can start. Android Live Mode does not request background Location.

An unowned board accepts its first phone at any time, so make that first pairing in trusted surroundings. After a board already has a bond, that phone can reconnect normally. A different phone is accepted only during the two-minute window after a physical power-on.

Both apps currently ship in English only. Most interface copy lives alongside the native views, while the shared FAQ is mirrored byte for byte from one JSON document and checked for drift. The BLE protocol is documented in [docs/ble-protocol.md](docs/ble-protocol.md).

## Flashing

### Production beacon

App-delivered updates are the normal path. USB recovery images are board-revision specific:

- [rev-A beacon flasher](https://soyboi.tech/flash.html)
- [rev-B beacon flasher](https://soyboi.tech/flash-revb.html)

Do not cross-flash these images. A rev-B image on rev-A hardware, or a rev-A image on rev-B hardware, can leave the board needing USB recovery. The production pages identify whether a current USB image is available.

### DIY OUI-Spy and Mesh-Detect

The hosted [DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) works in Chrome or Edge on a computer with Web Serial support.

1. Plug the XIAO ESP32-S3 into the computer with a data-capable USB-C cable.
2. Open the flasher and choose **Flash firmware**, **Flash Mesh-Detect**, or the private-channel Mesh-Detect option.
3. Select the board when the browser asks and let the flash finish.

Safari and Firefox do not expose the required USB interface. The self-hosted flasher source lives in [web/](web/).

### Flashing from the command line

PlatformIO is the easiest route when changing firmware:

```bash
cd firmware

pio run -e oui-spy -t upload
pio run -e mesh-detect -t upload

pio device monitor -b 115200
```

Shipping PlatformIO environments are `oui-spy`, `mesh-detect`, `mesh-detect-ch1`, `beacon-board` for rev-A, and `beacon-board-revb` for rev-B. The `beacon-board-capture` and `beacon-board-revb-capture` environments are diagnostic builds. They record nearby MAC addresses, SSIDs, names, and raw payloads, so keep those logs private and return the board to a shipping image after a capture. `odid-sim` is a bench-only Remote ID simulator.

From the repository root, rebuild the hosted OUI-Spy and Mesh-Detect images with:

```bash
./web/build-flasher.sh --unsigned-usb-only
```

Release signing uses the protected signing workflow instead. The DIY script does not build or publish production beacon images.

## Firmware targets

Every shipping target uses the same detector engine and honors the same per-category settings. The difference is the hardware and where alerts go.

- **OUI-Spy** is a single-radio XIAO ESP32-S3 build that streams detections to either phone app.
- **Mesh-Detect** is the same single-radio detector with an additional serial uplink to a Heltec V3 running Meshtastic. Messages use labels such as `ALPR camera detected` and `Drone detected`. It also pairs with the phone app, and can add the phone's location to Meshtastic alerts while connected.
- **the beacon rev-A and rev-B** use a dedicated nRF52840 for continuous Bluetooth scanning while the ESP32-S3 handles Wi-Fi and the app link. The two revisions require different ESP32-S3 images.

Wiring and Meshtastic setup are in [docs/mesh-setup.md](docs/mesh-setup.md).

## How the project is organized

```text
firmware/
├── platformio.ini            # shipping, capture, and bench build environments
├── lib/acab_core/            # shared detectors, scanner, BLE service, and OTA logic
├── src/beacon-board/         # app-connected OUI-Spy and beacon entry point
├── src/mesh-detect/          # Meshtastic entry point
├── src/odid-sim/             # bench Remote ID simulator
└── tools/                    # host tests, drift checks, capture, and release tooling

ios/                          # native iPhone app and Live Activity/widget extension
android/                      # native Android app, Live Mode service, and widget
web/                          # browser flashers and release manifests
docs/                         # protocol, signatures, evidence, and mesh wiring
```

The companion nRF firmware and the beacon hardware design, PCB, enclosure, and manufacturing files are not published in this repository.

## Where things stand

The current source version is **2.0.6** for the ESP32-S3 firmware and both phone apps. Public app and firmware distribution can lag the source tree.

The detector, Meshtastic path, native apps, and firmware update flows have been exercised on real hardware. Retail beacon hardware is still coming soon. Detection depends on known, defensible radio signatures, so field capture and ground-truth validation remain ongoing work.

ESP32-S3 updates verify a signed image on the board and use a health-confirmation rollback path. On the dual-radio beacon, a combined update installs the nRF package first, then the ESP32-S3 image. The phone verifies the nRF package before transfer; the stock nRF bootloader itself provides CRC validation rather than the ESP32-S3's on-device signature check. Triggering that update also requires the encrypted app session and the physical power-on authorization window. The combined sequence has completed successfully from both iPhone and Android test devices.

Still on the list:

- bring the iPhone app from TestFlight to a public App Store release
- publish current signed 2.0.6 recovery images for both board revisions before the retail launch
- replace the development OTA key with a production key, keep it offline, and back it up securely before the retail launch
- field-validate newer capture candidates before promoting any of them into production detection
- keep the signature evidence, apps, firmware, and public documentation in sync as real-world gear changes

## Licensing

The project-owned **application and ESP32-S3 firmware code** published in this repository is licensed under [Apache-2.0](LICENSE). Bundled third-party components retain their own licenses, including the OFL-1.1 app fonts and BSD-licensed Nordic DFU libraries. See [CREDITS.md](CREDITS.md), the vendored license files, and each dependency's distribution terms.

The **companion nRF firmware, beacon hardware design, PCB layout, enclosure, manufacturing files, product name, and trademarks are not included in that license** unless explicitly stated otherwise. Apache-2.0 here covers the published code, not the physical product or the name it ships under.

Apache-2.0 carries obligations that travel with the code. Keep the applicable [LICENSE](LICENSE) and [NOTICE](NOTICE) material with any firmware-bearing product and with any app distribution you build from this source. Full app distributions must also carry the notices required by their bundled third-party components.

Worth stating plainly, because the license is sometimes read as covering more than it does: nothing here is a defense against a compatible clone board. Apache-2.0 is a permissive code license and is not the instrument for that. Preventing clones is a trademark, patent, hardware-design, and distribution-strategy question, and it is answered outside this repository or not at all.

## Thanks to

- The **Colonel Panic OUI-Spy** ecosystem, whose compatible hardware this runs on and whose earlier work pointed the way.
- Remote ID decoding from [opendroneid-core-c](https://github.com/opendroneid/opendroneid-core-c) under Apache-2.0.
- Flock signature research from the [DeFlock](https://deflock.me) community and the independent researchers cited in [docs/signatures.md](docs/signatures.md).

All Cameras Are Beacons is an independent project and is not affiliated with, endorsed by, or sponsored by Colonel Panic. "OUI-Spy" and "Mesh-Detect" are Colonel Panic's product names, used here only to identify compatible hardware.
