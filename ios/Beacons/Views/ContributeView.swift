import SwiftUI
import PhotosUI
import UIKit
import MessageUI
import ImageIO
import CoreTransferable
import UniformTypeIdentifiers

private let contributionPhotoSourceByteLimit = 64 * 1024 * 1024

/// "Help improve detection" - a structured MANUAL export composer. iOS twin of Android's
/// ContributeScreen.kt; keep the copy in step.
///
/// THIS SHARES NOTHING BY ITSELF. It builds a capture the user REVIEWS, then opens a PRE-ADDRESSED
/// email to logs@soyboi.tech - recipient, subject and an inline plain-text body filled in, the CSV
/// (and photo) as real attachments - which the user still has to send. No server, no automatic
/// upload. When the device has no Mail account (canSendMail() == false) it falls back to the system
/// share sheet (which also offers Save to Files); the share sheet cannot pre-fill a recipient, so
/// the note carries the address to paste. Email, not a public issue, because a capture can contain
/// GPS - mirrors the site's "send the raw capture" flow.
///
/// WHAT THIS DOES AND DOES NOT SETTLE. The engineering fact is only that data never leaves on an
/// automatic path. It does NOT by itself decide the App Privacy / Data Safety declarations. Apple's
/// optional-feedback exception has simultaneous conditions (clearly show the submitting user's
/// identity, be infrequent, sit outside primary functionality) that a share like this does not
/// obviously meet; Google requires accurate disclosure of optional collection. Make those store
/// answers as a SEPARATE determination against the current policies before shipping, not from this
/// file. See developer.apple.com/app-store/app-privacy-details.
struct ContributeView: View {
    @EnvironmentObject var ble: BLEManager
    @Environment(\.dismiss) private var dismiss
    // Accessibility text sizes pad the scroll bottom so nothing ends under the tab bar.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // What the user VISUALLY confirmed. Their attestation, never a machine claim, so the options
    // are plain-language classes including "unknown" - an unclassifiable sighting is still worth
    // contributing, often the most valuable kind.
    private let kinds = ["ALPR camera", "Body camera", "Mobile surveillance trailer", "Drone", "Unknown"]
    @State private var kind: String?
    @State private var makerModel = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photoURL: URL?
    // Small decoded preview of the attached photo, cached so the review body never re-decodes a
    // multi-MB JPEG per eval. Set and cleared ONLY alongside photoURL, under the same generation
    // check, so the thumbnail can never show a photo that is not the one attached.
    @State private var photoThumb: UIImage?
    // A picker selection is not an attachment until its pixels have been decoded, scrubbed,
    // encoded, and durably written. Keep that intermediate state visible and gate every export
    // action on it so a quick Share cannot silently race ahead of the selected photo.
    @State private var photoLoading = false
    @State private var photoError: String?
    // A failed PhotosPickerItem is cleared so the same asset can be selected again. The resulting
    // nil onChange is bookkeeping, not a user-requested Remove, and must not delete the last good
    // attachment retained during a failed replacement.
    @State private var ignoreNextNilPhotoSelection = false
    // Bumped on every pick and on teardown. A picker Task publishes its result only if it is still
    // the newest selection in a live view, so late completions can't install a stale image.
    @State private var photoGeneration = 0
    // Per-share temp directories created on the fallback path, deleted when this view goes away.
    @State private var shareDirs: [URL] = []
    @State private var share: ShareBundle?
    @State private var mail: MailBundle?
    // Export build in flight (formatting + file writes run off-main); gates the action buttons.
    @State private var preparing = false
    // A failed build names itself instead of silently returning (drives the alert below).
    @State private var buildError: String?
    // Location policy, mirroring Android. THREE separate switches (see ContributionCsv):
    // the phone's own position OUT by default; the drone AIRCRAFT's broadcast coords IN by
    // default (they describe a machine); the drone OPERATOR's broadcast coords OUT by default
    // (they can reveal a person's location, so they get the same caution as the observer's).
    @State private var includeObserverLocation = false
    @State private var includeDroneLocation = true
    @State private var includeOperatorLocation = false

    // BOUNDED capture window. The contribution exports ONLY what was audible between Start and Stop,
    // so it is a purpose-built diagnostic capture, not the full history. `nowMs` ticks (below) while
    // capturing to drive the live count and elapsed timer.
    @State private var phase: CapturePhase = .idle
    @State private var startMs: Int64 = 0
    @State private var stopMs: Int64 = 0
    @State private var nowMs: Int64 = 0
    // Frozen exactly once at Stop: membership plus each device's last in-window sighting. Review /
    // share must never re-evaluate the mutable log, and bounded CSV timestamps must stay in-window.
    @State private var capturedAtByID: [String: Int64] = [:]
    // ALSO frozen exactly once at Stop: the full, UNREDACTED windowed CSV, rendered from the log
    // in the same main-actor instant the membership map is. The review count and disclosure derive
    // from THIS string, and share redacts THIS string (pure text ops) - the mutable log is never
    // re-read after Stop, so rows evicted between Stop and Share (ignore, clear log) can no longer
    // vanish out of the export while the header still claims the frozen count. Unredacted on
    // purpose: the location toggles stay live in review, so redaction happens per-share, not at
    // Stop. Cleared by Start over and confirmed Discard.
    @State private var frozenCsv = ""
    // Non-nil while the "Discard this capture?" confirmation is up; names what a confirm does
    // (close the flow, restart at idle, or start a fresh capture). Mirrors Android's DiscardTarget.
    @State private var confirmDiscard: DiscardTarget?
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static func nowMillis() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    private var liveCount: Int {
        switch phase {
        case .capturing: return ble.windowObservationCount(startMs: startMs, stopMs: nowMs)
        // Review counts the ARTIFACT (data rows of the frozen CSV), not the membership map, so
        // the number on screen can never disagree with the file that leaves.
        case .review:    return Self.csvRowCount(frozenCsv)
        case .idle:      return 0
        }
    }
    private var exportBusy: Bool { preparing || photoLoading }

    // Built in PLAIN SWIFT, not inside the ViewBuilder: a multi-line concat with a ternary is what
    // makes the SwiftUI type-checker time out. Window-aware, and states the actual result. The
    // contents sentence names EVERYTHING the CSV really carries and is canonical, shared with
    // Android byte for byte: the CSV has NO device-name column (the old sentence claimed one) and
    // DOES carry maker, height above ground and Remote ID status (the old sentence omitted them).
    // The closing two sentences are canonical too; only the platform-mechanics sentence after
    // them may differ per platform.
    private var disclosureText: String {
        let n = liveCount
        let obs = includeObserverLocation ? "Your location: INCLUDED." : "Your location: removed."
        let dro = "Drone aircraft coordinates: \(includeDroneLocation ? "included" : "removed")."
        let op  = "Drone operator position: \(includeOperatorLocation ? "included" : "removed")."
        // Own line, not appended with a space: Android joins with '\n', and the disclosure block
        // is a byte-for-byte contract between the platforms.
        let pho = photoURL != nil ? "\nPhoto location metadata removed automatically." : ""
        return "\(n) observation\(n == 1 ? "" : "s") from \(Self.clockTime(startMs)) to \(Self.clockTime(stopMs)), "
             + "as CSV: MAC addresses, device type and maker, signal strength, timestamps, match "
             + "evidence and confidence, sighting counts, company and UAS identifiers, drone "
             + "telemetry (altitude, speed, heading, height above ground), and Remote ID status.\n"
             + obs + "\n" + dro + "\n" + op + pho
             + "\n\nNothing is shared automatically. Diagnostic captures may contain identifiers from "
             + "nearby devices. Review and export only what you choose. This opens a pre-addressed "
             + "email you review before sending; without a Mail account it opens the share sheet "
             + "instead, which also offers Save to Files."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch phase {
                case .idle:      idleStep
                case .capturing: capturingStep
                case .review:    reviewStep
                }
            }
            .padding(ACABTheme.pad)
        }
        // Extra bottom margin only at accessibility sizes (tab bar clearance); zero otherwise.
        .contentMargins(.bottom, dynamicTypeSize.isAccessibilitySize ? 24 : 0, for: .scrollContent)
        .background(ACABTheme.bg.ignoresSafeArea())
        .navigationTitle("Improve detection")
        .navigationBarTitleDisplayMode(.inline)
        // Hiding the native item also disables NavigationStack's edge-swipe pop. A field capture
        // must go through the same confirmation whether the user taps Back or swipes from the edge.
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: requestDiscard) {
                    Image(systemName: "chevron.left")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .disabled(preparing)
                .accessibilityLabel("Back")
                .accessibilityHint(captureWorthKeeping ? "Asks before discarding this capture" : "Returns to Beacon")
            }
        }
        .sheet(item: $share) { ShareSheet(items: $0.items) }
        .sheet(item: $mail) { bundle in
            // A pre-addressed email is the point of this screen; the composer keeps the note as an
            // inline body (not a stray attachment) and fills To:/Subject. Finishing OR cancelling
            // just closes the composer - the review form stays put so the user can retry, matching
            // Android's "no onDone on cancel".
            MailComposeView(subject: bundle.subject, recipients: bundle.recipients,
                            body: bundle.body, attachments: bundle.attachments) { mail = nil }
        }
        .onChange(of: photoItem) { _, item in
            if item == nil, ignoreNextNilPhotoSelection {
                ignoreNextNilPhotoSelection = false
            } else {
                loadPhoto(item)
            }
        }
        // A failed export build says so instead of silently doing nothing.
        .alert("Couldn't prepare the export", isPresented: Binding(
            get: { buildError != nil }, set: { if !$0 { buildError = nil } })) {
            Button("OK", role: .cancel) { buildError = nil }
        } message: {
            Text(buildError ?? "Nothing was shared. Try again.")
        }
        .onReceive(ticker) { _ in if phase == .capturing { nowMs = Self.nowMillis() } }
        // One confirmation for every destructive way out of a live capture (Discard, Start over,
        // START A NEW CAPTURE): a field capture cannot be re-taken from the couch, so it is never
        // dropped on a single tap. Idle - and the empty review with nothing worth keeping - pass
        // straight through (see captureWorthKeeping). Mirrors Android's confirmDiscard dialog.
        .confirmationDialog("Discard this capture?",
                            isPresented: Binding(get: { confirmDiscard != nil },
                                                 set: { if !$0 { confirmDiscard = nil } }),
                            titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                if let target = confirmDiscard { confirmDiscard = nil; performDiscard(target) }
            }
            Button("Keep capture", role: .cancel) { confirmDiscard = nil }
        } message: {
            Text("The captured window and its details will be lost. This can't be undone.")
        }
        // Best-effort temp cleanup when leaving an IDLE flow ONLY. onDisappear is not "the user
        // left for good": the enclosing TabView fires it on the departing tab on every tab
        // switch, so an unconditional cleanup here deleted the attached photo out from under a
        // LIVE capture mid-walk (and the still-retained photoItem then blocked re-picking the
        // same photo). Gated on idle, an in-progress capture keeps its photo and share dirs
        // across tab switches; confirmed Discard and Start over run cleanupTemp explicitly
        // instead (performDiscard). A capture abandoned mid-flow by leaving the tab for good can
        // strand temp files - acceptable, the OS purges temporaryDirectory. onDisappear still
        // does NOT fire while a share or mail sheet is presented over this view (the presenter
        // stays "appeared"), so an in-flight share's files are never deleted here either.
        .onDisappear { if phase == .idle { cleanupTemp() } }
    }

    // ---- IDLE: explain, then arm a bounded capture window ------------------------------------
    @ViewBuilder private var idleStep: some View {
        Text("Found a device beacons didn't identify? Start a short capture, walk around the device, "
           + "then stop. Only what the beacon heard during that window is exported, so your "
           + "contribution is a focused diagnostic capture, not your whole history.")
            .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
        primaryButton("START CAPTURE") { startCapture() }
        discardLink
    }

    // ---- CAPTURING: live count + elapsed, until the user stops -------------------------------
    @ViewBuilder private var capturingStep: some View {
        Text("CAPTURING").font(ACABTheme.mono(11, weight: .bold)).foregroundStyle(ACABTheme.accent)
            .tracking(1)
        Text("Walk around the device, then stop.").font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.dim)
        Text("\(liveCount) observation\(liveCount == 1 ? "" : "s") heard  ·  \(Self.elapsed(startMs, nowMs))")
            .font(ACABTheme.mono(16, weight: .bold)).foregroundStyle(ACABTheme.text)
        primaryButton("STOP CAPTURE") {
            let stopped = Self.nowMillis()
            // One manager call freezes live-ledger membership, row fields, exact timestamps, and
            // matching capture-local phone positions before ingest can advance another row.
            let snapshot = ble.finishContributionCapture(startMs: startMs, stopMs: stopped)
            capturedAtByID = snapshot.capturedAtByID
            stopMs = stopped
            // FREEZE AT STOP: render the full unredacted CSV from that atomic snapshot. Review and
            // share never re-read the mutable manager store or its coalesced UI projection.
            frozenCsv = BLEManager.renderContributionCSV(
                snapshot.rows,
                includeObserverLocation: true, includeDroneLocation: true,
                includeOperatorLocation: true)
            phase = .review
        }
    }

    // ---- REVIEW: attest, set policy, see exactly what leaves, export the window --------------
    // A zero-observation window gets its own lead card: a normal-looking submission over an
    // empty CSV reads as "the capture worked", when the honest story is "nothing recognizable
    // was broadcasting". Explain and lead with a new capture - but keep the composer sections
    // VISIBLE beneath the card (Android parity): a photo, kind or maker retained from a previous
    // capture would otherwise ride an "empty" share invisibly. Everything that would export
    // stays on screen.
    @ViewBuilder private var reviewStep: some View {
        if liveCount == 0 {
            emptyReviewStep
        } else {
            Text("Captured \(liveCount) observation\(liveCount == 1 ? "" : "s") over \(Self.elapsed(startMs, stopMs)) "
               + "(\(Self.clockTime(startMs)) to \(Self.clockTime(stopMs))).")
                .font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.text)
            kindSection
            makerAndPhotoSection
            locationToggles
            disclosureCard
            actionButtons
        }
    }

    // Canonical empty-window copy, shared with Android word for word. The full composer (kind,
    // maker, photo, toggles, disclosure) renders BELOW the explanation, never hidden: whatever
    // would ride the share must be reviewable, even when the CSV is empty.
    @ViewBuilder private var emptyReviewStep: some View {
        Text("NOTHING HEARD").font(ACABTheme.mono(11, weight: .bold)).foregroundStyle(ACABTheme.dim)
            .tracking(1)
        Text("Nothing was heard in this window. That means no compatible broadcast was recognized "
           + "while you captured - it doesn't prove nothing is there. Try capturing closer to the "
           + "device, or for longer.")
            .font(ACABTheme.mono(13)).foregroundStyle(ACABTheme.text)
            .fixedSize(horizontal: false, vertical: true)
        primaryButton("START A NEW CAPTURE") { requestNewCapture() }
            .disabled(preparing)
            .opacity(preparing ? 0.5 : 1)
        kindSection
        makerAndPhotoSection
        locationToggles
        disclosureCard
        if exportBusy {
            HStack(spacing: 8) {
                ProgressView().tint(ACABTheme.dim)
                Text(photoLoading ? "Preparing photo\u{2026}" : "Preparing export\u{2026}")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 4)
        }
        // Sharing an empty capture stays possible (a confirmed visual with zero RF is itself a
        // data point) but deliberately reads as the secondary path.
        Button { buildAndShare(mode: .send) } label: {
            Text("Share the empty capture anyway")
                .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.faint)
                .frame(maxWidth: .infinity).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exportBusy)
        .opacity(exportBusy ? 0.5 : 1)
        Button { buildAndShare(mode: .save) } label: {
            Text("SAVE A COPY")
                .font(ACABTheme.mono(12, weight: .bold)).foregroundStyle(ACABTheme.dim)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exportBusy)
        .opacity(exportBusy ? 0.5 : 1)
        discardLink
    }

    @ViewBuilder private var kindSection: some View {
        Kicker("WHAT DID YOU SEE?")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(kinds, id: \.self) { k in kindChip(k) }
        }
        .disabled(preparing)
        .opacity(preparing ? 0.65 : 1)
    }

    // A real Button (not onTapGesture) so assistive tech gets the button trait, plus the
    // selected trait while active; minHeight 44 makes the chip a full-size touch target.
    private func kindChip(_ k: String) -> some View {
        let on = kind == k
        return Button { kind = on ? nil : k } label: {
            Text(k)
                .font(ACABTheme.mono(11, weight: on ? .bold : .regular))
                .foregroundStyle(on ? ACABTheme.text : ACABTheme.dim)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(minHeight: 44)
                .background(on ? ACABTheme.bg3 : ACABTheme.bg2, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(on ? ACABTheme.accent : ACABTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var makerAndPhotoSection: some View {
        TextField("Manufacturer / model (optional)", text: $makerModel)
            .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
            .padding(12)
            .background(ACABTheme.bg3, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
            .disabled(preparing)
            .opacity(preparing ? 0.65 : 1)

        // With a photo attached the row shows the REAL thumbnail plus explicit Replace / Remove,
        // so the user reviews the actual image that will leave, not a checkmark's word for it.
        // Both actions ride the existing generation/cleanup machinery: Replace is just another
        // pick (loadPhoto supersedes + deletes the old file), Remove clears the selection (which
        // loadPhoto(nil) treats as deselection and cleans up).
        if let thumb = photoThumb, photoURL != nil {
            HStack(spacing: 12) {
                Image(uiImage: thumb)
                    .resizable().scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(ACABTheme.line, lineWidth: 1))
                    .accessibilityLabel("Attached photo preview")
                VStack(alignment: .leading, spacing: 2) {
                    Text(photoLoading ? "Preparing replacement\u{2026}" : "Photo attached")
                        .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
                    Text(photoLoading ? "The current photo stays attached until this finishes"
                                      : "location metadata removed on export")
                        .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.faint)
                }
                Spacer(minLength: 8)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Text("REPLACE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.dim)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(ACABTheme.line, lineWidth: 1))
                        .frame(minHeight: 44)   // 44pt hit target; drawn capsule unchanged
                        .contentShape(Rectangle())
                }
                .disabled(photoLoading || preparing)
                Button {
                    // Clearing the selection routes through the same onChange -> loadPhoto(nil)
                    // path as a deselection, which bumps the generation and deletes the file.
                    if photoItem != nil { photoItem = nil } else { loadPhoto(nil) }
                } label: {
                    Text("REMOVE").font(ACABTheme.mono(10, weight: .bold)).tracking(1)
                        .foregroundStyle(ACABTheme.accent)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .overlay(Capsule().strokeBorder(ACABTheme.lineStrong, lineWidth: 1))
                        .frame(minHeight: 44)   // 44pt hit target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(photoLoading || preparing)
            }
            .padding(10)
            .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
        } else {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label(photoLoading ? "Preparing photo\u{2026}" : "Attach a photo (optional)",
                      systemImage: photoLoading ? "hourglass" : "photo")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .frame(minHeight: 44)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .disabled(photoLoading || preparing)
        }
        if photoLoading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(ACABTheme.accent)
                Text("Decoding and removing location metadata. Share and Save stay off until the photo is ready.")
                    .font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Preparing photo. Share and Save are unavailable until it is ready.")
        }
        if let photoError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(ACABTheme.warn)
                Text(photoError + " Choose the photo again to retry.")
                    .font(ACABTheme.mono(10.5)).foregroundStyle(ACABTheme.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        // NOTE: the onChange for photoItem lives on the always-mounted body, not on either
        // branch above, so a pick can never slip through while the row swaps branches.
    }

    // Three independent switches, because the three location sources are distinct (see
    // ContributionCsv): the phone's own position, the drone AIRCRAFT's broadcast position, and
    // the drone OPERATOR's broadcast position - the last locates a person, so it defaults off.
    @ViewBuilder private var locationToggles: some View {
        toggleRow("Include where I made this observation",
                  "Off by default. Your phone's location is removed from the export.",
                  $includeObserverLocation)
        toggleRow("Include drone aircraft locations",
                  "Only affects drone rows. The aircraft position from its Remote ID broadcast, not your phone.",
                  $includeDroneLocation)
        toggleRow("Include drone operator locations",
                  "The operator position from the same broadcast. Off by default because it can reveal a person's location.",
                  $includeOperatorLocation)
    }

    private func toggleRow(_ label: String, _ hint: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.text)
                Text(hint).font(ACABTheme.mono(10)).foregroundStyle(ACABTheme.faint)
            }
        }
        .tint(ACABTheme.accent)
        .disabled(preparing)
        .opacity(preparing ? 0.65 : 1)
    }

    // The privacy disclosure, so the user sees exactly what leaves before it can. Names the real
    // file contents, not a generic warning.
    private var disclosureCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker("WHAT THIS EXPORT CONTAINS")
            Text(disclosureText).font(ACABTheme.mono(11)).foregroundStyle(ACABTheme.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ACABTheme.bg2, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
    }

    // Review & share (submit) / save a copy / start over / discard. SAVE A COPY is a standing
    // action because the Mail path used to make Save to Files unreachable: canSendMail() == true
    // meant the composer always opened and the share sheet (the only surface offering Files)
    // never did. It always opens the file share sheet, Mail configured or not.
    @ViewBuilder private var actionButtons: some View {
        if exportBusy {
            HStack(spacing: 8) {
                ProgressView().tint(ACABTheme.dim)
                Text(photoLoading ? "Preparing photo\u{2026}" : "Preparing export\u{2026}")
                    .font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.dim)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
        }
        primaryButton("REVIEW & SHARE") { buildAndShare(mode: .send) }
            .disabled(exportBusy)
            .opacity(exportBusy ? 0.5 : 1)
        Button { buildAndShare(mode: .save) } label: {
            Text("SAVE A COPY").font(ACABTheme.mono(12, weight: .bold)).foregroundStyle(ACABTheme.dim)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .frame(minHeight: 44)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.line, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(exportBusy)
        .opacity(exportBusy ? 0.5 : 1)
        HStack {
            // Both destructive exits route through the discard confirmation (see body).
            Button { requestStartOver() } label: {
                Text("Start over").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.faint)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)   // 44pt targets for the quiet links too
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preparing)
            Spacer()
            Button { requestDiscard() } label: {
                Text("Discard").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.faint)
                    .padding(.vertical, 8)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(preparing)
        }
        .opacity(preparing ? 0.5 : 1)
    }

    // Shared accented full-width button + the plain Discard link, so the three phases render one
    // button style. Kept tiny so the type-checker never faces a big nested action expression.
    private func primaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(ACABTheme.mono(13, weight: .bold)).foregroundStyle(ACABTheme.text)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .frame(minHeight: 44)   // 44pt target
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ACABTheme.accent, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .opacity(preparing ? 0.5 : 1)
    }
    private var discardLink: some View {
        Button { requestDiscard() } label: {
            Text("Discard").font(ACABTheme.mono(12)).foregroundStyle(ACABTheme.faint)
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .frame(minHeight: 44)   // 44pt target
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preparing)
        .opacity(preparing ? 0.5 : 1)
    }

    // ---- Discard confirmation + capture lifecycle --------------------------------------------

    /// True when one tap would destroy something unrepeatable: a window mid-capture, or a review
    /// holding observations or any attachment/attestation (photo, kind, maker). The zero-
    /// observation review with none of those passes straight through - there is nothing to lose -
    /// matching Android. Idle always passes.
    private var captureWorthKeeping: Bool {
        switch phase {
        case .idle:      return false
        case .capturing: return true
        case .review:    return liveCount > 0 || photoURL != nil || photoLoading || kind != nil
                              || !makerModel.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    // All three entry points refuse while an export build is in flight: a confirmed discard
    // racing the detached buildAndShare task could delete the per-share dir the completing task
    // just appended (the queued sheet would then present dead file URLs), or present a stale
    // sheet over the idle screen. The buttons are already .disabled(preparing); the guards make
    // the invariant hold even if a future edit drops a .disabled.
    private func requestDiscard() {
        guard !preparing else { return }
        // Pass-through routes through performDiscard too (not a bare dismiss): phase must return
        // to .idle so the idle-gated onDisappear cleanup can release any stranded share dir from
        // an earlier "Share the empty capture anyway".
        if captureWorthKeeping { confirmDiscard = .close } else { performDiscard(.close) }
    }
    private func requestStartOver() {
        guard !preparing else { return }
        if captureWorthKeeping { confirmDiscard = .restart } else { performDiscard(.restart) }
    }
    private func requestNewCapture() {
        guard !preparing else { return }
        if captureWorthKeeping { confirmDiscard = .newCapture } else { performDiscard(.newCapture) }
    }

    /// A CONFIRMED discard (or a pass-through with nothing worth keeping). Deletes the capture's
    /// temp files HERE, explicitly - onDisappear no longer does it for a live capture (see body).
    /// Keeps kind/maker on restart paths: re-capturing the window should not make the user
    /// re-type their attestation (Android parity); the photo is a temp file owned by the cleanup
    /// machinery, so a discarded capture releases it.
    private func performDiscard(_ target: DiscardTarget) {
        // A capturing view owns manager-side live samples. Every destructive exit cancels them;
        // after Stop this is harmless because finishContributionCapture already cleared them.
        ble.cancelContributionCapture()
        // Drop the retained picker selection too: cleanupTemp deletes the photo FILE, and a
        // photoItem left behind would block re-picking the same photo (onChange never fires on
        // an unchanged value). Routing through the binding keeps the generation machinery honest.
        if photoItem != nil { photoItem = nil }
        cleanupTemp()
        capturedAtByID = [:]
        frozenCsv = ""
        switch target {
        case .close:      phase = .idle; dismiss()
        case .restart:    phase = .idle
        case .newCapture: startCapture()
        }
    }

    /// Arm a fresh capture window. Any previous window's frozen state is gone by now
    /// (performDiscard), or never existed (idle).
    private func startCapture() {
        capturedAtByID = [:]
        frozenCsv = ""
        startMs = Self.nowMillis(); nowMs = startMs
        ble.beginContributionCapture(startMs: startMs)
        phase = .capturing
    }

    private static func elapsed(_ fromMs: Int64, _ toMs: Int64) -> String {
        let s = max(0, toMs - fromMs) / 1000
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    nonisolated private static func clockTime(_ ms: Int64) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private func loadPhoto(_ item: PhotosPickerItem?) {
        // Each pick gets its own generation and UUID path. A replacement keeps the last GOOD photo
        // installed until its successor has completed every stage; a decode/write failure therefore
        // remains retryable and cannot turn a reviewed attachment into a silent omission.
        photoGeneration += 1
        let gen = photoGeneration
        let previous = photoURL
        guard let item else {
            photoLoading = false
            photoError = nil
            if let previous { try? FileManager.default.removeItem(at: previous) }
            photoURL = nil
            photoThumb = nil
            return
        }
        photoLoading = true
        photoError = nil

        Task {
            let result: PhotoPreparationResult
            do {
                guard let source = try await item.loadTransferable(type: PickedPhotoFile.self) else {
                    result = .failure("That photo couldn't be loaded.")
                    publishPhotoResult(result, generation: gen, replacing: previous)
                    return
                }
                defer { try? FileManager.default.removeItem(at: source.url) }
                // PhotosPicker hands us a file representation rather than materializing the
                // original asset as one unbounded Data value. Decode, orientation normalization,
                // JPEG re-encode, thumbnailing, and atomic output I/O remain detached.
                result = await Task.detached(priority: .userInitiated) {
                    Self.preparePhoto(source.url)
                }.value
            } catch {
                result = .failure("That photo couldn't be loaded.")
            }
            publishPhotoResult(result, generation: gen, replacing: previous)
        }
    }

    @MainActor
    private func publishPhotoResult(_ result: PhotoPreparationResult, generation gen: Int,
                                    replacing previous: URL?) {
        switch result {
        case .success(let url, let thumbnailData):
            guard gen == photoGeneration else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard let thumb = UIImage(data: thumbnailData) else {
                try? FileManager.default.removeItem(at: url)
                photoLoading = false
                photoError = "The prepared photo couldn't be previewed."
                ignoreNextNilPhotoSelection = true
                photoItem = nil
                return
            }
            if let previous, previous != url { try? FileManager.default.removeItem(at: previous) }
            photoURL = url
            photoThumb = thumb
            photoLoading = false
            photoError = nil
            // The URL is the attachment truth; clear the picker token so Replace can choose this
            // same library asset again and still generate a fresh selection event.
            ignoreNextNilPhotoSelection = true
            photoItem = nil

        case .failure(let message):
            guard gen == photoGeneration else { return }
            // Preserve `previous`, if any. Clear the picker token so choosing the SAME source
            // again produces a fresh onChange; ignoreNextNil keeps that reset from acting as Remove.
            photoLoading = false
            photoError = message
            ignoreNextNilPhotoSelection = true
            photoItem = nil
        }
    }

    /// Pixel-round-trip a source image into a new metadata-free JPEG and a tiny preview. This is
    /// called only from Task.detached. ImageIO downsamples while decoding and applies the source
    /// orientation before UIKit ever allocates a bitmap: a 48 MP library asset must not create a
    /// several-hundred-megabyte full-resolution render merely to accompany a field report. The
    /// 2560 px cap preserves useful visual evidence while bounding the working/output buffers.
    /// The fresh encoder receives only transformed pixels, so no EXIF orientation or other source
    /// metadata is needed or copied.
    nonisolated private static func preparePhoto(_ sourceURL: URL) -> PhotoPreparationResult {
        autoreleasepool {
            let values = try? sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let byteCount = values?.fileSize,
                  byteCount > 0, byteCount <= contributionPhotoSourceByteLimit else {
                return .failure("That image file is too large or unreadable.")
            }
            guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
                return .failure("That file isn't a readable image.")
            }

            let decodeOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_560,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(
                imageSource, 0, decodeOptions as CFDictionary
            ), decoded.width > 0, decoded.height > 0 else {
                return .failure("That file isn't a readable image.")
            }
            let source = UIImage(cgImage: decoded, scale: 1, orientation: .up)
            let outputSize = CGSize(width: CGFloat(decoded.width), height: CGFloat(decoded.height))

            let fullFormat = UIGraphicsImageRendererFormat.default()
            fullFormat.scale = 1
            fullFormat.opaque = true
            let normalized = UIGraphicsImageRenderer(size: outputSize, format: fullFormat).image { _ in
                source.draw(in: CGRect(origin: .zero, size: outputSize))
            }
            guard let jpeg = normalized.jpegData(compressionQuality: 0.9) else {
                return .failure("That photo couldn't be converted to JPEG.")
            }

            let maxSide: CGFloat = 112
            let scale = min(maxSide / normalized.size.width, maxSide / normalized.size.height, 1)
            let thumbSize = CGSize(width: max(1, normalized.size.width * scale),
                                   height: max(1, normalized.size.height * scale))
            let thumbFormat = UIGraphicsImageRendererFormat.default()
            thumbFormat.scale = 1
            thumbFormat.opaque = true
            let thumbnail = UIGraphicsImageRenderer(size: thumbSize, format: thumbFormat).image { _ in
                normalized.draw(in: CGRect(origin: .zero, size: thumbSize))
            }
            guard let thumbnailData = thumbnail.jpegData(compressionQuality: 0.75) else {
                return .failure("That photo couldn't be previewed.")
            }

            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("beacons-observation-\(UUID().uuidString).jpg")
            do {
                try jpeg.write(to: url, options: [.atomic, .completeFileProtection])
                return .success(url: url, thumbnailData: thumbnailData)
            } catch {
                try? FileManager.default.removeItem(at: url)
                return .failure("The prepared photo couldn't be saved.")
            }
        }
    }

    /// Remove the temp files this view owns: the current EXIF-stripped photo and every per-share
    /// directory. Called from performDiscard (a confirmed Discard / Start over) and from
    /// onDisappear only when the flow is IDLE - a live capture must survive tab switches (see
    /// body). Never runs while a share is in flight: the sheets keep this view "appeared" and
    /// the discard buttons are unreachable behind them. temporaryDirectory is OS-purgeable
    /// anyway, so this is housekeeping, not correctness.
    private func cleanupTemp() {
        // Invalidate any picker Task still loading. Its UUID path is private to that Task, so when
        // it eventually reaches the publish check it removes only its own file and cannot install a
        // photo after this view has gone away or collide with a later ContributeView instance.
        photoGeneration += 1
        if let photoURL { try? FileManager.default.removeItem(at: photoURL) }
        for d in shareDirs { try? FileManager.default.removeItem(at: d) }
        shareDirs = []
        photoURL = nil
        photoThumb = nil
        photoLoading = false
        photoError = nil
    }

    /// The two exits from review: SEND opens the pre-addressed email (or, with no Mail account,
    /// the share sheet with the note); SAVE always opens the file share sheet, because when Mail
    /// is configured the composer used to be the only path and Save to Files was unreachable.
    private enum DeliveryMode { case send, save }

    /// Redact the FROZEN capture CSV + note (+ EXIF-stripped photo) and present the chosen
    /// delivery surface. Only the capture window [startMs, stopMs] is exported - the CSV was
    /// rendered exactly once at Stop (see frozenCsv), so from here down the export is pure text
    /// and file work: the app's own log is untouched AND unread. Never sends on its own: the
    /// user confirms.
    ///
    /// CONCURRENCY SHAPE (do not reorder): every mutable input - frozen CSV, immutable photo URL,
    /// policy flags, and note fields - is captured synchronously before `preparing` disables every
    /// mutating control. The detached task then reads the photo once, redacts, and writes files.
    /// A missing/read-failed photo is a hard error rather than a bundle that silently omits it;
    /// every failure clears `preparing` and surfaces an alert.
    private func buildAndShare(mode: DeliveryMode) {
        guard !exportBusy else { return }
        let frozen = frozenCsv
        // Snapshot the immutable URL on MainActor, then read its potentially multi-megabyte bytes
        // in the detached build below. All photo mutation controls are disabled once `preparing`
        // flips, so cleanup/replacement cannot interleave with this read.
        let photoSourceURL = photoURL
        let subject = "beacons field observation" + (kind.map { " - \($0)" } ?? "")
        let obs = includeObserverLocation, dro = includeDroneLocation, op = includeOperatorLocation
        let kindValue = kind
        let maker = makerModel.trimmingCharacters(in: .whitespaces)
        let start = startMs, stop = stopMs
        let wantsMail = (mode == .send) && MFMailComposeViewController.canSendMail()
        preparing = true

        Task.detached(priority: .userInitiated) {
            let photoData: Data?
            if let photoSourceURL {
                do {
                    photoData = try Data(contentsOf: photoSourceURL)
                } catch {
                    await MainActor.run {
                        preparing = false
                        buildError = "The attached photo couldn't be read. Nothing was shared. Remove it or choose it again."
                    }
                    return
                }
            } else {
                photoData = nil
            }
            // Pure text ops on the artifact frozen at Stop: blank the location columns the
            // toggles exclude. No log re-read, so an ignore/clear between Stop and Share can
            // never thin the file behind the review header's count.
            let redacted = ContributionCsv.redact(frozen, blankColumns: ContributionCsv.blankColumns(
                includeObserverLocation: obs, includeDroneLocation: dro,
                includeOperatorLocation: op))
            guard let csvData = redacted.data(using: .utf8) else {
                await MainActor.run { preparing = false
                                      buildError = "The capture couldn't be encoded. Nothing was shared." }
                return
            }
            // The manifest note derives from the FINALIZED artifact, never the UI's belief: row
            // count from the actual CSV (lines minus header), and the photo clause only from the
            // attachment that ACTUALLY made it into the outgoing bundle - so the note is built
            // per delivery branch below, after the attach/write outcome is known, never from the
            // snapshot bytes alone.
            let rowCount = Self.csvRowCount(redacted)

            // Preferred send path: a REAL pre-addressed email. To:/Subject filled, note as the
            // inline body, CSV (and photo) as proper attachments. Nothing leaves until the user
            // taps Send. In-memory attachments: nothing on disk to race, and the note matches
            // what we attach. Mirrors Android's ACTION_SEND email.
            if wantsMail {
                var atts = [MailAttachment(data: csvData, mime: "text/csv", name: "beacons-observation.csv")]
                var photoAttached = false
                if let photoData {
                    atts.append(MailAttachment(data: photoData, mime: "image/jpeg", name: "beacons-observation.jpg"))
                    photoAttached = true
                }
                // Note gated on the attachment actually appended, not on the bytes existing.
                let note = Self.contributionNote(kind: kindValue, maker: maker, rowCount: rowCount,
                                                 startMs: start, stopMs: stop,
                                                 observerIncluded: obs, droneIncluded: dro,
                                                 operatorIncluded: op, hasPhoto: photoAttached)
                let bundle = MailBundle(subject: subject, recipients: ["logs@soyboi.tech"],
                                        body: note, attachments: atts)
                await MainActor.run { preparing = false; mail = bundle }
                return
            }

            // File path: SAVE A COPY always, and SEND when no Mail account exists. Materialise
            // into a FRESH per-share directory so the files are IMMUTABLE for the receiving
            // activity. loadPhoto only ever touches beacons-observation-<UUID>.jpg in the temp
            // ROOT, never this directory, so no picker Task can replace or delete these between
            // our check and the target's read - the same time-of-check/time-of-use guarantee the
            // synchronous version had. The unique parent dir keeps human-friendly filenames.
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
            else {
                await MainActor.run { preparing = false
                                      buildError = "The export file couldn't be created. Nothing was shared." }
                return
            }
            let csvURL = dir.appendingPathComponent("beacons-observation.csv")
            guard (try? csvData.write(to: csvURL,
                                      options: [.atomic, .completeFileProtection])) != nil else {
                try? FileManager.default.removeItem(at: dir)
                await MainActor.run { preparing = false
                                      buildError = "The export file couldn't be written. Nothing was shared." }
                return
            }
            var photoShareURL: URL?
            if let photoData {
                let p = dir.appendingPathComponent("beacons-observation.jpg")
                do {
                    try photoData.write(to: p, options: [.atomic, .completeFileProtection])
                    photoShareURL = p
                } catch {
                    try? FileManager.default.removeItem(at: dir)
                    await MainActor.run {
                        preparing = false
                        buildError = "The attached photo couldn't be written to the export. Nothing was shared."
                    }
                    return
                }
            }
            // Note derives from what THIS bundle actually carries, so wording and attachment
            // agree: the photo clause is gated on the per-share WRITE that succeeded
            // (photoShareURL), never on the snapshot bytes alone - a swallowed write failure
            // must not leave the note claiming "+ photo" over a bundle without one. SAVE hands
            // over bare file URLs (Save to Files then saves exactly the files); SEND's sheet
            // leads with the note, which carries the address to paste.
            let note = Self.contributionNote(kind: kindValue, maker: maker, rowCount: rowCount,
                                             startMs: start, stopMs: stop,
                                             observerIncluded: obs, droneIncluded: dro,
                                             operatorIncluded: op, hasPhoto: photoShareURL != nil)
            var items: [Any]
            if mode == .save {
                items = [csvURL]
            } else {
                items = [ContributionNote(text: note, subject: subject), csvURL]
            }
            if let photoShareURL { items.append(photoShareURL) }
            let bundle = ShareBundle(items: items)
            await MainActor.run {
                shareDirs.append(dir)   // owned by this view; removed on disappear
                preparing = false
                share = bundle
            }
        }
    }

    /// Logical CSV data records (quoted fields may contain newlines). Counting the ARTIFACT, not
    /// physical lines or UI state, keeps the manifest honest (see buildAndShare).
    nonisolated private static func csvRowCount(_ csv: String) -> Int {
        ContributionCsv.dataRowCount(csv)
    }

    /// The plain-text note accompanying the export, shared by both delivery paths (the email body
    /// and the share item). Static + pure so the off-main build task can call it on captured
    /// values without touching view state. Mirrors Android's note.
    nonisolated private static func contributionNote(kind: String?, maker: String, rowCount: Int,
                                         startMs: Int64, stopMs: Int64,
                                         observerIncluded: Bool, droneIncluded: Bool,
                                         operatorIncluded: Bool, hasPhoto: Bool) -> String {
        var note = "beacons field observation\n\n"
        note += "Visually observed: \(kind ?? "(not specified)")\n"
        if !maker.isEmpty {
            note += "Manufacturer / model: \(maker)\n"
        }
        note += "Captured \(rowCount) observation\(rowCount == 1 ? "" : "s") "
        note += "from \(clockTime(startMs)) to \(clockTime(stopMs)).\n"
        note += "\nAttached: capture window (CSV"
        note += observerIncluded ? ", your location included" : ", your location removed"
        note += "; drone aircraft coords \(droneIncluded ? "included" : "removed")"
        note += "; operator coords \(operatorIncluded ? "included" : "removed"))"
        note += hasPhoto ? " + photo (location metadata removed)" : ""
        note += ".\nSend to: logs@soyboi.tech\n\n"
        note += "This capture may contain identifiers from nearby devices. "
        note += "Shared voluntarily for signature research."
        return note
    }
}

private enum CapturePhase { case idle, capturing, review }

/// File-backed PhotosPicker import. Keeping the provider asset on disk lets ImageIO inspect and
/// downsample it without first allocating an unbounded source Data buffer. The provider-owned URL
/// is temporary, so the importer copies it to one UUID path that loadPhoto always removes.
private struct PickedPhotoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .image) { value in
            SentTransferredFile(value.url)
        } importing: { received in
            let sourceValues = try received.file.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey])
            guard sourceValues.isRegularFile == true,
                  let sourceSize = sourceValues.fileSize,
                  sourceSize > 0,
                  sourceSize <= contributionPhotoSourceByteLimit else {
                throw CocoaError(.fileReadTooLarge)
            }
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent("beacons-photo-source-\(UUID().uuidString)")
            do {
                try FileManager.default.copyItem(at: received.file, to: copy)
                // Re-check the private copy. The provider file can change between the first stat
                // and copy, so a size mismatch is a failed import rather than an unbounded or
                // partially changing source being handed to ImageIO.
                let copiedValues = try copy.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey])
                guard copiedValues.isRegularFile == true,
                      let copiedSize = copiedValues.fileSize,
                      copiedSize == sourceSize,
                      copiedSize > 0,
                      copiedSize <= contributionPhotoSourceByteLimit else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete], ofItemAtPath: copy.path)
                return PickedPhotoFile(url: copy)
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
        }
    }
}

/// Sendable output from the detached image pipeline. Only value types cross back to MainActor;
/// UIKit's full-size image objects live and die inside the worker autorelease pool.
private enum PhotoPreparationResult: Sendable {
    case success(url: URL, thumbnailData: Data)
    case failure(String)
}

/// What a confirmed "Discard this capture?" does: close the flow, return to idle for a fresh
/// start, or jump straight into a new capture window. Mirrors Android's DiscardTarget.
private enum DiscardTarget { case close, restart, newCapture }

/// Identifiable wrapper so a heterogeneous `[Any]` payload can drive `.sheet(item:)`.
private struct ShareBundle: Identifiable {
    let id = UUID()
    let items: [Any]
}

/// One in-memory email attachment (we attach Data, not file URLs, so nothing extra is written).
struct MailAttachment { let data: Data; let mime: String; let name: String }

/// Identifiable payload for the pre-addressed mail composer sheet.
private struct MailBundle: Identifiable {
    let id = UUID()
    let subject: String
    let recipients: [String]
    let body: String
    let attachments: [MailAttachment]
}

/// A genuine pre-addressed email (MFMailComposeViewController): recipient, subject and an inline
/// plain-text body, with the CSV (and photo) as real attachments. This is what makes the
/// "pre-addressed" promise true. A bare UIActivityViewController with a String item could not:
/// Apple Mail left To:/Subject empty and packaged the note as a bplist .txt attachment. The caller
/// only reaches this when canSendMail() is true; otherwise it uses ShareSheet.
struct MailComposeView: UIViewControllerRepresentable {
    let subject: String
    let recipients: [String]
    let body: String
    let attachments: [MailAttachment]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setToRecipients(recipients)
        vc.setSubject(subject)
        vc.setMessageBody(body, isHTML: false)
        for a in attachments { vc.addAttachmentData(a.data, mimeType: a.mime, fileName: a.name) }
        return vc
    }
    func updateUIViewController(_ vc: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        // Sent, saved, or cancelled - all just close the composer. The review form underneath stays,
        // so a cancel is recoverable (parity with Android's deliberate no-onDone-on-cancel).
        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

/// The note as a UIActivityItemSource for the FALLBACK share sheet (no Mail account). Returning a
/// String item plus a real Subject is the documented way to hand a mail-capable target a body and
/// subject; the recipient still can't be pre-filled by a share sheet, hence the address in the note.
private final class ContributionNote: NSObject, UIActivityItemSource {
    let text: String
    let subject: String
    init(text: String, subject: String) { self.text = text; self.subject = subject }
    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { text }
    func activityViewController(_ controller: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { text }
    func activityViewController(_ controller: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String { subject }
}
