import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

/// MYR-432 — §6.2 close code **4002 (Permission Revoked)** must PRUNE the vehicle
/// and stand down.
///
/// The defect these guard: the client never inspected the close code, so `supervise`
/// treated 4002 as transport churn. The reconnect re-handshakes successfully (the
/// JWT is still valid — only the access set shrank), `auth_ok` resets `attempt` to
/// 0 so backoff can never escalate, and `onConnected` re-subscribes every key in
/// `subscribers` — which still holds the revoked vehicle. A permanent ~1s loop,
/// plus one `GET /api/vehicles/{id}/snapshot` **403** per cycle from the MYR-387
/// standalone fallback, for as long as the app is open.
///
/// The four claims, one per group below:
///   1. 4002 → exactly ONE reconnect → the revoked vehicle is pruned, and nothing
///      about it is ever sent or fetched again.
///   2. A viewer revoked from ONE of two cars keeps the other streaming.
///   3. A TRANSIENT close is byte-identical to what it always was.
///   4. Defence in depth: a `403` snapshot stops the ladder for THAT vehicle.
final class AccessRevocationTests: XCTestCase {
    private func vehicleState() throws -> VehicleState {
        try JSONDecoder().decode(VehicleState.self, from: try Fixture.data("rest/snapshot.json"))
    }

    /// Fast, deterministic backoff so the escalation is observable without waiting
    /// on the 1s contract delay. Jitter 0 so a delay is a function of `attempt`
    /// alone.
    private let fastBackoff = ExponentialBackoff(initialDelay: 0.002, multiplier: 2, maxDelay: 0.05, jitterFraction: 0)

    private func makeSocket(
        channels: [MockWebSocketChannel],
        snapshots: any SnapshotFetching,
        access: (any VehicleAccessListing)?
    ) -> TelemetrySocket {
        TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: access,
            channelFactory: MockChannelFactory(channels),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            // One immediate attempt: the ladder is MYR-319's concern, and leaving
            // it armed would make "did the retry stop" a race with a 0.8s sleep.
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.02
        )
    }

    // MARK: - 1. One reconnect, then the prune

    func testAnAccessCloseReconnectsOnceAndPrunesTheVehicleTheNewSetOmits() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let factory = MockChannelFactory([channel0, channel1])
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        // The owner revoked this viewer outright: the re-handshake's access set is
        // EMPTY. The stub is what a reduced `GET /api/vehicles` answers with.
        let access = StubAccessListing([])

        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: access,
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.02
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }
        await eventually { await snapshots.callCount("v1") == 1 }

        // The owner taps Revoke; the server closes with §6.2's code.
        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)

        // EXACTLY ONE reconnect. The re-handshake is legitimate — it is the only
        // thing that can deliver the reduced set — and it is also the last one.
        await eventually(timeout: 3.0) { factory.madeCount() == 2 }
        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs().isEmpty }

        // The stream was terminated with the ACCESS event, not simply dropped: a
        // consumer must be able to tell "the server stopped letting us" from "we
        // stopped watching".
        let events = await drained(stream)
        guard case .accessRevoked = events.last else {
            return XCTFail("expected .accessRevoked last, got \(String(describing: events.last))")
        }

        // The second connection NEVER sent a subscribe frame for the revoked car —
        // the prune runs BEFORE `onConnected`, so both server generations converge:
        // one that would close again, and one that silently refuses (PR #369).
        let sent1 = await channel1.sentFrames()
        XCTAssertTrue(sent1.contains { $0.contains("\"auth\"") }, "must re-authenticate")
        XCTAssertFalse(
            sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v1") },
            "the revoked vehicle must never be re-subscribed"
        )

        await socket.disconnect()
    }

    func testAfterThePruneTheRevokedVehicleCostsNoFurtherFramesOrRestReads() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: [channel0, channel1],
            snapshots: snapshots,
            access: StubAccessListing([])
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await snapshots.callCount("v1") == 1 }

        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)
        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs().isEmpty }

        // Well past the MYR-387 standalone grace (0.02s) and the ladder's first
        // delay. The reported symptom was ~1–2 of these PER SECOND, forever.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let reads = await snapshots.callCount("v1")
        XCTAssertEqual(reads, 1, "the cold read from BEFORE the revoke, and nothing after it")

        // And a live frame for the revoked car reaches nobody.
        await channel1.push(Self.vehicleUpdateFrame(vehicleId: "v1"))
        try? await Task.sleep(nanoseconds: 50_000_000)
        let stillSubscribed = await socket.subscribedVehicleIDs()
        XCTAssertTrue(stillSubscribed.isEmpty)

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testTheRevocationIsPublishedWithWhatWentAndWhatIsLeft() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: [channel0, channel1],
            snapshots: snapshots,
            access: StubAccessListing(["v2"])
        )

        let s1 = await socket.subscribe(to: "v1")
        let s2 = await socket.subscribe(to: "v2")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        let revocations = await socket.accessRevocations()
        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)

        let received = await firstRevocation(in: revocations)
        XCTAssertEqual(received?.revoked, ["v1"])
        XCTAssertEqual(received?.remaining, ["v2"], "the surface's question is what is LEFT")

        await socket.disconnect()
        withExtendedLifetime((s1, s2)) {}
    }

    func testACloseThatLandsMidHandshakeIsStillReadAsAccess() async throws {
        // ⚠️ THE ARM THE FIRST IMPLEMENTATION MISSED. Capturing the close code in
        // the `receive()` catch reads as sufficient — a close is what makes a read
        // fail. But a close arriving while the handshake is still in flight makes
        // the `send` throw instead, and the code was silently lost: the revocation
        // then degraded into an ordinary reconnect and the loop came straight back.
        // The server closes ~100µs after the owner's tap, so a revoke landing
        // inside a reconnect's own handshake is ordinary rather than exotic — and
        // it is intermittent, which is why it was found by a suite-under-load
        // failure rather than by reading.
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: [channel0, channel1],
            snapshots: snapshots,
            access: StubAccessListing([])
        )

        // Closed with the code BEFORE the socket ever writes its `auth` frame, so
        // the failure surfaces on the send and never reaches a `receive()`.
        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()

        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs().isEmpty }
        let counters = await socket.retryCounters()
        XCTAssertEqual(counters.accessCloseStreak, 0, "the prune settled it")

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    // MARK: - 2. Partial revocation

    func testAViewerRevokedFromOneOfTwoCarsKeepsTheOtherStreaming() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let factory = MockChannelFactory([channel0, channel1])
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: StubAccessListing(["v2"]),
            channelFactory: factory,
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            snapshotRetryDelays: [0],
            standaloneSnapshotGrace: 0.02
        )

        let s1 = await socket.subscribe(to: "v1")
        let s2 = await socket.subscribe(to: "v2")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }
        await eventually { await snapshots.callCount("v2") == 1 }

        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)

        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs() == ["v2"] }
        await eventually(timeout: 3.0) { await socket.currentConnectionState() == .connected }

        // The surviving car re-subscribed and re-baselined exactly as an ordinary
        // reconnect leaves it — a revocation of somebody ELSE'S grant must be
        // invisible on this stream.
        let sent1 = await channel1.sentFrames()
        XCTAssertTrue(sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v2") })
        XCTAssertFalse(sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v1") })
        await eventually(timeout: 3.0) { await snapshots.callCount("v2") == 2 }

        // And it is still LIVE: a frame after the prune reaches it.
        await channel1.push(Self.vehicleUpdateFrame(vehicleId: "v2"))
        let update = await firstEvent(in: s2) { event in
            if case .update = event { return true }
            return false
        }
        XCTAssertNotNil(update, "the surviving car keeps streaming")

        await socket.disconnect()
        withExtendedLifetime(s1) {}
    }

    // MARK: - 3. Transient close codes are unchanged

    func testATransientCloseKeepsTodaysReconnectBehaviourByteIdentical() async throws {
        // Two arms of "transient": no close code at all (a dropped connection),
        // and a NAMED code that is not the access signal. Both must resubscribe.
        for code in [nil, 1001, 1011, 4001] as [Int?] {
            let channel0 = MockWebSocketChannel(label: 0)
            let channel1 = MockWebSocketChannel(label: 1)
            let factory = MockChannelFactory([channel0, channel1])
            let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
            // An access listing that would prune EVERYTHING if it were ever
            // consulted — so a transient close reaching the access path fails
            // loudly rather than passing quietly.
            let access = StubAccessListing([])
            let socket = TelemetrySocket(
                webSocketURL: URL(string: "wss://example/api/ws")!,
                tokenProvider: StaticTokenProvider("t"),
                snapshotSource: snapshots,
                accessListing: access,
                channelFactory: factory,
                backoff: fastBackoff,
                randomUnit: { 0.5 },
                snapshotRetryDelays: [0],
                standaloneSnapshotGrace: 0.02
            )

            let stream = await socket.subscribe(to: "v1")
            await socket.connect()
            await eventually { await snapshots.callCount("v1") == 1 }

            if let code { await channel0.closeWith(code: code) } else { await channel0.close() }

            await eventually(timeout: 3.0) { factory.madeCount() == 2 }
            await eventually(timeout: 3.0) { await snapshots.callCount("v1") == 2 }
            let sent1 = await channel1.sentFrames()
            XCTAssertTrue(
                sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v1") },
                "close \(String(describing: code)) must resubscribe exactly as before"
            )
            let subscribed = await socket.subscribedVehicleIDs()
            XCTAssertEqual(subscribed, ["v1"], "close \(String(describing: code))")
            let accessReads = await access.callCount()
            XCTAssertEqual(accessReads, 0, "a transient close must not consult the access set")
            let counters = await socket.retryCounters()
            XCTAssertEqual(counters.accessCloseStreak, 0, "close \(String(describing: code))")

            await socket.disconnect()
            withExtendedLifetime(stream) {}
        }
    }

    func testAnOwnerWhoseAccessSetIsUnchangedLosesNothing() async throws {
        // The owner path: 4002 is not a code they can receive today, but the
        // reconciliation must be inert for anyone whose set did not shrink — a
        // prune keyed on the close code alone would blank a whole fleet.
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: [channel0, channel1],
            snapshots: snapshots,
            access: StubAccessListing(["v1"])
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)

        await eventually(timeout: 3.0) { await snapshots.callCount("v1") == 2 }
        let subscribed = await socket.subscribedVehicleIDs()
        XCTAssertEqual(subscribed, ["v1"], "an unchanged set prunes nothing")
        let sent1 = await channel1.sentFrames()
        XCTAssertTrue(sent1.contains { $0.contains("\"subscribe\"") && $0.contains("v1") })

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testAFailedAccessReadPrunesNothing() async throws {
        struct Unreachable: Error {}
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: [channel0, channel1],
            snapshots: snapshots,
            // MYR-326's rule, pointed at access: a list that did not ANSWER is not
            // evidence a car is gone.
            access: StubAccessListing([], failure: Unreachable())
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)
        await eventually(timeout: 3.0) { await snapshots.callCount("v1") == 2 }
        let subscribed = await socket.subscribedVehicleIDs()
        XCTAssertEqual(subscribed, ["v1"])

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    // MARK: - The loop cannot be permanent

    func testRepeatedAccessClosesEscalateInsteadOfLooping() async throws {
        // An OLD server (or one closing over a set we already agree with): every
        // connection closes 4002 and the access set never shrinks, so no prune
        // ever settles it. This is the exact shape of the reported permanent loop.
        let channels = (0..<8).map { MockWebSocketChannel(label: $0) }
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(
            channels: channels,
            snapshots: snapshots,
            access: StubAccessListing(["v1"])
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        for index in 0..<4 {
            await channels[index].closeWith(code: TelemetryCloseCode.permissionRevoked)
            await eventually(timeout: 3.0) { await socket.retryCounters().accessCloseStreak == index + 1 }
            if index < 3 {
                await eventually(timeout: 3.0) { await socket.currentConnectionState() == .connected }
            }
        }

        let counters = await socket.retryCounters()
        XCTAssertEqual(counters.accessCloseStreak, 4)
        // THE ASSERTION THAT MATTERS. `attempt` is what the backoff reads, and
        // every one of these closes was preceded by an `auth_ok` that reset it to
        // 0 — which is precisely why the pre-fix loop ran at ~1s forever. The
        // access streak is what carries the escalation across that reset.
        XCTAssertGreaterThanOrEqual(counters.attempt, 3, "backoff must escalate across repeated access closes")

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testTheFirstAccessCloseIsFreeAndASettledPruneRearmsIt() async throws {
        let channel0 = MockWebSocketChannel(label: 0)
        let channel1 = MockWebSocketChannel(label: 1)
        let channel2 = MockWebSocketChannel(label: 2)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let access = StubAccessListing(["v1", "v2"])
        let socket = makeSocket(channels: [channel0, channel1, channel2], snapshots: snapshots, access: access)

        let s1 = await socket.subscribe(to: "v1")
        let s2 = await socket.subscribe(to: "v2")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        // First revocation: v1 goes.
        await access.setIDs(["v2"])
        await channel0.closeWith(code: TelemetryCloseCode.permissionRevoked)
        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs() == ["v2"] }
        // A prune that SETTLED the episode clears the streak, so a later, unrelated
        // revocation gets its own free re-handshake rather than inheriting this
        // one's escalation.
        let streakAfterFirst = await socket.retryCounters().accessCloseStreak
        XCTAssertEqual(streakAfterFirst, 0)

        // Second revocation, minutes later in wall-clock terms: v2 goes too.
        await access.setIDs([])
        await eventually(timeout: 3.0) { await socket.currentConnectionState() == .connected }
        await channel1.closeWith(code: TelemetryCloseCode.permissionRevoked)
        await eventually(timeout: 3.0) { await socket.subscribedVehicleIDs().isEmpty }
        let streakAfterSecond = await socket.retryCounters().accessCloseStreak
        XCTAssertEqual(streakAfterSecond, 0)

        await socket.disconnect()
        withExtendedLifetime((s1, s2)) {}
    }

    // MARK: - 4. Defence in depth — a 403 stops the ladder for THAT vehicle

    func testA403SnapshotStopsTheRetryForThatVehicleAndNoOther() async throws {
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState(), refusals: ["v1": 403])
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: nil,
            channelFactory: MockChannelFactory([channel]),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            // A REAL ladder: three further attempts, fast. A 403 must consume none
            // of them; a 503 (the asleep-car case MYR-319 exists for) must.
            snapshotRetryDelays: [0, 0.01, 0.02, 0.03],
            standaloneSnapshotGrace: 0.02
        )

        let s1 = await socket.subscribe(to: "v1")
        let s2 = await socket.subscribe(to: "v2")
        await socket.connect()
        await eventually { await snapshots.callCount("v2") == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)

        let refusedReads = await snapshots.callCount("v1")
        let healthyReads = await snapshots.callCount("v2")
        XCTAssertEqual(refusedReads, 1, "a 403 is an ANSWER — asking again cannot change it")
        XCTAssertEqual(healthyReads, 1, "the other car is untouched")

        await socket.disconnect()
        withExtendedLifetime((s1, s2)) {}
    }

    func testANonAccessFailureStillRunsTheFullLadder() async throws {
        // The control for the test above: MYR-319's whole reason for existing is a
        // car that answers `503 vehicle_asleep` first and succeeds later. Narrowing
        // the stop to 403 must leave that path exactly as it was.
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState(), refusals: ["v1": 503])
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: nil,
            channelFactory: MockChannelFactory([channel]),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            snapshotRetryDelays: [0, 0.01, 0.02, 0.03],
            standaloneSnapshotGrace: 0.02
        )

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually(timeout: 3.0) { await snapshots.callCount("v1") == 4 }

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testA403DoesNotArmTheStandaloneFallbackEither() async throws {
        // MYR-387's fallback fires when the SOCKET failed to deliver. The reported
        // "~1–2 REST 403s per second" came through it, so it has to stand down for
        // a refused vehicle on its own — not merely because the prune got there.
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState(), refusals: ["v1": 403])
        let socket = TelemetrySocket(
            webSocketURL: URL(string: "wss://example/api/ws")!,
            tokenProvider: StaticTokenProvider("t"),
            snapshotSource: snapshots,
            accessListing: nil,
            channelFactory: MockChannelFactory([channel]),
            backoff: fastBackoff,
            randomUnit: { 0.5 },
            // A REAL ladder behind each entry point, so the pre-fix build spends
            // three reads where this one spends one. With `[0]` the two builds
            // would be indistinguishable here and the test would prove nothing.
            snapshotRetryDelays: [0, 0.01, 0.02],
            standaloneSnapshotGrace: 0.02
        )

        // Subscribe with NO connection open, so the standalone grace is the only
        // thing that can fetch. It fires once, is refused, and stands down.
        let stream = await socket.subscribe(to: "v1")
        await eventually(timeout: 2.0) { await snapshots.callCount("v1") == 1 }
        // Re-arm it the way a resume would.
        await socket.refreshSnapshot(vehicleId: "v1")
        try? await Task.sleep(nanoseconds: 300_000_000)
        let asks = await snapshots.callCount("v1")
        XCTAssertLessThanOrEqual(
            asks, 2,
            "an explicit refresh may ask once; nothing may loop behind it"
        )

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    func testAnAccessSetThatRestoresAVehicleLiftsIts403Latch() async throws {
        // A client-side refusal must never outlive the server's decision.
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState(), refusals: ["v1": 403])
        let socket = makeSocket(channels: [channel], snapshots: snapshots, access: nil)

        let stream = await socket.subscribe(to: "v1")
        await socket.connect()
        await eventually(timeout: 2.0) { await snapshots.callCount("v1") >= 1 }
        let refusedCount = await snapshots.callCount("v1")

        await snapshots.allow("v1")
        // The same door the app's own §7.0 re-read uses.
        await socket.applyAccessSet(["v1"])
        await socket.refreshSnapshot(vehicleId: "v1")
        await eventually(timeout: 2.0) { await snapshots.callCount("v1") > refusedCount }
        let subscribed = await socket.subscribedVehicleIDs()
        XCTAssertEqual(subscribed, ["v1"], "a restored grant is not pruned")

        await socket.disconnect()
        withExtendedLifetime(stream) {}
    }

    // MARK: - `applyAccessSet` as the app's own door

    func testApplyAccessSetPrunesWithoutAnyCloseAtAll() async throws {
        // MYR-369's viewer half: a suspension is enforced by the row LEAVING
        // `GET /api/vehicles`, so a §7.0 read can be the first thing that knows —
        // for instance while the socket is down. The same reconciliation must be
        // reachable from there, not only from a close code.
        let channel = MockWebSocketChannel(label: 0)
        let snapshots = PerVehicleSnapshotSource(state: try vehicleState())
        let socket = makeSocket(channels: [channel], snapshots: snapshots, access: nil)

        let s1 = await socket.subscribe(to: "v1")
        let s2 = await socket.subscribe(to: "v2")
        await socket.connect()
        await eventually { await socket.currentConnectionState() == .connected }

        let revocation = await socket.applyAccessSet(["v2"])
        XCTAssertEqual(revocation?.revoked, ["v1"])
        let subscribed = await socket.subscribedVehicleIDs()
        XCTAssertEqual(subscribed, ["v2"])

        // Idempotent: a set that contains everything subscribed publishes nothing.
        let second = await socket.applyAccessSet(["v2"])
        XCTAssertNil(second)

        await socket.disconnect()
        withExtendedLifetime((s1, s2)) {}
    }

    // MARK: - Helpers

    /// Drain a stream to completion, or give up after `timeout`.
    ///
    /// The bound is not defensive padding — it is what makes the defect FAIL
    /// rather than HANG. Without the prune the continuation is never finished, so
    /// an unbounded `for await` on the pre-fix build blocks the whole suite
    /// forever and reports nothing at all. Verified: with the fix reverted these
    /// tests fail on their assertions; with an unbounded drain they simply never
    /// returned.
    private func drained(
        _ stream: AsyncStream<VehicleTelemetryEvent>,
        timeout: TimeInterval = 2.0
    ) async -> [VehicleTelemetryEvent] {
        await withTaskGroup(of: [VehicleTelemetryEvent]?.self) { group in
            group.addTask {
                var events: [VehicleTelemetryEvent] = []
                for await event in stream { events.append(event) }
                return events
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? []
        }
    }

    /// The first event satisfying `predicate`, or `nil` once `timeout` elapses.
    private func firstEvent(
        in stream: AsyncStream<VehicleTelemetryEvent>,
        timeout: TimeInterval = 2.0,
        matching predicate: @escaping @Sendable (VehicleTelemetryEvent) -> Bool
    ) async -> VehicleTelemetryEvent? {
        await withTaskGroup(of: VehicleTelemetryEvent?.self) { group in
            group.addTask {
                for await event in stream where predicate(event) { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The first published revocation, or `nil` once `timeout` elapses.
    private func firstRevocation(
        in stream: AsyncStream<VehicleAccessRevocation>,
        timeout: TimeInterval = 2.0
    ) async -> VehicleAccessRevocation? {
        await withTaskGroup(of: VehicleAccessRevocation?.self) { group in
            group.addTask {
                for await revocation in stream { return revocation }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func vehicleUpdateFrame(vehicleId: String) -> String {
        #"{"type":"vehicle_update","payload":{"vehicleId":"\#(vehicleId)","fields":{"chargeLevel":61},"timestamp":"2026-08-02T00:00:00Z"}}"#
    }
}
