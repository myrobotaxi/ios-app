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

// MARK: - Sample route fixture (screens.jsx:45-49 `buildSampleRoute()`)

/// The prototype's fixed demo route — 12 points in a 402×600 map-space,
/// reused by several screens/vignettes (screens.jsx `buildSampleRoute()`,
/// used by the story-deck vignettes `VigLiveMap`/`VigTrack`, tutorials.jsx).
public enum MRTSampleRoute {
    public static let points: [CGPoint] = [
        CGPoint(x: 34, y: 92), CGPoint(x: 62, y: 130), CGPoint(x: 88, y: 170),
        CGPoint(x: 120, y: 196), CGPoint(x: 150, y: 234), CGPoint(x: 184, y: 268),
        CGPoint(x: 212, y: 304), CGPoint(x: 240, y: 348), CGPoint(x: 262, y: 388),
        CGPoint(x: 288, y: 426), CGPoint(x: 322, y: 462), CGPoint(x: 358, y: 498),
    ]

    /// The route's native coordinate space — the jsx's SVG `viewBox="0 0 402 600"`.
    public static let sourceSize = CGSize(width: 402, height: 600)

    /// Maps `points` into a `target` frame the way the jsx's map-vignette SVG
    /// does (`preserveAspectRatio="xMidYMid slice"`, tutorials.jsx:27,186):
    /// uniform scale to **cover** the target, then center-crop.
    public static func sliced(into target: CGSize) -> [CGPoint] {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return points }
        let scale = max(target.width / sourceSize.width, target.height / sourceSize.height)
        let scaledSize = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        let dx = (target.width - scaledSize.width) / 2
        let dy = (target.height - scaledSize.height) / 2
        return points.map { CGPoint(x: $0.x * scale + dx, y: $0.y * scale + dy) }
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

// MARK: - Endpoint dot (components.jsx `EndpointDot`, components.jsx:482-489)

/// Route-endpoint marker — soft outer halo (r = size×0.9, 30% opacity) behind
/// a solid dot with a light ring. Used for both the real MapKit `Annotation`
/// on the Live Map (MYR-167) and the static hero-map route on Drive Summary
/// (MYR-169) — promoted here so both screens share one implementation
/// (CLAUDE.md "Reuse, don't fork").
public struct MRTEndpointDot: View {
    private let color: Color
    private let size: CGFloat

    public init(color: Color, size: CGFloat) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .opacity(0.3)
                .frame(width: size * 1.8, height: size * 1.8) // r = size * 0.9
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1.5))
        }
        .accessibilityHidden(true)
    }
}
