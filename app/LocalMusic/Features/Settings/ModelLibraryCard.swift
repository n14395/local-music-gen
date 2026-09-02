import AppKit
import SwiftUI

/// The model library group at the top of Settings ▸ Models & Downloads.
///
/// Everything here is scoped through the app's own catalog, and the card says
/// so repeatedly, because the default folder is `~/.cache/huggingface` — shared
/// with every other Hugging Face tool on the Mac. Two consequences shape the
/// whole design:
///
///   * The size we report is *our* models, which will not match what the Finder
///     says about the folder. So the other tools' share is printed beside it
///     rather than left as an unexplained discrepancy.
///   * Clear and Move are destructive against a folder we do not own. Both go
///     through a sheet that names every repository first, and both say louder
///     things when the folder is the shared default, where another tool may be
///     relying on the very blobs we are about to remove.
struct ModelLibraryCard: View {
    let env: AppEnvironment

    /// Everything the relocate sheet needs, in ONE piece of state.
    ///
    /// It used to be a `Bool` plus a separate `URL?`, presented with
    /// `.sheet(isPresented:)` and unwrapped inside the content closure. Both
    /// are set in the instant `NSOpenPanel.runModal()` returns — an AppKit
    /// modal run loop unwinding into a SwiftUI update — and the presentation
    /// could be processed against a self whose URL was still nil, leaving the
    /// closure to build an `EmptyView`: a sheet that opens as an empty grey
    /// box. `.sheet(item:)` hands the value to the closure as a parameter,
    /// so the data cannot be missing at the moment the content is built.
    struct RelocateRequest: Identifiable {
        let destination: URL
        let info: LibraryInfo
        var id: String { destination.path }
    }

    @State private var relocateRequest: RelocateRequest?
    @State private var clearing = false
    @State private var showingReport = false

    private var store: ModelLibraryStore { env.modelLibrary }
    private var info: LibraryInfo? { store.info }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("MODEL LIBRARY").eyebrow()
            folderRow
            if let caution = store.volume.caution { banner(caution, tone: .warn) }
            if info != nil {
                Divider().overlay(Bench.Palette.hairline)
                sizeRows
                usageBar
                if isTight { banner(tightMessage, tone: .warn) }
            }
            if let op = store.operation, op.isRunning {
                Divider().overlay(Bench.Palette.hairline)
                operationRow(op)
            } else {
                actionRow
            }
            if let error = store.lastError { banner(error, tone: .danger) }
            caption("Where model weights are kept. Sizes and every action here "
                    + "cover only the models in this app's catalog — anything "
                    + "else in the folder is left alone. Weights the app "
                    + "downloads outside this folder are counted with it, and "
                    + "travel with it when it moves.")
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
        .task { await store.refresh() }
        .sheet(item: $relocateRequest) { request in
            LibraryRelocateSheet(info: request.info,
                                 destination: request.destination) {
                disposition in
                Task { await beginRelocate(to: request.destination,
                                           disposition: disposition) }
            }
        }
        .sheet(isPresented: $clearing) {
            if let info {
                LibraryClearSheet(info: info) { scope in
                    Task { await store.clear(scope: scope) }
                }
            }
        }
        .sheet(isPresented: $showingReport) {
            if let report = store.verifyReport {
                LibraryVerifySheet(report: report)
            }
        }
    }

    // MARK: - Folder

    private var folderRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            BenchInfoRow(label: "Folder", labelWidth: 86) {
                HStack(spacing: 8) {
                    Text(info?.path ?? "Reading the library…")
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    // Worth showing: the first read walks every one of our
                    // repository directories, which on a full library is tens
                    // of thousands of stats and visibly not instant.
                    if store.isRefreshing { BenchSpinner(size: 11) }
                }
            }
            HStack(spacing: 8) {
                if info?.isDefault == true {
                    BenchBadge("SHARED HUGGING FACE CACHE")
                }
                if let name = store.volume.name, store.volume.isRemovable {
                    BenchBadge(name.uppercased(), tone: .warn)
                }
                Spacer(minLength: 0)
                Button("Reveal") {
                    guard let url = info?.url else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.bench(.quiet))
                .disabled(info == nil)
            }
        }
    }

    // MARK: - Sizes

    @ViewBuilder
    private var sizeRows: some View {
        if let info {
            BenchInfoRow(label: "This app", labelWidth: 86) {
                HStack(spacing: 8) {
                    Text(ByteFormat.gb(info.bytes))
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(Bench.Palette.textPrimary)
                    Text(modelSummary(info))
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                }
            }
            if info.otherRootBytes > 0 {
                BenchInfoRow(label: "Also ours", labelWidth: 86) {
                    HStack(spacing: 8) {
                        Text(ByteFormat.gb(info.otherRootBytes))
                            .font(Bench.Typo.mono(12))
                            .foregroundStyle(Bench.Palette.textPrimary)
                        Text("separators, timbre models, soundfonts and other "
                             + "weights the app fetches directly — kept "
                             + "outside this folder, and moved with it")
                            .font(Bench.Typo.caption)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if info.foreignBytes > 0 {
                BenchInfoRow(label: "Other tools", labelWidth: 86) {
                    HStack(spacing: 8) {
                        Text(ByteFormat.gb(info.foreignBytes))
                            .font(Bench.Typo.mono(12))
                            .foregroundStyle(Bench.Palette.textSecondary)
                        Text("models in this folder that are not ours — never "
                             + "counted, moved or removed")
                            .font(Bench.Typo.caption)
                            .foregroundStyle(Bench.Palette.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if let free = info.diskFreeBytes {
                BenchInfoRow(label: "Free space", labelWidth: 86) {
                    Text(info.diskTotalBytes.map {
                        "\(ByteFormat.gb(free)) of \(ByteFormat.gb($0))"
                    } ?? ByteFormat.gb(free))
                        .font(Bench.Typo.mono(12))
                        .foregroundStyle(isTight ? Bench.Palette.warn
                                                 : Bench.Palette.textPrimary)
                }
            }
        }
    }

    private func modelSummary(_ info: LibraryInfo) -> String {
        var parts = ["\(info.modelCount) model\(info.modelCount == 1 ? "" : "s")"]
        if info.partialCount > 0 {
            parts.append("\(ByteFormat.gb(info.partialBytes)) unfinished")
        }
        return "(" + parts.joined(separator: " · ") + ")"
    }

    /// Ours · everyone else's · free, on the disk the library sits on. The
    /// middle segment is why this bar exists: it is the visible answer to "why
    /// is this folder bigger than the number above it".
    ///
    /// "Ours" is `totalBytes`, not `bytes`: the auxiliary root is on this disk
    /// too whenever it sits inside the library folder, and a bar that only
    /// drew the Hugging Face share would under-report the app by gigabytes.
    @ViewBuilder
    private var usageBar: some View {
        if let info, let total = info.diskTotalBytes, total > 0 {
            BenchSplitBar(segments: [
                (Double(info.totalBytes) / Double(total), Bench.Palette.accent),
                (Double(info.foreignBytes) / Double(total),
                 Bench.Palette.accent.opacity(0.35)),
            ], height: 4)
        }
    }

    private var largestCatalogModel: Int64? {
        env.catalog.models.map(\.sizeBytes).max()
    }

    private var isTight: Bool {
        store.isTightOnSpace(largestModelBytes: largestCatalogModel)
    }

    private var tightMessage: String {
        let free = info?.diskFreeBytes ?? 0
        return "Only \(ByteFormat.gb(free)) free on this disk — less than the "
            + "largest model in the catalog needs. Downloads will fail part-way "
            + "rather than being refused up front."
    }

    // MARK: - Actions

    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Change folder…", action: chooseFolder)
                    .buttonStyle(.benchSecondary)
                Button(store.isVerifying ? "Checking…" : "Verify library") {
                    Task {
                        await store.verify()
                        showingReport = store.verifyReport != nil
                    }
                }
                .buttonStyle(.bench(.quiet))
                .disabled(store.isVerifying)
                if let info, info.partialCount > 0 {
                    Button("Clean up unfinished") {
                        Task { await store.clear(scope: "partial") }
                    }
                    .buttonStyle(.bench(.quiet))
                    .help("Remove \(ByteFormat.gb(info.partialBytes)) of "
                          + "interrupted downloads. Finished models are kept.")
                }
                Spacer(minLength: 0)
            }
            Button("Clear all models…") { clearing = true }
                .buttonStyle(.bench(.destructive))
                .disabled(info.map { $0.totalBytes == 0 } ?? true)
                .opacity((info?.totalBytes ?? 0) == 0 ? 0.45 : 1)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose where LocalMusic keeps model weights."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let info, url.path != info.path else { return }
        relocateRequest = RelocateRequest(destination: url, info: info)
    }

    /// The engine reads HF_HOME once, at launch. So the files move first, then
    /// the preference changes, then the engine comes back pointing at the new
    /// folder — in that order, because a preference applied before the move
    /// would leave every model reading as "not downloaded" for the length of
    /// the copy.
    private func beginRelocate(to url: URL, disposition: String) async {
        await store.relocate(to: url.path, disposition: disposition)
    }

    // MARK: - Running operation

    private func operationRow(_ op: LibraryOperation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                BenchSpinner(size: 13)
                Text(op.message.isEmpty ? "Working…" : op.message)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 8)
                if op.bytesTotal > 0 {
                    Text("\(ByteFormat.gb(op.bytesDone)) of "
                         + ByteFormat.gb(op.bytesTotal))
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                Button("Stop") { Task { await store.cancelOperation() } }
                    .buttonStyle(.bench(.quiet))
            }
            BenchProgressBar(fraction: op.fraction ?? 0)
            caption(op.mode == "relocate"
                    ? "Moving a library across disks is a copy — it takes as "
                      + "long as the bytes do. Stopping leaves whole models on "
                      + "one side or the other, never half of one."
                    : "Removing models from the library folder.")
        }
    }

    // MARK: - Bits

    private enum Tone { case warn, danger }

    private func banner(_ text: String, tone: Tone) -> some View {
        let color = tone == .warn ? Bench.Palette.warn : Bench.Palette.danger
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: tone == .warn ? "exclamationmark.triangle"
                                            : "exclamationmark.octagon")
                .font(.system(size: 11))
            Text(text)
                .font(Bench.Typo.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: color.opacity(0.08), stroke: color.opacity(0.22))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared sheet furniture

/// The list of repositories an action is about to touch, by name and size.
///
/// Present in both destructive sheets and not summarised away, because the
/// folder may be shared: "12 repositories (31 GB)" is not enough for someone
/// deciding whether the thing about to be deleted is also the thing another
/// project on this Mac depends on.
struct LibraryRepoList: View {
    let repos: [LibraryRepo]
    var limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(repos.prefix(limit)) { repo in
                HStack(spacing: 8) {
                    Text(repo.repoId)
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if repo.isPartial {
                        BenchBadge("UNFINISHED", tone: .warn)
                    }
                    Spacer(minLength: 8)
                    Text(ByteFormat.gb(repo.bytes))
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
            }
            if repos.count > limit {
                Text("and \(repos.count - limit) more")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.well)
    }
}

/// The same list for the roots we own outright — auxiliary caches and
/// ModelScope repos. They have no installed/partial distinction to draw, so
/// this is `LibraryRepoList` minus the badge rather than a variant of it.
struct LibraryDirList: View {
    let dirs: [LibraryRootDir]
    var limit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(dirs.prefix(limit)) { dir in
                HStack(spacing: 8) {
                    Text(dir.name)
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Text(ByteFormat.gb(dir.bytes))
                        .font(Bench.Typo.mono(11))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
            }
            if dirs.count > limit {
                Text("and \(dirs.count - limit) more")
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.well)
    }
}

/// The extra sentence a shared folder earns. We can see which repositories our
/// catalog names; we cannot see whether anything else on this Mac is using the
/// same cached blobs, and the honest thing is to say that rather than to guess.
struct SharedFolderWarning: View {
    let verb: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 11))
            Text("This is the Hugging Face cache shared with everything else on "
                 + "this Mac. These repositories are ours to \(verb), but other "
                 + "tools may be using the same downloaded files — and there is "
                 + "no way for this app to tell. Anything relying on them will "
                 + "re-download.")
                .font(Bench.Typo.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Bench.Palette.warn)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard(fill: Bench.Palette.warn.opacity(0.08),
                   stroke: Bench.Palette.warn.opacity(0.22))
    }
}
