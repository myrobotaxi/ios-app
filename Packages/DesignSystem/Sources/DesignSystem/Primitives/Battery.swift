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
/// COLOUR — it starts MOVING. The signal is the motion, which is what makes
/// it read as "something is happening right now" rather than as one more static
/// state chip. Committing to green at every level (rather than animating whatever
/// threshold colour the SOC resolves to) also keeps the meaning single: green
/// means a live charge session, at 12% exactly as at 76%.
///
/// MYR-337 changed WHAT the motion is, not what it means. MYR-333 shipped a
/// whole-bar opacity breath (1 ↔ 0.55 on a 2.4s autoreverse); on the client's
/// device that composited to roughly rgb(45,134,67) ↔ rgb(47,182,81) — two
/// greens close enough that the bar read as static and slightly dim: "Charging
/// pulse is really faint. It should pulse ACROSS smoothly." A whole-surface
/// fade has no direction, so there is nothing for the eye to track; the fix is
/// motion with a direction — a bright highlight travelling left→right across
/// the fill, the same grammar as `mrt-text-shimmer` / the CTA's border trace,
/// where the thing that moves is a highlight and the surface underneath holds
/// still.
public enum MRTBatteryCharge: Sendable, Equatable {
    /// No known charge session — the bar renders exactly as it always has, with
    /// the threshold colour and no motion. The value for `Disconnected`,
    /// `Stopped`, `NoPower`, `Starting`, an unrecognized wire value, and for
    /// every car that has never reported a charge state at all.
    case none
    /// Actively charging — green with a highlight travelling ACROSS the fill
    /// (Reduce Motion → static green).
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

    /// Whether the fill carries the travelling sweep. Only an ACTIVE session
    /// moves, and only when the user has not asked for less motion — the Reduce
    /// Motion fallback is the same static green, so the state is never lost,
    /// just held still (the `PulseDot` / `mrt-gold-pulse` precedent).
    ///
    /// Name kept from MYR-333 (it is the same predicate: "is this bar in
    /// motion") so every existing call site and test reads unchanged.
    var isPulsing: Bool { charge == .charging && !reduceMotion }

    /// MYR-337 — one full traversal every 2.6s, the period the design's
    /// travelling-highlight grammar already runs at (`mrt-text-shimmer` 2.6s on
    /// the tracking header, `mrt-trace-spin` 2.6s on the ride CTA). Slow enough
    /// to read as a smooth sweep rather than a flicker on a 6pt bar.
    static let sweepPeriod: Double = 2.6

    /// MYR-337 — half-width of the highlight band, as a fraction of the FILL's
    /// width. Wide on purpose: a narrow band on a 6pt-tall bar reads as a
    /// glitch, a wide one reads as light moving across a surface.
    static let sweepHalfBand: CGFloat = 0.30

    /// MYR-337 — where the hot spot sits, in fill-relative units, at a given
    /// phase of the loop (0…1). Pure so the motion is provable in a unit test
    /// as well as in the frame diff.
    ///
    /// It starts one half-band OFF the left edge and ends one half-band off the
    /// right, so the highlight is entering at the top of every cycle and has
    /// just left at the bottom of it — the loop point is invisible, which is
    /// what makes it read as continuous travel rather than a repeating flash.
    static func sweepLocation(phase: Double) -> CGFloat {
        -sweepHalfBand + (1 + 2 * sweepHalfBand) * CGFloat(phase)
    }

    /// MYR-337 — the fill's paint at a given phase: the resting green with a
    /// near-white-green hot spot at `sweepLocation`, feathered out over one
    /// half-band on each side.
    ///
    /// This is a moving GRADIENT, not a masked band moved by `offset`. MYR-326's
    /// shimmer lesson is the reason: a masked/offset band can end up composited
    /// once and never re-rendered, which looks motionless both in stills and in
    /// reality. Recomputing the gradient's stops per frame inside
    /// `TimelineView(.animation)` is the recipe `MRTTextShimmer` already ships
    /// and the one that is provably re-rendered every frame.
    static func sweepGradient(phase: Double, base: Color) -> LinearGradient {
        let location = sweepLocation(phase: phase)
        let clamp: (CGFloat) -> CGFloat = { min(max($0, 0), 1) }
        return LinearGradient(
            stops: [
                .init(color: base, location: 0),
                .init(color: base, location: clamp(location - sweepHalfBand)),
                .init(color: .mrtBatHighSweep, location: clamp(location)),
                .init(color: base, location: clamp(location + sweepHalfBand)),
                .init(color: base, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    public var body: some View {
        HStack(spacing: 10) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.mrtElevated)
                    fill
                        .frame(width: geo.size.width * max(pct, 3) / 100)
                        // A soft glow of the resting colour while a session is
                        // live. Static (it does not animate) — it exists so the
                        // charging bar carries weight in a STILL frame too;
                        // the sweep is what says "right now". Nothing about the
                        // bar's GEOMETRY animates: the width still belongs to
                        // `pct` alone, so a charging bar never appears to grow
                        // and shrink.
                        .shadow(color: fillColor.opacity(isPulsing ? 0.5 : 0), radius: 5)
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

    /// The filled capsule. Two shapes, deliberately: the resting bar is a plain
    /// solid fill with NO `TimelineView` above it, so every non-charging call
    /// site (which is every pre-MYR-333 one) renders exactly the view tree it
    /// always did and costs nothing per frame.
    ///
    /// The loop is driven off the shared reference date rather than an
    /// `@State` start, so a bar that appears mid-session joins the sweep already
    /// in progress instead of restarting it, and one that stops charging drops
    /// straight back to the solid fill with nothing left frozen mid-fade —
    /// what the MYR-333 `@State` breathing flag needed a settle animation for.
    @ViewBuilder
    private var fill: some View {
        if isPulsing {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: Self.sweepPeriod) / Self.sweepPeriod
                Capsule().fill(Self.sweepGradient(phase: phase, base: fillColor))
            }
        } else {
            Capsule().fill(fillColor)
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
