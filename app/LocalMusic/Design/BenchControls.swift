import SwiftUI

// The design draws its own controls rather than tinting AppKit's: a 4 pt track
// with a 14 pt knob, a lime pill toggle, a 2 pt-padded segmented container.
// Tinting the system controls gets none of those, so they are rebuilt here.
// Every one of them keeps the value visible beside the control, which is the
// rule the redesign is most insistent about.

// MARK: - Buttons

/// Lime, dark ink, glowing. The one action a screen is for: Generate, Create
/// mix, Split into 4 parts, Download.
struct BenchPrimaryButtonStyle: ButtonStyle {
    var size: Size = .regular
    var glows = true

    enum Size {
        case regular, compact

        var font: Font {
            switch self {
            case .regular: .system(size: 15, weight: .bold)
            case .compact: .system(size: 13, weight: .semibold)
            }
        }
        var padding: EdgeInsets {
            switch self {
            case .regular: EdgeInsets(top: 14, leading: 26, bottom: 14, trailing: 26)
            case .compact: EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20)
            }
        }
        var radius: CGFloat {
            switch self {
            case .regular: Bench.Metrics.Radius.buttonLarge
            case .compact: 9
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(size.font)
            .foregroundStyle(Bench.Palette.onAccent)
            .padding(size.padding)
            .background(RoundedRectangle(cornerRadius: size.radius, style: .continuous)
                .fill(Bench.Palette.accent))
            .shadow(color: glows ? Bench.Palette.accent.opacity(0.55) : .clear,
                    radius: 15, x: 0, y: 10)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .contentShape(RoundedRectangle(cornerRadius: size.radius, style: .continuous))
    }
}

/// `raised` fill + hairline stroke. Everything that isn't the one action.
struct BenchSecondaryButtonStyle: ButtonStyle {
    var tone: Tone = .neutral
    var padding = EdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
    var radius = Bench.Metrics.Radius.button

    enum Tone {
        case neutral, quiet, destructive, accent, violet

        var foreground: Color {
            switch self {
            case .neutral: Bench.Palette.textPrimary
            case .quiet: Bench.Palette.textSecondary
            case .destructive: Bench.Palette.danger
            case .accent: Bench.Palette.accent
            case .violet: Bench.Palette.violet
            }
        }
        var fill: Color {
            switch self {
            case .neutral: Bench.Palette.raised
            case .quiet: Bench.Palette.control
            case .destructive: Bench.Palette.danger.opacity(0.09)
            case .accent: Bench.Palette.accent.opacity(0.10)
            case .violet: Bench.Palette.violet.opacity(0.12)
            }
        }
        var stroke: Color {
            switch self {
            case .neutral: Bench.Palette.cardStrokeSoft
            case .quiet: .clear
            case .destructive: Bench.Palette.danger.opacity(0.22)
            case .accent: Bench.Palette.accent.opacity(0.22)
            case .violet: Bench.Palette.violet.opacity(0.24)
            }
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Bench.Typo.secondary)
            .foregroundStyle(tone.foreground)
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(tone.fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(tone.stroke, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
            // Transparent padding takes no hits in SwiftUI; without this the
            // label alone is clickable and the button feels broken at the edges.
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension ButtonStyle where Self == BenchPrimaryButtonStyle {
    static var benchPrimary: BenchPrimaryButtonStyle { .init() }
    static var benchPrimaryCompact: BenchPrimaryButtonStyle { .init(size: .compact) }
}

extension ButtonStyle where Self == BenchSecondaryButtonStyle {
    static var benchSecondary: BenchSecondaryButtonStyle { .init() }
    static func bench(_ tone: BenchSecondaryButtonStyle.Tone) -> BenchSecondaryButtonStyle {
        .init(tone: tone)
    }
}

// MARK: - Segmented

/// `Rows | Timeline`, `Songs | Parts | Renders`, `Simple | Full control`.
///
/// Not `Picker(.segmented)`: the design's selected segment is a lighter fill
/// inside a bordered container with 2 pt padding, and several instances carry
/// a dimmer count inside each label — neither is expressible with the system
/// control.
struct BenchSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Option]
    /// Share the full width between the segments instead of each taking only
    /// what its label needs. For a strip that heads a list rather than sitting
    /// in a toolbar: given the whole line it has nothing to crowd, and the
    /// text beside it stops being squeezed onto three lines.
    var fills = false

    struct Option: Identifiable {
        let value: Value
        let label: String
        /// Rendered after the label in a dimmer colour, e.g. `Songs 128`.
        var detail: String?
        /// Drawn before the label. For a strip whose tabs are not all the same
        /// kind of thing — a mark says "this one filters the list" without a
        /// second control to explain it.
        var symbol: String?
        var id: Value { value }
    }

    var body: some View {
        segments
            .padding(2)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                         style: .continuous)
                .fill(Bench.Palette.raised))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
    }

    /// Equal shares would be set by the widest label, so `Generated 96` and
    /// `Parts 3` would each get the same column and the long one would still
    /// truncate. `SegmentedFillLayout` gives every tab the width it actually
    /// needs and splits what is left over.
    @ViewBuilder
    private var segments: some View {
        if fills {
            SegmentedFillLayout { buttons }
        } else {
            HStack(spacing: 0) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
            ForEach(options) { option in
                let isOn = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 10))
                        }
                        Text(option.label)
                        if let detail = option.detail {
                            Text(detail)
                                .foregroundStyle(isOn ? Bench.Palette.textQuaternary
                                                      : Bench.Palette.textFaintest)
                        }
                    }
                    .font(isOn ? Bench.Typo.secondaryEmphasis : Bench.Typo.secondary)
                    .foregroundStyle(isOn ? Bench.Palette.textPrimary
                                          : Bench.Palette.textQuaternary)
                    // A segment squeezed below its label's width should shorten
                    // it, not stack it: two lines of "Gener/ated" inside a pill
                    // reads as a broken control rather than a tight one.
                    .lineLimit(1)
                    // 12 pt separates pills that hug their labels; a filling
                    // strip already has the whole share between them, so the
                    // inset is only stealing width from the word — and at five
                    // tabs across a 560 pt sheet those last 8 pt are the
                    // difference between "Generated" and "Generat…".
                    .padding(.horizontal, fills ? 8 : 12).padding(.vertical, 5)
                    // After the padding, before the fill: the segment's own
                    // pill has to grow with it, not float in the middle of it.
                    .frame(maxWidth: fills ? .infinity : nil)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? Bench.Palette.segmentedSelected : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
    }
}

/// A row where every subview gets the width it asked for, plus an equal share
/// of whatever is left over.
///
/// The alternative — `maxWidth: .infinity` on each — divides the row equally,
/// which is only right when the labels are the same length. A strip reading
/// `All 128 · Generated 96 · Imported 30 · Renders 2 · Parts 3 · Edited 2 ·
/// Loved 4` is not: equal columns are set by the longest label, so the long
/// one truncates while `Parts 3` sits in twice the room it needs.
///
/// Slack is shared equally rather than in proportion to width, so the padding
/// around each label stays even and the tabs read as one control.
struct SegmentedFillLayout: Layout {
    /// Pure and testable: what each subview gets out of `total`, given what
    /// each one asked for. Too little room shrinks them in proportion, so the
    /// widest gives up the most rather than the last one falling off the end.
    static func widths(ideals: [CGFloat], total: CGFloat) -> [CGFloat] {
        guard !ideals.isEmpty else { return [] }
        let wanted = ideals.reduce(0, +)
        guard total > wanted else {
            guard wanted > 0 else { return ideals }
            return ideals.map { $0 * total / wanted }
        }
        let slack = (total - wanted) / CGFloat(ideals.count)
        return ideals.map { $0 + slack }
    }

    private func ideals(_ subviews: Subviews) -> [CGFloat] {
        subviews.map { $0.sizeThatFits(.unspecified).width }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let ideals = ideals(subviews)
        let total = proposal.width ?? ideals.reduce(0, +)
        let height = subviews.reduce(CGFloat.zero) {
            max($0, $1.sizeThatFits(.unspecified).height)
        }
        return CGSize(width: total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(ideals: ideals(subviews), total: bounds.width)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY),
                          anchor: .leading,
                          proposal: ProposedViewSize(width: width,
                                                     height: bounds.height))
            x += width
        }
    }
}

// MARK: - Toggle

/// The lime pill switch. On: accent track, dark knob. Off: `#2C333C` track,
/// grey knob.
struct BenchToggleStyle: ToggleStyle {
    var width: CGFloat = 38
    var tint: Color = Bench.Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        let height = width * 22 / 38
        let inset: CGFloat = 2
        let knob = height - inset * 2
        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? tint : Bench.Palette.segmentedSelected)
                    Circle()
                        .fill(configuration.isOn ? Bench.Palette.onAccent
                                                 : Bench.Palette.textQuaternary)
                        .frame(width: knob, height: knob)
                        .padding(.horizontal, inset)
                }
                .frame(width: width, height: height)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
}

extension ToggleStyle where Self == BenchToggleStyle {
    static var bench: BenchToggleStyle { .init() }
    static func bench(width: CGFloat, tint: Color = Bench.Palette.accent) -> BenchToggleStyle {
        .init(width: width, tint: tint)
    }
}

/// The accent-tinted toggle *chip* from the workbench align bar — a switch and
/// its label inside a tinted, stroked pill that lights up when on.
struct BenchToggleChip: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(label)
                .font(Bench.Typo.secondaryEmphasis)
                .foregroundStyle(isOn ? Bench.Palette.accent : Bench.Palette.textQuaternary)
        }
        .toggleStyle(.bench(width: 32))
        .padding(.leading, 8).padding(.trailing, 11).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(isOn ? Bench.Palette.accent.opacity(0.10) : Bench.Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            .strokeBorder(isOn ? Bench.Palette.accent.opacity(0.22)
                               : Bench.Palette.cardStrokeSoft, lineWidth: 1))
    }
}

// MARK: - Slider

/// 4 pt track, filled in `tint`, with a 14 pt knob. The fill colour is a
/// parameter because the workbench fills each row's gain slider in that part's
/// stem colour — the same colour as its swatch, waveform and timeline clip.
struct BenchSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    var tint: Color = Bench.Palette.accent
    var knobSize: CGFloat = Bench.Metrics.Slider.knob
    var isEnabled = true
    /// Called once when a drag begins, so callers can open an undo group
    /// before the first mutation rather than after it.
    var onEditingBegan: (() -> Void)?
    /// Called once when it ends. A drag is one edit to undo, and the caller
    /// cannot know it is over without this.
    var onEditingEnded: (() -> Void)?

    @State private var dragging = false

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: Bench.Metrics.Slider.track)
                Capsule()
                    .fill(isEnabled ? tint : Bench.Palette.textMuted)
                    .frame(width: max(0, x), height: Bench.Metrics.Slider.track)
                Circle()
                    .fill(isEnabled ? Bench.Palette.knob : Color(hex: 0xB7BEC7))
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: x - knobSize / 2)
            }
            .frame(height: max(knobSize, Bench.Metrics.Slider.track))
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard isEnabled else { return }
                        if !dragging {
                            dragging = true
                            onEditingBegan?()
                        }
                        set(fromX: g.location.x, width: width)
                    }
                    .onEnded { _ in
                        if dragging { onEditingEnded?() }
                        dragging = false
                    })
        }
        .frame(height: knobSize)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func set(fromX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let f = Double(x / width).clamped(to: 0...1)
        var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            v = (v / step).rounded() * step
        }
        value = v.clamped(to: range)
    }
}

// MARK: - Numeric fields

/// The dark inset field every number sits in: `#0F1216`, hairline, r6, mono.
struct BenchValueField: View {
    let text: String
    var width: CGFloat?
    var alignment: Alignment = .trailing
    var font: Font = Bench.Typo.value
    var foreground: Color = Bench.Palette.textPrimary

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width, alignment: alignment)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                         style: .continuous)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
    }
}

/// Editable version of the same field.
struct BenchNumberField<F: ParseableFormatStyle>: View
where F.FormatInput: Equatable, F.FormatOutput == String {
    @Binding var value: F.FormatInput
    let format: F
    var width: CGFloat = 70
    var onCommit: (() -> Void)?

    var body: some View {
        TextField("", value: $value, format: format)
            .textFieldStyle(.plain)
            .font(Bench.Typo.value)
            .foregroundStyle(Bench.Palette.textPrimary)
            .multilineTextAlignment(.trailing)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: width)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                         style: .continuous)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            .onSubmit { onCommit?() }
    }
}

/// The same field, holding free text rather than a number.
struct BenchTextField: View {
    @Binding var text: String
    var placeholder: String = ""
    var font: Font = Bench.Typo.value
    var onCommit: (() -> Void)?

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Bench.Palette.textPrimary)
            // Drawn rather than handed to `TextField`: its own placeholder
            // inherits the field's `foregroundStyle`, so it came out at nearly
            // full strength and read as text already typed in rather than as a
            // default waiting to be replaced.
            //
            // A background of the *unpadded* field, so it shares the field's
            // frame and needs no inset of its own to guess at.
            // `BenchTextFieldTests` draws both and compares the ink.
            .background(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(font)
                        .foregroundStyle(Bench.Palette.textFaint)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                         style: .continuous)
                .fill(Bench.Palette.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                      style: .continuous)
                .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
            .onSubmit { onCommit?() }
    }
}

/// Numeric field with the attached ▲/▼ column, divided by a hairline.
struct BenchStepper: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...999
    var width: CGFloat = 38
    var onEdit: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            Text("\(value)")
                .font(Bench.Typo.mono(12, .semibold))
                .foregroundStyle(Bench.Palette.textPrimary)
                .frame(minWidth: width)
                .padding(.horizontal, 10).padding(.vertical, 7)
            VStack(spacing: 0) {
                stepButton("▲", delta: 1)
                Rectangle().fill(Bench.Palette.cardStroke).frame(height: 1)
                stepButton("▼", delta: -1)
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(Bench.Palette.cardStroke).frame(width: 1)
            }
        }
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                     style: .continuous)
            .fill(Bench.Palette.windowBackground))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.cardStroke, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.control,
                                    style: .continuous))
    }

    private func stepButton(_ glyph: String, delta: Int) -> some View {
        BenchStepButton(glyph: glyph, delta: delta, shape: .inline,
                        value: $value, range: range, onEdit: onEdit)
    }
}

/// The ▲/▼ pair on its own, for a value that is already shown large beside it.
/// Pairing this with a `BenchStepper` prints the number twice — which is what
/// the Studio's Takes card did.
struct BenchStepperArrows: View {
    @Binding var value: Int
    var range: ClosedRange<Int> = 1...999
    var limitNote: String?
    var onEdit: (() -> Void)?

    var body: some View {
        VStack(spacing: 3) {
            arrow("▲", delta: 1)
            arrow("▼", delta: -1)
        }
    }

    private func arrow(_ glyph: String, delta: Int) -> some View {
        BenchStepButton(glyph: glyph, delta: delta, shape: .standalone,
                        value: $value, range: range, limitNote: limitNote,
                        onEdit: onEdit)
    }
}

/// One arrow. Shared so both stepper shapes agree on what a limit looks like:
/// dimmed and inert rather than a live-looking button that silently does
/// nothing — the difference between "this tops out here" and "this control is
/// broken".
private struct BenchStepButton: View {
    enum Shape { case inline, standalone }

    let glyph: String
    let delta: Int
    let shape: Shape
    @Binding var value: Int
    let range: ClosedRange<Int>
    var limitNote: String?
    var onEdit: (() -> Void)?

    private var enabled: Bool { range.contains(value + delta) }

    var body: some View {
        Button {
            guard enabled else { return }
            onEdit?()
            value += delta
        } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(enabled ? "" : limitNote ?? "")
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(glyph)
            .foregroundStyle(enabled ? Bench.Palette.textTertiary
                                     : Bench.Palette.textFaintest)
        switch shape {
        case .inline:
            text.font(.system(size: 7))
                .padding(.horizontal, 6).padding(.vertical, 1.5)
        case .standalone:
            text.font(.system(size: 9))
                .frame(width: 26, height: 16)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Bench.Palette.raised))
        }
    }
}

// MARK: - Search

struct BenchSearchField: View {
    @Binding var text: String
    let placeholder: String
    /// nil fills whatever it is given — for a field that heads a panel of a
    /// fixed width rather than sitting in a toolbar. `frame(width:)` treats nil
    /// as "unconstrained", so the default keeps every existing call site at the
    /// exact width it had.
    var width: CGFloat? = 250

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Bench.Palette.textFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Bench.Typo.secondary)
                .foregroundStyle(Bench.Palette.textPrimary)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                     style: .continuous)
            .fill(Bench.Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: Bench.Metrics.Radius.button,
                                  style: .continuous)
            .strokeBorder(Bench.Palette.cardStrokeSoft, lineWidth: 1))
    }
}

// MARK: - Menus

/// The `Any model ⌄` / `Whole part ⌄` control: a bordered pill that opens a
/// menu, with a trailing chevron in the faint colour.
struct BenchMenu<Content: View>: View {
    let label: String
    var detail: String?
    var fill: Color = Bench.Palette.raised
    var stroke: Color = Bench.Palette.cardStrokeSoft
    var radius: CGFloat = Bench.Metrics.Radius.controlLarge
    @ViewBuilder var content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: 7) {
                if let detail {
                    Text(detail)
                        .font(Bench.Typo.mono(10))
                        .foregroundStyle(Bench.Palette.textMuted)
                }
                Text(label)
                    .font(Bench.Typo.secondary)
                    .foregroundStyle(Bench.Palette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Bench.Palette.textFaintest)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Helpers

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
