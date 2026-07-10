import CoreLocation
import Foundation
import MapKit

// MARK: - Pickup-point labeling, industry-style (MYR-217 deliverable 2)
//
// RESEARCH RECORD (full sources in the MYR-217 PR body): production rideshare
// apps do NOT show raw reverse-geocode output at the pickup pin. Uber labels
// pins from curated "suggested pickup points" (historical trip data), Grab from
// hand-surveyed venue entrances, Lyft from its Venues dataset; Google ships
// "Address Descriptors" (ranked landmarks + NEAR/BESIDE relations) precisely
// because bare reverse geocodes make poor human labels. Snapping the PIN to a
// point is only done by apps with curb-verified datasets — Apple POIs are
// building CENTROIDS, so a magnetic snap on Apple data would silently move the
// pickup into a building interior or the wrong frontage (and suburban POI
// sparsity would make it fire rarely and weirdly). DESIGN DECISION: FREE PIN —
// the confirmed coordinate is always exactly the glyph's MapProxy ground truth,
// untouched by labeling — with a nearest-named-entity label ladder:
//
//   1. a named POI effectively AT the pin (≤ `poiAtMeters`)      → "Starbucks"
//   2. the reverse-geocode street/address (MYR-212/213/216 ladder:
//      street-first, never ZIP/city, far-parcel guarded)          → "1200 Grandscape Blvd"
//   3. a named POI NEAR the pin (≤ `poiNearMeters`) — the
//      label-unknown case the client's suburb mid-block pin hits  → "Near Grandscape"
//   4. nothing precise                                            → neutral ("Pinned location")
//
// The POI candidates come from `MKLocalPointsOfInterestRequest` (radius
// `poiQueryRadiusMeters` around the pin) — Apple's radius-based POI fetch —
// run CONCURRENTLY with the reverse geocode on each debounced settle.
// `LivePinLabeler` (the guarded reverse-geocode) is reused as step 2 verbatim.

/// A named point-of-interest candidate near the pin.
struct PickupPOI: Equatable, Sendable {
    var name: String
    var coordinate: CLLocationCoordinate2D

    static func == (lhs: PickupPOI, rhs: PickupPOI) -> Bool {
        lhs.name == rhs.name
            && lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}

/// The live pickup-point labeler: POI lookup + guarded reverse geocode,
/// composed through the pure `bestLabel` ladder. Conforms to the existing
/// `RidePinLabeling` seam so `SharedViewerState`'s debounce/staleness pipeline
/// is unchanged (sim keeps `SimulatedPinLabeler` → fixture label).
@MainActor
final class LivePickupPointLabeler: RidePinLabeling {

    /// Injectable POI source so the ladder is testable without MapKit.
    typealias POIProvider = @Sendable (CLLocationCoordinate2D, CLLocationDistance) async -> [PickupPOI]

    /// A POI within this distance labels the pin AS the place ("Starbucks") —
    /// the pin is effectively at its doorstep. Tuned tighter than the
    /// reverse-geocode far-parcel guard (50m) so a doorstep POI outranks a
    /// parcel address but a storefront across the street does not.
    static let poiAtMeters: Double = 30
    /// A POI within this distance may still anchor a "Near X" label when the
    /// geocode has nothing street-precise (the suburb mid-block case) —
    /// matches Google Address Descriptors' NEAR semantics.
    static let poiNearMeters: Double = 75
    /// The POI fetch radius around the pin.
    static let poiQueryRadiusMeters: CLLocationDistance = 100

    private let pois: POIProvider
    private let geocode: LivePinLabeler

    init(pois: POIProvider? = nil, geocode: LivePinLabeler? = nil) {
        self.pois = pois ?? Self.systemPOIs
        self.geocode = geocode ?? LivePinLabeler()
    }

    func label(for coordinate: CLLocationCoordinate2D) async -> String? {
        async let poiCandidates = pois(coordinate, Self.poiQueryRadiusMeters)
        async let geocodeLabel = geocode.label(for: coordinate)
        return Self.bestLabel(
            pin: coordinate,
            pois: await poiCandidates,
            geocodeLabel: await geocodeLabel
        )
    }

    /// The label ladder (pure + static, unit-tested in
    /// `PickupPointLabelTests`). Returns `nil` for the neutral case — the
    /// caller (`SharedViewerState.pinDropLabel`) shows "Pinned location".
    /// NEVER returns a coordinate adjustment: labeling reads the pin, it
    /// never moves it (free-pin decision above).
    static func bestLabel(
        pin: CLLocationCoordinate2D,
        pois: [PickupPOI],
        geocodeLabel: String?
    ) -> String? {
        let nearest = pois
            .map { (poi: $0, distance: LivePinLabeler.distanceMeters($0.coordinate, pin)) }
            .min { $0.distance < $1.distance }

        // 1. A named place at the pin's doorstep beats a parcel address.
        if let nearest, nearest.distance <= poiAtMeters {
            return nearest.poi.name
        }
        // 2. The guarded street-first reverse geocode (never ZIP/city,
        //    far-parcel house numbers suppressed — MYR-212/213/216).
        if let geocodeLabel {
            return geocodeLabel
        }
        // 3. Label-unknown, but a named place is close: "Near X" — honest
        //    about the offset, still human-meaningful (vs. bare "Pinned
        //    location" in a spot the rider clearly recognizes).
        if let nearest, nearest.distance <= poiNearMeters {
            return "Near \(nearest.poi.name)"
        }
        // 4. Neutral — the caller's "Pinned location".
        return nil
    }

    /// The system POI source: `MKLocalPointsOfInterestRequest` around the pin.
    /// No category filter — suburban POI coverage is already sparse, and the
    /// distance thresholds (not categories) are what keep labels sane.
    static func systemPOIs(around coordinate: CLLocationCoordinate2D, radius: CLLocationDistance) async -> [PickupPOI] {
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: radius)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return [] }
        return response.mapItems.compactMap { item in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
            let itemCoordinate: CLLocationCoordinate2D
            if #available(iOS 26.0, *) {
                itemCoordinate = item.location.coordinate
            } else {
                itemCoordinate = item.placemark.coordinate
            }
            return PickupPOI(name: name, coordinate: itemCoordinate)
        }
    }
}
