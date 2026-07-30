import CoreLocation
@testable import MyRoboTaxi
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-341 — the rider idle ETA ("A ride is N min away")
//
// Three things are pinned here: the GATING MATRIX (what makes the placeholder
// fall back to a plain "Where to?"), the QUANTIZATION STABILITY (the number
// cannot twitch across the 2800ms rotation), and the CONSISTENCY WIRING (Review
// and Booking read the same estimate the placeholder does).
@MainActor
final class RiderPickupETATests: XCTestCase {

    // Financial District ↔ a point ~4 mi north-west.
    private let riderFix = CLLocationCoordinate2D(latitude: 37.7897, longitude: -122.3972)
    private let vehicleFix = CLLocationCoordinate2D(latitude: 37.8010, longitude: -122.4460)

    private func summary(
        status: VehicleSummary.Status = .parked,
        hasActiveRide: Bool? = false
    ) -> VehicleSummary {
        VehicleSummary(vehicleId: "veh-1", name: "Lunar", model: "Model Y", year: 2026,
                       color: "Quicksilver", vinLast4: "2046", status: status, chargeLevel: 68,
                       estimatedRange: 210, lastUpdated: "2026-07-26T12:00:00Z", role: .owner,
                       hasActiveRide: hasActiveRide)
    }

    /// A state wired the way the DEBUG capture scene wires it: live-shaped ETA
    /// resolution, an injected vehicle coordinate, a real-mapped fleet member,
    /// and a device fix through the simulated location seam.
    private func liveShapedState(
        riderFix: CLLocationCoordinate2D?,
        vehicleFix: CLLocationCoordinate2D?,
        status: VehicleSummary.Status = .parked,
        hasActiveRide: Bool? = false
    ) -> SharedViewerState {
        var seams = PlaceSearchComposition.Seams.simulated
        seams.userLocation = SimulatedUserLocation(debugFix: riderFix)
        let state = SharedViewerState(vehicle: VehicleFixtures.vehicles[0], seams: seams)
        state.debugResolvesLivePickupETA = true
        state.debugVehicleCoordinateOverride = vehicleFix
        state.debugFleetMemberOverride = LiveFleetMemberMapping.fleetMember(
            from: summary(status: status, hasActiveRide: hasActiveRide)
        )
        state.refreshPickupETAAnchors()
        return state
    }

    // MARK: - The gating matrix

    /// HAPPY PATH: a device fix, a vehicle coordinate, an available car and no
    /// request in flight → the prototype's second string, on a real number.
    func testHappyPathRestoresTheRotatingETALine() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix)
        let minutes = state.pickupETAMinutes

        XCTAssertNotNil(minutes)
        XCTAssertGreaterThan(minutes ?? 0, 0, "TripEstimate clamps at 1 — a 0 would be a bug, not a short hop")

        let items = RiderIdlePlaceholder.items(
            pickupETAMinutes: minutes, unavailability: nil, hasActiveRequest: false
        )
        XCTAssertEqual(items, ["Where to?", "A ride is \(minutes!) min away"])
        // Copy, exactly (design source screens.jsx:1977-1980).
        XCTAssertEqual(RiderIdlePlaceholder.etaLine(minutes: 3), "A ride is 3 min away")
    }

    /// GATE 1 — no device fix. The rider endpoint is unknown, so there is no
    /// honest number: the placeholder stays plain and stops rotating.
    func testNoUserLocationFixSuppressesTheETA() {
        let state = liveShapedState(riderFix: nil, vehicleFix: vehicleFix)

        XCTAssertNil(state.idleRiderAnchor)
        XCTAssertNil(state.pickupETAMinutes)
        XCTAssertEqual(
            RiderIdlePlaceholder.items(pickupETAMinutes: state.pickupETAMinutes,
                                       unavailability: nil, hasActiveRequest: false),
            ["Where to?"]
        )
    }

    /// GATE 1, the TRAP. `mapRegionCenter` falls back to the vehicle's own
    /// coordinate when there is no device fix, so an implementation that reached
    /// for it would estimate the car's distance to ITSELF and render a confident
    /// "A ride is 1 min away" to a rider whose phone has no location at all.
    /// This pins that the vehicle fallback is excluded: `mapRegionCenter` IS the
    /// vehicle coordinate here, and the ETA is still nil.
    func testVehicleRegionFallbackIsExcludedFromTheRiderEndpoint() {
        let state = liveShapedState(riderFix: nil, vehicleFix: vehicleFix)

        // Precondition: with no fix the map really does center on the vehicle.
        // (`mapRegionCenter` reads the live locator, which the DEBUG override
        // stands in for, so assert the equivalent: a 0-distance estimate WOULD
        // be produced if the vehicle coordinate were used for both endpoints.)
        XCTAssertEqual(RiderPickupETA.minutes(vehicle: vehicleFix, rider: vehicleFix), 1,
                       "the trap: vehicle→itself clamps to a plausible-looking 1 min")
        XCTAssertNil(state.pickupETAMinutes, "the rider endpoint must come from the location seam only")
    }

    /// GATE 2 — the watched vehicle has no coordinate (cold snapshot not landed,
    /// or the contract's 0,0 "no fix"). No number.
    func testUnknownVehicleCoordinateSuppressesTheETA() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: nil)

        XCTAssertNil(state.pickupETAVehicleAnchor)
        XCTAssertNil(state.pickupETAMinutes)
    }

    /// GATE 3 — an unavailable car is not "N min away" at any distance. The
    /// minutes are perfectly computable; the sentence is still false. Runs the
    /// REAL MYR-233 predicate through `LiveFleetMemberMapping` for all three
    /// reasons.
    func testUnavailableVehicleSuppressesTheETALineButNotTheEstimate() {
        for (status, hasRide, expected) in [
            (VehicleSummary.Status.parked, true, FleetUnavailability.busy),
            (VehicleSummary.Status.inService, false, FleetUnavailability.inService),
            (VehicleSummary.Status.offline, false, FleetUnavailability.offline),
        ] {
            let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix,
                                        status: status, hasActiveRide: hasRide)
            XCTAssertEqual(state.liveFleetMember?.unavailability, expected)
            // The estimate itself still exists — the GATE is what suppresses it.
            XCTAssertNotNil(state.pickupETAMinutes)
            XCTAssertEqual(
                RiderIdlePlaceholder.items(pickupETAMinutes: state.pickupETAMinutes,
                                           unavailability: state.liveFleetMember?.unavailability,
                                           hasActiveRequest: false),
                ["Where to?"],
                "\(expected) must not be advertised as N min away"
            )
        }
    }

    /// GATE 4 — a request is already in flight (`reqActive`, screens.jsx:1964).
    /// The prototype hides this whole block; the port keeps the bar but drops the
    /// offer, because the car is already coming to this rider.
    func testActiveRequestSuppressesTheETALine() {
        XCTAssertEqual(
            RiderIdlePlaceholder.items(pickupETAMinutes: 7, unavailability: nil, hasActiveRequest: true),
            ["Where to?"]
        )
    }

    /// A 0 can never reach the copy, even if a caller hands one in.
    func testZeroMinutesIsNeverRendered() {
        XCTAssertEqual(
            RiderIdlePlaceholder.items(pickupETAMinutes: 0, unavailability: nil, hasActiveRequest: false),
            ["Where to?"]
        )
    }

    // MARK: - Quantization + anchor stability (MYR-237 jitter class)

    /// The headline stability guarantee: two fixes 30m apart produce the SAME
    /// placeholder, so the number cannot change under the rotation's crossfade.
    func testTwoFixesThirtyMetresApartYieldTheIdenticalPlaceholder() {
        // ~30m north of the first fix.
        let jittered = CLLocationCoordinate2D(latitude: riderFix.latitude + 0.00027, longitude: riderFix.longitude)
        XCTAssertEqual(LivePinLabeler.distanceMeters(riderFix, jittered), 30, accuracy: 3)

        var anchor = StableFixAnchor()
        anchor.update(riderFix)
        let first = RiderPickupETA.minutes(vehicle: vehicleFix, rider: anchor.anchor)
        anchor.update(jittered)
        let second = RiderPickupETA.minutes(vehicle: vehicleFix, rider: anchor.anchor)

        XCTAssertEqual(first, second)
        XCTAssertEqual(RiderIdlePlaceholder.items(pickupETAMinutes: first, unavailability: nil, hasActiveRequest: false),
                       RiderIdlePlaceholder.items(pickupETAMinutes: second, unavailability: nil, hasActiveRequest: false))
    }

    /// The anchor is LATCHED, not re-quantized per fix — which is what survives
    /// the grid-BOUNDARY case quantization alone leaves open. A whole stream of
    /// sub-threshold jitter leaves the anchor bit-identical.
    func testSubThresholdJitterNeverMovesTheAnchor() {
        var anchor = StableFixAnchor()
        anchor.update(riderFix)
        let seated = anchor.anchor

        for step in 1...20 {
            let noise = Double(step % 5) * 0.0002 - 0.0004 // ±~45m
            anchor.update(CLLocationCoordinate2D(latitude: riderFix.latitude + noise,
                                                 longitude: riderFix.longitude + noise))
        }

        XCTAssertEqual(anchor.anchor?.latitude, seated?.latitude)
        XCTAssertEqual(anchor.anchor?.longitude, seated?.longitude)
    }

    /// A genuinely material move (> one grid cell) DOES re-seat the anchor —
    /// the guard is anti-jitter, not anti-movement.
    func testMaterialMoveReseatsTheAnchor() {
        var anchor = StableFixAnchor()
        anchor.update(riderFix)
        let moved = CLLocationCoordinate2D(latitude: riderFix.latitude + 0.01, longitude: riderFix.longitude) // ~1.1km
        anchor.update(moved)

        XCTAssertEqual(anchor.anchor?.latitude, moved.latitude)
    }

    /// Losing the fix clears the anchor — "no fix" degrades, it does not freeze
    /// the last number on screen.
    func testLosingTheFixClearsTheAnchor() {
        var anchor = StableFixAnchor()
        anchor.update(riderFix)
        anchor.update(nil)
        XCTAssertNil(anchor.anchor)
    }

    /// `quantize` snaps to a ~250m grid: nearby coordinates collapse onto the
    /// same cell, and the cell is idempotent.
    func testQuantizeSnapsToTheGridAndIsIdempotent() {
        let q = RiderPickupETA.quantize(riderFix)
        XCTAssertEqual(RiderPickupETA.quantize(q).latitude, q.latitude, accuracy: 1e-12)
        XCTAssertLessThan(LivePinLabeler.distanceMeters(riderFix, q), RiderPickupETA.anchorGridMeters)
    }

    /// A streaming fix must not WRITE through the state (an observable write per
    /// GPS tick would invalidate the sheet ~1Hz). The anchor property is
    /// unchanged across repeated sub-threshold refreshes.
    func testRefreshingAnchorsUnderJitterDoesNotMoveTheStateAnchor() {
        var seams = PlaceSearchComposition.Seams.simulated
        let location = MutableTestUserLocation(coordinate: riderFix)
        seams.userLocation = location
        let state = SharedViewerState(vehicle: VehicleFixtures.vehicles[0], seams: seams)
        state.debugResolvesLivePickupETA = true
        state.debugVehicleCoordinateOverride = vehicleFix
        state.refreshPickupETAAnchors()
        let seated = state.idleRiderAnchor
        let firstMinutes = state.pickupETAMinutes

        for step in 1...10 {
            location.coordinate = CLLocationCoordinate2D(
                latitude: riderFix.latitude + Double(step) * 0.00002, // ~2m per tick
                longitude: riderFix.longitude
            )
            state.refreshPickupETAAnchors()
        }

        XCTAssertEqual(state.idleRiderAnchor?.latitude, seated?.latitude)
        XCTAssertEqual(state.pickupETAMinutes, firstMinutes)
    }

    // MARK: - Consistency: Review + Booking read the same estimate

    /// The live mapping no longer carries the fixture ETA. This is the MYR-228
    /// leak this issue closes — a fixture 3 quoted about a car nobody measured.
    func testLiveMappingEmitsTheZeroSentinelNotTheFixtureETA() {
        let member = LiveFleetMemberMapping.fleetMember(from: summary())
        XCTAssertEqual(member.etaMin, 0)
        XCTAssertNotEqual(member.etaMin, RideRequestFixtures.fleet[0].etaMin)
    }

    /// The ONE read seam fills the sentinel, so `FleetMember.etaMin` — which
    /// feeds Review's "N min away" and Booking's pickup clock — is the SAME
    /// number the idle placeholder shows.
    func testLiveFleetMemberCarriesTheSameEstimateAsThePlaceholder() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix)
        let placeholderMinutes = state.pickupETAMinutes

        XCTAssertNotNil(placeholderMinutes)
        XCTAssertEqual(state.liveFleetMember?.etaMin, placeholderMinutes)
        XCTAssertEqual(RidePickupETADisplay.awayNote(etaMin: state.liveFleetMember!.etaMin),
                       "\(placeholderMinutes!) min away")
    }

    /// At Review/Booking the rider endpoint is the CONFIRMED pickup, not the
    /// idle anchor — one lineage, so the three surfaces measure to the same
    /// point as the rider advances.
    func testReviewPhaseMeasuresToTheConfirmedPickup() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix)
        let atIdle = state.pickupETAMinutes

        let farPickup = CLLocationCoordinate2D(latitude: 37.6213, longitude: -122.3790) // SFO
        state.draftPickup = RidePlace(id: "pin", label: "Pin", subtitle: nil, miles: 0, minutes: 0,
                                      icon: "mappin.circle.fill", coordinate: farPickup)

        XCTAssertEqual(state.pickupETARiderAnchor?.latitude, farPickup.latitude)
        XCTAssertNotEqual(state.pickupETAMinutes, atIdle)
        XCTAssertEqual(state.pickupETAMinutes, RiderPickupETA.minutes(vehicle: vehicleFix, rider: farPickup))
        XCTAssertEqual(state.liveFleetMember?.etaMin, state.pickupETAMinutes)
    }

    /// MYR-237's `previewPickupAnchor` is preferred over the idle anchor once a
    /// destination is chosen but no pin is dropped — the same anti-jitter anchor
    /// the route preview already uses.
    func testPreviewAnchorIsPreferredOverTheIdleAnchor() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix)
        state.chooseDestination(RideRequestFixtures.recentPlaces[1])

        XCTAssertNotNil(state.previewPickupAnchor)
        XCTAssertEqual(state.pickupETARiderAnchor?.latitude, state.previewPickupAnchor?.latitude)
    }

    /// The 0 sentinel must never render as a number. Both surfaces degrade to a
    /// calm unknown instead of "0 min away" / "arriving now".
    func testZeroSentinelRendersTheCalmUnknownOnReviewAndBooking() {
        XCTAssertEqual(RidePickupETADisplay.clock(etaMin: 0), RidePickupETADisplay.unknownClock)
        XCTAssertEqual(RidePickupETADisplay.clock(etaMin: 0, plus: 28), RidePickupETADisplay.unknownClock)
        XCTAssertNil(RidePickupETADisplay.awayNote(etaMin: 0))
        XCTAssertNil(RidePickupETADisplay.minutes(0))
    }

    // MARK: - The simulated path is untouched (drift gate)

    /// THE DRIFT GATE, asserted rather than photographed. A screenshot of this
    /// element captures the rotation's own crossfade phase, which differs between
    /// two launches of the SAME binary (measured: a base-vs-base control diffs as
    /// much as base-vs-branch), so pixels cannot prove byte-identity here. The
    /// content can: on every simulated boot the seam returns the prototype's own
    /// pair, unchanged, and none of the live machinery is consulted at all.
    func testSimulatedPlaceholderIsTheUnchangedFixturePair() {
        let state = SharedViewerState()
        state.refreshPickupETAAnchors()

        XCTAssertEqual(
            RiderIdlePlaceholder.items(
                resolvesLiveETA: state.resolvesPickupETA,
                pickupETAMinutes: state.pickupETAMinutes,
                unavailability: state.liveFleetMember?.unavailability,
                hasActiveRequest: false
            ),
            ["Where to?", "A ride is 3 min away"]
        )
        // And it stays the fixture pair even if a live-shaped input leaks in —
        // the sim branch is evaluated FIRST.
        XCTAssertEqual(
            RiderIdlePlaceholder.items(resolvesLiveETA: false, pickupETAMinutes: 41,
                                       unavailability: .busy, hasActiveRequest: true),
            ["Where to?", "A ride is 3 min away"]
        )
        XCTAssertEqual(RiderIdlePlaceholder.simulatedETAMinutes, RideRequestFixtures.fleet[0].etaMin)
    }

    /// SIM resolves no ETA at all, so every fixture number — and therefore every
    /// simulated capture — is exactly as before.
    func testSimulatedPathResolvesNoETAAndKeepsFixtureMinutes() {
        let state = SharedViewerState()
        state.refreshPickupETAAnchors()

        XCTAssertFalse(state.resolvesPickupETA)
        XCTAssertNil(state.pickupETAMinutes)
        XCTAssertNil(state.liveFleetMember, "no live member in sim — Review/Booking read the fixture fleet")
        // The fixture fleet still carries the prototype's own minutes.
        XCTAssertEqual(RideRequestFixtures.fleet[0].etaMin, 3)
        XCTAssertEqual(RidePickupETADisplay.awayNote(etaMin: 3), "3 min away")
        XCTAssertEqual(RidePickupETADisplay.clock(etaMin: 3), RideRequestClock.fromNow(minutes: 3))
    }

    /// The seam only fills the SENTINEL — a member that already carries minutes
    /// (every fixture) is returned untouched, the `TripEstimate.applied(to:)`
    /// gate style.
    func testAnExistingETAIsNeverOverwritten() {
        let state = liveShapedState(riderFix: riderFix, vehicleFix: vehicleFix)
        state.debugFleetMemberOverride = RideRequestFixtures.fleet[0] // etaMin 3

        XCTAssertEqual(state.liveFleetMember?.etaMin, 3)
    }
}

/// A `UserLocationProviding` whose fix can be moved from a test — the streaming
/// case `SimulatedUserLocation(debugFix:)` (a `let`) can't express.
@Observable
@MainActor
private final class MutableTestUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { false }
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    func start() {}
    func stop() {}
    func refresh() {}
}
