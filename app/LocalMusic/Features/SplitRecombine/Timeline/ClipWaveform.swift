import SwiftUI

/// The trimmed slice of a source's waveform, stretched across a clip.
///
/// `BenchWaveform` always draws a whole file across its full width, which is
/// exactly what a clip must not do: a clip shows `[sectionStart, sectionEnd)`
/// of the source, and — when the mix will time-stretch it — that slice is drawn
/// over the stretched length, so what you see is the length you will get.
struct ClipWaveform: View {
    let handle: PeaksStore.Handle
    let sourceDurationS: Double?
    let sectionStartS: Double?
    let sectionEndS: Double?

    var body: some View {
        Canvas { context, size in
            guard let peaks = handle.peaks, !peaks.mins.isEmpty,
                  size.width > 0, size.height > 0 else { return }
            let duration = sourceDurationS ?? 0
            let range = PeakSlice.range(
                startS: sectionStartS ?? 0,
                endS: sectionEndS ?? (duration > 0 ? duration : 1),
                durationS: duration, binCount: peaks.mins.count)
            let count = range.count
            guard count > 0 else { return }

            let mid = size.height / 2
            let step = size.width / CGFloat(count)
            // Zoomed out a clip can be narrower than its bin count; drawing
            // every bin then costs thousands of sub-pixel rects for nothing.
            let stride = max(1, Int((0.75 / max(step, 0.0001)).rounded()))
            var path = Path()
            var i = range.lowerBound
            while i < range.upperBound {
                let x = CGFloat(i - range.lowerBound) * step
                var lo = CGFloat(peaks.mins[i])
                var hi = CGFloat(peaks.maxs[i])
                // When striding, keep the extremes of the skipped bins so the
                // silhouette stays honest instead of sampling one bin in ten.
                for j in i..<min(i + stride, range.upperBound) {
                    lo = min(lo, CGFloat(peaks.mins[j]))
                    hi = max(hi, CGFloat(peaks.maxs[j]))
                }
                let top = mid - hi * mid * 0.95
                let bottom = mid - lo * mid * 0.95
                path.addRect(CGRect(x: x, y: min(top, bottom),
                                    width: max(step * CGFloat(stride) - 0.5, 0.5),
                                    height: max(abs(bottom - top), 1)))
                i += stride
            }
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .drawingGroup()
    }
}
