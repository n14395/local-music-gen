import SwiftUI

/// The queue, as the design draws it in Studio's right rail.
///
/// It is embedded at several call sites, so it stays a plain vertical stack
/// with no chrome of its own — the host supplies the panel and the header.
struct JobQueueSection: View {
    let jobs: JobsStore
    /// Downloads share the queue with renders, because they share the machine:
    /// the design's whole argument for one list is that the Mac is never asked
    /// for two big jobs at once.
    var downloads: DownloadsStore?
    var modelName: ((String) -> String)?
    /// Enables drag-to-reorder on the queued rows. Off where the section is
    /// only a status readout — the gesture has to be worth the affordance, and
    /// only the queued rows can move (§5.8: the running one is a 409).
    var reorderable = false
    /// Show a track a finished row produced, by song id.
    var onShowInLibrary: ((String) -> Void)?

    /// The row a drag is currently hovering, so the drop target says where the
    /// job would land instead of silently accepting it.
    @State private var dropTarget: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(jobs.displayJobs) { job in
                row(job)
            }
            if let downloads {
                ForEach(Self.ordered(downloads.downloads.values)) { info in
                    let name = modelName?(info.modelId) ?? info.modelId
                    DownloadQueueRow(
                        info: info,
                        // A runtime install fetches no model, so the row says
                        // what it is doing rather than naming a download the
                        // user never started.
                        title: info.isRuntimeOnly ? "\(name) runtime" : name,
                        onPause: { Task { await downloads.pause(info.id) } },
                        onResume: { Task { await downloads.resume(info.id) } },
                        onCancel: { Task { await downloads.cancel(info.id) } })
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ job: JobsStore.ActiveJob) -> some View {
        let movable = reorderable && job.status == .queued
        let view = JobRow(job: job,
                          title: jobs.displayTitle(for: job.info),
                          modelName: jobs.modelName(job.info.modelId),
                          movable: movable,
                          isDropTarget: dropTarget == job.id,
                          onCancel: { Task { await jobs.cancel(job.id) } },
                          onDismiss: { jobs.dismiss(job.id) },
                          // Take a: a multi-take job made several tracks and
                          // one of them has to be the one selected. The rest
                          // are its neighbours in the list, and the row's own
                          // meta line already says how many there were.
                          onShowInLibrary: onShowInLibrary.flatMap { show in
                              job.producedSongIds.first.map { id in
                                  { show(id) }
                              }
                          })
        if movable {
            // The payload is the job id as a plain String: no exported UTType
            // in Info.plist, which a custom Transferable would need (the same
            // reason the workbench drags part ids).
            view
                .draggable(job.id)
                .dropDestination(for: String.self) { ids, _ in
                    guard let moving = ids.first else { return false }
                    let order = QueueReorder.order(
                        jobs.reorderableJobs.map(\.id),
                        moving: moving, onto: job.id)
                    guard let order else { return false }
                    Task { await jobs.reorder(order) }
                    return true
                } isTargeted: { hovering in
                    dropTarget = hovering ? job.id : nil
                }
        } else {
            view
        }
    }

    /// Transfers first, then whatever is waiting for one. The engine does not
    /// put a queue position on the wire for downloads (contract §4.2 has state
    /// only), so within a rank the order is the stable one by id rather than an
    /// arrival order nobody here actually knows.
    static func ordered(_ downloads: some Collection<DownloadInfo>) -> [DownloadInfo] {
        func rank(_ info: DownloadInfo) -> Int {
            switch info.state {
            case .downloading, .provisioning: 0
            case .paused: 1
            case .queued: 2
            }
        }
        return downloads.sorted { (rank($0), $0.id) < (rank($1), $1.id) }
    }
}

/// Where a dragged job lands. Pure, because the interesting part is an index
/// shuffle and dragging a row in a test is not a thing.
enum QueueReorder {
    /// The queued run order after dropping `moving` onto the row at `target`:
    /// it takes that row's place and pushes it along. Nil when the drag changes
    /// nothing — a row dropped on itself, or an id that is no longer queued
    /// (the top of the queue can legitimately start while the pointer is down).
    static func order(_ ids: [String], moving: String, onto target: String)
        -> [String]? {
        guard moving != target,
              let from = ids.firstIndex(of: moving),
              let to = ids.firstIndex(of: target) else { return nil }
        var out = ids
        out.remove(at: from)
        // `to` is the target's index in the ORIGINAL list. Dragging downwards,
        // removal has already shifted the target down one, so inserting at `to`
        // puts the job after it; dragging upwards, nothing below moved, so the
        // same index puts it before. Both are "takes that row's place".
        out.insert(moving, at: to)
        return out
    }
}

struct JobRow: View {
    let job: JobsStore.ActiveJob
    let title: String
    let modelName: String
    /// Draws the grip and takes the accent edge while a drag hovers. The row
    /// does not own the gesture — its host does, because a drop has to know
    /// about the rows either side of this one.
    var movable = false
    var isDropTarget = false
    let onCancel: () -> Void
    let onDismiss: () -> Void
    /// Present only on a row that finished and left a track behind, which is
    /// what makes it the row's own answer to "so where did it go".
    var onShowInLibrary: (() -> Void)?

    private var isRunning: Bool {
        switch job.status {
        case .queued, .loading, .generating, .encoding: true
        case .succeeded, .failed, .canceled: false
        }
    }

    private var isActive: Bool {
        switch job.status {
        case .loading, .generating, .encoding: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                if movable {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .help("Drag to run this one sooner")
                }
                statusGlyph
                Text(title)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                trailing
            }
            if isActive, let fraction = job.progress?.fraction {
                BenchProgressBar(fraction: fraction,
                                 track: Color.white.opacity(0.09))
            }
            Text(metaLine)
                .metaLine()
                .lineLimit(2)
            if let onShowInLibrary {
                // Its own line rather than another control in the header row:
                // the title up there already gives way to the status readout
                // and the dismiss button, and a third would leave a two-word
                // prompt showing.
                Button("Show in library", action: onShowInLibrary)
                    .buttonStyle(.bench(.quiet))
                    .help("Open the Library on this track")
            }
        }
        .padding(13)
        .benchCard(fill: isActive ? Bench.Palette.cardSelected : Bench.Palette.card,
                   stroke: isDropTarget ? Bench.Palette.accent
                       : isActive ? Bench.Palette.accent.opacity(0.26)
                                  : Bench.Palette.cardStrokeSoft,
                   radius: 11)
    }

    @ViewBuilder
    private var statusGlyph: some View {
        switch job.status {
        case .queued:
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                .frame(width: 13, height: 13)
        case .loading, .generating, .encoding:
            BenchSpinner(size: 13)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Bench.Palette.ok)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Bench.Palette.danger)
        case .canceled:
            Image(systemName: "xmark.circle")
                .font(.system(size: 12)).foregroundStyle(Bench.Palette.textMuted)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isActive, let fraction = job.progress?.fraction {
            Text("\(Int((fraction * 100).rounded()))%")
                .font(Bench.Typo.mono(11, .semibold))
                .foregroundStyle(Bench.Palette.accent)
        } else if case .queued = job.status {
            Text("WAITING")
                .font(Bench.Typo.mono(10))
                .foregroundStyle(Bench.Palette.textMuted)
        }
        if isRunning {
            Button("Cancel", action: onCancel)
                .buttonStyle(.bench(.quiet))
                .controlSize(.small)
        } else {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textMuted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
    }

    /// The mono second line: model, size of the ask, and where it is.
    private var metaLine: String {
        var parts = [modelName.uppercased()]
        if let duration = job.info.durationS {
            parts.append("\(Int(duration.rounded())) S")
        }
        // One row still means one job, so the row has to say how much work is
        // in it — otherwise a four-take render is indistinguishable from a
        // one-take one until four tracks appear.
        if let take = job.takeLabel {
            parts.append(take.uppercased())
        } else if job.info.count > 1 {
            parts.append("\(job.info.count) TAKES")
        }
        switch job.status {
        case .queued:
            if let position = job.info.queuePosition, position > 0 {
                parts.append("#\(position) IN QUEUE")
            } else {
                parts.append("QUEUED")
            }
        case .loading:
            parts.append((job.progress?.message ?? "Loading model").uppercased())
        case .generating, .encoding:
            if let eta = job.progress?.etaS, eta > 1 {
                parts.append("\(Self.duration(eta)) LEFT")
            } else if job.progress?.fraction == nil {
                // Honest about not knowing, rather than a bar frozen at zero.
                parts.append("WORKING")
            }
            if let message = job.progress?.message, !message.isEmpty {
                parts.append(message.uppercased())
            }
        case .succeeded:
            parts.append(successText.uppercased())
        case .failed:
            parts.append((job.error.map {
                APIError.http(status: 0, body: $0).localizedDescription
            } ?? "Failed").uppercased())
        case .canceled:
            parts.append("CANCELED")
        }
        return parts.joined(separator: " · ")
    }

    private var successText: String {
        switch job.info.task ?? "generate" {
        case "separate": "Done — parts saved"
        case "analyze": "Done — analysis saved"
        default: "Done — saved to Library"
        }
    }

    /// `40 S` · `1 MIN 12 S` · `49 MIN` · `1 H 15 MIN`, as the design writes
    /// them. Precision drops as the number grows: seconds matter when a render
    /// is a minute away and are noise on a 49-minute download.
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) S" }
        let minutes = total / 60
        if minutes >= 60 { return "\(minutes / 60) H \(minutes % 60) MIN" }
        let remainder = total % 60
        if minutes >= 10 || remainder == 0 { return "\(minutes) MIN" }
        return "\(minutes) MIN \(remainder) S"
    }
}

/// A download in the same queue, with the pause/resume/cancel the engine has
/// always supported and the UI has never offered.
///
/// The throughput readout goes through the same `DownloadRate` EMA the Models
/// screen uses. The engine samples speed by re-walking the model cache twice a
/// second, so dividing a raw sample straight into the remaining bytes makes an
/// ETA that swings between minutes and hours — and two rows showing the same
/// download would disagree with each other.
struct DownloadQueueRow: View {
    let info: DownloadInfo
    let title: String
    let onPause: () -> Void
    let onResume: () -> Void
    let onCancel: () -> Void

    @State private var rate = DownloadRate()

    private var fraction: Double? {
        guard info.bytesTotal > 0 else { return nil }
        return Double(info.bytesDone) / Double(info.bytesTotal)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                switch info.state {
                case .downloading, .provisioning:
                    BenchSpinner(size: 13)
                case .queued:
                    // The same hollow square a queued render gets: this row is
                    // waiting its turn, not suspended by anyone.
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                case .paused:
                    Image(systemName: "pause.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                Text(title)
                    .font(Bench.Typo.secondaryEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let fraction {
                    // Accent is this queue's "moving"; a row that is waiting
                    // still has a real percentage, drawn quietly.
                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(Bench.Typo.mono(11, .semibold))
                        .foregroundStyle(info.state == .downloading
                                         ? Bench.Palette.accent
                                         : Bench.Palette.textMuted)
                }
                // Pause is accepted but does nothing over a runtime install or a
                // download still waiting for its turn (contract §4.2). Offering
                // a live button there would be an affordance that quietly
                // fails, so it dims and says why.
                let blocked = DownloadFormat.pauseBlockedReason(info.state)
                Button(info.state == .paused ? "Resume" : "Pause") {
                    info.state == .paused ? onResume() : onPause()
                }
                .buttonStyle(.bench(.quiet))
                .disabled(blocked != nil)
                .opacity(blocked == nil ? 1 : 0.45)
                .help(blocked ?? "")
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bench(.destructive))
            }
            if let fraction {
                BenchProgressBar(fraction: fraction, height: 5,
                                 tint: info.state == .downloading
                                     ? Bench.Palette.accent
                                     : Bench.Palette.textMuted,
                                 track: Color.white.opacity(0.09))
            }
            Text(metaLine)
                .metaLine()
        }
        .padding(13)
        // The selected-card treatment means "this is the one the machine is
        // working on"; a download waiting its turn is an ordinary row.
        .benchCard(fill: info.state == .queued ? Bench.Palette.card
                                               : Bench.Palette.cardSelected,
                   stroke: info.state == .queued
                       ? Bench.Palette.cardStrokeSoft
                       : Bench.Palette.accent.opacity(0.24),
                   radius: 11)
        .onChange(of: info.speedBps, initial: true) { rate.ingest(info.speedBps) }
    }

    private var metaLine: String {
        if info.stage == "provisioning" {
            // Nothing is transferring yet, so there is no rate and no ETA to
            // report — just what the installer is doing.
            return (info.message?.uppercased()).map { "PREPARING ENVIRONMENT · \($0)" }
                ?? "PREPARING ENVIRONMENT"
        }
        let progress = DownloadFormat.progress(done: info.bytesDone,
                                               total: info.bytesTotal)
        if info.state == .paused { return progress + " · PAUSED" }
        // A queued download has real bytes — whatever is already cached — and
        // no rate, because nothing is transferring. `line` would print the tail
        // of the smoother's last window as this row's speed.
        if info.state == .queued { return progress + " · WAITING" }
        return DownloadFormat.line(done: info.bytesDone, total: info.bytesTotal,
                                   rate: rate)
    }
}
