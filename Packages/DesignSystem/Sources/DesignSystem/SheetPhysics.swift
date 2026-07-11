import CoreGraphics

// MARK: - SheetPhysics — pure drag math for draggable sheets (MYR-236)
//
// The fluid-drag deliverable is MOTION, so the decision math is factored out
// of the SwiftUI view into pure, table-testable functions here (no `View`, no
// gesture types — just numbers). `MRTDetentSheet` and the ride-request
// dismiss handle both route their release/overscroll decisions through this
// one place so every draggable-sheet consumer inherits identical physics (no
// per-screen forks, CLAUDE.md "Reuse, don't fork").
//
// Convention: everything is in **height space** — a larger value = a taller
// sheet, so dragging UP is positive. Callers convert a `DragGesture`'s
// downward-positive translation/velocity with a leading minus before handing
// values in.
//
// Every function is `.isFinite`-guarded (MYR-227 standing rule: never let a
// NaN/∞ reach layout). A non-finite input collapses to a safe finite result
// rather than propagating.
public enum SheetPhysics {

    // MARK: Rubber-banding

    /// Logarithmic overscroll resistance past a `[lowerBound, upperBound]`
    /// detent range. Inside the range the value passes through unchanged (1:1);
    /// beyond it the excess is compressed so it *asymptotically* approaches
    /// `dimension` extra points — a soft wall, never a hard stop. This is the
    /// classic UIScrollView rubber-band curve
    /// `d · (1 − 1/(x·c/d + 1))`, bounded by `dimension`.
    ///
    /// - Parameters:
    ///   - value: proposed height.
    ///   - lowerBound: shortest detent height (e.g. peek).
    ///   - upperBound: tallest detent height (e.g. half).
    ///   - dimension: max overscroll past a bound, in points. Default 30 —
    ///     the prototype's `Math.max(peekH-30, Math.min(halfH+30, …))` band
    ///     (components.jsx:514), reused here as the resistance ceiling.
    ///   - coefficient: initial stiffness (0…1); lower = firmer. Default 0.55,
    ///     UIKit's constant.
    public static func rubberBand(
        _ value: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat,
        dimension: CGFloat = 30,
        coefficient: CGFloat = 0.55
    ) -> CGFloat {
        // Guard non-finite inputs (MYR-227): fall back to the nearer bound.
        guard value.isFinite else { return lowerBound.isFinite ? lowerBound : 0 }
        let lo = lowerBound.isFinite ? lowerBound : 0
        let hi = upperBound.isFinite ? upperBound : lo
        // Degenerate range: nothing to band against.
        guard hi >= lo else { return value }
        let d = max(dimension, 0)
        let c = max(coefficient, 0.0001)

        if value > hi {
            return hi + resist(value - hi, dimension: d, coefficient: c)
        } else if value < lo {
            return lo - resist(lo - value, dimension: d, coefficient: c)
        }
        return value
    }

    /// One-sided resistance curve, `x ≥ 0 → [0, dimension)`. Monotonic,
    /// starts with slope `coefficient`, saturates at `dimension`.
    private static func resist(_ x: CGFloat, dimension d: CGFloat, coefficient c: CGFloat) -> CGFloat {
        guard x > 0, d > 0 else { return 0 }
        return d * (1 - 1 / (x * c / d + 1))
    }

    // MARK: Velocity projection

    /// Projects how much farther a flick would coast from its release velocity
    /// — the UIScrollView deceleration model
    /// `(v/1000) · rate/(1 − rate)`. Feeding the release velocity in lets a
    /// fast flick change detents even when the finger barely moved
    /// (requirement 3).
    ///
    /// - Parameters:
    ///   - velocity: release velocity in **points per second**, height-space
    ///     (up = positive).
    ///   - decelerationRate: per-ms retention. Default 0.998 (UIKit "normal").
    /// - Returns: projected additional travel in points (same sign as
    ///   `velocity`).
    public static func projection(
        velocity: CGFloat,
        decelerationRate: CGFloat = 0.998
    ) -> CGFloat {
        guard velocity.isFinite else { return 0 }
        let rate = min(max(decelerationRate, 0), 0.9999)
        return (velocity / 1000) * rate / (1 - rate)
    }

    // MARK: Nearest-detent selection

    /// Picks the detent whose height is nearest `projectedHeight`. Callers pass
    /// the *velocity-projected* endpoint, not the raw release point, so a flick
    /// commits to the detent it was thrown toward.
    ///
    /// Ties (exactly the midpoint) resolve to `.peek` — bias toward the
    /// resting/collapsed state, matching the prototype's `> mid` test
    /// (components.jsx:522, strictly-greater ⇒ midpoint stays peek).
    public static func nearestDetent(
        toProjectedHeight projectedHeight: CGFloat,
        peekHeight: CGFloat,
        halfHeight: CGFloat
    ) -> MRTSheetDetent {
        guard projectedHeight.isFinite else { return .peek }
        let peek = peekHeight.isFinite ? peekHeight : 0
        let half = halfHeight.isFinite ? halfHeight : peek
        let midpoint = (peek + half) / 2
        return projectedHeight > midpoint ? .half : .peek
    }
}
