@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-478 — a withdrawn Rides grant has to reach the rider
//
// External beta, two testers, opposite sides of one grant, ~2 minutes apart
// (MYR-451). The owner's Share screen showed James's **Rides OFF**; James's app
// showed "Lunar — Location + rides" and handed him the whole booking flow. The
// server's create gate was correct and refused him; the client walked him to it.
//
// **THE WITHDRAWAL REACHES THIS DEVICE BY NO CHANNEL AT ALL.** §7.5.7 busts the
// server's own cached access set and stops; the WebSocket teardown is deliberately
// SUSPENSION-only, because `allowRides` has no socket effect — the contract's own
// amendment says exactly this and records the client half as tracked separately.
// So the only way to learn is to RE-READ §7.0, which already carries the derived
// `sharePermission` the tier is folded from.
//
// And the client did not re-read. The catalog behind the tier was loaded on
// rider-shell entry and, on foreground, only when `loadFailed && !hasLoaded` — a
// recovery for a list that had NEVER answered, and no refresh at all for one that
// had. A healthy session therefore held its first answer for the life of the
// process: MYR-402's *"a cold launch was the only refresh in the app"*, on the
// neighbouring read.
//
// These drive the SHIPPING pieces the shell wires together — the production
// `LiveSharedVehicleCatalog` over a list that CHANGES underneath it, the
// production `RiderVehicleSet.resolve`, and the production `SharedViewerState
// .adopt` — because seeding a tier by hand would pass straight over the read this
// issue is about. `RootView`'s own two funnel sites are covered by the tick
// contract at the bottom.
@MainActor
final class RiderRideCapabilityTests: XCTestCase {

    // MARK: The wire

    private static func viewerRow(permission: String?) -> VehicleSummary {
        VehicleSummary(
            vehicleId: "veh-shared", name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "3795", status: .parked,
            chargeLevel: 71, estimatedRange: 244,
            lastUpdated: "2026-08-06T00:30:00.000Z", role: .viewer,
            hasActiveRide: false,
            sharePermission: permission.flatMap(SharePermission.init(rawValue:))
        )
    }

    /// `GET /api/vehicles`, and it can change under the client.
    ///
    /// The `RoutedHTTP.setBody` idea (MYR-402) at the catalog's own injection
    /// seam: a FIXED list makes "the client re-read" indistinguishable from "the
    /// client used a cached value", so a test built on one passes on the broken
    /// build. It also counts, because "did it ask again" is half the question.
    private actor MutableList {
        private var rows: [VehicleSummary]
        private var failing = false
        private(set) var asks = 0

        init(_ rows: [VehicleSummary]) { self.rows = rows }

        struct Unreachable: Error {}

        func set(_ rows: [VehicleSummary]) { self.rows = rows }
        func setFailing(_ failing: Bool) { self.failing = failing }

        func read() throws -> [VehicleSummary] {
            asks += 1
            if failing { throw Unreachable() }
            return rows
        }
    }

    private struct Rig {
        let list: MutableList
        let catalog: LiveSharedVehicleCatalog
        let state: SharedViewerState
    }

    private func makeRig(permission: String?) -> Rig {
        let list = MutableList([Self.viewerRow(permission: permission)])
        let catalog = LiveSharedVehicleCatalog(
            api: UnusedSharingEndpoint(),
            listVehicles: { try await list.read() }
        )
        let state = SharedViewerState(vehicle: nil, seams: .init(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: SimulatedUserLocation(),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: true
        ))
        return Rig(list: list, catalog: catalog, state: state)
    }

    /// One pass of the funnel `RootView.refreshRiderVehicleSet()` performs: re-read
    /// the list, resolve it, adopt the answer. The two statements are the shell's,
    /// verbatim.
    private func runFunnelPass(_ rig: Rig) async {
        await rig.catalog.load()
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: rig.catalog.hasLoaded,
            loadFailed: rig.catalog.loadFailed,
            grants: rig.catalog.grants,
            ownedVehicles: rig.catalog.ownedVehicles
        )
        switch resolution {
        case .ridable(let adoption): rig.state.adopt(adoption)
        case .empty: rig.state.adopt(nil)
        case .resolving, .unavailable: break
        }
    }

    // MARK: The defect

    /// **THE ACCEPTANCE: withdrawal degrades the CTA on the next funnel pass.**
    ///
    /// The gold "Where to?" is gated on `SharedViewerState.canRequestRides`, and
    /// the honest replacement (`riderWatchOnly`'s muted "You can watch {car}")
    /// already exists — what was missing was any moment at which the input to that
    /// gate was asked for a second time.
    ///
    /// The middle assertion is the SHAPE OF THE BUG and is deliberately in the
    /// positive: with the wire already changed and no re-read, the client still
    /// offers rides. That is what James's phone was doing.
    func testWithdrawingRidesDegradesTheCTAOnTheNextFunnelPass() async {
        let rig = makeRig(permission: "rides")

        await runFunnelPass(rig)
        XCTAssertTrue(rig.state.canRequestRides, "a `rides` grant offers the booking flow")
        XCTAssertEqual(rig.state.sharedVehicleTier, .rides)

        // The owner turns Rides off. §7.5.7 re-derives `sharePermission` on every
        // read, so the very same row comes back on the lowest tier.
        await rig.list.set([Self.viewerRow(permission: "live")])

        XCTAssertTrue(rig.state.canRequestRides,
                      "nothing pushed: until the client asks again it still offers what will 403")

        await runFunnelPass(rig)
        XCTAssertFalse(rig.state.canRequestRides, "one funnel pass later the CTA is honest")
        XCTAssertEqual(rig.state.sharedVehicleTier, .live)
        let asks = await rig.list.asks
        XCTAssertEqual(asks, 2, "the funnel re-READS — a cached answer would pass the assertion above")
    }

    /// It reverses, on the same funnel, with no relaunch: an owner switching Rides
    /// back on is a `rides` row on the next read. "Right now" in the refusal copy
    /// is load-bearing precisely because of this.
    func testRestoringRidesBringsTheCTABack() async {
        let rig = makeRig(permission: "live")
        await runFunnelPass(rig)
        XCTAssertFalse(rig.state.canRequestRides)

        await rig.list.set([Self.viewerRow(permission: "rides")])
        await runFunnelPass(rig)
        XCTAssertTrue(rig.state.canRequestRides)
    }

    /// An ABSENT `sharePermission` on a viewer row is the LOWEST tier by contract
    /// ("never fail open"), so a projection that dropped the key degrades rather
    /// than silently restoring the booking flow.
    func testAnAbsentPermissionOnAViewerRowFailsClosed() async {
        let rig = makeRig(permission: "rides")
        await runFunnelPass(rig)
        XCTAssertTrue(rig.state.canRequestRides)

        await rig.list.set([Self.viewerRow(permission: nil)])
        await runFunnelPass(rig)
        XCTAssertFalse(rig.state.canRequestRides)
    }

    // MARK: The two paths that must NOT change

    /// **SUSPENSION IS UNCHANGED, and it is a different mechanism.** A suspended
    /// grant is enforced by REMOVING the row from the viewer's access set, so it
    /// does not arrive flagged — the car simply stops being in `GET /api/vehicles`,
    /// the set resolves `.empty`, and MYR-369's viewer half releases the map.
    /// Making the refresh more frequent must not turn that into anything else.
    func testASuspendedGrantStillResolvesEmptyAndReleases() async {
        let rig = makeRig(permission: "rides")
        await runFunnelPass(rig)
        XCTAssertNotNil(rig.state.sharedVehicle)

        await rig.list.set([]) // the grant was suspended: the row is gone
        await runFunnelPass(rig)
        XCTAssertNil(rig.state.sharedVehicle, "the map releases a car this account no longer has")
        XCTAssertNil(rig.state.sharedVehicleTier)
    }

    /// **A FAILED READ CHANGES NOTHING** (MYR-326, and `LiveSharedVehicleCatalog
    /// .load`'s own rule). This matters more now than it did: the refresh runs on
    /// every foreground, so a rider who resumes on a dead network must not have
    /// their car withdrawn by a fetch that never answered.
    func testAFailedRefreshLeavesTheCapabilityStanding() async {
        let rig = makeRig(permission: "rides")
        await runFunnelPass(rig)
        XCTAssertTrue(rig.state.canRequestRides)

        await rig.list.setFailing(true)
        await runFunnelPass(rig)
        XCTAssertTrue(rig.state.canRequestRides, "a list that did not answer is not a withdrawal")
        XCTAssertNotNil(rig.state.sharedVehicle, "and it is not an empty account either")
    }

    /// An OWNER in rider mode self-rides (MYR-343) and holds no tier at all, so the
    /// refresh can never gate them: §7.8's non-owner gate is not one they can fail.
    func testAnOwnerInRiderModeIsNeverGatedByTheRefresh() async {
        let list = MutableList([
            VehicleSummary(
                vehicleId: "owned-1", name: "Lunar", model: "Model Y", year: 2026,
                color: "Quicksilver", vinLast4: "3795", status: .parked,
                chargeLevel: 71, estimatedRange: 244,
                lastUpdated: "2026-08-06T00:30:00.000Z", role: .owner,
                hasActiveRide: false
            ),
        ])
        let catalog = LiveSharedVehicleCatalog(
            api: UnusedSharingEndpoint(),
            listVehicles: { try await list.read() }
        )
        let state = SharedViewerState(vehicle: nil, seams: .init(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: SimulatedUserLocation(),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: true
        ))
        let rig = Rig(list: list, catalog: catalog, state: state)

        await runFunnelPass(rig)
        await runFunnelPass(rig)
        XCTAssertNil(rig.state.sharedVehicleTier, "an owner is on no tier")
        XCTAssertTrue(rig.state.canRequestRides)
    }

    // MARK: The funnel's contract with the shell

    /// `RootView` observes ONE counter and performs the read. Both idle entry
    /// points bump it, so the ride-flow-entry funnel cannot be half-wired — and a
    /// third door added later has to walk past `noteRideFlowEntry`.
    func testEnteringTheRideFlowFromIdleAsksForTheCapability() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let start = state.rideCapabilityRefreshTick

        state.enterSearchFromIdle()
        XCTAssertEqual(state.rideCapabilityRefreshTick, start + 1, "the idle sheet's search-bar door")

        state.resetDraftToIdle()
        state.selectDestinationFromIdle(RideRequestFixtures.savedPlaces[0])
        XCTAssertEqual(state.rideCapabilityRefreshTick, start + 2, "the Home/Work chip door")
    }

    /// And the create-path 403 is the third door into the SAME funnel — the one
    /// moment the cached tier is KNOWN to be wrong, because the server has just
    /// refused a ride on it. Same reasoning MYR-385 re-reads §7.22 on.
    func testARefusedCreateAsksForTheCapability() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        let start = state.rideCapabilityRefreshTick
        state.noteRideCapabilityRefused()
        XCTAssertEqual(state.rideCapabilityRefreshTick, start + 1)
    }

    /// Nothing ELSE bumps it. A counter the shell re-reads on is a request per
    /// bump, so a phase flip or a draft reset must not become a poll.
    func testTheTickIsNotAPoll() {
        let state = SharedViewerState(vehicle: nil, seams: .simulated)
        state.enterSearchFromIdle()
        let afterEntry = state.rideCapabilityRefreshTick

        state.sheetPhase = .review
        state.sheetPhase = .booking
        state.discardDraftTrip()
        state.resetDraftToIdle()
        XCTAssertEqual(state.rideCapabilityRefreshTick, afterEntry,
                       "walking the flow is not a reason to re-read; entering it is")
    }
}

/// The catalog's sharing endpoint is only ever used by `redeem`, which none of
/// these tests calls — the subject here is the LIST read.
private struct UnusedSharingEndpoint: VehicleSharingEndpoint {
    struct NotUsed: Error {}

    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        throw NotUsed()
    }
    func shareInvites(vehicleID: String) async throws -> [ShareInvite] { throw NotUsed() }
    func revokeShareInvite(inviteID: String) async throws { throw NotUsed() }
    func resendShareInvite(inviteID: String) async throws -> ShareInvite { throw NotUsed() }
    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse { throw NotUsed() }
    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
        throw NotUsed()
    }
}
