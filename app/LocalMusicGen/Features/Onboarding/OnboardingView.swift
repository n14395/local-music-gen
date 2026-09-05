import SwiftUI

/// First run. The app is useless until some models exist on disk, and until now
/// the only thing a new install said was "No models installed" — leaving the
/// user to work out, from a list of sixty-four, which handful actually makes
/// the thing work.
///
/// Three states in one sheet: choose, watch, done — with the engine's own
/// setup in front of them.
///
/// The sheet used to wait for the catalog before appearing, which meant a
/// genuine first run spent its slowest minute in front of a fully-drawn app
/// whose every screen said nothing was installed, and only then said welcome.
/// That wait is real work — a private Python runtime and the engine's
/// dependencies, fetched once — and this is the honest place to spend it,
/// because it is the one surface a first run was always going to see.
struct OnboardingView: View {
    let catalog: ModelCatalogStore
    let downloads: DownloadsStore
    /// The engine's own state. A first run reaches this sheet long before the
    /// catalog exists — see `content` — and the wait it is showing is this.
    let backend: BackendStatusStore
    let freeDiskBytes: Int64?
    /// Called once the user has either started the installs or waved the sheet
    /// away — either way onboarding is over and must not come back.
    let onFinish: () -> Void

    @State private var selection: Set<String> = []
    @State private var phase: Phase = .choosing
    @State private var didPrimeSelection = false
    /// The models this sheet actually started installing, snapshotted at the
    /// moment Install was pressed. It cannot be re-derived from the plan:
    /// `OnboardingPlan.make` drops anything already installed, so a live plan
    /// would delete each row from the progress list at the exact moment it
    /// succeeded.
    @State private var installingModels: [ModelInfo] = []

    private enum Phase { case choosing, installing }

    private var plan: OnboardingPlan {
        OnboardingPlan.make(models: catalog.models,
                            physicalRAM: ModelCatalogStore.physicalRAM,
                            hasHFToken: catalog.hasHFToken)
    }

    private var selectedBytes: Int64 { plan.bytes(for: selection) }

    /// Every install this sheet started has finished. Runtime provisioning is
    /// deliberately not waited on — it happens on the first job and is reported
    /// there; holding the sheet open through a torch install would be a long,
    /// silent stare at a spinner.
    private var isComplete: Bool {
        !installingModels.isEmpty && installingModels.allSatisfy { model in
            catalog.model(id: model.id)?.installState == .installed
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Bench.Palette.hairline)
            ScrollView { content.padding(20) }
                .frame(maxHeight: .infinity)
            Divider().overlay(Bench.Palette.hairline)
            footer
        }
        .frame(width: 640, height: 660)
        .background(Bench.Palette.panel)
        .preferredColorScheme(.dark)
        .onAppear(perform: primeSelection)
        // The catalog can land a beat after the sheet does.
        .onChange(of: catalog.version) { primeSelection() }
    }

    /// Tick the defaults once, and only once: re-running it on every catalog
    /// refresh would undo the user's choices mid-sheet, and the catalog
    /// refreshes on every `models.changed` — including the ones this sheet's
    /// own downloads emit.
    private func primeSelection() {
        guard !didPrimeSelection, catalog.hasLoaded, !plan.isEmpty else { return }
        selection = plan.defaultSelection
        didPrimeSelection = true
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headerTitle)
                .font(Bench.Typo.inspectorTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(headerDetail)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    private var headerTitle: String {
        if phase == .installing { return "Setting up" }
        return "Welcome to LocalMusicGen"
    }

    private var headerDetail: String {
        if phase == .installing {
            return "Downloads run one at a time. You can close this and carry "
                + "on; progress stays in the Models tab."
        }
        if !catalog.readiness.knowsWhatIsInstalled {
            return "One moment — the app is starting the engine that runs the "
                + "models. The rest of the app works while it does."
        }
        return "Music models run on this Mac, so they have to be downloaded "
            + "first. Here's a set that makes everything work — you can add "
            + "or remove models any time."
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        // Order matters: once installing, the plan empties out underneath us as
        // each model lands, and the sheet must keep showing the run it started.
        if phase == .installing {
            installingList
        } else if case .pending(let detail) = catalog.readiness {
            engineSetupStep(detail)
        } else if case .unavailable(let message) = catalog.readiness {
            engineFailedStep(message)
        } else if plan.isEmpty {
            Text("Everything recommended is already installed.")
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textMuted)
                .frame(maxWidth: .infinity, minHeight: 260)
        } else {
            choosingList
        }
    }

    /// The wait, named. On the very first launch this is the engine fetching a
    /// private Python runtime and building its dependency set — tens of
    /// seconds, and it needs the internet. Saying so is the difference between
    /// a slow start and an app that looks broken.
    private func engineSetupStep(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                BenchSpinner(size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(backend.setupLine ?? detail)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text("First launch only.")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                }
                Spacer(minLength: 0)
            }
            Text("LocalMusicGen runs every model on this Mac, in its own private "
                 + "Python runtime. That runtime is fetched once, now, and "
                 + "never again — it needs the internet, and it is the only "
                 + "part of the app that does before you pick a model.")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textQuaternary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("Nothing is waiting on it except the model list. The "
                 + "Library, playback and importing all work already.")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaintest)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .benchCard(radius: 13)
    }

    /// The engine answered with a failure, so this is not a wait — it is a
    /// stop. Offering the model list here would be a lie: nothing on it could
    /// be downloaded either.
    private func engineFailedStep(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("The engine didn't start")
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(message)
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textQuaternary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("The most common cause on a first launch is no internet "
                 + "connection: the Python runtime the models need is fetched "
                 + "once, at this point. Reconnect and reopen the app.")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaintest)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.06),
                   stroke: Bench.Palette.warn.opacity(0.22), radius: 13)
    }

    private var choosingList: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !plan.essentials.isEmpty {
                section("THE BASICS") { essentialsRow }
            }
            if !plan.generators.isEmpty {
                section("MAKE MUSIC") {
                    VStack(spacing: 8) {
                        ForEach(plan.generators) { item in
                            generatorRow(item)
                        }
                    }
                }
            }
            licenceNote
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content)
        -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).eyebrow(Bench.Palette.textFaintest)
            content()
        }
    }

    // MARK: - Rows

    /// Seven models offered as one line. They are free or nearly free, and no
    /// part of the app they unlock is optional — asking someone on their first
    /// run to adjudicate a 40 MB SoundFont would be a fake choice.
    private var essentialsRow: some View {
        let ids = Set(plan.essentials.map(\.id))
        let isOn = ids.isSubset(of: selection)
        return card(isOn: isOn) {
            toggle(isOn: isOn) {
                if isOn { selection.subtract(ids) } else { selection.formUnion(ids) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text("Essentials")
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    BenchBadge(sizeBadge(plan.essentialBytes), tone: .ok)
                }
                Text("Tempo, key and beat detection · chords · quality "
                     + "scores · genre and mood tags · stem separation · "
                     + "note transcription · note rendering · beat-aligned "
                     + "mixing. Without these, most of Split & Recombine "
                     + "can't run.")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func generatorRow(_ item: OnboardingPlan.Item) -> some View {
        let isOn = selection.contains(item.id)
        return card(isOn: isOn) {
            toggle(isOn: isOn) {
                if isOn { selection.remove(item.id) }
                else { selection.insert(item.id) }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(item.model.displayName)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    BenchBadge(sizeBadge(item.model.sizeBytes))
                    if let tag = item.model.modelTags.first {
                        BenchBadge(tag.uppercased(), tone: .violet)
                    }
                }
                Text(item.model.description)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // What a big download buys, where the name does not say it.
                if let unlocks = OnboardingPlan.unlocks(item.id) {
                    Text(unlocks)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let reason = item.blockedReason {
                    Text(reason)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.warn)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var installingList: some View {
        VStack(spacing: 8) {
            ForEach(installingModels) { model in
                OnboardingProgressRow(
                    model: model,
                    download: downloads.info(forModel: model.id),
                    isInstalled: catalog.models
                        .first { $0.id == model.id }?.installState == .installed)
            }
        }
    }

    // MARK: - Row furniture

    private func card<Content: View>(isOn: Bool,
                                     @ViewBuilder content: () -> Content)
        -> some View {
        HStack(alignment: .top, spacing: 11) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isOn ? Bench.Palette.cardSelected : Bench.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isOn ? Bench.Palette.accent.opacity(0.30)
                               : Bench.Palette.cardStroke, lineWidth: 1))
    }

    private func toggle(isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isOn ? Bench.Palette.accent : Bench.Palette.control)
                .frame(width: 19, height: 19)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Bench.Palette.onAccent)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Bench.Palette.cardStroke, lineWidth: isOn ? 0 : 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 1)
    }

    /// `76 MB` under a gigabyte, `9.4 GB` over it. `ByteFormat.gb` would print
    /// most of the essentials as `0.0 GB`, which reads as a bug.
    private func sizeBadge(_ bytes: Int64) -> String {
        bytes < 1_073_741_824
            ? "\(Int((Double(bytes) / 1_000_000).rounded())) MB"
            : ByteFormat.gb(bytes).uppercased()
    }

    // MARK: - Licences

    private var licenceNote: some View {
        let licences = Set(plan.items(for: selection).map(\.model.license.name))
            .sorted()
        return VStack(alignment: .leading, spacing: 4) {
            Text("LICENCES").eyebrow(Bench.Palette.textFaintest)
            Text(licences.isEmpty ? "Nothing selected."
                                  : licences.joined(separator: " · "))
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            Text("Weights are downloaded from Hugging Face under your own "
                 + "acceptance of each model's license; nothing is "
                 + "redistributed by this app.")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaintest)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if phase == .choosing {
                VStack(alignment: .leading, spacing: 2) {
                    Text(footerSummary)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    if catalog.readiness.knowsWhatIsInstalled,
                       let disk = diskLine {
                        Text(disk.text)
                            .font(Bench.Typo.caption)
                            .foregroundStyle(disk.isShort ? Bench.Palette.warn
                                                          : Bench.Palette.textFaint)
                    }
                }
            } else {
                Text(isComplete ? "All set — everything is installed."
                                : "Downloading…")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textSecondary)
            }

            Spacer(minLength: 8)

            switch phase {
            case .choosing:
                // Nothing to install, either because the engine already had
                // everything or because it never answered: in both cases the
                // second button would be a disabled "Install" sitting next to
                // a "Skip" the user has no reason not to press, which is two
                // controls saying one thing.
                if hasNothingToOffer {
                    Button("Start making music", action: onFinish)
                        .buttonStyle(.benchPrimary)
                } else {
                    Button("Skip for now", action: onFinish)
                        .buttonStyle(.benchSecondary)
                    Button("Install", action: startInstall)
                        .buttonStyle(.benchPrimary)
                        .disabled(selection.isEmpty)
                }
            case .installing:
                Button(isComplete ? "Start making music" : "Continue in the app",
                       action: onFinish)
                    .buttonStyle(.benchPrimary)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    /// True when there is no choice left to make: the engine hasn't answered,
    /// it failed, or everything recommended is already here.
    private var hasNothingToOffer: Bool {
        !catalog.readiness.knowsWhatIsInstalled || plan.isEmpty
    }

    private var footerSummary: String {
        switch catalog.readiness {
        case .pending: "Getting ready…"
        case .unavailable: "Can't reach the engine"
        case .ready:
            plan.isEmpty ? "Everything recommended is here"
                : selection.isEmpty ? "Nothing selected"
                    : "\(ByteFormat.gb(selectedBytes)) to download"
        }
    }

    private var diskLine: (text: String, isShort: Bool)? {
        guard let free = freeDiskBytes else { return nil }
        let short = selectedBytes > free
        return (short
                ? "Not enough space — \(ByteFormat.gb(free)) free on this disk"
                : "\(ByteFormat.gb(free)) free on this disk", short)
    }

    // MARK: - Install

    private func startInstall() {
        let items = plan.items(for: selection)
        installingModels = items.map(\.model)
        phase = .installing
        Task {
            for item in items {
                // The same gate the Models tab applies (`requestDownload`):
                // a download is made under the user's acceptance of the
                // licence, which the sheet has just shown them.
                catalog.acceptLicense(for: item.model)
                await catalog.startDownload(item.model)
            }
        }
    }
}

// MARK: - Progress row

/// One model's install while onboarding watches it. Zero-byte models — the
/// three transcribers and the DSP mixdown, whose weights ride inside their
/// Python package — complete in a single tick with no bytes ever counted, so
/// this must never treat "no bytes" as "no progress".
private struct OnboardingProgressRow: View {
    let model: ModelInfo
    let download: DownloadInfo?
    let isInstalled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            icon
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(model.displayName)
                        .font(Bench.Typo.bodyEmphasis)
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Spacer(minLength: 0)
                    Text(status)
                        .font(Bench.Typo.metaLine)
                        .foregroundStyle(isInstalled ? Bench.Palette.ok
                                                     : Bench.Palette.textFaint)
                }
                if !isInstalled, let download, download.bytesTotal > 0 {
                    BenchProgressBar(fraction: Double(download.bytesDone)
                                        / Double(download.bytesTotal),
                                     height: 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
    }

    @ViewBuilder
    private var icon: some View {
        if isInstalled {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(Bench.Palette.ok)
        } else if download != nil {
            BenchSpinner(size: 15)
        } else {
            Image(systemName: "circle.dotted")
                .font(.system(size: 15))
                .foregroundStyle(Bench.Palette.textFaintest)
        }
    }

    private var status: String {
        if isInstalled { return "DONE" }
        guard let download else { return "WAITING" }
        switch download.state {
        case .queued: return "QUEUED"
        case .paused: return "PAUSED"
        case .provisioning: return "SETTING UP RUNTIME"
        case .downloading:
            guard download.bytesTotal > 0 else { return "DOWNLOADING" }
            return DownloadFormat.progress(done: download.bytesDone,
                                           total: download.bytesTotal)
                .uppercased()
        }
    }
}
