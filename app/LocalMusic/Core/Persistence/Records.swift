import Foundation
import GRDB

/// Where a song came from — the one axis the library's scopes are cut along.
///
/// Stored as a string so the column stays readable in a SQL browser and an
/// older build never chokes on a value it doesn't know; this enum is the typed
/// reading of it, so a scope filter can't be spelled wrong.
enum SongOrigin: String, CaseIterable, Codable, Sendable {
    case generated, imported, recombined

    /// How the scope, the picker tab and the empty state name this kind —
    /// a collection of them.
    var title: String {
        switch self {
        case .generated: "Generated"
        case .imported: "Imported"
        case .recombined: "Renders"
        }
    }

    /// How one row of this kind marks itself. Singular, because a row is one
    /// thing: "RENDER · 3:31", not "RENDERS · 3:31".
    var rowLabel: String {
        self == .recombined ? "Render" : title
    }
}

/// One song in the library, whatever made it. `fileName` is relative to
/// StoragePaths.libraryAudio so the library survives a moved home directory.
struct SongRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "song"

    var id: String
    var title: String
    var prompt: String
    var lyrics: String?
    var modelId: String
    var modelName: String
    var groupId: String?
    var paramsJSON: String
    var durationS: Double
    var sampleRate: Int
    var fileName: String
    var seedUsed: Int64?
    var createdAt: Date
    var rating: Int          // 0–5; 0 = unrated
    var notes: String
    var favorite: Bool
    var origin: String = "generated"   // generated | imported | recombined
    var recipeId: String?
    /// Performer, read from the file's own tags at import. Defaulted, so rows
    /// written before the v4 migration decode cleanly.
    var artist: String?
    /// The Editor's edit program (an `EditDocument`), nil until one exists.
    /// Optional so rows written before the v5 migration decode cleanly.
    var editsJSON: String?
    /// When that program was last applied to the file. nil while the program
    /// is only pending — the Library badge reads this, not `editsJSON`.
    var editedAt: Date?
    /// The stashed pristine original's file name, written when the backup is
    /// stashed (v6). Optional, and the getter below falls back to the old
    /// derivation, so rows written before it still resolve.
    var backupFileName: String?

    /// The typed `origin`. An unrecognised value reads as `.generated` rather
    /// than crashing or vanishing from every scope — a row is always somewhere.
    var originKind: SongOrigin { SongOrigin(rawValue: origin) ?? .generated }

    /// What a row's meta line leads with: who performed an imported track,
    /// otherwise the model that made it. An import with no tags falls back to
    /// `modelName` ("Imported"), which is still true and still reads.
    var sourceLabel: String {
        if let artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty {
            return artist
        }
        return modelName
    }

    var fileURL: URL { StoragePaths.libraryAudio.appendingPathComponent(fileName) }
    var waveformURL: URL {
        StoragePaths.libraryWaveforms.appendingPathComponent(id + ".peaks")
    }
    /// Where the pristine pre-edit original is stashed. The stored name wins:
    /// the live file is renamed by an apply (mp3 → wav) and the backup is
    /// not, so deriving the path from `fileName` loses it.
    var backupURL: URL {
        StoragePaths.libraryBackups.appendingPathComponent(
            backupFileName ?? StoragePaths.backupName(id: id,
                                                      fileName: fileName))
    }

    /// Default name for the nth generated track: `track007`. Padded to three
    /// digits so names sort lexically, and left to grow past 999 rather than
    /// wrapping.
    static func trackName(number: Int) -> String {
        String(format: "track%03d", number)
    }

    /// The names for one submission's takes, under the default `trackNNN` name.
    ///
    /// Takes asked for together are one thing you made, so they share a number
    /// and differ by a trailing letter — `track042a`, `track042b`, `track042c`.
    /// A single take has nothing to distinguish itself from, so it stays plain
    /// `track042`; a suffix there would only ever be `a`.
    static func trackNames(number: Int, count: Int) -> [String] {
        takeNames(base: trackName(number: number), count: count)
    }

    /// The names for one submission's takes under any base name.
    ///
    /// The letter attaches differently depending on what it is attaching to.
    /// `track042` is an identifier, and its letter belongs inside it —
    /// `track042a` — where it also stays parseable by `trackNumber(in:)`. A
    /// name someone typed is prose, and running a letter onto the end of it
    /// makes a different word: "Warehouse jam" would become "Warehouse jama".
    /// So a typed name takes its letter in brackets: `Warehouse jam (a)`.
    ///
    /// An empty or whitespace-only base is not a name; callers pass the
    /// `trackNNN` default instead of asking this to invent one.
    static func takeNames(base: String, count: Int) -> [String] {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard count > 1 else { return [trimmed] }
        let isDefaultForm = trackNumber(in: trimmed) != nil
        return (0..<count).map { take in
            isDefaultForm ? trimmed + takeSuffix(take)
                          : "\(trimmed) (\(takeSuffix(take)))"
        }
    }

    /// `a`, `b`, … `z`, `aa`, `ab` … for take 0, 1, … — bijective base 26, so
    /// no two takes of a batch can ever land on the same name. Models cap
    /// takes far below 26 today; this is here so that stays a catalog number
    /// and not a correctness constraint.
    static func takeSuffix(_ take: Int) -> String {
        var remaining = max(0, take)
        var suffix = ""
        repeat {
            suffix = String(UnicodeScalar(UInt8(97 + remaining % 26))) + suffix
            remaining = remaining / 26 - 1
        } while remaining >= 0
        return suffix
    }

    /// The number in a default track name, or nil for anything the user (or an
    /// import) named themselves.
    static func trackNumber(in title: String) -> Int? {
        guard title.hasPrefix("track") else { return nil }
        var digits = title.dropFirst("track".count)
        // The take letters come off before the number is read. Without this
        // `track042a` parses as nothing, the high-water mark below it stays at
        // 41, and the *next* batch is numbered 42 all over again — two batches
        // sharing a number is exactly what the letters exist to prevent.
        while let last = digits.last, last.isASCII, last.isLowercase {
            digits = digits.dropLast()
        }
        guard !digits.isEmpty, digits.allSatisfy(\.isWholeNumber) else { return nil }
        return Int(digits)
    }
}

/// One extracted component of a song (stem, notes, features). `fileName` is
/// relative to StoragePaths.libraryParts, keeping its real extension.
struct PartRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "part"

    var id: String
    var songId: String
    var kind: String          // dot-namespaced taxonomy: "stem.vocals", "notes.piano"
    var name: String
    var fileName: String
    var format: String        // wav | midi | json
    var previewFileName: String?
    var modelId: String
    var modelName: String
    var jobId: String?
    var splitParamsJSON: String
    var durationS: Double?
    var sampleRate: Int?
    var createdAt: Date
    /// Defaulted, so rows written before the v3 migration decode cleanly.
    var favorite: Bool = false
    /// 0–5; 0 = unrated, as on `SongRecord`. A stem is a thing you keep or
    /// discard on its own merits — the vocal take that carried the song, the
    /// drum bed that did not — so it gets the same judgement a track does
    /// (v9).
    var rating: Int = 0
    /// The Editor's edit program — stems are editable too (v5).
    var editsJSON: String?
    var editedAt: Date?
    /// The stashed pristine stem's file name (v6).
    var backupFileName: String?

    var fileURL: URL { StoragePaths.libraryParts.appendingPathComponent(fileName) }
    /// Same convention as a song's: the stored name wins over the derivation.
    var backupURL: URL {
        StoragePaths.libraryBackups.appendingPathComponent(
            backupFileName ?? StoragePaths.backupName(id: id,
                                                      fileName: fileName))
    }
    var previewURL: URL? {
        previewFileName.map { StoragePaths.libraryParts.appendingPathComponent($0) }
    }
    var waveformURL: URL {
        StoragePaths.libraryWaveforms.appendingPathComponent(id + ".peaks")
    }
    /// What the waveform/audition player should read: the payload for audio
    /// parts, the pre-rendered preview for MIDI parts.
    var auditionURL: URL? { format == "wav" ? fileURL : previewURL }
}

/// Musical analysis attachment for a song or part (ownerId = its id). Beat
/// grids, downbeats, and structure segments live in `analysisJSON`; the scalar
/// columns exist for filtering/sorting.
struct AnalysisRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "analysis"

    var ownerId: String
    var ownerType: String     // "song" | "part"
    var bpm: Double?
    var keyName: String?
    var camelot: String?
    var analysisJSON: String
    var modelId: String
    var createdAt: Date
}

/// Ingredient row for a recombined song: which part filled which slot, with the
/// placement transform a future timeline view renders as a clip.
struct SongIngredientRecord: Codable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "songIngredient"

    var songId: String
    var slotId: String
    var partId: String?
    var sourceSongTitle: String
    var transformJSON: String
}

/// Decoded shape of an "analysis" artifact JSON (engine wire: snake_case via
/// BackendClient.decoder). Every field tolerates absence — analyzers evolve.
struct AnalysisPayload: Codable, Sendable {
    var tempoBpm: Double?
    var beats: [Double]?
    var downbeats: [Double]?
    var key: String?
    var camelot: String?
    var keyConfidence: Double?
    var sections: [Section]?
    var lufs: Double?
    var chroma: [[Int]]?          // beat-synchronous, 0–255 quantized (v2)
    var bandEnergy: [Double]?     // 8 octave bands, sums to 1 (v2)
    var clap: [Double]?           // 512-dim unit CLAP timbre embedding (v3)
    var durationS: Double?
    var sampleRate: Int?

    struct Section: Codable, Sendable, Equatable {
        var startS: Double
        var endS: Double
        var group: String?
        var label: String?
    }
}

struct TagRecord: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tag"
    var id: String { name }
    var name: String
}

struct SongTagRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "songTag"
    var songId: String
    var tagName: String
}
