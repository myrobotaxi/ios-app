import Foundation
import MyRobotaxiContracts

// MARK: - Every word the Live Activity says (MYR-172, redesigned r16 v3 by MYR-398)
//
// ALL COPY IS THE CLIENT'S. The server sends the status ENUM and never prose —
// "so wording can change in an app update without a server deploy"
// (live-activity.schema.json). This is the one place that wording lives, for all
// four surfaces, and it is pure: no SwiftUI, no ActivityKit, so the app's unit
// tests can assert on it directly even though no presentation can be instantiated
// in a test.
//
// ─────────────────────────────────────────────────────────────────────────────
// THIS TABLE IS `design/la/la-data.jsx` (v3), ROW FOR ROW — FOURTEEN OF THEM.
//
// v3 was rebuilt against the field report of the v2 build with **Uber's ride Live
// Activity as the explicit structural and copy reference**. What changed about the
// words:
//
//   • **TWO HEADLINE FORMS, ONE PER LEG.** The pickup leg COUNTS DOWN —
//     `Pickup in 8 min`. The trip leg states a CLOCK TIME — `3:42 PM dropoff`.
//     That is the actual fix for the report's first complaint ("it's saying
//     arriving while on the way to the destination"): a duration and a time of day
//     can no longer be confused because they are not the same shape.
//   • **"ARRIVING" IS RETIRED FROM RIDER-FACING COPY.** It survives as a PHASE
//     name for engineering (Uber's `Dispatch → Enroute → Arriving → Arrived → On
//     trip`) and appears in no string on any surface. `testNoSurfaceSaysArriving`
//     is the sweep.
//   • **THE SUBLINE IS ALWAYS A PLACE OR AN IDENTIFICATION, NEVER A STATUS.** The
//     car on the way to you (`7SRJ294 · Silver Model Y`), where you are going
//     (`Heading to Duarte's Tavern`), where you got to (`Duarte's Tavern`), or the
//     one sentence an ending needs. v2's second line was the PICKUP place, which
//     names where the rider is already standing.
//   • **NO CHIPS, NO STATUS WORDS, ANYWHERE.** `chipWord` and `compactWord` are
//     both DELETED. The headline carries the status in words; the compact island
//     carries a FIGURE or nothing. Every one of v2's island strings ("On the way",
//     "Ride ended", "Dropped off") is gone, which also retires the width ladder
//     they needed — a slot that only ever holds `8 min` / `1 min` / `3:42 PM` or a
//     glyph cannot truncate.
//   • **NO ETA IS A WORD, NOT A GAP** — `Pickup soon` / `Dropoff soon`, in the same
//     slot at the same size.
//   • **STALENESS IS ONE SENTENCE IN THE SUBLINE** — `Last updated 3:31 PM`. No
//     pill, no dimmed rail, no "Not updating". See `lastUpdated(_:)` for where the
//     instant comes from and what happens until it does.
// ─────────────────────────────────────────────────────────────────────────────

enum RideActivityCopy {
    /// What to call the car when there is nothing at all to describe it with.
    ///
    /// The board's own nameless-vehicle rule. Reached from
    /// `RideActivityVehicleDescriptor.compose` when the plate, colour and model are
    /// all absent — not from an empty `vehicleName`, which v3 never renders (a
    /// nickname is a name FOR the car, not a description OF it, and the subline's
    /// job is letting a rider match a car they can see).
    static let genericVehicleName = "Your Tesla"

    // MARK: - Row 1 · the wordmark

    /// The card's top row, beside the 20pt tile — rendered uppercase at 42%.
    ///
    /// Written lower-case and cased by the view (`Wordmark`'s own grammar), so the
    /// string and its treatment stay separable the way they are everywhere else in
    /// the app. **Nothing trails it** in v3: the chip that used to sit there is
    /// gone from every surface.
    static let wordmark = "myrobotaxi"

    // MARK: - Row 2 · the headline

    /// The pickup countdown's leading word — `**Pickup** in 8 min`.
    ///
    /// Rendered 600 white, where `in` and the unit are 500 at 62%. It is a NOUN and
    /// not a verb ("Pick up in" was v2's): the line is about the pickup, not an
    /// instruction to the rider.
    static let pickupPhase = "Pickup"

    /// The joining word between the phase and the figure. Its own constant because
    /// it is set in a different weight and colour from either neighbour.
    static let countdownJoin = "in"

    /// The trip leg's trailing word — `3:42 PM **dropoff**`.
    ///
    /// **ONE WORD, NOT "drop-off"**, matching the reference. Set 500 at 62%, the
    /// same treatment `in` and the unit get, so the two headline forms read as one
    /// grammar in two tenses.
    static let dropoffWord = "dropoff"

    /// Dispatch — no car has been assigned, so there is nothing to count down.
    static let dispatchHeadline = "Finding your ride"

    /// The pickup leg with no ETA. Same slot, same size, one word — no badge needed
    /// to explain a missing number.
    static let pickupSoon = "Pickup soon"

    /// The trip leg with no ETA, and the trip leg when the pushes have stopped.
    static let dropoffSoon = "Dropoff soon"

    /// The car is at the kerb. **"Say ride, not a model name"** — the board's rule,
    /// and the reason this is not "{Car} is here".
    static let arrivedHeadline = "Your ride is here"

    /// The one ending that went right.
    static let completedHeadline = "You've arrived"

    /// Declined. **Subject-free and blame-free**: the owner's refusal is not
    /// something to report to the rider as a rejection.
    static let declinedHeadline = "No ride available"

    /// Cancelled. Subject-free on purpose — the rider may be the one who cancelled,
    /// and a sentence with the car in the subject position blames it for their tap.
    static let cancelledHeadline = "Ride cancelled"

    /// The reservation lapsed. The headline is the OUTCOME and the subline is the
    /// reason (`expiredSubline`).
    static let expiredHeadline = "Reservation expired"

    /// A status this build has never heard of — the arm the schema mandates
    /// tolerating. Deliberately bland: the alternative is guessing, and a confident
    /// wrong word on a lock screen is worse than a vague right one.
    static let unknownHeadline = "Ride in progress"

    // MARK: - Row 3 · the subline

    /// Dispatch's subline. The only one that describes a PROCESS rather than a
    /// place, because at dispatch there is neither a car to name nor a leg to be
    /// part-way along.
    static let dispatchSubline = "Matching you with a ride"

    /// The trip leg — `Heading to {place}`.
    static func headingTo(_ place: String) -> String { "Heading to \(place)" }

    /// Declined and cancelled. The one thing a rider wants to know about a ride
    /// that did not happen.
    static let nothingWasCharged = "Nothing was charged"

    /// The reason under `Reservation expired`.
    static let expiredSubline = "No car arrived in time"

    /// The unknown-status fallback's subline, and the only line on any surface that
    /// asks for a tap. It is offered exactly where nothing else can be said.
    static let openTheApp = "Tap to open MyRoboTaxi"

    /// The stale subline — `Last updated 3:31 PM`.
    ///
    /// ⚠️ **THE INSTANT'S SOURCE IS `ContentState.asOf`, WHICH IS NOT ON THE WIRE
    /// TODAY.** The widget process holds exactly three things — the static
    /// attributes, the content state, and `context.isStale` — and until the content
    /// state carries an update instant, none of them is one. `ActivityViewContext`
    /// exposes no `staleDate` (checked against the SDK interface, iOS 26.5), and
    /// the content state's only instant is the `eta`, which is a FUTURE instant
    /// chosen BEFORE the update that carried it: dating the notice from it
    /// OVERSTATES freshness on the one card whose entire job is to admit it has
    /// none. (v1 shipped exactly that, as "As of {eta} ago", which renders "in 4
    /// minutes ago" whenever the ETA has not yet elapsed.)
    ///
    /// So the arm is written, tested and reached the day the wire grows the field:
    /// contracts **0.28.0** adds `asOf` (unix seconds) to the Live Activity content
    /// state, `ContentState.asOfDate` reads it, and this line renders as the board
    /// drew it. Until then `resolve` passes `nil` and the subline is
    /// `waitingForAnUpdate` — which says the same true thing without a number
    /// nobody can source.
    static func lastUpdated(_ time: String) -> String { "Last updated \(time)" }

    /// The stale subline when there is no instant to date it from.
    static let waitingForAnUpdate = "Waiting for an update"

    // MARK: - Gates

    /// Whether this status may carry an ETA-derived figure at all — the countdown
    /// on the pickup leg, the clock time on the trip leg, and the compact island's
    /// figure on both.
    ///
    /// A terminal ride has no future arrival, so even if a stale `eta` is still
    /// sitting in the content state it must not be rendered — MYR-194's "never a
    /// confident stale ETA" applied to the STATE rather than to the clock.
    ///
    /// `requested` is FALSE here and that is the v3 change: at dispatch no car has
    /// been assigned, so a countdown would be counting down to a vehicle that does
    /// not exist yet. (v2 allowed it, because v2's `requested` card was a generic
    /// "on its way" sentence rather than the board's Dispatch state.)
    /// Whether STALENESS takes over this status's subline with `Last updated {t}` /
    /// `Waiting for an update`.
    ///
    /// The four states that are still RUNNING, and no others. **`completed` is the
    /// trap**: it has a LEG (the one it ended on, which the full rail needs), so a
    /// gate written as "does this status have a leg" reads as live and would put
    /// "Waiting for an update" under "You've arrived" — about a ride that is over and
    /// whose outcome cannot change. Every terminal card keeps its own subline, stale
    /// or not.
    ///
    /// `unrecognized` keeps its own line too: "Tap to open MyRoboTaxi" is the only
    /// useful thing to say about a status this build cannot interpret, and it is more
    /// useful stale than fresh.
    static func staleOwnsTheSubline(for status: LiveActivityRideStatus) -> Bool {
        switch status {
        case .requested, .accepted, .arrived, .enroute: return true
        case .completed, .declined, .cancelled, .reservationExpired: return false
        case .unrecognized: return false
        }
    }

    static func showsFigure(for status: LiveActivityRideStatus) -> Bool {
        switch status {
        case .accepted, .enroute: return true
        case .requested, .arrived: return false
        case .completed, .declined, .cancelled, .reservationExpired: return false
        case .unrecognized: return false
        }
    }
}

// MARK: - `{n} min` / `{n} s`

/// The pickup countdown's FORMAT, as a pure rule (MYR-398, handoff §7).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// **NEVER `mm:ss`.** `Text(timerInterval:countsDown:)` renders exactly that and
/// therefore cannot be used at all — `8:12` after "Pickup in" reads as a clock
/// time, which is precisely the confusion v3's two headline forms exist to remove,
/// and second-precision on a lock card is false precision about a car in traffic.
///
/// **AND IT DOES NOT COUNT DOWN — CLIENT DECISION, 2026-07-31, WHICH OUTRANKS THE
/// v3 HANDOFF'S OWN SWIFTUI NOTE.** That note (§9) asks for a 1s
/// `TimelineView(.periodic)` emitting a new figure every second. The client's
/// standing ruling, verbatim: *"We are pulling live data from Tesla ETA telemetry;
/// counting down is inaccurate."*
///
/// The point is PROVENANCE rather than rendering. The `eta` on the wire is the
/// CAR'S OWN carried navigation ETA (§7.21.3) — a live estimate over live traffic,
/// not a stopwatch that was started once. A phone decrementing it locally is not
/// showing the car's answer more often; it is showing an EXTRAPOLATION of the car's
/// last answer, dressed as the car's current one, and the rider cannot tell which
/// of the two they are looking at.
///
/// So the figure is derived ONCE, when a content state arrives, and HELD until the
/// next push (60–90s) or the next state change.
///
/// **THE PLATFORM AGREES, AND v2 MEASURED IT.** The handoff's timeline was
/// implemented on the v2 branch and photographed: one Activity, two SpringBoard
/// captures 70 seconds apart, a 6-minute ETA — the status-bar clock advanced 10:44
/// → 10:45 and the compact island read `5 min` in both frames. ActivityKit does not
/// tick a periodic timeline between content updates. The ruling and the platform's
/// behaviour are the same behaviour, so **this build has no clock in the widget
/// process at all** — the structural form of the rule rather than the disciplined
/// one.
/// ─────────────────────────────────────────────────────────────────────────────
///
/// The unit is NEVER dropped: "4" alone is the same ambiguity with less to go on.
enum RideActivityCountdown: Equatable {

    /// The figure and its unit, resolved for one instant in time.
    struct Parts: Equatable {
        /// The number, as digits. Rendered 600 tabular, in WHITE.
        var value: String
        /// "min" or "s". Rendered 500 at 62%, the same type size as the value.
        var unit: String

        /// The two joined, which is what the compact island shows and what an
        /// accessibility reader says.
        var text: String { "\(value) \(unit)" }
    }

    /// The threshold between the two units. At or above it the card says minutes.
    static let secondsUnit: TimeInterval = 60

    /// Resolve `until` against `now` — ONCE, when the content state arrives.
    ///
    /// **MINUTES ARE TRUNCATED, NOT ROUNDED.** "8 min" means "somewhere in the
    /// eighth minute", which is the reading every clock in the world has trained.
    /// Rounding up would print `9 min` over a car 8:12 away and would make the
    /// minute→second handover jump backwards (`2 min` → `1 min` → `59 s` across two
    /// seconds).
    ///
    /// **A LAPSED INSTANT CLAMPS TO `0 s`** rather than going negative or
    /// vanishing. The card is repainted by pushes it does not control, so an ETA can
    /// and does run out between them; `0 s` is honest, holds the line's width, and
    /// says "any moment now" without inventing a word for it.
    static func parts(until: Date, now: Date = Date()) -> Parts {
        let remaining = max(0, until.timeIntervalSince(now))

        if remaining >= secondsUnit {
            return Parts(value: String(Int(remaining / 60)), unit: "min")
        }
        return Parts(value: String(Int(remaining)), unit: "s")
    }
}

// MARK: - `3:42 PM`

/// The trip leg's clock time, and the stale subline's.
///
/// **A FORMATTED `Date`, NOT A TIMER**, and recomputed only when a new content
/// state arrives. It does not tick, and it does not need to: a time of day is true
/// however late it is read, which is the whole reason the board chose it for the
/// long leg.
///
/// The formatter is INJECTED into `RideActivityCard.resolve` rather than called
/// here directly, for one reason worth stating: this is the only string on any of
/// these surfaces that needs a LOCALE. `.shortened` is the system's 12/24-hour
/// answer, not ours, so the widget passes the system's and a test passes a fixed
/// one — and the fourteen-row table can then assert `3:42 PM` as a literal.
enum RideActivityClock {
    /// The system's own short time — "3:42 PM" in the US, "15:42" where that is the
    /// convention.
    static func shortTime(_ instant: Date) -> String {
        instant.formatted(date: .omitted, time: .shortened)
    }
}
