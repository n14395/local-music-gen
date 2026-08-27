import SwiftUI
import UniformTypeIdentifiers

/// Holds the values for one model's parameter form. Values are the exact `params`
/// dict submitted to /v1/jobs; clamping happens on write. Audio params are held
/// as local file URLs and uploaded at submit time (the submitter swaps in the
/// upload id).
@MainActor @Observable
final class ParameterFormState {
    let specs: [ParamSpec]
    private(set) var values: [String: JSONValue]
    var audioSelections: [String: URL] = [:]
    /// The library track name chosen for an audio param, kept alongside the URL
    /// so the row can show the sound's name instead of its storage filename.
    var audioSelectionNames: [String: String] = [:]

    init(specs: [ParamSpec]) {
        self.specs = specs
        self.values = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.default) })
    }

    /// Params as submitted; audio keys stay null here until upload.
    var params: [String: JSONValue] { values }

    func doubleValue(_ spec: ParamSpec) -> Double {
        values[spec.key]?.doubleValue ?? spec.default.doubleValue ?? 0
    }

    func setDouble(_ spec: ParamSpec, _ raw: Double) {
        var v = raw
        if let min = spec.min { v = Swift.max(min, v) }
        if let max = spec.max { v = Swift.min(max, v) }
        values[spec.key] = spec.type == .int ? .int(Int(v.rounded())) : .double(v)
    }

    func boolValue(_ spec: ParamSpec) -> Bool {
        if case .bool(let b)? = values[spec.key] { return b }
        return false
    }

    func setBool(_ spec: ParamSpec, _ v: Bool) { values[spec.key] = .bool(v) }

    func stringValue(_ spec: ParamSpec) -> String {
        if case .string(let s)? = values[spec.key] { return s }
        return ""
    }

    func setString(_ spec: ParamSpec, _ v: String) { values[spec.key] = .string(v) }

    func isNull(_ spec: ParamSpec) -> Bool {
        values[spec.key] == .null || values[spec.key] == nil
    }

    func setNull(_ spec: ParamSpec) { values[spec.key] = .null }

    /// Restore every key to the model's declared default — what a preset does
    /// before applying its own overrides.
    func reset() {
        values = Dictionary(uniqueKeysWithValues: specs.map { ($0.key, $0.default) })
        audioSelections = [:]
        audioSelectionNames = [:]
    }

    /// How many params differ from their declared default. The design's
    /// parameter panel leads with the preset row, and this is what tells you a
    /// preset is no longer what you are looking at.
    var changedCount: Int {
        specs.filter { $0.isInternal != true && values[$0.key] != $0.default }.count
    }
}

/// Everything the in-house material picker needs, bundled so any form that
/// renders audio params can be handed one value and offer the library
/// instead of the system file panel.
struct MaterialPickerContext {
    let catalog: ModelCatalogStore
    let library: LibraryStore
    let parts: PartsStore
    let jobs: JobsStore
    let playback: PlaybackController
    let onOpenModels: () -> Void
}

/// Generic renderer over `[ParamSpec]` — the app has zero hardcoded per-model UI.
///
/// The redesign changes three things about it. Parameters are sorted into named
/// groups (`ParameterGroups`) instead of one flat grid. Every control shows its
/// value beside it. And a nullable numeric is a **RANDOM pill next to the
/// number**, not a checkbox that hides the number: the old form made "random"
/// and "what value would that be" mutually exclusive, which is exactly backwards
/// for a control you are trying to reason about.
struct ParameterFormView: View {
    @Bindable var state: ParameterFormState
    /// Off for the compact forms inside action sheets, which have no room for
    /// group cards and only ever show a handful of params.
    var grouped = true
    var labelWidth: CGFloat = 112
    /// Lay the group cards out two-across when the container is wide enough.
    /// Only the inline form asks for it — a fixed-width inspector has room
    /// for exactly one column, and says so by leaving this off.
    var allowsTwoColumns = false
    /// When present, audio and MIDI params pick from the library instead of
    /// the filesystem — the user's material lives in the app, not in Finder.
    /// `_file` params keep the system panel either way: they ride the audio
    /// type for upload plumbing but carry non-library payloads (a .nam amp
    /// capture), so the library has nothing to offer them.
    var materialPicker: MaterialPickerContext?

    /// The audio/MIDI param a library pick is currently open for.
    private struct MaterialPick: Identifiable {
        let key: String
        let label: String
        let isMidi: Bool
        var id: String { key }
    }

    @State private var audioPickerKey: String?
    @State private var materialPick: MaterialPick?

    /// Internal params (e.g. mix_spec) are populated programmatically, never shown.
    private var visibleSpecs: [ParamSpec] {
        state.specs.filter { $0.isInternal != true }
    }

    /// The width one column of group cards needs before a second is worth
    /// having: a card is a label column plus a slider plus its number, and
    /// below this the help text under each control wraps to ribbons.
    private static let columnMinWidth: CGFloat = 330

    private func oneColumn(_ groups: [ParameterGroups.Group]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(groups) { groupCard($0) }
        }
    }

    /// Cards dealt alternately into two columns rather than split down the
    /// middle: group sizes vary a lot (a two-knob card beside an eight-knob
    /// one), and alternating keeps the columns closer in height.
    private func twoColumns(_ groups: [ParameterGroups.Group]) -> some View {
        let left = groups.enumerated().filter { $0.offset.isMultiple(of: 2) }
            .map(\.element)
        let right = groups.enumerated().filter { !$0.offset.isMultiple(of: 2) }
            .map(\.element)
        return HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(left) { groupCard($0) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(right) { groupCard($0) }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        // What ViewThatFits measures: two columns plus the gap. Narrower
        // than this and it falls through to the stacked layout.
        .frame(minWidth: Self.columnMinWidth * 2 + 14)
    }

    var body: some View {
        Group {
            if grouped {
                let groups = ParameterGroups.groups(for: visibleSpecs)
                if allowsTwoColumns, groups.count > 1 {
                    // Two columns only where they genuinely fit: below the
                    // pair's minimum the whole arrangement is rejected and
                    // the cards stack, rather than squeezing two columns of
                    // sliders into a width neither can use.
                    ViewThatFits(in: .horizontal) {
                        twoColumns(groups)
                        oneColumn(groups)
                    }
                } else {
                    oneColumn(groups)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleSpecs) { spec in
                        row(spec)
                    }
                }
            }
        }
        .sheet(item: $materialPick) { pick in
            if let picker = materialPicker {
                PartPickerSheet(
                    slotLabel: pick.label,
                    accepts: pick.isMidi
                        ? [KindPattern(pattern: "notes.*")]
                        : [KindPattern(pattern: "song.mix"),
                           KindPattern(pattern: "stem.*"),
                           KindPattern(pattern: "layer.*")],
                    autoDerive: nil, catalog: picker.catalog,
                    library: picker.library, parts: picker.parts,
                    jobs: picker.jobs, playback: picker.playback,
                    onOpenModels: picker.onOpenModels,
                    onPick: {
                        state.audioSelections[pick.key] = $0.fileURL
                        state.audioSelectionNames[pick.key] = $0.name
                    }
            )
        }
    }
}

    private func groupCard(_ group: ParameterGroups.Group) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.label.uppercased()).eyebrow()
                if let blurb = ParameterGroups.Known(rawValue: group.id)?.blurb {
                    Text(blurb)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(group.specs) { spec in
                row(spec)
            }
            if let footnote = ParameterGroups.dimmedFootnote(for: group.specs,
                                                             values: state.values) {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(Bench.Palette.textQuaternary)
                    Text(footnote)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
        .benchCard(stroke: Bench.Palette.cardStrokeSoft)
    }

    /// One labelled row, with what the control does written under it.
    ///
    /// Inapplicable controls dim rather than disappear, so the panel keeps the
    /// same shape as you change task — and the footnote under the group says
    /// which task they belong to.
    ///
    /// The explanation used to be a `.help` tooltip and nothing else, which is
    /// no use to the person who needs it: you have to already suspect a
    /// control is worth understanding before you hover over it, and Studio's
    /// "Full control" is precisely the screen where you don't. It stays as a
    /// tooltip too, for the compact ungrouped forms that have no room for it.
    @ViewBuilder
    private func row(_ spec: ParamSpec) -> some View {
        let applicable = ParameterGroups.isApplicable(spec, values: state.values)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Text(spec.label)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: labelWidth, alignment: .leading)
                control(for: spec)
            }
            // Bools already print their help beside the switch — the label
            // there is the sentence — so printing it again would double it.
            if grouped, spec.type != .bool, let help = spec.help {
                Text(help)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaintest)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, labelWidth + 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(applicable ? 1 : 0.45)
        .allowsHitTesting(applicable)
        .help(spec.help ?? "")
    }

    @ViewBuilder
    private func control(for spec: ParamSpec) -> some View {
        switch spec.type {
        case .int, .float:
            if spec.nullable {
                randomisable(spec)
            } else if let min = spec.min, let max = spec.max {
                BenchSlider(value: Binding(get: { state.doubleValue(spec) },
                                           set: { state.setDouble(spec, $0) }),
                            range: min...max, step: spec.step)
                BenchValueField(text: format(spec, state.doubleValue(spec)), width: 52)
            } else {
                Spacer(minLength: 0)
                BenchNumberField(value: Binding(get: { state.doubleValue(spec) },
                                                set: { state.setDouble(spec, $0) }),
                                 format: numberFormat(spec), width: 90)
            }
        case .bool:
            Toggle(isOn: Binding(get: { state.boolValue(spec) },
                                 set: { state.setBool(spec, $0) })) {
                if let help = spec.help {
                    Text(help)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            .toggleStyle(.bench)
            Spacer(minLength: 0)
        case .string:
            TextField(spec.placeholder ?? "", text: Binding(
                get: { state.stringValue(spec) },
                set: { state.setString(spec, $0) }))
                .textFieldStyle(.plain)
                .tint(Bench.Palette.accent)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .fill(Bench.Palette.windowBackground))
                .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
        case .enum:
            enumControl(spec)
        case .audio, .midi:
            audioRow(spec)
        case .json:
            // json params are internal (populated programmatically); nothing to render
            EmptyView()
        }
    }

    /// A menu drawn as a full-width field, matching the design's `Generate ⌄`
    /// and `English ⌄` rows.
    private func enumControl(_ spec: ParamSpec) -> some View {
        let choices = spec.choices ?? []
        let current = state.stringValue(spec)
        let label = choices.first { $0.value == current }?.label ?? current
        return Menu {
            ForEach(choices) { choice in
                Button(choice.label) { state.setString(spec, choice.value) }
            }
        } label: {
            HStack {
                Text(label.isEmpty ? "—" : label)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 6)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    /// A nullable numeric: RANDOM lights up when the value is unset, and the
    /// number stays on screen either way.
    private func randomisable(_ spec: ParamSpec) -> some View {
        let isRandom = state.isNull(spec)
        return HStack(spacing: 8) {
            Button {
                if isRandom {
                    state.setDouble(spec, spec.default.doubleValue ?? spec.min ?? 0)
                } else {
                    state.setNull(spec)
                }
            } label: {
                Text("RANDOM")
                    .font(Bench.Typo.mono(12, .semibold))
                    .foregroundStyle(isRandom ? Bench.Palette.onAccent
                                              : Bench.Palette.textSecondary)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control)
                        .fill(isRandom ? Bench.Palette.accent : Bench.Palette.control))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRandom ? "The engine picks a value" : "Let the engine pick")

            if isRandom {
                // Nothing true to show: the engine has not chosen yet, and
                // printing the last value would imply it is going to be reused.
                BenchValueField(text: "—", alignment: .leading,
                                foreground: Bench.Palette.textFaintest)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                BenchNumberField(value: Binding(get: { state.doubleValue(spec) },
                                                set: { state.setDouble(spec, $0) }),
                                 format: numberFormat(spec), width: 130)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func audioRow(_ spec: ParamSpec) -> some View {
        HStack(spacing: 9) {
            if let url = state.audioSelections[spec.key] {
                Text(state.audioSelectionNames[spec.key] ?? url.lastPathComponent)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Button {
                    state.audioSelections[spec.key] = nil
                    state.audioSelectionNames[spec.key] = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                .buttonStyle(.plain)
                .help("Remove")
            } else {
                Text("None")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            Spacer(minLength: 4)
            Button("Choose…") {
                if materialPicker != nil, !spec.key.hasSuffix("_file") {
                    materialPick = MaterialPick(key: spec.key,
                                                label: spec.label,
                                                isMidi: spec.type == .midi)
                } else {
                    audioPickerKey = spec.key
                }
            }
                .buttonStyle(.bench(.quiet))
                .fileImporter(
                    isPresented: Binding(
                        get: { audioPickerKey == spec.key },
                        set: { if !$0 { audioPickerKey = nil } }),
                    // `_file` params ride the audio type for upload plumbing
                    // but carry non-audio payloads (a .nam amp capture is
                    // JSON), so the picker must not filter them out.
                    allowedContentTypes: spec.type == .midi ? [.midi]
                        : spec.key.hasSuffix("_file") ? [.item] : [.audio]) { result in
                    if case .success(let url) = result {
                        state.audioSelections[spec.key] = url
                    }
                }
        }
    }

    private func numberFormat(_ spec: ParamSpec) -> FloatingPointFormatStyle<Double> {
        spec.type == .int ? .number.precision(.fractionLength(0)) : .number
    }

    private func format(_ spec: ParamSpec, _ value: Double) -> String {
        if spec.type == .int { return String(Int(value.rounded())) }
        // One decimal reads better than %g for the 0…1 and 1…15 ranges that
        // dominate here, but integers still print clean.
        return value == value.rounded() && abs(value) >= 10
            ? String(Int(value))
            : String(format: "%.1f", value)
    }
}
