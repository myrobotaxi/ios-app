import SwiftUI
import MapKit
import DesignSystem

// MARK: - RideRequestRouteMap (MYR-171)
//
// Small satellite `Map` for the ride-request flow's Review/Booking/Tracking/
// Summary phases. `VehicleMapView` (MYR-167) has no content-injection seam
// and is scoped to `SharedViewerState.vehicle`'s own telemetry — not the
// fleet member + pickup/destination pair the rider is actively requesting —
// so this is its own small `Map` rather than a fork of that file (CLAUDE.md
// "Reuse, don't fork": the pieces reused below are `MapPolyline`/
// `Annotation`/`MRTEndpointDot`/`VehicleRoute`, the same primitives
// `ScheduledRideSheet`'s `RideRouteMap` already uses for its own preview
// map, not `VehicleMapView` itself).
struct RideRequestRouteMap: View {
    let route: [CLLocationCoordinate2D]
    /// `nil` — Review/Booking: draw the full route solid gold (no live trip
    /// yet, matches ride-request.jsx's static review/pending route line).
    /// `0...1` — Tracking/Summary: split into travelled (bright) vs. full
    /// dim, per `RouteLine`'s recipe (Packages/DesignSystem RouteLine.swift).
    var progress: Double?
    /// Draws a moving marker at `progress` along the route — Tracking only.
    var showVehicle: Bool = false

    var body: some View {
        Map(initialPosition: .region(VehicleRoute.fittedRegion(for: route, paddingFactor: 1.7)), interactionModes: []) {
            // Suppresses MapKit's own auto-drawn "Origin"/"Destination" title
            // labels — see `VehicleMapView`'s identical call (MYR-167 review
            // finding #3), reused verbatim by `ScheduledRideSheet.RideRouteMap`.
            mapContent.annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if route.count > 1 {
            if let progress {
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGold.opacity(0.3), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                let travelled = VehicleRoute.travelledCoordinates(along: route, progress: progress)
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: travelled)
                    .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            } else {
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: route)
                    .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
        }
        if let origin = route.first {
            Annotation("Origin", coordinate: origin) { MRTEndpointDot(color: .mrtDriving, size: 11) }
        }
        if let destination = route.last, route.count > 1 {
            Annotation("Destination", coordinate: destination) { MRTEndpointDot(color: .mrtGold, size: 13) }
        }
        if showVehicle, let progress {
            let position = VehicleRoute.position(along: route, progress: progress)
            Annotation("Vehicle", coordinate: position.coordinate) {
                Circle()
                    .fill(Color.mrtGold)
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.mrtText, lineWidth: 1.5))
                    .shadow(color: .mrtGoldGlow, radius: 6)
            }
        }
    }
}
