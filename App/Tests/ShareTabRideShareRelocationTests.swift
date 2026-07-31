import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-369 fix round — what the relocation dropped on the way across
//
// MYR-342 drew the owner's ride-share switch as the last row of the owner sheet's
// "Status & location" card. MYR-358 then made that row DERIVE its position: while
// the car is in a service bay the switch renders OFF and inert with its own
// caption, the owner's stored preference is untouched underneath, and nothing is
// written on either transition. MYR-369 moved the control to the top of the Share
// tab — and the new card read the stored value straight through.
//
// TWO THINGS WENT MISSING, and neither had a compiler signature:
//
//   1. **THE DERIVATION.** `VehicleRideShare.display` kept passing its own unit
//      tests while having ZERO call sites in shipping code. A pure function with
//      good tests and no callers is the quietest possible regression: every
//      assertion about it stays green while the behaviour it describes is gone
//      from the product. So these tests assert through the SERVICE and the ROW —
//      the things a screen actually renders — rather than through the pure
//      function a second time.
//   2. **THE PRE-FLIGHT.** MYR-360's reservation warning was bound to the
//      per-vehicle `VehicleCommandExecutor`, which the Share tab does not have, so
//      turning ride sharing off stopped asking about booked riders entirely.
//
// The guard against both regressing again is structural rather than diligent:
// `VehicleRideShareRow` DERIVES its rendering instead of storing it, so a row
// cannot be built holding a position that disagrees with its own facts, and
// `RideSharePauseFlow` commits through a seam both surfaces supply.
@MainActor
final class ShareTabRideShareRelocationTests: XCTestCase {

    // MARK: - Harness

    /// A §7.18 stand-in that records every write, so "no write fired" is asserted
    /// on the WIRE rather than on a flag.
    private final class RecordingRideShareEndpoint: VehicleRideShareEndpoint, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var writes: [(vehicleID: String, enabled: Bool)] = []
        var failure: Error?

        func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
            lock.lock(); writes.append((vehicleID, enabled)); lock.unlock()
            if let failure { throw failure }
            return VehicleRideShareResponse(vehicleId: vehicleID, enabled: enabled)
        }
    }

    /// One owned car, with the two facts that decide the switch.
    private func vehicle(storedEnabled: Bool?, inService: Bool) -> Vehicle {
        let base = VehicleFixtures.vehicles[0]
        return Vehicle(
            id: base.id, name: base.name, model: base.model, colorName: base.colorName,
            plate: base.plate, seatHeat: base.seatHeat, seatVent: base.seatVent,
            activity: base.activity,
            rideShareEnabled: storedEnabled,
            isInService: inService
        )
    }

    private func makeService(
        storedEnabled: Bool?,
        inService: Bool,
        rideShare: RecordingRideShareEndpoint = RecordingRideShareEndpoint()
    ) -> LiveShareService {
        // `ScriptedShareEndpoint` is `VehicleSharingTests`' own §7.5 stub, reused
        // rather than re-stubbed — the §7.5 listing is not the subject of any
        // assertion here and a second hand-written conformance is a second thing
        // to keep in step with the protocol.
        LiveShareService(
            api: ScriptedShareEndpoint(),
            rideShareAPI: rideShare,
            ownedVehicles: { [self.vehicle(storedEnabled: storedEnabled, inService: inService)] }
        )
    }

    // MARK: - 1. The derived-off resolution, IN ITS NEW LOCATION

    /// THE REGRESSION, stated as directly as it can be: a car in a service bay,
    /// whose owner has ride sharing switched ON, must render OFF and inert on the
    /// Share tab's relocated card.
    ///
    /// Asserted through `LiveShareService.vehicleRideShare` — the exact property
    /// `InvitesScreen` renders — because that is where the derivation was lost. The
    /// pure `VehicleRideShare.display` never stopped being correct.
    func testInServiceRendersOffAndInertOnTheRelocatedCard() {
        let service = makeService(storedEnabled: true, inService: true)
        let row = service.vehicleRideShare.first

        XCTAssertEqual(row?.isEnabled, false, "a car in a service bay must not advertise rides")
        XCTAssertEqual(row?.isInteractive, false, "and the switch must not be movable")
        XCTAssertEqual(row?.caption, VehicleRideShare.inServiceCaption)
    }

    /// The derivation must hold for BOTH stored values, and the `true` case is the
    /// one that matters: a car whose owner never paused it is the common case, and
    /// it is the one that rendered an ON switch on a car sitting in a workshop.
    ///
    /// A `false` stored value renders off too — but for a DIFFERENT reason, and the
    /// caption is what distinguishes them.
    func testInServiceRendersOffForEveryStoredValue() {
        for stored in [true, false] {
            let row = makeService(storedEnabled: stored, inService: true).vehicleRideShare.first
            XCTAssertEqual(row?.isEnabled, false, "stored = \(stored)")
            XCTAssertEqual(row?.isInteractive, false, "stored = \(stored)")
            XCTAssertEqual(
                row?.caption, VehicleRideShare.inServiceCaption,
                "stored = \(stored): in service is named as such, never as the owner's pause"
            )
        }
    }

    /// **THE PREFERENCE SURVIVES THE VISIT.** The row renders off while the car is
    /// in service AND still carries the owner's stored ON underneath it, so the
    /// switch returns to where they left it the moment the visit ends.
    ///
    /// This is the assertion that separates a DERIVATION from a write: an
    /// implementation that "just wrote false on entry" would pass every rendering
    /// test above and fail this one.
    func testTheStoredPreferenceSurvivesTheServiceVisit() {
        let inService = makeService(storedEnabled: true, inService: true).vehicleRideShare.first
        XCTAssertEqual(inService?.storedEnabled, true, "the owner's standing instruction is untouched")
        XCTAssertEqual(inService?.isEnabled, false, "even though the switch reads off")

        // The same car, visit over. Nothing was written in between.
        let after = makeService(storedEnabled: true, inService: false).vehicleRideShare.first
        XCTAssertEqual(after?.isEnabled, true, "the stored preference comes straight back")
        XCTAssertEqual(after?.isInteractive, true)
        XCTAssertEqual(after?.caption, VehicleRideShare.rowCaption(isEnabled: true))
    }

    /// **NO WRITE FIRES ON THE TRANSITION, IN EITHER DIRECTION.** A PUT fired by a
    /// status change rather than by a finger would race the same reads MYR-351
    /// exists to fix, on a path nobody is watching.
    ///
    /// Asserted on the §7.18 endpoint across the whole in-service → out-of-service
    /// cycle: reading the rows is what a screen does on every redraw, and it must
    /// never be what writes.
    func testNoWriteFiresWhenTheCarEntersOrLeavesService() {
        let endpoint = RecordingRideShareEndpoint()

        let entering = makeService(storedEnabled: true, inService: true, rideShare: endpoint)
        _ = entering.vehicleRideShare          // render while in service
        _ = entering.vehicleRideShare          // and again

        let leaving = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        _ = leaving.vehicleRideShare           // render after the visit

        XCTAssertTrue(
            endpoint.writes.isEmpty,
            "deriving the position must never write it — a service transition is not a tap"
        )
    }

    /// A car that is NOT in service is completely unaffected, which is what keeps
    /// every simulated Share-tab capture byte-identical.
    func testAnOrdinaryCarIsUnchangedByTheDerivation() {
        let on = makeService(storedEnabled: true, inService: false).vehicleRideShare.first
        XCTAssertEqual(on?.isEnabled, true)
        XCTAssertEqual(on?.isInteractive, true)
        XCTAssertEqual(on?.caption, VehicleRideShare.rowCaption(isEnabled: true))

        let paused = makeService(storedEnabled: false, inService: false).vehicleRideShare.first
        XCTAssertEqual(paused?.isEnabled, false)
        XCTAssertEqual(
            paused?.isInteractive, true,
            "an OWNER's pause stays editable — that is the whole difference from in service"
        )
        XCTAssertEqual(paused?.caption, VehicleRideShare.rowCaption(isEnabled: false))
    }

    /// ABSENT MEANS ENABLED still holds underneath the derivation: a pre-0.20.0
    /// server's `nil` is an ON preference that renders off only because the car is
    /// in service, and comes back ON when it leaves.
    func testAbsentStillMeansEnabledUnderneathTheDerivation() {
        let inService = makeService(storedEnabled: nil, inService: true).vehicleRideShare.first
        XCTAssertEqual(inService?.storedEnabled, true, "absent is ENABLED, never paused")
        XCTAssertEqual(inService?.isEnabled, false, "and is derived off only by the service visit")

        let after = makeService(storedEnabled: nil, inService: false).vehicleRideShare.first
        XCTAssertEqual(after?.isEnabled, true)
    }

    /// **A FAILED WRITE MUST NOT PERSIST THE DERIVED POSITION.** The rollback
    /// restores `storedEnabled`, not `isEnabled` — reading the derived value there
    /// would write a service visit's temporary off into the owner's standing
    /// preference the first time a write failed on an in-service car.
    ///
    /// The write is unreachable from the UI in that state (the row is inert), which
    /// is exactly why the rollback is asserted directly: the guard that stops this
    /// today is a view modifier, and view modifiers move.
    func testARolledBackWriteRestoresTheStoredPreferenceNotTheDerivedPosition() async {
        let endpoint = RecordingRideShareEndpoint()
        endpoint.failure = RestError.http(status: 500, code: nil, message: nil, subCode: nil)
        let service = makeService(storedEnabled: true, inService: true, rideShare: endpoint)

        do {
            try await service.setVehicleRideShareEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id)
            XCTFail("the refusal must reach the caller")
        } catch {}

        XCTAssertEqual(
            service.vehicleRideShare.first?.storedEnabled, true,
            "the owner's stored ON must survive a failed write on an in-service car"
        )
    }

    // MARK: - 2. The per-viewer caption tells the two reasons apart

    /// Both kinds of off disable the per-viewer Rides switch — nobody can request
    /// the car either way — but they must not SAY the same thing. "Ride sharing is
    /// off for this car" describes a switch the owner set and can unset; a car in a
    /// service bay was withdrawn by nobody and the switch above it is itself inert,
    /// so that sentence would send the owner to a control they cannot move.
    func testThePerViewerCaptionNamesTheServiceVisitRatherThanAnOwnerChoice() {
        let person = viewer(name: "Mira", allowRides: true, suspended: false)

        let ownerPaused = ShareViewerControls.resolve(
            viewer: person, vehicleRideShareEnabled: false,
            vehicleInService: false, vehicleName: nil
        )
        let inService = ShareViewerControls.resolve(
            viewer: person, vehicleRideShareEnabled: false,
            vehicleInService: true, vehicleName: nil
        )

        XCTAssertNotEqual(
            ownerPaused.ridesCaption, inService.ridesCaption,
            "two different facts must not share one sentence"
        )
        XCTAssertEqual(
            inService.ridesInteractive, false,
            "in service still disables the switch — only the reason differs"
        )
        let caption = try? XCTUnwrap(inService.ridesCaption)
        XCTAssertTrue(
            caption?.lowercased().contains("in service") == true,
            "the in-service caption must state the fact: \(caption ?? "nil")"
        )
        XCTAssertFalse(
            caption?.lowercased().contains("ride sharing is off") == true,
            "and must not assert an owner choice nobody made"
        )
    }

    /// The multi-car form names the car, exactly as the owner-pause form does — on
    /// an account with two Teslas "this car" is ambiguous in both directions.
    func testTheInServiceCaptionNamesTheCarWhenThereIsMoreThanOne() {
        let person = viewer(name: "Mira", allowRides: true, suspended: false)
        let named = ShareViewerControls.resolve(
            viewer: person, vehicleRideShareEnabled: false,
            vehicleInService: true, vehicleName: "Lunar"
        )
        XCTAssertTrue(
            named.ridesCaption?.contains("Lunar") == true,
            "got: \(named.ridesCaption ?? "nil")"
        )
    }

    /// SUSPENSION STILL OUTRANKS BOTH. A viewer suspended on a car that is also in
    /// service must be told they cannot see the car at all — naming the lesser fact
    /// would send the owner to the wrong switch. MYR-369 set that precedence; the
    /// in-service arm must not have quietly jumped the queue.
    func testSuspensionStillOutranksTheServiceVisit() {
        let suspended = viewer(name: "Aanya", allowRides: true, suspended: true)
        let controls = ShareViewerControls.resolve(
            viewer: suspended, vehicleRideShareEnabled: false,
            vehicleInService: true, vehicleName: nil
        )
        XCTAssertTrue(
            controls.subtitle.contains("Aanya"),
            "the stronger, more specific fact is the one that gets named"
        )
        XCTAssertEqual(controls.locationOn, false)
        XCTAssertEqual(controls.ridesInteractive, false)
    }

    // MARK: - 3. The pause warning fires from the SHARE TAB's own seam
    //
    // MYR-360's decision logic is asserted exhaustively in
    // `RideSharePauseWarningTests`, driven through the executor. What is asserted
    // HERE is the thing that was actually broken: that the Share tab's committer
    // reaches that logic at all, and that a pause routed through it does not touch
    // §7.18 until the owner has answered.
    //
    // These drive `ShareServiceRideSharePauseTarget` — the SHIPPING adapter
    // `InvitesScreen` builds — against the real `LiveShareService`, so a
    // regression that re-pointed the screen straight at the service (which is
    // exactly what the relocation did) fails here.

    /// A reservation source scripted with what the car has booked.
    private struct StubReservations: UpcomingReservationSource {
        var reservations: [UpcomingReservation] = []
        var failure: Error?

        func upcomingReservations(vehicleID: String) async throws -> [UpcomingReservation] {
            if let failure { throw failure }
            return reservations
        }
        func decline(reservationID: String) async throws {}
    }

    private func reservation(id: String, name: String?) -> UpcomingReservation {
        UpcomingReservation(
            id: id,
            riderFirstName: name,
            scheduledFor: Date().addingTimeInterval(60 * 60 * 30)
        )
    }

    /// **NOTHING BOOKED → STRAIGHT WRITE.** This is nearly every pause, and it must
    /// cost no dialog and no extra step. A regression here would tax every owner
    /// for a situation that does not exist.
    func testPausingWithNoReservationsWritesImmediatelyAndRaisesNoDialog() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(source: StubReservations())
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id, onFailure: { _ in }
        )

        await flow.setEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id, target: target)

        XCTAssertNil(flow.warning, "nothing is booked — there is nothing to warn about")
        XCTAssertEqual(endpoint.writes.map(\.enabled), [false], "the pause PUT fires")
        XCTAssertEqual(service.vehicleRideShare.first?.isEnabled, false, "and the switch moved")
    }

    /// **AN ACCEPTED RESERVATION → DIALOG BEFORE THE WRITE.** The defect this whole
    /// flow exists for: pausing over a booked ride strands a rider who finds out 30
    /// minutes AFTER their pickup. The warning must be raised and §7.18 must be
    /// untouched while the owner is being asked.
    ///
    /// THIS IS THE ASSERTION THE RELOCATION BROKE. Before this fix the Share tab
    /// wrote straight through `setVehicleRideShareEnabled` and this test would show
    /// a write with no dialog.
    func testPausingOverAnAcceptedReservationWarnsBeforeWritingAnything() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(
            source: StubReservations(reservations: [reservation(id: "r1", name: "Alex")])
        )
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id, onFailure: { _ in }
        )

        await flow.setEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id, target: target)

        XCTAssertEqual(flow.warning?.reservations.map(\.id), ["r1"], "the owner is asked")
        XCTAssertEqual(flow.warning?.reservations.map(\.riderFirstName), ["Alex"])
        XCTAssertTrue(
            endpoint.writes.isEmpty,
            "and NOTHING is committed while they are deciding"
        )
        XCTAssertEqual(
            service.vehicleRideShare.first?.isEnabled, true,
            "the switch has not moved either — the owner can still back out"
        )
    }

    /// "Pause anyway" completes the write the dialog interrupted, through the same
    /// committer — so the answer lands on the car the question was asked about.
    func testPauseAnywayCommitsThroughTheShareTabsCommitter() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(
            source: StubReservations(reservations: [reservation(id: "r1", name: "Alex")])
        )
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id, onFailure: { _ in }
        )
        await flow.setEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id, target: target)
        XCTAssertTrue(endpoint.writes.isEmpty)

        await flow.pauseAnyway()

        XCTAssertNil(flow.warning)
        XCTAssertEqual(endpoint.writes.map(\.enabled), [false])
        XCTAssertEqual(service.vehicleRideShare.first?.isEnabled, false)
    }

    /// "Keep sharing" writes NOTHING and leaves the switch where it was. There is no
    /// position to restore, because the optimistic flip lives inside the service's
    /// write and this path never calls it.
    func testKeepSharingWritesNothingAtAll() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(
            source: StubReservations(reservations: [reservation(id: "r1", name: "Alex")])
        )
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id, onFailure: { _ in }
        )
        await flow.setEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id, target: target)

        flow.keepSharing()

        XCTAssertNil(flow.warning)
        XCTAssertTrue(endpoint.writes.isEmpty)
        XCTAssertEqual(service.vehicleRideShare.first?.isEnabled, true)
    }

    /// **RESUMING NEVER WARNS.** Turning ride sharing back ON cannot strand anyone —
    /// it is the recovery from this whole situation — so it never reads, never
    /// dialogs and never waits, even with reservations on the books.
    func testResumingNeverWarnsEvenWithReservationsBooked() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: false, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(
            source: StubReservations(reservations: [reservation(id: "r1", name: "Alex")])
        )
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id, onFailure: { _ in }
        )

        await flow.setEnabled(true, vehicleID: VehicleFixtures.vehicles[0].id, target: target)

        XCTAssertNil(flow.warning, "resuming is never questioned")
        XCTAssertEqual(endpoint.writes.map(\.enabled), [true])
    }

    /// **A READ THAT DID NOT ANSWER DOES NOT PAUSE.** Pausing on an unknown list
    /// risks the exact harm the flow exists to prevent, and the direction is not
    /// symmetric: a refused pause is repairable by the owner tapping again, a
    /// stranded rider is not. The Share tab says so with its own failure toast.
    func testAnUnreadableReservationListRefusesToPauseAndSaysSo() async {
        let endpoint = RecordingRideShareEndpoint()
        let service = makeService(storedEnabled: true, inService: false, rideShare: endpoint)
        let flow = RideSharePauseFlow(
            source: StubReservations(
                failure: RestError.http(status: 500, code: nil, message: nil, subCode: nil)
            )
        )
        var messages: [String] = []
        let target = ShareServiceRideSharePauseTarget(
            service: service, vehicleID: VehicleFixtures.vehicles[0].id,
            onFailure: { messages.append($0) }
        )

        await flow.setEnabled(false, vehicleID: VehicleFixtures.vehicles[0].id, target: target)

        XCTAssertNil(flow.warning)
        XCTAssertTrue(endpoint.writes.isEmpty, "an unknown list must not be paused over")
        XCTAssertEqual(
            service.vehicleRideShare.first?.isEnabled, true,
            "and the switch never moved, so the row is honest with no rollback needed"
        )
        XCTAssertEqual(messages, [VehicleCommandNotice.rideShareNotSaved.message])
    }

    /// The relocated control must SAY the same thing the owner-sheet row said. Two
    /// independent copies of one sentence is how a moved control starts speaking a
    /// new dialect.
    func testTheShareTabsFailureCopyMatchesTheOwnerSheetsNotice() {
        XCTAssertEqual(
            RideSharePauseFailure.rideShareNotSaved.shareTabMessage,
            VehicleCommandNotice.rideShareNotSaved.message
        )
        XCTAssertEqual(
            RideSharePauseFailure.reservationNotDeclined.shareTabMessage,
            VehicleCommandNotice.reservationNotDeclined.message
        )
    }

    private func viewer(name: String, allowRides: Bool, suspended: Bool) -> Viewer {
        Viewer(
            id: "v-\(name)", name: name, email: nil, online: false,
            perm: allowRides ? "Can request rides" : "Live location",
            tier: allowRides ? .rides : .live,
            allowRides: allowRides, suspended: suspended
        )
    }
}
