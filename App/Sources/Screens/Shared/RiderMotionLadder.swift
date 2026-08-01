import CoreLocation
import Foundation
import MyRobotaxiContracts

// MARK: - The honest motion ladder (MYR-393)
//
// r16, build 202607311641. The rider's tracking sheet read **"HEADING YOUR WAY ·
// Picking you up at Harbor Freight · 4 min · 1.4 mi away"** with a drawn car→pickup
// route, while the client's own in-car screenshot showed the Tesla PARKED at 2705 N
// Central Expy — the Plano service centre — and not at the position the app had
// drawn it. *"This seems mocked or random… Ensure you have correct status of the
// car."*
//
// **THE STATUS WAS DISPATCH-DERIVED, NOT MOTION-DERIVED.** `RiderTrackingStage`
// answers `.toPickup` for every non-terminal status, and the sheet's `statusWord`
// read "Heading your way" from `!atPickup` alone. So the sentence fired on the
// ACCEPT — an event about a decision somebody made, not about a car that moved —
// and the hero ETA was computed from `trackProgress`, a client-side ticker seeded
// at accept. Both were true of the ride and neither was true of the vehicle.
//
// CLIENT DECISION (2026-07-31): **"Waiting for {car} to start" until REAL MOTION is
// detected**, and only then "Heading your way" with the ETA countdown. Before
// motion the surface must not claim a countdown to pickup at all.
//
// THE SHAPE OF THE FIX. Three things, each a pure value so the whole ladder is
// assertable without a socket, a view or a clock:
//
//  1. `RiderMotionEvidence` — what we KNOW about the car moving, as three cases
//     rather than a `Bool`. "Stationary" and "we have not heard" are genuinely
//     different situations and MYR-343's lesson is that folding them into one flag
//     means one always borrows the other's surface. They happen to render the same
//     line here, and that is a decision this file makes explicitly rather than a
//     property of the type.
//  2. `RiderMotionLatch` — evidence ACCUMULATED over a ride. A car that has
//     demonstrably pulled away is heading your way while it waits at a red light,
//     so the ladder latches forward and never falls back to "waiting". This is the
//     honesty rule pointing the other way, and without it the line would flap.
//  3. `RiderTrackingLadder` — the state machine: (stage × evidence) → the status
//     line and whether a pickup countdown may be shown. Total over both inputs, so
//     no arm can be forgotten, and swept by `RiderMotionLadderTests` for the one
//     invariant that matters: **no state claims the car is approaching without
//     motion evidence.**
//
// THE SIMULATED PATH IS UNTOUCHED, BY CONSTRUCTION. `resolvesLiveMotion` is false
// on every simulated boot and every pre-existing DEBUG scene, and returns the
// pre-MYR-393 line before any evidence is consulted — the same short-circuit
// `RiderIdlePlaceholder.items(resolvesLiveETA:…)` uses, and for the same reason: a
// simulated tracking scene is driven by the `trackProgress` ticker, which has no
// telemetry to be honest with and models a car that IS moving. So `trackingLeg1`,
// `trackingLeg2` and `trackingArriving` render exactly what they always did.

// MARK: - Evidence

/// What is known about whether the ride's car is actually moving.
enum RiderMotionEvidence: Equatable, Sendable {
    /// The car reported motion — a non-zero speed, a driving status, or a
    /// position that has moved further than GPS noise can explain.
    case moving
    /// A live read landed and it says the car is standing still.
    case stationary
    /// No live read to go on at all: the snapshot has not arrived, or this ride
    /// has no telemetry behind it.
    case unknown

    /// Is this positive evidence of motion? The ONE predicate the ladder is
    /// allowed to turn on, so "we have not heard" can never be mistaken for "it
    /// is moving" by a caller reaching for `!= .stationary`.
    var provesMotion: Bool { self == .moving }
}

/// Reads motion evidence out of one live `VehicleState`, plus the displacement
/// the latch measured. Pure and static.
enum RiderCarMotion {

    /// The wire's `speed` is *"rounded to nearest integer from Tesla's float
    /// emission"*, so 1 mph is the smallest value that is not "stopped" — there
    /// is no sub-integer creep to filter out and no threshold to tune.
    static let movingSpeedMPH = 1

    /// How far a fix must land from the ride's motion anchor before it counts as
    /// the car having MOVED rather than the receiver having wandered.
    ///
    /// Deliberately NOT `RiderPickupETA.anchorGridMeters` (250m), even though the
    /// latch below is `StableFixAnchor` and the grammar is that file's. 250m is
    /// tuned so a sub-cell walk cannot change a ROUNDED MINUTE; the question here
    /// is far cruder — "has this car left the parking bay?" — and a car has
    /// plainly left it long before it has covered a quarter kilometre. 60m sits
    /// well above the ~10–30m a stationary consumer receiver drifts (which is the
    /// whole of what this must reject) and well inside a single city block, so
    /// the ladder turns over within seconds of a real departure.
    static let motionMoveMeters: Double = 60

    /// The evidence one snapshot carries, before any displacement is considered.
    ///
    /// `nil` state → `.unknown`. A state with **no fix** is `.unknown` too, not
    /// `.stationary`: a car that has not reported a position has not reported
    /// standing still either, and §2.3's `(0,0)` sentinel is an absence, not a
    /// place (MYR-387's lesson, on the rider's side of it).
    static func evidence(from state: VehicleState?) -> RiderMotionEvidence {
        guard let state else { return .unknown }
        if state.speed >= movingSpeedMPH { return .moving }
        // The gear group derives `status`, and `driving` is the server's own
        // reading of a car in D or R. Trusting it as well as `speed` is what
        // covers the seconds between a gear change and the first non-zero speed
        // frame — the two are separate Tesla emissions.
        if state.status == .driving { return .moving }
        guard RiderVehicleProjection.hasFix(state) else { return .unknown }
        return .stationary
    }

    /// Fold a measured displacement into the snapshot's own evidence. A car whose
    /// position has moved beyond `motionMoveMeters` is moving whatever its last
    /// speed frame said — which is the arm that matters for a vehicle whose
    /// speed/gear frames are sparse (an in-service car reporting position only).
    static func evidence(from state: VehicleState?, movedBeyondJitter: Bool) -> RiderMotionEvidence {
        if movedBeyondJitter { return .moving }
        return evidence(from: state)
    }
}

// MARK: - The latch

/// Accumulates motion evidence across a ride.
///
/// TWO jobs, and both are honesty rules:
///
///   • **It measures displacement** — seating a `StableFixAnchor` on the first fix
///     of the ride and treating a re-seat as proof the car moved. The anchor is
///     `RiderPickupETA`'s own type, at this file's tighter threshold, so the
///     "material move" grammar exists once. Quantization alone cannot do this: a
///     fix jittering across a grid boundary would report a departure from a car
///     that never left the bay, which is exactly the false claim this issue is
///     about.
///   • **It latches forward.** Once a ride has seen motion it keeps `hasMoved`,
///     because a car stopped at a light is still heading your way and a line that
///     flapped between "waiting" and "heading" every 40 seconds would be less
///     honest than either sentence alone.
///
/// The latch is scoped to a RIDE (`rideID`); a new ride starts from nothing, which
/// is what stops one trip's departure vouching for the next one's.
@MainActor
struct RiderMotionLatch {
    private(set) var rideID: String?
    private(set) var hasMoved = false
    private var anchor = StableFixAnchor(materialMoveMeters: RiderCarMotion.motionMoveMeters)

    init() {}

    /// Feed the ride's latest live state. Returns the accumulated evidence.
    @discardableResult
    mutating func update(rideID: String?, state: VehicleState?) -> RiderMotionEvidence {
        if rideID != self.rideID {
            self.rideID = rideID
            hasMoved = false
            anchor = StableFixAnchor(materialMoveMeters: RiderCarMotion.motionMoveMeters)
        }
        let fix = RiderVehicleProjection.coordinate(from: state)
        let previous = anchor.anchor
        anchor.update(fix)
        // A re-seat is a material move. The FIRST fix seats the anchor and is not
        // a move — there was nothing to move from, and calling it one would make
        // "the snapshot arrived" indistinguishable from "the car pulled away".
        let moved = previous != nil && anchor.anchor != nil && !Self.sameCoordinate(previous, anchor.anchor)
        let evidence = RiderCarMotion.evidence(from: state, movedBeyondJitter: moved)
        if evidence.provesMotion { hasMoved = true }
        return hasMoved ? .moving : evidence
    }

    private static func sameCoordinate(_ a: CLLocationCoordinate2D?, _ b: CLLocationCoordinate2D?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return a.latitude == b.latitude && a.longitude == b.longitude
    }
}

// MARK: - The status line

/// The one sentence at the top of the rider's tracking sheet.
///
/// A value rather than a `String` so the ladder's decision and the copy are
/// separately assertable, and so `claimsApproach` — the invariant the sweep test
/// turns on — is a property of the STATE rather than a guess about the words.
enum RiderTrackingStatusLine: Equatable, Sendable {
    /// Accepted/dispatched, and the car has not been observed to move yet. The
    /// state this issue exists to add.
    case waitingToStart(vehicle: String)
    /// Observed motion, heading to the pickup.
    case headingYourWay
    /// Observed motion, nearly at the pickup.
    case arrivingForPickup
    /// The car is at the pickup, awaiting the rider's Start.
    case carIsHere
    /// The rider is aboard, heading to the drop-off.
    case headingToDropoff(String)
    /// The drop-off takeover.
    case arrivingAtDropoff

    /// The rendered eyebrow text.
    var text: String {
        switch self {
        case .waitingToStart(let vehicle): "Waiting for \(vehicle) to start"
        case .headingYourWay: "Heading your way"
        case .arrivingForPickup: "Your ride is arriving"
        case .carIsHere: "Your car is here"
        case .headingToDropoff(let destination): "Heading to \(destination)"
        case .arrivingAtDropoff: "Arriving at drop-off"
        }
    }

    /// **THE INVARIANT.** Does this line assert that the car is moving TOWARDS the
    /// rider — the claim the client caught being made about a parked car?
    ///
    /// Scoped to the approach on purpose. `headingToDropoff` is also a sentence
    /// about a moving car, but the rider is INSIDE it: they pressed Start, they
    /// can see out of the window, and gating that line on a telemetry frame would
    /// tell somebody in a moving car that it has not set off. The lie this issue
    /// is about is only tellable about a car the rider cannot see.
    var claimsApproach: Bool {
        switch self {
        case .headingYourWay, .arrivingForPickup: true
        case .waitingToStart, .carIsHere, .headingToDropoff, .arrivingAtDropoff: false
        }
    }
}

/// What the ladder resolved: the line, and whether the sheet may put a countdown
/// to the pickup on screen.
struct RiderTrackingLadderState: Equatable, Sendable {
    let line: RiderTrackingStatusLine
    /// **Pre-motion there is no honest countdown to pickup.** The number the
    /// client photographed ("4 min") came from a ticker started by the accept, so
    /// it counted down while the car sat in a service bay. Nothing replaces it —
    /// there is no fetch running and no arrival to estimate from, so an honest
    /// waiting state says the one thing it knows and stops (the MYR-294
    /// no-placeholder rule).
    let showsPickupCountdown: Bool
}

/// The ladder: (stage × motion evidence) → what the sheet says.
enum RiderTrackingLadder {

    /// The SIMULATED / pre-MYR-393 rendering, returned before any evidence is
    /// consulted whenever `resolvesLiveMotion` is false.
    ///
    /// The simulated tracking scenes are driven by the `trackProgress` ticker,
    /// which has no `VehicleState` behind it: asking them for motion evidence
    /// would answer `.unknown` for a car the simulation is actively driving, and
    /// every tracking drift-gate capture would change to say the opposite of what
    /// its own scene models. So the gate is an ABSENCE of live inputs rather than
    /// a branch inside the ladder.
    static func resolve(
        resolvesLiveMotion: Bool,
        stage: RiderTrackingStage,
        evidence: RiderMotionEvidence,
        arrivingPickup: Bool,
        vehicleName: String,
        destinationName: String
    ) -> RiderTrackingLadderState {
        guard resolvesLiveMotion else {
            return resolve(
                stage: stage,
                evidence: .moving,
                arrivingPickup: arrivingPickup,
                vehicleName: vehicleName,
                destinationName: destinationName
            )
        }
        return resolve(
            stage: stage,
            evidence: evidence,
            arrivingPickup: arrivingPickup,
            vehicleName: vehicleName,
            destinationName: destinationName
        )
    }

    /// The state machine proper. Total over stage AND evidence — a switch, so a
    /// fifth stage or a fourth kind of evidence has to declare what it means
    /// rather than inheriting whatever the last `else` happened to say.
    static func resolve(
        stage: RiderTrackingStage,
        evidence: RiderMotionEvidence,
        arrivingPickup: Bool,
        vehicleName: String,
        destinationName: String
    ) -> RiderTrackingLadderState {
        switch stage {
        case .toPickup:
            switch evidence {
            case .moving:
                return RiderTrackingLadderState(
                    line: arrivingPickup ? .arrivingForPickup : .headingYourWay,
                    showsPickupCountdown: true
                )
            case .stationary, .unknown:
                // Both non-moving arms render the waiting state, and they do so
                // for the same reason rather than by coincidence: neither is
                // evidence the car set off, and "heading your way" is a claim
                // that needs evidence. They stay separate cases because the day
                // one of them earns its own copy — "we've lost contact with
                // {car}" is the obvious candidate — that must be a change to
                // THIS switch and not a re-interpretation of a boolean.
                return RiderTrackingLadderState(
                    line: .waitingToStart(vehicle: vehicleName),
                    showsPickupCountdown: false
                )
            }
        case .arrivedAwaitingStart:
            // The car is AT the pickup: the owner said so and the rider can see
            // it. No approach is being claimed and nothing is counting down to a
            // pickup that has happened.
            return RiderTrackingLadderState(line: .carIsHere, showsPickupCountdown: false)
        case .inRide:
            return RiderTrackingLadderState(line: .headingToDropoff(destinationName), showsPickupCountdown: false)
        case .arrivingDropoff:
            return RiderTrackingLadderState(line: .arrivingAtDropoff, showsPickupCountdown: false)
        }
    }

    /// Every (stage, evidence) pair — the sweep the tests walk, kept here so a new
    /// stage or a new kind of evidence widens the sweep automatically instead of
    /// leaving the new arm untested.
    static var allArms: [(stage: RiderTrackingStage, evidence: RiderMotionEvidence)] {
        let stages: [RiderTrackingStage] = [.toPickup, .arrivedAwaitingStart, .inRide, .arrivingDropoff]
        let evidences: [RiderMotionEvidence] = [.moving, .stationary, .unknown]
        return stages.flatMap { stage in evidences.map { (stage, $0) } }
    }
}

// MARK: - The car marker (MYR-393 defect 2)

/// What the tracking map draws for the ride's car.
///
/// **THE MARKER WAS A FICTION, AND THAT IS THE SECOND HALF OF THE CLIENT'S
/// REPORT.** `SharedViewerScreen.trackingCarPosition` interpolated a point along
/// the leg-1 polyline by `trackProgress` — the same accept-seeded ticker the ETA
/// came from — so the gold glyph slid smoothly down a road the car was not on,
/// on the live path as much as the simulated one. His screenshot is a car parked
/// at a service centre and an app drawing it a mile and a half away, moving.
///
/// The rule now: **the marker is the freshest position we hold, or it is not
/// drawn.** That is MYR-387's owner-side rule, which the rider map already
/// applies to its idle vehicle through `RiderVehicleProjection.hasFix` and never
/// applied to the tracking glyph — *a camera is context, a gold pin is a claim
/// that the car is there right now.*
///
/// Freshness is REPORTED, not corrected: MYR-394 is separately adding REST
/// position polling for non-streaming vehicles during active rides, so this side
/// renders truthfully whatever arrives at whatever cadence rather than assuming
/// one.
enum RiderCarMarker: Equatable, Sendable {
    /// Draw the glyph at the live fix. `stale` is the freshness qualifier the
    /// sheet says out loud.
    case live(stale: Bool)
    /// No fix at all — draw NO glyph. The route, the pins and the camera are
    /// unaffected; only the claim about where the car is right now is withheld.
    case withheld
    /// The simulated path's route interpolation, unchanged, so every tracking
    /// drift-gate capture is byte-identical.
    case simulated

    var drawsMarker: Bool { self != .withheld }

    /// Resolve from the ONE mode gate plus the live read.
    ///
    /// - Parameters:
    ///   - resolvesLiveMotion: the same `isLiveLocation` seam the ladder takes.
    ///   - state: the watched vehicle's accumulated live state.
    ///   - lastUpdated: the state's parsed read time (`nil` = never read).
    ///   - now: injected.
    static func resolve(
        resolvesLiveMotion: Bool,
        state: VehicleState?,
        lastUpdated: Date?,
        isStreaming: Bool?,
        now: Date
    ) -> RiderCarMarker {
        guard resolvesLiveMotion else { return .simulated }
        guard RiderVehicleProjection.hasFix(state) else { return .withheld }
        // A streaming car's position is current by definition — the same reading
        // `VehicleFreshnessStamp.recency` makes of `isStreaming`, so the marker
        // and the owner's stamp can never disagree about what "current" means.
        // `nil` is the simulated snapshot's answer and is deliberately NOT read
        // as streaming: on a live boot it means the freshness signals have not
        // arrived, which is the case the `lastUpdated` ladder below is for.
        if isStreaming == true { return .live(stale: false) }
        guard let lastUpdated else { return .live(stale: true) }
        return .live(stale: VehicleControlFreshness.isStale(lastUpdated: lastUpdated, now: now))
    }
}

/// The muted qualifier the tracking sheet renders under its status line when the
/// freshest position we hold is old.
///
/// Deliberately about the POSITION rather than about the data generally: on this
/// surface the one thing a stale read makes untrustworthy is where the gold glyph
/// is, and naming it is what lets a rider reconcile the map with a car they can
/// see out of the window. `nil` whenever no honest qualifier applies, so nothing
/// renders and no room is reserved.
enum RiderCarFreshnessNote {
    static func text(marker: RiderCarMarker, lastUpdated: Date?, now: Date) -> String? {
        guard case .live(let stale) = marker, stale else { return nil }
        guard let lastUpdated else { return "Position not reported yet" }
        return "Position from \(VehicleControlFreshness.agoLabel(since: lastUpdated, now: now))"
    }
}
