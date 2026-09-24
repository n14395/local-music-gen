// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Token Splice Playground: two pieces of material, one of which supplies the
/// coarse (structure) EnCodec codebooks while the other supplies the fine
/// (texture) ones, decoded back to audio.
///
/// Labelled experimental in the rail rather than hidden behind a warning
/// dialog — the artifacts ARE the point, and the design's rule is that the app
/// says what it is about to do rather than asking whether you are sure.
struct SpliceActionView: View {
    let recipe: Recipe
    let sourceId: String?
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
    let onBack: () -> Void

    @State private var materials: [String: PickedMaterial] = [:]
    /// Each slot's second line, keyed by slot id.
    ///
    /// `ActionCopy.sourceMeta` is a song read plus an analysis read, and both
    /// cards were asking for it from inside `body`, so every redraw of the
    /// page re-ran four queries. The line only depends on the material, so it
    /// is resolved when the slots change.
    @State private var metaBySlot: [String: String] = [:]
    @State private var pickingSlot: Slot?
    @State private var splitCodebook = 2
    @State private var swapped = false
    @State private var title = ""
    @State private var submitting = false
    @AppStorage("actions.lastRuns") private var runsJSON = "{}"
    /// The action log, decoded once rather than at render time.
    ///
    /// It lives in `@AppStorage` as a JSON blob, and the rail was asking for
    /// the whole thing to be parsed from inside `body` — so every redraw
    /// re-decoded it, which on a page with a text field is every keystroke.
    @State private var runLog = ActionRunLog()

    private var spliceModel: ModelInfo? {
        MixModels.splicer(in: catalog.models)
    }

    private var materialA: PickedMaterial? { materials["a"] }
    private var materialB: PickedMaterial? { materials["b"] }

    private var defaultName: String {
        guard let materialA, let materialB else { return recipe.name }
        return "Splice: \(materialA.sourceTitle) × \(materialB.sourceTitle)"
    }

    var body: some View {
        ActionPage(recipe: recipe, onBack: onBack) {
            if spliceModel == nil {
                ActionModelGate(
                    readiness: catalog.readiness,
                    title: "Token Splice is not installed",
                    detail: "A 76 MB EnCodec model does the encoding and the "
                        + "decoding. Nothing else on this page changes.",
                    onOpenModels: onOpenModels)
            }
            ForEach(recipe.slots) { slot in
                ActionSourceCard(
                    eyebrow: slot.label.uppercased(),
                    material: materials[slot.id],
                    meta: metaBySlot[slot.id],
                    playback: playback,
                    placeholder: slot.id == "a"
                        ? "Whose rhythm and arrangement survive."
                        : "Whose instruments and tone survive.",
                    chooseTitle: materials[slot.id] == nil
                        ? "Choose from Library…" : "Change…",
                    onChoose: { pickingSlot = slot },
                    onRemove: materials[slot.id] == nil ? nil : {
                        materials.removeValue(forKey: slot.id)
                    })
            }
            ActionOptionsCard(eyebrow: "SPLICE") {
                HStack(spacing: 12) {
                    Text("Split at codebook")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .frame(width: 130, alignment: .leading)
                    BenchStepper(value: $splitCodebook, range: 1...7)
                    Text("OF 8").metaLine()
                    Spacer(minLength: 12)
                    BenchToggleChip(isOn: $swapped, label: "Swap roles")
                }
                ActionFootnote(
                    text: "Lower keeps only the broadest structure from the "
                        + "first source; higher lets more of it survive into "
                        + "the texture. Mono, 24 kHz, and deliberately weird.")
            }
            ActionOptionsCard(eyebrow: "NAME") {
                ActionTextField(placeholder: defaultName, text: $title)
            }
        } commit: {
            ActionCommitRow(title: "Splice",
                            costLine: costLine,
                            costSubline: "ORIGINALS ARE NEVER MODIFIED",
                            isEnabled: materialA != nil && materialB != nil
                                && spliceModel != nil && !submitting,
                            error: jobs.lastError,
                            onCommit: { submit(back: true) },
                            onQueue: { submit(back: false) })
        } rail: {
            ActionRail(outputs: outputs,
                       explanation: "One new song in Library › Songs, recorded "
                            + "with both sources in its provenance. Expect "
                            + "artifacts — this is a codec being misused on "
                            + "purpose.",
                       lastRun: runLog.runs[recipe.id])
        }
        .onAppear(perform: restore)
        .onChange(of: materials) { refreshMetaBySlot() }
        .task { runLog = ActionRunLog.decoded(runsJSON) }
        .onChange(of: runsJSON) { runLog = ActionRunLog.decoded(runsJSON) }
        .sheet(item: $pickingSlot) { slot in
            PartPickerSheet(
                slotLabel: slot.label, accepts: slot.accepts,
                autoDerive: slot.autoDerive,
                catalog: catalog, library: library, parts: parts, jobs: jobs,
                playback: playback, onOpenModels: onOpenModels,
                onPick: { materials[slot.id] = $0 })
        }
    }

    private func refreshMetaBySlot() {
        metaBySlot = materials.mapValues {
            ActionCopy.sourceMeta($0, library: library, parts: parts)
        }
    }

    private var costLine: String? {
        let longest = [materialA, materialB]
            .compactMap { $0?.durationS }.max()
        return ActionFormat.join([
            ActionFormat.estimate(ActionEstimate.taskSeconds(
                model: spliceModel, sourceDurationS: longest)),
            "SAVED TO LIBRARY › SONGS"])
    }

    private var outputs: [ActionOutput] {
        let length = [materialA, materialB]
            .compactMap { $0?.durationS }.min()
        return [ActionOutput(id: "splice",
                             name: title.isEmpty ? defaultName : title,
                             qualifier: "experimental",
                             meta: ActionFormat.join([
                                length.map(ActionFormat.length),
                                "MONO 24 KHZ"]))]
    }

    private func restore() {
        guard let sourceId, materials["a"] == nil,
              let material = PickedMaterial.resolve(id: sourceId, parts: parts,
                                                    library: library)
        else { return }
        materials["a"] = material
    }

    private func submit(back: Bool) {
        guard let materialA, let materialB, let spliceModel else { return }
        submitting = true
        let name = title.isEmpty ? defaultName : title
        Task {
            let created = await jobs.submitTokenSplice(
                modelId: spliceModel.id, title: name,
                aId: materialA.id, bId: materialB.id,
                coarseFrom: swapped ? "b" : "a",
                splitCodebook: splitCodebook)
            submitting = false
            guard created != nil else { return }
            runsJSON = ActionRunLog.recording(
                .init(summary: name,
                      detail: ActionFormat.join([
                        "CODEBOOK \(splitCodebook)",
                        swapped ? "SWAPPED" : nil]),
                      at: Date(), sourceId: materialA.id,
                      modelId: spliceModel.id),
                recipeId: recipe.id, in: runsJSON)
            if back { onBack() }
        }
    }
}
