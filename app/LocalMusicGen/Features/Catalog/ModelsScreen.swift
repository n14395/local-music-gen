import AppKit
import SwiftUI

/// The Models screen: what you can run on *this* Mac, and what it would cost.
///
/// The catalog is 64 models deep and only a handful are worth a first look, so
/// the screen is built around one judgement — "recommended" means featured, or
/// currently downloading — with everything else folded behind a single
/// disclosure rather than paginated, searched for or hidden. Variants (the
/// quantised and runtime-specific builds of a family) nest one level under
/// their base so the list stays a list.
///
/// The sidebar's storage card is drawn by `MainWindow`; this screen owns only
/// the content column.
struct ModelsScreen: View {
    let catalog: ModelCatalogStore
    let downloads: DownloadsStore
    let telemetry: TelemetryStore
    /// Set when you arrived here from a gated feature: the list narrows to the
    /// models that would ungate it, and says so. A binding because dismissing
    /// the chip has to clear it for whoever routed you.
    @Binding var requirement: ModelRequirement?
    /// The row whose properties the rail is showing. By id rather than by
    /// value: the catalog is refetched on every install-state change, and a
    /// stored `ModelInfo` would go stale the moment the model it describes
    /// finished downloading.
    ///
    /// Bound to the window rather than held here, because this screen is
    /// rebuilt from scratch on every navigation — kept as local state, the
    /// rail would shut itself every time you nipped over to the Library.
    @Binding var inspectedId: String?
    /// Bound to the shell rather than held here, like `requirement` and
    /// `inspectedId` above and for a third reason as well as theirs: File's
    /// "Add Model from Hugging Face…" raises this sheet from any screen, and
    /// a flag private to Models could not be reached from a menu.
    @Binding var showAddModel: Bool
    /// Open an Actions card named in the properties rail. Absent where the
    /// screen has no route to Actions — the rail then just lists them.
    var onOpenAction: ((Recipe) -> Void)?

    @State private var licenseTarget: ModelInfo?
    @State private var deleteTarget: ModelInfo?
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var selectedTags: Set<String> = []
    /// Persisted, and shared with the sidebar's storage card: "Free up
    /// space…" narrows the list to what is actually taking up room, which
    /// means it has to be able to set this from outside the screen.
    private var onlyInstalled: Bool {
        get { catalog.onlyInstalledFilter }
        nonmutating set { catalog.onlyInstalledFilter = newValue }
    }
    /// Persisted rather than per-visit: a user who went looking for the long
    /// tail shouldn't have it snap shut every time they leave the screen.
    @AppStorage("models.showAll") private var showAllModels = false

    // MARK: - Filtering

    /// Shared with Studio's model picker: one catalog, one idea of a hit.
    /// See `ModelSearch` for why it is tokens rather than one substring.
    private func matchesSearch(_ model: ModelInfo) -> Bool {
        ModelSearch.matches(query: filter,
                            in: [model.displayName, model.description,
                                 model.family])
    }

    /// Everything the search box and the "Only installed" switch let through.
    /// The tag chips count against *this* rather than the whole catalog, so a
    /// chip never advertises models the other two filters are hiding.
    private var scopedModels: [ModelInfo] {
        // A requirement overrides the persisted filters rather than rewriting
        // them: "Only installed" is exactly wrong when you were sent here to
        // install something, and clobbering a stored preference as a
        // navigation side effect would outlive the errand that caused it.
        if let requirement {
            return catalog.models.filter {
                matchesSearch($0) && requirement.matches($0)
            }
        }
        return catalog.models.filter {
            matchesSearch($0) && (!onlyInstalled || $0.installState == .installed)
        }
    }

    /// What the filters let through, **plus anything currently downloading**.
    ///
    /// Promoting a download into `recommended` is not enough on its own: the
    /// layout drops any group the filters exclude, so typing a search term or
    /// ticking a tag could still hide an in-flight download from the only
    /// screen that can pause or cancel it. A filter is a question about the
    /// catalogue; a running download is a fact about right now.
    private var matchingIds: Set<String> {
        // Tag chips are hidden while a requirement is showing, so a selection
        // left over from a previous visit must not narrow the list invisibly.
        let matched = Set(scopedModels
            .filter { requirement != nil
                || ModelTagFilter.matches($0, selection: selectedTags) }
            .map(\.id))
        // The store's own set rather than a scan of the catalog against it:
        // the layout only ever asks this set whether it *contains* an id, so an
        // id for a model the catalog has not got costs nothing.
        return matched.union(downloads.downloadingModelIds)
    }

    /// This Mac's memory. Shown, not filtered on: the section header quotes it
    /// and every over-large model is badged with it, so an outsized model stays
    /// visible and says why it will not fit.
    private var physicalMemory: Int64 { ModelCatalogStore.physicalRAM }

    /// Base ids of anything with bytes in flight.
    private var downloadingBaseIds: Set<String> {
        ModelListLayout.baseIds(of: downloads.downloadingModelIds,
                                in: catalog.models)
    }

    /// Deliberately *not* filtered on memory. The design's one downloading row
    /// is `minimax-music3`, a 48 GB model drawn inside RECOMMENDED on a 36 GB
    /// Mac wearing `NEEDS 48 GB · YOU HAVE 36` — "for this Mac" is the eyebrow
    /// and the per-row badge, not a filter. Screening on RAM here would drop
    /// that row into `other`, where the badge warning you off it can never be
    /// seen, and a running download would hide itself.
    private var recommendedIds: Set<String> {
        ModelListLayout.recommendedIds(in: catalog.models)
    }

    // MARK: - The plan, and when it is stale

    /// The list as it will be drawn, plus the disclosure state that shaped it.
    /// The two travel together because they are one walk of the catalog: the
    /// expansion decides which variants the plan contains, and asking for it
    /// separately meant scanning the catalog a second time to get the same
    /// answer.
    private struct ListPlan {
        let plan: ModelListPlan
        /// What the list is actually showing, which is not always what the
        /// toggle was last set to: a requirement narrows to models that are
        /// frequently unfeatured, and a download in the long tail holds its
        /// section open.
        let isExpanded: Bool
    }

    /// Everything the plan is a function of, as one comparable value.
    ///
    /// Building the plan walks the catalog several times over — a tokenised
    /// search match per model, the variant chains, the sort — and `body` ran
    /// all of it on every pass, including the twice-a-second ones a running
    /// download causes. Not one of these inputs moves while bytes do, so the
    /// plan is kept between passes and this is what says when it is stale.
    private struct PlanKey: Equatable {
        let catalogVersion: Int
        let filter: String
        let tags: Set<String>
        let onlyInstalled: Bool
        let requirement: ModelRequirement?
        let showAll: Bool
        /// Which models are downloading, not how far along they are: a
        /// download joins the list and can hold the tail open, and both of
        /// those are settled the moment it starts.
        let downloading: Set<String>
    }

    private var planKey: PlanKey {
        PlanKey(catalogVersion: catalog.version, filter: filter,
                tags: selectedTags, onlyInstalled: onlyInstalled,
                requirement: requirement, showAll: showAllModels,
                downloading: downloads.downloadingModelIds)
    }

    @State private var planCache: (key: PlanKey, value: ListPlan)?

    private func buildPlan() -> ListPlan {
        // Always expanded under a requirement: the model you were sent for is
        // frequently an unfeatured build (the DiT variants that serve a style
        // mode nest under a base, and the separation models are not featured
        // at all), and a list that hides it defeats the whole errand.
        let expanded = showAllModels || requirement != nil
            || ModelListLayout.holdsTailOpen(
                models: catalog.models,
                downloadingBaseIds: downloadingBaseIds)
        return ListPlan(
            plan: ModelListLayout.plan(models: catalog.models,
                                       matching: matchingIds,
                                       recommended: recommendedIds,
                                       expanded: expanded),
            isExpanded: expanded)
    }

    private var listPlan: ListPlan {
        if let planCache, planCache.key == planKey { return planCache.value }
        // Built rather than cached here, because `body` must not write state.
        // The `.onChange` fills the cache a beat later; until it does the plan
        // is arrived at exactly the way it always was, so a keystroke in the
        // filter box is never a frame behind the list it filters.
        return buildPlan()
    }

    private func clearFilters() {
        selectedTags.removeAll()
        filter = ""
        onlyInstalled = false
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if !catalog.models.isEmpty { filterBar }
            HStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                BenchInspector(width: Bench.Metrics.Inspector.modelProperties) {
                    if let model = inspectedModel {
                        ModelInspector(
                            model: model,
                            actionCount: ModelActions.count(for: model),
                            onOpenAction: { onOpenAction?($0) })
                    } else {
                        LibraryEmptyState(title: "Select a model",
                                          message: "Details appear here.")
                    }
                }
            }
        }
        .background(Bench.Palette.windowBackground)
        // ⌘F is the Edit menu's item now, not a hidden button: one item that
        // names where it will land ("Find in Models") instead of four
        // invisible ones that claimed the key with nothing to show for it.
        .focusedSceneValue(\.searchCommand,
                           SearchCommand(scope: "Models") { filterFocused = true })
        .onChange(of: planKey, initial: true) { _, key in
            planCache = (key: key, value: buildPlan())
        }
        .task { await catalog.refresh() }
        .sheet(isPresented: $showAddModel) {
            AddModelSheet(catalog: catalog)
        }
        .sheet(item: $licenseTarget) { model in
            LicenseSheet(model: model) {
                catalog.acceptLicense(for: model)
                Task { await catalog.startDownload(model) }
            }
        }
        .confirmationDialog("Delete \(deleteTarget?.displayName ?? "model")?",
                            isPresented: Binding(get: { deleteTarget != nil },
                                                 set: { if !$0 { deleteTarget = nil } })) {
            Button("Delete model files", role: .destructive) {
                if let model = deleteTarget { Task { await catalog.delete(model) } }
            }
        } message: {
            Text(deleteTarget.map {
                ModelDeletion.message(for: $0, in: catalog.models)
            } ?? "")
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        BenchTopBar(title: "Models") {
            BenchSearchField(text: $filter, placeholder: "Filter models",
                             focused: $filterFocused)
            Button { showAddModel = true } label: {
                Text("＋ Add a model…")
            }
            .buttonStyle(.benchSecondary)
            .help("Add a model from Hugging Face")
        }
    }

    // MARK: - Filter bar

    @ViewBuilder
    private var filterBar: some View {
        if let requirement {
            BenchFilterBar { requirementChip(requirement) }
        } else {
            tagFilterBar
        }
    }

    /// What you were sent here to find, and the way back out. Kept until it is
    /// dismissed or satisfied rather than fading: installing takes minutes, and
    /// a hint that has gone by the time the download finishes leaves you in a
    /// filtered list with no memory of why.
    private func requirementChip(_ requirement: ModelRequirement) -> some View {
        let candidates = requirement.candidates(catalog.models)
        return HStack(spacing: 9) {
            Text("NEEDED FOR").eyebrow()
            Text(requirement.title)
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(candidates.count == 1 ? "1 MODEL"
                                       : "\(candidates.count) MODELS")
                .font(Bench.Typo.badge)
                .foregroundStyle(Bench.Palette.textQuaternary)
            Spacer(minLength: 8)
            Button("Show all models") { self.requirement = nil }
                .buttonStyle(.bench(.quiet))
        }
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(Bench.Palette.accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.accent.opacity(0.26), lineWidth: 1))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tagFilterBar: some View {
        let scoped = scopedModels
        let counts = ModelTagFilter.counts(from: scoped)
        return BenchFilterBar {
            FlowLayout(spacing: 7, rowSpacing: 7) {
                BenchFilterChip(label: "All", count: scoped.count,
                                isSelected: selectedTags.isEmpty) {
                    selectedTags.removeAll()
                }
                .help("Show every model")
                ForEach(ModelTagFilter.orderedTags(from: scoped), id: \.self) { tag in
                    BenchFilterChip(label: tag, count: counts[tag],
                                    isSelected: selectedTags.contains(tag)) {
                        if selectedTags.contains(tag) {
                            selectedTags.remove(tag)
                        } else {
                            selectedTags.insert(tag)
                        }
                    }
                    .help("Show models you can use for \(tag.lowercased())")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 9) {
                Text("Only installed")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(onlyInstalled ? Bench.Palette.textSecondary
                                                   : Bench.Palette.textQuaternary)
                Toggle(isOn: Binding(get: { onlyInstalled },
                                     set: { onlyInstalled = $0 })) {
                    EmptyView()
                }
                .toggleStyle(.bench(width: 34))
            }
            .fixedSize()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let shown = listPlan
        if catalog.models.isEmpty {
            placeholder
        } else if shown.plan.recommended.isEmpty && shown.plan.other.isEmpty {
            noMatches
        } else {
            list(shown)
        }
    }

    private func list(_ shown: ListPlan) -> some View {
        ScrollViewReader { proxy in
            listBody(shown)
                // One candidate is an answer rather than a choice, so it is
                // put in front of you. With more than one it stays a list:
                // five separation models differ in size, speed and licence,
                // and picking one silently is the decision this screen exists
                // to let you make.
                .onChange(of: requirement, initial: true) {
                    guard let requirement,
                          case let only = requirement.candidates(catalog.models),
                          only.count == 1, let target = only.first else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(target.id, anchor: .center)
                    }
                }
        }
    }

    private func listBody(_ shown: ListPlan) -> some View {
        // Read here, where `body` is what is running, so the dependency is
        // registered on this view rather than lost inside the lazy stack. The
        // *projection* rather than the raw dictionary: this read is what
        // decides how often the whole screen is rebuilt, so it has to be a
        // value that moves when the rows do and not when the bytes do.
        let active = downloads.modelDownloads
        let failures = downloads.failures
        func rowView(_ listRow: ModelListRow) -> some View {
            row(listRow,
                download: active[listRow.model.id],
                failure: failures[listRow.model.id])
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                Text("RECOMMENDED FOR THIS MAC · "
                     + ByteFormat.wholeGB(physicalMemory) + " GB")
                    .eyebrow()
                    .padding(.horizontal, 2).padding(.bottom, 4)

                if shown.plan.recommended.isEmpty {
                    Text("No featured model matches these filters.")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.horizontal, 2).padding(.bottom, 6)
                } else {
                    ForEach(shown.plan.recommended) { rowView($0) }
                }

                if shown.plan.hidden > 0 {
                    everythingElseDivider(shown)
                }
                if shown.isExpanded {
                    ForEach(shown.plan.other) { rowView($0) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func everythingElseDivider(_ shown: ListPlan) -> some View {
        HStack(spacing: 10) {
            Text("EVERYTHING ELSE · \(shown.plan.hidden)").eyebrow()
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            // Reads the state the list is really in, not the stored
            // preference: while a download holds this section open, a control
            // still offering "Show all" would be describing a section that is
            // already open, and one that closed it would hide the only place
            // to pause or cancel the transfer.
            let heldOpen = shown.isExpanded && !showAllModels
            Button {
                showAllModels.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(shown.isExpanded ? "Show less" : "Show all")
                    Image(systemName: shown.isExpanded ? "chevron.up"
                                                       : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.accent)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(heldOpen)
            .opacity(heldOpen ? 0.45 : 1)
            .help(heldOpen
                  ? "Kept open while a download here is running"
                  : "Include every model in the catalog, not just the featured ones")
        }
        .padding(.horizontal, 2).padding(.vertical, 10)
    }

    /// Handed its download and failure rather than reading them, because the
    /// caller is a `LazyVStack`'s `ForEach` closure: SwiftUI runs that during
    /// layout, outside the tracking scope of `body`, so an `@Observable` read
    /// in here registers no dependency and the row never hears about a change.
    ///
    /// It looked fine while bytes were moving — progress events and the 3 s
    /// telemetry poll invalidate the screen several times a second, which
    /// repaints everything by accident. Idle, the poll drops to 15 s and
    /// dismissing a failure appeared to do nothing at all.
    private func row(_ listRow: ModelListRow,
                     download: DownloadInfo?,
                     failure: DownloadsStore.DownloadFailure?) -> some View {
        ModelRowView(
            row: listRow,
            download: download,
            failure: failure,
            hasHFToken: catalog.hasHFToken,
            physicalMemory: physicalMemory,
            freeDiskBytes: telemetry.freeDiskBytes,
            actionCount: ModelActions.count(for: listRow.model),
            onDownload: { requestDownload(listRow.model) },
            onPause: { id in Task { await downloads.pause(id) } },
            onResume: { id in Task { await downloads.resume(id) } },
            onCancelDownload: { id in Task { await downloads.cancel(id) } },
            onDelete: { deleteTarget = listRow.model },
            onInstallRuntime: {
                Task { await catalog.installRuntime(listRow.model) }
            },
            onTogglePin: { enabled in
                Task { await catalog.setPin(listRow.model, enabled: enabled) }
            },
            onDismissFailure: { downloads.clearFailure(forModel: listRow.model.id) },
            isFavourite: catalog.isFavourite(listRow.model.id),
            onToggleFavourite: { catalog.toggleFavourite(listRow.model.id) },
            isInspected: inspectedId == listRow.model.id,
            // Clicking the row that is already open closes the rail: the same
            // gesture both ways, and the list gets its width back without
            // hunting for a close button.
            onInspect: {
                inspectedId = inspectedId == listRow.model.id
                    ? nil : listRow.model.id
            })
    }

    /// Looked up fresh on every read, so the rail follows a model through its
    /// own install: the bytes land, the catalog refetches, and the panel says
    /// "Installed: yes" without the user touching anything.
    private var inspectedModel: ModelInfo? {
        guard let inspectedId else { return nil }
        return catalog.model(id: inspectedId)
    }

    private func requestDownload(_ model: ModelInfo) {
        if catalog.acceptedLicenses.contains(model.id) {
            Task { await catalog.startDownload(model) }
        } else {
            licenseTarget = model
        }
    }

    // MARK: - Empty states

    @ViewBuilder
    private var placeholder: some View {
        switch catalog.readiness {
        case .pending(let detail):
            LoadingPlaceholder(title: "Loading models…", detail: detail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let message):
            CatalogNotice(title: "CAN'T LOAD THE CATALOG", message: message,
                          tone: Bench.Palette.dangerText)
        case .ready:
            CatalogNotice(title: "NO MODELS YET",
                          message: "The engine returned an empty catalog.",
                          tone: Bench.Palette.textFaint)
        }
    }

    /// Reached only when *nothing in the catalog* matches — a non-featured
    /// match keeps the list on screen with the "Show all" disclosure already
    /// counting it, so there is no "…but 12 others do" case left to explain.
    @ViewBuilder
    private var noMatches: some View {
        // Under a requirement the list is empty for a different reason, and
        // saying "no model fits your filters" would blame the user for a gap
        // in the catalog while offering a Clear button that changes nothing.
        if let requirement {
            CatalogNotice(title: "NOTHING CAN DO THIS YET",
                          message: requirement.emptyMessage,
                          tone: Bench.Palette.textFaint) {
                Button("Show all models") { self.requirement = nil }
                    .buttonStyle(.benchSecondary)
            }
        } else {
            CatalogNotice(title: "NO MODELS MATCH",
                          message: "No model fits the filters you picked.",
                          tone: Bench.Palette.textFaint) {
                Button("Clear filters", action: clearFilters)
                    .buttonStyle(.benchSecondary)
            }
        }
    }
}

// MARK: - Notice

/// The Bench version of an empty state: eyebrow, one sentence, and whatever
/// buttons would fix it. Not `ContentUnavailableView`, which paints itself in
/// system colours the rest of the window does not use.
struct CatalogNotice<Actions: View>: View {
    let title: String
    let message: String
    var tone: Color = Bench.Palette.textFaint
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 10) {
            Text(title).eyebrow(tone)
            Text(message)
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) { actions() }
                .padding(.top, 2)
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension CatalogNotice where Actions == EmptyView {
    init(title: String, message: String, tone: Color = Bench.Palette.textFaint) {
        self.init(title: title, message: message, tone: tone) { EmptyView() }
    }
}

// MARK: - License

/// Shown once, before the first download of a model, because the download is
/// made under the user's own acceptance of the licence — nothing is
/// redistributed by this app.
struct LicenseSheet: View {
    let model: ModelInfo
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("LICENSE · \(model.license.name.uppercased())").eyebrow()
                Text(model.displayName)
                    .font(Bench.Typo.inspectorTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
            }

            VStack(alignment: .leading, spacing: 9) {
                if !model.license.commercialUse {
                    noticeLine("Commercial use of the output is restricted.",
                               tone: Bench.Palette.warn)
                }
                if model.license.requiresHfToken {
                    noticeLine("Gated model — a Hugging Face token with access "
                               + "is required (Settings).",
                               tone: Bench.Palette.violet)
                }
                if let notes = model.notes {
                    Text(notes)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let urlString = model.license.url,
                   let url = URL(string: urlString) {
                    Button("Read the full license") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.plain)
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.accent)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .benchCard()

            Text("The model is downloaded from Hugging Face under your own "
                 + "acceptance of its license; nothing is redistributed by this app.")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.benchSecondary)
                Button("Accept & download") {
                    onAccept()
                    dismiss()
                }
                .buttonStyle(BenchPrimaryButtonStyle(size: .compact, glows: false))
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(Bench.Palette.panel)
    }

    private func noticeLine(_ text: String, tone: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(tone)
                .frame(width: 3).frame(maxHeight: .infinity)
            Text(text)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
