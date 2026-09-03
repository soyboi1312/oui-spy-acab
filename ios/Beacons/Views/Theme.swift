import SwiftUI
import UIKit
import Observation

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

// MARK: - Palette values

/// One sRGB colour with alpha, kept as plain numbers so the palette can be measured (WCAG
/// contrast in ContrastPaletteTests) without resolving a UIColor.
struct ACABTone: Equatable {
    let r: Double, g: Double, b: Double, a: Double

    init(_ hex: UInt32, alpha: Double = 1) {
        r = Double((hex >> 16) & 0xFF) / 255
        g = Double((hex >> 8)  & 0xFF) / 255
        b = Double(hex & 0xFF) / 255
        a = alpha
    }
    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    var uiColor: UIColor { UIColor(red: r, green: g, blue: b, alpha: a) }

    /// This tone composited over an opaque surface (alpha blending in sRGB space, which is
    /// how the renderer blends it and what the contrast measurement must therefore use).
    func over(_ bg: ACABTone) -> ACABTone {
        ACABTone(r: r * a + bg.r * (1 - a),
                 g: g * a + bg.g * (1 - a),
                 b: b * a + bg.b * (1 - a))
    }
}

/// The complete set of colour tokens for ONE contrast level. Two instances exist: `.normal`
/// (the Crimson cyber-noir look) and `.high` (what "increase contrast" resolves to). Every
/// ACABTheme colour is a dynamic UIColor that picks between the two by the
/// `accessibilityContrast` trait, so the choice is made per render, not at launch.
///
/// Android twin: `AcabPalette` in Theme.kt. Shared hex values are identical; the alpha tint
/// for `faint` differs per platform and each side documents its own measurement.
struct ACABPalette: Equatable {
    // Surfaces
    let bg: ACABTone, bg2: ACABTone, bg3: ACABTone
    let line: ACABTone, lineStrong: ACABTone
    // Text
    let text: ACABTone, dim: ACABTone, faint: ACABTone
    // Accent (crimson) + amber
    let accent: ACABTone, accentText: ACABTone, accentSoft: ACABTone, accentGlow: ACABTone
    let onAccent: ACABTone, warn: ACABTone, danger: ACABTone
    // Category tones
    let flockTone: ACABTone, droneTone: ACABTone, axonTone: ACABTone, trackerTone: ACABTone
    let watchTone: ACABTone, glassesTone: ACABTone, netcamTone: ACABTone, sandTone: ACABTone
    // Tab bar (UIKit) backdrop
    let tabBarBackground: ACABTone

    /// The warm off-white every secondary text tint is built from.
    private static let ink = (r: 240.0 / 255, g: 224.0 / 255, b: 226.0 / 255)
    private static func inkAt(_ alpha: Double) -> ACABTone {
        ACABTone(r: ink.r, g: ink.g, b: ink.b, a: alpha)
    }

    /// The default look. The measurements quoted here are alpha-composited onto each surface
    /// (see ACABTone.over) and are locked in by ContrastPaletteTests.
    static let normal = ACABPalette(
        bg:   ACABTone(0x0C0A0B),            // warm near-black
        bg2:  ACABTone(0x161214),            // card / panel
        bg3:  ACABTone(0x201A1D),            // raised / inputs / tiles
        line:       ACABTone(r: 236 / 255, g: 150 / 255, b: 140 / 255, a: 0.11),
        lineStrong: ACABTone(0xEE4034, alpha: 0.30),
        text:  ACABTone(0xF4EEF0),
        dim:   inkAt(0.60),
        // 0.52, not the original 0.33: faint carries real instructions and privacy copy, and at
        // 0.33 it measured ~2.5:1 against bg (WCAG AA wants 4.5:1 for text). 0.52 lands 4.69:1
        // on bg, 4.67:1 on bg2 and 4.55:1 on bg3 (composited), so it clears AA everywhere and
        // the three-step faint < dim < text hierarchy survives. Android sits at 0.54 for the
        // same token and documents its own numbers.
        faint: inkAt(0.52),
        accent:     ACABTone(0xEE4034),
        // Crimson AS TEXT. The fill accent measures 4.42:1 on bg3, under AA for text, and it
        // was used for 9pt version tags and 8pt category captions. This lighter cut clears
        // 6:1 on every surface while reading as the same crimson next to a fill.
        accentText: ACABTone(0xFF6A5E),
        accentSoft: ACABTone(0xEE4034, alpha: 0.13),
        accentGlow: ACABTone(0xEE4034, alpha: 0.55),
        onAccent:   ACABTone(0x120A0A),
        warn:       ACABTone(0xF2B53C),      // amber - drones / warnings
        danger:     ACABTone(0xFF7A4D),
        flockTone:   ACABTone(0xEE4034),
        droneTone:   ACABTone(0xF2B53C),
        axonTone:    ACABTone(0xCDC1C3),
        trackerTone: ACABTone(0x49C5B1),     // teal - BLE item trackers
        watchTone:   ACABTone(0xE0A84B),     // gold - user-starred (watched) devices
        glassesTone: ACABTone(0xB07CFF),     // violet - smart / recording glasses
        netcamTone:  ACABTone(0x3D8BFF),     // blue - branded IP / network cameras on WiFi
        sandTone:    ACABTone(r: 0.82, g: 0.67, b: 0.40),   // desert sand - nearby devices
        tabBarBackground: ACABTone(r: 18 / 255, g: 12 / 255, b: 14 / 255, a: 0.74)
    )

    /// The higher-contrast look. Surfaces are untouched so the bg < bg2 < bg3 hierarchy still
    /// reads; what changes is everything drawn ON them. Secondary text clears 7:1 (AAA) on all
    /// three surfaces, crimson text clears 7:1, and the strong line (control boundaries,
    /// selected states) clears the 3:1 non-text minimum. The plain hairline stays a decorative
    /// divider: brighter than default, but deliberately short of a control edge so a page of
    /// cards does not turn into a grid.
    static let high = ACABPalette(
        bg:   ACABTone(0x0C0A0B),
        bg2:  ACABTone(0x161214),
        bg3:  ACABTone(0x201A1D),
        line:       ACABTone(r: 236 / 255, g: 150 / 255, b: 140 / 255, a: 0.30),
        lineStrong: ACABTone(0xFF5A4E, alpha: 0.72),
        text:  ACABTone(0xFFFFFF),
        dim:   inkAt(0.85),
        faint: inkAt(0.75),
        accent:     ACABTone(0xFF5A4E),      // lighter crimson: dark-on-accent text still 6:1
        accentText: ACABTone(0xFF8C82),
        accentSoft: ACABTone(0xFF5A4E, alpha: 0.18),
        accentGlow: ACABTone(0xFF5A4E, alpha: 0.65),
        onAccent:   ACABTone(0x120A0A),
        warn:       ACABTone(0xF7C24E),
        danger:     ACABTone(0xFF8F66),
        flockTone:   ACABTone(0xFF5A4E),
        droneTone:   ACABTone(0xF7C24E),
        axonTone:    ACABTone(0xE4DADC),
        trackerTone: ACABTone(0x6FE0CE),
        watchTone:   ACABTone(0xF0BE5E),
        glassesTone: ACABTone(0xC9A6FF),
        netcamTone:  ACABTone(0x74ACFF),
        sandTone:    ACABTone(0xE0BE7A),
        tabBarBackground: ACABTone(r: 18 / 255, g: 12 / 255, b: 14 / 255, a: 0.92)
    )
}

// MARK: - Theme

/// ACAB's look, the "Crimson" cyber-noir theme. Dark surfaces, one crimson accent,
/// amber kept for drones.
///
/// Every colour below is dynamic: it resolves against the view's trait collection at draw
/// time and picks `ACABPalette.high` when `accessibilityContrast == .high`. That trait is set
/// by the iOS "Increase Contrast" setting, and ContrastPreference forces it on the window when
/// the in-app "always use higher contrast" switch is on. No view has to know either exists.
enum ACABTheme {
    /// A UIColor that reads the palette matching the resolving trait collection.
    private static func dynamic(_ pick: @escaping (ACABPalette) -> ACABTone) -> UIColor {
        UIColor { traits in
            pick(traits.accessibilityContrast == .high ? ACABPalette.high : ACABPalette.normal).uiColor
        }
    }
    private static func color(_ pick: @escaping (ACABPalette) -> ACABTone) -> Color {
        Color(uiColor: dynamic(pick))
    }

    // Surfaces
    static let bg   = color { $0.bg }
    static let bg2  = color { $0.bg2 }
    static let bg3  = color { $0.bg3 }
    static let line       = color { $0.line }
    static let lineStrong = color { $0.lineStrong }

    // Text
    static let text  = color { $0.text }
    static let dim   = color { $0.dim }
    static let faint = color { $0.faint }

    // Accent (crimson) + amber
    static let accent     = color { $0.accent }
    /// Crimson for TEXT and small glyphs. Use `accent` for fills, bars, strokes and tints of
    /// things a user does not have to read; use this for words and digits drawn in crimson.
    static let accentText = color { $0.accentText }
    static let accentSoft = color { $0.accentSoft }
    static let accentGlow = color { $0.accentGlow }
    static let onAccent   = color { $0.onAccent }
    static let warn       = color { $0.warn }
    static let danger     = color { $0.danger }

    // Category tones (3-tone system)
    static let flockTone   = color { $0.flockTone }
    static let droneTone   = color { $0.droneTone }
    static let axonTone    = color { $0.axonTone }
    static let trackerTone = color { $0.trackerTone }
    static let watchTone   = color { $0.watchTone }
    static let glassesTone = color { $0.glassesTone }
    static let netcamTone  = color { $0.netcamTone }
    static let sandTone    = color { $0.sandTone }

    // UIKit surfaces (tab bar appearance is configured with UIColor, not Color). These are the
    // same dynamic providers, handed over directly so UIKit resolves them per trait change
    // instead of snapshotting one value through UIColor(Color).
    static let uiFaint            = dynamic { $0.faint }
    static let uiAccent           = dynamic { $0.accent }
    static let uiTabBarBackground = dynamic { $0.tabBarBackground }

    // Back-compat aliases, older views still reference these names.
    static let black  = bg
    static let panel  = bg2
    static let ink    = text
    static let red    = accent
    static let amber  = warn
    static let ok     = accent
    static let cyan   = droneTone
    static let violet = axonTone

    // Shape
    static let radius:   CGFloat = 18
    static let radiusSm: CGFloat = 12
    static let pad:      CGFloat = 20

    // MARK: Type
    // Display = Space Grotesk, data = JetBrains Mono (bundled in Resources/Fonts).
    // Each weight maps to the nearest bundled cut.
    //
    // relativeTo: is the only thing making this app honour Dynamic Type. Font.custom(_:size:)
    // without it is frozen at the literal point size, so someone running the largest text
    // setting saw no change anywhere in the app. Everything renders through these two
    // helpers, so this is the single place it has to be fixed.
    //
    // Bold Text (Settings > Accessibility) is honoured the same way: custom fonts do not get
    // the system's automatic emboldening, so each call steps the requested weight up one cut
    // while TypePrefs.bold is set. TypePrefs is @Observable and this read happens inside view
    // bodies, so every view that called a helper re-renders when the setting flips.
    // Both are @MainActor because TypePrefs is: fonts are only ever built inside view bodies.
    @MainActor
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(spaceGrotesk(TypePrefs.shared.effectiveWeight(weight)), size: size, relativeTo: scaleAnchor(size))
    }
    @MainActor
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(jetBrains(TypePrefs.shared.effectiveWeight(weight)), size: size, relativeTo: scaleAnchor(size))
    }

    /// Which system curve a point size rides as the user's text size changes.
    /// Derived from the size rather than fixed per helper because the curves diverge hard at
    /// accessibility sizes: caption roughly quadruples, largeTitle less than doubles. Putting
    /// 9pt chrome and a 62pt counter on the same curve either leaves the chrome unreadable or
    /// bursts the counter out of the radar scope. Base sizes are untouched, so the layout at
    /// the default text setting is unchanged.
    private static func scaleAnchor(_ size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<12:  return .caption      // kickers, RSSI, timestamps, MAC tails
        case ..<18:  return .body         // device names, prose, anything actually read
        case ..<34:  return .title        // screen titles, stat values
        default:     return .largeTitle   // radar count, connect-screen wordmark
        }
    }

    private static func spaceGrotesk(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black, .semibold: return "SpaceGrotesk-Bold"
        case .medium:                          return "SpaceGrotesk-Medium"
        default:                               return "SpaceGrotesk-Regular"
        }
    }
    private static func jetBrains(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "JetBrainsMono-Bold"
        case .semibold:             return "JetBrainsMono-SemiBold"
        case .medium:               return "JetBrainsMono-Medium"
        default:                    return "JetBrainsMono-Regular"
        }
    }
}

/// The one observable the font helpers read: whether the system Bold Text setting is on.
///
/// Kept as an @Observable singleton rather than an environment value because the helpers are
/// static and called from ~500 sites; Observation tracks the property read wherever it happens
/// inside a body, so the dependency is registered without threading anything through views.
/// RootView mirrors `@Environment(\.legibilityWeight)` into `bold` (the SwiftUI-side signal),
/// and the UIAccessibility notification covers the case where no view has rendered yet.
@Observable
@MainActor
final class TypePrefs {
    static let shared = TypePrefs()

    var bold: Bool

    private init() {
        bold = UIAccessibility.isBoldTextEnabled
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.boldTextStatusDidChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in TypePrefs.shared.bold = UIAccessibility.isBoldTextEnabled }
        }
    }

    /// One cut heavier while Bold Text is on. Bold already sits at the heaviest bundled cut
    /// of both families, so it stays put.
    func effectiveWeight(_ w: Font.Weight) -> Font.Weight {
        guard bold else { return w }
        switch w {
        case .ultraLight, .thin, .light, .regular: return .medium
        case .medium:                              return .semibold
        case .semibold:                            return .bold
        default:                                   return w
        }
    }
}

/// Card container: panel fill, hairline border, rounded corners.
struct PanelModifier: ViewModifier {
    var strong = false
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
                    .strokeBorder(strong ? ACABTheme.lineStrong : ACABTheme.line, lineWidth: 1)
            )
    }
}

extension View {
    func panel(strong: Bool = false, padding: CGFloat = 16) -> some View {
        modifier(PanelModifier(strong: strong, padding: padding))
    }
}

/// Small all-caps mono label ("kicker") for section headers and data captions.
/// Deliberately NOT lowercased at the component: the caps + 1.6 tracking is what separates
/// instrument chrome (labels) from content (device names, prose), and collapsing the two
/// type roles into one flattens the whole screen.
struct Kicker: View {
    let text: String
    var color: Color = ACABTheme.faint
    init(_ text: String, color: Color = ACABTheme.faint) { self.text = text; self.color = color }

    /// Dynamic Type only started reaching this label when ACABTheme.mono gained `relativeTo:`.
    /// Before that, Font.custom(_:size:) was frozen at the literal point size, so the
    /// `fixedSize(horizontal: true)` below could never do any harm. Once the text actually scaled,
    /// that modifier - which means "never compress me, take my ideal width" - made every row
    /// carrying a Kicker wider than the screen, and the Device page ran off the left edge.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// True at any size above the system default. The threshold is deliberately "larger than
    /// default" rather than "accessibility size": the overflow starts well before the
    /// accessibility range, and the point is that DEFAULT layout is byte-for-byte what it was.
    private var scaled: Bool { dynamicTypeSize > .large }

    var body: some View {
        Text(text)
            .font(ACABTheme.mono(10.5, weight: .medium))
            .tracking(1.6)
            .foregroundStyle(color)
            // At default size: one line, hug the content, exactly as before. Above it: let the
            // label WRAP instead of forcing its row past the screen edge. A kicker is a short
            // uppercase caption, so two lines at large text reads fine; a row you cannot see the
            // left half of does not.
            .lineLimit(scaled ? nil : 1)
            .fixedSize(horizontal: !scaled, vertical: true)
    }
}
