// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

// The Settings window's chrome, wearing the main window's own.
//
// The redesign's argument is that a preferences window drawn in system parts —
// a second title band, a blue focus ring, an ungrouped list — reads as a
// different application bolted onto this one. So the rail here is built from
// `BenchSidebarRow`/`BenchSidebarHeading`/`BenchSidebarCard`, the same three
// components the main sidebar is built from, and the traffic lights sit over
// the rail's reserved 52 pt header exactly as they do there.

// MARK: - Rail

struct SettingsRail: View {
    let env: AppEnvironment
    @Binding var pane: SettingsPane
    @Binding var query: String
    var searchFocus: FocusState<Bool>.Binding
    /// Songs in the library, counted by the window rather than by the rail —
    /// it is a database read, and the rail is rebuilt on every keystroke in
    /// the search field.
    var songCount: Int

    var body: some View {
        VStack(spacing: 0) {
            // Reserved for the traffic lights, which the system draws over the
            // top-left of the window's content.
            Color.clear.frame(height: Bench.Metrics.topBarHeight)

            SettingsSearchField(query: $query, focus: searchFocus)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            VStack(spacing: 2) {
                ForEach(SettingsPane.Group.allCases, id: \.self) { group in
                    BenchSidebarHeading(
                        text: group.rawValue,
                        topPadding: group == .app ? 4 : 18)
                    ForEach(group.panes) { candidate in
                        BenchSidebarRow(destination: candidate,
                                        title: candidate.title,
                                        glyph: candidate.glyph,
                                        count: count(for: candidate),
                                        selection: $pane)
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 0)
            SettingsFooterCard(env: env)
        }
        .frame(width: Bench.Metrics.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
        }
    }

    /// The two counts the main rail also carries: how much is in the library,
    /// and how much of the catalog is on this Mac. Queue deliberately has
    /// none — a number that changes while you are reading a settings page is
    /// a distraction from the page.
    private func count(for pane: SettingsPane) -> String? {
        switch pane {
        case .library:
            return songCount > 0 ? "\(songCount)" : nil
        case .models:
            let models = env.catalog.models.filter { $0.id != "test-tiny" }
            guard !models.isEmpty else { return nil }
            let installed = models.count { $0.installState == .installed }
            return "\(installed)/\(models.count)"
        default:
            return nil
        }
    }
}

// MARK: - Search field

struct SettingsSearchField: View {
    @Binding var query: String
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Bench.Palette.textMuted)
            TextField("Search settings", text: $query)
                .textFieldStyle(.plain)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
                .tint(Bench.Palette.accent)
                .focused(focus)
                .onExitCommand { query = ""; focus.wrappedValue = false }
            if query.isEmpty {
                Text("\u{2318}F")
                    .font(Bench.Typo.mono(10))
                    .foregroundStyle(Bench.Palette.textDimmest)
            } else {
                Button {
                    query = ""
                    focus.wrappedValue = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(Bench.Palette.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            // Lime rather than the system tint, at the same weight the rail's
            // selected row uses. The macOS focus ring was the single loudest
            // non-native thing in the old window.
            .strokeBorder(focus.wrappedValue ? Bench.Palette.accent.opacity(0.4)
                                             : Bench.Palette.cardStroke,
                          lineWidth: 1))
        .focusEffectDisabled()
    }
}

// MARK: - Rail footer

/// The rail's bottom slot, which the main window never leaves empty either:
/// the render in flight when there is one, otherwise where these settings are
/// being written. Settings has no Save button and never will — saying where
/// the file is does the same job honestly.
struct SettingsFooterCard: View {
    let env: AppEnvironment

    /// The take in flight. `runningJob` is the same answer the store already
    /// keeps for its own shell state — sorting the whole queue here instead
    /// subscribed this card to every row's previews and produced-song lists.
    private var rendering: JobsStore.ActiveJob? { env.jobsStore.runningJob }

    var body: some View {
        BenchSidebarCard(stroke: rendering != nil
                         ? Bench.Palette.accent.opacity(0.2)
                         : Bench.Palette.hairline) {
            if let job = rendering {
                renderingBody(job)
            } else {
                savedBody
            }
        }
    }

    @ViewBuilder
    private func renderingBody(_ job: JobsStore.ActiveJob) -> some View {
        HStack(spacing: 8) {
            StatusDot(color: Bench.Palette.accent)
            Text("Rendering")
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        Text(renderDetail(job))
            .font(Bench.Typo.mono(10))
            .foregroundStyle(Bench.Palette.textMuted)
            .lineLimit(1)
        BenchProgressBar(fraction: job.progress?.fraction ?? 0)
    }

    private func renderDetail(_ job: JobsStore.ActiveJob) -> String {
        var parts: [String] = []
        if let take = job.takeLabel { parts.append(take.uppercased()) }
        if let fraction = job.progress?.fraction {
            parts.append("\(Int((fraction * 100).rounded()))%")
        } else {
            parts.append(job.status.rawValue.uppercased())
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var savedBody: some View {
        HStack(spacing: 8) {
            StatusDot(color: Bench.Palette.textFaintest)
            Text("Saved as you go")
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(Bench.Palette.textPrimary)
            Spacer(minLength: 0)
        }
        Text("Every change here applies immediately, including to work already "
             + "running.")
            .font(Bench.Typo.caption)
            .foregroundStyle(Bench.Palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Content header

/// The 52 pt bar at the top of the content column. It carries the section name
/// — the job the deleted "Settings" band was doing badly, since the window
/// title already said that — plus whatever one-line state the section has, as
/// a chip rather than as a card of its own.
struct SettingsSectionHeader<Chip: View>: View {
    let title: String
    var onReset: (() -> Void)?
    var resetDisabled = false
    @ViewBuilder var chip: () -> Chip

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            chip()
            Spacer(minLength: 8)
            if let onReset {
                Button("Reset this section", action: onReset)
                    .buttonStyle(.bench(.quiet))
                    .disabled(resetDisabled)
                    .opacity(resetDisabled ? 0.45 : 1)
                    .help(resetDisabled
                          ? "Everything in this section is already at its default"
                          : "Put every setting in this section back to its default")
            }
        }
        .padding(.horizontal, 24)
        .frame(height: Bench.Metrics.topBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

extension SettingsSectionHeader where Chip == EmptyView {
    init(title: String, onReset: (() -> Void)? = nil, resetDisabled: Bool = false) {
        self.init(title: title, onReset: onReset,
                  resetDisabled: resetDisabled) { EmptyView() }
    }
}

/// The header's one-line state: `● ALLOWED BY MACOS`.
struct SettingsChip: View {
    let text: String
    var tone: Color = Bench.Palette.ok

    var body: some View {
        HStack(spacing: 7) {
            StatusDot(color: tone, size: 6)
            Text(text)
                .font(Bench.Typo.badge)
                .foregroundStyle(tone)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tone.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(tone.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - Status strip

/// The 44 pt footer. It exists to make the Reset button above it trustworthy:
/// a section that says how many settings it holds and how many you have moved
/// is one you can reset without wondering what you are about to lose.
struct SettingsStatusStrip: View {
    let total: Int
    let changed: Int
    var link: (label: String, action: () -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            Text(summary)
                .font(Bench.Typo.mono(11))
                .foregroundStyle(Bench.Palette.textFaintest)
            Spacer(minLength: 8)
            if let link {
                Button {
                    link.action()
                } label: {
                    Text("\(link.label) \u{2197}")
                        .font(Bench.Typo.secondary)
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Bench.Palette.sidebar)
        .overlay(alignment: .top) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private var summary: String {
        // A section whose controls are locations rather than preferences
        // (Models & Downloads) says so instead of counting to zero.
        guard total > 0 else { return "NOTHING IN THIS SECTION RESETS" }
        let settings = "\(total) SETTING\(total == 1 ? "" : "S") IN THIS SECTION"
        // "ALL AT DEFAULT" rather than "0 CHANGED": the reassuring case should
        // read as a statement, not as an arithmetic result.
        return changed == 0 ? settings + " \u{00B7} ALL AT DEFAULT"
                            : settings + " \u{00B7} \(changed) CHANGED FROM DEFAULT"
    }
}
