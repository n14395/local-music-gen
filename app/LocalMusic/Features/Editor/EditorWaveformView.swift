import SwiftUI

/// The Editor's main well: section chips, the bar ruler, the zoomed waveform
/// with selection + playhead, and the snap/zoom rail — E01's centre column.
///
/// The waveform here is drawn from *range* peaks read fresh for the visible
/// window (`WaveformExtractor.peaks(for:startS:endS:…)`), because the cached
/// 2000-bin strip cannot support zoom. Each visible segment fetches its own
/// slice of the source, which is also what makes cuts, pastes and reversals
/// draw truthfully — the pixels come from the samples that would play there.
struct EditorWellView: View {
    @Bindable var store: EditorStore

    /// Peaks for one on-screen segment span.
    struct WaveSlice: Equatable {
        var startX: CGFloat
        var width: CGFloat
        var lanes: [WaveformExtractor.Peaks]
        var silent: Bool
        var gainDb: Double
    }

    @State private var slices: [WaveSlice] = []
    @State private var fetchToken = 0
    @State private var fetchTask: Task<Void, Never>?
    @State private var dragMode: DragMode?
    @State private var dragAnchorS: Double?

    private enum DragMode { case newSelection, moveStart, moveEnd, scrub }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let geometry = currentGeometry(width: geo.size.width)
                VStack(spacing: 0) {
                    sectionsRow(geometry)
                    rulerRow(geometry)
                    canvas(geometry)
                }
                .onAppear { syncViewport(width: geo.size.width) }
                .onChange(of: geo.size.width) { syncViewport(width: geo.size.width) }
            }
            snapZoomRow
        }
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Bench.Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    // MARK: geometry plumbing

    private func currentGeometry(width: CGFloat) -> EditorGeometry {
        var zoom = store.pxPerSecond
        if zoom <= 0 {
            zoom = EditorGeometry.fitZoom(durationS: store.timelineDurationS,
                                          width: width)
        }
        return EditorGeometry(visibleStartS: store.visibleStartS,
                              pxPerSecond: zoom, width: width,
                              durationS: store.timelineDurationS)
    }

    private func syncViewport(width: CGFloat) {
        if store.pxPerSecond <= 0 {
            store.pxPerSecond = EditorGeometry.fitZoom(
                durationS: store.timelineDurationS, width: width)
        }
        store.wellWidth = width
        refetch(width: width)
    }

    // MARK: sections (Tier 2.2)

    private func sectionsRow(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            Bench.Palette.sidebar
            ForEach(Array(store.grid.sections.enumerated()), id: \.offset) {
                _, section in
                let x0 = geometry.x(at: section.startS)
                let x1 = geometry.x(at: section.endS)
                if x1 > 0, x0 < geometry.width {
                    let color = Bench.Palette.stem(section.group)
                    Text(section.label)
                        .font(Bench.Typo.mono(9, .semibold))
                        .tracking(0.9)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(width: max(24, x1 - x0), height: 16,
                               alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(color.opacity(0.14)))
                        .clipped()
                        .offset(x: x0, y: 5)
                        .onTapGesture {
                            store.selection = EditRange(start: section.startS,
                                                        end: section.endS)
                        }
                }
            }
        }
        .frame(height: 26)
        .clipped()
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    // MARK: ruler

    private func rulerRow(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            Bench.Palette.sidebar
            Canvas { context, size in
                for tick in store.grid.barTicks {
                    let x = geometry.x(at: tick.timelineS)
                    guard x >= -1, x <= size.width + 1 else { continue }
                    context.fill(
                        Path(CGRect(x: x, y: size.height - 8, width: 1,
                                    height: 8)),
                        with: .color(.white.opacity(0.18)))
                }
            }
            barLabels(geometry)
            playheadFlag(geometry)
        }
        .frame(height: 30)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in
                store.seekPreview(to: snap(geometry.seconds(atX: value.location.x)))
            })
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private func barLabels(_ geometry: EditorGeometry) -> some View {
        // Thin the labels so they never overlap: at least ~44 pt apart.
        let visible = store.grid.barTicks.filter {
            let x = geometry.x(at: $0.timelineS)
            return x >= -20 && x <= geometry.width + 20
        }
        let minGap: CGFloat = 44
        var lastX: CGFloat = -.infinity
        var chosen: [EditorGrid.BarTick] = []
        for tick in visible {
            let x = geometry.x(at: tick.timelineS)
            if x - lastX >= minGap {
                chosen.append(tick)
                lastX = x
            }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(chosen, id: \.number) { tick in
                Text("\(tick.number)")
                    .font(Bench.Typo.mono(10, .semibold))
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .offset(x: geometry.x(at: tick.timelineS) + 5, y: 4)
            }
        }
    }

    private func playheadFlag(_ geometry: EditorGeometry) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !store.isPlaying)) { _ in
            let x = geometry.x(at: store.playheadS)
            ZStack(alignment: .topLeading) {
                if x >= 0, x <= geometry.width {
                    Rectangle()
                        .fill(Bench.Palette.accent)
                        .frame(width: 1, height: 30)
                        .offset(x: x)
                    Text(EditorClock.short(store.playheadS))
                        .font(Bench.Typo.mono(9, .bold))
                        .foregroundStyle(Bench.Palette.onAccent)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3)
                            .fill(Bench.Palette.accent))
                        .offset(x: max(0, min(geometry.width - 40, x - 19)),
                                y: 15)
                }
            }
        }
    }

    // MARK: canvas

    private func canvas(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            Bench.Palette.well
            if store.showBeatGrid { beatGrid(geometry) }
            waveform(geometry)
            fadeOverlays(geometry)
            joinMarkers(geometry)
            selectionOverlay(geometry)
            playheadLine(geometry)
            selectionTooltip(geometry)
        }
        .frame(maxHeight: .infinity)
        .clipped()
        .contentShape(Rectangle())
        .gesture(selectionGesture(geometry))
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            // Double-click: the region under the cursor (the whole track
            // until a cut or split has made boundaries).
            store.selectRegion(at: store.cursorS)
        })
        .onChange(of: store.visibleStartS) { refetch(width: geometry.width) }
        .onChange(of: store.pxPerSecond) { refetch(width: geometry.width) }
        .onChange(of: store.segments) { refetch(width: geometry.width) }
        .onChange(of: store.stereoView) { refetch(width: geometry.width) }
    }

    private func beatGrid(_ geometry: EditorGeometry) -> some View {
        Canvas { context, size in
            guard geometry.pxPerSecond > 2 else { return }
            let barXs = Set(store.grid.barTicks.map {
                (geometry.x(at: $0.timelineS) * 2).rounded() / 2
            })
            for beat in store.grid.beats {
                let x = geometry.x(at: beat)
                guard x >= 0, x <= size.width else { continue }
                let snapped = (x * 2).rounded() / 2
                let isBar = barXs.contains(snapped)
                context.fill(
                    Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                    with: .color(.white.opacity(isBar ? 0.09 : 0.04)))
            }
        }
    }

    private func waveform(_ geometry: EditorGeometry) -> some View {
        Canvas { context, size in
            let laneCount = store.stereoView ? 2 : 1
            let laneHeight = size.height / CGFloat(laneCount)
            // centre lines
            for lane in 0..<laneCount {
                let midY = laneHeight * (CGFloat(lane) + 0.5)
                context.fill(Path(CGRect(x: 0, y: midY, width: size.width,
                                         height: 1)),
                             with: .color(.white.opacity(0.07)))
            }
            if laneCount == 2 {
                context.fill(Path(CGRect(x: 0, y: laneHeight, width: size.width,
                                         height: 1)),
                             with: .color(.white.opacity(0.1)))
            }
            for slice in slices {
                if slice.silent {
                    // Hatch a silenced stretch rather than leaving it looking
                    // like missing data.
                    var hatch = Path()
                    var x = slice.startX
                    while x < slice.startX + slice.width {
                        hatch.move(to: CGPoint(x: x, y: size.height))
                        hatch.addLine(to: CGPoint(x: x + 8, y: 0))
                        x += 9
                    }
                    context.stroke(hatch, with: .color(.white.opacity(0.04)),
                                   lineWidth: 2)
                    continue
                }
                for (laneIndex, lane) in slice.lanes.enumerated() {
                    guard laneIndex < laneCount else { break }
                    drawLane(lane, in: &context, slice: slice,
                             laneTop: laneHeight * CGFloat(laneIndex),
                             laneHeight: laneHeight)
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func drawLane(_ peaks: WaveformExtractor.Peaks,
                          in context: inout GraphicsContext,
                          slice: WaveSlice, laneTop: CGFloat,
                          laneHeight: CGFloat) {
        let bins = peaks.maxs.count
        guard bins > 0 else { return }
        let pitch = slice.width / CGFloat(bins)
        let barWidth = max(0.8, pitch - 1)
        let midY = laneTop + laneHeight / 2
        let scale = (laneHeight / 2 - 4)
            * CGFloat(pow(10.0, slice.gainDb / 20.0))
        var bars = Path()
        for i in 0..<bins {
            let magnitude = max(abs(peaks.maxs[i]), abs(peaks.mins[i]))
            let height = max(1.5, CGFloat(magnitude) * scale * 2)
            let x = slice.startX + CGFloat(i) * pitch
            bars.addRoundedRect(
                in: CGRect(x: x, y: midY - height / 2, width: barWidth,
                           height: height),
                cornerSize: CGSize(width: 1, height: 1))
        }
        context.fill(bars, with: .color(.white.opacity(0.32)))
    }

    private func fadeOverlays(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            let anchors = store.fadeAnchors
            if let fadeIn = store.document.fadeIn {
                // From the first AUDIBLE moment: the engine attaches the ramp
                // to the first track, and leading silence produces no track.
                let x0 = geometry.x(at: anchors.headS)
                let width = geometry.x(at: anchors.headS + fadeIn.seconds) - x0
                LinearGradient(
                    colors: [Bench.Palette.well.opacity(0.9),
                             Bench.Palette.accent.opacity(0.07)],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, width))
                    .offset(x: x0)
                    .overlay(alignment: .trailing) {
                        Rectangle()
                            .fill(Bench.Palette.accent.opacity(0.35))
                            .frame(width: 1)
                    }
                Text("FADE IN \(trimmedSeconds(fadeIn.seconds)) S")
                    .font(Bench.Typo.mono(9, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Bench.Palette.accent)
                    .offset(x: x0 + max(0, width) + 8, y: 14)
            }
            if let fadeOut = store.document.fadeOut {
                let x0 = geometry.x(at: anchors.tailS - fadeOut.seconds)
                let x1 = geometry.x(at: anchors.tailS)
                LinearGradient(
                    colors: [Bench.Palette.accent.opacity(0.07),
                             Bench.Palette.well.opacity(0.9)],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(0, x1 - x0))
                    .offset(x: x0)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Bench.Palette.accent.opacity(0.35))
                            .frame(width: 1)
                    }
                Text("FADE OUT \(trimmedSeconds(fadeOut.seconds)) S")
                    .font(Bench.Typo.mono(9, .semibold))
                    .tracking(0.7)
                    .foregroundStyle(Bench.Palette.accent)
                    .offset(x: max(4, x0 - 92), y: 14)
            }
        }
        .allowsHitTesting(false)
    }

    /// The joins the render will crossfade: where consecutive segments are
    /// discontinuous source (a delete's seam, a paste's edges).
    private func joinMarkers(_ geometry: EditorGeometry) -> some View {
        var joins: [Double] = []
        var cursor = 0.0
        for (index, segment) in store.segments.enumerated() {
            defer { cursor += segment.length }
            guard index > 0 else { continue }
            let previous = store.segments[index - 1]
            guard !segment.silent, !previous.silent else { continue }
            let contiguous = !previous.reversed && !segment.reversed
                && abs(previous.sourceEnd - segment.sourceStart) < 1e-9
            if !contiguous { joins.append(cursor) }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(joins.enumerated()), id: \.offset) { _, join in
                let x = geometry.x(at: join)
                if x >= -20, x <= geometry.width + 20 {
                    Rectangle()
                        .fill(Bench.Palette.danger.opacity(0.14))
                        .frame(width: 12)
                        .overlay(Rectangle()
                            .strokeBorder(Bench.Palette.danger.opacity(0.5),
                                          lineWidth: 1))
                        .offset(x: x - 6)
                    if store.crossfadeJoins {
                        Text("JOIN · CROSSFADE 8 MS")
                            .font(Bench.Typo.mono(9, .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Bench.Palette.dangerText)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 5)
                                .fill(Bench.Palette.well)
                                .overlay(RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(
                                        Bench.Palette.danger.opacity(0.4),
                                        lineWidth: 1)))
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 10)
                            .offset(x: x + 12)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func selectionOverlay(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            if let selection = store.selection {
                let x0 = geometry.x(at: selection.start)
                let x1 = geometry.x(at: selection.end)
                Rectangle()
                    .fill(Bench.Palette.accent.opacity(0.1))
                    .frame(width: max(0, x1 - x0))
                    .offset(x: x0)
                Rectangle().fill(Bench.Palette.accent)
                    .frame(width: 1.5).offset(x: x0)
                Rectangle().fill(Bench.Palette.accent)
                    .frame(width: 1.5).offset(x: x1)
                handle(at: x0)
                handle(at: x1)
            }
        }
    }

    private func handle(at x: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Bench.Palette.accent)
            .frame(width: 9, height: 52)
            .overlay(HStack(spacing: 1.5) {
                Rectangle().fill(Bench.Palette.onAccent.opacity(0.55))
                    .frame(width: 1, height: 16)
                Rectangle().fill(Bench.Palette.onAccent.opacity(0.55))
                    .frame(width: 1, height: 16)
            })
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            .frame(maxHeight: .infinity)
            .offset(x: x - 4.5)
    }

    private func playheadLine(_ geometry: EditorGeometry) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30,
                                paused: !store.isPlaying)) { _ in
            let x = geometry.x(at: store.playheadS)
            ZStack(alignment: .topLeading) {
                if x >= 0, x <= geometry.width {
                    Rectangle()
                        .fill(Bench.Palette.knob)
                        .frame(width: 1.5)
                        .shadow(color: Bench.Palette.knob.opacity(0.35),
                                radius: 6)
                        .offset(x: x)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func selectionTooltip(_ geometry: EditorGeometry) -> some View {
        ZStack(alignment: .topLeading) {
            if let selection = store.selection {
                let x0 = geometry.x(at: selection.start)
                let x1 = geometry.x(at: selection.end)
                Text(tooltipText(selection))
                    .font(Bench.Typo.mono(10, .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Bench.Palette.accent)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Bench.Palette.onAccent)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Bench.Palette.accent.opacity(0.5),
                                          lineWidth: 1)))
                    .fixedSize()
                    .offset(x: ((x0 + x1) / 2 - 90)
                        .clamped(to: 4...max(4, geometry.width - 190)), y: 10)
            }
        }
        .allowsHitTesting(false)
    }

    private func tooltipText(_ selection: EditRange) -> String {
        var text = "\(EditorClock.full(selection.start)) → "
            + "\(EditorClock.full(selection.end)) · "
            + String(format: "%.2f S", selection.length)
        if let beats = store.barsInSelection() {
            text += " · \(beats) BEATS"
        }
        return text
    }

    // MARK: gestures

    private func selectionGesture(_ geometry: EditorGeometry) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let t = geometry.seconds(atX: value.location.x)
                if dragMode == nil {
                    dragMode = pickDragMode(value.startLocation.x,
                                            geometry: geometry)
                    if dragMode == .newSelection {
                        // ⇧ extends the existing selection instead.
                        if NSEvent.modifierFlags.contains(.shift),
                           let current = store.selection {
                            dragAnchorS = abs(t - current.start)
                                > abs(t - current.end)
                                ? current.start : current.end
                            dragMode = .moveEnd
                        } else {
                            dragAnchorS = snap(geometry, geometry.seconds(
                                atX: value.startLocation.x))
                        }
                    } else if dragMode == .moveStart {
                        dragAnchorS = store.selection?.end
                    } else if dragMode == .moveEnd, dragAnchorS == nil {
                        dragAnchorS = store.selection?.start
                    }
                }
                switch dragMode {
                case .newSelection, .moveStart, .moveEnd:
                    guard let anchor = dragAnchorS else { return }
                    if abs(value.translation.width) > 2
                        || dragMode != .newSelection {
                        store.selection = EditRange(start: anchor,
                                                    end: snap(geometry, t))
                    }
                case .scrub, nil:
                    break
                }
            }
            .onEnded { value in
                let t = geometry.seconds(atX: value.location.x)
                if dragMode == .newSelection,
                   abs(value.translation.width) <= 2 {
                    // A plain click: place the cursor, drop the selection.
                    store.selection = nil
                    store.seekPreview(to: snap(geometry, t))
                }
                dragMode = nil
                dragAnchorS = nil
                Task { await store.refineSelectionToZeroCrossings() }
            }
    }

    private func pickDragMode(_ x: CGFloat,
                              geometry: EditorGeometry) -> DragMode {
        if let selection = store.selection {
            if abs(geometry.x(at: selection.start) - x) < 8 { return .moveStart }
            if abs(geometry.x(at: selection.end) - x) < 8 { return .moveEnd }
        }
        return .newSelection
    }

    private func snap(_ geometry: EditorGeometry, _ t: Double) -> Double {
        geometry.snapped(t, candidates: store.grid.candidates(
            for: store.snapMode))
    }

    private func snap(_ t: Double) -> Double {
        let geometry = currentGeometry(width: max(1, store.wellWidth))
        return snap(geometry, t)
    }

    // MARK: snap + zoom rail

    private var snapZoomRow: some View {
        HStack(spacing: 10) {
            Text("SNAP").eyebrow()
            BenchSegmented(
                selection: Binding(get: { store.snapMode },
                                   set: { store.snapMode = $0 }),
                options: EditorGeometry.SnapMode.allCases.map {
                    .init(value: $0, label: $0.label)
                })
            snapDetail
            // Its own slot, not a snap detail: how joins are rendered is a
            // property of the edit, and it used to vanish whenever the snap
            // mode happened to have something to say.
            BenchToggleChip(
                isOn: Binding(get: { store.crossfadeJoins },
                              set: { store.setCrossfadeJoins($0) }),
                label: "Crossfade joins · 8 ms")
            Spacer(minLength: 8)
            Text("VIEW").eyebrow()
            BenchSegmented(
                selection: Binding(get: { store.stereoView },
                                   set: { store.stereoView = $0 }),
                options: [.init(value: false, label: "Mono"),
                          .init(value: true, label: "L / R")])
            Text("ZOOM").eyebrow()
            zoomControls
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private var snapDetail: some View {
        switch store.snapMode {
        case .beats, .bars:
            if store.grid.beats.isEmpty {
                Text("No detected grid — analyse this track for real snap")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    StatusDot(color: Bench.Palette.ok, size: 6, glows: false)
                    Text("Detected grid · \(store.grid.beats.count) beats")
                        .font(Bench.Typo.small)
                        .foregroundStyle(Bench.Palette.ok)
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Bench.Palette.ok.opacity(0.09)))
            }
        case .zeroX:
            Text("Cuts land on silence — no click")
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
                .lineLimit(1)
        case .off, .sections:
            EmptyView()
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 8) {
            zoomButton("minus") { scaleZoom(by: 0.75) }
            BenchSlider(value: zoomSliderBinding, range: 0...1,
                        tint: Bench.Palette.accent)
                .frame(width: 96)
            zoomButton("plus") { scaleZoom(by: 1.33) }
            Text(inViewLabel)
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textQuaternary)
                .frame(width: 82, alignment: .leading)
            Button("Fit") { store.pxPerSecond = 0; store.visibleStartS = 0 }
                .buttonStyle(.bench(.quiet))
        }
    }

    private func zoomButton(_ symbol: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Bench.Palette.raised))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The slider runs log-scale from fit to max — linear pixels-per-second
    /// spends nine tenths of its travel between "very zoomed" and "unusably
    /// zoomed".
    private var zoomSliderBinding: Binding<Double> {
        Binding(
            get: {
                let duration = store.timelineDurationS
                let width = max(1, store.wellWidth)
                guard duration > 0 else { return 0 }
                let fit = Double(EditorGeometry.fitZoom(durationS: duration,
                                                        width: width))
                let maxZ = Double(EditorGeometry.maxZoom)
                let zoom = Double(store.pxPerSecond > 0 ? store.pxPerSecond
                                                        : CGFloat(fit))
                guard maxZ > fit else { return 0 }
                return ((log(zoom) - log(fit)) / (log(maxZ) - log(fit)))
                    .clamped(to: 0...1)
            },
            set: { fraction in
                let duration = store.timelineDurationS
                let width = max(1, store.wellWidth)
                guard duration > 0 else { return }
                let fit = Double(EditorGeometry.fitZoom(durationS: duration,
                                                        width: width))
                let maxZ = Double(EditorGeometry.maxZoom)
                let zoom = exp(log(fit) + fraction * (log(maxZ) - log(fit)))
                setZoomKeepingCenter(CGFloat(zoom))
            })
    }

    private func scaleZoom(by factor: CGFloat) {
        let zoom = store.pxPerSecond > 0 ? store.pxPerSecond
            : EditorGeometry.fitZoom(durationS: store.timelineDurationS,
                                     width: max(1, store.wellWidth))
        setZoomKeepingCenter(zoom * factor)
    }

    private func setZoomKeepingCenter(_ zoom: CGFloat) {
        // Anchor on the playhead when visible, the window centre otherwise.
        let duration = store.timelineDurationS
        let width = max(1, store.wellWidth)
        let visible = store.pxPerSecond > 0
            ? Double(width / store.pxPerSecond) : duration
        let anchor = (store.playheadS >= store.visibleStartS
                      && store.playheadS <= store.visibleStartS + visible)
            ? store.playheadS : store.visibleStartS + visible / 2
        store.pxPerSecond = EditorGeometry.clampZoom(zoom, durationS: duration,
                                                     width: width)
        let newVisible = Double(width / store.pxPerSecond)
        store.visibleStartS = (anchor - newVisible / 2)
            .clamped(to: 0...max(0, duration - newVisible))
    }

    private var inViewLabel: String {
        guard store.pxPerSecond > 0, store.wellWidth > 0 else {
            return "ALL IN VIEW"
        }
        let seconds = Int((store.wellWidth / store.pxPerSecond).rounded())
        return "\(seconds) S IN VIEW"
    }

    // MARK: peak fetching

    private func refetch(width: CGFloat) {
        guard let sourceURL = store.sourceURL, width > 0 else { return }
        let geometry = currentGeometry(width: width)
        let segments = store.segments
        let stereo = store.stereoView
        fetchToken += 1
        let token = fetchToken
        let sourceDuration = store.sourceDurationS
        // One decode round per gesture, not per mouse-move: the previous
        // task is cancelled rather than left to finish work nobody will
        // read, and a short lead-in lets a fast drag settle first.
        fetchTask?.cancel()
        fetchTask = Task {
            try? await Task.sleep(for: .milliseconds(16))
            if Task.isCancelled { return }
            var out: [EditorWellView.WaveSlice] = []
            var cursor = 0.0
            for segment in segments {
                if Task.isCancelled { return }
                let segStart = cursor
                cursor += segment.length
                let segEnd = cursor
                guard segEnd > geometry.visibleStartS,
                      segStart < geometry.visibleEndS else { continue }
                let visibleStart = max(segStart, geometry.visibleStartS)
                let visibleEnd = min(segEnd, geometry.visibleEndS)
                let startX = geometry.x(at: visibleStart)
                let sliceWidth = geometry.x(at: visibleEnd) - startX
                guard sliceWidth > 1 else { continue }
                if segment.silent {
                    out.append(WaveSlice(startX: startX, width: sliceWidth,
                                         lanes: [], silent: true, gainDb: 0))
                    continue
                }
                // The source range under the visible span, respecting
                // direction; a reversed segment reads its slice backwards.
                let intoStart = visibleStart - segStart
                let intoEnd = visibleEnd - segStart
                let sourceLo: Double
                let sourceHi: Double
                if segment.reversed {
                    sourceLo = segment.sourceEnd - intoEnd
                    sourceHi = segment.sourceEnd - intoStart
                } else {
                    sourceLo = segment.sourceStart + intoStart
                    sourceHi = segment.sourceStart + intoEnd
                }
                let bins = max(8, Int(sliceWidth / 2))
                var lanes = (try? await WaveformExtractor.shared.peaks(
                    for: sourceURL,
                    startS: max(0, sourceLo),
                    endS: min(sourceDuration, sourceHi),
                    binCount: bins, mono: !stereo)) ?? []
                if segment.reversed {
                    lanes = lanes.map { lane in
                        WaveformExtractor.Peaks(
                            mins: lane.mins.reversed(),
                            maxs: lane.maxs.reversed())
                    }
                }
                out.append(WaveSlice(startX: startX, width: sliceWidth,
                                     lanes: lanes, silent: false,
                                     gainDb: segment.gainDb))
            }
            if token == fetchToken, !Task.isCancelled { slices = out }
        }
    }

    private func trimmedSeconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value))
                                 : String(format: "%.1f", value)
    }
}
