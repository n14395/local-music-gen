// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A saved set of parameter overrides for one model.
///
/// Only the keys that differ from the model's defaults are stored, so a preset
/// keeps working when a model gains a parameter — the new one takes its default
/// rather than being silently pinned to whatever it was the day the preset was
/// saved.
struct StudioPreset: Codable, Identifiable, Hashable {
    var id: String { name }
    let name: String
    let modelId: String
    let values: [String: JSONValue]
    /// Built-ins are derived from the model's own declared range rather than
    /// stored, so they cannot go stale, and they cannot be deleted.
    var isBuiltIn = false

    static func == (lhs: StudioPreset, rhs: StudioPreset) -> Bool {
        lhs.name == rhs.name && lhs.modelId == rhs.modelId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(modelId)
    }
}

/// The parameters rail: presets across the top, then the model's params sorted
/// into named group cards.
///
/// Two layouts, same content. `.inspector` is the fixed-width rail down the
/// side of a screen and scrolls itself. `.inline` sits in the composer's own
/// column, between the settings it belongs to and the button that spends
/// them — so it carries no scroller of its own (the composer already has
/// one) and spreads its cards across two columns when the window is wide.
struct StudioParameterPanel: View {
    enum Layout { case inspector, inline }

    @Bindable var state: ParameterFormState
    let model: ModelInfo?
    let onApplyPreset: (StudioPreset) -> Void
    var layout: Layout = .inspector
    /// Bound when the panel is hosting the length unlock. Optional so a panel
    /// shown somewhere without a length slider simply does not offer it.
    var unlockLength: Binding<Bool>?
    var materialPicker: MaterialPickerContext?
    /// Passed straight to the form: params the host is going to submit a value
    /// for even though the form leaves them unset ("Hold the seed").
    var heldValues: [String: Double] = [:]

    @AppStorage("studio.presets") private var storedPresetsJSON = "[]"
    @State private var naming = false
    @State private var draftName = ""
    @State private var appliedPreset: String?
    /// The model, and the form, the highlight belongs to.
    ///
    /// The panel's view identity survives a model switch in Studio, so the chip
    /// used to stay lit after a change of model — and built-in preset names are
    /// derived from a step range, so two models often produce the same
    /// "Draft 6-step". It also used to stay lit after a knob was moved, even
    /// though `changedCount` is this panel's stated signal that a preset is no
    /// longer what you are looking at. Comparing rather than clearing on a
    /// notification keeps the answer true whatever order SwiftUI applies the
    /// preset in.
    @State private var appliedModelId: String?
    @State private var appliedValues: [String: JSONValue]?

    /// The chip to draw as active: the applied preset, but only while the form
    /// is still exactly what it left behind.
    private var litPreset: String? {
        guard let appliedPreset, appliedModelId == model?.id,
              appliedValues == state.values else { return nil }
        return appliedPreset
    }

    var body: some View {
        Group {
            switch layout {
            case .inspector: inspectorBody
            case .inline: inlineBody
            }
        }
        .alert("Save preset", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the \(state.changedCount) parameter"
                 + (state.changedCount == 1 ? "" : "s")
                 + " you changed, for this model.")
        }
    }

    private var inspectorBody: some View {
        VStack(spacing: 0) {
            BenchPanelHeader {
                Text("Parameters")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if state.changedCount > 0 {
                    Text("\(state.changedCount) CHANGED")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer()
                presetRow
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    unlockLengthRow
                    ParameterFormView(state: state,
                                      materialPicker: materialPicker,
                                      heldValues: heldValues)
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
            }
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // No "PARAMETERS" title here: the Full control banner sits
            // directly above and already names what this is. Two headings
            // for one section is one heading too many.
            HStack(spacing: 9) {
                if state.changedCount > 0 {
                    Text("\(state.changedCount) CHANGED")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer(minLength: 8)
                presetRow
            }
            unlockLengthRow
            ParameterFormView(state: state, allowsTwoColumns: true,
                              materialPicker: materialPicker,
                              heldValues: heldValues)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Unlock max length", shown only for a model that declares somewhere to
    /// go. It lives here rather than beside the length slider on purpose: the
    /// slider is in Simple mode too, and a ceiling that can be raised by a
    /// control sitting next to it is a ceiling raised by accident. Full
    /// control is the room you go into deliberately.
    @ViewBuilder private var unlockLengthRow: some View {
        if let binding = unlockLength, let model,
           model.capabilities.duration.canUnlock {
            let duration = model.capabilities.duration
            VStack(alignment: .leading, spacing: 7) {
                Toggle(isOn: binding) {
                    Text("Unlock max length")
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(binding.wrappedValue
                                         ? Bench.Palette.warn
                                         : Bench.Palette.textSecondary)
                }
                .toggleStyle(.bench(width: 32, tint: Bench.Palette.warn))
                // Both numbers, always: the trade is only legible if you can
                // see what you are leaving as well as what you are getting.
                Text(binding.wrappedValue
                     ? "Length can now reach \(Int(duration.unlockedMaxS ?? duration.maxS)) s. "
                       + "Past \(Int(duration.maxS)) s this model is beyond what it was "
                       + "trained for — renders may drift, repeat, end early, or fail "
                       + "outright, and they take proportionally longer."
                     : "\(model.displayName) recommends at most \(Int(duration.maxS)) s. "
                       + "Unlocking raises the slider to \(Int(duration.unlockedMaxS ?? duration.maxS)) s, "
                       + "into lengths the model was not trained for.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(binding.wrappedValue
                                     ? Bench.Palette.warn.opacity(0.85)
                                     : Bench.Palette.textQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                         style: .continuous)
                .fill(binding.wrappedValue ? Bench.Palette.warn.opacity(0.08)
                                           : Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                      style: .continuous)
                .strokeBorder(binding.wrappedValue
                              ? Bench.Palette.warn.opacity(0.30)
                              : Bench.Palette.cardStrokeSoft, lineWidth: 1))
        }
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets) { preset in
                let lit = litPreset == preset.name
                Button {
                    // Applied first, then noted: the snapshot has to be the
                    // form as the preset left it.
                    onApplyPreset(preset)
                    noteApplied(preset.name)
                } label: {
                    Text(preset.name)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(lit ? Bench.Palette.onAccent
                                             : Bench.Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                            .fill(lit ? Bench.Palette.accent
                                      : Bench.Palette.control))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if !preset.isBuiltIn {
                        Button("Delete", role: .destructive) { delete(preset) }
                    }
                }
            }
            Button("Save…") {
                draftName = ""
                naming = true
            }
            .buttonStyle(.bench(.quiet))
            .disabled(model == nil || state.changedCount == 0)
        }
    }

    // MARK: presets

    private var presets: [StudioPreset] {
        guard let model else { return [] }
        // A saved preset may collide with a generated built-in name
        // ("Draft 6-step"). `StudioPreset.id` is the name, so without this the
        // menu hands `ForEach` two rows with one id — and the user's own
        // version is the one they meant, so it wins.
        let mine = stored.filter { $0.modelId == model.id }
        let names = Set(mine.map(\.name))
        return StudioPreset.builtIns(for: model).filter { !names.contains($0.name) }
            + mine
    }

    /// Every saved preset, for every model — see `StudioPresetMemo` for why
    /// this is not the decode it looks like.
    private var stored: [StudioPreset] {
        StudioPresetMemo.presets(in: storedPresetsJSON)
    }

    private func savePreset() {
        guard let model else { return }
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Only the deltas — see StudioPreset's note on why.
        var overrides: [String: JSONValue] = [:]
        for spec in state.specs where spec.isInternal != true {
            let current = state.values[spec.key] ?? .null
            if current != spec.default { overrides[spec.key] = current }
        }
        var all = stored.filter { !($0.name == name && $0.modelId == model.id) }
        all.append(StudioPreset(name: name, modelId: model.id, values: overrides))
        write(all)
        noteApplied(name)
    }

    /// Remember which preset the form currently *is* — see `litPreset`.
    private func noteApplied(_ name: String) {
        appliedPreset = name
        appliedModelId = model?.id
        appliedValues = state.values
    }

    private func delete(_ preset: StudioPreset) {
        write(stored.filter { $0 != preset })
        if appliedPreset == preset.name {
            appliedPreset = nil
            appliedValues = nil
            appliedModelId = nil
        }
    }

    private func write(_ presets: [StudioPreset]) {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else { return }
        storedPresetsJSON = json
    }
}

/// `studio.presets` → the presets saved in it.
///
/// The preset row is drawn by the panel's body, and that body is invalidated
/// by every write to `ParameterFormState.values` — one tracked property
/// covering every knob, so any slider invalidates it. Decoding the store
/// where the row asked for it therefore meant a `JSONDecoder` and a whole
/// preset document per frame for the length of a drag, to redraw two or three
/// chips that had not changed.
///
/// The JSON *is* the identity of the answer: a store that has changed is a
/// different string. So memoising on it is exact rather than a guess about
/// when to invalidate — and it holds for the writers too, since `savePreset`
/// and `delete` read the store back before rewriting it.
@MainActor
enum StudioPresetMemo {
    private static var lists: [String: [StudioPreset]] = [:]

    /// A save or a delete writes a *new* document, so a long session would
    /// otherwise keep every version of the store it had ever drawn. Past this
    /// the memo starts over rather than growing for the rest of the session.
    private static let capacity = 64

    static func presets(in json: String) -> [StudioPreset] {
        if let known = lists[json] { return known }
        let answer = (try? JSONDecoder().decode([StudioPreset].self,
                                                from: Data(json.utf8))) ?? []
        if lists.count >= capacity { lists.removeAll(keepingCapacity: true) }
        lists[json] = answer
        return answer
    }
}

extension StudioPreset {
    /// "Draft" and "Quality" for any model that exposes a step-count-like
    /// parameter. Derived from that param's own declared range, so a model with
    /// 8…60 steps and one with 1…200 both get sensible presets and neither
    /// needs the app to know anything about it.
    static func builtIns(for model: ModelInfo) -> [StudioPreset] {
        guard let steps = model.capabilities.params.first(where: {
            ($0.type == .int || $0.type == .float) && $0.isInternal != true
                && ($0.key.contains("step") || $0.key.contains("num_inference"))
        }), let min = steps.min, let max = steps.max, max > min else { return [] }

        let draft = min + (max - min) * 0.1
        let quality = min + (max - min) * 0.75
        return [
            StudioPreset(name: "Draft \(Int(draft.rounded()))-step",
                         modelId: model.id,
                         values: [steps.key: .int(Int(draft.rounded()))],
                         isBuiltIn: true),
            StudioPreset(name: "Quality \(Int(quality.rounded()))-step",
                         modelId: model.id,
                         values: [steps.key: .int(Int(quality.rounded()))],
                         isBuiltIn: true),
        ]
    }
}
