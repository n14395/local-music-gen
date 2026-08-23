import SwiftUI

// The redesign's biggest structural move: configuring an action is a *page*,
// not a sheet. A sheet can only ask "what settings?"; a page has room to answer
// "and what will that give me, and what will it cost?" at the same time — which
// is the whole argument of the design's fourth rule, that the app narrates what
// it is about to do before it does it.
//
// Everything in this file is the furniture every action page wears: the detail
// bar, the SOURCE card, the model radio cards, the pinned commit row, and the
// 352 pt right rail. The pages themselves only supply their own middle.

// MARK: - Mode badge

extension RecipeMode {
    var badgeText: String {
        switch self {
        case .exact: "EXACT"
        case .reimagine: "REIMAGINE"
        case .analyse: "ANALYSE"
        case .invent: "GENERATE"
        }
    }

    var badgeTone: BenchBadge.Tone {
        switch self {
        case .exact: .accent
        case .reimagine: .violet
        case .analyse: .cyan
        case .invent: .accent
        }
    }

    var color: Color {
        switch self {
        case .exact: Bench.Palette.accent
        case .reimagine: Bench.Palette.violet
        case .analyse: Bench.Palette.cyan
        case .invent: Bench.Palette.accent
        }
    }
}

/// `GENERATE` and `EXACT` lime · `REIMAGINE` violet · `ANALYSE` cyan. The one
/// thing every card
/// and every page states before you click.
struct ActionModeBadge: View {
    let mode: RecipeMode

    var body: some View {
        BenchBadge(mode.badgeText, tone: mode.badgeTone, emphasised: true)
    }
}

// MARK: - Page frame

/// `‹ Actions · │ · <name> · <badge>` over a main column with a pinned commit
/// row, beside a 352 pt rail.
///
/// The commit row lives *inside* the left column rather than spanning the page,
/// because the rail's own footer ("LAST RUN OF THIS ACTION") is pinned to the
/// same baseline and the two must not fight over the width.
struct ActionPage<Main: View, Commit: View, Rail: View>: View {
    let recipe: Recipe
    /// "‹ Close" when a page is hosted in a sheet rather than in the Actions
    /// destination — the Workbench reaches the AI-layer action that way.
    var backTitle = "‹ Actions"
    /// What "Save as preset" saves. Absent on the pages that have no parameter
    /// form at all (Match, Melody, Arrange), where there would be nothing in it.
    var preset: ActionPresetContext?
    let onBack: () -> Void
    @ViewBuilder var main: () -> Main
    @ViewBuilder var commit: () -> Commit
    @ViewBuilder var rail: () -> Rail

    var body: some View {
        VStack(spacing: 0) {
            detailBar
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) { main() }
                            .padding(.horizontal, 30)
                            .padding(.top, 26).padding(.bottom, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    commit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                BenchInspector(width: Bench.Metrics.Inspector.actionConfig) {
                    rail()
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var detailBar: some View {
        BenchTopBar {
            HStack(spacing: 12) {
                Button(action: onBack) {
                    Text(backTitle)
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                Rectangle().fill(Bench.Palette.windowStroke)
                    .frame(width: 1, height: 18)
                Text(recipe.name)
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                ActionModeBadge(mode: recipe.mode)
            }
        } trailing: {
            if let preset {
                ActionPresetMenu(model: preset.model, form: preset.form)
            }
        }
    }
}

// MARK: - Save as preset

/// The pair "Save as preset" needs: which model's parameters, and the live form
/// holding them.
struct ActionPresetContext {
    let model: ModelInfo
    let form: ParameterFormState
}

/// `Save as preset` in the detail bar (design 07).
///
/// It writes `StudioPreset` into the same `studio.presets` blob the Studio's
/// parameter panel reads, keyed by model id, because an action page and the
/// Studio configure the *same* model over the same `ParamSpec`s — a "12-step
/// draft" is the same request either way, and two stores of it would drift.
/// A preset carries only the keys that were moved off their defaults, so one
/// saved in the Studio still applies here even though this page shows a subset
/// of the model's params: a key the form does not have is skipped rather than
/// forced.
struct ActionPresetMenu: View {
    let model: ModelInfo
    let form: ParameterFormState

    @AppStorage("studio.presets") private var storedPresetsJSON = "[]"
    @State private var naming = false
    @State private var draftName = ""

    private var stored: [StudioPreset] {
        (try? JSONDecoder().decode([StudioPreset].self,
                                   from: Data(storedPresetsJSON.utf8))) ?? []
    }

    private var applicable: [StudioPreset] {
        // A saved preset may collide with a generated built-in name
        // ("Draft 6-step"). `StudioPreset.id` is the name, so without this the
        // menu hands `ForEach` two rows with one id — and the user's own
        // version is the one they meant, so it wins.
        let mine = stored.filter { $0.modelId == model.id }
        let names = Set(mine.map(\.name))
        return StudioPreset.builtIns(for: model).filter { !names.contains($0.name) }
            + mine
    }

    var body: some View {
        Menu {
            if form.changedCount > 0 {
                Button(form.changedCount == 1
                       ? "Save this setting…"
                       : "Save these \(form.changedCount) settings…") {
                    draftName = ""
                    naming = true
                }
            } else {
                // The fifth rule: say why rather than vanish. A preset of
                // nothing is not worth writing.
                Text("Nothing is off its default yet")
            }
            if !applicable.isEmpty {
                Divider()
                Section("Apply") {
                    ForEach(applicable) { preset in
                        Button(preset.name) { apply(preset) }
                    }
                }
            }
        } label: {
            Text("Save as preset")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textQuaternary)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .alert("Save as preset", isPresented: $naming) {
            TextField("Name", text: $draftName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Saves the \(form.changedCount) parameter"
                 + (form.changedCount == 1 ? "" : "s")
                 + " you changed, for \(model.displayName). It shows up in "
                 + "the Generate screen's preset row too.")
        }
    }

    /// Defaults first, then the preset's own keys through the typed setters, so
    /// a preset that predates a new parameter leaves the new one at its default
    /// instead of pinning it to whatever it was the day the preset was saved.
    private func apply(_ preset: StudioPreset) {
        form.reset()
        for (key, value) in preset.values {
            guard let spec = form.specs.first(where: { $0.key == key })
            else { continue }
            switch value {
            case .int(let v): form.setDouble(spec, Double(v))
            case .double(let v): form.setDouble(spec, v)
            case .bool(let v): form.setBool(spec, v)
            case .string(let v): form.setString(spec, v)
            case .null: form.setNull(spec)
            default: break
            }
        }
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Deltas only — see StudioPreset's note on why.
        var overrides: [String: JSONValue] = [:]
        for spec in form.specs where spec.isInternal != true {
            let current = form.values[spec.key] ?? .null
            if current != spec.default { overrides[spec.key] = current }
        }
        var all = stored.filter {
            !($0.name == name && $0.modelId == model.id)
        }
        all.append(StudioPreset(name: name, modelId: model.id,
                                values: overrides))
        guard let data = try? JSONEncoder().encode(all) else { return }
        storedPresetsJSON = String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Source card

/// `SOURCE` — eyebrow, the two ways in, then the chosen item as play button +
/// 210 pt title block + a 52 pt waveform. Used for every slot on every page, so
/// a two-ingredient recipe is two of these rather than a different layout.
struct ActionSourceCard: View {
    var eyebrow = "SOURCE"
    let material: PickedMaterial?
    /// Mono second line; built by the caller because only it knows whether the
    /// source is a song (model name) or a part (stem kind).
    var meta: String?
    let playback: PlaybackController
    var placeholder = "Choose a song or part to work on."
    var chooseTitle = "Choose from Library…"
    var importTitle: String?
    var isEnabled = true
    let onChoose: () -> Void
    var onImport: (() -> Void)?
    var onRemove: (() -> Void)?

    private var isCurrent: Bool {
        material.map { playback.currentSongId == $0.id } ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Text(eyebrow).eyebrow()
                Spacer(minLength: 8)
                if let onRemove, material != nil {
                    Button("Remove", action: onRemove)
                        .buttonStyle(BenchSecondaryButtonStyle(
                            tone: .quiet,
                            padding: .init(top: 6, leading: 10,
                                           bottom: 6, trailing: 10),
                            radius: Bench.Metrics.Radius.control))
                }
                Button(chooseTitle, action: onChoose)
                    .buttonStyle(BenchSecondaryButtonStyle(
                        tone: .quiet,
                        padding: .init(top: 6, leading: 10,
                                       bottom: 6, trailing: 10),
                        radius: Bench.Metrics.Radius.control))
                if let importTitle, let onImport {
                    Button(importTitle, action: onImport)
                        .buttonStyle(BenchSecondaryButtonStyle(
                            tone: .quiet,
                            padding: .init(top: 6, leading: 10,
                                           bottom: 6, trailing: 10),
                            radius: Bench.Metrics.Radius.control))
                }
            }
            if let material {
                HStack(spacing: 14) {
                    BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                                    isCurrent: isCurrent, size: 34) {
                        let url = material.auditionURL ?? material.fileURL
                        playback.play(url: url, songId: material.id,
                                      title: material.name,
                                      duration: material.durationS ?? 0,
                                      subtitle: "ACTION SOURCE")
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(material.name)
                            .font(Bench.Typo.bodyEmphasis)
                            .foregroundStyle(Bench.Palette.textPrimary)
                            .lineLimit(1)
                        if let meta, !meta.isEmpty {
                            Text(meta).metaLine()
                        }
                    }
                    .frame(width: 210, alignment: .leading)
                    MaterialStrip(material: material,
                                  playedFraction: isCurrent
                                      ? playback.playedFraction : 0,
                                  height: 52,
                                  onSeek: { seek(to: $0) })
                }
            } else {
                Text(placeholder)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .frame(height: 52, alignment: .center)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(radius: 13)
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// Click anywhere in the waveform to hear that moment — the design's first
    /// rule, that audio is for listening to rather than reading about.
    ///
    /// Play first, then seek: `PlaybackController.seek` moves a loaded track,
    /// so seeking one the player has never opened does nothing at all and the
    /// click reads as broken.
    private func seek(to fraction: Double) {
        guard let material else { return }
        if !isCurrent {
            playback.play(url: material.auditionURL ?? material.fileURL,
                          songId: material.id, title: material.name,
                          duration: material.durationS ?? 0,
                          subtitle: "ACTION SOURCE")
        }
        playback.seek(to: fraction * (material.durationS ?? 0))
    }
}

// MARK: - Model radio cards

/// 2–4 radio cards instead of a popup menu: the design's argument is that
/// picking a model is a real decision with a real cost, and a menu hides both
/// the description and the estimate behind a click.
struct ActionModelPicker: View {
    var eyebrow = "MODEL"
    let models: [ModelInfo]
    @Binding var selectedId: String?
    /// `INSTALLED · ≈ 40 S`. Built per model by the page, which knows the
    /// source duration the estimate needs.
    let meta: (ModelInfo) -> String

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10),
              count: min(3, max(1, models.count)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(eyebrow).eyebrow()
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(models) { model in
                    card(model, isSelected: model.id == selectedId)
                }
            }
        }
    }

    private func card(_ model: ModelInfo, isSelected: Bool) -> some View {
        Button {
            selectedId = model.id
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(model.displayName)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if isSelected {
                        ZStack {
                            Circle().fill(Bench.Palette.accent)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Bench.Palette.onAccent)
                        }
                        .frame(width: 14, height: 14)
                    }
                }
                Text(ActionCopy.oneLine(model.description))
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .lineSpacing(2)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(meta(model))
                    .metaLine(isSelected ? Bench.Palette.ok
                                         : Bench.Palette.textMuted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .benchCard(fill: isSelected ? Bench.Palette.cardSelected
                                        : Bench.Palette.card,
                       stroke: isSelected ? Bench.Palette.accent.opacity(0.32)
                                          : Bench.Palette.cardStrokeSoft)
            // Transparent padding takes no hits in SwiftUI: without this only
            // the text is clickable and the card feels broken at its edges.
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Options card

/// The plain card the option controls sit in — one shape so `Quality shifts`,
/// `Match tempo` and `Split at codebook` all read as the same kind of thing.
struct ActionOptionsCard<Content: View>: View {
    var eyebrow: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let eyebrow { Text(eyebrow).eyebrow() }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(radius: 13)
    }
}

/// The explanation the design puts under a control rather than behind a
/// tooltip — inapplicable and unusual settings say what they do out loud.
struct ActionFootnote: View {
    let text: String
    var tone: Color = Bench.Palette.textFaint

    var body: some View {
        Text(text)
            .font(Bench.Typo.small)
            .foregroundStyle(tone)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The one free-text field an action page has: what to call the result. Same
/// inset well as every numeric field, so a name and a number read as the same
/// kind of input.
struct ActionTextField: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat?
    var font: Font = Bench.Typo.body

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .tint(Bench.Palette.accent)
            .font(font)
            .foregroundStyle(Bench.Palette.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                         style: .continuous)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.controlLarge,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
    }
}

/// One chosen ingredient inside a multi-slot card: audition, stem colour,
/// name, and its own waveform — the design's first rule, that a list is for
/// hearing rather than reading, applies to slots too.
struct ActionMaterialRow: View {
    let material: PickedMaterial
    let playback: PlaybackController
    var meta: String?
    var onRemove: (() -> Void)?

    private var isCurrent: Bool { playback.currentSongId == material.id }

    var body: some View {
        HStack(spacing: 11) {
            BenchPlayButton(isPlaying: isCurrent && playback.isPlaying,
                            isCurrent: isCurrent, size: 26) {
                let url = material.auditionURL ?? material.fileURL
                playback.play(url: url, songId: material.id,
                              title: material.name,
                              duration: material.durationS ?? 0,
                              subtitle: "ACTION SOURCE")
            }
            StemBar(kind: material.kind, width: 5, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(material.name)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Text(meta ?? material.sourceTitle).metaLine()
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            MaterialStrip(material: material,
                          playedFraction: isCurrent ? playback.playedFraction : 0,
                          height: 26)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.windowBackground))
    }
}

// MARK: - Commit row

/// Pinned to the bottom of the main column: the lime primary, the mono cost
/// line, and `Add to queue`.
///
/// The two buttons submit exactly the same job. They differ in what happens to
/// *you*: the primary hands the screen back to the gallery, `Add to queue`
/// leaves the page configured so a second variation is one edit away. Every
/// job in this app already goes through one queue, so a button that claimed
/// otherwise would be lying.
struct ActionCommitRow: View {
    let title: String
    var costLine: String?
    var costSubline: String?
    var isEnabled = true
    var error: String?
    var queueTitle: String? = "Add to queue"
    let onCommit: () -> Void
    var onQueue: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            Button(title, action: onCommit)
                .buttonStyle(BenchPrimaryButtonStyle(glows: isEnabled))
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 3) {
                if let costLine {
                    Text(costLine)
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textQuaternary)
                }
                if let costSubline {
                    Text(costSubline)
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            Spacer(minLength: 8)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.dangerText)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .trailing)
            }
            if let queueTitle, let onQueue {
                Button(queueTitle, action: onQueue)
                    .buttonStyle(BenchSecondaryButtonStyle(
                        padding: .init(top: 11, leading: 16,
                                       bottom: 11, trailing: 16),
                        radius: 9))
                    .disabled(!isEnabled)
                    .opacity(isEnabled ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 30).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }
}

// MARK: - Right rail

/// One expected output. `kind` drives the stem colour bar, so the four cards
/// under a split are the same four colours the parts will wear everywhere else.
struct ActionOutput: Identifiable {
    var id: String
    var name: String
    var qualifier: String?
    var meta: String
    var kind: String?

    init(id: String, name: String, qualifier: String? = nil,
         meta: String, kind: String? = nil) {
        self.id = id
        self.name = name
        self.qualifier = qualifier
        self.meta = meta
        self.kind = kind
    }
}

/// `You'll get back` over the outputs, with `LAST RUN OF THIS ACTION` pinned to
/// the bottom of the same column.
struct ActionRail: View {
    var title = "You'll get back"
    let outputs: [ActionOutput]
    var explanation: String?
    var lastRun: ActionRunLog.Entry?
    /// Restores the recorded source and model onto the page. Absent when the
    /// page has nothing a summary could put back.
    var onReplay: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            BenchPanelHeader {
                Text(title)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(outputs) { output in
                        outputRow(output)
                    }
                    if let explanation {
                        Text(explanation)
                            .font(Bench.Typo.small)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .lineSpacing(3.5)
                            .padding(.top, 6)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if let lastRun {
                lastRunFooter(lastRun)
            }
        }
    }

    private func outputRow(_ output: ActionOutput) -> some View {
        HStack(spacing: 11) {
            StemBar(kind: output.kind, width: 6, height: 22)
            HStack(spacing: 5) {
                Text(output.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let qualifier = output.qualifier {
                    Text(qualifier)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 6)
            Text(output.meta).metaLine()
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(stroke: Bench.Palette.cardStrokeSoft, radius: 10)
    }

    private func lastRunFooter(_ entry: ActionRunLog.Entry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("LAST RUN OF THIS ACTION").eyebrow()
            HStack(spacing: 11) {
                if let onReplay {
                    Button(action: onReplay) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Bench.Palette.control)
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Bench.Palette.textSecondary)
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Put that source and model back on this page")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.summary)
                        .font(Bench.Typo.secondaryEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Text(ActionFormat.join([entry.detail.isEmpty ? nil
                                                                 : entry.detail,
                                            ActionFormat.ago(entry.at)]))
                        .metaLine()
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

// MARK: - Empty state

/// What a page shows when there is no installed model that can run it. It keeps
/// the route to Models rather than disabling into silence — the design's fifth
/// rule, said at page scale.
/// `ActionNeedsModel` with the third state in front of it.
///
/// Every page that gates on a model reaches the "you need to install this"
/// branch by finding an empty candidate list — which is also what an empty
/// list looks like for the first second of a launch, and for as long as a
/// broken engine stays broken. This picks between the three so no page has to
/// remember to.
struct ActionModelGate: View {
    let readiness: CatalogReadiness
    let title: String
    let detail: String
    let onOpenModels: () -> Void

    var body: some View {
        switch readiness {
        case .pending(let waiting):
            HStack(spacing: 11) {
                BenchSpinner(size: 15)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Checking what's installed…")
                        .font(Bench.Typo.sectionTitle)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(waiting)
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.textQuaternary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .benchCard(radius: 13)
        case .unavailable(let message):
            // Not "install a model": the models are probably right there, and
            // the download button this would otherwise offer cannot work
            // either. Models is still the destination — it is where the engine
            // failure is spelled out and where the restart lives.
            ActionNeedsModel(title: "The engine isn't running",
                             detail: message, onOpenModels: onOpenModels)
        case .ready:
            ActionNeedsModel(title: title, detail: detail,
                             onOpenModels: onOpenModels)
        }
    }
}

struct ActionNeedsModel: View {
    let title: String
    let detail: String
    let onOpenModels: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(detail)
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textQuaternary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Models", action: onOpenModels)
                .buttonStyle(.bench(.accent))
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.06),
                   stroke: Bench.Palette.warn.opacity(0.22), radius: 13)
    }
}
