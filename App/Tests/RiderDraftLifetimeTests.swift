import CoreLocation
@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-389 — the draft trip does not outlive the flow that made it
//
// r15 (build 202607311129): tapping the idle map's "Where to?" reopened the
// PREVIOUS booking attempt — destination filled, schedule latched, old route
// drawing behind the sheet. *"when I tried to search it pulled up a prev route,
// the state wasn't reset to a clean search."*
//
// `RiderDraftLifetimeUITests` proves the client's SEQUENCE with real taps. These
// pin the INVARIANT that makes the sequence impossible: entering the flow from
// idle starts from nothing, whatever the last flow left behind and however it
// left. That distinction matters — a per-exit fix is only ever as good as the
// exits that existed when it was written, and the exit that shipped this bug was
// added three issues after `resetDraftToIdle` was.

/// A device fix, so `capturePreviewPickupAnchor` has something to anchor.
private final class DraftLifetimeUserLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { true }
    func start() {}
    func stop() {}
    func refresh() {}
}

@MainActor
final class RiderDraftLifetimeTests: XCTestCase {

    /// A draft mid-flow with EVERY field populated — the state the client's 12:46
    /// attempt left behind. Deliberately built through the shipping mutators where
    /// they exist (`chooseDestination` is what anchors `previewPickupAnchor`), so
    /// the test seeds the draft the way the app does.
    private func makeAbandonedDraft() -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: DraftLifetimeUserLocation(
                coordinate: CLLocationCoordinate2D(latitude: 37.7899, longitude: -122.3969)
            ),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: false
        )
        let state = SharedViewerState(seams: seams)
        state.chooseDestination(RideRequestFixtures.recentPlaces[1]) // anchors the pickup
        state.draftPickup = RideRequestFixtures.savedPlaces[0]
        state.draftFleetMemberID = RideRequestFixtures.fleet[2].id
        state.draftPassenger = RidePassenger(name: "Mira", phone: "+15551234567")
        state.draftSchedule = RideSchedule(day: "Tomorrow", time: "12:00 PM")
        state.opensScheduleOnSearch = true
        state.scheduleReturn = .review
        state.pinReturn = .review
        state.showDeclinedNotice = true
        state.sheetPhase = .idle // the flow was left; the draft was not
        return state
    }

    private func assertClean(_ state: SharedViewerState, _ what: String) {
        XCTAssertNil(state.draftDestination, "\(what): destination")
        XCTAssertNil(state.draftPickup, "\(what): pickup")
        XCTAssertNil(state.draftPassenger, "\(what): passenger")
        XCTAssertNil(state.draftSchedule, "\(what): the schedule latch")
        XCTAssertNil(state.previewPickupAnchor, "\(what): the pickup anchor")
        XCTAssertEqual(state.draftFleetMemberID, RideRequestFixtures.fleet[0].id, "\(what): vehicle")
        XCTAssertFalse(state.opensScheduleOnSearch, "\(what): the one-shot schedule route")
        XCTAssertEqual(state.scheduleReturn, .search, "\(what): where the card returns to")
        XCTAssertEqual(state.pinReturn, .search, "\(what): where the pin returns to")
        XCTAssertFalse(state.showDeclinedNotice, "\(what): the declined notice")
    }

    // MARK: The entry invariant

    /// The client's tap. Everything the last flow left is gone, and the sheet that
    /// opens is Search.
    func testTappingWhereToStartsFromNothing() {
        let state = makeAbandonedDraft()
        state.enterSearchFromIdle()
        XCTAssertEqual(state.sheetPhase, .search)
        assertClean(state, "entering search from idle")
    }

    /// The DRAG-open is the same door. `RiderIdleSearchSheet.commitSettle` used to
    /// commit a bare `sheetPhase = .search`; if only the tap were fixed the two
    /// gestures on one affordance would disagree.
    func testTheScheduleLatchSpecificallyDoesNotSurvive() {
        let state = makeAbandonedDraft()
        XCTAssertNotNil(state.draftSchedule, "precondition: the latch is up")
        state.enterSearchFromIdle()
        XCTAssertNil(
            state.draftSchedule,
            "the visibly stale half of the client's frame — 'Pickup Tomorrow · 12:00 PM' over a fresh search"
        )
    }

    /// The Home/Work chips enter the flow WITH a destination. That destination is
    /// the only thing that may survive the entry.
    func testAQuickChipCarriesItsDestinationAndNothingElse() {
        let state = makeAbandonedDraft()
        let home = RideRequestFixtures.savedPlaces[0]
        state.selectDestinationFromIdle(home)
        XCTAssertEqual(state.draftDestination?.id, home.id, "the chip's own destination is the point")
        XCTAssertNil(state.draftSchedule, "a stale schedule must not become part of a brand-new trip")
        XCTAssertNil(state.draftPassenger, "nor a stale passenger")
        XCTAssertEqual(state.draftFleetMemberID, RideRequestFixtures.fleet[0].id)
    }

    // MARK: Every exit path, then the entry

    /// The invariant is stated over the EXITS to make the "covers ones added later"
    /// claim concrete: whichever way the flow ended — the search sheet collapsing,
    /// Review's ✕, the pin-drop cancel, Review's scheduled submit (the one that
    /// leaked), or a bare phase flip nobody has written yet — the next entry is
    /// clean, because the entry does not consult how it ended.
    func testEveryExitLeavesTheNextSearchClean() {
        let exits: [(String, (SharedViewerState) -> Void)] = [
            ("resetDraftToIdle (search collapse / ✕ / pin-drop cancel)", { $0.resetDraftToIdle() }),
            ("the scheduled submit's return to idle", { $0.resetDraftToIdle() }),
            ("a bare phase flip that clears nothing (the shipped defect)", { $0.sheetPhase = .idle }),
        ]
        for (name, exit) in exits {
            let state = makeAbandonedDraft()
            state.sheetPhase = .review
            exit(state)
            state.enterSearchFromIdle()
            assertClean(state, "after \(name)")
            XCTAssertEqual(state.sheetPhase, .search, "after \(name)")
        }
    }

    /// `resetDraftToIdle` forgot ONE field, and it is the one with no visible
    /// symptom of its own: the pickup ANCHOR keys the route cache, so a cleared
    /// draft could still be routing from the previous trip's pickup until a new
    /// destination re-anchored it (`capturePreviewPickupAnchor` only writes into a
    /// nil anchor). Both resets go through the same list now.
    func testTheResetClearsThePickupAnchorItUsedToLeaveBehind() {
        let state = makeAbandonedDraft()
        XCTAssertNotNil(state.previewPickupAnchor, "precondition: an anchor was captured")
        state.resetDraftToIdle()
        XCTAssertNil(state.previewPickupAnchor)
        XCTAssertEqual(state.sheetPhase, .idle)
    }

    // MARK: The scope guard — a SUBMITTED ride is not a draft

    /// Discarding the draft must not touch the rider's active slot. The reservation
    /// they just booked keeps existing, keeps holding the slot, and keeps resuming
    /// its own surface; it is simply no longer something the search sheet can
    /// re-open and re-submit.
    func testTheActiveRideSurvivesTheEntryReset() {
        let service = SimulatedRideRequestService()
        service.submit(RideRequestInput(
            pickup: RideRequestFixtures.savedPlaces[0],
            destination: RideRequestFixtures.recentPlaces[1],
            fleetMemberID: RideRequestFixtures.fleet[0].id,
            passenger: nil,
            schedule: RideSchedule(day: "Tomorrow", time: "12:00 PM"),
            requesterName: nil
        ))
        let submitted = service.activeRequest
        XCTAssertNotNil(submitted, "precondition: the reservation holds the slot")

        let state = makeAbandonedDraft()
        state.enterSearchFromIdle()

        XCTAssertEqual(service.activeRequest?.id, submitted?.id, "the booked reservation is untouched")
        XCTAssertEqual(service.activeRequest?.status, .pending)
        service.cancel() // don't leave the auto-accept timer armed
    }

    /// And the surface it resumes to is unchanged: an accepted LIVE ride still
    /// takes the rider to tracking from idle, entry reset or not. (The pure
    /// mapping is the thing that decides it — `enterSearchFromIdle` has no say.)
    func testAnAcceptedRideStillClaimsItsSurface() {
        let record = RideRequestRecord(
            input: RideRequestInput(
                pickup: RideRequestFixtures.savedPlaces[0],
                destination: RideRequestFixtures.recentPlaces[1],
                fleetMemberID: RideRequestFixtures.fleet[0].id,
                passenger: nil,
                schedule: nil,
                requesterName: nil
            ),
            status: .accepted
        )
        XCTAssertEqual(
            SharedViewerScreen.reconciledPhase(
                status: .accepted,
                isDormantReservation: RideReservation.isDormant(record),
                current: .idle,
                isAcknowledgedDecline: false
            ),
            .tracking,
            "the scope guard: a live ride still takes over from idle"
        )
    }

    // MARK: The route half

    /// A SEARCH may not take its route endpoints from any record — not a dead one
    /// (MYR-381) and not a live one either. Otherwise the sheet opens clean and the
    /// map behind it keeps drawing the reservation the rider just booked.
    func testTheSearchPreviewTakesNoEndpointsFromALiveRide() {
        let live = RideRequestRecord(
            input: RideRequestInput(
                pickup: RideRequestFixtures.savedPlaces[0],
                destination: RideRequestFixtures.recentPlaces[1],
                fleetMemberID: RideRequestFixtures.fleet[0].id,
                passenger: nil,
                schedule: nil,
                requesterName: nil
            ),
            status: .pending
        )
        XCTAssertNil(
            SharedViewerScreen.previewRouteRequest(phase: .search, liveRequest: live),
            "on search the only trip is the one being typed"
        )
        for phase: RiderSheetPhase in [.review, .booking, .tracking, .summary, .idle] {
            XCTAssertEqual(
                SharedViewerScreen.previewRouteRequest(phase: phase, liveRequest: live)?.id,
                live.id,
                "\(phase): the submitted record IS the trip on these surfaces — MYR-381's rule is unchanged"
            )
        }
    }
}
