@testable import MyRoboTaxi
import XCTest

// MARK: - MYR-395 item 3 — one footer, both roles
//
// r16, the client: *"How come rider screen shows guest access at bottom and other
// shows version?"*
//
// MYR-354 unified everything else about these two pages onto one grammar and
// deliberately left the footer role-split, on the reasoning that each line "says
// something true about the account looking at it". Both halves WERE true, and it
// was still the wrong call: the footer is page furniture, and furniture that
// carries two different kinds of fact makes one page look like a different app.
//
// The version wins because it is the only thing on either page a tester filing a
// report needs and cannot get anywhere else. Nothing is lost with "Guest access":
// the role is the gold badge in `SettingsProfileCard` at the TOP of the rider page
// (the prototype's own shared-screens.jsx:473) and the per-vehicle answer is
// MYR-354's vehicle section — so re-homing it as a third statement of one fact is
// the repetition MYR-366 deleted the Account name row for. The flat claim is also
// simply false for the account MYR-343 fixed: an owner in rider mode is not
// anybody's guest.
final class SettingsFooterParityTests: XCTestCase {

    /// The whole client report, as one assertion. There is ONE footer string and
    /// both screens render it — a `static` on the type rather than a literal typed
    /// on each page, so a third Settings surface cannot invent a third wording.
    func testBothRolesRenderTheSameFooterString() {
        XCTAssertEqual(SettingsFooter.appVersion.text, AppVersionStamp.footerText)
        XCTAssertFalse(AppVersionStamp.footerText.isEmpty)
    }

    /// The line the client asked to see on both pages, in the owner page's own
    /// shape (`"MyRoboTaxi v1.0 (24)"`) — brand, `v`, version, parenthesised build.
    func testTheFooterIsTheVersionLineInTheShapeTheOwnerPageAlreadyHad() {
        let text = AppVersionStamp.footerText
        XCTAssertTrue(text.hasPrefix("MyRoboTaxi v"), text)
        XCTAssertTrue(text.hasSuffix(")"), text)
        XCTAssertTrue(text.contains(" ("), text)
        XCTAssertTrue(text.contains(AppVersionStamp.shortVersion), text)
        XCTAssertTrue(text.contains(AppVersionStamp.build), text)
    }

    /// **The stamp is read, not typed.** The owner footer used to be the literal
    /// `"MyRoboTaxi v1.0 (24)"`; `project.yml` ships `MARKETING_VERSION 1.0.0` and
    /// a `CURRENT_PROJECT_VERSION` that RELEASING.md overrides per upload, so build
    /// "24" has never existed. The one line whose whole job is to identify the
    /// build was naming a build nobody could have installed — and now that both
    /// roles show it, a wrong stamp would be wrong twice.
    func testTheStampComesFromTheBundleAndNotFromAHardcodedLiteral() {
        XCTAssertEqual(
            AppVersionStamp.shortVersion,
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        XCTAssertEqual(
            AppVersionStamp.build,
            Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        )
        XCTAssertNotEqual(AppVersionStamp.footerText, "MyRoboTaxi v1.0 (24)",
                          "the retired literal must not be reachable again")
    }

    /// The footer no longer states a role, on either page. Asserted in the
    /// negative because the way this regresses is somebody "restoring" the rider's
    /// line out of sympathy for the prototype.
    func testNeitherFooterClaimsAnAccessLevel() {
        let text = AppVersionStamp.footerText.lowercased()
        for word in ["guest", "access", "owner", "rider", "viewer"] {
            XCTAssertFalse(text.contains(word), "the footer must not carry a role: \(text)")
        }
    }
}
