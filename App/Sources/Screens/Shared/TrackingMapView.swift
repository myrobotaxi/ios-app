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
    /// Pickup → destination road polyline (leg 2). Still the geometry the pins and
    /// the camera fit are derived from in BOTH legs — see `inRideRoute`.
    let leg2Route: [CLLocationCoordinate2D]
    /// MYR-482 — **the line the rider aboard actually needs: the car, right now, to
    /// the drop-off.** Tesla's own nav route when the wire has one, else the app's
    /// MKDirections road route, else the last one this journey really had
    /// (`OwnerDrivingRoute.resolve`). Empty leaves `leg2Route` as the in-ride
    /// stroke, which is the pre-MYR-482 rendering and what every simulated scene
    /// still gets.
    var inRideRoute: [CLLocationCoordinate2D] = []
    /// MYR-393 — the freshest position we hold for the car, or `nil` when we hold
    /// none. `nil` draws NO vehicle glyph: the route, both pins and the camera are
    /// unaffected, because a camera is context and a gold pin is a claim that the
    /// car is there right now (MYR-387's rule, on the rider's tracking map).
    let carCoordinate: CLLocationCoordinate2D?
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
    /// MYR-460 — the glyph's SMOOTH position between two ~1Hz fixes. Rendering
    /// only: `carCoordinate` (the raw fix) is what the camera, the fit and the
    /// change key all read, and this never reaches any of them.
    @State private var markerMotion = TrackingMarkerMotion()
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
            // MYR-393 — with no position for the car there is nothing to frame but
            // the pickup, which is a fact. Framing on a coordinate we do not have
            // is the same fabrication the marker now refuses.
            guard let carCoordinate else { return [pickupCoordinate] }
            return [carCoordinate, pickupCoordinate]
        case .inRide:
            if leg2Route.count > 1 { return leg2Route }
            if let destinationCoordinate { return [pickupCoordinate, destinationCoordinate] }
            guard let carCoordinate else { return [pickupCoordinate] }
            return [carCoordinate, pickupCoordinate]
        }
    }

    /// Where the glyph is DRAWN this frame — the interpolated position while a
    /// tween is running, the raw fix otherwise.
    ///
    /// MYR-393's withheld rule is kept STRUCTURAL rather than delegated: with no
    /// raw fix this is `nil` whatever the interpolator happens to be holding, so
    /// a tween can never outlive the position that justified it and leave a
    /// glyph gliding over a car we have stopped hearing from.
    private var displayCarCoordinate: CLLocationCoordinate2D? {
        guard carCoordinate != nil else { return nil }
        return markerMotion.rendered ?? carCoordinate
    }

    private var carKey: String {
        guard let carCoordinate else { return "nofix" }
        return "\(carCoordinate.latitude),\(carCoordinate.longitude)"
    }
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
                markerMotion.reduceMotion = reduceMotion
                markerMotion.ingest(carCoordinate)
                engage()
            }
            .onDisappear { markerMotion.stop() }
            .onChange(of: reduceMotion) { _, newValue in markerMotion.reduceMotion = newValue }
            .onChange(of: geo.size.height) { _, newValue in
                viewHeight = newValue
                engage()
            }
            .onChange(of: carKey) { _, _ in
                // ONE funnel for a new fix: the glyph starts its tween and the
                // camera decides whether to write, both from the RAW coordinate.
                markerMotion.ingest(carCoordinate)
                engage()
            }
            .onChange(of: routeKey) { _, _ in
                guard viewHeight > 0, !fitCoords.isEmpty,
                      let write = controller.reframe(leg: leg, fitCoords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset) else { return }
                applyWrite(write)
            }
            .onChange(of: leg) { _, _ in engage() }
            .onChange(of: bottomInset) { _, _ in engage() }
            .onChange(of: isFollowing) { _, following in
                guard following, viewHeight > 0 else { return }
                applyWrite(controller.recenter(leg: leg, carPosition: carCoordinate, fitCoords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset))
            }
            // MYR-460 — the client's *"after a few seconds it will snap right
            // back to the camera of the car"*. Keyed on `gestureToken`, which
            // bumps on EVERY gesture, so `.task(id:)` cancels the countdown and
            // starts a fresh one each time the rider touches the map: the window
            // is measured from the LAST gesture and a rider still panning is
            // never yanked. Re-arming through `isFollowing` rather than through
            // the controller directly is deliberate — the recenter BUTTON and
            // the idle window must re-engage by exactly the same path, or the
            // two ways back become two behaviours.
            .task(id: controller.gestureToken) {
                guard controller.gestureToken > 0, controller.phase == .userControlled else { return }
                try? await Task.sleep(nanoseconds: UInt64(MRTMetrics.trackingFollowIdleRearm * 1_000_000_000))
                guard !Task.isCancelled, controller.phase == .userControlled else { return }
                mrtCameraTrace("follow re-arm tracking after \(MRTMetrics.trackingFollowIdleRearm)s idle → follow on")
                isFollowing = true
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
            applyWrite(controller.enter(leg: leg, carPosition: carCoordinate, fitCoords: coords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset))
        } else if let write = controller.update(leg: leg, carPosition: carCoordinate, fitCoords: coords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: MRTMetrics.trackingFitTopInset) {
            applyWrite(write)
        }
    }

    private func applyWrite(_ write: TrackingCameraController.Write) {
        mrtCameraTrace("WRITE tracking frame=\(write.frame) leg=\(leg) center=\(write.region.center.latitude),\(write.region.center.longitude) span=\(write.region.span.latitudeDelta) animated=\(write.animated)")
        if write.animated, !reduceMotion {
            // A follow write is LINEAR over roughly the fix interval, so
            // consecutive writes hand off at constant speed and the map glides
            // under a stationary-looking car. An eased curve would decelerate
            // into every single fix, which at 1Hz is a visible pulse.
            let animation: Animation = write.frame == .follow
                ? .linear(duration: MRTMetrics.trackingFollowWriteDuration)
                : .easeInOut(duration: 0.5)
            withAnimation(animation) { cameraPosition = .region(write.region) }
        } else {
            cameraPosition = .region(write.region)
        }
    }

    private func handleUserGesture() {
        // ⚠️ THE CONTROLLER IS TOLD ABOUT EVERY GESTURE, INCLUDING ONE THAT
        // LANDS WHILE THE RIDER IS ALREADY IN CONTROL. The early return this
        // guard used to make was correct when a dethrone was permanent; with
        // MYR-460's idle re-arm it would mean the countdown starts at the
        // rider's FIRST touch and fires in the middle of their third pan. The
        // token bump is what pushes the deadline out, so it has to happen
        // before the phase is consulted.
        let wasFollowing = controller.phase == .following
        controller.userGestureBegan()
        guard wasFollowing else { return }
        mrtCameraTrace("gesture user pan/zoom during tracking → follow off (re-arms in \(MRTMetrics.trackingFollowIdleRearm)s idle)")
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
            inRideRoute: inRideRoute,
            pickupCoordinate: pickupCoordinate,
            destinationCoordinate: destinationCoordinate,
            carCoordinate: displayCarCoordinate,
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
        carCoordinate: CLLocationCoordinate2D?
    ) -> CLLocationCoordinate2D {
        // MYR-393 — the car is the LAST fallback and is now optional. With no leg
        // geometry AND no fix there is no pickup to pin, so `(0, 0)` would be the
        // only remaining answer and §2.3 says that is the no-fix sentinel, not a
        // place. The caller's own guard is what keeps that unreachable: leg 2 is
        // always the submitted ride's pickup→destination pair.
        leg1Route.last ?? leg2Route.first ?? carCoordinate ?? kCLLocationCoordinate2DInvalid
    }

    /// The drop-off, or `nil` when leg 2 has no geometry yet.
    static func destination(leg2Route: [CLLocationCoordinate2D]) -> CLLocationCoordinate2D? {
        leg2Route.last
    }

    /// MYR-482 — **the approach leg is HISTORY the moment the rider is aboard**,
    /// and this is the rule that retires it.
    ///
    /// External beta, build `202608081012`: an L-shaped gold fragment sat by the
    /// pickup pin for the whole trip. `TrackingRouteMapContent.content` draws BOTH
    /// legs in every phase — the inactive one dimmed (MYR-234) — and nothing ever
    /// cleared the car → pickup polyline on the flip to `.inRide`:
    /// `reconcileTrackingRoutes` stops FETCHING leg 1 there, which is not the same
    /// thing as stopping DRAWING it, and `RideRouteStore.leg1` keeps its geometry
    /// until the ride's slot empties. MYR-234's "the other leg dimmed" was written
    /// about leg 2 during leg 1 — the REST of the trip, which is a fact about the
    /// journey ahead. The reverse is a route the car has already driven.
    ///
    /// Stated as a function rather than as an `if` inside the builder so the screen
    /// can apply the SAME rule to the camera fit and the expanded viewer, and so a
    /// test can name it.
    static func drawnLeg1(_ route: [CLLocationCoordinate2D], leg: TrackingLeg) -> [CLLocationCoordinate2D] {
        leg.isLeg1Active ? route : []
    }

    /// MYR-482 — the polyline the ACTIVE leg strokes.
    ///
    /// Leg 1 is unchanged. In-ride, a resolved car → drop-off route (wire, fetched
    /// or held) REPLACES the pickup → drop-off preview: the rider is aboard, so the
    /// part of that preview behind the car is not their trip any more, and on a car
    /// that took a different road it never was. Empty falls back to `leg2Route`,
    /// which is exactly the pre-MYR-482 rendering — so a simulated scene, which has
    /// no live car and no wire route, is byte-identical.
    static func activeRoute(
        leg: TrackingLeg,
        leg1Route: [CLLocationCoordinate2D],
        leg2Route: [CLLocationCoordinate2D],
        inRideRoute: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        if leg.isLeg1Active { return leg1Route }
        return inRideRoute.isEmpty ? leg2Route : inRideRoute
    }

    @MapContentBuilder
    static func content(
        leg: TrackingLeg,
        leg1Route: [CLLocationCoordinate2D],
        leg2Route: [CLLocationCoordinate2D],
        inRideRoute: [CLLocationCoordinate2D] = [],
        pickupCoordinate: CLLocationCoordinate2D,
        destinationCoordinate: CLLocationCoordinate2D?,
        carCoordinate: CLLocationCoordinate2D?,
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
        //
        // MYR-482 — and once the rider is ABOARD there is no "other leg" to dim:
        // `drawnLeg1` retires the approach polyline, and the active stroke becomes
        // the car → drop-off route whenever one has resolved.
        if leg.isLeg1Active {
            routeLeg(leg2Route, active: false, legProgress: legProgress)
            routeLeg(leg1Route, active: true, legProgress: legProgress)
        } else {
            routeLeg(drawnLeg1(leg1Route, leg: leg), active: false, legProgress: legProgress)
            // The travelled/ahead split is measured along the polyline being
            // stroked. A car → drop-off route STARTS at the car, so none of it is
            // behind them: glowing `legProgress` of it would light a stretch of road
            // this ride has not driven.
            let active = activeRoute(leg: leg, leg1Route: leg1Route, leg2Route: leg2Route, inRideRoute: inRideRoute)
            routeLeg(active, active: true, legProgress: inRideRoute.isEmpty ? legProgress : 0)
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
        //
        // MYR-393 — drawn ONLY from a position we hold. The client's report is this
        // annotation rendered at a point interpolated along a polyline by a
        // client-side ticker, a mile and a half from a car that was parked; with no
        // fix there is no honest coordinate to put it at, and no marker is the only
        // truthful frame.
        if let carCoordinate {
            Annotation("Vehicle", coordinate: carCoordinate) {
                TrackingCarMarker(heading: HeadingMath.mapRelative(heading: carHeading, cameraHeading: 0))
            }
        }
    }

    /// MYR-458 — **whether this leg has a LINE to draw at all**, and the reason it
    /// is `RideRoutePolyline.isReal` rather than `count > 1`.
    ///
    /// This was the ONE route surface in the app that never consulted MYR-293's
    /// predicate. `SharedViewerScreen`'s `trackingLeg1Route` /
    /// `trackingLeg2Route` fall back to an ENDPOINT PAIR while the provider
    /// resolves — leg 1's pair is `[the car's live fix, the pickup]` — and a
    /// `count > 1` gate drew it. That is the external-beta report verbatim:
    /// *"After riding, there is straight line between the current location and
    /// beginning dot."* It is not a one-frame artifact because nothing refetches
    /// leg 1 once the ride is under way, so the segment stands for the whole trip
    /// and its length grows as the car drives away from the pickup.
    ///
    /// The pairs are deliberately KEPT — MYR-293's rule is *PINS unconditionally,
    /// the LINE only from `isReal`*, and both pins and the camera fit are derived
    /// from this same geometry (`pickup(leg1Route:leg2Route:carCoordinate:)`). So
    /// the endpoints still travel and only the stroke is withheld.
    static func drawsLine(_ route: [CLLocationCoordinate2D]) -> Bool {
        RideRoutePolyline.isReal(route)
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
        if drawsLine(route) {
            if active {
                // Whole leg at full strength — ahead segment included.
                // MYR-293 named this alpha (`MRTRouteStroke.aheadOpacity`) so the
                // owner map's route, which was still on the illustration 0.30,
                // reads the SAME value rather than a matching literal. Identical
                // number, so every tracking capture is byte-identical.
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGold.opacity(MRTRouteStroke.aheadOpacity), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
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
