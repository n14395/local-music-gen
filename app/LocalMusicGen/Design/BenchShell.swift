// Copyright 2026 Nick Fay
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// The window chrome: a 230 pt sidebar, a 52 pt top bar per screen, and a
// contextual card pinned to the bottom of the sidebar. The card is the part
// worth understanding — it is not decoration. Each destination puts the thing
// you need *while you are there* in the same physical spot: the engine while
// you generate, the legend while you browse actions, the parts drawer while
// you build a mix, storage while you manage models — with the engine's own
// readout stacked underneath, on every screen.

// MARK: - Nav glyphs

/// The sidebar's glyphs, drawn rather than borrowed from SF Symbols.
/// They are built from the same primitives as the rest of the design — bars,
/// squares, rules — so the nav reads as part of the app and not as a toolbar.
struct BenchNavGlyph: View {
    let kind: Kind
    var color: Color
    var size: CGFloat = 13

    enum Kind {
        case generate, styleTransfer, actions, workbench, editor, library, models
        // Settings' own rail. Drawn here rather than in the Settings feature
        // so both rails keep one glyph vocabulary — that shared set is most of
        // what makes the Settings window read as the same app.
        case info, bell, ring, engine
    }

    var body: some View {
        Group {
            switch kind {
            case .generate: bars(heights: [6, 13, 9], width: 2, spacing: 2)
            case .styleTransfer: transfer
            case .actions: grid
            case .workbench: rules(heights: [3, 3, 3], widths: [1, 0.69, 1], spacing: 2)
            case .editor: waveform
            case .library: rules(heights: [2, 2, 2, 2], widths: [1, 1, 1, 0.62],
                                 spacing: 2.5)
            case .models: chip
            case .info: info
            case .bell: bell
            case .ring: ring
            case .engine: centredChip
            }
        }
        .frame(width: size, height: size)
    }

    private func bars(heights: [CGFloat], width: CGFloat, spacing: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: width, height: height * size / 13)
            }
        }
        .frame(width: size, height: size, alignment: .bottom)
    }

    /// One wave and the same wave inverted — 180° apart, drawn as a pair
    /// above and below the centre line rather than through it. Two mirrored
    /// sines sharing one axis cross at every node, and at 13 pt that reads as
    /// a knot; held apart they read as what they are. Style Transfer keeps the
    /// music and changes its voice, and an inverted copy of a wave is exactly
    /// that: the same shape, answered. The lower one is quieter because it is
    /// the answer, not a second voice of equal standing.
    private var transfer: some View {
        ZStack {
            Self.upperWave.stroke(color, style: Self.waveStroke)
            Self.lowerWave.stroke(color.opacity(0.55), style: Self.waveStroke)
        }
        .frame(width: size, height: size)
    }

    /// The two waves the glyph is made of, named rather than built inline so
    /// that what a test measures is what the sidebar draws.
    static let upperWave = Sine(phase: 0, offset: -waveOffset)
    static let lowerWave = Sine(phase: .pi, offset: waveOffset)

    static let waveWidth: CGFloat = 1.3
    /// Distance from the centre line to each wave's own axis, and the height
    /// of its crests, both as a fraction of the glyph box. Together they leave
    /// a clear gap down the middle: 0.245 ± 0.13 keeps each wave inside its
    /// half with room to spare. Shallow on purpose — at 13 pt a taller crest
    /// stops reading as a wave and starts reading as a zigzag.
    static let waveOffset: CGFloat = 0.245
    static let waveAmplitude: CGFloat = 0.13
    private static let waveStroke = StrokeStyle(lineWidth: waveWidth, lineCap: .round)

    /// A sine across the whole box, sampled rather than fitted with Béziers:
    /// at this size the two are indistinguishable, and sampling keeps the
    /// period and the amplitude legible as numbers instead of as control
    /// points. Not private, so the pair's symmetry can be measured rather than
    /// eyeballed.
    struct Sine: Shape {
        /// Radians. The pair is drawn at 0 and `.pi`, and `.pi` is the same
        /// wave inverted — sin(x + π) == -sin(x) — which is the whole point of
        /// the glyph, so it has to stay exact.
        var phase: CGFloat
        /// Where this wave's own centre line sits, as a fraction of the box
        /// height either side of the middle.
        var offset: CGFloat
        /// Three half periods, as in the reference artwork: enough to read as
        /// a wave, few enough that the crests survive being points apart.
        var halfPeriods: CGFloat = 3

        func path(in rect: CGRect) -> Path {
            // Inset by half the stroke so the round caps stay inside the box
            // rather than crowding the label beside it.
            let box = rect.insetBy(dx: BenchNavGlyph.waveWidth / 2,
                                   dy: BenchNavGlyph.waveWidth / 2)
            let amplitude = box.height * BenchNavGlyph.waveAmplitude
            let axis = box.midY + offset * box.height
            var path = Path()
            for step in 0...48 {
                let t = CGFloat(step) / 48
                let point = CGPoint(
                    x: box.minX + t * box.width,
                    y: axis - sin(t * halfPeriods * .pi + phase) * amplitude)
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    /// The Editor's mark: the app icon's punch-out waveform without its
    /// circle — six capsules centred on one axis. Studio's bars stand on a
    /// baseline and climb; a waveform is symmetric about its middle, and that
    /// difference is what tells the two apart at 13 pt.
    private var waveform: some View {
        let bar = size * 1.5 / 13          // 6 bars + 5 gaps fill the box
        return HStack(spacing: size * 0.8 / 13) {
            ForEach(Array(Self.waveformBars.enumerated()), id: \.offset) { _, height in
                Capsule()
                    .fill(color)
                    .frame(width: bar, height: max(bar, size * height))
            }
        }
        .frame(width: size, height: size)
    }

    /// Bar heights as a fraction of the box, in the icon's own proportions
    /// (icons-ideas/icon-punchout.svg), with the tallest filling the glyph.
    static let waveformBars: [CGFloat] = {
        let source: [CGFloat] = [174.55, 337.45, 500.36, 256, 395.64, 128]
        let tallest = source.max() ?? 1
        return source.map { $0 / tallest }
    }()

    private var grid: some View {
        VStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 2) {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1).fill(color)
                    }
                }
            }
        }
    }

    private func rules(heights: [CGFloat], widths: [CGFloat],
                       spacing: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: size * widths[index], height: height * size / 13)
            }
        }
        .frame(width: size, height: size, alignment: .center)
    }

    /// General: the ⓘ, built from a ring and two stacked marks rather than
    /// set in a font, so it keeps the 1.5 pt stroke every other glyph uses.
    private var info: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .overlay(alignment: .top) {
                VStack(spacing: size * 1.5 / 13) {
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(color)
                        .frame(width: 1.5, height: size * 1.5 / 13)
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(color)
                        .frame(width: 1.5, height: size * 4 / 13)
                }
                .padding(.top, size * 2 / 13)
            }
    }

    /// Notifications: a bell as a dome over a clapper — two shapes, no outline
    /// tracing, so it survives being 13 pt beside a word.
    private var bell: some View {
        ZStack(alignment: .bottom) {
            UnevenRoundedRectangle(
                topLeadingRadius: size * 5 / 13,
                bottomLeadingRadius: size * 1.5 / 13,
                bottomTrailingRadius: size * 1.5 / 13,
                topTrailingRadius: size * 5 / 13, style: .continuous)
                .strokeBorder(color, lineWidth: 1.5)
                .frame(width: size * 10 / 13, height: size * 9 / 13)
                .frame(maxHeight: .infinity, alignment: .top)
            UnevenRoundedRectangle(
                bottomLeadingRadius: size / 13,
                bottomTrailingRadius: size / 13, style: .continuous)
                .fill(color)
                .frame(width: size * 4 / 13, height: size * 2.5 / 13)
        }
        .frame(width: size, height: size)
    }

    /// Audio & Output: a plain ring — the output stage, and the only glyph in
    /// the set that is a single unbroken shape.
    private var ring: some View {
        Circle()
            .strokeBorder(color, lineWidth: 1.5)
            .frame(width: size * 9 / 13, height: size * 9 / 13)
            .frame(width: size, height: size)
    }

    /// Engine: the models chip with its die centred. Deliberately a near-twin
    /// of `chip` — one is the weights, the other is the thing that runs them,
    /// and the pair reads as related at a glance.
    private var centredChip: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(color, lineWidth: 1.5)
            .overlay {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: size * 5 / 13, height: size * 5 / 13)
            }
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 3)
            .strokeBorder(color, lineWidth: 1.5)
            .overlay(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(color)
                    .frame(width: size * 5 / 13, height: size * 5 / 13)
                    .offset(x: size * 3 / 13, y: size * 2 / 13)
            }
    }
}

// MARK: - Sidebar

struct BenchSidebarRow<Destination: Hashable>: View {
    let destination: Destination
    let title: String
    let glyph: BenchNavGlyph.Kind
    var count: String?
    /// A job or download running behind this destination shows a spinner here,
    /// so you can leave Studio mid-render and still see it is going.
    var isBusy = false
    @Binding var selection: Destination

    private var isSelected: Bool { destination == selection }

    var body: some View {
        Button {
            selection = destination
        } label: {
            HStack(spacing: 11) {
                BenchNavGlyph(kind: glyph,
                              color: isSelected ? Bench.Palette.accent
                                                : Bench.Palette.textMuted)
                Text(title)
                    .font(isSelected ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                    .foregroundStyle(isSelected ? Bench.Palette.accent
                                                : Bench.Palette.textSecondary)
                    // A destination is one line by definition. Without this
                    // the longest of them ("Models & Downloads", in Settings'
                    // rail) wraps as soon as it has a count beside it, and a
                    // two-line row in a column of one-line rows reads as a
                    // different kind of thing.
                    .lineLimit(1)
                    // The longest destination ("Models & Downloads", with a
                    // count beside it) overruns 230 pt by a hair. A hair of
                    // shrink keeps the words; truncating them to
                    // "Models & Downlo…" does not.
                    .minimumScaleFactor(0.88)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                if isBusy {
                    BenchSpinner(size: 14)
                } else if let count {
                    Text(count)
                        .font(Bench.Typo.counter)
                        .foregroundStyle(isSelected ? Bench.Palette.accent
                                                    : Bench.Palette.textFaintest)
                        // `0/7` is three glyphs and a slash, and the slash is
                        // a break opportunity: given a narrow column it wraps
                        // to three stacked lines rather than shrinking the
                        // title beside it.
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(isSelected ? Bench.Palette.accent.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(isSelected ? Bench.Palette.accent.opacity(0.24) : .clear,
                              lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        // These rows say what is selected in the accent, and the system's
        // focus ring says what the keyboard is on — two different rows, two
        // different colours, and the ring stays put when you click elsewhere
        // because clicking does not move focus. One row ringed blue while
        // another is lit in lime reads as a bug however you explain it, so the
        // accent is the only selection signal here.
        .focusEffectDisabled()
    }
}

/// A row nested under a sidebar destination — the Library's scopes.
/// Quieter than `BenchSidebarRow` on purpose: these
/// switch a scope *within* the screen you are already on, so the selected one
/// reads as a raised surface rather than taking the accent, which stays with
/// the destination above it.
struct BenchSidebarSubRow<Scope: Hashable>: View {
    let scope: Scope
    let title: String
    /// Drawn to the left of the title, like the glyph on the destination rows
    /// above — and dimmer than the word for the same reason: the label is what
    /// you read, the mark is what you find it by. Required rather than
    /// optional because these rows are scanned as a column: one row without a
    /// mark either loses its title's left edge or holds an empty box.
    let symbol: String
    /// Whether any row in this group is drawn as chosen. The group stays on
    /// screen from every destination, but "selected" means *this is what you
    /// are looking at* — which is only true on the screen the scopes belong to.
    var showsSelection = true
    /// A trailing count, for a scope whose size is the point of it. Optional
    /// because most scopes are read by name alone.
    var count: String?
    @Binding var selection: Scope

    private var isSelected: Bool { showsSelection && scope == selection }

    /// The symbols are different widths by nature — a music note is barely half
    /// the width of a split rectangle — so they are drawn in a fixed column and
    /// the titles share one left edge regardless of which mark is beside them.
    static var symbolColumn: CGFloat { 15 }

    var body: some View {
        Button {
            selection = scope
        } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Bench.Palette.textPrimary
                                                : Bench.Palette.textMuted)
                    .frame(width: Self.symbolColumn)
                Text(title)
                    .font(isSelected ? Bench.Typo.bodyEmphasis : Bench.Typo.body)
                    .foregroundStyle(isSelected ? Bench.Palette.textPrimary
                                                : Bench.Palette.textSecondary)
                Spacer(minLength: 4)
                if let count {
                    Text(count)
                        .font(Bench.Typo.counter)
                        .foregroundStyle(isSelected ? Bench.Palette.textMuted
                                                    : Bench.Palette.textFaintest)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(isSelected ? Bench.Palette.textPrimary.opacity(0.07)
                                 : .clear))
            .contentShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()   // as above: the raised fill is the signal
        .padding(.leading, 14)   // indents under the destination's glyph
    }
}

/// Section header inside the sidebar: `MAKE`, `BROWSE`.
struct BenchSidebarHeading: View {
    let text: String
    var topPadding: CGFloat = 14

    var body: some View {
        Text(text)
            .eyebrow(Bench.Palette.textFaintest)
            .padding(.horizontal, 8)
            .padding(.top, topPadding).padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The card pinned to the bottom of the sidebar. Every destination fills the
/// same rectangle with whatever is useful there.
struct BenchSidebarCard<Content: View>: View {
    var stroke: Color = Bench.Palette.hairline
    /// The gap the card holds around itself. Zero when the card is one of a
    /// stack, so the container owns the spacing between them and the inset
    /// from the sidebar's edges — otherwise two stacked cards each contribute
    /// a margin and the gap between them comes out twice the outer inset.
    var margin: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Bench.Palette.statusCard))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(stroke, lineWidth: 1))
        .padding(margin)
    }
}

// MARK: - Sidebar control

/// The window's sidebar, as every screen's top bar sees it.
///
/// Passed through the environment rather than down eight screen signatures:
/// the state belongs to `MainWindow` and the control belongs in a bar that
/// every screen already draws, with nothing in between that has any business
/// knowing about either.
struct SidebarControl {
    var isCollapsed = false
    /// The window is too narrow to show the sidebar at all, so the button
    /// says so instead of pretending it can change anything.
    var isLocked = false
    /// Nil where there is no sidebar to toggle — previews, and the offscreen
    /// hosts the layout tests render into.
    var toggle: (() -> Void)?
}

private struct SidebarControlKey: EnvironmentKey {
    // Computed, not stored: `SidebarControl` carries a closure and so is not
    // Sendable, which makes a stored static a shared-mutable-state error under
    // strict concurrency. A fresh empty value per read costs nothing and is
    // what "no sidebar here" means anyway.
    static var defaultValue: SidebarControl { SidebarControl() }
}

extension EnvironmentValues {
    var sidebarControl: SidebarControl {
        get { self[SidebarControlKey.self] }
        set { self[SidebarControlKey.self] = newValue }
    }
}

/// The sidebar toggle, immediately left of every screen's title.
struct SidebarToggleButton: View {
    let control: SidebarControl

    var body: some View {
        Button { control.toggle?() } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(control.isLocked ? Bench.Palette.textFaintest
                                                  : Bench.Palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(control.isLocked)
        .help(control.isLocked
              ? "The window is too narrow to show the sidebar"
              : control.isCollapsed ? "Show the sidebar" : "Hide the sidebar")
        .accessibilityLabel(control.isCollapsed ? "Show the sidebar"
                                               : "Hide the sidebar")
    }
}

// MARK: - Top bar

/// The 52 pt strip at the top of every screen: the sidebar toggle and the
/// title on the left, whatever the screen needs on the right.
struct BenchTopBar<Leading: View, Trailing: View>: View {
    @Environment(\.sidebarControl) private var sidebar
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 14) {
            if sidebar.toggle != nil {
                SidebarToggleButton(control: sidebar)
                    // With the sidebar gone the traffic lights have nothing to
                    // sit over but this bar, so the row starts clear of them.
                    // Padding rather than a spacer: a spacer would also take
                    // the stack's 14 pt on both sides of itself.
                    .padding(.leading, sidebar.isCollapsed
                             ? Bench.Metrics.trafficLightInset : 0)
            }
            leading()
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .frame(height: Bench.Metrics.topBarHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
        }
    }
}

extension BenchTopBar where Leading == AnyView {
    /// Convenience for the common `title + trailing controls` shape.
    init(title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(leading: {
            AnyView(Text(title)
                .font(Bench.Typo.screenTitle)
                .tracking(-0.15)
                .foregroundStyle(Bench.Palette.textPrimary))
        }, trailing: trailing)
    }
}

/// The strip under the top bar that holds filters and chips.
struct BenchFilterBar<Content: View>: View {
    var background: Color = .clear
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) {
            content()
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Bench.Palette.hairlineFaint).frame(height: 1)
        }
    }
}

/// A right-hand inspector column: fixed width, `panel` fill, hairline on the
/// leading edge.
struct BenchInspector<Content: View>: View {
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(Bench.Palette.panel)
            .overlay(alignment: .leading) {
                Rectangle().fill(Bench.Palette.hairline).frame(width: 1)
            }
    }
}

/// Header row inside an inspector or panel — 16/18 padding and a bottom rule.
struct BenchPanelHeader<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Bench.Palette.hairline).frame(height: 1)
            }
    }
}
