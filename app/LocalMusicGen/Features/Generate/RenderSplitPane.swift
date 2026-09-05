import SwiftUI

/// The body of the render card: what the model is doing, beside what it is
/// saying.
///
/// This replaced the waveform hero. A take that is still rendering has no
/// waveform to show — only four of the eleven generative families can decode
/// partial audio at all, so the hero was a live envelope for some models and a
/// tinted bar for the rest. Both panes here work for every model, because both
/// are fed by things every model produces: the phase it reports (contract
/// §5.5) and the stderr the engine mirrors (`job.log`).
///
/// The height is fixed and neither pane grows into the other. Log lines arrive
/// several a second near the end of a render, and a pane that grew with them
/// would walk the buttons below down the screen while you were reaching for
/// them.
struct RenderSplitPane: View {
    let job: JobsStore.ActiveJob
    /// The job's log box rather than its lines — see `JobLog`. Handed
    /// straight to the pane below without being read here, so a line arriving
    /// redraws the log pane and not this card, its stage list or the render
    /// screen around it.
    let log: JobLog
    let stages: [PipelineStage]?
    let timing: RenderStageTiming
    let timings: RenderTimingStore
    let telemetry: TelemetryStore
    let modelId: String
    /// The catalog's own guess for the whole render, which the footer's
    /// "VS EST" is measured against. Nil where the model declares none.
    let estimateS: Double?

    static let height: CGFloat = 296
    static let stageColumnWidth: CGFloat = 296

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RenderStageList(stages: stages ?? [], progress: job.progress,
                            status: job.status, timing: timing,
                            timings: timings, modelId: modelId)
                .frame(width: Self.stageColumnWidth)
            EngineLogPane(log: log, telemetry: telemetry,
                          timing: timing, progress: job.progress,
                          estimateS: estimateS, isLive: !job.status.isTerminal)
        }
        .frame(height: Self.height)
    }
}

// MARK: - Stages

/// The model's declared pipeline, one row per stage, all of it visible from
/// the first frame.
///
/// Every stage keeps its row for the whole render — the list exists to say
/// what the model *will* do, and one that revealed stages as it reached them
/// would answer "how much is left" with a shrug. Only the running stage
/// expands, and only one is ever running.
struct RenderStageList: View {
    let stages: [PipelineStage]
    let progress: JobProgress?
    let status: JobStatus
    let timing: RenderStageTiming
    let timings: RenderTimingStore
    let modelId: String

    private enum State { case done, active, pending }

    private var activeIndex: Int? {
        // `timing.current` rather than `progress?.phase`: the supervisor's own
        // terminal event carries no phase, and recomputing from that would
        // blink every row back to pending for the frame before the job ends.
        guard let phase = timing.current else { return nil }
        return stages.firstIndex { $0.id == phase }
    }

    var body: some View {
        VStack(spacing: 6) {
            if stages.isEmpty {
                // A model that declares no pipeline still gets the pane. It
                // knows one thing — that it is working, and for how long — and
                // saying that in the same shape as everyone else beats
                // collapsing the layout around its silence.
                activeCard(label: progress?.message ?? "Working",
                           elapsed: timing.total(now: .now), counted: nil,
                           fraction: progress?.fraction)
            } else {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    // An optional stage the job skipped (passed without ever
                    // reporting it) is quietly dropped — a checkmark on work
                    // that never ran would be a small lie. Contract §5.5.
                    if !(stage.optional == true && state(at: index) == .done
                         && timing.elapsed(stage.id, now: .now) == nil) {
                        row(stage, state: state(at: index))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.2), value: activeIndex)
    }

    private func state(at index: Int) -> State {
        if status.isTerminal { return .done }
        guard let activeIndex else { return .pending }
        if index < activeIndex { return .done }
        return index == activeIndex ? .active : .pending
    }

    @ViewBuilder
    private func row(_ stage: PipelineStage, state: State) -> some View {
        switch state {
        case .active:
            TimelineView(.periodic(from: .now, by: 0.1)) { tick in
                activeCard(label: stage.label,
                           elapsed: timing.elapsed(stage.id, now: tick.date),
                           counted: counted,
                           fraction: fraction,
                           perStep: timing.secondsPerStep(step: progress?.step,
                                                          now: tick.date))
            }
        case .done:
            quietRow(stage.label, tint: Bench.Palette.textQuaternary,
                     trailing: timing.elapsed(stage.id, now: .now)
                         .map(Self.seconds)) {
                Image(systemName: "checkmark")
                    .font(Bench.Typo.mono(9, .bold))
                    .foregroundStyle(Bench.Palette.ok)
                    .frame(width: 15, height: 15)
                    .background(Circle().fill(Bench.Palette.ok.opacity(0.16)))
            }
        case .pending:
            // The estimate is a memory of the last time this model ran this
            // stage, not a projection — see `RenderTimingStore`. A stage
            // nobody has watched yet simply has no figure beside it.
            // An optional stage dims further: it may never run at all
            // (declared `optional` in the catalog — audit §4 minors).
            quietRow(stage.label, tint: Bench.Palette.textSecondary,
                     trailing: timings.estimate(modelId: modelId,
                                                phase: stage.id)
                         .map { "≈ \(Int($0.rounded())) s" }) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                    .frame(width: 15, height: 15)
            }
            .opacity(stage.optional == true ? 0.35 : 0.55)
        }
    }

    /// `6 / 8`, only where the adapter genuinely counts steps. Absence is
    /// information here (contract §5.5) and is drawn as absence.
    private var counted: String? {
        guard let step = progress?.step, let steps = progress?.steps,
              steps > 0 else { return nil }
        return "\(step) / \(steps)"
    }

    /// The running stage's own progress, which is not the job's. A stage with
    /// no step count falls back to the job fraction, which is the same
    /// approximation the card's percentage makes.
    private var fraction: Double? {
        if let step = progress?.step, let steps = progress?.steps, steps > 0 {
            return Double(step) / Double(steps)
        }
        return progress?.fraction
    }

    private func activeCard(label: String, elapsed: TimeInterval?,
                            counted: String?, fraction: Double?,
                            perStep: TimeInterval? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                BenchSpinner(size: 15)
                Text(label)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.accent)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let counted {
                    Text(counted)
                        .font(Bench.Typo.mono(11, .semibold))
                        .foregroundStyle(Bench.Palette.accent)
                }
            }
            if let fraction {
                BenchProgressBar(fraction: fraction, height: 5,
                                 track: Color.white.opacity(0.09))
            } else {
                // Genuinely unknown, and a bar frozen at zero reads as a hang.
                BenchProgressBar(fraction: 0, height: 5, tint: .clear,
                                 track: Color.white.opacity(0.09))
            }
            HStack(spacing: 0) {
                if let elapsed {
                    Text("\(Self.oneDecimal(elapsed)) S ELAPSED")
                }
                Spacer(minLength: 8)
                if let perStep {
                    Text("\(Self.oneDecimal(perStep)) S / STEP")
                }
            }
            .font(Bench.Typo.mono(10))
            .tracking(0.6)
            .foregroundStyle(Bench.Palette.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Bench.Palette.cardSelected))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Bench.Palette.accent.opacity(0.3), lineWidth: 1))
    }

    private func quietRow<Marker: View>(
        _ label: String, tint: Color, trailing: String?,
        @ViewBuilder marker: () -> Marker) -> some View {
        HStack(spacing: 11) {
            marker()
            Text(label)
                .font(Bench.Typo.secondary)
                .foregroundStyle(tint)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let trailing {
                Text(trailing)
                    .font(Bench.Typo.mono(11, .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Bench.Palette.inset))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .strokeBorder(Bench.Palette.hairlineFaint, lineWidth: 1))
    }

    /// `0.4 s` · `6.1 s` · `14 s` — how long a stage *took*, measured. A
    /// decimal is worth printing while the number is small enough for one to
    /// mean something; past ten seconds it is noise on a figure nobody is
    /// timing to a tenth.
    ///
    /// An estimate never gets one. `≈ 3.0 s` claims a precision the word
    /// "about" has just disclaimed, which is why the pending rows round.
    static func seconds(_ value: TimeInterval) -> String {
        value < 10 ? "\(oneDecimal(value)) s" : "\(Int(value.rounded())) s"
    }

    static func oneDecimal(_ value: TimeInterval) -> String {
        String(format: "%.1f", max(0, value))
    }
}

// MARK: - Log

/// What the worker is saying, as it says it.
///
/// The engine mirrors the worker's stderr line by line (`job.log`), which is
/// the one progress signal every family produces — an adapter that cannot
/// decompose its work into phases still prints. Nothing here is parsed or
/// interpreted: the lines are the model's own words, timestamped when the app
/// heard them.
struct EngineLogPane: View {
    /// The only view in the app that observes a job's log lines. Everything
    /// else takes the box and never reads it — see `JobLog`.
    let log: JobLog
    let telemetry: TelemetryStore
    let timing: RenderStageTiming
    let progress: JobProgress?
    let estimateS: Double?
    let isLive: Bool

    @State private var cursorOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            body(of: log.lines)
            footer
        }
        .padding(.horizontal, 15).padding(.vertical, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(Bench.Palette.well))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Bench.Palette.hairline, lineWidth: 1))
        .task {
            // The cursor is the liveness signal — the one thing on this card
            // that keeps moving when a model goes quiet for a minute mid-step.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(560))
                cursorOn.toggle()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Text("ENGINE")
                .font(Bench.Typo.mono(10))
                .tracking(1.4)
                .foregroundStyle(Bench.Palette.textFaintest)
            Spacer(minLength: 8)
            if isLive {
                Text("LIVE")
                    .font(Bench.Typo.mono(10))
                    .tracking(1)
                    .foregroundStyle(Bench.Palette.accent)
            }
        }
        .padding(.bottom, 9)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func body(of lines: [RenderLogLine]) -> some View {
        if lines.isEmpty {
            // Not every adapter prints. The pane keeps its shape and says so
            // rather than leaving a hole where the render's voice should be.
            Text(isLive ? "This model prints nothing while it works."
                        : "No output.")
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textDimmest)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topLeading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    // Lazy: the buffer holds `JobsStore.logCap` lines and a
                    // line arrives every step near the end of a render, so an
                    // eager stack rebuilt two hundred rows to add one — and
                    // scrolled to the bottom of them afterwards.
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(lines.enumerated()), id: \.element.id) {
                            index, line in
                            row(line, fromEnd: lines.count - 1 - index)
                                .id(line.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomLeading)
                .onChange(of: lines.last?.id) {
                    guard let last = lines.last?.id else { return }
                    proxy.scrollTo(last, anchor: .bottom)
                }
                .onAppear {
                    if let last = lines.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(_ line: RenderLogLine, fromEnd: Int) -> some View {
        HStack(spacing: 0) {
            Text(Self.clockText(line.at) + "  " + line.text)
                .font(Bench.Typo.mono(11))
                // Never wraps: a line that folded onto a second row would push
                // the whole pane's rhythm off and read as two events.
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(Self.fade(fromEnd: fromEnd))
            if fromEnd == 0 && isLive {
                Rectangle()
                    .fill(Bench.Palette.accent)
                    .frame(width: 7, height: 12)
                    .padding(.leading, 5)
                    .opacity(cursorOn ? 1 : 0)
            }
        }
    }

    /// The newest line is the only one at full strength; the three behind it
    /// step down, and everything older sits at the bottom of the ramp. Reading
    /// the pane from the bottom up is then reading backwards in time without
    /// having to check the clock.
    static func fade(fromEnd: Int) -> Color {
        switch fromEnd {
        case 0: Bench.Palette.textPrimary
        case 1: Bench.Palette.textQuaternary
        case 2: Bench.Palette.textFaint
        default: Bench.Palette.textDimmest
        }
    }

    private var footer: some View {
        HStack(spacing: 9) {
            // Device-wide GPU, never this job's share — macOS publishes no
            // per-process figure without root, which is why the label is
            // "GPU" and not "this render". Each readout is dropped rather
            // than zeroed when the engine cannot measure it.
            if let gpu = telemetry.gpuPercent {
                Text("GPU \(Int(gpu.rounded()))%")
            }
            if let bytes = telemetry.workerBytes {
                if telemetry.gpuPercent != nil { Text("·") }
                Text("\(TelemetryStore.gigabytes(bytes)) GB")
            }
            Spacer(minLength: 8)
            if let drift {
                Text(drift.text).foregroundStyle(drift.tone)
            }
        }
        .font(Bench.Typo.mono(10))
        .tracking(0.6)
        .foregroundStyle(Bench.Palette.textDimmest)
        .padding(.top, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
        .padding(.top, 8)
    }

    /// `−8 S VS EST` — where this render has got to against the catalog's own
    /// estimate for it, projected forward by the engine's remaining ETA.
    ///
    /// Held back until a stage has finished. Before that the projection is the
    /// estimate plus nothing, so it would read `0 S VS EST` for the length of
    /// a cold model load and then lurch.
    var drift: (text: String, tone: Color)? {
        guard let estimateS, estimateS > 0,
              let elapsed = timing.total(now: .now),
              timing.finished().count >= 1 else { return nil }
        let projected = elapsed + (progress?.etaS ?? 0)
        let delta = projected - estimateS
        guard abs(delta) >= 1 else { return nil }
        let sign = delta < 0 ? "−" : "+"
        return ("\(sign)\(Int(abs(delta).rounded())) S VS EST",
                delta < 0 ? Bench.Palette.ok : Bench.Palette.warn)
    }

    /// `13:04:56`. Shared with "Copy log" so the pasted text reads exactly
    /// like the pane it was copied from.
    static func clockText(_ date: Date) -> String { clock.string(from: date) }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
