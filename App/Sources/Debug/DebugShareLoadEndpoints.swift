#if DEBUG
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts

// MARK: - Share-tab LOAD endpoints (MYR-386 — drift-gate / screenshot only)
//
// THE CLIENT'S REPORT (TestFlight, build 202607311129): *"Need to add the
// skeleton loading to this page. It flashes no one added then appears."*
//
// The Share tab's two missing states — the §7.5.2 read IN FLIGHT and the §7.5.2
// read FAILED — have no other capture route. Against a healthy backend the first
// lasts milliseconds and cannot be screenshotted by racing it, and the second
// needs every one of the owner's vehicles to fail at once, behind a real auth
// session.
//
// So each parks the SHIPPING `LiveShareService.performLoad` in one branch and
// leaves it there. Same precedent as MYR-326's `DebugLoadingFleet` and MYR-342's
// `DebugHangingRideShareEndpoint`: inject the WIRE, run the real code path, so
// the capture proves the shipping phase resolution rather than a hand-set view
// flag. Every phase the screen renders in these scenes is one the production
// service raised.
//
// Release builds never compile this file.

/// A §7.5 endpoint whose LIST read never answers — the SKELETON capture.
///
/// Only `shareInvites` hangs. The other five methods are unreachable from these
/// scenes (there is no roster to act on and no CTA on the failure state), and
/// making them hang too would trade one honest park for a screen that hangs for
/// reasons the capture is not about.
struct DebugHangingSharingEndpoint: VehicleSharingEndpoint {
    func shareInvites(vehicleID: String) async throws -> [ShareInvite] {
        // Never resolves, and never spins a CPU. Cancellation is the only exit,
        // which is what the app does when the scene goes away.
        try await Task.sleep(for: .seconds(86_400))
        return []
    }

    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        throw DebugShareLoadFailure.notReachableFromThisScene
    }
    func revokeShareInvite(inviteID: String) async throws {
        throw DebugShareLoadFailure.notReachableFromThisScene
    }
    func resendShareInvite(inviteID: String) async throws -> ShareInvite {
        throw DebugShareLoadFailure.notReachableFromThisScene
    }
    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse {
        throw DebugShareLoadFailure.notReachableFromThisScene
    }
    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
        throw DebugShareLoadFailure.notReachableFromThisScene
    }
}

/// A §7.5 endpoint whose LIST read fails for every vehicle — the FAILURE-STATE
/// capture.
///
/// EVERY vehicle, deliberately: `LiveShareService.performLoad` reports a failure
/// only when all of them failed, precisely so one transient 500 does not put a
/// notice under a list that is otherwise fine. A stub that failed one car would
/// photograph a perfectly healthy screen.
struct DebugFailingSharingEndpoint: VehicleSharingEndpoint {
    /// A plain 500 — the store-layer failure, not a 401 or a 404, so nothing
    /// about the capture depends on a status the screen special-cases.
    var failure: RestError = .http(status: 500, code: nil, message: "store failure", subCode: nil)

    func shareInvites(vehicleID: String) async throws -> [ShareInvite] { throw failure }

    func createShareInvite(_ body: CreateShareInviteRequest, vehicleID: String) async throws -> ShareInvite {
        throw failure
    }
    func revokeShareInvite(inviteID: String) async throws { throw failure }
    func resendShareInvite(inviteID: String) async throws -> ShareInvite { throw failure }
    func redeemShareInvite(code: String) async throws -> RedeemShareInviteResponse { throw failure }
    func patchShareInvite(_ body: PatchShareInviteRequest, inviteID: String) async throws -> ShareInvite {
        throw failure
    }
}

/// The error the hanging stub's unreachable methods raise. Named rather than a
/// generic failure so a capture that somehow reaches one says so out loud instead
/// of looking like a server problem.
enum DebugShareLoadFailure: Error {
    case notReachableFromThisScene
}
#endif
