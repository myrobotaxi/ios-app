import Foundation
import Observation

// MARK: - Vehicle command seam (MYR-168 deliverable 2)
//
// `VehicleCommandExecutor` is the M1↔M2 seam for every mutating action inside
// `VehicleControls` (design/app/vehicle-controls.jsx) — lock, climate
// on/off + setpoint + mode + fan, seat heat/vent, trunk, charge port, and
// media playback/track/volume. This issue ships
// `SimulatedVehicleCommandExecutor`, which mutates `controls` locally with no
// network and no artificial delay: the prototype's own `onClick` handlers
// are synchronous `setState` calls (`onClick={() => setLocked(l => !l)}`,
// vehicle-controls.jsx:247 et al.) — there is no pending/spinner state
// anywhere in vehicle-controls.jsx to match.
//
// P11 (Vehicle Commands, MYR-180-183 — Backend: NOT ready) swaps in an
// implementation that calls the signed-command proxy and only mutates
// `controls` after the vehicle acknowledges. Every call site
// (`VehicleControls` and its subviews) stays unchanged, which is why every
// mutator below is `async throws` today even though the simulated path can't
// fail — mirrors `AuthSession`'s documented rationale (AuthSession.swift:4-12).
//
// License-plate editing and media scrub position are NOT vehicle commands:
// Tesla's data has no plate field (see `PlateRow`'s doc comment below, ported
// from vehicle-controls.jsx:124-125) and there is no Fleet API seek-to-
// position, so `setScrubPercent` is a plain synchronous local mutation (no
// await latency while dragging) and `setPlate` — while still `async throws`,
// to match the day it becomes a real backend `PATCH` — is a distinct concern
// from the Tesla command surface P11 replaces.

public enum VehicleClimateMode: String, Sendable, Equatable, CaseIterable {
    case auto, cool, heat
}

public enum VehicleSeatPosition: Sendable, Equatable {
    case driver, passenger
}

public enum VehicleSeatClimateMode: String, Sendable, Equatable {
    case heat, cool
}

public enum VehicleTrackDirection: Sendable, Equatable {
    case previous, next
}

// MARK: - Command UX state (MYR-249)
//
// The seam that lets a control render its in-flight / error state without
// knowing whether the executor is simulated or live. Every backend-backed
// control is keyed; the executor tracks a per-key `VehicleControlUIState`, and
// the view reads `executor.uiState(for:)` to show a spinner or an honest error
// line. The simulated executor returns `.idle` for every key (default protocol
// impl below), so the M1 / drift-gate scenes stay pixel-identical (CLAUDE.md).

/// The controls that map to a real §7.9 backend command (MYR-249). `chargePort`
/// is included even though it has NO backend command — the live executor reports
/// it UNSUPPORTED so the tile can be honestly disabled rather than faked.
public enum VehicleControlKey: Sendable, Hashable {
    case lock
    case climate        // auto_conditioning_start / stop (the on/off tile)
    case temp           // set_temps
    case trunk          // actuate_trunk (rear)
    case chargePort     // charge_port_door_open / close (MYR-249 phase 3, v186)
    case driverSeat     // remote_seat_heater_request / remote_seat_cooler_request
    case passengerSeat  // remote_seat_heater_request / remote_seat_cooler_request
    case media          // media_toggle_playback / next / prev (one in flight at a time)
}

/// A honest, non-dramatic notice for a failed/transient command (MYR-249).
/// Maps 1:1 from the Kit's `RestError.CommandFailureKind` via
/// `LiveVehicleCommandExecutor.notice(for:)`. Copy is deliberately quiet
/// (design minimalism) and points at the owner action where one exists.
public enum VehicleCommandNotice: Sendable, Equatable {
    case waking          // vehicle_asleep — the server retries; reflect that
    case pairKey         // key_not_paired — pair the virtual key in Tesla
    case relink          // permission_denied / not-owned / auth — reconnect Tesla
    case relinkCharging  // permission_denied on a charge-port command — the token
                         // lacks the `vehicle_charging_cmds` scope specifically
    case cooldown        // rate_limited (429) — brief "just a moment"
    case failed          // command_failed / invalid / offline — couldn't reach the car

    public var message: String {
        switch self {
        case .waking: "Waking the car\u{2026}"
        case .pairKey: "Pair your key in Tesla"
        case .relink: "Reconnect Tesla to allow this"
        // The charge-port commands need the `vehicle_charging_cmds` scope, which
        // the owner's token may not carry (MYR-249) — name the charging permission
        // so the re-link is unambiguous.
        case .relinkCharging: "Reconnect Tesla for charging access"
        case .cooldown: "Just a moment\u{2026}"
        case .failed: "Couldn\u{2019}t reach the car"
        }
    }

    /// Transient notices resolve on their own (the car is waking / cooling down);
    /// the others need an owner action and persist until the next tap.
    public var isTransient: Bool { self == .waking || self == .cooldown }
}

/// One control's live command state: pending (a command is in flight — suppress
/// re-fires) and/or a settled notice from the last attempt.
public struct VehicleControlUIState: Sendable, Equatable {
    public var isPending: Bool
    public var notice: VehicleCommandNotice?

    public init(isPending: Bool = false, notice: VehicleCommandNotice? = nil) {
        self.isPending = isPending
        self.notice = notice
    }

    public static let idle = VehicleControlUIState()
}

/// Everything a `VehicleControls` tree needs to render one tick of the
/// controls surface (vehicle-controls.jsx:208-225 `useState` block).
public struct VehicleControlsSnapshot: Sendable, Equatable {
    public var locked: Bool
    public var climateOn: Bool
    public var targetTemp: Int
    public var climateMode: VehicleClimateMode
    public var fanSpeed: Int
    public var driverSeatHeatLevel: Int
    public var driverSeatMode: VehicleSeatClimateMode
    public var passengerSeatHeatLevel: Int
    public var passengerSeatMode: VehicleSeatClimateMode
    public var trunkOpen: Bool
    public var chargePortOpen: Bool
    public var mediaPlaying: Bool
    public var trackIndex: Int
    public var volume: Double
    public var scrubPercent: Double
    public var plate: String

    public init(
        locked: Bool,
        climateOn: Bool,
        targetTemp: Int,
        climateMode: VehicleClimateMode,
        fanSpeed: Int,
        driverSeatHeatLevel: Int,
        driverSeatMode: VehicleSeatClimateMode,
        passengerSeatHeatLevel: Int,
        passengerSeatMode: VehicleSeatClimateMode,
        trunkOpen: Bool,
        chargePortOpen: Bool,
        mediaPlaying: Bool,
        trackIndex: Int,
        volume: Double,
        scrubPercent: Double,
        plate: String
    ) {
        self.locked = locked
        self.climateOn = climateOn
        self.targetTemp = targetTemp
        self.climateMode = climateMode
        self.fanSpeed = fanSpeed
        self.driverSeatHeatLevel = driverSeatHeatLevel
        self.driverSeatMode = driverSeatMode
        self.passengerSeatHeatLevel = passengerSeatHeatLevel
        self.passengerSeatMode = passengerSeatMode
        self.trunkOpen = trunkOpen
        self.chargePortOpen = chargePortOpen
        self.mediaPlaying = mediaPlaying
        self.trackIndex = trackIndex
        self.volume = volume
        self.scrubPercent = scrubPercent
        self.plate = plate
    }
}

/// The M1/M2 seam for vehicle commands. `VehicleControls` reads `controls`;
/// it doesn't know or care whether a mutator resolves a local optimistic
/// write (M1) or a round trip through the signed-command proxy (M2/P11).
/// Conforming types must be `@Observable` classes (see
/// `VehicleTelemetrySource`'s doc comment, VehicleTelemetry.swift:12-15, for
/// why `any VehicleCommandExecutor` is still safe to read from a SwiftUI body).
@MainActor
public protocol VehicleCommandExecutor: AnyObject, Observable {
    var controls: VehicleControlsSnapshot { get }

    func setLocked(_ locked: Bool) async throws
    func setClimateOn(_ on: Bool) async throws
    func setTargetTemp(_ temp: Int) async throws
    func setClimateMode(_ mode: VehicleClimateMode) async throws
    func setFanSpeed(_ speed: Int) async throws
    func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws
    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode: VehicleSeatClimateMode) async throws
    func setTrunkOpen(_ open: Bool) async throws
    func setChargePortOpen(_ open: Bool) async throws
    func setMediaPlaying(_ playing: Bool) async throws
    func skipTrack(_ direction: VehicleTrackDirection) async throws
    func setVolume(_ volume: Double) async throws
    func setPlate(_ plate: String) async throws

    /// Continuous scrub drag — not a vehicle command (see header); synchronous
    /// so the slider tracks the finger with no await latency.
    func setScrubPercent(_ percent: Double)

    // MARK: Command UX seam (MYR-249)

    /// The in-flight / error state for a backend-backed control. Default `.idle`
    /// (below) — the simulated executor never has an in-flight command, keeping
    /// the M1 / drift-gate scenes pixel-identical.
    func uiState(for key: VehicleControlKey) -> VehicleControlUIState

    /// Whether a control maps to a real backend command on THIS executor. Default
    /// `true` (below) — simulated everything is interactive. The live executor
    /// returns `false` for `.chargePort` (no §7.9 command) so the tile is honestly
    /// disabled rather than faked.
    func isSupported(_ key: VehicleControlKey) -> Bool
}

public extension VehicleCommandExecutor {
    func uiState(for key: VehicleControlKey) -> VehicleControlUIState { .idle }
    func isSupported(_ key: VehicleControlKey) -> Bool { true }
}

/// M1 implementation: mutates `controls` synchronously and locally, matching
/// the prototype's own `useState` setters — no network, no delay.
@Observable
@MainActor
public final class SimulatedVehicleCommandExecutor: VehicleCommandExecutor {
    public private(set) var controls: VehicleControlsSnapshot

    /// Number of fake tracks in the media fixture (vehicle-controls.jsx:199-203
    /// `TRACKS`) — kept in sync with `VehicleMediaTrack.all.count`.
    private let trackCount = 3

    /// vehicle-controls.jsx:205-225 defaults. `mediaPlaying` seeds from
    /// `driving` (jsx `useState(driving)`, line 222); `plate` from the
    /// vehicle fixture (jsx `v.plate || ''`, line 220).
    public init(driving: Bool, plate: String) {
        controls = VehicleControlsSnapshot(
            locked: true,
            climateOn: true,
            targetTemp: 70,
            climateMode: .auto,
            fanSpeed: 3,
            driverSeatHeatLevel: 2,
            driverSeatMode: .heat,
            passengerSeatHeatLevel: 0,
            passengerSeatMode: .heat,
            trunkOpen: false,
            chargePortOpen: false,
            mediaPlaying: driving,
            trackIndex: 0,
            volume: 45,
            scrubPercent: 38,
            plate: plate
        )
    }

    public func setLocked(_ locked: Bool) async throws {
        controls.locked = locked
    }

    public func setClimateOn(_ on: Bool) async throws {
        controls.climateOn = on
    }

    public func setTargetTemp(_ temp: Int) async throws {
        controls.targetTemp = min(82, max(60, temp)) // vehicle-controls.jsx:262,270
    }

    public func setClimateMode(_ mode: VehicleClimateMode) async throws {
        controls.climateMode = mode
    }

    public func setFanSpeed(_ speed: Int) async throws {
        controls.fanSpeed = min(10, max(0, speed))
    }

    public func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws {
        let clamped = min(3, max(0, level))
        switch seat {
        case .driver: controls.driverSeatHeatLevel = clamped
        case .passenger: controls.passengerSeatHeatLevel = clamped
        }
    }

    public func setSeatClimateMode(_ seat: VehicleSeatPosition, mode: VehicleSeatClimateMode) async throws {
        // vehicle-controls.jsx:90 — switching Heat/Cool resets the level.
        switch seat {
        case .driver:
            controls.driverSeatMode = mode
            controls.driverSeatHeatLevel = 0
        case .passenger:
            controls.passengerSeatMode = mode
            controls.passengerSeatHeatLevel = 0
        }
    }

    public func setTrunkOpen(_ open: Bool) async throws {
        controls.trunkOpen = open
    }

    public func setChargePortOpen(_ open: Bool) async throws {
        controls.chargePortOpen = open
    }

    public func setMediaPlaying(_ playing: Bool) async throws {
        controls.mediaPlaying = playing
    }

    public func skipTrack(_ direction: VehicleTrackDirection) async throws {
        switch direction {
        case .previous: controls.trackIndex = (controls.trackIndex + trackCount - 1) % trackCount
        case .next: controls.trackIndex = (controls.trackIndex + 1) % trackCount
        }
        controls.scrubPercent = 0 // vehicle-controls.jsx:365,371
    }

    public func setVolume(_ volume: Double) async throws {
        controls.volume = min(100, max(0, volume))
    }

    public func setScrubPercent(_ percent: Double) {
        controls.scrubPercent = min(100, max(0, percent))
    }

    public func setPlate(_ plate: String) async throws {
        controls.plate = plate
    }
}
