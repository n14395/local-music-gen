import Foundation

/// How long a clip is once the engine has had it.
///
/// This exists so there is exactly ONE answer in the codebase: the timeline
/// draws with it, the preview arms with it, and a test pins it against a real
/// engine render. Anywhere it is recomputed by hand, the picture starts
/// disagreeing with the mix, which is the failure mode a timeline exposes
/// fastest.
enum TimelineGeometry {

    /// Source seconds a clip consumes after its trim, or nil when the source
    /// length isn't known yet (analysis pending / duration not probed).
    static func sourceLengthS(sectionStartS: Double?, sectionEndS: Double?,
                              sourceDurationS: Double?) -> Double? {
        if let start = sectionStartS, let end = sectionEndS, end > start {
            return end - start
        }
        // A one-sided trim never reaches the wire (planMix only emits a section
        // when both bounds are set), so it must not shorten the drawing either.
        return sourceDurationS
    }

    /// Whether the mix will time-stretch this clip. Mirrors planMix: auto-match
    /// on, both tempos known. Quality never gates it — a stretch too big to
    /// recommend still happens, it just gets a red badge.
    static func stretches(sourceBpm: Double?, targetBpm: Double?,
                          autoMatchTempo: Bool) -> Bool {
        autoMatchTempo && sourceBpm != nil && targetBpm != nil
    }

    /// Seconds the clip occupies on the target timeline.
    ///
    /// The dsp adapter stretches by `target_bpm / source_bpm` (adapter.py:120),
    /// and pedalboard's factor > 1 means faster/shorter — so a stretched clip
    /// keeps its BEAT count and loses seconds, while an unstretched one keeps
    /// its seconds and its beat count changes.
    static func timelineLengthS(sourceLengthS: Double, sourceBpm: Double?,
                                targetBpm: Double?,
                                autoMatchTempo: Bool) -> Double {
        guard stretches(sourceBpm: sourceBpm, targetBpm: targetBpm,
                        autoMatchTempo: autoMatchTempo),
              let source = sourceBpm, let target = targetBpm,
              source > 0, target > 0 else { return sourceLengthS }
        return sourceLengthS * source / target
    }

    /// The same length expressed in target beats — the unit clips are placed
    /// in, so lengths and offsets can be added without a second conversion.
    static func timelineLengthBeats(sourceLengthS: Double, sourceBpm: Double?,
                                    targetBpm: Double?, autoMatchTempo: Bool,
                                    fallbackBpm: Double = 120) -> Double {
        let seconds = timelineLengthS(sourceLengthS: sourceLengthS,
                                      sourceBpm: sourceBpm,
                                      targetBpm: targetBpm,
                                      autoMatchTempo: autoMatchTempo)
        let bpm = targetBpm ?? fallbackBpm
        guard bpm > 0 else { return 0 }
        return seconds * bpm / 60.0
    }
}
