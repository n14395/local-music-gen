import AVFoundation
import Foundation
import Observation

/// Sample-locked multi-part audition for the Workbench: one AVAudioPlayerNode
/// per clip, all started against a shared host-time anchor (N independent
/// AVPlayers drift audibly within seconds). This is a ROUGH preview — real
/// offsets, trims and gains, but no time-stretch; authoritative alignment
/// happens engine-side in the mix job.
@MainActor @Observable
final class MultiPartPlayer {
    struct Item: Equatable {
        var id: String
        var url: URL
        var offsetS: Double
        var gainDb: Double
        var muted: Bool
        /// Source trim, matching mix_spec's `section`. Without it the preview
        /// plays whole files while the mix plays the trimmed ones.
        var sourceStartS: Double = 0
        var sourceEndS: Double?
    }

    enum TransportState: Equatable { case stopped, playing, paused }

    /// Where a clip's audio sits in its file and on the timeline. Pure, so the
    /// arithmetic is testable without an audio device.
    struct Placement: Equatable {
        var startFrame: AVAudioFramePosition
        var frameCount: AVAudioFrameCount
        var delayS: Double
    }

    private let engine = AVAudioEngine()
    private var nodes: [String: AVAudioPlayerNode] = [:]
    private var files: [String: AVAudioFile] = [:]
    private var armedItems: [Item] = []

    private(set) var state: TransportState = .stopped
    /// Peak level of the summed preview per channel, in dBFS, ~20 Hz while
    /// playing; nil otherwise. Opt-in: the tap costs a little per render
    /// cycle and only the Editor draws a meter.
    private(set) var meterDb: (left: Double, right: Double)?
    var metersEnabled = false
    /// The workbench sums its items, so headroom scales with their count.
    /// The Editor's items are one timeline cut into pieces — never more than
    /// two sounding at once (a crossfade) — and scaling by segment count
    /// would make a heavily-cut track quieter with every cut.
    var sumsConcurrently = true
    /// Coarse mirror of the audio clock for bindings and readouts; the playhead
    /// itself reads `currentPosition()` so nothing that draws clips is
    /// invalidated 30 times a second.
    private(set) var positionS: Double = 0
    private(set) var durationS: Double = 0
    var lastError: String?

    private var anchorHost: UInt64 = 0
    private var anchorPosition: Double = 0
    private var frozenPosition: Double?
    private var tick: Timer?

    var isPlaying: Bool { state == .playing }

    // MARK: pure geometry

    nonisolated static func placement(for item: Item, position: Double,
                                      fileFrames: AVAudioFramePosition,
                                      sampleRate: Double) -> Placement? {
        guard sampleRate > 0, fileFrames > 0 else { return nil }
        let fileDuration = Double(fileFrames) / sampleRate
        let sourceStart = max(0, min(item.sourceStartS, fileDuration))
        let sourceEnd = min(item.sourceEndS ?? fileDuration, fileDuration)
        guard sourceEnd > sourceStart else { return nil }

        let intoClip = max(0, position - item.offsetS)
        let startS = sourceStart + intoClip
        guard startS < sourceEnd else { return nil }   // playhead is past it

        let startFrame = AVAudioFramePosition(startS * sampleRate)
        let endFrame = min(fileFrames,
                           AVAudioFramePosition(sourceEnd * sampleRate))
        guard endFrame > startFrame else { return nil }
        return Placement(startFrame: startFrame,
                         frameCount: AVAudioFrameCount(endFrame - startFrame),
                         delayS: max(0, item.offsetS - position))
    }

    nonisolated static func clipLengthS(_ item: Item,
                                        fileDurationS: Double) -> Double {
        let start = max(0, min(item.sourceStartS, fileDurationS))
        let end = min(item.sourceEndS ?? fileDurationS, fileDurationS)
        return max(0, end - start)
    }

    nonisolated static func timelineDurationS(
        _ items: [Item], fileDurations: [String: Double]) -> Double {
        items.reduce(0) { longest, item in
            guard let duration = fileDurations[item.id] else { return longest }
            return max(longest,
                       item.offsetS + clipLengthS(item, fileDurationS: duration))
        }
    }

    // MARK: transport

    @discardableResult
    func play(items: [Item], from position: Double = 0) -> Bool {
        stop()
        guard prepare(items: items) else { return false }
        return arm(from: position)
    }

    func pause() {
        guard state == .playing else { return }
        frozenPosition = currentPosition()
        disarm()
        state = .paused
    }

    func resume() {
        guard state == .paused else { return }
        _ = arm(from: frozenPosition ?? 0)
    }

    func seek(to position: Double) {
        guard state != .stopped else { return }
        let wasPlaying = state == .playing
        disarm()
        if wasPlaying {
            _ = arm(from: max(0, position))
        } else {
            frozenPosition = max(0, position)
            positionS = frozenPosition ?? 0
        }
    }

    /// Live gain/mute updates without restarting (mute = volume 0; a muted
    /// node keeps its schedule so unmute stays in sync).
    func updateGains(items: [Item]) {
        for item in items {
            nodes[item.id]?.volume = item.muted
                ? 0 : Float(pow(10.0, item.gainDb / 20.0))
        }
    }

    func stop() {
        disarm()
        teardown()
        state = .stopped
        positionS = 0
        frozenPosition = nil
    }

    /// Exact position, derived from the audio device clock rather than
    /// accumulated — a counter drifts against the grid the clips are drawn on,
    /// and that drift is exactly what a timeline makes visible.
    func currentPosition() -> Double {
        if let frozenPosition { return frozenPosition }
        guard state == .playing else { return anchorPosition }
        let now: UInt64
        if let render = engine.outputNode.lastRenderTime, render.isHostTimeValid {
            now = render.hostTime
        } else {
            now = mach_absolute_time()      // pre-roll, before the first render
        }
        let elapsed = AVAudioTime.seconds(forHostTime: now)
            - AVAudioTime.seconds(forHostTime: anchorHost)
        return max(anchorPosition, anchorPosition + elapsed)
    }

    // MARK: graph lifecycle

    /// Build the graph once; seeking and pausing re-arm it rather than tearing
    /// it down, so nodes are not attached and detached mid-session.
    private func prepare(items: [Item]) -> Bool {
        var prepared: [Item] = []
        for item in items where !item.muted {
            guard let file = try? AVAudioFile(forReading: item.url) else {
                continue
            }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode,
                           format: file.processingFormat)
            node.volume = Float(pow(10.0, item.gainDb / 20.0))
            nodes[item.id] = node
            files[item.id] = file
            prepared.append(item)
        }
        guard !prepared.isEmpty else {
            lastError = "Nothing to play"
            teardown()
            return false
        }
        // Summing N clips with no normalisation clips the mixer; the mix job
        // normalises and limits, the preview does neither.
        engine.mainMixerNode.outputVolume = sumsConcurrently
            ? Float(min(1.0, 4.0 / Double(prepared.count).squareRoot()))
            : 1.0
        if metersEnabled { installMeterTap() }
        do {
            try engine.start()
        } catch {
            lastError = "Audio engine unavailable: \(error.localizedDescription)"
            teardown()
            return false
        }
        armedItems = prepared
        durationS = Self.timelineDurationS(prepared, fileDurations: fileDurations())
        return true
    }

    /// Schedule every clip against one anchor and start the clock.
    @discardableResult
    private func arm(from position: Double) -> Bool {
        var scheduled: [(AVAudioPlayerNode, Placement)] = []
        for item in armedItems {
            guard let node = nodes[item.id], let file = files[item.id] else {
                continue
            }
            let sampleRate = file.processingFormat.sampleRate
            guard let placement = Self.placement(
                for: item, position: position, fileFrames: file.length,
                sampleRate: sampleRate) else { continue }
            node.scheduleSegment(file, startingFrame: placement.startFrame,
                                 frameCount: placement.frameCount, at: nil)
            scheduled.append((node, placement))
        }
        guard !scheduled.isEmpty else {
            // Past the end of everything: hold the position rather than
            // pretending to play silence forever.
            anchorPosition = position
            positionS = position
            frozenPosition = position
            state = .paused
            return false
        }
        // Anchor AFTER scheduling: taking it first meant a slow schedule could
        // put the anchor in the past, and every late clip then started ASAP —
        // independently — which is the one thing this class exists to prevent.
        let margin = min(0.35, 0.12 + 0.004 * Double(scheduled.count))
        anchorHost = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: margin)
        anchorPosition = position
        for (node, placement) in scheduled {
            let startTime = AVAudioTime(
                hostTime: anchorHost
                    + AVAudioTime.hostTime(forSeconds: placement.delayS))
            node.play(at: startTime)
        }
        frozenPosition = nil
        state = .playing
        positionS = position
        lastError = nil
        startTick()
        return true
    }

    /// Stop the nodes (clearing their schedules) but keep the graph up.
    private func disarm() {
        tick?.invalidate()
        tick = nil
        for node in nodes.values where node.isPlaying {
            node.stop()
        }
    }

    /// Reads peaks on the render thread, publishes on the main actor. The
    /// buffer is only touched inside the tap block — what crosses the hop is
    /// two Doubles.
    private func installMeterTap() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 2048,
                                        format: format) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            guard frames > 0, channels > 0 else { return }
            var peaks = [Float](repeating: 0, count: min(2, channels))
            for channel in 0..<min(2, channels) {
                var peak: Float = 0
                for i in 0..<frames {
                    let v = abs(data[channel][i])
                    if v > peak { peak = v }
                }
                peaks[channel] = peak
            }
            let left = Double(peaks[0])
            let right = Double(peaks.count > 1 ? peaks[1] : peaks[0])
            func db(_ v: Double) -> Double {
                v > 0 ? max(-80, 20 * log10(v)) : -80
            }
            let value = (left: db(left), right: db(right))
            Task { @MainActor [weak self] in
                guard let self, self.state == .playing else { return }
                self.meterDb = value
            }
        }
    }

    private func teardown() {
        if metersEnabled { engine.mainMixerNode.removeTap(onBus: 0) }
        meterDb = nil
        engine.stop()
        for node in nodes.values {
            engine.detach(node)
        }
        nodes = [:]
        files = [:]
        armedItems = []
        durationS = 0
    }

    private func fileDurations() -> [String: Double] {
        var out: [String: Double] = [:]
        for (id, file) in files {
            let rate = file.processingFormat.sampleRate
            if rate > 0 { out[id] = Double(file.length) / rate }
        }
        return out
    }

    private func startTick() {
        tick?.invalidate()
        // 25 Hz is plenty for a numeric readout; the playhead itself reads the
        // audio clock directly on its own redraw.
        tick = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.currentPosition()
                self.positionS = now
                if self.durationS > 0 && now >= self.durationS {
                    self.finish()
                }
            }
        }
    }

    /// Everything has played out: park the playhead at the end rather than
    /// leaving `isPlaying` true forever (which it used to do).
    private func finish() {
        disarm()
        frozenPosition = durationS
        positionS = durationS
        state = .paused
    }

    /// True while any node still reports playing (used by tests).
    var anyNodePlaying: Bool {
        nodes.values.contains { $0.isPlaying }
    }
}
