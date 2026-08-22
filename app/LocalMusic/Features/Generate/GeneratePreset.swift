import Foundation

/// What a Generate card needs from a model, and which models do that job best.
///
/// Two different questions, deliberately in one type. The first is a *gate*:
/// a card that wants words sung cannot run on a model with no lyrics, and the
/// gallery must say so before you click rather than after. The second is only
/// a *preference*: any generative model will answer a prompt asking for a door
/// slam, but AudioLDM was trained on general audio and MusicGen was not, so
/// one of them will hand you a door and the other a chord. Preference picks
/// the model the card arrives on; it never hides a card.
///
/// Families rather than a catalog tag, because "good at foley" is not a
/// capability an engine can declare — nothing in the contract could carry it
/// honestly, and inventing a flag for a matter of taste would make it look
/// like one.
struct GenerateNeed: Equatable, Hashable, Sendable {
    /// Must be able to sing words the user wrote.
    var lyrics = false
    /// Must be able to reach this length in one take. A card offering a two
    /// minute backing track cannot run on a model that stops at thirty
    /// seconds.
    var reaches: Double?
    /// Must be able to go *this* short. A one-shot sample card on a model
    /// with a ten second floor is a card that cannot do what it says.
    var goesAsShortAs: Double?
    /// Families that do this particular job well, best first. Preference
    /// only — see above.
    var prefers: [String] = []

    /// Stable id, for `ModelRequirement` and for keying the Models filter.
    var key: String {
        var parts: [String] = []
        if lyrics { parts.append("lyrics") }
        if let reaches { parts.append("min\(Int(reaches))") }
        if let goesAsShortAs { parts.append("max\(Int(goesAsShortAs))") }
        return parts.isEmpty ? "any" : parts.joined(separator: "-")
    }

    /// Named as the thing the user was trying to do, which is what the Models
    /// screen's "Needed for" chip says.
    var title: String {
        if lyrics { return "Generate a song with lyrics" }
        if let reaches, reaches >= 60 { return "Generate a long take" }
        if goesAsShortAs != nil { return "Generate a short sample" }
        return "Generate from a description"
    }

    func canRun(_ model: ModelInfo) -> Bool {
        let caps = model.capabilities
        guard caps.supportedTasks.contains("generate") else { return false }
        if lyrics && !caps.supportsLyrics { return false }
        if let reaches, caps.duration.maxS + 0.001 < reaches { return false }
        if let goesAsShortAs, caps.duration.minS - 0.001 > goesAsShortAs {
            return false
        }
        return true
    }

    func eligible(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.installState == .installed && canRun($0) }
    }

    /// The installed model this card should arrive on: the preferred family if
    /// one is installed, otherwise whatever else can run it. Nil means the
    /// card is gated, and the gallery says which model would ungate it.
    func best(_ models: [ModelInfo]) -> ModelInfo? {
        let eligible = eligible(models)
        for family in prefers {
            if let match = eligible.first(where: { $0.family == family }) {
                return match
            }
        }
        return eligible.first
    }
}

/// What an Actions card carries into Generate.
///
/// The same shape as `StylePreset`, for the same reason: a card is a door into
/// a screen you keep working in, not a one-shot form that forgets everything
/// the moment you leave it.
struct GeneratePreset: Equatable, Identifiable, Sendable {
    /// Matches the recipe id that carries it, so a preset and its card cannot
    /// drift apart. **Wire value** by inheritance — recipe ids are written
    /// into provenance and `actions.lastRuns` — so these are re-pointed,
    /// never renamed.
    let id: String
    let need: GenerateNeed
    /// Dropped into the prompt on arrival, and deliberately skeletal: the
    /// point is to start the sentence, not to finish it. A prompt the user did
    /// not write is a prompt they will not read before pressing Generate, and
    /// the trailing comma is there to put the cursor somewhere useful.
    var promptSeed: String = ""
    /// Non-nil opens the lyrics editor with this in it.
    var lyricsSeed: String?
    var durationS: Double?
    /// How many takes to ask for. Four is the ceiling most models declare and
    /// the point of the two exploration cards.
    var takes: Int?
    /// Read the tempo and key of a track the user picks, and carry them in.
    var readsSource = false
    /// One line above the composer explaining what arriving here changed.
    var notice: String?
}

extension GeneratePreset {

    /// Every Generate preset, keyed by the recipe id that opens it.
    static let byRecipe: [String: GeneratePreset] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func preset(id: String) -> GeneratePreset? { byRecipe[id] }

    /// Preferred families, named once. `diffusers` is the AudioLDM line, which
    /// is the only one here trained on audio that is not music.
    private static let soundDesign = ["diffusers", "stableaudio"]
    private static let songs = ["acestepcpp", "acestep", "minimax"]
    private static let loops = ["stableaudio", "musicgen", "audiocraft"]

    static let all: [GeneratePreset] = [
        // MARK: songs
        GeneratePreset(
            id: "gen-song-lyrics",
            need: GenerateNeed(lyrics: true, reaches: 60, prefers: songs),
            promptSeed: "", lyricsSeed: "[verse]\n", durationS: 120,
            notice: "Write the words on the right; the model composes the "
                + "music around them."),
        GeneratePreset(
            id: "gen-instrumental",
            need: GenerateNeed(reaches: 60, prefers: songs),
            promptSeed: "instrumental, ", durationS: 120),
        GeneratePreset(
            id: "gen-sketch",
            need: GenerateNeed(reaches: 30),
            durationS: 30, takes: 4,
            notice: "Four short takes, so you can hear the idea before "
                + "spending minutes on a long one."),

        // MARK: production material
        GeneratePreset(
            id: "gen-drum-loop",
            need: GenerateNeed(goesAsShortAs: 12, prefers: loops),
            promptSeed: "drum loop, ", durationS: 10, takes: 4),
        GeneratePreset(
            id: "gen-bassline",
            need: GenerateNeed(goesAsShortAs: 15, prefers: loops),
            promptSeed: "bassline, ", durationS: 12, takes: 4),
        GeneratePreset(
            id: "gen-chord-bed",
            need: GenerateNeed(goesAsShortAs: 20, prefers: loops),
            promptSeed: "chord progression, ", durationS: 20),
        GeneratePreset(
            id: "gen-hook",
            need: GenerateNeed(goesAsShortAs: 20, prefers: ["musicgen"] + loops),
            promptSeed: "melodic hook, ", durationS: 15, takes: 4),
        GeneratePreset(
            id: "gen-ambient-bed",
            need: GenerateNeed(reaches: 60, prefers: ["stableaudio3"] + songs),
            promptSeed: "ambient bed, slow, no percussion, ", durationS: 120),

        // MARK: sound design
        GeneratePreset(
            id: "gen-sound-effect",
            need: GenerateNeed(goesAsShortAs: 10, prefers: soundDesign),
            promptSeed: "", durationS: 5, takes: 4,
            notice: "Best on an AudioLDM model — the only line here trained "
                + "on audio that is not music."),
        GeneratePreset(
            id: "gen-riser",
            need: GenerateNeed(goesAsShortAs: 10, prefers: soundDesign),
            promptSeed: "riser, rising tension, ", durationS: 6, takes: 4),
        GeneratePreset(
            id: "gen-one-shot",
            need: GenerateNeed(goesAsShortAs: 4, prefers: ["stableaudio"] + soundDesign),
            promptSeed: "single hit, ", durationS: 2, takes: 4),

        // MARK: fit to something you have
        GeneratePreset(
            id: "gen-fit-track",
            need: GenerateNeed(),
            readsSource: true,
            notice: "Tempo and key read from the track you picked and written "
                + "into the prompt. Nothing of its audio is used."),

        // MARK: comparison
        GeneratePreset(
            id: "gen-explore-prompt",
            need: GenerateNeed(),
            takes: 4,
            notice: "One prompt, four takes, four seeds — the cheapest way to "
                + "find out whether an idea is worth pursuing."),
    ]
}
