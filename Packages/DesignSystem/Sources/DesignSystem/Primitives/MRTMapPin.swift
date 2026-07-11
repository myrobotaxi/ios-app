import SwiftUI

// MARK: - MRTMapPin (MYR-234 — pickup / destination map markers)
//
// Proper, recognizable pickup and destination pins for the live tracking map,
// replacing the two look-alike `MRTEndpointDot`s that the client couldn't tell
// apart from the blue user-location dot or the gold car glyph (Thomas, QA
// 2026-07-11: "I want the pins to be a proper pick up pin and the destination
// being a proper destination pin").
//
// The two kinds carry the trip-card's ○ / □ language (the pickup→destination
// connector rail in `RideRequestSearchContent.routeRail`): the PICKUP head is a
// circle (○), the DESTINATION head is a square (□). Both are the sacred gold
// accent — markers are gold (CLAUDE.md tokens rule) — so a single hue keeps
// them on-brand while the head SHAPE + a dark inner glyph make them read apart
// at a glance, and the planted STEM distinguishes them from the flat blue user
// dot and the (stem-less, car-silhouette, pulsing) tracking car marker.
//
// A "lollipop" silhouette — a gold head on a tapered stem ending in a small
// contact dot — plants the marker at its coordinate. Render inside a MapKit
// `Annotation(anchor: .bottom)` so the contact dot sits exactly on the
// coordinate (the head floats above it), like a real dropped pin.
public struct MRTMapPin: View {
    public enum Kind: Equatable {
        /// Pickup — a circular (○) gold head, matching the trip-card pickup glyph.
        case pickup
        /// Destination — a square (□) gold head, matching the trip-card drop-off glyph.
        case destination
    }

    private let kind: Kind
    private let headSize: CGFloat

    public init(kind: Kind, headSize: CGFloat = 26) {
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
        VStack(spacing: 0) {
            head
            // Tapered stem + contact dot plant the pin on its coordinate.
            stem
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: Head

    @ViewBuilder
    private var head: some View {
        ZStack {
            switch kind {
            case .pickup:
                // ○ — circular head with a dark bullseye center.
                Circle()
                    .fill(Color.mrtGold)
                    .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1.5))
                    .overlay(
                        Circle()
                            .fill(Color.mrtBg)
                            .frame(width: headSize * 0.34, height: headSize * 0.34)
                    )
                    .frame(width: headSize, height: headSize)
            case .destination:
                // □ — square head with a dark square center.
                let corner = headSize * 0.24
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Color.mrtGold)
                    .overlay(
                        RoundedRectangle(cornerRadius: corner, style: .continuous)
                            .strokeBorder(Color.mrtText, lineWidth: 1.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: corner * 0.5, style: .continuous)
                            .fill(Color.mrtBg)
                            .frame(width: headSize * 0.34, height: headSize * 0.34)
                    )
                    .frame(width: headSize, height: headSize)
            }
        }
        // Same gold glow family as the tracking car marker, so pins + car read
        // as one map-marker system.
        .shadow(color: .mrtGold, radius: 4)
        .shadow(color: .mrtGoldGlow, radius: 9)
    }

    // MARK: Stem

    private var stem: some View {
        VStack(spacing: 0) {
            // A short tapered neck from the head down to the contact dot.
            Trapezoid()
                .fill(Color.mrtGold)
                .overlay(Trapezoid().stroke(Color.mrtText, lineWidth: 1))
                .frame(width: headSize * 0.30, height: headSize * 0.34)
            Circle()
                .fill(Color.mrtGold)
                .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1))
                .frame(width: headSize * 0.22, height: headSize * 0.22)
        }
    }
}

/// A downward-tapering neck (wide at top, narrow at bottom) joining a pin head
/// to its contact dot.
private struct Trapezoid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * 0.34
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
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
