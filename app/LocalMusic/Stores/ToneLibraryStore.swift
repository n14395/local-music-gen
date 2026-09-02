import Foundation
import Observation

/// The captures kept on this Mac: `.nam` files plus what is known about them.
///
/// They live in `tone3000-tones/` inside the engine's auxiliary root, beside
/// the other weights nobody downloads from Hugging Face. That is a deliberate
/// choice with two consequences worth naming:
///
///   * They are counted in Settings ▸ Model library and they move when the
///     library folder moves, which is what anyone would expect of several
///     hundred megabytes of amp captures.
///   * They are the one thing in that root a clear will not take
///     (`AUX_KEPT_DIRS`). Re-downloading a capture needs the user's own API
///     key and, worse, needs them to remember which of TONE3000's several
///     hundred thousand they had chosen. Removing them is offered here, where
///     the collection is, and nowhere else.
///
/// The index beside the files is what makes a row read as gear rather than as
/// a filename — and what keeps the author's licence attached to their work,
/// which the browse sheet has always been careful about. It is a cache of
/// metadata, never the source of truth for what exists: the files are, and
/// `reload()` reconciles the two in both directions.
@MainActor @Observable
final class ToneLibraryStore {
    /// One capture on disk. `id` is the file name, which is what makes the
    /// index self-healing: a row whose file has gone is dropped, and a file
    /// with no row is adopted under whatever its name says.
    struct Tone: Identifiable, Codable, Equatable {
        var fileName: String
        var title: String
        var author: String?
        var gear: String?
        var license: String?
        /// TONE3000's ids, when it came from there. `modelId` is what the
        /// browse tab matches against to show a capture as already here.
        var toneId: Int?
        var modelId: Int?
        var addedAt: Date
        var bytes: Int64

        var id: String { fileName }
        var isLocal: Bool { modelId == nil }

        /// Author · gear · licence, as the browse rows print it.
        var attribution: String {
            [author, gear?.uppercased(), license?.uppercased()]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
    }

    private(set) var tones: [Tone] = []
    var lastError: String?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Where

    var directory: URL {
        settings.auxCacheURL.appendingPathComponent("tone3000-tones",
                                                    isDirectory: true)
    }

    private var indexURL: URL {
        directory.appendingPathComponent("tones.json")
    }

    var totalBytes: Int64 { tones.reduce(0) { $0 + $1.bytes } }

    /// Model ids already here, so the browse tab can say so rather than
    /// offering to fetch the same file twice.
    var downloadedModelIds: Set<Int> {
        Set(tones.compactMap(\.modelId))
    }

    // MARK: - Reading

    /// Read the index, then reconcile it against the directory: files that
    /// vanished are dropped, files that appeared (a copy made in the Finder,
    /// an interrupted write from an older build) are adopted. The directory
    /// wins every disagreement — it is the thing the re-amp job actually
    /// reads.
    func reload() {
        let fm = FileManager.default
        var known: [String: Tone] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? Self.decoder.decode([Tone].self, from: data) {
            known = Dictionary(decoded.map { ($0.fileName, $0) },
                               uniquingKeysWith: { a, _ in a })
        }
        let files = (try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey,
                                                        .contentModificationDateKey]))
            ?? []
        var found: [Tone] = []
        for url in files where url.pathExtension.lowercased() == "nam" {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                           .contentModificationDateKey])
            let bytes = Int64(values?.fileSize ?? 0)
            if var tone = known[url.lastPathComponent] {
                tone.bytes = bytes          // a file can be replaced in place
                found.append(tone)
            } else {
                found.append(Tone(
                    fileName: url.lastPathComponent,
                    title: url.deletingPathExtension().lastPathComponent,
                    addedAt: values?.contentModificationDate ?? Date(),
                    bytes: bytes))
            }
        }
        tones = found.sorted { $0.addedAt > $1.addedAt }
        // Only when it actually differs: this runs on every sheet open, and
        // rewriting an unchanged index would touch the file for nothing.
        if found.count != known.count
            || found.contains(where: { known[$0.fileName] == nil }) {
            writeIndex()
        }
    }

    // MARK: - Adding

    /// Save a capture fetched from TONE3000. Returns its on-disk URL.
    @discardableResult
    func add(data: Data, name: String, toneId: Int?, modelId: Int?,
             author: String?, gear: String?, license: String?) -> URL? {
        let fileName = uniqueFileName(for: name, modelId: modelId)
        guard let url = write(data: data, fileName: fileName) else { return nil }
        tones.insert(Tone(fileName: fileName, title: name, author: author,
                          gear: gear, license: license, toneId: toneId,
                          modelId: modelId, addedAt: Date(),
                          bytes: Int64(data.count)), at: 0)
        writeIndex()
        return url
    }

    /// Import a `.nam` the user picked off their own disk. Their file stays
    /// where it is; this takes a copy, so the capture survives the folder
    /// being tidied and shows up in the list like any other.
    @discardableResult
    func importFile(at source: URL) -> URL? {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: source) else {
            lastError = "Could not read \(source.lastPathComponent)."
            return nil
        }
        let title = source.deletingPathExtension().lastPathComponent
        return add(data: data, name: title, toneId: nil, modelId: nil,
                   author: nil, gear: nil, license: nil)
    }

    func url(for tone: Tone) -> URL {
        directory.appendingPathComponent(tone.fileName)
    }

    // MARK: - Removing

    func remove(_ tone: Tone) {
        try? FileManager.default.removeItem(at: url(for: tone))
        tones.removeAll { $0.id == tone.id }
        writeIndex()
    }

    func removeAll() {
        for tone in tones {
            try? FileManager.default.removeItem(at: url(for: tone))
        }
        tones = []
        writeIndex()
    }

    // MARK: - Disk

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private func write(data: Data, fileName: String) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let dest = directory.appendingPathComponent(fileName)
            // Through a temp file: a capture half-written by a dropped
            // connection would parse as "not a readable .nam file" mid-render,
            // which is a confusing way to learn the download failed.
            let tmp = dest.appendingPathExtension("part")
            try data.write(to: tmp)
            _ = try? fm.removeItem(at: dest)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            lastError = "Could not save the capture: \(error.localizedDescription)"
            return nil
        }
    }

    private func writeIndex() {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try Self.encoder.encode(tones).write(to: indexURL)
        } catch {
            // The files are the library; an index that failed to write costs
            // the metadata on the next launch, not the captures.
            lastError = "Could not update the capture list: "
                + error.localizedDescription
        }
    }

    /// A file name that is safe, recognisable, and does not collide. TONE3000
    /// captures carry their model id so the same one downloaded twice lands on
    /// the same file rather than accumulating copies.
    private func uniqueFileName(for title: String, modelId: Int?) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " -_.()"))
        var safe = String(title.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }).trimmingCharacters(in: .whitespaces)
        if safe.isEmpty { safe = "capture" }
        safe = String(safe.prefix(60))
        if let modelId {
            return "t3k-\(modelId)-\(safe).nam"
        }
        var candidate = safe + ".nam"
        var n = 2
        let existing = Set(tones.map(\.fileName))
        while existing.contains(candidate) {
            candidate = "\(safe) (\(n)).nam"
            n += 1
        }
        return candidate
    }
}
