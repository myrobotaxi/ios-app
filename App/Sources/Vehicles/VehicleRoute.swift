import CoreLocation
import MapKit

// MARK: - Route geometry (MYR-167 — screens.jsx:374-395 `vehiclePos` useMemo)
//
// The jsx computes the vehicle's position + heading along its route in the
// *view* layer from `progress` + the static route points — not in state.
// This mirrors that split: `VehicleTelemetrySource` owns the number
// (`progress`), this enum owns the geometry query.

public enum VehicleRoute {
    /// A point along the route: its coordinate and the bearing (degrees from
    /// true north) of travel at that point.
    public struct Position: Equatable {
        public let coordinate: CLLocationCoordinate2D
        public let headingDegrees: Double

        public static func == (lhs: Position, rhs: Position) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude
                && lhs.coordinate.longitude == rhs.coordinate.longitude
                && lhs.headingDegrees == rhs.headingDegrees
        }
    }

    /// screens.jsx:375-395 — walk cumulative segment distances until the
    /// target fraction of the total route length is reached, then lerp
    /// within that segment. Heading uses the same planar
    /// `atan2(dx, -dy)` the jsx uses in SVG space (y grows downward/south);
    /// `MKMapPoint` shares that convention (y grows south in the Mercator
    /// projection), so the formula ports unchanged.
    public static func position(along route: [CLLocationCoordinate2D], progress: Double) -> Position {
        guard let first = route.first else {
            return Position(coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0), headingDegrees: 0)
        }
        guard route.count > 1 else {
            return Position(coordinate: first, headingDegrees: 0)
        }
        let points = route.map(MKMapPoint.init)
        let segmentLengths = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        let total = segmentLengths.reduce(0, +)
        let clamped = min(1, max(0, progress))
        let target = total * clamped

        var accumulated: Double = 0
        for i in 0..<segmentLengths.count {
            let segLen = segmentLengths[i]
            if accumulated + segLen >= target || i == segmentLengths.count - 1 {
                let t = segLen > 0 ? min(1, max(0, (target - accumulated) / segLen)) : 0
                let a = points[i], b = points[i + 1]
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                let dx = b.x - a.x, dy = b.y - a.y
                let heading = atan2(dx, -dy) * 180 / .pi
                let coordinate = MKMapPoint(x: x, y: y).coordinate
                return Position(coordinate: coordinate, headingDegrees: heading)
            }
            accumulated += segLen
        }
        return Position(coordinate: route[route.count - 1], headingDegrees: 0)
    }

    /// The route's coordinates up to `progress`, with the final point
    /// interpolated — used to render the "travelled" (bright) polyline
    /// segment distinct from the full (dim) path, per `RouteLine`
    /// (Packages/DesignSystem/.../RouteLine.swift `.trim(from:0,to:progress)`).
    public static func travelledCoordinates(along route: [CLLocationCoordinate2D], progress: Double) -> [CLLocationCoordinate2D] {
        guard route.count > 1 else { return route }
        let points = route.map(MKMapPoint.init)
        let segmentLengths = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        let total = segmentLengths.reduce(0, +)
        let clamped = min(1, max(0, progress))
        let target = total * clamped

        var result: [CLLocationCoordinate2D] = [route[0]]
        var accumulated: Double = 0
        for i in 0..<segmentLengths.count {
            let segLen = segmentLengths[i]
            if accumulated + segLen >= target {
                let t = segLen > 0 ? min(1, max(0, (target - accumulated) / segLen)) : 0
                let a = points[i], b = points[i + 1]
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                result.append(MKMapPoint(x: x, y: y).coordinate)
                return result
            }
            result.append(route[i + 1])
            accumulated += segLen
        }
        return result
    }

    /// The route's coordinates FROM `progress` to the end, with the first point
    /// interpolated at the current position — the "remaining" segment ahead of
    /// the vehicle. Used by the MYR-177 leg-fit tracking camera to frame the
    /// car → leg-destination portion (leg 1: car → pickup) so the view zooms in
    /// as the car approaches instead of holding the whole origin→pickup box.
    public static func remainingCoordinates(along route: [CLLocationCoordinate2D], progress: Double) -> [CLLocationCoordinate2D] {
        guard route.count > 1 else { return route }
        let points = route.map(MKMapPoint.init)
        let segmentLengths = zip(points, points.dropFirst()).map { $0.distance(to: $1) }
        let total = segmentLengths.reduce(0, +)
        let clamped = min(1, max(0, progress))
        let target = total * clamped

        var accumulated: Double = 0
        for i in 0..<segmentLengths.count {
            let segLen = segmentLengths[i]
            if accumulated + segLen >= target {
                let t = segLen > 0 ? min(1, max(0, (target - accumulated) / segLen)) : 0
                let a = points[i], b = points[i + 1]
                let x = a.x + (b.x - a.x) * t
                let y = a.y + (b.y - a.y) * t
                var result = [MKMapPoint(x: x, y: y).coordinate]
                result.append(contentsOf: route[(i + 1)...])
                return result
            }
            accumulated += segLen
        }
        return [route[route.count - 1]]
    }

    /// Total route length in miles — used by the Drives live-trip banner
    /// (MYR-169, screens.jsx:668 "28.4 mi") to derive "miles remaining" as
    /// `totalDistanceMiles * (1 - progress)` instead of hardcoding the jsx's
    /// static demo figure.
    static func totalDistanceMiles(along route: [CLLocationCoordinate2D]) -> Double {
        guard route.count > 1 else { return 0 }
        let points = route.map(MKMapPoint.init)
        let meters = zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
        return meters * 0.000621371
    }

    /// A `MKCoordinateRegion` fitted to `route`'s bounding box with padding —
    /// the static camera for Drive Summary's hero map (MYR-169, Handoff
    /// §5.6 "static camera fitted to route"), distinct from `HomeScreen`'s
    /// live-following camera (`VehicleMapView.recenter`).
    ///
    /// MYR-216 deliverable 4: `bottomInset` (points the bottom sheet covers) +
    /// `viewHeight` (the map's height) reframe the fit so the whole route sits in
    /// the UNOBSTRUCTED area ABOVE the sheet (the destination endpoint no longer
    /// hides behind it). Defaults keep every non-inset caller (Drive Summary hero,
    /// scheduled/incoming previews) byte-identical.
    static func fittedRegion(
        for route: [CLLocationCoordinate2D],
        paddingFactor: Double = 1.6,
        bottomInset: CGFloat = 0,
        viewHeight: CGFloat = 0,
        topInset: CGFloat = 0
    ) -> MKCoordinateRegion {
        guard let first = route.first else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for coordinate in route {
            minLat = min(minLat, coordinate.latitude)
            maxLat = max(maxLat, coordinate.latitude)
            minLon = min(minLon, coordinate.longitude)
            maxLon = max(maxLon, coordinate.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.02, (maxLat - minLat) * paddingFactor),
            longitudeDelta: max(0.02, (maxLon - minLon) * paddingFactor)
        )
        return insetRegion(center: center, span: span, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset)
    }

    /// MYR-216 deliverable 4 (pure, testable) — grow a fitted region so its route
    /// sits in the top `(viewHeight − bottomInset)` band, clear of a bottom sheet
    /// covering `bottomInset` points. The latitude span grows by `1/visibleFraction`
    /// so that band holds the whole route, and the center shifts SOUTH by half the
    /// added span so the covered strip falls behind the sheet; longitude grows by
    /// the same factor (uniform zoom-out — never clips a horizontal endpoint).
    /// No-op for an unset / degenerate inset, so plain fits are unchanged.
    ///
    /// MYR-177: extended with `topInset` (the status-bar/notch band at the top)
    /// so the route centers in the TRUE unobstructed rect — between the top
    /// inset and the sheet — instead of riding up under the notch. With
    /// `topInset == 0` this is byte-identical to the MYR-216 bottom-only inset
    /// (every existing caller keeps its framing).
    static func insetRegion(center: CLLocationCoordinate2D, span: MKCoordinateSpan, bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> MKCoordinateRegion {
        guard viewHeight > 0, bottomInset >= 0, topInset >= 0, bottomInset + topInset < viewHeight,
              bottomInset > 0 || topInset > 0 else {
            return MKCoordinateRegion(center: center, span: span)
        }
        let visibleFraction = (Double(viewHeight) - Double(bottomInset) - Double(topInset)) / Double(viewHeight)
        guard visibleFraction > 0 else { return MKCoordinateRegion(center: center, span: span) }
        let grownLat = span.latitudeDelta / visibleFraction
        let grownLon = span.longitudeDelta / visibleFraction
        // Shift the region center SOUTH by the net (bottom − top) obstruction so
        // the route's own center lands at the visible band's center. When the
        // insets are equal the shift is zero (perfectly centered).
        let shiftFraction = (Double(bottomInset) - Double(topInset)) / 2 / Double(viewHeight)
        let southwardShift = shiftFraction * grownLat
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude - southwardShift, longitude: center.longitude),
            span: MKCoordinateSpan(latitudeDelta: grownLat, longitudeDelta: grownLon)
        )
    }
}
