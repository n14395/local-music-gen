// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The window's navigation column: the destination list, the Library's scopes,
/// and the contextual footer.
///
/// A view of its own rather than a `MainWindow` property, and that is the whole
/// point of it. Its counts read `library.results`, `partsStore.results`,
/// `catalog.models` and `workbench.clips`; while this was computed inside
/// `MainWindow.body` those reads subscribed the *window* to all four, so a take
/// landing in the library rebuilt the entire screen next to the sidebar in
/// order to change a number in it. Now the redraw stops at this column.
struct ShellSidebar: View {
    let env: AppEnvironment
    @Binding var destination: Destination
    @Binding var libraryScope: LibraryScope

    var body: some View { sidebar }

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Reserved for the traffic lights, which the system draws over the
            // top-left of the window content.
            Color.clear.frame(height: Bench.Metrics.topBarHeight)

            // Scrolls only when it has to. The footer below is two cards
            // tall on most screens, and at the window's 700 pt floor the nav
            // and the footer together no longer fit — without this the stack
            // squeezes whatever it can reach and the cards clip.
            // Indicators stay on their macOS default — when the nav *does*
            // overflow, the overlay bar is the only thing saying there is
            // more of it below.
            ScrollView(.vertical) { navList }
                .scrollBounceBehavior(.basedOnSize)

            SidebarFooterCard(env: env, destination: destination,
                              libraryScope: libraryScope)
        }
        .frame(width: Bench.Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
        }
    }

    private var navList: some View {
        VStack(spacing: 2) {
                ForEach(Destination.Section.allCases, id: \.self) { section in
                    BenchSidebarHeading(text: section.rawValue,
                                        topPadding: section == .make ? 14 : 18)
                    ForEach(Destination.inSection(section)) { item in
                        BenchSidebarRow(destination: item,
                                        title: item.title,
                                        glyph: glyph(for: item),
                                        count: count(for: item),
                                        isBusy: isBusy(item),
                                        selection: navigation)
                        // The Library's scopes live under it rather than in the
                        // screen, and stay open from every destination: they
                        // are five places you can go, and a list that only
                        // appears once you are already there cannot take you
                        // anywhere. Picking one from elsewhere goes to the
                        // Library rather than quietly re-aiming a screen you
                        // are not looking at — which is also why none of them
                        // reads as selected until you are on it.
                        //
                        // `sidebarScopes`, not `allCases`: the sixth scope is
                        // All, and All is the Library row itself.
                        if item == .library {
                            ForEach(LibraryScope.sidebarScopes) { scope in
                                BenchSidebarSubRow(
                                    scope: scope, title: scope.title,
                                    symbol: scope.symbol,
                                    showsSelection: destination == .library,
                                    count: subRowCount(scope),
                                    selection: Binding(
                                        get: { libraryScope },
                                        set: {
                                            libraryScope = $0
                                            destination = .library
                                        }))
                            }
                        }
                    }
                }
            }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    /// The destination rows write through here rather than straight to the
    /// binding, because one of them has somewhere to be as well as something to
    /// select.
    ///
    /// Clicking **Library** means the whole library. It used to mean nothing at
    /// all once you were already in it — the row was a lid over five scopes,
    /// and pressing it returned you to whichever slice you had last opened, so
    /// the one view it could never give you was all of it. Now it goes to
    /// `.all`, exactly as the scopes below it go to theirs, and it reads as
    /// selected with no sub-row lit beneath it.
    private var navigation: Binding<Destination> {
        Binding(get: { destination },
                set: { next in
                    if next == .library { libraryScope = .all }
                    destination = next
                })
    }

    /// The one scope whose size is what it is for: how many tracks carry
    /// applied edits. The others are read by name.
    ///
    /// Off the store's cached count, not `repository.editedCount()`: this is a
    /// view body, and it used to run a `SELECT COUNT(*)` every time the column
    /// redrew.
    private func subRowCount(_ scope: LibraryScope) -> String? {
        guard scope == .edited else { return nil }
        let count = env.library.editedCount
        return count > 0 ? "\(count)" : nil
    }

    private func glyph(for destination: Destination) -> BenchNavGlyph.Kind {
        switch destination {
        case .generate: .generate
        case .styleTransfer: .styleTransfer
        case .actions: .actions
        case .workbench: .workbench
        case .editor: .editor
        case .library: .library
        case .models: .models
        }
    }

    private func count(for destination: Destination) -> String? {
        switch destination {
        case .library:
            // How many rows the Library is showing right now — so it tracks
            // the scope switch and any active filter rather than claiming a
            // fixed size the list may not be displaying.
            let total: Int
            switch libraryScope {
            case .parts: total = env.partsStore.results.count
            // All and Favourites are one view over two tables, so the count is
            // both halves. Off the stores' own published results — asking the
            // repository here was a query per render pass.
            case .all, .favourites:
                total = env.library.results.count + env.partsStore.results.count
            case .songs, .imported, .edited:
                total = env.library.results.count
            }
            return total > 0 ? "\(total)" : nil
        case .models:
            let installed = env.catalog.models.filter { $0.installState == .installed }
            guard !env.catalog.models.isEmpty else { return nil }
            return "\(installed.count)/\(env.catalog.models.count)"
        case .workbench:
            let clips = env.workbench.clips.count
            return clips > 0 ? "\(clips)" : nil
        default:
            return nil
        }
    }

    /// A spinner on the destination that owns the running work, so leaving a
    /// screen mid-job does not hide that the job is still going.
    private var styleTransferJobs: Set<String> {
        env.styleTransfer.outstandingJobIds
    }

    private func isBusy(_ destination: Destination) -> Bool {
        switch destination {
        case .generate, .actions:
            // One rule for both rows, so a job can only ever spin one of them
            // and neither can be reached by a predicate that forgot the other.
            // Minus the two destinations that own their own work: Style
            // Transfer reports the ids it started, and an Editor render is a
            // `mix` job that belongs to the Editor row.
            //
            // Over `busy` rather than `active.values`: the answer only depends
            // on which jobs are unfinished and what task each is, and reading
            // the rows themselves subscribed this whole window to every
            // progress tick they emit.
            return env.jobsStore.busy.contains {
                Destination.busyOwner(task: $0.task) == destination
                    && !styleTransferJobs.contains($0.id)
                    && !env.jobsStore.isEditorJob($0.id)
            }
        case .styleTransfer:
            // Style Transfer's jobs are ordinary generate/separate/mix jobs, so
            // neither arm above can tell them apart by shape — the workspace
            // reports the ids it started instead, and the other two subtract
            // them so one job never spins two destinations.
            return env.styleTransfer.isWaitingOnWork
        case .models:
            return env.downloadsStore.transfers.active > 0
        case .editor:
            return env.editor.applyStage.isBusy
        default:
            return false
        }
    }
}
