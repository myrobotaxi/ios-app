import SwiftUI

// MARK: - Battery (components.jsx batteryColor / BatteryBar / MiniBattery)

public extension Color {
    /// Threshold color for a battery percentage (0–100) — jsx `batteryColor`:
    /// < 20 low, < 50 mid, else high; charging always wins.
    static func mrtBatteryColor(_ pct: Double, charging: Bool = false) -> Color {
        if charging { return .mrtCharging }
        if pct < 20 { return .mrtBatLow }
        if pct < 50 { return .mrtBatMid }
        return .mrtBatHigh
    }
}

/// Horizontal battery bar on an `elevated` track, minimum 3% fill,
/// optional trailing percent label.
public struct BatteryBar: View {
    private let pct: Double
    private let height: CGFloat
    private let showLabel: Bool
    private let charging: Bool

    public init(pct: Double, height: CGFloat = 6, showLabel: Bool = false, charging: Bool = false) {
        self.pct = pct
        self.height = height
        self.showLabel = showLabel
        self.charging = charging
    }

    public var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mrtElevated)
                    Capsule()
                        .fill(Color.mrtBatteryColor(pct, charging: charging))
                        .frame(width: geo.size.width * max(pct, 3) / 100)
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.4), value: pct) // width .4s ease-out

            if showLabel {
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
    }
}

/// Small Tesla-style battery glyph filled relative to full.
/// Keeps the jsx's own thresholds (≤10 low, ≤20 mid), which deliberately
/// differ from `batteryColor`'s (<20 / <50).
public struct MiniBattery: View {
    private let pct: Double
    private let charging: Bool
    private let width: CGFloat
    private let height: CGFloat

    public init(pct: Double, charging: Bool = false, width: CGFloat = 26, height: CGFloat = 9) {
        self.pct = pct
        self.charging = charging
        self.width = width
        self.height = height
    }

    var fillColor: Color {
        if charging { return .mrtCharging }
        if pct <= 10 { return .mrtBatLow }
        if pct <= 20 { return .mrtBatMid }
        return .mrtBatHigh
    }

    public var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(Color.mrtElevated, lineWidth: 1)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(fillColor)
                        .frame(width: geo.size.width * max(8, pct) / 100)
                        // 0 0 5px {c}44
                        .shadow(color: fillColor.opacity(68.0 / 255.0), radius: 2.5)
                }
                .padding(2.3) // 1px border + 1.3px padding (border-box)
            }
            .frame(width: width, height: height)
            // Battery cap nub
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.mrtElevated)
                .frame(width: 1.5, height: height * 0.4)
        }
    }
}
