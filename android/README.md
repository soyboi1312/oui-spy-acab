# All Cameras Are Beacons, Android

Native Kotlin + Jetpack Compose companion for the OUI-Spy ACAB board, the Android
counterpart to the iOS app in `../ios`. It talks to the same firmware over the
same encrypted BLE GATT service (`../docs/ble-protocol.md`).

The app is the free, open-source companion to the beacon (the sold hardware), and
still works with DIY XIAO builds. It surfaces what the beacon detects: body cams
on by default, mapped ALPR awareness, drones, recording glasses, opt-in BLE item
trackers and network cameras, and encrypted offline-buffer replay of hits logged
while your phone was away.

## Status

Working end to end. Done:
- Gradle/Compose project, runtime permissions, the full Crimson theme.
- BLE layer (`ble/AcabBleManager.kt`): scan by service UUID, connect, **bond**
  (the GATT service is encrypted as of firmware 0.2.2/0.2.3), request a **512-byte
  ATT MTU** (so the status + richer drone JSON fit one notify; config writes stay
  chunked well under the 512 B cap), subscribe to the detection + status notifies,
  parse the JSON, write config.
- Models (`model/Models.kt`) matching the firmware `t`/`s`/`meth` fields, including
  the dual-radio co-processor-alive flag (`co` -> `coAlive`); `DeviceScreen` shows a
  fault banner when it reads `false` (the beacon board's companion BLE scanner has
  gone silent, so its half of detection is dark).
- Four-tab UI: status, an osmdroid (OpenStreetMap) map, log, and device controls.
- Tap a detection for its detail card: a signal-strength history, first-seen and
  last-seen timestamps, and identifiers, with the chart greying out when a device
  goes stale. The phone's location is geotagged onto fixed-install hits.
- Firmware updates: the app checks a hosted version manifest (no Play release
  needed when firmware ships) and, on OTA-capable boards, pushes the update over
  Bluetooth with progress and safe rollback; older boards get pointed at the
  browser flasher. Proven on real hardware.

Still TODO:
- Getting onto the Play Store / F-Droid (see below).

## Build & run

You need **Android Studio** (it bundles the SDK, a JDK, and Gradle):

1. Android Studio, **Open**, select this `android/` folder.
2. Let it run Gradle sync (first sync downloads Gradle 8.13 + the SDK).
3. **Run on a physical phone.** The emulator has no Bluetooth, so BLE needs a real
   device with USB debugging on.
4. On first connect the phone prompts to pair ("just works", no passkey). Accept
   it; the bond is remembered after that.

From the command line, with a JDK 17+ on `JAVA_HOME` (on macOS, Android Studio's
bundled JBR at `/Applications/Android Studio.app/Contents/jbr/Contents/Home` works)
and the SDK on `ANDROID_HOME`:

```bash
./gradlew :app:assembleDebug
```

The installable APK lands at `app/build/outputs/apk/debug/app-debug.apk`; push it
to a plugged-in phone with `adb install -r app/build/outputs/apk/debug/app-debug.apk`.

`applicationId` = `tech.soyboi.beacons`, `minSdk` 26, `targetSdk` 36.

## Shipping a real APK

The debug build above is signed with a throwaway debug key, fine for your own phone
but not for sharing widely or for the Play Store. For a real release:

1. **Make a signing key once** and keep it safe (you reuse it for every update):
   ```bash
   keytool -genkey -v -keystore acab-release.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias acab
   ```
2. Point Gradle at it: add a `signingConfig` to `app/build.gradle.kts` that reads
   the keystore path and passwords from `~/.gradle/gradle.properties` or env vars,
   so no secrets land in git.
3. Build the artifact:
   - `./gradlew :app:assembleRelease` for a signed **APK** to sideload or hand out.
   - `./gradlew :app:bundleRelease` for an **AAB**, the format the Play Store wants.

Getting it onto the **Play Store** also needs a one-time **$25** Google Play
developer account, a store listing (a real icon, screenshots, description, privacy
policy), and a data-safety form. The listen-only, BLE-only design keeps that form
short, but the **ACAB** name may draw review scrutiny, same as on iOS.

## Notes

- Reflashing the board with **erase** wipes its bond; after that the phone must
  "Forget This Device" in Bluetooth settings and re-pair. Flash without erase to
  keep the pairing (same as iOS).
- The map uses osmdroid against OpenStreetMap tiles, so there is no Google Play
  Services dependency and no map API key to register for.
