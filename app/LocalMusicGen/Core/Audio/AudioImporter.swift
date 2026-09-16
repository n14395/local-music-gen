import AVFoundation
import Foundation

/// Imports external audio files into the library: formats both the app
/// (AVFoundation) and the engine (libsndfile) read are copied as-is; anything
/// else AVFoundation can decode (m4a/aac/…) is transcoded to WAV so the stored
/// file is always engine-consumable.
actor AudioImporter {
    static let shared = AudioImporter()

    struct Imported: Sendable {
        let fileName: String
        let durationS: Double
        let sampleRate: Int
        /// From the file's own tags; nil when it carries none (or when the
        /// container is one AVFoundation can't read, e.g. ogg).
        var title: String?
        var artist: String?
    }

    private static let passthroughExtensions: Set<String> = [
        "wav", "flac", "mp3", "ogg", "aiff", "aif",
    ]

    func importFile(at source: URL, songId: String,
                    into directory: URL) async throws -> Imported {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        // Always read the tags off the source. The transcode below writes bare
        // PCM, so asking the destination would lose the artist on exactly the
        // formats (m4a/aac) most likely to have one.
        let tags = await Self.tags(of: source)
        let ext = source.pathExtension.lowercased()
        if Self.passthroughExtensions.contains(ext) {
            let dest = directory.appendingPathComponent("\(songId).\(ext)")
            let preexisting = FileManager.default.fileExists(atPath: dest.path)
            do {
                try FileManager.default.copyItem(at: source, to: dest)
            } catch {
                // `copyItem` can fail part-way — a full disk, a source that
                // vanished — and the caller only reports the error, it never
                // inserts a row. Nothing prunes Library/Audio, so the stub
                // would sit there forever. Only what this call created is
                // taken back: a file already at `dest` belongs to a row.
                if !preexisting { try? FileManager.default.removeItem(at: dest) }
                throw error
            }
            let meta = Self.metadata(of: dest)
            return Imported(fileName: dest.lastPathComponent,
                            durationS: meta.durationS,
                            sampleRate: meta.sampleRate,
                            title: tags.title, artist: tags.artist)
        }
        let src = try AVAudioFile(forReading: source)
        let dest = directory.appendingPathComponent("\(songId).wav")
        // Same reason as the copy above: `AVAudioFile(forWriting:)` creates
        // the file and the read/write loop below can throw at any point — a
        // truncated m4a, a disk that filled — which used to leave a partial
        // WAV nothing referenced and nothing ever deleted.
        let preexistingWav = FileManager.default.fileExists(atPath: dest.path)
        var completed = false
        defer {
            if !completed, !preexistingWav {
                try? FileManager.default.removeItem(at: dest)
            }
        }
        let format = src.processingFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let dst = try AVAudioFile(forWriting: dest, settings: settings,
                                  commonFormat: format.commonFormat,
                                  interleaved: format.isInterleaved)
        let chunk = AVAudioFrameCount(65536)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: chunk) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while src.framePosition < src.length {
            try src.read(into: buffer, frameCount: chunk)
            if buffer.frameLength == 0 { break }
            try dst.write(from: buffer)
        }
        completed = true
        return Imported(fileName: dest.lastPathComponent,
                        durationS: Double(src.length) / format.sampleRate,
                        sampleRate: Int(format.sampleRate),
                        title: tags.title, artist: tags.artist)
    }

    /// Title and artist from the container's common metadata — the one mapping
    /// AVFoundation normalises across ID3, MP4 atoms and Vorbis comments, so a
    /// single pair of identifiers covers every format we accept.
    ///
    /// Every failure here is silent by design: a file with no tags is a normal
    /// import, not a broken one, and the caller falls back to the filename.
    private static func tags(of url: URL) async -> (title: String?, artist: String?) {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else {
            return (nil, nil)
        }
        func value(_ identifier: AVMetadataIdentifier) async -> String? {
            let matches = AVMetadataItem.metadataItems(from: items,
                                                       filteredByIdentifier: identifier)
            guard let item = matches.first,
                  let string = try? await item.load(.stringValue) else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (await value(.commonIdentifierTitle),
                await value(.commonIdentifierArtist))
    }

    private static func metadata(of url: URL) -> (durationS: Double, sampleRate: Int) {
        guard let file = try? AVAudioFile(forReading: url),
              file.fileFormat.sampleRate > 0 else {
            // e.g. ogg: CoreAudio can't read it but the engine can; zeroes are
            // display-only and better than refusing the import.
            return (0, 0)
        }
        let rate = file.fileFormat.sampleRate
        return (Double(file.length) / rate, Int(rate))
    }
}
