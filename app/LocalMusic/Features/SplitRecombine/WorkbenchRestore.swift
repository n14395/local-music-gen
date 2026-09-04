import Foundation

/// Rebuilding a bench from a finished mix's provenance.
///
/// Every recombined song already stores one `AppliedIngredient` per clip —
/// placement, trim, gain, and what auto-match did to it. That was always
/// intended to be enough to reopen the arrangement, and this is the code that
/// cashes it in. The pure half takes decoded provenance and returns lanes and
/// clips so it can be tested without a database.
enum WorkbenchRestore {

    struct Result {
        var lanes: [WorkbenchModel.Lane]
        var clips: [WorkbenchModel.Clip]
        var targetBpm: Double?
        var autoMatchTempo: Bool
        var autoMatchKey: Bool
        /// Things the user should know were guessed or lost.
        var warnings: [String]
    }

    /// Lane a slotId belongs to. Timeline mixes write `<lane>-<n>`; everything
    /// written before that (and the section arranger's `sec-0-A1`) falls back
    /// to the role, which lands an arranger's output on one lane — exactly
    /// where it came from.
    static func laneName(slotId: String, role: String) -> String {
        let parts = slotId.split(separator: "-")
        if parts.count >= 2, Int(parts[parts.count - 1]) != nil {
            let slug = parts.dropLast().joined(separator: "-")
            if !slug.isEmpty { return slug.capitalized }
        }
        return role.isEmpty ? "Clip" : role.capitalized
    }

    /// The grid the mix was rendered on. Not stored directly, but recoverable:
    /// `stretchRatio == targetBpm / sourceBpm`, so any stretched ingredient
    /// whose source is still analyzed gives it back exactly.
    static func targetBpm(applied: [AppliedIngredient],
                          sourceBpm: [String: Double]) -> Double? {
        for item in applied {
            guard let ratio = item.stretchRatio, ratio > 0,
                  let source = sourceBpm[item.submission.partId], source > 0
            else { continue }
            return source * ratio
        }
        return nil
    }

    static func restore(applied: [AppliedIngredient],
                        materials: [String: PickedMaterial],
                        summaries: [String: AnalysisSummary],
                        sections: [String: [AnalysisPayload.Section]],
                        fallbackBpm: Double?) -> Result {
        var lanes: [WorkbenchModel.Lane] = []
        var laneIds: [String: String] = [:]      // lane name -> lane id
        var clips: [WorkbenchModel.Clip] = []
        var warnings: [String] = []
        var missing = 0

        for item in applied {
            let name = laneName(slotId: item.submission.slotId, role: item.role)
            let laneId: String
            if let existing = laneIds[name] {
                laneId = existing
            } else {
                let lane = WorkbenchModel.Lane(name: name)
                lanes.append(lane)
                laneIds[name] = lane.id
                laneId = lane.id
            }

            let partId = item.submission.partId
            let material = materials[partId]
                ?? PickedMaterial(missingId: partId,
                                  title: item.sourceSongTitle, role: item.role)
            var clip = WorkbenchModel.Clip(laneId: laneId, material: material)
            clip.isMissing = materials[partId] == nil
            if clip.isMissing { missing += 1 }
            clip.gainDb = item.submission.gainDb
            clip.pan = item.submission.pan ?? 0
            clip.muted = item.submission.muted
            clip.startBeats =
                TimelineMath.clampStart(item.submission.offsetBeats)
            clip.sectionStartS = item.submission.sectionStartS
            clip.sectionEndS = item.submission.sectionEndS
            clip.fadeInS = item.submission.fadeInS ?? 0
            clip.fadeOutS = item.submission.fadeOutS ?? 0
            clip.summary = summaries[partId]
            clip.sections = sections[partId] ?? []
            clip.sourceDurationS = material.durationS
            clips.append(clip)
        }

        let bpmByPart = summaries.compactMapValues { $0.bpm }
        let recovered = targetBpm(applied: applied, sourceBpm: bpmByPart)
        if recovered == nil && fallbackBpm == nil && !applied.isEmpty {
            warnings.append("Original tempo unknown — set Tempo to restore the "
                            + "spacing this mix was built on.")
        }
        if missing > 0 {
            warnings.append(missing == 1
                            ? "1 part is missing — replace or remove it before "
                              + "rendering."
                            : "\(missing) parts are missing — replace or "
                              + "remove them before rendering.")
        }
        // Loudness and keep-tracks were never recorded; say so rather than
        // pretending the restored bench is the original in every respect.
        warnings.append("Loudness and Keep tracks are back at their defaults.")

        return Result(lanes: lanes, clips: clips,
                      targetBpm: recovered ?? fallbackBpm,
                      autoMatchTempo: applied.contains { $0.stretchRatio != nil },
                      autoMatchKey: applied.contains { $0.pitchShiftSt != 0 },
                      warnings: warnings)
    }
}

extension WorkbenchModel {
    /// Load a recombined song's provenance onto the bench.
    @MainActor
    func load(songId: String, parts: PartsStore, library: LibraryStore)
        -> [String] {
        let rows = (try? parts.repository.ingredients(songId: songId)) ?? []
        let applied = rows.compactMap { row -> AppliedIngredient? in
            try? BackendClient.decoder.decode(
                AppliedIngredient.self, from: Data(row.transformJSON.utf8))
        }
        guard !applied.isEmpty else { return ["This song has no recorded parts."] }

        var materials: [String: PickedMaterial] = [:]
        var summaries: [String: AnalysisSummary] = [:]
        var sectionsById: [String: [AnalysisPayload.Section]] = [:]
        for item in applied {
            let partId = item.submission.partId
            guard materials[partId] == nil else { continue }
            if let material = PickedMaterial.resolve(id: partId, parts: parts,
                                                     library: library) {
                materials[partId] = material
            }
            if let record = parts.analysis(for: partId) {
                summaries[partId] = AnalysisSummary(record: record)
                // Sections only — see `ClipAnalysis`. An eight-part mix used to
                // decode eight whole analyses, beat lists and CLAP embeddings
                // and all, on the click that reopened it.
                let payload = try? BackendClient.decoder.decode(
                    ClipAnalysis.self, from: Data(record.analysisJSON.utf8))
                sectionsById[partId] = payload?.sections ?? []
            }
        }
        let songBpm = parts.analysis(for: songId).flatMap { $0.bpm }
        let result = WorkbenchRestore.restore(
            applied: applied, materials: materials, summaries: summaries,
            sections: sectionsById, fallbackBpm: songBpm)

        lanes = result.lanes
        clips = result.clips
        targetBpm = result.targetBpm
        autoMatchTempo = result.autoMatchTempo
        autoMatchKey = result.autoMatchKey
        outputName = ""
        return result.warnings
    }
}
