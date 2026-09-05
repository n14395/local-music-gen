import Foundation

/// One thing done to one track, with no model involved.
///
/// `mix_spec` has always been able to reverse a track, stretch it, shift its
/// key, ramp it and run it through a processor chain (contract §5.4). Until
/// these cards the only doors to any of it were the Workbench, which is for
/// arranging several sources, and the Editor, which is for surgery on a
/// selection. Neither is what you want when the whole job is "play that
/// backwards".
///
/// The Editor still does every one of these, and better — with a waveform, an
/// undo stack and a preview. What a card adds is one operation on a whole file
/// without opening a window, which is the same argument that already justifies
/// "Polish the mix" sitting beside the Editor's normalise.
///
/// Pure data: the control a card draws, the bounds it draws it within, and the
/// `RecombineOptions` it produces. `TransformActionView` renders it and
/// `RecombineOptions` is what the engine is actually told.
enum TrackTransform: String, Equatable, Sendable, CaseIterable {
    case reverse
    case speed
    case key
    case fades
    case cleanUp
    case loop
    case conform

    /// What the one control is called, or nil where there is nothing to set.
    var controlTitle: String? {
        switch self {
        case .reverse: nil
        case .speed: "SPEED"
        case .key: "SHIFT"
        case .fades: "FADE"
        case .cleanUp: nil
        case .loop: "LENGTH"
        case .conform: nil
        }
    }

    /// The control's range and starting value, in the unit named below.
    var bounds: (range: ClosedRange<Double>, initial: Double, step: Double)? {
        switch self {
        // 0.5× to 2× either way, which is as far as a time-stretch stays
        // musical rather than becoming an effect in its own right.
        case .speed: (0.5...2, 1, 0.01)
        // An octave in each direction. Beyond that formant preservation is
        // holding together something that has already stopped being the same
        // instrument.
        case .key: (-12...12, 0, 1)
        case .fades: (0...10, 2, 0.5)
        // Bars, not seconds — a loop that is not a whole number of bars is
        // not a loop.
        case .loop: (1...16, 4, 1)
        case .reverse, .cleanUp, .conform: nil
        }
    }

    var unit: String {
        switch self {
        case .speed: "×"
        case .key: "ST"
        case .fades: "S"
        case .loop: "BARS"
        case .reverse, .cleanUp, .conform: ""
        }
    }

    /// Whether the card needs a second slot — a track it measures rather than
    /// one it renders.
    var needsReference: Bool { self == .conform }

    /// Whether it needs the source's beat grid, and is therefore gated on the
    /// track having been analysed.
    var needsAnalysis: Bool { self == .loop || self == .conform }

    /// What the engine is told. `value` is the control's, ignored where there
    /// is no control.
    func options(value: Double) -> RecombineOptions {
        var options = RecombineOptions()
        // Nothing here is a mashup: two of these cards match a grid on
        // purpose and the rest must leave tempo and key exactly as they found
        // them. Auto-match defaults to on, which for a one-source transform
        // would silently stretch a track nobody asked to stretch.
        options.autoMatchTempo = false
        options.autoMatchKey = false
        switch self {
        case .reverse:
            options.reverse = true
        case .speed:
            options.speedRate = value
        case .key:
            options.pitchShiftSt = value
        case .fades:
            options.fadeInS = value
            options.fadeOutS = value
        case .cleanUp:
            // Rumble out, silence down, peaks in — the order a mastering
            // chain runs them and the order the engine applies them.
            options.effects = [
                MixSpec.Effect(type: "highpass", cutoffHz: 80),
                MixSpec.Effect(type: "gate", thresholdDb: -55),
                MixSpec.Effect(type: "compressor", thresholdDb: -18,
                               ratio: 2.5, attackMs: 12, releaseMs: 160),
            ]
        case .loop:
            // The section is set per-ingredient by the page, which is the
            // only place the downbeats are known.
            break
        case .conform:
            options.autoMatchTempo = true
            options.autoMatchKey = true
        }
        return options
    }
}
