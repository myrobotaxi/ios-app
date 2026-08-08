import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - MYR-466 — the Auto tap that reverted to manual with nothing said
//
// External beta, build 202608030843, the owner: *"Change the climate to Auto
// mode and it did not register in car or change the mode in the car and then in
// the app it flipped right back to manual mode so it looks like this is not
// working."*
//
// The revert itself is CORRECT — the car really was in manual — so these tests
// are deliberately not about keeping the segment on Auto. They are about the
// SILENCE. Each one fails if the `.notAdopted` verdict is removed or its notice
// is dropped, and the pre-existing MYR-274 suite still asserts that the segment
// lands on the car's real mode, so the two halves cannot be traded off against
// each other.
@MainActor
final class ClimateAutoConfirmationTests: XCTestCase {

    private func makeExecutor(settleWindow: TimeInterval = 15) -> LiveVehicleCommandExecutor {
        LiveVehicleCommandExecutor(
            vehicleID: "veh-1",
            sender: ScriptedCommandSender(),
            plateEndpoint: ScriptedPlateEndpoint(),
            serviceWindowEndpoint: ScriptedServiceWindowEndpoint(),
            rideShareEndpoint: ScriptedRideShareEndpoint(),
            driving: false,
            plate: "",
            wakeRetryDelay: .zero,
            maxWakeRetries: 1,
            settleWindow: settleWindow,
            noticeDisplayDuration: .seconds(600)
        )
    }

    /// The tester's own state: HVAC on, manual, AC compressor running — the frame
    /// his screenshot shows ("Climate On · 64°", segment on Cool).
    private func manualCoolFrame() -> VehicleState {
        var state = Contracts.parkedState()
        state.hvacAutoMode = .override
        state.hvacAcEnabled = true
        state.isClimateOn = true
        return state
    }

    // MARK: The pure verdict

    func testTheVerdictConfirmsOnAutoWhateverTheDeadline() {
        let expired = ClimateAutoConfirmation.Pending(deadline: Date().addingTimeInterval(-60))
        XCTAssertEqual(
            ClimateAutoConfirmation.verdict(reported: .auto, pending: expired),
            .confirmed,
            "a car reporting auto has adopted the command, however late it says so"
        )
    }

    func testTheVerdictHoldsADisagreeingFrameInsideTheWindow() {
        let open = ClimateAutoConfirmation.Pending(deadline: Date().addingTimeInterval(60))
        XCTAssertEqual(ClimateAutoConfirmation.verdict(reported: .cool, pending: open), .awaiting)
        XCTAssertEqual(ClimateAutoConfirmation.verdict(reported: .heat, pending: open), .awaiting)
    }

    func testTheVerdictCondemnsADisagreeingFrameOnceTheWindowLapses() {
        let expired = ClimateAutoConfirmation.Pending(deadline: Date().addingTimeInterval(-1))
        XCTAssertEqual(ClimateAutoConfirmation.verdict(reported: .cool, pending: expired), .notAdopted)
    }

    // MARK: The executor

    /// THE DEFECT, restored end to end. Tap Auto against a car already running in
    /// manual; the command is applied (200) and the car keeps reporting
    /// `Override`. The segment must land on the car's real mode AND say why.
    ///
    /// Fails on `main`: the pre-MYR-466 executor reaches exactly this state with
    /// `uiState(for: .climate).notice == nil`.
    func testAnAutoThatTheCarNeverAdoptsSaysSoInsteadOfSpringingBackInSilence() async {
        let exec = makeExecutor(settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)
        XCTAssertEqual(exec.controls.climateMode, .auto, "optimistic Auto applied on the 200")
        XCTAssertNil(exec.uiState(for: .climate).notice, "nothing to say while the car may still adopt it")

        // Inside the window the stale Override is absorbed, exactly as MYR-274
        // intended — the owner must not see a one-frame flicker.
        exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.controls.climateMode, .auto)
        XCTAssertNil(exec.uiState(for: .climate).notice)

        try? await Task.sleep(for: .milliseconds(90))
        exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())

        XCTAssertEqual(exec.controls.climateMode, .cool, "the car's real mode is still adopted — it is the truth")
        XCTAssertEqual(
            exec.uiState(for: .climate).notice, .autoNotAdopted,
            "and the segment moving on its own is explained rather than left to be discovered"
        )
    }

    /// The notice has to SURVIVE the frames that follow it. `reconcile` runs on
    /// every folded delta — a cabin temperature, a GPS fix — and MYR-301's
    /// clear-on-reconcile would otherwise wipe this sentence about a second after
    /// it was raised, leaving the owner with the original symptom.
    func testTheNoticeSurvivesTheTelemetryFramesThatKeepArrivingBehindIt() async {
        let exec = makeExecutor(settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)
        try? await Task.sleep(for: .milliseconds(90))
        exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.uiState(for: .climate).notice, .autoNotAdopted)

        for _ in 0..<5 {
            exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())
        }
        XCTAssertEqual(
            exec.uiState(for: .climate).notice, .autoNotAdopted,
            "five more frames of the same manual mode are not new information"
        )
    }

    /// The happy path stays quiet. A car that adopts Auto raises nothing at all —
    /// a notice on a command that worked is noise, and it would appear on the
    /// intermittent-success half of the tester's own evening.
    func testAnAutoTheCarAdoptsRaisesNoNotice() async {
        let exec = makeExecutor(settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)

        var confirmed = Contracts.parkedState()
        confirmed.hvacAutoMode = .on
        exec.reconcile(from: confirmed, snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.controls.climateMode, .auto)
        XCTAssertNil(exec.uiState(for: .climate).notice)

        // And once confirmed, a LATER genuine switch to manual in the car is an
        // ordinary reconcile with no notice — the confirmation spent the pending.
        try? await Task.sleep(for: .milliseconds(90))
        exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.controls.climateMode, .cool)
        XCTAssertNil(
            exec.uiState(for: .climate).notice,
            "somebody turning the dial in the car is not a failed command"
        )
    }

    /// **A deadline is not evidence.** A car that has streamed no HVAC mode at all
    /// since the ack has not disagreed with anything, so the window lapsing over
    /// silence must accuse nothing — the honest-unknown rule (MYR-251) applied to
    /// a verdict rather than to a value.
    func testACarThatReportsNoModeAtAllIsNeverAccusedOfRefusingTheCommand() async {
        let exec = makeExecutor(settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)
        try? await Task.sleep(for: .milliseconds(90))

        // `parkedState()` carries no `hvacAutoMode`, i.e. the car said nothing.
        exec.reconcile(from: Contracts.parkedState(), snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.controls.climateMode, .auto, "nothing contradicted the command")
        XCTAssertNil(exec.uiState(for: .climate).notice)
    }

    /// Tapping Auto again after a refusal takes the key pending and clears the
    /// notice, so the row does not carry the last attempt's verdict over the next
    /// one. This is `beginPending`'s existing rule; it is asserted here because
    /// `.autoNotAdopted` is the first notice `reconcile` is forbidden to clear.
    func testANewAutoAttemptClearsTheRefusalItIsRetrying() async {
        let exec = makeExecutor(settleWindow: 0.05)
        try? await exec.setClimateMode(.auto)
        try? await Task.sleep(for: .milliseconds(90))
        exec.reconcile(from: manualCoolFrame(), snapshotReadIssuedAt: Date())
        XCTAssertEqual(exec.uiState(for: .climate).notice, .autoNotAdopted)

        try? await exec.setClimateMode(.auto)
        XCTAssertNil(exec.uiState(for: .climate).notice, "a new attempt owns the surface")
    }

    // MARK: The copy

    /// `.autoNotAdopted` is a REFUSAL BY PHYSICS, not by the car's command
    /// handler, so it must not borrow `.rejected`'s sentence — an owner told "The
    /// car didn't accept that" about a command the car returned 200 for goes
    /// looking for a failure that did not happen.
    func testTheNoticeNamesTheOutcomeAndRoutesNowhere() {
        XCTAssertEqual(VehicleCommandNotice.autoNotAdopted.message, "The car stayed on manual climate")
        XCTAssertNotEqual(
            VehicleCommandNotice.autoNotAdopted.message,
            VehicleCommandNotice.rejected(nil).message,
            "a command that was applied is not a command that was refused"
        )
        XCTAssertNil(
            VehicleCommandNotice.autoNotAdopted.action,
            "the Tesla link demonstrably works — a Reconnect pill would be a dead end"
        )
        XCTAssertFalse(
            VehicleCommandNotice.autoNotAdopted.isTransient,
            "nothing is still in flight; this is a settled verdict with a bounded display"
        )
        XCTAssertFalse(VehicleCommandNotice.autoNotAdopted.tileText.isEmpty)
    }
}
