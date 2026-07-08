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
