import Foundation
import MyRoboTaxiKit
import Observation

// MARK: - LiveVehicleCommandExecutor (MYR-249 — P11 owner actuation, MYR-181–183)
//
// The live `VehicleCommandExecutor`: every owner control that maps to a real §7.9
// Tesla command routes through the backend command endpoint (via the Kit's
// `VehicleCommandSending`); the few controls with no backend command stay local
// mutations, flagged below. This is the executor `LiveVehicleFleet` now injects in
// place of the simulated one (P11 is ready as of MYR-249; phase 3 added charge
// port, seat climate, and media once backend v186 registered them).
//
// Backend-backed (real command sent, then optimistic state on ack):
//   • lock tile          → door_lock / door_unlock
//   • climate on/off     → auto_conditioning_start / auto_conditioning_stop
//   • set temp ±         → set_temps (driver_temp °C; passenger mirrors)
//   • trunk tile         → actuate_trunk (rear)
//   • charge port tile   → charge_port_door_open / charge_port_door_close (v186;
//                          scope `vehicle_charging_cmds` — a token without it
//                          surfaces `.relinkCharging`)
//   • seat heat/cool     → remote_seat_heater_request (level 0–3) OR
//                          remote_seat_cooler_request (seat_cooler_level 1–4),
//                          chosen by the seat's current mode; the heater/cooler
//                          asymmetry lives in the Kit's seat factories
//   • media play/pause   → media_toggle_playback
//   • media prev/next    → media_prev_track / media_next_track
//   • volume slider      → adjust_volume (0–11; immediate-local + coalesced send —
//                          a continuous slider can't await a round trip per delta,
//                          so it applies at once and best-effort-sends the latest,
//                          with no per-tile spinner/notice surface)
//
// NO backend command in the §7.9 catalog (flagged — kept as a local mutation to
// preserve the control's feel):
//   • climate mode (Auto/Cool/Heat) → no set-mode command
//   • fan speed          → no fan command
//   • media scrub        → no seek-to-position command (local feedback only)
//   • license plate      → not a Tesla command (no plate field, per MYR-168)
//
// UX (per MYR-249 task 3): a tap sets the control PENDING (double-tap suppressed
// by the pending guard); the value flips only once the command is acknowledged
// (optimistic-on-ack — the next telemetry frame remains authoritative); an error
// maps to an honest `VehicleCommandNotice` (charge-port `permission_denied` names
// the charging scope). `vehicle_asleep` (503) keeps the control pending with
// "Waking the car…" and retries once with backoff, reflecting that the server
// itself woke+retried (§7.9).
//
// SAFETY: this type is only ever constructed on the LIVE path (`LiveVehicleFleet`,
// built only for a live `AppMode`); the simulated demo never touches it. Tests
// drive it with a fake `VehicleCommandSending` — never a real token.
@Observable
@MainActor
final class LiveVehicleCommandExecutor: VehicleCommandExecutor {
    private(set) var controls: VehicleControlsSnapshot
    private var uiStates: [VehicleControlKey: VehicleControlUIState] = [:]

    /// The controls whose displayed value is CONFIRMED — i.e. the owner has
    /// commanded them and the car acknowledged (optimistic-on-ack), or they are
    /// local-only settings the owner has touched. Everything else renders as an
    /// honest unknown ("—") rather than the seeded fixture (MYR-228 / MYR-251).
    /// The `VehicleState` contract carries none of these actuator states today
    /// (see `VehicleControlField`), so nothing is confirmed until the owner acts.
    private var knownFields: Set<VehicleControlField> = []

    private let vehicleID: String
    private let sender: any VehicleCommandSending
    /// Backoff before the single `vehicle_asleep` retry (injectable → `.zero` in
    /// tests for determinism; ~2 s in production, matching the §7.9 wake curve).
    private let wakeRetryDelay: Duration
    private let maxWakeRetries: Int
    private let trackCount = 3

    /// One-in-flight coalescer for the volume slider (`adjust_volume`): while a
    /// send is outstanding the newest drag value is stashed and sent when it
    /// settles, so a drag fires the first + last value (not every delta) without
    /// blocking the thumb. Best-effort — a slider has no spinner/notice surface.
    private var volumeSending = false
    private var pendingVolume: Double?

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
        // Seed identical to the simulated executor, but on the live path these
        // values are NEVER displayed until `knownFields` confirms them (MYR-251):
        // they only serve as the optimistic base a command mutates. The UI reads
        // `isKnown(_:)` and shows "—" for every field the owner hasn't yet
        // commanded, so no fixture value ever renders on the live path (MYR-228).
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

    /// MYR-251 — a live control's value is only KNOWN once the owner has
    /// commanded it (optimistic-on-ack) or touched a local-only setting. Until
    /// then the UI shows an honest "—" instead of the seeded placeholder, because
    /// the `VehicleState` contract carries no actuator state today.
    func isKnown(_ field: VehicleControlField) -> Bool {
        knownFields.contains(field)
    }

    // Every keyed control now maps to a real §7.9 command (charge port joined the
    // catalog in v186), so `isSupported` keeps the protocol default (`true`).

    /// Map the Kit's typed §7.9 failure onto an honest control notice. `key` lets
    /// a `permission_denied` on the charge port name the charging scope
    /// specifically (`vehicle_charging_cmds`), which the owner's token may lack.
    static func notice(for kind: RestError.CommandFailureKind, key: VehicleControlKey) -> VehicleCommandNotice {
        switch kind {
        case .vehicleAsleep: .waking
        case .keyNotPaired: .pairKey
        case .permissionDenied: key == .chargePort ? .relinkCharging : .relink
        case .notOwned, .auth: .relink
        case .rateLimited: .cooldown
        case .invalidRequest, .commandFailed, .notFound, .transport, .other: .failed
        }
    }

    // MARK: Backend-backed commands (§7.9)

    func setLocked(_ locked: Bool) async throws {
        await run(.lock, command: locked ? .doorLock : .doorUnlock) { [weak self] in
            self?.controls.locked = locked
            self?.knownFields.insert(.locked)
        }
    }

    func setClimateOn(_ on: Bool) async throws {
        await run(.climate, command: on ? .autoConditioningStart : .autoConditioningStop) { [weak self] in
            self?.controls.climateOn = on
            self?.knownFields.insert(.climateOn)
        }
    }

    func setTargetTemp(_ temp: Int) async throws {
        let clamped = min(82, max(60, temp)) // vehicle-controls.jsx:262,270 (°F)
        await run(.temp, command: .setTemps(driverTempC: Self.celsius(fromFahrenheit: clamped), passengerTempC: nil)) { [weak self] in
            self?.controls.targetTemp = clamped
            self?.knownFields.insert(.targetTemp)
        }
    }

    func setTrunkOpen(_ open: Bool) async throws {
        // The tile toggles the REAR trunk (the design's single trunk affordance);
        // front-trunk actuation waits on a UI that offers the choice.
        await run(.trunk, command: .actuateTrunk(.rear)) { [weak self] in
            self?.controls.trunkOpen = open
            self?.knownFields.insert(.trunkOpen)
        }
    }

    func setChargePortOpen(_ open: Bool) async throws {
        // v186: charge_port_door_open / close. Scope `vehicle_charging_cmds` — a
        // token lacking it surfaces `.relinkCharging` (see `notice(for:key:)`).
        await run(.chargePort, command: open ? .chargePortDoorOpen : .chargePortDoorClose) { [weak self] in
            self?.controls.chargePortOpen = open
            self?.knownFields.insert(.chargePortOpen)
        }
    }

    func setSeatHeatLevel(_ seat: VehicleSeatPosition, level: Int) async throws {
        let clamped = min(3, max(0, level))
        let key = Self.seatKey(seat)
        let side = Self.seatSide(seat)
        // The level squares actuate whichever mode the seat is armed to (the UI's
        // accent follows the mode) — heater for .heat, cooler for .cool. The Kit
        // factories own the seat_position + level-scale (0–3 vs 1–4) mapping.
        let mode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
        let command: VehicleCommand = mode == .cool
            ? .seatCooler(side, uiLevel: clamped)
            : .seatHeater(side, uiLevel: clamped)
        await run(key, command: command) { [weak self] in
            switch seat {
            case .driver:
                self?.controls.driverSeatHeatLevel = clamped
                self?.knownFields.insert(.driverSeat)
            case .passenger:
                self?.controls.passengerSeatHeatLevel = clamped
                self?.knownFields.insert(.passengerSeat)
            }
        }
    }

    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode newMode: VehicleSeatClimateMode) async throws {
        let oldMode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
        let oldLevel = seat == .driver ? controls.driverSeatHeatLevel : controls.passengerSeatHeatLevel
        let apply: @MainActor () -> Void = { [weak self] in
            // vehicle-controls.jsx:90 — switching Heat/Cool resets the level.
            switch seat {
            case .driver:
                self?.controls.driverSeatMode = newMode
                self?.controls.driverSeatHeatLevel = 0
                self?.knownFields.insert(.driverSeat)
            case .passenger:
                self?.controls.passengerSeatMode = newMode
                self?.controls.passengerSeatHeatLevel = 0
                self?.knownFields.insert(.passengerSeat)
            }
        }
        // Nothing was actively heating/cooling → the mode switch is a pure local
        // arm change (no vehicle actuation to make).
        guard oldLevel > 0 else { apply(); return }
        // The design's reset-to-0 means the previously-active element must stop on
        // the car: send the OFF for the OLD mode, then flip mode + level locally.
        let side = Self.seatSide(seat)
        let offCommand: VehicleCommand = oldMode == .cool
            ? .seatCooler(side, uiLevel: 0)
            : .seatHeater(side, uiLevel: 0)
        await run(Self.seatKey(seat), command: offCommand, apply: apply)
    }

    func setMediaPlaying(_ playing: Bool) async throws {
        // media_toggle_playback is a toggle regardless of direction; `playing` is
        // the optimistic target applied on ack.
        await run(.media, command: .mediaTogglePlayback) { [weak self] in
            self?.controls.mediaPlaying = playing
            self?.knownFields.insert(.mediaPlaying)
        }
    }

    func skipTrack(_ direction: VehicleTrackDirection) async throws {
        let command: VehicleCommand = direction == .next ? .mediaNextTrack : .mediaPrevTrack
        await run(.media, command: command) { [weak self] in
            guard let self else { return }
            switch direction {
            case .previous: self.controls.trackIndex = (self.controls.trackIndex + self.trackCount - 1) % self.trackCount
            case .next: self.controls.trackIndex = (self.controls.trackIndex + 1) % self.trackCount
            }
            // The displayed track list is placeholder art (see MediaSection); the
            // real command skips the car's track while the UI cycles optimistically.
            self.controls.scrubPercent = 0
        }
    }

    func setVolume(_ volume: Double) async throws {
        // A continuous slider can't await a round trip per drag delta, so apply
        // immediately (smooth thumb) and best-effort-send the latest value with a
        // one-in-flight coalescer. adjust_volume takes 0–11; the UI is 0–100.
        let clamped = min(100, max(0, volume))
        controls.volume = clamped
        knownFields.insert(.volume)
        sendVolume(clamped)
    }

    func setScrubPercent(_ percent: Double) {
        // No seek-to-position command in §7.9 — local feedback only (flagged).
        controls.scrubPercent = min(100, max(0, percent))
    }

    // MARK: No backend command — local mutation, flagged (see header)

    func setClimateMode(_ mode: VehicleClimateMode) async throws {
        controls.climateMode = mode
    }

    func setFanSpeed(_ speed: Int) async throws {
        // No §7.9 fan command and no wire field — a local-only setting. Touching
        // it confirms the owner's chosen value, so it becomes known (MYR-251).
        controls.fanSpeed = min(10, max(0, speed))
        knownFields.insert(.fanSpeed)
    }

    func setPlate(_ plate: String) async throws {
        controls.plate = plate
    }

    // MARK: - Seat helpers

    private static func seatKey(_ seat: VehicleSeatPosition) -> VehicleControlKey {
        seat == .driver ? .driverSeat : .passengerSeat
    }

    private static func seatSide(_ seat: VehicleSeatPosition) -> VehicleCommand.SeatSide {
        seat == .driver ? .driver : .passenger
    }

    // MARK: - Volume coalescer (best-effort adjust_volume)

    /// Send `uiVolume` (0–100) as `adjust_volume` (0–11), coalescing to one send
    /// in flight — a queued newer value replaces an older one and is sent when the
    /// current send settles. Errors are swallowed (the slider has no error surface).
    private func sendVolume(_ uiVolume: Double) {
        guard !volumeSending else { pendingVolume = uiVolume; return }
        volumeSending = true
        let wire = uiVolume / 100 * 11
        let sender = self.sender
        let vehicleID = self.vehicleID
        Task { @MainActor [weak self] in
            _ = try? await sender.sendCommand(.adjustVolume(volume: wire), vehicleID: vehicleID)
            guard let self else { return }
            self.volumeSending = false
            if let next = self.pendingVolume {
                self.pendingVolume = nil
                self.sendVolume(next)
            }
        }
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
            uiStates[key] = VehicleControlUIState(isPending: false, notice: Self.notice(for: kind, key: key))
        } catch {
            uiStates[key] = VehicleControlUIState(isPending: false, notice: .failed)
        }
    }
}
