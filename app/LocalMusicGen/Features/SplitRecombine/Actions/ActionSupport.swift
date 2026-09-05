import Foundation
import SwiftUI

// The numbers and sentences an action config page has to say out loud before
// you commit: how long it will take, what it will write, what it did last time.
// Kept together and away from the views because every page says the same things
// in the same mono voice, and because the estimate rules are the one piece of
// arithmetic here worth reading on its own.

// MARK: - Estimates

/// Two different declarations, two different multiplications.
///
/// A task model (separate / transcribe / analyze / mix / render) declares
/// `estRealtimeFactor` — processing seconds per second of *input*. A generative
/// model declares `estSecondsPerAudioSecond` — seconds per second of *requested
/// output*. Neither is a promise, and a model that declares neither gets no
/// estimate at all rather than a made-up one.
enum ActionEstimate {
    /// Task models: factor × the source's duration.
    static func taskSeconds(model: ModelInfo?, sourceDurationS: Double?) -> Double? {
        guard let model, let factor = model.capabilities.estRealtimeFactor,
              factor > 0, let duration = sourceDurationS, duration > 0
        else { return nil }
        return factor * duration
    }

    /// Generative models: factor × the length being asked for.
    static func generativeSeconds(model: ModelInfo?, durationS: Double) -> Double? {
        guard let model, durationS > 0 else { return nil }
        let factor = model.capabilities.estSecondsPerAudioSecond
        guard factor > 0 else { return nil }
        return factor * durationS
    }
}

// MARK: - Mono formatting

/// The mono voice: all-caps, no decimals unless they carry information.
enum ActionFormat {
    /// `40 S` · `1 MIN 10 S` · `4 MIN` — how long some *work* takes. MIN is
    /// reserved for that: see `length` for why.
    static func duration(_ seconds: Double) -> String {
        let total = Int(max(1, seconds.rounded()))
        if total < 90 { return "\(total) S" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) MIN" : "\(minutes) MIN \(rest) S"
    }

    /// `119 S` · `201 S` — how long a piece of *audio* is, always in whole
    /// seconds however long it runs.
    ///
    /// The design writes `119 S · WAV`, `201 S · 107 BPM` and `≤ 300 S`, and
    /// never rolls a length over to minutes: a length sits beside a BPM and a
    /// key in the same mono line, where `3 MIN 21 S` is three tokens where the
    /// others are one. The Library says the same thing the same way through
    /// `LibraryFormat.seconds`. MIN belongs to `duration`, which measures work.
    static func length(_ seconds: Double) -> String {
        // No floor: a half-second slice is a half-second slice. Rounding it up
        // to "1 S" is a small lie in a formatter that eight call sites read.
        if seconds < 1 { return String(format: "%.1f S", max(0, seconds)) }
        return "\(Int(seconds.rounded())) S"
    }

    /// `≈ 40 S`, or nil when the model declared no estimate — the design would
    /// rather say nothing than guess at what the Mac will do.
    static func estimate(_ seconds: Double?) -> String? {
        guard let seconds else { return nil }
        return "≈ " + duration(seconds)
    }

    /// `12 MIN AGO` · `3 DAYS AGO` — the "when" half of the last-run summary.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))
        if elapsed < 60 { return "JUST NOW" }
        if elapsed < 3600 { return "\(Int(elapsed / 60)) MIN AGO" }
        if elapsed < 86400 {
            let hours = Int(elapsed / 3600)
            return "\(hours) HOUR\(hours == 1 ? "" : "S") AGO"
        }
        let days = Int(elapsed / 86400)
        return "\(days) DAY\(days == 1 ? "" : "S") AGO"
    }

    /// Camelot/BPM/length metadata joined the way every row in the app joins it.
    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - Copy

/// Text the pages lift out of catalog data. Every one of these reads real
/// values; none of them invent a fact the app does not hold.
enum ActionCopy {
    /// A model's `description` is a paragraph — a radio card has one line. Take
    /// the first sentence, or the clause before the em dash, whichever comes
    /// first. (`—` is where the catalog puts the "and here is the caveat" half.)
    static func oneLine(_ description: String) -> String {
        let stops = [". ", " — "]
        var cut = description
        for stop in stops {
            if let range = cut.range(of: stop) {
                cut = String(cut[cut.startIndex..<range.lowerBound])
            }
        }
        if cut.hasSuffix(".") { cut.removeLast() }
        return cut
    }

    /// `VOCALS · 119 S · 86 BPM · 5B` — the mono second line under a chosen
    /// source. Assembled from the record and its analysis; a field the library
    /// does not have simply does not appear.
    @MainActor
    static func sourceMeta(_ material: PickedMaterial, library: LibraryStore,
                           parts: PartsStore) -> String {
        var bits: [String?] = []
        if material.kind == "song.mix" {
            let song = (try? library.repository.song(id: material.songId)) ?? nil
            bits.append(song?.sourceLabel.uppercased())
        } else {
            bits.append(kindLabel(material.kind).uppercased())
        }
        if let duration = material.durationS, duration > 0 {
            bits.append(ActionFormat.length(duration))
        }
        let analysis = parts.analysis(for: material.id)
        if let bpm = analysis?.bpm {
            bits.append("\(Int(bpm.rounded())) BPM")
        }
        if let camelot = analysis?.camelot {
            bits.append(camelot.uppercased())
        }
        return ActionFormat.join(bits)
    }

    /// `stem.vocals` → `Vocals`, `notes.melody` → `Melody notes`.
    static func kindLabel(_ kind: String) -> String {
        let tail = kind.split(separator: ".").dropFirst().joined(separator: " ")
        let name = tail.isEmpty ? kind : tail
        let capitalised = name.prefix(1).uppercased() + name.dropFirst()
        return kind.hasPrefix("notes.") ? "\(capitalised) notes" : capitalised
    }
}

// MARK: - Last run

/// "LAST RUN OF THIS ACTION", persisted per recipe.
///
/// Written at submit time, because that is the moment the app knows every fact
/// it shows: which source, which model, which knobs were moved. It deliberately
/// does *not* claim a run duration — the screen is often gone before the job
/// finishes, so it reports when the run started instead of inventing how long
/// it took.
struct ActionRunLog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var summary: String        // "test01 → parts"
        var detail: String         // "DEMUCS 6-STEM · SHIFTS 2"
        var at: Date
        var sourceId: String?
        var modelId: String?
    }

    var runs: [String: Entry] = [:]

    static func decoded(_ raw: String) -> ActionRunLog {
        guard let data = raw.data(using: .utf8),
              let log = try? JSONDecoder().decode(ActionRunLog.self, from: data)
        else { return ActionRunLog() }
        return log
    }

    func encoded() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The `Recently used ⌄` menu, newest first.
    var recentRecipeIds: [String] {
        runs.sorted { $0.value.at > $1.value.at }.map(\.key)
    }

    /// Returns the new blob rather than taking the store `inout`: the callers
    /// are `@AppStorage` properties written from inside an escaping `Task`,
    /// where an inout access to a captured property is not available.
    static func recording(_ entry: Entry, recipeId: String,
                          in raw: String) -> String {
        var log = decoded(raw)
        log.runs[recipeId] = entry
        return log.encoded()
    }

    /// `SHIFTS 2 · SEED 41` — the knobs that were moved off their defaults,
    /// which is the only part of a parameter form worth remembering.
    @MainActor
    static func changedParams(_ state: ParameterFormState) -> String {
        let changed = state.specs.filter {
            $0.isInternal != true && state.params[$0.key] != $0.default
        }
        return changed.prefix(3).map { spec in
            "\(spec.label.uppercased()) \(describe(state.params[spec.key]))"
        }.joined(separator: " · ")
    }

    private static func describe(_ value: JSONValue?) -> String {
        switch value {
        case .string(let s): s.uppercased()
        case .int(let i): "\(i)"
        case .double(let d): String(format: "%g", d)
        case .bool(let b): b ? "ON" : "OFF"
        default: "—"
        }
    }
}
