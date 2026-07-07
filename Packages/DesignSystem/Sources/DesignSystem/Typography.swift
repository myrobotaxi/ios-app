import SwiftUI

// MARK: - Type scale
//
// Ported from the design project's type scale (Handoff §1). Every text style
// scales with Dynamic Type via `@ScaledMetric` relative to a matching system
// text style.
//
//   Screen Title   28 / 600   tracking -0.6
//   Hero Number    28–40 / 300, monospaced digits
//   Section Title  18 / 600
//   Body           14–15 / 400
//   Label          10–12 / 500, UPPERCASE, tracking +1.2
//   Tab            10 / 500

public enum MRTTextStyle: Equatable {
    case screenTitle
    case heroNumber(size: CGFloat = 34) // spec range 28–40
    case sectionTitle
    case body // 15pt default
    case bodySmall // 14pt
    case label(size: CGFloat = 11) // spec range 10–12
    case tab

    var size: CGFloat {
        switch self {
        case .screenTitle: 28
        case .heroNumber(let size): min(max(size, 28), 40)
        case .sectionTitle: 18
        case .body: 15
        case .bodySmall: 14
        case .label(let size): min(max(size, 10), 12)
        case .tab: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .screenTitle, .sectionTitle: .semibold // 600
        case .heroNumber: .light // 300
        case .body, .bodySmall: .regular // 400
        case .label, .tab: .medium // 500
        }
    }

    var tracking: CGFloat {
        switch self {
        case .screenTitle: -0.6
        case .label: 1.2
        default: 0
        }
    }

    var isUppercased: Bool {
        if case .label = self { return true }
        return false
    }

    var usesMonospacedDigits: Bool {
        if case .heroNumber = self { return true }
        return false
    }

    /// System text style used as the Dynamic Type scaling anchor.
    var relativeTextStyle: Font.TextStyle {
        switch self {
        case .screenTitle: .title
        case .heroNumber: .largeTitle
        case .sectionTitle: .title3
        case .body, .bodySmall: .body
        case .label: .caption
        case .tab: .caption2
        }
    }
}

public extension View {
    /// Applies a MyRoboTaxi text style (font, weight, tracking, case,
    /// monospaced digits) with Dynamic Type scaling.
    func mrtTextStyle(_ style: MRTTextStyle) -> some View {
        modifier(MRTTextStyleModifier(style: style))
    }
}

struct MRTTextStyleModifier: ViewModifier {
    let style: MRTTextStyle
    @ScaledMetric private var scaledSize: CGFloat

    init(style: MRTTextStyle) {
        self.style = style
        _scaledSize = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTextStyle)
    }

    func body(content: Content) -> some View {
        content
            .font(font)
            .tracking(style.tracking)
            .textCase(style.isUppercased ? .uppercase : nil)
    }

    private var font: Font {
        var font = Font.system(size: scaledSize, weight: style.weight)
        if style.usesMonospacedDigits {
            font = font.monospacedDigit()
        }
        return font
    }
}
