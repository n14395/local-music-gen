import SwiftUI

/// The "Bench" design system.
///
/// Every colour, size and weight in this file is lifted from the redesign
/// document (`Music ML App Redesign.dc.html`, direction 1a). The app is
/// deliberately dark-only — see `Palette` for why — so these are plain sRGB
/// values rather than asset-catalog pairs, and nothing here consults
/// `ColorScheme`.
///
/// Rules the design makes that this file encodes:
///   * all numerics are monospaced (`Typo.mono*`),
///   * a control always shows its value beside it,
///   * state is a badge, not a colour alone,
///   * stem identity is a colour carried everywhere (`Palette.stem(_:)`).
enum Bench {}

// MARK: - Palette

extension Bench {
    /// Dark-only on purpose: the app is a tool for looking at waveforms, and
    /// the design fixes the contrast between the well (`#0D1013`), the lanes
    /// and the lime accent. A light rendering of the same tokens would need a
    /// second set of decisions the design does not make, so rather than
    /// half-support Light Mode the window pins itself to dark.
    enum Palette {
        // Surfaces
        static let windowBackground = Color(hex: 0x0F1216)
        static let sidebar = Color(hex: 0x13171D)
        static let panel = Color(hex: 0x12161C)
        static let card = Color(hex: 0x171B21)
        static let cardSelected = Color(hex: 0x1A1F27)
        static let raised = Color(hex: 0x1B2027)
        static let control = Color(hex: 0x232A32)
        static let controlDim = Color(hex: 0x1F252D)
        static let segmentedSelected = Color(hex: 0x2C333C)
        static let well = Color(hex: 0x0D1013)
        static let statusCard = Color(hex: 0x191E25)

        /// Alternating list rows. Deliberately an overlay rather than an opaque
        /// colour so rows read the same on `windowBackground` and on `panel`.
        static let rowZebra = Color.white.opacity(0.02)
        static let rowSelected = controlDim

        // Strokes
        static let hairline = Color.white.opacity(0.06)
        static let hairlineFaint = Color.white.opacity(0.05)
        static let cardStroke = Color.white.opacity(0.08)
        static let cardStrokeSoft = Color.white.opacity(0.07)
        static let windowStroke = Color.white.opacity(0.09)

        // Text
        static let textPrimary = Color(hex: 0xE9EDF2)
        static let textSecondary = Color(hex: 0xC3CBD4)
        static let textTertiary = Color(hex: 0x98A2AE)
        static let textQuaternary = Color(hex: 0x8A94A2)
        static let textMuted = Color(hex: 0x7C8794)
        static let textFaint = Color(hex: 0x6B7480)
        static let textFaintest = Color(hex: 0x5C6672)

        // Semantic
        static let accent = Color(hex: 0xD8FF5A)
        static let onAccent = Color(hex: 0x14180A)
        static let accentHover = Color(hex: 0xEBFF9B)
        static let ok = Color(hex: 0x5BE585)
        static let warn = Color(hex: 0xFFB454)
        static let star = Color(hex: 0xFFC53D)
        static let starEmpty = Color(hex: 0x39414B)
        static let danger = Color(hex: 0xFF7A6B)
        static let dangerText = Color(hex: 0xFF9E8A)
        static let violet = Color(hex: 0xB69CFF)
        static let cyan = Color(hex: 0x6FD9F2)

        /// Knob fill for every slider — brighter than `textPrimary` so it reads
        /// as a physical control rather than a label.
        static let knob = Color(hex: 0xF2F5F8)

        // Tints. The design never fills with a flat semantic colour; it always
        // uses the hue at low alpha with a slightly stronger stroke.
        static func tint(_ color: Color, _ alpha: Double = 0.12) -> Color {
            color.opacity(alpha)
        }

        // MARK: stems

        /// Stem identity. Carried by the swatch bar, the waveform, the gain
        /// slider fill, the timeline clip and the playhead — the design leans
        /// on this being the *same* colour in all five places.
        static func stem(_ kind: String?) -> Color {
            switch StemKind(kind) {
            case .vocals: Color(hex: 0xFF8FA3)
            case .drums: Color(hex: 0xFFB454)
            case .bass: Color(hex: 0x4ECDC4)
            case .other: Color(hex: 0xB69CFF)
            case .piano: Color(hex: 0x7DA6FF)
            case .guitar: Color(hex: 0xC6E96B)
            case .notes: Color(hex: 0x6FD9F2)
            case .unknown: Color(hex: 0x8A94A2)
            }
        }
    }

    /// The stem vocabulary the palette knows about. Parsed leniently because
    /// part kinds arrive as free-form strings like `stem.vocals`,
    /// `layer.piano` or `notes.melody`.
    enum StemKind {
        case vocals, drums, bass, other, piano, guitar, notes, unknown

        init(_ raw: String?) {
            guard let raw = raw?.lowercased(), !raw.isEmpty else {
                self = .unknown
                return
            }
            // Match on the most specific token so "stem.vocals" and
            // "vocals-2" both land on .vocals.
            if raw.contains("vocal") { self = .vocals }
            else if raw.contains("drum") { self = .drums }
            else if raw.contains("bass") { self = .bass }
            else if raw.contains("piano") || raw.contains("keys") { self = .piano }
            else if raw.contains("guitar") { self = .guitar }
            else if raw.contains("note") || raw.contains("midi") { self = .notes }
            else if raw.contains("other") { self = .other }
            else { self = .unknown }
        }
    }
}

// MARK: - Typography

extension Bench {
    /// The design uses exactly two families: the system face for prose and a
    /// monospaced face for **every number**. Sizes carry fractional weights in
    /// the source (620, 640, 660, 680); SwiftUI has no such granularity, so
    /// each maps to the nearest of `.medium`/`.semibold`/`.bold`.
    enum Typo {
        // Prose
        static let screenTitle = Font.system(size: 15, weight: .semibold)
        static let sectionTitle = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let bodyEmphasis = Font.system(size: 13, weight: .semibold)
        static let secondary = Font.system(size: 12)
        static let secondaryEmphasis = Font.system(size: 12, weight: .semibold)
        static let small = Font.system(size: 11.5)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 10.5)

        /// Inspector headline — 17/650 in the source.
        static let inspectorTitle = Font.system(size: 17, weight: .semibold)
        /// The Simple-mode prompt. Large, quiet, the focus of the screen.
        static let promptHero = Font.system(size: 22)
        /// The Full-control prompt, which shares the column with lyrics.
        static let promptCompact = Font.system(size: 18)

        // Mono
        static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }

        /// The recurring all-caps section header ("SAMPLING", "TAGS").
        /// Tracking is applied separately — see `View.eyebrow()`.
        static let eyebrow = mono(10, .semibold)
        /// The second line of every row: `MUSICGEN SMALL · 9.9 S · 13:00`.
        static let metaLine = mono(10)
        static let badge = mono(10)
        static let value = mono(13, .semibold)
        static let valueLarge = mono(15, .semibold)
        static let counter = mono(11)
    }
}

// MARK: - Metrics

extension Bench {
    enum Metrics {
        static let sidebarWidth: CGFloat = 230
        static let topBarHeight: CGFloat = 52
        static let filterBarHeight: CGFloat = 48
        static let transportHeight: CGFloat = 66
        static let timelineLaneHeight: CGFloat = 100
        static let timelineRulerHeight: CGFloat = 28
        static let timelineHeaderWidth: CGFloat = 212

        /// Right-hand inspector widths, which differ per screen in the design
        /// because the content genuinely differs — the parameter panel needs
        /// room for label + slider + value, the queue does not.
        enum Inspector {
            static let takes: CGFloat = 392
            static let parameters: CGFloat = 576
            static let queue: CGFloat = 340
            static let library: CGFloat = 404
            static let actionConfig: CGFloat = 352
            static let workbench: CGFloat = 322
        }

        enum Radius {
            static let window: CGFloat = 14
            static let card: CGFloat = 12
            static let cardLarge: CGFloat = 14
            static let button: CGFloat = 8
            static let buttonLarge: CGFloat = 11
            static let control: CGFloat = 6
            static let controlLarge: CGFloat = 7
            static let badge: CGFloat = 5
            static let row: CGFloat = 9
            static let swatch: CGFloat = 3
        }

        /// Slider geometry, shared so every slider in the app is the same
        /// object: a 4 pt track with a 14 pt knob.
        enum Slider {
            static let track: CGFloat = 4
            static let knob: CGFloat = 14
            static let knobSmall: CGFloat = 13
        }
    }
}

// MARK: - Helpers

extension Color {
    /// `Color(hex: 0xD8FF5A)` — the design document is written in hex and
    /// transcribing to 0-1 triples by hand is how palettes drift.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

extension View {
    /// The all-caps mono section label used throughout the design.
    func eyebrow(_ color: Color = Bench.Palette.textFaint) -> some View {
        self.font(Bench.Typo.eyebrow)
            .tracking(1.6)          // .16em at 10 pt
            .foregroundStyle(color)
    }

    /// The mono second line under a title.
    func metaLine(_ color: Color = Bench.Palette.textMuted) -> some View {
        self.font(Bench.Typo.metaLine)
            .tracking(0.2)
            .foregroundStyle(color)
    }

    /// A card: fill, hairline stroke, rounded. `stroke` is passed explicitly
    /// when a card is selected, since selection in this design is always a
    /// coloured stroke rather than a fill change alone.
    func benchCard(fill: Color = Bench.Palette.card,
                   stroke: Color = Bench.Palette.cardStroke,
                   radius: CGFloat = Bench.Metrics.Radius.card) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(stroke, lineWidth: 1))
    }
}
