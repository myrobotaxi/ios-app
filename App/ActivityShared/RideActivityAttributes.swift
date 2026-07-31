import ActivityKit
import Foundation
import MyRobotaxiContracts

// MARK: - The rider's ride Live Activity (MYR-172, decisions in MYR-194)
//
// THIS FILE IS COMPILED INTO TWO TARGETS — `MyRoboTaxi` (which starts, updates
// and ends the Activity) and `MyRoboTaxiWidgets` (which renders it, in a separate
// process). It is shared as a SOURCE FOLDER listed by both targets in
// `project.yml` rather than as a fourth local SPM package, because it is one small
// value type with no behaviour: a package would add a module boundary, a
// `public`-everything surface and a second place to bump the contracts pin, and
// would buy nothing that two `sources:` entries do not.
//
// It must therefore stay free of anything only ONE side has. In particular it
// imports no DesignSystem (the app does not render the Activity) and no
// MyRoboTaxiKit (the extension does no networking, and must not link a REST client
// into a process that renders a lock screen).

/// The static, never-changing half of the Activity — fixed at `Activity.request`
/// and immutable for the Activity's whole life.
///
/// It carries the ride id and nothing else. Everything a rider READS comes over
/// the wire in `ContentState`, and anything put here would be frozen at start
/// time: a `vehicleName` in the attributes would still say "Blue Whale" after the
/// owner renamed the car mid-ride, with no way for a push to correct it. The ride
/// id is here precisely because it is the one fact that genuinely cannot change —
/// it is what the Activity IS.
struct RideActivityAttributes: ActivityAttributes {
    /// The SERVER's ride-request id (`RideRequest.id`), which is also
    /// `RideRequestRecord.id` on the live path. It is the path component of
    /// `POST/DELETE /api/ride-requests/{id}/activity-token`, so an Activity that
    /// could not name its server ride could never be registered for pushes.
    var rideID: String

    /// The mutable half — the exact shape the server sends as `aps.content-state`
    /// on an ActivityKit remote update.
    ///
    /// ────────────────────────────────────────────────────────────────────────
    /// THE PROPERTY NAMES ARE THE WIRE KEYS. THERE ARE NO `CodingKeys` HERE, AND
    /// ADDING ONE IS A BREAKING CHANGE EVEN IF EVERYTHING STILL COMPILES.
    /// ────────────────────────────────────────────────────────────────────────
    ///
    /// ActivityKit decodes a remote update's `content-state` into this type with a
    /// plain `JSONDecoder` and NO key strategy, so the synthesized `CodingKeys` —
    /// i.e. the Swift property names, spelled exactly — are what has to match
    /// `schemas/live-activity.schema.json`. Renaming a property to read better
    /// (`etaAt`, `vehicle`, `destinationLabel`) silently stops that key decoding.
    ///
    /// That failure is SILENT for `eta` specifically, and this is the MYR-362 trap
    /// in a new place: `eta` is optional on the wire and optional here, so a wrong
    /// key does not throw — it decodes to `nil`, which is indistinguishable from
    /// the server's own legitimate "ETA unknown, key omitted". The lock screen just
    /// quietly never shows a countdown, no error is logged, and a decode
    /// round-trip test written against this same misspelling passes. The guard is
    /// `RideActivityContentStateTests`, which asserts the RAW KEYS this type
    /// produces against the raw keys the GENERATED `LiveActivityContentState`
    /// produces — the check MYR-362 lacked, since there the hand-authored type and
    /// its fixture were written from one misreading and agreed with each other.
    ///
    /// Why a mirror at all, rather than using the generated type directly:
    /// `ActivityAttributes.ContentState` requires `Hashable`, and the generated
    /// `LiveActivityContentState` is `Codable, Equatable, Sendable`. Retro-fitting
    /// `Hashable` onto generated code is not ours to do, so the mirror is
    /// unavoidable — which is exactly why it is pinned rather than trusted.
    struct ContentState: Codable, Hashable, Sendable {
        /// Content-state schema version — `1` today. The server can keep sending
        /// v1 to installed builds while v2 goes to new ones, because a Swift
        /// ContentState is frozen into an app a rider may not update for months.
        var v: Int

        /// The ride state being displayed. This is the GENERATED contracts enum,
        /// not a second copy, so it inherits the `unrecognized(String)` arm the
        /// schema requires a client to tolerate ("a client MUST tolerate an
        /// unrecognised member rather than failing to decode"). A hand-written
        /// mirror enum would have thrown on the first status a future server adds
        /// and taken the whole lock screen down with it.
        ///
        /// `reservation_expired` is the member with no `RideRequestStatus` twin,
        /// and it is the reason this enum is not simply the app's own status type.
        var status: LiveActivityRideStatus

        /// The car's arrival time as an ABSOLUTE unix timestamp in SECONDS —
        /// **not** a duration, and **not** milliseconds.
        ///
        /// Absolute is the contract's central decision: a duration decays silently
        /// on a screen the server cannot repaint ("4 min" stays "4 min" for an
        /// hour), whereas an instant stays true however late it is read, and the
        /// phone counts down on its own between the 60–90s pushes. That is what
        /// lets the lock screen use `Text(timerInterval:)` and be correct with no
        /// push at all.
        ///
        /// OMITTED ENTIRELY when unknown — never null, never zero, never a guess.
        /// So `nil` here means "no ETA to show", and the renderer must say nothing
        /// rather than show a placeholder number. A car with no active nav route
        /// yields no key at all; there is no server-side route solver.
        var eta: Int?

        /// The owner-chosen nickname, e.g. "Blue Whale". EMPTY STRING when the car
        /// has no name — not absent, not null. The client renders its own generic
        /// fallback in that case (`RideActivityCopy.vehicleDisplayName`), never a
        /// blank space where a name should be.
        var vehicleName: String

        /// The dropoff's short label — the name the RIDER chose when booking, e.g.
        /// "Home".
        ///
        /// P1, and the one field here that the ride-lifecycle ALERT copy policy
        /// forbids on a lock screen. It is carried narrowly and deliberately: a
        /// Live Activity is the rider's own ride on the rider's own device,
        /// addressed by a token scoped to that one Activity. It must never be
        /// copied into an alert body, and it is never sent to an owner's Activity —
        /// v1 starts none.
        var destination: String

        init(
            v: Int = RideActivityContentVersion.current,
            status: LiveActivityRideStatus,
            eta: Int? = nil,
            vehicleName: String,
            destination: String
        ) {
            self.v = v
            self.status = status
            self.eta = eta
            self.vehicleName = vehicleName
            self.destination = destination
        }
    }
}

/// The content-state schema version this build speaks.
enum RideActivityContentVersion {
    static let current = 1
}

extension RideActivityAttributes.ContentState {
    /// The ETA as a `Date`, or `nil` when the server sent no ETA.
    ///
    /// The multiplication by 1 is the whole point of this property existing: the
    /// wire unit is SECONDS (`x-unit: unix-seconds`) and `Date(timeIntervalSince1970:)`
    /// takes seconds, so there is no conversion — but every other timestamp this
    /// app reads off a wire is an ISO-8601 string, so a reader arriving here is
    /// primed to expect a parse and a unit. Naming the accessor is how the absence
    /// of one is made visible.
    var etaDate: Date? {
        eta.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// True when the ride has reached a state that will never be pushed to again.
    ///
    /// Drives the client's local end-fallback. `reservationExpired` counts — that
    /// is its entire reason for existing — and an `unrecognized` status does NOT:
    /// a member this build has never heard of is far more likely to be a new
    /// IN-FLIGHT state than a new terminal one, and guessing wrong in that
    /// direction takes a live ride off the rider's lock screen. Guessing wrong in
    /// the other direction leaves a card up until the server's own `end` push or
    /// the app's next observation clears it, which is the recoverable failure.
    var isTerminal: Bool {
        switch status {
        case .completed, .declined, .cancelled, .reservationExpired:
            return true
        case .requested, .accepted, .arrived, .enroute:
            return false
        case .unrecognized:
            return false
        }
    }
}
