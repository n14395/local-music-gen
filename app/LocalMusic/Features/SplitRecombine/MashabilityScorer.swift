import Foundation

/// Compact musical profile of a song or part, decoded from its stored
/// AnalysisRecord. Everything is optional — scoring degrades to neutral when a
/// signal is missing rather than blocking the workbench.
struct AnalysisSummary: Equatable {
    var bpm: Double?
    var camelot: String?
    var downbeats: [Double]?
    var chroma: [[Int]]?
    var bandEnergy: [Double]?
    var clap: [Double]?

    init(bpm: Double? = nil, camelot: String? = nil,
         downbeats: [Double]? = nil, chroma: [[Int]]? = nil,
         bandEnergy: [Double]? = nil, clap: [Double]? = nil) {
        self.bpm = bpm
        self.camelot = camelot
        self.downbeats = downbeats
        self.chroma = chroma
        self.bandEnergy = bandEnergy
        self.clap = clap
    }

    init?(record: AnalysisRecord?) {
        guard let record else { return nil }
        let payload = try? BackendClient.decoder.decode(
            AnalysisPayload.self, from: Data(record.analysisJSON.utf8))
        bpm = record.bpm ?? payload?.tempoBpm
        camelot = record.camelot ?? payload?.camelot
        downbeats = payload?.downbeats
        chroma = payload?.chroma
        bandEnergy = payload?.bandEnergy
        clap = payload?.clap
    }
}

enum MatchQuality { case green, amber, red }

struct TempoMatch: Equatable {
    var score: Double            // 1.0 identical … 0 hopeless
    var stretchRatio: Double     // factor applied to the source (>1 = speed up)
    var stretchPercent: Double   // |ratio − 1| × 100
    var halfTimeFold: Bool       // matched via double/half-time interpretation
    /// The tempo this match is expressed against: the source BPM, or its
    /// double/half when folding found a closer fit. The mix must be told THIS
    /// number — the engine recomputes target/source itself, so handing it the
    /// unfolded BPM would double-time a half-time source while the badge here
    /// claims no stretch at all.
    var foldedSourceBpm: Double

    func quality(forDrums: Bool = false) -> MatchQuality {
        let amberCap = forDrums ? 10.0 : 12.0
        let eps = 1e-9   // 112/100 must land in the ≤12% band, not float past it
        if stretchPercent <= 5.0 + eps { return .green }
        if stretchPercent <= amberCap + eps { return .amber }
        return .red
    }

    /// Actionable advice when a stretch is out of budget. Drums smear audibly
    /// past their band, so the fix is different material, not a bigger stretch.
    func hint(forDrums: Bool) -> String? {
        guard forDrums, quality(forDrums: true) == .red else { return nil }
        return "Too big a stretch for drums — re-quantize or pick a closer tempo"
    }
}

struct KeyMatch: Equatable {
    var score: Double
    var pitchShiftSt: Double     // semitones to apply to the source (0 = none)

    var quality: MatchQuality {
        if score >= 0.8 && pitchShiftSt == 0 { return .green }
        if score > 0 { return .amber }
        return .red
    }
}

struct MatchBadges: Equatable {
    var tempo: TempoMatch?
    var key: KeyMatch?
    var harmonic: Double?        // 0…1 chroma agreement (nil = unknown)
    var spectral: Double?        // 0…1 band complementarity (nil = unknown)
    var timbre: Double? = nil    // 0…1 CLAP similarity (nil = unknown)
    var stars: Double            // 0…5 overall
}

/// What auto-match will actually do to a source to sit on the target grid.
struct MatchPlan: Equatable {
    var stretchRatio: Double?    // nil = no tempo adjustment possible/needed
    var pitchShiftSt: Double
    var badges: MatchBadges
}

/// Pure scoring math for "what mashes with what" — all inputs come from stored
/// analysis, so this runs instantly on the main thread for UI badges.
enum Mashability {

    // MARK: camelot

    static func parseCamelot(_ code: String?) -> (number: Int, minor: Bool)? {
        guard let code, code.count >= 2,
              let number = Int(code.dropLast()),
              (1...12).contains(number) else { return nil }
        switch code.last {
        case "A", "a": return (number, true)
        case "B", "b": return (number, false)
        default: return nil
        }
    }

    /// Base compatibility of two camelot codes with no pitch shifting.
    private static func baseScore(_ a: (number: Int, minor: Bool),
                                  _ b: (number: Int, minor: Bool)) -> Double {
        if a == b { return 1.0 }
        if a.number == b.number { return 0.9 }          // relative major/minor
        let dist = min((a.number - b.number + 12) % 12,
                       (b.number - a.number + 12) % 12)
        if dist == 1 && a.minor == b.minor { return 0.8 }
        return 0.0
    }

    /// Best key relationship achievable with at most ±2 semitones of shift on
    /// the source (each semitone moves the camelot number by +7 mod 12 and
    /// costs ×0.9).
    static func keyMatch(source: String?, target: String?) -> KeyMatch? {
        guard let src = parseCamelot(source), let tgt = parseCamelot(target)
        else { return nil }
        var best = KeyMatch(score: baseScore(src, tgt), pitchShiftSt: 0)
        for shift in [-2, -1, 1, 2] where best.score < 1.0 {
            let shifted = (number: ((src.number - 1 + 7 * shift) % 12 + 12) % 12 + 1,
                           minor: src.minor)
            let score = baseScore(shifted, tgt)
                * pow(0.9, Double(abs(shift)))
            if score > best.score {
                best = KeyMatch(score: score, pitchShiftSt: Double(shift))
            }
        }
        return best
    }

    // MARK: tempo

    static func tempoMatch(source: Double?, target: Double?) -> TempoMatch? {
        guard let source, let target, source > 0, target > 0 else { return nil }
        // fold at the octave: a 70 BPM ballad can ride a 140 BPM grid
        let candidates: [(bpm: Double, folded: Bool)] =
            [(source, false), (source * 2, true), (source / 2, true)]
        let best = candidates.min {
            abs(log2(target / $0.bpm)) < abs(log2(target / $1.bpm))
        }!
        let ratio = target / best.bpm
        let percent = abs(ratio - 1.0) * 100.0
        let score = max(0.0, 1.0 - percent / 25.0)
        return TempoMatch(score: score, stretchRatio: ratio,
                          stretchPercent: percent, halfTimeFold: best.folded,
                          foldedSourceBpm: best.bpm)
    }

    // MARK: spectral features

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let dot = zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        let na = (a.reduce(0) { $0 + $1 * $1 }).squareRoot()
        let nb = (b.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard na > 0, nb > 0 else { return nil }
        return dot / (na * nb)
    }

    /// Chroma agreement maximized over bar offsets (0…1, nil when unknown).
    static func harmonic(source: [[Int]]?, target: [[Int]]?) -> Double? {
        guard let source, let target, source.count >= 4, target.count >= 4
        else { return nil }
        let window = min(64, source.count, target.count)
        var best = -1.0
        for offset in 0..<min(16, target.count) {
            var sims: [Double] = []
            for i in 0..<window {
                let t = (i + offset) % target.count
                if let sim = cosine(source[i].map(Double.init),
                                    target[t].map(Double.init)) {
                    sims.append(sim)
                }
            }
            if !sims.isEmpty {
                best = max(best, sims.reduce(0, +) / Double(sims.count))
            }
        }
        return best < 0 ? nil : max(0.0, min(1.0, best))
    }

    /// Spectral complementarity: parts that occupy different bands stack
    /// cleanly (1 = fully complementary, 0 = fighting for the same bands).
    static func spectral(source: [Double]?, target: [Double]?) -> Double? {
        guard let source, let target,
              let sim = cosine(source, target) else { return nil }
        return max(0.0, min(1.0, 1.0 - sim))
    }

    /// Timbral similarity from CLAP embeddings (analysis-clap variant): songs
    /// that *sound* alike mash more naturally. 0…1; nil when either side has
    /// no embedding.
    static func timbre(source: [Double]?, target: [Double]?) -> Double? {
        guard let source, let target, source.count == 512,
              target.count == 512, let sim = cosine(source, target)
        else { return nil }
        return max(0.0, min(1.0, sim))
    }

    // MARK: overall

    static func plan(source: AnalysisSummary, target: AnalysisSummary,
                     isDrums: Bool = false) -> MatchPlan {
        let tempo = tempoMatch(source: source.bpm, target: target.bpm)
        let key = keyMatch(source: source.camelot, target: target.camelot)
        let harm = harmonic(source: source.chroma, target: target.chroma)
        let spec = spectral(source: source.bandEnergy, target: target.bandEnergy)
        let timb = timbre(source: source.clap, target: target.clap)

        // weighted product; unknown signals contribute a neutral 0.6 so a
        // fully-analyzed pair can outrank an unknown one but absence never
        // zeroes the score. The CLAP term is a pure refinement: its absent
        // case multiplies by 1.0 so SR2-era scores are unchanged when no
        // embedding exists.
        let parts: [(value: Double, weight: Double)] = [
            (key?.score ?? 0.6, 0.3),
            (tempo?.score ?? 0.6, 0.3),
            (harm.map { 0.4 + 0.6 * $0 } ?? 0.6, 0.2),
            (spec.map { 0.4 + 0.6 * $0 } ?? 0.6, 0.2),
            (timb.map { 0.4 + 0.6 * $0 } ?? 1.0, timb == nil ? 0.0 : 0.15),
        ]
        let overall = parts.reduce(1.0) { $0 * pow(max($1.value, 0.001), $1.weight) }
        let stars = (overall * 5 * 2).rounded() / 2

        let usableStretch = tempo.map {
            $0.quality(forDrums: isDrums) == .red ? nil : $0.stretchRatio
        } ?? nil
        return MatchPlan(
            stretchRatio: usableStretch,
            pitchShiftSt: key?.pitchShiftSt ?? 0,
            badges: MatchBadges(tempo: tempo, key: key, harmonic: harm,
                                spectral: spec, timbre: timb, stars: stars))
    }
}
