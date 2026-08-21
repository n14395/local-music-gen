import SwiftUI

/// The whole-track strip above the main well: the full edited timeline at a
/// glance, the draggable viewport window, the selection tint, and a red mark
/// at every cut — E01/E02's "WHOLE TRACK" band.
struct EditorOverviewStrip: View {
    @Bindable var store: EditorStore

    @State private var peaks: WaveformExtractor.Peaks?
    @State private var loadedFor: URL?
    /// Where inside the viewport window the drag was grabbed, so it moves
    /// with the pointer instead of jumping to centre on it.
    @State private var grabOffsetS: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Text(store.material?.isPart == true ? "WHOLE PART"
                                                    : "WHOLE TRACK")
                    .eyebrow()
                if cutCount > 0 {
                    Text(cutCount == 1 ? "1 REGION REMOVED"
                                       : "\(cutCount) REGIONS REMOVED")
                        .font(Bench.Typo.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(Bench.Palette.dangerText)
                } else {
                    Text("DRAG THE WINDOW TO SCROLL")
                        .font(Bench.Typo.mono(10))
                        .tracking(0.4)
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer(minLength: 8)
                Text("0:00 — \(EditorClock.short(store.timelineDurationS))")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            GeometryReader { geo in
                strip(width: geo.size.width)
            }
            .frame(height: 58)
        }
    }

    private var cutCount: Int { store.joinTimes.count }

    private func strip(width: CGFloat) -> some View {
        let duration = max(0.001, store.timelineDurationS)
        func x(_ t: Double) -> CGFloat { CGFloat(t / duration) * width }
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Bench.Palette.well)
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Bench.Palette.hairline, lineWidth: 1)
            overviewWave(width: width)
                .padding(.horizontal, 8).padding(.vertical, 7)
            // selection tint
            if let selection = store.selection {
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.18))
                    .frame(width: max(0, x(selection.end) - x(selection.start)))
                    .offset(x: x(selection.start))
            }
            // cut markers
            ForEach(Array(cutPositions.enumerated()), id: \.offset) { _, cut in
                Rectangle()
                    .fill(Bench.Palette.danger)
                    .frame(width: 2)
                    .offset(x: x(cut))
                Text("CUT")
                    .font(Bench.Typo.mono(9, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Bench.Palette.danger)
                    .offset(x: x(cut) + 5, y: 4)
            }
            // viewport window
            viewportWindow(width: width)
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                let visible = visibleSeconds
                let at = Double(value.location.x / max(1, width)) * duration
                if grabOffsetS == nil {
                    let grabbed = Double(value.startLocation.x
                                         / max(1, width)) * duration
                    let inside = grabbed >= store.visibleStartS
                        && grabbed <= store.visibleStartS + visible
                    // Grabbing the window drags it; clicking outside it
                    // still jumps there, centred.
                    grabOffsetS = inside ? grabbed - store.visibleStartS
                                         : visible / 2
                }
                store.visibleStartS = (at - (grabOffsetS ?? visible / 2))
                    .clamped(to: 0...max(0, duration - visible))
            }
            .onEnded { _ in grabOffsetS = nil })
        .task(id: store.sourceURL) { await loadPeaks() }
        .onChange(of: store.applyStage) {
            if !store.applyStage.isBusy { Task { await loadPeaks() } }
        }
    }

    private var cutPositions: [Double] { store.joinTimes }

    private var visibleSeconds: Double {
        guard store.pxPerSecond > 0, store.wellWidth > 0 else {
            return store.timelineDurationS
        }
        return Double(store.wellWidth / store.pxPerSecond)
    }

    private func viewportWindow(width: CGFloat) -> some View {
        let duration = max(0.001, store.timelineDurationS)
        let visible = visibleSeconds
        let x0 = CGFloat(store.visibleStartS / duration) * width
        let w = CGFloat(min(1, visible / duration)) * width
        return Rectangle()
            .fill(Bench.Palette.accent.opacity(0.08))
            .overlay(alignment: .leading) {
                Rectangle().fill(Bench.Palette.accent).frame(width: 2)
            }
            .overlay(alignment: .trailing) {
                Rectangle().fill(Bench.Palette.accent).frame(width: 2)
            }
            .frame(width: max(6, w))
            .offset(x: x0)
    }

    /// The overview draws the *edited* timeline by resampling the source's
    /// cached whole-file peaks through the segment map — cheap, and honest
    /// about what was cut, pasted or reversed.
    private func overviewWave(width: CGFloat) -> some View {
        Canvas { context, size in
            guard let peaks, !peaks.maxs.isEmpty else { return }
            let duration = max(0.001, store.timelineDurationS)
            let sourceDuration = max(0.001, store.sourceDurationS)
            let bars = max(1, Int(size.width / 3))
            let pitch = size.width / CGFloat(bars)
            let mid = size.height / 2
            var path = Path()
            for i in 0..<bars {
                let t = (Double(i) + 0.5) / Double(bars) * duration
                guard let s = EditProgram.timelineToSource(t,
                                                           in: store.segments)
                else { continue }
                let bin = Int(s / sourceDuration * Double(peaks.maxs.count))
                    .clamped(to: 0...(peaks.maxs.count - 1))
                let magnitude = max(abs(peaks.maxs[bin]), abs(peaks.mins[bin]))
                let height = max(1.5, CGFloat(magnitude) * size.height * 0.94)
                path.addRoundedRect(
                    in: CGRect(x: CGFloat(i) * pitch, y: mid - height / 2,
                               width: max(1, pitch - 1), height: height),
                    cornerSize: CGSize(width: 1, height: 1))
            }
            context.fill(path, with: .color(.white.opacity(0.24)))
        }
    }

    private func loadPeaks() async {
        guard let url = store.sourceURL,
              let cache = store.sourcePeaksCacheURL else { return }
        guard loadedFor != url || peaks == nil else { return }
        peaks = try? await WaveformExtractor.shared.peaks(for: url,
                                                          cacheURL: cache)
        loadedFor = url
    }
}
