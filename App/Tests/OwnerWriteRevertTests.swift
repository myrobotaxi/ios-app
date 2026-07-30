import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-351 — an owner write must not be reverted by a stale read
//
// THE DEFECT, in one sentence: every `vehicle_update` frame re-played the LAST
// SNAPSHOT's snapshot-only fields into the executor, so a value the owner had
// just committed was overwritten by the value it replaced, seconds later.
//
// Three TestFlight reports on build 202607292219, one root cause:
//
//   1. "I just cleared service completion date and it popped right back after a
//      few seconds. Seems to be same issue across this bottom sheet with
//      updating any field."
//   2. Clearing the service date didn't remove the hero line either.
//   3. "Whenever I turn off ride share it switches back on so I don't know if it
//      turned off or not."
//
// WHY IT HAPPENED. `LiveVehicleCommandExecutor.reconcile` documented its three
// snapshot-only arms — `licensePlate` (MYR-286), `serviceEstimatedEndAt`
// (MYR-316) and `rideShareEnabled` (MYR-342) — as running "only ever on a cold
// `/snapshot` read". That was false. `LiveVehicleFleet` wires `reconcile` to
// `LiveVehicleState.onStateChanged`, which fires for BOTH `.snapshot` AND
// `.update`; and `VehicleStateMerger.apply(fields:to:)` opens with
// `var state = original`, so a merged delta carries the last snapshot's
// snapshot-only fields forward VERBATIM. The merger declining to FOLD those
// fields (they are `snapshotOnlyFields`) is not the same as the state not
// CARRYING them — and the executor could not tell the two apart.
//
// So the guard the arms actually had — `uiState(for:).isPending == false` —
// covered only the milliseconds the write was in flight. The frame that arrived
// after the echo settled walked straight through it.
//
// THE FIX, and why it is ONE mechanism rather than two: every reconciled state
// now arrives stamped with the instant the `/snapshot` GET that produced its
// snapshot-only fields was ISSUED, and the executor refuses to adopt a
// snapshot-only field from a read that was issued before the last write to it
// was committed. That single rule closes both hazards at once:
//
//   • the CARRIED-FORWARD DELTA (this file's 1–3): it inherits the old
//     snapshot's issue instant, which necessarily predates the write;
//   • the IN-FLIGHT SNAPSHOT (test 5): a GET issued at t=0 that lands at t=3,
//     straddling a write committed at t=2. RECEIPT time would call it fresh —
//     it is the newest thing that arrived. ISSUE time correctly calls it stale.
//     MYR-319's 0/0.8/3/9s cold-read ladder and MYR-315's foreground refetch
//     make that straddle a routine path on an in-service or sleeping car, not a
//     corner.
//
// The guard is deliberately SCOPED TO THE THREE SNAPSHOT-ONLY FIELDS. The
// streamed controls (lock/climate/seat/trunk/charge-port/media) keep MYR-249's
// opposite and correct rule — telemetry is authoritative and OVERRIDES the
// optimistic-on-ack value, because the car really is the authority on whether
// its doors are locked. Nothing here weakens that; test 6 pins it.
@MainActor
final class OwnerWriteRevertTests: XCTestCase {

    // MARK: - Fixtures

    private static let teslaWindow = "2026-08-01T21:00:00.000Z"

    /// A live-shaped `VehicleState` carrying the three snapshot-only fields.
    private static func state(
        serviceEstimatedEndAt: String? = nil,
        rideShareEnabled: Bool? = nil,
        licensePlate: String? = nil,
        locked: Bool? = nil
    ) -> VehicleState {
        VehicleState(
            vehicleId: "veh-1", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
            status: .inService, speed: 0, heading: 0, latitude: 37.79, longitude: -122.39,
            locationName: "Embarcadero", locationAddress: "1 Embarcadero Ctr",
            chargeLevel: 61, estimatedRange: 166, interiorTemp: 68, exteriorTemp: 61,
            odometerMiles: 18432, fsdMilesSinceReset: 11274,
            locked: locked,
            licensePlate: licensePlate,
            serviceEstimatedEndAt: serviceEstimatedEndAt,
            rideShareEnabled: rideShareEnabled,
            lastUpdated: "2026-07-29T16:00:00Z"
        )
    }

    private func makeExecutor(
        serviceWindowEndpoint: any VehicleServiceWindowEndpoint = ScriptedServiceWindowEndpoint(),
        rideShareEndpoint: any VehicleRideShareEndpoint = ScriptedRideShareEndpoint(),
        plateEndpoint: any VehiclePlateEndpoint = ScriptedPlateEndpoint()
    ) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: plateEndpoint,
            serviceWindowEndpoint: serviceWindowEndpoint,
            rideShareEndpoint: rideShareEndpoint,
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 0
        )
    }

    // MARK: - 1. The service window (report 1 + 2)

    /// THE CLIENT'S REPORT, reduced to its mechanism: the owner clears the
    /// completion date, the server persists the clear and echoes null, and the very
    /// next telemetry frame — carrying the pre-clear snapshot's window forward —
    /// puts the old instant straight back.
    ///
    /// The two reads that reverted are the "Service completion date" ROW and the
    /// peek hero's COMPLETION LINE, and they revert together because both resolve
    /// through `VehicleServiceWindow.resolvedEndAt` off this one committed value.
    /// That is why report (2) is not a second bug: one clobber, two surfaces.
    func testAClearedServiceWindowIsNotRevertedByTheNextTelemetryFrame() async throws {
        let executor = makeExecutor(
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint()
        )
        // A cold snapshot lands carrying Tesla's window.
        let coldRead = Date()
        let snapshot = Self.state(serviceEstimatedEndAt: Self.teslaWindow)
        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)
        XCTAssertNotNil(executor.controls.serviceEstimatedEndAt, "precondition: the window is on screen")

        // The owner clears it. The server echoes null; the executor commits it.
        try await executor.setServiceWindow(nil)
        XCTAssertNil(executor.controls.serviceEstimatedEndAt)
        XCTAssertTrue(executor.isKnown(.serviceWindow), "a committed CLEAR is a real answer, not an absence")

        // A `vehicle_update` frame arrives. It carries no service window of its own
        // — the merger declares the field snapshot-only and never folds it — but
        // the MERGED state it produces still holds the cold read's instant, because
        // `VehicleStateMerger.apply` opens with `var state = original`.
        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)

        XCTAssertNil(
            executor.controls.serviceEstimatedEndAt,
            "a delta carrying the PRE-CLEAR snapshot's window forward must not resurrect it"
        )
    }

    // MARK: - 2. Ride sharing (report 3)

    /// "Whenever I turn off ride share it switches back on so I don't know if it
    /// turned off or not." The same mechanism on the sibling field, and the one
    /// where the revert is not merely cosmetic: an owner who believes their car is
    /// withdrawn while it is still taking requests is the exact belief §7.18
    /// forbids the client to manufacture.
    func testAPausedCarIsNotUnPausedByTheNextTelemetryFrame() async throws {
        let executor = makeExecutor()
        let coldRead = Date()
        let snapshot = Self.state(rideShareEnabled: true)
        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)
        XCTAssertTrue(executor.controls.rideShareEnabled, "precondition: the switch is ON")

        try await executor.setRideShareEnabled(false)
        XCTAssertFalse(executor.controls.rideShareEnabled)

        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)

        XCTAssertFalse(
            executor.controls.rideShareEnabled,
            "a delta carrying the PRE-PAUSE snapshot's `true` forward must not un-pause the car"
        )
    }

    // MARK: - 3. The plate ("same issue ... with updating any field")

    /// The client's own generalization was correct, and this is the third field it
    /// covers. The plate has the identical delivery property (§7.14 fires no WS
    /// push) and had the identical hole, so a saved plate reverted to the previous
    /// one on the next frame exactly as the other two did.
    func testASavedPlateIsNotRevertedByTheNextTelemetryFrame() async throws {
        let executor = makeExecutor(plateEndpoint: ScriptedPlateEndpoint(normalizedEcho: "ABC 1234"))
        let coldRead = Date()
        let snapshot = Self.state(licensePlate: "OLD 0000")
        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)
        XCTAssertEqual(executor.controls.plate, "OLD 0000")

        try await executor.setPlate("abc1234")
        XCTAssertEqual(executor.controls.plate, "ABC 1234")

        executor.reconcile(from: snapshot, snapshotReadIssuedAt: coldRead)

        XCTAssertEqual(
            executor.controls.plate, "ABC 1234",
            "a delta carrying the PRE-SAVE snapshot's plate forward must not revert the save"
        )
    }

    // MARK: - 4. The guard is not a latch

    /// The guard must expire, or it would be a worse bug than the one it fixes: a
    /// car that genuinely left service, or an owner who changed the switch on
    /// another device, would never reach this client again.
    ///
    /// A read ISSUED AFTER the write is newer information by construction, and is
    /// adopted in full — including a value that disagrees with what we committed.
    func testAReadIssuedAfterTheWriteIsAdoptedInFull() async throws {
        let executor = makeExecutor()
        executor.reconcile(from: Self.state(rideShareEnabled: true), snapshotReadIssuedAt: Date())

        try await executor.setRideShareEnabled(false)
        XCTAssertFalse(executor.controls.rideShareEnabled)

        // A genuinely FRESH snapshot, issued after the commit, says the car is
        // taking requests again (the owner re-enabled it elsewhere).
        executor.reconcile(
            from: Self.state(rideShareEnabled: true),
            snapshotReadIssuedAt: Date().addingTimeInterval(60)
        )
        XCTAssertTrue(
            executor.controls.rideShareEnabled,
            "a read issued AFTER the write is newer information and must win"
        )

        // The same for the window: a fresh read that re-populates a cleared window
        // is the server telling us Tesla produced an estimate, and must land.
        try await executor.setServiceWindow(nil)
        XCTAssertNil(executor.controls.serviceEstimatedEndAt)
        executor.reconcile(
            from: Self.state(serviceEstimatedEndAt: Self.teslaWindow),
            snapshotReadIssuedAt: Date().addingTimeInterval(120)
        )
        XCTAssertNotNil(
            executor.controls.serviceEstimatedEndAt,
            "a cleared window must still accept a LATER read that re-populates it"
        )
    }

    // MARK: - 5. The in-flight snapshot race

    /// THE RACE THE ISSUE NAMES, and the reason the stamp is the read's ISSUE
    /// instant rather than its arrival: a `/snapshot` GET issued BEFORE the write
    /// that lands AFTER the echo.
    ///
    /// Ordered by wall clock: the GET goes out at t=0, the owner clears at t=1 and
    /// the echo commits, and the response — carrying the pre-clear window, because
    /// that is what was true when it was served — arrives at t=2. It is the most
    /// recently RECEIVED information and the OLDEST information in the system, and
    /// only the issue instant can tell those apart.
    ///
    /// This is a routine path rather than a corner: MYR-319 retries the cold read
    /// at 0/0.8/3/9s, and MYR-315 refetches on every foreground.
    func testASnapshotIssuedBeforeTheWriteDoesNotClobberItWhenItLandsAfter() async throws {
        let executor = makeExecutor(
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint()
        )
        // t=0 — the GET is issued. Its response is still in flight.
        let inFlightRead = Date()

        // t=1 — the owner clears the window and the echo commits.
        try await executor.setServiceWindow(nil)
        XCTAssertNil(executor.controls.serviceEstimatedEndAt)

        // t=2 — the response arrives, carrying the world as it was at t=0.
        executor.reconcile(
            from: Self.state(serviceEstimatedEndAt: Self.teslaWindow),
            snapshotReadIssuedAt: inFlightRead
        )

        XCTAssertNil(
            executor.controls.serviceEstimatedEndAt,
            "a snapshot ISSUED before the write must not clobber it merely by ARRIVING after"
        )
    }

    // MARK: - 6. The streamed controls keep MYR-249's opposite rule

    /// The scope line, asserted so a future tidy-up cannot quietly widen the guard.
    ///
    /// For a STREAMED field the car is the authority and telemetry MUST override an
    /// optimistic value — a lock that the owner commanded and the car did not
    /// actually engage has to read as unlocked. That rule is the correct one there
    /// precisely because those fields ARE refreshed by every frame, which is the
    /// property the three snapshot-only fields lack. Nothing in this fix touches it.
    func testStreamedControlsAreStillOverriddenByTelemetry() async throws {
        let executor = makeExecutor()
        let read = Date()
        executor.reconcile(from: Self.state(locked: true), snapshotReadIssuedAt: read)
        XCTAssertTrue(executor.controls.locked)

        // A frame stamped with the SAME (by now old) read instant still corrects a
        // streamed field — the guard must not have leaked onto it.
        executor.reconcile(from: Self.state(locked: false), snapshotReadIssuedAt: read)
        XCTAssertFalse(
            executor.controls.locked,
            "streamed fields keep MYR-249's telemetry-is-authoritative rule"
        )
    }
}
