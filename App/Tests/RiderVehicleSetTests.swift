import XCTest
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-343 — the owner-in-rider-mode trap
//
// THE CLIENT'S REPORT (TestFlight, Jul 29): "When I switched to rider mode as an
// owner I briefly saw the rider home page and then it prompted me to enter a
// code." A regression from MYR-184 (#117), and two defects in one sentence:
//
//   1. The zero-shared-vehicles empty state (`SharedNoVehiclesScreen` →
//      `InviteCodeFlow`) was gated on `grants.isEmpty` — i.e. on SHARES. An OWNER
//      in rider mode has zero `role: viewer` rows by definition, so an account
//      that owns a Tesla outright got told it had no vehicles and was sent to
//      redeem an invite code. Self-rides are a supported flow (MYR-325 tested one
//      live end-to-end).
//
//   2. THE FLASH. The gate was `hasLoaded && grants.isEmpty`, so the
//      not-yet-loaded case fell through to the rider home, which rendered over an
//      unresolved vehicle set and was then swapped out. That is the "briefly saw
//      the rider home page" half.
//
// These tests are the failing-first reproduction of both, written against the
// pure rule (`RiderVehicleSet.resolve`) and the real `role` partitioning
// (`LiveSharedVehicleCatalog`), so neither needs a view, a server or a clock.

// MARK: - Fixture rows

/// A §7.0 `VehicleSummary`, in either role. Local to this file (the sharing
/// suite has its own private copy) so neither can be changed out from under the
/// other.
private func vehicleRow(
    id: String,
    name: String,
    role: VehicleSummary.Role,
    permission: String? = nil
) -> VehicleSummary {
    VehicleSummary(
        vehicleId: id,
        name: name,
        model: "Model 3",
        year: 2024,
        color: "Pearl White",
        vinLast4: "0001",
        status: .parked,
        chargeLevel: 72,
        estimatedRange: 210,
        lastUpdated: "2026-07-29T15:04:05Z",
        role: role,
        hasActiveRide: false,
        licensePlate: "8ABC123",
        serviceEstimatedEndAt: nil,
        sharePermission: permission.map { SharePermission(rawValue: $0) }
    )
}

/// The four account shapes this issue is about, each expressed as the §7.0 list
/// the server would actually return for it.
private enum AccountShape {
    /// An OWNER: one owned car, nothing shared with them. The client's account.
    static let owner = [vehicleRow(id: "owned-1", name: "Lunar", role: .owner)]
    /// A pure VIEWER: one redeemed share, owns nothing.
    static let viewer = [
        vehicleRow(id: "shared-1", name: "Alex\u{2019}s Model 3", role: .viewer, permission: "rides")
    ]
    /// BOTH: owns a car and holds a share.
    static let both = owner + viewer
    /// NEITHER: a signed-in account with nothing on it at all.
    static let neither: [VehicleSummary] = []
}

// MARK: - The adoption rule

@MainActor
final class RiderVehicleSetTests: XCTestCase {

    private func resolve(_ summaries: [VehicleSummary]) -> RiderVehicleSet {
        RiderVehicleSet.resolve(
            hasLoaded: true,
            loadFailed: false,
            grants: LiveSharedVehicleCatalog.grants(from: summaries),
            ownedVehicles: LiveSharedVehicleCatalog.ownedVehicles(from: summaries)
        )
    }

    // MARK: Defect 1 — the trap itself

    /// THE REGRESSION. An owner in rider mode must adopt their OWN car and land
    /// on the rider shell. Before this issue they resolved to `.empty`, which is
    /// the invite-code route.
    func testAnOwnerInRiderModeAdoptsTheirOwnVehicle() {
        guard case .ridable(let adoption) = resolve(AccountShape.owner) else {
            return XCTFail("an owner with a car must have a car to ride")
        }
        XCTAssertEqual(adoption.source, .owned)
        XCTAssertEqual(adoption.vehicle?.id, "owned-1")
        XCTAssertEqual(adoption.vehicle?.name, "Lunar")
    }

    /// The same account, stated as the negative the client actually hit: it must
    /// NEVER route to the invite-code empty state.
    func testAnOwnerInRiderModeIsNeverRoutedToTheInviteCodePrompt() {
        XCTAssertNotEqual(resolve(AccountShape.owner), .empty)
        XCTAssertNotEqual(resolve(AccountShape.both), .empty)
    }

    /// An owned car carries NO tier — tiers are a sharing concept, and §7.8's
    /// non-owner gate is not one an owner can fail. `canRequestRides` reads a nil
    /// tier as "not gated", so the "Where to?" CTA is offered, which is the whole
    /// point of self-ride.
    func testAnOwnedVehicleIsNotTierGated() {
        guard case .ridable(let adoption) = resolve(AccountShape.owner) else {
            return XCTFail("expected a ridable owned vehicle")
        }
        XCTAssertNil(adoption.tier)

        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        state.adopt(adoption)
        XCTAssertTrue(state.canRequestRides, "an owner must be offered a ride on their own car")
        XCTAssertEqual(state.sharedVehicle?.id, "owned-1")
    }

    // MARK: The other three account shapes

    /// A pure viewer is unchanged by this issue: the first `role: viewer` row,
    /// with its tier.
    func testAViewerWithSharesStillAdoptsTheSharedVehicle() {
        guard case .ridable(let adoption) = resolve(AccountShape.viewer) else {
            return XCTFail("expected a ridable shared vehicle")
        }
        XCTAssertEqual(adoption.source, .shared)
        XCTAssertEqual(adoption.vehicle?.id, "shared-1")
        XCTAssertEqual(adoption.tier, .rides)
    }

    /// THE FLAGGED DECISION (see `RiderVehicleSet.resolve`): an account holding
    /// BOTH prefers its OWN car. The load-bearing reason is consistency with the
    /// ride itself — `RiderLiveVehicleLocator` publishes `vehicles.first` as the
    /// `FleetMember` the request is created against, so adopting a shared car onto
    /// the map would put two different vehicles on two halves of one flow.
    func testAnAccountWithBothPrefersItsOwnVehicle() {
        guard case .ridable(let adoption) = resolve(AccountShape.both) else {
            return XCTFail("expected a ridable vehicle")
        }
        XCTAssertEqual(adoption.source, .owned)
        XCTAssertEqual(adoption.vehicle?.id, "owned-1")
        XCTAssertNil(adoption.tier, "the owned car is not gated by the share's tier")
    }

    /// A share on a LOW tier must not be able to hide the "Where to?" CTA from
    /// someone who owns a Tesla — the concrete failure the precedence rule avoids.
    func testALowTierShareCannotGateAnOwnersOwnCar() {
        let summaries = AccountShape.owner + [
            vehicleRow(id: "shared-1", name: "Alex\u{2019}s Model 3", role: .viewer, permission: "live")
        ]
        guard case .ridable(let adoption) = resolve(summaries) else {
            return XCTFail("expected a ridable vehicle")
        }
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        state.adopt(adoption)
        XCTAssertTrue(state.canRequestRides)
    }

    /// The empty state means what its copy says — NO vehicles at all, neither
    /// owned nor shared. This is the only shape that may reach the invite prompt.
    func testAnAccountWithNeitherOwnedNorSharedVehiclesIsTheEmptyState() {
        XCTAssertEqual(resolve(AccountShape.neither), .empty)
    }

    // MARK: Defect 2 — the flash

    /// THE FLASH. Until the vehicle set has resolved, the shell commits to
    /// NOTHING: not the rider home (the client's flash), not the invite prompt.
    func testTheShellResolvesBeforeItPresentsAnything() {
        XCTAssertEqual(
            RiderVehicleSet.resolve(hasLoaded: false, loadFailed: false, grants: [], ownedVehicles: []),
            .resolving
        )
    }

    /// The pre-fix shape of the bug, pinned directly: an owner's list is empty of
    /// GRANTS at every moment of the load, so a gate that reads grants alone shows
    /// the rider home and then the invite prompt — never the car. Both frames the
    /// client saw are wrong, and both are now something else.
    func testNeitherFrameOfTheClientsReportIsReachableForAnOwner() {
        let owned = LiveSharedVehicleCatalog.ownedVehicles(from: AccountShape.owner)
        let grants = LiveSharedVehicleCatalog.grants(from: AccountShape.owner)
        XCTAssertTrue(grants.isEmpty, "an owner genuinely has no viewer rows — that was never the question")

        // Frame 1 (in flight): a skeleton, not the rider home.
        XCTAssertEqual(
            RiderVehicleSet.resolve(hasLoaded: false, loadFailed: false, grants: grants, ownedVehicles: []),
            .resolving
        )
        // Frame 2 (landed): the rider home on their OWN car, not the invite prompt.
        guard case .ridable(let adoption) = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: false, grants: grants, ownedVehicles: owned
        ) else {
            return XCTFail("expected the owner's own car")
        }
        XCTAssertEqual(adoption.source, .owned)
    }

    // MARK: Loading ≠ unavailable (MYR-326's rule, applied here)

    /// A list that never answered is NOT "you have no vehicles". Telling a rider
    /// that because one fetch timed out is a claim the app cannot support.
    func testAFailedListIsUnavailableNotEmpty() {
        XCTAssertEqual(
            RiderVehicleSet.resolve(hasLoaded: false, loadFailed: true, grants: [], ownedVehicles: []),
            .unavailable
        )
    }

    /// A catalog that has ALREADY loaded keeps rendering its last-known set even
    /// if a later refresh fails — the same rule `LiveSharedVehicleCatalog.load`
    /// applies when it leaves the grants standing.
    func testALaterFailureNeverUnseatsALoadedSet() {
        let owned = LiveSharedVehicleCatalog.ownedVehicles(from: AccountShape.owner)
        guard case .ridable = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: true, grants: [], ownedVehicles: owned
        ) else {
            return XCTFail("a loaded set survives a failed refresh")
        }
    }

    // MARK: The SIM path is untouched

    /// The simulated catalog owns nothing and reports loaded-with-grants from the
    /// first frame, so it resolves to the SAME first grant it always did — no
    /// skeleton, no empty state, no owned branch. Every simulated + DEBUG rider
    /// capture is byte-identical by construction.
    func testTheSimulatedCatalogResolvesToItsFirstGrantOnTheFirstFrame() {
        let catalog = SimulatedSharedVehicleCatalog()
        XCTAssertTrue(catalog.ownedVehicles.isEmpty)
        XCTAssertFalse(catalog.loadFailed)

        guard case .ridable(let adoption) = RiderVehicleSet.resolve(
            hasLoaded: catalog.hasLoaded,
            loadFailed: catalog.loadFailed,
            grants: catalog.grants,
            ownedVehicles: catalog.ownedVehicles
        ) else {
            return XCTFail("the simulated rider always has a vehicle")
        }
        XCTAssertEqual(adoption.source, .shared)
        // SIM grants carry no `Vehicle` (three personas, no cars behind them) —
        // the sim viewer keeps its fixture seed, exactly as before this issue.
        XCTAssertNil(adoption.vehicle)
        XCTAssertEqual(adoption.tier, .rides)
    }

    /// Adopting a SIM grant must not disturb `canRequestRides` — the prototype's
    /// rider always keeps the "Where to?" CTA.
    func testAdoptingASimulatedGrantKeepsTheRequestAffordance() {
        let state = SharedViewerState()
        state.adopt(RiderVehicleAdoption(source: .shared, vehicle: nil, tier: .rides))
        XCTAssertTrue(state.canRequestRides)
    }
}

// MARK: - The role partition

@MainActor
final class RiderVehicleRolePartitionTests: XCTestCase {

    /// The two partitions are disjoint and cover the list: an owned row never
    /// becomes a grant (it would show up under "Shared with me"), and a viewer row
    /// never becomes an owned vehicle (it would escape its tier gate).
    func testTheRolePartitionIsDisjointAndComplete() {
        let grants = LiveSharedVehicleCatalog.grants(from: AccountShape.both)
        let owned = LiveSharedVehicleCatalog.ownedVehicles(from: AccountShape.both)

        XCTAssertEqual(grants.map(\.id), ["shared-1"])
        XCTAssertEqual(owned.map(\.id), ["owned-1"])
        XCTAssertEqual(grants.count + owned.count, AccountShape.both.count)
    }

    /// Owned rows keep §7.0 list order, so "the first owned car" is the same car
    /// `RiderLiveVehicleLocator` publishes as `vehicles.first`.
    func testOwnedRowsKeepListOrder() {
        let summaries = [
            vehicleRow(id: "owned-1", name: "Lunar", role: .owner),
            vehicleRow(id: "shared-1", name: "Alex\u{2019}s Model 3", role: .viewer, permission: "rides"),
            vehicleRow(id: "owned-2", name: "Solstice", role: .owner),
        ]
        XCTAssertEqual(LiveSharedVehicleCatalog.ownedVehicles(from: summaries).map(\.id), ["owned-1", "owned-2"])
    }

    /// A live catalog load populates BOTH partitions off ONE `GET /api/vehicles`
    /// — no second round trip, and no new dependency on the owner fleet.
    func testOneListPopulatesBothPartitions() async {
        let catalog = LiveSharedVehicleCatalog(
            api: ScriptedShareEndpoint(),
            listVehicles: { AccountShape.both }
        )
        await catalog.load()

        XCTAssertTrue(catalog.hasLoaded)
        XCTAssertFalse(catalog.loadFailed)
        XCTAssertEqual(catalog.grants.map(\.id), ["shared-1"])
        XCTAssertEqual(catalog.ownedVehicles.map(\.id), ["owned-1"])
    }

    /// A failed list records the failure without inventing an empty account.
    func testAFailedListRecordsTheFailureAndClaimsNothing() async {
        struct Boom: Error {}
        let catalog = LiveSharedVehicleCatalog(
            api: ScriptedShareEndpoint(),
            listVehicles: { throw Boom() }
        )
        await catalog.load()

        XCTAssertFalse(catalog.hasLoaded)
        XCTAssertTrue(catalog.loadFailed)
        XCTAssertTrue(catalog.grants.isEmpty)
        XCTAssertTrue(catalog.ownedVehicles.isEmpty)
    }

    /// A recovering load clears the failure flag and lands the real set.
    func testARecoveringLoadClearsTheFailure() async {
        final class Flaky: @unchecked Sendable {
            var shouldFail = true
        }
        let flaky = Flaky()
        let catalog = LiveSharedVehicleCatalog(
            api: ScriptedShareEndpoint(),
            listVehicles: {
                struct Boom: Error {}
                if flaky.shouldFail { throw Boom() }
                return AccountShape.owner
            }
        )
        await catalog.load()
        XCTAssertTrue(catalog.loadFailed)

        flaky.shouldFail = false
        await catalog.load()
        XCTAssertFalse(catalog.loadFailed)
        XCTAssertTrue(catalog.hasLoaded)
        XCTAssertEqual(catalog.ownedVehicles.map(\.id), ["owned-1"])
    }

    /// A redeem answers with VIEWER rows only (§7.5.5), so it must not touch the
    /// owned partition — an owner who redeems a share still owns their own car.
    func testRedeemDoesNotDisturbTheOwnedPartition() async throws {
        let endpoint = ScriptedShareEndpoint()
        endpoint.redeemResult = .success(
            RedeemShareInviteResponse(
                ownerFirstName: "Alex",
                vehicles: [vehicleRow(id: "shared-9", name: "Alex\u{2019}s Cybercab", role: .viewer, permission: "rides")]
            )
        )
        let catalog = LiveSharedVehicleCatalog(api: endpoint, listVehicles: { AccountShape.owner })
        await catalog.load()
        XCTAssertEqual(catalog.ownedVehicles.map(\.id), ["owned-1"])

        _ = try await catalog.redeem(code: "ABC123")

        XCTAssertEqual(catalog.ownedVehicles.map(\.id), ["owned-1"], "a redeem cannot add or remove an owned car")
        XCTAssertEqual(catalog.grants.map(\.id), ["shared-9"])
    }
}
