// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest
@testable import LocalMusicGen

final class AudioImporterTests: XCTestCase {
    private func makeWav(at url: URL, seconds: Double = 1.0,
                         rate: Int = 8000) throws {
        let n = Int(seconds * Double(rate))
        var samples = [Int16]()
        for i in 0..<n {
            let t = Double(i) / Double(rate)
            samples.append(Int16(sin(2 * .pi * 440 * t) * 20000))
        }
        var data = Data()
        func put(_ s: String) { data.append(Data(s.utf8)) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put("RIFF"); put32(UInt32(36 + n * 2)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(1)
        put32(UInt32(rate)); put32(UInt32(rate * 2)); put16(2); put16(16)
        put("data"); put32(UInt32(n * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return dir
    }

    func testWavPassthrough() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        try makeWav(at: source)

        let imported = try await AudioImporter.shared.importFile(
            at: source, songId: "abc", into: dir)
        XCTAssertEqual(imported.fileName, "abc.wav")
        XCTAssertEqual(imported.sampleRate, 8000)
        XCTAssertEqual(imported.durationS, 1.0, accuracy: 0.05)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("abc.wav").path))
    }

    /// A file with no tags is a normal import, not a failed one: the caller
    /// falls back to the filename, so the importer must simply report nothing.
    func testUntaggedFileReportsNoTitleOrArtist() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        try makeWav(at: source)

        let imported = try await AudioImporter.shared.importFile(
            at: source, songId: "bare", into: dir)
        XCTAssertNil(imported.title)
        XCTAssertNil(imported.artist)
    }

    /// An import that throws must leave nothing behind. Nothing prunes
    /// `Library/Audio`, so a destination created before the failure sits
    /// there forever with no row pointing at it.
    func testAFailedImportLeavesNoFileBehind() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Not audio, and not a passthrough extension: this takes the
        // transcode branch, the one that creates its destination first.
        let source = dir.appendingPathComponent("junk.m4a")
        try Data("this is not an m4a".utf8).write(to: source)

        do {
            _ = try await AudioImporter.shared.importFile(
                at: source, songId: "junk", into: dir)
            XCTFail("an unreadable source must throw")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("junk.wav").path))
        }
    }

    /// The cleanup only takes back what the failed import itself created: a
    /// file already at the destination belongs to a row, and deleting it
    /// would be losing somebody's audio over a name collision.
    func testAPreexistingDestinationSurvivesAFailedImport() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("tone.wav")
        try makeWav(at: source)
        let taken = Data("someone else's audio".utf8)
        let dest = dir.appendingPathComponent("taken.wav")
        try taken.write(to: dest)

        do {
            _ = try await AudioImporter.shared.importFile(
                at: source, songId: "taken", into: dir)
            XCTFail("copying onto an existing file must throw")
        } catch {
            XCTAssertEqual(try Data(contentsOf: dest), taken)
        }
    }

    /// Tags are read off the source, which matters most here: this file is
    /// transcoded to bare PCM, so reading the destination would lose them.
    func testTagsSurviveTheTranscode() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tagged = try await makeTaggedM4a(in: dir, title: "Midnight Drive",
                                             artist: "Aurora Halo")

        let imported = try await AudioImporter.shared.importFile(
            at: tagged, songId: "tag", into: dir)
        XCTAssertEqual(imported.fileName, "tag.wav")
        XCTAssertEqual(imported.title, "Midnight Drive")
        XCTAssertEqual(imported.artist, "Aurora Halo")
    }

    /// Writes a half-second AAC file carrying common title/artist metadata.
    /// Skips rather than fails if the export is unavailable — the subject here
    /// is the importer, not AVFoundation's encoder.
    private func makeTaggedM4a(in dir: URL, title: String,
                               artist: String) async throws -> URL {
        let plain = dir.appendingPathComponent("plain.m4a")
        try writeAAC(to: plain)
        let asset = AVURLAsset(url: plain)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw XCTSkip("No AppleM4A export preset on this machine")
        }
        func item(_ identifier: AVMetadataIdentifier,
                  _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        let out = dir.appendingPathComponent("tagged.m4a")
        export.outputURL = out
        export.outputFileType = .m4a
        export.metadata = [item(.commonIdentifierTitle, title),
                           item(.commonIdentifierArtist, artist)]
        await export.export()
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw XCTSkip("Tagged m4a export did not produce a file")
        }
        return out
    }

    private func writeAAC(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100,
                                   channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ]
        // Writer must fall out of scope so the container is finalized.
        try {
            let out = try AVAudioFile(forWriting: url, settings: settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
            let frames = AVAudioFrameCount(44100 / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] =
                    sinf(2 * .pi * 440 * Float(i) / 44100) * 0.5
            }
            try out.write(from: buffer)
        }()
    }

    func testM4aDecodesToWav() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Synthesize an AAC file via AVAudioFile.
        let m4a = dir.appendingPathComponent("clip.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100,
                                   channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
        ]
        // Writer must fall out of scope so the AAC container is finalized
        // before anything reads it.
        try {
            let out = try AVAudioFile(forWriting: m4a, settings: settings,
                                      commonFormat: .pcmFormatFloat32,
                                      interleaved: false)
            let frames = AVAudioFrameCount(44100 / 2)
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: frames)!
            buffer.frameLength = frames
            for i in 0..<Int(frames) {
                buffer.floatChannelData![0][i] =
                    sinf(2 * .pi * 440 * Float(i) / 44100) * 0.5
            }
            try out.write(from: buffer)
        }()

        let imported = try await AudioImporter.shared.importFile(
            at: m4a, songId: "dec", into: dir)
        XCTAssertEqual(imported.fileName, "dec.wav")
        XCTAssertEqual(imported.sampleRate, 44100)
        XCTAssertEqual(imported.durationS, 0.5, accuracy: 0.1)
        // The decoded WAV must be readable audio, not a copy of the AAC bytes.
        let decoded = try AVAudioFile(
            forReading: dir.appendingPathComponent("dec.wav"))
        XCTAssertEqual(decoded.fileFormat.sampleRate, 44100)
    }
}
