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
// THE ANTI-LOOP RULE (MYR-222): the camera re-fits ONLY on a meaningful change
// — a leg flip, or the car crossing into the outer margin of the region it last
// framed (about to leave view). A car sitting comfortably inside the frame
// produces ZERO writes at any fix rate; that is what the mandatory streaming-fix
// probe verifies.
//
//   inactive ──enter──▶ following ──car leaves frame / leg flip──▶ (re-fit) following
//                          │  ▲
//     userGesture / unmatched settle │  └── recenter() ──┐
//                          ▼                              │
//                     userControlled ────────────────────┘
@MainActor
@Observable
final class TrackingCameraController {

    enum Phase: Equatable {
        case inactive
        /// The owner holds the leg fit — re-fits on leg flip / frame exit only.
        case following
        /// The rider panned/zoomed — the owner stands down until recenter.
        case userControlled
    }

    struct Write: Equatable {
        var region: MKCoordinateRegion
        var animated: Bool
        static func == (lhs: Write, rhs: Write) -> Bool {
            lhs.animated == rhs.animated
                && lhs.region.center.latitude == rhs.region.center.latitude
                && lhs.region.center.longitude == rhs.region.center.longitude
                && lhs.region.span.latitudeDelta == rhs.region.span.latitudeDelta
                && lhs.region.span.longitudeDelta == rhs.region.span.longitudeDelta
        }
    }

    private(set) var phase: Phase = .inactive
    private(set) var currentLeg: TrackingLeg?

    // MARK: Tuning
    private let paddingFactor: Double
    private let refitMarginFraction: Double

    // MARK: State
    private var fittedRegion: MKCoordinateRegion?
    private var ledger = CameraSettleLedger()

    init(
        paddingFactor: Double = MRTMetrics.trackingLegFitPadding,
        refitMarginFraction: Double = MRTMetrics.trackingRefitMarginFraction
    ) {
        self.paddingFactor = paddingFactor
        self.refitMarginFraction = refitMarginFraction
    }

    // MARK: Events

    /// Enter the tracking phase (cold mount or warm transition) on `leg`, fitting
    /// `fitCoords` into the unobstructed band above the sheet. Un-animated —
    /// the rider is looking at a fresh appearance, not a camera move.
    func enter(leg: TrackingLeg, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write {
        phase = .following
        currentLeg = leg
        ledger.clear()
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: false)
    }

    /// A car fix / progress update. Returns a write ONLY when the leg flipped or
    /// the car left the framed region — otherwise `nil` (the anti-loop
    /// guarantee). No-op while the rider is in control.
    func update(leg: TrackingLeg, carPosition: CLLocationCoordinate2D, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write? {
        guard phase == .following else { return nil }
        if leg != currentLeg {
            currentLeg = leg
            return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
        }
        guard let region = fittedRegion else {
            return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
        }
        if Self.carWithinRegion(carPosition, region: region, marginFraction: refitMarginFraction) {
            return nil // comfortably framed — no write, at any fix rate
        }
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// Re-fit the current leg because the ROUTE GEOMETRY changed (the real Apple
    /// polyline replaced the straight fallback) — but only while the owner still
    /// holds follow (never yank a camera the rider took control of). Distinct
    /// from `update`, which re-fits on car movement.
    func reframe(leg: TrackingLeg, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write? {
        guard phase == .following else { return nil }
        currentLeg = leg
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// The rider's recenter button — re-engage the leg fit from any phase.
    func recenter(leg: TrackingLeg, fitCoords: [CLLocationCoordinate2D], bottomInset: CGFloat, viewHeight: CGFloat, topInset: CGFloat = 0) -> Write {
        phase = .following
        currentLeg = leg
        ledger.clear()
        return refit(coords: fitCoords, bottomInset: bottomInset, viewHeight: viewHeight, topInset: topInset, animated: true)
    }

    /// The rider's finger moved the map (gesture recognizer, not settle
    /// inference) — the owner stands down for the phase until recenter.
    func userGestureBegan() {
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
        fittedRegion = region
        ledger.expect(center: region.center, spanDelta: region.span.latitudeDelta)
        return Write(region: region, animated: animated)
    }

    // MARK: Fit-region membership (pure, unit-tested)

    /// Whether `car` sits comfortably inside `region` — inside the region's
    /// bounds shrunk on every side by `marginFraction` of the span. Crossing
    /// OUT of this inner box is the re-fit trigger (the car is nearing the edge
    /// of view). Pure + static so `TrackingCameraFitTests` pins the policy.
    static func carWithinRegion(_ car: CLLocationCoordinate2D, region: MKCoordinateRegion, marginFraction: Double) -> Bool {
        let halfLat = region.span.latitudeDelta / 2
        let halfLon = region.span.longitudeDelta / 2
        let innerHalfLat = halfLat * (1 - marginFraction)
        let innerHalfLon = halfLon * (1 - marginFraction)
        let dLat = abs(car.latitude - region.center.latitude)
        let dLon = abs(car.longitude - region.center.longitude)
        return dLat <= innerHalfLat && dLon <= innerHalfLon
    }
}
