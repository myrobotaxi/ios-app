import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-432 — a revoked viewer's surface stands down within seconds
//
// The Kit's own suite proves the SOCKET prunes (`AccessRevocationTests`). This one
// proves the two things a pure actor test cannot: that the app's live compositions
// are WIRED to that signal, and that the signal lands in the release machinery
// that already exists rather than in a second one.
//
// **THE FUNNEL, END TO END.** The server closes §6.2's `4002` → the socket
// re-handshakes once, resolves the reduced `GET /api/vehicles` set and prunes →
// the locator drops the watched car and RE-READS §7.0 → `fleetMembers` shrinks →
// `RiderVehicleSet.resolve` over the reduced catalog answers `.empty`, which is
// exactly what `RootView.adoptRiderVehicle` releases on (MYR-369). No new release
// path; the first one, triggered seconds after the revoke instead of on the next
// cold launch.
//
// Everything here runs the PRODUCTION `RiderLiveVehicleLocator` /
// `LiveVehicleFleet` over a routed wire whose `/vehicles` body CHANGES mid-test.
// That mutability is load-bearing (MYR-402's `RoutedHTTP.setBody` lesson): a fixed
// stub makes "the client re-read the list" indistinguishable from "the client used
// what it already had", so a test built on one passes on the broken build.
@MainActor
final class AccessRevocationFunnelTests: XCTestCase {

    // MARK: Wire fixtures

    /// MYR-455 — the role is a PARAMETER now, defaulted to `.viewer` so every
    /// rider-side test in this file is unchanged.
    ///
    /// It had to become one because the owner-fleet test below was seeding
    /// VIEWER rows and asserting the owner fleet adopted them — which is
    /// precisely the conflation MYR-455 removes (`GET /api/vehicles` carries both
    /// partitions, and the owner shell must take only its own half). The test's
    /// subject is "a revocation re-reads §7.0", which is about the owner's own
    /// cars; using shares to stand in for them was incidental, and the fix
    /// surfaced it.
    private nonisolated static func row(
        _ id: String,
        _ name: String,
        role: VehicleSummary.Role = .viewer
    ) -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: name, model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "3795", status: .parked,
            chargeLevel: 71, estimatedRange: 244,
            lastUpdated: "2026-08-02T22:40:00.000Z", role: role,
            sharePermission: role == .viewer ? .rides : nil
        )
    }

    /// The owner half of the same list — an account's own car.
    private nonisolated static func ownedRow(_ id: String, _ name: String) -> VehicleSummary {
        row(id, name, role: .owner)
    }

    private nonisolated static func snapshot(_ id: String) -> VehicleState {
        VehicleState(
            vehicleId: id, name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vin: "7SAYGDET7TA613795",
            softwareVersion: "2026.20.6.6", trim: nil,
            status: .parked, speed: 0, heading: 180,
            latitude: 37.7949, longitude: -122.3995,
            locationName: "Embarcadero Center", locationAddress: "1 Embarcadero Ctr",
            gearPosition: .p,
            chargeLevel: 71, chargeState: nil, estimatedRange: 244, timeToFull: nil,
            interiorTemp: 68, exteriorTemp: 61,
            odometerMiles: 6349, fsdMilesSinceReset: 812.5,
            lastUpdated: "2026-08-02T22:41:00.000Z"
        )
    }

    private nonisolated static func snapshotBody(_ id: String) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(snapshot(id))
    }

    // MARK: Composition

    private struct RiderRig {
        let http: RoutedHTTP
        let channels: AuthenticatingChannelFactory
        let locator: RiderLiveVehicleLocator
        let state: SharedViewerState
    }

    private func makeRiderRig(rows: [VehicleSummary]) -> RiderRig {
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.snapshotBody(rows.first?.vehicleId ?? "veh-a")),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
        let channels = AuthenticatingChannelFactory()
        let locator = RiderLiveVehicleLocator(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: channels
        ))
        let state = SharedViewerState(vehicle: nil, seams: .init(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: StaticRiderLocation(coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)),
            liveVehicleLocator: locator,
            pinLabeler: SimulatedPinLabeler(),
            isLive: true
        ))
        return RiderRig(http: http, channels: channels, locator: locator, state: state)
    }

    /// Close the LIVE channel the way the telemetry server does on a revoke.
    ///
    /// Waits for the handshake to SETTLE first. That is not padding: a close
    /// landing mid-handshake is a genuinely different arm of the socket (the
    /// `send` throws rather than the `receive`), and it is pinned where it
    /// belongs — `AccessRevocationTests.testACloseThatLandsMidHandshakeIsStillReadAsAccess`
    /// in the Kit. Leaving it to chance here made this suite pass alone and fail
    /// under load, which is a test that reports the wrong thing either way.
    private func revoke(_ rig: RiderRig) async {
        await eventually { rig.locator.telemetrySource?.connectionState == .connected }
        guard let live = rig.channels.madeChannels().last else { return XCTFail("no channel") }
        await live.closeWith(code: TelemetryCloseCode.permissionRevoked)
    }

    // MARK: - The rider surface releases

    func testAFullyRevokedRiderLandsOnTheHonestEmptyStateWithoutARelaunch() async throws {
        let rig = makeRiderRig(rows: [Self.row("veh-a", "Lunar")])
        rig.state.startTelemetry()
        await eventually { rig.locator.watchedVehicleID == "veh-a" }
        await eventually { rig.locator.fleetMembers.count == 1 }

        // The owner revokes. The server's §7.0 now answers with nothing.
        await rig.http.setBody(suffix: "/vehicles", body: Contracts.listResponse([]))
        await revoke(rig)

        // 1. The socket pruned and the locator let the car go.
        await eventually(timeout: 5.0) { rig.locator.watchedVehicleID == nil }
        // 2. The §7.0 RE-READ happened — this is the funnel, and it is what every
        //    downstream surface resolves from.
        await eventually(timeout: 5.0) { rig.locator.fleetMembers.isEmpty }
        // 3. The shell's trigger fired. `RootView` keys its catalog re-read on
        //    exactly this, so a tick that never moves is a surface that never
        //    releases.
        XCTAssertEqual(rig.state.riderAccessRevocationTick, 1)

        // 4. And the reduced list resolves to the arm that RELEASES — the same
        //    pure rule `RootView.adoptRiderVehicle` switches on (MYR-369).
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: true, loadFailed: false, grants: [], ownedVehicles: []
        )
        XCTAssertEqual(resolution, .empty)

        rig.state.stopTelemetry()
    }

    func testAPartialRevocationKeepsTheSurvivingCarAndReAdoptsIt() async throws {
        let rig = makeRiderRig(rows: [Self.row("veh-a", "Lunar"), Self.row("veh-b", "Comet")])
        rig.state.startTelemetry()
        await eventually { rig.locator.watchedVehicleID == "veh-a" }
        await eventually { rig.locator.fleetMembers.count == 2 }

        // Only the WATCHED car's grant is suspended; the other stands.
        await rig.http.setBody(suffix: "/vehicles", body: Contracts.listResponse([Self.row("veh-b", "Comet")]))
        await revoke(rig)

        // The survivor is adopted by the locator's OWN fallback (`loadFleet` adopts
        // `vehicles.first` while nothing is watched), so the rider is left on a
        // working map rather than on an empty state — the whole reason the prune is
        // designed around the SET rather than around the close code.
        await eventually(timeout: 5.0) { rig.locator.watchedVehicleID == "veh-b" }
        await eventually(timeout: 5.0) { rig.locator.fleetMembers.map(\.id) == ["veh-b"] }
        XCTAssertEqual(rig.state.riderAccessRevocationTick, 1)

        rig.state.stopTelemetry()
    }

    func testATransientCloseTouchesNothingOnThisSurface() async throws {
        let rig = makeRiderRig(rows: [Self.row("veh-a", "Lunar")])
        rig.state.startTelemetry()
        await eventually { rig.locator.watchedVehicleID == "veh-a" }
        await eventually { rig.locator.fleetMembers.count == 1 }

        // A plain drop — no close code. Today's supervise/backoff behaviour, and
        // the surface must not so much as flinch.
        guard let live = rig.channels.madeChannels().last else { return XCTFail("no channel") }
        await live.close()

        // The socket reconnects underneath; nothing here is released or re-asked
        // as an ACCESS event.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(rig.locator.watchedVehicleID, "veh-a")
        XCTAssertEqual(rig.state.riderAccessRevocationTick, 0, "a drop is not a revocation")
        XCTAssertEqual(rig.locator.fleetMembers.count, 1)

        rig.state.stopTelemetry()
    }

    func testTheSimulatedPathHasNoTickAtAll() {
        // The funnel is live-path-only by construction: no locator, no socket, no
        // close code. `RootView`'s `onChange` can never fire in sim, which is what
        // keeps every simulated + DEBUG capture byte-identical.
        let state = SharedViewerState(vehicle: nil, seams: .init(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: StaticRiderLocation(coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)),
            liveVehicleLocator: nil,
            pinLabeler: SimulatedPinLabeler(),
            isLive: false
        ))
        XCTAssertEqual(state.riderAccessRevocationTick, 0)
    }

    // MARK: - The owner fleet re-reads its list

    func testTheOwnerFleetReReadsItsListOnARevocation() async throws {
        let http = RoutedHTTP([
            .init("/snapshot", body: Self.snapshotBody("veh-a")),
            .init("/vehicles", body: Contracts.listResponse([Self.ownedRow("veh-a", "Lunar"), Self.ownedRow("veh-b", "Comet")])),
        ])
        let channels = AuthenticatingChannelFactory()
        let fleet = LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: channels
        ))
        fleet.start()
        await eventually { fleet.vehicles.count == 2 }
        let listReadsBefore = await http.callCount(suffix: "/vehicles")

        await http.setBody(suffix: "/vehicles", body: Contracts.listResponse([Self.ownedRow("veh-b", "Comet")]))
        await eventually { (fleet.telemetry(at: 0) as? LiveVehicleTelemetrySource)?.connectionState == .connected }
        guard let live = channels.madeChannels().last else { return XCTFail("no channel") }
        await live.closeWith(code: TelemetryCloseCode.permissionRevoked)

        // The list is the owner surface's spine — the switcher, the hero and the
        // teardown bookkeeping are all built from it — so the revocation has to
        // land there and not only inside the socket.
        await eventually(timeout: 5.0) { fleet.vehicles.map(\.id) == ["veh-b"] }
        let listReadsAfter = await http.callCount(suffix: "/vehicles")
        XCTAssertGreaterThan(listReadsAfter, listReadsBefore, "the revocation must re-read §7.0")

        fleet.stop()
    }

    // MARK: Helpers

    private func eventually(
        timeout: TimeInterval = 3.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

/// A `UserLocationProviding` whose fix never moves — nothing here is about the
/// rider's own position, only about which car the surface is pointed at.
private final class StaticRiderLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    init(coordinate: CLLocationCoordinate2D?) { self.coordinate = coordinate }
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}
