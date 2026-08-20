import Foundation

/// State behind the Workbench, in both of its lenses.
///
/// A **lane** is presentation plus a mixer bus: the wire has no lane concept,
/// so lane gain/mute/solo fold into every clip on the way out. A **clip** is
/// one placement of one part and maps 1:1 to an `IngredientSubmission` — which
/// is what lets a lane hold the same stem three times (verse, chorus, outro)
/// with no schema or contract change: `submitRecombine` dedupes uploads by file
/// URL, so repeats cost nothing.
///
/// The pure helpers (mute matrix, folding, slot naming, ingredient building)
/// are `nonisolated static` and unit-tested.
@MainActor @Observable
final class WorkbenchModel {

    struct Lane: Identifiable, Equatable {
        let id: String
        var name: String
        var gainDb: Double = 0
        var muted = false
        var solo = false

        init(id: String = UUID().uuidString.lowercased(), name: String,
             gainDb: Double = 0, muted: Bool = false, solo: Bool = false) {
            self.id = id
            self.name = name
            self.gainDb = gainDb
            self.muted = muted
            self.solo = solo
        }
    }

    struct Clip: Identifiable, Equatable {
        /// SwiftUI identity; slotId is derived. `var` so a copy can take a
        /// fresh one — duplicating by hand-copying fields silently drops any
        /// property added later.
        var id: String
        var laneId: String
        var material: PickedMaterial
        /// Provenance referred to a part that no longer exists. Kept so a
        /// reopened mix still shows where it sat, excluded from the render.
        var isMissing = false
        var gainDb: Double = 0
        var muted = false
        /// Start on the TARGET grid. Fractional because the wire always was
        /// (`IngredientSubmission.offsetBeats` is a Double) and the engine now
        /// places to the sample.
        var startBeats: Double = 0
        var sectionStartS: Double?
        var sectionEndS: Double?
        var fadeInS: Double = 0
        var fadeOutS: Double = 0
        var sourceDurationS: Double?
        var summary: AnalysisSummary?
        var sections: [AnalysisPayload.Section] = []
        /// "A1", "B2" … when this clip is one section of a structure, so a
        /// wall of identically-named clips is still readable.
        var sectionLabel: String?

        var isDrums: Bool { material.kind.hasPrefix("stem.drums") }

        init(id: String = UUID().uuidString.lowercased(), laneId: String,
             material: PickedMaterial) {
            self.id = id
            self.laneId = laneId
            self.material = material
            self.sourceDurationS = material.durationS
        }
    }

    var lanes: [Lane] = []
    var clips: [Clip] = []
    /// 4/4 unless told otherwise. Not inferred per clip: the dsp worker infers
    /// its own bars from downbeat medians, and two disagreeing guesses would be
    /// worse than one constant.
    var beatsPerBar: Double = 4
    var autoMatchTempo = true
    var autoMatchKey = true
    var targetBpm: Double?
    var targetCamelot: String?
    var targetLufs: Double = -14
    var keepTracks = false
    var outputName = ""

    // MARK: target grid

    var effectiveTargetBpm: Double? {
        targetBpm ?? clips.compactMap { $0.summary?.bpm }.first
    }

    var effectiveTargetCamelot: String? {
        targetCamelot ?? clips.compactMap { $0.summary?.camelot }.first
    }

    var targetSummary: AnalysisSummary {
        AnalysisSummary(bpm: effectiveTargetBpm,
                        camelot: effectiveTargetCamelot)
    }

    func plan(for clip: Clip) -> MatchPlan? {
        guard let summary = clip.summary else { return nil }
        return Mashability.plan(source: summary, target: targetSummary,
                                isDrums: clip.isDrums)
    }

    // MARK: lane folding (pure)

    /// Solo wins, at lane granularity: while any lane is soloed, every clip on
    /// a non-solo lane is silenced. A clip's own mute always silences it.
    nonisolated static func effectivelyMuted(lanes: [Lane],
                                             clips: [Clip]) -> [String: Bool] {
        let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        let anySolo = lanes.contains { $0.solo }
        return Dictionary(uniqueKeysWithValues: clips.map { clip in
            let lane = byId[clip.laneId]
            let laneSilent = anySolo ? !(lane?.solo ?? false)
                                     : (lane?.muted ?? false)
            return (clip.id, clip.muted || laneSilent)
        })
    }

    /// Lane trim adds to clip trim — the two faders are in series, as on a desk.
    nonisolated static func effectiveGainDb(lanes: [Lane],
                                            clips: [Clip]) -> [String: Double] {
        let byId = Dictionary(uniqueKeysWithValues: lanes.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: clips.map {
            ($0.id, $0.gainDb + (byId[$0.laneId]?.gainDb ?? 0))
        })
    }

    /// Lane order, then time. Deterministic ordering keeps `mix_spec.tracks`,
    /// provenance rows and keep_tracks stem names stable between renders.
    nonisolated static func ordered(lanes: [Lane], clips: [Clip]) -> [Clip] {
        let rank = Dictionary(uniqueKeysWithValues:
                                lanes.enumerated().map { ($1.id, $0) })
        return clips.sorted {
            let (l, r) = (rank[$0.laneId] ?? .max, rank[$1.laneId] ?? .max)
            if l != r { return l < r }
            if $0.startBeats != $1.startBeats { return $0.startBeats < $1.startBeats }
            return $0.id < $1.id
        }
    }

    /// `"vocals-1"`, `"vocals-2"`, … — readable in the provenance list and
    /// unique, which the (songId, slotId) primary key requires once a lane can
    /// hold several clips. The engine never reads slotId, so this is free.
    nonisolated static func slugged(_ name: String) -> String {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { out, ch in
                if ch == "-" && (out.isEmpty || out.hasSuffix("-")) { return }
                out.append(ch)
            }
        let trimmed = slug.hasSuffix("-") ? String(slug.dropLast()) : slug
        return trimmed.isEmpty ? "clip" : trimmed
    }

    nonisolated static func slotIds(lanes: [Lane], clips: [Clip]) -> [String: String] {
        let laneName = Dictionary(uniqueKeysWithValues:
                                    lanes.map { ($0.id, slugged($0.name)) })
        var counts: [String: Int] = [:]
        var out: [String: String] = [:]
        for clip in ordered(lanes: lanes, clips: clips) {
            let slug = laneName[clip.laneId] ?? "clip"
            let n = (counts[slug] ?? 0) + 1
            counts[slug] = n
            out[clip.id] = "\(slug)-\(n)"
        }
        return out
    }

    // MARK: submission

    func ingredients() -> [IngredientSubmission] {
        let mute = Self.effectivelyMuted(lanes: lanes, clips: clips)
        let gain = Self.effectiveGainDb(lanes: lanes, clips: clips)
        let slots = Self.slotIds(lanes: lanes, clips: clips)
        // Missing clips are dropped, and the UI blocks Create Mix while any
        // exist — quietly rendering without a track the user can see would be
        // worse than refusing.
        return Self.ordered(lanes: lanes, clips: clips)
            .filter { !$0.isMissing }
            .map { clip in
                IngredientSubmission(
                    slotId: slots[clip.id] ?? clip.id,
                    partId: clip.material.id,
                    gainDb: gain[clip.id] ?? clip.gainDb,
                    muted: mute[clip.id] ?? clip.muted,
                    offsetBeats: clip.startBeats,
                    sectionStartS: clip.sectionStartS,
                    sectionEndS: clip.sectionEndS,
                    fadeInS: clip.fadeInS > 0 ? clip.fadeInS : nil,
                    fadeOutS: clip.fadeOutS > 0 ? clip.fadeOutS : nil)
            }
    }

    func options() -> RecombineOptions {
        RecombineOptions(autoMatchTempo: autoMatchTempo,
                         autoMatchKey: autoMatchKey,
                         targetBpm: targetBpm, targetCamelot: targetCamelot,
                         targetLufs: targetLufs, keepTracks: keepTracks,
                         targetDurationS: arrangementDurationS)
    }

    /// End of the last clip, or nil when nothing is placed. Sent so a fade-out
    /// that runs past the audio still renders instead of being trimmed away.
    var arrangementDurationS: Double? {
        guard let bpm = effectiveTargetBpm else { return nil }
        let endBeats = clips.filter { !$0.isMissing }
            .map { $0.startBeats + lengthBeats(of: $0) }.max()
        guard let endBeats, endBeats > 0 else { return nil }
        return endBeats * 60.0 / bpm
    }

    var hasMissingClips: Bool { clips.contains { $0.isMissing } }

    // MARK: editing

    /// Adding material makes a new lane holding one clip — so the simple case
    /// (stack two stems, hit Create Mix) is exactly what it always was.
    @discardableResult
    func add(material: PickedMaterial, parts: PartsStore?) -> Clip {
        let lane = Lane(name: material.name)
        lanes.append(lane)
        var clip = Self.makeClip(material: material, laneId: lane.id,
                                 parts: parts)
        clip.startBeats = 0
        clips.append(clip)
        return clip
    }

    static func makeClip(material: PickedMaterial, laneId: String,
                         parts: PartsStore?) -> Clip {
        var clip = Clip(laneId: laneId, material: material)
        if let record = parts?.analysis(for: material.id) {
            clip.summary = AnalysisSummary(record: record)
            let payload = try? BackendClient.decoder.decode(
                AnalysisPayload.self, from: Data(record.analysisJSON.utf8))
            clip.sections = payload?.sections ?? []
            clip.sourceDurationS = material.durationS ?? payload?.durationS
        }
        return clip
    }

    func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }

    func clips(inLane id: String) -> [Clip] {
        clips.filter { $0.laneId == id }.sorted { $0.startBeats < $1.startBeats }
    }

    func removeClip(_ id: String) {
        clips.removeAll { $0.id == id }
    }

    func removeLane(_ id: String) {
        clips.removeAll { $0.laneId == id }
        lanes.removeAll { $0.id == id }
    }

    /// Duplicate a clip onto the same lane, placed right after itself unless
    /// told otherwise — the "repeat this bar" gesture.
    @discardableResult
    func duplicate(_ id: String, atBeats: Double? = nil) -> Clip? {
        guard let source = clips.first(where: { $0.id == id }) else { return nil }
        var copy = source
        copy.id = UUID().uuidString.lowercased()
        copy.startBeats = atBeats ?? (source.startBeats + lengthBeats(of: source))
        clips.append(copy)
        return copy
    }

    /// Length on the target grid, via the one shared formula.
    func lengthBeats(of clip: Clip) -> Double {
        guard let sourceLength = TimelineGeometry.sourceLengthS(
            sectionStartS: clip.sectionStartS, sectionEndS: clip.sectionEndS,
            sourceDurationS: clip.sourceDurationS) else {
            return beatsPerBar * 4     // unknown duration: draw four bars
        }
        return TimelineGeometry.timelineLengthBeats(
            sourceLengthS: sourceLength, sourceBpm: clip.summary?.bpm,
            targetBpm: effectiveTargetBpm, autoMatchTempo: autoMatchTempo)
    }

    /// Replace a clip with one clip per analyzed section, laid back to back on
    /// its lane — the Structure Arranger's move, now something you can grab and
    /// reorder afterwards.
    @discardableResult
    func explodeIntoSections(_ id: String) -> [Clip] {
        guard let source = clips.first(where: { $0.id == id }),
              source.sections.count > 1 else { return [] }
        var made: [Clip] = []
        var cursor = source.startBeats
        var groupCounts: [String: Int] = [:]
        for section in source.sections {
            var clip = Clip(laneId: source.laneId, material: source.material)
            clip.gainDb = source.gainDb
            clip.muted = source.muted
            clip.summary = source.summary
            clip.sections = source.sections
            clip.sourceDurationS = source.sourceDurationS
            clip.sectionStartS = section.startS
            clip.sectionEndS = section.endS
            clip.startBeats = cursor
            // A1, A2, B1 … — the same naming the structure arranger used, and
            // the only way a lane of one repeated stem stays readable.
            let group = section.label ?? section.group ?? "S"
            let n = (groupCounts[group] ?? 0) + 1
            groupCounts[group] = n
            clip.sectionLabel = "\(group)\(n)"
            cursor += lengthBeats(of: clip)
            made.append(clip)
        }
        clips.removeAll { $0.id == id }
        clips.append(contentsOf: made)
        return made
    }

    /// Fade the overlap between two clips on one lane: the earlier one fades
    /// out across it, the later one fades in. Expressed as ordinary per-clip
    /// fades, so the engine needs no notion of a crossfade at all.
    func crossfade(_ firstId: String, with secondId: String) {
        guard let a = clips.firstIndex(where: { $0.id == firstId }),
              let b = clips.firstIndex(where: { $0.id == secondId })
        else { return }
        let (early, late) = clips[a].startBeats <= clips[b].startBeats
            ? (a, b) : (b, a)
        let earlyEnd = clips[early].startBeats + lengthBeats(of: clips[early])
        let overlapBeats = min(earlyEnd, clips[late].startBeats
                               + lengthBeats(of: clips[late]))
            - clips[late].startBeats
        guard overlapBeats > 0, let bpm = effectiveTargetBpm ?? targetBpm
        else { return }
        let seconds = overlapBeats * 60.0 / bpm
        clips[early].fadeOutS = seconds
        clips[late].fadeInS = seconds
    }

    /// Move every clip so the earliest starts at zero. The engine rejects
    /// negative offsets, so this is how the timeline makes room at the front.
    func shiftAll(byBeats delta: Double) {
        let moved = TimelineMath.normalizedToZero(
            clips.map { $0.startBeats + delta })
        for (index, start) in moved.enumerated() {
            clips[index].startBeats = start
        }
    }

    // MARK: snapshots (undo)

    struct Snapshot: Equatable {
        var lanes: [Lane]
        var clips: [Clip]
    }

    func snapshot() -> Snapshot { Snapshot(lanes: lanes, clips: clips) }

    func apply(_ snapshot: Snapshot) {
        lanes = snapshot.lanes
        clips = snapshot.clips
    }
}
