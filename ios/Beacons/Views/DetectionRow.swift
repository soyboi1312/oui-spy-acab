import SwiftUI

/// One Logbook row: category glyph, node handle, how it was seen, and current signal.
struct DetectionRow: View {
    let detection: Detection
    /// How honest the row's timestamp is. Defaults to .exact for the call sites that show live
    /// rows only (the map's cluster sheet), where the caveat would be noise.
    var timeBasis: TimeBasis = .exact
    /// Active mute state is supplied only by the Log. Other call sites keep their active-surface
    /// presentation and default to false.
    var isMuted = false
    private var d: Detection { detection }
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ViewBuilder
    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                accessibilityLayout
            } else {
                compactLayout
            }
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    /// The familiar dense row at ordinary text sizes.
    private var compactLayout: some View {
        HStack(spacing: 12) {
            CatGlyph(type: d.type, size: 40, filled: true)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // Lead with the advertised name / UAS-ID / broadcast manufacturer when we
                    // have one, else the device class. displayName falls back to type.label on
                    // its own, so the old hasName ternary was already a no-op and is now actively
                    // wrong: it would strip a maker-led title back to "Network camera".
                    Text(d.displayName)
                        .font(ACABTheme.display(15, weight: .semibold)).foregroundStyle(ACABTheme.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    metadataBadges
                    // No per-row "new" dot: it marked everything until the seen-watermark was
                    // fixed, and even corrected it duplicated the NEW scope chip. What is new
                    // lives in that filter now.
                }
                HStack(spacing: 6) {
                    // When a name leads, keep the device class visible as the subtitle.
                    Text(subtitle)
                        .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint).lineLimit(1)
                    // Confidence, so the list answers "is this definitely something, or just
                    // suspected?" without opening the dossier. Bands and colours are LIFTED FROM
                    // DetectionDetailView.verdictColor (<50 weak / <80 partial / >=80 strong) so a
                    // row and its dossier can never disagree.
                    // HIDDEN at 0: Desert-mode nearby devices carry confidence 0 by construction
                    // (no signature was matched), and a wall of "0%" chips would be pure noise.
                    confidenceChip
                    locationChip
                }
            }

            Spacer(minLength: 8)

            signalReadout
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(ACABTheme.faint)
        }
    }

    /// At accessibility sizes, fixed one-line metadata would either vanish or squeeze the title
    /// to a few characters. Give every fact its own vertical room and keep signal at the trailing
    /// edge of the final row.
    private var accessibilityLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                CatGlyph(type: d.type, size: 40, filled: true)
                Text(d.displayName)
                    .font(ACABTheme.display(15, weight: .semibold))
                    .foregroundStyle(ACABTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(ACABTheme.faint)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("NODE \(d.nodeName)")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if d.type.isExperimental { ExpTag() }
                if d.offline { OfflineTag() }
                if isMuted { mutedBadge }
                TimeBasisTag(basis: timeBasis)
                Text(subtitle)
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
                if d.confidence > 0 { confidenceChip }
                if d.locationAgeText != nil { locationChip }
            }

            HStack {
                Spacer()
                signalReadout
            }
        }
    }

    private var subtitle: String {
        d.hasName
            ? "\(d.type.label) \u{00B7} \(d.method.label)"
            : "\(d.source.label) \u{00B7} \(d.method.label)"
    }

    @ViewBuilder private var metadataBadges: some View {
        Text("NODE \(d.nodeName)")
            .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        if d.type.isExperimental { ExpTag() }
        if d.offline { OfflineTag() }
        if isMuted { mutedBadge }
        // OFFLINE says where the row came from; this says what its time is worth.
        TimeBasisTag(basis: timeBasis)
    }

    /// Kept compact because it shares the metadata line with NODE / OFFLINE / time basis. The
    /// explicit spoken state matters: colour and the crossed-bell concept alone do not tell a
    /// VoiceOver user why this retained history row is absent from nearby surfaces.
    private var mutedBadge: some View {
        Text("MUTED")
            .font(ACABTheme.mono(8, weight: .bold)).tracking(0.7)
            .foregroundStyle(ACABTheme.dim)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(ACABTheme.bg3, in: Capsule())
            .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Muted device")
            .accessibilityHint("This active mute hides the device from nearby status and alerts")
    }

    @ViewBuilder private var confidenceChip: some View {
        if d.confidence > 0 {
            Text("\(d.confidence)%")
                .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                .foregroundStyle(confidenceTint)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(confidenceTint.opacity(0.14), in: Capsule())
                .monospacedDigit()
                .accessibilityLabel("confidence \(d.confidence) percent, \(confidenceWord)")
        }
    }

    @ViewBuilder private var locationChip: some View {
        if let age = d.locationAgeText {
            Text("LOC \(age)")
                .font(ACABTheme.mono(9, weight: .bold)).tracking(0.5)
                .foregroundStyle(ACABTheme.warn)
                .padding(.horizontal, 5).padding(.vertical, 1.5)
                .background(ACABTheme.warn.opacity(0.14), in: Capsule())
                .accessibilityLabel("Location age \(age)")
        }
    }

    private var signalReadout: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text("\(d.rssi)")
                .font(ACABTheme.mono(13, weight: .semibold))
                .foregroundStyle(d.type.textTint).monospacedDigit()
            SignalBars(bars: d.signalBars, tint: d.type.tint)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal strength \(d.rssi) decibels relative to one milliwatt")
    }

    /// Same bands as DetectionDetailView.verdictColor - keep the two in step if either moves.
    private var confidenceTint: Color {
        switch d.confidence {
        case ..<50: return ACABTheme.warn
        case ..<80: return ACABTheme.dim
        default:    return ACABTheme.text
        }
    }
    private var confidenceWord: String {
        switch d.confidence {
        case ..<50: return "weak match, verify"
        case ..<80: return "partial match"
        default:    return "strong match"
        }
    }
}
