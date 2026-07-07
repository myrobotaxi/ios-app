import SwiftUI

// MARK: - Stat cluster (components.jsx StatCol / StatRow) + KV + divider

/// One stat: 23pt light numeric value (+ optional unit) over a 10pt
/// uppercase label. Apple spaces these with whitespace, never hard rules.
public struct StatCol: View {
    private let label: String
    private let value: String
    private let unit: String?
    private let accent: Bool
    private let alignment: HorizontalAlignment

    public init(
        label: String,
        value: String,
        unit: String? = nil,
        accent: Bool = false,
        alignment: HorizontalAlignment = .center
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.accent = accent
        self.alignment = alignment
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: 7) {
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 23, weight: .light))
                    .monospacedDigit()
                    .tracking(-0.6)
                    .foregroundStyle(accent ? Color.mrtGold : Color.mrtText)
                if let unit {
                    Text(unit)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(1)
                .textCase(.uppercase)
                .foregroundStyle(Color.mrtTextMuted)
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading: .leading
        case .trailing: .trailing
        default: .center
        }
    }
}

/// Clean stat cluster — equal-width columns, top-aligned, 8pt gaps.
public struct StatRow<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) { content }
    }
}

/// Dense key-value row for settings/details lists.
public struct KV: View {
    private let label: String
    private let value: String
    private let gold: Bool

    public init(label: String, value: String, gold: Bool = false) {
        self.label = label
        self.value = value
        self.gold = gold
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(gold ? Color.mrtGold : Color.mrtText)
        }
        .padding(.vertical, 8)
    }
}

/// 1pt section divider (`Divider` in the jsx — MRT-prefixed to avoid the
/// SwiftUI.Divider collision).
public struct MRTDivider: View {
    private let pad: CGFloat

    public init(pad: CGFloat = 14) {
        self.pad = pad
    }

    public var body: some View {
        Rectangle()
            .fill(Color.mrtBorder)
            .frame(height: 1)
            .padding(.vertical, pad)
    }
}
