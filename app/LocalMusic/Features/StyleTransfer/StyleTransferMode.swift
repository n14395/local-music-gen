import Foundation

/// What the user wants to **keep**, and what that means on the wire.
///
/// Pure and store-free, in the style of `ModelListLayout` and
/// `OnboardingPlan`: the whole semantic layer of Style Transfer is a mapping
/// from a musician's intent onto a set of engine params, and that mapping is
/// exactly the kind of thing that deserves a test rather than a screenshot.
///
/// ## Why "what survives" is the organising idea
///
/// Style transfer in audio does not work the way it does in images. The image
/// technique (Gatys) matches Gram matrices, which work *because* they throw
/// away spatial position — perfect for texture. A spectrogram's horizontal
/// axis is time, so throwing away position there destroys rhythm, meter and
/// structure, which is substantially the music. What actually works is
/// conditioning a generative model on a reference, and every model here
/// preserves a **different** axis: chroma keeps melody and harmony but not
/// timbre; ACE-Step's cover keeps the tune and the words but re-performs the
/// production; repaint keeps everything outside a window; stem separation
/// keeps a chosen stem *literally*, the only lossless option on the list.
///
/// A user who does not know which axis a mode preserves cannot tell a bad
/// result from the wrong tool. So each mode carries its own honest one-liner
/// (`survives`), rendered under the control rather than buried in help.
enum StyleTransferMode: String, CaseIterable, Identifiable, Codable, Sendable {

    // MARK: Restyle the whole thing

    /// `task_type=cover` — the workhorse. Melody and lyrics survive.
    case cover
    /// `reference_audio` — "sound like this". Works with or without a source,
    /// because upstream VAE-encodes the reference for *every* task, not just
    /// cover (see the note on `wireTask(hasSource:)`).
    case reference
    /// `melody_audio` — chroma conditioning. MusicGen's melody builds.
    case melody
    /// `task_type=text2music` + `flow_edit_morph` — a caption-to-caption morph
    /// that, unlike extract/lego/complete, runs on the **turbo** DiT and so is
    /// reachable from a default install.
    case morph
    /// `init_audio` + `init_noise_level` — Stable Audio's audio-to-audio.
    case shape
    /// Split, restyle the rest, mix the kept stems back in. Not one job — see
    /// `StyleTransferChain`.
    case stems

    // MARK: Change part of it

    /// `task_type=repaint` over a selected window.
    case repaint
    /// `task_type=complete` — fill in what the arrangement is missing.
    case complete
    /// `extend_audio` — keep the whole source, append new audio.
    case continueTrack = "continue"

    // MARK: Make a new part

    /// `task_type=lego` — a new layer over the source. Output is a **part**.
    case layer
    /// `task_type=extract` — pull a stem out generatively. Output is a part.
    case extract

    var id: String { rawValue }

    // MARK: - Grouping

    /// The three shelves the mode chips sit on. Not derivable from the wire —
    /// `complete` and `layer` are both ACE-Step tasks over a whole source, but
    /// one returns a song and the other returns material, which is the
    /// difference a musician actually feels.
    enum Group: String, CaseIterable, Identifiable, Sendable {
        case restyle, rework, parts

        var id: String { rawValue }

        var title: String {
            switch self {
            case .restyle: "RESTYLE THE WHOLE THING"
            case .rework: "CHANGE PART OF IT"
            case .parts: "MAKE A NEW PART"
            }
        }
    }

    var group: Group {
        switch self {
        case .cover, .reference, .melody, .morph, .shape, .stems: .restyle
        case .repaint, .complete, .continueTrack: .rework
        case .layer, .extract: .parts
        }
    }

    static func inGroup(_ group: Group) -> [StyleTransferMode] {
        allCases.filter { $0.group == group }
    }

    // MARK: - Copy

    /// The chip label. Musician language: the ML term is the name of the
    /// section, not of the buttons inside it.
    var title: String {
        switch self {
        case .cover: "Keep melody + words"
        case .reference: "Sound like a reference"
        case .melody: "Keep the melody"
        case .morph: "Morph the description"
        case .shape: "Keep the shape"
        case .stems: "Keep chosen stems"
        case .repaint: "Keep everything but a section"
        case .complete: "Complete it"
        case .continueTrack: "Continue it"
        case .layer: "Add over the top"
        case .extract: "Extract from it"
        }
    }

    /// The honest one-liner, rendered under the control. This is the feature,
    /// not a caveat bolted onto it — see the type's doc comment.
    var survives: String {
        switch self {
        case .cover:
            "The tune and the lyrics survive; the model re-performs everything "
                + "else — instruments, voice, production."
        case .reference:
            "Your track keeps its structure; the reference lends texture and "
                + "sound. It borrows a feel, not a melody."
        case .melody:
            "Melody and harmony survive. Timbre does not — expect the same "
                + "tune played by something else entirely."
        case .morph:
            "The model reads your source as one description and rewrites it as "
                + "another. Broad strokes survive; details are re-imagined."
        case .shape:
            "The rough arrangement survives in proportion to the dial. Push it "
                + "far and only a silhouette of the original is left."
        case .stems:
            "The stems you keep survive exactly — this is the only mode that "
                + "preserves the original recording rather than re-performing it."
        case .repaint:
            "Everything outside the selected window survives untouched. Only "
                + "the seconds you choose are regenerated."
        case .complete:
            "What is already played survives; the model adds the parts it "
                + "thinks the arrangement is missing."
        case .continueTrack:
            "The whole source survives. New audio is appended to the end."
        case .layer:
            "All of it survives — the result is a new part sitting over the "
                + "original, not a replacement for it."
        case .extract:
            "Nothing is preserved as audio: the model plays the part it hears "
                + "rather than filtering it out. For a literal stem, split instead."
        }
    }

    /// Eyebrow over the prompt field. Ported from `GenerativeShape.promptLabel`
    /// so existing pages read identically after the consolidation.
    var promptLabel: String {
        switch self {
        case .layer: "WHAT SHOULD IT PLAY?"
        case .shape: "NEW TEXTURE"
        case .continueTrack: "HOW SHOULD IT CONTINUE?"
        case .morph: "WHAT SHOULD IT BECOME?"
        case .melody: "WHAT SHOULD PLAY THE TUNE?"
        default: "NEW STYLE"
        }
    }

    var promptPlaceholder: String {
        switch self {
        case .layer: "e.g. a simple countermelody on muted trumpet"
        case .continueTrack: "e.g. build to a final chorus, then fade"
        case .melody: "e.g. solo piano, close-mic'd, felt hammers"
        case .morph: "e.g. the same song as a slow acoustic ballad"
        default: "e.g. dreamy synthwave, warm analog pads"
        }
    }

    /// SF Symbol for the chip.
    var icon: String {
        switch self {
        case .cover: "music.mic"
        case .reference: "square.on.square.dashed"
        case .melody: "music.quarternote.3"
        case .morph: "arrow.triangle.swap"
        case .shape: "waveform.path"
        case .stems: "square.stack.3d.up"
        case .repaint: "paintbrush"
        case .complete: "person.3"
        case .continueTrack: "forward.end"
        case .layer: "plus.square.on.square"
        case .extract: "scissors"
        }
    }

    // MARK: - Inputs

    /// How much the mode needs a given audio slot.
    enum SlotNeed: Sendable {
        case required, optional, unused

        var isNeeded: Bool { self != .unused }
    }

    /// The track being transformed.
    ///
    /// Only `reference` makes it optional, and only because
    /// `reference_audio` on a bare `text2music` is a real, working shape.
    /// Everything else in this section transforms audio that exists — that is
    /// the boundary between Style Transfer and Studio.
    var sourceNeed: SlotNeed {
        self == .reference ? .optional : .required
    }

    /// The track whose sound is being borrowed.
    var referenceNeed: SlotNeed {
        switch self {
        case .reference: .required
        case .cover: .optional
        default: .unused
        }
    }

    /// The keys a style reference may ride, most specific first.
    ///
    /// `style_audio` is MusicGen-Style's excerpt conditioner; `reference_audio`
    /// is ACE-Step's. They do the same job for the user and nothing alike
    /// underneath, which is exactly why the mode names the intent and the model
    /// picks the key.
    static let referenceAudioKeys = ["style_audio", "reference_audio"]

    /// Which key this model wants a reference on, if it takes one at all.
    func referenceAudioKey(for model: ModelInfo?) -> String? {
        guard referenceNeed.isNeeded else { return nil }
        guard let model else { return "reference_audio" }
        return Self.referenceAudioKeys.first { key in
            model.capabilities.params.contains { $0.key == key }
        }
    }

    /// Which wire key carries the source upload. `nil` for `reference`, whose
    /// source is optional and rides `src_audio` only when present.
    var sourceAudioKey: String {
        switch self {
        case .shape: "init_audio"
        case .continueTrack: "extend_audio"
        case .melody: "melody_audio"
        default: "src_audio"
        }
    }

    /// The `task_type` value to submit.
    ///
    /// `reference` is the one mode that varies: with a source attached it is a
    /// cover that also carries a reference; with none it is a plain
    /// text-to-music generation that happens to be style-conditioned. Upstream
    /// treats both identically — `_prepare_reference_and_source_audio` encodes
    /// the reference for every task, defaulting to a silence latent — so the
    /// only thing the app has to get right is which task it names.
    ///
    /// `nil` means the model has no `task_type` param at all (Stable Audio,
    /// MusicGen); the audio key alone selects the behaviour.
    func wireTask(hasSource: Bool) -> String? {
        switch self {
        case .cover, .stems: "cover"
        case .reference: hasSource ? "cover" : "text2music"
        case .morph: "text2music"
        case .repaint: "repaint"
        case .complete: "complete"
        case .layer: "lego"
        case .extract: "extract"
        case .shape, .continueTrack, .melody: nil
        }
    }

    /// Extract sends the human title instead of a prompt — the adapter drops it
    /// from the caption so it cannot bias the stem — so it is the one mode with
    /// no prompt field.
    var needsPrompt: Bool { self != .extract }

    /// Which instrument the model should work on.
    var trackNeed: SlotNeed {
        switch self {
        case .extract, .layer: .required
        case .complete: .optional
        default: .unused
        }
    }

    var needsRegion: Bool { self == .repaint }

    /// Whether new words are part of what this mode changes.
    ///
    /// `stems` is deliberately absent: its middle step re-performs the stems
    /// you are *replacing*, which for "keep the vocal" is the band. Offering a
    /// lyrics editor over a job that will never sing them is worse than not
    /// offering one.
    var allowsLyrics: Bool {
        switch self {
        case .cover, .reference, .morph, .repaint: true
        default: false
        }
    }

    /// extract/lego outputs are material belonging to the source song, not new
    /// songs — they land in Library › Parts and the Workbench can stack them.
    var outputsPart: Bool { self == .extract || self == .layer }

    /// `stems` is not one job; `StyleTransferChain` plans it.
    var isChain: Bool { self == .stems }

    // MARK: - The strength dial

    /// The single `Original ←→ Style` slider, and how each mode maps it.
    ///
    /// Two models expose "how far from the source" with **opposite** senses
    /// and wildly different ranges. Exposing both raw is how they ended up
    /// buried under ADVANCED as anonymous sliders, one of which counts up while
    /// the other counts down. The workspace shows one dial, `styleAmount`,
    /// where 0 is *stay close to the original* and 1 is *go as far as the model
    /// allows*, and each mode converts.
    struct Dial: Equatable, Sendable {
        enum Sense: Equatable, Sendable {
            /// `audio_cover_strength`: 0…1, **higher keeps more of the
            /// source**. The catalog's own help says so — "lower (0.2) is
            /// closer to pure style transfer" — so the slider is its inverse.
            case invertedUnit
            /// `init_noise_level`: 0.1…10, higher is freer. Mapped
            /// geometrically rather than linearly, which is the only way the
            /// model's own default of 1.0 lands on the middle of the slider:
            /// the range spans two decades, so a linear map would squeeze
            /// every useful value into the bottom tenth of the travel.
            case logarithmic
        }

        let key: String
        let sense: Sense
        let nominalMin: Double
        let nominalMax: Double
        let nominalDefault: Double

        private func bounds(_ spec: ParamSpec?) -> (min: Double, max: Double) {
            (spec?.min ?? nominalMin, spec?.max ?? nominalMax)
        }

        /// styleAmount (0…1) → the value to put on the wire.
        func wireValue(styleAmount: Double, spec: ParamSpec? = nil) -> Double {
            let t = min(max(styleAmount, 0), 1)
            let (lo, hi) = bounds(spec)
            switch sense {
            case .invertedUnit:
                return hi - t * (hi - lo)
            case .logarithmic:
                // Guard the geometric map against a nonsensical catalog: a
                // zero or negative bound has no logarithm, and falling back to
                // linear is better than returning NaN into a job param.
                guard lo > 0, hi > lo else { return lo + t * (hi - lo) }
                return lo * pow(hi / lo, t)
            }
        }

        /// The inverse, for placing the slider from a stored or default value.
        func styleAmount(wireValue: Double, spec: ParamSpec? = nil) -> Double {
            let (lo, hi) = bounds(spec)
            switch sense {
            case .invertedUnit:
                guard hi > lo else { return 0 }
                return min(max((hi - wireValue) / (hi - lo), 0), 1)
            case .logarithmic:
                guard lo > 0, hi > lo, wireValue > 0 else { return 0 }
                return min(max(log(wireValue / lo) / log(hi / lo), 0), 1)
            }
        }

        /// Where the slider sits before the user touches it: whatever the
        /// model's own default maps to, so "I didn't move it" and "the model's
        /// default" are the same run.
        func defaultStyleAmount(spec: ParamSpec? = nil) -> Double {
            styleAmount(wireValue: spec?.default.doubleValue ?? nominalDefault,
                        spec: spec)
        }
    }

    /// Which modes the dial belongs to, and — just as important — which it
    /// does not.
    ///
    /// `audio_cover_strength` is honoured by ACE-Step for *any* task with a
    /// source, not only cover: upstream keys the blend on the value alone and
    /// switches conditioning after `int(steps * strength)` of them. The catalog
    /// declared it non-nullable at 0.7 and the app rendered it as an anonymous
    /// ADVANCED slider, so every repaint, extract, layer and complete job was
    /// quietly asking for a 70 % source blend nobody chose — on tasks whose
    /// entire promise is "the rest of it survives untouched".
    ///
    /// So the dial is offered only where moving towards the style is the point,
    /// and on the other four the key is never sent at all, leaving upstream's
    /// own default of 1.0: honour the source completely. "Keep everything but a
    /// section" now means it.
    var dial: Dial? {
        switch self {
        case .cover, .reference, .stems:
            Dial(key: "audio_cover_strength", sense: .invertedUnit,
                 nominalMin: 0, nominalMax: 1, nominalDefault: 0.7)
        case .shape:
            Dial(key: "init_noise_level", sense: .logarithmic,
                 nominalMin: 0.1, nominalMax: 10, nominalDefault: 1)
        case .repaint, .complete, .layer, .extract, .morph, .continueTrack,
             .melody:
            nil
        }
    }

    // MARK: - Which models can serve it

    /// What makes a model able to run this mode, expressed **only** against
    /// the params it declares. Never against ids: the catalog gains variants
    /// constantly, and an id list is a list that goes stale silently.
    indirect enum Requirement: Equatable, Sendable {
        /// The model declares a param with this key.
        case declaresParam(String)
        /// The model's `task_type` enum offers this choice.
        case taskChoice(String)
        /// Any one of these is enough. Two families can offer the same
        /// capability under different key names — ACE-Step calls a style
        /// reference `reference_audio`, MusicGen-Style calls its excerpt
        /// `style_audio` — and a mode is about what the user gets, not about
        /// what the wire happens to call it.
        case either([Requirement])

        func isMet(by model: ModelInfo) -> Bool {
            let params = model.capabilities.params
            switch self {
            case .declaresParam(let key):
                return params.contains { $0.key == key }
            case .taskChoice(let value):
                guard let spec = params.first(where: { $0.key == "task_type" })
                else { return false }
                return (spec.choices ?? []).contains { $0.value == value }
            case .either(let options):
                return options.contains { $0.isMet(by: model) }
            }
        }
    }

    var requirements: [Requirement] {
        switch self {
        case .cover, .stems: [.taskChoice("cover")]
        case .reference: [.either([.declaresParam("reference_audio"),
                                   .declaresParam("style_audio")])]
        case .melody: [.declaresParam("melody_audio")]
        case .morph: [.declaresParam("flow_edit_morph")]
        case .shape: [.declaresParam("init_audio")]
        case .repaint: [.taskChoice("repaint")]
        case .complete: [.taskChoice("complete")]
        case .continueTrack: [.declaresParam("extend_audio")]
        case .layer: [.taskChoice("lego")]
        case .extract: [.taskChoice("extract")]
        }
    }

    /// Ignores install state — "could this model ever do it", which is the
    /// question the dimmed-with-a-reason affordance asks.
    func canRun(_ model: ModelInfo) -> Bool {
        model.capabilities.supportedTasks.contains("generate")
            && requirements.allSatisfy { $0.isMet(by: model) }
    }

    /// The models that can serve this mode right now.
    func eligible(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.installState == .installed && canRun($0) }
    }

    /// The models that *would* serve it, installed or not — what to offer when
    /// the mode is dimmed. Smallest first, because the answer to "which one do
    /// I download" is almost always "the cheapest one that works".
    func candidates(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter(canRun).sorted { $0.sizeBytes < $1.sizeBytes }
    }

    /// Why the mode is dimmed, in one line, when no installed model serves it.
    func unavailableReason(_ models: [ModelInfo]) -> String? {
        guard eligible(models).isEmpty else { return nil }
        guard let smallest = candidates(models).first else {
            return "No model in the catalog can do this yet."
        }
        return "Needs \(smallest.displayName)."
    }

    // MARK: - Building the wire params

    /// Everything the mode needs from the workspace to name its params.
    /// Uploads happen outside this type — they are async and this is not.
    struct Inputs: Equatable, Sendable {
        var sourceUploadId: String?
        var referenceUploadId: String?
        var track: String?
        var regionStartS: Double = 0
        var regionEndS: Double = 0
        /// 0 = stay close to the original, 1 = go as far as the model allows.
        /// `nil` leaves the model's own default alone.
        var styleAmount: Double?
        /// What the source is, in the model's own words — FlowEdit morphs from
        /// one caption to another, so it needs both ends.
        var sourceCaption: String?

        init(sourceUploadId: String? = nil, referenceUploadId: String? = nil,
             track: String? = nil, regionStartS: Double = 0,
             regionEndS: Double = 0, styleAmount: Double? = nil,
             sourceCaption: String? = nil) {
            self.sourceUploadId = sourceUploadId
            self.referenceUploadId = referenceUploadId
            self.track = track
            self.regionStartS = regionStartS
            self.regionEndS = regionEndS
            self.styleAmount = styleAmount
            self.sourceCaption = sourceCaption
        }
    }

    /// The programmatic half of a job's params — everything the workspace owns
    /// rather than the generic knob form.
    ///
    /// Deliberately does **not** merge the user's advanced overrides: the
    /// caller does that, and does it in this order, so a mode-owned key always
    /// wins over a stale override of the same key.
    func wireParams(_ inputs: Inputs, model: ModelInfo? = nil,
                    spec dialSpec: ParamSpec? = nil) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]

        if let sourceUploadId = inputs.sourceUploadId {
            params[sourceAudioKey] = .string(sourceUploadId)
        }
        if let referenceUploadId = inputs.referenceUploadId,
           let key = referenceAudioKey(for: model) {
            params[key] = .string(referenceUploadId)
        }
        if let task = wireTask(hasSource: inputs.sourceUploadId != nil) {
            params["task_type"] = .string(task)
        }
        if trackNeed.isNeeded, let track = inputs.track {
            params["track"] = .string(track)
        }
        if needsRegion {
            params["repainting_start"] = .double(inputs.regionStartS)
            params["repainting_end"] = .double(inputs.regionEndS)
        }
        if self == .morph {
            params["flow_edit_morph"] = .bool(true)
            if let caption = inputs.sourceCaption, !caption.isEmpty {
                params["flow_edit_source_caption"] = .string(caption)
            }
        }
        if let dial, let amount = inputs.styleAmount {
            params[dial.key] = .double(
                dial.wireValue(styleAmount: amount, spec: dialSpec))
        }
        // With a model in hand, drop anything it does not declare.
        //
        // Not defensive tidiness: the engine discards unrecognised param keys
        // *silently*, recording them as a `job.log` line and nothing else. A
        // mode that names a `task_type` on a model with no task selector, or a
        // strength dial on a model with no such knob, would produce a job that
        // ran happily and ignored half of what it was told — which is far
        // harder to notice than an error.
        guard let model else { return params }
        let declared = Set(model.capabilities.params.map(\.key))
        return params.filter { declared.contains($0.key) }
    }

    /// Every key any mode may write, so the generic knob form can hide them
    /// and an override dict can be filtered against them.
    ///
    /// This supersedes `GenerativeModels.programmaticKeys`, which omitted
    /// `audio_cover_strength` and `init_noise_level` — with the result that the
    /// two most important dials in the feature appeared twice: once as the
    /// mode's own control and once as an anonymous slider under ADVANCED, with
    /// the second silently overwriting the first.
    static let programmaticKeys: Set<String> = [
        "task_type", "src_audio", "reference_audio", "track",
        "repainting_start", "repainting_end", "init_audio", "melody_audio",
        "extend_audio", "inpaint_audio", "inpaint_start_s", "inpaint_end_s",
        "audio_cover_strength", "init_noise_level",
        "flow_edit_morph", "flow_edit_source_caption",
    ]

    /// The knobs left for the generic form once the workspace has taken what
    /// it owns.
    static func knobSpecs(for model: ModelInfo) -> [ParamSpec] {
        model.capabilities.params.filter {
            !programmaticKeys.contains($0.key) && $0.isInternal != true
        }
    }

    /// The dial's own spec on a given model, so the slider can honour a
    /// catalog that widens the range later without an app change.
    ///
    /// `nil` also means "this model has no such control", which is how the
    /// screen knows to hide the strength slider rather than show one that
    /// writes a key the engine will throw away — MusicGen-Style conditions on
    /// an excerpt and has no notion of distance from a source at all.
    func dialSpec(for model: ModelInfo?) -> ParamSpec? {
        guard let dial, let model else { return nil }
        return model.capabilities.params.first { $0.key == dial.key }
    }

    /// Whether the strength slider means anything on this model.
    func hasDial(on model: ModelInfo?) -> Bool {
        dial != nil && (model == nil || dialSpec(for: model) != nil)
    }

    // MARK: - Bridging from the recipe table

    /// The `RecipeEngine.generate(modelTask:)` values, so a preset can be
    /// declared in the old vocabulary and still land here.
    ///
    /// Forgiving on purpose, exactly as `GenerativeShape` was: an unrecognised
    /// task falls back to `cover`, the mode with the most models behind it, so
    /// a catalog that grows a task the app has not learned yet degrades to
    /// something usable rather than to an empty screen.
    static func forModelTask(_ task: String) -> StyleTransferMode {
        switch task {
        case "cover": .cover
        case "repaint": .repaint
        case "extract": .extract
        case "lego": .layer
        case "complete": .complete
        case "init_audio": .shape
        case "extend_audio": .continueTrack
        case "melody_audio", "melody": .melody
        case "flow_edit_morph", "morph": .morph
        case "stems": .stems
        default: .cover
        }
    }

    /// The mode a workspace should land on for a given source and catalog:
    /// the requested one when a model can serve it, otherwise the first mode
    /// that can, so a deep link into an unavailable mode still shows a working
    /// screen with the reason printed on the dimmed chip.
    static func firstAvailable(preferring wanted: StyleTransferMode,
                               models: [ModelInfo]) -> StyleTransferMode {
        if !wanted.eligible(models).isEmpty { return wanted }
        return allCases.first { !$0.eligible(models).isEmpty } ?? wanted
    }
}
