import CoreLocation
import DesignSystem
@testable import MyRoboTaxi
import MyRobotaxiContracts
import SwiftUI
import XCTest

// MARK: - MYR-294 — the honest driving hero
//
// TestFlight, build 202607252156, three separate submissions:
//   • *"When no navigation, state just shows navigating — maybe remove that"*
//   • *"Taking a long time to populate destination name even though route
//     appeared"*
//   • *"I don't like the dot next to the destination."*
//
// One cause behind all three: `DrivingTrip.destinationName` was a non-optional
// `String`, so the live mapping substituted the literal `"Navigating"` whenever
// the wire had no name — and the hero, having no way to know the difference,
// wrapped that word in a whole fabricated trip: an arrival row computed from an
// `etaMinutes` that collapses absent to 0, an "ETA" of `Date() + 0`, a trip
// progress bar at its 5% clamp, and a Route leg reading `"· "` because
// `destinationCity` is parsed from an address the wire never live-broadcasts.
//
// These tests are about the WIRE → STATE decision (`navigation(from:)`), the two
// gates the hero applies to it, and the join that produced the stray separator.
// The BAND the resulting hero occupies is pinned separately, in
// `OwnerPeekBandTests`, against the real rendered view.

final class DrivingNavigationMappingTests: XCTestCase {

    /// A driving `VehicleState` with every navigation-group member null — what
    /// the server sends after `navClearFields`, and what a car that is simply
    /// being driven reports all day.
    private func drivingState(
        destinationName: String? = nil,
        destinationAddress: String? = nil,
        destinationLatitude: Double? = nil,
        destinationLongitude: Double? = nil,
        etaMinutes: Int? = nil,
        tripDistanceRemaining: Double? = nil,
        navRouteCoordinates: [[Double]]? = nil
    ) -> VehicleState {
        var state = VehicleState(
            vehicleId: "v",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            status: .driving,
            speed: 38,
            heading: 214,
            latitude: 37.7749,
            longitude: -122.4194,
            locationName: "Market St \u{00B7} San Francisco",
            locationAddress: "798 Market St, San Francisco",
            chargeLevel: 64,
            estimatedRange: 174,
            interiorTemp: 68,
            exteriorTemp: 61,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: "2026-07-27T10:00:00Z"
        )
        state.destinationName = destinationName
        state.destinationAddress = destinationAddress
        state.destinationLatitude = destinationLatitude
        state.destinationLongitude = destinationLongitude
        state.etaMinutes = etaMinutes
        state.tripDistanceRemaining = tripDistanceRemaining
        state.navRouteCoordinates = navRouteCoordinates
        return state
    }

    // MARK: The client's first report

    /// THE DEFECT. An all-null navigation group is *"Null = no active
    /// navigation"* by the contract's own words, and there is no name to print.
    /// Before this issue the same state produced `destinationName == "Navigating"`
    /// — a word Tesla never sent, rendered as a 28pt destination headline.
    func testNoNavigationFieldsAtAllMeansNoNavigation() {
        let trip = VehicleContractMapping.drivingTrip(from: drivingState())
        XCTAssertEqual(trip.navigation, .none)
        XCTAssertFalse(trip.navigation.isActive)
        XCTAssertNil(trip.destinationName, "there is no destination, so there is no name — not even a stand-in")
        XCTAssertNil(trip.destinationCity)
        XCTAssertNil(trip.destinationAddress)
    }

    /// The word itself, nowhere. A grep-proof assertion: the literal was the whole
    /// defect, and it could come back as a `??` on any of three fields.
    func testTheLiteralNavigatingIsNeverProduced() {
        for state in [drivingState(), drivingState(navRouteCoordinates: [[-122.41, 37.77], [-122.40, 37.80]])] {
            let trip = VehicleContractMapping.drivingTrip(from: state)
            XCTAssertNotEqual(trip.destinationName, "Navigating")
            XCTAssertNotEqual(trip.destinationCity, "Navigating")
        }
    }

    // MARK: The client's second report

    /// *"Taking a long time to populate destination name even though route
    /// appeared."* Tesla emits `RouteLine` and `DestinationName` independently, so
    /// the route (and the ETA, and the destination coordinates) routinely land up
    /// to ~60s before the name. Navigation is ON; only the name is pending.
    func testARouteWithoutANameIsNavigationStillResolving() {
        let state = drivingState(
            destinationLatitude: 37.8087,
            destinationLongitude: -122.4098,
            etaMinutes: 12,
            tripDistanceRemaining: 3.4,
            navRouteCoordinates: [[-122.4194, 37.7749], [-122.4098, 37.8087]]
        )
        let trip = VehicleContractMapping.drivingTrip(from: state)
        XCTAssertEqual(trip.navigation, .resolvingDestination)
        XCTAssertTrue(trip.navigation.isActive, "the trip is real — it is the NAME that is missing")
        XCTAssertNil(trip.destinationName)
    }

    /// Gating on `destinationName` alone — the obvious implementation — would
    /// classify the first minute of every real trip as "not navigating" and tear
    /// the hero down and back up again. Each nav member ALONE is enough.
    func testAnyLoneNavigationMemberMeansNavigationIsOn() {
        let cases: [(String, VehicleState)] = [
            ("navRouteCoordinates", drivingState(navRouteCoordinates: [[-122.41, 37.77], [-122.40, 37.80]])),
            ("etaMinutes", drivingState(etaMinutes: 9)),
            ("tripDistanceRemaining", drivingState(tripDistanceRemaining: 2.2)),
            ("destinationLatitude", drivingState(destinationLatitude: 37.8087)),
            ("destinationLongitude", drivingState(destinationLongitude: -122.4098)),
            ("destinationAddress", drivingState(destinationAddress: "1 Ferry Building, San Francisco")),
        ]
        for (name, state) in cases {
            XCTAssertTrue(
                VehicleContractMapping.navigation(from: state).isActive,
                "\(name) alone must count as active navigation"
            )
        }
    }

    /// A BLANK name is a missing name, not a destination called "". It resolves
    /// to the same `.resolvingDestination` state, never to an empty 28pt
    /// headline.
    func testABlankDestinationNameResolvesToResolvingDestination() {
        let state = drivingState(destinationName: "   ", navRouteCoordinates: [[-122.41, 37.77], [-122.40, 37.80]])
        XCTAssertEqual(VehicleContractMapping.navigation(from: state), .resolvingDestination)
    }

    /// The named case, unchanged — the city parsed out of the address, both
    /// carried through.
    func testANamedDestinationCarriesItsCityAndAddress() {
        let state = drivingState(
            destinationName: "Duarte's Tavern",
            destinationAddress: "202 Stage Rd, Pescadero, CA",
            navRouteCoordinates: [[-122.41, 37.77], [-122.40, 37.80]]
        )
        let trip = VehicleContractMapping.drivingTrip(from: state)
        XCTAssertEqual(trip.destinationName, "Duarte's Tavern")
        XCTAssertEqual(trip.destinationCity, "Pescadero")
        XCTAssertEqual(trip.destinationAddress, "202 Stage Rd, Pescadero, CA")
    }

    /// The lean list row carries NO navigation fields, so the honest placeholder
    /// is "we know of none" — it used to be the `"Navigating"` literal, which is
    /// how a car whose snapshot had not arrived yet got a destination headline
    /// before the app had heard one word about its navigation.
    func testThePlaceholderActivityClaimsNoNavigation() {
        let summary = VehicleSummary(
            vehicleId: "v", name: "Lunar", model: "Model Y", year: 2026, color: "",
            vinLast4: "3456", status: .driving, chargeLevel: 64, estimatedRange: 174,
            lastUpdated: "2026-07-27T10:00:00Z", role: .owner, licensePlate: nil
        )
        guard case .driving(let trip) = VehicleContractMapping.placeholderActivity(for: summary) else {
            return XCTFail("a driving summary still builds a driving activity")
        }
        XCTAssertEqual(trip.navigation, .none)
    }

    /// A blank `locationAddress` is no address — the origin leg omits its second
    /// line rather than rendering an empty one.
    func testABlankOriginAddressBecomesNoSubtitle() {
        var state = drivingState()
        state.locationAddress = ""
        XCTAssertNil(VehicleContractMapping.drivingTrip(from: state).originAddress)
    }
}

// MARK: - The stray separator (the client's third report)

final class DrivingRouteLegTitleTests: XCTestCase {

    /// *"I don't like the dot next to the destination."* The row interpolated
    /// `"\(city) · \(name)"` unconditionally, and `city` is derived from
    /// `destinationAddress` — which the telemetry writer persists but does NOT put
    /// on the navigation group's live broadcast. So on a WS-driven trip the name
    /// was present, the city was empty, and the leg read "· Local Creamery".
    func testASeparatorOnlyEverSitsBetweenTwoPresentParts() {
        XCTAssertEqual(DrivingRouteLegTitle.compose(city: nil, name: "Local Creamery"), "Local Creamery")
        XCTAssertEqual(DrivingRouteLegTitle.compose(city: "", name: "Local Creamery"), "Local Creamery")
        XCTAssertEqual(DrivingRouteLegTitle.compose(city: "   ", name: "Local Creamery"), "Local Creamery")
        XCTAssertEqual(DrivingRouteLegTitle.compose(city: "Pescadero", name: nil), "Pescadero")
        XCTAssertEqual(
            DrivingRouteLegTitle.compose(city: "Pescadero", name: "Duarte's Tavern"),
            "Pescadero \u{00B7} Duarte's Tavern",
            "the prototype's own join, unchanged when both halves exist"
        )
    }

    /// Neither half ⇒ no title at all, which is what drops the whole Route
    /// section rather than rendering an empty line or a bare separator.
    func testNoPartsAtAllMeansNoTitle() {
        XCTAssertNil(DrivingRouteLegTitle.compose(city: nil, name: nil))
        XCTAssertNil(DrivingRouteLegTitle.compose(city: "", name: "  "))
    }
}

// MARK: - What the hero renders (MYR-294, and the client's skeleton amendment)
//
// The client, watching the first build of this branch on a simulator: *"why are
// you skeleton loading when no route that looks so weird and useless"*, then the
// rule: *"if no route then no need to show a route, if a route is about to arrive
// then sure thats fine bc we're loading something"*. The test is whether a fetch
// is ACTUALLY RUNNING — and for the destination name, none ever is.

final class DrivingHeroElementTests: XCTestCase {

    private let named = DrivingNavigation.destination(name: "Duarte's Tavern", city: "Pescadero", address: nil)

    // MARK: THE CLIENT'S RULE

    /// **NO PLACEHOLDER EXISTS.** The vocabulary this hero can render has no
    /// skeleton, shimmer or stand-in member at all — so "we shimmered something
    /// nobody is fetching" is unreachable by construction rather than by care, and
    /// a future change cannot reintroduce it without deleting this assertion.
    func testTheHeroHasNoPlaceholderElementToRender() {
        let names = DrivingHeroElement.allCases.map { String(describing: $0).lowercased() }
        for forbidden in ["skeleton", "shimmer", "placeholder", "loading", "pending"] {
            XCTAssertFalse(
                names.contains { $0.contains(forbidden) },
                "the driving hero grew a '\(forbidden)' element — nothing here is ever fetched, so nothing here may promise arrival"
            )
        }
    }

    /// NO NAVIGATION ⇒ no route UI of any kind. Not a dimmed one, not a
    /// placeholder one: the destination title, the arrival pair, the trip progress
    /// bar and the whole Route section are all absent. What is left is what is
    /// true — the speed, and the street the car is on.
    func testNoNavigationRendersNoRouteUIAtAll() {
        let e = DrivingHeroElement.resolve(navigation: .none, etaMinutes: 12, progress: 0.42)
        XCTAssertEqual(e, [.speed, .location])
        XCTAssertFalse(e.contains(.destinationTitle))
        XCTAssertFalse(e.contains(.arrival), "a stale ETA outliving a cancelled nav is still not an arrival")
        XCTAssertFalse(e.contains(.progressBar), "no journey ⇒ no progress along one")
        XCTAssertFalse(e.contains(.routeSection))
    }

    /// NAVIGATION ON, NAME NOT SENT — the state the skeleton used to occupy.
    /// Everything the wire genuinely carries stays (speed, the real ETA, the real
    /// progress bar); the two things that need a NAME are simply absent. Nothing
    /// stands in for them.
    func testAnUnnamedDestinationShowsTheRealTripAndNoStandIn() {
        let e = DrivingHeroElement.resolve(navigation: .resolvingDestination, etaMinutes: 12, progress: 0.42)
        XCTAssertEqual(e, [.speed, .arrival, .progressBar])
        XCTAssertFalse(e.contains(.destinationTitle), "no name ⇒ no headline, and no placeholder for one")
        XCTAssertFalse(e.contains(.routeSection), "a two-ended section with one unnameable end is not rendered")
    }

    /// The LOCATION line is the hero's fallback SUBJECT, not an extra line: it
    /// appears exactly when there is neither a destination to name nor an arrival
    /// to state, so the hero always has something to be about.
    ///
    /// Stating the rule that way (rather than "navigation is off") is what keeps
    /// the peek band to two driving values — see `DrivingHeroPeekBaseTests`. A
    /// `.resolvingDestination` that has landed NOTHING yet renders the same shape
    /// `.none` does and must take the same band with it.
    func testTheLocationLineAppearsExactlyWhenTheHeroHasNothingElseToSay() {
        // Nothing landed under live navigation ⇒ same shape as no navigation.
        XCTAssertEqual(
            DrivingHeroElement.resolve(navigation: .resolvingDestination, etaMinutes: 0, progress: 0),
            [.speed, .location]
        )
        // An arrival to state ⇒ the trip is the subject.
        XCTAssertFalse(
            DrivingHeroElement.resolve(navigation: .resolvingDestination, etaMinutes: 12, progress: 0).contains(.location)
        )
        // A destination to name ⇒ likewise.
        XCTAssertFalse(
            DrivingHeroElement.resolve(navigation: named, etaMinutes: 0, progress: 0).contains(.location)
        )
    }

    /// The named case — every simulated hero, and the drift gate depends on it
    /// rendering exactly what it always did.
    func testANamedDestinationRendersTheWholeTripHero() {
        let e = DrivingHeroElement.resolve(navigation: named, etaMinutes: 87, progress: 0.42)
        XCTAssertEqual(e, [.speed, .destinationTitle, .arrival, .progressBar, .routeSection])
        XCTAssertFalse(e.contains(.location), "with a journey to describe, the hero describes the journey")
    }

    // MARK: The per-element gates

    /// `etaMinutes` collapses an absent wire value to 0, and 0 is reachable with
    /// navigation genuinely on (its group members may arrive apart inside the
    /// server's 500ms accumulation window). It used to render "Arriving in 0 min"
    /// beside an "ETA" of `Date() + 0` — i.e. now.
    func testNoRealETAMeansNoArrivalRowEvenUnderLiveNavigation() {
        XCTAssertFalse(DrivingHeroElement.resolve(navigation: named, etaMinutes: 0, progress: 0.42).contains(.arrival))
        XCTAssertFalse(DrivingHeroElement.resolve(navigation: .resolvingDestination, etaMinutes: 0, progress: 0.42).contains(.arrival))
    }

    /// `TripProgressBar` CLAMPS to 0.05, so a 0 progress draws its orb 5% along
    /// the journey. Under live navigation that is a fabricated POSITION; with no
    /// navigation it is a fabricated journey as well.
    func testAZeroProgressFractionDrawsNoProgressBar() {
        XCTAssertFalse(DrivingHeroElement.resolve(navigation: named, etaMinutes: 87, progress: 0).contains(.progressBar))
        XCTAssertTrue(DrivingHeroElement.resolve(navigation: named, etaMinutes: 87, progress: 0.01).contains(.progressBar))
    }

    /// The speed is the one element with no gate — it is true of a car in motion
    /// whatever else is or is not known, which is why it becomes the headline.
    func testTheSpeedIsAlwaysPresent() {
        for nav in [DrivingNavigation.none, .resolvingDestination, named] {
            XCTAssertTrue(DrivingHeroElement.resolve(navigation: nav, etaMinutes: 0, progress: 0).contains(.speed))
        }
    }
}

// MARK: - The peek band picks the hero it is actually rendering

@MainActor
final class DrivingHeroPeekBaseTests: XCTestCase {

    private func snapshot(driving: Bool) -> VehicleTelemetrySnapshot {
        VehicleTelemetrySnapshot(
            status: driving ? .driving : .parked,
            progress: driving ? 0.42 : 0,
            speedMPH: driving ? 38 : 0,
            batteryPercent: 80,
            etaMinutes: driving ? 12 : 0
        )
    }

    private func vehicle(navigation: DrivingNavigation) -> Vehicle {
        Vehicle(
            id: "v", name: "Lunar", model: "Model Y", colorName: "", plate: "",
            seatHeat: false, seatClimate: .unknown,
            activity: .driving(DrivingTrip(
                navigation: navigation,
                originLabel: "Market St",
                originAddress: nil,
                route: []
            ))
        )
    }

    /// A parked car and a navigating car keep the prototype's own bands — this is
    /// the whole simulated drift gate, since every fixture trip is `.destination`.
    func testThePrototypeBandsAreUntouched() {
        let parked = VehicleFixtures.vehicles.first { !$0.activity.isDriving }!
        XCTAssertEqual(HomeScreen.peekBase(vehicle: parked, snapshot: snapshot(driving: false)), MRTMetrics.homePeekHeightParked)

        let driving = VehicleFixtures.vehicles.first { $0.activity.isDriving }!
        XCTAssertEqual(HomeScreen.peekBase(vehicle: driving, snapshot: snapshot(driving: true)), MRTMetrics.homePeekHeightDriving)
    }

    /// The honest hero is a THIRD block of content and takes its own band. Leaving
    /// it on 280 would drop every point the missing rows used to occupy into the
    /// gap above the floating nav — MYR-345's defect, arrived at from the other
    /// direction.
    func testTheNoNavigationHeroTakesItsOwnBand() {
        XCTAssertEqual(
            HomeScreen.peekBase(vehicle: vehicle(navigation: .none), snapshot: snapshot(driving: true)),
            MRTMetrics.homePeekHeightDrivingNoNavigation
        )
        XCTAssertLessThan(MRTMetrics.homePeekHeightDrivingNoNavigation, MRTMetrics.homePeekHeightDriving)
        XCTAssertGreaterThan(MRTMetrics.homePeekHeightDrivingNoNavigation, MRTMetrics.homePeekHeightParked)
    }

    /// A trip whose NAME is pending, with its ETA and progress landed, renders the
    /// full trip hero and keeps the full driving band — only the headline differs,
    /// so the sheet does not jump the moment Tesla sends the name.
    func testAResolvingDestinationWithARealTripKeepsTheFullDrivingBand() {
        XCTAssertEqual(
            HomeScreen.peekBase(vehicle: vehicle(navigation: .resolvingDestination), snapshot: snapshot(driving: true)),
            MRTMetrics.homePeekHeightDriving
        )
    }

    /// …but one that has landed NOTHING yet renders the same shape `.none` does —
    /// just a speed and a street — and must take the same band. Deriving the band
    /// from the navigation CASE instead of the rendered elements put a measured
    /// 40pt hole under exactly this state.
    func testAResolvingDestinationWithNothingLandedTakesTheShortBand() {
        var snap = snapshot(driving: true)
        snap.etaMinutes = 0
        snap.progress = 0
        XCTAssertEqual(
            HomeScreen.peekBase(vehicle: vehicle(navigation: .resolvingDestination), snapshot: snap),
            MRTMetrics.homePeekHeightDrivingNoNavigation
        )
    }

    /// The band follows the SNAPSHOT's status first: a car whose snapshot says
    /// parked is a parked hero whatever stale activity it is carrying.
    func testAParkedSnapshotIsAParkedBandRegardlessOfActivity() {
        XCTAssertEqual(
            HomeScreen.peekBase(vehicle: vehicle(navigation: .none), snapshot: snapshot(driving: false)),
            MRTMetrics.homePeekHeightParked
        )
    }
}
