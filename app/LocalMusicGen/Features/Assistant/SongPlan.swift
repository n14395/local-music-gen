// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A plan an ACE-Step model wrote before rendering anything.
///
/// ACE-Step generates in two halves. A 5 Hz language model writes a plan — a
/// `<think>` block naming tempo, key, time signature, language and a rewritten
/// caption, followed by a stream of coarse audio codes sketching the whole
/// song — and only then does the diffusion half render that plan into audio.
///
/// The plan is the half that decides what the song *is*. Until now it was
/// invisible: you sent a description and got back a wav, and if the result had
/// the right sound but the wrong shape there was nothing to point at. This
/// type is that plan, made readable and reusable.
///
/// `codes` is deliberately opaque — thousands of `<|audio_code_N|>` tokens that
/// mean nothing to a person. It is carried, never shown. Handing it back to a
/// generate job renders this exact plan again, which is what "keep the song,
/// change how it sounds" is built from.
struct SongPlan: Sendable, Equatable, Identifiable {
    var id: Int { index }
    var index: Int
    var bpm: Int?
    var keyscale: String?
    var timeSignature: String?
    var caption: String?
    var genres: String?
    var language: String?
    var durationS: Int?
    var codes: String

    /// Whether this plan can actually be re-rendered. A plan with no codes is
    /// still worth showing — the metadata is the readable half — but it cannot
    /// be the source of a "render this one" action, and the UI must not offer
    /// one that would silently generate something different.
    var isRenderable: Bool { !codes.isEmpty }

    init(index: Int, metadata: [String: JSONValue], codes: String) {
        self.index = index
        self.codes = codes
        self.bpm = metadata["bpm"]?.intValue
        self.keyscale = metadata["keyscale"]?.stringValue?.nonEmpty
        self.timeSignature = metadata["timesignature"]?.stringValue?.nonEmpty
        self.caption = metadata["caption"]?.stringValue?.nonEmpty
        self.genres = metadata["genres"]?.stringValue?.nonEmpty
        self.language = metadata["language"]?.stringValue?.nonEmpty
        self.durationS = metadata["duration"]?.intValue
    }

    /// Every plan in a finished `plan` job's result.
    static func all(meta: [String: JSONValue]?) -> [SongPlan] {
        guard let raw = meta?["plans"]?.arrayValue else { return [] }
        return raw.enumerated().compactMap { offset, value in
            guard let object = value.objectValue else { return nil }
            return SongPlan(
                index: object["index"]?.intValue ?? offset,
                metadata: object["metadata"]?.objectValue ?? [:],
                codes: object["audio_codes"]?.stringValue ?? "")
        }
    }

    /// The single plan behind a finished *generate* take, if the model
    /// reported one. Absent for every model that has no planning stage, and
    /// for the ACE-Step tasks that skip it — which is why this is optional
    /// rather than an empty plan.
    static func of(meta: [String: JSONValue]?) -> SongPlan? {
        guard let meta else { return nil }
        let metadata = meta["lm_metadata"]?.objectValue
        let codes = meta["audio_codes"]?.stringValue ?? ""
        guard metadata?.isEmpty == false || !codes.isEmpty else { return nil }
        return SongPlan(index: 0, metadata: metadata ?? [:], codes: codes)
    }

    // MARK: - Reading it out

    /// The plan as one line of plain English, for a card subtitle.
    ///
    /// Only what was actually reported: a model that named a tempo and nothing
    /// else gets a one-fact line, never a line padded with defaults it never
    /// chose.
    var summary: String {
        var parts: [String] = []
        if let bpm { parts.append("\(bpm) BPM") }
        if let keyscale { parts.append(keyscale) }
        if let timeSignature { parts.append(timeSignatureLabel(timeSignature)) }
        if let durationS, durationS > 0 {
            parts.append(SongDigest.length(Double(durationS)))
        }
        return parts.joined(separator: " · ")
    }

    /// The labelled facts, for a plan card's body.
    var facts: [(label: String, value: String)] {
        var rows: [(String, String)] = []
        if let bpm { rows.append(("Tempo", "\(bpm) BPM")) }
        if let keyscale { rows.append(("Key", keyscale)) }
        if let timeSignature {
            rows.append(("Time", timeSignatureLabel(timeSignature)))
        }
        if let durationS, durationS > 0 {
            rows.append(("Length", SongDigest.length(Double(durationS))))
        }
        if let genres { rows.append(("Style", genres)) }
        if let language { rows.append(("Sung in", languageLabel(language))) }
        return rows
    }

    /// ACE-Step writes the time signature as a bare numerator ("4", "3"), so
    /// showing it raw would put a lone "3" under a heading called Time.
    private func timeSignatureLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "4", "4/4": "4/4"
        case "3", "3/4": "3/4 (waltz)"
        case "6", "6/8": "6/8"
        case "5", "5/4": "5/4"
        case "7", "7/8": "7/8"
        default: raw
        }
    }

    private func languageLabel(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty || trimmed == "unknown" { return "—" }
        return Locale.current.localizedString(forLanguageCode: trimmed)
            ?? trimmed.uppercased()
    }
}

/// Models that can show their plan before rendering it.
///
/// Shape-driven, like every other model choice here: a model qualifies by
/// declaring the `plan` task, not by being named.
enum PlanModels {
    static func canPlan(_ model: ModelInfo) -> Bool {
        model.capabilities.supportedTasks.contains("plan")
    }

    /// A model that can be *told* a plan — the other half of the feature. A
    /// captured plan is only reusable on a model that declares the param it
    /// rides in.
    static func acceptsPlan(_ model: ModelInfo) -> Bool {
        model.capabilities.params.contains { $0.key == "audio_codes" }
    }

    static func installed(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter { $0.installState == .installed && canPlan($0) }
    }

    static func candidates(_ models: [ModelInfo]) -> [ModelInfo] {
        models.filter(canPlan).sorted { $0.sizeBytes < $1.sizeBytes }
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
