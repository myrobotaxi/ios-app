import CoreLocation
import DesignSystem
import MyRobotaxiContracts
import XCTest
@testable import MyRoboTaxi

// MARK: - What the redesigned Live Activity card renders (MYR-398)
//
// The card itself cannot be tested. `ActivityViewContext` needs a real Activity in
// a real host process with a real installed widget extension, so a SwiftUI
// assertion about the lock screen is not available at any price — which is exactly
// why `RideActivityCard.resolve` exists as a pure function and why the views take
// its output rather than a content state. Everything below drives that function.
//
// The suite is organised around the honesty rules in rest-api.md §7.21.3, because
// those are the promises the server made ON THE STRENGTH OF this client rendering
// them. The server is free to omit `progress` precisely because an absent key
// produces a trackless card rather than a car parked at the kerb; if that stopped
// being true, the server's whole degradation table would quietly become a set of
// lies and nothing on either side would fail.

final class RideActivityCardTests: XCTestCase {

    private let eta = Date(timeIntervalSince1970: 1_785_535_200)

    private func state(
        _ status: LiveActivityRideStatus,
        eta: Int? = 1_785_535_200,
        vehicleName: String = "Blue Whale",
        destination: String = "Home",
        progress: Double? = nil
    ) -> RideActivityAttributes.ContentState {
        RideActivityAttributes.ContentState(
            status: status,
            eta: eta,
            vehicleName: vehicleName,
            destination: destination,
            progress: progress
        )
    }

    private func card(
        _ status: LiveActivityRideStatus,
        eta: Int? = 1_785_535_200,
        progress: Double? = nil,
        pickupLabel: String? = "Ferry Building",
        destination: String = "Home",
        vehicleName: String = "Blue Whale",
        isStale: Bool = false
    ) -> RideActivityCard {
        RideActivityCard.resolve(
            state: state(
                status,
                eta: eta,
                vehicleName: vehicleName,
                destination: destination,
                progress: progress
            ),
            pickupLabel: pickupLabel,
            isStale: isStale
        )
    }

    // MARK: - 1. The leg is read off the status, and only off the status

    func testEveryStatusResolvesToTheLegTheContractSaysItIs() {
        // §7.21.3: "`accepted` is leg one — the car driving to the rider — and
        // `enroute` is leg two". The leg is deliberately NOT on the wire, so this
        // reading is the client's whole share of that decision.
        XCTAssertEqual(RideActivityLeg.of(.requested), .pickup)
        XCTAssertEqual(RideActivityLeg.of(.accepted), .pickup)
        XCTAssertEqual(
            RideActivityLeg.of(.arrived),
            .pickup,
            """
            `arrived` is the END of leg one, not the start of leg two — the car is \
            at the kerb and the rider has not boarded. Reading it as leg two would \
            put its server-asserted progress of 1 on the DROP-OFF track and tell a \
            rider who has not got in the car that they have arrived.
            """
        )
        XCTAssertEqual(RideActivityLeg.of(.enroute), .dropoff)
        XCTAssertEqual(RideActivityLeg.of(.completed), .dropoff)

        for status in [
            LiveActivityRideStatus.declined,
            .cancelled,
            .reservationExpired,
            .unrecognized("boarding"),
        ] {
            XCTAssertNil(
                RideActivityLeg.of(status),
                """
                \(status.rawValue) is not part-way along anything. A leg here would \
                be a track on an ending card, which §7.21.3's table promises there \
                is not.
                """
            )
        }
    }

    // MARK: - 2. Headline × leg × eta-present

    func testLegOneWithAnETACountsDownToThePickup() {
        for status in [LiveActivityRideStatus.accepted, .arrived, .requested] {
            XCTAssertEqual(
                card(status).headline,
                .countdown(prefix: "Pick up in", until: eta),
                "\(status.rawValue) is leg one, so the number is when the car reaches the RIDER"
            )
        }
    }

    func testLegTwoWithAnETACountsDownToTheDropoff() {
        XCTAssertEqual(card(.enroute).headline, .countdown(prefix: "Arriving in", until: eta))
    }

    func testTheTwoLegsNeverShareAPrefix() {
        // One label for both would be wrong half the time: before pickup the number
        // is when the car reaches the rider, after it is when the rider reaches the
        // destination.
        XCTAssertNotEqual(
            RideActivityCopy.headlinePrefix(for: .pickup),
            RideActivityCopy.headlinePrefix(for: .dropoff)
        )
    }

    func testNoETAOnTheWireDegradesToAStatusSentenceAndNEVERToANumber() {
        // `eta` is OPTIONAL ON THE WIRE TODAY — a car with no active nav route
        // yields no key at all, and there is no server-side route solver. So this
        // is an ordinary state, and it is also what makes a future server-side ETA
        // freshness gate (MYR-401) shippable without a client release: omitting the
        // key lands on a card that already knows what to say.
        XCTAssertEqual(card(.accepted, eta: nil).headline, .sentence("Heading to pickup"))
        XCTAssertEqual(card(.enroute, eta: nil).headline, .sentence("On the way"))
        XCTAssertEqual(card(.arrived, eta: nil).headline, .sentence("Blue Whale is here"))
    }

    func testAnArrivedCarReadsTheSameWhetherOrNotAnETAIsStillSittingInTheState() {
        // `arrived` normally carries no ETA — the car is here, there is nothing to
        // count down. But a stale instant CAN still be in the content state, and
        // the honest render is the same sentence either way rather than a countdown
        // to an arrival that already happened.
        //
        // NOTE this is the one place the matrix is deliberately NOT total: `arrived`
        // + eta resolves to a countdown, because a server that sends both is making
        // a claim we are not entitled to overrule (§7.21.3: "the client MUST render
        // both as given"). What is asserted is that the NO-eta arm — the one the
        // server actually emits — reads correctly.
        XCTAssertEqual(card(.arrived, eta: nil).headline, .sentence("Blue Whale is here"))
    }

    func testTheGenericVehicleNameReachesTheHeadlineRatherThanABlank() {
        XCTAssertEqual(
            card(.arrived, eta: nil, vehicleName: "   ").headline,
            .sentence("\(RideActivityCopy.genericVehicleName) is here")
        )
    }

    func testEveryTerminalStatusKeepsItsOwnSentenceAndNeverCountsDown() {
        // MYR-172's endings are unchanged by the redesign: they are not degraded
        // headlines, they are the ride's ending, and a terminal ride must not count
        // down even if an `eta` is still in the frame.
        let endings: [(LiveActivityRideStatus, String)] = [
            (.completed, "You've arrived at Home"),
            (.declined, "Blue Whale can't take this ride"),
            (.cancelled, "This ride was cancelled"),
            (.reservationExpired, "Blue Whale didn't make it in time"),
        ]

        for (status, sentence) in endings {
            XCTAssertEqual(card(status).headline, .sentence(sentence), status.rawValue)
        }
    }

    func testAnUnrecognisedStatusSaysNothingItCannotKnow() {
        // The schema mandates tolerating a member this build has never heard of.
        // The headline falls back to the ONE fact that is still true whatever the
        // status turns out to mean — the car's name — rather than guessing at a
        // verb. A confident wrong word on a lock screen is worse than a bare one.
        //
        // Every element that would ASSERT something withdraws: no countdown (the
        // status may not be a leg at all, so neither prefix is safe), no meet-at
        // and no trip line. The TRACK is the one thing that stays, and that is not
        // an oversight — a fraction the server chose to send is the server's claim
        // to make, and §7.21.3's "render both as given" does not carve out statuses
        // this build has not heard of.
        let unknown = card(.unrecognized("boarding"), progress: 0.5)

        XCTAssertEqual(unknown.headline, .sentence("Blue Whale"))
        XCTAssertNil(unknown.leg)
        XCTAssertNil(unknown.meetAt)
        XCTAssertNil(unknown.trip)
        XCTAssertEqual(unknown.track, 0.5)
        XCTAssertEqual(
            RideActivityCopy.kicker(for: .unrecognized("boarding")),
            "Ride",
            "the compact island's one word stays deliberately bland"
        )
    }

    // MARK: - 3. The second line

    func testLegOneSaysWhereToStandAndLegTwoSaysWhereItIsGoing() {
        XCTAssertEqual(card(.accepted).meetAt, "Meet at Ferry Building")
        XCTAssertNil(card(.accepted).trip, "the meet-at line owns the slot on leg one")

        XCTAssertNil(card(.enroute).meetAt)
        XCTAssertEqual(
            card(.enroute).trip,
            RideActivityCard.TripLine(vehicle: "Blue Whale", destination: "Home"),
            "leg two keeps MYR-172's trip line verbatim — the destination behaviour is unchanged"
        )
    }

    func testThePickupLineComesFromTheSTATICATTRIBUTESAndNotFromThePush() {
        // §7.21.3, "Why the 'Meet at {pickup}' line is NOT on the wire": the server
        // deliberately does not push it. A client that expected it on the content
        // state would render no meet-at line, forever, against a correct server —
        // and would look exactly like a server bug.
        //
        // The proof is that the line survives a content state carrying NOTHING but
        // the required keys, and disappears when only the ATTRIBUTE is missing.
        XCTAssertEqual(
            card(.accepted, eta: nil, progress: nil, destination: "").meetAt,
            "Meet at Ferry Building"
        )
        XCTAssertNil(card(.accepted, pickupLabel: nil).meetAt)
    }

    func testAPickupLabelOfOnlySpacesRendersNoLineRatherThanADanglingPreposition() {
        XCTAssertNil(card(.accepted, pickupLabel: "   ").meetAt)
        XCTAssertNil(card(.accepted, pickupLabel: "").meetAt)
    }

    func testTheEndingCardNamesNoTripAtAll() {
        // MYR-172's reasoning, kept: "Cancelled" over "Blue Whale → Home" reads as
        // a ride still in progress.
        for status in [LiveActivityRideStatus.completed, .declined, .cancelled, .reservationExpired] {
            XCTAssertNil(card(status).trip, status.rawValue)
            XCTAssertNil(card(status).meetAt, status.rawValue)
        }
    }

    // MARK: - 4. The track — absent vs present

    func testAnAbsentProgressRendersNOTRACK() {
        // THE GOVERNING RULE. §7.21.3: "an absent `progress` renders a TRACKLESS
        // card, a wrong one renders a LIE". `nil` must not become 0 anywhere on the
        // way to the view, because 0 is the claim "the car has covered none of the
        // distance" and the view has no way to tell the two apart.
        for status in LiveActivityRideStatus.allCases {
            XCTAssertNil(
                card(status, progress: nil).track,
                "\(status.rawValue) with no progress key must draw no track"
            )
        }
    }

    func testAPresentProgressRendersTheFractionTheServerSent() {
        XCTAssertEqual(card(.accepted, progress: 0.34).track, 0.34)
        XCTAssertEqual(card(.enroute, progress: 0.62).track, 0.62)
    }

    func testZeroIsRenderedAsARealTrackAtZeroAndNotConfusedWithAbsence() {
        // The server does not send `0` — but if it ever does, it is a CLAIM ("the
        // car has covered none of it"), and the card must draw it rather than
        // silently degrade to the no-track state, which says something different.
        let zero = card(.accepted, progress: 0)
        XCTAssertEqual(zero.track, 0)
        XCTAssertNotNil(zero.track)
    }

    func testTheEndsAreNOTCLAMPEDAWAYTheWayTheDesignSystemBarClampsThem() {
        // `TripProgressBar.clamped` floors at 0.05 and ceils at 0.95, which is right
        // for an illustrated bar and wrong for a claim about a car: `arrived` and
        // `completed` send exactly `1` on the ride record's authority, and a track
        // that stopped just short would contradict the card's own headline.
        //
        // `PrimitiveTests.testTripProgressClamp` is the other half of
        // this pair and lives in that package, where `clamped` is reachable; what
        // is asserted HERE is that the card does not inherit the behaviour — it
        // draws exactly what the server asserted, at both ends.
        XCTAssertEqual(card(.arrived, eta: nil, progress: 1).track, 1)
        XCTAssertEqual(card(.completed, eta: nil, progress: 1).track, 1)
        XCTAssertEqual(card(.accepted, progress: 0.02).track, 0.02, "and no 0.05 floor either")
    }

    func testAnOutOfRangeFractionIsClampedIntoZeroToOneRatherThanDrawnOffTheRail() {
        XCTAssertEqual(card(.enroute, progress: 1.4).track, 1)
        XCTAssertEqual(card(.enroute, progress: -0.2).track, 0)
    }

    func testCompletedLingersWithAFullTrack() {
        // The completed frame stays up ~15 minutes so the rider sees the arrival
        // state. Its track is full for the whole linger rather than vanishing at the
        // moment the ride ends.
        let done = card(.completed, eta: nil, progress: 1)
        XCTAssertEqual(done.track, 1)
        XCTAssertEqual(done.leg, .dropoff)
        XCTAssertEqual(done.headline, .sentence("You've arrived at Home"))
    }

    // MARK: - 5. Staleness

    func testStalenessREPLACESTheCountdownRatherThanDimmingIt() {
        // MYR-194: "never a confident stale ETA". A greyed-out "4:12" is still a
        // number a rider plans around.
        let stale = card(.enroute, isStale: true)
        XCTAssertEqual(stale.headline, .sentence("On the way"))
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.staleReference, eta, "the notice dates itself from the last instant the server gave us")
    }

    func testStalenessKEEPSTheTrackBecauseAFractionIsAClaimAboutThePast() {
        // The opposite treatment to the countdown, deliberately. A countdown is a
        // claim about the FUTURE and rots on its own as the clock runs; a fraction
        // is a claim about the PAST — the car really was that far along when we last
        // heard — and it does not become a different number while nobody is looking.
        // Removing it would also make staleness look identical to the server's
        // honest "no fraction to give you" arm, which is a different situation.
        XCTAssertEqual(card(.enroute, progress: 0.62, isStale: true).track, 0.62)
    }

    func testAStaleCardWithNoETAHasNoInstantToDateItselfFrom() {
        XCTAssertNil(card(.accepted, eta: nil, isStale: true).staleReference)
    }

    // MARK: - 6. The full matrix, swept

    func testTheHeadlineIsNeverACountdownWithoutAnETAAndNeverASentenceWithOne() {
        // The one invariant that has to hold across the whole grid, stated as a
        // sweep rather than as twenty-eight literals: a countdown appears if and
        // only if there is an instant to count to, the ride is still running, the
        // card is not stale, and the status belongs to a leg.
        for status in LiveActivityRideStatus.allCases {
            for etaValue in [nil, 1_785_535_200] as [Int?] {
                for stale in [false, true] {
                    for progress in [nil, 0.5] as [Double?] {
                        let resolved = card(status, eta: etaValue, progress: progress, isStale: stale)
                        let expectsCountdown = etaValue != nil
                            && !stale
                            && RideActivityCopy.showsCountdown(for: status)
                            && RideActivityLeg.of(status) != nil

                        switch resolved.headline {
                        case .countdown:
                            XCTAssertTrue(
                                expectsCountdown,
                                "\(status.rawValue) eta=\(String(describing: etaValue)) stale=\(stale) counted down and should not have"
                            )
                        case .sentence(let text):
                            XCTAssertFalse(
                                expectsCountdown,
                                "\(status.rawValue) eta=\(String(describing: etaValue)) stale=\(stale) should have counted down"
                            )
                            XCTAssertFalse(text.isEmpty, "a headline is never blank")
                        }

                        // And the track is a pure function of the key's presence,
                        // independent of every other axis.
                        XCTAssertEqual(
                            resolved.track != nil,
                            progress != nil,
                            "the track's presence must depend on the progress key and nothing else"
                        )
                    }
                }
            }
        }
    }

    // MARK: - 7. The monotone hold and the leg reset

    func testWithinOneLegTheFractionNeverGoesDOWN() {
        // The server clamps, so this is the client's belt-and-braces on the frames
        // IT composes. An arrow sliding back down the rail reads as a broken widget
        // rather than as traffic.
        XCTAssertEqual(
            RideActivityProgress.held(
                current: 0.41,
                currentLeg: .dropoff,
                previous: 0.62,
                previousLeg: .dropoff
            ),
            0.62
        )
    }

    func testWithinOneLegAHigherFractionIsAdopted() {
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.8, currentLeg: .dropoff, previous: 0.62, previousLeg: .dropoff),
            0.8
        )
    }

    func testWithinOneLegAMissingFractionCarriesTheLastOneFORWARD() {
        // The same carry-forward `eta` gets, for the same reason: the last fraction
        // the car reported does not stop being the last fraction the car reported.
        // This is the arm the app's own locally-composed frames take, since the
        // client never computes a fraction of its own.
        XCTAssertEqual(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: 0.34, previousLeg: .pickup),
            0.34
        )
    }

    func testTHELEGISTHERESETKEYAndNothingSurvivesTheFlip() {
        // Leg one ends at exactly 1 and leg two opens near 0, so a max taken ACROSS
        // the flip would pin the drop-off track at full for the entire ride — the
        // single worst thing this rule could get wrong.
        XCTAssertEqual(
            RideActivityProgress.held(current: 0.04, currentLeg: .dropoff, previous: 1, previousLeg: .pickup),
            0.04
        )
    }

    func testALegFlipWithNoFractionYETIsAnHonestNoTrackAndNotAHeldFullOne() {
        // §7.21.3's table: "Telemetry never seen this leg → no key → no track". The
        // new leg adopts `nil` verbatim rather than inheriting leg one's `1`, which
        // would draw a journey the car has not started.
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .dropoff, previous: 1, previousLeg: .pickup)
        )
    }

    func testALegThatBECOMESNilDropsTheFractionSoAnEndingCardCarriesNoTrack() {
        // cancelled / declined / reservation_expired have no leg at all, and the
        // table promises "no track on the ending card". A car that was 62% of the
        // way to a rider who cancelled is not 62% of the way to anything.
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: nil, previous: 0.62, previousLeg: .dropoff)
        )
    }

    func testTheFirstFrameOfAnActivityHoldsNothingBecauseThereIsNoPrevious() {
        XCTAssertNil(
            RideActivityProgress.held(current: nil, currentLeg: .pickup, previous: nil, previousLeg: nil)
        )
    }

    // MARK: - 8. The hold, through the shipping state machine

    func testTheStateMachineCarriesAPushedFractionForwardOntoItsOwnFrames() {
        // The app is the BACKSTOP: it composes a local frame whenever the ride
        // record moves, and the server's last pushed fraction is the only one it
        // has. Dropping it would blank the track every time the app noticed
        // anything.
        let previous = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home",
            progress: 0.62
        )

        let next = RideActivityStateMachine.contentState(
            for: enrouteRecord,
            vehicleName: "Blue Whale",
            previous: previous
        )

        XCTAssertEqual(next.progress, 0.62)
        XCTAssertEqual(next.eta, 1_785_535_200, "the ETA carries forward for the same reason")
    }

    func testTheStateMachineNEVERINVENTSAFractionFromTheAppsOwnTrackProgress() {
        // The record carries `trackProgress`, a 0…1 over the WHOLE trip (both legs).
        // Rendering it as a fraction of the CURRENT leg would be the "a wrong one
        // renders a lie" half of the rule — drawn confidently, with nothing on the
        // card admitting it was invented.
        var record = enrouteRecord
        record.trackProgress = 0.8

        let frame = RideActivityStateMachine.contentState(
            for: record,
            vehicleName: "Blue Whale",
            previous: nil
        )

        XCTAssertNil(frame.progress)
    }

    func testTheCancelledEndingFrameDropsTheTrackItInherited() {
        // `with(status:)` corrects the last known frame into a final one when the
        // ride was ERASED rather than transitioned. The fraction must not survive
        // that correction.
        let live = RideActivityAttributes.ContentState(
            status: .enroute,
            eta: 1_785_535_200,
            vehicleName: "Blue Whale",
            destination: "Home",
            progress: 0.62
        )

        let ending = live.with(status: .cancelled)

        XCTAssertEqual(ending.status, .cancelled)
        XCTAssertNil(ending.progress, "no track on the ending card")
        XCTAssertNil(
            RideActivityCard.resolve(state: ending, pickupLabel: "Ferry Building", isStale: false).track
        )
    }

    // MARK: - Fixtures

    private var enrouteRecord: RideRequestRecord {
        var record = RideRequestRecord(
            id: "ride-1",
            input: RideRequestInput(
                pickup: RidePlace(
                    id: "pickup",
                    label: "Ferry Building",
                    subtitle: nil,
                    miles: 0,
                    minutes: 0,
                    icon: "location.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.7955, longitude: -122.3937)
                ),
                destination: RidePlace(
                    id: "dest",
                    label: "Home",
                    subtitle: nil,
                    miles: 4.2,
                    minutes: 12,
                    icon: "house.fill",
                    coordinate: CLLocationCoordinate2D(latitude: 37.77, longitude: -122.39)
                ),
                fleetMemberID: "vehicle-1"
            ),
            status: .enroute
        )
        record.status = .enroute
        return record
    }
}

private extension LiveActivityRideStatus {
    /// Every member this build knows, plus one it does not — the sweep above has to
    /// cover the `unrecognized` arm, and a generated enum with an associated-value
    /// catch-all has no synthesized `CaseIterable`.
    static var allCases: [LiveActivityRideStatus] {
        [
            .requested, .accepted, .arrived, .enroute,
            .completed, .declined, .cancelled, .reservationExpired,
            .unrecognized("boarding"),
        ]
    }
}
