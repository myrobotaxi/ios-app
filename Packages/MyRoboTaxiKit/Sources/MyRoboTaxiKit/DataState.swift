/// The four atomic field groups whose freshness is tracked **independently**
/// per vehicle (state-machine.md §2, vehicle-state-schema.md §2). A single
/// `vehicle_update` frame carries members of at most one of these plus ungrouped
/// fields (websocket-protocol.md §3.2).
public enum AtomicGroup: String, Sendable, CaseIterable {
    case gps
    case gear
    case charge
    case navigation
}

/// Per-group data freshness (state-machine.md §2.1). Independent of
/// ``ConnectionState`` — the UI composes the two (FR-8.2); the Kit never
/// collapses them into one enum (Rule CG-SM-2).
///
/// Freshness is **event-driven, never timer-based** (NFR-3.7 / Rule CG-SM-1):
/// the only triggers for ``ready`` → ``stale`` are a WebSocket disconnect
/// (NFR-3.8b) and a server-initiated clear (which lands as ``cleared``, not
/// ``stale``).
public enum DataState: Sendable, Equatable {
    /// Snapshot being fetched (cold load or reconnect). Cached values, if any,
    /// remain visible during a reconnect load.
    case loading
    /// Fresh — snapshot applied or a live update merged.
    case ready
    /// WebSocket disconnected; cached values remain visible indefinitely
    /// (NFR-3.12/3.13, Rule CG-SM-5).
    case stale
    /// Server explicitly nulled this group's fields (e.g. navigation cancelled).
    /// The whole group goes null atomically (NFR-3.9, Rule CG-SM-3).
    case cleared
    /// Snapshot fetch failed or data failed validation for this group; other
    /// groups are unaffected.
    case error
}
