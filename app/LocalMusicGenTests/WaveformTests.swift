import XCTest
@testable import LocalMusicGen

final class WaveformTests: XCTestCase {
    /// Minimal PCM16 mono WAV with a sine tone.
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

    func testExtractAndCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wf-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        let audio = dir.appendingPathComponent("tone.wav")
        let cache = dir.appendingPathComponent("tone.peaks")
        try makeWav(at: audio)

        let peaks = try await WaveformExtractor.shared
            .peaks(for: audio, cacheURL: cache)
        XCTAssertGreaterThan(peaks.mins.count, 100)
        XCTAssertEqual(peaks.mins.count, peaks.maxs.count)
        XCTAssertGreaterThan(peaks.maxs.max() ?? 0, 0.4, "sine should peak high")
        XCTAssertLessThan(peaks.mins.min() ?? 0, -0.4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))

        // cache round-trip: audio file gone, peaks still served
        try FileManager.default.removeItem(at: audio)
        let cached = try await WaveformExtractor.shared
            .peaks(for: audio, cacheURL: cache)
        XCTAssertEqual(cached, peaks)
    }
}
