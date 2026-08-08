import Foundation
import Observation

// MARK: - Telemetry seam (MYR-167 deliverable 1)
//
// `VehicleTelemetrySource` is the M1↔M2 seam: this issue ships
// `SimulatedVehicleTelemetrySource` (a local ticker over fixture data, no
// network — CLAUDE.md "M1 is simulated"). MYR-21's `MyRoboTaxiKit` WS client
// (M2) swaps in a source that decodes `MyRobotaxiContracts.VehicleState`
// frames into the same `VehicleTelemetrySnapshot` shape and drives the
// identical `snapshot` property — `HomeScreen` and `HomeSheetContent` never
// change. Conforming types must be `@Observable` classes (Swift's
// `Observation` tracks field access on the concrete object even when called
// through the protocol's witness table, so `any VehicleTelemetrySource` is
// safe to read from a SwiftUI body).

public enum VehicleTelemetryStatus: String, Sendable, Equatable {
    case driving
    case parked
}

/// MYR-333 — the car's LIVE charge session, folded down to the three answers the
/// UI actually renders differently.
///
/// The wire enum (`VehicleState.chargeState`, contracted since MYR-11, sourced
/// from Tesla proto 179 since MYR-42) has seven members plus an open
/// `.unrecognized` arm plus `null`. All of that collapses here, in ONE place
/// (`VehicleContractMapping.chargingState(from:)`), so no screen ever has to
/// know the wire vocabulary and a future Tesla enum value cannot invent a new
/// look by accident.
///
/// Why this is SEPARATE from `status`: the wire `status` enum is single-valued,
/// and `in_service` outranks `charging` in the server's own derivation
/// (`deriveVehicleStatus`). A car being charged AT a service centre is therefore
/// `in_service` on the wire and the charge session is invisible in `status` —
/// which is exactly the client's report: "Service center was charging my car but
/// I couldn't see it was charging." `chargeState` is the field that stays true
/// through that, so the charging treatment reads from it, never from `status`.
public enum VehicleChargingState: String, Sendable, Equatable {
    /// Wire `Charging` — a live session. Pulsing green bar + "Charging".
    case charging
    /// Wire `Complete` — the session finished at the limit. Static green +
    /// "Charge complete". Honest: it is NOT still charging, so it does not pulse.
    case complete
    /// Everything else — wire `Disconnected`, `Stopped`, `NoPower`, `Starting`,
    /// `Unknown`, a forward-compat `.unrecognized` value, and `null` (a car that
    /// has never charged). Renders exactly as the app did before MYR-333.
    ///
    /// `Starting` sits here deliberately: it is the pre-session handshake, and a
    /// handshake that has not become a session yet must not claim "Charging".
    /// It is transient by nature, so nothing rests in this state for long.
    case idle
}

/// Everything a `HomeSheetContent` hero needs to render one tick
/// (screens.jsx `HomeScreen` props `driving, progress, battery, speed` +
/// the `eta` it derives at line 373).
public struct VehicleTelemetrySnapshot: Sendable, Equatable {
    public var status: VehicleTelemetryStatus
    /// 0...1 along the vehicle's `DrivingTrip.route`. Always 0 when parked.
    public var progress: Double
    /// screens.jsx:472 `speed` — 0 when parked.
    public var speedMPH: Int
    /// screens.jsx battery tweak (0...100).
    public var batteryPercent: Double
    /// screens.jsx:373 `eta = Math.max(1, Math.round((1 - progress) * 87))`
    /// — minutes remaining. 0 when parked.
    public var etaMinutes: Int
    /// Cabin interior temperature in °F (vehicle-controls.jsx Interior/Exterior
    /// row). Real `VehicleState.interiorTemp` on the live path; the fixture 66 on
    /// the simulated path. `nil` = unknown (no live snapshot yet) → the controls
    /// render "—" rather than a fixture value (MYR-228 / MYR-251).
    public var interiorTempF: Int?
    /// Ambient exterior temperature in °F. Real `VehicleState.exteriorTemp` live;
    /// the fixture 58 simulated; `nil` = unknown.
    public var exteriorTempF: Int?
    /// Lifetime odometer in whole miles (vehicle-controls Lifetime section). Real
    /// `VehicleState.odometerMiles` on the live path; the fixture 42,184 simulated;
    /// `nil` = not yet streamed → the Lifetime rows render "— Syncing" rather than
    /// a fixture number (MYR-228 / MYR-255).
    public var odometerMiles: Int?
    /// FSD miles since last reset (`VehicleState.fsdMilesSinceReset`). Real live;
    /// the fixture 31,907 simulated; `nil` = not yet streamed. "Driven
    /// autonomously %" is derived from this over `odometerMiles` — no separate
    /// wire field, so it too is honest-unknown until both stream in.
    public var fsdMilesSinceReset: Double?
    /// MYR-260 — the snapshot's server read time (`VehicleState.lastUpdated`).
    /// Used to (a) tell a genuinely-connecting state (no snapshot yet → `nil`)
    /// from a reachable one, and (b) qualify a KNOWN-but-stale control value with
    /// a bounded "· synced X ago" so the owner knows it may be out of date
    /// (especially Trunk/Lock). `nil` on the simulated path and before the first
    /// live frame, so M1 / drift-gate render identically (no qualifier).
    public var lastUpdated: Date?
    /// MYR-260 — whether the car is currently STREAMING live telemetry (online:
    /// driving/parked/charging) as opposed to not (offline/in_service/asleep).
    /// Distinguishes a transient unknown ("Syncing" — the value is still in
    /// flight from a streaming car) from a genuine one ("Unavailable" — the car
    /// isn't streaming and the one-shot REST read couldn't fill it, so the value
    /// is not coming). `nil` on the simulated path (treated as live), keeping M1
    /// pixel-identical.
    public var isStreaming: Bool?
    /// MYR-303 — the car's now-playing block (contracts 0.16.0 media fields),
    /// mapped by `VehicleContractMapping.nowPlaying(from:)`. `nil` on the simulated
    /// path AND on a live car that has never streamed a media field, so the Media
    /// card hides the block rather than showing a placeholder track (MYR-264). Its
    /// non-nil-ness is therefore the live-media signal itself: nothing but a real
    /// `VehicleState` can produce one, which keeps the M1 / drift-gate media card
    /// (the `VehicleMediaTrack` fixture) pixel-identical.
    public var nowPlaying: VehicleNowPlaying?
    /// MYR-316 — when the car's CURRENT service visit is estimated to end
    /// (contracts 0.17.0 `serviceEstimatedEndAt`). Non-nil only while the wire
    /// status is `in_service`; the server clears it on any other status, so no
    /// consumer ages it out. `nil` on the simulated path AND — commonly — on a
    /// live in-service car whose visit has no Tesla appointment record, which is
    /// exactly why every consumer treats nil as "no window known" and renders
    /// nothing / floors nothing rather than as an error.
    ///
    /// SNAPSHOT-ONLY by contract: it rides the cold REST read, never a
    /// `vehicle_update` delta (see the Kit's `VehicleStateMerger`).
    public var serviceEstimatedEndAt: Date?
    /// MYR-333 — the car's live charge session, mapped from the wire
    /// `VehicleState.chargeState` by `VehicleContractMapping.chargingState(from:)`.
    ///
    /// Unlike `serviceEstimatedEndAt` this is a FOLDED STREAMING field: it is a
    /// member of the `charge` atomic group, the Kit's `VehicleStateMerger`
    /// already folds it off a live `vehicle_update`, and the backend re-asserts
    /// it every 120s (MYR-333's `DetailedChargeState` resend). So it reaches the
    /// hero on both the cold `/snapshot` AND every subsequent delta, which is
    /// what lets a car that starts charging while the sheet is open begin
    /// pulsing without a refetch.
    ///
    /// `.idle` on the simulated path and before the first live frame, so M1 and
    /// every drift-gate scene stay pixel-identical.
    public var chargingState: VehicleChargingState
    /// MYR-342 — the owner's ride-sharing switch as the last REST read reported it
    /// (contracts 0.20.0 `rideShareEnabled`). `true` = riders can request this car,
    /// `false` = the owner has PAUSED requests.
    ///
    /// OPTIONAL, and the nil is doing something different here from every other
    /// optional on this struct. Elsewhere `nil` means "not known yet → render an
    /// honest dash". Here it means "the wire did not say", and the contract's rule
    /// is that a silent wire means ENABLED — so nothing ever renders a dash off
    /// this field. It stays optional anyway rather than defaulting to `true` at
    /// this layer, so that "the snapshot never told us" and "the snapshot said
    /// true" remain distinguishable for the resolver that has to decide whether the
    /// executor's committed value outranks it.
    ///
    /// SNAPSHOT-ONLY by contract: it rides the cold REST read, never a
    /// `vehicle_update` delta (see the Kit's `VehicleStateMerger`, where the
    /// non-fold is a security property rather than a style choice).
    ///
    /// `nil` on the simulated path, where it renders nothing at all — the toggle
    /// row is live-only — so M1 and every drift-gate scene are unchanged.
    public var rideShareEnabled: Bool?
    /// MYR-456/MYR-457 — the wire's `tripDistanceRemaining`, in miles.
    ///
    /// `progress` above is a FRACTION, and a fraction is only meaningful against
    /// the polyline it was measured on. The owner's map may draw the app's own
    /// road route when Tesla has decoded no `RouteLine`, so the screen has to be
    /// able to re-measure against what it actually rendered — which needs the
    /// distance, not the ratio derived from a route that was not used.
    ///
    /// **`nil` is not `0` here.** `nil` means this frame carried no distance (an
    /// ordinary state mid-update: the nav group's members arrive apart inside the
    /// server's 500ms accumulation window), and rendering that as 0 is the whole
    /// of MYR-456's vanishing progress bar. `nil` on the simulated path, whose
    /// `progress` is the ticker's own and needs no re-derivation.
    public var tripDistanceRemainingMiles: Double?

    public init(
        status: VehicleTelemetryStatus,
        progress: Double,
        speedMPH: Int,
        batteryPercent: Double,
        etaMinutes: Int,
        interiorTempF: Int? = nil,
        exteriorTempF: Int? = nil,
        odometerMiles: Int? = nil,
        fsdMilesSinceReset: Double? = nil,
        lastUpdated: Date? = nil,
        isStreaming: Bool? = nil,
        nowPlaying: VehicleNowPlaying? = nil,
        serviceEstimatedEndAt: Date? = nil,
        chargingState: VehicleChargingState = .idle,
        rideShareEnabled: Bool? = nil,
        tripDistanceRemainingMiles: Double? = nil
    ) {
        self.tripDistanceRemainingMiles = tripDistanceRemainingMiles
        self.status = status
        self.progress = progress
        self.speedMPH = speedMPH
        self.batteryPercent = batteryPercent
        self.etaMinutes = etaMinutes
        self.interiorTempF = interiorTempF
        self.exteriorTempF = exteriorTempF
        self.odometerMiles = odometerMiles
        self.fsdMilesSinceReset = fsdMilesSinceReset
        self.lastUpdated = lastUpdated
        self.isStreaming = isStreaming
        self.nowPlaying = nowPlaying
        self.serviceEstimatedEndAt = serviceEstimatedEndAt
        self.chargingState = chargingState
        self.rideShareEnabled = rideShareEnabled
    }
}

/// The M1/M2 seam. `HomeScreen` reads `snapshot`; it doesn't know or care
/// whether the value comes from a local timer (M1) or a live WS frame (M2).
@MainActor
public protocol VehicleTelemetrySource: AnyObject, Observable {
    var snapshot: VehicleTelemetrySnapshot { get }
    /// Begin producing updates. Idempotent.
    func start()
    /// Stop producing updates (e.g. when the screen disappears). Idempotent.
    func stop()
}

/// M1 implementation: a local ticker that animates a driving vehicle along
/// its fixture route — no network. Parked vehicles emit one static snapshot
/// and never tick (screens.jsx has no parked-state animation).
@Observable
@MainActor
public final class SimulatedVehicleTelemetrySource: VehicleTelemetrySource {
    public private(set) var snapshot: VehicleTelemetrySnapshot

    private let totalRouteMinutes: Double
    /// Demo acceleration: the prototype's own auto-advance effect
    /// (app.jsx:51-58) is a no-op stub in the standalone build (its state
    /// mutation was never wired up), so there's no real-time pace to match.
    /// This ticks the full remaining route in ~90s of wall-clock time so the
    /// drift-gate screenshots and simulator runs show visible motion.
    private let demoDurationSeconds: Double = 90
    // `nonisolated(unsafe)`: only ever touched on the main actor except in
    // `deinit`, which Swift always runs nonisolated even for `@MainActor`
    // classes; `Timer.invalidate()` is safe to call from any thread.
    private nonisolated(unsafe) var timer: Timer?
    private let tickInterval: TimeInterval = 1.0 / 30.0

    public init(activity: VehicleActivity) {
        switch activity {
        case .driving:
            // Matches the prototype's default tweaks (app.jsx:12-19):
            // tripProgress 0.42, battery 68, speed 64; eta from screens.jsx:373.
            let progress = 0.42
            totalRouteMinutes = 87
            snapshot = VehicleTelemetrySnapshot(
                status: .driving,
                progress: progress,
                speedMPH: 64,
                batteryPercent: 68,
                etaMinutes: max(1, Int(((1 - progress) * 87).rounded())),
                // vehicle-controls.jsx:229-230 fixture cabin/exterior temps — kept
                // here so the simulated controls render identically to M1.
                interiorTempF: 66,
                exteriorTempF: 58,
                // vehicle-controls.jsx:412-414 fixture Lifetime stats — seeded here
                // so the SIMULATED controls render the exact same 42,184 / 31,907 /
                // 76% as M1 (the drift-gate scenes depend on it); the LIVE path
                // takes the real wire values via VehicleContractMapping (MYR-255).
                odometerMiles: 42184,
                fsdMilesSinceReset: 31907
            )
        case .parked:
            totalRouteMinutes = 0
            snapshot = VehicleTelemetrySnapshot(
                status: .parked,
                progress: 0,
                speedMPH: 0,
                batteryPercent: 68,
                etaMinutes: 0,
                interiorTempF: 66,
                exteriorTempF: 58,
                odometerMiles: 42184,
                fsdMilesSinceReset: 31907
            )
        }
    }

    public func start() {
        guard snapshot.status == .driving, timer == nil else { return }
        let timer = Timer(timeInterval: tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
    }

    private func tick() {
        guard snapshot.status == .driving else { return }

        // app.jsx:51-53's target-speed formula (`55 + Math.sin(Date.now() /
        // 4000) * 18`), smoothed toward like a real ambient fluctuation
        // rather than snapping every tick.
        let t = Date().timeIntervalSinceReferenceDate
        let targetSpeed = 55 + sin(t / 4) * 18
        let smoothedSpeed = Double(snapshot.speedMPH) + (targetSpeed - Double(snapshot.speedMPH)) * 0.06
        snapshot.speedMPH = max(0, Int(smoothedSpeed.rounded()))

        let progressPerTick = tickInterval / demoDurationSeconds
        snapshot.progress = min(1, snapshot.progress + progressPerTick)
        snapshot.etaMinutes = max(0, Int(((1 - snapshot.progress) * totalRouteMinutes).rounded()))
        // Gentle battery drain while driving — cosmetic, not range-modeled.
        snapshot.batteryPercent = max(0, snapshot.batteryPercent - 0.0015)

        if snapshot.progress >= 1 {
            stop()
        }
    }
}
