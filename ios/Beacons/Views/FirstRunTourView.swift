import SwiftUI

/// One-time orientation, shown the first time a board connects (and re-openable from the Device
/// tab). WHY THIS EXISTS: RootView switches straight from ConnectView to MainTabView the instant a
/// board is found, so the moment of peak confusion - "I'm connected, now what?" - had zero
/// guidance. New users landed on tabs full of vocabulary (Desert mode, watchlist, confidence,
/// category toggles) with nothing telling them where to look first. Friends kept getting stuck
/// exactly here (2026-07-29).
///
/// Deliberately NOT a feature tour. Four cards, each answering one question a first-timer actually
/// asks, in the order they ask it. It is skippable, it never shows twice, and it teaches the two
/// ideas the rest of the app assumes you already have: what a confidence number means, and that
/// silence is a real (good) result rather than a broken device.
struct FirstRunTourView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Card {
        let glyph: String
        let title: String
        let body: String
        let note: String?
    }

    private let cards: [Card] = [
        Card(glyph: "dot.radiowaves.left.and.right",
             title: "your beacon is listening",
             body: "It scans on two radios at once and sends what it hears to your phone. You don't have to point it, aim it, or press anything.",
             note: "Detection is passive: it does not jam, spoof, or control nearby devices. It only reports what they already broadcast."),
        Card(glyph: "list.bullet.rectangle",
             title: "the Log is the answer",
             body: "Every device it recognizes lands in the Log, newest first. Tap any row to see what it is, how sure the beacon is, and where you were when it was heard.",
             note: "The Log lives on your phone, not on the beacon. It survives the board going flat, and you can export it as CSV."),
        Card(glyph: "percent",
             title: "read the confidence number",
             body: "Each hit carries a percentage. 80 and up is a strong signature match. Under 50 means something looked similar and is worth a second glance, not an alarm.",
             note: "Tap a row for the full reasoning: which signal matched, and why the beacon scored it that way."),
        // The empty-log sentence is canonical, shared with Android: the old wording ("nothing
        // to find") over-promised. An empty log only means nothing RECOGNIZABLE was BROADCASTING,
        // and equipment that is silent, wired, cellular-backhauled or off is invisible to this
        // hardware by design.
        Card(glyph: "checkmark.circle",
             title: "quiet is a real result",
             body: "Most places are quiet. An empty log means no compatible radio broadcast was recognized nearby - not that nothing is there. Silent, wired, cellular-only, or powered-off equipment has nothing for beacons to hear.",
             note: "Want to see it work? Body cams and drones are common. Trackers and network cameras are opt-in, switch them on in Beacon settings."),
        // Closing trust card (kept word-for-word with Android). Prompted by the Improve detection
        // and log export flows: users reasonably wonder what file access those need. The honest
        // answer is a win: exports are written in app-private space, leave only via the share
        // sheet, and iOS never shows a storage prompt because none is needed.
        Card(glyph: "lock",
             title: "nothing leaves without you",
             body: "Log exports and Improve detection reports are files the app writes in its own private space. Sharing one opens the system share sheet, and you choose exactly where it goes.",
             note: "Nothing is uploaded automatically. beacons never asks for storage permission and cannot see your photos or files."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { finish() }
                    .font(ACABTheme.mono(12, weight: .medium))
                    .foregroundStyle(ACABTheme.dim)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 20).padding(.top, 18)

            TabView(selection: $page) {
                ForEach(cards.indices, id: \.self) { i in
                    cardView(cards[i]).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            // dots
            HStack(spacing: 7) {
                ForEach(cards.indices, id: \.self) { i in
                    Circle()
                        .fill(i == page ? ACABTheme.accent : ACABTheme.faint)
                        .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                }
            }
            .padding(.bottom, 18)
            .animation(.easeOut(duration: 0.18), value: page)

            Button {
                if page < cards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < cards.count - 1 ? "Next" : "Start listening")
                    .font(ACABTheme.mono(14, weight: .bold))
                    .foregroundStyle(ACABTheme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(ACABTheme.accent, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 26)
        }
        .background(ACABTheme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()      // must be dismissed via Skip / Start, so it can't be
                                           // half-swiped away and marked seen without being read
    }

    /// Wrapped in a ScrollView so large Dynamic Type never clips a card: at accessibility
    /// sizes a page's text outgrows the fixed TabView page and was simply cut off. The inner
    /// minHeight keeps the Spacer-centering at default sizes, so the page looks exactly as
    /// before whenever the content still fits; it only starts scrolling once it does not.
    private func cardView(_ c: Card) -> some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Spacer(minLength: 0)
                    Image(systemName: c.glyph)
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(ACABTheme.accent)
                    Text(c.title)
                        .font(ACABTheme.display(23, weight: .semibold))
                        .foregroundStyle(ACABTheme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(c.body)
                        .font(ACABTheme.mono(12.5))
                        .foregroundStyle(ACABTheme.dim)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let n = c.note {
                        Text(n)
                            .font(ACABTheme.mono(10.5))
                            .foregroundStyle(ACABTheme.faint)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 26)
                .frame(minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func finish() {
        FirstRunTour.markSeen()
        dismiss()
    }
}

/// Persistence for the one-time tour. UserDefaults (not @AppStorage on the view) so RootView can
/// decide whether to present BEFORE the sheet is ever constructed, and so Device settings can
/// re-arm it for a user who wants to read it again.
enum FirstRunTour {
    private static let key = "acab.firstRunTour.seen"
    static var hasSeen: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markSeen() { UserDefaults.standard.set(true, forKey: key) }
    /// "Show the tour again" from Device settings.
    static func reset() { UserDefaults.standard.set(false, forKey: key) }
}
