import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-237 — route "etch" prefix geometry
//
// The review-screen etch draws the route's cumulative-length PREFIX (pickup →
// current head) as the settled gold body and the short SUFFIX of that prefix as
// the bright leading head. Both are the same `VehicleRoute` primitives the
// MYR-177 tracking map already uses (`travelledCoordinates` for the drawn
// prefix, `remainingCoordinates` for the trailing bright head) — pinned here for
// the fraction→partial-polyline contract the animator relies on: monotonic
// growth, exact 0/1 edges, and a 2-point route.
final class RouteEtchGeometryTests: XCTestCase {

    // A simple L-shaped, unequal-length polyline so the length-fraction split is
    // non-trivial (a naive index split would land in the wrong segment).
    private let a = CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
    private let b = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
    private let c = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3700)

    private var route: [CLLocationCoordinate2D] { [a, b, c] }

    private func meters(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D) -> Double {
        MKMapPoint(x).distance(to: MKMapPoint(y))
    }

    private func totalLength(_ coords: [CLLocationCoordinate2D]) -> Double {
        guard coords.count > 1 else { return 0 }
        let points = coords.map(MKMapPoint.init)
        return zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    private func assertClose(_ x: CLLocationCoordinate2D, _ y: CLLocationCoordinate2D, _ tol: Double = 1.0, _ msg: String = "") {
        XCTAssertLessThan(meters(x, y), tol, msg)
    }

    // MARK: travelledCoordinates — the drawn prefix

    func testPrefixAtZeroStartsAtOrigin() {
        // Fraction 0 must not draw ahead: the prefix collapses to the origin.
        let head = VehicleRoute.travelledCoordinates(along: route, progress: 0)
        assertClose(head.first!, a, 1.0, "prefix starts at the origin")
        assertClose(head.last!, a, 1.0, "at fraction 0 the head has not advanced")
    }

    func testPrefixAtOneIsTheWholeRoute() {
        let head = VehicleRoute.travelledCoordinates(along: route, progress: 1)
        assertClose(head.first!, a)
        assertClose(head.last!, c, 1.0, "at fraction 1 the head reaches the destination")
        // Every original vertex is present (no dropped corner).
        assertClose(head[1], b, 1.0)
    }

    func testPrefixLengthGrowsWithFraction() {
        let total = totalLength(route)
        // Half the LENGTH (not half the vertices) lands partway along the long
        // second segment for this L-shape.
        let half = VehicleRoute.travelledCoordinates(along: route, progress: 0.5)
        let halfLen = totalLength(half)
        XCTAssertEqual(halfLen, total * 0.5, accuracy: total * 0.02, "prefix length tracks the fraction")
        // Monotonic: a larger fraction is never shorter.
        let quarterLen = totalLength(VehicleRoute.travelledCoordinates(along: route, progress: 0.25))
        XCTAssertLessThan(quarterLen, halfLen)
    }

    func testPrefixClampsOutOfRange() {
        assertClose(VehicleRoute.travelledCoordinates(along: route, progress: -3).last!, a, 1.0, "negative clamps to 0")
        assertClose(VehicleRoute.travelledCoordinates(along: route, progress: 5).last!, c, 1.0, "over 1 clamps to the end")
    }

    // MARK: two-point route (the straight [pickup, destination] fallback)

    func testTwoPointRouteMidpoint() {
        let mid = VehicleRoute.travelledCoordinates(along: [a, b], progress: 0.5)
        XCTAssertEqual(mid.count, 2)
        assertClose(mid.first!, a)
        let expectedMid = CLLocationCoordinate2D(latitude: (a.latitude + b.latitude) / 2, longitude: (a.longitude + b.longitude) / 2)
        assertClose(mid.last!, expectedMid, 2.0, "the cut point is the segment midpoint")
    }

    // MARK: remainingCoordinates — the bright leading head (suffix of the prefix)

    func testBrightHeadIsTheTrailingSuffix() {
        // Take a mid-draw prefix, then its last portion — the bright head.
        let head = VehicleRoute.travelledCoordinates(along: route, progress: 0.6)
        let bright = VehicleRoute.remainingCoordinates(along: head, progress: 0.7)
        // The bright head ends exactly where the drawn head currently is…
        assertClose(bright.last!, head.last!, 1.0, "bright head ends at the draw head")
        // …and is strictly shorter than the whole drawn prefix.
        XCTAssertLessThan(totalLength(bright), totalLength(head))
        XCTAssertGreaterThan(totalLength(bright), 0)
    }

    func testBrightHeadWholePrefixWhenFractionZero() {
        let head = VehicleRoute.travelledCoordinates(along: route, progress: 0.3)
        let bright = VehicleRoute.remainingCoordinates(along: head, progress: 0)
        XCTAssertEqual(totalLength(bright), totalLength(head), accuracy: 1.0, "fraction 0 keeps the entire prefix bright")
    }
}

// MARK: - PolylineHeadDot.point(along:fraction:) — the traveling glow point

extension RouteEtchGeometryTests {
    func testHeadDotPointAtEdges() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)]
        XCTAssertEqual(PolylineHeadDot.point(along: pts, fraction: 0), pts[0])
        XCTAssertEqual(PolylineHeadDot.point(along: pts, fraction: 1), pts[2])
    }

    func testHeadDotPointAtHalfIsLengthParameterized() {
        // Total length 40 (10 + 30); halfway (20) lands 10pt down the second leg.
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 30)]
        let mid = PolylineHeadDot.point(along: pts, fraction: 0.5)
        XCTAssertEqual(mid?.x ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(mid?.y ?? -1, 10, accuracy: 0.001)
    }

    func testHeadDotPointClampsNonFinite() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        XCTAssertNotNil(PolylineHeadDot.point(along: pts, fraction: 2))
        XCTAssertNil(PolylineHeadDot.point(along: [], fraction: 0.5))
    }
}
