import Foundation
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
    ///
    /// `readIssuedAt` is the instant the `/snapshot` GET was **ISSUED**, not the
    /// instant its response landed here (MYR-351). Consumers that hold a value
    /// they committed themselves — the three snapshot-only fields have no WS
    /// delta, so a write echo is the only way they can be current — need to know
    /// whether this read SAW that write, and only the issue instant answers that.
    /// A GET issued before a write and served before it lands is the newest thing
    /// to ARRIVE and the oldest information in the system; an arrival stamp calls
    /// it fresh and is wrong. The straddle is routine rather than rare: the cold
    /// read retries on a 0/0.8/3/9s ladder and the app refetches on every
    /// foreground.
    case snapshot(VehicleState, readIssuedAt: Date)
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
    /// MYR-432 — this account no longer has access to this vehicle, and the
    /// subscription has been PRUNED. The **last** event on the stream: the
    /// continuation finishes immediately after it.
    ///
    /// Distinct from a stream that simply ends (which is what an ordinary
    /// ``TelemetrySocket/unsubscribe(from:)`` produces, i.e. *we* stopped
    /// watching). This one says the SERVER stopped letting us, which is the
    /// difference between "nothing more is coming" and "nothing more is coming
    /// and the surface must stand down". A consumer that could not tell them
    /// apart would keep a revoked car on screen with a dead stream behind it.
    ///
    /// It carries no payload on purpose: the vehicle is the stream's own
    /// identity, and the ACCOUNT-level question (what is left) is answered by
    /// ``TelemetrySocket/accessRevocations()``, whose consumer is the surface
    /// rather than the per-vehicle bridge.
    case accessRevoked
}
