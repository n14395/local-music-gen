import SwiftUI

// The small parts the library screen is assembled from. They live here rather
// than in `Design/` because they are library-specific: a checkbox that only the
// songs list uses, the tag well, the 3×2 action tile. Anything genuinely
// shared — badges, stars, waveforms, stem bars, menus — comes from Bench.

// MARK: - Formatting

/// Every string in this screen that is a *number* goes through here, because
/// the design renders them all in mono and all in the same shapes: `9.9 S`,
/// `0:02 / 0:09`, `TODAY 13:00`, `636 kB`.
enum LibraryFormat {
    /// `9.9` / `120` — one decimal, but never a trailing `.0`, which is what
    /// the design's `10 S` beside `9.9 S` is showing.
    static func seconds(_ value: Double) -> String {
        guard value.isFinite, value > 0 else { return "0" }
        let rounded = (value * 10).rounded() / 10
        return rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    static func clock(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "0:00" }
        let total = Int(value.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// `TODAY 13:00` · `YESTERDAY` · `17 AUG` · `17 AUG 2025`. The row meta
    /// line is mono and tight, so old dates lose their time and very old ones
    /// gain a year rather than every row carrying a full timestamp.
    static func when(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "TODAY " + date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        let sameYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        let format: Date.FormatStyle = sameYear
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.day().month(.abbreviated).year()
        return date.formatted(format).uppercased()
    }

    /// Measured from the file on disk rather than stored alongside the row, so
    /// it stays honest if the audio is replaced or trimmed underneath us.
    static func fileSize(of url: URL) -> String? {
        guard let bytes = try? url
            .resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }

    /// `107.0 BPM · 8B (A♭ min)` — whatever of the three the analysis has.
    static func tempoAndKey(_ analysis: AnalysisRecord?) -> String? {
        guard let analysis else { return nil }
        var parts: [String] = []
        if let bpm = analysis.bpm { parts.append(String(format: "%.1f BPM", bpm)) }
        switch (analysis.camelot, analysis.keyName) {
        case (let camelot?, let key?): parts.append("\(camelot) (\(key))")
        case (let camelot?, nil): parts.append(camelot)
        case (nil, let key?): parts.append(key)
        case (nil, nil): break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Beats are only in the analysis payload, not in a column, so this decodes
    /// the stored JSON. nil when the owner was never analysed — the design's
    /// green `detected · 358 beats` has to be able to say "no" too.
    static func beatGrid(_ analysis: AnalysisRecord?) -> (text: String, detected: Bool) {
        guard let analysis,
              let payload = try? BackendClient.decoder.decode(
                  AnalysisPayload.self, from: Data(analysis.analysisJSON.utf8)),
              let beats = payload.beats, !beats.isEmpty else {
            return ("not analysed", false)
        }
        return ("detected · \(beats.count) beats", true)
    }
}

// MARK: - Checkbox

/// The 15 pt tick the songs list uses to build an A/B pair. Accent-filled when
/// ticked; a hairline square when not.
struct LibraryCheckbox: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isOn ? Bench.Palette.accent : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(isOn ? .clear : Color.white.opacity(0.16),
                                  lineWidth: 1.5))
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Bench.Palette.onAccent)
                    }
                }
                .frame(width: 15, height: 15)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Remove from the comparison" : "Pick for an A/B comparison")
    }
}

// MARK: - Favourite

/// The heart on a hearted row, in the same pink the rest of the app gives a
/// favourite.
///
/// It keeps its slot when the row is not a favourite rather than disappearing:
/// a mark that changes the width of every other row's trailing cluster makes
/// the stars beside it jitter left and right down the list, which is a worse
/// read than one empty column.
struct FavouriteHeart: View {
    let isFavourite: Bool
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "heart.fill")
            .font(.system(size: size))
            .foregroundStyle(TrackRow.favouriteHeart)
            .opacity(isFavourite ? 1 : 0)
            .frame(width: size + 3)
            .accessibilityHidden(!isFavourite)
            .accessibilityLabel("Favourite")
            .help(isFavourite ? "Favourite" : "")
    }
}

// MARK: - Stem badge

/// `STEM` / `NOTES` / `FEATURES` in the part's own colour.
///
/// `BenchBadge` deliberately offers a fixed set of semantic tones — accent, ok,
/// warn, danger — and stem identity is none of those: it is a per-part hue that
/// has to match the swatch bar, the waveform and the playhead beside it. So the
/// one badge that carries a stem colour is drawn here rather than widening the
/// shared component's tone list with a case only this screen can use.
struct LibraryStemBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(Bench.Typo.mono(10, .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.badge,
                                         style: .continuous)
                .fill(color.opacity(0.12)))
            .fixedSize()
    }
}

// MARK: - Empty state

/// `ContentUnavailableView` in Bench clothing. The system view brings its own
/// greys and its own idea of a headline size, neither of which is in the
/// palette, so the two states the library has are drawn here instead.
struct LibraryEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textSecondary)
            Text(message)
                .font(Bench.Typo.small)
                .foregroundStyle(Bench.Palette.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Action grid

/// One tile of an inspector's action grid. `primary` is the lime one — a grid
/// has at most one, and the design uses it to say which action the panel is
/// really for (`Add to Workbench`).
struct LibraryActionTile: View {
    let title: String
    var tone: Tone = .neutral
    var isEnabled = true
    /// Rule 5 of the design: an inapplicable control dims and says why rather
    /// than disappearing, so this is required even when the tile is enabled.
    let help: String
    let action: () -> Void

    enum Tone { case neutral, primary, destructive }

    var body: some View {
        Group {
            switch tone {
            case .primary:
                Button(action: action) { label }
                    .buttonStyle(BenchPrimaryButtonStyle(size: .compact,
                                                         glows: false))
            case .neutral:
                Button(action: action) { label }.buttonStyle(tile(.neutral))
            case .destructive:
                Button(action: action) { label }.buttonStyle(tile(.destructive))
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
    }

    private var label: some View {
        Text(title)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(maxWidth: .infinity)
    }

    /// Same rectangle for every tone, so the two rows of the grid line up
    /// whatever mix of tones they hold.
    private func tile(_ tone: BenchSecondaryButtonStyle.Tone)
        -> BenchSecondaryButtonStyle {
        BenchSecondaryButtonStyle(
            tone: tone,
            padding: EdgeInsets(top: 11, leading: 8, bottom: 11, trailing: 8),
            radius: 9)
    }
}

// MARK: - Tags

/// `TAGS` — chips plus a dashed `＋ add`.
///
/// Every edit is handed back as the whole tag list rather than as an
/// add/remove pair, because `SongEditor` owns the write and targets the song
/// the text was typed for, not the one on screen when the write lands.
struct LibraryTagField: View {
    let tags: [String]
    let onChange: ([String]) -> Void

    @State private var adding = false
    @State private var draft = ""
    @State private var hovered: String?
    @FocusState private var focused: Bool

    var body: some View {
        FlowLayout(spacing: 6, rowSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                BenchTag(text: tag)
                    .overlay(alignment: .topTrailing) {
                        if hovered == tag {
                            Button {
                                onChange(tags.filter { $0 != tag })
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Bench.Palette.textMuted)
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .help("Remove “\(tag)”")
                        }
                    }
                    .onHover { hovered = $0 ? tag : nil }
            }
            if adding {
                TextField("tag", text: $draft)
                    .textFieldStyle(.plain)
                    .tint(Bench.Palette.accent)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .frame(width: 84)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                                 style: .continuous)
                        .fill(Bench.Palette.windowBackground))
                    .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                              style: .continuous)
                        .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
                    .focused($focused)
                    .onSubmit(commit)
                    // A field that loses focus without Return has still been
                    // typed into; the library's other fields commit on the way
                    // out too, so this one does as well.
                    .onChange(of: focused) { if !focused { commit() } }
                    .onAppear { focused = true }
            } else {
                Button {
                    adding = true
                } label: {
                    Text("＋ add")
                        .font(Bench.Typo.caption)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                                  style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14),
                                          style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a tag — commas separate several at once")
            }
        }
    }

    private func commit() {
        let typed = draft.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        draft = ""
        adding = false
        guard !typed.isEmpty else { return }
        onChange(tags + typed.filter { !tags.contains($0) })
    }
}

// MARK: - A/B compare

/// Two library songs held side by side: A plays, Tab switches to B *at the same
/// position*, and the transport bar's right slot becomes the `A|B` switch.
///
/// It is a reference type held by the shell rather than screen state because
/// the transport bar lives outside the library screen — the bar has to be able
/// to read which of the pair is playing and to flip it.
@MainActor @Observable
final class LibraryCompare {
    private(set) var a: SongRecord?
    private(set) var b: SongRecord?
    private(set) var isB = false

    var isActive: Bool { a != nil && b != nil }
    var current: SongRecord? { isB ? b : a }
    var other: SongRecord? { isB ? a : b }

    func start(a: SongRecord, b: SongRecord, playback: PlaybackController) {
        self.a = a
        self.b = b
        isB = false
        play(a, playback: playback, at: 0)
    }

    /// Swap sides without losing your place. This is the whole point of the
    /// feature: the two takes are the same music, so the comparison is only
    /// worth anything if the switch lands on the same bar.
    func toggle(playback: PlaybackController) {
        guard isActive else { return }
        let position = playback.currentTime
        isB.toggle()
        guard let next = current else { return }
        play(next, playback: playback, at: position)
    }

    /// Follow a play started somewhere other than the switch — a row's play
    /// button, its waveform. Without this the transport bar's `A|B` keeps
    /// pointing at A while B is coming out of the speakers, and Tab then
    /// "switches" to the side that is already playing.
    func focus(songId: String) {
        guard isActive else { return }
        if songId == b?.id { isB = true }
        else if songId == a?.id { isB = false }
    }

    func end() {
        a = nil
        b = nil
        isB = false
    }

    private func play(_ song: SongRecord, playback: PlaybackController,
                      at position: Double) {
        // `play` toggles pause when handed the id that is already loaded, which
        // on a switch would stop the comparison instead of moving it.
        if playback.currentSongId != song.id {
            playback.play(url: song.fileURL, songId: song.id, title: song.title,
                          duration: song.durationS, subtitle: subtitle)
        }
        if position > 0 {
            // Seek after play, never before: the item is only replaced by
            // `play`, and seeking the outgoing item moves the wrong track.
            playback.seek(to: min(position, max(0, song.durationS - 0.05)))
        }
    }

    /// The keystroke the switch is actually bound to. The design writes bare
    /// Tab, but a bare Tab shortcut is window-scoped and would trap focus for
    /// the length of the comparison — see `LibraryScreen.selectionControls`.
    /// The transport bar's second line has to name the key that really works,
    /// so both it and the button read it from here.
    static let switchKey = "⌥TAB"
    static let switchKeyLabel = "SWITCH WITH \(switchKey)"

    /// `A · SWITCH TO B WITH ⌥TAB` — the transport subtitle the design writes.
    var subtitle: String {
        isB ? "B · SWITCH TO A WITH \(Self.switchKey)"
            : "A · SWITCH TO B WITH \(Self.switchKey)"
    }
}
