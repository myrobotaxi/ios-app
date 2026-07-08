import Foundation
import Observation

// MARK: - Ride request seam (MYR-171)
//
// `RideRequestService` is the M1↔M2 seam for the whole ride-request flow —
// mirrors `VehicleTelemetrySource`'s reasoning (VehicleTelemetry.swift): this
// issue ships `SimulatedRideRequestService`, a local state machine + timers,
// no network (CLAUDE.md "M1 is simulated"). P10's real dispatch API (M2)
// swaps in a service that talks to the backend over `MyRoboTaxiKit` and
// drives the identical `activeRequest` snapshot — the rider's
// `SharedViewerScreen` phases and the owner's `IncomingRequestSheet` don't
// change; they only ever read `activeRequest` and call the methods below.
//
// Lifted at `RootView` (alongside `sharedViewerState`/`ownerHomeState`), so
// ONE instance is visible to both roles within a single app session — the
// mechanism M1 uses to demo the cross-role round trip without a backend: the
// rider submits a request on the Shared flow, switches role to Owner
// (Settings → Sign out → Add Tesla — RootView's existing role-switch path),
// and `IncomingRequestSheet` on the owner Home reads the very same
// `activeRequest`, because `rideRequestService` is never recreated across
// that switch (see `RootView`'s header comment for why its `@State`
// properties survive changing `screen`/`role`).
@MainActor
public protocol RideRequestService: AnyObject, Observable {
    /// `nil` when no ride has been requested this session (or the last one
    /// finished and was dismissed). One request in flight at a time — M1
    /// scope, matches the prototype's single `requestState`/`requestDest`.
    var activeRequest: RideRequestRecord? { get }

    /// Submits a new request — mirrors ride-request.jsx's `onSubmit`
    /// (`ReviewContent`'s primary CTA, ride-request.jsx:1234-1237): status
    /// becomes `.pending` immediately (visible to the owner's
    /// `IncomingRequestSheet` right away — the rider's own 10s "sending"
    /// countdown, `PendingContent`, is a local flavor animation on top of
    /// this, not a gate on when the owner sees it, see `RideRequestTiming`).
    /// Arms the `minimizeToAutoAcceptDelay` fallback (ride-request.jsx:
    /// 1112-1117) in case the owner never manually intervenes.
    func submit(_ input: RideRequestInput)

    /// Owner accepts (`IncomingRequestSheet`'s "Accept & send"/"Accept
    /// ride"). Cancels the auto-accept fallback, flips `status` to
    /// `.accepted`, stamps `acceptedAt`, seeds `trackProgress` at
    /// `RideRequestTiming.autoAcceptInitialProgress`, and starts ticking it
    /// toward 1 over `RideRequestTiming.trackingDemoDuration`.
    func accept()

    /// Owner declines. Immediate, no animation (ride-request.jsx:1276
    /// `onReject` has no choreography, unlike accept).
    func decline()

    /// Rider cancels an in-flight (not yet accepted) request
    /// (`PendingContent`'s "Cancel request" / `closeToIdle`).
    func cancel()

    /// Ride Summary's "See you soon" — builds the completed-ride record for
    /// `RideHistoryStore` and resets `activeRequest` to `nil`. Returns `nil`
    /// if there's no request or it hasn't reached `trackProgress >= 0.999`.
    func completeAndReset() -> RequestedRide?
}

// MARK: - Timing constants (single source, per CLAUDE.md deliverable 2)

/// Every simulated delay in the ride-request flow, one place, each cited to
/// the jsx it ports. M2's real service deletes this file — dispatch timing
/// then comes from the backend.
public enum RideRequestTiming {
    /// Rider's booking CTA gold-fill sweep — ride-request.jsx:528,647 `10000ms linear`.
    public static let sendFillDuration: TimeInterval = 10
    /// Hold on "Request sent" before minimizing to idle — ride-request.jsx:524 `1000ms`.
    public static let sentHoldDuration: TimeInterval = 1
    /// Minimize-then-auto-accept fallback if the owner never manually
    /// intervenes — ride-request.jsx:1112-1117 `2600ms`.
    public static let minimizeToAutoAcceptDelay: TimeInterval = 2.6
    /// Owner's manual accept: tap → "Sending to {vehicle}…" — ride-request.jsx:1278 `700ms`.
    public static let ownerSendingDuration: TimeInterval = 0.7
    /// Owner's manual accept: "sent" checkmark hold before `onAccept` fires —
    /// ride-request.jsx:1279 (total 1700ms from tap; `1000ms` after `sent`).
    public static let ownerSentHoldDuration: TimeInterval = 1.0
    /// `RouteSentToast` auto-dismiss — app.jsx:144 `4200ms`.
    public static let toastAutoDismissDuration: TimeInterval = 4.2
    /// Fixed pickup leg ("car → rider") used by both Pending and Tracking —
    /// ride-request.jsx:554,751,918 `6 min`.
    public static let pickupLegMinutes: Double = 6
    /// `trackProgress` seed on auto-accept (no intermediate "accepted"
    /// banner) — screens.jsx:2081 `progressOverride = 0.06`.
    public static let autoAcceptInitialProgress: Double = 0.06
    /// Total wall-clock time to animate `trackProgress` 0→1 once accepted.
    /// The prototype has no reference auto-increment — `trackProgress` is
    /// entirely Tweaks-slider-driven there (see MYR-171 research notes); this
    /// compresses a ride the way `SimulatedVehicleTelemetrySource
    /// .demoDurationSeconds` already compresses a drive, so the tracking →
    /// Ride Summary transition is observable in a manual QA pass or the
    /// drift-gate screenshots without a real multi-minute wait.
    public static let trackingDemoDuration: TimeInterval = 48
    /// Rotating placeholder / search glow interval reused as-is
    /// (`SharedViewerScreen.RotatingPlaceholder`, MYR-191) — not redefined
    /// here.
}

// MARK: - Models

public enum RideRequestStatus: String, Sendable, Equatable {
    case pending
    case accepted
    case declined
}

public struct RideSchedule: Sendable, Equatable {
    public var day: String
    public var time: String
    public init(day: String, time: String) {
        self.day = day
        self.time = time
    }
}

/// What the rider is asking for — ride-request.jsx's `requestDest` +
/// `requestPassenger` + `requestKind`/`requestSchedule` + the chosen
/// `FleetMember`, bundled into one value the service can stamp with a status.
public struct RideRequestInput: Sendable, Equatable {
    public var pickup: RidePlace
    public var destination: RidePlace
    public var fleetMemberID: String
    public var passenger: RidePassenger?
    public var schedule: RideSchedule?

    public init(pickup: RidePlace, destination: RidePlace, fleetMemberID: String, passenger: RidePassenger? = nil, schedule: RideSchedule? = nil) {
        self.pickup = pickup
        self.destination = destination
        self.fleetMemberID = fleetMemberID
        self.passenger = passenger
        self.schedule = schedule
    }

    public var fleetMember: FleetMember {
        RideRequestFixtures.fleet.first { $0.id == fleetMemberID } ?? RideRequestFixtures.fleet[0]
    }
}

public struct RideRequestRecord: Identifiable, Sendable, Equatable {
    public let id: String
    public var input: RideRequestInput
    public var status: RideRequestStatus
    public let requestedAt: Date
    public var acceptedAt: Date?
    /// 0...1 along the whole trip (pickup leg + drop-off leg combined) —
    /// `nil` until `.accepted`. `>= 0.999` is "arrived" (ride-request.jsx:
    /// 1125,1245 `isSummary`).
    public var trackProgress: Double?

    public init(id: String = UUID().uuidString, input: RideRequestInput, status: RideRequestStatus = .pending, requestedAt: Date = Date()) {
        self.id = id
        self.input = input
        self.status = status
        self.requestedAt = requestedAt
    }

    /// `pickupMins / (pickupMins + tripMins)` — the leg split
    /// (ride-request.jsx:751-757).
    public var pickupCut: Double {
        let pickupMins = RideRequestTiming.pickupLegMinutes
        let tripMins = Double(max(input.destination.minutes, 1))
        return pickupMins / (pickupMins + tripMins)
    }

    public var isArrived: Bool { (trackProgress ?? 0) >= 0.999 }
}
