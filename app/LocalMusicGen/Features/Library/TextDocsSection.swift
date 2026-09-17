import SwiftUI

/// The text documents on one song or part — descriptions, transcribed
/// lyrics, Q&A answers, tags, notation — grouped by kind, each slot
/// attributed, editable, copyable and deletable. A kind that has been run
/// more than once shows one result at a time, on a strip of tabs named for
/// their sources.
///
/// Reads the ambient `TextStore` the way panes read `AppSettings`: previews
/// and tests host these panes without an environment, and "no store" must
/// read as "no section" rather than a crash.
///
/// Editing is explicit (Edit → Done), not debounced like notes: several
/// slots can be on screen at once, and one committed buffer per edit beats a
/// dictionary of timers racing a delete.
struct TextDocsSection: View {
    let ownerId: String
    let ownerType: String           // "song" | "part"
    let playback: PlaybackController?
    /// What "Describe…" does — routes to the listening card. nil hides it.
    var onDescribe: (() -> Void)?
    /// What "Open" on a notation slot does. The host resolves the document
    /// into a `NotationDocument` and presents `NotationSheet`, because only
    /// the host knows the song's parts and has a route to the renderer. nil
    /// hides the button.
    var onOpenNotation: ((TextDocRecord) -> Void)?

    @Environment(TextStore.self) private var textStore: TextStore?
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    @State private var editingId: String?
    @State private var draft = ""
    @State private var confirmDeleteId: String?
    /// A "Write my own ＋" document that is being typed but has not been
    /// written yet. The row used to be inserted blank the moment the button was
    /// pressed, so Cancel — and Done on an untouched draft — left a permanent
    /// empty card attributed to YOU.
    @State private var pendingDoc: TextDocRecord?
    /// Notation slots showing their ABC source instead of the engraving.
    @State private var showingABCText: Set<String> = []
    /// What the page said about each notation slot's last engraving. A report
    /// of no tunes switches the slot to its text; one taller than the cap adds
    /// "Open to see all". Cleared when the text is edited, so a document
    /// typed into real notation is engraved again rather than staying prose.
    @State private var renders: [String: NotationRender] = [:]
    /// Which document each kind's strip is on, by kind, while there is more
    /// than one. Ids rather than positions: a delete or a refresh reorders
    /// nothing under the reader's choice, and an id that stops matching —
    /// the pane moved to another song — simply falls back to the newest.
    @State private var selectedTab: [TextDocKind: String] = [:]

    /// How tall a slot's score may grow before it defers to the sheet. A
    /// four-voice transcription is a page of SVG, and the pane is a column.
    static let scoreHeightCap: CGFloat = 360

    private var docs: [TextDocRecord] {
        textStore?.docs(for: ownerId) ?? []
    }

    /// The stored documents of one kind, plus the uncommitted new one while it
    /// is the slot being edited.
    private func rows(of kind: TextDocKind) -> [TextDocRecord] {
        var rows = docs.filter { $0.kindValue == kind }
        if let pendingDoc, pendingDoc.kindValue == kind,
           editingId == pendingDoc.id {
            rows.append(pendingDoc)
        }
        return rows
    }

    /// Kinds in reading order: what it is, what it says, what it sang,
    /// what it scored, how it is written.
    private static let kindOrder: [TextDocKind] =
        [.description, .caption, .qa, .lyrics, .tags, .abc]

    var body: some View {
        if textStore != nil,
           !(docs.isEmpty && pendingDoc == nil && onDescribe == nil) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.kindOrder, id: \.self) { kind in
                    let group = rows(of: kind)
                    if !group.isEmpty {
                        Text(Self.eyebrow(kind, count: group.count)).eyebrow()
                        if Self.tabbed(kind), group.count > 1,
                           let shown = Self.shown(group,
                                                  selected: selectedTab[kind]) {
                            // Run twice — a second tagger, lyrics from
                            // another model, notation re-extracted — a kind
                            // used to stack every result under one eyebrow,
                            // and the pane read as the section repeating
                            // itself. One at a time, chosen by its source.
                            BenchSegmented(
                                selection: Binding(
                                    get: { shown.id },
                                    set: { selectedTab[kind] = $0 }),
                                options: Self.tabs(for: group), fills: true)
                            slot(shown)
                        } else {
                            ForEach(group) { doc in
                                slot(doc)
                            }
                        }
                    }
                }
                addRow
            }
            .confirmationDialog(
                "Delete this text?",
                isPresented: Binding(
                    get: { confirmDeleteId != nil },
                    set: { if !$0 { confirmDeleteId = nil } })) {
                Button("Delete text", role: .destructive) {
                    if let id = confirmDeleteId,
                       let doc = docs.first(where: { $0.id == id }) {
                        textStore?.delete(doc)
                    }
                    confirmDeleteId = nil
                }
            }
        }
    }

    // MARK: - One slot

    @ViewBuilder
    private func slot(_ doc: TextDocRecord) -> some View {
        // `segments` decodes `segmentsJSON` on every read, and the branch
        // below wants the answer twice — once to choose the timed layout,
        // once to draw it. Decoded here so a slot costs one, and so the two
        // reads cannot disagree about whether there are any.
        let segments = doc.kindValue == .lyrics ? doc.segments : []
        VStack(alignment: .leading, spacing: 6) {
            if let question = doc.question, !question.isEmpty {
                Text(question)
                    .font(Bench.Typo.body.italic())
                    .foregroundStyle(Bench.Palette.textFaint)
            }
            if editingId == doc.id {
                TextEditor(text: $draft)
                    .font(doc.kindValue == .abc ? Bench.Typo.mono(12)
                                                : Bench.Typo.body)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .frame(minHeight: 72)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Bench.Palette.inset))
            } else if !segments.isEmpty {
                segmentLines(segments)
            } else if doc.kindValue == .abc, showsScore(doc) {
                score(doc)
            } else {
                Text(doc.text)
                    .font(doc.kindValue == .abc ? Bench.Typo.mono(12)
                                                : Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if renders[doc.id]?.isEmpty == true {
                    // A prose reply filed as ABC — the bug `abc_convert`
                    // fixed on the engine side, still in old rows. abcjs's
                    // "no tunes" is the whole test; the source still reads,
                    // and says why it is the source you are reading.
                    Text("Could not draw this as notation — showing the source.")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            verbRow(doc)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Bench.Palette.inset.opacity(0.6)))
    }

    /// Whether a notation slot draws its score: not while the source is
    /// open, and not once the page has said there is no score in it.
    private func showsScore(_ doc: TextDocRecord) -> Bool {
        !showingABCText.contains(doc.id) && renders[doc.id]?.isEmpty != true
    }

    /// The engraving, at the pane's density and capped in height; past the
    /// cap the sheet is where the rest is.
    private func score(_ doc: TextDocRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            NotationView(abc: doc.text, scale: 0.8,
                         maxHeight: Self.scoreHeightCap,
                         onRendered: { renders[doc.id] = $0 })
            if let render = renders[doc.id],
               CGFloat(render.height) > Self.scoreHeightCap {
                Text(onOpenNotation == nil ? "Showing the first part"
                                           : "Open to see all")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
    }

    /// Attribution and the slot's verbs.
    ///
    /// A notation slot has two verbs more than any other, and five quiet
    /// buttons beside a `BASIC PITCH · 2 D AGO` line do not fit a 344 pt
    /// pane on one row — the labels came out as "Sh…" and "De…". That slot
    /// stacks the attribution over a wrapping row instead; every other slot
    /// keeps the one-line shape it always had.
    @ViewBuilder
    private func verbRow(_ doc: TextDocRecord) -> some View {
        if doc.kindValue == .abc, editingId != doc.id {
            VStack(alignment: .leading, spacing: 6) {
                attributionText(doc)
                FlowLayout(spacing: 6, rowSpacing: 6) {
                    if let onOpenNotation {
                        Button("Open") { onOpenNotation(doc) }
                            .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    }
                    // Nothing to switch to once the page has said the text is
                    // not a score: the slot is already showing the source.
                    if renders[doc.id]?.isEmpty != true {
                        Button(showingABCText.contains(doc.id)
                               ? "Show score" : "Show ABC") {
                            if showingABCText.contains(doc.id) {
                                showingABCText.remove(doc.id)
                            } else {
                                showingABCText.insert(doc.id)
                            }
                        }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    }
                    verbs(doc)
                }
            }
        } else {
            HStack(spacing: 8) {
                attributionText(doc)
                Spacer()
                if editingId == doc.id {
                    Button("Cancel") { cancelEdit() }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    Button("Done") { commit(doc) }
                        .buttonStyle(BenchSecondaryButtonStyle())
                } else {
                    verbs(doc)
                }
            }
        }
    }

    private func attributionText(_ doc: TextDocRecord) -> some View {
        Text(attribution(doc))
            .font(Bench.Typo.mono(10))
            .foregroundStyle(Bench.Palette.textFaintest)
    }

    /// Copy · Edit · Delete — the verbs every slot has.
    @ViewBuilder
    private func verbs(_ doc: TextDocRecord) -> some View {
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(doc.text, forType: .string)
        }
        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
        Button("Edit") {
            // One draft buffer: starting another edit abandons an
            // untyped new document rather than stranding it.
            pendingDoc = nil
            draft = doc.text
            editingId = doc.id
        }
        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
        Button("Delete") { requestDelete(doc) }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
    }

    /// Transcribed lyrics as tappable timestamped lines: a tap seeks the
    /// transport when this track is what is playing.
    private func segmentLines(
        _ segments: [TextPayload.Segment]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                Button {
                    if let playback, playback.currentSongId == ownerId {
                        playback.seek(to: seg.startS)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.stamp(seg.startS))
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textFaintest)
                        Text(seg.text)
                            .font(Bench.Typo.body)
                            .foregroundStyle(Bench.Palette.textPrimary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 8) {
            if let onDescribe {
                Button("Describe with a model…", action: onDescribe)
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
            }
            Button("Write my own ＋") {
                let doc = TextDocRecord(
                    id: UUID().uuidString.lowercased(),
                    ownerId: ownerId, ownerType: ownerType,
                    kind: TextDocKind.description.rawValue, text: "",
                    segmentsJSON: nil, question: nil, language: nil,
                    modelId: "", modelName: "You", jobId: nil,
                    edited: false, createdAt: Date(), updatedAt: Date())
                // Held, not inserted: nothing reaches the database until Done
                // with something in it.
                pendingDoc = doc
                draft = ""
                editingId = doc.id
                // It joins the strip beside the stored descriptions, and a
                // new card you cannot see is one you cannot type into.
                selectedTab[.description] = doc.id
            }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
        }
    }

    // MARK: - Mutations

    private func cancelEdit() {
        editingId = nil
        pendingDoc = nil    // never written, so there is nothing to clean up
        draft = ""
    }

    private func commit(_ doc: TextDocRecord) {
        editingId = nil
        // The engraving starts over for the new text: a verdict of "no
        // tunes" on the old text must not keep a corrected score in prose.
        renders[doc.id] = nil
        showingABCText.remove(doc.id)
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingDoc?.id == doc.id {
            // Not in the database yet, so an empty draft means "never written"
            // rather than "emptied slot to delete".
            pendingDoc = nil
            guard !text.isEmpty else { return }
            var created = doc
            created.text = text
            created.updatedAt = Date()
            textStore?.insert(created)
            return
        }
        var updated = doc
        updated.text = text
        guard updated.text != doc.text else { return }
        if updated.text.isEmpty {
            // An emptied slot is a deleted slot — a blank card with a model
            // attribution would claim the model wrote nothing.
            textStore?.delete(doc)
            return
        }
        updated.edited = true
        updated.updatedAt = Date()
        textStore?.save(updated)
    }

    private func requestDelete(_ doc: TextDocRecord) {
        if appSettings?.confirmDeletes ?? true {
            confirmDeleteId = doc.id
        } else {
            textStore?.delete(doc)
        }
    }

    // MARK: - Tabs

    /// Whether a kind shows one document at a time. Q&A is the exception:
    /// its documents are answers to different questions — a list, not
    /// re-runs of one thing — and a strip of the same model name three times
    /// over would say nothing about which answer is which.
    static func tabbed(_ kind: TextDocKind) -> Bool {
        kind != .qa
    }

    /// The strip for one kind's documents, in the store's order (newest
    /// first). A tab is its source — the model, or YOU — and only when the
    /// same source wrote more than one does the tab also say when, so two
    /// WHISPER tabs can be told apart without opening both.
    static func tabs(for docs: [TextDocRecord],
                     now: Date = Date()) -> [BenchSegmented<String>.Option] {
        var runs: [String: Int] = [:]
        for doc in docs { runs[doc.modelName, default: 0] += 1 }
        return docs.map { doc in
            .init(value: doc.id, label: doc.modelName,
                  detail: runs[doc.modelName, default: 0] > 1
                      ? tabStamp(doc.createdAt, now: now) : nil)
        }
    }

    /// The document a strip shows: the chosen one while it still exists,
    /// otherwise the newest. Deleting the one on screen, or the pane moving
    /// to a song whose documents have other ids, lands on the newest rather
    /// than on nothing.
    static func shown(_ docs: [TextDocRecord],
                      selected: String?) -> TextDocRecord? {
        docs.first { $0.id == selected } ?? docs.first
    }

    /// `20:03` for a run today, `16 Sep` for an older one: the shortest thing
    /// that separates two runs of one model in the room a 344 pt pane leaves
    /// a tab, and the card's own attribution line carries the rest.
    static func tabStamp(_ date: Date, now: Date) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    // MARK: - Copy

    static func eyebrow(_ kind: TextDocKind, count: Int) -> String {
        switch kind {
        case .description: count > 1 ? "DESCRIPTIONS" : "DESCRIPTION"
        case .caption: "CAPTION"
        case .qa: "Q&A"
        case .lyrics: "LYRICS (TRANSCRIBED)"
        case .tags: "TAGS (SCORED)"
        case .abc: "NOTATION"
        }
    }

    private func attribution(_ doc: TextDocRecord) -> String {
        var bits = [doc.modelName.uppercased()]
        bits.append(Self.ago(doc.createdAt).uppercased())
        if doc.edited { bits.append("EDITED") }
        if let language = doc.language, !language.isEmpty {
            bits.append(language.uppercased())
        }
        return bits.joined(separator: " · ")
    }

    static func stamp(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Built once and kept. `RelativeDateTimeFormatter` resolves a locale
    /// and a calendar when it is constructed, and `attribution` asks for one
    /// of these per document slot — on a pane that redraws with the playhead
    /// that was a formatter per slot, four times a second.
    ///
    /// On the actor because it is a class with settings on it and no
    /// `Sendable` conformance; every caller is already drawing.
    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    @MainActor private static func ago(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}
