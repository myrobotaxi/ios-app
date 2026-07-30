import CoreLocation
import Foundation

// MARK: - RiderPickupETA (MYR-341 — "A ride is N min away", for real)
//
// The rider idle sheet's rotating search placeholder alternates "Where to?" with
// "A ride is N min away" (screens.jsx:1977-1980). MYR-228 dropped that second
// string on the LIVE path because the only N available was `FLEET[0].etaMin` — a
// hardcoded 3 belonging to a fixture car on nobody's account. This is the real N.
//
// METHOD — the SAME closed form the rest of the flow already trusts
// (`TripEstimate`: great-circle × 1.3 detour ÷ 24 mph, clamped ≥ 1 min), measured
// from the watched vehicle's coordinate to the RIDER's own location.
//
// DELIBERATELY NOT MKDirections. The Linear issue floated a routed call; the
// surface rules it out. This placeholder is visible the entire time the rider
// sits on idle and re-renders on a 2800ms rotation, and `RideRouteProvider`'s own
// header documents what Apple's throttle does to a caller that re-asks on a
// visible cadence (MYR-237: the etched route collapsed back to "loading" in a
// ~2s loop on the client's device). A closed form is deterministic, free,
// network-less, unit-testable, and consistent with the trip numbers Review and
// Booking already show — which the routed call would silently contradict.
//
// STABILITY (MYR-237 jitter class). A device streams fixes at ~1Hz; feeding raw
// GPS into a number that is on screen across a 2800ms crossfade makes it twitch.
// Two guards, both here:
//   • `quantize` snaps each endpoint to a ~250m grid before estimating, so the
//     estimate is a function of a CELL, not of a fix;
//   • `StableFixAnchor` holds the anchor until the raw fix leaves that cell's
//     radius, so a fix jittering across a grid BOUNDARY cannot flip cells either
//     (quantization alone does not survive the boundary case).
// Together: any two fixes within 250m of the anchor produce the identical
// placeholder, and the anchor is only re-seated on a genuinely material move.
enum RiderPickupETA {
    /// ~250m — the anchor grid, and the material-move threshold. At 24 mph a
    /// 250m step is ≈0.4 min of estimate, so a sub-cell move cannot change the
    /// rounded minute at all; a cell-crossing one is a real change worth showing.
    static let anchorGridMeters: Double = 250

    /// Meters per degree of latitude (WGS-84 mean) — the grid's only constant.
    private static let metersPerDegreeLatitude: Double = 111_320

    /// Snap a coordinate to the ~250m grid. Longitude steps are scaled by
    /// `cos(latitude)` so a cell is roughly square at any latitude; the cosine is
    /// floored so a coordinate near a pole can't produce an infinite step.
    static func quantize(_ coordinate: CLLocationCoordinate2D, gridMeters: Double = anchorGridMeters) -> CLLocationCoordinate2D {
        guard gridMeters > 0, coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return coordinate }
        let latStep = gridMeters / metersPerDegreeLatitude
        let cosLatitude = max(abs(cos(coordinate.latitude * .pi / 180)), 0.01)
        let lonStep = gridMeters / (metersPerDegreeLatitude * cosLatitude)
        return CLLocationCoordinate2D(
            latitude: (coordinate.latitude / latStep).rounded() * latStep,
            longitude: (coordinate.longitude / lonStep).rounded() * lonStep
        )
    }

    /// Minutes for the vehicle to reach the rider, or `nil` when either endpoint
    /// is unknown. `nil` is the ONLY honest answer with a missing endpoint — the
    /// caller renders no number at all rather than a fabricated one.
    ///
    /// Both endpoints are quantized first, so this is a pure function of two grid
    /// cells. `TripEstimate` clamps at 1, so a returned value is never 0.
    static func minutes(vehicle: CLLocationCoordinate2D?, rider: CLLocationCoordinate2D?) -> Int? {
        guard let vehicle, let rider else { return nil }
        return TripEstimate.estimate(from: quantize(vehicle), to: quantize(rider)).minutes
    }
}

// MARK: - StableFixAnchor (MYR-341 — the "material move" latch)

/// Holds a coordinate anchor across a stream of noisy fixes: the anchor is
/// adopted on the first fix and then only REPLACED once a fix lands further than
/// `materialMoveMeters` from it. Losing the fix entirely clears the anchor —
/// "no fix" is a state the ETA must degrade on, never a reason to keep showing
/// the last number (MYR-341 honesty gate 1).
///
/// This is what makes the placeholder immune to the grid-boundary case that
/// quantization alone leaves open: the anchor is the input to `quantize`, so a
/// jittering fix keeps hitting the same anchor and therefore the same cell.
/// `@MainActor` only because it reuses `LivePinLabeler.distanceMeters` (which is
/// isolated by its enclosing type) rather than forking a second haversine — and
/// its one owner, `SharedViewerState`, is main-actor anyway.
@MainActor
struct StableFixAnchor {
    /// How far a fix must land from the anchor before the anchor is re-seated.
    let materialMoveMeters: Double
    private(set) var anchor: CLLocationCoordinate2D?

    init(materialMoveMeters: Double = RiderPickupETA.anchorGridMeters) {
        self.materialMoveMeters = materialMoveMeters
    }

    /// Feed the latest raw fix; returns the anchor to estimate from.
    @discardableResult
    mutating func update(_ fix: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        guard let fix else {
            anchor = nil
            return nil
        }
        guard let current = anchor else {
            anchor = fix
            return fix
        }
        if LivePinLabeler.distanceMeters(current, fix) > materialMoveMeters {
            anchor = fix
        }
        return anchor
    }
}

// MARK: - RiderIdlePlaceholder (MYR-341 — the gating matrix)

/// The rider idle sheet's rotating placeholder items, and the ONE place the
/// honesty gates live. `RotatingPlaceholder` never rotates a single-item list,
/// so a gated result is simply the static "Where to?" the live path has shown
/// since MYR-228 — no layout change, no empty slot, no fabricated number.
enum RiderIdlePlaceholder {
    /// screens.jsx:1978 — the destination prompt, always item 0.
    static let destinationPrompt = "Where to?"

    /// screens.jsx:1979 `A ride is ${sel.etaMin} min away` — copied exactly.
    static func etaLine(minutes: Int) -> String { "A ride is \(minutes) min away" }

    /// THE matrix. The placeholder stays plain `["Where to?"]` unless every gate
    /// passes:
    ///
    ///  • **`hasActiveRequest`** — the prototype gates this whole block on
    ///    `!reqActive` (screens.jsx:1964,2173): with a request in flight the car
    ///    is coming to you, and "a ride is N min away" would be describing a ride
    ///    the rider has already booked as though it were an offer.
    ///  • **`unavailability`** — a busy / in-service / offline car is NOT "N min
    ///    away" at any distance (the MYR-233 `FleetUnavailability` predicate,
    ///    reused verbatim rather than re-derived). The straight-line minutes are
    ///    perfectly computable for a car sitting in a service bay; they are also
    ///    a lie.
    ///  • **`pickupETAMinutes`** — `nil` whenever either endpoint is unknown: no
    ///    device fix (gate 1), or no vehicle coordinate (gate 2). The rider
    ///    endpoint must come from the LOCATION SEAM, never from
    ///    `SharedViewerState.mapRegionCenter` — that falls back to the vehicle's
    ///    own coordinate, which would estimate the car's distance to itself and
    ///    render a confident "A ride is 1 min away" to a rider whose phone has no
    ///    location permission at all.
    static func items(
        pickupETAMinutes: Int?,
        unavailability: FleetUnavailability?,
        hasActiveRequest: Bool
    ) -> [String] {
        guard !hasActiveRequest,
              unavailability == nil,
              let minutes = pickupETAMinutes,
              minutes > 0
        else { return [destinationPrompt] }
        return [destinationPrompt, etaLine(minutes: minutes)]
    }

    /// screens.jsx:15-19 `FLEET[0].etaMin` — the SIMULATED path's fixture ETA.
    static let simulatedETAMinutes = 3

    /// The whole seam, both paths, in one pure function — so the drift gate can
    /// be asserted rather than photographed (a wall-clock screenshot of this
    /// element captures the rotation's own crossfade phase, which differs between
    /// two launches of the *same* binary and can therefore never prove
    /// byte-identity).
    ///
    /// `resolvesLiveETA == false` — every simulated boot — returns the fixture
    /// pair verbatim, evaluated before any live machinery is consulted.
    static func items(
        resolvesLiveETA: Bool,
        pickupETAMinutes: Int?,
        unavailability: FleetUnavailability?,
        hasActiveRequest: Bool
    ) -> [String] {
        guard resolvesLiveETA else {
            return [destinationPrompt, etaLine(minutes: simulatedETAMinutes)]
        }
        return items(pickupETAMinutes: pickupETAMinutes,
                     unavailability: unavailability,
                     hasActiveRequest: hasActiveRequest)
    }
}

// MARK: - RidePickupETADisplay (MYR-341 — 0 is a sentinel, not a number)

/// How Review and Booking render `FleetMember.etaMin`.
///
/// Before this issue the live mapping copied `RideRequestFixtures.fleet[0].etaMin`
/// into every live member, so both surfaces confidently said "3 min away" about a
/// car whose position nobody had measured. `LiveFleetMemberMapping` now emits
/// **0** — "no estimate" — and `SharedViewerState.liveFleetMember` fills it from
/// `RiderPickupETA` when the endpoints exist, exactly the `TripEstimate
/// .applied(to:)` gate style (fill only when the value is the 0 sentinel).
///
/// That leaves 0 genuinely reachable on live (a car with no fix), so 0 must
/// render as "unknown", never as "the car is already here". Every FIXTURE member
/// carries a non-zero `etaMin` (3 / 8 / 12), so nothing on the simulated path
/// takes these branches and every simulated scene is byte-identical.
enum RidePickupETADisplay {
    /// The calm unknown, matching Review's existing unresolved-destination dash.
    static let unknownClock = "\u{2014}"
    /// The calm sub-line where "N min away" would go. Plainly honest, and
    /// deliberately NOT the design's in-flight grammar ("Finding route…"):
    /// nothing is retrying — the car simply has not reported a position.
    static let unknownNote = "Time unknown"

    /// The real minutes, or `nil` for the 0 sentinel.
    static func minutes(_ etaMin: Int) -> Int? { etaMin > 0 ? etaMin : nil }

    /// A wall-clock time `etaMin` from now, or the calm dash when unknown.
    static func clock(etaMin: Int) -> String {
        minutes(etaMin).map(RideRequestClock.fromNow) ?? unknownClock
    }

    /// A wall-clock time `etaMin + offset` from now, or the calm dash when the
    /// pickup ETA is unknown (an unknown pickup makes the arrival unknown too).
    static func clock(etaMin: Int, plus offset: Int) -> String {
        minutes(etaMin).map { RideRequestClock.fromNow(minutes: $0 + offset) } ?? unknownClock
    }

    /// The "N min away" note, or `nil` when there is no estimate — the caller
    /// renders nothing rather than "0 min away".
    static func awayNote(etaMin: Int) -> String? {
        minutes(etaMin).map { "\($0) min away" }
    }
}
