# app guide

the iPhone and Android apps connect to the beacon, OUI-Spy, or Mesh-Detect and show what the board hears. live detection requires a board; sample data and your saved Log remain available without one. see the [project overview](../README.md) for supported hardware and detection limits.

install from the [App Store](https://apps.apple.com/us/app/beacons-surveillance-scanner/id6781841861) for iOS 18 or newer, or [Google Play](https://play.google.com/store/apps/details?id=tech.soyboi.beacons) for Android 8 or newer. both apps currently use English. developer instructions are in [ios/README.md](../ios/README.md) and [android/README.md](../android/README.md).

## try it or connect a board

tap **See how it works** to explore six fictional detections. sample settings do not configure hardware, and sample rows never enter your real Log. tap **Exit sample data** to restore your saved data and settings. the sample walkthrough does not replace the orientation shown after your first real connection.

to connect:

1. power the board and keep it near your phone, with Bluetooth on.
2. grant the requested connection access, tap **Scan for beacons**, choose the board, and approve the system pairing prompt.
3. finish the walkthrough and review the permission and readiness prompts.

connection needs Bluetooth access on iPhone, Nearby devices on Android 12 or newer, or Location on Android 8 through 11. newer Android versions and iPhone let you decline Location and still detect and keep a Log. location adds observation pins and place mutes; iPhone also requires it to start Live Mode. Android Live Mode does not request background Location.

make the first pairing in trusted surroundings: an unowned board accepts its first phone at any time. already-bonded phones can reconnect normally. a new phone can pair only during the two-minute window after a physical power-on. turn the board off and on to reopen it; a firmware-update restart does not reopen the window.

## read the results

- **Status** counts devices heard in roughly the last 45 seconds. tap a category for its filtered Log, or its detector setting when disabled.
- **Log** keeps sightings on your phone while disconnected. filter rows, inspect match evidence and signal history, or export the rows you are viewing as CSV or GPX.
- **Map** combines located sightings with an optional community-mapped camera layer.
- **Beacon** controls detector categories, alert behavior, radios, offline buffering, firmware updates, and setup readiness.

most map pins show where your phone heard a signal, using its strongest sighting, rather than the device's exact location. Remote ID drones can supply aircraft coordinates and sometimes operator coordinates; vendor-only drone matches do not provide those positions. community-mapped cameras are a separate dataset. a missing pin does not prove that no camera exists.

the confidence percentage describes the specificity of the matching evidence, not signal strength. open a detection for identifiers, first and last sightings, location context, and why it matched. weak vendor matches need confirmation. tracker details can show **Seen with you** evidence from the current app session; a sighting or repeated nearby presence is not a stalking verdict.

## watch or mute a device

star a detection to watch that exact device. open a detection to mute it permanently, for 1 hour, for 24 hours, or within 50 meters of a saved place. manage names, stars, and mutes under **Beacon**. muted history remains in the Log with a **MUTED** label.

permanent mutes are copied to the board and silence that device's alerts with the phone away. timed and place mutes depend on the connected phone; the board can still sound according to its alert setting. stars and mutes follow an exact hardware address, so a device that rotates addresses may appear again.

## choose alerts

**buzzer** uses the board's speaker. **vibrate** mutes its detection sounds and uses category-specific phone haptics; glasses use a double tap and body cams use a repeating pattern. **silent** suppresses those detection alerts. iPhone haptics work while the app is open and defer to Focus when Focus status access is allowed. Android haptics defer to Do Not Disturb.

vibrate and silent also suppress the startup jingle. deliberate shutdown and battery-model press-and-hold start cues can still sound; master volume at zero silences those too. lights are controlled separately. tracker-category detections never beep on the board, including when starred. a star adds watched-device alerts only when no built-in signature matches.

per-category phone notifications are separate from board alert mode. every notification category starts off; enable the ones you want under **Beacon** and grant notification permission when requested. system notification settings can still prevent delivery or sound.

## Live Mode and widgets

Live Mode shows the nearby-now count on supported system surfaces. it starts enabled after first setup, subject to permissions and operating-system availability. detection and the Log still work if it is unavailable or switched off.

- iPhone uses a Live Activity on the Lock Screen and Dynamic Island. Location is required for background reliability.
- Android uses an ongoing notification or Live Update where supported. Android 13 or newer requires notification permission for that surface.

counts appear on the Lock Screen by default. the hide-counts setting under **Beacon** hides the iPhone Lock Screen count, but Dynamic Island, Watch, and CarPlay counts remain visible. iPhone detection-alert previews follow the system's **Show Previews** setting. on Android, hiding counts also removes the status-bar count and category details from locked detection notifications.

add the home-screen widget through your system's widget picker. it shows today's detection total and connection state, with the latest hit and category breakdown where space permits. its daily total differs from Live Mode's recent count. Live Mode can be toggled from Control Center on iPhone or Quick Settings on Android. supported setups can show compact Live Activities in CarPlay and Apple Watch Smart Stack, or the Android widget in compatible car hosts. these are system-provided views, not dedicated car or watch apps.

## accessibility and your data

key controls and status surfaces include VoiceOver or TalkBack descriptions, and layouts support larger text. the palette follows supported system contrast settings; **Beacon > Display > always use higher contrast** forces higher contrast on.

offline buffering is optional and encrypted, but the enabled board stores its key too, so it is not protection against forensic access to a captured board. offline pins may use the phone's last shared fix; they do not track the board's movement. the board also advertises a fixed Bluetooth address, allowing observers to correlate it over time. see the [BLE privacy and buffer details](ble-protocol.md).

exports can include observation, aircraft, and operator locations. review them before sharing. detections are not automatically uploaded; map tiles, firmware updates, and the optional camera dataset require ordinary network requests. see the [privacy policy](../web/privacy.html), [getting-started guide](https://soyboi.tech/getting-started), or [FAQ](https://soyboi.tech/faq) for more help.
