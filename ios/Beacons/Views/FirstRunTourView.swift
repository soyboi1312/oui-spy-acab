import SwiftUI

/// One-time orientation, shown after the first secure beacon connection and replayable from Help.
/// RootView switches from ConnectView to MainTabView only after the encrypted stream is ready, but
/// that is still the moment of peak confusion: "I'm connected, now what?" New users landed on
/// tabs full of vocabulary (Desert mode, watchlist, confidence,
/// category toggles) with nothing telling them where to look first. Friends kept getting stuck
/// exactly here (2026-07-29).
///
/// Deliberately NOT a feature tour. Four cards, each answering one question a first-timer actually
/// asks, in the order they ask it. It is skippable; real-board onboarding appears once while the
/// sample-data version is non-persisting. It teaches the ideas the rest of the app assumes you
/// already have: what the beacon does, what quiet means, how to read confidence, and where detector
/// coverage lives.
///
/// EVERY STRING HERE IS SHARED COPY. Android's FirstRunTour.kt carries the same cards word for
/// word and its own doc comment says so, so a wording change made on one side alone is a silent
/// drift the compiler cannot catch: the last one left the two platforms describing card 4's
/// behaviour differently, with only iOS mentioning that tapping an OFF category opens its setting
/// (both platforms have always done it - see DashboardView's category accessibilityHint and
/// StatusScreen's onClickLabel). Edit both files in the same change.
struct FirstRunTourView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    /// Sample-data orientation is deliberately non-persisting: trying the app without hardware
    /// must not spend the first real-board onboarding moment.
    var isSampleData = false
    /// RootView owns real onboarding persistence because only it can verify the encrypted session
    /// and durably arm Finish setup before marking this tour seen. Help replay keeps the default
    /// no-op, so opening setup help before pairing cannot spend or advance real onboarding.
    var onFinish: () -> Void = {}

    private struct Card {
        let glyph: String
        let title: String
        let body: String
        let note: String?
    }

    private let realCards: [Card] = [
        Card(glyph: "dot.radiowaves.left.and.right",
             title: "your beacon is listening",
             body: "the beacon does the scanning and the app is its screen. keep it powered and nearby; you do not have to point it, aim it, or press anything.",
             note: "detection is passive. it does not jam, spoof, or control nearby devices. it only reports what they already broadcast."),
        Card(glyph: "checkmark.circle",
             title: "quiet does not mean clear",
             body: "zero nearby means no supported broadcast was recognized in the last 45 seconds. silent, wired, cellular-only, 5 GHz-only, powered-off, or unsupported gear can still be there.",
             note: "the radar shows signal strength, not direction."),
        Card(glyph: "list.bullet.rectangle",
             title: "the Log keeps the details",
             body: "each detection lands in the Log, newest first. tap one to see what matched and its confidence. when Location is allowed, it also shows where your phone heard it.",
             note: "80 and up is a strong signature match. under 50 is worth a second look, not an alarm. the phone keeps the main Log. the optional offline buffer lets the beacon keep hits while your phone is away, tagged with the last location your phone shared until that fix is 18 hours old, then with no location."),
        Card(glyph: "switch.2",
             title: "Status is your starting point",
             body: "tap a category on Status to open its filtered Log. if that detector is off, the same tap opens its setting on the Beacon tab.",
             note: "ALPR, drones, body cams, and glasses start on. trackers and network cameras start off because they can be noisy. desert mode reports every nearby broadcast when you want proof of life, so turn it back off when you are done."),
    ]

    private let sampleCards: [Card] = [
        Card(glyph: "dot.radiowaves.left.and.right",
             title: "this is sample data",
             body: "six fictional nearby devices fill the app so you can try every screen without a beacon. nothing here came from your surroundings.",
             note: "sample settings are safe to explore. they do not configure hardware or replace the one-time orientation shown when your real beacon connects."),
        Card(glyph: "list.bullet.rectangle",
             title: "follow a sample hit",
             body: "tap a category on Status to open its filtered Log, tap a row for the full details, and use Map to see where your phone heard each example.",
             note: "the examples cover ALPR, a drone, body camera, tracker, recording glasses, and a network camera."),
        Card(glyph: "switch.2",
             title: "leave whenever you are ready",
             body: "an Exit sample data banner stays at the top of the app, so you never have to hunt through settings to return to beacon scanning.",
             note: "your real saved Log is restored after you exit. sample detections are never added to it."),
    ]

    private var cards: [Card] { isSampleData ? sampleCards : realCards }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if isSampleData {
                    Kicker("SAMPLE DATA TOUR")
                }
                Spacer()
                Button("skip") { finish() }
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

            VStack(spacing: 8) {
                Text("step \(page + 1) of \(cards.count)")
                    .font(ACABTheme.mono(10, weight: .medium))
                    .foregroundStyle(ACABTheme.faint)
                HStack(spacing: 7) {
                    ForEach(cards.indices, id: \.self) { i in
                        Circle()
                            .fill(i == page ? ACABTheme.accent : ACABTheme.faint)
                            .frame(width: i == page ? 7 : 5, height: i == page ? 7 : 5)
                    }
                }
            }
            .padding(.bottom, 18)
            .animation(.easeOut(duration: 0.18), value: page)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("step \(page + 1) of \(cards.count)")

            Button {
                if page < cards.count - 1 {
                    withAnimation { page += 1 }
                } else {
                    finish()
                }
            } label: {
                Text(page < cards.count - 1 ? "next"
                     : (isSampleData ? "explore sample data" : "open Status"))
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
        onFinish()
        dismiss()
    }
}

/// Persistence for the one-time tour. UserDefaults (not @AppStorage on the view) so RootView can
/// decide whether to present BEFORE the sheet is ever constructed, and so Device settings can
/// re-arm it for a user who wants to read it again.
enum FirstRunTour {
    private static let key = "acab.firstRunTour.seen"
    static var hasSeen: Bool { hasSeen(in: .standard) }
    static func hasSeen(in defaults: UserDefaults) -> Bool { defaults.bool(forKey: key) }
    static func markSeen(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
    /// "Show the tour again" from Device settings.
    static func reset(in defaults: UserDefaults = .standard) {
        defaults.set(false, forKey: key)
    }
}
