import SwiftUI
import MapKit
import DesignSystem

// MARK: - VehicleMapView (MYR-167 deliverable 2)
//
// Real MapKit (SwiftUI `Map`, DEVIATIONS "Mapbox GL → MapKit … Native
// MKMapView for vehicle annotation + route overlay. Accept minor fidelity
// loss on building extrusions" — the SwiftUI `Map` API wraps `MKMapView`).
// Dark styling comes for free from the app's forced-dark interface style
// (project.yml `INFOPLIST_KEY_UIUserInterfaceStyle: Dark`); POIs/traffic are
// excluded to keep the chrome as close to the prototype's minimal stylized
// map as MapKit allows.
struct VehicleMapView: View {
    let vehicle: Vehicle
    let snapshot: VehicleTelemetrySnapshot
    @Binding var cameraPosition: MapCameraPosition
    @Binding var isFollowing: Bool
    /// MYR-197 fix: `SharedViewerScreen`'s rider idle/search/pinDrop map
    /// reuses this same view (MYR-191) — but client QA found it was also
    /// drawing the owner's current-trip route polyline + origin/destination
    /// dots on the rider's idle map before any ride is booked, because
    /// `VEHICLES[0]`'s default fixture activity is `.driving` (matches the
    /// owner Home screen's own default tweaks, `VehicleTelemetry.swift`'s
    /// `SimulatedVehicleTelemetrySource.init` comment). The prototype's rider
    /// live map never shows a route pre-booking (confirmed via the MYR-197
    /// prototype walk) — a route only belongs once an actual request exists,
    /// which is already correctly handled by `RideRequestRouteMap` for
    /// `.review`/`.booking`/`.tracking` (`SharedViewerScreen
    /// .backgroundMap`). Defaults `true` (unchanged behavior for
    /// `HomeScreen`'s owner map, which legitimately shows its own vehicle's
    /// live trip) — the rider call site below opts out.
    var showRoute: Bool = true
    /// MYR-198 client ruling (overrides the design jsx's idle vehicle
    /// marker): the rider's idle/search/pinDrop/review map — including the
    /// "request sent, not yet accepted" pending state, which still renders
    /// this same `.idle`-phase call site — shows NO vehicle location at all,
    /// no marker and no label, until a ride is actually accepted (tracking).
    /// Client QA round 3 screenshots are the spec (privacy: don't broadcast
    /// a fleet vehicle's live position to a rider who hasn't been matched to
    /// it yet). Defaults `true` (unchanged for `HomeScreen`'s owner map,
    /// which legitimately shows its own vehicle) — the rider call site in
    /// `SharedViewerScreen.backgroundMap` opts out, mirroring `showRoute`'s
    /// identical default/opt-out shape immediately above.
    var showVehicle: Bool = true
    /// MYR-199 fix (client QA round 4): the rider's idle/search/pinDrop map
    /// was centering the camera — and RE-centering it every progress tick
    /// (`.onChange(of: progressBucket)` below) — on the watched vehicle's
    /// live simulated-driving position, even though `showVehicle`/`showRoute`
    /// are both `false` at that call site (MYR-197/198 privacy rulings), so
    /// nothing was ever drawn to explain why the map kept visibly panning
    /// down the vehicle's route. Client QA: "why is the map moving around
    /// when there's no ride booked… map should be set to the user's current
    /// location." Fix: an optional static override coordinate — when set,
    /// the camera centers there once (`onAppear`) and never re-centers on
    /// vehicle telemetry; when `nil` (the owner's `HomeScreen` call site,
    /// unchanged), legacy vehicle-follow behavior.
    var centerOverride: CLLocationCoordinate2D?
    /// MYR-211: draw the standard MapKit user-location dot (the rider's live
    /// map in live mode, when location is authorized). The prototype defines no
    /// bespoke user marker (`grep` "current location" in `design/` is only the
    /// pickup-label fallback), so the standard blue dot is the accepted
    /// deviation. Defaults `false` — the owner `HomeScreen` map is unaffected.
    var showsUserLocation: Bool = false
    /// Reserved height along the bottom edge the sheet now physically
    /// covers (MYR-196 punch-list #2, `MRTDetentSheet`'s
    /// `.ignoresSafeArea(edges: .bottom)`). `MKMapView` reads its own
    /// `safeAreaInsets` to keep the legally-required attribution/legal
    /// label (and compass) clear of obstructed regions — `.safeAreaPadding`
    /// grows that inset without shrinking the map's own edge-to-edge
    /// render, so the label settles just above the sheet's peek edge
    /// instead of being hidden underneath it.
    let bottomContentInset: CGFloat
    /// MYR-212: reports the map's settled region center at the end of every
    /// pan/zoom — the rider's pin-drop phase uses it as the AUTHORITATIVE
    /// pickup coordinate (the pin is fixed on screen; the coordinate under it is
    /// wherever the map settled). `nil` at every other call site.
    var onCameraCenterChange: ((CLLocationCoordinate2D) -> Void)? = nil

    // Cooldown *window*, not a single-consume flag: recenters can overlap
    // (a new one fires every progress-percent tick, ~1/sec, while the
    // previous 0.8s animation's `.onEnd` is still in flight), so a
    // consume-once boolean races — a later recenter's suppress flag can get
    // eaten by an earlier animation's trailing `.onEnd`. A rolling deadline
    // tolerates overlap: any camera-change event that lands before it is
    // ours, no matter which recenter call last set it.
    @State private var programmaticCameraUntil: Date = .distantPast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var vehiclePosition: VehicleRoute.Position {
        switch vehicle.activity {
        case .driving(let trip):
            VehicleRoute.position(along: trip.route, progress: snapshot.progress)
        case .parked(let loc):
            VehicleRoute.Position(coordinate: loc.coordinate, headingDegrees: 0)
        }
    }

    /// Rounds the 30Hz simulated progress to whole percent so the follow
    /// camera re-centers roughly once a second instead of on every tick.
    private var progressBucket: Double { (snapshot.progress * 100).rounded() }

    /// MYR-211: a change key for `centerOverride` so the camera re-centers when
    /// the live location fix arrives / moves (the first fix commonly lands after
    /// `onAppear`). `nil` for the owner map (no override) — never fires.
    private var centerOverrideKey: String? {
        centerOverride.map { "\($0.latitude),\($0.longitude)" }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            mapContent
                // Suppress MapKit's own auto-drawn title labels for every
                // `Annotation` below — `VehicleMarker`'s `label` chip is the
                // only vehicle-name label the design wants
                // (components.jsx:443); leaving titles on doubled it up next
                // to the marker (review finding #3). The `Origin`/
                // `Destination`/vehicle-name strings passed to `Annotation`
                // are accessibility labels only.
                .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .safeAreaPadding(.bottom, bottomContentInset)
        // Force dark so MKMapView doesn't fall back to a light palette
        // independent of the app's own forced-dark Info.plist trait
        // (review finding #4). This measurably darkens urban/street
        // contexts (deep navy water, muted gray streets) but — verified in
        // the Simulator — does NOT reach near-black for natural
        // landcover/terrain (forests, coastal scrub): MapKit's `.standard`
        // style keeps a saturated teal-green there regardless of
        // `emphasis`. See the PR body for the documented limitation and
        // side-by-side evidence; there is no more aggressive terrain color
        // knob on the public SwiftUI `Map` style API.
        .preferredColorScheme(.dark)
        .onMapCameraChange(frequency: .onEnd) { context in
            // MYR-212: report the settled center for the pin-drop pickup — on
            // every settle (programmatic seed AND user drag) so the confirmed
            // coordinate always tracks the map. Reported before the follow
            // guard below, which is unrelated (recenter-affordance state).
            onCameraCenterChange?(context.region.center)
            guard Date() >= programmaticCameraUntil else { return }
            // A real drag/pinch settled — the prototype's FloatingMapButton
            // recenter affordance is meant for exactly this (Handoff §5.5;
            // "appears when user has panned away").
            isFollowing = false
        }
        .onAppear { recenter(animated: false) }
        .onChange(of: progressBucket) { _, _ in
            // MYR-199 fix: a static `centerOverride` never re-centers on the
            // ticking vehicle telemetry — see that property's header comment.
            guard centerOverride == nil else { return }
            if isFollowing { recenter(animated: true) }
        }
        .onChange(of: isFollowing) { _, following in
            if following { recenter(animated: true) }
        }
        // MYR-211: re-center when the live location override changes (first fix
        // / device movement) — but never fight a user who has panned away.
        .onChange(of: centerOverrideKey) { _, _ in
            guard centerOverride != nil, isFollowing else { return }
            recenter(animated: true)
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if showsUserLocation {
            UserAnnotation()
        }
        switch vehicle.activity {
        case .driving(let trip):
            if showRoute {
                let travelled = VehicleRoute.travelledCoordinates(along: trip.route, progress: snapshot.progress)
                // Full path, dim (RouteLine.swift: alpha 0.30).
                MapPolyline(coordinates: trip.route)
                    .stroke(Color.mrtGold.opacity(0.3), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                // Glow underlay beneath the travelled segment (RouteLine.swift
                // doc: "draw a third, wider underlay polyline").
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                // Travelled portion, bright (RouteLine.swift: alpha 0.95).
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                if let origin = trip.route.first {
                    Annotation("Origin", coordinate: origin) {
                        MRTEndpointDot(color: .mrtDriving, size: 10)
                    }
                }
                if let destination = trip.route.last {
                    Annotation("Destination", coordinate: destination) {
                        MRTEndpointDot(color: .mrtGold, size: 11)
                    }
                }
            }
            if showVehicle {
                Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                    VehicleMarker(heading: vehiclePosition.headingDegrees, label: vehicle.name)
                }
            }
        case .parked:
            if showVehicle {
                Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                    VehicleMarker(heading: 0, label: vehicle.name)
                }
            }
        }
    }

    private func recenter(animated: Bool) {
        // Covers the 0.8s animation plus slack for `.onEnd`'s async delivery.
        programmaticCameraUntil = Date().addingTimeInterval(1.2)
        let region = MKCoordinateRegion(
            center: centerOverride ?? vehiclePosition.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.06, longitudeDelta: 0.06)
        )
        if animated, !reduceMotion {
            // screens.jsx:417 vehicle-marker transition — `left .8s linear, top .8s linear`.
            withAnimation(.linear(duration: 0.8)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }
}
