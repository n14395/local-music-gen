import SwiftUI

// The content column's building blocks.
//
// Two rules from the redesign, and both are about the left edge:
//
//   * The group label lifts out of the card. A card whose first line is
//     `DELIVERY` and whose second is its only row was mostly label; above the
//     card, in the app's mono style, the label costs a line and orders the
//     page instead of padding it.
//   * The control moves to the right. With switches on the left, every title
//     and description started at a different x than the section label above
//     them, so nothing in the column shared an edge. Right-aligned in one
//     column, the text block reads as a single measure — and rows can then be
//     separated by hairlines rather than by gaps, which is what lets one card
//     hold six of them without becoming a list of boxes.

/// `DELIVERY` over a card. The label is a sibling of the card, not its first
/// child.
struct SettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .eyebrow()
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .benchCard()
        }
    }
}

/// The hairline between two rows of one card. Inset from the card's edge so it
/// separates the rows rather than cutting the card in half.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Bench.Palette.hairline)
            .frame(height: 1)
            .padding(.horizontal, 18)
    }
}

/// Title and description on the left, one control on the right.
///
/// The control column is fixed rather than sized to its contents: a card whose
/// switches, menus and steppers all ended at a different x is the thing the
/// right-hand column was introduced to fix, and letting each row size itself
/// would quietly reintroduce it.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    /// Cross-axis alignment for the control. Switches and menus sit against
    /// the title's own line; a slider that owns the row's full width doesn't.
    var alignment: VerticalAlignment = .top
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: alignment, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Bench.Typo.caption)
                        .lineSpacing(2)
                        .foregroundStyle(Bench.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .fixedSize()
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Control == EmptyView {
    /// A row that is all text — a note inside a card, or a control that has to
    /// draw across the full width and supplies its own row below.
    init(title: String, detail: String? = nil) {
        self.init(title: title, detail: detail) { EmptyView() }
    }
}

/// The common case: a row whose control is a switch.
struct SettingsToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.bench)
                // The label is the row's own title, several points to the
                // left; VoiceOver would otherwise announce an unnamed switch.
                .accessibilityLabel(title)
        }
    }
}

/// A row whose control needs the width — a slider with its value box, a
/// picker over a long list. The title column keeps its measure and the control
/// runs beneath the description rather than beside it.
struct SettingsWideRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Bench.Typo.bodyEmphasis)
                    .foregroundStyle(Bench.Palette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Bench.Typo.caption)
                        .lineSpacing(2)
                        .foregroundStyle(Bench.Palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            control()
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of buttons inside a card — "Show welcome tour again", the reset
/// actions. Not a setting, so it carries no title column.
struct SettingsActionRow<Content: View>: View {
    var detail: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) { content() }
            if let detail {
                Text(detail)
                    .font(Bench.Typo.caption)
                    .foregroundStyle(Bench.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
