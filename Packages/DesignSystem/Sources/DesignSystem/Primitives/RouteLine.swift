import SwiftUI

// MARK: - RouteLine (components.jsx) — two-tone gold route polyline
//
// SwiftUI implementation for vignettes/previews. For real MapKit overlays,
// map it 1:1 to MKPolylineRenderer (screen agents own that wiring):
//
//   • Full path      → MKPolylineRenderer(polyline: fullRoute) with
//     strokeColor = UIColor(Color.mrtGold).withAlphaComponent(0.30),
//     lineWidth = 4, lineCap = .round, lineJoin = .round.
//   • Travelled part → a second MKPolyline containing the coordinates up to
//     `progress` × total length (interpolate the cut point along cumulative
//     point-to-point distances — the same length-fraction split as the jsx
//     stroke-dasharray), rendered at alpha 0.95, same width/caps/joins.
//   • Glow           → CSS drop-shadow(0 0 4px goldGlow6): in an
//     MKPolylineRenderer subclass set
//     `context.setShadow(offset: .zero, blur: 4, color:
//     UIColor(Color.mrtGoldGlow).cgColor)` before stroking, or draw a third,
//     wider underlay polyline (lineWidth ≈ 10, gold at ~0.25) beneath the
//     travelled segment.

/// Open polyline through `points`, given in the view's local coordinates.
public struct RoutePolylineShape: Shape {
    public var points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

public struct RouteLine: View {
    private let points: [CGPoint]
    private let progress: Double
    private let lineWidth: CGFloat
    private let glow: Bool

    public init(points: [CGPoint], progress: Double = 0.4, lineWidth: CGFloat = 4, glow: Bool = true) {
        self.points = points
        self.progress = progress
        self.lineWidth = lineWidth
        self.glow = glow
    }

    public var body: some View {
        let shape = RoutePolylineShape(points: points)
        let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        ZStack {
            // Full path at 30% opacity
            shape.stroke(Color.mrtGold.opacity(0.3), style: style)
            // Travelled portion at 95% + glow. `.trim` splits by fractional
            // path length — the same cut as the jsx stroke-dasharray.
            shape
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(Color.mrtGold.opacity(0.95), style: style)
                // drop-shadow(0 0 4px goldGlow6)
                .shadow(color: glow ? .mrtGoldGlow : .clear, radius: glow ? 2 : 0)
        }
    }
}
