import Foundation
import Observation
import MyRobotaxiContracts

/// Main-actor `@Observable` bridge from the ``TelemetrySocket`` actor's async
/// streams to SwiftUI. This is the shape a future `VehicleTelemetrySource`
/// adapter (MYR-167) wraps: it exposes an accumulated `VehicleState`, the two
/// independent state dimensions (``connectionState`` + per-group ``dataState``),
/// and the drive lifecycle — all as observable properties a view reads directly.
///
/// It folds ``VehicleTelemetryEvent/update`` deltas onto the last
/// ``VehicleTelemetryEvent/snapshot`` with ``VehicleStateMerger`` (which applies
/// the atomic nav-clear amplification, NFR-3.9). `connectionState` and
/// `dataState` are mirrored from the socket, which is their single authority —
/// the two dimensions are never collapsed (FR-8.2).
@MainActor
@Observable
public final class LiveVehicleState {
    public let vehicleId: String

    /// The accumulated snapshot: `nil` until the first snapshot arrives, then
    /// updated in place by each live delta. Retained across disconnects so the
    /// UI keeps showing last-known values (NFR-3.12/3.13).
    public private(set) var state: VehicleState?
    /// Transport health (mirrors the socket).
    public private(set) var connectionState: ConnectionState = .disconnected
    /// Per-atomic-group freshness (mirrors the socket).
    public private(set) var dataState: [AtomicGroup: DataState] = [:]
    /// True while a drive is in progress (DR-1 → DR-3).
    public private(set) var isDriving = false
    /// The most recent completed-drive summary (cleared to `nil` is the caller's
    /// choice once consumed).
    public private(set) var lastDriveSummary: DriveEndedPayload?
    /// Vehicle↔server connectivity, once a `connectivity` frame has arrived.
    public private(set) var vehicleOnline: Bool?

    private let socket: TelemetrySocket
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    public init(vehicleId: String, socket: TelemetrySocket) {
        self.vehicleId = vehicleId
        self.socket = socket
    }

    /// Begin observing this vehicle: mirrors the connection state, subscribes on
    /// the socket, folds its events into observable state, and opens the
    /// connection. Idempotent.
    public func start() {
        guard eventTask == nil else { return }
        let socket = self.socket
        let vehicleId = self.vehicleId

        connectionTask = Task { [weak self] in
            let states = await socket.connectionStates()
            for await state in states {
                guard let self else { break }
                self.connectionState = state
            }
        }
        eventTask = Task { [weak self] in
            let events = await socket.subscribe(to: vehicleId)
            for await event in events {
                guard let self else { break }
                self.apply(event)
            }
        }
        Task { await socket.connect() }
    }

    /// Stop observing: cancel the stream tasks and unsubscribe. Idempotent.
    public func stop() {
        eventTask?.cancel(); eventTask = nil
        connectionTask?.cancel(); connectionTask = nil
        let socket = self.socket
        let vehicleId = self.vehicleId
        Task { await socket.unsubscribe(from: vehicleId) }
    }

    private func apply(_ event: VehicleTelemetryEvent) {
        switch event {
        case .snapshot(let snapshot):
            state = snapshot
        case .update(let payload):
            guard let current = state else { return } // ordering: snapshot precedes updates
            state = VehicleStateMerger.apply(fields: payload.fields, to: current).state
        case .driveStarted:
            isDriving = true
        case .driveEnded(let summary):
            isDriving = false
            lastDriveSummary = summary
        case .connectivity(let payload):
            vehicleOnline = payload.online
        case .dataState(let group, let value):
            dataState[group] = value
        }
    }
}
