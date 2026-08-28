import Foundation

/// Everything one finished take was generated with, read back off its library
/// row — and the three sizes of "make another one like that" the app offers.
///
/// Most of the recipe was already on the row: `prompt`, `lyrics`, `modelId`,
/// the whole submitted param dict in `paramsJSON` (which is where the Full
/// control panel's values live), and the seed the engine actually rolled in
/// `seedUsed`. Two things were not, because neither is a *param*: the length
/// and the take count are arguments of the submission itself. `durationS` on
/// the row is no substitute for the first — it is the length that came back,
/// and a model that pads or trims does not return what it was asked for. So
/// `requestEnvelope` writes both down at ingest, and everything here reads
/// them back while tolerating every row written before it existed.
struct GenerationSettings: Equatable {
    /// The submitted params, with the reserved sidecars below stripped out —
    /// what a parameter form can be poured from directly.
    var params: [String: JSONValue] = [:]
    /// The length that submission asked for. Nil on rows written before the
    /// envelope existed; fall back to the row's own `durationS`.
    var requestedDurationS: Double?
    /// How many takes it asked for. Nil for the same reason.
    var takes: Int?
    /// The seed the engine actually used — which is the interesting one. A
    /// take rendered on Random has no seed in `params` at all, and this is the
    /// only record of what it turned out to be.
    var seedUsed: Int64?

    /// Keys that ride inside `paramsJSON` beside the real params.
    ///
    /// The bag is already the record of everything-about-this-render, and
    /// `meta` has ridden in it since the planning models landed, so the
    /// envelope goes in the same way rather than growing two columns and a
    /// migration for one number each. No model in the catalog declares a param
    /// under either name, and `stripped(_:)` is the one reader that has to
    /// know: everywhere else these are simply not params.
    static let metaKey = "meta"
    static let requestKey = "request"
    /// The one key every generative family in the catalog spells the same way.
    static let seedKey = "seed"

    /// The sidecar written at ingest. `durationS` is what the submission
    /// asked for, not what came back.
    static func requestEnvelope(durationS: Double?, takes: Int) -> JSONValue {
        var fields: [String: JSONValue] = ["count": .int(max(1, takes))]
        if let durationS { fields["duration_s"] = .double(durationS) }
        return .object(fields)
    }

    /// Read a row's recipe. Never fails: an unparseable or absent params bag
    /// reads as "nothing remembered", which still leaves prompt, lyrics and
    /// model to reuse.
    static func of(_ song: SongRecord) -> GenerationSettings {
        var settings = GenerationSettings(seedUsed: song.seedUsed)
        guard let data = song.paramsJSON.data(using: .utf8),
              let stored = try? JSONDecoder().decode([String: JSONValue].self,
                                                     from: data)
        else { return settings }
        if let request = stored[requestKey]?.objectValue {
            settings.requestedDurationS = request["duration_s"]?.doubleValue
            settings.takes = request["count"]?.intValue
        }
        settings.params = stripped(stored)
        return settings
    }

    /// The params without the sidecars.
    static func stripped(_ stored: [String: JSONValue]) -> [String: JSONValue] {
        var params = stored
        params.removeValue(forKey: metaKey)
        params.removeValue(forKey: requestKey)
        return params
    }

    /// The values to pour into a fresh form for one scope.
    ///
    /// Seed is the only key handled specially, and in both directions. Without
    /// it the key is *removed* rather than zeroed, so the form keeps its own
    /// Random default and the next take is a new performance of the same
    /// recipe. With it, `seedUsed` wins over whatever `params` holds: a take
    /// rendered on Random stored no seed at all, and the number the engine
    /// reported is exactly the thing that makes the render repeatable.
    func reusableParams(includeSeed: Bool) -> [String: JSONValue] {
        var out = params
        out.removeValue(forKey: Self.seedKey)
        if includeSeed {
            if let seedUsed {
                out[Self.seedKey] = .int(Int(seedUsed))
            } else if let stored = params[Self.seedKey], stored != .null {
                out[Self.seedKey] = stored
            }
        }
        return out
    }

    /// How many values the reuse actually carries, which is what the arrival
    /// notice counts. Seed is excluded in both scopes — it is named
    /// separately there, and counting it would make "and a fresh seed" read
    /// as one of the settings being reused.
    var settingCount: Int {
        reusableParams(includeSeed: false).filter { $0.value != .null }.count
    }
}

/// How much of a finished take the composer is filled with.
///
/// One type rather than three closures because the three differ only in how
/// far they reach, and because the copy has to be identical in the four places
/// they are offered — a menu, a tile grid, the takes rail, and a tooltip.
enum ReuseScope: String, CaseIterable, Sendable {
    /// Prompt, lyrics and model. What "Reuse prompt" has always done.
    case prompt
    /// Everything the take was made with, seed left on Random: the same
    /// recipe, played again rather than repeated.
    case all
    /// Everything including the seed the engine used — the same render.
    case allWithSeed

    /// Menu wording, where there is room to be unambiguous.
    var title: String {
        switch self {
        case .prompt: "Reuse prompt"
        case .all: "Reuse all parameters"
        case .allWithSeed: "Reuse all + seed"
        }
    }

    /// The same action where the control is 116 pt wide. "Reuse all
    /// parameters" does not survive that at a legible size, and a tile that
    /// scales its label down to fit reads as broken rather than as terse.
    var shortTitle: String {
        switch self {
        case .prompt: "Reuse prompt"
        case .all: "Reuse all"
        case .allWithSeed: "Reuse all + seed"
        }
    }

    var help: String {
        switch self {
        case .prompt:
            "Start a new generation from this track's prompt, lyrics and model"
        case .all:
            "Start a new generation from everything this track was made "
                + "with — model, length, takes and every Full control "
                + "setting — with a fresh seed, so you get a different take "
                + "of the same recipe"
        case .allWithSeed:
            "The same, with the seed this track was rendered on — the same "
                + "render again, so changing one setting is the only thing "
                + "you hear change"
        }
    }

    var includesParams: Bool { self != .prompt }
    var includesSeed: Bool { self == .allWithSeed }
}

extension GenerationSettings {
    /// The composer prefill one scope produces for a track.
    ///
    /// `@MainActor` for `PrefillBox.Prefill` alone; nothing here touches the
    /// stores.
    @MainActor
    static func prefill(for song: SongRecord,
                        scope: ReuseScope) -> PrefillBox.Prefill {
        var request = PrefillBox.Prefill(prompt: song.prompt,
                                         lyrics: song.lyrics,
                                         modelId: song.modelId)
        guard scope.includesParams else { return request }
        let settings = of(song)
        request.params = settings.reusableParams(
            includeSeed: scope.includesSeed)
        request.durationS = settings.requestedDurationS ?? song.durationS
        request.takes = settings.takes
        request.notice = notice(for: song, settings: settings, scope: scope)
        return request
    }

    /// The line above the composer saying what arriving here changed.
    ///
    /// Worth the sentence: a reuse writes values into a panel that is closed
    /// in Simple mode, and a screen that silently changed nine things you
    /// cannot see is the surprise the notice band exists to prevent.
    static func notice(for song: SongRecord, settings: GenerationSettings,
                       scope: ReuseScope) -> String {
        let count = settings.settingCount
        let values = count == 1 ? "1 setting" : "\(count) settings"
        switch scope {
        case .prompt:
            return "Reusing \(song.title)'s prompt."
        case .all:
            return "Reusing everything \(song.title) was made with — "
                + "\(values), on a fresh seed."
        case .allWithSeed:
            let seed = settings.seedUsed.map {
                "seed \($0.formatted(.number.grouping(.never)))"
            } ?? "its own seed"
            return "Reusing everything \(song.title) was made with — "
                + "\(values), \(seed)."
        }
    }
}
