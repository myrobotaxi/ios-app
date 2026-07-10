import XCTest
@testable import MyRoboTaxi
import MyRoboTaxiKit

/// App-side session-seam tests (MYR-164). The live ASAuthorization flow can't
/// run headless (no Apple ID in the sim), so these cover the seams that ARE
/// deterministic: the default (sim) composition and the `AuthSession` state
/// contract the routing shell in `RootView` drives (signed-out → sign-in,
/// signed-in → app, sign-out → sign-in).
@MainActor
final class AuthSessionRoutingTests: XCTestCase {

    /// With no live launch env (the default, and the test host's configuration),
    /// `AuthComposition` yields the simulated session and NO backend token
    /// provider — the shipped-demo / RELEASE posture, unchanged by MYR-164.
    func testCompositionDefaultsToSimulatedSessionWithoutProvider() {
        let result = AuthComposition.make()
        XCTAssertTrue(result.session is SimulatedAuthSession, "default is the simulated session")
        XCTAssertNil(result.sessionTokenProvider, "no backend session provider in sim mode")
    }

    /// The seam contract the routing shell depends on: sign-in establishes a
    /// session, sign-out tears it down.
    func testSimulatedSessionSignInThenSignOutFlipsState() async throws {
        let session = SimulatedAuthSession()
        XCTAssertFalse(session.isSignedIn, "signed-out → sign-in screen")

        try await session.signIn()
        XCTAssertTrue(session.isSignedIn, "signed-in → main app")

        session.signOut()
        XCTAssertFalse(session.isSignedIn, "sign-out → back to sign-in screen")
    }

    /// The seam is exercised through the existential type the shell holds
    /// (`any AuthSession`), proving the routing shell's call sites are satisfied.
    func testSessionUsableThroughExistential() async throws {
        let session: any AuthSession = SimulatedAuthSession()
        try await session.signIn()
        XCTAssertTrue(session.isSignedIn)
    }
}
