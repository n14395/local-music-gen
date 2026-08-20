import SwiftUI
import UniformTypeIdentifiers

/// The gallery: one shelf per category, four cards across, every card stating
/// its mode before you click it.
///
/// The old screen nested Split / Parts / Recombine / Recipes / Workbench inside
/// each other, which meant separating stems was a *place* and mashing two songs
/// was a different *place*. Here they are the same kind of thing — an action
/// with a source, a model and an output — and the only navigation is "pick one".
struct ActionGallery: View {
    let recipes: [Recipe]
    /// Precomputed by `ActionsScreen`, which owns the model-availability rules.
    let states: [String: ActionsScreen.CardState]
    let recent: [Recipe]
    @Binding var query: String
    @Binding var category: RecipeCategory?
    @Binding var onlyRunnable: Bool
    let onOpen: (Recipe) -> Void
    let onDropAudio: ([URL]) -> Void
    /// Only the empty state uses it, and only because the one way out of an
    /// empty gallery is to install something.
    let onOpenModels: () -> Void

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            filterBar
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleCategories) { section in
                        Text(section.sectionTitle).eyebrow()
                            .padding(.top, section == visibleCategories.first
                                     ? 0 : 4)
                        grid(for: section)
                    }
                    if visibleCategories.isEmpty {
                        emptyState
                    }
                }
                .padding(.horizontal, 20).padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: empty

    /// An empty gallery has three different causes and only one of them is a
    /// failed search. Ticking "Only what my installed models can do" on a fresh
    /// install empties the shelves while the search box is still empty, and
    /// `No action matches ""` is both untrue and a dead end — the only fix for
    /// that state lives in Models, so the state says so and offers the route.
    @ViewBuilder
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !query.isEmpty {
                Text("No action matches “\(query)”.")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textFaint)
            } else if onlyRunnable {
                Text("No installed model can run anything yet.")
                    .font(Bench.Typo.sectionTitle)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("Every action is still here. Untick “Only what my "
                     + "installed models can do” to see them all — each card "
                     + "says what it needs — or install a model and they "
                     + "un-grey themselves.")
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430, alignment: .leading)
                Button("Open Models", action: onOpenModels)
                    .buttonStyle(.bench(.accent))
                    .padding(.top, 2)
            } else {
                Text("Nothing in this category yet.")
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textFaint)
            }
        }
        .padding(.top, 40)
    }

    // MARK: bars

    private var topBar: some View {
        BenchTopBar {
            HStack(spacing: 14) {
                Text("Actions")
                    .font(Bench.Typo.screenTitle)
                    .tracking(-0.15)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Text("\(recipes.count)")
                    .font(Bench.Typo.counter)
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
        } trailing: {
            HStack(spacing: 9) {
                BenchSearchField(text: $query,
                                 placeholder: "What do you want to do?")
                BenchMenu(label: "Recently used") {
                    if recent.isEmpty {
                        Text("Nothing yet")
                    } else {
                        ForEach(recent) { recipe in
                            Button(recipe.name) { onOpen(recipe) }
                        }
                    }
                }
            }
        }
    }

    private var filterBar: some View {
        BenchFilterBar {
            BenchFilterChip(label: "All", count: matchingSearch.count,
                            isSelected: category == nil) { category = nil }
            ForEach(RecipeCategory.allCases) { candidate in
                BenchFilterChip(label: candidate.title,
                                count: count(of: candidate),
                                isSelected: category == candidate) {
                    category = category == candidate ? nil : candidate
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: $onlyRunnable) {
                Text("Only what my installed models can do")
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(onlyRunnable ? Bench.Palette.textSecondary
                                                  : Bench.Palette.textQuaternary)
            }
            .toggleStyle(.bench(width: 32))
        }
    }

    // MARK: grid

    private func grid(for section: RecipeCategory) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                 count: 4),
                  alignment: .leading, spacing: 10) {
            ForEach(visible(in: section)) { recipe in
                ActionCard(recipe: recipe,
                           state: states[recipe.id] ?? .active,
                           isRecommended: recipe.id == recommendedId) {
                    onOpen(recipe)
                }
            }
            // The drop tile ends the first shelf, where "I have a file, now
            // what?" is the question actually being asked.
            if section == visibleCategories.first {
                BenchDropTarget(
                    title: "Drop audio here",
                    subtitle: "Or pick from Library · any action accepts a file",
                    isTargeted: isTargeted)
                    .frame(minHeight: 118)
                    .dropDestination(for: URL.self) { urls, _ in
                        let audio = AudioDrop.audioFiles(in: urls)
                        guard !audio.isEmpty else { return false }
                        onDropAudio(audio)
                        return true
                    } isTargeted: { isTargeted = $0 }
            }
        }
    }

    // MARK: filtering

    private var matchingSearch: [Recipe] {
        recipes.filter { recipe in
            guard onlyRunnable ? isRunnable(recipe) : true else { return false }
            guard !query.isEmpty else { return true }
            return recipe.name.localizedCaseInsensitiveContains(query)
                || recipe.tagline.localizedCaseInsensitiveContains(query)
        }
    }

    private func isRunnable(_ recipe: Recipe) -> Bool {
        if case .active = states[recipe.id] ?? .active { return true }
        return false
    }

    private func count(of section: RecipeCategory) -> Int {
        matchingSearch.filter { $0.category == section }.count
    }

    private func visible(in section: RecipeCategory) -> [Recipe] {
        matchingSearch.filter { $0.category == section }
    }

    private var visibleCategories: [RecipeCategory] {
        RecipeCategory.allCases.filter { section in
            guard category == nil || category == section else { return false }
            return !visible(in: section).isEmpty
        }
    }

    /// The design accent-strokes one card as "start here". It is the first card
    /// of the first shelf — separating a song is what every other exact recipe
    /// wants as material.
    private var recommendedId: String? {
        visibleCategories.first.flatMap { visible(in: $0).first?.id }
    }
}

// MARK: - Card

private struct ActionCard: View {
    let recipe: Recipe
    let state: ActionsScreen.CardState
    let isRecommended: Bool
    let action: () -> Void

    private var isComingSoon: Bool {
        if case .comingSoon = state { return true }
        return false
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: recipe.icon)
                        .font(.system(size: 14))
                        .foregroundStyle(recipe.mode.color)
                        .frame(height: 14)
                    Spacer(minLength: 4)
                    ActionModeBadge(mode: recipe.mode)
                }
                Text(recipe.name)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(recipe.tagline)
                    .font(Bench.Typo.small)
                    .foregroundStyle(Bench.Palette.textQuaternary)
                    .lineSpacing(2.5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let footnote = state.footnote {
                    Text(footnote)
                        .font(Bench.Typo.micro)
                        .foregroundStyle(Bench.Palette.warn)
                        .padding(.horizontal, 7).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5,
                                                     style: .continuous)
                            .fill(Bench.Palette.warn.opacity(0.10)))
                        .overlay(RoundedRectangle(cornerRadius: 5,
                                                  style: .continuous)
                            .strokeBorder(Bench.Palette.warn.opacity(0.2),
                                          lineWidth: 1))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
            .benchCard(stroke: isRecommended
                       ? Bench.Palette.accent.opacity(0.3)
                       : Bench.Palette.cardStrokeSoft)
            // Transparent padding takes no hits in SwiftUI: without this only
            // the glyph and the text are clickable.
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.card,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        // Gated cards stay ENABLED on purpose — clicking one is how you get to
        // the model it needs. Only "coming soon" is genuinely inert.
        .disabled(isComingSoon)
        .opacity(isComingSoon ? 0.45 : 1)
        .help(isComingSoon ? "Coming in a later update" : recipe.tagline)
    }
}
