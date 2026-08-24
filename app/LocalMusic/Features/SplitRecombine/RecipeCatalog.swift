import Foundation

/// Prefix-wildcard matcher over the part-kind taxonomy. "stem.*" matches any
/// stem; "song.mix" matches whole library songs (which are slot-fillable
/// material like any part).
///
/// Convention: AI-generated layers ("layer.*" — lego outputs, SoundFont
/// renders) are musically interchangeable with stems, so every slot that
/// accepts "stem.*" also lists "layer.*" explicitly.
struct KindPattern: Equatable {
    let pattern: String

    func matches(_ kind: String) -> Bool {
        if pattern.hasSuffix(".*") {
            return kind.hasPrefix(String(pattern.dropLast(1)))
        }
        return kind == pattern
    }
}

/// The one-click fix for an unfillable slot: run this split on a song first.
struct AutoDerive: Equatable {
    let splitTask: String        // "separate"
    let note: String             // "Split '%@' into instruments first"
}

struct Slot: Identifiable, Equatable {
    let id: String               // slotId on the wire and in provenance
    let label: String
    let accepts: [KindPattern]
    let arity: ClosedRange<Int>
    let autoDerive: AutoDerive?

    func accepts(kind: String) -> Bool {
        accepts.contains { $0.matches(kind) }
    }
}

struct MixDefaults: Equatable {
    var autoMatchTempo = true
    var autoMatchKey = true
    var stretch = true           // Polish the Mix sets false: levels only
}

enum RecipeEngine: Equatable {
    case mix(defaults: MixDefaults)          // literal dsp mixdown
    case split(task: String, note: String)   // recipe is a preset split
    /// Opens the Style Transfer workspace with this preset applied.
    ///
    /// Replaces the old `.generate(modelTask:)`, which built a one-shot page
    /// per card. Same cards, same ids, same musician language — but the card is
    /// now a door rather than a destination, because the settings behind it are
    /// worth keeping when you leave to go and find a reference track.
    case styleTransfer(preset: StylePreset)
    case render                              // notes part → SoundFont audio
    case workbench                           // freeform surface marker
    case arrange                             // structure arranger → mix job
    case match                               // ranking browser, no job
    case tokenSplice                         // EnCodec codebook splice (mix)
    /// Opens Generate with this preset applied — a prompt already started, a
    /// length already set, and the model the job suits already picked.
    ///
    /// A door rather than a page, for the same reason `.styleTransfer` is one:
    /// the settings behind it are worth keeping when you leave to think.
    case generate(preset: GeneratePreset)
    /// One prompt through several models at once, for the comparison this
    /// whole app exists to make. The only Generate card that is a page: a
    /// comparison is genuinely a one-shot batch — a prompt and a set of ticks
    /// — rather than a workspace anyone returns to.
    case compareModels
    /// One track, one DSP transform, no model — see `TrackTransform`.
    case transform(TrackTransform)
    /// A door into the Editor, the way `.workbench` is one into the bench.
    case editor
    /// Separate a whole selection in one go.
    case batchSplit
    /// The writing assistant, doing one of the jobs it knows how to do.
    ///
    /// The kind carries everything that differs between these cards, so twelve
    /// of them share one page: what changes is which question gets asked and
    /// how the answer is laid out, and both of those are properties of the
    /// kind. `needsSource` is separate because it is a fact about the *card*,
    /// not the kind — "Describe this song back to me" and "Name and file it"
    /// both read a song, and both use kinds that would work without one.
    case assistant(kind: AssistKind, needsSource: Bool = false)
    /// The planning half of a generative model, made visible.
    case songPlan(mode: PlanCardMode)
}

/// What a plan card does with the plan once it has one.
///
/// All four run against a model that declares the `plan` task, and all four
/// show the same readable facts; they differ in what happens next, which is
/// enough of a difference to be worth four cards rather than one page with a
/// mode switch on it.
enum PlanCardMode: Equatable, Sendable {
    /// Roll several plans, show them, render only the chosen one.
    case choose
    /// Show the plan behind a take that has already been rendered.
    case inspect
    /// Re-render a take's existing plan with different sound.
    case reroll
    /// Pin tempo, key and time signature so the planner stops guessing them.
    case pin
}

/// What the action *is*, which the gallery turns into a badge. Not the same
/// question as `RecipeCategory` — "What mashes with this?" sits among the
/// recombine actions because that is what you are about to do, but it measures
/// and returns no audio, so it is badged `ANALYSE`.
/// `.invent` is the from-nothing case: no source audio exists to be exact
/// about or to reimagine, because there is no source. It is a claim about
/// where the audio comes from, which is why the badge is worth drawing —
/// "REIMAGINE" over a card that has never been shown a file is a promise
/// about material the user does not have.
/// `.write` is the odd one out, and says so: it is the only mode that produces
/// no audio at all. What comes back is words — a description, lyrics, a title,
/// a plan — which you then read, edit, and choose to use or not. Badging that
/// as `GENERATE` would promise a render that never arrives.
enum RecipeMode { case exact, reimagine, analyse, invent, write }

/// The three labelled shelves of the gallery. Derived from neither `mode` nor
/// `engine` on its own: karaoke is a preset separation (`.split`) yet belongs
/// under Recombine because that is the goal, and the melody hand-off is a
/// Reimagine even though it submits no job of its own.
enum RecipeCategory: String, CaseIterable, Identifiable {
    /// First, because it is the only shelf that needs nothing to start from.
    /// Everything below it asks you to bring audio.
    case generate
    /// Second, because it is where you go when you cannot fill in the first.
    /// Everything on this shelf produces words rather than audio: a
    /// description, lyrics, a title, a plan. Nothing here renders anything,
    /// and nothing here commits until you have read it and said yes.
    case assist
    case separate, recombine, reimagine

    var id: String { rawValue }

    /// Chip label in the filter row.
    var title: String {
        switch self {
        case .generate: "Generate"
        case .assist: "Help me write"
        case .separate: "Separate & analyse"
        case .recombine: "Recombine"
        case .reimagine: "Reimagine"
        }
    }

    /// Section eyebrow above the grid, which says what the shelf promises.
    var sectionTitle: String {
        switch self {
        case .generate: "GENERATE — FROM NOTHING BUT A DESCRIPTION"
        case .assist: "HELP ME WRITE — WORDS FIRST, MUSIC AFTER"
        case .separate: "SEPARATE & ANALYSE"
        case .recombine: "RECOMBINE — YOUR AUDIO, EXACTLY"
        case .reimagine: "REIMAGINE — A MODEL REWRITES IT"
        }
    }
}

struct Recipe: Identifiable, Equatable {
    let id: String
    let name: String
    let tagline: String
    let mode: RecipeMode
    let category: RecipeCategory
    let icon: String
    let slots: [Slot]
    let engine: RecipeEngine
    let phase: Int               // ≤2 available; ≥3 shown "coming soon"
    var wantsLyrics = false      // show the lyrics editor (Rewrite the Lyrics)
    /// Models this card should open on when installed, best first.
    ///
    /// A preference, never a gate: the page still lists every model that can
    /// do the task, and a card whose favourite is not installed opens on
    /// whatever else can. It exists because several specialists — monophonic
    /// pitch tracking, expressive piano — are strictly better at one job and
    /// completely invisible behind a dropdown that lists them alphabetically.
    var prefersModelIds: [String] = []

    var isAvailable: Bool { phase <= 2 }
}

/// The launch recipe table. Data only — views render it, JobsStore executes it.
///
/// `id` is a wire value: it travels as `recipeId` on a recombine submission and
/// is written into the provenance of every mix. Renaming one orphans the
/// provenance of everything already made, so names and taglines move freely and
/// ids never do.
enum RecipeCatalog {
    /// A card's engine, from the preset table keyed by its own id. Force
    /// unwrapped on purpose: a Generate card with no preset is a card that
    /// opens a screen and does nothing, and the two tables are twenty lines
    /// apart — a build failure here is the cheapest possible way to find out.
    /// The one slot every transform card takes: anything with audio in it.
    private static func transformSlot() -> Slot {
        Slot(id: "source", label: "Song or part",
             accepts: [KindPattern(pattern: "song.mix"),
                       KindPattern(pattern: "stem.*"),
                       KindPattern(pattern: "layer.*")],
             arity: 1...1, autoDerive: nil)
    }

    private static func generate(_ id: String) -> RecipeEngine {
        .generate(preset: GeneratePreset.preset(id: id)!)
    }

    /// What the assistant cards read from. Anything with audio in it: these
    /// cards describe, rename or react to a piece of music, and a stem is as
    /// describable as a whole song. `layer.*` rides along with `stem.*` by the
    /// convention at the top of this file.
    private static func assistSourceSlot() -> Slot {
        Slot(id: "source", label: "Song or part",
             accepts: [KindPattern(pattern: "song.mix"),
                       KindPattern(pattern: "stem.*"),
                       KindPattern(pattern: "layer.*")],
             arity: 1...1, autoDerive: nil)
    }

    /// What the plan cards read from — a song only.
    ///
    /// Narrower than the assistant slot on purpose: a plan belongs to a whole
    /// generated take. A stem cut out of one afterwards has no plan of its
    /// own, and offering it here would promise something the engine cannot
    /// answer.
    private static func planSlot() -> Slot {
        Slot(id: "source", label: "Generated song",
             accepts: [KindPattern(pattern: "song.mix")],
             arity: 1...1, autoDerive: nil)
    }

    static let all: [Recipe] = [
        // MARK: Generate
        //
        // Every other shelf starts from audio you already have. These start
        // from a sentence. They carry no slots for that reason — the source
        // picker every other card opens with would have nothing to pick.
        Recipe(id: "gen-song-lyrics",
               name: "Write a song with lyrics",
               tagline: "Words you write, sung over music it composes",
               mode: .invent, category: .generate, icon: "music.mic",
               slots: [], engine: generate("gen-song-lyrics"), phase: 1,
               wantsLyrics: true),
        Recipe(id: "gen-instrumental",
               name: "Instrumental track",
               tagline: "A full-length backing, no voice on it",
               mode: .invent, category: .generate,
               icon: "music.quarternote.3",
               slots: [], engine: generate("gen-instrumental"), phase: 1),
        Recipe(id: "gen-sketch",
               name: "Song sketch",
               tagline: "Four short takes, before you commit to a long one",
               mode: .invent, category: .generate, icon: "bolt",
               slots: [], engine: generate("gen-sketch"), phase: 1),
        Recipe(id: "gen-drum-loop",
               name: "Drum loop",
               tagline: "A bar or two of drums to build the rest on",
               mode: .invent, category: .generate, icon: "metronome",
               slots: [], engine: generate("gen-drum-loop"), phase: 1),
        Recipe(id: "gen-bassline",
               name: "Bassline",
               tagline: "Low end to drop under something",
               mode: .invent, category: .generate, icon: "waveform.path",
               slots: [], engine: generate("gen-bassline"), phase: 1),
        Recipe(id: "gen-chord-bed",
               name: "Chord bed",
               tagline: "Pads and harmony to write over",
               mode: .invent, category: .generate, icon: "pianokeys",
               slots: [], engine: generate("gen-chord-bed"), phase: 1),
        Recipe(id: "gen-hook",
               name: "Melody or hook",
               tagline: "The line the song gets remembered by",
               mode: .invent, category: .generate, icon: "music.note",
               slots: [], engine: generate("gen-hook"), phase: 1),
        Recipe(id: "gen-ambient-bed",
               name: "Ambient bed",
               tagline: "Long, slow and edgeless — for underneath",
               mode: .invent, category: .generate, icon: "wind",
               slots: [], engine: generate("gen-ambient-bed"), phase: 1),
        Recipe(id: "gen-sound-effect",
               name: "Sound effect",
               tagline: "Foley and one-off noises, not music",
               mode: .invent, category: .generate,
               icon: "speaker.wave.2",
               slots: [], engine: generate("gen-sound-effect"), phase: 1),
        Recipe(id: "gen-riser",
               name: "Riser or transition",
               tagline: "The lift into a drop, or the sweep out of one",
               mode: .invent, category: .generate,
               icon: "arrow.up.forward",
               slots: [], engine: generate("gen-riser"), phase: 1),
        Recipe(id: "gen-one-shot",
               name: "One-shot sample",
               tagline: "A single hit, short enough to drop in a sampler",
               mode: .invent, category: .generate,
               icon: "circle.grid.cross",
               slots: [], engine: generate("gen-one-shot"), phase: 1),
        Recipe(id: "gen-fit-track",
               name: "Generate to fit this track",
               tagline: "New audio at the tempo and key of one you have",
               mode: .invent, category: .generate, icon: "tuningfork",
               // The slot is what the picker offers; nothing of the track's
               // audio is used, only its measured tempo and key.
               slots: [Slot(id: "reference", label: "Track to match",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: generate("gen-fit-track"), phase: 1),
        Recipe(id: "gen-explore-prompt",
               name: "Explore a prompt",
               tagline: "Four takes of one idea, four different seeds",
               mode: .invent, category: .generate,
               icon: "square.on.square.dashed",
               slots: [], engine: generate("gen-explore-prompt"), phase: 1),
        Recipe(id: "gen-compare-models",
               name: "Compare models on one prompt",
               tagline: "The same description through several models at once",
               mode: .invent, category: .generate,
               icon: "square.grid.3x1.below.line.grid.1x2",
               slots: [], engine: .compareModels, phase: 1),

        // MARK: The model's own plan
        //
        // Four cards over one capability: a model that declares the `plan`
        // task can run its planning half alone, cheaply, and say what it
        // intends before the expensive half starts. They sit on the Generate
        // shelf because that is what they lead to.
        Recipe(id: "plan-choose",
               name: "Pick the plan before the sound",
               tagline: "Three quick plans — choose one before the slow part",
               mode: .invent, category: .generate, icon: "list.bullet.rectangle",
               slots: [], engine: .songPlan(mode: .choose), phase: 1),
        Recipe(id: "plan-inspect",
               name: "What was it thinking?",
               tagline: "The tempo, key and shape the model chose for you",
               mode: .analyse, category: .generate, icon: "eye",
               slots: [planSlot()], engine: .songPlan(mode: .inspect), phase: 1),
        Recipe(id: "plan-reroll",
               name: "Same song, new sound",
               tagline: "Keep what it wrote; record it again differently",
               mode: .invent, category: .generate, icon: "arrow.triangle.2.circlepath",
               slots: [planSlot()], engine: .songPlan(mode: .reroll), phase: 1),
        Recipe(id: "plan-pin",
               name: "Lock in the tempo and key",
               tagline: "You set the facts; the model fills in the rest",
               mode: .invent, category: .generate, icon: "pin",
               slots: [], engine: .songPlan(mode: .pin), phase: 1),

        // MARK: Help me write
        //
        // Every card here runs the writing assistant — a small language model
        // that lives on this machine. None of them render audio, and none of
        // them commit anything: each ends in an editable draft the user
        // accepts, changes, or throws away.
        Recipe(id: "assist-interview",
               name: "Help me describe it",
               tagline: "Answer a few questions; it writes the description",
               mode: .write, category: .assist, icon: "bubble.left.and.bubble.right",
               slots: [], engine: .assistant(kind: .interview), phase: 1),
        Recipe(id: "assist-flesh-out",
               name: "Flesh out my idea",
               tagline: "A rough phrase in, a vivid description back",
               mode: .write, category: .assist, icon: "wand.and.stars",
               slots: [], engine: .assistant(kind: .fleshOut), phase: 1),
        Recipe(id: "assist-lyrics",
               name: "Write the lyrics with me",
               tagline: "Verses and choruses, tagged the way the model likes",
               mode: .write, category: .assist, icon: "text.quote",
               slots: [], engine: .assistant(kind: .lyrics), phase: 1),
        Recipe(id: "assist-pick-model",
               name: "Which model should I use?",
               tagline: "Say what you're after; it points at the right one",
               mode: .write, category: .assist, icon: "signpost.right",
               slots: [], engine: .assistant(kind: .pickModel), phase: 1),
        Recipe(id: "assist-plan-song",
               name: "Plan the song first",
               tagline: "Sketch the shape before any audio is made",
               mode: .write, category: .assist, icon: "square.stack.3d.down.right",
               slots: [], engine: .assistant(kind: .planSong), phase: 1),
        Recipe(id: "assist-route",
               name: "Say the job in your own words",
               tagline: "Describe what you want; it opens the right card",
               mode: .write, category: .assist, icon: "text.magnifyingglass",
               slots: [], engine: .assistant(kind: .routeIntent), phase: 1),
        Recipe(id: "assist-brief",
               name: "Surprise me with a brief",
               tagline: "A fresh idea when you're out of them",
               mode: .write, category: .assist, icon: "dice",
               slots: [], engine: .assistant(kind: .brief), phase: 1),
        Recipe(id: "assist-translate",
               name: "Sing it in another language",
               tagline: "The same song, in French — or fifty others",
               mode: .write, category: .assist, icon: "globe",
               slots: [], engine: .assistant(kind: .translateLyrics), phase: 1),
        Recipe(id: "assist-describe",
               name: "Describe this song back to me",
               tagline: "Hear what the app hears, in a sentence",
               mode: .write, category: .assist, icon: "quote.bubble",
               slots: [assistSourceSlot()],
               engine: .assistant(kind: .describeSong, needsSource: true),
               phase: 1),
        Recipe(id: "assist-more-like",
               name: "More like this one",
               tagline: "Point at a song you love; get more of that family",
               mode: .write, category: .assist, icon: "square.on.square",
               slots: [assistSourceSlot()],
               engine: .assistant(kind: .moreLikeThis, needsSource: true),
               phase: 1),
        Recipe(id: "assist-critique",
               name: "Fix what bothers me",
               tagline: "Say what's wrong; it rewrites the description",
               mode: .write, category: .assist, icon: "bandage",
               slots: [assistSourceSlot()],
               engine: .assistant(kind: .critiqueFix, needsSource: true),
               phase: 1),
        Recipe(id: "assist-name",
               name: "Name and file it",
               tagline: "Titles and tags, so the library stays findable",
               mode: .write, category: .assist, icon: "tag",
               slots: [assistSourceSlot()],
               engine: .assistant(kind: .nameAndTag, needsSource: true),
               phase: 1),

        // MARK: Separate & analyse
        Recipe(id: "melody-notes",
               name: "Extract the melody line",
               tagline: "The tune as notes — one line, no chords",
               mode: .analyse, category: .separate, icon: "music.note",
               slots: [Slot(id: "source", label: "Vocal or lead part",
                            accepts: [KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*"),
                                      KindPattern(pattern: "song.mix")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song to get its vocal stem"))],
               engine: .split(task: "transcribe",
                              note: "Monophonic: it follows one line and "
                                  + "ignores everything under it, which is "
                                  + "why a stem beats a mix here."),
               phase: 1,
               prefersModelIds: ["transcribe-swiftf0"]),
        Recipe(id: "piano-notes",
               name: "Transcribe a piano performance",
               tagline: "Onsets, offsets, velocities and pedal",
               mode: .analyse, category: .separate, icon: "pianokeys",
               slots: [Slot(id: "source", label: "Piano recording or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .split(task: "transcribe",
                              note: "Built for piano alone — it will "
                                  + "transcribe anything and be wrong about "
                                  + "most of it."),
               phase: 1,
               prefersModelIds: ["transcribe-transkun"]),
        Recipe(id: "batch-split",
               name: "Split several at once",
               tagline: "Every track you tick, separated in one go",
               mode: .exact, category: .separate,
               icon: "square.stack.3d.up",
               slots: [], engine: .batchSplit, phase: 1),

        // MARK: One track, one transform
        //
        // Everything here is `mix_spec` doing what it has always been able to
        // do (contract §5.4) with no model in the way. The Editor does each of
        // them too, and better; these are the version where you do not open a
        // window. See `TrackTransform`.
        Recipe(id: "reverse",
               name: "Reverse it",
               tagline: "Backwards, sample for sample",
               mode: .exact, category: .recombine,
               icon: "arrow.uturn.backward",
               slots: [transformSlot()], engine: .transform(.reverse),
               phase: 1),
        Recipe(id: "speed",
               name: "Change the speed",
               tagline: "Faster or slower, same pitch",
               mode: .exact, category: .recombine, icon: "speedometer",
               slots: [transformSlot()], engine: .transform(.speed),
               phase: 1),
        Recipe(id: "key-shift",
               name: "Change the key",
               tagline: "Up or down in semitones, formants intact",
               mode: .exact, category: .recombine, icon: "arrow.up.arrow.down",
               slots: [transformSlot()], engine: .transform(.key), phase: 1),
        Recipe(id: "fades",
               name: "Fade in and out",
               tagline: "A clean top and tail, both ends the same",
               mode: .exact, category: .recombine,
               icon: "slider.horizontal.3",
               slots: [transformSlot()], engine: .transform(.fades),
               phase: 1),
        Recipe(id: "clean-up",
               name: "Clean up a recording",
               tagline: "Rumble out, silence down, peaks in",
               mode: .exact, category: .recombine, icon: "bandage",
               slots: [transformSlot()], engine: .transform(.cleanUp),
               phase: 1),
        Recipe(id: "loop-cut",
               name: "Make a loop",
               tagline: "Whole bars, cut on the track's own downbeats",
               mode: .exact, category: .recombine,
               icon: "repeat",
               slots: [transformSlot()], engine: .transform(.loop), phase: 1),
        Recipe(id: "conform",
               name: "Conform to another track",
               tagline: "Take one track's tempo and key onto another",
               mode: .exact, category: .recombine,
               icon: "arrow.triangle.swap",
               slots: [transformSlot(),
                       Slot(id: "reference", label: "Track to match",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .transform(.conform), phase: 1),
        Recipe(id: "editor",
               name: "Open in Editor",
               tagline: "Trim, cut, level and fade one file by hand",
               mode: .exact, category: .recombine, icon: "scissors",
               slots: [], engine: .editor, phase: 1),

        Recipe(id: "split-instruments",
               name: "Split into instruments",
               tagline: "Vocals, drums, bass and more as separate parts",
               mode: .exact, category: .separate, icon: "waveform",
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
                            arity: 1...1, autoDerive: nil)],
               engine: .split(task: "separate",
                              note: "Each part is written to Library › Parts "
                                  + "and stays linked to the song it came from."),
               phase: 1),
        Recipe(id: "transcribe-notes",
               name: "Transcribe to notes",
               tagline: "MIDI note tracks per instrument, drums included",
               mode: .analyse, category: .separate, icon: "music.note",
               // Its own note has always said a stem transcribes more
               // cleanly than a mix; until now it said so to a picker that
               // would not let you choose one.
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .split(task: "transcribe",
                              note: "Works best on a separated stem — split "
                                  + "into instruments first for cleaner notes."),
               phase: 1),
        Recipe(id: "read-features",
               name: "Read the features",
               tagline: "Tempo, key, beat grid and section structure",
               mode: .analyse, category: .separate,
               icon: "chart.bar.doc.horizontal",
               // A stem has a tempo and a key of its own, and the app
               // already stores analysis per part — the picker was the only
               // thing insisting the question could only be asked of a song.
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .split(task: "analyze",
                              note: "Attaches the measurements to the song. "
                                  + "Alignment, compatibility badges and "
                                  + "auto-match all read them."),
               phase: 1),

        // MARK: Recombine — your audio, exactly
        Recipe(id: "karaoke",
               name: "Make a karaoke track",
               tagline: "Pull the vocals out — keep both halves",
               mode: .exact, category: .recombine, icon: "music.mic",
               slots: [Slot(id: "song", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
                            arity: 1...1, autoDerive: nil)],
               engine: .split(task: "separate",
                              note: "A vocals-versus-instrumental separator "
                                  + "gives you the cleanest two halves."),
               phase: 1),
        Recipe(id: "mashup",
               name: "Mash up two songs",
               tagline: "Key and tempo auto-matched, beat-aligned",
               mode: .exact, category: .recombine, icon: "arrow.triangle.merge",
               slots: [Slot(id: "parts", label: "Parts",
                            accepts: [KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*"),
                                      KindPattern(pattern: "song.mix")],
                            arity: 2...8,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song into instruments for cleaner material"))],
               engine: .mix(defaults: MixDefaults()),
               phase: 2),
        Recipe(id: "swap-vocals",
               name: "Swap the vocals",
               tagline: "This voice over that backing track",
               mode: .exact, category: .recombine, icon: "person.wave.2",
               slots: [Slot(id: "vocals", label: "Vocals",
                            accepts: [KindPattern(pattern: "stem.vocals")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song to get its vocal stem")),
                       Slot(id: "backing", label: "Backing track",
                            accepts: [KindPattern(pattern: "stem.instrumental"),
                                      KindPattern(pattern: "song.mix")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song to get its instrumental"))],
               engine: .mix(defaults: MixDefaults()),
               phase: 2),
        Recipe(id: "replace-drums",
               name: "Replace the drums",
               tagline: "New rhythm section under the same song",
               mode: .exact, category: .recombine, icon: "metronome",
               slots: [Slot(id: "song", label: "Song (minus drums)",
                            accepts: [KindPattern(pattern: "stem.vocals"),
                                      KindPattern(pattern: "stem.bass"),
                                      KindPattern(pattern: "stem.other"),
                                      KindPattern(pattern: "stem.guitar"),
                                      KindPattern(pattern: "stem.piano")],
                            arity: 1...5,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split the song into instruments first")),
                       Slot(id: "drums", label: "Drums",
                            accepts: [KindPattern(pattern: "stem.drums"),
                                      KindPattern(pattern: "stem.drums.*")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song to get its drum stem"))],
               engine: .mix(defaults: MixDefaults()),
               phase: 2),
        Recipe(id: "polish",
               name: "Polish the mix",
               tagline: "Loudness-normalise and limit — nothing else",
               mode: .exact, category: .recombine, icon: "wand.and.stars",
               slots: [Slot(id: "mix", label: "Mix",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .mix(defaults: MixDefaults(autoMatchTempo: false,
                                                  autoMatchKey: false,
                                                  stretch: false)),
               phase: 2),
        Recipe(id: "remix-structure",
               name: "Remix the structure",
               tagline: "Reorder, repeat or drop sections — same sound",
               mode: .exact, category: .recombine,
               icon: "square.grid.3x1.below.line.grid.1x2",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .arrange, phase: 2),
        Recipe(id: "notes-instrument",
               name: "Notes into a new instrument",
               tagline: "Render a MIDI part to audio, then restyle it",
               mode: .exact, category: .recombine, icon: "pianokeys",
               slots: [Slot(id: "notes", label: "Notes",
                            accepts: [KindPattern(pattern: "notes.*")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "transcribe",
                                note: "Transcribe a song or stem into notes first"))],
               engine: .render, phase: 2),
        Recipe(id: "what-mashes",
               name: "What mashes with this?",
               tagline: "Rank your whole library by musical compatibility",
               mode: .analyse, category: .recombine,
               icon: "sparkle.magnifyingglass",
               slots: [Slot(id: "base", label: "Starting point",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .match, phase: 2),
        Recipe(id: "workbench",
               name: "Open in Workbench",
               tagline: "Freeform: stack any parts, tweak everything",
               mode: .exact, category: .recombine,
               icon: "slider.horizontal.3",
               slots: [],
               engine: .workbench,
               phase: 2),

        // MARK: Reimagine — a model rewrites it
        // (SR3 — every generative mode below passed the Mac-path spike)
        Recipe(id: "melody-start",
               name: "Start a song from this melody",
               tagline: "A new arrangement that follows this tune",
               mode: .reimagine, category: .reimagine,
               icon: "waveform.badge.plus",
               slots: [Slot(id: "melody", label: "Melody",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*"),
                                      KindPattern(pattern: "notes.melody")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "melody-start", mode: .melody)),
               phase: 1),
        Recipe(id: "restyle",
               name: "Restyle this song",
               tagline: "Same song, new sound — an AI cover",
               mode: .reimagine, category: .reimagine, icon: "sparkles",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil),
                       Slot(id: "reference", label: "Style reference (optional)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 0...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "restyle", mode: .cover)),
               phase: 2),
        Recipe(id: "sound-like",
               name: "Make it sound like this",
               tagline: "Borrow another track's texture, keep your own song",
               mode: .reimagine, category: .reimagine,
               icon: "square.on.square.dashed",
               slots: [Slot(id: "source", label: "Your track (optional)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 0...1, autoDerive: nil),
                       Slot(id: "reference", label: "Sound to borrow",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "sound-like", mode: .reference)),
               phase: 2),
        Recipe(id: "keep-stems",
               name: "Keep the vocal, replace the band",
               tagline: "The stems you keep are the original recording",
               mode: .reimagine, category: .reimagine,
               icon: "square.stack.3d.up",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song into stems first"))],
               engine: .styleTransfer(preset: StylePreset(
                   id: "keep-stems", mode: .stems)),
               phase: 2),
        Recipe(id: "morph-style",
               name: "Morph into another style",
               tagline: "Describe what it is, then what it should become",
               mode: .reimagine, category: .reimagine,
               icon: "arrow.triangle.swap",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "morph-style", mode: .morph)),
               phase: 2),
        Recipe(id: "rewrite-lyrics",
               name: "Rewrite the lyrics",
               tagline: "The same music sings your new words",
               mode: .reimagine, category: .reimagine, icon: "text.quote",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "rewrite-lyrics", mode: .cover,
                   notice: "Type the new words below. The music stays; the "
                       + "model sings what you write.")),
               phase: 2, wantsLyrics: true),
        Recipe(id: "add-layer",
               name: "Add a new layer",
               tagline: "AI plays a new instrument over your track",
               mode: .reimagine, category: .reimagine,
               icon: "plus.square.on.square",
               slots: [Slot(id: "context", label: "Track",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "add-layer", mode: .layer)),
               phase: 2),
        Recipe(id: "back-vocal",
               name: "Back this vocal",
               tagline: "An AI band behind your singer",
               mode: .reimagine, category: .reimagine, icon: "person.2.wave.2",
               slots: [Slot(id: "context", label: "Vocals",
                            accepts: [KindPattern(pattern: "stem.vocals")],
                            arity: 1...1,
                            autoDerive: AutoDerive(
                                splitTask: "separate",
                                note: "Split a song to get its vocal stem"))],
               engine: .styleTransfer(preset: StylePreset(
                   id: "back-vocal", mode: .layer)),
               phase: 2),
        Recipe(id: "repaint",
               name: "Fill or fix a section",
               tagline: "Regenerate just the seconds you select",
               mode: .reimagine, category: .reimagine, icon: "bandage",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "repaint", mode: .repaint)),
               phase: 2),
        Recipe(id: "complete-band",
               name: "Complete the band",
               tagline: "A sparse track becomes a full arrangement",
               mode: .reimagine, category: .reimagine, icon: "person.3",
               slots: [Slot(id: "source", label: "Sparse track",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "complete-band", mode: .complete)),
               phase: 2),
        Recipe(id: "loop-reimagine",
               name: "Reimagine a loop",
               tagline: "Short section in, fresh texture out",
               mode: .reimagine, category: .reimagine,
               icon: "arrow.2.squarepath",
               slots: [Slot(id: "loop", label: "Loop (≤ 47 s)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "loop-reimagine", mode: .shape)),
               phase: 2),
        Recipe(id: "continue-song",
               name: "Continue this song",
               tagline: "Extends up to 120 s total",
               mode: .reimagine, category: .reimagine, icon: "forward.end",
               slots: [Slot(id: "source", label: "Song to continue (≤ 115 s)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "continue-song", mode: .continueTrack)),
               phase: 2),
        Recipe(id: "ai-extract",
               name: "Extract a stem with AI",
               tagline: "Generative stems, not the original recording",
               mode: .reimagine, category: .reimagine, icon: "scissors",
               slots: [Slot(id: "source", label: "Song or part",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .styleTransfer(preset: StylePreset(
                   id: "ai-extract", mode: .extract)),
               phase: 2),
        Recipe(id: "token-splice",
               name: "Token Splice playground",
               tagline: "Experimental — one song's bones, another's skin",
               mode: .reimagine, category: .reimagine,
               icon: "waveform.path.badge.plus",
               slots: [Slot(id: "a", label: "Structure (coarse tokens)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil),
                       Slot(id: "b", label: "Texture (fine tokens)",
                            accepts: [KindPattern(pattern: "song.mix"),
                                      KindPattern(pattern: "stem.*"),
                                      KindPattern(pattern: "layer.*")],
                            arity: 1...1, autoDerive: nil)],
               engine: .tokenSplice, phase: 2),
    ]

    static func recipe(id: String) -> Recipe? {
        all.first { $0.id == id }
    }

    static func inCategory(_ category: RecipeCategory) -> [Recipe] {
        all.filter { $0.category == category }
    }
}
