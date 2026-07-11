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
//   • DESTINATION (end) — a regular white drop-off map pin: a round bulbous
//     head tapering to a sharp point, with a dark circular hole punched in the
//     head. The tip itself is the ground contact (no separate ground marker —
//     that read as a rocket nozzle). No square.
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

    // MARK: Destination — regular drop-off pin

    private var destination: some View {
        Teardrop()
            .fill(Color.mrtText)
            .overlay(alignment: .top) {
                // Dark circular hole punched in the round head.
                Circle()
                    .fill(Color.mrtBg)
                    .frame(width: headSize * 0.42, height: headSize * 0.42)
                    // Centered on the head (head center is headSize/2 down).
                    .padding(.top, headSize * 0.29)
            }
            // Round head (diameter = headSize) tapering to a point below; the
            // tip is the frame's bottom edge, so `.bottom` anchoring plants it
            // on the coordinate — no separate ground marker (that read as a
            // rocket nozzle).
            .frame(width: headSize, height: headSize * 1.4)
    }
}

/// A classic map-pin silhouette: a round bulbous head tapering to a sharp point
/// at the bottom (the tip lands on the coordinate under `.bottom` anchoring).
struct Teardrop: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let cx = rect.minX + w * 0.5
        let r = w * 0.5              // head radius = half the width → circular head
        let cy = rect.minY + r       // head center
        let tip = CGPoint(x: cx, y: rect.maxY)
        var path = Path()
        // Two symmetric cubics: a near-circular head at the top drawing in to a
        // sharp point at the tip. The 1.33·r horizontal control offset makes the
        // upper head read as a true circle.
        path.move(to: tip)
        path.addCurve(
            to: CGPoint(x: cx, y: rect.minY),
            control1: CGPoint(x: cx - r * 1.33, y: cy + r * 0.55),
            control2: CGPoint(x: cx - r * 1.33, y: cy - r * 0.95)
        )
        path.addCurve(
            to: tip,
            control1: CGPoint(x: cx + r * 1.33, y: cy - r * 0.95),
            control2: CGPoint(x: cx + r * 1.33, y: cy + r * 0.55)
        )
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
