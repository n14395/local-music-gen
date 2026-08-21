import SwiftUI

/// The transport bar's strip while the Editor is frontmost: the *edited*
/// timeline in miniature — the source's cached peaks resampled through the
/// segment map — tinted to the playhead, seekable.
struct EditorMiniWave: View {
    @Bindable var store: EditorStore

    @State private var peaks: WaveformExtractor.Peaks?
    @State private var loadedFor: URL?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Drawn once per edit, not once per frame: the bars are the
                // expensive part and they do not change while playing.
                Canvas { context, size in
                    draw(in: &context, size: size)
                }
                // Only the played tint follows the clock, and only while
                // something is actually playing.
                TimelineView(.animation(minimumInterval: 1.0 / 30,
                                        paused: !store.isPlaying)) { _ in
                    Canvas { context, size in
                        draw(in: &context, size: size, playedOnly: true)
                    }
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let duration = store.timelineDurationS
                guard duration > 0, geo.size.width > 0 else { return }
                let fraction = (value.location.x / geo.size.width)
                    .clamped(to: 0...1)
                store.seekPreview(to: Double(fraction) * duration)
            })
        }
        .task(id: store.sourceURL) {
            guard let url = store.sourceURL,
                  let cache = store.sourcePeaksCacheURL,
                  loadedFor != url || peaks == nil else { return }
            peaks = try? await WaveformExtractor.shared.peaks(for: url,
                                                              cacheURL: cache)
            loadedFor = url
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize,
                      playedOnly: Bool = false) {
        guard let peaks, !peaks.maxs.isEmpty else { return }
        let duration = max(0.001, store.timelineDurationS)
        let sourceDuration = max(0.001, store.sourceDurationS)
        let bars = max(1, Int(size.width / 3))
        let pitch = size.width / CGFloat(bars)
        let mid = size.height / 2
        let playedX = size.width
            * CGFloat((store.playheadS / duration).clamped(to: 0...1))
        var played = Path()
        var rest = Path()
        for i in 0..<bars {
            let t = (Double(i) + 0.5) / Double(bars) * duration
            guard let s = EditProgram.timelineToSource(t, in: store.segments)
            else { continue }
            let bin = Int(s / sourceDuration * Double(peaks.maxs.count))
                .clamped(to: 0...(peaks.maxs.count - 1))
            let magnitude = max(abs(peaks.maxs[bin]), abs(peaks.mins[bin]))
            let height = max(1.5, CGFloat(magnitude) * size.height * 0.94)
            let x = CGFloat(i) * pitch
            let rect = CGRect(x: x, y: mid - height / 2,
                              width: max(1, pitch - 1), height: height)
            if x + pitch / 2 <= playedX {
                played.addRoundedRect(in: rect,
                                      cornerSize: CGSize(width: 1, height: 1))
            } else {
                rest.addRoundedRect(in: rect,
                                    cornerSize: CGSize(width: 1, height: 1))
            }
        }
        if !playedOnly {
            context.fill(rest, with: .color(.white.opacity(0.13)))
        }
        context.fill(played, with: .color(Bench.Palette.accent))
    }
}
