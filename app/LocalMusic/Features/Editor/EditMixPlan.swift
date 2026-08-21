import Foundation

/// Turns an `EditDocument` into the one-track `mix` job that commits it —
/// always against the pristine original, never the already-edited file, so
/// quality never compounds and every step stays adjustable.
///
/// "One-track" describes the input: one source file. The spec itself carries
/// one *mix track per segment* of the edited timeline, because that is
/// exactly what the engine's mix worker already knows how to render — a
/// delete is two tracks, a paste is more, a gap is an offset the next track
/// leaves unfilled (contract §5.4).
enum EditMixPlan {

    /// The job to submit: the spec, plus the side-channel params that ride
    /// beside `mix_spec`.
    struct Plan: Equatable {
        var spec: MixSpec
        var normalize: Bool
        var limiter: Bool
        var targetLufs: Double

        /// The engine fails a `mix_spec` with no audible tracks outright
        /// ("mix_spec contains no audible tracks"). A program that silenced
        /// or deleted everything is a real thing to have typed, so the app
        /// refuses it in plain language *before* stashing a backup and
        /// uploading — see `EditorStore.renderRefusal`.
        var isRenderable: Bool { !spec.tracks.isEmpty }
    }

    /// `source` is the placeholder written into every track's `source` field
    /// (the caller swaps in the upload id, as `submitRecombine` does).
    static func plan(document: EditDocument, source: String,
                     sourceDuration: Double, sampleRate: Int,
                     sourceBpm: Double?) -> Plan {
        let segments = EditProgram.segments(sourceDuration: sourceDuration,
                                            ops: document.ops)
        let rate = document.speedRate
        let pitch = document.pitchSemitones
        // The engine's uniform stretch is a bpm ratio, so speed rides as
        // "this source at bpm B should land on a grid at B×rate". Real bpm
        // when analysed — the number is honest in provenance — else a plain
        // 120 carrier; only the ratio matters.
        let carrierBpm = sourceBpm ?? 120
        let stretching = abs(rate - 1) > 1e-6
        let effects = wireEffects(document.enabledEffects)
        let crossfadeS = max(0, document.joinCrossfadeMs) / 1000

        // Runs of contiguous same-direction same-gain segments become ONE
        // track. A split is bookkeeping — the source either side of it is
        // continuous — and two abutting tracks would each get the engine's
        // 2 ms de-click over disjoint windows, summing to a 4 ms hole in
        // audio nothing was supposed to change.
        var runs: [Run] = []
        var cursor = 0.0
        for segment in segments {
            let start = cursor
            cursor += segment.length
            guard !segment.silent else { continue }
            if var last = runs.last, last.joins(segment, at: start) {
                // A run grows at the end the source is travelling towards:
                // forwards that is `sourceEnd`, backwards it is
                // `sourceStart`. Growing the wrong one silently drops the
                // material the run started from.
                if segment.reversed {
                    last.sourceStart = segment.sourceStart
                } else {
                    last.sourceEnd = segment.sourceEnd
                }
                last.timelineEnd = cursor
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(timelineStart: start, timelineEnd: cursor,
                                sourceStart: segment.sourceStart,
                                sourceEnd: segment.sourceEnd,
                                reversed: segment.reversed,
                                gainDb: segment.gainDb,
                                followsGap: hasGap(before: start,
                                                   in: segments)))
            }
        }

        var tracks: [MixSpec.Track] = []
        for (index, run) in runs.enumerated() {
            tracks.append(MixSpec.Track(
                source: source,
                role: "edit-\(index + 1)",
                gainDb: run.gainDb,
                mute: false,
                offsetS: run.timelineStart / rate,
                section: MixSpec.Section(startS: run.sourceStart,
                                         endS: run.sourceEnd),
                fadeInS: nil, fadeOutS: nil,
                fadeInCurve: nil, fadeOutCurve: nil,
                sourceBpm: stretching ? carrierBpm : nil,
                sourceDownbeats: nil,
                stretch: MixSpec.Stretch(
                    mode: stretching ? "uniform" : "none",
                    transientMode: "smooth",
                    preserveFormants: true),
                pitchShiftSt: pitch,
                reverse: run.reversed ? true : nil,
                effects: effects.isEmpty ? nil : effects))
        }

        // Crossfades at discontinuous joins: extend both sides into source
        // material that exists, complementary linear ramps over the overlap.
        // Contiguous same-direction same-gain neighbours are one unbroken
        // stretch of the source split only by bookkeeping — no join to mask.
        // Every remaining join IS a discontinuity (the runs above already
        // absorbed the continuous ones), so each gets the same treatment:
        // lap the two sides into source material that exists and let the
        // complementary linear ramps sum back to unity.
        //
        // Never below the engine's own 2 ms de-click: two butt-joined
        // sections each fade to zero over disjoint windows, which is a hole
        // rather than a splice. `crossfadeJoins` off means "as short as is
        // honest", not "none".
        let minOverlapS = Self.engineEdgeFadeS * 2
        for i in tracks.indices.dropLast() {
            let a = runs[i], b = runs[i + 1]
            guard !b.followsGap else { continue }   // silence sits between
            let want = max(minOverlapS, crossfadeS)
            let budget = min(want, min(a.length, b.length) / rate) / 2
            let wantSource = budget * rate
            let extendA: Double
            if a.reversed {
                extendA = min(wantSource, a.sourceStart)
                tracks[i].section?.startS -= extendA
            } else {
                extendA = min(wantSource,
                              max(0, sourceDuration - a.sourceEnd))
                tracks[i].section?.endS += extendA
            }
            let extendB: Double
            if b.reversed {
                extendB = min(wantSource,
                              max(0, sourceDuration - b.sourceEnd))
                tracks[i + 1].section?.endS += extendB
            } else {
                extendB = min(wantSource, b.sourceStart)
                tracks[i + 1].section?.startS -= extendB
            }
            let overlap = (extendA + extendB) / rate
            guard overlap > 1e-9 else { continue }
            tracks[i].fadeOutS = overlap
            tracks[i + 1].fadeInS = overlap
            // Pulling the second track earlier must never take it below
            // zero — the engine fails the job on a negative offset_s.
            tracks[i + 1].offsetS = max(0, tracks[i + 1].offsetS
                                        - extendB / rate)
        }

        // The audible head/tail fades. Two conversions matter: the ramps are
        // authored in timeline seconds but the engine applies them AFTER
        // stretching, so they go out divided by the rate; and they attach to
        // the first and last AUDIBLE track, which is what the well draws
        // them against too (see `EditorStore.fadeAnchors`).
        if let fadeIn = document.fadeIn, !tracks.isEmpty,
           let length = targetLength(tracks[0], rate: rate) {
            tracks[0].fadeInS = min(fadeIn.seconds / rate, length)
            tracks[0].fadeInCurve = fadeIn.curve == .linear
                ? nil : fadeIn.curve.rawValue
        }
        if let fadeOut = document.fadeOut, !tracks.isEmpty,
           let length = targetLength(tracks[tracks.count - 1], rate: rate) {
            tracks[tracks.count - 1].fadeOutS = min(fadeOut.seconds / rate,
                                                    length)
            tracks[tracks.count - 1].fadeOutCurve = fadeOut.curve == .linear
                ? nil : fadeOut.curve.rawValue
        }

        let normalize = document.normalizeLufs != nil
        let amplifiesUp = document.ops.contains { op in
            if case .amplify(_, let db) = op.kind { return db > 0 }
            return false
        }
        let duration = EditProgram.timelineDuration(segments) / rate
        let spec = MixSpec(
            target: MixSpec.Target(
                bpm: stretching ? carrierBpm * rate : nil,
                key: nil,
                sampleRate: document.resampleHz ?? sampleRate,
                downbeats: nil,
                durationS: duration > 0 ? duration : nil),
            tracks: tracks)
        return Plan(spec: spec,
                    normalize: normalize,
                    // Levelling engages the safety limiter (the design's
                    // "both end in the same limiter at −1 dBTP"); a program
                    // that never raises gain passes through untouched.
                    limiter: normalize || amplifiesUp,
                    targetLufs: document.normalizeLufs ?? -14)
    }

    /// One stretch of the edited timeline that renders as a single mix
    /// track: a run of segments the source runs straight through.
    private struct Run {
        var timelineStart: Double
        var timelineEnd: Double
        var sourceStart: Double
        var sourceEnd: Double
        var reversed: Bool
        var gainDb: Double
        /// Whether silence sits immediately before this run — a join across
        /// a gap is not a join, and must not be lapped shut.
        var followsGap: Bool

        var length: Double { max(0, timelineEnd - timelineStart) }

        /// Whether `next`, starting at `start`, is the same unbroken stretch
        /// of source at the same level and in the same direction.
        func joins(_ next: EditSegment, at start: Double) -> Bool {
            guard abs(start - timelineEnd) < 1e-9,
                  next.reversed == reversed,
                  abs(next.gainDb - gainDb) < 1e-9 else { return false }
            return reversed
                ? abs(next.sourceEnd - sourceStart) < 1e-9
                : abs(next.sourceStart - sourceEnd) < 1e-9
        }
    }

    /// `EDGE_FADE_S` in the dsp adapter: the de-click every `section` trim
    /// gets whether or not the caller asked for a crossfade.
    static let engineEdgeFadeS = 0.002

    private static func hasGap(before timelineStart: Double,
                               in segments: [EditSegment]) -> Bool {
        var cursor = 0.0
        for segment in segments {
            let end = cursor + segment.length
            if abs(end - timelineStart) < 1e-9 { return segment.silent }
            cursor = end
        }
        return false
    }

    private static func targetLength(_ track: MixSpec.Track,
                                     rate: Double) -> Double? {
        guard let section = track.section else { return nil }
        return max(0, section.endS - section.startS) / rate
    }

    private static func wireEffects(_ settings: [EffectSetting]) -> [MixSpec.Effect] {
        settings.map { fx in
            switch fx.kind {
            case .highpass, .lowpass:
                MixSpec.Effect(type: fx.kind.rawValue, cutoffHz: fx.cutoffHz)
            case .eq3:
                MixSpec.Effect(type: "eq3", lowDb: fx.lowDb, midDb: fx.midDb,
                               highDb: fx.highDb)
            case .compressor:
                MixSpec.Effect(type: "compressor",
                               thresholdDb: fx.thresholdDb, ratio: fx.ratio,
                               attackMs: fx.attackMs, releaseMs: fx.releaseMs)
            case .gate:
                MixSpec.Effect(type: "gate", thresholdDb: fx.thresholdDb)
            }
        }
    }
}
