import CoreLocation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest

// MARK: - MYR-449 — live tracking must ENGAGE on frames, and SAY SO when it cannot
//
// **THE REPORT.** External beta, build `202608030843`, 2026-08-07: *"riders were
// not able to see the live telemetry data from the vehicle for the ride share flow
// and it instead was showing like apple maps route after ride was accepted by
// tesla."*
//
// **THE SERVER SIDE WAS CLEARED BY PROD, WHICH IS WHAT MAKES THIS A CLIENT
// ISSUE.** Every external-tester ride since 2026-08-03 ran on one car that was
// `connected`, virtual-key paired and streaming continuously, and viewer-role
// `mask_applied` events land on the viewer BROADCAST path *inside* every ride
// window (James, 08-06 00:05:34 → 00:17:48; Aarthi, 08-05 00:44:50 and 00:48:50).
// Both riders held accepted `allow_rides` shares. MYR-435's mask was cleared as a
// suspect too — it retains latitude, longitude, heading, speed and the whole nav
// group. **The car streamed, the grant was valid, the frames were delivered, and
// the rider's tracking sheet drew a route with no car on it.**
//
// **THE CAUSE, AND WHY EVERY SIMULATED CAPTURE PASSED.** `LiveVehicleState
// .apply(.update:)` opened `guard let current = state else { return }` — so a
// `vehicle_update` was DISCARDED unless a cold REST `/snapshot` had already
// landed. The rider's entire live surface was therefore gated on one REST read
// that the VIEWER path can legitimately never complete: a `403` latches
// `snapshotAccessDenied` per vehicle for good (MYR-432), the MYR-319 ladder is
// bounded and then stops, and MYR-440 records a viewer snapshot that "retried
// silently forever" while the map sat on "Locating…". Downstream that is
// `state == nil` → `RiderVehicleProjection.hasFix` false → `RiderCarMarker
// .withheld` → no glyph, and `trackingLeg1Route == []` → one MKDirections leg-2
// polyline and two pins. **That picture IS an Apple-Maps route preview.** No
// simulated or DEBUG scene could ever reach it, because both supply a snapshot.
//
// So every test below drives the REAL composition — `RiderLiveVehicleLocator` →
// `TelemetrySocket` (authenticating channel + routed REST) → `LiveVehicleState` →
// `LiveVehicleTelemetrySource` → `VehicleContractMapping` /
// `RiderVehicleProjection` → the shipping `RiderCarMarker` /
// `RiderTrackingLiveReport` resolvers — with the WIRE injected and nothing
// downstream stubbed, and the SNAPSHOT REFUSED exactly as the server refuses it.
// A test that seeded a `VehicleState` would pass over the whole defect.
@MainActor
final class RiderLiveTrackingEngagementTests: XCTestCase {

    // MARK: Wire fixtures

    /// A car shared with the rider at tier `rides` — James's and Aarthi's grant.
    private nonisolated static func sharedRow(id: String = "shared-1") -> VehicleSummary {
        VehicleSummary(
            vehicleId: id, name: "Lunar", model: "Model Y", year: 2026,
            color: "Quicksilver", vinLast4: "3795", status: .driving,
            chargeLevel: 71, estimatedRange: 244,
            lastUpdated: "2026-08-06T00:04:38.000Z", role: .viewer,
            sharePermission: .rides
        )
    }

    /// Somewhere on the ride. The exact value only has to differ from `(0, 0)`.
    private static let onRoute = CLLocationCoordinate2D(latitude: 37.7871, longitude: -122.3971)
    private static let furtherAlong = CLLocationCoordinate2D(latitude: 37.7920, longitude: -122.3999)

    /// **THE SNAPSHOT IS REFUSED, FOREVER.** `failFirst` far exceeds the MYR-319
    /// ladder, so this is not "slow" — it is the server's settled `403`, the answer
    /// MYR-432 latches per vehicle. It is the whole reason the frames matter.
    private nonisolated static func routedHTTPRefusingSnapshots(rows: [VehicleSummary]) -> RoutedHTTP {
        RoutedHTTP([
            .init("/snapshot", failFirst: 9_999, status: 403,
                  failureBody: Data(#"{"error":{"code":"forbidden","message":"viewer"}}"#.utf8),
                  body: Data()),
            .init("/vehicles", body: Contracts.listResponse(rows)),
        ])
    }

    // MARK: Composition (the real one)

    private func makeLocator(
        http: any HTTPPerforming,
        channels: AuthenticatingChannelFactory
    ) -> RiderLiveVehicleLocator {
        RiderLiveVehicleLocator(config: .init(
            environment: .test,
            tokenProvider: StaticTokenProvider("test-token"),
            http: http,
            channelFactory: channels
        ))
    }

    private func makeState(locator: RiderLiveVehicleLocator, isLive: Bool = true) -> SharedViewerState {
        let seams = PlaceSearchComposition.Seams(
            placeSearch: SimulatedPlaceSearch(),
            userLocation: TrackingFakeLocation(),
            liveVehicleLocator: locator,
            pinLabeler: SimulatedPinLabeler(),
            isLive: isLive
        )
        // `nil` is what `RootView` passes on the live path (MYR-184/228).
        return SharedViewerState(vehicle: isLive ? nil : VehicleFixtures.vehicles[0], seams: seams)
    }

    /// The SHIPPING adoption rule over a §7.0 list, exactly as `RootView
    /// .adoptRiderVehicle` runs it.
    private func adopt(_ rows: [VehicleSummary], into state: SharedViewerState) {
        let resolution = RiderVehicleSet.resolve(
            hasLoaded: true,
            loadFailed: false,
            grants: LiveSharedVehicleCatalog.grants(from: rows),
            ownedVehicles: LiveSharedVehicleCatalog.ownedVehicles(from: rows)
        )
        if case .ridable(let adoption) = resolution { state.adopt(adoption) }
    }

    /// The marker the tracking map would draw for this frame, through the SHIPPING
    /// resolver and the SHIPPING seams — not a re-implementation of the rule.
    private func marker(_ state: SharedViewerState, now: Date = Date()) -> RiderCarMarker {
        RiderCarMarker.resolve(
            resolvesLiveMotion: state.resolvesTrackingMotion,
            state: state.trackingVehicleState,
            lastUpdated: state.trackingPositionRead.lastUpdated,
            isStreaming: state.trackingPositionRead.isStreaming,
            now: now
        )
    }

    // MARK: - THE HEADLINE: frames arriving + tracking mounted → live rendering engages

    /// **THE REGRESSION GUARD FOR MYR-449.** The car is streaming, the server
    /// delivers a viewer-role `vehicle_update`, the cold snapshot is refused `403`
    /// — and the rider's tracking surface must show the car.
    ///
    /// Pre-fix this fails on the first assertion: the frame is discarded,
    /// `trackingVehicleState` is `nil`, and the map draws a route with no car.
    func testAViewerFrameEngagesLiveTrackingWithNoSnapshotBehindIt() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking

        // The subscription is genuinely up before any frame is pushed — otherwise
        // this would prove only that a frame nobody subscribed to was ignored.
        await eventually { locator.watchedVehicleID == row.vehicleId }
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        // Precondition, and it is the defect's own precondition: the server
        // refused the snapshot, so nothing has established state.
        XCTAssertNil(state.trackingVehicleState, "precondition: the 403 left no snapshot")

        await Self.push(channels, AuthenticatingWebSocketChannel.viewerGPSFrame(
            vehicleId: row.vehicleId,
            latitude: Self.onRoute.latitude,
            longitude: Self.onRoute.longitude
        ))

        await eventually { state.trackingVehicleCoordinate != nil }

        assertCoordinate(state.trackingVehicleCoordinate, isNear: Self.onRoute)
        XCTAssertEqual(marker(state), .live(stale: false),
                       "a delivered viewer frame must put the car on the tracking map")
        XCTAssertTrue(RiderTrackingLiveReport.resolve(
            marker: marker(state),
            openedAt: state.trackingLiveWatch.openedAt,
            now: Date()
        ).claimsLivePosition)

        state.stopTelemetry()
    }

    /// THE CAR MOVES. One frame proves engagement; a second proves this is
    /// tracking rather than a single position that happens to be drawn.
    func testSuccessiveFramesMoveTheTrackedCar() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        await Self.push(channels, AuthenticatingWebSocketChannel.viewerGPSFrame(
            vehicleId: row.vehicleId,
            latitude: Self.onRoute.latitude, longitude: Self.onRoute.longitude
        ))
        await eventually { state.trackingVehicleCoordinate != nil }

        await Self.push(channels, AuthenticatingWebSocketChannel.viewerGPSFrame(
            vehicleId: row.vehicleId,
            latitude: Self.furtherAlong.latitude, longitude: Self.furtherAlong.longitude,
            lastUpdated: "2026-08-06T00:12:44Z"
        ))
        await eventually {
            (state.trackingVehicleCoordinate?.latitude ?? 0) > Self.onRoute.latitude
        }

        assertCoordinate(state.trackingVehicleCoordinate, isNear: Self.furtherAlong)

        // And the MOTION LADDER agrees, off the same state: a rider watching this
        // must read "Heading your way", not MYR-393's waiting line.
        var latch = RiderMotionLatch()
        let evidence = latch.update(rideID: "ride-1", state: state.trackingVehicleState)
        XCTAssertTrue(evidence.provesMotion, "a streaming car in D is moving")

        state.stopTelemetry()
    }

    // MARK: - THE HONEST HALF: when nothing is flowing, the sheet says so

    /// **THE SURFACE MAY NOT IMPERSONATE TRACKING.** With no frame and no snapshot,
    /// the map correctly withholds the marker (MYR-393) — and before this issue it
    /// also said nothing at all, which is what made a data-less tracking sheet
    /// indistinguishable from a route preview.
    func testWithNoDataTheSheetSaysItIsWaitingRatherThanShowingASilentPreview() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventuallyAsync { await Self.subscribed(channels, to: row.vehicleId) }

        let opened = try? XCTUnwrap(state.trackingLiveWatch.openedAt)
        XCTAssertNotNil(opened, "entering tracking arms the honest-state clock")

        let marker = marker(state)
        XCTAssertEqual(marker, .withheld, "no fix → no gold pin (MYR-393, unchanged)")

        // Inside the grace: waiting, and it SAYS waiting.
        let early = RiderTrackingLiveReport.resolve(
            marker: marker, openedAt: state.trackingLiveWatch.openedAt, now: Date()
        )
        XCTAssertEqual(early, .waiting)
        XCTAssertFalse(early.claimsLivePosition)
        let earlyNote = RiderTrackingLiveReport.note(
            state: early, marker: marker, lastUpdated: nil, vehicleName: "Lunar", now: Date()
        )
        XCTAssertEqual(earlyNote, "Waiting for live location from Lunar…")

        // Past it: the escalation NAMES a likely cause, in the repo's own
        // honest-degradation grammar, and keeps "right now" — the ladder is still
        // retrying underneath, so this must not read as a verdict.
        let late = Date().addingTimeInterval(RiderTrackingLiveReport.grace + 1)
        let escalated = RiderTrackingLiveReport.resolve(
            marker: marker, openedAt: state.trackingLiveWatch.openedAt, now: late
        )
        XCTAssertEqual(escalated, .unavailable)
        XCTAssertFalse(escalated.claimsLivePosition)
        let lateNote = RiderTrackingLiveReport.note(
            state: escalated, marker: marker, lastUpdated: nil, vehicleName: "Lunar", now: late
        )
        XCTAssertEqual(lateNote, "Live location unavailable right now — Lunar may be asleep")

        state.stopTelemetry()
    }

    /// A FRAME THAT ARRIVES AND THEN STOPS falls back to MYR-393's "last seen"
    /// grammar rather than leaving a stale marker looking current — and it is
    /// MYR-393's sentence verbatim, not a second dialect for one fact.
    func testFramesThatStopFallBackToTheLastSeenGrammar() {
        let quiet = Date().addingTimeInterval(-4 * 60)
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true,
            state: Self.stateWithFix(),
            lastUpdated: quiet,
            isStreaming: false,
            now: Date()
        )
        XCTAssertEqual(marker, .live(stale: true))

        let resolved = RiderTrackingLiveReport.resolve(
            marker: marker, openedAt: Date().addingTimeInterval(-300), now: Date()
        )
        XCTAssertEqual(resolved, .stale)
        XCTAssertFalse(resolved.claimsLivePosition, "a stale position is not live tracking")
        XCTAssertEqual(
            RiderTrackingLiveReport.note(
                state: resolved, marker: marker, lastUpdated: quiet, vehicleName: "Lunar", now: Date()
            ),
            RiderCarFreshnessNote.text(marker: marker, lastUpdated: quiet, now: Date()),
            "the stale arm is MYR-393's sentence verbatim — one fact, one grammar"
        )
    }

    /// THE SIMULATED PATH IS UNTOUCHED, BY CONSTRUCTION. Every `trackingLeg1` /
    /// `trackingLeg2` / `trackingArriving` capture renders no note at all, so the
    /// drift gate is unmoved — the same short-circuit MYR-393 takes.
    func testTheSimulatedTrackingSurfaceRendersNoNoteAtAll() {
        for openedAt in [nil, Date().addingTimeInterval(-3_600)] as [Date?] {
            let resolved = RiderTrackingLiveReport.resolve(
                marker: .simulated, openedAt: openedAt, now: Date()
            )
            XCTAssertEqual(resolved, .simulated)
            XCTAssertNil(RiderTrackingLiveReport.note(
                state: resolved, marker: .simulated, lastUpdated: nil,
                vehicleName: "Cybercab", now: Date()
            ))
        }
    }

    /// A CURRENT FIX CARRIES NO WORDS. The gold glyph is the whole statement, so
    /// the healthy live surface is byte-identical to before this issue.
    func testAHealthyLiveFixRendersNoNote() {
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true, state: Self.stateWithFix(),
            lastUpdated: Date(), isStreaming: true, now: Date()
        )
        let resolved = RiderTrackingLiveReport.resolve(
            marker: marker, openedAt: Date().addingTimeInterval(-600), now: Date()
        )
        XCTAssertEqual(resolved, .live)
        XCTAssertTrue(resolved.claimsLivePosition)
        XCTAssertNil(RiderTrackingLiveReport.note(
            state: resolved, marker: marker, lastUpdated: Date(), vehicleName: "Lunar", now: Date()
        ))
    }

    // MARK: - THE RECOVERY: a silently dark socket is re-established, boundedly

    /// **THE CLIENT STOPS WAITING ON A SOCKET THAT SAYS NOTHING.** Two server
    /// hazards (a handshake `ResolveRole` blip leaving a deny-all mask; an access
    /// set that only ever narrows) produce a socket that is up, authenticated,
    /// error-free — and delivers zero frames for ever, with no reconnect trigger.
    /// Indistinguishable from a parked car from here, so after the grace the
    /// stream is re-established rather than waited on.
    func testAStreamThatNeverDeliversIsReEstablishedAfterTheGrace() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        await eventually { locator.watchedVehicleID == row.vehicleId }

        XCTAssertEqual(locator.darkStreamRecoveryCount, 0)

        // Drive the clock rather than sleeping through 30s of real time.
        state.trackingLiveWatch.advance(
            now: Date().addingTimeInterval(RiderTrackingLiveReport.grace + 1)
        )
        await eventually { locator.darkStreamRecoveryCount == 1 }

        XCTAssertEqual(locator.watchedVehicleID, row.vehicleId,
                       "the recovery re-takes the SAME subscription, it does not drop the car")

        state.stopTelemetry()
    }

    /// **BOUNDED.** The honest end state for a car that is genuinely asleep is the
    /// sheet saying so, not a client reconnecting at it for the whole ride — the
    /// MYR-432 "~1–2 requests per second, forever" defect wearing a fix's clothes.
    func testTheDarkStreamRecoveryIsBounded() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        await eventually { locator.watchedVehicleID == row.vehicleId }

        for _ in 0..<6 { locator.recoverDarkStream() }

        XCTAssertEqual(locator.darkStreamRecoveryCount,
                       RiderLiveVehicleLocator.maxDarkStreamRecoveries,
                       "a recovery that is not bounded is a reconnect loop")

        state.stopTelemetry()
    }

    /// A CAR THAT IS REPORTING IS NEVER RECOVERED AT, however long the surface has
    /// been up — the watch asks for a fix before it fires, so a long healthy ride
    /// cannot be interrupted by its own clock.
    func testTheWatchDoesNotRecoverWhileAFixIsInHand() {
        let watch = RiderTrackingLiveWatch()
        var fired = 0
        watch.hasLiveFix = { true }
        watch.onGraceElapsed = { fired += 1 }
        watch.arm(now: Date().addingTimeInterval(-600))

        watch.advance(now: Date())

        XCTAssertEqual(fired, 0, "a streaming car needs no recovery")
        watch.disarm()
    }

    /// AND IT FIRES AT MOST ONCE PER ARMED SURFACE, so a 5s tick cannot become a
    /// 5s reconnect cadence.
    func testTheGraceFiresOnceForOneArmedSurface() {
        let watch = RiderTrackingLiveWatch()
        var fired = 0
        watch.hasLiveFix = { false }
        watch.onGraceElapsed = { fired += 1 }
        watch.arm()

        let late = Date().addingTimeInterval(RiderTrackingLiveReport.grace + 1)
        for _ in 0..<5 { watch.advance(now: late) }

        XCTAssertEqual(fired, 1)
        watch.disarm()
    }

    /// LEAVING TRACKING DISARMS IT. A grace must not elapse behind a surface that
    /// is gone, and re-entering starts a fresh one.
    func testLeavingTrackingDisarmsTheClock() async {
        let row = Self.sharedRow()
        let http = Self.routedHTTPRefusingSnapshots(rows: [row])
        let channels = AuthenticatingChannelFactory()
        let locator = makeLocator(http: http, channels: channels)
        let state = makeState(locator: locator)

        adopt([row], into: state)
        state.startTelemetry()
        state.sheetPhase = .tracking
        XCTAssertNotNil(state.trackingLiveWatch.openedAt)

        state.sheetPhase = .summary
        XCTAssertNil(state.trackingLiveWatch.openedAt)

        state.sheetPhase = .tracking
        XCTAssertNotNil(state.trackingLiveWatch.openedAt, "re-entering arms a fresh grace")

        state.stopTelemetry()
    }

    // MARK: - Helpers

    private nonisolated static func stateWithFix() -> VehicleState {
        VehicleState(
            vehicleId: "shared-1", name: "Lunar", model: "Model Y", year: 2026, color: "Quicksilver",
            status: .driving, speed: 27, heading: 212,
            latitude: onRoute.latitude, longitude: onRoute.longitude,
            locationName: "Embarcadero", locationAddress: "1 Embarcadero Ctr",
            chargeLevel: 71, estimatedRange: 244, odometerMiles: 6349, fsdMilesSinceReset: 812.5,
            lastUpdated: "2026-08-06T00:11:44Z"
        )
    }

    /// Has the socket actually sent a `subscribe` for this vehicle on the live
    /// channel? Pushing a frame before it has would prove nothing.
    private static func subscribed(_ channels: AuthenticatingChannelFactory, to vehicleId: String) async -> Bool {
        for channel in channels.madeChannels() {
            let frames = await channel.sentFrames()
            if frames.contains(where: { $0.contains(#""type":"subscribe""#) && $0.contains(vehicleId) }) {
                return true
            }
        }
        return false
    }

    /// Push a server frame down the newest channel — the one the socket is on.
    private static func push(_ channels: AuthenticatingChannelFactory, _ frame: String) async {
        guard let channel = channels.madeChannels().last else { return }
        await channel.emit(frame)
    }

    private func assertCoordinate(
        _ actual: CLLocationCoordinate2D?,
        isNear expected: CLLocationCoordinate2D,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else { return XCTFail("no coordinate", file: file, line: line) }
        XCTAssertEqual(actual.latitude, expected.latitude, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.longitude, expected.longitude, accuracy: 0.0001, file: file, line: line)
    }

    private func eventually(
        timeout: TimeInterval = 4.0,
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

    private func eventuallyAsync(
        timeout: TimeInterval = 4.0,
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("async condition never became true", file: file, line: line)
    }
}

// MARK: - Test doubles

@Observable
@MainActor
private final class TrackingFakeLocation: UserLocationProviding {
    var coordinate: CLLocationCoordinate2D?
    var currentLocationLabel: String { "Current location" }
    var showsUserLocationDot: Bool { coordinate != nil }
    func start() {}
    func stop() {}
    func refresh() {}
}
