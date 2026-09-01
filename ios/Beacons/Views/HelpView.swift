import SwiftUI

func improveDetectionAvailable(isSessionReady: Bool, isDemoMode: Bool) -> Bool {
    isSessionReady && !isDemoMode
}

func helpSupportActionIsVisible(_ action: String?, canImproveDetection: Bool) -> Bool {
    action != "improveDetection" || canImproveDetection
}

/// Help + support: the bundled FAQ, a search over it, and the routes to a human.
///
/// This screen exists because the answers were all on the website and none of them were in the
/// app. A reporter using the device hit the exact gap: the map showed an ALPR, the beacon detected
/// nothing, and nothing on screen explained that a map pin is a MAPPED LOCATION rather than a live
/// detection, or that most fixed ALPRs backhaul over cellular and are silent to this hardware. The
/// answer already existed on soyboi.tech/faq. It was just nowhere he was looking. So it ships
/// inside the binary now, works with the radio off, and never phones home to say it was opened.
///
/// `scrollToId` is the deep link from a dossier's RELATED HELP row: the question opens expanded and
/// scrolls to the top, so the tap lands on the answer rather than somewhere near it.
struct HelpView: View {
    var scrollToId: String? = nil
    /// Improve detection starts a live capture and therefore needs a usable real beacon. Setup
    /// Help stays safe by default; connected callers opt in only while encrypted readiness is live.
    var canImproveDetection = false

    @State private var query = ""
    /// One open question at a time, globally, matching the config drawer's fold behaviour. Global
    /// rather than per-card because search collapses everything into one flat list anyway, and two
    /// different rules for the same gesture is how a screen starts feeling arbitrary.
    @State private var openId: String?
    @State private var showTour = false
    @FocusState private var searchFocused: Bool

    private let faq = FAQContent.shared

    private var results: [(section: String, question: FAQContent.Question)] { faq.search(query) }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var visibleSupport: [FAQContent.SupportRow] {
        faq.support.filter {
            helpSupportActionIsVisible($0.action,
                                       canImproveDetection: canImproveDetection)
        }
    }

    var body: some View {
        ZStack {
            ACABTheme.bg.ignoresSafeArea()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        searchField
                        if searching {
                            resultsCard
                        } else {
                            ForEach(faq.sections) { section in
                                sectionCard(section)
                            }
                        }
                        supportCard
                        Text("answers ship with the app · no connection needed")
                            .font(ACABTheme.mono(9.5)).foregroundStyle(ACABTheme.faint)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: 640).frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onAppear {
                    // Deep link: expand first, then scroll. Doing it in one pass would scroll to
                    // the row's collapsed height and leave the answer under the fold.
                    guard let id = scrollToId, faq.question(id: id) != nil else { return }
                    openId = id
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
        }
        .navigationTitle("Help + support")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showTour) { FirstRunTourView() }
    }

    // MARK: search

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(ACABTheme.faint)
            TextField("", text: $query, prompt: Text("search help…")
                .font(ACABTheme.mono(11.5)).foregroundColor(ACABTheme.faint))
                .font(ACABTheme.mono(11.5))
                .foregroundStyle(ACABTheme.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(ACABTheme.faint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ACABTheme.radiusSm, style: .continuous)
            .strokeBorder(searchFocused ? ACABTheme.lineStrong : ACABTheme.line, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: searchFocused)
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(results.isEmpty ? "NO RESULTS" : "\(results.count) RESULT\(results.count == 1 ? "" : "S")")
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            if results.isEmpty {
                Text("nothing matches. try fewer words, or open the FAQ online below.")
                    .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                    .padding(.horizontal, 16).padding(.bottom, 18)
            } else {
                ForEach(Array(results.enumerated()), id: \.element.question.id) { idx, row in
                    questionRow(row.question, sectionKicker: row.section)
                    if idx < results.count - 1 { hairline }
                }
            }
        }
        .cardChrome()
    }

    // MARK: sections

    private func sectionCard(_ section: FAQContent.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker(section.kicker)
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            ForEach(Array(section.questions.enumerated()), id: \.element.id) { idx, q in
                questionRow(q)
                if idx < section.questions.count - 1 { hairline }
            }
        }
        .cardChrome()
    }

    /// One accordion row. `sectionKicker` is only passed in search results, where a bare question
    /// out of context does not say which part of the FAQ it came from.
    private func questionRow(_ q: FAQContent.Question, sectionKicker: String? = nil) -> some View {
        let open = openId == q.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { openId = open ? nil : q.id }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    if let k = sectionKicker {
                        Text(k).font(ACABTheme.mono(9, weight: .medium)).tracking(1.4)
                            .foregroundStyle(ACABTheme.faint)
                    }
                    HStack(alignment: .top, spacing: 10) {
                        Text(q.q)
                            .font(ACABTheme.display(14, weight: .medium))
                            .foregroundStyle(ACABTheme.text)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(open ? ACABTheme.accent : ACABTheme.faint)
                            .rotationEffect(.degrees(open ? 180 : 0))
                            .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Collapse answer" : "Expand answer")

            if open {
                Text(q.a)
                    .font(ACABTheme.mono(11))
                    .foregroundStyle(ACABTheme.dim)
                    .lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .background(open ? ACABTheme.accent.opacity(0.04) : .clear)
        .id(q.id)          // the deep-link + scrollTo anchor
    }

    // MARK: support

    private var supportCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Kicker("SUPPORT")
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 6)
            Text("spotted a false positive, or a device it missed? tell me what it flagged and what it actually was.")
                .font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 12)
            hairline
            ForEach(Array(visibleSupport.enumerated()), id: \.element.id) { idx, row in
                supportRow(row)
                if idx < visibleSupport.count - 1 { hairline }
            }
        }
        .cardChrome()
    }

    @ViewBuilder
    private func supportRow(_ row: FAQContent.SupportRow) -> some View {
        // An external row is a Link so the OS handles http/mailto; an in-app one is a Button.
        // The trailing glyph follows that split, not the styling: ↗ means "this leaves the app".
        if row.external, let s = row.url, let url = URL(string: s) {
            Link(destination: url) { supportRowBody(row, glyph: "arrow.up.right", tint: ACABTheme.accent) }
                .buttonStyle(.plain)
        } else if row.action == "improveDetection" {
            // Opens the contribution composer by pushing it onto the same navigation stack HelpView
            // sits in (whether reached from the Beacon screen or a dossier's related help). Mirrors
            // Android's onImproveDetection handler.
            NavigationLink { ContributeView() } label: {
                supportRowBody(row, glyph: "chevron.right", tint: ACABTheme.faint)
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if row.action == "firstRunTour" { showTour = true }
            } label: { supportRowBody(row, glyph: "chevron.right", tint: ACABTheme.faint) }
                .buttonStyle(.plain)
        }
    }

    private func supportRowBody(_ row: FAQContent.SupportRow, glyph: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(ACABTheme.display(14, weight: .medium)).foregroundStyle(ACABTheme.text)
                Text(row.sub).font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var hairline: some View {
        Rectangle().fill(ACABTheme.line).frame(height: 1).padding(.leading, 16)
    }
}

private extension View {
    /// The card chrome every panel on this screen shares. `.clipped()` matters: the expanded
    /// accent wash runs edge to edge and would otherwise square off the card's rounded corners.
    func cardChrome() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading)
            .background(ACABTheme.bg2)
            .clipShape(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ACABTheme.radius, style: .continuous)
                .strokeBorder(ACABTheme.line, lineWidth: 1))
    }
}
