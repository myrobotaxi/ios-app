import Foundation
import MyRobotaxiContracts

// MARK: - Live fleet-member mapping (MYR-212 deliverable 4)
//
// Folds the account's first owned `VehicleSummary` onto the fixture-shaped
// `FleetMember` the rider's Review + Booking cards already render — so a live
// ride shows the REAL vehicle instead of the fixture "Alex's Quicksilver Model
// Y · RBO-2046 · 68%" (client QA round 2, defect 4). Every field that has a
// telemetry source is real; the two that do not are called out below.
//
// DECISIONS (documented, no invented data):
//  • `plate`: MYR-286 — the REAL owner-entered plate now reaches the rider. It
//    rides `VehicleSummary.licensePlate` (contracts 0.15.0, deliberately in the
//    VIEWER role mask too: a plate only the owner can see fails at its one job,
//    which is letting a rider identify the correct car at pickup). Tesla itself
//    still has no plate field anywhere, so when the owner hasn't entered one the
//    chip keeps the VIN last-4 degrade ("VIN ····2046") via the shared
//    `VehicleContractMapping.plateDisplay`. Empty plate AND empty VIN yields an
//    empty string → the caller hides the chip rather than showing a blank box.
//    We never fabricate a plate.
//    v1 caveat: there is NO WS delta for the plate, so a plate edited mid-ride
//    reaches the rider on the next `GET /api/vehicles` fetch.
//  • `etaMin`: MYR-341 — this used to copy `RideRequestFixtures.fleet[0].etaMin`,
//    so every live member claimed the fixture's 3 minutes about a car whose
//    position nobody had measured (a MYR-228 fixture leak with no grep
//    signature). It is now the **0 sentinel**: this layer sees one wire row and
//    knows nothing about where the rider is standing, so it cannot compute a
//    pickup ETA and must not pretend to. `SharedViewerState.liveFleetMember` —
//    the single read seam that also folds the MYR-233 own-ride exception — fills
//    it from `RiderPickupETA` when both endpoints exist. When they do not, 0
//    survives to the UI, which renders `RidePickupETADisplay`'s calm unknown.
//  • `owner`: telemetry carries no owner *display name*. For the single owned
//    vehicle the rider is requesting, the honest headline is the vehicle's own
//    nickname (`summary.name`, e.g. "Lunar") — so the CTAs read "Request from
//    Lunar" / "Booking ride with Lunar". A real owner-name join is MYR-91/210
//    scope (the shared-viewer access set); this stays a single-vehicle join.
enum LiveFleetMemberMapping {

    static func fleetMember(from summary: VehicleSummary) -> FleetMember {
        let nickname = nonEmpty(summary.name) ?? nonEmpty(summary.model) ?? "Your Tesla"
        // MYR-233: the instant-request gate. Mapped WITHOUT the own-ride
        // exception — this layer sees one list row and knows nothing about the
        // rider's own rides. The exception is folded in exactly once, at the
        // single read seam (`SharedViewerState.liveFleetMember`), so no caller
        // can forget it.
        let unavailability = unavailability(status: summary.status, hasActiveRide: summary.hasActiveRide, rideShareEnabled: summary.rideShareEnabled)
        return FleetMember(
            id: summary.vehicleId,
            owner: nickname, // no owner display name in telemetry — nickname stands in
            relationship: "Your Tesla",
            name: nonEmpty(summary.model) ?? "Tesla",
            model: VehicleContractMapping.modelLabel(year: summary.year, model: "Tesla"),
            colorName: nonEmpty(summary.color) ?? "",
            battery: summary.chargeLevel,
            etaMin: 0, // MYR-341 sentinel — filled at the `liveFleetMember` seam
            plate: VehicleContractMapping.plateDisplay(
                licensePlate: summary.licensePlate, vinLast4: summary.vinLast4
            ),
            // An unavailable vehicle is never "Available now" — fold the gate
            // onto MYR-212's dot/word pair so the row can't say two things.
            isAvailable: unavailability == nil && isAvailable(summary.status),
            availabilityWord: unavailability?.word ?? availabilityWord(summary.status),
            unavailability: unavailability,
            // MYR-316 — the rider-side scheduling floor. Parsed off the list row
            // (contracts 0.17.0), which is the ONLY surface the rider reads: this
            // mapping is built from `GET /api/vehicles`, and the field is
            // snapshot-only by contract, so a floor set by the owner reaches the
            // rider on the next list fetch (or immediately, via the owner fleet's
            // `onServiceWindowSaved` echo, on a single-account device).
            //
            // Deliberately NOT gated on `status == .inService` here: the server
            // already guarantees a non-service row carries null, and re-deriving
            // that guarantee client-side would silently swallow a real value if the
            // two ever disagreed. An unparseable string degrades to nil — "no
            // bound" — never to a fabricated instant.
            serviceEstimatedEndAt: summary.serviceEstimatedEndAt
                .flatMap(VehicleContractMapping.parseTimestamp)
        )
    }

    // MARK: - MYR-233 — the rider availability predicate
    //
    // THE predicate, in one pure function:
    //
    //     hasActiveRide == true || status ∈ { inService, offline }
    //
    // ...minus the own-ride exception. Three deliberate properties:
    //
    //  • TOLERANT DECODE (acceptance criterion 5). `hasActiveRide` is OPTIONAL in
    //    contracts 0.14.0 — an older server omits it entirely. Absence means
    //    "availability unknown", NOT "busy": `hasActiveRide == true` is an
    //    explicit-true test, so `nil` and `false` both read as available. Busy is
    //    NEVER rendered from absence.
    //  • `driving` IS NOT HERE, on purpose. MYR-212 already renders a driving car
    //    with a muted dot + "Driving" (not bookable *now*), but MYR-233's chip +
    //    instant-CTA gate are scoped to the three states the issue names. A car
    //    that is driving on someone's open ride reports `hasActiveRide == true`
    //    anyway and is caught by the first clause; a car merely being driven by
    //    its owner keeps today's behavior untouched.
    //  • MYR-342 — THE PAUSE IS A FOURTH TERM, CHECKED FIRST:
    //
    //        rideShareEnabled == false
    //          || hasActiveRide == true || status ∈ { inService, offline }
    //
    //    ...and it is the only term that is not about the CAR. The other three are
    //    facts the vehicle (or the ride system) reports about itself, and each ends
    //    on its own; this one is the owner's open-ended intention. That is why it
    //    outranks the others and why it alone survives both the own-ride exception
    //    and the scheduled-draft exemption. Same tolerant decode as `hasActiveRide`,
    //    pointing the same way: absence is NEVER the unavailable answer.
    //  • OWN-RIDE EXCEPTION (acceptance criterion 4). The rider holding the open
    //    ride sees their active ride, never Busy — their own ride state takes
    //    precedence client-side (the contract's own consumer guidance). It
    //    suppresses `busy` ONLY: an in_service / offline car is unavailable to
    //    everyone, including the rider mid-ride, and saying otherwise would be
    //    dishonest.

    /// MYR-233 — why `summary` can't take an instant request, or `nil` when it can.
    /// - Parameters:
    ///   - status: the list row's wire status.
    ///   - hasActiveRide: contracts 0.14.0 `VehicleSummary.hasActiveRide`. `nil`
    ///     (older server) is treated as available — never as Busy.
    ///   - rideShareEnabled: contracts 0.20.0 `VehicleSummary.rideShareEnabled`.
    ///     `nil` (older server) and `true` are BOTH available; only an explicit
    ///     `false` is a pause. Checked FIRST — see the body.
    ///   - riderOwnsActiveRide: true when THIS rider owns the vehicle's open ride.
    static func unavailability(
        status: VehicleSummary.Status,
        hasActiveRide: Bool?,
        rideShareEnabled: Bool? = nil,
        riderOwnsActiveRide: Bool = false
    ) -> FleetUnavailability? {
        // MYR-342 — THE PAUSE IS CHECKED FIRST, and the ordering is load-bearing
        // rather than cosmetic.
        //
        // A car can easily be paused AND in service (or offline, or busy). Which
        // reason we name decides which CTA the rider gets, and the two disagree:
        // `inService`/`offline`/`busy` offer "Schedule with … instead", because
        // each of those ENDS on its own and the server accepts a reservation
        // against them (MYR-313). A pause does not end and the server refuses
        // scheduled rides too (rest-api.md §7.18). So naming the vehicle-state
        // reason on a car that is ALSO paused would walk the rider into a
        // scheduling flow ending in `409 vehicle_unavailable`, having filled in a
        // pickup, a time and a passenger first.
        //
        // Explicit `== false`, via the single predicate — NEVER `!= true`. `nil`
        // (a server predating contracts 0.20.0) means ENABLED, and a client that
        // read absence as paused would withdraw every car on every older
        // deployment at once. This is the tolerant-decode rule the contract states
        // in as many words.
        //
        // No `riderOwnsActiveRide` exemption here, deliberately: that exception is
        // about the rider's OWN ride and suppresses `busy` only. A pause is the
        // owner's decision about the car and applies to everyone — offering a rider
        // mid-ride a second request against a withdrawn car would be a lie the
        // server then refuses.
        if VehicleRideShare.isPaused(rideShareEnabled) { return .paused }

        switch status {
        case .inService: return .inService
        case .offline: return .offline
        case .driving, .parked, .charging, .unrecognized:
            // Explicit-true only: `nil`/`false` → available (tolerant decode).
            guard hasActiveRide == true, !riderOwnsActiveRide else { return nil }
            return .busy
        }
    }

    /// Parked / charging read as bookable-now; driving / offline / in-service do
    /// not (drives the green dot + the "now" suffix in the Review vehicle row).
    static func isAvailable(_ status: VehicleSummary.Status) -> Bool {
        switch status {
        case .parked, .charging: return true
        case .driving, .offline, .inService, .unrecognized: return false
        }
    }

    /// The status word shown in the vehicle row — "Available" when bookable,
    /// otherwise the live status (real data, within the design's status-line
    /// slot; no new UI).
    static func availabilityWord(_ status: VehicleSummary.Status) -> String {
        switch status {
        case .parked, .charging: return "Available"
        case .driving: return "Driving"
        case .offline: return "Offline"
        case .inService: return "In service"
        case .unrecognized: return "Unavailable"
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
