// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What the rail's search field puts in the content column.
///
/// The window holds forty-odd preferences across eight sections, and the two
/// questions people actually arrive with — "where is the Dock bounce one" and
/// "is there a setting for X at all" — are both answerable only by opening
/// every section in turn. So results name their section: finding the setting
/// and learning where it lives are the same act, and the next time you go
/// straight there.
struct SettingsSearchResults: View {
    let query: String
    let onPick: (SettingEntry) -> Void

    private var matches: [SettingEntry] { SettingsCatalog.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if matches.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(SettingsPane.allCases) { pane in
                            let inPane = matches.filter { $0.pane == pane }
                            if !inPane.isEmpty {
                                SettingsGroup(pane.title.uppercased()) {
                                    ForEach(Array(inPane.enumerated()),
                                            id: \.element.id) { index, entry in
                                        if index > 0 { SettingsDivider() }
                                        row(entry)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 24).padding(.bottom, 28)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Search")
                .font(Bench.Typo.sectionTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text(matches.isEmpty
                 ? "NO MATCHES"
                 : "\(matches.count) MATCH\(matches.count == 1 ? "" : "ES")")
                .font(Bench.Typo.badge)
                .foregroundStyle(Bench.Palette.textFaintest)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 24)
        .frame(height: Bench.Metrics.topBarHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("Nothing matches \u{201C}\(query)\u{201D}")
                .font(Bench.Typo.body)
                .foregroundStyle(Bench.Palette.textSecondary)
            Text("Sections are searched too, so the name of one — "
                 + "\u{201C}engine\u{201D}, \u{201C}library\u{201D} — finds "
                 + "everything in it.")
                .font(Bench.Typo.caption)
                .foregroundStyle(Bench.Palette.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ entry: SettingEntry) -> some View {
        Button {
            onPick(entry)
        } label: {
            HStack(spacing: 12) {
                BenchNavGlyph(kind: entry.pane.glyph,
                              color: Bench.Palette.textMuted)
                Text(entry.title)
                    .font(Bench.Typo.body)
                    .foregroundStyle(Bench.Palette.textPrimary)
                Spacer(minLength: 8)
                Text("GO \u{2192}")
                    .font(Bench.Typo.badge)
                    .foregroundStyle(Bench.Palette.accent)
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
    }
}
