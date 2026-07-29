import XCTest
@testable import MyRoboTaxi

/// The permission-moment decision matrix (MYR-186).
///
/// The app asks for notification authorization at the FIRST MEANINGFUL MOMENT,
/// never at launch — owner: first arrival on the live home map; rider: right
/// after their first ride request submits. iOS shows the system alert exactly
/// once per install, so getting this wrong is not recoverable in-app: every cell
/// of `role × liveness × moment × already-asked` is pinned here.
@MainActor
final class PushPermissionMomentTests: XCTestCase {

    // MARK: The two moments that DO ask

    func testOwnerIsAskedOnFirstArrivalOnTheLiveHomeMap() {
        let decision = PushPermissionMoment.decide(
            role: .owner, isLive: true, trigger: .ownerLiveHomeAppeared, hasAsked: false
        )
        XCTAssertEqual(decision, .ask, "the owner's meaningful moment is arriving on the live home map")
    }

    func testRiderIsAskedRightAfterSubmittingTheirFirstRequest() {
        let decision = PushPermissionMoment.decide(
            role: .shared, isLive: true, trigger: .riderRideRequestSubmitted, hasAsked: false
        )
        XCTAssertEqual(decision, .ask, "the rider's meaningful moment is having just submitted a request")
    }

    // MARK: Liveness — the simulated path must be untouched

    func testSimulatedOwnerIsNeverAsked() {
        let decision = PushPermissionMoment.decide(
            role: .owner, isLive: false, trigger: .ownerLiveHomeAppeared, hasAsked: false
        )
        XCTAssertEqual(decision, .skip(.notLive), "fixtures + DEBUG scenes never prompt (drift-gate captures)")
    }

    func testSimulatedRiderIsNeverAsked() {
        let decision = PushPermissionMoment.decide(
            role: .shared, isLive: false, trigger: .riderRideRequestSubmitted, hasAsked: false
        )
        XCTAssertEqual(decision, .skip(.notLive))
    }

    /// Liveness is evaluated FIRST, so no combination of the other three inputs
    /// can produce a prompt on the simulated path.
    func testLivenessOutranksEveryOtherInput() {
        for role in [UserRole.owner, .shared] {
            for trigger in [PushPermissionTrigger.ownerLiveHomeAppeared, .riderRideRequestSubmitted] {
                for hasAsked in [true, false] {
                    let decision = PushPermissionMoment.decide(
                        role: role, isLive: false, trigger: trigger, hasAsked: hasAsked
                    )
                    XCTAssertEqual(
                        decision, .skip(.notLive),
                        "simulated must never ask (role=\(role) trigger=\(trigger) hasAsked=\(hasAsked))"
                    )
                }
            }
        }
    }

    // MARK: One shot

    func testOwnerIsNotAskedTwice() {
        let decision = PushPermissionMoment.decide(
            role: .owner, isLive: true, trigger: .ownerLiveHomeAppeared, hasAsked: true
        )
        XCTAssertEqual(decision, .skip(.alreadyAsked), "the gate is one-shot — every later arrival is free")
    }

    func testRiderIsNotAskedTwice() {
        let decision = PushPermissionMoment.decide(
            role: .shared, isLive: true, trigger: .riderRideRequestSubmitted, hasAsked: true
        )
        XCTAssertEqual(decision, .skip(.alreadyAsked))
    }

    /// Authorization is per-APP, not per-role: a user asked as an owner who then
    /// switches to the rider shell and submits a request must NOT see a second
    /// prompt (which iOS would silently swallow anyway).
    func testTheGateIsSharedAcrossRoles() {
        let decision = PushPermissionMoment.decide(
            role: .shared, isLive: true, trigger: .riderRideRequestSubmitted, hasAsked: true
        )
        XCTAssertEqual(decision, .skip(.alreadyAsked), "asking as owner consumes the rider's prompt too")
    }

    // MARK: Role/moment mismatch

    func testOwnerIsNotAskedByTheRidersMoment() {
        let decision = PushPermissionMoment.decide(
            role: .owner, isLive: true, trigger: .riderRideRequestSubmitted, hasAsked: false
        )
        XCTAssertEqual(decision, .skip(.triggerNotMeaningfulForRole))
    }

    func testRiderIsNotAskedByTheOwnersMoment() {
        let decision = PushPermissionMoment.decide(
            role: .shared, isLive: true, trigger: .ownerLiveHomeAppeared, hasAsked: false
        )
        XCTAssertEqual(decision, .skip(.triggerNotMeaningfulForRole))
    }

    /// The whole matrix in one place: exactly two of the sixteen cells ask.
    func testExactlyTwoCellsOfTheMatrixAsk() {
        var asking: [(UserRole, PushPermissionTrigger, Bool, Bool)] = []
        for role in [UserRole.owner, .shared] {
            for isLive in [true, false] {
                for trigger in [PushPermissionTrigger.ownerLiveHomeAppeared, .riderRideRequestSubmitted] {
                    for hasAsked in [true, false] where
                        PushPermissionMoment.decide(role: role, isLive: isLive, trigger: trigger, hasAsked: hasAsked) == .ask {
                        asking.append((role, trigger, isLive, hasAsked))
                    }
                }
            }
        }
        XCTAssertEqual(asking.count, 2, "live + never-asked + the role's own moment — and nothing else")
    }
}
