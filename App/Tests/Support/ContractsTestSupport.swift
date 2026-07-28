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
        licensePlate: String? = nil
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
            role: .owner,
            licensePlate: licensePlate
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
