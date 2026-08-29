import AppKit
import SwiftUI

// The Editor's right rail: Selection / Adjust / Effects / Edits, with the
// send-onward panel under the Selection tab — E01, E04 and E07's right side.

struct EditorRail: View {
    @Bindable var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            tabs
            switch store.railTab {
            case .selection: SelectionTab(store: store)
            case .adjust: AdjustTab(store: store)
            case .effects: EffectsTab(store: store)
            case .edits: EditsTab(store: store)
            }
        }
        .frame(width: 316)
        .frame(maxHeight: .infinity)
        .background(Bench.Palette.panel)
        .overlay(alignment: .leading) {
            Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
        }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(EditorStore.RailTab.allCases, id: \.self) { tab in
                let isOn = store.railTab == tab
                Button {
                    store.railTab = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(label(for: tab))
                        if tab == .edits, store.document.ops.count > 0 {
                            Text("\(store.document.ops.count)")
                                .foregroundStyle(isOn
                                    ? Bench.Palette.textQuaternary
                                    : Bench.Palette.textFaintest)
                        }
                    }
                    .font(isOn ? Bench.Typo.secondaryEmphasis
                               : Bench.Typo.secondary)
                    .foregroundStyle(isOn ? Bench.Palette.textPrimary
                                          : Bench.Palette.textQuaternary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6,
                                                 style: .continuous)
                        .fill(isOn ? Bench.Palette.segmentedSelected : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 6,
                                                   style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(Bench.Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
        .padding(12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private func label(for tab: EditorStore.RailTab) -> String {
        switch tab {
        case .selection: "Selection"
        case .adjust: "Adjust"
        case .effects: "Effects"
        case .edits: "Edits"
        }
    }
}

// MARK: - Selection

private struct SelectionTab: View {
    @Bindable var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    readouts
                    editListPreview
                }
            }
            Spacer(minLength: 0)
            SendOnwardPanel(store: store)
        }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Text("Selection")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer()
                if store.selection != nil, store.snapMode != .off {
                    Text("SNAPPED TO \(store.snapMode.label.uppercased())")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            row("Start", value: store.selection.map {
                EditorClock.full($0.start)
            } ?? "—", bar: store.selection.flatMap {
                store.barNumber(at: $0.start)
            })
            row("End", value: store.selection.map {
                EditorClock.full($0.end)
            } ?? "—", bar: store.selection.flatMap {
                store.barNumber(at: $0.end)
            })
            row("Length", value: store.selection.map {
                String(format: "%.2f s", $0.length)
            } ?? "—", bar: nil,
                valueColor: Bench.Palette.accent)
            HStack(spacing: 6) {
                Button {
                    store.selectAll()
                } label: {
                    HStack(spacing: 5) {
                        Text("Select all")
                        Text("⌘A")
                            .font(Bench.Typo.mono(10, .semibold))
                            .foregroundStyle(Bench.Palette.textFaintest)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.benchSecondary)
                Button("Snap to section") { store.snapSelectionToSection() }
                    .buttonStyle(.benchSecondary)
                    .frame(maxWidth: .infinity)
                    .disabled(store.grid.sections.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private func row(_ label: String, value: String, bar: Int?,
                     valueColor: Color = Bench.Palette.textPrimary) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textMuted)
                .frame(width: 52, alignment: .leading)
            BenchValueField(text: value, alignment: .leading,
                            foreground: valueColor)
                .frame(maxWidth: .infinity)
            Text(bar.map { "BAR \($0)" } ?? "")
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textFaintest)
                .frame(width: 52, alignment: .leading)
        }
    }

    private var editListPreview: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Text("EDIT LIST").eyebrow()
                Text("\(store.document.ops.count) · NON-DESTRUCTIVE")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                Spacer()
                if !store.document.ops.isEmpty {
                    Button("All ›") { store.railTab = .edits }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.accent)
                }
            }
            ForEach(Array(store.document.ops.suffix(3).enumerated()),
                    id: \.element.id) { index, op in
                let number = store.document.ops.count
                    - min(3, store.document.ops.count) + index + 1
                HStack(spacing: 10) {
                    Text("\(number)")
                        .font(Bench.Typo.mono(10, .bold))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .frame(width: 12, alignment: .leading)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(op.kind.tint)
                        .frame(width: 4, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(op.kind.title)
                            .font(Bench.Typo.secondaryEmphasis)
                            .foregroundStyle(Bench.Palette.textPrimary)
                        Text(op.kind.detail)
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .benchCard(fill: Bench.Palette.card,
                           stroke: Bench.Palette.cardStrokeSoft, radius: 9)
            }
            Text("Every edit is stored as a list and re-rendered from the "
                 + "untouched original, so you can change any step later — "
                 + "including a week from now.")
                .font(Bench.Typo.small)
                .lineSpacing(2)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }
}

// MARK: - Send onward (Tier 3.1)

private struct SendOnwardPanel: View {
    @Bindable var store: EditorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("SEND SELECTION TO").eyebrow()
            sendButton("Continue from here", color: Bench.Palette.violet,
                       symbol: "sparkles",
                       help: "Render this selection and hand it to Generate "
                           + "as melody guidance") {
                Task { await store.sendSelection(.continueFrom) }
            }
            sendButton("Split just this region", color: Bench.Palette.accent,
                       symbol: "arrow.triangle.branch",
                       help: "Render this selection and open Split on it") {
                Task { await store.sendSelection(.splitRegion) }
            }
            sendButton("Find matches for this", color: Bench.Palette.cyan,
                       symbol: "circle.circle",
                       help: "Render this selection and look for tracks that "
                           + "mix well with it") {
                Task { await store.sendSelection(.findMatches) }
            }
            sendButton("Export selection…", color: Bench.Palette.textSecondary,
                       symbol: "arrow.down.to.line",
                       help: "Save this selection as its own audio file") {
                store.exportSheetOpen = true
            }
            if case .failed(let message) = store.exportStage {
                Text(message)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.dangerText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if store.exportStage.isBusy {
                HStack(spacing: 7) {
                    BenchSpinner(size: 12)
                    Text("Rendering the selection…")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textTertiary)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
        .opacity(store.selection == nil ? 0.45 : 1)
        .disabled(store.selection == nil || store.exportStage.isBusy)
    }

    private func sendButton(_ title: String, color: Color, symbol: String,
                            help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .frame(width: 14)
                Text(title)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .benchCard(fill: Bench.Palette.card,
                       stroke: Bench.Palette.cardStrokeSoft, radius: 8)
            .contentShape(RoundedRectangle(cornerRadius: 8,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Adjust (Tier 1.7 · 2.7)

private struct AdjustTab: View {
    @Bindable var store: EditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                levelSection
                speedSection
                outputSection
            }
        }
    }

    private var levelSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("LEVEL").eyebrow()
            // Amplify the selection…
            HStack(spacing: 10) {
                radio(on: store.selection != nil
                      && abs(store.amplifyDbForSelection) > 0.049)
                Text("Amplify selection")
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(store.selection == nil
                        ? Bench.Palette.textFaint
                        : Bench.Palette.textPrimary)
                Spacer()
                Text(String(format: "%+.1f dB", store.amplifyDbForSelection))
                    .font(Bench.Typo.mono(12, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
            }
            HStack(spacing: 11) {
                BenchSlider(
                    value: Binding(get: { store.amplifyDbForSelection },
                                   set: { store.setAmplify(db: $0) }),
                    range: -24...24, step: 0.5,
                    isEnabled: store.selection != nil,
                    onEditingEnded: { store.endInteraction() })
                Text("−24 · +24")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            // …or normalise the whole thing. Not both: the design says why.
            HStack(spacing: 10) {
                Button {
                    store.setNormalize(
                        lufs: store.document.normalizeLufs == nil
                            ? store.houseTargetLufs() : nil)
                } label: {
                    HStack(spacing: 10) {
                        radio(on: store.document.normalizeLufs != nil)
                        Text(store.material?.isPart == true
                             ? "Normalise whole part" : "Normalise whole track")
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textPrimary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Text(String(format: "%.0f LUFS",
                            store.document.normalizeLufs
                                ?? store.houseTargetLufs()))
                    .font(Bench.Typo.mono(12, .semibold))
                    .foregroundStyle(store.document.normalizeLufs == nil
                        ? Bench.Palette.textQuaternary : Bench.Palette.accent)
            }
            if store.document.normalizeLufs != nil {
                BenchSliderRow(
                    label: "Target",
                    value: Binding(
                        get: { store.document.normalizeLufs
                            ?? store.houseTargetLufs() },
                        set: { store.setNormalize(lufs: $0) }),
                    range: -30...(-6), step: 0.5, labelWidth: 52,
                    format: { String(format: "%.1f", $0) },
                        onEditingEnded: { store.endInteraction() })
            }
            Text("Pick one — normalising after amplifying would undo it. "
                 + "Both end in the same limiter at −1 dBTP.")
                .font(Bench.Typo.caption)
                .lineSpacing(2)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private func radio(on: Bool) -> some View {
        Circle()
            .strokeBorder(on ? Bench.Palette.accent
                             : Color.white.opacity(0.2),
                          lineWidth: on ? 4.5 : 1.5)
            .frame(width: 15, height: 15)
    }

    private var speedSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 9) {
                Text("SPEED & PITCH").eyebrow()
                Text(store.material?.isPart == true ? "WHOLE PART"
                                                    : "WHOLE TRACK")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            BenchSliderRow(
                label: "Tempo",
                value: Binding(get: { store.document.speedRate },
                               set: { store.setSpeed(rate: $0) }),
                range: 0.5...2, step: 0.01,
                tint: Bench.Palette.textMuted, labelWidth: 52,
                valueWidth: 58,
                format: { rate in
                    if let bpm = store.bpm {
                        return String(format: "%.1f", bpm * rate)
                    }
                    return String(format: "%d%%", Int((rate * 100).rounded()))
                },
                    onEditingEnded: { store.endInteraction() })
            BenchSliderRow(
                label: "Pitch",
                value: Binding(get: { store.document.pitchSemitones },
                               set: { store.setPitch(semitones: $0) }),
                range: -12...12, step: 1,
                tint: Bench.Palette.textMuted, labelWidth: 52,
                valueWidth: 58,
                format: { String(format: "%+.0f st", $0) },
                    onEditingEnded: { store.endInteraction() })
            HStack(spacing: 11) {
                Text("Engine")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                    .frame(width: 52, alignment: .leading)
                Text("Rubber Band R3 · formant-preserving")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.ok)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OUTPUT").eyebrow()
            HStack(spacing: 7) {
                BenchMenu(label: resampleLabel) {
                    Button("Same as source") { store.setResample(hz: nil) }
                    Divider()
                    ForEach([44100, 48000, 96000], id: \.self) { hz in
                        Button("\(hz.formatted(.number)) Hz") {
                            store.setResample(hz: hz)
                        }
                    }
                }
                Spacer(minLength: 4)
                Button("Export selection…") { store.exportSheetOpen = true }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
                    .disabled(store.exportStage.isBusy)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var resampleLabel: String {
        store.document.resampleHz.map { "\($0.formatted(.number)) Hz" }
            ?? "Resample…"
    }
}

// MARK: - Effects (Tier 3.2)

private struct EffectsTab: View {
    @Bindable var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Text("CHAIN").eyebrow()
                        Text("IN ORDER").font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textFaintest)
                        Spacer()
                        if !store.document.effects.isEmpty {
                            Button(allBypassed ? "Enable all" : "Bypass all") {
                                store.setAllEffectsEnabled(allBypassed)
                            }
                            .buttonStyle(.plain)
                            .font(Bench.Typo.small)
                            .foregroundStyle(Bench.Palette.textQuaternary)
                        }
                    }
                    ForEach(store.document.effects) { effect in
                        EffectCard(store: store, effect: effect)
                    }
                    addMenu
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                Text("Rendered by pedalboard on Apply — the chain is drawn "
                     + "here but not run live in preview, like fades.")
                    .font(Bench.Typo.small)
                    .lineSpacing(2)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .top) {
                Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            }
        }
    }

    private var allBypassed: Bool {
        !store.document.effects.contains(where: \.enabled)
    }

    private var addMenu: some View {
        Menu {
            ForEach(EffectSetting.Kind.allCases, id: \.self) { kind in
                Button(kind.label) { store.addEffect(kind) }
            }
        } label: {
            Text("＋ Add a processor")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textQuaternary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10,
                                             style: .continuous)
                    .strokeBorder(Color.white.opacity(0.13),
                                  style: StrokeStyle(lineWidth: 1,
                                                     dash: [4, 3])))
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }
}

private struct EffectCard: View {
    @Bindable var store: EditorStore
    let effect: EffectSetting

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Toggle(isOn: Binding(
                    get: { effect.enabled },
                    set: { on in
                        var updated = effect
                        updated.enabled = on
                        store.updateEffect(updated)
                    })) { EmptyView() }
                    .toggleStyle(.bench(width: 30))
                Text(effect.kind.label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer()
                Text(summary)
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(effect.enabled
                        ? Bench.Palette.textSecondary
                        : Bench.Palette.textMuted)
                menu
            }
            if effect.enabled { controls }
        }
        .padding(11)
        .benchCard(fill: Bench.Palette.card,
                   stroke: Bench.Palette.cardStrokeSoft, radius: 10)
        .opacity(effect.enabled ? 1 : 0.62)
    }

    private var menu: some View {
        Menu {
            Button("Move up") { store.moveEffect(id: effect.id, up: true) }
            Button("Move down") { store.moveEffect(id: effect.id, up: false) }
            Divider()
            Button("Remove", role: .destructive) {
                store.removeEffect(id: effect.id)
            }
        } label: {
            Text("···")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var summary: String {
        switch effect.kind {
        case .highpass, .lowpass:
            effect.cutoffHz >= 1000
                ? String(format: "%.1f kHz", effect.cutoffHz / 1000)
                : String(format: "%.0f Hz", effect.cutoffHz)
        case .eq3: "3-BAND"
        case .compressor: String(format: "%.0f:%.0f", -effect.thresholdDb,
                                 effect.ratio)
        case .gate: String(format: "%.0f dB", effect.thresholdDb)
        case .convolve: effect.irPath == nil
            ? "NO IR"
            : String(format: "%.0f%%", effect.mix * 100)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch effect.kind {
        case .highpass:
            slider("Cutoff", value: \.cutoffHz, range: 20...1000, step: 5,
                   format: { String(format: "%.0f", $0) })
            note("12 dB/oct")
        case .lowpass:
            slider("Cutoff", value: \.cutoffHz, range: 1000...20000, step: 100,
                   format: { String(format: "%.1fk", $0 / 1000) })
            note("12 dB/oct")
        case .eq3:
            slider("Low 120", value: \.lowDb, range: -12...12, step: 0.5,
                   format: { String(format: "%+.1f", $0) })
            slider("Mid 1.2k", value: \.midDb, range: -12...12, step: 0.5,
                   format: { String(format: "%+.1f", $0) })
            slider("High 8k", value: \.highDb, range: -12...12, step: 0.5,
                   format: { String(format: "%+.1f", $0) })
        case .compressor:
            slider("Thresh", value: \.thresholdDb, range: -60...0, step: 1,
                   format: { String(format: "%.0f", $0) })
            slider("Ratio", value: \.ratio, range: 1...20, step: 0.5,
                   format: { String(format: "%.1f:1", $0) })
            slider("Attack", value: \.attackMs, range: 0.1...100, step: 0.1,
                   format: { String(format: "%.0f ms", $0) })
            slider("Release", value: \.releaseMs, range: 10...1000, step: 10,
                   format: { String(format: "%.0f ms", $0) })
        case .gate:
            slider("Thresh", value: \.thresholdDb, range: -80...0, step: 1,
                   format: { String(format: "%.0f dB", $0) })
        case .convolve:
            HStack(spacing: 8) {
                Button(effect.irPath == nil ? "Pick impulse response…"
                                            : "Change IR…") {
                    pickIR()
                }
                .buttonStyle(.bench(.quiet))
                if let path = effect.irPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            slider("Mix", value: \.mix, range: 0...1, step: 0.05,
                   format: { String(format: "%.0f%%", $0 * 100) })
            note("A room, hall or cab as a .wav — until an IR is picked "
                 + "this card does nothing")
        }
    }

    private func pickIR() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an impulse response (.wav)"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var updated = effect
            updated.irPath = url.path
            store.updateEffect(updated)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Bench.Typo.mono(10))
            .foregroundStyle(Bench.Palette.textFaintest)
    }

    private func slider(_ label: String,
                        value keyPath: WritableKeyPath<EffectSetting, Double>,
                        range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        BenchSliderRow(
            label: label,
            value: Binding(get: { effect[keyPath: keyPath] },
                           set: { newValue in
                               var updated = effect
                               updated[keyPath: keyPath] = newValue
                               // Keyed, so a drag is one undo step rather
                               // than one per mouse-move; `onEditingEnded`
                               // below closes it when the gesture does.
                               store.updateEffect(
                                   updated,
                                   coalescing: "fx-\(effect.id)-\(label)")
                           }),
            range: range, step: step, labelWidth: 62, valueWidth: 54,
            format: format,
            onEditingEnded: { store.endInteraction() })
    }
}

// MARK: - Edits (the reopenable list, E02's right rail)

private struct EditsTab: View {
    @Bindable var store: EditorStore
    @State private var expandedOpId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Text("Edit list")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("\(store.document.ops.count) · IN ORDER")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
                Spacer()
                if !store.document.ops.isEmpty {
                    Button("Clear all") { store.clearAllOps() }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            }
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(Array(store.document.ops.enumerated()),
                            id: \.element.id) { index, op in
                        EditOpRow(store: store, op: op, number: index + 1,
                                  isExpanded: expandedOpId == op.id,
                                  onToggleExpand: {
                                      expandedOpId = expandedOpId == op.id
                                          ? nil : op.id
                                  })
                    }
                    if store.document.ops.isEmpty {
                        Text("Nothing yet — select a region and reach for "
                             + "the toolbar under the waveform.")
                            .font(Bench.Typo.small)
                            .lineSpacing(2)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            Spacer(minLength: 0)
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Result")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                Spacer()
                Text(EditorClock.full(store.resultDurationS))
                    .font(Bench.Typo.mono(13, .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
            }
            HStack {
                Text("Render estimate")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                Spacer()
                Text("≈ \(max(2, Int((store.resultDurationS * 0.06).rounded()))) s")
                    .font(Bench.Typo.mono(13, .semibold))
                    .foregroundStyle(Bench.Palette.accent)
            }
            Text("One dsp-mixdown pass from the original — never from an "
                 + "already-edited file, so quality never compounds.")
                .font(Bench.Typo.caption)
                .lineSpacing(2)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

/// One row of the edit list — reopenable where the step has something to
/// adjust (fade length and curve, amplify level, normalise target, speed,
/// pitch), removable always.
private struct EditOpRow: View {
    @Bindable var store: EditorStore
    let op: EditOp
    let number: Int
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(Bench.Typo.mono(10, .bold))
                    .foregroundStyle(isExpanded ? Bench.Palette.accent
                                                : Bench.Palette.textFaintest)
                    .frame(width: 12, alignment: .leading)
                RoundedRectangle(cornerRadius: 2)
                    .fill(op.kind.tint)
                    .frame(width: 4, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(op.kind.title)
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(op.kind.detail + (isExpanded ? " · EDITING" : ""))
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(isExpanded
                            ? Bench.Palette.textQuaternary
                            : Bench.Palette.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    if op.kind.isAdjustable {
                        Button(isExpanded ? "Close" : "Adjust…",
                               action: onToggleExpand)
                    }
                    Button("Remove", role: .destructive) {
                        store.removeOp(id: op.id)
                    }
                } label: {
                    Text("···")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if isExpanded { editorControls }
        }
        .padding(11)
        .benchCard(fill: isExpanded ? Bench.Palette.cardSelected
                                    : Bench.Palette.card,
                   stroke: isExpanded ? Bench.Palette.accent.opacity(0.26)
                                      : Bench.Palette.cardStrokeSoft,
                   radius: 9)
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .onTapGesture { if op.kind.isAdjustable { onToggleExpand() } }
    }

    @ViewBuilder
    private var editorControls: some View {
        switch op.kind {
        case .fadeIn(let seconds, let curve):
            fadeControls(seconds: seconds, curve: curve,
                         coalescing: "row-\(op.id)-fadein") { s, c in
                store.updateOp(id: op.id, kind: .fadeIn(seconds: s, curve: c),
                               coalescing: "row-\(op.id)-fadein")
            }
        case .fadeOut(let seconds, let curve):
            fadeControls(seconds: seconds, curve: curve,
                         coalescing: "row-\(op.id)-fadeout") { s, c in
                store.updateOp(id: op.id, kind: .fadeOut(seconds: s, curve: c),
                               coalescing: "row-\(op.id)-fadeout")
            }
        case .amplify(let range, let db):
            BenchSliderRow(
                label: "Gain",
                value: Binding(get: { db }, set: {
                    store.updateOp(id: op.id, kind: .amplify(range, db: $0),
                                   coalescing: "row-\(op.id)-amp")
                }),
                range: -24...24, step: 0.5, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%+.1f dB", $0) },
                    onEditingEnded: { store.endInteraction() })
        case .normalize(let lufs):
            BenchSliderRow(
                label: "Target",
                value: Binding(get: { lufs }, set: {
                    store.updateOp(id: op.id, kind: .normalize(lufs: $0),
                                   coalescing: "row-\(op.id)-norm")
                }),
                range: -30...(-6), step: 0.5, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%.1f", $0) },
                    onEditingEnded: { store.endInteraction() })
        case .speed(let rate):
            BenchSliderRow(
                label: "Rate",
                value: Binding(get: { rate }, set: {
                    store.updateOp(id: op.id, kind: .speed(rate: $0),
                                   coalescing: "row-\(op.id)-speed")
                }),
                range: 0.5...2, step: 0.01, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%d%%", Int(($0 * 100).rounded())) },
                    onEditingEnded: { store.endInteraction() })
        case .pitch(let semitones):
            BenchSliderRow(
                label: "Shift",
                value: Binding(get: { semitones }, set: {
                    store.updateOp(id: op.id, kind: .pitch(semitones: $0),
                                   coalescing: "row-\(op.id)-pitch")
                }),
                range: -12...12, step: 1, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%+.0f st", $0) },
                    onEditingEnded: { store.endInteraction() })
        case .insertGap(let at, let seconds):
            BenchSliderRow(
                label: "Length",
                value: Binding(get: { seconds }, set: {
                    store.updateOp(id: op.id,
                                   kind: .insertGap(at: at, seconds: $0),
                                   coalescing: "row-\(op.id)-gap")
                }),
                range: 0.1...30, step: 0.1, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%.1f s", $0) },
                    onEditingEnded: { store.endInteraction() })
        default:
            EmptyView()
        }
    }

    private func fadeControls(seconds: Double, curve: FadeCurve,
                              coalescing key: String,
                              update: @escaping (Double, FadeCurve) -> Void)
        -> some View {
        VStack(alignment: .leading, spacing: 10) {
            BenchSliderRow(
                label: "Length",
                value: Binding(get: { seconds }, set: { update($0, curve) }),
                range: 0.1...min(30, max(0.2, store.timelineDurationS)),
                step: 0.1, labelWidth: 52, valueWidth: 56,
                format: { String(format: "%.1f s", $0) },
                    onEditingEnded: { store.endInteraction() })
            HStack(spacing: 10) {
                Text("Curve")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .frame(width: 52, alignment: .leading)
                BenchSegmented(
                    selection: Binding(get: { curve },
                                       set: {
                                           store.endInteraction()
                                           update(seconds, $0)
                                           store.endInteraction()
                                       }),
                    options: FadeCurve.allCases.map {
                        .init(value: $0, label: $0.label)
                    })
            }
        }
    }
}

// MARK: - Row vocabulary

extension EditOp.Kind {
    var title: String {
        switch self {
        case .trim: "Trim to region"
        case .delete: "Delete region"
        case .silence: "Silence region"
        case .insertGap: "Insert gap"
        case .splitAt: "Split"
        case .paste: "Paste"
        case .reverse: "Reverse"
        case .amplify: "Amplify"
        case .fadeIn: "Fade in"
        case .fadeOut: "Fade out"
        case .normalize: "Normalise"
        case .speed: "Speed"
        case .pitch: "Pitch"
        case .resample: "Resample"
        }
    }

    var detail: String {
        switch self {
        case .trim(let range):
            "KEEP \(EditorClock.full(range.start)) → \(EditorClock.full(range.end))"
        case .delete(let range):
            "\(EditorClock.full(range.start)) → \(EditorClock.full(range.end))"
                + String(format: " · −%.2f S", range.length)
        case .silence(let range):
            "\(EditorClock.full(range.start)) → \(EditorClock.full(range.end))"
        case .insertGap(let at, let seconds):
            "AT \(EditorClock.full(at)) · " + String(format: "%.1f S", seconds)
        case .splitAt(let at):
            "AT \(EditorClock.full(at))"
        case .paste(let at, let slices):
            "AT \(EditorClock.full(at)) · "
                + String(format: "%.2f S",
                         slices.reduce(0) { $0 + $1.length })
        case .reverse(let range):
            "\(EditorClock.full(range.start)) → \(EditorClock.full(range.end))"
        case .amplify(let range, let db):
            String(format: "%+.1f DB · ", db)
                + "\(EditorClock.full(range.start)) → \(EditorClock.full(range.end))"
        case .fadeIn(let seconds, let curve):
            "0:00 → \(EditorClock.full(seconds)) · \(curve.label.uppercased())"
        case .fadeOut(let seconds, let curve):
            String(format: "LAST %.2f S · ", seconds)
                + curve.label.uppercased()
        case .normalize(let lufs):
            "WHOLE TRACK · " + String(format: "%.0f LUFS", lufs)
        case .speed(let rate):
            "WHOLE TRACK · " + String(format: "%d%%", Int((rate * 100).rounded()))
        case .pitch(let semitones):
            "WHOLE TRACK · " + String(format: "%+.0f ST", semitones)
        case .resample(let hz):
            "\(hz.formatted(.number)) HZ"
        }
    }

    /// The colour bar the design keys rows by: red for what removes,
    /// lime for what shapes, cyan for what levels.
    var tint: Color {
        switch self {
        case .delete, .silence: Bench.Palette.danger
        case .trim, .splitAt, .insertGap, .paste, .fadeIn, .fadeOut:
            Bench.Palette.accent
        case .reverse, .speed, .pitch, .resample: Bench.Palette.violet
        case .amplify, .normalize: Bench.Palette.cyan
        }
    }

    var isAdjustable: Bool {
        switch self {
        case .fadeIn, .fadeOut, .amplify, .normalize, .speed, .pitch,
             .insertGap:
            true
        default:
            false
        }
    }
}
