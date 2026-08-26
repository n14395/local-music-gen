import SwiftUI

/// TONE3000 browse for the re-amp card: search the capture library, pick a
/// model file, and it lands in the card's `nam_file` slot — no browser trip.
///
/// The user's `t3k_cs_…` secret key (Settings › Models) rides every request
/// as a plain Bearer; the app stores nothing but that key. Downloads go to a
/// temp file that lives exactly as long as the job needs it — captures are
/// not collected into a library, and each row shows its author and license
/// because the per-capture terms are the author's, not this app's.
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
    var downloading: Int?

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

    /// Fetch one capture into a temp .nam file (the `model_url` needs the
    /// same Bearer auth as the API) and hand back its URL.
    func download(_ model: Model) async -> URL? {
        guard let key = Keychain.get(account: "tone3000-key"),
              let url = URL(string: model.modelUrl) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        downloading = model.id
        defer { downloading = nil }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                error = "TONE3000 refused the download."
                return nil
            }
            let safe = model.name.replacingOccurrences(of: "/", with: "-")
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("t3k-\(model.id)-\(safe)")
                .appendingPathExtension("nam")
            try data.write(to: dest)
            return dest
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

/// The browse sheet the re-amp card opens. Picking a model downloads it and
/// hands the temp file back through `onPick`.
struct Tone3000BrowseSheet: View {
    let onPick: (URL) -> Void
    let onOpenSettings: (() -> Void)?

    @State private var store = Tone3000Store()
    @State private var query = ""
    @State private var opened: Int?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("BROWSE TONE3000").eyebrow()
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bench(.quiet))
            }
            if !Tone3000Store.hasKey {
                ActionFootnote(
                    text: "Add your TONE3000 API key (the t3k_cs_… secret "
                        + "key) in Settings › Models to browse captures "
                        + "here.",
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
        .frame(width: 520, height: 480)
        .background(Bench.Palette.panel)
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
                        modelRow(model)
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

    private func modelRow(_ model: Tone3000Store.Model) -> some View {
        HStack(spacing: 8) {
            Text(model.name)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textSecondary)
                .lineLimit(1)
            if let size = model.size {
                Text(size.uppercased())
                    .font(Bench.Typo.mono(9))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            Spacer(minLength: 8)
            Button(store.downloading == model.id ? "Fetching…" : "Use this") {
                Task {
                    if let url = await store.download(model) {
                        onPick(url)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.benchSecondary)
            .disabled(store.downloading != nil)
        }
        .padding(.leading, 20).padding(.trailing, 10).padding(.vertical, 3)
    }
}
