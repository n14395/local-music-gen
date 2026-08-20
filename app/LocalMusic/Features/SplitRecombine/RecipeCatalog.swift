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
}

/// What the action *is*, which the gallery turns into a badge. Not the same
/// question as `RecipeCategory` — "What mashes with this?" sits among the
/// recombine actions because that is what you are about to do, but it measures
/// and returns no audio, so it is badged `ANALYSE`.
enum RecipeMode { case exact, reimagine, analyse }

/// The three labelled shelves of the gallery. Derived from neither `mode` nor
/// `engine` on its own: karaoke is a preset separation (`.split`) yet belongs
/// under Recombine because that is the goal, and the melody hand-off is a
/// Reimagine even though it submits no job of its own.
enum RecipeCategory: String, CaseIterable, Identifiable {
    case separate, recombine, reimagine

    var id: String { rawValue }

    /// Chip label in the filter row.
    var title: String {
        switch self {
        case .separate: "Separate & analyse"
        case .recombine: "Recombine"
        case .reimagine: "Reimagine"
        }
    }

    /// Section eyebrow above the grid, which says what the shelf promises.
    var sectionTitle: String {
        switch self {
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

    var isAvailable: Bool { phase <= 2 }
}

/// The launch recipe table. Data only — views render it, JobsStore executes it.
///
/// `id` is a wire value: it travels as `recipeId` on a recombine submission and
/// is written into the provenance of every mix. Renaming one orphans the
/// provenance of everything already made, so names and taglines move freely and
/// ids never do.
enum RecipeCatalog {
    static let all: [Recipe] = [
        // MARK: Separate & analyse
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
               slots: [Slot(id: "source", label: "Song",
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
               slots: [Slot(id: "source", label: "Song",
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
               slots: [Slot(id: "source", label: "Song",
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
               slots: [Slot(id: "source", label: "Song",
                            accepts: [KindPattern(pattern: "song.mix")],
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
