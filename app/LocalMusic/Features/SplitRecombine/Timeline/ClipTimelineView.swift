import SwiftUI

/// The Workbench's timeline lens: lanes down, target-grid time across.
///
/// Named ClipTimeline* on purpose — `TimelineView` is SwiftUI's own type, and
/// the playhead wants it.
struct ClipTimelineView: View {
    @Bindable var model: WorkbenchModel
    @Binding var selection: Set<String>
    let peaksStore: PeaksStore
    let preview: MultiPartPlayer
    let onAddPart: () -> Void
    /// Start the shared preview player at a position on the timeline.
    let onPlay: (Double) -> Void
    /// Material ids dropped on the lanes, with the beat they should land on
    /// (0 = bar 1). Resolving an id to a part needs the stores, which live on
    /// the screen, so the lane area only reports where the drop happened.
    let onDrop: ([String], Double) -> Bool

    @State private var zoom: CGFloat = 20
    @State private var snap: TimelineMath.Snap = .bar
    @State private var playheadBeats: Double = 0
    @State private var showsWaveforms = true
    @State private var drag: DragSession?
    @Environment(\.undoManager) private var undoManager

    /// An in-flight drag, held outside the model so a 60 fps gesture doesn't
    /// invalidate every clip view on every frame.
    struct DragSession: Equatable {
        var clipId: String
        var grab: ClipDrag.Grab
        var startBeats: Double
        var laneIndex: Int
        var previewStartBeats: Double
        var previewLengthBeats: Double
        var previewLaneIndex: Int
        var trim: ClipDrag.Trim?
    }

    static let laneHeight: CGFloat = Bench.Metrics.timelineLaneHeight
    static let headerWidth: CGFloat = Bench.Metrics.timelineHeaderWidth
    /// Gap between a clip and its lane's edges. Shared with `draggedFrames`,
    /// which has to undo it to compute a vertical offset.
    static let clipInset: CGFloat = 8

    private var math: TimelineMath {
        TimelineMath(bpm: model.effectiveTargetBpm,
                     beatsPerBar: model.beatsPerBar, pxPerSecond: zoom)
    }

    private var placements: [TimelineMath.Placement] {
        let laneIndex = Dictionary(uniqueKeysWithValues:
                                    model.lanes.enumerated().map { ($1.id, $0) })
        return model.clips.map { clip in
            TimelineMath.Placement(id: clip.id,
                                   laneIndex: laneIndex[clip.laneId] ?? 0,
                                   startBeats: clip.startBeats,
                                   lengthBeats: model.lengthBeats(of: clip))
        }
    }

    private var contentBeats: Double {
        TimelineMath.contentBeats(placements, trailingBars: 2,
                                  beatsPerBar: model.beatsPerBar)
    }

    private var contentWidth: CGFloat { math.width(beats: contentBeats) }

    private var frames: [String: CGRect] {
        Dictionary(uniqueKeysWithValues:
                    math.frames(placements, laneHeight: Self.laneHeight,
                                clipInset: Self.clipInset)
            .map { ($0.id, $0.rect) })
    }

    /// Overlapping spans per lane, for the grid's hatching.
    private var overlaps: [(lane: Int, start: Double, end: Double)] {
        var out: [(lane: Int, start: Double, end: Double)] = []
        for (index, lane) in model.lanes.enumerated() {
            let spans = model.clips.filter { $0.laneId == lane.id }
                .map { (start: $0.startBeats, length: model.lengthBeats(of: $0)) }
            for range in TimelineMath.overlaps(inLane: spans) {
                out.append((index, range.start, range.end))
            }
        }
        return out
    }

    private var muteMap: [String: Bool] {
        WorkbenchModel.effectivelyMuted(lanes: model.lanes, clips: model.clips)
    }

    var body: some View {
        VStack(spacing: 0) {
            transport
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    laneHeaders
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            ClipTimelineRuler(math: math, width: contentWidth,
                                              onScrub: { beats in
                                                  playheadBeats = beats
                                                  if preview.isPlaying {
                                                      preview.seek(
                                                          to: math.seconds(
                                                            beats: beats))
                                                  }
                                              })
                            ZStack(alignment: .topLeading) {
                                ClipTimelineGrid(
                                    math: math, laneCount: model.lanes.count,
                                    laneHeight: Self.laneHeight,
                                    width: contentWidth, overlaps: overlaps)
                                clipLayer
                                playhead
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                // ⌥ drops at the playhead, as the parts drawer
                                // says it does; a plain drop starts at bar 1.
                                // The drop point itself is deliberately not
                                // used — a lane is created for the material, so
                                // the y of the pointer names no existing lane.
                                onDrop(ids,
                                       NSEvent.modifierFlags.contains(.option)
                                           ? playheadBeats : 0)
                            }
                        }
                    }
                }
            }
            .background(Bench.Palette.windowBackground)
            if let selected = selectedClipBinding {
                ClipInspector(
                    clip: selected,
                    clipNumber: clipNumber(of: selected.wrappedValue),
                    beatsPerBar: model.beatsPerBar,
                    lengthBeats: model.lengthBeats(of: selected.wrappedValue),
                    lengthSeconds: math.seconds(
                        beats: model.lengthBeats(of: selected.wrappedValue)),
                    onDuplicate: {
                        registerUndo()
                        if let new = model.duplicate(selected.wrappedValue.id) {
                            selection = [new.id]
                        }
                    },
                    onRemove: {
                        registerUndo()
                        let id = selected.wrappedValue.id
                        model.removeClip(id)
                        selection.remove(id)
                    },
                    onBeforeEdit: { registerUndo() })
            }
        }
        .onChange(of: model.clips.map(\.material.id)) { _, ids in
            peaksStore.retain(ids: Set(ids))
        }
        .onDeleteCommand {
            guard !selection.isEmpty else { return }
            registerUndo()
            for id in selection { model.removeClip(id) }
            selection = []
        }
        .onMoveCommand { direction in
            nudge(direction)
        }
    }

    /// Binding to the one selected clip (the inspector edits a single clip;
    /// multi-selection is for move/delete).
    private var selectedClipBinding: Binding<WorkbenchModel.Clip>? {
        guard selection.count == 1, let id = selection.first,
              model.clips.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { model.clips.first { $0.id == id } ?? model.clips[0] },
            set: { updated in
                if let i = model.clips.firstIndex(where: { $0.id == id }) {
                    model.clips[i] = updated
                }
            })
    }

    /// Which placement of its lane a clip is, counting from the start of the
    /// arrangement — `CLIP 2` in the inspector.
    private func clipNumber(of clip: WorkbenchModel.Clip) -> Int {
        let siblings = model.clips.filter { $0.laneId == clip.laneId }
            .sorted { $0.startBeats < $1.startBeats }
        return (siblings.firstIndex { $0.id == clip.id } ?? 0) + 1
    }

    /// Arrow keys nudge by one snap unit; the grid is the unit of intent, so
    /// "off" falls back to a beat rather than a pixel.
    private func nudge(_ direction: MoveCommandDirection) {
        guard !selection.isEmpty else { return }
        let step: Double
        switch snap {
        case .bar: step = model.beatsPerBar
        case .beat, .off: step = 1
        }
        let delta: Double
        switch direction {
        case .left: delta = -step
        case .right: delta = step
        default: return
        }
        registerUndo()
        for id in selection {
            guard let i = model.clips.firstIndex(where: { $0.id == id })
            else { continue }
            model.clips[i].startBeats =
                TimelineMath.clampStart(model.clips[i].startBeats + delta)
        }
    }

    // MARK: layers

    private var clipLayer: some View {
        ClipTimelineLayout(
            frames: draggedFrames,
            contentSize: CGSize(width: contentWidth,
                                height: CGFloat(max(model.lanes.count, 1))
                                    * Self.laneHeight)
        ) {
            ForEach(model.clips) { clip in
                ClipView(clip: clip, plan: model.plan(for: clip),
                         selected: selection.contains(clip.id),
                         muted: muteMap[clip.id] ?? clip.muted,
                         peaks: peaksHandle(for: clip),
                         showsWaveform: showsWaveforms,
                         fadeInFraction: fadeFraction(clip, clip.fadeInS),
                         fadeOutFraction: fadeFraction(clip, clip.fadeOutS))
                    .clipTimelineID(clip.id)
                    .gesture(dragGesture(for: clip))
                    .contextMenu { clipMenu(clip) }
            }
        }
    }

    /// Frames with the in-flight drag applied. The model is NOT written during
    /// a drag: an @Observable write invalidates every view reading `clips`, so
    /// mutating per frame drops the whole timeline to single-digit fps.
    private var draggedFrames: [String: CGRect] {
        var out = frames
        guard let drag, let rect = out[drag.clipId] else { return out }
        switch drag.grab {
        case .body:
            out[drag.clipId] = rect.offsetBy(
                dx: math.x(beats: drag.previewStartBeats) - rect.minX,
                dy: CGFloat(drag.previewLaneIndex) * Self.laneHeight
                    - (rect.minY - Self.clipInset))
        case .leadingEdge, .trailingEdge:
            let x = math.x(beats: drag.previewStartBeats)
            out[drag.clipId] = CGRect(x: x, y: rect.minY,
                                      width: max(6, math.width(
                                        beats: drag.previewLengthBeats)),
                                      height: rect.height)
        }
        return out
    }

    /// One gesture for both click and drag: a DragGesture with a minimum
    /// distance would swallow plain clicks, and a separate tap gesture next to
    /// it never gets a look in.
    private func dragGesture(for clip: WorkbenchModel.Clip)
        -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let width = frames[clip.id]?.width ?? 0
                if drag == nil {
                    let grab = ClipDrag.grab(atX: value.startLocation.x,
                                             width: width)
                    drag = DragSession(
                        clipId: clip.id, grab: grab,
                        startBeats: clip.startBeats,
                        laneIndex: laneIndex(of: clip),
                        previewStartBeats: clip.startBeats,
                        previewLengthBeats: model.lengthBeats(of: clip),
                        previewLaneIndex: laneIndex(of: clip))
                    select(clip.id)
                }
                updateDrag(value, clip: clip)
            }
            .onEnded { value in
                // A press that never moved is a click: select, don't commit a
                // no-op edit (which would push an empty undo step).
                let moved = abs(value.translation.width) > 2
                    || abs(value.translation.height) > 2
                if moved { commitDrag() }
                drag = nil
            }
    }

    private func updateDrag(_ value: DragGesture.Value,
                            clip: WorkbenchModel.Clip) {
        guard var session = drag else { return }
        // ⌥ bypasses snapping for the length of the drag, the macOS convention.
        let effectiveSnap = NSEvent.modifierFlags.contains(.option)
            ? TimelineMath.Snap.off : snap
        switch session.grab {
        case .body:
            session.previewStartBeats = ClipDrag.movedStart(
                originalBeats: session.startBeats,
                deltaX: value.translation.width, math: math,
                snap: effectiveSnap)
            session.previewLaneIndex = ClipDrag.laneIndex(
                originalIndex: session.laneIndex,
                deltaY: value.translation.height,
                laneHeight: Self.laneHeight, laneCount: model.lanes.count)
        case .leadingEdge, .trailingEdge:
            guard let trim = trimResult(for: clip, session: session,
                                        deltaX: value.translation.width) else {
                return
            }
            session.previewStartBeats = trim.startBeats
            session.previewLengthBeats = lengthBeats(
                clip: clip, sectionStartS: trim.sectionStartS,
                sectionEndS: trim.sectionEndS)
            session.trim = trim
        }
        drag = session
    }

    private func commitDrag() {
        guard let session = drag,
              let index = model.clips.firstIndex(where: {
                  $0.id == session.clipId
              }) else { return }
        registerUndo()
        switch session.grab {
        case .body:
            model.clips[index].startBeats = session.previewStartBeats
            if model.lanes.indices.contains(session.previewLaneIndex) {
                model.clips[index].laneId =
                    model.lanes[session.previewLaneIndex].id
            }
        case .leadingEdge, .trailingEdge:
            guard let trim = session.trim else { return }
            model.clips[index].sectionStartS = trim.sectionStartS
            model.clips[index].sectionEndS = trim.sectionEndS
            model.clips[index].startBeats = trim.startBeats
        }
    }

    private func trimResult(for clip: WorkbenchModel.Clip,
                            session: DragSession,
                            deltaX: CGFloat) -> ClipDrag.Trim? {
        guard let duration = clip.sourceDurationS else { return nil }
        let stretching = TimelineGeometry.stretches(
            sourceBpm: clip.summary?.bpm, targetBpm: model.effectiveTargetBpm,
            autoMatchTempo: model.autoMatchTempo)
        let factor = stretching
            ? (clip.summary?.bpm ?? 1) / (model.effectiveTargetBpm ?? 1) : 1
        return ClipDrag.trim(
            grab: session.grab, deltaX: deltaX, math: math,
            clipStartBeats: session.startBeats,
            sectionStartS: clip.sectionStartS, sectionEndS: clip.sectionEndS,
            sourceDurationS: duration, stretchFactor: factor)
    }

    private func lengthBeats(clip: WorkbenchModel.Clip,
                             sectionStartS: Double,
                             sectionEndS: Double) -> Double {
        var probe = clip
        probe.sectionStartS = sectionStartS
        probe.sectionEndS = sectionEndS
        return model.lengthBeats(of: probe)
    }

    private func laneIndex(of clip: WorkbenchModel.Clip) -> Int {
        model.lanes.firstIndex { $0.id == clip.laneId } ?? 0
    }

    @ViewBuilder
    private func clipMenu(_ clip: WorkbenchModel.Clip) -> some View {
        Button("Duplicate") {
            registerUndo()
            model.duplicate(clip.id)
        }
        Button("Split into sections") {
            registerUndo()
            model.explodeIntoSections(clip.id)
        }
        .disabled(clip.sections.count < 2)
        .help(clip.sections.count < 2
              ? "Run Musical analysis on this part to find its sections"
              : "Replace this clip with one clip per section")
        if let overlap = crossfadeCandidate(clip) {
            Button("Crossfade with neighbour") {
                registerUndo()
                model.crossfade(clip.id, with: overlap)
            }
        }
        Divider()
        Button("Remove", role: .destructive) {
            registerUndo()
            model.removeClip(clip.id)
            selection.remove(clip.id)
        }
    }

    /// A clip on the same lane whose span overlaps this one — the pair a
    /// crossfade applies to.
    private func crossfadeCandidate(_ clip: WorkbenchModel.Clip) -> String? {
        let start = clip.startBeats
        let end = start + model.lengthBeats(of: clip)
        return model.clips.first { other in
            other.id != clip.id && other.laneId == clip.laneId
                && other.startBeats < end
                && other.startBeats + model.lengthBeats(of: other) > start
        }?.id
    }

    /// While playing, the playhead follows the AUDIO clock on its own redraw —
    /// nothing that draws clips may depend on it, or the whole timeline
    /// invalidates 30 times a second.
    private var playhead: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !preview.isPlaying)) { _ in
            let beats = preview.isPlaying
                ? math.beats(seconds: preview.currentPosition())
                : playheadBeats
            Rectangle()
                .fill(Bench.Palette.accent)
                .frame(width: 1.5)
                .shadow(color: Bench.Palette.accent.opacity(0.5), radius: 6)
                .overlay(alignment: .top) {
                    PlayheadCap()
                        .fill(Bench.Palette.accent)
                        .frame(width: 10, height: 7)
                }
                .offset(x: math.x(beats: beats))
                .allowsHitTesting(false)
        }
    }

    // MARK: track headers

    private var laneHeaders: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("TRACKS").eyebrow(Bench.Palette.textFaintest)
                .padding(.horizontal, 14)
                .frame(height: ClipTimelineRuler.height, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
                }
            ForEach(Array(model.lanes.enumerated()), id: \.element.id) {
                index, lane in
                LaneHeaderRow(lane: $model.lanes[index],
                              kind: kind(ofLane: lane.id),
                              clipCount: model.clips.filter {
                                  $0.laneId == lane.id }.count,
                              isSelected: model.clips.contains {
                                  $0.laneId == lane.id
                                      && selection.contains($0.id) },
                              onRemove: { model.removeLane(lane.id) })
            }
            Button(action: onAddPart) {
                Text("＋ Add track")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
        }
        .frame(width: Self.headerWidth, alignment: .leading)
        .background(Bench.Palette.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Bench.Palette.cardStrokeSoft).frame(width: 1)
        }
    }

    /// A lane's stem colour comes from the material on it — the lane itself has
    /// no kind, and an empty lane falls back to the neutral swatch.
    private func kind(ofLane id: String) -> String? {
        model.clips.first { $0.laneId == id }?.material.kind
    }

    // MARK: transport

    private var transport: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                BenchPlayButton(isPlaying: preview.isPlaying, isCurrent: true,
                                size: 28) {
                    if preview.isPlaying {
                        preview.pause()
                    } else {
                        onPlay(playheadBeats)
                    }
                }
                .help(preview.isPlaying ? "Pause" : "Play from the playhead")
                Button {
                    preview.stop()
                    playheadBeats = 0
                } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 10))
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(BenchSecondaryButtonStyle(
                    tone: .neutral,
                    padding: EdgeInsets(top: 8, leading: 8,
                                        bottom: 8, trailing: 8),
                    radius: Bench.Metrics.Radius.controlLarge))
                .help("Back to the start")
            }
            Text(clock(math.seconds(beats: playheadBeats)))
                .font(Bench.Typo.mono(13, .semibold))
                .foregroundStyle(Bench.Palette.textPrimary)
                .frame(minWidth: 74, alignment: .leading)
            Text(String(format: "BAR %.1f",
                        playheadBeats / model.beatsPerBar + 1))
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textFaintest)

            HStack(spacing: 9) {
                Text("SNAP").eyebrow(Bench.Palette.textFaintest)
                BenchSegmented(
                    selection: $snap,
                    options: TimelineMath.Snap.allCases.map {
                        BenchSegmented<TimelineMath.Snap>.Option(
                            value: $0, label: $0.rawValue)
                    })
                    .help("Where clips land when dragged (hold ⌥ to bypass)")
            }
            .padding(.leading, 8)

            Spacer(minLength: 12)

            if zoom > detailedZoomLimit {
                BenchBadge("COARSE", tone: .warn)
                    .help("Past the cached waveform detail — clip shapes are "
                          + "approximate at this zoom; placement is exact")
            }
            Button {
                zoom = TimelineMath.clampZoom(zoom / 1.5)
            } label: {
                Text("－")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    // Padded before the content shape, not after: transparent
                    // padding takes no hits, so the bare glyph left a ~13×16
                    // target either side of a 150 pt slider.
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom out")
            BenchSlider(value: Binding(get: { Double(zoom) },
                                       set: { zoom = CGFloat($0) }),
                        range: Double(TimelineMath.minZoom)
                            ... Double(TimelineMath.maxZoom),
                        tint: Bench.Palette.textMuted)
                .frame(width: 150)
                .help("Zoom")
            Button {
                zoom = TimelineMath.clampZoom(zoom * 1.5)
            } label: {
                Text("＋")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Zoom in")
            Text(String(format: "%.0f px/s", zoom))
                .font(Bench.Typo.mono(11, .semibold))
                .foregroundStyle(Bench.Palette.textSecondary)
                .frame(minWidth: 52, alignment: .trailing)
            BenchToggleChip(isOn: $showsWaveforms, label: "Waveforms")
        }
        .padding(.horizontal, 20)
        .frame(height: 46)
        .background(Bench.Palette.windowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    /// Where the cached peaks stop having detail to show. Editing must not be
    /// capped by it — on a 3-minute source that would mean no zoom at all —
    /// so past this point the waveforms simply go coarse and say so.
    private var detailedZoomLimit: CGFloat {
        let longest = model.clips.compactMap(\.sourceDurationS).max() ?? 0
        return PeakSlice.usefulZoomCap(sourceDurationS: longest,
                                       binCount: WaveformExtractor.binCount)
    }

    // MARK: helpers

    private func peaksHandle(for clip: WorkbenchModel.Clip)
        -> PeaksStore.Handle? {
        guard let url = clip.material.auditionURL, !clip.isMissing else {
            return nil
        }
        return peaksStore.handle(
            id: clip.material.id, audioURL: url,
            cacheURL: StoragePaths.libraryWaveforms
                .appendingPathComponent("\(clip.material.id).peaks"))
    }

    /// Fade seconds as a share of the clip's drawn length. Fades are applied
    /// after stretching, so they are target-time seconds — the same time base
    /// the clip is drawn in.
    private func fadeFraction(_ clip: WorkbenchModel.Clip,
                              _ seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        let lengthS = math.seconds(beats: model.lengthBeats(of: clip))
        guard lengthS > 0 else { return 0 }
        return min(1, seconds / lengthS)
    }

    /// Snapshot before every mutation. The model is two arrays of value types,
    /// so undo is a swap — and dragging clips around without it is miserable.
    private func registerUndo() {
        let before = model.snapshot()
        undoManager?.registerUndo(withTarget: model) { target in
            let after = target.snapshot()
            target.apply(before)
            undoManager?.registerUndo(withTarget: target) { redoTarget in
                redoTarget.apply(after)
            }
        }
        undoManager?.setActionName("Edit Timeline")
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%d:%05.2f", Int(seconds) / 60,
               seconds.truncatingRemainder(dividingBy: 60))
    }

    private func select(_ id: String) {
        if NSEvent.modifierFlags.contains(.shift)
            || NSEvent.modifierFlags.contains(.command) {
            if selection.contains(id) { selection.remove(id) }
            else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }
}

/// The downward wedge on top of the playhead. Drawn rather than an SF Symbol so
/// its width matches the 1.5 pt line it caps.
private struct PlayheadCap: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// One lane's controls, beside its track. 100 pt because it carries three
/// rows — identity, state, and level — and the lane it heads is 100 pt tall.
struct LaneHeaderRow: View {
    @Binding var lane: WorkbenchModel.Lane
    /// The material kind on this lane, for the stem colour.
    let kind: String?
    let clipCount: Int
    let isSelected: Bool
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StemBar(kind: kind, height: 16)
                TextField("Lane", text: $lane.name)
                    .textFieldStyle(.plain)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .tint(Bench.Palette.accent)
                    .lineLimit(1)
                Spacer(minLength: 0)
                WorkbenchRemoveButton(help: "Remove lane", action: onRemove)
            }
            HStack(spacing: 6) {
                WorkbenchToggleBadge(kind: .solo, isOn: $lane.solo)
                WorkbenchToggleBadge(kind: .mute, isOn: $lane.muted)
                BenchSlider(value: $lane.gainDb, range: -24...6,
                            tint: Bench.Palette.stem(kind),
                            knobSize: Bench.Metrics.Slider.knobSmall)
                    .padding(.leading, 4)
                    .help("Lane gain")
            }
            HStack(spacing: 8) {
                Text(clipCount == 1 ? "1 CLIP" : "\(clipCount) CLIPS")
                    .metaLine()
                Spacer(minLength: 0)
                Text(String(format: "%+.1f dB", lane.gainDb))
                    .font(Bench.Typo.mono(10, .semibold))
                    .foregroundStyle(Bench.Palette.textSecondary)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .frame(height: ClipTimelineView.laneHeight)
        .background(isSelected ? Color.white.opacity(0.03) : .clear)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }
}
