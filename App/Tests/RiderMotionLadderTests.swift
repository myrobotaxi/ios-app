import XCTest
import CoreLocation
import MyRobotaxiContracts
@testable import MyRoboTaxi

// MARK: - MYR-393 — the honest motion ladder
//
// THE CLIENT'S REPORT (r16, build 202607311641): the rider tracking sheet read
// "HEADING YOUR WAY · Picking you up at Harbor Freight · 4 min · 1.4 mi away" over
// a drawn car→pickup route, while his own in-car screenshot showed the Tesla
// PARKED at the Plano service centre and not at the position the app had drawn it.
//
// These tests are the failing-first reproduction, written against the pure rules
// so none of them needs a socket, a view or a clock:
//
//   • THE SWEEP — every (stage × evidence) arm, asserting the ONE invariant: no
//     state claims the car is approaching without motion evidence. This is the
//     test that would have failed before the fix, in four arms at once.
//   • THE EVIDENCE — what one `VehicleState` proves, including the two absences
//     that must NOT read as "stationary".
//   • THE LATCH — a departure is remembered (a red light is not a reversal) and is
//     scoped to a ride (one trip's departure does not vouch for the next).
//   • THE MARKER — the freshest position, or none at all.
//   • THE MODE GATE — the simulated path resolves the pre-MYR-393 rendering before
//     any evidence is consulted, which is what keeps every tracking capture
//     byte-identical.

// MARK: - Fixtures

/// A live-shaped `VehicleState`. Local to this file so it cannot be changed out
/// from under another suite.
private func state(
    speed: Int,
    status: VehicleState.Status = .parked,
    latitude: Double = 33.0432,
    longitude: Double = -96.7100,
    lastUpdated: String = "2026-07-31T18:00:00Z"
) -> VehicleState {
    VehicleState(
        vehicleId: "v1",
        name: "Lunar",
        model: "Model Y",
        year: 2026,
        color: "Quicksilver",
        status: status,
        speed: speed,
        heading: 0,
        latitude: latitude,
        longitude: longitude,
        locationName: "Tesla Plano",
        locationAddress: "2705 N Central Expy",
        chargeLevel: 68,
        estimatedRange: 240,
        interiorTemp: 71,
        exteriorTemp: 88,
        odometerMiles: 12_480,
        fsdMilesSinceReset: 0,
        lastUpdated: lastUpdated
    )
}

final class RiderMotionLadderTests: XCTestCase {

    private func resolve(
        stage: RiderTrackingStage,
        evidence: RiderMotionEvidence,
        arrivingPickup: Bool = false
    ) -> RiderTrackingLadderState {
        RiderTrackingLadder.resolve(
            stage: stage,
            evidence: evidence,
            arrivingPickup: arrivingPickup,
            vehicleName: "Lunar",
            destinationName: "SFO"
        )
    }

    // MARK: THE SWEEP

    /// **THE INVARIANT.** Across every arm of the machine, a line that claims the
    /// car is approaching may only be produced from `.moving`.
    ///
    /// Before this issue the sheet said "Heading your way" for `.toPickup`
    /// unconditionally, so this sweep fails in two arms (`.stationary`,
    /// `.unknown`) — plus their `arrivingPickup` twins, which is four.
    func testNoStateClaimsTheCarIsApproachingWithoutMotionEvidence() {
        for arm in RiderTrackingLadder.allArms {
            for arrivingPickup in [false, true] {
                let resolved = resolve(stage: arm.stage, evidence: arm.evidence, arrivingPickup: arrivingPickup)
                if resolved.line.claimsApproach {
                    XCTAssertEqual(
                        arm.evidence, .moving,
                        "\(resolved.line) claims the car is approaching on \(arm.evidence) evidence, stage \(arm.stage)"
                    )
                }
            }
        }
    }

    /// The same sweep for the OTHER half of the client's screenshot: the countdown.
    /// A pickup countdown is a claim about when a car will arrive, so it needs the
    /// same evidence the sentence does.
    func testNoPickupCountdownIsOfferedWithoutMotionEvidence() {
        for arm in RiderTrackingLadder.allArms {
            let resolved = resolve(stage: arm.stage, evidence: arm.evidence)
            if resolved.showsPickupCountdown {
                XCTAssertEqual(arm.stage, .toPickup)
                XCTAssertEqual(arm.evidence, .moving, "a countdown to pickup on \(arm.evidence) evidence")
            }
        }
    }

    /// The machine is TOTAL: every arm resolves to something, and nothing is left
    /// to a default. (A sweep that silently skipped an arm would pass the two
    /// above.)
    func testEveryArmOfTheMatrixIsCovered() {
        XCTAssertEqual(RiderTrackingLadder.allArms.count, 4 * 3)
        for arm in RiderTrackingLadder.allArms {
            XCTAssertFalse(resolve(stage: arm.stage, evidence: arm.evidence).line.text.isEmpty)
        }
    }

    // MARK: The waiting state itself

    func testAParkedCarOnAnAcceptedRideWaitsRatherThanHeads() {
        let resolved = resolve(stage: .toPickup, evidence: .stationary)
        XCTAssertEqual(resolved.line, .waitingToStart(vehicle: "Lunar"))
        XCTAssertEqual(resolved.line.text, "Waiting for Lunar to start")
        XCTAssertFalse(resolved.showsPickupCountdown)
    }

    /// **NO READ IS NOT A STATIONARY READ, AND IT IS NOT A MOVING ONE EITHER.**
    /// They render the same line here and that is a decision the switch makes
    /// explicitly; what must never happen is `.unknown` resolving to "heading".
    func testNoTelemetryAtAllAlsoWaits() {
        let resolved = resolve(stage: .toPickup, evidence: .unknown)
        XCTAssertEqual(resolved.line, .waitingToStart(vehicle: "Lunar"))
        XCTAssertFalse(resolved.showsPickupCountdown)
    }

    func testMotionEvidenceIsWhatTurnsTheLineOver() {
        let resolved = resolve(stage: .toPickup, evidence: .moving)
        XCTAssertEqual(resolved.line, .headingYourWay)
        XCTAssertTrue(resolved.showsPickupCountdown)
    }

    func testTheLastStretchToPickupStillNeedsEvidence() {
        XCTAssertEqual(
            resolve(stage: .toPickup, evidence: .moving, arrivingPickup: true).line,
            .arrivingForPickup
        )
        XCTAssertEqual(
            resolve(stage: .toPickup, evidence: .stationary, arrivingPickup: true).line,
            .waitingToStart(vehicle: "Lunar")
        )
    }

    /// The rider is INSIDE the car past pickup, so the in-ride sentences are not
    /// gated on a telemetry frame — see `claimsApproach`'s own note. Asserted so
    /// the exclusion is deliberate rather than an omission.
    func testTheInRideSentencesAreNotGatedOnEvidence() {
        for evidence in [RiderMotionEvidence.moving, .stationary, .unknown] {
            XCTAssertEqual(resolve(stage: .inRide, evidence: evidence).line, .headingToDropoff("SFO"))
            XCTAssertEqual(resolve(stage: .arrivingDropoff, evidence: evidence).line, .arrivingAtDropoff)
            XCTAssertEqual(resolve(stage: .arrivedAwaitingStart, evidence: evidence).line, .carIsHere)
        }
    }

    /// A car with no nickname must not produce "Waiting for  to start".
    func testANamelessVehicleGetsANeutralNoun() {
        let resolved = RiderTrackingLadder.resolve(
            stage: .toPickup, evidence: .stationary, arrivingPickup: false,
            vehicleName: "your ride", destinationName: "SFO"
        )
        XCTAssertEqual(resolved.line.text, "Waiting for your ride to start")
    }

    // MARK: THE MODE GATE

    /// **The simulated path is untouched, before any evidence is consulted.**
    /// `trackingLeg1`'s car is driven by the `trackProgress` ticker and has no
    /// `VehicleState` at all — asking it for evidence would answer `.unknown` and
    /// every tracking capture would change to say the opposite of what its own
    /// scene models.
    func testTheSimulatedPathKeepsThePreviousLineWhateverTheEvidenceSays() {
        for evidence in [RiderMotionEvidence.stationary, .unknown, .moving] {
            let resolved = RiderTrackingLadder.resolve(
                resolvesLiveMotion: false,
                stage: .toPickup,
                evidence: evidence,
                arrivingPickup: false,
                vehicleName: "Lunar",
                destinationName: "SFO"
            )
            XCTAssertEqual(resolved.line, .headingYourWay)
            XCTAssertTrue(resolved.showsPickupCountdown)
        }
    }

    func testTheLiveGateForwardsTheEvidenceItIsGiven() {
        let resolved = RiderTrackingLadder.resolve(
            resolvesLiveMotion: true,
            stage: .toPickup,
            evidence: .stationary,
            arrivingPickup: false,
            vehicleName: "Lunar",
            destinationName: "SFO"
        )
        XCTAssertEqual(resolved.line, .waitingToStart(vehicle: "Lunar"))
    }

    // MARK: THE EVIDENCE

    func testASpeedFrameIsMotion() {
        XCTAssertEqual(RiderCarMotion.evidence(from: state(speed: 1)), .moving)
        XCTAssertEqual(RiderCarMotion.evidence(from: state(speed: 34)), .moving)
    }

    func testADrivingStatusIsMotionEvenBeforeTheFirstSpeedFrame() {
        // Tesla emits gear and speed independently; the server derives `driving`
        // from the gear group. Gating on speed alone would read the first seconds
        // of every departure as "still parked".
        XCTAssertEqual(RiderCarMotion.evidence(from: state(speed: 0, status: .driving)), .moving)
    }

    func testAZeroSpeedParkedReadIsStationary() {
        XCTAssertEqual(RiderCarMotion.evidence(from: state(speed: 0, status: .parked)), .stationary)
    }

    /// §2.3 — `(0, 0)` is the no-fix SENTINEL. A car that has not reported a
    /// position has not reported standing still either.
    func testTheNoFixSentinelIsUnknownAndNotStationary() {
        XCTAssertEqual(RiderCarMotion.evidence(from: state(speed: 0, latitude: 0, longitude: 0)), .unknown)
    }

    func testNoStateAtAllIsUnknown() {
        XCTAssertEqual(RiderCarMotion.evidence(from: nil), .unknown)
    }

    func testDisplacementOverridesAQuietSpeedFrame() {
        // The arm that matters for a car whose speed/gear frames are sparse: the
        // position moved, so it moved, whatever the last speed frame said.
        XCTAssertEqual(
            RiderCarMotion.evidence(from: state(speed: 0, status: .parked), movedBeyondJitter: true),
            .moving
        )
    }

    /// **The threshold rejects receiver drift and nothing more.** Pinned as a
    /// range rather than a literal so the intent survives a tune: above the
    /// ~10–30m a stationary consumer receiver wanders, well inside a city block.
    func testTheMotionThresholdSitsAboveJitterAndBelowABlock() {
        XCTAssertGreaterThan(RiderCarMotion.motionMoveMeters, 30)
        XCTAssertLessThan(RiderCarMotion.motionMoveMeters, 150)
        // And it is NOT the pickup-ETA grid, which is tuned for a different
        // question entirely (see `motionMoveMeters`' own note).
        XCTAssertNotEqual(RiderCarMotion.motionMoveMeters, RiderPickupETA.anchorGridMeters)
    }

    // MARK: THE LATCH

    @MainActor
    func testTheFirstFixSeatsTheAnchorAndIsNotItselfAMove() {
        var latch = RiderMotionLatch()
        // A snapshot ARRIVING is not a car departing. Reading it as one would make
        // the ladder turn over the moment the socket connects, which is the same
        // defect this issue is about with a different trigger.
        XCTAssertEqual(latch.update(rideID: "r1", state: state(speed: 0)), .stationary)
    }

    @MainActor
    func testAFixBeyondTheThresholdIsADeparture() {
        var latch = RiderMotionLatch()
        _ = latch.update(rideID: "r1", state: state(speed: 0))
        // ~0.005° of latitude ≈ 550m — comfortably past the threshold.
        let moved = latch.update(rideID: "r1", state: state(speed: 0, latitude: 33.0482))
        XCTAssertEqual(moved, .moving)
    }

    @MainActor
    func testAFixInsideTheThresholdIsNotADeparture() {
        var latch = RiderMotionLatch()
        _ = latch.update(rideID: "r1", state: state(speed: 0))
        // ~0.0002° ≈ 22m — receiver drift for a car sitting in a bay.
        let jittered = latch.update(rideID: "r1", state: state(speed: 0, latitude: 33.0434))
        XCTAssertEqual(jittered, .stationary)
    }

    /// **A red light is not a reversal.** Once a ride has seen motion the ladder
    /// holds it, or the line would flap between "waiting" and "heading" every time
    /// the car stopped — which is less honest than either sentence alone.
    @MainActor
    func testMotionIsLatchedForTheRestOfTheRide() {
        var latch = RiderMotionLatch()
        _ = latch.update(rideID: "r1", state: state(speed: 0))
        XCTAssertEqual(latch.update(rideID: "r1", state: state(speed: 30, status: .driving)), .moving)
        XCTAssertEqual(latch.update(rideID: "r1", state: state(speed: 0, status: .parked)), .moving)
        XCTAssertTrue(latch.hasMoved)
    }

    /// …and NOT for the next one. One trip's departure vouching for the next is
    /// how a latch turns into the bug it was written to fix.
    @MainActor
    func testTheLatchIsScopedToARide() {
        var latch = RiderMotionLatch()
        _ = latch.update(rideID: "r1", state: state(speed: 0))
        _ = latch.update(rideID: "r1", state: state(speed: 30, status: .driving))
        XCTAssertEqual(latch.update(rideID: "r2", state: state(speed: 0, status: .parked)), .stationary)
        XCTAssertFalse(latch.hasMoved)
    }

    // MARK: THE MARKER

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTheSimulatedPathKeepsItsRouteInterpolation() {
        XCTAssertEqual(
            RiderCarMarker.resolve(resolvesLiveMotion: false, state: nil, lastUpdated: nil, isStreaming: nil, now: now),
            .simulated
        )
    }

    /// **A gold pin is a claim that the car is there right now** (MYR-387). With
    /// no fix there is no honest coordinate, so there is no pin.
    func testNoFixWithholdsTheMarkerEntirely() {
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true,
            state: state(speed: 0, latitude: 0, longitude: 0),
            lastUpdated: now,
            isStreaming: true,
            now: now
        )
        XCTAssertEqual(marker, .withheld)
        XCTAssertFalse(marker.drawsMarker)
    }

    func testAStreamingCarIsCurrentByDefinition() {
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true, state: state(speed: 0),
            lastUpdated: now.addingTimeInterval(-3600), isStreaming: true, now: now
        )
        XCTAssertEqual(marker, .live(stale: false))
    }

    func testAnOldReadIsRenderedAndSaidOutLoud() {
        let read = now.addingTimeInterval(-12 * 60)
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true, state: state(speed: 0),
            lastUpdated: read, isStreaming: false, now: now
        )
        XCTAssertEqual(marker, .live(stale: true))
        XCTAssertTrue(marker.drawsMarker, "we hold a position — withholding it would be the opposite lie")
        let note = RiderCarFreshnessNote.text(marker: marker, lastUpdated: read, now: now)
        XCTAssertNotNil(note)
        XCTAssertTrue(note!.hasPrefix("Position from "), "got \(note!)")
    }

    func testAFreshReadSaysNothingAtAll() {
        let read = now.addingTimeInterval(-5)
        let marker = RiderCarMarker.resolve(
            resolvesLiveMotion: true, state: state(speed: 0),
            lastUpdated: read, isStreaming: false, now: now
        )
        XCTAssertEqual(marker, .live(stale: false))
        // Nothing renders, so nothing reserves room for it (MYR-345's per-line rule).
        XCTAssertNil(RiderCarFreshnessNote.text(marker: marker, lastUpdated: read, now: now))
    }

    func testTheSimulatedMarkerNeverCarriesAQualifier() {
        XCTAssertNil(RiderCarFreshnessNote.text(marker: .simulated, lastUpdated: nil, now: now))
        XCTAssertNil(RiderCarFreshnessNote.text(marker: .withheld, lastUpdated: nil, now: now))
    }

    /// The staleness threshold is the SHARED one, so the rider's position
    /// qualifier and the owner's freshness stamp can never disagree about what
    /// "current" means.
    func testStalenessIsTheSharedThresholdAndNotASecondOne() {
        let read = now.addingTimeInterval(-VehicleControlFreshness.staleThreshold - 1)
        XCTAssertEqual(
            RiderCarMarker.resolve(resolvesLiveMotion: true, state: state(speed: 0), lastUpdated: read, isStreaming: false, now: now),
            .live(stale: true)
        )
        let fresh = now.addingTimeInterval(-VehicleControlFreshness.staleThreshold + 1)
        XCTAssertEqual(
            RiderCarMarker.resolve(resolvesLiveMotion: true, state: state(speed: 0), lastUpdated: fresh, isStreaming: false, now: now),
            .live(stale: false)
        )
    }
}
