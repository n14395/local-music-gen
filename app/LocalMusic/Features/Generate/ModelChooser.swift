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
        let badges: [ModelBadges.Badge]
    }

    let entries: [Entry]
    let selectedId: String?
    let onPick: (String) -> Void
    let onManage: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hovered: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries) { entry in
                            row(entry).id(entry.id)
                        }
                    }
                    .padding(6)
                }
                .onAppear {
                    // Open on the model you are using, not at the top of a
                    // list that may be forty long.
                    if let selectedId { proxy.scrollTo(selectedId, anchor: .center) }
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

    private func row(_ entry: Entry) -> some View {
        let isSelected = entry.id == selectedId
        let isHovered = hovered == entry.id
        return Button {
            onPick(entry.id)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 10) {
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
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Bench.Palette.accent)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(isSelected ? Bench.Palette.accent.opacity(0.10)
                                 : (isHovered ? Bench.Palette.raised : .clear)))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? entry.id : (hovered == entry.id ? nil : hovered) }
    }
}
