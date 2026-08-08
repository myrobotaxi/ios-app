import Foundation
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Contracts fixtures (MYR-201 tests — no network)
//
// Builders for the generated `MyRobotaxiContracts` types, so the mapping tests
// read as "this wire shape → this view model". Deliberately explicit rather than
// loading JSON files: the mapping under test is Swift-value → Swift-value.

enum Contracts {
    /// A driving `VehicleState` down a short 2-point nav route with an ETA and a
    /// distance-remaining that puts the trip ~40% along.
    static func drivingState(
        vehicleId: String = "v1",
        chargeLevel: Int = 68,
        speed: Int = 64,
        etaMinutes: Int? = 42,
        tripDistanceRemaining: Double? = 6.0
    ) -> VehicleState {
        VehicleState(
            vehicleId: vehicleId,
            name: "Cybercab",
            model: "Cybercab",
            year: 2026,
            color: "Mercury Silver",
            status: .driving,
            speed: speed,
            heading: 210,
            latitude: 37.7749,
            longitude: -122.4194,
            locationName: "Home",
            locationAddress: "221 Folsom St, San Francisco",
            gearPosition: .d,
            chargeLevel: chargeLevel,
            chargeState: nil,
            estimatedRange: 240,
            timeToFull: nil,
            interiorTemp: 70,
            exteriorTemp: 61,
            odometerMiles: 42184,
            fsdMilesSinceReset: 128.4,
            destinationName: "Duarte's Tavern",
            destinationAddress: "202 Stage Rd, Pescadero, CA",
            destinationLatitude: 37.2554,
            destinationLongitude: -122.3800,
            originLatitude: 37.7749,
            originLongitude: -122.4194,
            etaMinutes: etaMinutes,
            tripDistanceRemaining: tripDistanceRemaining,
            // GeoJSON [lon, lat] pairs — a 10-mi hop so distance-remaining maps
            // to a meaningful progress fraction.
            navRouteCoordinates: [[-122.4194, 37.7749], [-122.3800, 37.2554]],
            lastUpdated: "2026-07-08T17:30:00Z"
        )
    }

    /// A parked `VehicleState` at a geocoded lot, no navigation.
    static func parkedState(
        vehicleId: String = "v2",
        status: VehicleState.Status = .parked,
        chargeLevel: Int = 82,
        locationName: String = "Embarcadero Center · Lot B",
        licensePlate: String? = nil
    ) -> VehicleState {
        VehicleState(
            vehicleId: vehicleId,
            name: "Daily",
            model: "Model 3 LR",
            year: 2024,
            color: "Pearl White",
            status: status,
            speed: 0,
            heading: 0,
            latitude: 37.7955,
            longitude: -122.3937,
            locationName: locationName,
            locationAddress: "1 Embarcadero Ctr, San Francisco",
            gearPosition: .p,
            chargeLevel: chargeLevel,
            chargeState: status == .charging ? .charging : nil,
            estimatedRange: 210,
            timeToFull: status == .charging ? 1.5 : nil,
            interiorTemp: 68,
            exteriorTemp: 60,
            odometerMiles: 20481,
            fsdMilesSinceReset: 12.0,
            destinationName: nil,
            destinationAddress: nil,
            destinationLatitude: nil,
            destinationLongitude: nil,
            originLatitude: nil,
            originLongitude: nil,
            etaMinutes: nil,
            tripDistanceRemaining: nil,
            navRouteCoordinates: nil,
            // MYR-286 — snapshot-only by contract (no WS delta ever carries it).
            // `nil` by default so every pre-existing test keeps the absent-key
            // shape and its `VIN ····xxxx` expectations.
            licensePlate: licensePlate,
            lastUpdated: "2026-07-08T15:48:00Z"
        )
    }

    static func summary(
        vehicleId: String = "v2",
        name: String = "Daily",
        model: String = "Model 3 LR",
        year: Int = 2024,
        color: String = "Pearl White",
        vinLast4: String = "9417",
        status: VehicleSummary.Status = .parked,
        chargeLevel: Int = 82,
        licensePlate: String? = nil,
        // MYR-455 — the §7.0 list carries BOTH partitions and `role` is the only
        // discriminator. Defaulted to `.owner` so every pre-MYR-455 caller is
        // byte-identical; a viewer row is now expressible, which it was not
        // before, and that absence is part of why the owner fleet went two years
        // adopting shares as if they were the account's own cars.
        role: VehicleSummary.Role = .owner,
        sharePermission: SharePermission? = nil
    ) -> VehicleSummary {
        VehicleSummary(
            vehicleId: vehicleId,
            name: name,
            model: model,
            year: year,
            color: color,
            vinLast4: vinLast4,
            status: status,
            chargeLevel: chargeLevel,
            estimatedRange: 210,
            lastUpdated: "2026-07-08T15:48:00Z",
            role: role,
            licensePlate: licensePlate,
            sharePermission: sharePermission
        )
    }

    static func listResponse(_ items: [VehicleSummary]) -> Data {
        // swiftlint:disable:next force_try
        try! JSONEncoder().encode(VehicleListResponse(items: items))
    }

    static func errorEnvelope(code: String = "auth_failed", message: String = "unauthorized") -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }
}

// MARK: - Test doubles

/// Deterministic `HTTPPerforming` returning one fixed response. No network.
struct StubHTTP: HTTPPerforming {
    let status: Int
    let body: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// MYR-286 — a scripted `VehiclePlateEndpoint` for the §7.14 plate write. Records
/// every submitted value (so "the RAW input is sent, not a client-normalized one"
/// is assertable) and either echoes a scripted NORMALIZED value or throws. Same
/// lock-guarded `@unchecked Sendable` shape as `ScriptedCommandSender`.
final class ScriptedPlateEndpoint: VehiclePlateEndpoint, @unchecked Sendable {
    private let lock = NSLock()
    /// The value the server echoes back — deliberately DIFFERENT from what the
    /// caller submits in the round-trip tests, so adopting the echo (rather than
    /// the raw input) is provable.
    private var echo: String
    private var failure: RestError?
    private var _submitted: [String] = []

    init(normalizedEcho: String = "", failure: RestError? = nil) {
        self.echo = normalizedEcho
        self.failure = failure
    }

    func setLicensePlate(_ plate: String, vehicleID: String) async throws -> VehiclePlateResponse {
        lock.lock()
        _submitted.append(plate)
        let failure = self.failure
        let echo = self.echo
        lock.unlock()
        if let failure { throw failure }
        return VehiclePlateResponse(vehicleId: vehicleID, licensePlate: echo)
    }

    /// Every value handed to the endpoint, in order.
    var submitted: [String] {
        lock.lock(); defer { lock.unlock() }
        return _submitted
    }

    var callCount: Int { submitted.count }
}

/// A WS channel that never completes its handshake and never emits frames — it
/// just parks `receive()` until closed. Keeps the fleet's socket from making any
/// real network dial in tests; the read-path under test is REST + mapping.
actor ParkedWebSocketChannel: WebSocketChannel {
    struct Closed: Error {}
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false

    func send(_ text: String) async throws {}
    func ping() async throws {}

    func receive() async throws -> String {
        if closed { throw Closed() }
        return try await withCheckedThrowingContinuation { self.waiter = $0 }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        if let waiter { self.waiter = nil; waiter.resume(throwing: Closed()) }
    }
}

final class ParkedChannelFactory: WebSocketChannelFactory, @unchecked Sendable {
    func makeChannel(url: URL) -> any WebSocketChannel { ParkedWebSocketChannel() }
}

/// MYR-319 — a WS channel that completes the handshake (`auth_ok` the moment the
/// socket sends its `auth` frame) and then **emits nothing at all**.
///
/// That is not a degenerate case: it is EXACTLY a car that is offline or in
/// service. Telemetry only streams while a car is awake, so for such a vehicle
/// the socket is healthy, the subscription is live, and the only data that will
/// ever arrive is the cold REST `/snapshot` the socket fetches on connect.
/// `ParkedWebSocketChannel` (which never authenticates) can never reach that
/// path — its socket stays `.connecting` forever — so no App-target test before
/// this one exercised the snapshot-only read at fleet level.
actor AuthenticatingWebSocketChannel: WebSocketChannel {
    struct Closed: Error {}

    private var inbound: [String] = []
    private var waiter: CheckedContinuation<String, any Error>?
    private var closed = false
    private var sent: [String] = []
    /// MYR-432 — the close code this channel reports once it has closed. `nil` for
    /// every pre-MYR-432 use, i.e. an ordinary transport drop.
    private var reportedCloseCode: Int?

    func send(_ text: String) async throws {
        if closed { throw Closed() }
        sent.append(text)
        // `WireCodec` is Kit-internal, so match the wire text (§2.2: the auth
        // frame is always the first frame after the upgrade).
        if text.contains(#""type":"auth""#) {
            enqueue(Self.authOKFrame)
        }
    }

    func receive() async throws -> String {
        if closed { throw Closed() }
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { self.waiter = $0 }
    }

    func ping() async throws { if closed { throw Closed() } }

    func close() async {
        guard !closed else { return }
        closed = true
        if let waiter { self.waiter = nil; waiter.resume(throwing: Closed()) }
    }

    func sentFrames() -> [String] { sent }

    /// MYR-449 — push a SERVER frame down this channel.
    ///
    /// Every use of this channel before now was "the socket is healthy and the car
    /// says nothing" (MYR-319's asleep car). MYR-449's question is the opposite one
    /// and could not be asked without this: *the car is streaming and the server IS
    /// delivering viewer frames — does the rider's surface render them?* Prod
    /// answered the first half for the external-beta rides (viewer-role
    /// `mask_applied` inside every ride window); this is how the second half is
    /// driven without a backend.
    func emit(_ text: String) async {
        guard !closed else { return }
        enqueue(text)
    }

    /// A `vehicle_update` carrying the VIEWER-shaped field set — position, heading,
    /// speed, status, `lastUpdated`. Deliberately NOT a full state: MYR-435 narrows
    /// the shared-viewer mask to exactly this kind of frame, so a fixture carrying
    /// owner fields would prove something no rider is ever sent.
    static func viewerGPSFrame(
        vehicleId: String,
        latitude: Double,
        longitude: Double,
        speed: Int = 27,
        heading: Int = 212,
        status: String = "driving",
        lastUpdated: String = "2026-08-06T00:11:44Z"
    ) -> String {
        """
        {"type":"vehicle_update","payload":{"vehicleId":"\(vehicleId)","fields":{\
        "latitude":\(latitude),"longitude":\(longitude),"heading":\(heading),\
        "speed":\(speed),"status":"\(status)","lastUpdated":"\(lastUpdated)"},\
        "timestamp":"\(lastUpdated)"}}
        """
    }

    func closeCode() -> Int? { reportedCloseCode }

    /// MYR-432 — close the way a SERVER does, with a code. The code is set BEFORE
    /// the close so the socket's read of it (which happens the instant `receive()`
    /// fails) can never race the assignment.
    func closeWith(code: Int) async {
        reportedCloseCode = code
        await close()
    }

    private func enqueue(_ text: String) {
        if let waiter { self.waiter = nil; waiter.resume(returning: text) }
        else { inbound.append(text) }
    }

    static let authOKFrame =
        #"{"type":"auth_ok","payload":{"userId":"u1","vehicleCount":1,"issuedAt":"2026-07-26T00:00:00Z"}}"#
}

final class AuthenticatingChannelFactory: WebSocketChannelFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [AuthenticatingWebSocketChannel] = []

    func makeChannel(url: URL) -> any WebSocketChannel {
        let channel = AuthenticatingWebSocketChannel()
        lock.lock(); channels.append(channel); lock.unlock()
        return channel
    }

    /// MYR-432 — every channel handed out so far, newest last. A test needs the
    /// LIVE one to close it with a code, and needs the COUNT to assert that the
    /// access close bought exactly one re-handshake.
    func madeChannels() -> [AuthenticatingWebSocketChannel] {
        lock.lock(); defer { lock.unlock() }
        return channels
    }
}

/// MYR-319 — an `HTTPPerforming` that answers by PATH rather than by call order.
/// The live read path interleaves `GET /api/vehicles` with the socket's
/// `GET /api/vehicles/{id}/snapshot`, and their order is a race between the REST
/// load task and the WS handshake — a sequenced stub would make the test's
/// outcome depend on which won.
actor RoutedHTTP: HTTPPerforming {
    /// `(path suffix, status, body)`, matched by `hasSuffix` in declaration order.
    /// `failFirst` scripts the first N calls to that route as `status` +
    /// `failureBody` before it starts answering with `body` — the shape of a
    /// backend that can't reach a SLEEPING car on the first ask.
    struct Route: Sendable {
        var suffix: String
        var status: Int
        var body: Data
        var failFirst: Int
        var failureBody: Data

        init(
            _ suffix: String,
            failFirst: Int = 0,
            status: Int = 200,
            failureBody: Data = Data(),
            body: Data
        ) {
            self.suffix = suffix
            self.status = status
            self.body = body
            self.failFirst = failFirst
            self.failureBody = failureBody
        }
    }

    private var routes: [Route]
    private var requests: [URLRequest] = []
    private var served: [String: Int] = [:]

    init(_ routes: [Route]) { self.routes = routes }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let path = request.url?.path ?? ""
        guard let index = routes.firstIndex(where: { path.hasSuffix($0.suffix) }) else {
            let body = Data(#"{"error":{"code":"not_found","message":"\#(path)"}}"#.utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        let route = routes[index]
        let count = (served[route.suffix] ?? 0) + 1
        served[route.suffix] = count
        let failing = count <= route.failFirst
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: failing ? route.status : 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (failing ? route.failureBody : route.body, response)
    }

    /// MYR-402 — REPLACE what a route answers, mid-test.
    ///
    /// Every stub before this one was a fixed script, which is the right shape for
    /// "what does the client make of this payload". MYR-402's question is the other
    /// one: *does the client ever ASK AGAIN?* — and a stub that cannot change its
    /// answer makes a re-read indistinguishable from a cached value, so a test built
    /// on one would pass on the broken build. The wire changing under a client that
    /// did not notice IS the defect.
    func setBody(suffix: String, body: Data) {
        guard let index = routes.firstIndex(where: { $0.suffix == suffix }) else { return }
        routes[index].body = body
    }

    func paths() -> [String] { requests.compactMap { $0.url?.path } }
    /// MYR-381 — the whole requests, for the tests that assert the BYTES (method +
    /// path + the id inside it) rather than only which routes were touched. A path
    /// list cannot tell a `POST …/cancel` from a `GET` of the same URL, and that
    /// distinction is exactly what the r14 cancel defect turned on.
    func capturedRequests() -> [URLRequest] { requests }
    /// How many times a route has been asked — "did the client try again?".
    func callCount(suffix: String) -> Int { served[suffix] ?? 0 }
}

/// MYR-315 — a movable clock, so the foreground-refetch debounce is provable
/// without the test actually sleeping through it.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.current = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// Deterministic `HTTPPerforming` that replays a scripted response SEQUENCE.
/// (App-target twin of the Kit test's `RecordingHTTP`; the App tests can't see the
/// Kit test target's doubles.)
///
/// MYR-315 moved it here from `DriveContractMappingTests` and grew it two things
/// the resume tests need: a per-stub STATUS (so a 503 can be scripted) and a
/// request RECORDER (so "did the resume actually refetch?" is answerable —
/// `StubHTTP` answers every request identically, which cannot distinguish
/// "refetched" from "never asked"). Once the script runs out the LAST stub
/// repeats, so a test only scripts the responses it cares about.
actor SequencedHTTP: HTTPPerforming {
    struct Stub: Sendable {
        var status: Int
        var body: Data
        init(status: Int = 200, body: Data) { self.status = status; self.body = body }
    }

    private var stubs: [Stub]
    private var requests: [URLRequest] = []

    init(_ stubs: [Stub]) { self.stubs = stubs }

    /// Bodies-only convenience for the pagination tests, which script a sequence
    /// of 200s and don't inspect the requests.
    init(_ bodies: [Data]) { self.stubs = bodies.map { Stub(body: $0) } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let stub = stubs.count > 1 ? stubs.removeFirst() : (stubs.first ?? Stub(status: 500, body: Data()))
        let response = HTTPURLResponse(url: request.url!, statusCode: stub.status, httpVersion: nil, headerFields: nil)!
        return (stub.body, response)
    }

    func capturedRequests() -> [URLRequest] { requests }
    func requestCount() -> Int { requests.count }
    /// Paths in order, the readable form for "what did this resume actually do".
    func paths() -> [String] { requests.compactMap { $0.url?.path } }
}

extension BackendEnvironment {
    /// A well-formed but never-dialed environment for fleet tests.
    static let test = BackendEnvironment(
        restBaseURL: URL(string: "https://telemetry.test/api")!,
        webSocketURL: URL(string: "wss://telemetry.test/api/ws")!,
        allowsInsecureLoopback: false
    )
}
