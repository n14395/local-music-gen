import SwiftUI

/// Everything the catalog knows about one model, in the rail beside the list.
///
/// The rows are a scanning surface — name, size, a few badges — and they are
/// deliberately terse, so the facts that decide whether a model is the right
/// one had nowhere to live: what it accepts, what it produces, what it costs
/// to run, what licence it carries, which repositories it pulls.
///
/// The section that justifies the panel is **What it can do**. `ACTIONS` was
/// a number on the row, and a number is exactly the wrong shape for that
/// question: "17 actions" tells you a model is versatile without telling you
/// whether it does the one thing you came for. Here they are named, grouped
/// under the same shelves the Actions gallery uses, so the answer to "can
/// this model split vocals" is a word rather than an arithmetic.
///
/// Derived, never stored: the list comes from `ModelActions`, which reads the
/// recipe catalog against the model's declared tasks and params. A recipe
/// added tomorrow appears here with no change to this file.
struct ModelInspector: View {
    let model: ModelInfo
    let actionCount: Int
    let onOpenAction: (Recipe) -> Void

    private var caps: Capabilities { model.capabilities }

    var body: some View {
        VStack(spacing: 0) {
            BenchPanelHeader {
                Text("Model")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    heading
                    actionsSection
                    whatItTakes
                    costSection
                    licenceSection
                    repoSection
                    if let notes = model.notes, !notes.isEmpty {
                        section("NOTES") {
                            Text(notes)
                                .font(Bench.Typo.caption)
                                .foregroundStyle(Bench.Palette.textFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.displayName)
                .font(Bench.Typo.inspectorTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.id)
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textFaintest)
                .textSelection(.enabled)
            if !model.description.isEmpty {
                Text(model.description)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - What it can do

    @ViewBuilder
    private var actionsSection: some View {
        let groups = ModelActions.grouped(for: model)
        section("WHAT IT CAN DO", count: actionCount) {
            if groups.isEmpty {
                // Not a failure: plenty of entries are one job done well, and
                // some are building blocks another card runs.
                Text("No Actions card runs on this model directly — it is "
                     + "used from Generate, or as part of another card's "
                     + "chain.")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.category) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.category.title.uppercased())
                                .font(Bench.Typo.mono(9))
                                .foregroundStyle(Bench.Palette.textFaintest)
                            ForEach(group.recipes) { recipe in
                                actionRow(recipe)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Clickable, because the panel would otherwise be a list of things you
    /// then have to go and find. The Actions gallery is one route; this is
    /// the shorter one.
    private func actionRow(_ recipe: Recipe) -> some View {
        Button { onOpenAction(recipe) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: recipe.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Bench.Palette.accent)
                    .frame(width: 16, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recipe.name)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(recipe.tagline)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open “\(recipe.name)” in Actions")
    }

    // MARK: - Inputs and outputs

    private var whatItTakes: some View {
        section("WHAT IT TAKES") {
            VStack(alignment: .leading, spacing: 6) {
                fact("Tasks", caps.supportedTasks
                    .map { $0.replacingOccurrences(of: "-", with: " ") }
                    .joined(separator: ", "))
                if caps.needsSourceAudio {
                    fact("Needs", "audio in — it transforms, it cannot start "
                         + "from a prompt alone")
                }
                if caps.needsLyrics {
                    fact("Needs", "lyrics — it sings words you give it")
                } else if caps.supportsLyrics {
                    fact("Lyrics", "optional")
                }
                if caps.supportedTasks.contains("generate") {
                    let d = caps.duration
                    fact("Length", "\(Int(d.minS))–\(Int(d.maxS)) s "
                         + "(default \(Int(d.defaultS)))")
                    if caps.outputsPerJobMax > 1 {
                        fact("Takes", "up to \(caps.outputsPerJobMax) per run")
                    }
                }
                fact("Output", "\(caps.sampleRate / 1000) kHz")
                let knobs = caps.params.filter { $0.isInternal != true }
                if !knobs.isEmpty {
                    fact("Parameters", "\(knobs.count) — "
                         + knobs.prefix(4).map(\.label)
                            .joined(separator: ", ")
                         + (knobs.count > 4 ? "…" : ""))
                }
            }
        }
    }

    // MARK: - Cost

    private var costSection: some View {
        section("WHAT IT COSTS") {
            VStack(alignment: .leading, spacing: 6) {
                fact("Download", ByteFormat.gb(model.sizeBytes))
                fact("Memory", "\(ByteFormat.wholeGB(model.requirements.minRamBytes)) GB "
                     + "at least")
                if let est = speedLine { fact("Speed", est) }
                fact("Installed", installedLine)
            }
        }
    }

    private var speedLine: String? {
        if caps.supportedTasks.contains("generate"),
           caps.estSecondsPerAudioSecond > 0 {
            let rate = caps.estSecondsPerAudioSecond
            return rate < 1
                ? String(format: "about %.1f× faster than realtime", 1 / rate)
                : String(format: "about %.0f× the length of what it makes",
                         rate)
        }
        if let factor = caps.estRealtimeFactor, factor > 0 {
            return factor < 1
                ? String(format: "about %.1f× faster than realtime", 1 / factor)
                : String(format: "about %.0f× the length of its input", factor)
        }
        return nil
    }

    private var installedLine: String {
        switch model.installState {
        case .installed: "yes"
        case .downloading: "downloading now"
        default: "no"
        }
    }

    // MARK: - Licence and repos

    private var licenceSection: some View {
        section("LICENCE") {
            VStack(alignment: .leading, spacing: 6) {
                fact("Terms", model.license.name)
                fact("Commercial use", model.license.commercialUse ? "allowed"
                                                                   : "not allowed")
                if model.license.requiresHfToken {
                    fact("Gated", "needs a Hugging Face token, and the licence "
                         + "accepted on the model's page")
                }
                if let url = model.license.url, let link = URL(string: url) {
                    Link("Read the licence", destination: link)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var repoSection: some View {
        // Where the weights actually come from — the thing to check when a
        // download 401s, and the only place the app admits that one model can
        // be several repositories.
        if !model.hfRepos.isEmpty {
            section("WEIGHTS FROM") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.hfRepos, id: \.repoId) { repo in
                        Text(repo.repoId)
                            .font(Bench.Typo.mono(10))
                            .foregroundStyle(Bench.Palette.textTertiary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: - Pieces

    private func section<Content: View>(
        _ title: String, count: Int? = nil,
        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(title).eyebrow()
                if let count {
                    Text("\(count)")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaintest)
                .frame(width: 92, alignment: .leading)
            Text(value)
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
