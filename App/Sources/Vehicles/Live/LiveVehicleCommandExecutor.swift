import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - LiveVehicleCommandExecutor (MYR-249 — P11 owner actuation, MYR-181–183)
//
// The live `VehicleCommandExecutor`: the four owner controls that map to a real
// §7.9 Tesla command route through the backend command endpoint (via the Kit's
// `VehicleCommandSending`); everything with no backend command stays a local
// mutation, flagged below. This is the executor `LiveVehicleFleet` now injects in
// place of the simulated one (P11 is ready as of MYR-249).
//
// Backend-backed (real command sent, then optimistic state on ack):
//   • lock tile         → door_lock / door_unlock
//   • climate on/off    → auto_conditioning_start / auto_conditioning_stop
//   • set temp ±        → set_temps (driver_temp °C; passenger mirrors)
//   • trunk tile        → actuate_trunk (rear)
//
// NO backend command in the §7.9 catalog (flagged follow-ups — kept as a local
// mutation to preserve the control's feel, EXCEPT charge-port which is reported
// unsupported so the tile is honestly disabled on live):
//   • charge port tile  → no charge_port command  → `isSupported(.chargePort) == false`
//   • climate mode (Auto/Cool/Heat) → no set-mode command
//   • fan speed         → no fan command
//   • seat heat / vent  → no seat-climate command
//   • media (play/skip/volume/scrub) → media is NOT in the catalog
//   • license plate      → not a Tesla command (no plate field, per MYR-168)
//
// UX (per MYR-249 task 3): a tap sets the control PENDING (double-tap suppressed
// by the pending guard); the value flips only once the command is acknowledged
// (optimistic-on-ack — the next telemetry frame remains authoritative); an error
// maps to an honest `VehicleCommandNotice`. `vehicle_asleep` (503) keeps the
// control pending with "Waking the car…" and retries once with backoff, reflecting
// that the server itself woke+retried (§7.9).
//
// SAFETY: this type is only ever constructed on the LIVE path (`LiveVehicleFleet`,
// built only for a live `AppMode`); the simulated demo never touches it. Tests
// drive it with a fake `VehicleCommandSending` — never a real token.
@Observable
@MainActor
final class LiveVehicleCommandExecutor: VehicleCommandExecutor {
    private(set) var controls: VehicleControlsSnapshot
    private var uiStates: [VehicleControlKey: VehicleControlUIState] = [:]

    private let vehicleID: String
    private let sender: any VehicleCommandSending
    /// Backoff before the single `vehicle_asleep` retry (injectable → `.zero` in
    /// tests for determinism; ~2 s in production, matching the §7.9 wake curve).
    private let wakeRetryDelay: Duration
    private let maxWakeRetries: Int
    private let trackCount = 3

    init(
        vehicleID: String,
        sender: any VehicleCommandSending,
        driving: Bool,
        plate: String,
        wakeRetryDelay: Duration = .seconds(2),
        maxWakeRetries: Int = 1
    ) {
        self.vehicleID = vehicleID
        self.sender = sender
        self.wakeRetryDelay = wakeRetryDelay
        self.maxWakeRetries = maxWakeRetries
        // Seed identical to the simulated executor so a switch to a not-yet-known
        // control state renders the same neutral defaults (vehicle-controls.jsx:205-225).
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

    // MARK: Command UX seam

    func uiState(for key: VehicleControlKey) -> VehicleControlUIState {
        uiStates[key] ?? .idle
    }

    func isSupported(_ key: VehicleControlKey) -> Bool {
        // Charge PORT has no §7.9 command — honestly disabled on live rather than
        // faked (MYR-249). Everything else here maps to a real command.
        key != .chargePort
    }

    /// Map the Kit's typed §7.9 failure onto an honest control notice.
    static func notice(for kind: RestError.CommandFailureKind) -> VehicleCommandNotice {
        switch kind {
        case .vehicleAsleep: .waking
        case .keyNotPaired: .pairKey
        case .permissionDenied, .notOwned, .auth: .relink
        case .rateLimited: .cooldown
        case .invalidRequest, .commandFailed, .notFound, .transport, .other: .failed
        }
    }

    // MARK: Backend-backed commands (§7.9)

    func setLocked(_ locked: Bool) async throws {
        await run(.lock, command: locked ? .doorLock : .doorUnlock) { [weak self] in
            self?.controls.locked = locked
        }
    }

    func setClimateOn(_ on: Bool) async throws {
        await run(.climate, command: on ? .autoConditioningStart : .autoConditioningStop) { [weak self] in
            self?.controls.climateOn = on
        }
    }

    func setTargetTemp(_ temp: Int) async throws {
        let clamped = min(82, max(60, temp)) // vehicle-controls.jsx:262,270 (°F)
        await run(.temp, command: .setTemps(driverTempC: Self.celsius(fromFahrenheit: clamped), passengerTempC: nil)) { [weak self] in
            self?.controls.targetTemp = clamped
        }
    }

    func setTrunkOpen(_ open: Bool) async throws {
        // The tile toggles the REAR trunk (the design's single trunk affordance);
        // front-trunk actuation waits on a UI that offers the choice.
        await run(.trunk, command: .actuateTrunk(.rear)) { [weak self] in
            self?.controls.trunkOpen = open
        }
    }

    // MARK: No backend command — local mutation, flagged (see header)

    func setClimateMode(_ mode: VehicleClimateMode) async throws {
        controls.climateMode = mode
    }

    func setFanSpeed(_ speed: Int) async throws {
        controls.fanSpeed = min(10, max(0, speed))
    }

    func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws {
        let clamped = min(3, max(0, level))
        switch seat {
        case .driver: controls.driverSeatHeatLevel = clamped
        case .passenger: controls.passengerSeatHeatLevel = clamped
        }
    }

    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode: VehicleSeatClimateMode) async throws {
        switch seat {
        case .driver:
            controls.driverSeatMode = mode
            controls.driverSeatHeatLevel = 0
        case .passenger:
            controls.passengerSeatMode = mode
            controls.passengerSeatHeatLevel = 0
        }
    }

    func setChargePortOpen(_ open: Bool) async throws {
        // No charge_port command in §7.9. The live tile is disabled
        // (`isSupported(.chargePort) == false`), so this is not reached on live;
        // kept as a safe local mutation for API totality.
        controls.chargePortOpen = open
    }

    func setMediaPlaying(_ playing: Bool) async throws {
        controls.mediaPlaying = playing
    }

    func skipTrack(_ direction: VehicleTrackDirection) async throws {
        switch direction {
        case .previous: controls.trackIndex = (controls.trackIndex + trackCount - 1) % trackCount
        case .next: controls.trackIndex = (controls.trackIndex + 1) % trackCount
        }
        controls.scrubPercent = 0
    }

    func setVolume(_ volume: Double) async throws {
        controls.volume = min(100, max(0, volume))
    }

    func setScrubPercent(_ percent: Double) {
        controls.scrubPercent = min(100, max(0, percent))
    }

    func setPlate(_ plate: String) async throws {
        controls.plate = plate
    }

    // MARK: - Command runner

    /// Fahrenheit → Celsius, rounded to Tesla's 0.5° granularity.
    static func celsius(fromFahrenheit f: Int) -> Double {
        let c = (Double(f) - 32) * 5 / 9
        return (c * 2).rounded() / 2
    }

    /// Send `command`; on ack run `apply` (optimistic state flip) and clear the
    /// control; on error map to an honest notice. Suppresses re-fires while a
    /// command for `key` is already in flight (double-tap suppression).
    private func run(_ key: VehicleControlKey, command: VehicleCommand, apply: @escaping @MainActor () -> Void) async {
        guard uiState(for: key).isPending == false else { return }
        uiStates[key] = VehicleControlUIState(isPending: true, notice: nil)
        await attempt(key, command: command, apply: apply, wakeRetriesLeft: maxWakeRetries)
    }

    private func attempt(
        _ key: VehicleControlKey,
        command: VehicleCommand,
        apply: @MainActor () -> Void,
        wakeRetriesLeft: Int
    ) async {
        do {
            _ = try await sender.sendCommand(command, vehicleID: vehicleID)
            apply()
            uiStates[key] = .idle
        } catch let error as RestError {
            let kind = error.commandFailureKind
            if kind == .vehicleAsleep, wakeRetriesLeft > 0 {
                // Transient — the server already woke+retried; reflect the wake and
                // retry once with backoff (§7.9).
                uiStates[key] = VehicleControlUIState(isPending: true, notice: .waking)
                try? await Task.sleep(for: wakeRetryDelay)
                await attempt(key, command: command, apply: apply, wakeRetriesLeft: wakeRetriesLeft - 1)
                return
            }
            uiStates[key] = VehicleControlUIState(isPending: false, notice: Self.notice(for: kind))
        } catch {
            uiStates[key] = VehicleControlUIState(isPending: false, notice: .failed)
        }
    }
}
