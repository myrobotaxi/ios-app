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
        .onMapCameraChange(frequency: .onEnd) { _ in
            guard Date() >= programmaticCameraUntil else { return }
            // A real drag/pinch settled — the prototype's FloatingMapButton
            // recenter affordance is meant for exactly this (Handoff §5.5;
            // "appears when user has panned away").
            isFollowing = false
        }
        .onAppear { recenter(animated: false) }
        .onChange(of: progressBucket) { _, _ in
            if isFollowing { recenter(animated: true) }
        }
        .onChange(of: isFollowing) { _, following in
            if following { recenter(animated: true) }
        }
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        switch vehicle.activity {
        case .driving(let trip):
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
            Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                VehicleMarker(heading: vehiclePosition.headingDegrees, label: vehicle.name)
            }
        case .parked:
            Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                VehicleMarker(heading: 0, label: vehicle.name)
            }
        }
    }

    private func recenter(animated: Bool) {
        // Covers the 0.8s animation plus slack for `.onEnd`'s async delivery.
        programmaticCameraUntil = Date().addingTimeInterval(1.2)
        let region = MKCoordinateRegion(
            center: vehiclePosition.coordinate,
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
