import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
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
//   • climate mode: Auto → auto_conditioning_start (returns the car to auto climate,
//                          MYR-274). Cool/Heat are NOT commandable (see below).
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
//   • climate mode Cool/Heat → no set-mode command; Tesla's API cannot FORCE a
//                          manual cool/heat mode, so these segments are honest
//                          DISPLAY-ONLY reflections of the car's reported mode — a
//                          tap sends NOTHING (MYR-274). Only Auto is actionable.
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

    /// Settle-window guard for the commanded boolean toggles (climate/lock/trunk/
    /// charge-port). The in-flight `isPending` guard only protects UNTIL the command
    /// acks — but the car keeps streaming the OLD state for a few seconds AFTER the
    /// ack until it actually reflects the change. Once MYR-272 folds these fields on
    /// every live delta, that stale frame lands ~1s after the ack and clobbers the
    /// optimistic value back (client: "turned climate off, it loaded then showed On
    /// again"). After a command acks we record the COMMANDED value + a deadline;
    /// reconcile ignores a DISAGREEING streamed value for that key until it confirms
    /// (agrees) or the deadline passes (then we accept the car's reported reality —
    /// honest, e.g. a service center keeping HVAC on). Mirrors the volume coalescer.
    private var settleHold: [VehicleControlKey: (want: Bool, until: Date)] = [:]
    private let settleWindow: TimeInterval

    /// Seat-climate settle-window guard (MYR-280), the two-field analogue of
    /// `settleHold`: a seat's committed state is (mode, level), not a bool. After a
    /// seat command acks we record the commanded (mode, level) + a deadline;
    /// `reconcileSeat` ignores a DISAGREEING streamed frame for that seat until the
    /// car confirms it or the deadline lapses — so a stale WS frame (the level the
    /// car streamed a second ago, or a heater read-back arriving after we switched
    /// to cool) can't clobber the optimistic seat state, exactly as MYR-272 fixed
    /// for the boolean toggles.
    private var seatSettleHold: [VehicleControlKey: (mode: VehicleSeatClimateMode, level: Int, until: Date)] = [:]

    /// Climate-mode settle-window guard (MYR-274), the Auto/Cool/Heat-segment
    /// analogue of `settleHold`. Tapping Auto commands `auto_conditioning_start`;
    /// after it acks we optimistically show `.auto` and record it here with a
    /// deadline. `reconcileClimateMode` then ignores a DISAGREEING streamed mode
    /// (a stale `Override` the car keeps reporting for a second or two, or the
    /// mode simply absent) until the car confirms `On`/Auto or the window lapses —
    /// so a stale frame can't immediately flip the segment back off Auto, exactly
    /// as MYR-272 fixed for the boolean toggles.
    private var climateModeSettleHold: (want: VehicleClimateMode, until: Date)?

    init(
        vehicleID: String,
        sender: any VehicleCommandSending,
        driving: Bool,
        plate: String,
        wakeRetryDelay: Duration = .seconds(2),
        maxWakeRetries: Int = 1,
        settleWindow: TimeInterval = 15
    ) {
        self.vehicleID = vehicleID
        self.sender = sender
        self.wakeRetryDelay = wakeRetryDelay
        self.maxWakeRetries = maxWakeRetries
        self.settleWindow = settleWindow
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

    // MARK: Telemetry reconciliation (MYR-252 — v0.12.0 cabin read-back)
    //
    // The v0.12.0 `VehicleState` now carries the owner-actuator state as OPTIONAL
    // fields. Each field PRESENT on the wire reconciles its control to the car's
    // REAL value and marks it KNOWN (`isKnown` → true), so the tile stops showing
    // "—" and shows true state; each field ABSENT stays honestly unknown — never a
    // fixture (MYR-228 / MYR-251). Telemetry is authoritative and OVERRIDES the
    // optimistic-on-ack value a prior command applied (MYR-249): a command ack
    // shows the optimistic state, the next telemetry frame confirms/corrects it.
    // The one exception is a control whose command is still in flight (pending) —
    // its value is left for the ack + next frame so the tile doesn't flicker
    // mid-command.
    //
    // Called on every cold snapshot and every folded delta via the Kit's
    // `LiveVehicleState.onStateChanged` hook (wired in `LiveVehicleFleet`).
    func reconcile(from state: VehicleState) {
        // Climate on/off — use the server-DERIVED `isClimateOn` ONLY. The backend
        // OMITS it (→ nil) when `hvacPower` is "Unknown", so an absent value stays
        // honestly unknown; the raw `hvacPower` "Unknown" must NEVER read as
        // climate-on (MYR-251/252 honesty fix). We deliberately do not consult
        // `state.hvacPower` here.
        if let on = state.isClimateOn {
            reconcileControlled(.climateOn, key: .climate, wire: on) { self.controls.climateOn = $0 }
        }

        if let locked = state.locked {
            reconcileControlled(.locked, key: .lock, wire: locked) { self.controls.locked = $0 }
        }

        // Single target-temp tile mirrors the DRIVER setpoint (matches
        // `setTargetTemp`, which commands `driver_temp`). Passenger setpoint is on
        // the wire (`passengerTempSetting`) but has no separate tile.
        if let temp = state.driverTempSetting {
            reconcileField(.targetTemp, key: .temp) { self.controls.targetTemp = min(82, max(60, temp)) }
        }

        if let fan = state.fanSpeed {
            reconcileField(.fanSpeed, key: nil) { self.controls.fanSpeed = min(10, max(0, fan)) }
        }

        // Climate mode (Auto/Cool/Heat) — reconcile the car's REAL mode onto the
        // segment and mark it known, honoring the in-flight/settle discipline so a
        // stale frame can't clobber a just-commanded Auto (MYR-274).
        reconcileClimateMode(autoMode: state.hvacAutoMode, acEnabled: state.hvacAcEnabled)

        reconcileSeat(.driver, key: .driverSeat, heater: state.seatHeaterLeft, cooler: state.seatCoolerLeft)
        reconcileSeat(.passenger, key: .passengerSeat, heater: state.seatHeaterRight, cooler: state.seatCoolerRight)

        if let trunk = state.trunkOpen {
            reconcileControlled(.trunkOpen, key: .trunk, wire: trunk) { self.controls.trunkOpen = $0 }
        }

        if let port = state.chargePortDoorOpen {
            reconcileControlled(.chargePortOpen, key: .chargePort, wire: port) { self.controls.chargePortOpen = $0 }
        }

        // Media playback — the enum carries an explicit `.unknown`; treat it (and
        // any unrecognized value) as honestly unknown, never a fabricated play/pause.
        if let status = state.mediaPlaybackStatus, let playing = Self.mediaPlaying(from: status) {
            reconcileField(.mediaPlaying, key: .media) { self.controls.mediaPlaying = playing }
        }

        // Media volume — wire 0–11 (fractional) → UI 0–100. Skip while the slider's
        // own coalescer has a send outstanding so a live frame can't yank the thumb
        // out from under a drag.
        if let vol = state.mediaVolume, !volumeSending, pendingVolume == nil {
            reconcileField(.volume, key: .media) { self.controls.volume = min(100, max(0, vol / 11 * 100)) }
        }
    }

    /// Apply a wire value to a control and mark it KNOWN — unless a command for its
    /// `key` is currently in flight (leave the optimistic in-flight value alone; the
    /// ack + next frame reconcile it). `key: nil` for controls with no command
    /// (fan) — always applied.
    private func reconcileField(_ field: VehicleControlField, key: VehicleControlKey?, apply: () -> Void) {
        if let key, uiState(for: key).isPending { return }
        apply()
        knownFields.insert(field)
    }

    /// Like `reconcileField` for a COMMANDED boolean toggle, but also honors the
    /// post-ack settle window: after a command applies, a streamed value that
    /// DISAGREES with what we commanded is ignored until the car confirms (agrees)
    /// or the deadline lapses — so a stale frame can't yank the tile back (the
    /// climate-off revert, MYR-272). Confirmation or timeout clears the hold and the
    /// live stream resumes driving the tile (incl. a genuine external change).
    private func reconcileControlled(
        _ field: VehicleControlField, key: VehicleControlKey, wire: Bool, assign: (Bool) -> Void
    ) {
        if uiState(for: key).isPending { return } // command still in flight
        if let hold = settleHold[key] {
            if wire == hold.want {
                settleHold[key] = nil // the car confirmed the commanded state
            } else if Date() < hold.until {
                return // settling — ignore a stale frame that disagrees with the command
            } else {
                settleHold[key] = nil // timed out — accept the car's reported reality (honest)
            }
        }
        assign(wire)
        knownFields.insert(field)
    }

    /// Reconcile one seat from its heater + cooler read-back levels (both 0–3 on the
    /// wire, matching the UI's level scale). Active cooling (cooler > 0) wins the
    /// mode; else active heating (heater > 0) → heat; else the seat is OFF and the
    /// wire is mode-ambiguous, so the seat's current/armed mode is PRESERVED (never
    /// forced to heat — MYR-280). Absent on both → stays unknown.
    private func reconcileSeat(_ seat: VehicleSeatPosition, key: VehicleControlKey, heater: Int?, cooler: Int?) {
        guard heater != nil || cooler != nil else { return }
        if uiState(for: key).isPending { return } // command still in flight
        let mode: VehicleSeatClimateMode
        let level: Int
        if let cooler, cooler > 0 {
            mode = .cool
            level = min(3, max(0, cooler))
        } else if let heater, heater > 0 {
            mode = .heat
            level = min(3, max(0, heater))
        } else {
            // Seat is OFF (no active heat or cool on the wire). An off seat streams
            // heater=0/cooler=0 IDENTICALLY whether the owner armed it to Heat or
            // Cool — the wire cannot distinguish the two. Defaulting to .heat here
            // silently reverted a seat the owner had just switched to Cool-but-off
            // back to Heat once the settle window lapsed (the MYR-280 "impossible to
            // toggle heated↔cooled" complaint, for the off state). Preserve the
            // seat's current/armed mode instead; a genuine actuation (level > 0)
            // still wins the mode in the branches above. This also lets an all-zero
            // frame CONFIRM a `(.cool, 0)` settle hold instead of disagreeing with it.
            mode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
            level = 0
        }
        // Post-ack settle window (MYR-280): ignore a streamed seat state that
        // DISAGREES with the just-commanded (mode, level) until the car confirms it
        // or the window lapses (then accept the car's reported reality — honest).
        if let hold = seatSettleHold[key] {
            if mode == hold.mode && level == hold.level {
                seatSettleHold[key] = nil // the car confirmed the commanded state
            } else if Date() < hold.until {
                return // settling — ignore a stale frame that disagrees
            } else {
                seatSettleHold[key] = nil // timed out — accept the car's reality
            }
        }
        switch seat {
        case .driver:
            controls.driverSeatMode = mode
            controls.driverSeatHeatLevel = level
            knownFields.insert(.driverSeat)
        case .passenger:
            controls.passengerSeatMode = mode
            controls.passengerSeatHeatLevel = level
            knownFields.insert(.passengerSeat)
        }
    }

    /// Reconcile the car's reported HVAC mode onto the Auto/Cool/Heat segment
    /// (MYR-274). Only a KNOWN `On`/`Override` asserts a mode (and marks the field
    /// known); an `Unknown`/absent frame leaves the segment as-is — it never
    /// fabricates a mode and never downgrades a value already known (honest-unknown
    /// is the INITIAL state, before any command or reconcile). While the Auto
    /// command is in flight the frame is left for the ack; after the ack a settle
    /// window holds the optimistic Auto against a stale `Override` frame until the
    /// car confirms `On`/Auto or the deadline lapses (then the car's reality wins).
    private func reconcileClimateMode(autoMode: VehicleState.HvacAutoMode?, acEnabled: Bool?) {
        guard let mode = Self.climateMode(autoMode: autoMode, acEnabled: acEnabled) else { return }
        if uiState(for: .climate).isPending { return } // Auto command still in flight
        if let hold = climateModeSettleHold {
            if mode == hold.want {
                climateModeSettleHold = nil // the car confirmed the commanded mode
            } else if Date() < hold.until {
                return // settling — ignore a stale frame that disagrees with the command
            } else {
                climateModeSettleHold = nil // timed out — accept the car's reported reality
            }
        }
        controls.climateMode = mode
        knownFields.insert(.climateMode)
    }

    /// Fold the HVAC auto-mode + AC-enabled read-back onto the app's Auto/Cool/Heat
    /// segment. Only a KNOWN auto state asserts a mode: `On` → Auto; `Override`
    /// (manual) → Cool when the AC compressor is on, else Heat. `Unknown`/
    /// unrecognized/absent → nil (leave the last-shown mode untouched — honest).
    static func climateMode(autoMode: VehicleState.HvacAutoMode?, acEnabled: Bool?) -> VehicleClimateMode? {
        switch autoMode {
        case .on: return .auto
        case .override: return (acEnabled == true) ? .cool : .heat
        case .unknown, .unrecognized, .none: return nil
        }
    }

    /// Map the media playback enum onto the play/pause boolean. `Unknown` and any
    /// unrecognized value return nil so the control stays honestly unknown (MYR-251)
    /// rather than asserting a fabricated play/pause.
    static func mediaPlaying(from status: VehicleState.MediaPlaybackStatus) -> Bool? {
        switch status {
        case .playing: return true
        case .paused, .stopped: return false
        case .unknown, .unrecognized: return nil
        }
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
            self?.holdSettle(.lock, want: locked)
        }
    }

    func setClimateOn(_ on: Bool) async throws {
        await run(.climate, command: on ? .autoConditioningStart : .autoConditioningStop) { [weak self] in
            self?.controls.climateOn = on
            self?.knownFields.insert(.climateOn)
            self?.holdSettle(.climate, want: on)
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
            self?.holdSettle(.trunk, want: open)
        }
    }

    func setChargePortOpen(_ open: Bool) async throws {
        // v186: charge_port_door_open / close. Scope `vehicle_charging_cmds` — a
        // token lacking it surfaces `.relinkCharging` (see `notice(for:key:)`).
        await run(.chargePort, command: open ? .chargePortDoorOpen : .chargePortDoorClose) { [weak self] in
            self?.controls.chargePortOpen = open
            self?.knownFields.insert(.chargePortOpen)
            self?.holdSettle(.chargePort, want: open)
        }
    }

    /// Start the post-ack settle window for a commanded toggle (see `settleHold`).
    private func holdSettle(_ key: VehicleControlKey, want: Bool) {
        settleHold[key] = (want: want, until: Date().addingTimeInterval(settleWindow))
    }

    /// Start the post-ack settle window for a commanded seat (see `seatSettleHold`).
    private func holdSeatSettle(_ key: VehicleControlKey, mode: VehicleSeatClimateMode, level: Int) {
        seatSettleHold[key] = (mode: mode, level: level, until: Date().addingTimeInterval(settleWindow))
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
            guard let self else { return }
            switch seat {
            case .driver:
                self.controls.driverSeatHeatLevel = clamped
                self.knownFields.insert(.driverSeat)
            case .passenger:
                self.controls.passengerSeatHeatLevel = clamped
                self.knownFields.insert(.passengerSeat)
            }
            // Hold the optimistic (mode, level) against a stale frame (MYR-280).
            self.holdSeatSettle(key, mode: mode, level: clamped)
        }
    }

    func setSeatClimateMode(_ seat: VehicleSeatPosition, mode newMode: VehicleSeatClimateMode) async throws {
        let oldMode = seat == .driver ? controls.driverSeatMode : controls.passengerSeatMode
        let oldLevel = seat == .driver ? controls.driverSeatHeatLevel : controls.passengerSeatHeatLevel
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // vehicle-controls.jsx:90 — switching Heat/Cool resets the level.
            switch seat {
            case .driver:
                self.controls.driverSeatMode = newMode
                self.controls.driverSeatHeatLevel = 0
                self.knownFields.insert(.driverSeat)
            case .passenger:
                self.controls.passengerSeatMode = newMode
                self.controls.passengerSeatHeatLevel = 0
                self.knownFields.insert(.passengerSeat)
            }
            // Hold the optimistic mode switch against a stale frame (MYR-280) — e.g.
            // the heater level the car streamed just before it stopped for cool.
            self.holdSeatSettle(Self.seatKey(seat), mode: newMode, level: 0)
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

    // MARK: Climate mode — Auto is a real command; Cool/Heat are display-only (MYR-274)

    /// The Auto/Cool/Heat segment. Per the product decision (Thomas, MYR-274) —
    /// "Auto real, Cool/Heat reflect state":
    ///   • **Auto** is the one actionable control: it sends the real Tesla
    ///     `auto_conditioning_start`, returning the car to auto climate, then
    ///     optimistically shows `.auto` on ack with a settle-window hold so a stale
    ///     `Override`/absent frame can't immediately flip it back (MYR-272 discipline).
    ///   • **Cool/Heat** are HONEST DISPLAY-ONLY: Tesla's API has no command to force
    ///     a manual cool/heat mode, so a tap sends NOTHING and mutates NOTHING — the
    ///     segment merely REFLECTS the mode the car reports (`reconcileClimateMode`).
    /// Reuses the `.climate` key so an Auto command shares the pending/settle
    /// discipline of climate on/off (both are HVAC start/stop — never fire two at once).
    func setClimateMode(_ mode: VehicleClimateMode) async throws {
        guard mode == .auto else { return } // Cool/Heat are non-commanding reflections
        await run(.climate, command: .autoConditioningStart) { [weak self] in
            guard let self else { return }
            self.controls.climateMode = .auto
            self.knownFields.insert(.climateMode)
            self.climateModeSettleHold = (want: .auto, until: Date().addingTimeInterval(self.settleWindow))
        }
    }

    // MARK: No backend command — local mutation, flagged (see header)

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
