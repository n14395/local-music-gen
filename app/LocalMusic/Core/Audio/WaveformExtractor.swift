import AVFoundation
import Foundation

/// Extracts min/max peak bins from an audio file and caches them as a compact
/// binary file (.peaks) so waveforms render instantly ever after.
///
/// Cache format: "LMPK" magic, UInt32 bin count, then bins × (Float32 min, Float32 max).
actor WaveformExtractor {
    static let shared = WaveformExtractor()
    static let binCount = 2000

    struct Peaks: Sendable, Equatable {
        var mins: [Float]
        var maxs: [Float]
    }

    private var inFlight: [String: Task<Peaks, Error>] = [:]

    func peaks(for audioURL: URL, cacheURL: URL) async throws -> Peaks {
        if let cached = Self.readCache(cacheURL) { return cached }
        let key = cacheURL.path
        if let task = inFlight[key] { return try await task.value }
        let task = Task<Peaks, Error>.detached(priority: .utility) {
            let peaks = try Self.extract(from: audioURL)
            Self.writeCache(peaks, to: cacheURL)
            return peaks
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Peaks for a file that is not worth caching — a streaming render
    /// preview, superseded within seconds, which would otherwise leave one
    /// stale `.peaks` file per frame.
    func peaks(for audioURL: URL) async throws -> Peaks {
        try await Task<Peaks, Error>.detached(priority: .utility) {
            try Self.extract(from: audioURL)
        }.value
    }

    // MARK: extraction

    private static func extract(from url: URL) throws -> Peaks {
        let file = try AVAudioFile(forReading: url)
        let totalFrames = Int(file.length)
        guard totalFrames > 0 else { return Peaks(mins: [], maxs: []) }
        let bins = min(binCount, totalFrames)
        let framesPerBin = totalFrames / bins
        var mins = [Float](repeating: 0, count: bins)
        var maxs = [Float](repeating: 0, count: bins)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: file.processingFormat.sampleRate,
                                   channels: file.processingFormat.channelCount,
                                   interleaved: false)!
        let chunk = AVAudioFrameCount(65536)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var frameIndex = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: chunk)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData?[0] else { break }
            for i in 0..<n {
                let bin = min(bins - 1, (frameIndex + i) / framesPerBin)
                let v = data[i]
                if v < mins[bin] { mins[bin] = v }
                if v > maxs[bin] { maxs[bin] = v }
            }
            frameIndex += n
        }
        return Peaks(mins: mins, maxs: maxs)
    }

    // MARK: cache

    private static func readCache(_ url: URL) -> Peaks? {
        guard let data = try? Data(contentsOf: url), data.count >= 8,
              data.prefix(4) == Data("LMPK".utf8) else { return nil }
        let count = data.withUnsafeBytes { $0.load(fromByteOffset: 4, as: UInt32.self) }
        let expected = 8 + Int(count) * 8
        guard data.count == expected else { return nil }
        var mins = [Float](repeating: 0, count: Int(count))
        var maxs = [Float](repeating: 0, count: Int(count))
        data.withUnsafeBytes { raw in
            let floats = raw.baseAddress!.advanced(by: 8)
                .assumingMemoryBound(to: Float32.self)
            for i in 0..<Int(count) {
                mins[i] = floats[i * 2]
                maxs[i] = floats[i * 2 + 1]
            }
        }
        return Peaks(mins: mins, maxs: maxs)
    }

    private static func writeCache(_ peaks: Peaks, to url: URL) {
        var data = Data("LMPK".utf8)
        var count = UInt32(peaks.mins.count)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for i in 0..<peaks.mins.count {
            var lo = peaks.mins[i], hi = peaks.maxs[i]
            withUnsafeBytes(of: &lo) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &hi) { data.append(contentsOf: $0) }
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
