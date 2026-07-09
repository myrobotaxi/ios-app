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
        locationName: String = "Embarcadero Center · Lot B"
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
        chargeLevel: Int = 82
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
            role: .owner
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

extension BackendEnvironment {
    /// A well-formed but never-dialed environment for fleet tests.
    static let test = BackendEnvironment(
        restBaseURL: URL(string: "https://telemetry.test/api")!,
        webSocketURL: URL(string: "wss://telemetry.test/api/ws")!,
        allowsInsecureLoopback: false
    )
}
