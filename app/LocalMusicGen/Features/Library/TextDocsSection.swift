import SwiftUI

/// The text documents on one song or part — descriptions, transcribed
/// lyrics, Q&A answers, tags, notation — grouped by kind, each slot
/// attributed, editable, copyable and deletable.
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

    @Environment(TextStore.self) private var textStore: TextStore?
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    @State private var editingId: String?
    @State private var draft = ""
    @State private var confirmDeleteId: String?

    private var docs: [TextDocRecord] {
        textStore?.docs(for: ownerId) ?? []
    }

    /// Kinds in reading order: what it is, what it says, what it sang,
    /// what it scored, how it is written.
    private static let kindOrder: [TextDocKind] =
        [.description, .caption, .qa, .lyrics, .tags, .abc]

    var body: some View {
        if textStore != nil, !(docs.isEmpty && onDescribe == nil) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Self.kindOrder, id: \.self) { kind in
                    let group = docs.filter { $0.kindValue == kind }
                    if !group.isEmpty {
                        Text(Self.eyebrow(kind, count: group.count)).eyebrow()
                        ForEach(group) { doc in
                            slot(doc)
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
            } else {
                Text(doc.text)
                    .font(doc.kindValue == .abc ? Bench.Typo.mono(12)
                                                : Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                Text(attribution(doc))
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                Spacer()
                if editingId == doc.id {
                    Button("Cancel") { editingId = nil }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    Button("Done") { commit(doc) }
                        .buttonStyle(BenchSecondaryButtonStyle())
                } else {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(doc.text,
                                                       forType: .string)
                    }
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    Button("Edit") {
                        draft = doc.text
                        editingId = doc.id
                    }
                    .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                    Button("Delete") { requestDelete(doc) }
                        .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10)
            .fill(Bench.Palette.inset.opacity(0.6)))
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
                textStore?.insert(doc)
                draft = ""
                editingId = doc.id
            }
            .buttonStyle(BenchSecondaryButtonStyle(tone: .quiet))
        }
    }

    // MARK: - Mutations

    private func commit(_ doc: TextDocRecord) {
        editingId = nil
        var updated = doc
        updated.text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
