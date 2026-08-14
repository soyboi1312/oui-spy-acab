import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8)  & 0xFF) / 255,
                  blue:  Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// ACAB's look, the "Crimson" cyber-noir theme. Dark surfaces, one crimson accent,
/// amber kept for drones.
enum ACABTheme {
    // Surfaces
    static let bg   = Color(hex: 0x0C0A0B)            // warm near-black
    static let bg2  = Color(hex: 0x161214)            // card / panel
    static let bg3  = Color(hex: 0x201A1D)            // raised / inputs / tiles
    static let line       = Color(red: 236/255, green: 150/255, blue: 140/255).opacity(0.11)
    static let lineStrong = Color(hex: 0xEE4034).opacity(0.30)

    // Text
    static let text  = Color(hex: 0xF4EEF0)
    static let dim   = Color(red: 240/255, green: 224/255, blue: 226/255).opacity(0.60)
    // 0.52, not the original 0.33: faint carries real instructions and privacy copy, and at 0.33
    // it measured ~2.5:1 against bg (WCAG AA wants 4.5:1 for text). 0.52 lands 4.69:1 on bg,
    // 4.67:1 on bg2 and 4.55:1 on bg3 while staying below dim (0.60, ~5.9:1), so the three-step
    // faint < dim < text hierarchy survives. Verified by compositing the tint over each surface.
    static let faint = Color(red: 240/255, green: 224/255, blue: 226/255).opacity(0.52)

    // Accent (crimson) + amber
    static let accent     = Color(hex: 0xEE4034)
    static let accentSoft = Color(hex: 0xEE4034).opacity(0.13)
    static let accentGlow = Color(hex: 0xEE4034).opacity(0.55)
    static let onAccent   = Color(hex: 0x120A0A)
    static let warn       = Color(hex: 0xF2B53C)      // amber - drones / warnings
    static let danger     = Color(hex: 0xFF7A4D)

    // Category tones (3-tone system)
    static let flockTone = Color(hex: 0xEE4034)
    static let droneTone = Color(hex: 0xF2B53C)
    static let axonTone  = Color(hex: 0xCDC1C3)
    static let trackerTone = Color(hex: 0x49C5B1)     // teal - BLE item trackers
    static let watchTone   = Color(hex: 0xE0A84B)     // gold - user-starred (watched) devices
    static let glassesTone = Color(hex: 0xB07CFF)     // violet - smart / recording glasses
    static let netcamTone  = Color(hex: 0x3D8BFF)     // blue - branded IP / network cameras on WiFi

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
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(spaceGrotesk(weight), size: size, relativeTo: scaleAnchor(size))
    }
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.custom(jetBrains(weight), size: size, relativeTo: scaleAnchor(size))
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
