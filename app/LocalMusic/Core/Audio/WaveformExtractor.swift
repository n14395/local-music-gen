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

    /// Peaks for one *window* of a file, read fresh from only the frames in
    /// view — the whole-file cache is 2000 bins (~90 ms per bin on a three
    /// minute track), which cannot support a zoomed editor. No cache: the
    /// window moves with every scroll and zoom, and reading a few seconds of
    /// PCM is cheaper than managing invalidation for it.
    ///
    /// One `Peaks` per channel: `[mono]` for a mono file, `[left, right]`
    /// for stereo (further channels are ignored, matching the mix path).
    /// `mono: true` folds them into one lane by max magnitude.
    /// Detached, with cancellation forwarded by hand.
    ///
    /// It used to run straight on the actor's executor, which kept the decode
    /// off the main thread but put *every other request* behind it — this is
    /// a serial executor, and at fit zoom the window is the whole file. So
    /// while the Editor decoded, every library row's 16 KB cache read and
    /// every timeline clip's peaks queued up behind it, and waveforms
    /// arrived one at a time. Only the in-flight bookkeeping needs the actor.
    ///
    /// The reason it was not detached before is real and is handled here: a
    /// detached task does not inherit cancellation, and a window the view has
    /// already scrolled past must stop rather than decode to the end.
    /// `extractRange` checks cancellation per chunk; this forwards it.
    ///
    /// Windows repeat constantly — press Fit, toggle Mono, resize the window,
    /// make an edit and the same span is asked for again — so recent answers
    /// are kept. The cache is small and keyed on everything that changes the
    /// answer.
    func peaks(for audioURL: URL, startS: Double, endS: Double,
               binCount: Int, mono: Bool) async throws -> [Peaks] {
        // The file's modification date is part of the key, so bytes changing
        // under a path — an apply, a revert — can never serve a stale window.
        // That is one `stat` per request, against a decode; and it means no
        // call site has to remember to invalidate this.
        let modified = (try? audioURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = WindowKey(path: audioURL.path,
                            modified: modified ?? .distantPast,
                            startS: startS, endS: endS,
                            binCount: binCount, mono: mono)
        if let hit = windowCache[key] {
            windowOrder.removeAll { $0 == key }
            windowOrder.append(key)
            return hit
        }
        let task = Task<[Peaks], Error>.detached(priority: .userInitiated) {
            try Self.extractRange(from: audioURL, startS: startS, endS: endS,
                                  binCount: binCount, mono: mono)
        }
        let answer = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        store(answer, for: key)
        return answer
    }

    /// Everything that changes a window's answer. The file's path rather than
    /// the URL so an equal path is an equal key.
    private struct WindowKey: Hashable {
        var path: String
        var modified: Date
        var startS: Double
        var endS: Double
        var binCount: Int
        var mono: Bool
    }

    /// Small on purpose: this holds decoded PCM peaks, and the point is to
    /// survive a zoom in and back out, not to hold a session.
    private static let windowCacheLimit = 24
    private var windowCache: [WindowKey: [Peaks]] = [:]
    private var windowOrder: [WindowKey] = []

    private func store(_ peaks: [Peaks], for key: WindowKey) {
        windowCache[key] = peaks
        windowOrder.removeAll { $0 == key }
        windowOrder.append(key)
        while windowOrder.count > Self.windowCacheLimit {
            windowCache.removeValue(forKey: windowOrder.removeFirst())
        }
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

    private static func extractRange(from url: URL, startS: Double,
                                     endS: Double, binCount: Int,
                                     mono: Bool) throws -> [Peaks] {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0, file.length > 0, endS > startS,
              binCount > 0 else { return [] }
        let channelCount = mono ? 1 : min(2, Int(file.processingFormat.channelCount))
        let firstFrame = max(0, min(file.length,
                                    AVAudioFramePosition(startS * sampleRate)))
        let lastFrame = max(firstFrame,
                            min(file.length,
                                AVAudioFramePosition(endS * sampleRate)))
        let totalFrames = Int(lastFrame - firstFrame)
        guard totalFrames > 0 else {
            return Array(repeating: Peaks(mins: [], maxs: []),
                         count: channelCount)
        }
        let bins = min(binCount, totalFrames)
        let framesPerBin = max(1, totalFrames / bins)
        var mins = Array(repeating: [Float](repeating: 0, count: bins),
                         count: channelCount)
        var maxs = Array(repeating: [Float](repeating: 0, count: bins),
                         count: channelCount)

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: file.processingFormat.channelCount,
                                   interleaved: false)!
        let chunk = AVAudioFrameCount(65536)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        file.framePosition = firstFrame
        var frameIndex = 0
        while frameIndex < totalFrames {
            // Checked per chunk: the caller is a scroll gesture, and the
            // window it wanted is stale the moment the next event lands.
            try Task.checkCancellation()
            let want = AVAudioFrameCount(min(Int(chunk),
                                             totalFrames - frameIndex))
            try file.read(into: buffer, frameCount: want)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            let sourceChannels = Int(buffer.format.channelCount)
            for i in 0..<min(n, totalFrames - frameIndex) {
                let bin = min(bins - 1, (frameIndex + i) / framesPerBin)
                for lane in 0..<channelCount {
                    let v: Float
                    if mono {
                        // Fold every channel by magnitude, keeping sign of
                        // the loudest, so the lane still draws both halves.
                        var loudest: Float = 0
                        for channel in 0..<sourceChannels {
                            let sample = data[channel][i]
                            if abs(sample) > abs(loudest) { loudest = sample }
                        }
                        v = loudest
                    } else {
                        v = data[min(lane, sourceChannels - 1)][i]
                    }
                    if v < mins[lane][bin] { mins[lane][bin] = v }
                    if v > maxs[lane][bin] { maxs[lane][bin] = v }
                }
            }
            frameIndex += n
        }
        return (0..<channelCount).map {
            Peaks(mins: mins[$0], maxs: maxs[$0])
        }
    }

    /// Drop a file's cached whole-file peaks — an in-place edit that keeps
    /// the cache would draw the old audio forever.
    nonisolated static func invalidateCache(_ cacheURL: URL) {
        try? FileManager.default.removeItem(at: cacheURL)
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
