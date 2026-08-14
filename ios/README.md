# All Cameras Are Beacons

The iPhone app. It pairs with an OUI-Spy board over Bluetooth and shows you what
it's picking up as it happens. It's the free, open-source companion to the beacon
(the board we sell), and it works just the same with the DIY OUI-Spy and
Mesh-Detect XIAO builds. How it talks to the board is written up in
[../docs/ble-protocol.md](../docs/ble-protocol.md).

> You'll need a real iPhone to do anything useful with it. Bluetooth doesn't work
> in the iOS Simulator, so actually connecting to a board only happens on a
> physical phone. The app itself builds and runs in the Simulator if you just
> want to look around.

## Opening it in Xcode

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen), so it isn't stored in the repo.
First time through:

```bash
brew install xcodegen      # if you don't already have it
cd ios
xcodegen generate          # creates Beacons.xcodeproj
open Beacons.xcodeproj
```

Then in Xcode, pick your signing team (the Beacons target, under Signing &
Capabilities), plug in your iPhone, and press Run. The first run on a new phone
also needs Developer Mode turned on, under Settings → Privacy & Security →
Developer Mode, and you'll need to unlock the phone so Xcode can finish setting
it up.

Not a fan of XcodeGen? You can start a fresh SwiftUI app (iOS 18 or newer), drop
in everything under `Beacons/`, and add the Bluetooth and location usage
descriptions to Info.plist.

## What's inside

```
ios/Beacons/
├── ACABApp.swift            # the app entry point
├── Models/                  # the data: device types, detections, status
├── BLE/
│   ├── ACABProfile.swift    # the Bluetooth service + characteristic IDs
│   └── BLEManager.swift     # all the Bluetooth and location plumbing
└── Views/
    ├── Theme.swift          # the look: dark, mono type, crimson accent
    ├── Components.swift      # shared bits (wordmark, signal bars, radar, ...)
    ├── ConnectView.swift     # find and pick a board
    ├── DashboardView.swift   # the radar "what's around me" home screen
    ├── MapTabView.swift      # everything located, on a map
    ├── DetectionsView.swift  # the logbook, with CSV export
    ├── DetectionDetailView.swift
    └── SettingsView.swift    # the Beacon screen: radios, buzzer, firmware, about
```

## How it talks to the board

The app looks for a board advertising the ACAB service, subscribes to its
detection and status updates, and writes settings back when you flip a radio or
the buzzer. If you ever change the firmware's IDs or message format, update
`ACABProfile.swift` and the matching models so the two stay in step.

On connect the firmware negotiates a **512-byte ATT MTU** so the status and richer
drone records fit one notify; iOS decides the final value, and `BLEManager+OTA`
reads back `maximumWriteValueLength` for its chunk size rather than assuming 512.
Dual-radio beacon boards add a co-processor-alive flag (`co`) to the status JSON;
`SettingsView` shows a fault banner when it reads `false`, meaning the board's
companion BLE scanner has gone silent (its half of detection is dark).

## Where it's at

It's a working app: connect to a board, watch detections on a radar dashboard and
a map, browse and export a logbook, check the board's firmware version, and tune
its radios and buzzer. Firmware updates are built in: the app checks a hosted
manifest for the latest version (no App Store release needed when firmware ships)
and, on OTA-capable boards, pushes the update over Bluetooth with progress and a
safe rollback; older boards get pointed at the browser flasher.
