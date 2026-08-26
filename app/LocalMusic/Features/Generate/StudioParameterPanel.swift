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
    var materialPicker: MaterialPickerContext?

    @AppStorage("studio.presets") private var storedPresetsJSON = "[]"
    @State private var naming = false
    @State private var draftName = ""
    @State private var appliedPreset: String?

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
                ParameterFormView(state: state, materialPicker: materialPicker)
                    .padding(.horizontal, 18).padding(.vertical, 16)
            }
        }
    }

    private var inlineBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Text("PARAMETERS").eyebrow()
                if state.changedCount > 0 {
                    Text("\(state.changedCount) CHANGED")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer(minLength: 8)
                presetRow
            }
            ParameterFormView(state: state, allowsTwoColumns: true,
                              materialPicker: materialPicker)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var presetRow: some View {
        HStack(spacing: 6) {
            ForEach(presets) { preset in
                Button {
                    appliedPreset = preset.name
                    onApplyPreset(preset)
                } label: {
                    Text(preset.name)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(appliedPreset == preset.name
                                         ? Bench.Palette.onAccent
                                         : Bench.Palette.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                            .fill(appliedPreset == preset.name ? Bench.Palette.accent
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

    private var stored: [StudioPreset] {
        (try? JSONDecoder().decode([StudioPreset].self,
                                   from: Data(storedPresetsJSON.utf8))) ?? []
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
        appliedPreset = name
    }

    private func delete(_ preset: StudioPreset) {
        write(stored.filter { $0 != preset })
        if appliedPreset == preset.name { appliedPreset = nil }
    }

    private func write(_ presets: [StudioPreset]) {
        guard let data = try? JSONEncoder().encode(presets),
              let json = String(data: data, encoding: .utf8) else { return }
        storedPresetsJSON = json
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
