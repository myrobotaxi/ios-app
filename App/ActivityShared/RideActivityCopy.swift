import Foundation
import MyRobotaxiContracts

// MARK: - Every word the Live Activity says (MYR-172, redesigned r16 v2 by MYR-398)
//
// ALL COPY IS THE CLIENT'S. The server sends the status ENUM and never prose —
// "so wording can change in an app update without a server deploy"
// (live-activity.schema.json). This is the one place that wording lives, for all
// four surfaces, and it is pure: no SwiftUI, no ActivityKit, so the app's unit
// tests can assert on it directly even though no presentation can be instantiated
// in a test.
//
// ─────────────────────────────────────────────────────────────────────────────
// THIS TABLE IS `design/la/la-data.jsx`, PORTED ROW FOR ROW.
//
// That file's own header says it: "This mirrors RideActivityCopy on the client;
// every string here is a client-side string." So it is the ANSWER KEY, not an
// illustration — a state whose wording differs from its row is a defect on this
// side, and `RideActivityCardTests` walks all twelve rows.
//
// What the v2 redesign changed about the words themselves:
//
//   • THE COUNTDOWN IS `{n} min` / `{n} s`, NEVER `mm:ss` (handoff §1 change 3).
//     Formatting lives in `RideActivityCountdown` below, so the one rule that
//     decides "minutes or seconds" is testable rather than living in a view.
//   • TWO STATES GAINED HEADLINES THAT DID NOT EXIST — `requested` and the
//     unknown-status fallback (handoff §1 change 11). Both are reachable: a push
//     can legitimately move an Activity's status backwards to `requested` in a
//     race, and the schema mandates tolerating a member this build has not heard
//     of.
//   • THE DEGRADE SENTENCES WENT. MYR-398 v1 had "Heading to pickup" / "On the
//     way" standing in for an absent ETA; the board replaced both with the
//     state's OWN sentence, so a card with no ETA reads like a card and not like
//     a truncation.
//   • `Meet at ` AND THE `{Vehicle} → {Destination}` TRIP LINE ARE DROPPED
//     (handoff §1 change 10). The second line is one place: the pickup's bare
//     name on leg one, the destination's bare name on leg two.
//   • THE STATUS WORD IS NOW TWO WORDS, and they are different lengths on
//     purpose. `chipWord` is the chip's ("Reservation expired"); `compactWord` is
//     the compact island's ("Ended"). One table served both before, which is why
//     the island was falling back to the long word (handoff §1 change 6).
// ─────────────────────────────────────────────────────────────────────────────

enum RideActivityCopy {
    /// What to call the car when the wire's `vehicleName` is the empty string.
    ///
    /// The schema is explicit that an unnamed car arrives as `""` rather than as an
    /// absent key, "in which case the client renders its own generic fallback
    /// rather than a blank". Trimming first because a name of only spaces is the
    /// same situation wearing a disguise, and a lock screen reading "  is on its
    /// way" is the failure this exists to prevent.
    static let genericVehicleName = "Your Tesla"

    static func vehicleDisplayName(_ wireName: String) -> String {
        let trimmed = wireName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? genericVehicleName : trimmed
    }

    // MARK: - The wordmark

    /// The card's brand row, beside the 20pt tile — rendered uppercase at 42%.
    ///
    /// Written lower-case and cased by the view (`Wordmark`'s own grammar), so the
    /// string and its treatment stay separable the way they are everywhere else in
    /// the app.
    static let wordmark = "myrobotaxi"

    // MARK: - The headline

    /// What comes before the live countdown — "Pick up in **4 min**" / "Arriving in
    /// **17 min**".
    ///
    /// It switches on the LEG rather than on the status because the number means
    /// two different things either side of the pickup, and because `accepted`,
    /// `arrived` and `requested` are one leg wearing three statuses.
    static func headlinePrefix(for leg: RideActivityLeg) -> String {
        switch leg {
        case .pickup: return "Pick up in"
        case .dropoff: return "Arriving in"
        }
    }

    /// The sentence headline — the whole line when there is no number to show, and
    /// the whole line on every ending.
    ///
    /// `la-data.jsx`, row for row. Three rows are worth naming:
    ///
    ///   • `cancelled` is SUBJECT-FREE — "This ride was cancelled", not "{Car}
    ///     cancelled". The rider may be the one who cancelled it, and a sentence
    ///     that puts the car in the subject position blames it for their own tap.
    ///   • `completed` names the PLACE, because that is the one ending where where
    ///     you are is the news. It degrades to "You've arrived" rather than to
    ///     "You've arrived at " when the wire carries no destination label.
    ///   • `unrecognized` says "{Car} ride in progress" — new in v2, where v1 had
    ///     the bare vehicle name. A name on its own is not a sentence and read as
    ///     a truncated one; "in progress" is the only thing still safe to assert
    ///     about a status this build cannot interpret.
    static func sentence(
        for status: LiveActivityRideStatus,
        vehicleName: String,
        destination: String
    ) -> String {
        let car = vehicleDisplayName(vehicleName)
        let place = destination.trimmingCharacters(in: .whitespacesAndNewlines)

        switch status {
        case .requested:
            return "\(car) is on its way to you"
        case .accepted:
            return "\(car) is coming to pick you up"
        case .arrived:
            return "\(car) is here"
        case .enroute:
            return "\(car) is taking you there"
        case .completed:
            return place.isEmpty ? "You've arrived" : "You've arrived at \(place)"
        case .declined:
            return "\(car) can't take this ride"
        case .cancelled:
            return "This ride was cancelled"
        case .reservationExpired:
            // The one status with no ride-row twin. The sweeper gave up, so the
            // honest thing is to say the reservation lapsed rather than leave the
            // rider reading "on its way" about a car that is not coming.
            return "\(car) didn't make it in time"
        case .unrecognized:
            return "\(car) ride in progress"
        }
    }

    // MARK: - The chip

    /// The status chip's word. 10.5/500 at 82% white, beside a 5pt tone dot.
    ///
    /// "Reservation expired" is the widest of these and therefore sets the chip's
    /// maximum width — the handoff calls that out because the lock card's brand row
    /// has to hold tile + wordmark + chip at that width without reflowing.
    static func chipWord(for status: LiveActivityRideStatus) -> String {
        switch status {
        case .requested: return "Requested"
        case .accepted: return "On the way"
        case .arrived: return "Arrived"
        case .enroute: return "In ride"
        case .completed: return "Dropped off"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .reservationExpired: return "Reservation expired"
        // A status this build has never heard of. Deliberately bland: the
        // alternative is guessing, and a confident wrong word on a lock screen is
        // worse than a vague right one.
        case .unrecognized: return "Ride"
        }
    }

    /// What the chip says INSTEAD once ActivityKit marks the content stale
    /// (handoff §1 change 7, board decision 2).
    ///
    /// **THE CHIP IS THE WARNING NOW.** v1 put staleness in a notice under the card
    /// and left the chip saying "In ride", which is the one place a rider looks
    /// first and the one place that was still confident. The notice stays, quieter,
    /// and the chip carries the news with a grey dot.
    ///
    /// The word "stale" never renders anywhere — it is ActivityKit's vocabulary,
    /// not a rider's.
    static let staleChipWord = "Not updating"

    /// The stale notice, dated from the last thing the server said.
    ///
    /// ⚠️ **`lastUpdate` IS `nil` ON TODAY'S WIRE, AND THAT IS NOT AN OVERSIGHT.**
    /// The widget process holds exactly three things — the static attributes, the
    /// content state, and `context.isStale` — and none of them is an update
    /// instant. `ActivityViewContext` exposes no `staleDate` (checked against the
    /// SDK interface, iOS 26.5), the content state's only instant is the `eta`, and
    /// the `eta` is a FUTURE instant that was chosen BEFORE the update that carried
    /// it. Rendering "Last update 4:02 PM" off an ETA would therefore overstate
    /// freshness on the one card whose entire job is to admit it has none — the
    /// worst direction to be wrong in. (v1 shipped exactly that, as
    /// "As of {eta} ago", which renders "in 4 minutes ago" on a card whose ETA has
    /// not yet elapsed.)
    ///
    /// So the `{t}` arm is written, tested and unreachable: the day the wire (or a
    /// future `ActivityViewContext`) carries an update instant, `resolve` passes it
    /// and the design's line renders as drawn. Until then the notice keeps its
    /// SHAPE — hollow 5pt ring, 11.5pt at 42% — and says the one true thing.
    static func staleNotice(lastUpdate: Date?, formatter: (Date) -> String) -> String {
        guard let lastUpdate else { return staleNoticeWithoutAnInstant }
        return "Last update \(formatter(lastUpdate))"
    }

    /// The notice when there is no instant to date it from.
    static let staleNoticeWithoutAnInstant = "Waiting for an update"

    // MARK: - The compact island

    /// The compact island's status text, for the states with no figure to show.
    ///
    /// A separate table from `chipWord` on purpose, and that is the part of board
    /// decision 1 that matters: the compact region is a few dozen points wide, and
    /// v1 fell back to the chip's word there — which put "Reservation expired" into
    /// a slot that fits "Ended". Rejected alternatives, from the board: the vehicle
    /// name (reads as branding, and repeats across five states) and arrow-only (the
    /// island already has a minimal presentation).
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    /// **CLIENT DECISION, 2026-07-31 — this table SUPERSEDES `la-data.jsx`'s own
    /// compact column, and it relaxes the board's "one word" rule on purpose.**
    ///
    ///   requested                     Sent    → **Requested**
    ///   accepted                      Coming  → **On the way**
    ///   arrived                       Here    → **Arrived**
    ///   enroute                       Driving → **Arriving**
    ///   completed                     Done    → **Dropped off**
    ///   declined/cancelled/expired    Ended   → **Ride ended**  ⚠️ see below
    ///   unrecognized                  Ride    (unchanged)
    ///
    /// ⚠️ **THE THREE ENDINGS' PHRASE IS ONE WORD OFF WHAT WAS ASKED FOR, AND THE
    /// REASON IS A MEASUREMENT.** The client asked for **"Ride cancelled"** and
    /// asked, in the same breath, that it be verified in a capture rather than
    /// assumed — *"if either truncates on device geometry, report it WITH the
    /// capture and the widest passing alternative, don't silently shorten."*
    ///
    /// It truncates. Captured on the iPhone 17 Pro compact island: **"Ride
    /// cancell…"**, with the pill grown so wide it evicts the status bar's wifi and
    /// battery glyphs. Measured text widths in that slot, same run, same device:
    ///
    ///   "Requested"       70.3pt   fits
    ///   "Ride ended"      73.7pt   fits          ← shipped
    ///   "On the way"      74.3pt   fits
    ///   "Dropped off"     80.0pt   fits
    ///   "Ride cancelled"  91.3pt   **TRUNCATED** — the slot's ceiling is ~91pt
    ///
    /// So this is the widest passing alternative that keeps every part of the
    /// client's intent: ONE shared phrase across all three unhappy endings, more
    /// explicit than the board's bare "Ended", and saying the one thing a glance
    /// needs — this ride is not happening. It is **not** a silent shortening: it is
    /// called out in the PR with the capture, pinned by
    /// `testTheShippedEndingPhraseIsTheWidestONEThatFits`, and it is a one-word
    /// revert the moment the client prefers a different fit.
    ///
    /// "Ride ended" is also the more accurate of the two, which is a bonus rather
    /// than the reason: a ride the OWNER declined did not "cancel", and neither did
    /// a reservation the sweeper gave up on. The precision the SHARED phrase costs
    /// is still deliberate and still the client's call — `chipWord` keeps all three
    /// apart on the card, where there is room to say which.
    ///
    /// Five of the seven now MATCH the chip verbatim, which reads as board decision
    /// 1 being undone and is not. What that decision was about is the island having
    /// its OWN column, so a state whose chip is long can say something SHORTER —
    /// and that is intact where it matters: `reservation_expired`'s chip is 19
    /// characters and its island string is 14. What the client changed is which
    /// words go in the column, and he chose the ride's own vocabulary over the car
    /// talking about itself ("Coming"/"Driving" → "On the way"/"Arriving").
    ///
    /// **THE THREE UNHAPPY ENDINGS SHARE ONE PHRASE**, client-directed: declined,
    /// cancelled and reservation-expired all read the same thing on the island, and
    /// the specific reason stays on the card, where the chip and a whole sentence
    /// have room for it. The client's reasoning is that a glance at the island wants
    /// one fact — this ride is not happening — and three near-synonyms in a slot
    /// this size are three chances to make a rider stop and parse.
    ///
    /// **THE LONGEST STRINGS FIT, AND THAT IS MEASURED RATHER THAN ASSUMED.** The
    /// board's rule was "one word, never truncates"; the first half was how the
    /// second half was guaranteed, and this table breaks it repeatedly ("On the
    /// way" 10, "Dropped off" 11). Once the rule is gone the guarantee has to be a
    /// capture — and the first string that went past the slot's ceiling proved it,
    /// above. See `RideActivityIslandUITests.testTheLongestCompactWordsFitTheSlot`.
    /// ─────────────────────────────────────────────────────────────────────────
    static func compactWord(for status: LiveActivityRideStatus) -> String {
        switch status {
        case .requested: return "Requested"
        case .accepted: return "On the way"
        case .arrived: return "Arrived"
        case .enroute: return "Arriving"
        case .completed: return "Dropped off"
        case .declined, .cancelled, .reservationExpired: return "Ride ended"
        case .unrecognized: return "Ride"
        }
    }

    /// The expanded island's affordance line, at its quietest step.
    ///
    /// It appears in exactly one situation (la-kit's `LAIslandExpanded`): a SENTENCE
    /// state that is not stale and has no rail — i.e. the endings, where the bottom
    /// row would otherwise be empty. The expanded island is reached by a deliberate
    /// long press, so a rider who got there was looking for something; on a live
    /// state the chip, the rail and the countdown are that something, and on an
    /// ending the only thing left to offer is the way back into the app.
    static let islandHint = "Tap to open MyRoboTaxi"

    // MARK: - Gates

    /// Whether a countdown may be shown at all for this status.
    ///
    /// A terminal ride has no future arrival, so even if a stale `eta` is still
    /// sitting in the content state it must not be counted down — that is the
    /// "never a confident stale ETA" rule (MYR-194) applied to the state rather
    /// than to the clock.
    static func showsCountdown(for status: LiveActivityRideStatus) -> Bool {
        switch status {
        case .accepted, .arrived, .enroute, .requested: return true
        case .completed, .declined, .cancelled, .reservationExpired: return false
        case .unrecognized: return false
        }
    }
}

// MARK: - `{n} min` / `{n} s`

/// The ETA figure's FORMAT, as a pure rule (MYR-398 v2, handoff §1 change 3 + §3).
///
/// ─────────────────────────────────────────────────────────────────────────────
/// **NEVER `mm:ss`.** `Text(timerInterval:countsDown:)` renders exactly that and
/// therefore cannot be used at all — the handoff's SwiftUI note 1 says so in as
/// many words, and it is the reason this type exists instead of a one-line view.
/// `4:12` after "Pick up in" reads as a clock time (a rider glances and thinks
/// "quarter past four"), and second-precision on a lock card is false precision
/// about a car in traffic.
///
/// **AND IT DOES NOT COUNT DOWN — CLIENT DECISION, 2026-07-31, WHICH SUPERSEDES
/// THE HANDOFF'S OWN SWIFTUI NOTE 1.** That note proposed a 1s
/// `TimelineView(.periodic)` emitting a new figure every second. The client's
/// ruling, verbatim: *"We are pulling live data from Tesla ETA telemetry; counting
/// down is inaccurate."*
///
/// He is right about the thing that matters, and it is a point about PROVENANCE
/// rather than about rendering. The `eta` on the wire is the CAR'S OWN carried
/// navigation ETA (§7.21.3), which is a live estimate over live traffic — not a
/// stopwatch that was started once. A phone decrementing it locally is not showing
/// the car's answer more often, it is showing an EXTRAPOLATION of the car's last
/// answer and dressing it as the car's current one. Between pushes that
/// extrapolation is exactly as wrong as the traffic is, and the rider cannot tell
/// which of the two they are looking at.
///
/// So the figure is derived ONCE, when a content state arrives, from the pushed
/// instant against that moment — and then it HOLDS until the next push (60–90s) or
/// the next state change. A figure that has stopped being refreshed at all is what
/// staleness is for: the chip becomes "Not updating" and the headline swaps to the
/// sentence.
///
/// **THE PLATFORM AGREES, WHICH IS WORTH RECORDING.** Before the ruling landed this
/// was implemented with the handoff's 1s `TimelineView(.periodic)` and MEASURED on
/// the simulator: one Activity, two SpringBoard captures 70 seconds apart, a
/// 6-minute ETA — the status-bar clock advanced from 10:44 to 10:45 and the compact
/// island read `5 min` in both frames. ActivityKit does not tick a periodic
/// timeline between content updates; only `Text(timerInterval:)` and
/// `ProgressView(timerInterval:)` are special-cased that way, and both render the
/// format the board removed. The client's decision and the platform's behaviour are
/// the same behaviour, so this build no longer has a mechanism that only appears to
/// work.
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
    /// `now` is "the moment this frame was composed", which for a pushed update is
    /// the moment the push landed. It is a parameter and not `Date()` inside the
    /// body precisely so that is a statement rather than an accident: the figure
    /// belongs to the frame, and re-deriving it later would be the local countdown
    /// the client ruled out.
    ///
    /// **MINUTES ARE TRUNCATED, NOT ROUNDED**, and the handoff's own worked example
    /// is what settles it: change 3 rewrites the shipped `4:12` as `4 min`. That is
    /// floor, and it is also the reading every clock in the world has trained —
    /// "4 min" means "somewhere in the fourth minute". Rounding up would print
    /// `5 min` over a car 4:12 away and would make the minute→second handover jump
    /// backwards (`2 min` → `1 min` → `59 s` across two seconds).
    ///
    /// **A LAPSED INSTANT CLAMPS TO `0 s` RATHER THAN GOING NEGATIVE OR VANISHING.**
    /// The card is repainted by pushes it does not control, so an ETA can and does
    /// run out between them; `0 s` is honest, holds the line's width, and is the
    /// only value in the set that says "any moment now" without inventing a word
    /// for it.
    static func parts(until: Date, now: Date = Date()) -> Parts {
        let remaining = max(0, until.timeIntervalSince(now))

        if remaining >= secondsUnit {
            return Parts(value: String(Int(remaining / 60)), unit: "min")
        }
        return Parts(value: String(Int(remaining)), unit: "s")
    }
}
