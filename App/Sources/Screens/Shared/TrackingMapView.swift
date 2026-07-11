import SwiftUI
import MapKit
import DesignSystem

// MARK: - TrackingMapView (MYR-177 — live leg-fit tracking map)
//
// The rider's LIVE tracking map, replacing the old static `RideRequestRouteMap`
// preview for the `.tracking` phase (which framed the whole straight
// pickup→destination box with a fake straight line even while the car was 0.9
// mi away heading to pickup — the client bug). It is a real interactive `Map`:
//
//   • the leg-fit camera (`TrackingCameraController`) frames car → pickup in
//     leg 1 and pickup → destination in leg 2, re-fitting only on a leg flip or
//     when the car leaves the frame — never per fix (MYR-222 anti-loop);
//   • routes are real road geometry (`RideRouteStore` → MKDirections, Apple
//     temp) — the active leg solid gold, the other leg dimmed;
//   • the car is an Uber-style top-down glyph rotated to real heading
//     (`TrackingCarMarker`), smoothly turning the short way between fixes.
//
// Every programmatic camera write flows through the single owner + the shared
// `CameraSettleLedger`; a user gesture dethrones it (pinch-out to see
// everything sticks) and the rider recenter button re-engages the leg fit —
// the exact ownership discipline MYR-217/222 established.
struct TrackingMapView: View {
    let leg: TrackingLeg
    /// Car → pickup road polyline (leg 1). May be `[car, pickup]` fallback.
    let leg1Route: [CLLocationCoordinate2D]
    /// Pickup → destination road polyline (leg 2).
    let leg2Route: [CLLocationCoordinate2D]
    let carCoordinate: CLLocationCoordinate2D
    /// Map-relative heading (deg clockwise from north) — `TrackingCarMarker`
    /// rotates the glyph to it.
    let carHeading: Double
    /// Progress within the CURRENT leg (0…1) — the leg-1 remaining fit + the
    /// travelled-vs-ahead polyline split.
    let legProgress: Double
    let bottomInset: CGFloat
    @Binding var cameraPosition: MapCameraPosition
    @Binding var isFollowing: Bool
    var controller: TrackingCameraController
    var showsUserLocation: Bool = false

    @State private var viewHeight: CGFloat = 0
    @State private var liveCameraRegion = LiveCameraRegionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Derived geometry

    private var pickupCoordinate: CLLocationCoordinate2D {
        leg1Route.last ?? leg2Route.first ?? carCoordinate
    }
    private var destinationCoordinate: CLLocationCoordinate2D? { leg2Route.last }

    /// The coordinates the leg-fit camera frames: the REMAINING car → pickup in
    /// leg 1 (so the view zooms in as the car approaches), the whole pickup →
    /// destination in leg 2.
    private var fitCoords: [CLLocationCoordinate2D] {
        switch leg {
        case .toPickup:
            if leg1Route.count > 1 {
                return VehicleRoute.remainingCoordinates(along: leg1Route, progress: legProgress)
            }
            return [carCoordinate, pickupCoordinate]
        case .inRide:
            if leg2Route.count > 1 { return leg2Route }
            if let destinationCoordinate { return [pickupCoordinate, destinationCoordinate] }
            return [carCoordinate, pickupCoordinate]
        }
    }

    private var carKey: String { "\(carCoordinate.latitude),\(carCoordinate.longitude)" }
    /// Changes when a leg's polyline is (re)fetched — the straight fallback → the
    /// real Apple route — so the fit tightens to the actual road geometry.
    private var routeKey: String { "\(leg1Route.count)-\(leg2Route.count)" }

    var body: some View {
        GeometryReader { geo in
            Map(position: $cameraPosition) {
                mapContent.annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .safeAreaPadding(.bottom, bottomInset)
            .preferredColorScheme(.dark)
            .onMapCameraChange(frequency: .continuous) { context in
                liveCameraRegion.region = context.region
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                let ours = controller.cameraSettled(
                    center: context.region.center,
                    latitudeDelta: context.region.span.latitudeDelta
                )
                if ours {
                    mrtCameraTrace("settle tracking leg=\(leg) center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) classified=programmatic (token)")
                } else {
                    mrtCameraTrace("settle tracking leg=\(leg) center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) classified=user → follow off")
                    isFollowing = false
                }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in handleUserGesture() })
            .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02).onChanged { _ in handleUserGesture() })
            .onAppear {
                viewHeight = geo.size.height
                engage()
            }
            .onChange(of: geo.size.height) { _, newValue in
                viewHeight = newValue
                engage()
            }
            .onChange(of: carKey) { _, _ in engage() }
            .onChange(of: routeKey) { _, _ in
                guard viewHeight > 0, !fitCoords.isEmpty,
                      let write = controller.reframe(leg: leg, fitCoords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset) else { return }
                applyWrite(write)
            }
            .onChange(of: leg) { _, _ in engage() }
            .onChange(of: bottomInset) { _, _ in engage() }
            .onChange(of: isFollowing) { _, following in
                guard following, viewHeight > 0 else { return }
                applyWrite(controller.recenter(leg: leg, fitCoords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset))
            }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background: controller.sceneWillBackground()
                case .active: controller.sceneDidForeground()
                default: break
                }
            }
        }
    }

    // MARK: Camera plumbing

    /// Drive the single owner: enter on first ready layout, otherwise let it
    /// decide whether the car's move warrants a re-fit (it returns `nil` — no
    /// write — while the car stays comfortably framed, at any fix rate).
    private func engage() {
        guard viewHeight > 0 else { return }
        let coords = fitCoords
        guard !coords.isEmpty else { return }
        if controller.phase == .inactive {
            applyWrite(controller.enter(leg: leg, fitCoords: coords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset))
        } else if let write = controller.update(leg: leg, carPosition: carCoordinate, fitCoords: coords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset) {
            applyWrite(write)
        }
    }

    private func applyWrite(_ write: TrackingCameraController.Write) {
        mrtCameraTrace("WRITE tracking leg=\(leg) center=\(write.region.center.latitude),\(write.region.center.longitude) span=\(write.region.span.latitudeDelta) animated=\(write.animated)")
        if write.animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.5)) { cameraPosition = .region(write.region) }
        } else {
            cameraPosition = .region(write.region)
        }
    }

    private func handleUserGesture() {
        guard controller.phase == .following else { return }
        mrtCameraTrace("gesture user pan/zoom during tracking → follow off")
        controller.userGestureBegan()
        isFollowing = false
        // Kill any in-flight programmatic glide so it can't slide back over the
        // user's drag (MYR-222) — pin the camera at its current visual region.
        if let current = liveCameraRegion.region {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { cameraPosition = .region(current) }
        }
    }

    // MARK: Content

    @MapContentBuilder
    private var mapContent: some MapContent {
        if showsUserLocation {
            UserAnnotation()
        }

        // The OTHER leg's route, dimmed (RouteLine dim alpha 0.30) — drawn but
        // never fitted by the camera. Leg 1: the pickup→destination trip is a
        // faint preview. Leg 2: the completed car→pickup approach fades back.
        switch leg {
        case .toPickup:
            dimmedRoute(leg2Route)
            activeRoute(leg1Route)
        case .inRide:
            dimmedRoute(leg1Route)
            activeRoute(leg2Route)
        }

        // Endpoints — pickup + destination dots (the design's `MRTEndpointDot`).
        Annotation("Pickup", coordinate: pickupCoordinate) {
            MRTEndpointDot(color: .mrtDriving, size: 11)
        }
        if let destinationCoordinate {
            Annotation("Destination", coordinate: destinationCoordinate) {
                MRTEndpointDot(color: .mrtGold, size: 13)
            }
        }

        // The live car — Uber-style top-down glyph rotated to real heading.
        Annotation("Vehicle", coordinate: carCoordinate) {
            TrackingCarMarker(heading: HeadingMath.mapRelative(heading: carHeading, cameraHeading: 0))
        }
    }

    /// The active leg: solid gold with a bright travelled segment + glow underlay
    /// (the existing `RouteLine` recipe), the ahead segment dim gold.
    @MapContentBuilder
    private func activeRoute(_ route: [CLLocationCoordinate2D]) -> some MapContent {
        if route.count > 1 {
            MapPolyline(coordinates: route)
                .stroke(Color.mrtGold.opacity(0.3), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            let travelled = VehicleRoute.travelledCoordinates(along: route, progress: legProgress)
            MapPolyline(coordinates: travelled)
                .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: travelled)
                .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
        }
    }

    /// The inactive leg: a single dim gold line (no new hex — the same 0.30
    /// dim token the full-route underlay uses).
    @MapContentBuilder
    private func dimmedRoute(_ route: [CLLocationCoordinate2D]) -> some MapContent {
        if route.count > 1 {
            MapPolyline(coordinates: route)
                .stroke(Color.mrtGold.opacity(0.3), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        }
    }
}
