// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The model list behind Studio's `⌄ ACE-Step 1.5` heading.
///
/// A system `Menu` cannot be themed — it draws AppKit's own list, in AppKit's
/// colours, with one line per item — so this is a plain popover panel built out
/// of the same pieces as the rest of the app. Two lines per model, because a
/// bare name is not enough to choose between forty of them: the first line says
/// what it is and what it can do, the second says what it is for.
struct ModelChooser: View {
    struct Entry: Identifiable, Equatable {
        let id: String
        let name: String
        let description: String
        /// Searched but not drawn — "acestep" finds the ACE-Step models even
        /// though no row says that word, which is how the Models screen
        /// already behaves.
        var family: String = ""
        var isFavourite: Bool = false
        let badges: [ModelBadges.Badge]
    }

    /// Favourites first, each group keeping the order it arrived in.
    ///
    /// A stable partition rather than a sort: a model that is neither
    /// favourited nor searched for stays exactly where the catalog put it, and
    /// two favourites keep their relative order instead of being shuffled by
    /// whatever `sorted` decides about equal keys.
    static func ordered(_ entries: [Entry]) -> [Entry] {
        entries.filter(\.isFavourite) + entries.filter { !$0.isFavourite }
    }

    /// Which entries a query lets through. Static and pure so the matching is
    /// testable without a popover, a catalog or a window.
    static func filter(_ entries: [Entry], query: String) -> [Entry] {
        entries.filter {
            ModelSearch.matches(query: query,
                                in: [$0.name, $0.description, $0.family])
        }
    }

    let entries: [Entry]
    let selectedId: String?
    let onPick: (String) -> Void
    let onManage: () -> Void
    var onToggleFavourite: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var hovered: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The order and grouping this showing uses, captured when the popover
    /// opens and then held.
    ///
    /// Hearting a model from this list must NOT re-sort it under the pointer.
    /// A row that leaps to the top the moment you click its heart drags the
    /// row below it under your cursor, and the next click lands on the wrong
    /// model — a misclick the feature would have created. The heart fills in
    /// at once, which is the feedback; the new order is what you get the next
    /// time you open the list.
    @State private var favouritesAtOpen: Set<String> = []
    @State private var rank: [String: Int] = [:]

    /// What the list draws: filtered by the query, in this showing's order.
    private var visible: [Entry] {
        Self.filter(entries, query: query)
            .sorted { rank[$0.id, default: .max] < rank[$1.id, default: .max] }
    }

    /// Headers earn their place only when the list actually has two groups in
    /// it. A search that returns favourites alone gets no headings.
    private var showsGroupHeadings: Bool {
        let ids = visible.map(\.id)
        return ids.contains(where: favouritesAtOpen.contains)
            && ids.contains(where: { !favouritesAtOpen.contains($0) })
    }

    private func capture() {
        favouritesAtOpen = Set(entries.filter(\.isFavourite).map(\.id))
        rank = Dictionary(uniqueKeysWithValues:
            Self.ordered(entries).enumerated().map { ($0.element.id, $0.offset) })
    }

    var body: some View {
        VStack(spacing: 0) {
            search
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if visible.isEmpty { noMatches } else {
                            ForEach(Array(visible.enumerated()), id: \.element.id) {
                                index, entry in
                                if showsGroupHeadings, let heading = heading(at: index) {
                                    Text(heading).eyebrow()
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.top, index == 0 ? 4 : 12)
                                        .padding(.bottom, 2)
                                }
                                row(entry).id(entry.id)
                            }
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    capture()
                    // Open on the model you are using, not at the top of a
                    // list that may be forty long.
                    if let selectedId { proxy.scrollTo(selectedId, anchor: .center) }
                }
                .onChange(of: query) {
                    // Results start at the top. Without this the list keeps the
                    // offset it had for the previous query, which on a short
                    // result set can leave it scrolled past everything.
                    if let first = visible.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
            .frame(maxHeight: 420)

            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            Button {
                dismiss()
                onManage()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11))
                    Text("Manage models…")
                        .font(Bench.Typo.secondary)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Bench.Palette.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 460)
        .background(Bench.Palette.panel)
    }

    private var search: some View {
        BenchSearchField(text: $query, placeholder: "Search models", width: nil)
            .focused($searchFocused)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            // Enter takes the top result, so a query narrow enough to leave one
            // model can be finished without reaching for the mouse.
            .onSubmit {
                guard let first = visible.first else { return }
                onPick(first.id)
                dismiss()
            }
            .onAppear {
                // Next turn, not this one: a popover's first responder is not
                // settled at `onAppear`, and focus set here is dropped.
                Task { @MainActor in searchFocused = true }
            }
    }

    /// "FAVOURITES" above the first row, "ALL MODELS" above the first row that
    /// is not one — nil everywhere else.
    private func heading(at index: Int) -> String? {
        let isFavourite = favouritesAtOpen.contains(visible[index].id)
        if index == 0 { return isFavourite ? "FAVOURITES" : "ALL MODELS" }
        let previous = favouritesAtOpen.contains(visible[index - 1].id)
        guard previous, !isFavourite else { return nil }
        return "ALL MODELS"
    }

    private var noMatches: some View {
        Text("No model matches “\(query.trimmingCharacters(in: .whitespaces))”.")
            .font(Bench.Typo.secondary)
            .foregroundStyle(Bench.Palette.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 16)
    }

    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.id == selectedId
        let isHovered = hovered == entry.id
        // The heart is a SIBLING of the picking button, not nested inside it: a
        // button within a button gives one click two meanings, and the meaning
        // it picks is the one that closes the popover on the model you were
        // only trying to heart.
        return HStack(alignment: .top, spacing: 6) {
            Button {
                onPick(entry.id)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    // Name and labels share a line and wrap together: a model
                    // with a RAM warning and a licence note would otherwise
                    // push the name off the panel.
                    FlowLayout(spacing: 6, rowSpacing: 5) {
                        Text(entry.name)
                            .font(Bench.Typo.bodyEmphasis)
                            .foregroundStyle(isSelected ? Bench.Palette.accent
                                                        : Bench.Palette.textPrimary)
                        ForEach(entry.badges) { badge in
                            BenchBadge(badge.text, tone: badge.tone)
                        }
                    }
                    if !entry.description.isEmpty {
                        Text(entry.description)
                            .font(Bench.Typo.secondary)
                            .foregroundStyle(Bench.Palette.textMuted)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            heart(entry, isHovered: isHovered)
            // Reserved rather than conditional: a checkmark that only takes
            // width on the selected row would shift that row's heart out of
            // line with every other one.
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Bench.Palette.accent)
                .opacity(isSelected ? 1 : 0)
                .padding(.top, 2)
                .accessibilityHidden(!isSelected)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(isSelected ? Bench.Palette.accent.opacity(0.10)
                             : (isHovered ? Bench.Palette.raised : .clear)))
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
    }

    /// Pink when hearted, a faint outline on hover, and nothing at all
    /// otherwise — forty always-on hearts would read as decoration rather than
    /// a control, and the ones that matter would stop standing out.
    private func heart(_ entry: Entry, isHovered: Bool) -> some View {
        Button {
            onToggleFavourite(entry.id)
        } label: {
            Image(systemName: entry.isFavourite ? "heart.fill" : "heart")
                .font(.system(size: 11))
                .foregroundStyle(entry.isFavourite ? TrackRow.favouriteHeart
                                                   : Bench.Palette.textFaint)
                .opacity(entry.isFavourite || isHovered ? 1 : 0)
                .padding(.top, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(entry.isFavourite ? "Remove from favourite models"
                                : "Show this model first in the picker")
        .accessibilityHidden(!entry.isFavourite && !isHovered)
    }
}
