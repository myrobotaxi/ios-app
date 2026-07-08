import SwiftUI

// MARK: - Text shimmer (MYR-171, `mrt-text-shimmer` — design/app/
// ride-request.jsx:1494-1497, applied at 2.6s on the Tracking "Arriving"
// header (ride-request.jsx:848) and 3.6s on the Ride Summary greeting
// (ride-request.jsx:951))
//
// A bright highlight band sweeps left→right across gold text on a linear
// loop — CSS masks a moving gradient across the text; ported here as a
// gradient `foregroundStyle` whose highlight stop position advances with
// `TimelineView(.animation)`, the same recipe `MRTTraceBorder` already uses
// for its conic sweep. Not gated by `prefers-reduced-motion` in the jsx
// source (see MYR-171 research notes) — CLAUDE.md's blanket "Honor Reduce
// Motion" rule still applies, so Reduce Motion here renders the resting gold
// color with no sweep, consistent with every other MYR-171/162 motion in
// this package.
public struct MRTTextShimmer: ViewModifier {
    private let duration: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(duration: Double = 2.6) {
        self.duration = duration
    }

    public func body(content: Content) -> some View {
        if reduceMotion {
            content.foregroundStyle(Color.mrtGold)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                let phase = (t.truncatingRemainder(dividingBy: duration)) / duration
                content.foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: .mrtGold, location: 0),
                            .init(color: .mrtGold, location: max(0, phase - 0.22)),
                            .init(color: .mrtGoldTraceBright, location: phase),
                            .init(color: .mrtGold, location: min(1, phase + 0.22)),
                            .init(color: .mrtGold, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            }
        }
    }
}

public extension View {
    /// `mrt-text-shimmer` — see `MRTTextShimmer`.
    func mrtTextShimmer(duration: Double = 2.6) -> some View {
        modifier(MRTTextShimmer(duration: duration))
    }
}

// MARK: - Diagonal shimmer band (MYR-165, `mrtShimmer` — design/app/
// onboarding.jsx:222,282, applied at 2.8s ease-in-out infinite on the Add
// Tesla virtual-key card)
//
// A 46%-wide highlight band, skewed -12°, sweeping translateX -160%→280%
// (arriving at 55%, holding to 100%) — a diagonal "catching the light" sweep
// distinct from `MRTTextShimmer`'s left-right text-gradient recipe above.
// First built for `AddTeslaFlow`'s `VirtualKeyCard` (MYR-165); MYR-199 lifts
// it here so the tracking flow's "LOOK FOR" plate chip (Handoff §8, same
// diagonal-sweep treatment as the jsx's `mrt-plate-shine`) reuses this
// implementation rather than re-writing it (CLAUDE.md "Reuse, don't fork").
/// Overlay this on any card/chip to sweep a soft diagonal highlight across
/// it on a loop. Reduce Motion → renders nothing (static base content only).
public struct MRTShimmerBand: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private let period: Double

    public init(period: Double = 2.8) {
        self.period = period
    }

    private static let skew = CGFloat(tan(-12 * Double.pi / 180))

    public var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                let bandWidth = proxy.size.width * 0.46
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSince(start)
                        .truncatingRemainder(dividingBy: period) / period
                    let progress = UnitCurve.easeInOut.value(at: min(phase / 0.55, 1))
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0), location: 0),
                            .init(color: .white.opacity(0.16), location: 0.5),
                            .init(color: .white.opacity(0), location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: bandWidth)
                    .transformEffect(CGAffineTransform(a: 1, b: 0, c: Self.skew, d: 1, tx: 0, ty: 0))
                    .offset(x: (-1.6 + 4.4 * progress) * bandWidth)
                }
            }
            .allowsHitTesting(false)
        }
    }
}
