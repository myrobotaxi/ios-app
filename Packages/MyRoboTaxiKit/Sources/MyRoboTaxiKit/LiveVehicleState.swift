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

    /// MYR-432 — this account's access to this vehicle was revoked and the
    /// subscription has been pruned. Latched: access coming back is a NEW
    /// subscription (a new bridge), never this one waking up.
    ///
    /// The last-known ``state`` is deliberately RETAINED, exactly as it is across
    /// a disconnect (NFR-3.12/3.13). Blanking it here would make a surface that
    /// has not yet released flash empty in the instant before it does, and the
    /// release is the caller's decision — the bridge's job is to say the stream is
    /// over and WHY, not to decide what the screen does about it.
    public private(set) var accessRevoked = false

    /// MYR-432 — fired once when ``accessRevoked`` latches.
    ///
    /// The per-vehicle half of the signal, for a consumer holding exactly this
    /// bridge; the ACCOUNT-level question ("what is left, and should the surface
    /// release?") is answered by ``TelemetrySocket/accessRevocations()``, which is
    /// where the app's §7.0 re-read hangs.
    public var onAccessRevoked: (@MainActor () -> Void)?

    /// MYR-351 — when the `/snapshot` GET behind the current ``state``'s
    /// SNAPSHOT-ONLY fields was issued. `nil` until the first snapshot arrives.
    ///
    /// It does NOT advance on a delta: a delta refreshes the streamed fields and
    /// leaves the snapshot-only ones exactly as old as they were, so advancing it
    /// would claim a freshness the carried-forward values do not have — which is
    /// the whole defect this exists to close.
    public private(set) var snapshotReadIssuedAt: Date?

    /// Optional hook fired when a `drive_ended` frame arrives for this vehicle
    /// (FR-9.2). The app's live Drives list wires this to a first-page refresh so
    /// a completed drive appears without re-deriving anything from telemetry.
    /// `@MainActor` because the whole bridge is main-actor isolated.
    public var onDriveEnded: (@MainActor (DriveEndedPayload) -> Void)?

    /// Optional hook fired whenever the accumulated ``state`` changes — i.e. on
    /// every cold snapshot and every folded `vehicle_update` delta (MYR-252). The
    /// app's live command executor wires this to reconcile the owner-actuator
    /// read-back fields the v0.12.0 `VehicleState` now carries (lock, climate,
    /// seats, trunk/charge-port, media) so a control shows the car's REAL state
    /// instead of an honest "—". `@MainActor` because the bridge is main-actor
    /// isolated. Fired AFTER `state` is updated, with the new value.
    ///
    /// The second argument is the instant the `/snapshot` GET that produced this
    /// state's SNAPSHOT-ONLY fields was issued (MYR-351). On a `.snapshot` that is
    /// this read's own stamp. On a folded delta it is the stamp of the snapshot the
    /// delta was folded ONTO — which is exactly right, because
    /// ``VehicleStateMerger/apply(fields:to:)`` opens with `var state = original`
    /// and therefore carries every snapshot-only field forward VERBATIM. The
    /// merger declining to FOLD those fields is not the same as the state not
    /// CARRYING them, and a consumer that could not tell the two apart re-applied a
    /// stale value on every frame.
    public var onStateChanged: (@MainActor (VehicleState, _ snapshotReadIssuedAt: Date) -> Void)?

    /// MYR-449 — may a live `vehicle_update` ESTABLISH the state, rather than only
    /// refresh one a cold snapshot already established?
    ///
    /// **THE ORDERING GUARANTEE WAS DOING A SECOND JOB NOBODY CHOSE FOR IT.**
    /// `apply(.update:)` opened `guard let current = state else { return }`, on
    /// CG-SM-4's perfectly good rule that a snapshot precedes the updates it
    /// baselines. What that `return` also did — silently, for every consumer —
    /// was make the cold REST `/snapshot` a SINGLE POINT OF FAILURE for the whole
    /// live surface: with no snapshot in hand, a healthy socket delivering a
    /// perfectly good frame every few seconds produced *nothing at all*, for the
    /// life of the session, with no error, no log and no state to show for it.
    ///
    /// That is MYR-449. On the RIDER's side the snapshot is genuinely refusable
    /// and genuinely skippable — a `403` latches `snapshotAccessDenied` per
    /// vehicle for good (MYR-432), the MYR-319 ladder is bounded and then stops,
    /// and MYR-440 records a viewer snapshot that "retried silently forever" while
    /// the map sat on "Locating…". Any one of those left the tracking sheet with
    /// no car marker and no motion over a car the server was streaming: the static
    /// route and two pins the external testers reported as "an Apple Maps route".
    ///
    /// **DEFAULTS TO `false`, so the OWNER path is byte-identical by
    /// construction.** The owner's sheet renders IDENTITY off this state (model,
    /// VIN, software, seat capability) and MYR-387's `OwnerHomePresentation` gates
    /// its whole content branch on `hasLiveSnapshotForActiveVehicle`; seeding
    /// there would put a nameless car behind surfaces written to assume a snapshot
    /// stands behind them. The rider's surfaces ask this state exactly one
    /// question — *where is the car right now* — which is the question a delta can
    /// answer on its own. The owner half is a disclosed gap, not a fix withheld:
    /// the owner's equivalent recovery is MYR-387's standalone snapshot fallback.
    private let seedsStateFromDeltas: Bool

    private let socket: TelemetrySocket
    private var eventTask: Task<Void, Never>?
    private var connectionTask: Task<Void, Never>?

    public init(vehicleId: String, socket: TelemetrySocket, seedsStateFromDeltas: Bool = false) {
        self.vehicleId = vehicleId
        self.socket = socket
        self.seedsStateFromDeltas = seedsStateFromDeltas
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

    /// Fold one event into the observable state.
    ///
    /// INTERNAL rather than private (MYR-351) so `@testable` can drive the fold
    /// directly. It stays out of the public API — the ordering rules it enforces
    /// (a snapshot precedes the updates it baselines; a delta inherits the
    /// snapshot's read stamp) are this type's own invariants, not a seam callers
    /// are invited to reach into.
    func apply(_ event: VehicleTelemetryEvent) {
        switch event {
        case .snapshot(let snapshot, let readIssuedAt):
            state = snapshot
            snapshotReadIssuedAt = readIssuedAt
            onStateChanged?(snapshot, readIssuedAt)
        case .update(let payload):
            // MYR-449 — the ordering guarantee (CG-SM-4: a snapshot precedes the
            // updates it baselines) is preserved whenever a snapshot is COMING.
            // What changed is what happens when one never does: a bridge that
            // seeds folds this frame onto `VehicleStateBaseline`, whose every
            // field is the schema's own "nothing reported" value — including the
            // `(0, 0)` no-fix sentinel — so the seed can only ever publish what
            // the car itself sent. `snapshotReadIssuedAt` stays `nil`, which is
            // the public signal that no snapshot stands behind these values.
            guard let current = state ?? seededBaseline() else { return }
            let merged = VehicleStateMerger.apply(fields: payload.fields, to: current).state
            state = merged
            // MYR-351 — the delta's own fields are current, but its SNAPSHOT-ONLY
            // fields are as old as the snapshot it was folded onto. The ordering
            // guarantee above (a snapshot always precedes the updates it baselines)
            // is what makes this non-nil whenever `state` is.
            onStateChanged?(merged, snapshotReadIssuedAt ?? .distantPast)
        case .driveStarted:
            isDriving = true
        case .driveEnded(let summary):
            isDriving = false
            lastDriveSummary = summary
            onDriveEnded?(summary)
        case .connectivity(let payload):
            vehicleOnline = payload.online
        case .dataState(let group, let value):
            dataState[group] = value
        case .accessRevoked:
            // MYR-432 — the socket has already pruned the subscription and is
            // about to finish this stream. Tear the bridge's own tasks down so
            // nothing here outlives it: `stop()` is idempotent and its
            // `unsubscribe` is a no-op against a subscription that is already
            // gone. Latch first so a consumer reading `accessRevoked` from inside
            // the hook sees `true`.
            guard !accessRevoked else { return }
            accessRevoked = true
            stop()
            onAccessRevoked?()
        }
    }

    /// MYR-449 — the fold target for a delta that arrived before any snapshot, or
    /// `nil` on a bridge that does not seed (every owner consumer), which restores
    /// the pre-MYR-449 `return` exactly.
    private func seededBaseline() -> VehicleState? {
        guard seedsStateFromDeltas else { return nil }
        return VehicleStateBaseline.forDeltaSeed(vehicleId: vehicleId)
    }
}
