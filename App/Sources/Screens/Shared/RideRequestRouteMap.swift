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
    /// MYR-216 deliverable 4: points the phase's bottom sheet covers (+ margin).
    /// The route camera fits the route into the UNOBSTRUCTED area above the sheet
    /// so both endpoints + the full polyline clear it. `0` (default) keeps the
    /// plain full-frame fit for non-inset callers.
    ///
    /// MYR-223 deliverable 2: this same value ALSO drives `.safeAreaPadding
    /// (.bottom:)`, so MapKit's legally-required attribution/legal label sits
    /// just above the sheet instead of hidden behind it (parity with
    /// `VehicleMapView`'s idle/search/pin-drop map). `safeAreaPadding` repositions
    /// only the map ornaments — it does NOT reframe the camera (the route fit is
    /// still the `initialPosition` region above) — so the polyline framing is
    /// unchanged; only the attribution moves.
    var bottomInset: CGFloat = 0

    var body: some View {
        // The fit needs the map's height to know what fraction the sheet covers
        // (MYR-216 d4). `GeometryReader` reports the full-bleed height (the caller
        // applies `.ignoresSafeArea()`), read once for `initialPosition`.
        GeometryReader { geo in
            Map(
                initialPosition: .region(VehicleRoute.fittedRegion(
                    for: route, paddingFactor: 1.7, bottomInset: bottomInset, viewHeight: geo.size.height
                )),
                interactionModes: []
            ) {
                // Suppresses MapKit's own auto-drawn "Origin"/"Destination" title
                // labels — see `VehicleMapView`'s identical call (MYR-167 review
                // finding #3), reused verbatim by `ScheduledRideSheet.RideRouteMap`.
                mapContent.annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            // MYR-223 d2: keep the MapKit attribution just above the phase's
            // bottom chrome (same mechanism as `VehicleMapView`). No-op when
            // `bottomInset` is 0 (the Summary full-screen takeover).
            .safeAreaPadding(.bottom, bottomInset)
            .preferredColorScheme(.dark)
            .allowsHitTesting(false)
        }
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
