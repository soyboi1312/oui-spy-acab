import ActivityKit
import Foundation

/// Live Activity model for a "Drive mode" detection session, shown in the Dynamic
/// Island and on the Lock Screen (and, on iOS 26+, mirrored to the CarPlay Dashboard).
///
/// Compiled into BOTH the app and the widget extension. Deliberately dependency-free
/// and Color-free: the widget maps each bucket to a symbol/tint with its own tokens,
/// so we never drag the app's `DeviceType`/`ACABTheme` (which pull SwiftUI `Color`)
/// into the extension. The six buckets mirror the dashboard tiles exactly
/// (ALPR = flockCamera + flockRaven, drone, body cam, tracker, glasses, camera - `cameras` joined
/// them 2026-07-31, see ContentState below); there is no police bucket because the retired
/// firmware `t=6` has no `DeviceType` raw value. The decoder does NOT drop it: Detection's
/// init(from:) deliberately files an unrecognized `t` as `.unknown` so this platform never hides a
/// row Android shows; `.unknown` stays off these surfaces because it has no
/// `DeviceType.widgetCategoryKey`, the gate `recomputeLiveCounts` filters on
/// (`onDriveSurface` only gates the escalated first-sighting push).
struct DetectionActivityAttributes: ActivityAttributes {
    typealias ContentState = DetectionState

    /// Static for the whole session.
    let deviceName: String
    let sessionStart: Date

    /// Live counts, pushed by the app as detections arrive. ~4 ints + 2 short
    /// strings, far under ActivityKit's 4 KB ContentState limit.
    struct DetectionState: Codable, Hashable {
        var alpr: Int          // flockCamera + flockRaven
        var drones: Int
        var bodyCams: Int
        var trackers: Int
        var glasses: Int
        var cameras: Int       // network cameras; only ever nonzero when the opt-in is on
        var lastKind: String   // "ALPR" / "DRONE" / "BODY CAM" / "TRACKER" / "GLASSES" / ""
        var lastSeen: Date
        var connected: Bool    // false -> show "Reconnecting…" instead of a frozen count
        var redact: Bool       // hide counts on the Lock Screen banner (user setting, ships OFF;
                               // decode + placeholder fall back to true only as a fail-private
                               // stance for payloads that predate or lack the field)

        /// WidgetCategory rawValues for the detectors the BOARD currently has switched on, or nil
        /// when no status has arrived yet.
        ///
        /// OPTIONAL ON PURPOSE. A plain array cannot tell "no status yet" from "every detector is
        /// off", and those need opposite handling: unknown falls back to the historical five so the
        /// surface is never blank, while all-off must draw NOTHING, because five phantom columns
        /// advertising coverage that is not running is the exact bug this whole change set exists
        /// to fix. Collapsing them also left the headline total summing six buckets while the
        /// fallback drew five.
        ///
        /// WHY (2026-07-31): the buckets used to be a fixed five, which made a "0" ambiguous in
        /// the worst way. A zero under an ENABLED detector is real information ("watching, found
        /// nothing"). A zero under a DISABLED one is a lie by omission: it implies coverage the
        /// board is not providing. The user hit exactly this, reading GLASS 0 / TRACK 0 / BODY 0
        /// on a drive where those detectors were off.
        ///
        /// Driving the columns off the board's own toggles fixes both, and dissolves the network
        /// camera special case: it was hardcoded out because it is opt-in and "would dilute the
        /// drive-mode buckets", but an opt-in category that only appears once you opt in dilutes
        /// nothing. nil means "unknown" (no status yet) and falls back to the historical five;
        /// [] means every detector is genuinely off and renders no columns at all.
        var enabled: [String]?

        /// Decoded with defaults so an activity STARTED BY A PREVIOUS BUILD still decodes.
        /// ActivityKit hands back the ContentState it persisted; `cameras` and `enabled` were
        /// added 2026-07-31, and synthesised Codable would have thrown `keyNotFound` on that
        /// older payload, which is exactly the path adoptExisting() takes on launch. The result
        /// would have been a live drive-mode activity the app could no longer adopt or end.
        init(alpr: Int, drones: Int, bodyCams: Int, trackers: Int, glasses: Int, cameras: Int,
             lastKind: String, lastSeen: Date, connected: Bool, redact: Bool, enabled: [String]?) {
            self.alpr = alpr; self.drones = drones; self.bodyCams = bodyCams
            self.trackers = trackers; self.glasses = glasses; self.cameras = cameras
            self.lastKind = lastKind; self.lastSeen = lastSeen
            self.connected = connected; self.redact = redact; self.enabled = enabled
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            alpr     = try c.decodeIfPresent(Int.self, forKey: .alpr) ?? 0
            drones   = try c.decodeIfPresent(Int.self, forKey: .drones) ?? 0
            bodyCams = try c.decodeIfPresent(Int.self, forKey: .bodyCams) ?? 0
            trackers = try c.decodeIfPresent(Int.self, forKey: .trackers) ?? 0
            glasses  = try c.decodeIfPresent(Int.self, forKey: .glasses) ?? 0
            cameras  = try c.decodeIfPresent(Int.self, forKey: .cameras) ?? 0
            lastKind = try c.decodeIfPresent(String.self, forKey: .lastKind) ?? ""
            lastSeen = try c.decodeIfPresent(Date.self, forKey: .lastSeen) ?? Date()
            connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? true
            redact   = try c.decodeIfPresent(Bool.self, forKey: .redact) ?? true
            enabled  = try c.decodeIfPresent([String].self, forKey: .enabled)   // absent -> nil = unknown
        }

        /// Sum of the buckets actually RENDERED, not of every bucket counted.
        ///
        /// The columns follow `enabled`, so an unfiltered sum let the headline exceed the sum of
        /// the visible tiles: a drive with the tracker detector off but tracker rows still in the
        /// store showed "7" above columns adding to 4. Falls back to summing everything when
        /// `enabled` is unknown, which is exactly when the UI also falls back to all five.
        var total: Int {
            // nil = no status yet. Sum exactly the FALLBACK column set (the historical five), not all
            // six: the tiles fall back to five, so summing six here made the headline exceed the sum
            // of what is drawn, which is the bug this property was introduced to fix.
            guard let enabled else { return alpr + drones + bodyCams + trackers + glasses }
            var n = 0
            for key in enabled {
                switch key {
                case "ALPR":    n += alpr
                case "DRONE":   n += drones
                case "BODY":    n += bodyCams
                case "TRACKER": n += trackers
                case "GLASSES": n += glasses
                case "CAMERA":  n += cameras
                default:        break
                }
            }
            return n
        }

        static let empty = DetectionState(alpr: 0, drones: 0, bodyCams: 0, trackers: 0, glasses: 0,
                                          cameras: 0, lastKind: "", lastSeen: .now,
                                          connected: true, redact: true, enabled: nil)
    }
}

/// The category breakdown the medium home-screen widget draws, and the single source of truth for
/// its App Group keys.
///
/// It lives in Shared/ because the widget target compiles only `BeaconsWidget/` plus this file and
/// DriveModeIntents (see project.yml). DeviceType.swift is app-only, so the widget cannot map a
/// detection type itself; the app does that mapping (DeviceType.widgetCategoryKey) and writes one
/// scalar per key, and the widget reads them back by the same key.
///
/// Six categories, matching the Status and Log screens. As of 2026-07-31 the Live Activity
/// tracks the same six: it used to omit network cameras on the grounds that they are opt-in and
/// "would dilute the drive-mode buckets", but now that the Live Activity renders only the
/// detectors the board actually has ON (DetectionState.enabled), an opt-in category simply does
/// not appear until you opt in, so there is nothing left to dilute.
public enum WidgetCategory: String, CaseIterable {
    case alpr    = "ALPR"
    case drone   = "DRONE"
    case body    = "BODY"
    case tracker = "TRACKER"
    case glasses = "GLASSES"
    case camera  = "CAMERA"

    /// App Group key holding today's count for this category.
    public var defaultsKey: String { "w_c_" + rawValue }

    /// SF Symbol, matching each type's glyph in the app.
    public var symbol: String {
        switch self {
        case .alpr: return "camera.fill"
        case .drone: return "airplane"
        case .body: return "person.fill.viewfinder"
        case .tracker: return "dot.radiowaves.left.and.right"
        case .glasses: return "eyeglasses"
        case .camera: return "web.camera.fill"
        }
    }
}
