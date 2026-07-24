import Foundation
import MyRobotaxiContracts

// MARK: - Vehicle command surface (rest-api.md §7.9, MYR-249 / P11 MYR-181–183)
//
// The owner-only Tesla actuation endpoint:
// `POST /api/vehicles/{vehicleId}/command/{name}` (Bearer + owner of vehicleId).
// Each `VehicleCommand` case is one row of the §7.9 catalog; `name` is the exact
// Tesla Fleet command name (the `{name}` path segment) and `encodedBody()` is the
// typed param body (empty for parameterless commands).
//
// NAVIGATION / DISPATCH commands (`navigation_gps_request`, `navigation_request`)
// are deliberately absent: they are dispatch-only (MYR-176, pushed server-side on
// ride accept) and are never issued from the owner controls.
//
// MYR-249 phase 3 (backend v186) ADDED eight owner controls to the §7.9 catalog:
// charge-port open/close, seat heater/cooler, and the four media transport
// commands. The seat heater and cooler are ASYMMETRIC on the wire (documented in
// §7.9): the heater's `level` is 0–3 (0 = off) while the cooler's
// `seat_cooler_level` is 1–4 (1 = off, 2 = low, 3 = med, 4 = high), and each uses
// a different `seat_position` numbering. That asymmetry lives in exactly ONE
// place — the `seatHeater`/`seatCooler` factories below — and is table-tested at
// its boundaries in `VehicleCommandEndpointTests`.
//
// Why the param shapes live here rather than in `MyRobotaxiContracts`: the
// contracts codegen covers READ models + the WS envelope only — there is no
// generated command-request type (verified against the checked-out contracts
// `Generated/` set). These are the ONE definition of the (tiny, transit-only)
// command wire shapes, kept in a single table-testable place (name + JSON body
// asserted per case in `VehicleCommandEndpointTests`).

public enum VehicleCommand: Sendable, Equatable {
    case doorLock
    case doorUnlock
    case autoConditioningStart
    case autoConditioningStop
    /// Temps are CELSIUS on the wire (§7.9). `passengerTempC == nil` → the server
    /// mirrors the driver temp to the passenger.
    case setTemps(driverTempC: Double, passengerTempC: Double?)
    case chargeStart
    case chargeStop
    /// `percent` is validated server-side to the §7.9 range (int 50–100).
    case setChargeLimit(percent: Int)
    case actuateTrunk(TrunkSelection)
    case remoteStartDrive
    case honkHorn
    case flashLights
    // MYR-249 phase 3 (v186) — charge port, seat climate, media.
    /// Scope `vehicle_charging_cmds` — the owner's token may lack it → the server
    /// returns `permission_denied` (re-link Tesla for charging access).
    case chargePortDoorOpen
    case chargePortDoorClose
    /// `seat_position` 0–8 (0 = front-left driver, 1 = front-right passenger — the
    /// proxy's seatPositions table, §7.9); `level` 0–3 (0 = off). Build via
    /// `seatHeater(_:uiLevel:)` — do not hand-map the numbering.
    case remoteSeatHeaterRequest(seatPosition: Int, level: Int)
    /// `seat_position` **1 = front-left, 2 = front-right ONLY** (§7.9);
    /// `seat_cooler_level` **1–4** (1 = off, 2 = low, 3 = med, 4 = high) — the
    /// asymmetric scale. Build via `seatCooler(_:uiLevel:)`.
    case remoteSeatCoolerRequest(seatPosition: Int, seatCoolerLevel: Int)
    case mediaTogglePlayback
    case mediaNextTrack
    case mediaPrevTrack
    /// `volume` float 0–11 (§7.9).
    case adjustVolume(volume: Double)

    public enum TrunkSelection: String, Sendable, Equatable {
        case front
        case rear
    }

    /// Which front seat a seat-climate command targets. The wire `seat_position`
    /// differs between the heater and the cooler (§7.9) — resolved in the
    /// factories below, never at the call site.
    public enum SeatSide: Sendable, Equatable {
        case driver
        case passenger
    }

    // MARK: Seat-climate factories — the ONE place the heater/cooler asymmetry lives

    /// A `remote_seat_heater_request` for `side` at `uiLevel` (the UI's 0–3 heat
    /// step, 0 = off). Heater `seat_position`: driver 0, passenger 1 (§7.9 proxy
    /// seatPositions table). `level` passes straight through (0–3), clamped.
    public static func seatHeater(_ side: SeatSide, uiLevel: Int) -> VehicleCommand {
        .remoteSeatHeaterRequest(
            seatPosition: side == .driver ? 0 : 1,
            level: min(3, max(0, uiLevel))
        )
    }

    /// A `remote_seat_cooler_request` for `side` at `uiLevel` (the SAME UI 0–3
    /// step, 0 = off). The cooler is asymmetric with the heater (§7.9): its
    /// `seat_position` is driver 1 / passenger 2 (front-left/front-right only) and
    /// its `seat_cooler_level` is 1–4, so the UI step maps `uiLevel + 1`
    /// (0 → 1 off, 1 → 2 low, 2 → 3 med, 3 → 4 high).
    public static func seatCooler(_ side: SeatSide, uiLevel: Int) -> VehicleCommand {
        .remoteSeatCoolerRequest(
            seatPosition: side == .driver ? 1 : 2,
            seatCoolerLevel: min(3, max(0, uiLevel)) + 1
        )
    }

    /// The Tesla Fleet command name — the `{name}` path segment (§7.9 catalog).
    public var name: String {
        switch self {
        case .doorLock: "door_lock"
        case .doorUnlock: "door_unlock"
        case .autoConditioningStart: "auto_conditioning_start"
        case .autoConditioningStop: "auto_conditioning_stop"
        case .setTemps: "set_temps"
        case .chargeStart: "charge_start"
        case .chargeStop: "charge_stop"
        case .setChargeLimit: "set_charge_limit"
        case .actuateTrunk: "actuate_trunk"
        case .remoteStartDrive: "remote_start_drive"
        case .honkHorn: "honk_horn"
        case .flashLights: "flash_lights"
        case .chargePortDoorOpen: "charge_port_door_open"
        case .chargePortDoorClose: "charge_port_door_close"
        case .remoteSeatHeaterRequest: "remote_seat_heater_request"
        case .remoteSeatCoolerRequest: "remote_seat_cooler_request"
        case .mediaTogglePlayback: "media_toggle_playback"
        case .mediaNextTrack: "media_next_track"
        case .mediaPrevTrack: "media_prev_track"
        case .adjustVolume: "adjust_volume"
        }
    }

    /// The typed JSON body for the command, or `nil` for a parameterless command
    /// (§7.9: "parameterless commands take an empty body").
    public func encodedBody() throws -> Data? {
        let encoder = JSONEncoder()
        switch self {
        case .setTemps(let driver, let passenger):
            return try encoder.encode(SetTempsBody(driverTemp: driver, passengerTemp: passenger))
        case .setChargeLimit(let percent):
            return try encoder.encode(SetChargeLimitBody(percent: percent))
        case .actuateTrunk(let which):
            return try encoder.encode(ActuateTrunkBody(whichTrunk: which.rawValue))
        case .remoteSeatHeaterRequest(let seatPosition, let level):
            return try encoder.encode(SeatHeaterBody(seatPosition: seatPosition, level: level))
        case .remoteSeatCoolerRequest(let seatPosition, let seatCoolerLevel):
            return try encoder.encode(SeatCoolerBody(seatPosition: seatPosition, seatCoolerLevel: seatCoolerLevel))
        case .adjustVolume(let volume):
            return try encoder.encode(AdjustVolumeBody(volume: volume))
        default:
            return nil
        }
    }

    // MARK: Param bodies (snake_case wire keys per §7.9)

    private struct SetTempsBody: Encodable {
        let driverTemp: Double
        let passengerTemp: Double?
        enum CodingKeys: String, CodingKey {
            case driverTemp = "driver_temp"
            case passengerTemp = "passenger_temp"
        }
    }

    private struct SetChargeLimitBody: Encodable {
        let percent: Int
    }

    private struct ActuateTrunkBody: Encodable {
        let whichTrunk: String
        enum CodingKeys: String, CodingKey {
            case whichTrunk = "which_trunk"
        }
    }

    private struct SeatHeaterBody: Encodable {
        let seatPosition: Int
        let level: Int
        enum CodingKeys: String, CodingKey {
            case seatPosition = "seat_position"
            case level
        }
    }

    private struct SeatCoolerBody: Encodable {
        let seatPosition: Int
        let seatCoolerLevel: Int
        enum CodingKeys: String, CodingKey {
            case seatPosition = "seat_position"
            case seatCoolerLevel = "seat_cooler_level"
        }
    }

    private struct AdjustVolumeBody: Encodable {
        let volume: Double
    }
}

/// `200 OK` body for a vehicle command (§7.9): `{ "status": "applied",
/// "command": "door_lock", "vin": "***0001" }`. The VIN is server-redacted to
/// the last 4 (P0 rule); the client never needs it, so it is optional/ignored.
public struct VehicleCommandResult: Decodable, Sendable, Equatable {
    public let status: String
    public let command: String
    public let vin: String?

    public init(status: String, command: String, vin: String?) {
        self.status = status
        self.command = command
        self.vin = vin
    }
}

// MARK: - Sending seam

/// The narrow "send one owner command" capability the app's live command
/// executor depends on — so the executor can be unit-tested against a fake
/// sender with no network. `RestClient` is the production conformer.
public protocol VehicleCommandSending: Sendable {
    /// `POST /api/vehicles/{vehicleId}/command/{name}` (§7.9). Throws
    /// `RestError` on any non-2xx (see `RestError.commandFailureKind` for the
    /// typed §7.9 error mapping).
    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult
}

// MARK: - Typed §7.9 error mapping

public extension RestError {
    /// The §7.9 command error catalog, folded to the semantic outcome a caller's
    /// UI acts on. The three MYR-180 codes (`key_not_paired`, `vehicle_asleep`,
    /// `command_failed`) are REST-only extensions the shared `ErrorPayload.Code`
    /// enum does not yet carry, so they arrive as `.unrecognized("…")` — matched
    /// here on the raw string, exactly as `RestClient` already matches
    /// `ride_active` (a later additive contracts entry keeps working unchanged).
    enum CommandFailureKind: Sendable, Equatable {
        /// 503 `vehicle_asleep` — transient; the server already woke+retried
        /// internally (§7.9). The SDK MAY retry once more with backoff.
        case vehicleAsleep
        /// 403 `key_not_paired` — the virtual key is not enrolled; needs owner
        /// action (pair in Tesla settings, MYR-115). Never auto-retry.
        case keyNotPaired
        /// 403 `permission_denied` — the owner's Tesla token lacks the scope;
        /// re-link Tesla. Never auto-retry.
        case permissionDenied
        /// 403 `vehicle_not_owned` — the caller is not the owner.
        case notOwned
        /// 429 `rate_limited` — per-vehicle cooldown; a brief "just a moment".
        case rateLimited
        /// 400 `invalid_request` — bad command/params (a client bug); surface, no retry.
        case invalidRequest
        /// 502 `command_failed` — the vehicle rejected the action; surface, no blind retry.
        case commandFailed
        /// 404 `not_found` — unknown vehicleId.
        case notFound
        /// 401 auth failure (caller token, or Tesla token un-refreshable).
        case auth
        /// Connectivity failure before a response formed.
        case transport
        /// Anything else (e.g. an unexpected status without a typed code).
        case other
    }

    /// Fold this error onto the §7.9 command outcome. Uses the typed
    /// `ErrorPayload.Code` where the shared enum carries it, and the raw code
    /// string for the REST-only MYR-180 codes.
    var commandFailureKind: CommandFailureKind {
        switch self {
        case .transport:
            return .transport
        case .insecureTransport, .invalidResponse, .decoding:
            return .other
        case .rideActive:
            return .other
        case .http(let status, let code, _, _):
            switch code?.rawValue {
            case "vehicle_asleep": return .vehicleAsleep
            case "key_not_paired": return .keyNotPaired
            case "permission_denied": return .permissionDenied
            case "vehicle_not_owned": return .notOwned
            case "rate_limited": return .rateLimited
            case "invalid_request": return .invalidRequest
            case "command_failed": return .commandFailed
            case "not_found": return .notFound
            case "auth_failed", "auth_timeout": return .auth
            default: break
            }
            // Fall back on the HTTP status when the body carried no typed code.
            switch status {
            case 401: return .auth
            case 403: return .permissionDenied
            case 404: return .notFound
            case 429: return .rateLimited
            case 502: return .commandFailed
            case 503: return .vehicleAsleep
            default: return .other
            }
        }
    }
}
