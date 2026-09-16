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
    /// Must declare a param with this key. This is a *gate*, for cards whose
    /// whole point is one capability (`accompany_audio`, `edit_strength`) —
    /// it lands the card on the right member of a family that shares one
    /// adapter. Setting it also says "this card knows what it is feeding the
    /// model", which lifts the bare-prompt exclusion below.
    var requiresParam: String?

    /// Stable id, for `ModelRequirement` and for keying the Models filter.
    var key: String {
        var parts: [String] = []
        if lyrics { parts.append("lyrics") }
        if let reaches { parts.append("min\(Int(reaches))") }
        if let goesAsShortAs { parts.append("max\(Int(goesAsShortAs))") }
        if let requiresParam { parts.append("param-\(requiresParam)") }
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
        if let requiresParam {
            guard caps.params.contains(where: { $0.key == requiresParam })
            else { return false }
        } else if caps.needsSourceAudio {
            // A bare prompt cannot feed a model that requires audio in —
            // the job would only fail at the adapter.
            return false
        }
        // The other direction of the lyrics test above: a need that does not
        // promise lyrics cannot run a model that demands them. Without this
        // Compare Models pre-ticked YuE2 and HeartMuLa and sent them
        // lyricless jobs they refused — after loading several gigabytes.
        if !lyrics && caps.needsLyrics { return false }
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
    /// Read the tempo and key of a track the user picks, and carry them in as
    /// *words*. The model never hears the track.
    var readsMeasurements = false
    /// Feed the picked track's *audio* into this param of the arriving model.
    /// The tempo-and-key prompt line is skipped — the model hears the track
    /// itself, so writing "132 bpm" into the prompt would be describing audio
    /// it is already listening to. This is the door for cards like
    /// vocals2music, whose whole point is a specific audio input.
    var sourceParamKey: String?

    /// Whether opening this card opens a source picker.
    ///
    /// Computed, and that is the point: `sourceParamKey`'s contract has always
    /// been that it implies a picker, but the implication was written out by
    /// hand at each of the five cards that name one. Five copies of a rule is
    /// five chances to forget it — and `readsSource` then meant two different
    /// things depending on which call site was asking, which is what
    /// `readsMeasurements` is now for.
    var readsSource: Bool { readsMeasurements || sourceParamKey != nil }
    /// One line above the composer explaining what arriving here changed.
    var notice: String?
}

extension GeneratePreset {

    /// Every Generate preset, keyed by the recipe id that opens it.
    ///
    /// Bigger than the set of cards on purpose: the seed-only presets lost
    /// their cards to the Studio's "starting points" chips, but the presets
    /// stay — the chips read them, and old provenance still names their ids.
    static let byRecipe: [String: GeneratePreset] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// The Studio's "starting points" chips, in display order: what used to
    /// be ten gallery cards whose whole contents were a starter prompt,
    /// a length and a take count. Each chip applies the preset the card
    /// applied; the label is the card's old name, shortened to chip length.
    static let starters: [(label: String, id: String)] = [
        ("Instrumental", "gen-instrumental"),
        ("Drum loop", "gen-drum-loop"),
        ("Bassline", "gen-bassline"),
        ("Chord bed", "gen-chord-bed"),
        ("Hook", "gen-hook"),
        ("Ambient bed", "gen-ambient-bed"),
        ("Riser", "gen-riser"),
        ("One-shot", "gen-one-shot"),
        ("Sketch ×4", "gen-sketch"),
        ("Explore ×4", "gen-explore-prompt"),
    ]

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
            readsMeasurements: true,
            notice: "Tempo and key read from the track you picked and written "
                + "into the prompt. Nothing of its audio is used."),

        // MARK: comparison
        GeneratePreset(
            id: "gen-explore-prompt",
            need: GenerateNeed(),
            takes: 4,
            notice: "One prompt, four takes, four seeds — the cheapest way to "
                + "find out whether an idea is worth pursuing."),

        // MARK: doors that feed the picked track INTO the model
        //
        // These presets name a `sourceParamKey`: the track the card asks for
        // is uploaded into that param, not described in the prompt. Their
        // `requiresParam` lands each card on the right member of a family
        // that shares one adapter — and marks the preset as knowing what it
        // feeds the model, which lifts the bare-prompt exclusion in `canRun`.
        GeneratePreset(
            id: "vocals2music",
            need: GenerateNeed(lyrics: true, prefers: ["diffsynthace"],
                               requiresParam: "accompany_audio"),
            lyricsSeed: "[verse]\n",
            sourceParamKey: "accompany_audio",
            notice: "Your vocal is kept exactly as sung; the model composes "
                + "the band around it. Pasting the sung words as lyrics "
                + "helps it follow. (\"Back this vocal\" adds a layer over "
                + "the vocal instead of replacing the arrangement.)"),
        GeneratePreset(
            id: "edit-with-words",
            need: GenerateNeed(prefers: ["melodyflow"],
                               requiresParam: "edit_strength"),
            sourceParamKey: "src_audio",
            notice: "Describe the change; the model rewrites the audio "
                + "toward the words. Structure and tempo survive in "
                + "proportion to the strength dial."),
        GeneratePreset(
            id: "vamp-loop",
            need: GenerateNeed(prefers: ["vampnet"],
                               requiresParam: "periodic_prompt"),
            sourceParamKey: "src_audio",
            notice: "Vamping keeps the loop's identity token by token and "
                + "re-plays the material between the beats it pins. "
                + "(\"Reimagine a loop\" repaints the texture instead.)"),
        GeneratePreset(
            id: "gen-my-voice",
            need: GenerateNeed(lyrics: true, prefers: ["songgen"],
                               requiresParam: "ref_voice"),
            lyricsSeed: "",
            sourceParamKey: "ref_voice",
            notice: "The track you picked is the VOICE reference — a few "
                + "clean seconds are enough. Use your own recording, or "
                + "one you have permission to use; nothing is stored. "
                + "Write the words on the right."),
        GeneratePreset(
            id: "style-morph",
            need: GenerateNeed(prefers: ["magentart"],
                               requiresParam: "style_audio_b"),
            sourceParamKey: "style_audio",
            notice: "The track you picked is where the stream STARTS. "
                + "Set the morph target below — a second clip or a "
                + "description — and the music travels from one to the "
                + "other over the take."),
    ]
}
