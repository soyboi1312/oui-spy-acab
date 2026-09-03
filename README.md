# All Cameras Are Beacons

**beacons** recognizes supported surveillance devices from their Wi-Fi and Bluetooth broadcasts, then shows detections on your phone or sends alerts over Meshtastic. it runs on the beacon, our pocket dual-radio detector, and on Colonel Panic's OUI-Spy and Mesh-Detect hardware.

> **detection is passive.** shipping firmware does not probe, jam, spoof, control, or interfere with nearby devices. the board exchanges data with your phone over bonded, encrypted Bluetooth; Mesh-Detect also transmits alerts through its wired Meshtastic node.

## start here

- **want the beacon?** visit [Tindie](https://www.tindie.com/stores/soyboitech/) for hardware and [soyboi.tech](https://soyboi.tech) for pricing and availability.
- **need help?** read the [getting-started guide](https://soyboi.tech/getting-started), [app guide](docs/app-guide.md), or [FAQ](https://soyboi.tech/faq), or open a [GitHub issue](https://github.com/soyboi1312/all-cameras-are-beacons/issues).
- **trying it without hardware?** install the [iPhone app](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) or [Android app](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) and tap **See how it works** to explore fictional detections.
- **already have a board?** power it on, tap **Scan for beacons** in the app, choose the board, and approve pairing. the app walks you through setup and permissions. make your first pairing in trusted surroundings; see the [pairing guide](docs/app-guide.md#try-it-or-connect-a-board).
- **building OUI-Spy or Mesh-Detect?** use the [DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) or the [command-line instructions](#flashing-from-the-command-line).

**a compatible board is required for live detection.** sample mode and your saved Log remain available without one. the iPhone and Android apps are free.

<a id="the-beacon"></a>
<a id="firmware-targets"></a>

## supported hardware

every shipping target uses the same detector engine and per-category settings. the hardware determines radio coverage and where alerts go.

| hardware | radios | detection output |
|---|---|---|
| **the beacon, rev-A and rev-B** | dedicated nRF52840 Bluetooth scanner; ESP32-S3 for Wi-Fi and the app link | iPhone or Android app, onboard buzzer, optional encrypted offline logging |
| **OUI-Spy** | Seeed XIAO ESP32-S3 sharing one radio between Wi-Fi and Bluetooth | iPhone or Android app |
| **Mesh-Detect** | same single-radio XIAO build, plus a wired Heltec V3 running Meshtastic | phone app and mesh alerts, with optional phone location while connected |

the beacon is about the size of an AirPods case, uses USB-C power, and charges through the same port on the battery model. retail units are designed to arrive pre-flashed; pair with the app to choose detector categories, alerts, and optional location or offline logging. firmware updates are delivered through the app, with separate USB recovery images for each board revision.

see [mesh wiring and setup](docs/mesh-setup.md) for the Heltec connection and public or private channel options.

## what it detects

| category | radio | default | identification limits |
|---|---|---|---|
| **Flock cameras** (license-plate readers) | Bluetooth + Wi-Fi | on | supported names and SSIDs provide stronger evidence; vendor-prefix matches need confirmation |
| **Flock Raven** audio sensors | Bluetooth | on | matches field-captured Raven-specific services |
| **Remote ID drones** | Bluetooth + Wi-Fi | on | can include broadcast aircraft coordinates; the separate, opt-in vendor fallback may identify a controller |
| **body cams** (Axon and Utility BodyWorn) | Bluetooth + Wi-Fi | on | Axon's device tag is the strongest match; the broad Motorola vendor proxy is separate, opt-in, and weak |
| **item trackers** | Bluetooth | off | supported Find My, Find Hub, Tile, and SmartTag broadcasts; Find My and Find Hub require the separated state; no board buzzer alerts |
| **smart or recording glasses** | Bluetooth | on | eyewear-specific evidence is stronger; shared Meta identifiers can also belong to other hardware |
| **network cameras** | Wi-Fi | off | vendor-family matches can identify a camera, recorder, hub, or accessory |

the [signature reference](docs/signatures.md) lists supported manufacturers, evidence, confidence choices, and rejected matches. see also the [Axon notes](docs/axon.md) and [glasses research](docs/glasses.md). Remote ID decoding uses [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c).

diagnostic builds collect additional [capture candidates](docs/signatures.md#capture-only-alpr-vendor-prefix-candidates-206) for research; these are not production detections and never reach either phone app.

## limits and privacy

### how reliable is it?

a decoded Remote ID payload or device-specific signature is stronger evidence than a corporate radio-address prefix (OUI). an OUI identifies a registered vendor, not the exact product. shared chip suppliers are excluded where their identifiers would flag unrelated consumer gear.

tap a detection to see its method, confidence, and matching evidence. **confidence describes how specific the evidence is, not signal strength or a measured probability that a camera is present.** treat weak results as leads to verify.

### how much does it actually hear?

**2.4 GHz only; there is no 5 GHz radio.** silent, wired-only, and purely optical equipment without supported broadcasts stays invisible. Wi-Fi listens to one channel at a time, so brief transmissions can be missed; battery-saver mode adds further gaps. OUI-Spy and Mesh-Detect share radio time, while the beacon's dedicated Bluetooth scanner runs continuously during normal scanning.

a quiet screen means no supported broadcast was recognized while listening. **it does not mean you are unwatched.** see [radio coverage](docs/radio-coverage.md) for the channel schedule, duty cycles, and battery-saver tradeoffs.

### privacy

there are no accounts, analytics, third-party tracking, or automatic detection uploads. detections stay on your board and phone unless you explicitly export or contribute them. ordinary network requests load map tiles, firmware files, and the optional mapped-camera dataset; they do not include your detections.

optional location access lets the phone geotag sightings and send its fix to your board over the encrypted link. offline records can retain that location. exports can also contain observation and broadcast drone locations, so review them before sharing.

**the board itself can be tracked:** it advertises a fixed factory Bluetooth address so bonded iPhones can reconnect reliably. **offline encryption does not protect against forensic access to a captured board:** its key is stored on the board while buffering is enabled. read the [privacy policy](web/privacy.html) and [Bluetooth privacy details](docs/ble-protocol.md#peripheral-address-bonding-and-privacy) before relying on those protections.

## the phone apps

both native apps provide the same core views:

- **Status:** devices heard recently, grouped by category.
- **Map:** optional location context and a separate community-mapped camera layer.
- **Log:** saved detections, filters, signal history, matching evidence, and CSV or GPX export, available even while disconnected.
- **Beacon:** detector categories, alert settings, radios, offline buffering, firmware updates, and connection status.

**most detection pins mark where your phone heard the signal, not the device's exact position.** Remote ID drones can supply their own aircraft coordinates. the community camera layer is reference data, and a missing pin does not establish that no camera exists.

you can star or mute individual devices, enable phone notifications, and use Live Mode or home-screen widgets for quick counts. permanent mutes sync to the board; timed and place mutes depend on the connected phone. notification categories start off. both apps support screen readers, larger text, and higher contrast, and currently ship in English.

| platform | requirement | install | build from source |
|---|---|---|---|
| iPhone | iOS 18 or newer | [App Store](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) | [iOS README](ios/README.md) |
| Android | Android 8 or newer | [Google Play](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) | [Android README](android/README.md) |

the [app guide](docs/app-guide.md) covers pairing, platform permissions, sample mode, alerts and mutes, tracker evidence, Live Mode, widgets, and accessibility.

## flashing

### production beacon

use app-delivered firmware updates for normal operation. USB recovery is board-revision specific:

- [rev-A beacon flasher](https://soyboi.tech/flash.html)
- [rev-B beacon flasher](https://soyboi.tech/flash-revb.html)

**do not cross-flash revisions or use the DIY images on a production beacon.** the wrong image can leave the board needing USB recovery. each production page identifies whether a current recovery image is available.

### DIY OUI-Spy and Mesh-Detect

1. connect the XIAO ESP32-S3 to a computer with a data-capable USB-C cable.
2. open the [DIY flasher](https://soyboi1312.github.io/all-cameras-are-beacons/) in Chrome or Edge and choose the matching firmware.
3. select the board when prompted and let flashing finish.

the flasher requires desktop Web Serial support; Safari and Firefox are unsupported. [web flasher documentation](web/README.md) covers self-hosting and rebuilding its images.

### flashing from the command line

use PlatformIO when developing firmware. choose the upload command for your DIY board:

```bash
cd firmware
pio run -e oui-spy -t upload
# or, for Mesh-Detect:
pio run -e mesh-detect -t upload

pio device monitor -b 115200
```

[platformio.ini](firmware/platformio.ini) defines the shipping, capture, and bench environments. capture builds record nearby identifiers and raw payloads; keep those logs private and restore shipping firmware afterward. `odid-sim` is a bench-only Remote ID simulator.

<a id="how-the-project-is-organized"></a>

## developer documentation

| location | contents |
|---|---|
| [firmware/](firmware/) | shared detector engine, board entry points, tests, and release tools |
| [ios/](ios/) and [android/](android/) | native apps and system widgets |
| [web/](web/) | browser flashers and DIY release manifests |
| [docs/](docs/) | app guide, radio coverage, signature evidence, protocol, and mesh setup |

start with the [BLE protocol](docs/ble-protocol.md) for app integration, [signature reference](docs/signatures.md) for detector work, and [release guide](firmware/tools/RELEASE.md) for signing and publication checks. the companion nRF firmware and beacon hardware design files are not published in this repository.

## where things stand

the current source version is **2.0.7** for the ESP32-S3 firmware and both apps. public distribution can lag the source tree; check the app's firmware update screen and store listings for available releases.

the detector, mesh path, apps, and update flows have been exercised on real hardware. field validation remains ongoing, especially for capture candidates. update sequencing is documented in the [OTA protocol](docs/ble-protocol.md#firmware-update-ota), and the 2.0.7 transition requirements are in the [key-rotation guide](firmware/tools/RELEASE.md#ota-key-rotation).

## licensing

the project-owned **application and ESP32-S3 firmware code** published here is licensed under [Apache-2.0](LICENSE). bundled third-party components retain their own licenses; see [CREDITS.md](CREDITS.md) and their license files. keep the applicable [LICENSE](LICENSE), [NOTICE](NOTICE), and third-party notices with distributions.

the **companion nRF firmware, hardware design, PCB layout, enclosure, manufacturing files, product name, and trademarks are excluded** from that license unless explicitly stated otherwise.

## thanks to

- the **Colonel Panic OUI-Spy** ecosystem for compatible hardware and earlier work.
- [OpenDroneID](https://github.com/opendroneid/opendroneid-core-c) for Remote ID decoding.
- [DeFlock](https://deflock.me) and the independent researchers cited in the [signature reference](docs/signatures.md).

All Cameras Are Beacons is an independent project and is not affiliated with, endorsed by, or sponsored by Colonel Panic. "OUI-Spy" and "Mesh-Detect" are Colonel Panic's product names, used here only to identify compatible hardware.
