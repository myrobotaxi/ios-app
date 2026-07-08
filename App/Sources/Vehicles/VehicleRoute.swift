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
}
