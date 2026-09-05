import AVFoundation
import XCTest
@testable import LocalMusicGen

@MainActor
final class MultiPartPlayerTests: XCTestCase {
    private func synthWav(_ name: String, freq: Double,
                          seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mpp-\(name)-\(UUID().uuidString).wav")
        let sr = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sr,
                                   channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] =
                sin(2 * .pi * freq * Double(i) / sr).isFinite
                ? Float(0.4 * sin(2 * .pi * freq * Double(i) / sr)) : 0
        }
        try file.write(from: buffer)
        return url
    }

    func testSampleLockedPlaybackOfTwoParts() throws {
        let a = try synthWav("a", freq: 440, seconds: 1.5)
        let b = try synthWav("b", freq: 220, seconds: 1.5)
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let player = MultiPartPlayer()
        let items = [
            MultiPartPlayer.Item(id: "a", url: a, offsetS: 0, gainDb: 0,
                                 muted: false),
            MultiPartPlayer.Item(id: "b", url: b, offsetS: 0.5, gainDb: -6,
                                 muted: false),
        ]
        guard player.play(items: items) else {
            throw XCTSkip("audio hardware unavailable: "
                          + (player.lastError ?? "unknown"))
        }
        XCTAssertTrue(player.isPlaying)
        // both nodes scheduled; at least one is actively rendering
        let deadline = Date().addingTimeInterval(1.0)
        var sawPlaying = false
        while Date() < deadline && !sawPlaying {
            sawPlaying = player.anyNodePlaying
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(sawPlaying)
        // live gain update must not throw or stop playback
        player.updateGains(items: items.map {
            var item = $0
            item.gainDb = -12
            return item
        })
        XCTAssertTrue(player.isPlaying)
        player.stop()
        XCTAssertFalse(player.isPlaying)
        XCTAssertFalse(player.anyNodePlaying)
    }

    func testMutedEverythingRefusesToStart() {
        let player = MultiPartPlayer()
        let ok = player.play(items: [
            MultiPartPlayer.Item(
                id: "x",
                url: URL(fileURLWithPath: "/nonexistent.wav"),
                offsetS: 0, gainDb: 0, muted: false),
        ])
        XCTAssertFalse(ok)
        XCTAssertFalse(player.isPlaying)
    }

    // MARK: placement geometry (no audio hardware needed)

    private func item(offset: Double = 0, start: Double = 0,
                      end: Double? = nil) -> MultiPartPlayer.Item {
        MultiPartPlayer.Item(id: "c", url: URL(fileURLWithPath: "/x.wav"),
                             offsetS: offset, gainDb: 0, muted: false,
                             sourceStartS: start, sourceEndS: end)
    }

    /// 10 s file at 44.1 kHz.
    private let frames: AVAudioFramePosition = 441_000
    private let rate = 44_100.0

    func testWholeClipFromTheTop() throws {
        let p = try XCTUnwrap(MultiPartPlayer.placement(
            for: item(offset: 2), position: 0, fileFrames: frames,
            sampleRate: rate))
        XCTAssertEqual(p.startFrame, 0)
        XCTAssertEqual(p.frameCount, 441_000)
        XCTAssertEqual(p.delayS, 2, accuracy: 1e-9)
    }

    /// The trim the mix applies must be the trim you hear — the preview used
    /// to ignore it and play whole files.
    func testSourceTrimIsScheduledNotTheWholeFile() throws {
        let p = try XCTUnwrap(MultiPartPlayer.placement(
            for: item(start: 2, end: 5), position: 0, fileFrames: frames,
            sampleRate: rate))
        XCTAssertEqual(p.startFrame, 88_200)          // 2 s in
        XCTAssertEqual(p.frameCount, 132_300)         // 3 s long
    }

    func testSeekingIntoAClipStartsPartWayThroughIt() throws {
        let p = try XCTUnwrap(MultiPartPlayer.placement(
            for: item(offset: 4, start: 2, end: 5), position: 5,
            fileFrames: frames, sampleRate: rate))
        XCTAssertEqual(p.startFrame, 132_300)         // 2 s trim + 1 s in
        XCTAssertEqual(p.frameCount, 88_200)          // 2 s left
        XCTAssertEqual(p.delayS, 0)
    }

    func testClipsEntirelyBehindThePlayheadAreSkipped() {
        XCTAssertNil(MultiPartPlayer.placement(
            for: item(offset: 0, start: 0, end: 3), position: 4,
            fileFrames: frames, sampleRate: rate))
    }

    func testTrimBeyondTheFileIsClampedAndEmptyTrimIsSkipped() throws {
        let clamped = try XCTUnwrap(MultiPartPlayer.placement(
            for: item(start: 8, end: 999), position: 0, fileFrames: frames,
            sampleRate: rate))
        XCTAssertEqual(clamped.frameCount, 88_200)    // 8 s → end of file
        XCTAssertNil(MultiPartPlayer.placement(
            for: item(start: 5, end: 5), position: 0, fileFrames: frames,
            sampleRate: rate))
    }

    func testTimelineDurationIsTheLastClipEnd() {
        let items = [
            MultiPartPlayer.Item(id: "a", url: URL(fileURLWithPath: "/a"),
                                 offsetS: 0, gainDb: 0, muted: false),
            MultiPartPlayer.Item(id: "b", url: URL(fileURLWithPath: "/b"),
                                 offsetS: 8, gainDb: 0, muted: false,
                                 sourceStartS: 1, sourceEndS: 3),
        ]
        XCTAssertEqual(
            MultiPartPlayer.timelineDurationS(items,
                                              fileDurations: ["a": 10, "b": 10]),
            10)
        XCTAssertEqual(
            MultiPartPlayer.timelineDurationS(items,
                                              fileDurations: ["a": 4, "b": 10]),
            10)                                        // 8 + 2 s of trim
    }

    // MARK: transport (needs audio hardware)

    func testPauseFreezesAndSeekMoves() throws {
        let a = try synthWav("t", freq: 440, seconds: 3)
        defer { try? FileManager.default.removeItem(at: a) }
        let player = MultiPartPlayer()
        guard player.play(items: [
            MultiPartPlayer.Item(id: "a", url: a, offsetS: 0, gainDb: 0,
                                 muted: false),
        ]) else {
            throw XCTSkip("audio hardware unavailable: "
                          + (player.lastError ?? "unknown"))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        player.pause()
        XCTAssertEqual(player.state, .paused)
        let frozen = player.currentPosition()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(player.currentPosition(), frozen, accuracy: 0.02,
                       "a paused playhead must not move")

        player.seek(to: 1.0)
        XCTAssertEqual(player.currentPosition(), 1.0, accuracy: 0.15)
        player.resume()
        XCTAssertTrue(player.isPlaying)
        player.stop()
        XCTAssertEqual(player.state, .stopped)
    }

    /// isPlaying used to stay true forever once the audio ran out.
    func testPlaybackEndsAtTheEndOfTheTimeline() throws {
        let a = try synthWav("short", freq: 440, seconds: 0.4)
        defer { try? FileManager.default.removeItem(at: a) }
        let player = MultiPartPlayer()
        guard player.play(items: [
            MultiPartPlayer.Item(id: "a", url: a, offsetS: 0, gainDb: 0,
                                 muted: false),
        ]) else {
            throw XCTSkip("audio hardware unavailable")
        }
        XCTAssertEqual(player.durationS, 0.4, accuracy: 0.05)
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline && player.isPlaying {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(player.isPlaying, "playback should have finished")
        player.stop()
    }

    /// The meter tap runs on AVFAudio's own realtime queue. When its block
    /// inherited `@MainActor` from the enclosing method, the Swift runtime
    /// trapped on the very first buffer — so the app died the moment the
    /// Editor started playing. Only real audio through a real tap catches it:
    /// before the fix, this test killed the test process outright.
    func testMeterTapPublishesLevelsWithoutTrapping() throws {
        let a = try synthWav("meter", freq: 440, seconds: 1.5)
        defer { try? FileManager.default.removeItem(at: a) }
        let player = MultiPartPlayer()
        player.metersEnabled = true
        player.sumsConcurrently = false
        guard player.play(items: [
            MultiPartPlayer.Item(id: "a", url: a, offsetS: 0, gainDb: 0,
                                 muted: false),
        ]) else {
            throw XCTSkip("audio hardware unavailable: "
                          + (player.lastError ?? "unknown"))
        }
        // Wait for signal, not merely for a reading: the nodes start a beat
        // after the engine does, so the first buffers really are silent.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, (player.meterDb?.left ?? -80) < -40 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let level = try XCTUnwrap(player.meterDb, "no meter level arrived")
        // The synth is a 0.4-amplitude sine: -7.96 dBFS.
        XCTAssertEqual(level.left, -7.96, accuracy: 3.0)
        XCTAssertEqual(level.right, level.left, accuracy: 0.01,
                       "a mono source should meter equally on both sides")
        player.stop()
        XCTAssertNil(player.meterDb, "a stopped player must not hold a level")
    }

    /// Pins the isolation the fix depends on: peak reading is callable from
    /// off the main actor, which is where the audio thread calls it.
    func testPeakDbReadsBothChannelsOffTheMainActor() async throws {
        let value = await Task.detached { () -> MultiPartPlayer.MeterLevel? in
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000,
                                       channels: 2)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: 128)!
            buffer.frameLength = 128
            for i in 0..<128 {
                buffer.floatChannelData![0][i] = 0.5
                buffer.floatChannelData![1][i] = 0.25
            }
            return MultiPartPlayer.peakDb(in: buffer)
        }.value
        let peaks = try XCTUnwrap(value)
        XCTAssertEqual(peaks.left, -6.02, accuracy: 0.05)
        XCTAssertEqual(peaks.right, -12.04, accuracy: 0.05)
    }
}
