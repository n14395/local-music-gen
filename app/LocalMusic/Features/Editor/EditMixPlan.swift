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

        var tracks: [MixSpec.Track] = []
        var trackSegmentIndex: [Int] = []   // segments index per track
        var cursor = 0.0                    // edit-time position
        for (index, segment) in segments.enumerated() {
            defer { cursor += segment.length }
            guard !segment.silent else { continue }
            tracks.append(MixSpec.Track(
                source: source,
                role: "edit-\(tracks.count + 1)",
                gainDb: segment.gainDb,
                mute: false,
                offsetS: cursor / rate,
                section: MixSpec.Section(startS: segment.sourceStart,
                                         endS: segment.sourceEnd),
                fadeInS: nil, fadeOutS: nil,
                fadeInCurve: nil, fadeOutCurve: nil,
                sourceBpm: stretching ? carrierBpm : nil,
                sourceDownbeats: nil,
                stretch: MixSpec.Stretch(
                    mode: stretching ? "uniform" : "none",
                    transientMode: "smooth",
                    preserveFormants: true),
                pitchShiftSt: pitch,
                reverse: segment.reversed ? true : nil,
                effects: effects.isEmpty ? nil : effects))
            trackSegmentIndex.append(index)
        }

        // Crossfades at discontinuous joins: extend both sides into source
        // material that exists, complementary linear ramps over the overlap.
        // Contiguous same-direction same-gain neighbours are one unbroken
        // stretch of the source split only by bookkeeping — no join to mask.
        if crossfadeS > 0 {
            for i in tracks.indices.dropLast() {
                let a = trackSegmentIndex[i]
                let b = trackSegmentIndex[i + 1]
                guard b == a + 1 else { continue }   // a gap sits between
                let segA = segments[a]
                let segB = segments[b]
                if !segA.reversed && !segB.reversed
                    && abs(segA.sourceEnd - segB.sourceStart) < 1e-9
                    && abs(segA.gainDb - segB.gainDb) < 1e-9 {
                    continue
                }
                let want = min(crossfadeS,
                               min(segA.length, segB.length) / rate) / 2
                let wantSource = want * rate
                let extendA: Double
                if segA.reversed {
                    extendA = min(wantSource, segA.sourceStart)
                    tracks[i].section?.startS -= extendA
                } else {
                    extendA = min(wantSource,
                                  max(0, sourceDuration - segA.sourceEnd))
                    tracks[i].section?.endS += extendA
                }
                let extendB: Double
                if segB.reversed {
                    extendB = min(wantSource,
                                  max(0, sourceDuration - segB.sourceEnd))
                    tracks[i + 1].section?.endS += extendB
                } else {
                    extendB = min(wantSource, segB.sourceStart)
                    tracks[i + 1].section?.startS -= extendB
                }
                let overlap = (extendA + extendB) / rate
                guard overlap > 1e-6 else { continue }
                tracks[i].fadeOutS = overlap
                tracks[i + 1].fadeInS = overlap
                tracks[i + 1].offsetS -= extendB / rate
            }
        }

        // The audible head/tail fades, clamped to the track that carries
        // them: the engine's ramps cannot start mid-gain, so a fade longer
        // than its end segment fades that whole segment (the store surfaces
        // the clamp; see EditorStore).
        if let fadeIn = document.fadeIn, !tracks.isEmpty,
           let length = targetLength(tracks[0], rate: rate) {
            tracks[0].fadeInS = min(fadeIn.seconds, length)
            tracks[0].fadeInCurve = fadeIn.curve == .linear
                ? nil : fadeIn.curve.rawValue
        }
        if let fadeOut = document.fadeOut, !tracks.isEmpty,
           let length = targetLength(tracks[tracks.count - 1], rate: rate) {
            tracks[tracks.count - 1].fadeOutS = min(fadeOut.seconds, length)
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
