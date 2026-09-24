// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Help ▸ Keyboard Shortcuts.
///
/// Declined the first time the menubar was filled out, on the grounds that a
/// second list of every binding is a thing to keep in sync for no gain. That
/// objection is answered rather than overruled: the rows here are
/// `ShortcutCatalog`, which is also where every menu item takes its
/// `KeyboardShortcut` from — so a key that moves in the menus moves here, and
/// a key that is added without being listed is a key that does not exist.
///
/// Two columns of cards rather than one long list: forty-odd bindings in a
/// single column is a scroll, and the point of a reference is to be scanned.
struct KeyboardShortcutsSheet: View {
    let onClose: () -> Void

    private var columns: ([ShortcutSection], [ShortcutSection]) {
        let sections = ShortcutCatalog.sections
        // Split by content rather than in half: Playback alone is fourteen
        // rows, so an even split by *count of sections* would leave one column
        // twice the height of the other.
        var left: [ShortcutSection] = []
        var right: [ShortcutSection] = []
        var leftRows = 0
        var rightRows = 0
        for section in sections {
            if leftRows <= rightRows {
                left.append(section)
                leftRows += section.lines.count + 2
            } else {
                right.append(section)
                rightRows += section.lines.count + 2
            }
        }
        return (left, right)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Bench.Palette.hairline)
            ScrollView {
                HStack(alignment: .top, spacing: 18) {
                    let split = columns
                    column(split.0)
                    column(split.1)
                }
                .padding(20)
            }
            .frame(maxHeight: .infinity)
            Divider().overlay(Bench.Palette.hairline)
            footer
        }
        .frame(width: 720, height: 680)
        .background(Bench.Palette.panel)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keyboard Shortcuts")
                .font(Bench.Typo.inspectorTitle)
                .foregroundStyle(Bench.Palette.textPrimary)
            Text("Every key the menubar installs. Items marked \u{201C}system\u{201D} "
                 + "are macOS's own, and the last card is bound to a screen "
                 + "rather than to a menu.")
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.vertical, 18)
    }

    private func column(_ sections: [ShortcutSection]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(section.title.uppercased()).eyebrow()
                    VStack(spacing: 0) {
                        ForEach(Array(section.lines.enumerated()),
                                id: \.element.id) { index, line in
                            row(line)
                            if index < section.lines.count - 1 {
                                Rectangle().fill(Bench.Palette.hairline)
                                    .frame(height: 1)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 10,
                                                 style: .continuous)
                        .fill(Bench.Palette.card))
                    .overlay(RoundedRectangle(cornerRadius: 10,
                                              style: .continuous)
                        .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ line: ShortcutLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = line.note {
                    Text(note.uppercased())
                        .font(Bench.Typo.mono(9))
                        .foregroundStyle(Bench.Palette.textFaintest)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(line.keys)
                .font(Bench.Typo.mono(12, .semibold))
                .foregroundStyle(Bench.Palette.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5,
                                             style: .continuous)
                    .fill(Bench.Palette.raised))
                .fixedSize()
        }
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Done", action: onClose)
                .buttonStyle(.benchPrimaryCompact)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
