import Foundation

/// Analysis, in words.
///
/// The analyzer produces numbers: 128.4 BPM, "F# minor", eight octave-band
/// energies, a 512-dimensional CLAP vector. A 1.5B language model can do
/// nothing with any of that — a bare number carries no musical meaning to it,
/// and the CLAP vector carries none to anyone. So this turns a measurement
/// into the sentence a person would say: "quick, around 128 beats per minute",
/// "in F# minor", "bass-heavy, not much on top".
///
/// Pure and synchronous on purpose: everything it needs is already decoded,
/// nothing here touches the network or the database, and it is the one piece
/// of the assistant feature that is worth unit-testing on its own.
enum SongDigest {

    /// The whole digest, as the assistant receives it. One fact per line,
    /// because a small model follows a list far more reliably than a
    /// paragraph, and lines it does not understand it simply ignores.
    ///
    /// Returns an empty string when there is nothing measured worth saying.
    /// Callers treat that as "no analysis" and say so in their own words
    /// rather than sending the model an empty list to reason about.
    static func text(payload: AnalysisPayload?, title: String? = nil,
                     durationS: Double? = nil, prompt: String? = nil,
                     descriptions: [String] = [], tags: [String] = []) -> String {
        var lines: [String] = []
        if let title, !title.isEmpty {
            lines.append("Title: \(title)")
        }
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("It was made from this description: \(prompt)")
        }
        // What a listening model wrote about the track, when one has — the
        // one line in this digest that comes from the audio itself rather
        // than from measurements, and the closest the assistant gets to
        // hearing anything. First description only: a small model reasons
        // from one good sentence better than from three that disagree.
        if let heard = descriptions.first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !heard.isEmpty {
            lines.append("A model that listened to it wrote: \(heard)")
        }
        if !tags.isEmpty {
            lines.append("Tags: \(tags.joined(separator: ", "))")
        }
        let seconds = durationS ?? payload?.durationS
        if let seconds, seconds > 0 {
            lines.append("Length: \(length(seconds))")
        }
        if let bpm = payload?.tempoBpm, bpm > 0 {
            lines.append("Tempo: \(tempo(bpm))")
        }
        if let key = payload?.key, !key.isEmpty {
            lines.append("Key: \(key)\(payload?.camelot.map { " (Camelot \($0))" } ?? "")")
        }
        if let sections = payload?.sections, sections.count > 1 {
            lines.append("Structure: \(structure(sections))")
        }
        if let chords = payload?.chords,
           let line = progression(chords) {
            lines.append("Chords: \(line)")
        }
        if let quality = payload?.quality {
            lines.append("Recording quality: \(qualityLine(quality))")
        }
        if let bands = payload?.bandEnergy, !bands.isEmpty {
            lines.append("Balance: \(balance(bands))")
        }
        if let lufs = payload?.lufs {
            lines.append("Loudness: \(loudness(lufs))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The individual translations

    /// Tempo as a musician would say it, with the number kept alongside.
    ///
    /// The word matters more than the figure to the model, but dropping the
    /// figure would lose the only fact precise enough to reuse — several cards
    /// pin the tempo of the next generation to it.
    static func tempo(_ bpm: Double) -> String {
        let rounded = Int(bpm.rounded())
        let word = switch bpm {
        case ..<70: "very slow"
        case ..<90: "slow"
        case ..<110: "relaxed, mid-tempo"
        case ..<130: "steady, danceable"
        case ..<150: "quick"
        case ..<180: "fast"
        default: "very fast"
        }
        return "\(word), around \(rounded) beats per minute"
    }

    /// Section letters as a shape. The analyzer names groups A/B/C by first
    /// appearance, which is exactly a form description once it is read aloud —
    /// "A B A B C" is a verse-chorus song and the model treats it as one.
    static func structure(_ sections: [AnalysisPayload.Section]) -> String {
        let letters = sections.compactMap { $0.group ?? $0.label }
        guard !letters.isEmpty else { return "\(sections.count) sections" }
        let distinct = Set(letters).count
        let shape = letters.joined(separator: " ")
        if distinct == 1 {
            return "\(sections.count) sections, all much the same (\(shape))"
        }
        return "\(sections.count) sections in the shape \(shape), "
            + "\(distinct) distinct kinds"
    }

    /// The chord track reduced to what a musician would name: the loop the
    /// song leans on (most frequent four-chord window) and how much colour
    /// sits around it. Nil when nothing but N/X was recognised.
    static func progression(
        _ segments: [AnalysisPayload.ChordSegment]) -> String? {
        // Collapse repeats first — "Am Am Am F" is one chord held, not three.
        var run: [String] = []
        for seg in segments where seg.chord != "N" && seg.chord != "X" {
            if run.last != seg.chord { run.append(seg.chord) }
        }
        guard !run.isEmpty else { return nil }
        let distinct = Set(run).count
        if run.count < 4 {
            return run.joined(separator: " → ")
        }
        var counts: [String: Int] = [:]
        for i in 0...(run.count - 4) {
            counts[run[i..<(i + 4)].joined(separator: " → "),
                   default: 0] += 1
        }
        let loop = counts.max { $0.value < $1.value }!.key
        return "mostly \(loop), \(distinct) distinct chords overall"
    }

    /// SQUIM's three scores in words, with the caveat the payload itself
    /// carries: speech-trained numbers rank takes, they do not grade music.
    static func qualityLine(_ quality: AnalysisPayload.Quality) -> String {
        var parts: [String] = []
        if let stoi = quality.stoi {
            parts.append("intelligibility \(String(format: "%.2f", stoi)) of 1")
        }
        if let pesq = quality.pesq {
            parts.append("perceptual score \(String(format: "%.1f", pesq)) of 4.5")
        }
        if let siSdr = quality.siSdr {
            parts.append("signal-to-distortion \(String(format: "%.1f", siSdr)) dB")
        }
        guard !parts.isEmpty else { return "measured, but empty" }
        return parts.joined(separator: ", ")
            + " (speech-trained estimates — good for comparing takes)"
    }

    /// Eight octave bands, summing to 1, reduced to where the weight sits.
    ///
    /// Thirds rather than eighths: the model cannot act on "band 5 is 0.11",
    /// and neither can a person. The thresholds are deliberately loose — this
    /// is a description, and calling a nearly-even mix "even" is the right
    /// answer far more often than naming whichever third won by a point.
    static func balance(_ bands: [Double]) -> String {
        guard bands.count >= 3 else { return "even across the range" }
        // Per-band averages, not bucket sums: the middle bucket holds more
        // bands than the outer two (4 of 8, against 2 and 2), so summing
        // called a perfectly even mix "mid-focused" — the middle won by
        // having more members, not more energy.
        let third = bands.count / 3
        let low = bands.prefix(third).reduce(0, +) / Double(third)
        let high = bands.suffix(third).reduce(0, +) / Double(third)
        let midCount = bands.count - 2 * third
        let mid = max(0, bands.reduce(0, +)
                         - bands.prefix(third).reduce(0, +)
                         - bands.suffix(third).reduce(0, +))
            / Double(midCount)
        let spread = max(low, max(mid, high)) - min(low, min(mid, high))
        if spread < 0.12 { return "evenly balanced across the range" }
        if low >= mid && low >= high { return "bass-heavy, weighted low" }
        if high >= mid && high >= low { return "bright, weighted towards the top" }
        return "mid-focused, without much deep bass or air"
    }

    /// Integrated loudness against the streaming target this app normalises to.
    static func loudness(_ lufs: Double) -> String {
        switch lufs {
        case ..<(-20): "quiet and dynamic"
        case ..<(-15): "moderate, with room to breathe"
        case ..<(-11): "at about streaming loudness"
        default: "loud and compressed"
        }
    }

    static func length(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) seconds" }
        let minutes = total / 60
        let rest = total % 60
        return rest == 0 ? "\(minutes) minutes"
                         : "\(minutes) min \(rest) sec"
    }
}
