import SwiftUI

// MARK: - Brand marks
//
// Verbatim port of `HexLogo`, `ArrowMark`, and `Wordmark` from the design
// project's `app/components.jsx`. Geometry, colors, and shadows match the
// prototype's SVG/CSS. CSS box-shadow / drop-shadow blur radii are halved
// for SwiftUI's `.shadow(radius:)` (Gaussian sigma vs. CSS 2-sigma blur).

/// One facet of the brand arrow — a polygon in the prototype's 100×100
/// SVG viewBox, scaled into the shape's rect.
struct ArrowFacetShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.minX + p.x / 100 * rect.width,
                y: rect.minY + p.y / 100 * rect.height
            )
        }
        path.move(to: map(first))
        for point in points.dropFirst() { path.addLine(to: map(point)) }
        path.closeSubpath()
        return path
    }
}

/// The two-tone facet arrow, rotated -22° like the jsx `rotate(-22 50 50)`.
struct ArrowGlyph: View {
    var body: some View {
        ZStack {
            // <polygon points="50,12 50,64 18,85" fill="#E4D08A" />
            ArrowFacetShape(points: [
                CGPoint(x: 50, y: 12), CGPoint(x: 50, y: 64), CGPoint(x: 18, y: 85),
            ])
            .fill(Color.mrtArrowFacetLight)
            // <polygon points="50,12 82,85 50,64" fill="#9C7E2C" />
            ArrowFacetShape(points: [
                CGPoint(x: 50, y: 12), CGPoint(x: 82, y: 85), CGPoint(x: 50, y: 64),
            ])
            .fill(Color.mrtArrowFacetDark)
        }
        .rotationEffect(.degrees(-22))
    }
}

/// Bare brand symbol — arrow only, no tile (tight / inverted contexts).
public struct ArrowMark: View {
    private let size: CGFloat
    private let glow: Bool

    public init(size: CGFloat = 32, glow: Bool = false) {
        self.size = size
        self.glow = glow
    }

    public var body: some View {
        ArrowGlyph()
            .frame(width: size, height: size)
            // drop-shadow(0 0 {size*0.18}px goldGlow6)
            .shadow(color: glow ? .mrtGoldGlow : .clear, radius: glow ? size * 0.09 : 0)
    }
}

/// Brand mark — flat two-tone gold facet arrow on a matte near-black tile
/// with a radial gold sheen. (Name kept as `HexLogo` so call sites match the
/// prototype source.)
public struct HexLogo: View {
    private let size: CGFloat
    private let glow: Bool

    public init(size: CGFloat = 32, glow: Bool = false) {
        self.size = size
        self.glow = glow
    }

    // CSS `linear-gradient(155deg, …)`: 0deg points up, angles run clockwise.
    // dx = sin(155°)/2 ≈ 0.2113, dy = -cos(155°)/2 ≈ 0.4532.
    static let tileGradientStart = UnitPoint(x: 0.5 - 0.2113, y: 0.5 - 0.4532)
    static let tileGradientEnd = UnitPoint(x: 0.5 + 0.2113, y: 0.5 + 0.4532)

    public var body: some View {
        ZStack {
            // linear-gradient(155deg, #1b1407 0%, #0d0b06 55%, #090806 100%)
            LinearGradient(
                stops: [
                    .init(color: .mrtLogoTileTop, location: 0),
                    .init(color: .mrtLogoTileMid, location: 0.55),
                    .init(color: .mrtLogoTileBottom, location: 1),
                ],
                startPoint: Self.tileGradientStart,
                endPoint: Self.tileGradientEnd
            )
            // radial-gradient(95% 80% at 32% 2%, rgba(201,168,76,0.16), transparent 60%)
            // (95%/80% ellipse approximated by the elliptical gradient's frame fit)
            EllipticalGradient(
                stops: [
                    .init(color: Color.mrtGold.opacity(0.16), location: 0),
                    .init(color: Color.mrtGold.opacity(0), location: 0.6),
                ],
                center: UnitPoint(x: 0.32, y: 0.02),
                startRadiusFraction: 0,
                endRadiusFraction: 0.95
            )
            if glow {
                // radial-gradient(circle, rgba(201,168,76,0.28), transparent 62%)
                Circle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: Color.mrtGold.opacity(0.28), location: 0),
                            .init(color: Color.mrtGold.opacity(0), location: 0.62),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.92 * 0.7071 // CSS farthest-corner radius
                    ))
                    .frame(width: size * 0.92, height: size * 0.92)
            }
            ArrowGlyph()
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225))
        // inset 0 0 0 0.5px rgba(255,255,255,0.07)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.225)
                .strokeBorder(Color.mrtText.opacity(0.07), lineWidth: MRTMetrics.hairline)
        )
        // 0 {size*0.04}px {size*0.12}px rgba(0,0,0,0.5)
        .shadow(color: .black.opacity(0.5), radius: size * 0.06, x: 0, y: size * 0.04)
    }
}

/// Brand wordmark — "myrobotaxi", uppercase, weight 500, tracking size×0.04.
/// The jsx uses Roboto; per the documented Inter→SF Pro deviation the native
/// app uses the system font.
public struct Wordmark: View {
    private let size: CGFloat
    private let color: Color?
    private let withLogo: Bool

    public init(size: CGFloat = 24, color: Color? = nil, withLogo: Bool = false) {
        self.size = size
        self.color = color
        self.withLogo = withLogo
    }

    public var body: some View {
        HStack(spacing: size * 0.5) {
            if withLogo { HexLogo(size: size * 1.25) }
            Text("myrobotaxi")
                .font(.system(size: size, weight: .medium))
                .tracking(size * 0.04)
                .textCase(.uppercase)
                .foregroundStyle(color ?? Color.mrtText)
        }
    }
}
