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
// await latency while dragging).
//
// MYR-286 — `setPlate` is now a REAL backend write, just not a Tesla one: the
// owner-scoped `PUT /api/tesla/vehicles/{vehicleId}/plate` (rest-api.md §7.14),
// which is the ONLY writer of `Vehicle.licensePlate` anywhere in the stack. That
// is why it was always `async throws`. On the live path it persists and adopts
// the SERVER-NORMALIZED echo; on the simulated path it stays a local mutation so
// the M1 / drift-gate scenes are pixel-identical.

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
    /// MYR-286 — the owner-entered license plate. NOT a §7.9 Tesla command: it is
    /// the local owner-scoped `PUT /api/tesla/vehicles/{id}/plate` (§7.14), which
    /// touches no Tesla surface at all. It is keyed here anyway because it needs
    /// exactly the same pending/notice UX as the commanded controls — before
    /// MYR-286 `setPlate` wrote only to memory and the edit sheet silently
    /// discarded the owner's input.
    case plate

    /// The control's name in owner-facing copy (MYR-301). The notice row sits
    /// BELOW the tile row, so it has to say which control it is talking about —
    /// the tile's own label is too far away to carry that on its own.
    public var displayName: String {
        switch self {
        case .lock: "Lock"
        case .climate: "Climate"
        case .temp: "Temperature"
        case .trunk: "Trunk"
        case .chargePort: "Charge port"
        case .driverSeat: "Driver seat"
        case .passengerSeat: "Passenger seat"
        case .media: "Media"
        case .plate: "Plate"
        }
    }

    /// The SF Symbol the quick tile uses, reused by the notice row's disc so the
    /// row is visually tied to the tile that failed (MYR-301). Non-tile controls
    /// don't need one — they render their notice in place, next to themselves.
    public var tileIcon: String? {
        switch self {
        case .lock: "lock.fill"
        case .climate: "fan"
        case .trunk: "car.fill"
        case .chargePort: "bolt.fill"
        // The plate lives in a labelled details ROW, not a tile — its notice
        // renders in place, next to itself, so it needs no disc icon.
        case .temp, .driverSeat, .passengerSeat, .media, .plate: nil
        }
    }
}

/// The owner action a notice can route to (MYR-301). A notice that names a
/// broken Tesla connection is not just copy — it is a dead end unless the owner
/// can get to the fix from where they read it, so the notice carries the route
/// and every surface that renders notices makes it tappable (44pt).
public enum VehicleCommandNoticeAction: Sendable, Equatable {
    /// Re-run the Tesla account link (the same flow Settings → Tesla Account →
    /// "Add another Tesla" / onboarding uses). Re-consent is what grants a
    /// missing scope (e.g. `vehicle_charging_cmds`).
    case relinkTesla

    /// The gold pill's label on the notice row.
    public var label: String {
        switch self {
        case .relinkTesla: "Reconnect"
        }
    }
}

/// A honest, non-dramatic notice for a failed/transient command (MYR-249).
/// Maps 1:1 from the Kit's `RestError.CommandFailureKind` via
/// `LiveVehicleCommandExecutor.notice(for:)`. Copy is deliberately quiet
/// (design minimalism) and points at the owner action where one exists.
///
/// MYR-301 — a notice now carries THREE things, because the ~80pt control tile
/// cannot hold a sentence (the client saw "Reconnec…"):
///   • `tileText` — a SHORT token that fits the tile sub on one line at the one
///     uniform 11pt size MYR-281 established (no per-tile scaling),
///   • `message` — the FULL honest sentence, rendered on a full-width surface
///     (the notice row under the tiles, the seat row's own line, the media line),
///   • `action` — the route that FIXES it, where one exists.
public enum VehicleCommandNotice: Sendable, Equatable {
    case waking          // vehicle_asleep — in flight: the server/SDK is retrying
    case asleep          // vehicle_asleep — settled: it did NOT wake in time (MYR-301)
    case pairKey         // key_not_paired — pair the virtual key in Tesla
    case relink          // permission_denied / not-owned / auth — reconnect Tesla
    case relinkCharging  // permission_denied on a charge-port command — the token
                         // lacks the `vehicle_charging_cmds` scope specifically
    case cooldown        // rate_limited (429) — brief "just a moment"
    case rejected        // command_failed (502) — the CAR refused the action (MYR-301)
    case failed          // transport / invalid / not-found — couldn't reach the car
    // MYR-286 — the two plate outcomes. The plate is NOT a Tesla command (§7.14 is
    // a local owner-scoped DB write with no Tesla call in it), so every notice
    // above that talks about "the car" would be a lie on this path: the car is
    // never asked, never asleep, and never the thing that refused.
    case invalidPlate    // 400 invalid_request — the plate itself violates the rule
    case plateNotSaved   // transport / 404 / 5xx — the write didn't land

    public var message: String {
        switch self {
        case .waking: "Waking the car\u{2026}"
        // MYR-301 — 503 `vehicle_asleep` used to settle as "Waking the car…"
        // (claiming an ongoing wake that had in fact given up) and read as the
        // same "couldn't reach the car" class as a 502. It is neither: the car is
        // simply asleep and the wake didn't land in time.
        case .asleep: "Car is asleep \u{2014} try again shortly"
        case .pairKey: "Pair your key in Tesla"
        case .relink: "Reconnect Tesla to allow this"
        // The charge-port commands need the `vehicle_charging_cmds` scope, which
        // the owner's token may not carry (MYR-249) — name the charging permission
        // so the re-link is unambiguous.
        case .relinkCharging: "Reconnect Tesla for charging access"
        case .cooldown: "Just a moment\u{2026}"
        // MYR-301 — 502 `command_failed` is a REJECTION by the vehicle, not a
        // reachability problem: we reached the car and it said no. Saying
        // "couldn't reach the car" for it is dishonest (and hid the asleep case).
        case .rejected: "The car didn\u{2019}t accept that"
        case .failed: "Couldn\u{2019}t reach the car"
        // MYR-286 — the server normalizes (trim + uppercase) BEFORE validating, so
        // a 400 means the plate genuinely breaks the rule (charset or the 10-char
        // cap) rather than that the owner typed it lowercase or with stray spaces.
        // The copy says what is wrong (the plate, not the car, not the network)
        // without echoing the rejected value — it is P1 and the server itself
        // never repeats it back.
        case .invalidPlate: "That plate doesn\u{2019}t look right"
        // Reachability / store failure on the plate write. Deliberately NOT
        // "Couldn't reach the car": no Tesla call is involved in §7.14 at all.
        case .plateNotSaved: "Couldn\u{2019}t save the plate"
        }
    }

    /// The tile sub token (MYR-301). MUST render within the control tile's inner
    /// width (~54pt at the uniform 11pt sub size) so it never ellipsizes — see
    /// `VehicleCommandNoticeTests.testTileTextFitsTheControlTile`, which measures
    /// every case. The FULL `message` is surfaced on the notice row below the
    /// tiles, so nothing is hidden by the shortening.
    public var tileText: String {
        switch self {
        case .waking: "Waking\u{2026}"
        case .asleep: "Asleep"
        case .pairKey: "Pair key"
        case .relink, .relinkCharging: "Re-link"
        case .cooldown: "One sec\u{2026}"
        case .rejected: "Declined"
        case .failed: "Failed"
        // Never rendered on a tile (the plate is a details row, not a tile), but
        // the token is measured with the rest so the vocabulary stays uniform.
        case .invalidPlate: "Check it"
        case .plateNotSaved: "Not saved"
        }
    }

    /// The owner action that resolves this notice, or `nil` when there is nothing
    /// in-app to route to (waking/cooldown resolve themselves; pairing happens in
    /// the Tesla app; a rejection/unreachable car is retried by tapping again).
    public var action: VehicleCommandNoticeAction? {
        switch self {
        case .relink, .relinkCharging: .relinkTesla
        // MYR-286 — neither plate notice routes anywhere: the fix for an invalid
        // plate is to re-open the edit sheet and correct it (the row is already
        // the tap target), and a failed save is retried by saving again.
        case .waking, .asleep, .pairKey, .cooldown, .rejected, .failed,
             .invalidPlate, .plateNotSaved: nil
        }
    }

    /// Transient notices resolve on their own (the car is waking / cooling down);
    /// the others need an owner action and persist until the next tap.
    public var isTransient: Bool { self == .waking || self == .cooldown }
}

/// A control whose CURRENT displayed state the live path may not yet know
/// (MYR-251). The owner's actuator state — lock, climate on/off, setpoint, fan,
/// seat levels, trunk, charge-port, media — is NOT carried by the `VehicleState`
/// contract today (the generated `MyRobotaxiContracts.VehicleState` has no such
/// property; several of these values stream on the WS but are uncontracted, so
/// the Kit cannot fold them without a hand-written wire shape — forbidden by
/// CLAUDE.md). The live executor therefore cannot assert a resting value and
/// renders the control as unknown ("—") until the owner commands it
/// (optimistic-on-ack) or, once the contract grows the field, real telemetry
/// reconciles it (MYR-228: no fixture values on the live path). The simulated
/// executor knows every field (fixtures), keeping the M1 / drift-gate scenes
/// pixel-identical.
public enum VehicleControlField: Sendable, Hashable, CaseIterable {
    case locked
    case climateOn
    case targetTemp
    // The Auto/Cool/Heat segment (MYR-274). Known once the car's HVAC mode is
    // reconciled from the wire (`hvacAutoMode`/`hvacAcEnabled`) or the owner
    // commands Auto (`auto_conditioning_start`). Until then it is honestly unknown
    // (nothing lit) rather than the seeded `.auto` (MYR-228 / MYR-251).
    case climateMode
    case fanSpeed
    case driverSeat
    case passengerSeat
    case trunkOpen
    case chargePortOpen
    case mediaPlaying
    case volume
    /// MYR-286 — the owner-entered plate. Unlike its siblings this one IS on the
    /// read contract (`VehicleState.licensePlate`, contracts 0.15.0), so it
    /// becomes known the moment a snapshot arrives, or when the owner saves one.
    /// Until then the details row shows the designed "Add plate" affordance and
    /// the display surfaces fall back to `VIN ····xxxx` — never a fabricated plate.
    case plate
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
    /// The RAW owner-entered license plate — empty when none is set (MYR-286).
    /// NOT the display string: the `VIN ····xxxx` fallback belongs to
    /// `VehicleContractMapping.plateDisplay` and to `Vehicle.plate`, which is what
    /// the switcher / Settings rows / rider chip render. Keeping this one raw is
    /// what lets the edit sheet prefill exactly what the owner typed and lets an
    /// unset plate render the designed "Add plate" affordance instead of a VIN the
    /// owner cannot edit. The simulated executor seeds it from the fixture plate,
    /// so M1 is unchanged.
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

    // MARK: Honest-state seam (MYR-251)

    /// Whether THIS executor knows the control's current displayed state. Default
    /// `true` (below) — the simulated executor's fixtures are authoritative, so
    /// M1 / drift-gate scenes render every value and stay pixel-identical. The
    /// live executor returns `false` until the field is confirmed by a command
    /// ack, so an unconfirmed control renders a design-consistent unknown ("—")
    /// instead of a fixture value on the live path (MYR-228 / MYR-251).
    func isKnown(_ field: VehicleControlField) -> Bool
}

public extension VehicleCommandExecutor {
    func uiState(for key: VehicleControlKey) -> VehicleControlUIState { .idle }
    func isSupported(_ key: VehicleControlKey) -> Bool { true }
    func isKnown(_ field: VehicleControlField) -> Bool { true }
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
