import AppKit
import SwiftUI

/// The library inspector when more than one row is ticked.
///
/// The single-row pane renames, rates, restyles and explains, and almost none
/// of that survives being asked of twenty rows at once — a title field over
/// twenty titles has nothing true to put in it. So this is not that pane with
/// controls removed; it is the shorter list of things that genuinely mean the
/// same for many as for one, and it says out loud how many it is about before
/// any of them are pressed.
struct LibrarySelectionInspector: View {
    let selection: LibrarySelection
    let library: LibraryStore
    let parts: PartsStore
    let playback: PlaybackController
    let onCompare: () -> Void
    let onAddToWorkbench: (PartRecord) -> Void
    let onClear: () -> Void
    /// Rows have gone; whoever owns the tick set has to drop them.
    let onDeleted: () -> Void

    @State private var confirmDelete = false
    @State private var exportNotice: String?
    /// Whether that notice is a complaint, so a partial export does not read
    /// as a quiet success in the same grey as "Exported 12 files."
    @State private var exportFailed = false
    /// Ambient, optional — see `SongDetailView`; absent means "ask".
    @Environment(AppSettings.self) private var appSettings: AppSettings?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                favouriteAndRating
                actions
                if let exportNotice {
                    Text(exportNotice)
                        .font(Bench.Typo.caption)
                        .foregroundStyle(exportFailed
                                         ? Bench.Palette.dangerText
                                         : Bench.Palette.textQuaternary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footnote
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Delete \(selection.count) items?",
            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete \(selection.count) and their files",
                   role: .destructive, action: deleteAll)
        } message: {
            Text("The audio files go too, and their parts with them. This "
                 + "cannot be undone.")
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(selection.count) selected")
                    .font(Bench.Typo.inspectorTitle)
                    .tracking(-0.17)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 8)
                Button("Clear", action: onClear)
                    .buttonStyle(.bench(.quiet))
            }
            Text(ActionFormat.join([
                selection.kindLine,
                selection.durationS.map { ActionFormat.duration($0) },
                selection.unresolved > 0
                    ? "\(selection.unresolved) NO LONGER IN THE LIBRARY" : nil]))
                .metaLine()
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: favourite + rating

    private var favouriteAndRating: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: toggleFavourite) {
                HStack(spacing: 9) {
                    Image(systemName: selection.allFavourite
                          ? "heart.fill" : "heart")
                        .font(.system(size: 13))
                        .foregroundStyle(selection.allFavourite
                                         ? TrackRow.favouriteHeart
                                         : Bench.Palette.textFaint)
                    // A mixed selection fills in rather than emptying out:
                    // "remove" only once there is nothing left to add, so one
                    // press never silently un-hearts the ones that were.
                    Text(selection.allFavourite
                         ? "Remove all from favourites"
                         : "Add all to favourites")
                        .font(Bench.Typo.body)
                        .foregroundStyle(Bench.Palette.textSecondary)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 10) {
                Text("RATE ALL").eyebrow()
                // Filled only where they agree. Showing one row's stars over
                // a selection that disagrees would invite a press that
                // overwrites the other nineteen with a number nobody chose.
                RatingStars(rating: selection.sharedRating ?? 0, size: 15,
                            spacing: 2, onRate: rateAll)
                if selection.sharedRating == nil {
                    Text("MIXED")
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textFaintest)
                }
                Spacer(minLength: 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .benchCard()
    }

    // MARK: actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DO THIS TO ALL OF THEM").eyebrow()
            LibraryActionTile(
                title: "A / B compare",
                isEnabled: selection.canCompare,
                help: selection.canCompare
                    ? "Compare the first two against each other"
                    : "Needs two songs — a comparison is between a pair",
                action: onCompare)
            LibraryActionTile(
                title: "Add to Workbench",
                isEnabled: selection.canAddToWorkbench,
                help: selection.canAddToWorkbench
                    ? "Put every one of these parts on the bench"
                    : "Parts only — a whole song goes on the bench as its "
                        + "separated parts, not as one lane",
                action: { for part in selection.parts { onAddToWorkbench(part) } })
            LibraryActionTile(
                title: "Export…",
                help: "Copy every file into a folder you pick",
                action: exportAll)
            LibraryActionTile(
                title: "Reveal in Finder",
                isEnabled: !selection.fileURLs.isEmpty,
                help: "Show all of them in one Finder window",
                action: {
                    NSWorkspace.shared
                        .activateFileViewerSelecting(selection.fileURLs)
                })
            LibraryActionTile(
                title: "Delete…", tone: .destructive,
                help: "Delete all \(selection.count) and their audio files",
                action: {
                    if appSettings?.confirmDeletes ?? true {
                        confirmDelete = true
                    } else {
                        deleteAll()
                    }
                })
        }
    }

    private var footnote: some View {
        Text("Renaming, restyling and the rest stay on the single-row panel — "
             + "they need one answer each, and there is no honest one to give "
             + "for \(selection.count) rows at once.")
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textFaintest)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: doing it

    private func toggleFavourite() {
        let wanted = !selection.allFavourite
        library.update(selection.songs.filter { $0.favorite != wanted }
            .map { var song = $0; song.favorite = wanted; return song })
        parts.update(selection.parts.filter { $0.favorite != wanted }
            .map { var part = $0; part.favorite = wanted; return part })
    }

    private func rateAll(_ rating: Int) {
        library.update(selection.songs.filter { $0.rating != rating }
            .map { var song = $0; song.rating = rating; return song })
        parts.update(selection.parts.filter { $0.rating != rating }
            .map { var part = $0; part.rating = rating; return part })
    }

    private func deleteAll() {
        // Anything playing out of a file about to be removed is stopped
        // first; a player holding a deleted file is a stall with no error.
        for song in selection.songs { playback.stop(songId: song.id) }
        for part in selection.parts { playback.stop(songId: part.id) }
        library.delete(selection.songs)
        parts.delete(selection.parts)
        onDeleted()
    }

    /// Copy every file into one folder.
    ///
    /// A folder rather than a save panel per file: twenty save panels is not a
    /// feature. Names collide — two songs called `track042` from different
    /// batches, or a song and its own stem — so a taken name gets a numeric
    /// suffix rather than silently overwriting a file — whether this export
    /// wrote it a moment ago or an earlier one left it there.
    private func exportAll() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export here"
        panel.message = "Choose a folder for \(selection.count) files"
        panel.begin { response in
            guard response == .OK, let folder = panel.url else { return }
            // Seeded with what the folder already holds, so a name that is
            // taken takes the `-2` suffix — which is what `unique`'s own
            // comment has always claimed. It used to start empty and
            // `removeItem` the destination first, and a folder chooser (unlike
            // a save panel) never asks about replacing anything: exporting a
            // second selection into a folder an earlier one had used deleted
            // those files without a word, and a copy that then failed left
            // neither.
            var used = Set(((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil)) ?? [])
                .map(\.lastPathComponent))
            var written = 0
            var firstFailure: String?
            for (url, name) in exportNames() {
                let unique = Self.unique(name, taken: &used)
                let destination = folder.appendingPathComponent(unique)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    written += 1
                } catch {
                    if firstFailure == nil {
                        firstFailure = error.localizedDescription
                    }
                    continue
                }
            }
            let total = selection.count
            exportFailed = written != total
            exportNotice = written == total
                ? "Exported \(written) files."
                : "Exported \(written) of \(total) — "
                    + (firstFailure ?? "the rest could not be copied.")
        }
    }

    private func exportNames() -> [(URL, String)] {
        selection.songs.map {
            ($0.fileURL, SongDetailView.exportName(title: $0.title,
                                                   fileName: $0.fileName))
        } + selection.parts.map {
            ($0.fileURL, SongDetailView.exportName(title: $0.name,
                                                   fileName: $0.fileName))
        }
    }

    /// `track042.wav`, then `track042-2.wav`, then `track042-3.wav`.
    static func unique(_ name: String, taken: inout Set<String>) -> String {
        guard taken.contains(name) else {
            taken.insert(name)
            return name
        }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            n += 1
        }
    }
}
