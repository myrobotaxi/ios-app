import SwiftUI
import MapKit
import UIKit
import DesignSystem

// MARK: - DriveShareCard (screens.jsx:1192-1224 `DSShareCard`)
//
// "The polished card a rider shares to Messages / socials" — rendered offscreen
// via `ImageRenderer` (see `DriveSummaryScreen.buildShareImage`) and shared
// alongside a plain-text summary through `ActivityShareSheet`
// (`UIActivityViewController`, per Handoff §5.6).
//
// Deviation (same reasoning as `DriveHeroMap`): the jsx draws its hero against
// the shared decorative `MapBackground`/`DS_HERO_ROUTE` SVG squiggle —
// identical for every drive. This port instead bakes the drive's own real
// MapKit route into a static `UIImage` via `MKMapSnapshotter`
// (`DriveShareCard.snapshotRoute`). `ImageRenderer` can't be trusted to catch
// a live `Map` view's asynchronously-loaded tiles mid-render, so the map is
// fully pre-rendered (tiles + route line + endpoint dots baked in with Core
// Graphics) before the card is composed.
struct DriveShareCard: View {
    let drive: Drive
    let dateLabel: String
    let mapImage: UIImage?

    private var fsdPct: Int { drive.fsdPercent }

    var body: some View {
        VStack(spacing: 0) {
            heroMap
            statPanel
        }
        .background(Color.mrtBg)
        .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.shareCardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.shareCardRadius, style: .continuous)
                .strokeBorder(Color.mrtDsShareCardBorder, lineWidth: MRTMetrics.hairline)
        )
        // 0 8px 40px rgba(0,0,0,0.5), 0 0 0 1px rgba(201,168,76,0.06) (screens.jsx:1194).
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.shareCardRadius, style: .continuous)
                .strokeBorder(Color.mrtDsShareCardOuterRing, lineWidth: 1)
        )
        .shadow(color: .mrtScrimSoft, radius: 20, y: 8)
    }

    // MARK: Hero map (screens.jsx:1195-1207)

    private var heroMap: some View {
        ZStack(alignment: .topLeading) {
            if let mapImage {
                Image(uiImage: mapImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.mrtSurface
            }
            // linear-gradient(180deg, rgba(10,10,10,0.2), rgba(10,10,10,0) 30%, rgba(18,16,12,0.7) 100%)
            LinearGradient(
                stops: [
                    .init(color: .mrtDsShareCardScrimStart, location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .mrtDsShareCardScrimEnd, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            brandMark
                .padding(.leading, 14)
                .padding(.top, 12)
        }
        .frame(width: MRTMetrics.shareCardWidth, height: MRTMetrics.shareCardMapHeight)
        .clipped()
    }

    /// screens.jsx:1203-1206 — bare `ArrowMark` + lowercase "myrobotaxi"
    /// wordmark (not `Wordmark`: this instance has no `textTransform`, so the
    /// jsx renders it lowercase, unlike every other wordmark use).
    private var brandMark: some View {
        HStack(spacing: 7) {
            ArrowMark(size: 16)
            Text("myrobotaxi")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.2)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.7), radius: 3, y: 1)
        }
    }

    // MARK: Stat panel (screens.jsx:1208-1220)

    private var statPanel: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                Text("\(drive.from) → \(drive.to)")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                Text(dateLabel)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.mrtTextMuted)
                    .fixedSize()
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                statValue(String(format: "%.1f", drive.miles), unit: "mi")
                statValue("\(drive.mins)", unit: "min")
                Spacer(minLength: 0)
                fsdBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(
            LinearGradient(colors: [.mrtDsShareCardPanelTop, .mrtDsShareCardPanelBottom], startPoint: .top, endPoint: .bottom)
        )
    }

    private func statValue(_ value: String, unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .light))
                .monospacedDigit()
                .tracking(-1)
                .foregroundStyle(Color.mrtText)
            Text(unit)
                .font(.system(size: 12))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .fixedSize()
    }

    private var fsdBadge: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("\(fsdPct)%")
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .tracking(-0.3)
                .foregroundStyle(Color.mrtGold)
            Text("FSD")
                .font(.system(size: 9.5))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.mrtGoldLight)
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.mrtDsShareCardPillFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtDsShareCardBorder, lineWidth: MRTMetrics.hairline))
    }
}

// MARK: - Route snapshotting (MKMapSnapshotter → UIImage with the route baked in)

enum DriveRouteSnapshot {
    /// Renders `region`/`route` to a flat, muted-style `UIImage` at `size`
    /// (points; scaled by the screen's scale internally), with the gold route
    /// line + endpoint dots drawn on top via Core Graphics — mirrors
    /// `DriveHeroMap`'s glow-underlay + bright-line double stroke and
    /// `MRTEndpointDot`'s halo + bordered-disc styling, baked into the bitmap
    /// so `ImageRenderer` never races a live map's async tile loading.
    @MainActor
    static func render(region: MKCoordinateRegion, route: [CLLocationCoordinate2D], size: CGSize) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.region = region
        options.size = size
        options.showsBuildings = false
        options.pointOfInterestFilter = .excludingAll
        options.mapType = .mutedStandard

        let snapshotter = MKMapSnapshotter(options: options)
        guard let snapshot = try? await snapshotter.start() else { return nil }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            snapshot.image.draw(at: .zero)
            guard route.count > 1 else { return }

            let cg = context.cgContext
            let points = route.map { snapshot.point(for: $0) }
            let path = CGMutablePath()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }

            // Glow underlay, then the bright line (DriveHeroMap's double stroke).
            cg.saveGState()
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.addPath(path)
            cg.setStrokeColor(UIColor(Color.mrtGoldGlowSoft).cgColor)
            cg.setLineWidth(9)
            cg.strokePath()
            cg.addPath(path)
            cg.setStrokeColor(UIColor(Color.mrtGold).withAlphaComponent(0.95).cgColor)
            cg.setLineWidth(4)
            cg.strokePath()
            cg.restoreGState()

            drawEndpoint(points[0], color: UIColor(Color.mrtDriving), size: 11, in: cg)
            drawEndpoint(points[points.count - 1], color: UIColor(Color.mrtGold), size: 11, in: cg)
        }
    }

    /// Mirrors `MRTEndpointDot`: a 30%-opacity halo at 1.8× the dot size,
    /// then a solid disc with a 1.5pt white border.
    private static func drawEndpoint(_ point: CGPoint, color: UIColor, size: CGFloat, in cg: CGContext) {
        cg.saveGState()
        let haloSize = size * 1.8
        cg.setFillColor(color.withAlphaComponent(0.3).cgColor)
        cg.fillEllipse(in: CGRect(x: point.x - haloSize / 2, y: point.y - haloSize / 2, width: haloSize, height: haloSize))

        let dotRect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        cg.setFillColor(color.cgColor)
        cg.fillEllipse(in: dotRect)
        cg.setStrokeColor(UIColor.white.cgColor)
        cg.setLineWidth(1.5)
        cg.strokeEllipse(in: dotRect.insetBy(dx: 0.75, dy: 0.75))
        cg.restoreGState()
    }
}

#Preview {
    DriveShareCard(drive: DriveFixtures.drive(id: "d8")!, dateLabel: "Today", mapImage: nil)
        .frame(width: MRTMetrics.shareCardWidth)
        .padding(24)
        .background(Color.mrtBg)
        .preferredColorScheme(.dark)
}
