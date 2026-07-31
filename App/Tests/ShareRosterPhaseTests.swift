import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-386 — the Share tab's load phase, through the SERVICE
//
// THE CLIENT'S REPORT (TestFlight, build 202607311129): *"Need to add the
// skeleton loading to this page. It flashes no one added then appears."*
//
// `ShareRosterStateTests` pins the RULE (`ShareRosterState.resolve`). These pin
// what the production service feeds it, which is the half that actually
// regressed: `ShareService` has published a loading signal since MYR-184 and
// nothing read it, so a pure-function test could have been green for two years
// while the screen flashed.
//
// The sharpest case is the one nobody would think to write: an EMPTY FLEET.
// §7.5.2 is per-vehicle, so `performLoad` short-circuits when there are no
// vehicles — correctly — but it could not tell "this account owns no cars" from
// "the vehicle list has not answered yet", and answered BOTH with "nothing is
// shared". That is the client's flash on a cold boot, and it is also why a Share
// tab opened during one used to sit on the empty hero for the rest of the
// session: nothing re-asked when the fleet landed.
@MainActor
final class ShareRosterPhaseTests: XCTestCase {

    // MARK: - Harness

    /// A §7.5.2 list read the test can hold open, so "in flight" is a state the
    /// assertions can stand still in rather than a race to lose.
    ///
    /// **PARKED WITH A CONTINUATION, NOT A SEMAPHORE.** `LiveShareService` is
    /// `@MainActor` and so is this test, so a `DispatchSemaphore.wait()` here
    /// blocks the very actor the load has to run on: the read never begins, the
    /// wait never ends, and the whole suite hangs on this file. (Written that way
    /// first, and it did exactly that.) Suspending instead lets the main actor
    /// keep servicing the load while the test holds it open.
    private final class GatedShareEndpoint: VehicleSharingEndpoint, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        /// Releases granted before anyone was waiting for them, so `release()`
        /// works whichever side arrives first.
        private var permits = 0
        private var entryCount = 0

        /// When set, the read fails with this instead of answering.
        var failure: Error?
        var rows: [ShareInvite] = []

        func shareInvites(vehicleID: String) async throws -> [ShareInvite] {
            await withCheckedContinuation { continuation in
                lock.lock()
                entryCount += 1
                if permits > 0 {
                    permits -= 1
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                    lock.unlock()
                }
            }
            if let failure { throw failure }
            return rows
        }

        private var entries: Int { lock.lock(); defer { lock.unlock() }; return entryCount }

        /// Yield until the service has genuinely entered its `count`-th read.
        /// Bounded, so a broken expectation fails the test instead of hanging it.
        func awaitEntry(_ count: Int = 1) async {
            for _ in 0..<10_000 where entries < count { await Task.yield() }
            XCTAssertGreaterThanOrEqual(entries, count, "the service never entered the list read")
        }

        /// Let one parked read finish.
        func release() {
            lock.lock()
            let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
            if waiter == nil { permits += 1 }
            lock.unlock()
            waiter?.resume()
        }

        func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
            throw Unreached()
        }
        func revokeShareInvite(inviteID: String) async throws { throw Unreached() }
        func resendShareInvite(inviteID: String) async throws -> ShareInvite { throw Unreached() }
        func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse { throw Unreached() }
        func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
            throw Unreached()
        }

        struct Unreached: Error {}
    }

    private struct InertRideShareEndpoint: VehicleRideShareEndpoint {
        func setRideShareEnabled(_ enabled: Bool, vehicleID: String) async throws -> VehicleRideShareResponse {
            VehicleRideShareResponse(vehicleId: vehicleID, enabled: enabled)
        }
    }

    private var car: Vehicle { VehicleFixtures.vehicles[0] }

    private func accepted(_ label: String, vehicle: String) -> ShareInvite {
        ShareInvite(
            inviteId: "acc-\(label)", vehicleId: vehicle, label: label,
            permission: SharePermission(rawValue: "rides"),
            allowRides: true, suspended: false, status: .accepted,
            createdAt: "2026-07-01T10:00:00Z", acceptedAt: "2026-07-01T11:00:00Z"
        )
    }

    // MARK: - 1. The phase a fetch actually passes through

    /// `.idle` BEFORE anything asks — the state the screen is in on its very first
    /// frame, and the one two booleans could not express (`isLoading == false,
    /// statusMessage == nil` was also "loaded and genuinely empty").
    func testAFreshServiceHasNotAskedYet() {
        let service = LiveShareService(
            api: GatedShareEndpoint(), rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { [self.car] }
        )
        XCTAssertEqual(service.rosterPhase, .idle)
    }

    /// `.loading` WHILE THE READ IS GENUINELY OPEN, and `.loaded` only once it
    /// has answered — asserted from inside the fetch rather than inferred, which
    /// is the whole difference between a skeleton that is honest and one that is
    /// decorative.
    func testThePhaseIsLoadingWhileTheReadIsOpenAndLoadedOnlyAfterItAnswers() async {
        let endpoint = GatedShareEndpoint()
        endpoint.rows = [accepted("Mira Chen", vehicle: car.id)]
        let service = LiveShareService(
            api: endpoint, rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { [self.car] }
        )

        let load = Task { await service.load() }
        await endpoint.awaitEntry()
        XCTAssertEqual(service.rosterPhase, .loading)
        XCTAssertTrue(service.viewers.isEmpty, "nothing is known yet — this is the flash's raw material")

        endpoint.release()
        await load.value
        XCTAssertEqual(service.rosterPhase, .loaded)
        XCTAssertEqual(service.viewers.count, 1)
    }

    /// A read that FAILS settles on `.failed`, never back on a phase the screen
    /// would render as "no one has access yet".
    func testAFailedReadSettlesOnFailedRatherThanOnAnEmptyAnswer() async {
        struct Boom: Error {}
        let endpoint = GatedShareEndpoint()
        endpoint.failure = Boom()
        let service = LiveShareService(
            api: endpoint, rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { [self.car] }
        )

        let load = Task { await service.load() }
        await endpoint.awaitEntry()
        endpoint.release()
        await load.value

        XCTAssertEqual(service.rosterPhase, .failed(LiveShareService.unreadableMessage))
        XCTAssertEqual(
            ShareRosterState.resolve(phase: service.rosterPhase, viewers: [], pending: []),
            .unavailable(LiveShareService.unreadableMessage)
        )
    }

    // MARK: - 2. THE EMPTY FLEET — the second flash, and the sharper one
    //
    // These three are the same call with the same empty vehicle list and three
    // different answers, which is exactly the point: before MYR-386 the service
    // had no way to ask and gave all three the empty-hero verdict.

    private func serviceWithNoVehicles(fleet: ShareFleetState) -> LiveShareService {
        LiveShareService(
            api: GatedShareEndpoint(), rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { [] },
            fleetState: { fleet }
        )
    }

    /// THE CLIENT'S COLD BOOT. `GET /api/vehicles` is in flight, so the roster is
    /// genuinely blocked on a fetch that is genuinely running — skeleton, not
    /// "No one has access yet".
    func testAFleetStillResolvingLeavesTheRosterLoading() async {
        let service = serviceWithNoVehicles(fleet: .resolving)
        await service.load()

        XCTAssertEqual(service.rosterPhase, .loading)
        XCTAssertEqual(
            ShareRosterState.resolve(phase: service.rosterPhase, viewers: [], pending: []),
            .loading
        )
    }

    /// The unchanged, honest case: the fleet ANSWERED and holds nothing, so the
    /// account genuinely has nothing shared and the hero is correct.
    func testAResolvedEmptyFleetIsGenuinelyTheEmptyState() async {
        let service = serviceWithNoVehicles(fleet: .resolved)
        await service.load()

        XCTAssertEqual(service.rosterPhase, .loaded)
        XCTAssertEqual(
            ShareRosterState.resolve(phase: service.rosterPhase, viewers: [], pending: []),
            .empty
        )
    }

    /// A fleet that did not answer is not an account with no cars, so it is not
    /// an account with nothing shared either. MYR-343's rule, one seam further in.
    func testAnUnreachableFleetIsAFailureAndNotAnEmptyRoster() async {
        let service = serviceWithNoVehicles(fleet: .unreachable)
        await service.load()

        XCTAssertEqual(service.rosterPhase, .failed(LiveShareService.unreadableMessage))
        XCTAssertNotEqual(
            ShareRosterState.resolve(phase: service.rosterPhase, viewers: [], pending: []),
            .empty
        )
    }

    /// And the recovery: once the fleet lands, the SAME service asked again reads
    /// the real list. `InvitesScreen` re-asks on the vehicle ids changing, which
    /// is what closes the "opened during a cold boot, empty forever" half of this
    /// defect — before MYR-386 the `.task` had already fired and nothing else did.
    func testTheRosterLoadsForRealOnceTheFleetArrives() async {
        var vehicles: [Vehicle] = []
        var fleet: ShareFleetState = .resolving
        let endpoint = GatedShareEndpoint()
        endpoint.rows = [accepted("Mira Chen", vehicle: car.id)]
        let service = LiveShareService(
            api: endpoint, rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { vehicles },
            fleetState: { fleet }
        )

        await service.load()
        XCTAssertEqual(service.rosterPhase, .loading, "the fleet has not answered")

        vehicles = [car]
        fleet = .resolved
        let load = Task { await service.load() }
        await endpoint.awaitEntry()
        endpoint.release()
        await load.value

        XCTAssertEqual(service.rosterPhase, .loaded)
        XCTAssertEqual(service.viewers.map(\.name), ["Mira Chen"])
    }

    // MARK: - 3. The rule that keeps a re-read from blanking the page

    /// `LiveShareService` re-reads the whole list after every mutation. A revoke
    /// therefore passes through `.loading` with rows already on screen — and the
    /// resolved state must stay `populated` throughout, or a revoke would look
    /// like the list falling over.
    func testARefreshWithRowsInHandNeverShimmers() async {
        let endpoint = GatedShareEndpoint()
        endpoint.rows = [accepted("Mira Chen", vehicle: car.id)]
        let service = LiveShareService(
            api: endpoint, rideShareAPI: InertRideShareEndpoint(),
            ownedVehicles: { [self.car] }
        )

        let first = Task { await service.load() }
        await endpoint.awaitEntry()
        endpoint.release()
        await first.value
        XCTAssertEqual(service.viewers.count, 1)

        let second = Task { await service.load() }
        await endpoint.awaitEntry(2)
        XCTAssertEqual(service.rosterPhase, .loading)
        // The PHASE says loading; the resolved STATE keeps the rows.
        guard case .populated = ShareRosterState.resolve(
            phase: service.rosterPhase, viewers: service.viewers, pending: service.pending
        ) else {
            endpoint.release()
            await second.value
            return XCTFail("a re-read blanked a roster that was already on screen")
        }
        endpoint.release()
        await second.value
    }
}
