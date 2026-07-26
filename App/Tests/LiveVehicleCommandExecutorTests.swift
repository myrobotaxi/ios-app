import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-249 — live command executor (fake REST layer, no network, no real token)
//
// Covers: control action → §7.9 command + optimistic-on-ack apply; the §7.9
// error catalog → honest UX notice; double-tap suppression; the vehicle_asleep
// retry; the honest charge-port disable; and Fahrenheit→Celsius for set_temps.
@MainActor
final class LiveVehicleCommandExecutorTests: XCTestCase {

    private func makeExecutor(
        _ sender: any VehicleCommandSending,
        driving: Bool = false,
        maxWakeRetries: Int = 1,
        settleWindow: TimeInterval = 15
    ) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: sender,
            driving: driving,
            plate: "VIN ····0001",
            wakeRetryDelay: .zero,
            maxWakeRetries: maxWakeRetries,
            settleWindow: settleWindow
        )
    }

    private static func restError(_ code: String, _ status: Int) -> RestError {
        .http(status: status, code: ErrorPayload.Code(rawValue: code), message: nil, subCode: nil)
    }

    // MARK: control action → command + optimistic apply

    func testActionMapsToCommandAndAppliesOnAck() async {
        struct Case {
            let action: (LiveVehicleCommandExecutor) async -> Void
            let expected: VehicleCommand
            let verify: (LiveVehicleCommandExecutor) -> Bool
            let key: VehicleControlKey
            let line: UInt
            init(
                _ expected: VehicleCommand,
                key: VehicleControlKey,
                line: UInt = #line,
                action: @escaping (LiveVehicleCommandExecutor) async -> Void,
                verify: @escaping (LiveVehicleCommandExecutor) -> Bool
            ) {
                self.expected = expected; self.key = key; self.line = line
                self.action = action; self.verify = verify
            }
        }
        let cases: [Case] = [
            Case(.doorUnlock, key: .lock, action: { try? await $0.setLocked(false) }, verify: { $0.controls.locked == false }),
            Case(.doorLock, key: .lock, action: { try? await $0.setLocked(true) }, verify: { $0.controls.locked == true }),
            Case(.autoConditioningStop, key: .climate, action: { try? await $0.setClimateOn(false) }, verify: { $0.controls.climateOn == false }),
            Case(.autoConditioningStart, key: .climate, action: { try? await $0.setClimateOn(true) }, verify: { $0.controls.climateOn == true }),
            Case(.setTemps(driverTempC: 22.0, passengerTempC: nil), key: .temp, action: { try? await $0.setTargetTemp(72) }, verify: { $0.controls.targetTemp == 72 }),
            Case(.actuateTrunk(.rear), key: .trunk, action: { try? await $0.setTrunkOpen(true) }, verify: { $0.controls.trunkOpen == true }),
            // MYR-249 phase 3 (v186).
            Case(.chargePortDoorOpen, key: .chargePort, action: { try? await $0.setChargePortOpen(true) }, verify: { $0.controls.chargePortOpen == true }),
            Case(.chargePortDoorClose, key: .chargePort, action: { try? await $0.setChargePortOpen(false) }, verify: { $0.controls.chargePortOpen == false }),
            // Driver seat seeds mode .heat → the heater command (seat_position 0, level pass-through).
            Case(.remoteSeatHeaterRequest(seatPosition: 0, level: 3), key: .driverSeat, action: { try? await $0.setSeatHeatLevel(.driver, level: 3) }, verify: { $0.controls.driverSeatHeatLevel == 3 }),
            Case(.mediaTogglePlayback, key: .media, action: { try? await $0.setMediaPlaying(true) }, verify: { $0.controls.mediaPlaying == true }),
            Case(.mediaNextTrack, key: .media, action: { try? await $0.skipTrack(.next) }, verify: { $0.controls.trackIndex == 1 }),
            Case(.mediaPrevTrack, key: .media, action: { try? await $0.skipTrack(.previous) }, verify: { $0.controls.trackIndex == 2 }),
        ]
        for c in cases {
            let sender = ScriptedCommandSender()
            let exec = makeExecutor(sender)
            await c.action(exec)
            XCTAssertEqual(sender.calls, [c.expected], "command for key \(c.key)", line: c.line)
            XCTAssertTrue(c.verify(exec), "optimistic apply for key \(c.key)", line: c.line)
            XCTAssertEqual(exec.uiState(for: c.key), .idle, "settled idle for key \(c.key)", line: c.line)
        }
    }

    // MARK: error code → UX notice, value unchanged

    func testErrorCodeMapsToNoticeAndLeavesValueUnchanged() async {
        struct Case {
            let code: String
            let status: Int
            let notice: VehicleCommandNotice
            let line: UInt
            init(_ code: String, _ status: Int, _ notice: VehicleCommandNotice, line: UInt = #line) {
                self.code = code; self.status = status; self.notice = notice; self.line = line
            }
        }
        let cases: [Case] = [
            Case("key_not_paired", 403, .pairKey),
            Case("permission_denied", 403, .relink),
            Case("vehicle_not_owned", 403, .relink),
            Case("auth_failed", 401, .relink),
            Case("rate_limited", 429, .cooldown),
            Case("command_failed", 502, .failed),
            Case("invalid_request", 400, .failed),
            Case("not_found", 404, .failed),
            Case("vehicle_asleep", 503, .waking),
        ]
        for c in cases {
            let sender = ScriptedCommandSender([.failure(Self.restError(c.code, c.status))])
            // maxWakeRetries 0 so vehicle_asleep surfaces immediately (no retry) here.
            let exec = makeExecutor(sender, maxWakeRetries: 0)
            try? await exec.setLocked(false) // locked starts true

            XCTAssertEqual(exec.uiState(for: .lock).notice, c.notice, "notice for \(c.code)", line: c.line)
            XCTAssertFalse(exec.uiState(for: .lock).isPending, "not pending after settle for \(c.code)", line: c.line)
            XCTAssertTrue(exec.controls.locked, "value unchanged on failure for \(c.code)", line: c.line)
        }
    }

    // MARK: vehicle_asleep — retry once, then apply

    func testVehicleAsleepRetriesOnceThenApplies() async {
        let sender = ScriptedCommandSender([.failure(Self.restError("vehicle_asleep", 503)), .success(Self.ok("door_unlock"))])
        let exec = makeExecutor(sender, maxWakeRetries: 1)

        try? await exec.setLocked(false)

        XCTAssertEqual(sender.calls.count, 2, "one wake retry")
        XCTAssertFalse(exec.controls.locked, "applied on the retry ack")
        XCTAssertEqual(exec.uiState(for: .lock), .idle)
    }

    func testVehicleAsleepExhaustedSurfacesWaking() async {
        let sender = ScriptedCommandSender([
            .failure(Self.restError("vehicle_asleep", 503)),
            .failure(Self.restError("vehicle_asleep", 503)),
        ])
        let exec = makeExecutor(sender, maxWakeRetries: 1)

        try? await exec.setLocked(false)

        XCTAssertEqual(sender.calls.count, 2)
        XCTAssertEqual(exec.uiState(for: .lock).notice, .waking)
        XCTAssertFalse(exec.uiState(for: .lock).isPending)
        XCTAssertTrue(exec.controls.locked, "not applied while still asleep")
    }

    // MARK: double-tap suppression

    func testDoubleTapWhilePendingIsSuppressed() async {
        let sender = GatedCommandSender()
        let exec = makeExecutor(sender)

        let first = Task { try? await exec.setLocked(false) }
        // Let the first command reach the gate (pending set before its send suspends).
        await eventually { exec.uiState(for: .lock).isPending }

        // A second tap while pending must NOT fire a second command.
        try? await exec.setLocked(false)
        XCTAssertEqual(sender.callCount(), 1, "second tap suppressed while pending")

        sender.release()
        await first.value
        XCTAssertFalse(exec.uiState(for: .lock).isPending)
        XCTAssertFalse(exec.controls.locked)
    }

    // MARK: MYR-251 — honest unknown state until the owner commands a control

    func testFreshExecutorKnowsNothing() {
        let exec = makeExecutor(ScriptedCommandSender())
        for field in VehicleControlField.allCases {
            XCTAssertFalse(exec.isKnown(field), "\(field) must be unknown before any command (no wire field, MYR-228)")
        }
    }

    func testSuccessfulCommandMakesOnlyThatFieldKnown() async {
        struct Case {
            let field: VehicleControlField
            let action: (LiveVehicleCommandExecutor) async -> Void
            let line: UInt
            init(_ field: VehicleControlField, line: UInt = #line, _ action: @escaping (LiveVehicleCommandExecutor) async -> Void) {
                self.field = field; self.action = action; self.line = line
            }
        }
        let cases: [Case] = [
            Case(.locked) { try? await $0.setLocked(false) },
            Case(.climateOn) { try? await $0.setClimateOn(true) },
            Case(.targetTemp) { try? await $0.setTargetTemp(72) },
            Case(.trunkOpen) { try? await $0.setTrunkOpen(true) },
            Case(.chargePortOpen) { try? await $0.setChargePortOpen(true) },
            Case(.driverSeat) { try? await $0.setSeatHeatLevel(.driver, level: 2) },
            Case(.passengerSeat) { try? await $0.setSeatHeatLevel(.passenger, level: 1) },
            Case(.mediaPlaying) { try? await $0.setMediaPlaying(true) },
            Case(.fanSpeed) { try? await $0.setFanSpeed(5) },
            Case(.volume) { try? await $0.setVolume(30) },
        ]
        for c in cases {
            let exec = makeExecutor(ScriptedCommandSender())
            await c.action(exec)
            XCTAssertTrue(exec.isKnown(c.field), "\(c.field) known after its command", line: c.line)
            for other in VehicleControlField.allCases where other != c.field {
                // volume + fan are independent local settings; a seat command
                // confirms only its own seat — no field leaks known-ness.
                XCTAssertFalse(exec.isKnown(other), "\(other) must stay unknown after only \(c.field) was commanded", line: c.line)
            }
        }
    }

    func testFailedCommandLeavesFieldUnknown() async {
        let sender = ScriptedCommandSender([.failure(Self.restError("command_failed", 502))])
        let exec = makeExecutor(sender, maxWakeRetries: 0)

        try? await exec.setLocked(false)

        XCTAssertFalse(exec.isKnown(.locked), "a failed command must NOT confirm the value — stays unknown")
        XCTAssertEqual(exec.uiState(for: .lock).notice, .failed)
    }

    // MARK: capability — every keyed control is backend-backed now (charge port joined v186)

    func testAllKeyedControlsSupported() {
        let exec = makeExecutor(ScriptedCommandSender())
        for key in [VehicleControlKey.lock, .climate, .temp, .trunk, .chargePort, .driverSeat, .passengerSeat, .media] {
            XCTAssertTrue(exec.isSupported(key), "\(key) should be backend-backed")
        }
    }

    // MARK: no-backend controls — still a local mutation, no command sent

    func testNoBackendControlsMutateLocallyWithoutSending() async {
        let sender = ScriptedCommandSender()
        let exec = makeExecutor(sender)

        // fan speed has no §7.9 command; scrub has no seek command.
        try? await exec.setFanSpeed(7)
        exec.setScrubPercent(55)

        XCTAssertEqual(exec.controls.fanSpeed, 7)
        XCTAssertEqual(exec.controls.scrubPercent, 55)
        XCTAssertTrue(sender.calls.isEmpty, "no §7.9 command exists for these controls")
    }

    // MARK: - MYR-274 — climate Auto/Cool/Heat: Auto real, Cool/Heat reflect state

    /// Tapping Auto sends the real `auto_conditioning_start`, optimistically shows
    /// Auto on ack, and marks the mode field known.
    func testClimateAutoSendsAutoConditioningStartAndBecomesKnown() async {
        let sender = ScriptedCommandSender()
        let exec = makeExecutor(sender)

        try? await exec.setClimateMode(.auto)

        XCTAssertEqual(sender.calls, [.autoConditioningStart], "Auto sends the real auto-conditioning command")
        XCTAssertEqual(exec.controls.climateMode, .auto, "optimistic Auto applied on ack")
        XCTAssertTrue(exec.isKnown(.climateMode), "Auto command confirms the mode field")
        // auto_conditioning_start turns the HVAC on → the on/off tile moves in lockstep.
        XCTAssertTrue(exec.controls.climateOn, "Auto optimistically turns climate on")
        XCTAssertTrue(exec.isKnown(.climateOn), "Auto command confirms the climate-on field")
        XCTAssertEqual(exec.uiState(for: .climate), .idle)
    }

    /// Cool/Heat have NO Tesla set-mode command — a tap must send NOTHING and mutate
    /// NOTHING (honest display-only). The mode also stays unknown (no command, no
    /// reconcile), so the segment lights nothing rather than a fabricated Cool/Heat.
    func testClimateCoolAndHeatSendNothingAndStayUnknown() async {
        for mode in [VehicleClimateMode.cool, .heat] {
            let sender = ScriptedCommandSender()
            let exec = makeExecutor(sender)

            try? await exec.setClimateMode(mode)

            XCTAssertTrue(sender.calls.isEmpty, "\(mode) is non-commanding — no §7.9 command exists")
            XCTAssertFalse(exec.isKnown(.climateMode), "\(mode) tap must not fabricate a known mode")
        }
    }

    /// Honest-unknown: the mode field is unknown before any reconcile or command,
    /// so the segment shows nothing lit rather than the seeded `.auto`.
    func testClimateModeUnknownBeforeAnyReconcileOrCommand() {
        let exec = makeExecutor(ScriptedCommandSender())
        XCTAssertFalse(exec.isKnown(.climateMode), "mode honest-unknown until reconciled or Auto commanded")
    }

    /// Reconcile folds the car's real mode honestly: On → Auto (known); Override +
    /// AC → Cool; Override + no AC → Heat; an absent mode stays unknown.
    func testClimateModeReconcileFoldsRealModeAndAbsentStaysUnknown() {
        // On → Auto
        let onExec = makeExecutor(ScriptedCommandSender())
        var on = Contracts.parkedState(); on.hvacAutoMode = .on
        onExec.reconcile(from: on)
        XCTAssertTrue(onExec.isKnown(.climateMode)); XCTAssertEqual(onExec.controls.climateMode, .auto)

        // Override + AC on → Cool
        let coolExec = makeExecutor(ScriptedCommandSender())
        var cool = Contracts.parkedState(); cool.hvacAutoMode = .override; cool.hvacAcEnabled = true
        coolExec.reconcile(from: cool)
        XCTAssertTrue(coolExec.isKnown(.climateMode)); XCTAssertEqual(coolExec.controls.climateMode, .cool)

        // Override + AC off → Heat
        let heatExec = makeExecutor(ScriptedCommandSender())
        var heat = Contracts.parkedState(); heat.hvacAutoMode = .override; heat.hvacAcEnabled = false
        heatExec.reconcile(from: heat)
        XCTAssertTrue(heatExec.isKnown(.climateMode)); XCTAssertEqual(heatExec.controls.climateMode, .heat)

        // Absent → stays unknown (never fabricated)
        let absentExec = makeExecutor(ScriptedCommandSender())
        absentExec.reconcile(from: Contracts.parkedState())
        XCTAssertFalse(absentExec.isKnown(.climateMode), "absent mode stays honestly unknown")
    }

    /// Settle window: after Auto acks, a STALE `Override` frame that still reports
    /// manual must NOT flip the segment off Auto — until the car confirms On or the
    /// window lapses (the MYR-272 clobber fix, extended to the mode segment).
    func testClimateAutoSurvivesStaleOverrideFrameThenConfirms() async {
        let exec = makeExecutor(ScriptedCommandSender())
        try? await exec.setClimateMode(.auto)
        XCTAssertEqual(exec.controls.climateMode, .auto, "optimistic Auto applied on ack")

        // The car keeps streaming a manual Override right after the ack.
        var stale = Contracts.parkedState(); stale.hvacAutoMode = .override; stale.hvacAcEnabled = true
        exec.reconcile(from: stale)
        XCTAssertEqual(exec.controls.climateMode, .auto, "stale Override ignored within the settle window")

        // The car finally reflects On — confirmation clears the hold.
        var confirm = Contracts.parkedState(); confirm.hvacAutoMode = .on
        exec.reconcile(from: confirm)
        XCTAssertEqual(exec.controls.climateMode, .auto)

        // Hold cleared → a later GENUINE external switch to manual is honored.
        exec.reconcile(from: stale)
        XCTAssertEqual(exec.controls.climateMode, .cool, "after confirmation the live stream drives the segment")
    }

    /// Honest revert: if the car NEVER confirms Auto, after the settle window lapses
    /// the live stream's (contradicting) mode wins — the app doesn't lie forever.
    func testClimateModeRevertsToRealityAfterSettleWindow() async {
        let exec = makeExecutor(ScriptedCommandSender(), settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)
        XCTAssertEqual(exec.controls.climateMode, .auto)

        var override = Contracts.parkedState(); override.hvacAutoMode = .override; override.hvacAcEnabled = false
        exec.reconcile(from: override)
        XCTAssertEqual(exec.controls.climateMode, .auto, "held within the window")

        try? await Task.sleep(for: .milliseconds(80))
        exec.reconcile(from: override)
        XCTAssertEqual(exec.controls.climateMode, .heat, "after the window, the car's reported mode wins (honest)")
    }

    // MARK: seat cooler — cool mode routes to remote_seat_cooler_request (1–4 scale)

    func testSeatCoolerUsesCoolerCommandWithAsymmetricLevel() async {
        let sender = ScriptedCommandSender()
        let exec = makeExecutor(sender)

        // Driver seeds mode .heat level 2 → switch to cool first. That switch sends
        // the heater OFF (level 0) for the previously-active heat, then arms cool@0.
        try? await exec.setSeatClimateMode(.driver, mode: .cool)
        XCTAssertEqual(sender.calls, [.remoteSeatHeaterRequest(seatPosition: 0, level: 0)], "mode switch stops the old heat")
        XCTAssertEqual(exec.controls.driverSeatMode, .cool)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 0)

        // Now a cool level: UI 3 → cooler seat_cooler_level 4 (asymmetric), seat_position 1.
        try? await exec.setSeatHeatLevel(.driver, level: 3)
        XCTAssertEqual(sender.calls.last, .remoteSeatCoolerRequest(seatPosition: 1, seatCoolerLevel: 4))
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3)
    }

    // MARK: seat mode switch with nothing running — pure local, no command

    func testSeatModeSwitchWhenOffSendsNothing() async {
        let sender = ScriptedCommandSender()
        let exec = makeExecutor(sender)

        // Passenger seeds level 0 (off) → switching mode actuates nothing.
        try? await exec.setSeatClimateMode(.passenger, mode: .cool)
        XCTAssertTrue(sender.calls.isEmpty, "off seat needs no command on a mode switch")
        XCTAssertEqual(exec.controls.passengerSeatMode, .cool)
        XCTAssertEqual(exec.controls.passengerSeatHeatLevel, 0)
    }

    // MARK: charge-port permission_denied → the charging-specific re-link copy

    func testChargePortPermissionDeniedNamesChargingScope() async {
        let sender = ScriptedCommandSender([.failure(Self.restError("permission_denied", 403))])
        let exec = makeExecutor(sender)

        try? await exec.setChargePortOpen(true)

        XCTAssertEqual(exec.uiState(for: .chargePort).notice, .relinkCharging)
        XCTAssertFalse(exec.controls.chargePortOpen, "value unchanged on failure")
    }

    // MARK: volume — adjust_volume (0–11), immediate local apply, best-effort send

    func testVolumeAppliesLocallyAndSendsScaledAdjustVolume() async {
        let sender = ScriptedCommandSender()
        let exec = makeExecutor(sender)

        try? await exec.setVolume(100) // UI 0–100 → wire 0–11
        XCTAssertEqual(exec.controls.volume, 100, "slider applies immediately")
        await eventually { sender.calls.contains(.adjustVolume(volume: 11)) }
    }

    // MARK: - MYR-252 — telemetry reconciliation of the v0.12.0 cabin read-back

    /// A snapshot carrying the cabin fields flips each present control to
    /// known + the car's real value.
    func testReconcilePresentFieldsBecomeKnownAndCorrect() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState()
        state.locked = true
        state.hvacPower = .on
        state.isClimateOn = true
        state.driverTempSetting = 68
        state.fanSpeed = 4
        state.chargePortDoorOpen = false
        state.trunkOpen = true
        state.seatHeaterLeft = 2
        state.seatCoolerLeft = 0
        state.mediaPlaybackStatus = .playing
        state.mediaVolume = 5.5 // wire 0–11 → UI 50

        exec.reconcile(from: state)

        XCTAssertTrue(exec.isKnown(.locked)); XCTAssertTrue(exec.controls.locked)
        XCTAssertTrue(exec.isKnown(.climateOn)); XCTAssertTrue(exec.controls.climateOn)
        XCTAssertTrue(exec.isKnown(.targetTemp)); XCTAssertEqual(exec.controls.targetTemp, 68)
        XCTAssertTrue(exec.isKnown(.fanSpeed)); XCTAssertEqual(exec.controls.fanSpeed, 4)
        XCTAssertTrue(exec.isKnown(.chargePortOpen)); XCTAssertFalse(exec.controls.chargePortOpen)
        XCTAssertTrue(exec.isKnown(.trunkOpen)); XCTAssertTrue(exec.controls.trunkOpen)
        XCTAssertTrue(exec.isKnown(.driverSeat))
        XCTAssertEqual(exec.controls.driverSeatMode, .heat)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 2)
        XCTAssertTrue(exec.isKnown(.mediaPlaying)); XCTAssertTrue(exec.controls.mediaPlaying)
        XCTAssertTrue(exec.isKnown(.volume)); XCTAssertEqual(exec.controls.volume, 50, accuracy: 0.001)
    }

    /// Settle window: after a command acks, a STALE streamed frame that still
    /// reports the OLD state must NOT revert the optimistic value — until the car
    /// confirms (agrees) or the window lapses (MYR-272 clobber fix). The client
    /// turned climate off; it loaded, then a stale on-frame flipped it back to On.
    func testCommandOffSurvivesStaleOnFrameThenConfirms() async {
        let exec = makeExecutor(ScriptedCommandSender())
        try? await exec.setClimateOn(false)
        XCTAssertFalse(exec.controls.climateOn, "optimistic off applied on ack")

        // The car (in service) keeps streaming ON right after the ack.
        var stale = Contracts.parkedState(); stale.isClimateOn = true
        exec.reconcile(from: stale)
        XCTAssertFalse(exec.controls.climateOn, "stale on-frame ignored within the settle window")

        // The car finally reflects the off — confirmation clears the hold.
        var confirm = Contracts.parkedState(); confirm.isClimateOn = false
        exec.reconcile(from: confirm)
        XCTAssertFalse(exec.controls.climateOn)

        // Hold cleared → a later GENUINE external ON is honored again.
        exec.reconcile(from: stale)
        XCTAssertTrue(exec.controls.climateOn, "after confirmation the live stream drives the tile")
    }

    /// Honest revert: if the car NEVER confirms the commanded value, after the
    /// settle window lapses the live stream's (contradicting) reality wins — the
    /// app doesn't lie indefinitely (e.g. a service center keeping HVAC on).
    func testCommandRevertsToRealityAfterSettleWindow() async {
        let exec = makeExecutor(ScriptedCommandSender(), settleWindow: 0.05)
        try? await exec.setClimateOn(false)
        XCTAssertFalse(exec.controls.climateOn)

        // Stale on-frame within the (tiny) window is still held.
        var on = Contracts.parkedState(); on.isClimateOn = true
        exec.reconcile(from: on)
        XCTAssertFalse(exec.controls.climateOn, "held within the window")

        // Let the window lapse; the next contradicting frame is now authoritative.
        try? await Task.sleep(for: .milliseconds(80))
        exec.reconcile(from: on)
        XCTAssertTrue(exec.controls.climateOn, "after the window, the car's reported reality wins (honest)")
    }

    /// A field ABSENT from the wire stays honestly unknown — never a fixture (MYR-228).
    func testReconcileAbsentFieldsStayUnknown() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState() // every cabin field nil…
        state.locked = true                 // …except lock
        exec.reconcile(from: state)

        XCTAssertTrue(exec.isKnown(.locked))
        for field in VehicleControlField.allCases where field != .locked {
            XCTAssertFalse(exec.isKnown(field), "\(field) absent on the wire must stay unknown")
        }
    }

    /// The isClimateOn honesty fix: the backend OMITS `isClimateOn` when
    /// `hvacPower` is "Unknown", so climate must stay honestly unknown — the raw
    /// hvacPower "Unknown" must NEVER read as climate-on (MYR-251/252).
    func testHvacPowerUnknownDoesNotReadAsClimateOn() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState()
        state.hvacPower = .unknown
        state.isClimateOn = nil // omitted by the server
        exec.reconcile(from: state)

        XCTAssertFalse(exec.isKnown(.climateOn), "hvacPower Unknown → climate honest-unknown, not on")
    }

    /// Real telemetry is authoritative for a control with NO in-flight command or
    /// settle hold — a live frame drives the tile (the correcting-a-command case is
    /// the settle-window test above, where a DISAGREEING frame is held briefly).
    func testTelemetryReconcileDrivesUncommandedControl() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState()
        state.locked = false // the car reports unlocked; the user never commanded lock
        exec.reconcile(from: state)
        XCTAssertTrue(exec.isKnown(.locked))
        XCTAssertFalse(exec.controls.locked, "telemetry drives an uncommanded control")

        var relock = Contracts.parkedState()
        relock.locked = true
        exec.reconcile(from: relock)
        XCTAssertTrue(exec.controls.locked, "a later live frame updates it again")
    }

    /// A frame arriving while a control's command is in flight must not clobber the
    /// pending interaction — the field stays unconfirmed until the ack.
    func testReconcileSkipsControlWithCommandInFlight() async {
        let sender = GatedCommandSender()
        let exec = makeExecutor(sender)
        let task = Task { try? await exec.setLocked(false) }
        await eventually { exec.uiState(for: .lock).isPending }

        var state = Contracts.parkedState()
        state.locked = false
        exec.reconcile(from: state)
        XCTAssertFalse(exec.isKnown(.locked), "reconcile skipped while the lock command is in flight")

        sender.release()
        await task.value
        XCTAssertTrue(exec.isKnown(.locked), "confirmed once the command settles")
        XCTAssertFalse(exec.controls.locked)
    }

    // MARK: MYR-280 — seat heat↔cool settle window (stale WS frame must not clobber)

    /// After a seat heat-level command acks, a STALE streamed frame reporting the
    /// OLD level must NOT revert the optimistic seat state — until the car confirms
    /// or the window lapses (the MYR-272 discipline, extended to seats).
    func testSeatLevelSurvivesStaleFrameThenConfirms() async {
        let exec = makeExecutor(ScriptedCommandSender())
        // Driver seeds .heat level 2 → command a new level 3.
        try? await exec.setSeatHeatLevel(.driver, level: 3)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3, "optimistic level applied on ack")

        // The car keeps streaming the OLD level 2 right after the ack.
        var stale = Contracts.parkedState(); stale.seatHeaterLeft = 2; stale.seatCoolerLeft = 0
        exec.reconcile(from: stale)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3, "stale seat frame ignored within the settle window")
        XCTAssertEqual(exec.controls.driverSeatMode, .heat)

        // The car finally reflects level 3 — confirmation clears the hold.
        var confirm = Contracts.parkedState(); confirm.seatHeaterLeft = 3; confirm.seatCoolerLeft = 0
        exec.reconcile(from: confirm)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3)

        // Hold cleared → a later GENUINE external change is honored again.
        exec.reconcile(from: stale)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 2, "after confirmation the live stream drives the seat")
    }

    /// Switching a seat heat→cool holds the optimistic cool arm against a stale
    /// HEATER read-back that arrives right after the switch, AND — critically — the
    /// arm survives once the settle window lapses. An OFF seat streams
    /// heater=0/cooler=0 identically for heat-off and cool-off, so the reconciler
    /// must PRESERVE the armed mode rather than default to heat; otherwise a seat
    /// the owner switched to Cool-but-off silently reverts to Heat (MYR-280 review).
    func testSeatModeSwitchSurvivesStaleHeaterFrame() async {
        let exec = makeExecutor(ScriptedCommandSender(), settleWindow: 0.05)
        // Driver seeds .heat level 2 → switch to cool (sends heater OFF, arms cool@0).
        try? await exec.setSeatClimateMode(.driver, mode: .cool)
        XCTAssertEqual(exec.controls.driverSeatMode, .cool)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 0)

        // A stale frame still reporting the old heater level 2 must not flip it back.
        var stale = Contracts.parkedState(); stale.seatHeaterLeft = 2; stale.seatCoolerLeft = 0
        exec.reconcile(from: stale)
        XCTAssertEqual(exec.controls.driverSeatMode, .cool, "stale heater frame ignored — seat stays armed cool")
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 0)

        // The car reports the seat OFF (heater 0 / cooler 0) — this CONFIRMS the
        // armed (.cool, 0) state (the wire can't say heat-off vs cool-off), clearing
        // the hold without reverting the mode.
        var off = Contracts.parkedState(); off.seatHeaterLeft = 0; off.seatCoolerLeft = 0
        exec.reconcile(from: off)
        XCTAssertEqual(exec.controls.driverSeatMode, .cool, "all-zero frame confirms the cool arm, not a heat revert")

        // And AFTER the settle window lapses, a further off frame must STILL keep the
        // owner's Cool selection — the pre-fix bug flipped this to .heat here.
        try? await Task.sleep(for: .milliseconds(80))
        exec.reconcile(from: off)
        XCTAssertEqual(exec.controls.driverSeatMode, .cool, "cool arm preserved past the settle window (no heat revert)")
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 0)
    }

    /// An OFF seat the owner never touched has no armed cool intent — it reconciles
    /// to the default heat/off presentation and does not fabricate a cool state.
    func testUntouchedOffSeatReconcilesToHeatOff() {
        let exec = makeExecutor(ScriptedCommandSender())
        var off = Contracts.parkedState(); off.seatHeaterRight = 0; off.seatCoolerRight = 0
        exec.reconcile(from: off)
        XCTAssertTrue(exec.isKnown(.passengerSeat))
        XCTAssertEqual(exec.controls.passengerSeatMode, .heat, "off + never armed cool → default heat/off")
        XCTAssertEqual(exec.controls.passengerSeatHeatLevel, 0)
    }

    /// Honest revert: if the car NEVER confirms the commanded seat state, after the
    /// window lapses the live stream's contradicting reality wins (MYR-280).
    func testSeatRevertsToRealityAfterSettleWindow() async {
        let exec = makeExecutor(ScriptedCommandSender(), settleWindow: 0.05)
        try? await exec.setSeatHeatLevel(.driver, level: 3)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3)

        var contradicting = Contracts.parkedState(); contradicting.seatHeaterLeft = 1; contradicting.seatCoolerLeft = 0
        exec.reconcile(from: contradicting)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 3, "held within the window")

        try? await Task.sleep(for: .milliseconds(80))
        exec.reconcile(from: contradicting)
        XCTAssertEqual(exec.controls.driverSeatHeatLevel, 1, "after the window, the car's reality wins (honest)")
    }

    /// Active cooling reconciles to cool mode at the reported level.
    func testSeatCoolerReconcilesToCoolMode() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState()
        state.seatHeaterRight = 0
        state.seatCoolerRight = 3
        exec.reconcile(from: state)

        XCTAssertTrue(exec.isKnown(.passengerSeat))
        XCTAssertEqual(exec.controls.passengerSeatMode, .cool)
        XCTAssertEqual(exec.controls.passengerSeatHeatLevel, 3)
    }

    /// Media `Unknown` stays honestly unknown even as volume reconciles.
    func testMediaUnknownStaysUnknownWhileVolumeReconciles() {
        let exec = makeExecutor(ScriptedCommandSender())
        var state = Contracts.parkedState()
        state.mediaPlaybackStatus = .unknown
        state.mediaVolume = 11 // → UI 100
        exec.reconcile(from: state)

        XCTAssertFalse(exec.isKnown(.mediaPlaying), "media Unknown → honest unknown")
        XCTAssertTrue(exec.isKnown(.volume))
        XCTAssertEqual(exec.controls.volume, 100, accuracy: 0.001)
    }

    /// The Auto/Cool/Heat fold is honest: only a known On/Override asserts a mode.
    func testClimateModeFold() {
        XCTAssertEqual(LiveVehicleCommandExecutor.climateMode(autoMode: .on, acEnabled: nil), .auto)
        XCTAssertEqual(LiveVehicleCommandExecutor.climateMode(autoMode: .override, acEnabled: true), .cool)
        XCTAssertEqual(LiveVehicleCommandExecutor.climateMode(autoMode: .override, acEnabled: false), .heat)
        XCTAssertNil(LiveVehicleCommandExecutor.climateMode(autoMode: .unknown, acEnabled: true))
        XCTAssertNil(LiveVehicleCommandExecutor.climateMode(autoMode: nil, acEnabled: true))
    }

    // MARK: Fahrenheit → Celsius

    func testFahrenheitToCelsius() {
        XCTAssertEqual(LiveVehicleCommandExecutor.celsius(fromFahrenheit: 70), 21.0, accuracy: 0.001)
        XCTAssertEqual(LiveVehicleCommandExecutor.celsius(fromFahrenheit: 60), 15.5, accuracy: 0.001)
        XCTAssertEqual(LiveVehicleCommandExecutor.celsius(fromFahrenheit: 72), 22.0, accuracy: 0.001)
        XCTAssertEqual(LiveVehicleCommandExecutor.celsius(fromFahrenheit: 82), 28.0, accuracy: 0.001)
    }

    // MARK: helper

    private static func ok(_ command: String) -> VehicleCommandResult {
        VehicleCommandResult(status: "applied", command: command, vin: nil)
    }

    private func eventually(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition never became true", file: file, line: line)
    }
}

// MARK: - Fakes

/// Records commands and replays a scripted result queue (success by default).
final class ScriptedCommandSender: VehicleCommandSending, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<VehicleCommandResult, any Error>]
    private var _calls: [VehicleCommand] = []

    init(_ results: [Result<VehicleCommandResult, any Error>] = []) { self.results = results }

    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        lock.lock()
        _calls.append(command)
        let result: Result<VehicleCommandResult, any Error> = results.isEmpty
            ? .success(VehicleCommandResult(status: "applied", command: command.name, vin: nil))
            : results.removeFirst()
        lock.unlock()
        return try result.get()
    }

    var calls: [VehicleCommand] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
}

/// Holds the FIRST command inside `sendCommand` until `release()`, so a test can
/// observe the pending state and prove a concurrent second tap is suppressed.
final class GatedCommandSender: VehicleCommandSending, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func sendCommand(_ command: VehicleCommand, vehicleID: String) async throws -> VehicleCommandResult {
        lock.lock(); count += 1; let n = count; lock.unlock()
        if n == 1 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock(); continuation = c; lock.unlock()
            }
        }
        return VehicleCommandResult(status: "applied", command: command.name, vin: nil)
    }

    func release() {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.resume()
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
