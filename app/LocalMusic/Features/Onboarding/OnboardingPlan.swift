import Foundation

/// What a fresh install is offered on first run, and which of it *this* Mac
/// should arrive with ticked.
///
/// Pure and store-free, for the same reason `ModelListLayout` is: which models
/// a new user gets is a product decision that deserves a test rather than a
/// screenshot, and the RAM arithmetic underneath it is exactly the kind of
/// thing that goes quietly wrong on a machine nobody developing has.
struct OnboardingPlan: Equatable {

    // MARK: - The set

    /// The models the app's non-generation half is dead without, plus three
    /// near-free enrichers that otherwise leave whole surfaces dimmed.
    ///
    /// Together these cost about 275 MB — three of them are literally zero
    /// bytes, their weights riding along inside the adapter's Python package —
    /// against 9.4 GB for a single song model. Without the core, Split &
    /// Recombine, tempo and key badges, note transcription, beat-aligned
    /// mixing and note rendering are all either invisible or silently inert:
    /// `autoAnalyze` gives up without a word when no analyzer is installed,
    /// and a mix with no analysis behind it still renders, just never aligned.
    ///
    /// The last three are enrichers rather than load-bearing — chords (BTC),
    /// quality scores (SQUIM) and tags (Essentia) — but they earn the row the
    /// same way: without them the "Read the chords", "Rate the quality" and
    /// "Tag my library" cards sit dimmed on a fresh install with nothing
    /// explaining why, the section map has no chord chips, and the song
    /// digest has no progression to speak of. All three together are ~75 MB
    /// with 4 GB floors.
    ///
    /// Ordered as the essentials row reads them out.
    static let essentialIds = [
        "analysis-basic",        // tempo, key, beats, sections — the auto-analyze
        "analysis-chords-btc",   // chord chips, chord-bed part, digest progression
        "analysis-squim",        // quality scores for any part
        "separation-htdemucs",   // split into stems, karaoke
        "transcribe-basicpitch", // notes, general case
        "transcribe-swiftf0",    // notes, melody line
        "transcribe-transkun",   // notes, piano
        "render-soundfont",      // hear a notes part back
        "dsp-mixdown",           // every beat-aligned mix and recombine
        "tag-essentia-discogs",  // genre/mood tags, batch tagging, tag search
    ]

    /// The generators a new user starts with: two full-song models so the
    /// app's whole premise — running one prompt through more than one model —
    /// works before they have downloaded anything themselves, one small
    /// instrumental model that runs on the smallest Apple Silicon Mac, the
    /// Base DiT that Style Transfer's stem modes need, and the one model in
    /// the catalog that EDITS existing audio toward a prompt.
    ///
    /// `minimax-music3-mlx-small` is deliberately the MLX build and not the
    /// catalog's featured `minimax-music3`: same model, 8.3 GB against 53 GB
    /// and a 16 GB memory floor against 48 GB. It is a *variant*, which is
    /// fine here — installs are by id — and once installed it draws nested
    /// under its base in the Models list without any further help.
    ///
    /// `melodyflow-t24` earns the fifth slot on capability, not size: nothing
    /// else here rewrites a clip from a description ("make it orchestral"),
    /// so the "Edit with words" card is dimmed without it — and at 4.1 GB
    /// with an 8 GB floor and MPS rendering (10 s in ~3 s) it is the
    /// smallest and fastest real generator on the sheet.
    ///
    /// No gated model appears here on purpose. All three Stability entries
    /// need a Hugging Face token in the Keychain, and demanding one in the
    /// first minute of the app is the wrong trade for a fifth generator.
    static let generatorIds = [
        "acestep-base",              // songs with vocals, up to 5 minutes
        "acestep-15-dit-base",       // unlocks extract / layer / complete
        "minimax-music3-mlx-small",  // a second, different full-song model
        "musicgen-small",            // instrumental, runs on an 8 GB Mac
        "melodyflow-t24",            // fast instrumental + edits audio with words
    ]

    /// What a generator buys that its description does not already say.
    ///
    /// Only `acestep-15-dit-base` has anything to add, and it needs it: at
    /// 13.9 GB it is the largest single item the sheet offers, and what it buys
    /// is invisible from its name. The Turbo DiT that `acestep-base` runs can
    /// cover and repaint but **cannot** extract a stem, add a layer or complete
    /// an arrangement — the pipeline does not refuse a wrong DiT, it just
    /// produces garbage — so without this entry three of the Style Transfer
    /// modes are dimmed on a fresh install with no obvious way to light them.
    static func unlocks(_ id: String) -> String? {
        id == "acestep-15-dit-base"
            ? "Unlocks extracting a stem, adding a layer and completing an "
                + "arrangement — the Turbo model cannot do any of the three."
            : nil
    }

    // MARK: - Items

    struct Item: Identifiable, Equatable {
        let model: ModelInfo
        let isEssential: Bool
        /// Whether the row arrives ticked. Essentials always do; a generator
        /// does unless this Mac cannot run it.
        let defaultsOn: Bool
        /// Why the row arrives unticked, ready to print under it. Nil when
        /// there is nothing standing in the way.
        let blockedReason: String?

        var id: String { model.id }

        /// `ModelInfo` is not `Equatable` — the same reason `ModelListRow`
        /// writes this by hand. Everything the sheet draws from the model is
        /// fixed for a given id, so the id stands in for it.
        static func == (lhs: Item, rhs: Item) -> Bool {
            lhs.model.id == rhs.model.id
                && lhs.model.installState == rhs.model.installState
                && lhs.isEssential == rhs.isEssential
                && lhs.defaultsOn == rhs.defaultsOn
                && lhs.blockedReason == rhs.blockedReason
        }
    }

    let essentials: [Item]
    let generators: [Item]

    var all: [Item] { essentials + generators }

    /// Nothing left to offer — every recommended model is already installed,
    /// so there is no sheet worth showing.
    var isEmpty: Bool { all.isEmpty }

    /// The ids ticked when the sheet opens.
    var defaultSelection: Set<String> {
        Set(all.filter(\.defaultsOn).map(\.id))
    }

    /// What the essentials cost as one line, since the sheet offers them as
    /// one row: seven separate decisions about models that are free or nearly
    /// free is not a choice, it is an obstacle.
    var essentialBytes: Int64 {
        essentials.reduce(0) { $0 + $1.model.sizeBytes }
    }

    func bytes(for selection: Set<String>) -> Int64 {
        all.filter { selection.contains($0.id) }
            .reduce(0) { $0 + $1.model.sizeBytes }
    }

    func items(for selection: Set<String>) -> [Item] {
        all.filter { selection.contains($0.id) }
    }

    // MARK: - Building

    /// - Parameters:
    ///   - models: the catalog as the engine reported it.
    ///   - physicalRAM: this Mac's memory, against each model's declared floor.
    static func make(models: [ModelInfo], physicalRAM: Int64) -> OnboardingPlan {
        let byId = Dictionary(models.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })

        func build(_ ids: [String], essential: Bool) -> [Item] {
            ids.compactMap { id -> Item? in
                // A recommended id that is not in the catalog is skipped rather
                // than fatal: the catalog ships separately from the app, and a
                // renamed entry should cost the user one model, not a launch.
                guard let model = byId[id] else { return nil }
                // Already here — there is nothing for onboarding to do with it.
                guard model.installState != .installed else { return nil }

                let needs = model.requirements.minRamBytes
                let blocked = needs > physicalRAM
                    ? "Needs \(ByteFormat.wholeGB(needs)) GB — this Mac has "
                        + "\(ByteFormat.wholeGB(physicalRAM)) GB"
                    : nil
                return Item(model: model, isEssential: essential,
                            defaultsOn: blocked == nil, blockedReason: blocked)
            }
        }

        return OnboardingPlan(essentials: build(essentialIds, essential: true),
                              generators: build(generatorIds, essential: false))
    }
}
