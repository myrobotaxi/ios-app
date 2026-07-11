import SwiftUI

// MARK: - MRTMapPin (MYR-235 — slim Tesla-style pickup / destination markers)
//
// Slim, elegant map markers for the live tracking map, replacing the MYR-234
// "fat" gold heads (circle/square on a tapered gold stem with a heavy gold glow
// plate) the client rejected (Thomas, 2026-07-11: "I don't like the fat pins
// you are using … the difference between start and end pins"). The reference is
// the Tesla ride map's two-pin language:
//
//   • PICKUP (start) — a slim "donut lollipop": a small monochrome-white RING
//     head (white disc with a dark punched center) floating on a thin hairline
//     white stem, planted at the coordinate by a small GOLD contact dot ringed
//     in white. (Tesla's contact dot was route-blue; our route accent is the
//     sacred gold, so the contact dot is gold — CLAUDE.md tokens rule.)
//   • DESTINATION (end) — a classic white TEARDROP map pin (rounded head
//     tapering to a point) with a dark circular hole punched in the head and a
//     small white donut at the ground contact just at the tip. No square.
//
// The heads are monochrome white with dark cutouts (NOT gold), which reads them
// apart from the gold car glyph (`TrackingCarMarker`) and the blue user dot at a
// glance; a single subtle scrim shadow — NOT the old glow plate — lifts them off
// the dark Flat map. Every color is an existing DesignSystem token: white heads
// = `mrtText`, dark cutouts = `mrtBg`, pickup contact = `mrtGold`.
//
// Render inside a MapKit `Annotation(anchor: .bottom)`: the pin's bottom-most
// element (the pickup contact dot / the teardrop's ground donut) sits on the
// coordinate, so the marker plants exactly at its point (MYR-213 glyph=coordinate
// rule).
public struct MRTMapPin: View {
    public enum Kind: Equatable {
        /// Pickup — a slim white donut-lollipop with a gold contact dot.
        case pickup
        /// Destination — a classic white teardrop map pin.
        case destination
    }

    private let kind: Kind
    /// Head diameter (pickup ring / teardrop head width). Slim by design — the
    /// whole pin is a fraction of the MYR-234 marker's footprint.
    private let headSize: CGFloat

    public init(kind: Kind, headSize: CGFloat = 15) {
        self.kind = kind
        self.headSize = headSize
    }

    private var accessibilityLabel: String {
        switch kind {
        case .pickup: return "Pickup"
        case .destination: return "Destination"
        }
    }

    public var body: some View {
        Group {
            switch kind {
            case .pickup: pickup
            case .destination: destination
            }
        }
        // A single subtle scrim shadow lifts the white heads off the dark map —
        // the old heavy gold glow plate (MYR-234) is gone.
        .shadow(color: .mrtScrim, radius: 2.5, y: 1)
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Pickup — donut lollipop

    private var pickup: some View {
        VStack(spacing: 0) {
            // Skinny ring head: a thin white ring with a dark punched center
            // (donut) — a wide hole keeps the white a slim ring, not a disc.
            Circle()
                .fill(Color.mrtText)
                .overlay(
                    Circle()
                        .fill(Color.mrtBg)
                        .frame(width: headSize * 0.58, height: headSize * 0.58)
                )
                .frame(width: headSize, height: headSize)
            // Thin hairline white stem.
            Capsule()
                .fill(Color.mrtText)
                .frame(width: 2, height: headSize * 1.05)
            // Ground contact: small gold filled dot ringed in white, planted on
            // the coordinate.
            Circle()
                .fill(Color.mrtGold)
                .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1.5))
                .frame(width: headSize * 0.5, height: headSize * 0.5)
        }
    }

    // MARK: Destination — teardrop

    private var destination: some View {
        let headHeight = headSize * 1.5
        return VStack(spacing: 0) {
            Teardrop()
                .fill(Color.mrtText)
                .overlay(alignment: .top) {
                    // Dark circular hole punched in the head.
                    Circle()
                        .fill(Color.mrtBg)
                        .frame(width: headSize * 0.42, height: headSize * 0.42)
                        // Center the hole on the teardrop head (≈0.32 down).
                        .padding(.top, headHeight * 0.32 - headSize * 0.21)
                }
                .frame(width: headSize, height: headHeight)
            // Ground donut: small white ring at the tip / ground contact.
            Circle()
                .strokeBorder(Color.mrtText, lineWidth: 1.6)
                .background(Circle().fill(Color.mrtBg))
                .frame(width: headSize * 0.42, height: headSize * 0.42)
                // Nestle the ring up so the teardrop tip meets its center.
                .padding(.top, -headSize * 0.21)
        }
    }
}

/// A classic map-pin teardrop: a rounded head tapering to a point at the bottom
/// (the tip lands on the coordinate under `.bottom` anchoring).
struct Teardrop: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * w, y: rect.minY + y * h)
        }
        var path = Path()
        // Tip at the bottom center; two symmetric cubics bulge out to a round
        // head and meet in a rounded point at the top.
        path.move(to: p(0.5, 1.0))
        path.addCurve(to: p(0.5, 0.0), control1: p(0.02, 0.72), control2: p(0.02, 0.10))
        path.addCurve(to: p(0.5, 1.0), control1: p(0.98, 0.10), control2: p(0.98, 0.72))
        path.closeSubpath()
        return path
    }
}

#if DEBUG
#Preview("Map pins") {
    HStack(spacing: 40) {
        MRTMapPin(kind: .pickup)
        MRTMapPin(kind: .destination)
    }
    .padding(60)
    .background(Color.mrtBg)
}
#endif
