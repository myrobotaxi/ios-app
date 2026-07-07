import SwiftUI

// MARK: - MapBackground (components.jsx:305-397) — dark stylized map backdrop
//
// Deterministic seeded port of the prototype's generated SVG map: land base,
// park ellipses, a rotated street grid, one sweeping freeway, and an
// ocean/coastline shape, topped with a radial vignette. Used as the static
// (non-MapKit) backdrop behind the StoryDeck live-map vignettes
// (`VigLiveMap`/`VigTrack`, tutorials.jsx) — CLAUDE.md is explicit that
// vignette map backdrops must be small static stylized views, not MapKit.
// For the real MapKit-backed Live Map screen (a later issue), this view is
// not reused — swap for `MKMapView` there.
public struct MapBackground: View {
    private let width: CGFloat
    private let height: CGFloat
    private let seed: Int

    public init(width: CGFloat = 402, height: CGFloat = 600, seed: Int = 42) {
        self.width = width
        self.height = height
        self.seed = seed
    }

    public var body: some View {
        let model = MapBackgroundModel(width: width, height: height, seed: seed)
        ZStack {
            Canvas { context, _ in
                context.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(.mrtMapLand))

                for park in model.parks {
                    context.fill(park, with: .color(.mrtMapPark))
                }

                for d in model.streets { context.stroke(d, with: .color(.mrtMapStreet), lineWidth: 1.4) }
                for d in model.avenues { context.stroke(d, with: .color(.mrtMapStreet), lineWidth: 1.4) }
                for d in model.collectors {
                    context.stroke(d, with: .color(.mrtMapCollectorCasing), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                }
                for d in model.collectors {
                    context.stroke(d, with: .color(.mrtMapCollectorFill), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                }

                context.stroke(model.freeway, with: .color(.mrtMapFreewayCasing), style: StrokeStyle(lineWidth: 6.5, lineCap: .round))
                context.stroke(model.freeway, with: .color(.mrtMapFreewayFill), style: StrokeStyle(lineWidth: 3, lineCap: .round))

                context.fill(model.water, with: .color(.mrtMapWater))
                context.stroke(model.coastLine, with: .color(.mrtMapCoast), lineWidth: 2)
            }

            // Labels — SwiftUI Text over the Canvas (components.jsx:389-391).
            Text("Pacific Ocean")
                .font(.system(size: 11, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(Color.mrtMapLabelOcean)
                .fixedSize()
                .rotationEffect(.degrees(-26))
                .position(x: width * 0.72, y: height * 0.80)
            Text("PESCADERO PARK")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.mrtMapLabelPark)
                .fixedSize()
                .position(x: width * 0.62, y: height * 0.22)
            Text("Cabrillo Hwy")
                .font(.system(size: 8.5, weight: .medium))
                .tracking(0.5)
                .foregroundStyle(Color.mrtMapLabelStreet)
                .fixedSize()
                .rotationEffect(.degrees(-12))
                .position(x: width * 0.20, y: height * 0.60)

            // Radial vignette overlay (`#mapVignette`, components.jsx:361-364).
            RadialGradient(
                stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.45), location: 1),
                ],
                center: .center,
                startRadius: 0,
                endRadius: max(width, height) * 0.78
            )
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: - Deterministic model

/// Port of `seedRand` (components.jsx:302): a tiny linear congruential
/// generator, `s = (s*9301 + 49297) % 233280`, `next = s / 233280`.
struct SeededMapRandom {
    private var s: Double
    init(seed: Int) { s = Double(seed) }
    mutating func next() -> Double {
        s = (s * 9301 + 49297).truncatingRemainder(dividingBy: 233280)
        return s / 233280
    }
}

private struct MapBackgroundModel {
    let parks: [Path]
    let streets: [Path]
    let avenues: [Path]
    let collectors: [Path]
    let freeway: Path
    let water: Path
    let coastLine: Path

    init(width: CGFloat, height: CGFloat, seed: Int) {
        var rng = SeededMapRandom(seed: seed)
        func jitter(_ a: CGFloat) -> CGFloat { CGFloat(rng.next() - 0.5) * a }

        // ── Coastline (components.jsx:312-325)
        var coast: [CGPoint] = []
        let cn = 7
        for i in 0...cn {
            let t = CGFloat(i) / CGFloat(cn)
            let x = t * width
            let y = height * (0.92 - t * 0.42) + sin(t * 7 + 1) * 14
            coast.append(CGPoint(x: x, y: y))
        }
        var water = Path()
        water.move(to: CGPoint(x: 0, y: height))
        water.addLine(to: CGPoint(x: 0, y: coast[0].y))
        for p in coast { water.addLine(to: p) }
        water.addLine(to: CGPoint(x: width, y: height))
        water.closeSubpath()
        self.water = water

        var coastLine = Path()
        coastLine.move(to: coast[0])
        for p in coast.dropFirst() { coastLine.addLine(to: p) }
        self.coastLine = coastLine

        // ── Parks — fixed ratios, not seeded (components.jsx:328-332)
        let parkSpecs: [(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, rot: Double)] = [
            (width * 0.70, height * 0.20, 58, 44, -12),
            (width * 0.30, height * 0.16, 40, 34, 8),
            (width * 0.86, height * 0.52, 34, 50, 18),
        ]
        parks = parkSpecs.map { spec in
            let rect = CGRect(x: spec.cx - spec.rx, y: spec.cy - spec.ry, width: spec.rx * 2, height: spec.ry * 2)
            let center = CGPoint(x: spec.cx, y: spec.cy)
            let rotation = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: spec.rot * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            return Path(ellipseIn: rect).applying(rotation)
        }

        // ── Street grid, rotated -15° around center (components.jsx:335-350,373)
        let center = CGPoint(x: width / 2, y: height / 2)
        let gridRotation = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -15 * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)

        let pad: CGFloat = 120
        var avenues: [Path] = [], streets: [Path] = [], collectors: [Path] = []
        let aGap: CGFloat = 44, sGap: CGFloat = 52
        var idx = 0
        var x = -pad
        while x < width + pad {
            var p = Path()
            p.move(to: CGPoint(x: x + jitter(8), y: -pad))
            p.addLine(to: CGPoint(x: x + jitter(8), y: height + pad))
            p = p.applying(gridRotation)
            if idx % 3 == 0 { collectors.append(p) } else { avenues.append(p) }
            idx += 1
            x += aGap
        }
        idx = 0
        var y = -pad
        while y < height + pad {
            var p = Path()
            p.move(to: CGPoint(x: -pad, y: y + jitter(8)))
            p.addLine(to: CGPoint(x: width + pad, y: y + jitter(8)))
            p = p.applying(gridRotation)
            if idx % 3 == 1 { collectors.append(p) } else { streets.append(p) }
            idx += 1
            y += sGap
        }
        self.avenues = avenues
        self.streets = streets
        self.collectors = collectors

        // ── Freeway — one sweeping quadratic-curve arterial (components.jsx:352-355)
        var freeway = Path()
        freeway.move(to: CGPoint(x: -20, y: height * 0.62))
        var fx: CGFloat = 0
        while fx <= width + 40 {
            let control = CGPoint(x: fx + 35, y: height * 0.62 + sin(fx / 130) * 22)
            let end = CGPoint(x: fx + 70, y: height * 0.60 + sin(fx / 110) * 20)
            freeway.addQuadCurve(to: end, control: control)
            fx += 70
        }
        self.freeway = freeway
    }
}
