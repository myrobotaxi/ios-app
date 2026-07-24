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
        maxWakeRetries: Int = 1
    ) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: sender,
            driving: driving,
            plate: "VIN ····0001",
            wakeRetryDelay: .zero,
            maxWakeRetries: maxWakeRetries
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

        // climate mode + fan speed have no §7.9 command; scrub has no seek command.
        try? await exec.setClimateMode(.cool)
        try? await exec.setFanSpeed(7)
        exec.setScrubPercent(55)

        XCTAssertEqual(exec.controls.climateMode, .cool)
        XCTAssertEqual(exec.controls.fanSpeed, 7)
        XCTAssertEqual(exec.controls.scrubPercent, 55)
        XCTAssertTrue(sender.calls.isEmpty, "no §7.9 command exists for these controls")
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
