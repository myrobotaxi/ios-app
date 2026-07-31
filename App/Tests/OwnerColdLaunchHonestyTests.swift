import CoreLocation
import DesignSystem
import MapKit
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-387 — the black map and the eternal skeleton
//
// THE CLIENT'S REPORT (TestFlight, build 202607311129 = main 69a1e43,
// 2026-07-31 12:44 CT, iPhone 17 Pro Max): owner Vehicle tab, the Lunar switcher
// chip up, a COMPLETELY BLACK map area with no tiles and no vehicle marker, and
// the bottom sheet stuck on skeleton placeholder rows. *"Nothing loading, what
// happened?"*
//
// Everything the backend owed him was there: `GET /api/vehicles` and `GET
// /api/vehicles/{id}/snapshot` both answered in full, latitude/longitude/heading
// included, and a Share-tab screenshot from the SAME MINUTE proves the device had
// network and a valid session. His car was `in_service` and therefore NOT
// STREAMING, which is the condition every finding below turns on.
//
// Three defects, each of which alone produces some of that screenshot:
//
//   1. THE COLD SNAPSHOT WAS GATED ON THE WEBSOCKET. `TelemetrySocket
//      .fetchAndEmitSnapshot` had two callers and both required a live, AUTHED
//      connection. A socket that failed to connect meant the REST snapshot was
//      never even ATTEMPTED — on a device whose REST client had just answered a
//      fleet list. A terminal `auth_failed` is permanent for the session.
//   2. THE HONEST END STATE WAS UNREACHABLE. MYR-326 bounds the wait and
//      publishes "Can't reach Lunar right now"; `HomeScreen`'s content branch
//      needed only a vehicle ROW, and the fleet LIST had succeeded, so that
//      branch matched and Home rendered content over a snapshot that does not
//      exist. The skeleton did not become an honest failure — it became a LIE.
//   3. THE CAMERA WENT TO NULL ISLAND. `placeholderActivity` parks a car at
//      `(0, 0)` — §2.3's no-fix sentinel — and `recenter` wrote it verbatim. On
//      a dark, muted, POI-free map style the Gulf of Guinea renders as a plain
//      black rectangle.
//
// Every test below fails on `main` at 69a1e43.
@MainActor
final class OwnerColdLaunchHonestyTests: XCTestCase {

    private static let vehicleID = "v-lunar"

    // MARK: - 1. The render decision (pure)

    /// **THE SHIPPED DEFECT.** The retries are spent, the fleet says so, and
    /// there is no snapshot — and the screen rendered CONTENT, because the fleet
    /// list had told it the car is called Lunar. A name is not a position.
    func testAColdReadTimeoutRendersTheHonestStateEvenThoughTheListSucceeded() {
        let presentation = OwnerHomePresentation.resolve(
            hasVehicle: true,          // the LIST landed — this is the client's case
            hasTelemetry: true,        // a source exists; it just has no state
            isConnecting: false,       // MYR-326 suppresses loading on a status message
            statusMessage: "Can\u{2019}t reach Lunar right now",
            hasLiveSnapshot: false     // …and nothing ever arrived
        )
        XCTAssertEqual(
            presentation, .unavailable(message: "Can\u{2019}t reach Lunar right now"),
            "a settled failure with nothing behind it must not render as content"
        )
        XCTAssertTrue(presentation.offersRetry, "and it must offer a way to ask again")
    }

    /// **THE SHIPPED PREDICATE, PINNED AS WRONG.** `HomeScreen.body` asked
    /// literally this, and nothing else, before choosing content:
    ///
    ///     selectedVehicle != nil && selectedTelemetry != nil && !isConnecting
    ///
    /// On the client's inputs that expression is `true`, which is why the honest
    /// end state MYR-326 built was unreachable for the entire class of accounts
    /// it was written for. The test states both halves together, so a future
    /// refactor back toward the naive predicate fails here rather than in
    /// TestFlight.
    func testTheOldContentPredicateWasTrueForTheClientsExactState() {
        let hasVehicle = true, hasTelemetry = true, isConnecting = false
        let statusMessage: String? = "Can\u{2019}t reach Lunar right now"
        let hasLiveSnapshot = false

        XCTAssertTrue(
            hasVehicle && hasTelemetry && !isConnecting,
            "this is the shipped predicate; if it were false there would have been no bug"
        )
        XCTAssertNotEqual(
            OwnerHomePresentation.resolve(
                hasVehicle: hasVehicle, hasTelemetry: hasTelemetry,
                isConnecting: isConnecting, statusMessage: statusMessage,
                hasLiveSnapshot: hasLiveSnapshot
            ),
            .content,
            "the resolver must NOT agree with the predicate that shipped the defect"
        )
    }

    /// The other side of the same rule, and the one that keeps it safe: a failure
    /// that lands BEHIND an already-rendered sheet must never blank it. A failed
    /// read never clears what we hold (NFR-3.12/3.13).
    func testAFailureBehindRealDataKeepsTheSheetUp() {
        let presentation = OwnerHomePresentation.resolve(
            hasVehicle: true,
            hasTelemetry: true,
            isConnecting: false,
            statusMessage: "Can\u{2019}t reach telemetry right now",
            hasLiveSnapshot: true
        )
        XCTAssertEqual(presentation, .content)
        XCTAssertFalse(presentation.offersRetry)
    }

    /// A skeleton requires something in flight, and it NEVER carries a retry —
    /// there is already a request running behind it.
    func testAGenuineInFlightReadIsTheOnlySkeleton() {
        let presentation = OwnerHomePresentation.resolve(
            hasVehicle: true,
            hasTelemetry: true,
            isConnecting: true,
            statusMessage: nil,
            hasLiveSnapshot: false
        )
        XCTAssertEqual(presentation, .loading)
        XCTAssertFalse(presentation.offersRetry, "shimmer plus a retry button is two contradictory claims")
    }

    /// The whole 2×2×2×2 matrix, asserted as ONE property rather than four cases:
    /// **a skeleton may only be resolved when something is genuinely in flight**,
    /// which after rule 1 means `isConnecting` with no settled failure under it.
    func testSkeletonsAlwaysTerminate() {
        for hasVehicle in [true, false] {
            for hasTelemetry in [true, false] {
                for hasSnapshot in [true, false] {
                    for message in [nil, "Can\u{2019}t reach Lunar right now"] as [String?] {
                        let settledFailure = message != nil && !hasSnapshot
                        // A settled failure is not a loading state, so the fleet
                        // reports `isConnecting == false` for it — model both.
                        for isConnecting in [true, false] {
                            let presentation = OwnerHomePresentation.resolve(
                                hasVehicle: hasVehicle,
                                hasTelemetry: hasTelemetry,
                                isConnecting: isConnecting,
                                statusMessage: message,
                                hasLiveSnapshot: hasSnapshot
                            )
                            if settledFailure {
                                XCTAssertNotEqual(
                                    presentation, .loading,
                                    "a shimmer over a settled failure is the banned eternal skeleton"
                                )
                            }
                            if presentation == .loading {
                                XCTAssertTrue(
                                    isConnecting,
                                    "a skeleton was resolved with nothing in flight behind it"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    /// The simulated fleet's own inputs. Every drift-gate scene must stay on
    /// `.content` — this issue may not move a single simulated pixel.
    func testTheSimulatedFleetAlwaysResolvesToContent() {
        XCTAssertEqual(
            OwnerHomePresentation.resolve(
                hasVehicle: true, hasTelemetry: true,
                isConnecting: false, statusMessage: nil, hasLiveSnapshot: true
            ),
            .content
        )
    }

    // MARK: - 2. The camera (pure)

    /// **NULL ISLAND, THE INVARIANT.** No combination of inputs may ever produce
    /// a region centred on `(0, 0)`.
    func testTheCameraNeverWritesNullIsland() {
        let nullIsland = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let real = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        let candidates: [CLLocationCoordinate2D?] = [nil, nullIsland, real]

        for vehicle in [nullIsland, real] {
            for override in candidates {
                for lastKnown in candidates {
                    let target = OwnerMapCamera.resolve(
                        vehicle: vehicle, override: override, lastKnown: lastKnown,
                        spanDelta: MRTMetrics.mapRegionSpanDelta
                    )
                    if let center = target.center {
                        XCTAssertTrue(
                            OwnerMapCamera.hasFix(center),
                            "the camera was pointed at the no-fix sentinel"
                        )
                    }
                    if let region = OwnerMapCamera.region(for: target) {
                        XCTAssertFalse(
                            region.center.latitude == 0 && region.center.longitude == 0,
                            "a region was written at 0,0"
                        )
                    }
                }
            }
        }
    }

    /// The client's exact frame: no fix, nothing cached. The camera is NOT
    /// written — MapKit's own wide framing stands. Deliberately not a fabricated
    /// default city, which would be a lie with better lighting.
    func testNoFixAndNoCacheLeavesTheCameraUnwritten() {
        let target = OwnerMapCamera.resolve(
            vehicle: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            spanDelta: MRTMetrics.mapRegionSpanDelta
        )
        XCTAssertEqual(target.source, .unpositioned)
        XCTAssertNil(target.center)
        XCTAssertNil(OwnerMapCamera.region(for: target))
    }

    /// With a cached position the map opens somewhere REAL — and wider, because
    /// where the car was is not where it is.
    func testNoFixFallsBackToTheCachedPosition() {
        let cached = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        let target = OwnerMapCamera.resolve(
            vehicle: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            lastKnown: cached,
            spanDelta: MRTMetrics.mapRegionSpanDelta
        )
        XCTAssertEqual(target.source, .lastKnown)
        XCTAssertEqual(target.center?.latitude, cached.latitude)
        XCTAssertGreaterThan(
            target.spanDelta, MRTMetrics.mapRegionSpanDelta,
            "a last-known position must not be framed as tightly as a live fix"
        )
    }

    /// The regression guard for every existing capture: a car WITH a fix is
    /// framed exactly as it was before this issue — same centre, same span.
    func testARealFixIsFramedExactlyAsBefore() {
        let real = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        let target = OwnerMapCamera.resolve(
            vehicle: real,
            lastKnown: CLLocationCoordinate2D(latitude: 1, longitude: 1),
            spanDelta: MRTMetrics.mapRegionSpanDelta
        )
        XCTAssertEqual(target.source, .liveFix)
        XCTAssertEqual(target.center?.latitude, real.latitude)
        XCTAssertEqual(target.center?.longitude, real.longitude)
        XCTAssertEqual(target.spanDelta, MRTMetrics.mapRegionSpanDelta)
    }

    /// The rider map's explicit centre still outranks everything — that call site
    /// is byte-identical.
    func testAnExplicitOverrideStillWins() {
        let device = CLLocationCoordinate2D(latitude: 37.78, longitude: -122.41)
        let target = OwnerMapCamera.resolve(
            vehicle: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937),
            override: device,
            spanDelta: MRTMetrics.mapRegionSpanDelta
        )
        XCTAssertEqual(target.source, .override)
        XCTAssertEqual(target.center?.latitude, device.latitude)
    }

    /// The pin is a claim about NOW. It is withheld without a fix even when the
    /// camera is positioned from cache, and it is never planted at `(0, 0)`.
    func testTheVehicleMarkerIsWithheldWithoutAFix() {
        XCTAssertFalse(OwnerMapCamera.drawsVehicleMarker(
            vehicle: CLLocationCoordinate2D(latitude: 0, longitude: 0)))
        XCTAssertTrue(OwnerMapCamera.drawsVehicleMarker(
            vehicle: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)))
    }

    /// The live placeholder is what put `(0, 0)` on screen in the first place —
    /// both arms of it. Pinned so a future change cannot make one of them look
    /// like a real coordinate to the camera.
    func testBothLivePlaceholderActivitiesReportNoFix() {
        for status in [VehicleSummary.Status.parked, .driving, .offline, .inService] {
            let activity = VehicleContractMapping.placeholderActivity(for: Self.listRow(status: status))
            let coordinate: CLLocationCoordinate2D
            switch activity {
            case .parked(let location):
                coordinate = location.coordinate
            case .driving(let trip):
                coordinate = VehicleRoute.position(along: trip.route, progress: 0).coordinate
            }
            XCTAssertFalse(
                OwnerMapCamera.hasFix(coordinate),
                "the \(status) placeholder must be recognised as NO FIX, not framed as a place"
            )
        }
    }

    // MARK: - 3. The last-known-position cache

    func testTheCacheRoundTripsAPosition() {
        let store = Self.makeStore()
        let real = CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        XCTAssertTrue(store.record(vehicleID: Self.vehicleID, coordinate: real))
        XCTAssertEqual(store.position(forVehicleID: Self.vehicleID)?.latitude, real.latitude)
        XCTAssertNil(store.position(forVehicleID: "someone-elses-car"))
    }

    /// The cache may never store the sentinel it exists to replace — that would
    /// poison the fallback, silently, from inside.
    func testTheCacheRefusesTheNoFixSentinel() {
        let store = Self.makeStore()
        XCTAssertFalse(store.record(
            vehicleID: Self.vehicleID,
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0)
        ))
        XCTAssertNil(store.position(forVehicleID: Self.vehicleID))
        XCTAssertTrue(store.allPositions().isEmpty)
    }

    func testAnExpiredPositionIsNotOffered() {
        let store = Self.makeStore()
        let now = Date()
        store.record(
            vehicleID: Self.vehicleID,
            coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937),
            now: now.addingTimeInterval(-LastKnownVehiclePositionStore.maxAge - 60)
        )
        XCTAssertNil(store.position(forVehicleID: Self.vehicleID, now: now))
    }

    func testTheCacheIsCappedAndKeepsTheNewest() {
        let store = Self.makeStore()
        let now = Date()
        let overflow = LastKnownVehiclePositionStore.maxEntries + 5
        for index in 0..<overflow {
            store.record(
                vehicleID: "v-\(index)",
                coordinate: CLLocationCoordinate2D(latitude: 37 + Double(index) / 1000, longitude: -122),
                now: now.addingTimeInterval(Double(index))
            )
        }
        XCTAssertEqual(store.allPositions().count, LastKnownVehiclePositionStore.maxEntries)
        XCTAssertNotNil(store.position(forVehicleID: "v-\(overflow - 1)"), "the newest must survive")
        XCTAssertNil(store.position(forVehicleID: "v-0"), "the oldest must fall off")
    }

    /// A re-record REPLACES rather than accumulating — a fleet of one car may not
    /// fill the key.
    func testRecordingTheSameCarTwiceKeepsOneRow() {
        let store = Self.makeStore()
        store.record(vehicleID: Self.vehicleID, coordinate: .init(latitude: 37.79, longitude: -122.39))
        store.record(vehicleID: Self.vehicleID, coordinate: .init(latitude: 37.80, longitude: -122.40))
        XCTAssertEqual(store.allPositions().count, 1)
        XCTAssertEqual(store.position(forVehicleID: Self.vehicleID)?.latitude ?? 0, 37.80, accuracy: 0.0001)
    }

    // MARK: - 4. The fleet, end to end

    /// **THE ROOT CAUSE, PROVEN.** A WebSocket that never completes its handshake
    /// (`ParkedChannelFactory`) with a perfectly healthy REST backend behind it.
    ///
    /// Before this issue the snapshot was never even ASKED for — `subscribe` only
    /// fetched when already connected, and the only other route was `auth_ok`. So
    /// owner Home sat on its skeleton until the `ColdSnapshotLoad` budget expired
    /// and then rendered "Locating…" at 0,0 forever. The cold read is a REST call
    /// and now behaves like one.
    func testTheColdSnapshotDoesNotWaitOnTheWebSocket() async {
        let fleet = Self.makeFleet(channelFactory: ParkedChannelFactory(), budget: 30)
        fleet.start()

        await eventually { fleet.vehicles.count == 1 }
        await eventually(timeout: 5) { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }

        XCTAssertFalse(fleet.isConnecting, "the skeleton must end when the REST read lands")
        XCTAssertNil(fleet.statusMessage)
        XCTAssertTrue(fleet.hasLiveSnapshotForActiveVehicle)
        XCTAssertEqual(
            OwnerHomePresentation.resolve(
                hasVehicle: true, hasTelemetry: true,
                isConnecting: fleet.isConnecting,
                statusMessage: fleet.statusMessage,
                hasLiveSnapshot: fleet.hasLiveSnapshotForActiveVehicle
            ),
            .content
        )
        fleet.stop()
    }

    /// RETRIES EXHAUSTED, non-streaming car: the socket authenticates and emits
    /// nothing (a car in service), and every `/snapshot` ask fails. The screen
    /// must land on the HONEST state — the arm `HomeScreen` could not reach —
    /// with a retry, and never on content built over a snapshot that never came.
    func testRetriesExhaustedOnANonStreamingCarRendersTheHonestState() async {
        let fleet = Self.makeFleet(
            channelFactory: AuthenticatingChannelFactory(),
            snapshotAlwaysFails: true,
            budget: 0.4
        )
        fleet.start()

        await eventually { fleet.vehicles.count == 1 }
        await eventually(timeout: 5) { fleet.statusMessage != nil }

        XCTAssertFalse(fleet.hasLiveSnapshotForActiveVehicle)
        let presentation = OwnerHomePresentation.resolve(
            hasVehicle: fleet.vehicles.count > 0,
            hasTelemetry: true,
            isConnecting: fleet.isConnecting,
            statusMessage: fleet.statusMessage,
            hasLiveSnapshot: fleet.hasLiveSnapshotForActiveVehicle
        )
        XCTAssertEqual(presentation, .unavailable(message: "Can\u{2019}t reach Lunar right now"))
        XCTAssertTrue(presentation.offersRetry)
        fleet.stop()
    }

    /// The retry is a real re-ask, not a spinner: from the honest state it drops
    /// the stale line and goes back to loading while it asks again — the same
    /// ladder a resume walks.
    func testRetryReAsksFromTheHonestState() async {
        let fleet = Self.makeFleet(
            channelFactory: AuthenticatingChannelFactory(),
            snapshotAlwaysFails: true,
            budget: 0.4
        )
        fleet.start()
        await eventually(timeout: 5) { fleet.statusMessage != nil }

        fleet.retry()

        XCTAssertNil(fleet.statusMessage, "the retry must drop the line it is retrying")
        XCTAssertTrue(fleet.isConnecting, "…and say so, honestly, while it re-asks")
        // And the budget is a REAL one — it settles again rather than shimmering
        // forever, which is the whole invariant.
        await eventually(timeout: 5) { fleet.statusMessage != nil }
        fleet.stop()
    }

    /// A snapshot that lands is REMEMBERED, so the next cold launch has somewhere
    /// real to point the camera before the read completes.
    func testALandedSnapshotSeedsTheLastKnownPositionCache() async {
        let store = Self.makeStore()
        let fleet = Self.makeFleet(
            channelFactory: AuthenticatingChannelFactory(),
            budget: 30,
            lastKnownPositions: store
        )
        fleet.start()

        await eventually(timeout: 5) { fleet.telemetry(at: 0).snapshot.odometerMiles != nil }
        await eventually { store.position(forVehicleID: Self.vehicleID) != nil }

        XCTAssertEqual(fleet.lastKnownPosition(at: 0)?.latitude ?? 0, 37.7955, accuracy: 0.0001)
        fleet.stop()
    }

    /// And a car that never answers still gets a NON-null-island camera off that
    /// cache — the two halves of the fix meeting.
    func testAColdLaunchWithNoSnapshotStillFramesTheCachedPosition() async {
        let store = Self.makeStore()
        store.record(
            vehicleID: Self.vehicleID,
            coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
        )
        let fleet = Self.makeFleet(
            channelFactory: AuthenticatingChannelFactory(),
            snapshotAlwaysFails: true,
            budget: 0.4,
            lastKnownPositions: store
        )
        fleet.start()
        await eventually { fleet.vehicles.count == 1 }

        // The row is the LIST's, so its activity is the `(0, 0)` placeholder…
        let placeholder = fleet.vehicles[0].activity
        guard case .parked(let location) = placeholder else {
            return XCTFail("an offline list row must map to a parked placeholder")
        }
        XCTAssertFalse(OwnerMapCamera.hasFix(location.coordinate))

        // …and the camera goes to the cache instead of the Gulf of Guinea.
        let target = OwnerMapCamera.resolve(
            vehicle: location.coordinate,
            lastKnown: fleet.lastKnownPosition(at: 0),
            spanDelta: MRTMetrics.mapRegionSpanDelta
        )
        XCTAssertEqual(target.source, .lastKnown)
        XCTAssertTrue(OwnerMapCamera.hasFix(target.center!))
        fleet.stop()
    }

    // MARK: - Support

    private static func makeStore() -> LastKnownVehiclePositionStore {
        let suite = "MYR387-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return LastKnownVehiclePositionStore(defaults: defaults)
    }

    private static func makeFleet(
        channelFactory: any WebSocketChannelFactory,
        snapshotAlwaysFails: Bool = false,
        budget: TimeInterval,
        lastKnownPositions: LastKnownVehiclePositionStore? = nil
    ) -> LiveVehicleFleet {
        // swiftlint:disable:next force_try
        let snapshotBody = try! JSONEncoder().encode(snapshotState())
        let asleep = Data(#"{"error":{"code":"vehicle_asleep","message":"did not wake"}}"#.utf8)
        let http = RoutedHTTP([
            .init(
                "/snapshot",
                failFirst: snapshotAlwaysFails ? Int.max : 0,
                status: 503,
                failureBody: asleep,
                body: snapshotBody
            ),
            .init("/vehicles", body: Contracts.listResponse([listRow()])),
        ])
        return LiveVehicleFleet(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: channelFactory,
            coldSnapshotBudget: budget,
            lastKnownPositions: lastKnownPositions ?? makeStore()
        ))
    }

    /// The LEAN list row: name known, position not. Exactly the client's shape.
    private nonisolated static func listRow(status: VehicleSummary.Status = .offline) -> VehicleSummary {
        VehicleSummary(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vinLast4: "3795",
            status: status,
            chargeLevel: 71,
            estimatedRange: 244,
            lastUpdated: "2026-07-31T17:40:00.000Z",
            role: .owner,
            licensePlate: nil
        )
    }

    private nonisolated static func snapshotState() -> VehicleState {
        VehicleState(
            vehicleId: vehicleID,
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "",
            vin: "7SAYGDEE9RA123795",
            softwareVersion: "2026.14.3",
            trim: "Performance",
            status: .parked,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: "Embarcadero Center",
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: 71,
            estimatedRange: 244,
            interiorTemp: 58,
            exteriorTemp: 55,
            odometerMiles: 18432,
            fsdMilesSinceReset: 11274,
            lastUpdated: "2026-07-31T17:40:00.000Z"
        )
    }

    private func eventually(
        timeout: TimeInterval = 3,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "condition never became true within \(timeout)s")
    }
}
