import SwiftUI

/// The page behind every "Help me write" card.
///
/// Twelve cards, one view. What differs between them is the `AssistKind`: which
/// question gets asked, what the answer looks like, and where the answer goes
/// when you accept it. All three are properties of the kind, so splitting this
/// into twelve near-identical files would duplicate the framing — the source
/// card, the ask button, the working state, the error handling — twelve times
/// over to vary three things.
///
/// The rule the whole page obeys: **nothing is committed by the assistant.**
/// Every answer lands in an editable field, and the only thing that leaves this
/// page is what the user pressed a button to send. A small model gets things
/// wrong often enough that anything else would be a bad trade, and the edit
/// step is where most of the value is anyway — reading a draft is a much easier
/// way to work out what you want than facing an empty box.
struct AssistantActionView: View {
    let recipe: Recipe
    let kind: AssistKind
    let needsSource: Bool
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let assistant: AssistantStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onUseText: (PrefillBox.Prefill) -> Void
    let onOpenAction: (String, String?) -> Void
    let onBack: () -> Void

    /// Ambient, optional — see `TextDocsSection`. When present, what a
    /// listening model wrote about the source joins the digest, which is the
    /// closest this page's small LLM ever gets to hearing the track.
    @Environment(TextStore.self) private var textStore: TextStore?

    @State private var source: PickedMaterial?
    /// The track card's second line, resolved when the source changes.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and it
    /// was being asked for from inside `body` — so both ran again between one
    /// keystroke of the prompt field and the next. The line only depends on
    /// the material, so it is resolved with it.
    @State private var sourceMeta: String?
    @State private var choosing = false
    /// What the user typed, whatever this kind calls it.
    @State private var input = ""
    /// The second field, where a kind has one (existing lyrics, a complaint).
    @State private var secondary = ""
    @State private var language = "French"
    @State private var answers: [String: String] = [:]
    /// The draft the user is editing — seeded from the answer, then theirs.
    @State private var draft = ""
    @State private var draftLyrics = ""
    /// Which of several offered variations is selected.
    @State private var chosenVariation: String?
    @State private var applied = false

    private var slot: Slot? { recipe.slots.first }
    private var phase: AssistantStore.Phase { assistant.phase(recipe.id) }
    private var result: AssistResult? { phase.result }

    /// The music model the text is being written for.
    ///
    /// Only a preference — the assistant writes in that model's dialect, and
    /// getting it wrong costs style rather than correctness. Nothing is gated
    /// on it, which is why a machine with no generative model installed can
    /// still use every card here.
    private var targetModel: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportedTasks.contains("generate")
        }
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if needsSource {
                ActionSourceCard(
                    eyebrow: "TRACK",
                    material: source,
                    meta: sourceMeta,
                    playback: playback,
                    placeholder: sourcePlaceholder,
                    chooseTitle: source == nil ? "Choose from Library…" : "Change…",
                    onChoose: { choosing = true },
                    onRemove: source == nil ? nil : { source = nil })
            }
            if AssistantModels.installed(catalog.models).isEmpty {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "The writing assistant is not installed",
                    detail: "A small language model that runs on this Mac and "
                        + "never sends anything anywhere. It is about 0.9 GB, "
                        + "and it stays loaded alongside your music model "
                        + "rather than replacing it.",
                    onOpenModels: onOpenModels)
            } else {
                inputCard
                answerCard
            }
        } commit: {
            ActionCommitRow(title: commitTitle,
                            costLine: costLine,
                            costSubline: commitSubline,
                            isEnabled: canCommit,
                            error: errorText,
                            onCommit: { commit() },
                            onQueue: nil)
        } rail: {
            ActionRail(outputs: [],
                       explanation: railExplanation,
                       lastRun: nil)
        }
        .onAppear {
            if source == nil, let sourceId {
                source = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                library: library)
            }
            // The source-reading kinds have nothing to type, so waiting for a
            // button press would only add a click to a page whose whole job
            // is one answer.
            if autoRuns, result == nil, !phase.isWorking { ask() }
        }
        .onDisappear { assistant.clear(recipe.id) }
        .onChange(of: source?.id) { _, _ in
            assistant.clear(recipe.id)
            draft = ""
            sourceMeta = source.map {
                ActionCopy.sourceMeta($0, library: library, parts: parts)
            }
            if autoRuns, source != nil { ask() }
        }
        .sheet(isPresented: $choosing) {
            PartPickerSheet(
                slotLabel: slot?.label ?? "Track",
                accepts: slot?.accepts ?? [KindPattern(pattern: "song.mix")],
                autoDerive: slot?.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { source = $0 })
        }
    }

    // MARK: - Asking

    /// Kinds whose input is entirely the chosen track.
    private var autoRuns: Bool {
        switch kind {
        case .describeSong, .moreLikeThis, .nameAndTag: true
        default: false
        }
    }

    private var canAsk: Bool {
        guard !phase.isWorking else { return false }
        if needsSource && source == nil { return false }
        switch kind {
        case .fleshOut, .routeIntent, .pickModel, .planSong:
            return !input.trimmed.isEmpty
        case .translateLyrics:
            return !input.trimmed.isEmpty
        case .critiqueFix:
            return !input.trimmed.isEmpty
        default:
            return true
        }
    }

    private func ask(kind override: AssistKind? = nil) {
        let kind = override ?? self.kind
        assistant.ask(slot: recipe.id, kind: kind, input: payload(for: kind),
                      targetModel: targetModel)
    }

    /// What the assistant is told, per kind.
    ///
    /// The digest is the interesting part: analysis produces numbers, and a
    /// 1.5B model can do nothing with "band 5 is 0.11". `SongDigest` turns the
    /// measurements into the sentence a person would say, which is what
    /// actually gets reasoned over.
    private func payload(for kind: AssistKind) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let digest = sourceDigest
        if !digest.isEmpty { out["digest"] = .string(digest) }

        switch kind {
        case .interview:
            if !input.trimmed.isEmpty { out["idea"] = .string(input.trimmed) }
            out["answers"] = .array(answeredSoFar)
        case .interviewFinish:
            if !input.trimmed.isEmpty { out["idea"] = .string(input.trimmed) }
            out["answers"] = .array(answeredSoFar)
        case .fleshOut:
            out["idea"] = .string(input.trimmed)
        case .lyrics:
            if !input.trimmed.isEmpty { out["theme"] = .string(input.trimmed) }
            if !secondary.trimmed.isEmpty {
                out["lyrics"] = .string(secondary)
            }
        case .pickModel:
            out["idea"] = .string(input.trimmed)
            out["models"] = .array(catalogSummary)
        case .planSong:
            out["idea"] = .string(input.trimmed)
            if let seconds = Double(secondary.trimmed), seconds > 0 {
                out["duration_s"] = .double(seconds)
            }
        case .routeIntent:
            out["request"] = .string(input.trimmed)
            out["actions"] = .array(actionSummary)
        case .brief:
            if !input.trimmed.isEmpty { out["nudge"] = .string(input.trimmed) }
        case .translateLyrics:
            out["lyrics"] = .string(input)
            out["language"] = .string(language)
        case .describeSong, .nameAndTag:
            if let prompt = sourcePrompt, !prompt.isEmpty {
                out["prompt"] = .string(prompt)
            }
        case .moreLikeThis:
            out["count"] = .int(3)
            if let prompt = sourcePrompt, !prompt.isEmpty {
                out["prompt"] = .string(prompt)
            }
        case .critiqueFix:
            out["complaint"] = .string(input.trimmed)
            out["prompt"] = .string(sourcePrompt ?? secondary)
            if let plan = sourcePlanSummary { out["plan"] = .string(plan) }
        }
        return out
    }

    private var answeredSoFar: [JSONValue] {
        (result?.questions ?? []).compactMap { question in
            let answer = answers[question.question]?.trimmed ?? ""
            guard !answer.isEmpty else { return nil }
            return .object(["question": .string(question.question),
                            "answer": .string(answer)])
        }
    }

    /// The catalog, reduced to what a model needs to choose between models.
    ///
    /// Only installed-or-not, what it does, and how big it is. Sending the
    /// whole ModelInfo would spend most of the context window on parameter
    /// specs the question never turns on.
    private var catalogSummary: [JSONValue] {
        catalog.models.filter { $0.variantOf == nil }.prefix(24).map { model in
            .object([
                "id": .string(model.id),
                "name": .string(model.displayName),
                "installed": .bool(model.installState == .installed),
                "size": .string(model.sizeBytes
                                    .formatted(.byteCount(style: .file))),
                "does": .array((model.tags ?? []).map { .string($0) }),
                "lyrics": .bool(model.capabilities.supportsLyrics),
            ])
        }
    }

    /// The gallery, as a list the router can choose from. Only runnable cards:
    /// routing someone to a card that is gated or unbuilt is worse than
    /// admitting nothing fits.
    private var actionSummary: [JSONValue] {
        RecipeCatalog.all.filter { $0.isAvailable && $0.id != recipe.id }
            .map { candidate in
                .object(["id": .string(candidate.id),
                         "name": .string(candidate.name),
                         "does": .string(candidate.tagline)])
            }
    }

    private var sourceDigest: String {
        guard let source else { return "" }
        let described = (textStore?.docs(for: source.id) ?? [])
            .filter { $0.kindValue == .description || $0.kindValue == .caption }
            .map(\.text)
        return SongDigest.text(payload: analysisPayload,
                               title: source.name,
                               durationS: source.durationS,
                               prompt: sourcePrompt,
                               descriptions: described,
                               tags: library.tags(for: source.songId))
    }

    private var analysisPayload: AnalysisPayload? {
        guard let source else { return nil }
        guard let json = parts.analyses[source.analysisOwner.id]?.analysisJSON,
              let data = json.data(using: .utf8) else { return nil }
        return try? BackendClient.decoder.decode(AnalysisPayload.self, from: data)
    }

    private var sourcePrompt: String? {
        guard let source, let song = library.song(id: source.songId) else {
            return nil
        }
        return song.prompt.isEmpty ? nil : song.prompt
    }

    private var sourcePlanSummary: String? {
        guard let source, let song = library.song(id: source.songId),
              let data = song.paramsJSON.data(using: .utf8),
              let params = try? JSONDecoder().decode([String: JSONValue].self,
                                                     from: data),
              let plan = SongPlan.of(meta: params["meta"]?.objectValue) else {
            return nil
        }
        return plan.summary.isEmpty ? nil : plan.summary
    }

    // MARK: - Cards

    @ViewBuilder
    private var inputCard: some View {
        switch kind {
        case .interview:
            interviewCard
        default:
            if let field = inputField {
                ActionOptionsCard(eyebrow: field.eyebrow) {
                    VStack(alignment: .leading, spacing: 10) {
                        AssistField(text: $input,
                                        placeholder: field.placeholder,
                                        multiline: field.multiline)
                        if let second = secondField {
                            AssistField(text: $secondary,
                                            placeholder: second,
                                            multiline: kind == .lyrics)
                        }
                        if kind == .translateLyrics { languagePicker }
                        askButton
                    }
                }
            } else if !autoRuns {
                ActionOptionsCard(eyebrow: "ASK") { askButton }
            }
        }
    }

    private var askButton: some View {
        HStack(spacing: 10) {
            AssistButton(title: phase.isWorking ? kind.workingLine : askTitle,
                        tone: .accent,
                        action: { ask() })
                .disabled(!canAsk)
            if result != nil, !phase.isWorking {
                AssistButton(title: "Again", tone: .quiet, action: { ask() })
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var interviewCard: some View {
        ActionOptionsCard(eyebrow: "YOUR IDEA") {
            VStack(alignment: .leading, spacing: 10) {
                AssistField(
                    text: $input,
                    placeholder: "A few words about what you want — or leave "
                        + "this blank and let it ask",
                    multiline: false)
                if let result, !result.questions.isEmpty {
                    ForEach(result.questions) { question in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(question.question)
                                .font(Bench.Typo.body)
                                .foregroundStyle(Bench.Palette.textPrimary)
                            if !question.examples.isEmpty {
                                Text("for example: "
                                     + question.examples.joined(separator: ", "))
                                    .font(Bench.Typo.caption)
                                    .foregroundStyle(Bench.Palette.textTertiary)
                            }
                            AssistField(
                                text: Binding(
                                    get: { answers[question.question] ?? "" },
                                    set: { answers[question.question] = $0 }),
                                placeholder: "Your answer",
                                multiline: false)
                        }
                    }
                }
                HStack(spacing: 10) {
                    AssistButton(title: phase.isWorking ? kind.workingLine
                                               : (result == nil ? "Ask me questions"
                                                                : "More questions"),
                        tone: result == nil ? .accent : .quiet,
                        action: { ask(kind: .interview) })
                        .disabled(phase.isWorking)
                    if result != nil && !answeredSoFar.isEmpty {
                        AssistButton(title: "Write the description",
                                    tone: .accent,
                                    action: { ask(kind: .interviewFinish) })
                            .disabled(phase.isWorking)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var answerCard: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .working(let working):
            ActionOptionsCard(eyebrow: "WORKING") {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(working.workingLine)
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textSecondary)
                }
            }
        case .failed(let message):
            ActionOptionsCard(eyebrow: "DIDN'T WORK") {
                ActionFootnote(text: message)
            }
        case .done(let result):
            answerBody(result)
        }
    }

    @ViewBuilder
    private func answerBody(_ result: AssistResult) -> some View {
        ActionOptionsCard(eyebrow: answerEyebrow) {
            VStack(alignment: .leading, spacing: 12) {
                if !result.ok {
                    // The structured read failed but the words are real. Far
                    // better to show them and let the user edit than to
                    // report an error over an answer that exists.
                    ActionFootnote(
                        text: "It didn't answer in the expected shape, so "
                            + "here is what it wrote. Edit it as you like.")
                    AssistField(text: $draft, placeholder: "",
                                    multiline: true)
                } else {
                    structured(result)
                }
            }
        }
        .onAppear { seed(from: result) }
        .onChange(of: result) { _, new in seed(from: new) }
    }

    @ViewBuilder
    private func structured(_ result: AssistResult) -> some View {
        switch result.kind {
        case .interview:
            // The questions live in the input card, which is where they are
            // answered. Repeating them here would only ask twice.
            if result.interviewIsDone {
                ActionFootnote(text: "That's enough to go on — press "
                               + "\"Write the description\".")
            }
        case .pickModel:
            modelPicks(result)
        case .planSong:
            planSections(result)
        case .routeIntent:
            routeAnswer(result)
        case .moreLikeThis:
            variations(result)
        case .nameAndTag:
            nameAndTags(result)
        case .lyrics, .translateLyrics:
            AssistField(text: $draftLyrics, placeholder: "", multiline: true)
            if !result.title.isEmpty {
                Text("Suggested title: \(result.title)")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textTertiary)
            }
        default:
            AssistField(text: $draft, placeholder: "", multiline: true)
            extras(result)
        }
    }

    @ViewBuilder
    private func extras(_ result: AssistResult) -> some View {
        if !result.addedDetails.isEmpty {
            detailList(title: "It added", items: result.addedDetails)
        }
        if !result.changes.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("WHAT CHANGED")
                    .eyebrow()
                ForEach(result.changes) { change in
                    Text("\(change.before.isEmpty ? "—" : change.before) → "
                         + "\(change.after)")
                        .font(Bench.Typo.metaLine)
                        .foregroundStyle(Bench.Palette.textSecondary)
                }
            }
        }
        if !result.idea.isEmpty {
            Text(result.idea)
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textSecondary)
        }
        if !result.description.isEmpty, result.kind == .describeSong {
            Text(result.description)
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textPrimary)
        }
    }

    private func detailList(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .eyebrow()
            ForEach(items, id: \.self) { item in
                Text("· \(item)")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func modelPicks(_ result: AssistResult) -> some View {
        if let best = result.modelPick {
            pickRow(best, emphasis: true)
        }
        ForEach(result.modelAlternatives) { pick in
            pickRow(pick, emphasis: false)
        }
        if result.modelPick == nil && result.modelAlternatives.isEmpty {
            ActionFootnote(text: "It didn't settle on one.")
        }
    }

    private func pickRow(_ pick: AssistModelPick, emphasis: Bool) -> some View {
        let model = catalog.models.first { $0.id == pick.modelId }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(model?.displayName ?? pick.modelId)
                    .font(emphasis ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let model, model.installState != .installed {
                    BenchBadge(model.sizeBytes
                        .formatted(.byteCount(style: .file)), tone: .warn)
                } else if model != nil {
                    BenchBadge("INSTALLED", tone: .ok)
                }
                Spacer()
            }
            if !pick.why.isEmpty {
                Text(pick.why)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textSecondary)
            }
            // Named a model that is not in the catalog. It happens with a model
            // this size, and saying so is better than a row that does nothing.
            if model == nil {
                Text("That model isn't in your catalog.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.warn)
            }
        }
    }

    @ViewBuilder
    private func planSections(_ result: AssistResult) -> some View {
        if result.sections.isEmpty {
            ActionFootnote(text: "It didn't produce a shape.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(result.sections) { section in
                    HStack(alignment: .top, spacing: 8) {
                        Text(section.tag)
                            .font(Bench.Typo.metaLine)
                            .foregroundStyle(Bench.Palette.violet)
                            .frame(width: 96, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.what)
                                .font(Bench.Typo.body)
                                .foregroundStyle(Bench.Palette.textPrimary)
                            if section.seconds > 0 {
                                Text("\(section.seconds)s")
                                    .font(Bench.Typo.caption)
                                    .foregroundStyle(Bench.Palette.textTertiary)
                            }
                        }
                        Spacer()
                    }
                }
            }
            if !result.summary.isEmpty {
                ActionFootnote(text: result.summary)
            }
        }
    }

    @ViewBuilder
    private func routeAnswer(_ result: AssistResult) -> some View {
        if let route = result.route, let target = route.recipe {
            VStack(alignment: .leading, spacing: 6) {
                Text(target.name)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text(target.tagline)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textSecondary)
                if !route.reason.isEmpty {
                    ActionFootnote(text: route.reason)
                }
            }
        } else {
            ActionFootnote(
                text: result.route?.reason.isEmpty == false
                    ? result.route!.reason
                    : "Nothing here matches that. Try describing the result "
                        + "you want rather than the steps.")
        }
    }

    @ViewBuilder
    private func variations(_ result: AssistResult) -> some View {
        if result.variations.isEmpty {
            ActionFootnote(text: "It didn't come up with any.")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(result.variations) { variation in
                    Button {
                        chosenVariation = variation.prompt
                        draft = variation.prompt
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(variation.prompt)
                                .font(Bench.Typo.body)
                                .foregroundStyle(Bench.Palette.textPrimary)
                                .multilineTextAlignment(.leading)
                            if !variation.differs.isEmpty {
                                Text(variation.differs)
                                    .font(Bench.Typo.caption)
                                    .foregroundStyle(Bench.Palette.textTertiary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(chosenVariation == variation.prompt
                                      ? Bench.Palette.accent.opacity(0.14)
                                      : Color.clear))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(chosenVariation == variation.prompt
                                        ? Bench.Palette.accent
                                        : Bench.Palette.hairline,
                                        lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func nameAndTags(_ result: AssistResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            AssistField(text: $draft, placeholder: "Title", multiline: false)
            if !result.tags.isEmpty {
                detailList(title: "Tags", items: result.tags)
            }
            if applied {
                ActionFootnote(text: "Saved to the library.")
            }
        }
    }

    // MARK: - Seeding the editable draft

    /// Copy the answer into the fields the user edits — once per answer.
    ///
    /// Guarded on emptiness so that re-rendering the view does not overwrite an
    /// edit in progress. A fresh answer clears the draft first (see `ask`'s
    /// callers), so this does fire again when it should.
    private func seed(from result: AssistResult) {
        if draft.isEmpty {
            draft = switch result.kind {
            case .nameAndTag: result.title
            case .describeSong: result.prompt.isEmpty ? result.description
                                                      : result.prompt
            case .moreLikeThis: result.variations.first?.prompt ?? ""
            default: result.ok ? result.prompt : result.raw
            }
        }
        if draftLyrics.isEmpty, result.kind.producesLyrics {
            draftLyrics = result.lyricsText.isEmpty ? result.raw
                                                    : result.lyricsText
        }
        if chosenVariation == nil {
            chosenVariation = result.variations.first?.prompt
        }
    }

    // MARK: - Copy

    private struct InputField {
        var eyebrow: String
        var placeholder: String
        var multiline: Bool
    }

    private var inputField: InputField? {
        switch kind {
        case .fleshOut:
            InputField(eyebrow: "YOUR IDEA",
                       placeholder: "e.g. something sad with a piano",
                       multiline: false)
        case .lyrics:
            InputField(eyebrow: "WHAT IT'S ABOUT",
                       placeholder: "e.g. leaving a town you grew up in",
                       multiline: false)
        case .pickModel:
            InputField(eyebrow: "WHAT YOU WANT TO MAKE",
                       placeholder: "e.g. a full song with singing, about "
                            + "three minutes",
                       multiline: false)
        case .planSong:
            InputField(eyebrow: "THE SONG",
                       placeholder: "e.g. a slow build from quiet piano to a "
                            + "big chorus",
                       multiline: false)
        case .routeIntent:
            InputField(eyebrow: "WHAT DO YOU WANT TO DO?",
                       placeholder: "e.g. make a karaoke version of this song",
                       multiline: false)
        case .brief:
            InputField(eyebrow: "NUDGE IT (OPTIONAL)",
                       placeholder: "e.g. something with strings",
                       multiline: false)
        case .translateLyrics:
            InputField(eyebrow: "LYRICS",
                       placeholder: "Paste the lyrics to translate",
                       multiline: true)
        case .critiqueFix:
            InputField(eyebrow: "WHAT'S WRONG WITH IT?",
                       placeholder: "e.g. too busy, and the drums are too loud",
                       multiline: false)
        default:
            nil
        }
    }

    private var secondField: String? {
        switch kind {
        case .lyrics: "Lines you've already written (optional)"
        case .planSong: "How long, in seconds (optional)"
        default: nil
        }
    }

    private var languagePicker: some View {
        Picker("Into", selection: $language) {
            ForEach(["French", "Spanish", "German", "Italian", "Portuguese",
                     "Japanese", "Korean", "Mandarin Chinese", "Swedish",
                     "Polish", "Turkish", "Hindi"], id: \.self) {
                Text($0).tag($0)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 220, alignment: .leading)
    }

    private var askTitle: String {
        switch kind {
        case .fleshOut: "Flesh it out"
        case .lyrics: "Write the lyrics"
        case .pickModel: "Recommend one"
        case .planSong: "Sketch the shape"
        case .routeIntent: "Work it out"
        case .brief: "Surprise me"
        case .translateLyrics: "Translate"
        case .critiqueFix: "Rewrite it"
        case .describeSong: "Describe it"
        case .moreLikeThis: "Find the family"
        case .nameAndTag: "Name it"
        default: "Ask"
        }
    }

    private var answerEyebrow: String {
        switch kind {
        case .lyrics, .translateLyrics: "LYRICS"
        case .pickModel: "RECOMMENDED"
        case .planSong: "THE SHAPE"
        case .routeIntent: "THAT WOULD BE"
        case .moreLikeThis: "THREE WAYS"
        case .nameAndTag: "TITLE & TAGS"
        case .describeSong: "WHAT IT SOUNDS LIKE"
        default: "DRAFT — EDIT FREELY"
        }
    }

    private var sourcePlaceholder: String {
        switch kind {
        case .nameAndTag: "The track to name."
        case .critiqueFix: "The track that came out wrong."
        default: "A song or part from your library."
        }
    }

    private var railExplanation: String {
        switch kind {
        case .routeIntent:
            "Nothing runs from here — it finds the card that does the job and "
                + "opens it with what you said already filled in."
        case .pickModel:
            "A recommendation, not an installation. Nothing is downloaded "
                + "until you say so on the Models screen."
        case .nameAndTag:
            "The title and tags are written onto the track in your library. "
                + "Nothing about the audio changes."
        default:
            "A draft you can edit. When you're happy with it, it goes into "
                + "Generate with the model already chosen — nothing renders "
                + "until you press the button there."
        }
    }

    // MARK: - Committing

    private var commitTitle: String {
        switch kind {
        case .routeIntent: "Open that action"
        case .pickModel: "Show me in Models"
        case .nameAndTag: applied ? "Saved" : "Save to library"
        case .lyrics, .translateLyrics: "Use these lyrics"
        default: "Use this in Generate"
        }
    }

    private var commitSubline: String? {
        switch kind {
        case .nameAndTag: "THE AUDIO IS UNTOUCHED"
        case .routeIntent, .pickModel: nil
        default: "NOTHING RENDERS YET"
        }
    }

    private var costLine: String? {
        switch kind {
        case .routeIntent: result?.route?.recipe.map { "GOES TO › \($0.name)" }
        case .pickModel: nil
        case .nameAndTag: "SAVED TO LIBRARY"
        default: "GOES TO › GENERATE"
        }
    }

    private var canCommit: Bool {
        guard let result else { return false }
        switch kind {
        case .routeIntent: return result.route?.recipe != nil
        case .pickModel: return result.modelPick != nil
        case .nameAndTag: return !draft.trimmed.isEmpty && !applied
        case .lyrics, .translateLyrics: return !draftLyrics.trimmed.isEmpty
        default: return !draft.trimmed.isEmpty
        }
    }

    private var errorText: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    private func commit() {
        guard let result else { return }
        switch kind {
        case .routeIntent:
            guard let route = result.route, let target = route.recipe else { return }
            onOpenAction(target.id, source?.id ?? route.subject)
        case .pickModel:
            onOpenModels()
        case .nameAndTag:
            applyNameAndTags(result)
        case .lyrics, .translateLyrics:
            onUseText(.init(prompt: sourcePrompt ?? "",
                            lyrics: draftLyrics,
                            modelId: lyricCapableModel?.id,
                            notice: "Lyrics written by the assistant. "
                                + "Edit them here before rendering."))
        default:
            onUseText(.init(prompt: draft.trimmed,
                            modelId: targetModel?.id,
                            notice: noticeForUse))
        }
    }

    private var noticeForUse: String {
        switch kind {
        case .critiqueFix: "Rewritten to fix what you said was wrong."
        case .moreLikeThis: "In the same vein as \(source?.name ?? "your track")."
        case .describeSong: "Described from \(source?.name ?? "your track")."
        default: "Drafted by the writing assistant. Edit freely."
        }
    }

    /// A model that can actually sing the lyrics we just wrote. Falling back to
    /// the general target would land lyrics on a model that ignores them.
    private var lyricCapableModel: ModelInfo? {
        catalog.models.first {
            $0.installState == .installed
                && $0.capabilities.supportsLyrics
                && $0.capabilities.supportedTasks.contains("generate")
        }
    }

    /// Write the title and tags onto the song.
    ///
    /// Tags go into `notes` rather than a column of their own: the library's
    /// search already indexes notes, so they become findable immediately, and
    /// a schema migration for what is currently one card's output would be the
    /// wrong order to do things in. Appended, never replacing — the user's own
    /// notes are not the assistant's to overwrite.
    private func applyNameAndTags(_ result: AssistResult) {
        guard let source, var song = library.song(id: source.songId) else { return }
        let wanted = draft.trimmed
        guard !wanted.isEmpty else { return }
        let old = song.title
        let unique = library.titleIsTaken(wanted, excluding: song.id)
            ? library.uniqueTitle(wanted) : wanted
        song.title = unique
        if !result.tags.isEmpty {
            let line = result.tags.joined(separator: ", ")
            song.notes = song.notes.isEmpty ? line
                                            : song.notes + "\n" + line
        }
        library.update(song)
        library.renameParts(ofSong: song.id, from: old, to: unique)
        applied = true
    }
}

// MARK: - Small pieces this page needs
//
// `ActionTextField` is single-line by construction and `StudioPromptEditor`
// carries Studio's own fixed placeholder, so neither fits a page that needs
// both shapes with its own wording. These two wrap the same look rather than
// re-styling anything.

/// One field, single- or multi-line depending on what is being written.
struct AssistField: View {
    @Binding var text: String
    var placeholder: String
    var multiline = false

    var body: some View {
        if multiline {
            TextEditor(text: $text)
                .tint(Bench.Palette.accent)
                .font(Bench.Typo.body)
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .foregroundStyle(Bench.Palette.textPrimary)
                .frame(minHeight: 96)
                .padding(.horizontal, 7).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Bench.Palette.inset))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(Bench.Palette.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty && !placeholder.isEmpty {
                        Text(placeholder)
                            .font(Bench.Typo.body)
                            .foregroundStyle(Bench.Palette.textFaint)
                            // 5 pt is TextEditor's own lineFragmentPadding; the
                            // rest matches the padding above, so the
                            // placeholder sits exactly where typing begins.
                            .padding(.leading, 12).padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
        } else {
            ActionTextField(placeholder: placeholder, text: $text)
        }
    }
}

/// A button in one of this page's two weights.
struct AssistButton: View {
    let title: String
    var tone: Tone = .accent
    let action: () -> Void

    enum Tone { case accent, quiet }

    var body: some View {
        Button(title, action: action)
            .buttonStyle(BenchSecondaryButtonStyle())
            .opacity(tone == .accent ? 1 : 0.8)
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
