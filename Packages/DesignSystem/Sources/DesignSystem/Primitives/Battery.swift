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

/// The LIVE charge-session treatment for a battery bar (MYR-333).
///
/// This is deliberately NOT the same axis as `BatteryBar(charging:)` /
/// `mrtBatteryColor(_:charging:)`. That flag is the prototype's `batteryColor`
/// rule — "charging always wins", resolving to the amber `mrtCharging` — and it
/// stays exactly as it was for `MiniBattery` and the primitives showcase.
///
/// `MRTBatteryCharge` is the owner hero's treatment, and it is GREEN on purpose.
/// The client asked for it in those words ("the bar should be a clean pulsing
/// green animation"), and green is the right answer for a second reason: it is
/// already the bar's resting colour at a healthy state of charge
/// (`mrtBatHigh`), so at the moment charging starts the bar does not change
/// COLOUR — it starts BREATHING. The signal is the motion, which is what makes
/// it read as "something is happening right now" rather than as one more static
/// state chip. Committing to green at every level (rather than pulsing whatever
/// threshold colour the SOC resolves to) also keeps the meaning single: green
/// means a live charge session, at 12% exactly as at 76%.
public enum MRTBatteryCharge: Sendable, Equatable {
    /// No known charge session — the bar renders exactly as it always has, with
    /// the threshold colour and no motion. The value for `Disconnected`,
    /// `Stopped`, `NoPower`, `Starting`, an unrecognized wire value, and for
    /// every car that has never reported a charge state at all.
    case none
    /// Actively charging — pulsing green (Reduce Motion → static green).
    case charging
    /// Charge complete — STATIC green, no pulse. The session is over, so
    /// motion would be a lie; the colour still says "this ended well".
    case complete
}

/// Horizontal battery bar on an `elevated` track, minimum 3% fill,
/// optional trailing percent label.
public struct BatteryBar: View {
    private let pct: Double
    private let height: CGFloat
    private let showLabel: Bool
    private let charging: Bool
    private let charge: MRTBatteryCharge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    public init(
        pct: Double,
        height: CGFloat = 6,
        showLabel: Bool = false,
        charging: Bool = false,
        charge: MRTBatteryCharge = .none
    ) {
        self.pct = pct
        self.height = height
        self.showLabel = showLabel
        self.charging = charging
        self.charge = charge
    }

    /// The fill colour. A live charge session (`charging` or `complete`) commits
    /// to green; otherwise the existing threshold/`charging:` rule is untouched,
    /// which is what keeps every pre-MYR-333 call site pixel-identical.
    var fillColor: Color {
        switch charge {
        case .charging, .complete: return .mrtBatHigh
        case .none: return .mrtBatteryColor(pct, charging: charging)
        }
    }

    /// Whether the fill should breathe. Only an ACTIVE session pulses, and only
    /// when the user has not asked for less motion — the Reduce Motion fallback
    /// is the same static green, so the state is never lost, just held still
    /// (the `PulseDot` / `mrt-gold-pulse` precedent).
    var isPulsing: Bool { charge == .charging && !reduceMotion }

    public var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mrtElevated)
                    Capsule()
                        .fill(fillColor)
                        .frame(width: geo.size.width * max(pct, 3) / 100)
                        // The breathe: opacity + a soft glow of the SAME colour,
                        // on a 2.4s ease-in-out autoreversing loop — one full
                        // cycle every ~2.4s, the design's established motion
                        // grammar for "alive" (`mrt-gold-pulse` 2.4s,
                        // `mrt-pulse-ring` 2s). Nothing about the bar's GEOMETRY
                        // animates: the width still belongs to `pct` alone, so a
                        // charging bar never appears to grow and shrink.
                        .opacity(isPulsing && breathing ? 0.55 : 1)
                        .shadow(
                            color: fillColor.opacity(isPulsing && breathing ? 0.55 : 0),
                            radius: 6
                        )
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.4), value: pct) // width .4s ease-out
            .onAppear { startBreathingIfNeeded() }
            .onChange(of: isPulsing) { _, _ in startBreathingIfNeeded() }

            if showLabel {
                Text("\(Int(pct.rounded()))%")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
    }

    /// Drive the loop from the resolved `isPulsing` rather than from `onAppear`
    /// alone: a car that starts charging while the sheet is already on screen
    /// must begin breathing, and one that stops must settle back to a solid bar
    /// instead of being left frozen mid-fade.
    private func startBreathingIfNeeded() {
        guard isPulsing else {
            withAnimation(.easeOut(duration: 0.25)) { breathing = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            breathing = true
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
