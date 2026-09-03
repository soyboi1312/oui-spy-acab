# radio coverage

beacons can recognize a device only when it receives a supported broadcast. match confidence describes the evidence in a received signal; radio coverage describes the opportunity to receive it. a quiet screen does not establish that you are unwatched.

## Wi-Fi coverage

the ESP32-S3 listens on **2.4 GHz only**. it cannot hear 5 GHz traffic, and it listens to one Wi-Fi channel at a time.

all shipping boards use the same channel-hopping sequence. it returns to channel 6 between visits to the other channels to favor brief Wi-Fi Remote ID broadcasts:

| channel | slots per sweep | nominal share of the active sweep |
|---|---|---|
| 6 | 12 of 24 | 50 percent |
| each of 1–5 and 7–13 | 1 of 24 | about 4.2 percent |

these are scheduling shares, not reception probabilities. a camera broadcasting on channel 11 during a brief drive-by can be missed while the scanner listens elsewhere. interference, range, obstructions, and the transmitter's timing also affect reception.

battery-saver eco mode inserts **3, 7, or 15 seconds** with Wi-Fi reception disabled between sweeps. zero disables that extra pause. this trades Wi-Fi coverage for runtime without pausing Bluetooth scanning. diagnostic capture builds ignore eco mode so it cannot create intentional gaps in a capture.

the schedule and eco behavior are defined by `WIFI_HOP_SEQ`, `wifiHopTask`, and `acabScannerSetWifiEco` in [acab_scanner.cpp](../firmware/lib/acab_core/acab_scanner.cpp).

## Bluetooth coverage

- **OUI-Spy and Mesh-Detect** share the ESP32-S3 radio between Bluetooth scanning, Wi-Fi, and the phone link. the configured Bluetooth scan window is 67/131 of each interval, about **51 percent**. there are also short pauses between scan runs, so this is not a measured guarantee of listening time.
- **the dual-radio beacon** gives Bluetooth scanning its own nRF52840, configured to scan continuously while enabled. it does not pause for the ESP32-S3's Wi-Fi channel hops. continuous scanning still does not guarantee that every broadcast arrives or produces a detection.

the single-radio settings and scan loop are in `acabScannerBegin` and `bleScanTask` in [acab_scanner.cpp](../firmware/lib/acab_core/acab_scanner.cpp). the dual-radio selection is defined by `ACAB_DUAL_RADIO` in [platformio.ini](../firmware/platformio.ini) and `setup` in [main.cpp](../firmware/src/beacon-board/main.cpp).

return to [how much does it actually hear?](../README.md#how-much-does-it-actually-hear).
