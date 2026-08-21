import Foundation

// The Editor's non-destructive edit program — the pure half of the feature.
// Nothing in this file touches audio, files or views: an `EditDocument` is
// replayed into `[EditSegment]` (what to play, in order, from the pristine
// source), and `EditMixPlan` turns that into the one-track `mix` job that
// commits it. Both are deterministic, so the same stored document always
// renders the same audio — which is the entire warranty behind "edits stay
// adjustable" and "revert works forever".

/// A closed range on a timeline, in seconds. Not `ClosedRange` because edit
/// documents are stored JSON and this shape has to stay decodable forever.
struct EditRange: Codable, Equatable {
    var start: Double
    var end: Double

    var length: Double { max(0, end - start) }

    init(start: Double, end: Double) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

/// How a fade's gain moves through its ramp. Raw values are the wire words
/// the engine's `fade_in_curve`/`fade_out_curve` accept.
enum FadeCurve: String, Codable, CaseIterable {
    case linear, scurve, log

    var label: String {
        switch self {
        case .linear: "Linear"
        case .scurve: "S-curve"
        case .log: "Log"
        }
    }
}

/// One step of the program. Steps are replayed in order against the timeline
/// *as the previous steps left it* — a delete's times mean what the ruler
/// showed when the delete was made, and editing an earlier row later re-times
/// everything after it, which is what "reopen and change any step" means.
struct EditOp: Codable, Equatable, Identifiable {
    /// Timeline steps reshape the segment list; whole-track steps ride on the
    /// render. `paste` carries resolved *source* slices rather than a
    /// reference to what was on the clipboard's timeline range, so a paste
    /// keeps pasting the same material however the rows around it change.
    enum Kind: Codable, Equatable {
        case trim(EditRange)
        case delete(EditRange)
        case silence(EditRange)
        case insertGap(at: Double, seconds: Double)
        case splitAt(Double)
        case paste(at: Double, slices: [EditSegment])
        case reverse(EditRange)
        case amplify(EditRange, db: Double)
        case fadeIn(seconds: Double, curve: FadeCurve)
        case fadeOut(seconds: Double, curve: FadeCurve)
        case normalize(lufs: Double)
        case speed(rate: Double)
        case pitch(semitones: Double)
        case resample(hz: Int)
    }

    var id: UUID
    var kind: Kind

    init(id: UUID = UUID(), kind: Kind) {
        self.id = id
        self.kind = kind
    }

    /// Whether this step reshapes the timeline (and therefore re-times every
    /// row after it) or rides whole on the render.
    var reshapesTimeline: Bool {
        switch kind {
        case .trim, .delete, .silence, .insertGap, .splitAt, .paste,
             .reverse, .amplify:
            true
        case .fadeIn, .fadeOut, .normalize, .speed, .pitch, .resample:
            false
        }
    }
}

/// A stretch of the edited timeline: which slice of the source plays there,
/// which way, how loud — or silence. This is both the evaluator's working
/// state and the payload a paste stores, which is why it is Codable.
struct EditSegment: Codable, Equatable {
    var sourceStart: Double
    var sourceEnd: Double
    var reversed: Bool
    var gainDb: Double
    var silent: Bool

    init(sourceStart: Double, sourceEnd: Double, reversed: Bool = false,
         gainDb: Double = 0, silent: Bool = false) {
        self.sourceStart = sourceStart
        self.sourceEnd = sourceEnd
        self.reversed = reversed
        self.gainDb = gainDb
        self.silent = silent
    }

    var length: Double { max(0, sourceEnd - sourceStart) }

    static func gap(_ seconds: Double) -> EditSegment {
        EditSegment(sourceStart: 0, sourceEnd: max(0, seconds), silent: true)
    }
}

/// One processor in the whole-track chain (Tier 3.2). A flat struct rather
/// than an enum-with-payloads so a card's sliders bind to plain fields; the
/// unused fields for a kind are simply never shown or sent.
struct EffectSetting: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case highpass, lowpass, eq3, compressor, gate

        var label: String {
            switch self {
            case .highpass: "High-pass"
            case .lowpass: "Low-pass"
            case .eq3: "EQ"
            case .compressor: "Compressor"
            case .gate: "Noise gate"
            }
        }
    }

    var id: UUID
    var kind: Kind
    var enabled: Bool
    var cutoffHz: Double
    var lowDb: Double
    var midDb: Double
    var highDb: Double
    var thresholdDb: Double
    var ratio: Double
    var attackMs: Double
    var releaseMs: Double

    init(id: UUID = UUID(), kind: Kind, enabled: Bool = true,
         cutoffHz: Double = 0, lowDb: Double = 0, midDb: Double = 0,
         highDb: Double = 0, thresholdDb: Double = 0, ratio: Double = 3,
         attackMs: Double = 8, releaseMs: Double = 120) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.cutoffHz = cutoffHz
        self.lowDb = lowDb
        self.midDb = midDb
        self.highDb = highDb
        self.thresholdDb = thresholdDb
        self.ratio = ratio
        self.attackMs = attackMs
        self.releaseMs = releaseMs
    }

    /// A freshly added processor, at the values the design's cards show.
    static func fresh(_ kind: Kind) -> EffectSetting {
        switch kind {
        case .highpass:
            EffectSetting(kind: .highpass, cutoffHz: 80)
        case .lowpass:
            EffectSetting(kind: .lowpass, cutoffHz: 18000)
        case .eq3:
            EffectSetting(kind: .eq3)
        case .compressor:
            EffectSetting(kind: .compressor, thresholdDb: -18)
        case .gate:
            EffectSetting(kind: .gate, thresholdDb: -54)
        }
    }
}

/// Everything the Editor stores about one track: the program, the chain, and
/// the facts about the original that outlive it. This is what `editsJSON`
/// holds — decoded leniently so a document written by any version reads.
struct EditDocument: Codable, Equatable {
    var version: Int = 1
    var ops: [EditOp] = []
    var effects: [EffectSetting] = []
    /// Milliseconds of overlap at every discontinuous join (Tier 2.6). Zero
    /// disables — the engine's 2 ms de-click still applies either way.
    var joinCrossfadeMs: Double = 8
    /// When this exact program was last rendered into the file; nil while it
    /// is only pending. The Library's badge and filter read this.
    var appliedAt: Date?
    /// The original's shape, recorded when the backup is stashed — so the
    /// inspector can say "1:44.60 was 1:59.00" without opening the backup.
    var originalDurationS: Double?
    /// The file name the track had before its first apply. An apply always
    /// renders WAV, so an imported mp3's fileName changes; revert restores it.
    var originalFileName: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        ops = try c.decodeIfPresent([EditOp].self, forKey: .ops) ?? []
        effects = try c.decodeIfPresent([EffectSetting].self,
                                        forKey: .effects) ?? []
        joinCrossfadeMs = try c.decodeIfPresent(
            Double.self, forKey: .joinCrossfadeMs) ?? 8
        appliedAt = try c.decodeIfPresent(Date.self, forKey: .appliedAt)
        originalDurationS = try c.decodeIfPresent(
            Double.self, forKey: .originalDurationS)
        originalFileName = try c.decodeIfPresent(
            String.self, forKey: .originalFileName)
    }

    var enabledEffects: [EffectSetting] { effects.filter(\.enabled) }

    /// What "Apply N edits" counts: program steps, plus the chain as one.
    var editCount: Int { ops.count + (enabledEffects.isEmpty ? 0 : 1) }

    var isEmpty: Bool { ops.isEmpty && enabledEffects.isEmpty }

    // MARK: whole-track readings (last row of each kind wins)

    var fadeIn: (seconds: Double, curve: FadeCurve)? {
        for op in ops.reversed() {
            if case .fadeIn(let seconds, let curve) = op.kind {
                return (seconds, curve)
            }
        }
        return nil
    }

    var fadeOut: (seconds: Double, curve: FadeCurve)? {
        for op in ops.reversed() {
            if case .fadeOut(let seconds, let curve) = op.kind {
                return (seconds, curve)
            }
        }
        return nil
    }

    var normalizeLufs: Double? {
        for op in ops.reversed() {
            if case .normalize(let lufs) = op.kind { return lufs }
        }
        return nil
    }

    var speedRate: Double {
        for op in ops.reversed() {
            if case .speed(let rate) = op.kind, rate > 0 { return rate }
        }
        return 1
    }

    var pitchSemitones: Double {
        for op in ops.reversed() {
            if case .pitch(let semitones) = op.kind { return semitones }
        }
        return 0
    }

    var resampleHz: Int? {
        for op in ops.reversed() {
            if case .resample(let hz) = op.kind { return hz }
        }
        return nil
    }
}

// MARK: - Evaluation

/// Replays a program into segments and answers the geometry questions the
/// screen asks (where is source beat N on the edited timeline, what source
/// second is under the playhead). Pure and cheap: rebuild on every change.
enum EditProgram {

    /// The segment list a document plays, before speed is applied.
    static func segments(sourceDuration: Double,
                         ops: [EditOp]) -> [EditSegment] {
        var segments = [EditSegment(sourceStart: 0, sourceEnd: max(0, sourceDuration))]
        for op in ops {
            segments = apply(op.kind, to: segments)
        }
        return segments.filter { $0.length > 1e-9 }
    }

    /// The edited timeline's length before speed; multiply by 1/rate for the
    /// duration that renders.
    static func timelineDuration(_ segments: [EditSegment]) -> Double {
        segments.reduce(0) { $0 + $1.length }
    }

    /// What a document renders to, in seconds.
    static func resultDuration(sourceDuration: Double,
                               document: EditDocument) -> Double {
        timelineDuration(segments(sourceDuration: sourceDuration,
                                  ops: document.ops)) / document.speedRate
    }

    // MARK: one step

    static func apply(_ kind: EditOp.Kind,
                      to segments: [EditSegment]) -> [EditSegment] {
        let duration = timelineDuration(segments)
        switch kind {
        case .trim(let range):
            let r = clamp(range, to: duration)
            guard r.length > 0 else { return segments }
            return extract(segments, range: r)
        case .delete(let range):
            let r = clamp(range, to: duration)
            guard r.length > 0 else { return segments }
            var out = extract(segments, range: EditRange(start: 0, end: r.start))
            out += extract(segments, range: EditRange(start: r.end, end: duration))
            return out
        case .silence(let range):
            let r = clamp(range, to: duration)
            guard r.length > 0 else { return segments }
            var out = extract(segments, range: EditRange(start: 0, end: r.start))
            out.append(.gap(r.length))
            out += extract(segments, range: EditRange(start: r.end, end: duration))
            return out
        case .insertGap(let at, let seconds):
            guard seconds > 0 else { return segments }
            let t = min(max(0, at), duration)
            var out = extract(segments, range: EditRange(start: 0, end: t))
            out.append(.gap(seconds))
            out += extract(segments, range: EditRange(start: t, end: duration))
            return out
        case .splitAt(let at):
            // A razor cut: pure bookkeeping. The two halves are contiguous
            // source, so nothing sounds different — but the boundary becomes
            // a region edge the selection can land on, and the join marker
            // the well draws.
            let t = min(max(0, at), duration)
            guard t > 1e-9, t < duration - 1e-9 else { return segments }
            var out = extract(segments, range: EditRange(start: 0, end: t))
            out += extract(segments, range: EditRange(start: t, end: duration))
            return out
        case .paste(let at, let slices):
            guard !slices.isEmpty else { return segments }
            let t = min(max(0, at), duration)
            var out = extract(segments, range: EditRange(start: 0, end: t))
            out += slices
            out += extract(segments, range: EditRange(start: t, end: duration))
            return out
        case .reverse(let range):
            let r = clamp(range, to: duration)
            guard r.length > 0 else { return segments }
            var out = extract(segments, range: EditRange(start: 0, end: r.start))
            let covered = extract(segments, range: r)
            out += covered.reversed().map { segment in
                var flipped = segment
                flipped.reversed.toggle()
                return flipped
            }
            out += extract(segments, range: EditRange(start: r.end, end: duration))
            return out
        case .amplify(let range, let db):
            let r = clamp(range, to: duration)
            guard r.length > 0 else { return segments }
            var out = extract(segments, range: EditRange(start: 0, end: r.start))
            // SETS the level rather than adding to it. The control is a
            // slider reading "this region is at +2.5 dB", so two rows over
            // the same audio must not silently render +5 — and after a cut
            // has re-timed the ruler there is no reliable way to recognise
            // "the same audio" by its numbers alone.
            out += extract(segments, range: r).map { segment in
                var louder = segment
                if !louder.silent { louder.gainDb = db }
                return louder
            }
            out += extract(segments, range: EditRange(start: r.end, end: duration))
            return out
        case .fadeIn, .fadeOut, .normalize, .speed, .pitch, .resample:
            return segments   // whole-track: applied at render, not here
        }
    }

    /// The sub-segments covering a timeline range — the workhorse every
    /// timeline step is built from, and what copy resolves the clipboard with.
    static func extract(_ segments: [EditSegment],
                        range: EditRange) -> [EditSegment] {
        var out: [EditSegment] = []
        var cursor = 0.0
        for segment in segments {
            let segStart = cursor
            let segEnd = cursor + segment.length
            cursor = segEnd
            let lo = max(segStart, range.start)
            let hi = min(segEnd, range.end)
            guard hi - lo > 1e-9 else { continue }
            out.append(slice(segment, from: lo - segStart, to: hi - segStart))
        }
        return out
    }

    /// The piece of one segment between two offsets into *its own* timeline
    /// extent. Reversed segments index their source from the far end: offset
    /// u into a reversed [s0,s1] is playing source s1−u.
    static func slice(_ segment: EditSegment, from: Double,
                      to: Double) -> EditSegment {
        var out = segment
        if segment.silent {
            out.sourceStart = 0
            out.sourceEnd = to - from
        } else if segment.reversed {
            out.sourceStart = segment.sourceEnd - to
            out.sourceEnd = segment.sourceEnd - from
        } else {
            out.sourceStart = segment.sourceStart + from
            out.sourceEnd = segment.sourceStart + to
        }
        return out
    }

    // MARK: mapping

    /// Source second → edited-timeline second (pre-speed), or nil if that
    /// moment was cut out. First match wins when a paste repeats material.
    static func sourceToTimeline(_ s: Double,
                                 in segments: [EditSegment]) -> Double? {
        var cursor = 0.0
        for segment in segments {
            defer { cursor += segment.length }
            guard !segment.silent,
                  s >= segment.sourceStart - 1e-9,
                  s <= segment.sourceEnd + 1e-9 else { continue }
            return segment.reversed
                ? cursor + (segment.sourceEnd - s)
                : cursor + (s - segment.sourceStart)
        }
        return nil
    }

    /// Edited-timeline second (pre-speed) → source second, or nil over a gap.
    static func timelineToSource(_ t: Double,
                                 in segments: [EditSegment]) -> Double? {
        var cursor = 0.0
        for segment in segments {
            let next = cursor + segment.length
            if t >= cursor - 1e-9 && t < next + 1e-9 {
                guard !segment.silent else { return nil }
                let u = t - cursor
                return segment.reversed ? segment.sourceEnd - u
                                        : segment.sourceStart + u
            }
            cursor = next
        }
        return nil
    }

    /// Timeline positions where one segment ends and the next begins —
    /// the region boundaries a split creates and a double-click selects
    /// between (0 and the duration are implied edges).
    static func boundaries(_ segments: [EditSegment]) -> [Double] {
        var out: [Double] = [0]
        var cursor = 0.0
        for segment in segments {
            cursor += segment.length
            out.append(cursor)
        }
        return out
    }

    private static func clamp(_ range: EditRange,
                              to duration: Double) -> EditRange {
        EditRange(start: min(max(0, range.start), duration),
                  end: min(max(0, range.end), duration))
    }
}
