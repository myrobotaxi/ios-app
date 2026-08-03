import Foundation
import XCTest
@testable import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Fixtures

/// Loads canonical fixtures copied verbatim from the telemetry repo
/// (`docs/contracts/fixtures/`) into the test bundle under `Fixtures/`.
enum Fixture {
    static func url(_ relativePath: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    static func text(_ relativePath: String) throws -> String {
        String(decoding: try data(relativePath), as: UTF8.self)
    }
}

// MARK: - Token provider

/// Counts `token()` calls and can hand out a sequence of tokens (so the 401
/// refresh path can be observed handing back a fresh value).
actor CountingTokenProvider: TokenProvider {
    private var queue: [String]
    private var count = 0

    init(_ tokens: [String]) { self.queue = tokens }

    func token() async throws -> String {
        count += 1
        if queue.count > 1 { return queue.removeFirst() }
        return queue.first ?? ""
    }

    func callCount() -> Int { count }
}

// MARK: - Refresh-token store (fake Keychain)

/// In-memory ``RefreshTokenStore`` for the session state-machine tests — no
/// Keychain. Thread-safe via a lock so it stays `Sendable` across the actor.
final class InMemoryRefreshTokenStore: RefreshTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    /// Count of writes, so tests can assert rotation actually persisted.
    private(set) var writeCount = 0

    init(seed: String? = nil) { self.stored = seed }

    func read() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }

    func write(_ token: String) throws {
        lock.lock(); defer { lock.unlock() }
        stored = token
        writeCount += 1
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        stored = nil
    }
}

// MARK: - Authentication endpoint (scripted)

/// Scripted ``AuthenticationEndpoint`` for the session tests. Each method
/// replays a queued result and records how many times it was called (so the
/// single-use-rotation coalescing can be asserted: exactly one refresh network
/// call for N concurrent `token()` callers).
actor MockAuthEndpoint: AuthenticationEndpoint {
    enum Result {
        case success(AuthTokenResponse)
        case failure(RestError)
    }

    private var appleResults: [Result]
    private var refreshResults: [Result]
    private(set) var appleCallCount = 0
    private(set) var refreshCallCount = 0
    private(set) var revokeCallCount = 0
    /// When set, `refreshSession` suspends on this before returning, so a test
    /// can hold multiple callers inside one in-flight refresh.
    private var refreshGate: (@Sendable () async -> Void)?

    init(apple: [Result] = [], refresh: [Result] = []) {
        self.appleResults = apple
        self.refreshResults = refresh
    }

    func setRefreshGate(_ gate: @escaping @Sendable () async -> Void) { refreshGate = gate }

    func signInWithApple(_ body: AppleSignInRequest) async throws -> AuthTokenResponse {
        appleCallCount += 1
        return try unwrap(appleResults.isEmpty ? nil : appleResults.removeFirst())
    }

    func refreshSession(_ body: RefreshTokenRequest) async throws -> AuthTokenResponse {
        refreshCallCount += 1
        let result = refreshResults.isEmpty ? nil : refreshResults.removeFirst()
        if let refreshGate { await refreshGate() }
        return try unwrap(result)
    }

    func revokeSession(_ body: RefreshTokenRequest) async throws {
        revokeCallCount += 1
    }

    func counts() -> (apple: Int, refresh: Int, revoke: Int) {
        (appleCallCount, refreshCallCount, revokeCallCount)
    }

    private func unwrap(_ result: Result?) throws -> AuthTokenResponse {
        switch result {
        case .success(let response): return response
        case .failure(let error): throw error
        case .none: throw RestError.invalidResponse
        }
    }
}

/// A movable clock for the proactive-refresh tests.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { self.current = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current += interval
    }
}

// MARK: - HTTP transport

/// Deterministic `HTTPPerforming` — replays a scripted response sequence and
/// records every outbound request. No network.
actor RecordingHTTP: HTTPPerforming {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        init(status: Int, body: Data) { self.status = status; self.body = body }
    }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let stub = stubs.isEmpty ? Stub(status: 500, body: Data()) : stubs.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        return (stub.body, response)
    }

    func capturedRequests() -> [URLRequest] { requests }
}

// MARK: - Snapshot source

/// Stub `SnapshotFetching` — returns a fixed `VehicleState` and counts calls so
/// the reconnect re-fetch can be asserted.
actor StubSnapshotSource: SnapshotFetching {
    private let state: VehicleState
    private var count = 0

    init(state: VehicleState) { self.state = state }

    func snapshot(vehicleId: String) async throws -> VehicleState {
        count += 1
        return state
    }

    func callCount() -> Int { count }
}

/// MYR-432 — a `SnapshotFetching` scripted PER VEHICLE, so one car's `403` can be
/// observed alongside another car's healthy read on the same socket.
///
/// Counting per vehicle is the whole point: "the retry stopped" and "the retry
/// stopped for the RIGHT car" are different claims, and a single global counter
/// cannot tell them apart.
actor PerVehicleSnapshotSource: SnapshotFetching {
    private let state: VehicleState
    /// Vehicle ids whose read is refused, and with what status.
    private var refusals: [String: Int]
    private var counts: [String: Int] = [:]

    init(state: VehicleState, refusals: [String: Int] = [:]) {
        self.state = state
        self.refusals = refusals
    }

    func snapshot(vehicleId: String) async throws -> VehicleState {
        counts[vehicleId, default: 0] += 1
        if let status = refusals[vehicleId] {
            throw RestError.http(status: status, code: nil, message: nil, subCode: nil)
        }
        var scoped = state
        scoped.vehicleId = vehicleId
        return scoped
    }

    func callCount(_ vehicleId: String) -> Int { counts[vehicleId] ?? 0 }
    func totalCallCount() -> Int { counts.values.reduce(0, +) }
    /// Lift a refusal mid-test — access coming back.
    func allow(_ vehicleId: String) { refusals.removeValue(forKey: vehicleId) }
}

// MARK: - Access listing (MYR-432)

/// MYR-432 — a scripted ``VehicleAccessListing``. Hands out a set that a test can
/// change between handshakes (the whole point: the post-4002 handshake must see a
/// REDUCED set) and counts how often the socket asked.
actor StubAccessListing: VehicleAccessListing {
    private var ids: Set<String>
    private var failure: (any Error)?
    private var count = 0

    init(_ ids: Set<String>, failure: (any Error)? = nil) {
        self.ids = ids
        self.failure = failure
    }

    func accessibleVehicleIDs() async throws -> Set<String> {
        count += 1
        if let failure { throw failure }
        return ids
    }

    func setIDs(_ next: Set<String>) { ids = next }
    func callCount() -> Int { count }
}

// MARK: - WebSocket channel

/// Scripted `WebSocketChannel`. Auto-emits an `auth_ok` frame the moment the
/// socket sends its `auth` frame (mimicking a healthy server handshake), records
/// every sent frame, and lets a test push frames or close the socket.
actor MockWebSocketChannel: WebSocketChannel {
    struct Closed: Error {}

    let label: Int
    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false
    private var sent: [String] = []
    /// MYR-432 — the close code this channel reports once it has closed. `nil` is
    /// the ordinary transport drop every pre-MYR-432 test produces, which is what
    /// keeps their behaviour byte-identical.
    private var reportedCloseCode: Int?

    init(label: Int) { self.label = label }

    func send(_ text: String) async throws {
        if closed { throw Closed() }
        sent.append(text)
        if let envelope = try? WireCodec.decodeEnvelope(text), envelope.type == .auth {
            enqueue(Self.authOKFrame)
        }
    }

    func receive() async throws -> String {
        if closed { throw Closed() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            self.waiter = continuation
        }
    }

    func ping() async throws {
        if closed { throw Closed() }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let waiter { self.waiter = nil; waiter.resume(throwing: Closed()) }
    }

    func closeCode() -> Int? { reportedCloseCode }

    // Test hooks
    func push(_ text: String) { enqueue(text) }
    func sentFrames() -> [String] { sent }
    /// MYR-432 — close the way a SERVER does, with a code. Set before the close so
    /// the socket's read of `closeCode()` (which happens the instant `receive()`
    /// fails) can never race it.
    func closeWith(code: Int) {
        reportedCloseCode = code
        close()
    }

    private func enqueue(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { inbound.append(text) }
    }

    static let authOKFrame = #"{"type":"auth_ok","payload":{"userId":"u1","vehicleCount":1,"issuedAt":"2026-07-08T00:00:00Z"}}"#
}

/// Hands the socket a fixed sequence of `MockWebSocketChannel`s (one per
/// connection attempt) so a test can inspect each attempt independently.
final class MockChannelFactory: WebSocketChannelFactory, @unchecked Sendable {
    private let channels: [MockWebSocketChannel]
    private let lock = NSLock()
    private var index = 0

    init(_ channels: [MockWebSocketChannel]) { self.channels = channels }

    func makeChannel(url: URL) -> any WebSocketChannel {
        lock.lock(); defer { lock.unlock() }
        let channel = channels[min(index, channels.count - 1)]
        index += 1
        return channel
    }

    func madeCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return index
    }
}

// MARK: - Connection-state recorder

/// Records the sequence of `ConnectionState` values the socket emits.
actor ConnectionRecorder {
    private var states: [ConnectionState] = []
    func append(_ state: ConnectionState) { states.append(state) }
    func snapshot() -> [ConnectionState] { states }
    func contains(_ state: ConnectionState) -> Bool { states.contains(state) }
    func count(_ state: ConnectionState) -> Int { states.filter { $0 == state }.count }
}

// MARK: - Async polling helper

extension XCTestCase {
    /// Polls `condition` until it is true or the timeout elapses, without a fixed
    /// sleep. Keeps the reconnect tests deterministic and fast.
    func eventually(
        timeout: TimeInterval = 2.0,
        _ message: @autoclosure () -> String = "condition never became true",
        _ condition: () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000) // 2ms
        }
        XCTFail(message(), file: file, line: line)
    }
}
