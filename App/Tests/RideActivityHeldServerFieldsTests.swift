import CoreLocation
import MyRoboTaxiKit
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - The server's fields survive a local recomposition (MYR-423)
//
// THE CLIENT'S REPRO, r20 build 202608020949: the card and the island showed the
// server-pushed "Pick up in 12 min"; he unlocked the phone and re-locked it; the
// card read "Pickup soon / Last updated 11:19 AM". The ETA the server delivered was
// gone, and nothing would bring it back until the next push.
//
// THE CAUSE IS NOT IN THE STATE MACHINE'S LOGIC, WHICH WAS ALWAYS RIGHT. It has
// held `eta` forward since MYR-172 ("carrying the PREVIOUS eta forward is not a
// guess"), over an input that could not contain one: the coordinator passed
// `RideActivityPhase.live`'s state, i.e. this process's memory of the last frame IT
// composed, and a locally-composed frame has no `eta`, no `progress` and no `asOf`
// by construction. So the carry-forward inherited nil from nil and the composed
// frame asserted nil over the server's values on the card. A composed frame does
// not decline to speak about a field — it carries a value for every field — so
// "carrying nothing forward" is an active, destructive assertion.
//
// ⚠️ THE STUB IS WHY THESE TESTS ARE PROOF RATHER THAN TAUTOLOGY.
// `StubRideActivityPresenter.deliveredStates` is written by `start`/`update` (as
// the system does) AND by `deliver(push:)`, which is the half of the truth this
// process never sees. A stub that only echoed our own updates back could not tell
// "held the server's value" from "re-wrote its own", because on such a stub the two
// are the same bytes.

@MainActor
final class RideActivityHeldServerFieldsTests: XCTestCase {

    /// A pickup ETA twelve minutes out, an instant the CAR reported and only the
    /// server knows.
    private let pushedETA = Int(Date().addingTimeInterval(12 * 60).timeIntervalSince1970)
    private let pushedAsOf = Int(Date().addingTimeInterval(-30).timeIntervalSince1970)

    // MARK: - 1 · The client's repro

    /// **UNLOCK, THEN RE-LOCK, AND "12 min" IS STILL THERE.**
    ///
    /// Driven through `handleLaunchOrForeground` because that is the ACTUAL path an
    /// unlock takes — `RootView`'s `.onChange(of: scenePhase)` calls exactly this on
    /// `.active`, and it ends by funnelling into `handleRideChange`. Driving
    /// `handleRideChange` alone would test the merge while skipping the reconcile,
    /// the adopt and the re-seat that a real foreground runs first.
    func testAForegroundRecompositionHoldsTheServerPushedETA() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        let record = makeRecord(status: .accepted)

        await coordinator.handleRideChange(record)
        XCTAssertNil(
            presenter.deliveredContentState(rideID: "ride-1")?.eta,
            "A locally started card opens with no countdown — MYR-172's own rule."
        )

        // THE PUSH. It happens entirely outside this process: APNs replaces the
        // Activity's content state and the app is not told.
        presenter.deliver(
            push: pushedFrame(status: .accepted, progress: 0.4),
            rideID: "ride-1"
        )

        // THE UNLOCK — `RootView`'s `.onChange(of: scenePhase)` on `.active`.
        await coordinator.handleLaunchOrForeground {
            RideActivityAccountRide(record: record, isResolved: true)
        }
        await settle()

        XCTAssertEqual(
            coordinator.phase.state?.eta,
            pushedETA,
            """
            THE DIRECT GUARD, and the one an assertion on the card alone misses. \
            `phase` is what the NEXT composition inherits from, so this is where the \
            defect actually lives — and it is silent at this instant, because a \
            coordinator whose memory has diverged from the card writes nothing until \
            something else makes it speak.
            """
        )

        // …AND THE SAME FOREGROUND MAKES IT SPEAK. `RootView` also fires
        // `refreshActiveRide()` on `.active` (MYR-402), which folds the authoritative
        // §7.8 record — so a ride that advanced while the phone was locked lands its
        // status change through `.onChange(of: activeRequest)` moments later. THAT is
        // the write that reached the client's lock screen.
        await coordinator.handleRideChange(makeRecord(status: .arrived))
        await settle()

        let written = try XCTUnwrap(presenter.updates.last)
        XCTAssertEqual(written.status, .arrived)
        XCTAssertEqual(
            written.eta,
            pushedETA,
            "The frame the unlock wrote must still carry the twelve minutes the server sent."
        )

        let onCard = try XCTUnwrap(presenter.deliveredContentState(rideID: "ride-1"))
        XCTAssertEqual(
            onCard.eta,
            pushedETA,
            """
            THE CLIENT'S BUG. Foregrounding recomposed the Activity locally from the \
            app's own ride record — which carries no etaMinutes — and wrote that \
            poorer frame over the pushed one, so "Pick up in 12 min" became "Pickup \
            soon".
            """
        )
        XCTAssertEqual(onCard.progress, 0.4, "Progress is the server's on the same terms as the ETA.")
        XCTAssertEqual(
            onCard.asOf,
            pushedAsOf,
            """
            And `asOf` with them. Dropping it is not neutral: absence means "this \
            server does not say", so a blanked `asOf` makes an up-to-date card render \
            the wordless "Waiting for an update" — which is the second half of the \
            line the client photographed.
            """
        )
        XCTAssertTrue(
            presenter.updates.allSatisfy { $0.eta == pushedETA },
            "No frame this coordinator writes may carry an ETA the server did not send."
        )
    }

    // MARK: - 2 · A local status change still applies

    /// The app is still the BACKSTOP, and the fix must not turn holding into
    /// muteness. The status is the one thing the client is authoritative about — it
    /// comes from the rider's own service — so it lands, and the server's fields ride
    /// along with it.
    func testALocalStatusChangeStillAppliesAndCarriesTheHeldFieldsWithIt() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.deliver(push: pushedFrame(status: .accepted, progress: 0.6), rideID: "ride-1")

        // The car reached the kerb. `accepted → arrived` is the SAME leg (pickup), so
        // nothing about the ETA or the fraction is invalidated by it.
        await coordinator.handleRideChange(makeRecord(status: .arrived))
        await settle()

        let written = try XCTUnwrap(presenter.updates.last)
        XCTAssertEqual(written.status, .arrived, "A status the app knows must still reach the card.")
        XCTAssertEqual(written.eta, pushedETA)
        XCTAssertEqual(written.progress, 0.6)
        XCTAssertEqual(written.asOf, pushedAsOf)
        XCTAssertEqual(
            presenter.deliveredContentState(rideID: "ride-1")?.status,
            .arrived
        )
    }

    // MARK: - 3 · A newer push replaces what was held

    /// Holding is not latching. The server remains the author of these three fields,
    /// and the value the client holds is only ever the LAST one delivered.
    func testAGenuinelyNewerServerPushReplacesTheHeldValues() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.deliver(push: pushedFrame(status: .accepted, progress: 0.2), rideID: "ride-1")
        await coordinator.handleLaunchOrForeground {
            RideActivityAccountRide(record: self.makeRecord(status: .accepted), isResolved: true)
        }

        // The ticker speaks again: four minutes out, further along.
        let newerETA = Int(Date().addingTimeInterval(4 * 60).timeIntervalSince1970)
        let newerAsOf = Int(Date().timeIntervalSince1970)
        presenter.deliver(
            push: RideActivityAttributes.ContentState(
                status: .accepted,
                eta: newerETA,
                vehicleName: "Lunar",
                destination: "Home",
                progress: 0.7,
                asOf: newerAsOf
            ),
            rideID: "ride-1"
        )

        // Any local recomposition at all — here the same kerb-side status change.
        await coordinator.handleRideChange(makeRecord(status: .arrived))
        await settle()

        let written = try XCTUnwrap(presenter.updates.last)
        XCTAssertEqual(written.eta, newerETA, "The newest push wins; nothing is latched.")
        XCTAssertNotEqual(written.eta, pushedETA)
        XCTAssertEqual(written.progress, 0.7)
        XCTAssertEqual(written.asOf, newerAsOf)
    }

    // MARK: - 4 · The leg flip clears what the leg owned

    /// **THE ETA IS LEG-SCOPED, AND FOR A SHARPER REASON THAN STALENESS.**
    ///
    /// `RideActivityCard.figure` reads a pickup ETA as a countdown ("8 min") and a
    /// dropoff ETA as a clock time ("3:42 PM"), and `RideActivityCopy.showsFigure` is
    /// true for `accepted` AND `enroute`. So a pickup arrival instant surviving the
    /// flip would not merely linger — it would be re-read as the moment the rider is
    /// DROPPED OFF, stated with full confidence. Before this issue `previous?.eta`
    /// was always nil, so the leg question could never arise; it can now.
    func testALegFlipClearsTheLegScopedFieldsAndKeepsAsOf() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .arrived))
        // End of leg one: the pickup rail is full and the pickup ETA is in hand.
        presenter.deliver(push: pushedFrame(status: .arrived, progress: 1.0), rideID: "ride-1")

        // The rider boarded and started the ride. Leg two.
        await coordinator.handleRideChange(makeRecord(status: .enroute))
        await settle()

        let written = try XCTUnwrap(presenter.updates.last)
        XCTAssertEqual(written.status, .enroute)
        XCTAssertNil(
            written.eta,
            "Leg one's arrival instant must not be re-read as leg two's dropoff clock."
        )
        XCTAssertNil(
            written.progress,
            """
            MYR-398's existing rule, unchanged: leg one ends at exactly 1 and leg two \
            opens near 0, so holding the fraction across the flip would draw a \
            completed journey the car has not started.
            """
        )
        XCTAssertEqual(
            written.asOf,
            pushedAsOf,
            """
            `asOf` is NOT leg-scoped — it says when the server last learned something \
            about this RIDE, which a leg flip does not change.
            """
        )
    }

    /// The pure rule on its own, including the arm the equality check alone gets
    /// wrong: two statuses with NO leg are not "the same leg".
    func testTheHeldETARuleIsLegScopedAndRefusesALeglessStatus() {
        XCTAssertEqual(
            RideActivityHeldETA.held(currentLeg: .pickup, previous: 900, previousLeg: .pickup),
            900
        )
        XCTAssertNil(RideActivityHeldETA.held(currentLeg: .dropoff, previous: 900, previousLeg: .pickup))
        XCTAssertNil(RideActivityHeldETA.held(currentLeg: .pickup, previous: 900, previousLeg: .dropoff))
        XCTAssertNil(
            RideActivityHeldETA.held(currentLeg: nil, previous: 900, previousLeg: nil),
            """
            `nil == nil` is true and would wave a cancelled ride's frame straight \
            through with an arrival instant on it. A ride with no leg is not arriving \
            anywhere.
            """
        )
        XCTAssertNil(RideActivityHeldETA.held(currentLeg: .pickup, previous: nil, previousLeg: .pickup))
    }

    // MARK: - The two paths that recompose from scratch

    /// **ADOPTION IS THE OTHER HALF, AND IT WAS THE BLATANT ONE.** The launch /
    /// foreground spelling composed with `previous: nil` outright — its own comment
    /// said the pushed fields "are the SERVER's and are not ours to re-assert", which
    /// is exactly right and is not what `nil` does.
    func testAdoptingARestoredCardInheritsItsDeliveredFieldsRatherThanBlankingThem() async throws {
        let (coordinator, presenter, _) = makeCoordinator()
        let record = makeRecord(status: .accepted)

        // A card left by a PREVIOUS process, carrying what the server pushed to it.
        presenter.restored = [RideActivitySnapshot(rideID: "ride-1", lifecycle: .active)]
        presenter.deliver(push: pushedFrame(status: .accepted, progress: 0.5), rideID: "ride-1")

        await coordinator.handleLaunchOrForeground {
            RideActivityAccountRide(record: record, isResolved: true)
        }
        await settle()

        XCTAssertEqual(presenter.adopted, ["ride-1"], "Adopt, never duplicate — MYR-405, unchanged.")
        XCTAssertEqual(presenter.startCount, 0)
        XCTAssertEqual(
            coordinator.phase.state?.eta,
            pushedETA,
            """
            The ADOPTION path's own guard: what the coordinator adopted as its \
            remembered frame has to be the restored card's, not the stand-in composed \
            for it. Asserting only on the card would pass with `previous: nil` \
            restored, because an adoption writes nothing by itself — it simply leaves \
            the next composition holding an empty hand.
            """
        )
        let onCard = try XCTUnwrap(presenter.deliveredContentState(rideID: "ride-1"))
        XCTAssertEqual(onCard.eta, pushedETA)
        XCTAssertEqual(onCard.progress, 0.5)
        XCTAssertEqual(onCard.asOf, pushedAsOf)
        XCTAssertEqual(
            onCard.vehicleName,
            "Lunar",
            """
            The wire's `vehicleName` outranks whatever the client resolved from its \
            own fleet list — MYR-417's finding, which is the same class of clobber \
            one field over.
            """
        )
    }

    /// The ending frame for a REMOTELY CANCELLED ride, which is an erasure rather
    /// than a transition. It is now built from a state that genuinely holds an ETA,
    /// so `with(status:)` has to clear it — `cancelled` has no leg, and §7.21.3
    /// promises no track and no figure on that card.
    func testATerminalFrameHoldsNoArrivalInstant() async throws {
        let (coordinator, presenter, _) = makeCoordinator()

        await coordinator.handleRideChange(makeRecord(status: .accepted))
        presenter.deliver(push: pushedFrame(status: .accepted, progress: 0.4), rideID: "ride-1")

        // The record disappears: the wire's `cancelled` maps to no app status at all.
        await coordinator.handleRideChange(nil)
        await settle()

        let ending = try XCTUnwrap(presenter.endedWith)
        XCTAssertEqual(ending.state.status, .cancelled)
        XCTAssertNil(ending.state.eta, "A car that was 12 minutes from a rider who cancelled is 12 minutes from nothing.")
        XCTAssertNil(ending.state.progress)
        XCTAssertEqual(
            ending.state.vehicleName,
            "Lunar",
            "The honest ending still names the right car — that is why the last frame is held at all."
        )
    }

    // MARK: - Helpers

    private func pushedFrame(
        status: LiveActivityRideStatus,
        progress: Double
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: pushedETA,
            vehicleName: "Lunar",
            destination: "Home",
            progress: progress,
            asOf: pushedAsOf
        )
    }

    private func makeCoordinator() -> (
        RideActivityCoordinator, StubRideActivityPresenter, SpyRideActivityEndpoint
    ) {
        let presenter = StubRideActivityPresenter()
        let endpoint = SpyRideActivityEndpoint()
        let coordinator = RideActivityCoordinator(
            presenter: presenter,
            endpoint: endpoint,
            isLive: true,
            sandbox: true,
            vehicleName: { "Blue Whale" },
            vehicle: { nil },
            serverRideID: { "ride-1" },
            // MYR-416 — in memory, so no test's `local ↔ server` mapping can reach
            // another test through `UserDefaults.standard`.
            identities: InMemoryRideActivityRideIDs(),
            sleep: { _ in }
        )
        return (coordinator, presenter, endpoint)
    }

    private func makeRecord(status: MyRoboTaxi.RideRequestStatus) -> RideRequestRecord {
        let place = RidePlace(
            id: "dest", label: "Home", subtitle: nil, miles: 4.2, minutes: 12,
            icon: "house.fill",
            coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
        )
        var record = RideRequestRecord(
            id: "ride-1",
            input: RideRequestInput(pickup: place, destination: place, fleetMemberID: "vehicle-1"),
            status: status
        )
        record.status = status
        return record
    }

    private func settle() async {
        for _ in 0..<12 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
}
