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
/// Everything a rider READS normally comes over the wire in `ContentState`, and
/// anything put here is frozen at start time: a `vehicleName` in the attributes
/// would still say "Blue Whale" after the owner renamed the car mid-ride, with no
/// way for a push to correct it. So the bar for a static field is that the fact
/// genuinely CANNOT change for the life of the Activity.
///
/// Two fields clear it. The ride id is what the Activity IS. The VEHICLE is the
/// MYR-398 v3 addition (`RideActivityVehicle`) and clears it for the same kind of
/// reason: §7.8 has no endpoint that re-assigns a ride's car, and a ride whose car
/// changed would be a different ride. Pushing five identification strings through
/// APNs ~40 times a ride to tell the phone facts it read off `GET /api/vehicles`
/// before the Activity started would be the same waste §7.21.3 already refuses for
/// the pickup label.
///
/// ⚠️ **`pickupLabel` IS GONE IN v3.** v2's second line was the pickup PLACE
/// ("Meet at Sansome & Clay"), which names where the rider is already standing; the
/// v3 board's leg-one subline is the CAR (`7SRJ294 · Silver Model Y`), which is what
/// somebody at a kerb is actually looking for. Nothing renders the label any more,
/// and a stored attribute nothing reads is the MYR-369 shape — a field that looks
/// wired and is not. Removing it is safe in the one direction that matters: an
/// Activity started by the v2 build carries an extra key, and a synthesized Swift
/// decoder IGNORES unknown keys. (Adding a NON-OPTIONAL one is what would break that
/// decode, which is why `vehicle` below is optional.)
struct RideActivityAttributes: ActivityAttributes {
    /// The SERVER's ride-request id (`RideRequest.id`), which is also
    /// `RideRequestRecord.id` on the live path. It is the path component of
    /// `POST/DELETE /api/ride-requests/{id}/activity-token`, so an Activity that
    /// could not name its server ride could never be registered for pushes.
    var rideID: String

    /// The car, as the pickup leg's subline identifies it — plate, colour, model,
    /// year, trim (MYR-398 v3, MYR-279/286/320).
    ///
    /// OPTIONAL, for two independent reasons. (1) An Activity started by a build
    /// that predates this field is DECODED by the system after an app update, and a
    /// non-optional addition would fail that decode and take a live ride's card off
    /// the lock screen on upgrade day. (2) A ride whose vehicle the app has not
    /// resolved yet is a real state, and `RideActivityVehicleDescriptor` answers it
    /// with "Your Tesla" rather than with a blank line.
    var vehicle: RideActivityVehicle?

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

        /// How far along the CURRENT LEG the car is, `0...1` — the fraction the
        /// progress track draws (MYR-398, contracts 0.27.0).
        ///
        /// WHICH leg is not on the wire and must not be asked for: `status` already
        /// says it (`accepted`/`arrived` is the car coming to the rider, `enroute`
        /// is the car taking them onward), and one fact carried twice is one fact
        /// that can disagree with itself. `RideActivityLeg.of(_:)` is the client's
        /// single reading of it.
        ///
        /// OMITTED ENTIRELY when the server cannot say — never null, never `0`.
        /// That distinction is the whole feature: **an absent progress renders a
        /// TRACKLESS card, a wrong one renders a lie.** `0` is not the humble
        /// answer, it is the claim "the car has covered none of the distance", so a
        /// renderer must never substitute it for `nil` and must never invent a
        /// fraction from the ETA, the app's own `trackProgress`, or anything else
        /// the phone can see. This is the same trap `eta` carries: optional on the
        /// wire AND optional here, so a MISSPELLED key decodes silently to `nil`
        /// and simply renders no track — no throw, no log. Cross-pinned by
        /// `RideActivityContentStateTests`.
        ///
        /// It is MONOTONE PER LEG, clamped SERVER-SIDE to the highest fraction
        /// already delivered to this Activity. `eta` deliberately is NOT clamped,
        /// and §7.21.3 is explicit that the client must render both AS GIVEN:
        /// "most of the way there, and arriving later than it said" is a coherent
        /// pair, and a client that tries to reconcile them hides the true one.
        var progress: Double?

        init(
            v: Int = RideActivityContentVersion.current,
            status: LiveActivityRideStatus,
            eta: Int? = nil,
            vehicleName: String,
            destination: String,
            progress: Double? = nil
        ) {
            self.v = v
            self.status = status
            self.eta = eta
            self.vehicleName = vehicleName
            self.destination = destination
            self.progress = progress
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

    /// When the server last had something to say — the instant the stale subline
    /// dates itself from (`Last updated 3:31 PM`).
    ///
    /// ⚠️ **`nil` ON TODAY'S WIRE, AND THIS ACCESSOR IS THE WHOLE SEAM.** The v3
    /// board's stale row reads `Last updated {h:mm A}`, and nothing the widget
    /// process holds is an update instant: `ActivityViewContext` exposes no
    /// `staleDate` (SDK interface, iOS 26.5), and the content state's only instant
    /// is the `eta` — a FUTURE instant chosen BEFORE the update that carried it, so
    /// dating the notice from it OVERSTATES freshness on the one card whose entire
    /// job is to admit it has none. (v1 shipped exactly that, as "As of {eta} ago",
    /// which renders "in 4 minutes ago".)
    ///
    /// **contracts 0.28.0 adds `asOf` (unix seconds) to the Live Activity content
    /// state.** It was NOT tagged when this branch was cut (latest published tag:
    /// `v0.27.0`), so the mirror below carries no `asOf` property and this accessor
    /// answers `nil`, which `RideActivityCard.subline` renders as
    /// `Waiting for an update`. Landing it is three lines and one test, in this
    /// order — and the order matters, because the SECOND step is the one with a
    /// silent failure mode:
    ///
    ///   1. bump the Kit's contracts pin to `0.28.0`;
    ///   2. add `var asOf: Int?` to the mirror below — **spelled exactly**, since
    ///      ActivityKit decodes `aps.content-state` with a plain `JSONDecoder` and
    ///      no key strategy, and a wrong key on an OPTIONAL decodes silently to
    ///      `nil` (the MYR-362 trap, which `eta` and `progress` already carry);
    ///   3. return `asOf.map { Date(timeIntervalSince1970: TimeInterval($0)) }`
    ///      here, and extend `RideActivityContentStateTests`' raw-key cross-pin,
    ///      which is what makes step 2 checkable at all.
    var asOfDate: Date? { nil }

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
