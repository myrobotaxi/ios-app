import XCTest
import SwiftUI
import UIKit
import DesignSystem
import MyRoboTaxiKit
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-354 — the rider Settings vehicle section
//
// THE CLIENT'S REPORT (TestFlight, Jul 30): *"Showing no vehicles shared with
// me… I own a vehicle so would it appear here or no? Because technically I can
// request a ride from it."*
//
// MYR-343 fixed exactly this reasoning error on the rider SHELL and left it
// standing in rider SETTINGS: the tab still asked `catalog.grants`, i.e. "what
// is shared with me", of an account whose car is its own. So the map offered a
// "Where to?" on the client's Tesla while the Settings tab, one tap away, said
// he had no vehicles.
//
// These tests drive the section from the REAL §7.0 rows through the REAL
// role partitioner (`LiveSharedVehicleCatalog.grants` / `.ownedVehicles`) — the
// same route the screen takes — so they exercise the shipping mapping rather
// than hand-built inputs. The matrix is the four account shapes (owned /
// shared / both / none) plus the two non-answers a live list can give.

// MARK: - Fixture rows

/// A §7.0 `VehicleSummary` in either role. Local to this file for the same
/// reason `RiderVehicleSetTests` keeps its own: neither suite may be changed out
/// from under the other.
private func settingsVehicleRow(
    id: String,
    name: String,
    role: VehicleSummary.Role,
    permission: String? = nil
) -> VehicleSummary {
    VehicleSummary(
        vehicleId: id,
        name: name,
        model: "Model 3",
        year: 2024,
        color: "Pearl White",
        vinLast4: "0001",
        status: .parked,
        chargeLevel: 72,
        estimatedRange: 210,
        lastUpdated: "2026-07-30T15:04:05Z",
        role: role,
        hasActiveRide: false,
        licensePlate: "8ABC123",
        serviceEstimatedEndAt: nil,
        sharePermission: permission.map { SharePermission(rawValue: $0) }
    )
}

/// The four account shapes, each as the §7.0 list a server would really return.
private enum SettingsAccount {
    /// The CLIENT: one owned car, nothing shared with him.
    static let owned = [settingsVehicleRow(id: "owned-1", name: "Lunar", role: .owner)]
    /// A pure viewer: two redeemed shares, owns nothing.
    static let shared = [
        settingsVehicleRow(id: "shared-1", name: "Alex\u{2019}s Model 3", role: .viewer, permission: "rides"),
        settingsVehicleRow(id: "shared-2", name: "Mom\u{2019}s Model Y", role: .viewer, permission: "live"),
    ]
    /// BOTH — and deliberately with the OWNED row NOT first on the wire, so the
    /// render order is proven to be the rule's and not the server's.
    static let both = [shared[0]] + owned + [shared[1]]
    /// NEITHER: signed in, nothing on the account at all.
    static let none: [VehicleSummary] = []
}

@MainActor
final class RiderSettingsVehicleSectionTests: XCTestCase {

    private func section(
        _ summaries: [VehicleSummary],
        hasLoaded: Bool = true,
        loadFailed: Bool = false
    ) -> RiderSettingsVehicleSection {
        RiderSettingsVehicleSection.resolve(
            hasLoaded: hasLoaded,
            loadFailed: loadFailed,
            owned: LiveSharedVehicleCatalog.ownedVehicles(from: summaries),
            shared: LiveSharedVehicleCatalog.grants(from: summaries)
        )
    }

    // MARK: The matrix

    /// OWNED — the client's account. His car is listed, captioned with the
    /// answer to the question he asked, and the empty state is nowhere.
    func testAnOwnedVehicleLeadsTheSectionAndTheEmptyStateIsGone() {
        let s = section(SettingsAccount.owned)
        XCTAssertEqual(s.rows, [
            .owned(id: "owned-1", name: "Lunar"),
            .enterCode,
        ])
        XCTAssertFalse(s.rows.contains(.empty))
    }

    /// The caption is the two facts he asked about, in the order he asked them.
    func testTheOwnedRowSaysWhoseCarItIsAndThatHeCanRideIt() {
        XCTAssertEqual(RiderSettingsVehicleSection.ownedCaption, "Your car \u{00B7} Ride from it anytime")
    }

    /// SHARED — a pure viewer is the prototype's own account and is UNCHANGED by
    /// this issue: the same rows, in the same order, under the same label.
    func testAPureViewerIsUnchanged() {
        let s = section(SettingsAccount.shared)
        XCTAssertEqual(s.label, RiderSettingsVehicleSection.sharedOnlyLabel)
        XCTAssertEqual(s.rows, [
            .shared(id: "shared-1", title: "Alex\u{2019}s Model 3", caption: "Can request rides"),
            .shared(id: "shared-2", title: "Mom\u{2019}s Model Y", caption: "Live location"),
            .enterCode,
        ])
    }

    /// BOTH — owned first, whatever order the server sent. This is the same
    /// precedence `RiderVehicleSet` adopts, and for the same reason: the ride is
    /// created against `vehicles.first`, so the car at the head of this list is
    /// the car a "Where to?" actually books.
    func testAnAccountWithBothLeadsWithTheOwnedCar() {
        let s = section(SettingsAccount.both)
        XCTAssertEqual(s.rows, [
            .owned(id: "owned-1", name: "Lunar"),
            .shared(id: "shared-1", title: "Alex\u{2019}s Model 3", caption: "Can request rides"),
            .shared(id: "shared-2", title: "Mom\u{2019}s Model Y", caption: "Live location"),
            .enterCode,
        ])
    }

    /// NONE — the ONE account "No vehicles shared with you yet" is true of.
    func testOnlyAnAccountWithNothingSeesTheEmptyState() {
        XCTAssertEqual(section(SettingsAccount.none).rows, [.empty, .enterCode])
        for shape in [SettingsAccount.owned, SettingsAccount.shared, SettingsAccount.both] {
            XCTAssertFalse(section(shape).rows.contains(.empty))
        }
    }

    // MARK: The label

    /// "Shared with me" is FALSE of an owned row, so a section that leads with
    /// one is not titled with it. A pure viewer keeps the prototype's label
    /// verbatim, which is why every simulated capture is unchanged.
    func testTheLabelStopsClaimingASharedAccountOnceOneIsOwned() {
        XCTAssertEqual(section(SettingsAccount.owned).label, RiderSettingsVehicleSection.ownedLabel)
        XCTAssertEqual(section(SettingsAccount.both).label, RiderSettingsVehicleSection.ownedLabel)
        XCTAssertEqual(section(SettingsAccount.shared).label, RiderSettingsVehicleSection.sharedOnlyLabel)
        XCTAssertEqual(section(SettingsAccount.none).label, RiderSettingsVehicleSection.sharedOnlyLabel)
    }

    // MARK: The two non-answers

    /// STILL RESOLVING — the list has not answered, so the card claims nothing.
    /// "No vehicles shared with you yet" over an unanswered fetch is exactly the
    /// two-way-boolean mistake MYR-343 removed from the shell.
    func testAListStillInFlightMakesNoClaim() {
        XCTAssertEqual(section(SettingsAccount.none, hasLoaded: false).rows, [.enterCode])
    }

    /// UNREACHABLE — one timed-out fetch is not evidence that an account owns
    /// nothing (MYR-326: loading ≠ unavailable, and neither is "empty").
    func testAListThatFailedIsNotAnEmptyAccount() {
        let s = section(SettingsAccount.none, hasLoaded: false, loadFailed: true)
        XCTAssertEqual(s.rows, [.unavailable, .enterCode])
        XCTAssertFalse(s.rows.contains(.empty))
    }

    /// The unavailable line is the SAME words the rider shell uses for the same
    /// fact — one situation, one sentence.
    func testTheUnavailableLineMatchesTheShell() {
        XCTAssertEqual(
            RiderSettingsVehicleSection.unavailableText,
            "Can\u{2019}t reach your vehicles right now"
        )
    }

    // MARK: The invariant that keeps the two surfaces honest

    /// THE POINT OF THE ISSUE. Settings shows the empty state **iff** the shell
    /// resolves `.empty`. Asserted across the whole matrix AND both non-answers,
    /// so the tab and the map can never again give one account two different
    /// answers to "do you have a car?".
    func testTheEmptyStateAgreesWithTheShellOnEveryInput() {
        let shapes: [[VehicleSummary]] = [
            SettingsAccount.owned, SettingsAccount.shared, SettingsAccount.both, SettingsAccount.none,
        ]
        for shape in shapes {
            for (hasLoaded, loadFailed) in [(true, false), (false, false), (false, true)] {
                let owned = LiveSharedVehicleCatalog.ownedVehicles(from: shape)
                let grants = LiveSharedVehicleCatalog.grants(from: shape)
                let shell = RiderVehicleSet.resolve(
                    hasLoaded: hasLoaded, loadFailed: loadFailed,
                    grants: grants, ownedVehicles: owned
                )
                let rows = RiderSettingsVehicleSection.resolve(
                    hasLoaded: hasLoaded, loadFailed: loadFailed,
                    owned: owned, shared: grants
                ).rows
                XCTAssertEqual(rows.contains(.empty), shell == .empty,
                               "empty-state disagreement for hasLoaded=\(hasLoaded) loadFailed=\(loadFailed)")
                XCTAssertEqual(rows.contains(.unavailable), shell == .unavailable,
                               "unavailable disagreement for hasLoaded=\(hasLoaded) loadFailed=\(loadFailed)")
            }
        }
    }

    /// The invite-code row is ALWAYS last and always present — a rider must be
    /// able to redeem a code no matter what the account already holds (an owner
    /// can also be a viewer).
    func testTheInviteCodeRowIsAlwaysTheLastRow() {
        for shape in [SettingsAccount.owned, SettingsAccount.shared, SettingsAccount.both, SettingsAccount.none] {
            XCTAssertEqual(section(shape).rows.last, .enterCode)
            XCTAssertEqual(section(shape).rows.filter { $0 == .enterCode }.count, 1)
        }
    }

    // MARK: SIM is untouched

    /// The simulated catalog owns nothing and holds the prototype's three
    /// personas, so the simulated page keeps the prototype's label and its three
    /// rows — which is why every simulated + DEBUG rider capture is unchanged by
    /// the new rule.
    func testTheSimulatedCatalogStillRendersThePrototypesSection() {
        let catalog = SimulatedSharedVehicleCatalog()
        let s = RiderSettingsVehicleSection.resolve(
            hasLoaded: catalog.hasLoaded,
            loadFailed: catalog.loadFailed,
            owned: catalog.ownedVehicles,
            shared: catalog.grants
        )
        XCTAssertEqual(s.label, RiderSettingsVehicleSection.sharedOnlyLabel)
        XCTAssertEqual(s.rows, [
            .shared(id: "alex", title: "Alex\u{2019}s Cybercab", caption: "Roommate \u{00B7} Request rides"),
            .shared(id: "mom", title: "Mom\u{2019}s Model Y", caption: "Family \u{00B7} Request rides"),
            .shared(id: "jordan", title: "Jordan\u{2019}s Model 3", caption: "Friend \u{00B7} Request rides"),
            .enterCode,
        ])
    }
}

// MARK: - MYR-354 — the one settings grammar

final class SettingsGrammarTests: XCTestCase {

    /// The card grammar's row inset is the rider prototype's own 16
    /// (shared-screens.jsx:480 `padding: '13px 16px'`), not the page gutter.
    func testTheCardRowInsetIsTheRiderPrototypesOwnNumber() {
        XCTAssertEqual(MRTSettingsGrammar.rowHorizontalPadding, 16)
        XCTAssertEqual(MRTSettingsGrammar.rowVerticalPadding, 13)
        XCTAssertEqual(MRTSettingsGrammar.sectionSpacing, 22)
        XCTAssertEqual(MRTSettingsGrammar.labelSpacing, 8)
    }

    /// THE HANDOFF GUARD (MYR-347). `ViewerRow` bakes the PAGE GUTTER into its
    /// own horizontal padding because it was built for the full-bleed owner list
    /// and is shared with the Share tab. Owner Settings hosts it inside a card
    /// and corrects the difference at the call site, so this constant is exactly
    /// "what ViewerRow adds, minus what a card row wants".
    ///
    /// When MYR-347's restyle lands and the row stops baking a page gutter, this
    /// value becomes 0 and nothing else on either Settings screen changes.
    func testTheViewerRowCardInsetIsTheGutterDifference() {
        XCTAssertEqual(
            MRTSettingsGrammar.viewerRowCardInset,
            MRTMetrics.pageGutter - MRTSettingsGrammar.rowHorizontalPadding
        )
        XCTAssertEqual(MRTSettingsGrammar.viewerRowCardInset, 8)
    }

    /// The two prototypes' screen titles differed by 6pt of bottom padding for
    /// no stated reason; ONE grammar means one number, and it is the card page's.
    func testBothPagesUseOneHeaderBottomPadding() {
        XCTAssertEqual(MRTSettingsGrammar.headerBottomPadding, 12)
    }

    // MARK: Notification rows (MYR-354, from MYR-349's prefs findings)

    /// The rider's TWO prototype rows were ONE `ride_lifecycle` preference
    /// wearing two masks. Merged, the single row must NAME what it governs —
    /// otherwise the merge silently removes control the rider believed they had.
    func testTheMergedRiderRowNamesEveryNotificationItGoverns() {
        XCTAssertEqual(SettingsNotificationCopy.riderRideUpdates, "Ride updates")
        let caption = SettingsNotificationCopy.riderRideUpdatesCaption
        for named in ["Accepted", "declined", "pick-up", "arrival"] {
            XCTAssertTrue(caption.localizedCaseInsensitiveContains(named),
                          "the merged row must still name \(named): \(caption)")
        }
    }

    /// The owner's missing switch. `ride_lifecycle` was already gating their
    /// "X wants a ride" pushes with nothing on the page saying so.
    func testTheOwnerHasARideRequestsRow() {
        XCTAssertEqual(SettingsNotificationCopy.ownerRideRequests, "Ride requests")
    }

    /// Every notification row on both pages fits its own line at the narrowest
    /// supported width, the same rule `VehicleControlTileCaptionTests` applies to
    /// the quick tiles — a row label that wraps under a toggle reads as broken.
    func testTheNotificationLabelsFitTheRow() {
        // 375pt device − 2×24 page gutter − 2×16 card inset − 51pt toggle − 12pt gap.
        let available: CGFloat = 375 - 48 - 32 - 51 - 12
        let labels = [
            SettingsNotificationCopy.ownerRideRequests,
            SettingsNotificationCopy.riderRideUpdates,
            "Drive started", "Drive completed", "Charging complete", "Viewer joined",
        ]
        for label in labels {
            let width = (label as NSString).size(
                withAttributes: [.font: UIFont.systemFont(ofSize: 14)]
            ).width
            XCTAssertLessThan(width, available, "\"\(label)\" does not fit its row")
        }
    }

    // MARK: The notices slot (MYR-354 × MYR-349, asserted at the merge)

    /// MYR-354 named `SettingsSectionNotices` as the slot under the notifications
    /// card where MYR-186's `PushDeniedNotice` and MYR-349's live-only
    /// `PushPrefsNotice` would BOTH land. MYR-349 shipped its notice loose in each
    /// body instead, so the merge had to move it — and a view moved into a
    /// container is exactly the kind of change that compiles while rendering
    /// nothing.
    ///
    /// Measured through a `UIHostingController` (the `OwnerPeekBandTests`
    /// precedent) rather than reasoned about: the slot must be ZERO-height with
    /// nothing to say — which is what keeps every simulated and DEBUG capture
    /// pixel-identical, since `SimulatedPushPrefsService.statusMessage` is always
    /// nil — and must GROW for each notice that has something to say.
    func testTheNoticesSlotRendersWhatItIsGiven() {
        let width: CGFloat = 375

        func height<V: View>(_ view: V) -> CGFloat {
            let host = UIHostingController(rootView: view.frame(width: width))
            host.view.backgroundColor = .clear
            return host.sizeThatFits(
                in: CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
        }

        // The simulated path: nothing to say, so the slot reserves nothing.
        let silent = height(
            SettingsSectionNotices {
                PushPrefsNotice(message: nil)
                PushDeniedNotice(state: .notDetermined)
            }
        )
        XCTAssertEqual(silent, 0, accuracy: 0.5,
                       "an empty slot must not move a single row below it")

        // The live path: a write that did not land. The notice RENDERS here now.
        let withPrefsNotice = height(
            SettingsSectionNotices {
                PushPrefsNotice(message: "That didn\u{2019}t save. Try again.")
                PushDeniedNotice(state: .notDetermined)
            }
        )
        XCTAssertGreaterThan(withPrefsNotice, silent,
                             "PushPrefsNotice must render inside the slot it was moved into")

        // Both at once — the pair the slot exists for.
        let both = height(
            SettingsSectionNotices {
                PushPrefsNotice(message: "That didn\u{2019}t save. Try again.")
                PushDeniedNotice(state: .denied)
            }
        )
        XCTAssertGreaterThan(both, withPrefsNotice,
                             "the two notices stack; neither may swallow the other")
    }
}
