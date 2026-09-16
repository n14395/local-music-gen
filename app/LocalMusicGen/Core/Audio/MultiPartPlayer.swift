import Accelerate
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
        /// -1 hard left … +1 hard right, matching mix_spec's `pan`. The
        /// preview pans with AVAudioPlayerNode's own constant-power law,
        /// which is the same law the mix job applies.
        var pan: Double = 0
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
    private(set) var meterDb: MeterLevel?

    /// Peak level per channel, in dBFS.
    struct MeterLevel: Equatable, Sendable {
        var left: Double
        var right: Double
    }
    var metersEnabled = false
    /// The workbench sums its items, so headroom scales with their count.
    /// The Editor's items are one timeline cut into pieces — never more than
    /// two sounding at once (a crossfade) — and scaling by segment count
    /// would make a heavily-cut track quieter with every cut.
    var sumsConcurrently = true
    /// The listener's own level, 0…1, multiplied into the mixer on top of the
    /// headroom scaling above.
    ///
    /// Separate from that scaling rather than folded into it: headroom is a
    /// property of what is being summed and changes with the arrangement,
    /// while this is a property of how loud the room is. Applied live, so
    /// Volume Up during a preview is heard rather than queued for the next
    /// one.
    var outputScale: Double = 1 {
        didSet {
            guard outputScale != oldValue else { return }
            applyOutputVolume()
        }
    }
    /// The count the headroom was last computed from, kept so the level can be
    /// reapplied without rebuilding the graph.
    private var preparedCount = 0
    private(set) var durationS: Double = 0
    var lastError: String?

    private var anchorHost: UInt64 = 0
    private var anchorPosition: Double = 0
    private var frozenPosition: Double?
    private var tick: Timer?
    /// Whether the meter tap is on the mixer — see `prepare`.
    private var meterTapInstalled = false
    /// The output-device watch — see `handleConfigurationChange`. Outside
    /// observation and isolation so `deinit` can hand it back.
    @ObservationIgnored nonisolated(unsafe)
    private var configurationObserver: (any NSObjectProtocol)?

    var isPlaying: Bool { state == .playing }

    init() {
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

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
        disarm()
        guard prepare(items: items) else {
            state = .stopped
            frozenPosition = nil
            return false
        }
        return arm(from: position)
    }

    func pause() {
        guard state == .playing else { return }
        frozenPosition = currentPosition()
        disarm()
        state = .paused
        // A meter that keeps showing the last level of a stopped signal is
        // reporting something that is not happening.
        meterDb = nil
    }

    func resume() {
        guard state == .paused else { return }
        // `finish()` parks at the end, where nothing can be scheduled and
        // `arm` would only park again — so Play after a preview has played
        // out starts it over rather than doing nothing until Stop.
        let from = frozenPosition ?? 0
        _ = arm(from: durationS > 0 && from >= durationS ? 0 : from)
    }

    func seek(to position: Double) {
        guard state != .stopped else { return }
        let wasPlaying = state == .playing
        disarm()
        if wasPlaying {
            _ = arm(from: max(0, position))
        } else {
            frozenPosition = max(0, position)
        }
    }

    /// What `arm` actually schedules: every property of an item except how
    /// loud it is.
    ///
    /// Two item lists with equal schedules are already playing the right
    /// audio at the right time and differ only in volume, so `updateGains`
    /// is the whole update and the graph never has to stop. Sorted by id so
    /// the comparison does not depend on the order the caller built them in.
    struct Schedule: Equatable {
        struct Entry: Equatable {
            var id: String
            var url: URL
            var offsetS: Double
            var sourceStartS: Double
            var sourceEndS: Double?
        }
        var entries: [Entry]

        init(_ items: [Item]) {
            entries = items.map {
                Entry(id: $0.id, url: $0.url, offsetS: $0.offsetS,
                      sourceStartS: $0.sourceStartS, sourceEndS: $0.sourceEndS)
            }
            .sorted { $0.id < $1.id }
        }
    }

    /// The schedule currently armed — what a caller compares against to find
    /// out whether it needs `play` or only `updateGains`.
    var armedSchedule: Schedule { Schedule(armedItems) }

    /// The mixer's level: headroom for what is being summed, times the
    /// listener's own volume.
    private func applyOutputVolume() {
        // Nothing armed and nothing running: reading `mainMixerNode` would
        // build the graph, and a level set at launch has no business starting
        // an audio engine. `prepare` applies it before anything sounds.
        guard preparedCount > 0 || engine.isRunning else { return }
        let headroom = sumsConcurrently && preparedCount > 0
            ? min(1.0, 4.0 / Double(preparedCount).squareRoot())
            : 1.0
        engine.mainMixerNode.outputVolume =
            Float(headroom * outputScale.clamped(to: 0...1))
    }

    /// Live gain/mute updates without restarting (mute = volume 0; a muted
    /// node keeps its schedule so unmute stays in sync).
    func updateGains(items: [Item]) {
        for item in items {
            nodes[item.id]?.volume = item.muted
                ? 0 : Float(pow(10.0, item.gainDb / 20.0))
            nodes[item.id]?.pan = Float(max(-1, min(1, item.pan)))
        }
    }

    func stop() {
        disarm()
        teardown()
        state = .stopped
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

    /// Bring the graph into line with `items`, keeping everything that
    /// survives the change.
    ///
    /// Structural edits re-enter here constantly — every delete, trim, split
    /// or paste while the preview runs, and every settle of a speed or pitch
    /// drag. Rebuilding from nothing each time meant `engine.stop()`, a
    /// detach of every node, an `AVAudioFile` reopened from disk per segment
    /// and `engine.start()` again: on a heavily cut track that is dozens of
    /// file opens and two blocking HAL calls on the main thread, for an edit
    /// that usually moves one boundary.
    ///
    /// So a clip keeps its node and its open file when its id and url both
    /// survive; only genuinely new clips are opened and attached, only
    /// departed ones are detached, and the engine keeps running throughout.
    /// The url has to be part of that test — the Editor swaps every item onto
    /// a reversed copy of the source, which is the same ids pointing at
    /// different audio.
    private func prepare(items: [Item]) -> Bool {
        var nextNodes: [String: AVAudioPlayerNode] = [:]
        var nextFiles: [String: AVAudioFile] = [:]
        var prepared: [Item] = []
        // Muted items get a node too, at volume 0. Skipping them meant a
        // clip that was silent when Play was pressed had no node for
        // `updateGains` to reach, so un-muting it (or clearing a solo)
        // mid-preview did nothing — and the timeline's length left it out.
        for item in items {
            if let file = files[item.id], file.url == item.url,
               let node = nodes[item.id] {
                nextNodes[item.id] = node
                nextFiles[item.id] = file
                prepared.append(item)
                continue
            }
            guard let file = try? AVAudioFile(forReading: item.url) else {
                continue
            }
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode,
                           format: file.processingFormat)
            nextNodes[item.id] = node
            nextFiles[item.id] = file
            prepared.append(item)
        }
        // Anything the new list does not use — a deleted clip, or one whose
        // audio moved to another file — leaves the graph.
        for (id, node) in nodes where nextNodes[id] !== node {
            node.stop()
            engine.detach(node)
        }
        nodes = nextNodes
        files = nextFiles
        guard !prepared.isEmpty else {
            lastError = "Nothing to play"
            teardown()
            return false
        }
        // Set every pass, not just for new nodes: a reused node is carrying
        // the gain it was given last time.
        for item in prepared {
            nodes[item.id]?.volume = item.muted
                ? 0 : Float(pow(10.0, item.gainDb / 20.0))
            nodes[item.id]?.pan = Float(max(-1, min(1, item.pan)))
        }
        // Summing N clips with no normalisation clips the mixer; the mix job
        // normalises and limits, the preview does neither.
        preparedCount = prepared.count
        applyOutputVolume()
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                lastError = "Audio engine unavailable: \(error.localizedDescription)"
                teardown()
                return false
            }
        }
        // After start, not before: the mixer only resolves its output format
        // once the engine is running, and installing a tap with a 0-channel
        // format throws. Tracked rather than re-installed per pass, because
        // the graph now outlives the edit that changed it.
        if metersEnabled, !meterTapInstalled { installMeterTap() }
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
            frozenPosition = position
            state = .paused
            meterDb = nil
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
        lastError = nil
        startTick()
        return true
    }

    /// Stop the nodes (clearing their schedules) but keep the graph up.
    private func disarm() {
        tick?.invalidate()
        tick = nil
        // Every node, not just the sounding ones: `stop()` is also what
        // clears a node's scheduled segments, and since nodes now survive a
        // re-prepare, one that was scheduled against a future anchor but had
        // not started yet would otherwise keep that schedule and play the
        // pre-edit audio alongside the new.
        for node in nodes.values {
            node.stop()
        }
    }

    /// Reads peaks on the render thread, publishes on the main actor. The
    /// buffer is only touched inside the tap block — what crosses the hop is
    /// two Doubles.
    ///
    /// The block MUST be `@Sendable`. A closure written inside a `@MainActor`
    /// method inherits that isolation unless it says otherwise, and AVFAudio
    /// calls a tap on its own realtime queue: the inherited version trapped in
    /// `swift_task_checkIsolated` on the very first buffer, so arming the
    /// Editor's preview crashed the app the moment audio started.
    private func installMeterTap() {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        meterTapInstalled = true
        engine.mainMixerNode.installTap(
            onBus: 0, bufferSize: 2048, format: format
        ) { @Sendable [weak self] buffer, _ in
            guard let value = Self.peakDb(in: buffer) else { return }
            Task { @MainActor in
                guard let self, self.state == .playing else { return }
                // Gated: this fires about twenty-one times a second for the
                // length of the preview, and a level that has not moved is a
                // redraw of the meter for nothing. `MeterLevel` is a struct
                // rather than the tuple it was precisely so this comparison
                // can exist — tuples cannot be `Equatable`.
                if value != self.meterDb { self.meterDb = value }
            }
        }
    }

    /// Peak dBFS per channel for one render buffer. Pure and `nonisolated`:
    /// it runs on the audio thread, which must not touch main-actor state.
    nonisolated static func peakDb(
        in buffer: AVAudioPCMBuffer) -> MeterLevel? {
        guard let data = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return nil }
        // `vDSP_maxmgv` is the same answer as the scalar loop — the maximum
        // magnitude — vectorised. This runs on the realtime render thread, so
        // the cheaper it is the better.
        func peak(_ channel: Int) -> Double {
            var peak: Float = 0
            vDSP_maxmgv(data[channel], 1, &peak, vDSP_Length(frames))
            return Double(peak)
        }
        func db(_ v: Double) -> Double { v > 0 ? max(-80, 20 * log10(v)) : -80 }
        let left = peak(0)
        return MeterLevel(left: db(left),
                          right: db(channels > 1 ? peak(1) : left))
    }

    private func teardown() {
        // Unconditional: `metersEnabled` may have been switched off since the
        // tap went in, and removing a bus that has none is a no-op.
        engine.mainMixerNode.removeTap(onBus: 0)
        meterTapInstalled = false
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
        // This timer's only remaining job is noticing that the timeline has
        // played out. It used to publish `positionS` at 25 Hz as well — an
        // observable write, four times a second's worth of registrar traffic,
        // to a property that a grep of the whole app showed nothing reads:
        // every playhead reads `currentPosition()` on its own redraw, which
        // is what the doc comment on it said. So the property is gone and the
        // tick is as slow as end-detection actually needs; `finish()` parks
        // exactly at `durationS` regardless of when it notices.
        //
        // Added to `.common` rather than scheduled: `Timer.scheduledTimer`
        // installs in the default run loop mode only, which AppKit leaves
        // while it tracks a scroll or a menu.
        let timer = Timer(timeInterval: 0.2, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.durationS > 0,
                   self.currentPosition() >= self.durationS {
                    self.finish()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tick = timer
    }

    /// The output device changed under the engine — headphones or AirPods
    /// in or out, an interface appearing, a sample-rate change in Audio MIDI
    /// Setup. AVAudioEngine stops itself and drops its connections when that
    /// happens, and nothing here noticed: the transport kept advancing across
    /// a silent timeline until it reached the end. Rebuild the graph from
    /// nothing — the mixer's output format may have changed, and every node
    /// was connected against the old one — and pick up where it was.
    private func handleConfigurationChange() {
        guard state != .stopped else { return }
        let items = armedItems
        let position = currentPosition()
        let wasPlaying = state == .playing
        disarm()
        teardown()
        guard prepare(items: items) else {
            state = .stopped
            frozenPosition = nil
            return
        }
        if wasPlaying {
            _ = arm(from: position)
        } else {
            anchorPosition = position
            frozenPosition = position
        }
    }

    /// Everything has played out: park the playhead at the end rather than
    /// leaving `isPlaying` true forever (which it used to do).
    private func finish() {
        disarm()
        frozenPosition = durationS
        state = .paused
        meterDb = nil
    }

    /// True while any node still reports playing (used by tests).
    var anyNodePlaying: Bool {
        nodes.values.contains { $0.isPlaying }
    }
}
