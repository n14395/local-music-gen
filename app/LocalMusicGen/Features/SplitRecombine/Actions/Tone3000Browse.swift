import SwiftUI
import UniformTypeIdentifiers

/// TONE3000 search for the capture picker: query the site's library, download
/// a model file, and it lands in the app's own capture library and in the
/// card's `nam_file` slot.
///
/// The user's `t3k_cs_…` secret key (Settings › Models) rides every request as
/// a plain Bearer; the app stores nothing but that key. Every row shows its
/// author and license because the per-capture terms are the author's, not this
/// app's — and those travel into the local library with the file, so a capture
/// downloaded a month ago still says whose it is.
@MainActor @Observable
final class Tone3000Store {
    struct Tone: Identifiable, Decodable {
        struct EmbeddedUser: Decodable {
            var username: String
        }

        var id: Int
        var title: String
        var user: EmbeddedUser
        var gear: String
        var license: String?
        var modelsCount: Int
    }

    struct Model: Identifiable, Decodable {
        var id: Int
        var name: String
        var modelUrl: String
        var size: String?
        var architectureVersion: String?
    }

    private struct Page<T: Decodable>: Decodable {
        var data: [T]
    }

    var results: [Tone] = []
    var searching = false
    var error: String?
    /// Models of the tone the user opened, keyed so rows can expand lazily.
    var models: [Int: [Model]] = [:]
    /// Model ids being fetched right now. A set rather than one id: a visit to
    /// this sheet is usually "collect the three rigs I want", and a single
    /// in-flight slot would have made that three round trips through a modal.
    var downloading: Set<Int> = []

    static var hasKey: Bool { Keychain.get(account: "tone3000-key") != nil }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func request(_ path: String,
                         query: [URLQueryItem] = []) -> URLRequest? {
        guard let key = Keychain.get(account: "tone3000-key") else {
            error = "Add your TONE3000 API key in Settings › Models first."
            return nil
        }
        var comps = URLComponents(
            string: "https://www.tone3000.com/api/v1/" + path)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return req
    }

    func search(_ text: String) async {
        guard let req = request("tones/search", query: [
            .init(name: "query", value: text),
            .init(name: "format", value: "nam"),
            .init(name: "page_size", value: "25"),
        ]) else { return }
        searching = true
        defer { searching = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                error = "TONE3000 refused the search — is the key a "
                    + "t3k_cs_… secret key?"
                return
            }
            results = try decoder.decode(Page<Tone>.self, from: data).data
            error = results.isEmpty ? "No capture matches that." : nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadModels(toneId: Int) async {
        guard models[toneId] == nil,
              let req = request("models", query: [
                  .init(name: "tone_id", value: String(toneId)),
              ]) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            models[toneId] = try decoder.decode(Page<Model>.self,
                                                from: data).data
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fetch one capture (the `model_url` needs the same Bearer auth as the
    /// API) into the app's capture library, with the tone's attribution
    /// attached, and hand back where it landed.
    ///
    /// It used to go to a temp file that lived exactly as long as the job did.
    /// Downloading the same capture again for every render was the wrong
    /// default for something the user chose deliberately.
    @discardableResult
    func download(_ model: Model, from tone: Tone?,
                  into library: ToneLibraryStore) async -> URL? {
        guard let key = Keychain.get(account: "tone3000-key"),
              let url = URL(string: model.modelUrl) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        downloading.insert(model.id)
        defer { downloading.remove(model.id) }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                error = "TONE3000 refused the download."
                return nil
            }
            // The tone names the gear and the licence; the model names the
            // particular capture of it. Both belong on the row.
            let title = tone.map { "\($0.title) — \(model.name)" } ?? model.name
            guard let saved = library.add(
                data: data, name: title, toneId: tone?.id, modelId: model.id,
                author: tone?.user.username, gear: tone?.gear,
                license: tone?.license) else {
                error = library.lastError ?? "Could not save the capture."
                return nil
            }
            return saved
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// The capture picker the re-amp card opens: what you already have first,
/// TONE3000's several hundred thousand second.
///
/// Downloaded-first is the whole point of the ordering. Re-amping is something
/// you do to eight stems in a session with the same rig, and the capture you
/// picked last time is the one you almost certainly want again — searching a
/// website for it every time was the old shape and it was backwards.
struct CapturePickerSheet: View {
    @Bindable var library: ToneLibraryStore
    /// The chosen capture's file and the name to show in the slot.
    let onPick: (URL, String) -> Void

    private enum Tab: Hashable { case downloaded, browse }

    @State private var tab: Tab = .downloaded
    @State private var store = Tone3000Store()
    @State private var query = ""
    @State private var opened: Int?
    @State private var importing = false
    @State private var confirmingRemoveAll = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            BenchSegmented(selection: $tab, options: [
                .init(value: .downloaded, label: "Downloaded",
                      detail: library.tones.isEmpty
                          ? nil : String(library.tones.count)),
                .init(value: .browse, label: "TONE3000"),
            ], fills: true)
                .padding(.horizontal, 18).padding(.bottom, 12)
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            switch tab {
            case .downloaded: downloadedTab
            case .browse: browseTab
            }
        }
        .frame(width: 540, height: 500)
        .background(Bench.Palette.panel)
        .task { library.reload() }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: Self.namTypes,
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { library.importFile(at: url) }
        }
    }

    /// `.nam` is JSON with a bespoke extension and no registered UTI, so the
    /// importer has to accept any file — the same reason the generic parameter
    /// row does for `_file` params.
    private static let namTypes: [UTType] = [.item]

    private var header: some View {
        HStack {
            Text("CHOOSE A CAPTURE").eyebrow()
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.bench(.quiet))
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 12)
    }

    // MARK: - Downloaded

    @ViewBuilder
    private var downloadedTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button("From a file…") { importing = true }
                    .buttonStyle(.benchSecondary)
                    .help("Copy a .nam from your Mac into the capture library "
                          + "— your own capture, or one downloaded in a "
                          + "browser. The original is left where it is.")
                Spacer(minLength: 0)
                if !library.tones.isEmpty {
                    Text(ByteFormat.compact(library.totalBytes))
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaint)
                    Button("Remove all…") { confirmingRemoveAll = true }
                        .buttonStyle(.bench(.quiet))
                }
            }
            if let error = library.lastError {
                ActionFootnote(text: error, tone: Bench.Palette.warn)
            }
            if library.tones.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(library.tones) { tone in
                            downloadedRow(tone)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert("Remove every capture?", isPresented: $confirmingRemoveAll) {
            Button("Cancel", role: .cancel) {}
            Button("Remove \(library.tones.count)", role: .destructive) {
                library.removeAll()
            }
        } message: {
            Text("Deletes \(library.tones.count) capture"
                 + (library.tones.count == 1 ? "" : "s")
                 + " (\(ByteFormat.compact(library.totalBytes))) from this Mac. "
                 + "Anything from TONE3000 can be downloaded again; captures "
                 + "you imported yourself cannot, unless you still have the "
                 + "original file.")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No captures yet")
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textSecondary)
            Text("Search TONE3000 in the next tab, or add a .nam file from "
                 + "this Mac. Captures are kept with your models, are counted "
                 + "in Settings ▸ Model library, and move with it — but "
                 + "clearing your models never removes them.")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func downloadedRow(_ tone: ToneLibraryStore.Tone) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tone.title)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(ActionFormat.join([
                    tone.attribution.isEmpty ? "imported" : tone.attribution,
                    Self.added.string(from: tone.addedAt),
                    ByteFormat.compact(tone.bytes),
                ]))
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [library.url(for: tone)])
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Bench.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            Button {
                library.remove(tone)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(Bench.Palette.textMuted)
            }
            .buttonStyle(.plain)
            .help("Delete this capture from the library")
            Button("Use this") {
                onPick(library.url(for: tone), tone.title)
                dismiss()
            }
            .buttonStyle(.benchSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.row,
                                     style: .continuous)
            .fill(Bench.Palette.well))
    }

    private static let added: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    // MARK: - TONE3000

    @ViewBuilder
    private var browseTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !Tone3000Store.hasKey {
                ActionFootnote(
                    text: "Add your TONE3000 API key (the t3k_cs_… secret "
                        + "key) in Settings › Models to search captures here.",
                    tone: Bench.Palette.warn)
            } else {
                HStack(spacing: 8) {
                    BenchTextField(text: $query,
                                   placeholder: "Amp, pedal or rig…")
                        .onSubmit { Task { await store.search(query) } }
                    Button(store.searching ? "Searching…" : "Search") {
                        Task { await store.search(query) }
                    }
                    .buttonStyle(.benchSecondary)
                    .disabled(store.searching || query.isEmpty)
                }
                if let error = store.error {
                    ActionFootnote(text: error, tone: Bench.Palette.warn)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.results) { tone in
                            toneRow(tone)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func toneRow(_ tone: Tone3000Store.Tone) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                opened = opened == tone.id ? nil : tone.id
                Task { await store.loadModels(toneId: tone.id) }
            } label: {
                HStack(spacing: 8) {
                    Text(tone.title)
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // Author + license: the capture's terms are the
                    // author's, and the row is where they belong.
                    Text(ActionFormat.join([
                        tone.user.username,
                        tone.gear.uppercased(),
                        tone.license?.uppercased(),
                    ]))
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaint)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(RoundedRectangle(
                    cornerRadius: Bench.Metrics.Radius.row,
                    style: .continuous)
                    .fill(opened == tone.id
                          ? Bench.Palette.accent.opacity(0.07) : .clear))
            }
            .buttonStyle(.plain)
            if opened == tone.id {
                if let models = store.models[tone.id] {
                    ForEach(models) { model in
                        modelRow(model, tone: tone)
                    }
                } else {
                    Text("Loading models…")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func modelRow(_ model: Tone3000Store.Model,
                          tone: Tone3000Store.Tone) -> some View {
        // Already here: the row selects the local copy rather than fetching
        // the same bytes a second time.
        let existing = library.tones.first { $0.modelId == model.id }
        return HStack(spacing: 8) {
            Text(model.name)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .lineLimit(1)
            if let size = model.size {
                Text(size.uppercased())
                    .font(Bench.Typo.mono(9))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            if existing != nil {
                BenchBadge("DOWNLOADED")
            }
            Spacer(minLength: 8)
            // Downloading and choosing are two decisions, so they are two
            // buttons in sequence rather than one that does both. Fetching a
            // capture leaves the sheet open — collecting several in one visit
            // is the normal way to use this — and only once a capture is here
            // does the row offer to put it in the slot, which is the click
            // that closes the sheet.
            Button(buttonLabel(model, existing: existing)) {
                if let existing {
                    onPick(library.url(for: existing), existing.title)
                    dismiss()
                    return
                }
                Task { await store.download(model, from: tone, into: library) }
            }
            .buttonStyle(.benchSecondary)
            // Per row, not per sheet: one fetch in flight must not freeze the
            // buttons on every other capture.
            .disabled(store.downloading.contains(model.id))
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 3)
    }

    private func buttonLabel(_ model: Tone3000Store.Model,
                             existing: ToneLibraryStore.Tone?) -> String {
        if store.downloading.contains(model.id) { return "Fetching…" }
        return existing == nil ? "Download" : "Use this"
    }
}
