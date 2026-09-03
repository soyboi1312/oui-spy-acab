import SwiftUI

/// What this app looks for. Raw values match the firmware's `t` field (see
/// docs/ble-protocol.md). `nearbyDevice` (t=7) is Desert mode's catch-all. The
/// firmware no longer emits a separate police-gear type (t=6) - Motorola/LE gear
/// now reports as a body cam.
enum DeviceType: Int, CaseIterable, Identifiable, Codable {
    /// A wire type this build doesn't recognize: a future `t` from firmware newer than the app
    /// (OTA ships board updates independently of app releases), or the retired t=6 off an old
    /// build still in the field. Shown as a generic row instead of being dropped, so this
    /// platform never silently hides a detection the other one shows. Mirrors Android's
    /// UNKNOWN(0) fallback in DeviceType.from().
    case unknown     = 0
    case flockCamera = 1
    case flockRaven  = 2
    case axonBodyCam = 3
    case drone       = 4
    case tracker     = 5
    case nearbyDevice = 7   // Desert mode: any device in range
    case watched      = 8   // user-starred: alert on this exact MAC even with no signature match
    case recordingGlasses = 9   // smart / camera glasses (Ray-Ban/Oakley Meta, Snap, Luxottica) by BLE company ID
    case networkCamera = 10  // branded IP-camera OUI on host WiFi (Hikvision/Dahua/etc.); opt-in, WiFi data-frame source MAC

    var id: Int { rawValue }

    /// Key into `faq-content.json`'s `relatedHelp` map. Matches the Android enum's SCREAMING_CASE
    /// names, because the JSON is shared and Android keys off `name` directly.
    ///
    /// Every real key now has a relatedHelp entry (BODY_CAM and GLASSES got theirs 2026-08-10;
    /// the earlier reserved-on-purpose state is over), and check-signature-drift.py FAILS the
    /// build if a real key ever loses its entry, so add the JSON row in the same commit as a new
    /// category. nearbyDevice and unknown return "", which means NEVER a panel: neither is a
    /// category a user can have a question about (nearbyDevice is Desert mode's firehose,
    /// unknown is a parse fallback).
    var faqKey: String {
        switch self {
        case .flockCamera:       return "FLOCK_CAMERA"
        case .flockRaven:        return "FLOCK_RAVEN"
        case .axonBodyCam:       return "BODY_CAM"
        case .drone:             return "DRONE"
        case .tracker:           return "TRACKER"
        case .watched:           return "WATCHED"
        case .recordingGlasses:  return "GLASSES"
        case .networkCamera:     return "NETWORK_CAMERA"
        case .nearbyDevice, .unknown: return ""
        }
    }

    var label: String {
        switch self {
        case .flockCamera: return "ALPR Camera"
        case .flockRaven:  return "Flock Raven"
        case .axonBodyCam: return "Body Camera"
        case .drone:       return "Drone"
        case .tracker:     return "Tracker"
        case .nearbyDevice:return "Nearby Device"
        case .watched:     return "Watched device"
        case .recordingGlasses: return "Recording glasses"
        case .networkCamera: return "Network camera"
        case .unknown:     return "Unknown"
        }
    }

    var shortTag: String {
        switch self {
        case .flockCamera: return "ALPR"
        case .flockRaven:  return "RAVEN"
        case .axonBodyCam: return "BODY CAM"
        case .drone:       return "DRONE"
        case .tracker:     return "TRACKER"
        case .nearbyDevice:return "NEARBY"
        case .watched:     return "WATCHED"
        case .recordingGlasses: return "GLASSES"
        case .networkCamera: return "NET CAM"
        case .unknown:     return "UNKNOWN"
        }
    }

    /// SF Symbol for lists, map markers, and detail headers.
    var symbol: String {
        switch self {
        case .flockCamera: return "camera.fill"
        case .flockRaven:  return "waveform"
        case .axonBodyCam: return "person.fill.viewfinder"
        case .drone:       return "airplane"
        case .tracker:     return "dot.radiowaves.left.and.right"
        case .nearbyDevice:return "antenna.radiowaves.left.and.right"
        case .watched:     return "star.fill"
        case .recordingGlasses: return "eyeglasses"
        // Wall/IP surveillance-camera glyph, distinct from flockCamera's plain camera.fill so
        // a network camera reads as a fixed CCTV/NVR install rather than a handheld camera.
        case .networkCamera: return "web.camera.fill"
        case .unknown:       return "questionmark.circle"   // Android's HelpOutline analog
        }
    }

    /// Category color: Flock = crimson, drone = amber, Axon = gray, tracker = teal, glasses = violet.
    var tint: Color {
        switch self {
        case .flockCamera, .flockRaven: return ACABTheme.flockTone
        case .drone:                    return ACABTheme.droneTone
        case .axonBodyCam:              return ACABTheme.axonTone
        case .tracker:                  return ACABTheme.trackerTone
        case .nearbyDevice:             return ACABTheme.sandTone   // desert sand
        case .watched:                  return ACABTheme.watchTone
        case .recordingGlasses:         return ACABTheme.glassesTone
        case .networkCamera:            return ACABTheme.netcamTone
        case .unknown:                  return ACABTheme.dim   // neutral, like Android's Acab.dim
        }
    }

    /// The category colour for TEXT and digits. Only crimson differs from `tint`: the fill
    /// accent measures under AA as text on the raised surface, so words in the Flock colour
    /// use ACABTheme.accentText. Fills, bars, rings and pins keep `tint`.
    /// Android twin: DeviceType.textTone() in Theme.kt.
    var textTint: Color {
        switch self {
        case .flockCamera, .flockRaven: return ACABTheme.accentText
        default:                        return tint
        }
    }

    /// Whether the drive-mode surfaces speak this bucket: the six counters, and only those.
    ///
    /// .networkCamera joined 2026-07-31. It was excluded while the Live Activity had a fixed five
    /// columns, because letting it set the "last ..." line would have named a category with no
    /// tile. Now that the columns follow the board's toggles it gets a tile exactly when the
    /// opt-in is on, so the reason is gone. LEAVING IT OUT WAS AN ACTIVE BUG for one revision:
    /// the same change started folding cameras into DetectionState.total, and the widget gates
    /// its footer on total > 0 while (in that revision) ingestDetection wrote lastLiveKind gated
    /// on onDriveSurface, so a camera-only drive rendered "last <blank> 2h ago" with an age
    /// measured from app launch. Today recomputeLiveCounts writes lastLiveKind, gated on
    /// widgetCategoryKey plus the board-enabled set; onDriveSurface only decides whether a
    /// first sighting escalates an immediate Live Activity push.
    ///
    /// .watched LEFT on 2026-08-26. It used to be here on the reasoning that a star pinging the
    /// drive surface is the point of starring, but nothing downstream ever honored that: a starred
    /// row has no widgetCategoryKey, so recomputeLiveCounts skips it before any bucket or
    /// lastLiveKind, and Android's DRIVE_CATS has no "WATCHED" either. Saying true here bought one
    /// live cost and no benefit - a first-ever starred device forced an escalated push carrying a
    /// ContentState that had not changed, spending the escalateMinGap budget a genuine ALPR or
    /// body-cam hit arriving in the next 1.5 s then had to wait out. A star is not silent: the
    /// firmware gives ACAB_WATCHED its own tone and DetectionNotifier lists it as a push category.
    /// Giving it a real column instead would mean inventing a label for a user-defined bucket on a
    /// surface whose columns are board toggles, which is the decision widgetCategoryKey already
    /// took the other way.
    ///
    /// Desert-mode .nearbyDevice still fills no tile and would make "last ..." meaningless.
    /// Mirrors Android DeviceType.onDriveSurface. The home widget is separate state and keeps
    /// all six categories regardless.
    var onDriveSurface: Bool {
        switch self {
        case .flockCamera, .flockRaven, .drone, .axonBodyCam, .tracker,
             .recordingGlasses, .networkCamera:
            return true
        case .nearbyDevice, .watched, .unknown:
            return false
        }
    }

    /// Coarse category label for the dashboard tiles and map filters.
    var category: String {
        switch self {
        case .flockCamera, .flockRaven: return "ALPR"
        case .drone:                    return "DRONE"
        case .axonBodyCam:              return "BODY CAM"
        case .tracker:                  return "TRACKER"
        case .nearbyDevice:             return "NEARBY"
        case .watched:                  return "WATCHED"
        case .recordingGlasses:         return "GLASSES"
        case .networkCamera:            return "CAMERA"
        case .unknown:                  return "UNKNOWN"
        }
    }

    /// Vendor behind the hardware, shown in the detail view. ALPR gear is Flock
    /// Safety; the rest aren't tied to one brand.
    var brand: String? {
        switch self {
        case .flockCamera, .flockRaven: return "Flock Safety"
        default:                        return nil
        }
    }

    /// Not field-verified yet - the UI flags these specially. Glasses is the last one:
    /// body cam graduated on 2026-07-19 when the Axon "BWCDEVICE" service-data tag
    /// (confidence 90) was field-validated against a visually confirmed scene. Keep in
    /// step with Android DeviceType.isExperimental and the EXP counter on both platforms.
    var isExperimental: Bool { self == .recordingGlasses }

    /// The noun the "experimental detector" banner names, so that banner can never again
    /// describe a category other than the one on screen. It hardcoded "Body-cam signatures"
    /// and kept saying so after body cam graduated on 2026-07-19 and isExperimental moved to
    /// glasses, which put a body-cam warning on every glasses detection (seen in the field
    /// 2026-07-31). Deriving it from the type is what stops that recurring.
    var experimentalNoun: String {
        switch self {
        case .recordingGlasses: return "Recording-glasses"
        case .axonBodyCam:      return "Body-cam"
        case .networkCamera:    return "Network-camera"
        case .flockCamera, .flockRaven: return "ALPR"
        case .drone:            return "Drone"
        case .tracker:          return "Tracker"
        case .nearbyDevice, .watched, .unknown: return "These"
        }
    }

    /// First line of the "Confirm it" checklist: what to physically look for to verify THIS
    /// kind of device. Was one hardcoded ALPR string ("pole-mounted camera, solar panel, small
    /// antenna"), which is the wrong instruction on every other category and was showing on
    /// glasses detections in the field 2026-07-31. A checklist that names the wrong object is
    /// worse than none: it invites the user to confirm a false negative.
    var confirmPrompt: String {
        switch self {
        case .flockCamera, .flockRaven:
            return "Look around, pole-mounted camera, solar panel, small antenna?"
        case .axonBodyCam:
            return "Look around, anyone with a camera worn on the chest or shoulder?"
        case .recordingGlasses:
            return "Look around, anyone in glasses with a lens or LED in the frame?"
        case .networkCamera:
            return "Look around, a doorbell camera, or one under an eave or on a wall?"
        case .drone:
            return "Look up, anything hovering or circling?"
        case .tracker:
            return "Check your bag, pockets, and car for a tag that isn't yours."
        case .nearbyDevice, .watched, .unknown:
            return "Look around, anything nearby that could be transmitting?"
        }
    }

    /// Which home-screen-widget bucket this type falls into, or nil for types the widget does not
    /// break out. ALPR folds flockCamera + flockRaven the same way the Log and Status tiles do.
    /// nearbyDevice / watched are excluded on purpose: Desert rows are ambient noise, and a starred
    /// device is a user-defined bucket that would need its own label to mean anything.
    var widgetCategoryKey: String? {
        switch self {
        case .flockCamera, .flockRaven: return WidgetCategory.alpr.rawValue
        case .drone:                    return WidgetCategory.drone.rawValue
        case .axonBodyCam:              return WidgetCategory.body.rawValue
        case .tracker:                  return WidgetCategory.tracker.rawValue
        case .recordingGlasses:         return WidgetCategory.glasses.rawValue
        case .networkCamera:            return WidgetCategory.camera.rawValue
        case .nearbyDevice, .watched, .unknown: return nil
        }
    }
}

/// Which radio saw the device (firmware `s` field).
enum DetectionSource: Int, Codable {
    case ble = 0, wifi = 1, remoteID = 2
    var label: String {
        switch self {
        case .ble:      return "BLE"
        case .wifi:     return "WiFi"
        case .remoteID: return "Remote ID"
        }
    }
}

/// What made the device match (firmware `meth` field).
enum DetectionMethod: Int, Codable {
    case none = 0, oui, name, mfgID, serviceUUID, ssid, probe, remoteID
    case serviceData = 8   // ASCII tag in service data / 128-bit UUID (MAC-independent)
    case mfgSubtype  = 9   // decoded manufacturer-data subtype
    case watchlist   = 10  // exact-MAC user rule (starred device)
    var label: String {
        switch self {
        case .none:        return "unknown"
        case .oui:         return "OUI match"
        case .name:        return "device name"
        case .mfgID:       return "manufacturer ID"
        case .serviceUUID: return "service UUID"
        case .ssid:        return "SSID"
        case .probe:       return "wildcard probe"
        case .remoteID:    return "Remote ID"
        case .serviceData: return "service data"
        case .mfgSubtype:  return "manufacturer subtype"
        case .watchlist:   return "watchlist"
        }
    }
}
