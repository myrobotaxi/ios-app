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
    /// MYR-327 — "click into the map". This map is already pannable, but the
    /// tracking sheet covers most of it; a tap opens the full-bleed expanded
    /// viewer where the whole route is reachable. `nil` leaves the map exactly as
    /// it was (previews / any host that offers no expansion).
    var onExpand: (() -> Void)?

    @State private var viewHeight: CGFloat = 0
    @State private var liveCameraRegion = LiveCameraRegionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    // MARK: Derived geometry

    private var pickupCoordinate: CLLocationCoordinate2D {
        TrackingRouteMapContent.pickup(leg1Route: leg1Route, leg2Route: leg2Route, carCoordinate: carCoordinate)
    }
    private var destinationCoordinate: CLLocationCoordinate2D? {
        TrackingRouteMapContent.destination(leg2Route: leg2Route)
    }

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
            // MYR-327 — a discrete TAP (never a pan/pinch, which the two
            // gestures above already claim) opens the expanded route viewer.
            // `simultaneousGesture` so MapKit keeps its own recognizers intact.
            .simultaneousGesture(TapGesture().onEnded { onExpand?() })
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
        TrackingRouteMapContent.content(
            leg: leg,
            leg1Route: leg1Route,
            leg2Route: leg2Route,
            pickupCoordinate: pickupCoordinate,
            destinationCoordinate: destinationCoordinate,
            carCoordinate: carCoordinate,
            carHeading: carHeading,
            legProgress: legProgress,
            showsUserLocation: showsUserLocation
        )
    }
}

// MARK: - TrackingRouteMapContent (MYR-327 — one recipe, two cameras)
//
// The two-leg route + pins + heading marker, lifted verbatim out of
// `TrackingMapView` so the MYR-327 expanded viewer can draw EXACTLY what the
// inline tracking map draws. Nothing about the rendering changed in the move —
// the inline map calls straight through, so the tracking drift-gate scenes are
// byte-identical.
enum TrackingRouteMapContent {

    /// The pickup the pins + fit use: the end of leg 1 when it exists, else the
    /// start of leg 2, else the car itself. (Lifted from `TrackingMapView` so the
    /// inline map and the expanded viewer can never derive different endpoints.)
    static func pickup(
        leg1Route: [CLLocationCoordinate2D],
        leg2Route: [CLLocationCoordinate2D],
        carCoordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        leg1Route.last ?? leg2Route.first ?? carCoordinate
    }

    /// The drop-off, or `nil` when leg 2 has no geometry yet.
    static func destination(leg2Route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        leg2Route.last
    }

    @MapContentBuilder
    static func content(
        leg: TrackingLeg,
        leg1Route: [CLLocationCoordinate2D],
        leg2Route: [CLLocationCoordinate2D],
        pickupCoordinate: CLLocationCoordinate2D,
        destinationCoordinate: CLLocationCoordinate2D?,
        carCoordinate: CLLocationCoordinate2D,
        carHeading: Double,
        legProgress: Double,
        showsUserLocation: Bool
    ) -> some MapContent {
        if showsUserLocation {
            UserAnnotation()
        }

        // Leg-differentiated route (MYR-234): the ACTIVE leg the rider is
        // traversing renders full-strength gold; the OTHER leg renders subdued
        // (`mrtRouteInactive`) so "the active route to pickup vs the rest of the
        // trip" reads apart — the client's ask. The split is driven by the ONE
        // `leg` phase input, so MYR-231's `in_ride` status flips it in one line.
        // The inactive leg is always drawn first so the active leg + its glow sit
        // on top.
        if leg.isLeg1Active {
            routeLeg(leg2Route, active: false, legProgress: legProgress)
            routeLeg(leg1Route, active: true, legProgress: legProgress)
        } else {
            routeLeg(leg1Route, active: false, legProgress: legProgress)
            routeLeg(leg2Route, active: true, legProgress: legProgress)
        }

        // Endpoints — slim Tesla-style pickup (donut lollipop) + destination
        // (teardrop) pins (MYR-235). Anchored at the pin tip so the planted
        // contact dot / teardrop tip sits on the coordinate.
        Annotation("Pickup", coordinate: pickupCoordinate, anchor: .bottom) {
            MRTMapPin(kind: .pickup)
        }
        if let destinationCoordinate {
            Annotation("Destination", coordinate: destinationCoordinate, anchor: .bottom) {
                MRTMapPin(kind: .destination)
            }
        }

        // The live car — Uber-style top-down glyph rotated to real heading.
        Annotation("Vehicle", coordinate: carCoordinate) {
            TrackingCarMarker(heading: HeadingMath.mapRelative(heading: carHeading, cameraHeading: 0))
        }
    }

    /// One route leg, rendered per its `active` phase (MYR-234) — the single
    /// active/inactive code path both legs flow through, so the ACTIVE-leg accent
    /// follows the `leg` phase input wherever it points.
    ///
    ///   • active — full-strength gold end to end (the client's "active route to
    ///     pickup" must NOT be the same shade as the rest of the trip): the whole
    ///     leg draws at a strong gold, with the travelled portion getting the glow
    ///     underlay + a solid-gold bright pass so in-leg progress still reads.
    ///   • inactive — a single subdued same-hue line (`mrtRouteInactive`), so the
    ///     remaining trip is visibly dimmed against the live leg.
    @MapContentBuilder
    static func routeLeg(_ route: [CLLocationCoordinate2D], active: Bool, legProgress: Double) -> some MapContent {
        if route.count > 1 {
            if active {
                // Whole leg at full strength — ahead segment included.
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGold.opacity(0.85), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                let travelled = VehicleRoute.travelledCoordinates(along: route, progress: legProgress)
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            } else {
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtRouteInactive, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
