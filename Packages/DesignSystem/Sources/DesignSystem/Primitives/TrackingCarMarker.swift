import SwiftUI

// MARK: - Heading math (MYR-177 — shortest-arc rotation, pure + unit-tested)
//
// `VehicleState.heading` is degrees CLOCKWISE from north (0 = N, 90 = E),
// map-relative. Rotating a marker straight to a new heading with `withAnimation`
// would take the LONG way around the compass when the value wraps (359° → 1°
// spins 358° backwards). `unwrapped(from:to:)` returns a CONTINUOUS angle
// (never re-wrapped to 0…360) that is the shortest arc from the currently
// displayed angle, so the marker always turns the short way. Reduce Motion
// callers snap to it without animating.
public enum HeadingMath {
    /// The signed shortest angular delta (−180, 180] to rotate from `current`
    /// to `target` (both in degrees). 359 → 1 gives +2, not −358.
    public static func shortestDelta(from current: Double, to target: Double) -> Double {
        guard current.isFinite, target.isFinite else { return 0 }
        let raw = (target - current).truncatingRemainder(dividingBy: 360)
        if raw <= -180 { return raw + 360 }
        if raw > 180 { return raw - 360 }
        return raw
    }

    /// A continuous angle equal to `current + shortestDelta(current, target)` —
    /// feed this to `.rotationEffect` so the interpolation is the short way
    /// around. The displayed value is kept unwrapped across calls (it may grow
    /// past 360 / below 0), which is exactly what makes SwiftUI animate the arc.
    public static func unwrapped(from current: Double, to target: Double) -> Double {
        guard current.isFinite else { return target.isFinite ? target : 0 }
        return current + shortestDelta(from: current, to: target)
    }

    /// Screen-space rotation for a map-relative heading under a (possibly
    /// rotated) camera: the marker must render at `heading − cameraHeading` so a
    /// north-relative bearing stays correct even when the map itself is turned.
    /// With a north-up camera (`cameraHeading == 0`, the tracking map's only
    /// mode today) this is just `heading`.
    public static func mapRelative(heading: Double, cameraHeading: Double) -> Double {
        let h = heading.isFinite ? heading : 0
        let c = cameraHeading.isFinite ? cameraHeading : 0
        return h - c
    }
}

// MARK: - Top-down car glyph (MYR-177)
//
// A clean overhead car silhouette pointing "up" (north) at heading 0 — the
// Uber-style marker the client asked to replace the plain gold dot on the live
// tracking map. Drawn in the design system's language (gold body, white
// hairline, soft gold glow — the same tokens `VehicleMarker` uses; NO new hex),
// so it reads as one family with the heading-arrow marker on the other maps.
struct TopDownCarShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Normalized car body in a unit box, nose toward the top (−y).
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        // Rounded capsule-ish body with a tapered nose and squared tail — an
        // instantly-legible top-down car. Coordinates tuned for a 0…1 box.
        path.move(to: p(0.50, 0.02))
        path.addCurve(to: p(0.82, 0.24), control1: p(0.68, 0.02), control2: p(0.82, 0.10)) // nose → right shoulder
        path.addLine(to: p(0.84, 0.74))                                                     // right flank
        path.addCurve(to: p(0.70, 0.98), control1: p(0.84, 0.90), control2: p(0.80, 0.98)) // right rear corner
        path.addLine(to: p(0.30, 0.98))                                                     // tail
        path.addCurve(to: p(0.16, 0.74), control1: p(0.20, 0.98), control2: p(0.16, 0.90)) // left rear corner
        path.addLine(to: p(0.18, 0.24))                                                     // left flank
        path.addCurve(to: p(0.50, 0.02), control1: p(0.18, 0.10), control2: p(0.32, 0.02)) // → nose
        path.closeSubpath()
        return path
    }
}

/// Windshield strip near the nose — a subtle dark inset that gives the glyph a
/// clear "front", so its orientation reads at a glance.
struct CarWindshieldShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * w, y: rect.minY + y * h) }
        var path = Path()
        path.move(to: p(0.30, 0.30))
        path.addCurve(to: p(0.70, 0.30), control1: p(0.42, 0.22), control2: p(0.58, 0.22))
        path.addLine(to: p(0.64, 0.44))
        path.addLine(to: p(0.36, 0.44))
        path.closeSubpath()
        return path
    }
}

/// The live-tracking vehicle marker (MYR-177): a top-down car glyph rotated to
/// the vehicle's real heading, with a soft pulse ring behind it. Rotation is
/// smoothly interpolated the SHORT way around the compass between fixes;
/// Reduce Motion snaps instead of spinning. `heading` is the map-relative
/// screen rotation the caller has already resolved (see `HeadingMath.mapRelative`).
public struct TrackingCarMarker: View {
    private let heading: Double
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedHeading: Double
    @State private var pulsing = false

    public init(heading: Double = 0, size: CGFloat = 30) {
        let safe = heading.isFinite ? heading : 0
        self.heading = safe
        self.size = size
        _displayedHeading = State(initialValue: safe)
    }

    public var body: some View {
        ZStack {
            // Soft pulse ring — the same "vehicle in motion" language as
            // `VehicleMarker`. Reduce Motion → the static resting glow.
            if reduceMotion {
                Circle().fill(Color.mrtGold).opacity(0.18)
                    .frame(width: size * 1.9, height: size * 1.9)
            } else {
                Circle().fill(Color.mrtGold)
                    .frame(width: size * 1.9, height: size * 1.9)
                    .scaleEffect(pulsing ? 2.0 : 0.7)
                    .opacity(pulsing ? 0 : 0.55)
            }
            // The car glyph, rotated to heading (short-arc interpolated).
            ZStack {
                TopDownCarShape()
                    .fill(Color.mrtGold)
                    .overlay(TopDownCarShape().stroke(Color.mrtText, lineWidth: 1.5))
                    .overlay(CarWindshieldShape().fill(Color.mrtBg.opacity(0.55)))
                    .frame(width: size * 0.62, height: size)
                    .shadow(color: .mrtGold, radius: 5)
                    .shadow(color: .mrtGoldGlow, radius: 11)
            }
            .rotationEffect(.degrees(displayedHeading))
        }
        .frame(width: 44, height: 44)
        .onChange(of: heading) { _, newValue in
            let target = HeadingMath.unwrapped(from: displayedHeading, to: newValue)
            if reduceMotion {
                displayedHeading = target
            } else {
                // Ambient GPS/heading refresh cadence — a calm turn, not a snap.
                withAnimation(.easeInOut(duration: 0.45)) { displayedHeading = target }
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { pulsing = true }
        }
    }
}
