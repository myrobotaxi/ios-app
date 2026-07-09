/// Transport health of the telemetry WebSocket, as consumed by the UI.
///
/// This is one of the **two independent** state dimensions the SDK exposes; the
/// other is ``DataState`` per atomic group. The UI composes them and the Kit
/// never collapses them into a single enum (FR-8.1 / FR-8.2, Rule CG-SM-2).
///
/// Mapped from the five-state `connectionState` machine in state-machine.md §1:
/// the doc's `initializing` and its terminal `error` / user-stopped states both
/// surface here as ``disconnected`` (with ``TelemetrySocket/lastError`` carrying
/// the typed reason), while the doc's `disconnected`-with-reconnect-scheduled
/// and every retry attempt surface as ``reconnecting``. These four cases are
/// exactly the surface MYR-21 specified.
public enum ConnectionState: Sendable, Equatable {
    /// No connection and none scheduled: initial state, or a terminal stop
    /// (user disconnect, or a non-retryable auth failure).
    case disconnected
    /// The first connection attempt is in flight (open + auth handshake).
    case connecting
    /// Open, authenticated (`auth_ok` received, C-3), live telemetry flowing.
    case connected
    /// A prior connection dropped; a jittered-backoff reconnect is scheduled or
    /// in flight. Cached data remains visible (NFR-3.12/3.13).
    case reconnecting
}
