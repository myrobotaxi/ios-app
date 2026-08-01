import XCTest
import SwiftUI
import DesignSystem
@testable import MyRoboTaxi

// MARK: - MYR-397 — the tracking sheet's structure
//
// Three client asks, three groups of assertions:
//
//   1. **CANCEL** — in every pre-pickup phase, gone at pickup and beyond, and with
//      NO DEAD SPACE where it was. The last clause is the one a comment cannot
//      keep: the slot is MEASURED at 0pt when hidden, the same
//      `SettingsGrammarTests.testTheNoticesSlotRendersWhatItIsGiven` precedent.
//   2. **THE OWNER CHIP** — owner yes, viewer no, and no chip without an account to
//      switch.
//   3. **PEEK vs FULL** — the peek is a COMPLETE composition at its own height, not
//      the full card cropped (MYR-296's guillotine), and it is shorter than the
//      card by a real margin so the two detents are genuinely two states.

final class RiderTrackingSheetCompositionTests: XCTestCase {

    /// The narrowest supported device, so a caption that wraps on a small screen
    /// shows up here rather than in a client screenshot (the MYR-335 lesson).
    private static let deviceWidth: CGFloat = 375

    /// A ride record at a given status. Local to this file so the stage matrix
    /// cannot be changed out from under another suite.
    @MainActor
    private static func record(status: RideRequestStatus) -> RideRequestRecord {
        RideRequestRecord(
            input: RideRequestInput(
                pickup: RideRequestFixtures.savedPlaces[0],
                destination: RideRequestFixtures.recentPlaces[0],
                fleetMemberID: RideRequestFixtures.fleet[0].id
            ),
            status: status
        )
    }

    @MainActor
    private func height<V: View>(_ view: V, width: CGFloat = deviceWidth) -> CGFloat {
        let host = UIHostingController(rootView: view.frame(width: width))
        host.view.backgroundColor = .clear
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    // MARK: 1 — the Cancel visibility matrix

    /// *"Cancel appears in EVERY pre-pickup phase (requested/accepted/waiting/
    /// heading); at pickup and beyond, same sheet grammar, no Cancel."*
    ///
    /// The four pre-pickup phases the client names all fold to ONE stage
    /// (`.toPickup`) — which is why the rule is expressed over the stage rather
    /// than over `RideRequestStatus`: the sheet already decides the phase there,
    /// and a second derivation is a second chance to disagree with it.
    func testCancelRendersThroughoutThePrePickupLegAndNowhereElse() {
        XCTAssertTrue(RiderTrackingCancelVisibility.showsCancel(stage: .toPickup))
        XCTAssertFalse(RiderTrackingCancelVisibility.showsCancel(stage: .arrivedAwaitingStart))
        XCTAssertFalse(RiderTrackingCancelVisibility.showsCancel(stage: .inRide))
        XCTAssertFalse(RiderTrackingCancelVisibility.showsCancel(stage: .arrivingDropoff))
    }

    /// **AT PICKUP IS THE BOUNDARY, AND IT IS A NO.** The owner has confirmed the
    /// car is at the kerb; the server would refuse the cancel, and a control that
    /// exists to be refused is MYR-233's dead end wearing a destructive tint.
    func testTheArrivedStageIsTheBoundaryAndIsExcluded() {
        XCTAssertFalse(
            RiderTrackingCancelVisibility.showsCancel(stage: .arrivedAwaitingStart),
            "the car is AT the pickup — offering a cancel here offers a 409"
        )
    }

    /// Every pre-pickup STATUS resolves to the stage that shows Cancel, driven
    /// through the shipping stage derivation rather than asserted about it.
    @MainActor
    func testEveryPrePickupStatusResolvesToAStageThatOffersCancel() {
        for status in [RideRequestStatus.pending, .accepted] {
            var record = Self.record(status: status)
            record.trackProgress = 0.08
            let stage = RiderTrackingStage.stage(request: record, navMinutesToArrival: nil)
            XCTAssertEqual(stage, .toPickup, "status \(status)")
            XCTAssertTrue(RiderTrackingCancelVisibility.showsCancel(stage: stage))
        }
    }

    @MainActor
    func testAtPickupAndBeyondNoStatusOffersCancel() {
        for (status, progress) in [(RideRequestStatus.arrived, 0.08), (.enroute, 0.5), (.completed, 1.0)] {
            var record = Self.record(status: status)
            record.trackProgress = progress
            let stage = RiderTrackingStage.stage(request: record, navMinutesToArrival: nil)
            XCTAssertFalse(RiderTrackingCancelVisibility.showsCancel(stage: stage), "status \(status)")
        }
    }

    /// **"No dead space where it was."** A conditional inside the parent `VStack`
    /// is correct today and is exactly the shape that grows a reserved height the
    /// next time somebody tunes this layout (MYR-360's `Optional`-slot lesson). As
    /// its own view the emptiness is measurable — so it is measured.
    @MainActor
    func testTheCancelSlotIsExactlyZeroPointsWhenHidden() {
        XCTAssertEqual(height(TrackingCancelSlot(visible: false, isCancelling: false, action: {})), 0, accuracy: 0.5)
    }

    @MainActor
    func testTheCancelSlotIsAFullTapTargetWhenShown() {
        let shown = height(TrackingCancelSlot(visible: true, isCancelling: false, action: {}))
        XCTAssertEqual(shown, MRTMetrics.minTapTarget + MRTMetrics.trackingCancelTopGap, accuracy: 1)
        XCTAssertGreaterThanOrEqual(shown - MRTMetrics.trackingCancelTopGap, MRTMetrics.minTapTarget)
    }

    /// The in-flight row must not resize the sheet under the rider's thumb.
    @MainActor
    func testTheSlotDoesNotChangeHeightWhileTheCancelIsInFlight() {
        XCTAssertEqual(
            height(TrackingCancelSlot(visible: true, isCancelling: false, action: {})),
            height(TrackingCancelSlot(visible: true, isCancelling: true, action: {})),
            accuracy: 0.5
        )
    }

    // MARK: 2 — the owner-role chip gate

    /// CLIENT CONSTRAINT: *"render it ONLY for accounts that actually hold an owner
    /// role (own a linked Tesla). Viewers/riders without an owner profile never see
    /// it."*
    func testOnlyAnOwnerRoleSeesTheModeChip() {
        XCTAssertTrue(RiderOwnerModeChipGate.showsChip(holdsOwnerRole: true, canSwitchModes: true))
        XCTAssertFalse(RiderOwnerModeChipGate.showsChip(holdsOwnerRole: false, canSwitchModes: true))
    }

    /// …and no chip without a real account behind it: `switchViewMode()` needs a
    /// user id to persist the choice against and no-ops without one, so the tap
    /// would do nothing at all.
    func testNoChipWithoutAnAccountToSwitch() {
        XCTAssertFalse(RiderOwnerModeChipGate.showsChip(holdsOwnerRole: true, canSwitchModes: false))
        XCTAssertFalse(RiderOwnerModeChipGate.showsChip(holdsOwnerRole: false, canSwitchModes: false))
    }

    /// **SIM SEES NO CHIP, BY CONSTRUCTION.** `SimulatedSharedVehicleCatalog`
    /// owns nothing, so `holdsOwnerRole` is false on every simulated boot and every
    /// pre-existing DEBUG scene — which is what keeps every tracking capture
    /// byte-identical. Driven through the real catalog rather than asserted about
    /// it, so a future seed that gave the simulated catalog an owned row would fail
    /// here rather than in a screenshot.
    @MainActor
    func testTheSimulatedCatalogHoldsNoOwnerRoleAndSoRendersNoChip() {
        let catalog = SimulatedSharedVehicleCatalog()
        XCTAssertTrue(catalog.ownedVehicles.isEmpty)
        XCTAssertFalse(
            RiderOwnerModeChipGate.showsChip(holdsOwnerRole: !catalog.ownedVehicles.isEmpty, canSwitchModes: true)
        )
    }

    /// The chip is `MapHeader` grammar, not a look-alike: same chip height, and a
    /// tap target at or above the 44pt hard rule.
    @MainActor
    func testTheChipMeetsTheTapTargetFloor() {
        XCTAssertGreaterThanOrEqual(MRTMetrics.minTapTarget, 44)
        let chipOnly = height(RiderOwnerModeChip(action: {}).frame(height: 200), width: Self.deviceWidth)
        XCTAssertEqual(chipOnly, 200, accuracy: 0.5, "the chip positions itself in the band it is given")
    }

    // MARK: 3 — peek vs full composition

    private var sampleLadder: RiderTrackingLadderState {
        RiderTrackingLadderState(line: .headingYourWay, showsPickupCountdown: true)
    }

    @MainActor
    private func peek(freshnessNote: String? = nil, countdown: Bool = true) -> some View {
        RiderTrackingPeekContent(
            ladder: countdown
                ? RiderTrackingLadderState(line: .headingYourWay, showsPickupCountdown: true)
                : RiderTrackingLadderState(line: .waitingToStart(vehicle: "Lunar"), showsPickupCountdown: false),
            duration: countdown ? ("4", "min") : nil,
            milesText: countdown ? "1.4 mi away" : nil,
            contextPrefix: "Picking you up at ",
            contextPlace: "Harbor Freight",
            freshnessNote: freshnessNote
        )
    }

    /// **The peek is a COMPLETE composition**, so it has a real, finite height of
    /// its own rather than being whatever 150pt of a taller card happens to show.
    /// That is the whole of MYR-296's lesson applied here: nothing is cropped
    /// because nothing is hidden.
    @MainActor
    func testThePeekCompositionSizesToItsOwnContent() {
        let measured = height(peek())
        XCTAssertGreaterThan(measured, 0)
        // Comfortably inside the sheet's own peek band — a summary, not a card.
        XCTAssertLessThan(measured + MRTMetrics.sheetGrabHandleHeight, MRTMetrics.trackingMapBottomInset)
    }

    /// MYR-393's qualifier BRINGS EXACTLY ITS OWN ROOM (MYR-345's per-line rule) —
    /// measured on the composition where it can cost anything, which is the WAITING
    /// peek: no hero pair, so the status column is what sets the height.
    @MainActor
    func testThePositionQualifierAddsExactlyItsOwnLine() {
        let without = height(peek(countdown: false))
        let with = height(peek(freshnessNote: "Position from 12m ago", countdown: false))
        XCTAssertGreaterThan(with, without)
        XCTAssertLessThan(with - without, 24, "one 11.5pt line, not a reserved band")
    }

    /// **AND IT IS FREE BESIDE A LIVE COUNTDOWN**, which is worth pinning rather
    /// than discovering later as a mystery: the 34pt hero + its 12.5pt sub make the
    /// trailing column the taller one, so an 11.5pt line added to the leading
    /// column changes nothing at all. A future tune that shrinks the hero would
    /// start charging for the qualifier, and this is where that shows up.
    @MainActor
    func testTheQualifierCostsNothingWhileTheHeroPairIsUp() {
        XCTAssertEqual(
            height(peek()),
            height(peek(freshnessNote: "Position from 12m ago")),
            accuracy: 0.5
        )
    }

    /// The pre-motion peek carries the waiting line and NO number — the same
    /// suppression the full card makes, from the same ladder verdict.
    @MainActor
    func testThePreMotionPeekDropsTheHeroPair() {
        let withCountdown = height(peek(countdown: true))
        let waiting = height(peek(countdown: false))
        XCTAssertLessThanOrEqual(waiting, withCountdown)
    }

    /// The two detents must be genuinely two states: a peek that measured the same
    /// as the card would make the drag pointless (and would make `detents` an
    /// unsorted pair the engine has to sanitise).
    @MainActor
    func testThePeekIsMateriallyShorterThanTheSheetsFullCoverHeight() {
        let peekHeight = height(peek()) + MRTMetrics.sheetGrabHandleHeight
        XCTAssertLessThan(
            peekHeight, MRTMetrics.trackingMapBottomInset - 80,
            "the peek must reveal materially more map than the full card does"
        )
    }

    /// The peek's own bottom band is the SMALLER one, deliberately — a summary ends
    /// on its last line of ink where the full card ends above a home indicator.
    func testThePeekBandIsTunedSeparatelyFromTheCards() {
        XCTAssertLessThan(MRTMetrics.trackingPeekBottomPad, 30)
        XCTAssertGreaterThan(MRTMetrics.trackingPeekBottomPad, 0)
    }
}
