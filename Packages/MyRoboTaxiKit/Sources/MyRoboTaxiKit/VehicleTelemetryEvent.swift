import MyRobotaxiContracts

/// One event on a single vehicle's telemetry stream.
///
/// Ordering guarantee (Rule CG-SM-4 / NFR-3.11): a ``snapshot`` — the REST
/// cold-load / reconnect baseline — always precedes the live ``update`` frames
/// it baselines. Live frames that arrive mid-snapshot-fetch are buffered by the
/// socket and delivered afterwards.
///
/// Drive lifecycle events are pass-through from the server; the Kit never
/// synthesizes them from telemetry (Rule CG-SM-6).
public enum VehicleTelemetryEvent: Sendable {
    /// REST snapshot baseline for this vehicle. Emitted on first subscribe and
    /// again after every reconnect, before any live ``update``.
    case snapshot(VehicleState)
    /// A live field delta (the raw `vehicle_update.payload`). `fields` carries
    /// members of at most one atomic group plus ungrouped fields (§3.2). Fold it
    /// onto the last ``snapshot`` with ``VehicleStateMerger`` — which also
    /// applies the atomic nav-clear amplification (NFR-3.9).
    case update(VehicleUpdatePayload)
    /// Drive started (state-machine.md §3, DR-1/DR-6).
    case driveStarted(DriveStartedPayload)
    /// Drive ended with summary stats (DR-3). The full record is fetched on
    /// demand via REST; this payload is a lightweight summary.
    case driveEnded(DriveEndedPayload)
    /// Vehicle↔server mTLS connectivity — distinct from the client↔server
    /// WebSocket, which is reflected by ``ConnectionState``.
    case connectivity(ConnectivityPayload)
    /// A per-group freshness transition for this vehicle (state-machine.md §2).
    /// The socket is the single authority for these transitions; a view model
    /// mirrors them rather than re-deriving.
    case dataState(group: AtomicGroup, state: DataState)
}
