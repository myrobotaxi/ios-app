import CoreLocation
import DesignSystem
import Foundation
import MapKit
import Observation

// MARK: - Tracking leg (MYR-177)
//
// Which live-tracking leg the ride is in. Until MYR-231's two-leg dispatch
// state machine lands, the leg is derived LOCALLY from `trackProgress` vs the
// record's `pickupCut` (the pickup/drop-off split). When real
// `accepted`/`enroute` vs `arrived_pickup`/`in_ride` statuses arrive, this
// enum is the single seam that flips — the camera/route/marker code above never
// changes.
enum TrackingLeg: Equatable {
    /// Heading to the rider — fit car → pickup.
    case toPickup
    /// In the ride — fit pickup → destination.
    case inRide

    static func forProgress(_ progress: Double, pickupCut: Double) -> TrackingLeg {
        progress >= pickupCut ? .inRide : .toPickup
    }

    /// MYR-234 — whether leg 1 (car → pickup) is the ACTIVE route leg for this
    /// phase. The tracking map's polyline + pin treatment split on this ONE
    /// value: the active leg renders full-strength gold, the other subdued. It is
    /// the single phase input the client asked for ("active route to pickup vs
    /// the rest of the trip"); MYR-231's `in_ride` status flips it in one line by
    /// flipping the `TrackingLeg` itself.
    var isLeg1Active: Bool { self == .toPickup }
}

// MARK: - TrackingCameraController (MYR-177 — the ONE camera owner for tracking)
//
// The tracking phase's single programmatic camera writer, mirroring
// `PinDropCameraController`'s ownership discipline (MYR-217/222): every write
// flows through here, each registers its expected settle in a
// `CameraSettleLedger` (no wall clock — immune to fix rate), a user gesture
// dethrones the owner for the phase, and the rider recenter button re-engages
// it. It replaces the old static `RideRequestRouteMap` fit (which framed the
// whole straight pickup→destination box even while the car was 0.9 mi away
// heading to pickup — the client bug).
//
// MYR-460 — THE OWNER NOW HAS TWO FRAMES, and which one it holds is a fact
// about the CAR rather than a mode anybody chooses:
//
//   • `.follow` — the car, centred in the unobstructed band at street level,
//     rewritten at fix cadence. This is the client's Tesla-nav ask and it is the
//     RESTING frame of a ride: *"camera that follows the car on the route so
//     that it's just like the TESLA navigation system."*
//   • `.legFit` — MYR-177's whole-leg framing, which is now the answer to one
//     question only: **we hold no position for the car.** A camera cannot follow
//     something it cannot locate, and framing the leg is the honest thing to
//     show instead (MYR-393/MYR-449's no-fix case). The first fix promotes to
//     `.follow` and never goes back.
//
// THE ANTI-LOOP RULE (MYR-222) IS UNCHANGED IN KIND AND RESTATED PER FRAME. A
// write is still only ever issued for a MEANINGFUL change; what counts as
// meaningful differs because the two frames are about different things:
//
//   • `.legFit` — a leg flip, or the route geometry changing under `reframe`.
//     Nothing about a car can move this frame, because this frame is only ever
//     held when there is no car position to move. (MYR-177's `carWithinRegion`
//     margin band is DELETED with the case it served: a leg fit that can hold a
//     car position no longer exists, so the band was a rule about an
//     unreachable state, and a pure function with tests and no callers is the
//     quietest regression this repo knows.)
//   • `.follow` — the car having MOVED (`followMinMoveFraction` of the span)
//     since the last written centre. A car that is genuinely driving therefore
//     writes once per fix, and that is not the loop MYR-222 is about: the loop
//     is a write that provokes a settle that provokes a write, which is why
//     every write still registers its expected settle in the ledger and why a
//     PARKED car — whose fixes jitter by a metre — writes nothing at all.
//
// The probe's healthy signature for this surface is therefore: writes at fix
// cadence while armed, and ZERO writes from the moment a gesture logs
// `follow off` until the rider recentres or the idle window elapses.
//
//   inactive ──enter──▶ following{.follow | .legFit} ──car moved / leg flip / first fix──▶ (write)
//                          │  ▲
//     userGesture / unmatched settle │  └── recenter() or idle re-arm ──┐
//                          ▼                                            │
//                     userControlled ───────────────────────────────────┘
@MainActor
@Observable
final class TrackingCameraController {

    enum Phase: Equatable {
        case inactive
        /// The owner holds the camera — see `frame` for which framing.
        case following
        /// The rider panned/zoomed — the owner stands down until recenter or the
        /// MYR-460 idle window elapses.
        case userControlled
    }

    /// WHAT the owner is framing while it holds the camera (MYR-460).
    enum Frame: Equatable {
        /// The car itself, at street level — the resting frame of a ride.
        case follow
        /// The whole leg. Reached ONLY when we hold no position for the car.
        case legFit
    }

    struct Write: Equatable {
        var region: MKCoordinateRegion
        var animated: Bool
        /// Which frame produced this write. The view reads it to pick the
        /// animation (a follow write is LINEAR over the fix interval so
        /// consecutive writes hand off at constant speed and the map glides; an
        /// eased write would decelerate into every fix and read as stutter) and
        /// the probe trace prints it, so a log line says which camera wrote.
        var frame: Frame = .legFit
        static func == (lhs: Write, rhs: Write) -> Bool {
            lhs.animated == rhs.animated
                && lhs.frame == rhs.frame
                && lhs.region.center.latitude == rhs.region.center.latitude
                && lhs.region.center.longitude == rhs.region.center.longitude
                && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
                && lhs.region.span.longitudeDelta == rhs.region.span.longitudeDelta
        }
    }

    private(set) var phase: Phase = .inactive
    private(set) var currentLeg: TrackingLeg?
    /// Which framing the owner holds. Meaningless while `phase != .following`.
    private(set) var frame: Frame = .legFit

    /// MYR-460 — bumped on EVERY gesture, including one that lands while the
    /// rider is already in control. The view restarts its idle re-arm countdown
    /// on this value, so the window is measured from the LAST gesture rather
    /// than from the first: a rider who keeps panning is never yanked mid-drag,
    /// which is the whole reconciliation with MYR-222/MYR-338.
    private(set) var gestureToken: Int = 0

    // MARK: Tuning
    private let paddingFactor: Double
    private let followSpanDelta: Double
    private let followMinMoveFraction: Double

    // MARK: State
    private var fittedRegion: MKCoordinateRegion?
    /// The car coordinate the last FOLLOW write was centred on — the anti-jitter
    /// reference. Deliberately the RAW fix and never the interpolated render
    /// position (MYR-237/MYR-389: rendering-only interpolation, the raw fix
    /// remains the fact, and a camera keyed on a tweened coordinate would write
    /// at the tween's rate rather than the car's).
    private var followedCar: CLLocationCoordinate2D?
    private var ledger = CameraSettleLedger()

    init(
        paddingFactor: Double = MRTMetrics.trackingLegFitPadding,
        followSpanDelta: Double = MRTMetrics.trackingFollowSpanDelta,
        followMinMoveFraction: Double = MRTMetrics.trackingFollowMinMoveFraction
    ) {
        self.paddingFactor = paddingFactor
        self.followSpanDelta = followSpanDelta
        self.followMinMoveFraction = followMinMoveFraction
    }

    // MARK: Events

    /// Enter the tracking phase (cold mount or warm transition) on `leg`.
    ///
    /// Follows the car when we hold a position for it — the ride's resting frame
    /// — and falls back to MYR-177's whole-leg fit when we do not. Un-animated
    /// either way: the rider is looking at a fresh appearance, not a camera move.
    func enter(leg: TrackingLeg, carPosition: CLLocationCoordinate2D?, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write {
        phase = .following
        currentLeg = leg
        ledger.clear()
        if let carPosition {
            return followWrite(car: carPosition, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: false)
        }
        frame = .legFit
        followedCar = nil
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: false)
    }

    /// A car fix / progress update. Returns a write ONLY when something
    /// meaningful changed — see this file's header for what that means in each
    /// frame. No-op while the rider is in control.
    func update(leg: TrackingLeg, carPosition: CLLocationCoordinate2D?, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write? {
        guard phase == .following else { return nil }
        let legFlipped = leg != currentLeg
        currentLeg = leg

        // THE PROMOTION IS ONE-WAY. With a position in hand the camera follows,
        // whatever it was doing before; without one it cannot, so `.legFit` is
        // reached only by the absence below and never as a fallback from follow
        // (a car that stops reporting keeps its last followed frame, which is
        // where it last was — MYR-393's rule, applied to the camera).
        guard let carPosition else {
            // No position: the only thing that can have changed about a leg fit
            // is the LEG. Everything else about this frame is the route, which
            // `reframe` owns.
            guard frame == .legFit, legFlipped || fittedRegion == nil else { return nil }
            return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
        }

        // The first fix of the ride (promotion out of the leg fit) and a leg
        // flip are both unconditional writes; only a car that is merely still
        // driving has to earn one.
        if frame == .legFit || legFlipped {
            return followWrite(car: carPosition, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
        }
        guard Self.carMovedMaterially(from: followedCar, to: carPosition, spanDelta: followSpanDelta, minMoveFraction: followMinMoveFraction) else {
            return nil // jitter, or a car standing still — no write, at any fix rate
        }
        return followWrite(car: carPosition, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// The ROUTE GEOMETRY changed (the real Apple polyline replaced the straight
    /// fallback). Only the leg fit is a statement about the route, so a FOLLOW
    /// camera ignores this entirely — one fewer write class than MYR-177 had,
    /// and the MYR-222 loop is structurally unreachable from a late polyline.
    func reframe(leg: TrackingLeg, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write? {
        guard phase == .following, frame == .legFit else { return nil }
        currentLeg = leg
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// The rider's recenter button, and the MYR-460 idle re-arm — re-engage from
    /// any phase, following the car when we have one.
    func recenter(leg: TrackingLeg, carPosition: CLLocationCoordinate2D?, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write {
        phase = .following
        currentLeg = leg
        ledger.clear()
        if let carPosition {
            return followWrite(car: carPosition, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
        }
        frame = .legFit
        followedCar = nil
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// The rider's finger moved the map (gesture recognizer, not settle
    /// inference) — the owner stands down until recenter or the idle window.
    func userGestureBegan() {
        // The token bumps even when the owner is ALREADY stood down: that second
        // pan is what must push the re-arm deadline out, and a guard placed
        // above this line would let a rider who is still working the map be
        // interrupted by a countdown started by their first touch.
        gestureToken &+= 1
        guard phase == .following else { return }
        phase = .userControlled
        ledger.clear()
    }

    /// A camera settle during tracking. Returns `true` if it was OURS (ignore),
    /// `false` if the rider moved the map (the view should drop follow). Uses
    /// the same token ledger as every other camera owner.
    func cameraSettled(center: CLLocationCoordinate2D, latitudeDelta: Double) -> Bool {
        guard phase == .following else { return true }
        if ledger.classifySettle(center: center, latitudeDelta: latitudeDelta) { return true }
        phase = .userControlled
        ledger.clear()
        return false
    }

    func exit() {
        phase = .inactive
        currentLeg = nil
        fittedRegion = nil
        followedCar = nil
        frame = .legFit
        ledger.clear()
    }

    // MARK: Scene lifecycle (parity with PinDropCameraController)

    func sceneWillBackground() {
        guard phase == .following else { return }
        ledger.clear()
    }

    /// Grant one free settle pass after a resume re-layout (not a gesture).
    func sceneDidForeground() {
        guard phase == .following else { return }
        ledger.grantFreePass()
    }

    // MARK: Internals

    private func refit(coords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat, animated: Bool) -> Write {
        let region = VehicleRoute.fittedRegion(
            for: coords, paddingFactor: paddingFactor, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset
        )
        frame = .legFit
        fittedRegion = region
        ledger.expect(center: region.center, spanDelta: region.span.latitudeDelta)
        return Write(region: region, animated: animated, frame: .legFit)
    }

    private func followWrite(car: CLLocationCoordinate2D, bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat, animated: Bool) -> Write {
        let region = Self.followRegion(
            car: car, spanDelta: followSpanDelta,
            bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset
        )
        frame = .follow
        followedCar = car
        fittedRegion = region
        ledger.expect(center: region.center, spanDelta: region.span.latitudeDelta)
        return Write(region: region, animated: animated, frame: .follow)
    }

    // MARK: The follow rules (pure + static, unit-tested with no map)

    /// The region that puts `car` in the middle of the band the sheet leaves
    /// visible, at street level.
    ///
    /// **The car is CENTRED, with no forward lead**, and that is a decision
    /// rather than a simplification. A lead ("show more of the road ahead") has
    /// to be pushed along the heading, and heading is the one telemetry field
    /// that keeps moving when the car does not — a stationary car's compass
    /// wanders freely, so a lead would swing the camera through a full circle
    /// around a parked vehicle while `carMovedMaterially` correctly reported no
    /// motion at all. Centring costs a little of the road ahead and cannot
    /// manufacture movement out of a stationary car.
    ///
    /// `insetRegion` does the real work: it grows the span so `spanDelta`
    /// survives being squeezed into the unobstructed band and shifts the centre
    /// south by the net obstruction, so the car lands in the middle of what the
    /// rider can actually see rather than the middle of the map view.
    static func followRegion(
        car: CLLocationCoordinate2D,
        spanDelta: Double,
        bottomInset: CGFloat,
        viewHeight: CGFloat,
        topInset: CGFloat
    ) -> MKCoordinateRegion {
        VehicleRoute.insetRegion(
            center: car,
            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta),
            bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset
        )
    }

    /// Whether the car has moved far enough from the last written follow centre
    /// to be worth a camera write — the follow frame's anti-loop gate.
    ///
    /// `nil` (nothing written yet) is always material. The threshold is a
    /// fraction of the SPAN rather than a distance in metres so it scales with
    /// the zoom the camera is actually holding, and it is compared in degrees on
    /// both axes with longitude weighted by latitude, so the same physical
    /// distance reads the same at any latitude.
    static func carMovedMaterially(
        from previous: CLLocationCoordinate2D?,
        to car: CLLocationCoordinate2D,
        spanDelta: Double,
        minMoveFraction: Double
    ) -> Bool {
        guard let previous else { return true }
        guard car.latitude.isFinite, car.longitude.isFinite else { return false }
        let threshold = abs(spanDelta) * abs(minMoveFraction)
        guard threshold > 0 else { return true }
        let dLat = car.latitude - previous.latitude
        // Longitude degrees shrink with latitude; weight them so a metre east
        // counts the same as a metre north.
        let dLon = (car.longitude - previous.longitude) * cos(previous.latitude * .pi / 180)
        return (dLat * dLat + dLon * dLon).squareRoot() >= threshold
    }

    /// Whether a dethroned camera has been left alone long enough to re-arm
    /// itself — the client's *"after a few seconds it will snap right back"*.
    ///
    /// Measured from the LAST gesture, which is what keeps this from becoming
    /// the MYR-222 complaint: a rider still working the map keeps pushing the
    /// deadline out, and the camera only returns to a map nobody has touched for
    /// the whole window.
    static func idleRearmDue(lastGestureAt: Date?, now: Date, delay: TimeInterval) -> Bool {
        guard let lastGestureAt else { return false }
        guard delay > 0 else { return true }
        return now.timeIntervalSince(lastGestureAt) >= delay
    }
}
