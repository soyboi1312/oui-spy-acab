# Credits and provenance

All Cameras Are Beacons grew out of the OUI-Spy and Flock-detection community. This
file records where the detection comes from, the public sources behind the
signatures, the third-party components, and the project's own work, so the
lineage stays visible.

## Detection sources

- **Flock Safety + Raven detection** (`firmware/lib/acab_core/flock_detect.*`):
  the MAC OUI, the `Flock-` SSID, advertised-name patterns, and the BT
  manufacturer ID are re-derived from public data, the IEEE OUI registry, the
  Bluetooth SIG assigned numbers, independent Flock research (ryanohoro, CEHRP,
  GainSec), the **deflock.me** community, and our own field captures. Each entry's
  source is documented in `docs/signatures.md`.
- **Body-cam detection** (`firmware/lib/acab_core/axon_detect.*`): the Axon OUI is
  from the IEEE registry, the `BWC DEVICE` payload is our own field capture, and the
  Utility "BodyWorn Remote" name signature is a field observation contributed by the
  community `nite-oui-collection` (@NitekryDPaul). Public facts only; sources in
  `docs/signatures.md`.
- **Drone Remote ID detection** (`firmware/lib/acab_core/drone_detect.*`): our own
  classifier for the public **ASTM F3411 / OpenDroneID** broadcast formats, the
  Service-Data UUID 0xFFFA, the NAN multicast address, and the beacon vendor IEs
  are all defined in the standard.
- **OpenDroneID decoder** (`firmware/lib/acab_core/opendroneid/`): vendored from
  **opendroneid/opendroneid-core-c**, licensed **Apache-2.0** (the full license is
  preserved in `firmware/lib/acab_core/opendroneid/LICENSE`).

This project grew out of the **OUI-Spy** ecosystem: it runs on Colonel Panic's
OUI-Spy and Mesh-Detect hardware, and earlier releases of these detectors began as
ports of `colonelpanichacks/oui-spy` and `colonelpanichacks/oui-spy-unified-blue` before the
signatures were re-sourced and the classifiers re-derived from the public references
above.

## Original to this project

The Axon body-cam detector, the BLE item-tracker detector, the recording-glasses
detector, the network-camera detector, the Motorola-gear detector, the shared
`acab_core` engine structure, the encrypted BLE GATT protocol, the native iOS and
Android apps (written from scratch, not derived from any upstream companion app), the
Meshtastic uplink, and the web flasher pages are original to All Cameras Are Beacons.
The flasher's flashing engine is the vendored **ESP Web Tools** bundle (Apache-2.0,
see below), not our code.

## A note on licensing

Two third-party *sources* are vendored into this repo. The first is
opendroneid-core-c, which is cleanly Apache-2.0; its license travels with the main
vendored copy at `firmware/lib/acab_core/opendroneid/` (the second copy for the
host-side simulator at `firmware/src/odid-sim/` carries SPDX Apache-2.0 headers in
each file instead of a separate LICENSE). The second is the compiled **ESP Web
Tools** flasher bundle at `web/vendor/esp-web-tools/` (Apache-2.0; the bundle also
compiles in Lit, BSD-3-Clause, plus Material Web, esptool-js, and the Improv WiFi
SDK, all Apache-2.0). Minification strips its per-file license headers, so the full
license text is kept alongside the bundle at `web/vendor/esp-web-tools/LICENSE`, and
the soyboi.tech site repo carries the same license file next to its identical copy.
The two OFL-1.1 typefaces bundled with the apps and the website are covered in the
Fonts section below. The firmware also links three permissively-licensed
libraries that are pulled at build time rather than vendored here: NimBLE-Arduino
(Apache-2.0), ArduinoJson (MIT), and Adafruit SPIFlash (MIT); their notices are in
`NOTICE`. The WiFi-promiscuous plus NimBLE concurrency approach was informed by the
sky-spy project (architecture only, no code). Everything else, the detection
signatures, the classifiers, the `acab_core` engine, the BLE GATT protocol, the apps,
the Meshtastic uplink, and the web flasher pages (which drive the vendored ESP Web
Tools bundle above), is this project's own work, built from the
public references in `docs/signatures.md`. Earlier releases ported detection code from
`colonelpanichacks/oui-spy`, `colonelpanichacks/oui-spy-unified-blue`, and `flock-you`; those
signatures have since been re-sourced from public registries and the classifiers
re-derived from public standards, so the project no longer carries their
upstream detection code.

`flock-you` added an [MIT license](https://github.com/colonelpanichacks/flock-you/blob/0793fba16d426cdb8a26440dc64a173b0bfa40f9/LICENSE)
on [2026-07-29](https://github.com/colonelpanichacks/flock-you/commit/0793fba16d426cdb8a26440dc64a173b0bfa40f9).
Its earlier lack of a license is historical, not its current status. This records
the license change without reassessing earlier releases or the licenses of the
other OUI-Spy repositories.

## Fonts

Both apps and the website use two typefaces, each licensed under the **SIL Open Font
License 1.1**, which permits free commercial use, bundling, and embedding:

- **Space Grotesk**, copyright 2020 The Space Grotesk Project Authors
  (florian karsten typefaces, github.com/floriankarsten/space-grotesk), OFL-1.1.
- **JetBrains Mono**, copyright 2020 The JetBrains Mono Project Authors
  (JetBrains, github.com/JetBrains/JetBrainsMono), OFL-1.1.

The OFL's only redistribution condition is that this copyright and license notice
accompany the font files; this section satisfies it. The fonts are not sold on their
own, and no Reserved Font Name is used for anything modified.

## Keeping signatures fresh

Detection signatures drift as vendors change hardware. Run

    python3 firmware/tools/check-signature-drift.py

periodically to watch for a new opendroneid-core-c release worth re-vendoring. It no
longer diffs the Flock OUI table against any third-party curated list (that table uses
our field captures and Flock's IEEE assignment); it only reports and never changes anything.
