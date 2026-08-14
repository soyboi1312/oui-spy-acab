import SwiftUI

// MARK: - Brand

/// Small in-app wordmark.
struct BrandMark: View {
    var size: CGFloat = 20
    var body: some View {
        Text("beacons")
            .font(ACABTheme.display(size, weight: .bold))
            .foregroundStyle(ACABTheme.text)
    }
}

/// Big centered wordmark for the connect screen.
struct ACABWordmark: View {
    var subtitle: String? = "ALL CAMERAS ARE BEACONS"
    var body: some View {
        VStack(spacing: 8) {
            Text("beacons")
                .font(ACABTheme.display(46, weight: .bold))
                .foregroundStyle(ACABTheme.text)
                // A 46pt display face on the accessibility curve is wider than any iPhone. It also
                // sets this VStack's width, which then dragged the subtitle off both edges with it,
                // so this one line was the whole hero overflowing. Shrink to fit instead of
                // truncating: the wordmark is the brand, and "Beac..." is worse than smaller type.
                .lineLimit(1)
                .minimumScaleFactor(0.4)
            if let subtitle {
                Kicker(subtitle, color: ACABTheme.faint)
                    .multilineTextAlignment(.center)
            }
        }
        // Never wider than the screen, whatever the text size. Without this the VStack reports an
        // ideal width larger than the viewport and everything inside it is clipped symmetrically.
        .frame(maxWidth: .infinity)
    }
}

/// The board status pill: crimson dot + glow when connected, amber "DEMO" in sample-data mode.
struct LinkChip: View {
    var version: String? = nil
    var connected: Bool
    var demo: Bool = false
    var body: some View {
        let tone = demo ? ACABTheme.warn : (connected ? ACABTheme.accent : ACABTheme.faint)
        // dot + CONNECTED / OFFLINE / DEMO, matching the Android LinkChip. The firmware
        // version lives on the Device screen's firmware row; repeating it in the header chip
        // was noise on a pill the user reads as "is my board there or not".
        let label = demo ? "DEMO" : connected ? "CONNECTED" : "OFFLINE"
        return HStack(spacing: 6) {
            Circle().fill(tone)
                .frame(width: 7, height: 7)
                .shadow(color: demo ? ACABTheme.warn.opacity(0.6)
                                    : (connected ? ACABTheme.accentGlow : .clear), radius: 4)
            Kicker(label,
                   color: demo ? ACABTheme.warn : (connected ? ACABTheme.dim : ACABTheme.faint))
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(ACABTheme.bg2, in: Capsule())
        .overlay(Capsule().strokeBorder(demo ? ACABTheme.warn.opacity(0.4) : ACABTheme.line, lineWidth: 1))
    }
}

/// Blinking "live" dot.
struct ScanDot: View {
    var color: Color = ACABTheme.accent
    @State private var on = true
    // Reduce Motion parks the blink: the dot stays lit (state is still conveyed by colour +
    // the kicker text beside it), it just stops pulsing.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.25)
            .shadow(color: color.opacity(0.5), radius: 3)
            .onAppear(perform: updateAnimation)
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        var parked = Transaction(animation: nil)
        parked.disablesAnimations = true
        withTransaction(parked) { on = true }
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = false }
    }
}

// MARK: - Category glyph

/// A category glyph in a rounded tile, tinted by category.
struct CatGlyph: View {
    let type: DeviceType
    var size: CGFloat = 34
    var filled: Bool = false
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(filled ? type.tint.opacity(0.16) : ACABTheme.bg3)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(ACABTheme.line, lineWidth: 1)
            )
            .overlay(
                Image(systemName: type.symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(type.tint)
            )
    }
}

// MARK: - Signal bars

/// Four rising signal-strength bars (0 = nothing, 4 = full).
struct SignalBars: View {
    let bars: Int            // 0...4
    var tint: Color = ACABTheme.accent
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < bars ? tint : ACABTheme.line)
                    .frame(width: 3, height: CGFloat(5 + i * 3))
            }
        }
    }
}

// MARK: - Radar scope (the signature element)

struct RadarDot: Identifiable {
    let id: String
    let angle: Double     // degrees
    let radius: Double    // 0...1 (0 = center)
    let tone: Color
}

struct RadarScope: View {
    let count: Int
    let dots: [RadarDot]
    /// False parks the beam. A scope that keeps sweeping with the radios off (or the nRF
    /// dark) reads as scanning when nothing is.
    var sweeping: Bool = true

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                ForEach(1...3, id: \.self) { i in
                    Circle()
                        .strokeBorder(i == 3 ? ACABTheme.lineStrong : ACABTheme.line, lineWidth: 1)
                        .frame(width: s * CGFloat(i) / 3, height: s * CGFloat(i) / 3)
                }
                Path { p in
                    p.move(to: CGPoint(x: s/2, y: 0));  p.addLine(to: CGPoint(x: s/2, y: s))
                    p.move(to: CGPoint(x: 0, y: s/2));  p.addLine(to: CGPoint(x: s, y: s/2))
                }
                .stroke(ACABTheme.line, lineWidth: 1)

                if sweeping { SweepBeam(size: s) }

                ForEach(dots) { dot in
                    Circle().fill(dot.tone)
                        .frame(width: 8, height: 8)
                        .shadow(color: dot.tone.opacity(0.8), radius: 5)
                        .offset(x: CGFloat(cos(dot.angle * .pi/180) * dot.radius) * s/2,
                                y: CGFloat(sin(dot.angle * .pi/180) * dot.radius) * s/2)
                }

                VStack(spacing: 2) {
                    Text("\(count)")
                        .font(ACABTheme.display(62, weight: .bold))
                        .foregroundStyle(ACABTheme.text)
                        .monospacedDigit()
                    // "ACTIVE" is load-bearing: this count is filtered to recently-seen
                    // devices, so it reads lower than the Log's whole-session total. Saying
                    // "active" tells the user why Status < Log instead of looking like a bug.
                    // Fixed size, NOT ACABTheme.mono: the caption anchor roughly quadruples at
                    // accessibility sizes and this label lives inside the scope's fixed
                    // geometry, where it collided with the count. The count itself (real
                    // content) keeps scaling; the whole scope carries a spoken summary below.
                    Text("ACTIVE NEARBY")
                        .font(Font.custom("JetBrainsMono-Medium", fixedSize: 10.5))
                        .tracking(1.6)
                        .foregroundStyle(ACABTheme.faint)
                }
            }
            .frame(width: s, height: s)
            .frame(maxWidth: .infinity)
        }
        // One spoken element for the whole instrument: the dots and rings are positional
        // decoration a screen reader cannot use, so say what the scope actually knows.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) active device\(count == 1 ? "" : "s") nearby. Radar shows signal strength only, not direction.")
    }
}

/// The rotating angular gradient that fakes a radar sweep beam. Its own view so the
/// repeatForever animation lives and dies with it: parking the beam by removing the view
/// stops the animation, and re-adding it restarts from onAppear.
private struct SweepBeam: View {
    let size: CGFloat
    @State private var sweep = 0.0
    // Reduce Motion holds the beam still: the gradient stays visible (so "scanning" still
    // reads as distinct from a parked scope), it just does not rotate forever.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Circle()
            .fill(AngularGradient(gradient: Gradient(stops: [
                .init(color: ACABTheme.accent.opacity(0.0),  location: 0.72),
                .init(color: ACABTheme.accent.opacity(0.40), location: 0.99),
                .init(color: ACABTheme.accent.opacity(0.0),  location: 1.0),
            ]), center: .center))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(sweep))
            .blendMode(.screen)
            .onAppear(perform: updateAnimation)
            .onChange(of: reduceMotion) { _, _ in updateAnimation() }
    }

    private func updateAnimation() {
        var parked = Transaction(animation: nil)
        parked.disablesAnimations = true
        withTransaction(parked) { sweep = 0 }
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) { sweep = 360 }
    }
}

/// "they're watching - watch back."
struct PunkLine: View {
    var body: some View {
        // Ornamental brand copy, so it is pinned at its design size: at accessibility text
        // sizes every point it grows is a point stolen from the content around it.
        (Text("they're watching. ").foregroundStyle(ACABTheme.dim)
         + Text("watch back.").foregroundStyle(ACABTheme.accent).italic())
            .font(Font.custom("SpaceGrotesk-Medium", fixedSize: 14))
    }
}

/// Filled-area sparkline of a number series (e.g. an RSSI trend).
struct Sparkline: View {
    let values: [Int]
    var tint: Color = ACABTheme.accent
    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if values.count >= 2 {
                ZStack {
                    areaPath(size)
                        .fill(LinearGradient(colors: [tint.opacity(0.32), tint.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                    linePath(size)
                        .stroke(tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                }
            } else {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: size.height / 2))
                    p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                }
                .stroke(tint.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            }
        }
    }

    private func point(_ i: Int, _ size: CGSize) -> CGPoint {
        let lo = Double(values.min() ?? 0), hi = Double(values.max() ?? 1)
        let range = max(1, hi - lo)
        let x = size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
        let y = size.height - size.height * 0.86 * CGFloat((Double(values[i]) - lo) / range) - size.height * 0.07
        return CGPoint(x: x, y: y)
    }
    private func linePath(_ size: CGSize) -> Path {
        Path { p in
            p.move(to: point(0, size))
            for i in 1..<values.count { p.addLine(to: point(i, size)) }
        }
    }
    private func areaPath(_ size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: 0, y: size.height))
            for i in values.indices { p.addLine(to: point(i, size)) }
            p.addLine(to: CGPoint(x: size.width, y: size.height)); p.closeSubpath()
        }
    }
}

extension Detection {
    /// Last 4 hex of the MAC, uppercased, a short "node" handle.
    var nodeName: String {
        String(mac.replacingOccurrences(of: ":", with: "").suffix(4)).uppercased()
    }
    /// Friendly vendor guess for the detail screen.
    var vendor: String {
        switch type {
        case .flockCamera, .flockRaven: return "Flock Safety"
        case .drone:                    return "UAS · Remote ID"
        case .axonBodyCam:              return "Axon (unverified)"
        case .tracker:                  return "Item tracker"
        case .nearbyDevice:             return "Nearby device"
        case .watched:                  return "Watched device"
        case .recordingGlasses:         return "Camera glasses"
        case .networkCamera:            return "Network camera"
        case .unknown:                  return "Unknown device"   // future wire type this build can't name (Android's UNKNOWN parity)
        }
    }
    /// Short category label for the badge pill.
    var classLabel: String {
        switch type {
        case .flockCamera: return "PLATE READER"
        case .flockRaven:  return "AUDIO SENSOR"
        case .drone:       return "AERIAL · RID"
        case .axonBodyCam: return "BODY CAMERA"
        case .tracker:     return "ITEM TRACKER"
        case .nearbyDevice:return "DEVICE"
        case .watched:     return "STARRED"
        case .recordingGlasses: return "SMART GLASSES"
        case .networkCamera: return "NETWORK CAMERA"
        case .unknown:     return "UNKNOWN"
        }
    }
}

// MARK: - Small reused bits

/// The one EXP tag for experimental detectors: tinted amber, matching on both platforms.
/// Amber text on amber 14% fill with an amber 40% border, radius 4.
struct ExpTag: View {
    var body: some View {
        Text("EXP")
            .font(ACABTheme.mono(9, weight: .bold)).tracking(1)
            .foregroundStyle(ACABTheme.warn)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(ACABTheme.warn.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ACABTheme.warn.opacity(0.4), lineWidth: 1))
    }
}

/// Marks a log row that was captured by the board while the phone was away and filed on
/// reconnect. Same badge geometry as ExpTag, but a muted/neutral tone so it reads as
/// metadata, not an alert.
struct OfflineTag: View {
    var body: some View {
        MetaTag("OFFLINE")
    }
}

/// Says how a row's timestamp was arrived at, in the one word a dense list has room for:
/// RECON for a time the board reconstructed from uptime, RANGE for one we could only bound,
/// NO TIME for one we could not date at all. Nothing for a live row, which needs no caveat.
/// Deliberately the same badge as OFFLINE and EXP rather than a new visual language: this is
/// metadata about the row, in the same register as the other two.
struct TimeBasisTag: View {
    let basis: TimeBasis
    var body: some View {
        if let text = TimeBasisCopy.tag(for: basis) { MetaTag(text) }
    }
}

/// The shared badge geometry behind OfflineTag and TimeBasisTag: ExpTag's shape in a muted
/// tone, so a row's metadata chips line up instead of each inventing their own padding.
private struct MetaTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(ACABTheme.mono(9, weight: .bold)).tracking(1)
            .foregroundStyle(ACABTheme.dim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(ACABTheme.faint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ACABTheme.line, lineWidth: 1))
    }
}
