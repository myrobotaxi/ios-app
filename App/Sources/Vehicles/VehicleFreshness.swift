import Foundation

// MARK: - VehicleFreshness (MYR-315)
//
// Data freshness has two halves, and this file owns the PURE decision layer for
// both so each is unit-testable without a view or a network.
//
//   1. THE STAMP — what the owner is told about how current the sheet is, and
//      whether tapping it should actually ask the server for something newer.
//   2. THE FOREGROUND REFETCH — whether coming back to the app is worth a round
//      trip at all.
//
// The honesty problem this solves: at the PEEK detent the owner sees a battery
// figure, a location and a status badge, and nothing anywhere says WHEN any of it
// was read. MYR-260 established the freshness vocabulary, but only inside the
// controls stack — the per-tile "Synced 2h ago" qualifier and the "Not live"
// footer both live at HALF, below a scroll. A car that has been asleep since
// yesterday therefore presents yesterday's battery as if it were current on the
// very surface the owner looks at first. The stamp closes that gap, and — because
// "how old is this?" is useless without "get me something newer" — it is also the
// affordance that spends a wake (rest-api.md §7.15).
//
// Everything here takes an injected `now` and returns values, never views, so the
// matrix (streaming / fresh / stale / never) is asserted directly. The staleness
// THRESHOLD is deliberately NOT re-declared: it is `VehicleControlFreshness
// .staleThreshold`, so the stamp and the tile qualifiers can never disagree about
// what "stale" means.

/// What the recency stamp says, resolved from the telemetry snapshot's freshness
/// signals. `nil` (see ``VehicleFreshnessStamp/recency(isStreaming:lastUpdated:now:)``)
/// means "no honest claim is available" and the stamp renders nothing at all.
public enum VehicleRecency: Equatable {
    /// The car is online and delivering frames — the sheet IS current.
    case streaming
    /// Not streaming, but we hold a read time: report how old it is, bounded.
    case synced(String)
    /// Not streaming and no read has ever landed — say exactly that rather than
    /// implying a sync happened at some unknown time.
    case never

    /// The stamp's text.
    public var label: String {
        switch self {
        case .streaming: "Live"
        case .synced(let ago): "Synced \(ago)"
        case .never: "Not synced yet"
        }
    }
}

/// The pure resolver behind the stamp.
public enum VehicleFreshnessStamp {
    /// The honest recency claim, or `nil` when none can be made.
    ///
    /// `isStreaming == nil` is the SIMULATED path (`VehicleTelemetrySnapshot`
    /// leaves both freshness signals nil there — MYR-260). It returns `nil`, so
    /// even if a simulated surface ever rendered the stamp it would show nothing
    /// rather than a fabricated "Live". That is belt-and-braces: the stamp is
    /// additionally gated to live mode at the call site (see `HomeScreen`), which
    /// is what keeps the drift-gate scenes byte-identical.
    public static func recency(isStreaming: Bool?, lastUpdated: Date?, now: Date) -> VehicleRecency? {
        switch isStreaming {
        case nil:
            return nil
        case .some(true):
            // A streaming car refreshes its read time every frame, so "Live" is
            // the whole truth — an "X ago" next to it would just be noise.
            return .streaming
        case .some(false):
            guard let lastUpdated else { return .never }
            return .synced(VehicleControlFreshness.agoLabel(since: lastUpdated, now: now))
        }
    }

    /// Whether a tap should actually spend a §7.15 call (and therefore possibly a
    /// wake), or merely acknowledge.
    ///
    /// Two situations need no round trip, and asking anyway would be worse than
    /// useless — it burns part of a finite wake budget and, inside the endpoint's
    /// ~60s cooldown, comes straight back as a `429` the owner would read as a
    /// failure:
    ///   • the car is STREAMING — the data is already as current as it gets;
    ///   • the last read is younger than the shared staleness threshold — the
    ///     server would answer `fresh` (its own no-op) anyway.
    /// A car with NO read at all is always worth asking about: that is precisely
    /// the state a wake exists to resolve.
    public static func wakes(isStreaming: Bool?, lastUpdated: Date?, now: Date) -> Bool {
        guard isStreaming == false else { return false }
        guard let lastUpdated else { return true }
        return VehicleControlFreshness.isStale(lastUpdated: lastUpdated, now: now)
    }
}

// MARK: - Refresh outcome + notices

/// What a §7.15 refresh did, projected off the Kit's response for the app layer.
/// `unsupported` is the SIMULATED fleet: there is no backend to ask, and the
/// simulated snapshot is definitionally current.
public enum VehicleRefreshOutcome: Equatable {
    case unsupported
    /// The server declined to wake because the car streamed recently — a success.
    case fresh
    /// The server woke the car and read it; a fresh snapshot follows on the
    /// normal telemetry pipeline.
    case refreshed
}

/// The honest, non-dramatic line shown in place of the stamp when a refresh
/// couldn't deliver. Copy is REUSED from the MYR-301 notice grammar wherever the
/// situation is the same one — a car that won't wake is the same physical fact
/// whether a lock command or a refresh discovered it, and telling the owner two
/// different things about it would be a fork, not a feature.
public enum VehicleRefreshNotice: Equatable {
    /// 503 `vehicle_asleep` — the wake budget is spent and the car did not come up.
    case asleep
    /// 429 `rate_limited` — the per-vehicle ~60s cooldown. Deliberately NOT the
    /// command `.cooldown` copy ("Just sent — one moment", MYR-320): the two
    /// share a grammar because they are the same back-off, but they name
    /// different acts — a refresh the owner PULLED versus a command they SENT —
    /// and each says which one it was.
    case cooldown
    /// Anything else (auth, ownership, transport). The owner's move is the same
    /// in every case — try again — so they are not split into copy the owner
    /// cannot act on differently.
    case failed

    public var message: String {
        switch self {
        case .asleep: VehicleCommandNotice.asleep.message
        case .cooldown: "Just refreshed \u{2014} one moment"
        case .failed: VehicleCommandNotice.failed.message
        }
    }

    /// Fold a refresh failure onto its notice through the EXISTING typed §7.9
    /// catalog (`RestError.commandFailureKind`) — never by string-matching the
    /// server's human message (FR-7.1).
    public static func resolve(commandFailureKind kind: VehicleRefreshFailureKind) -> VehicleRefreshNotice {
        switch kind {
        case .vehicleAsleep: .asleep
        case .rateLimited: .cooldown
        case .other: .failed
        }
    }
}

/// The narrow slice of the Kit's `RestError.CommandFailureKind` this surface acts
/// on. Declared here (rather than importing the Kit into every caller) so the
/// pure resolver + its tests stay free of transport types; `OwnerHomeState` does
/// the one fold from the typed Kit error.
public enum VehicleRefreshFailureKind: Equatable {
    case vehicleAsleep
    case rateLimited
    case other
}

/// The stamp's transient state while the owner's tap is being served.
public enum VehicleRefreshPhase: Equatable {
    /// Showing the plain recency stamp.
    case idle
    /// A §7.15 call is in flight for the named vehicle — the wake can take
    /// several seconds, and silence during it reads as a dead tap.
    case waking(String)
    /// The tap was a deliberate no-op (already current). Held only long enough to
    /// register as a response; the stamp itself re-renders underneath.
    case acknowledged
    /// The refresh couldn't deliver; shows the honest line until the next tap.
    case notice(VehicleRefreshNotice)

    /// The in-progress copy, naming the actual car ("Waking Lunar…") so an owner
    /// with several vehicles knows which one is being woken.
    public var text: String? {
        switch self {
        case .waking(let name): "Waking \(name)\u{2026}"
        case .notice(let notice): notice.message
        case .idle, .acknowledged: nil
        }
    }
}

// MARK: - Foreground refetch policy

/// Whether returning to the foreground is worth a refetch (MYR-315 deliverable 2).
///
/// The app already nudges the WS on resume (`TelemetrySocket
/// .handleForegroundTransition`), but a nudge only helps when the socket actually
/// dropped. The common case is worse and quieter: iOS suspends the process, the
/// socket is silently dead for the whole background spell, and on return the sheet
/// renders whatever was last in memory until the liveness watchdog notices. So the
/// resume ALSO refetches the fleet list and the selected vehicle's snapshot.
///
/// Debounced, because the resume path is not rare: switching to another app for a
/// glance, pulling down Control Center, or answering a notification all produce a
/// background→active round trip within seconds, and refetching on each would spend
/// two requests to re-learn what the still-live socket already knows.
public enum ForegroundRefetchPolicy {
    /// Below this, the data cannot have meaningfully aged and the socket has had
    /// no real chance to die.
    public static let minimumBackgroundInterval: TimeInterval = 10

    /// `backgroundedFor` is `nil` when no background transition was recorded —
    /// a cold launch (whose initial load is the fleet's own `start()`), or an
    /// `.inactive` blip that never reached `.background`. Neither warrants a
    /// refetch.
    public static func shouldRefetch(backgroundedFor interval: TimeInterval?) -> Bool {
        guard let interval else { return false }
        return interval >= minimumBackgroundInterval
    }
}
