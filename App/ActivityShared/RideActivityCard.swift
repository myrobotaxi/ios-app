import Foundation
import MyRobotaxiContracts

// MARK: - What the Live Activity card SAYS and DRAWS (MYR-398, r16 redesign v3)
//
// PURE, and for the same reason `RideActivityStateMachine` is: the presentations
// themselves cannot be instantiated in a unit test (an `ActivityViewContext` needs
// a real Activity in a real host process), so everything worth asserting about the
// card lives here as a function of (content state, static attributes, staleness).
// The SwiftUI in `Widgets/Sources/RideActivityPresentation.swift` reads this and
// lays it out; it makes no decisions of its own.
//
// It is compiled into BOTH targets (`App/ActivityShared`), so the app's test bundle
// can reach it even though the widget process is the only thing that renders it.
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT v3 CHANGED ABOUT THIS TYPE'S OUTPUT SHAPE
//
// The split — one pure resolver, views that switch on values and never on `status`
// — is v2's and is kept verbatim, because it is what made the board an executable
// assertion. What changed is every field it returns:
//
//   • `headline` is THREE forms now, and two of them are per-leg. The pickup leg
//     counts down (`Pickup in 8 min`); the trip leg states a clock time (`3:42 PM
//     dropoff`); everything else is a sentence.
//   • `subline` replaces `secondLine`. It is always a PLACE or an IDENTIFICATION,
//     never a status, and it is a plain `String?` rather than a two-case enum
//     because v3 has no per-case treatment left — one size, one colour, one line.
//   • `rail` replaces `track: Double?`. **The rail is ALWAYS rendered.** An absent
//     progress is the `idle` variant (track and pin drawn, no fill, 50% puck at the
//     origin) rather than an absent row — "an untraveled route, not an error", and
//     the reason every state has the same 128pt footprint.
//   • `chipWord`, `tone`, `pulsesToneDot` are **DELETED**. There are no chips and
//     no status colours on any surface; one accent (gold), no tone dots, no pulse.
//   • `compact` is a FIGURE, a GLYPH, or NOTHING. Every status word v2 put in that
//     slot is gone.
// ─────────────────────────────────────────────────────────────────────────────
//
// ─────────────────────────────────────────────────────────────────────────────
// WHAT §0 CHANGED (MYR-398 §0, the client's change request against the v3 build in
// TestFlight as `202608011331`)
//
// One thing, and it is the "or NOTHING" above. The compact island's empty half-pill
// and the expanded island's empty trailing slot are now a PROGRESS RING, and the
// choice between a figure, a glyph and each of the ring's three modes is resolved
// HERE, as `RideActivityTrailingSlot`, for the same reason everything else on this
// surface is: a priority ladder living in a view is a ladder no test can climb.
//
// `compact` keeps its name and its meaning; `expandedTrailing` is the same ladder
// with the ETA rung removed, and the minimal island renders that one too.
// ─────────────────────────────────────────────────────────────────────────────
//
// ─────────────────────────────────────────────────────────────────────────────
// THE HONESTY RULES, AND HOW v3 KEEPS THEM WITH AN ALWAYS-DRAWN RAIL
//
// §7.21.3's rule 1 is that an absent `progress` must not be rendered as `0`: "`0`
// is the claim the car has covered none of the distance; absence is the admission
// we cannot say." v2 kept it by drawing NO rail. v3 keeps it by drawing the IDLE
// rail — which is a different mark, not a zero-valued one: no gold fill at all, and
// a half-strength puck parked at the origin. A rail with a gold fill of width zero
// and a full-strength puck would be the lie; this is the row saying "here is the
// route, nothing of it has been reported".
//
//   2. `eta` ABSENT → NO FIGURE. The headline degrades to `Pickup soon` /
//      `Dropoff soon`. The client NEVER computes an ETA — the contract's ETA is the
//      CAR'S OWN carried navigation ETA and nothing on the phone is that.
//   3. RENDER BOTH AS GIVEN. `progress` is clamped server-side and `eta` is
//      deliberately not, so "most of the way there and arriving later than it said"
//      is a coherent pair. Reconciling them here would hide the true one.
// ─────────────────────────────────────────────────────────────────────────────

/// Which half of the ride the card is describing.
///
/// The LEG IS NOT ON THE WIRE and must never be asked for: §7.21.3 keeps it off the
/// payload precisely because `status` already carries it, and "one fact on the wire
/// twice is two things that can disagree". This is the client's single reading of
/// it — the headline's FORM, the subline's subject and the rail's reset key all come
/// through here rather than each switching on `status` themselves.
enum RideActivityLeg: String, Hashable, CaseIterable {
    /// Leg one — the car driving to the RIDER. The card counts down in minutes and
    /// the subline identifies the car.
    case pickup

    /// Leg two — the car driving the rider ONWARD. The card states a clock time and
    /// the subline names where they are going.
    case dropoff

    /// `nil` for a ride that has no leg in progress at all, which is not the same
    /// as "leg unknown": a declined, cancelled or lapsed ride is not part-way along
    /// anything, and neither is a status this build has never heard of.
    static func of(_ status: LiveActivityRideStatus) -> RideActivityLeg? {
        switch status {
        case .requested, .accepted, .arrived:
            // `arrived` is the END of leg one, not the start of leg two: the car is
            // at the kerb and the rider has not boarded. The server sends exactly
            // `1` here on the ride record's authority, so the pickup rail renders
            // FULL — which is the picture the rider wants at that moment.
            //
            // `requested` is leg ONE too, even though at Dispatch there is no car
            // yet. The leg is what the ride is DOING; the absence of a vehicle is
            // what the idle rail and the mark-only island say.
            return .pickup
        case .enroute:
            return .dropoff
        case .completed:
            // The leg it ENDED on. `completed` lingers FIVE MINUTES (MYR-405,
            // client 2026-07-31 — superseding MYR-194's ~15, and superseding the v3
            // handoff's stale "~15 min" note in its own la-data row) carrying a
            // `progress` of exactly `1`, so the drop-off rail renders full for the
            // whole linger rather than disappearing at the moment of arrival.
            return .dropoff
        case .declined, .cancelled, .reservationExpired, .unrecognized:
            return nil
        }
    }
}

/// The card's headline — row 2, 20/600, ONE line, `lineLimit(1)`.
///
/// **TWO OF THE THREE FORMS ARE PER-LEG, AND THAT IS THE FIELD REPORT'S FIX.** A
/// duration and a time of day are now different shapes, so `17 min` on the way to a
/// destination can never be read as "arriving at 17 past".
enum RideActivityHeadline: Equatable {
    /// `Pickup in 8 min` — the pickup leg, counting down in MINUTES (`45 s` under a
    /// minute). Resolved once per content state and HELD; see
    /// `RideActivityCountdown`.
    case pickupCountdown(RideActivityCountdown.Parts)

    /// `3:42 PM dropoff` — the trip leg, stating a CLOCK TIME. Already formatted,
    /// so the view cannot re-derive it and no clock enters the widget process.
    case dropoffClock(String)

    /// A sentence with no figure in it: Dispatch, both `… soon` degrades, the
    /// arrival, and every ending.
    case sentence(String)
}

/// The route line — row 4, 18pt, **ALWAYS RENDERED**.
///
/// Two states only, which is the board's §4 rail contract in full. There is no
/// dimmed variant and no absent variant: when the pushes stop, the last known
/// position is still true, so the rail keeps its gold and the SUBLINE says
/// `Last updated 3:31 PM`. (v2 desaturated it to `#5C5A54`; that colour is deleted
/// with this type's `isStale` reading of the rail.)
struct RideActivityRailState: Equatable {
    /// `0…1`, clamped. On `idle` it is always `0` — an idle rail with a fraction
    /// would be a fill that is not drawn, i.e. a number the card is keeping to
    /// itself.
    var progress: Double

    /// The untravelled variant: track and destination pin drawn, NO gold fill, and
    /// the puck at 50% opacity parked at the origin.
    var isIdle: Bool

    static let idle = RideActivityRailState(progress: 0, isIdle: true)

    static func live(_ progress: Double) -> RideActivityRailState {
        RideActivityRailState(progress: min(1, max(0, progress)), isIdle: false)
    }
}

/// **THE TRAILING SLOT, RESOLVED — the §0 D priority ladder as five values.**
///
/// One type for three surfaces (the compact island's trailing half-pill, the
/// expanded island's `.trailing` region, and the minimal island), because the RULE
/// is one rule with one exception, and writing it once is what stops the three
/// disagreeing about a state nobody thought to check.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// **THE LADDER RESOLVES STRICTLY, TOP DOWN:**
///
///   1. **The ETA FIGURE**, if the server has one — `8 min` / `1 min` / `3:42 PM`,
///      rendered exactly as they were before §0. **The ring never displaces a
///      number.**
///   2. **The arrival GLYPH**, at the two stops.
///   3. **The RING**, and only when neither: Dispatch, both no-ETA states, the
///      no-telemetry state, and every ending. It fills the half-pill that used to be
///      EMPTY (v3's `markOnly`), which is the whole of §0 B — a rider who cannot see
///      an ETA could not previously tell "waiting on the car" from "the app is
///      dead".
///
/// The expanded island's slot runs the SAME ladder **minus step 1** — the expanded
/// headline already carries the figure, so a second copy of it 20pt to the right is
/// the badge the whole redesign removed. That slot is glyph-or-ring, never empty and
/// never the ETA. The minimal island renders that same figure-less resolution.
/// ─────────────────────────────────────────────────────────────────────────────
enum RideActivityTrailingSlot: Equatable {
    /// 15/600 tabular, white. The pickup countdown's `{n} {unit}` or the trip leg's
    /// clock time — already composed, for the same no-clock-in-the-widget reason.
    /// **Compact only.**
    case figure(String)

    /// A real SF Symbol, white — `hand.wave.fill` at the kerb, `checkmark.circle.fill`
    /// when the ride is done. Not artwork: Apple's optical weights, the same shapes
    /// the board drew with Material Symbols.
    ///
    /// It arrives with the §0 C beat, and it outranks the ring rather than sitting
    /// beside it because the two are one mark. **On the compact and expanded trailing
    /// slots it stands ALONE** (MYR-412 — the client's board, and his *"why is there a
    /// circle around the hand"*); on the MINIMAL island it lands inside the completed
    /// ring, which is the surface that keeps a centre at all.
    case glyph(Glyph)

    /// Telemetry is flowing — a gold arc of `rail.p`, floored so its cap is visible.
    ///
    /// **THE FRACTION IS THE RAIL'S OWN**, not a second reading of `progress`: one
    /// source, so the card's rail and the island's ring can never disagree about how
    /// far along the same leg is.
    case ringDeterminate(Double)

    /// The route is known and the car has reported nothing yet — **the board's
    /// LOADING RING**: solid track, a partial gold arc, round cap, nothing in the
    /// middle. It was designed to turn (§0 B), and MYR-412 established that no
    /// mechanism available on this surface will turn it — not `repeatForever`, not an
    /// appearance-armed animation, and not an SF Symbol effect. It ships static, which
    /// is what the client's mock draws.
    case ringIndeterminate

    /// The ring with no arc at all. A ride that ENDED is not making progress and is
    /// not waiting on anything, so it gets the track and nothing else.
    case ringTrackOnly

    enum Glyph: Equatable {
        /// `hand.wave.fill`, 17 — the car greeting you.
        case wave
        /// `checkmark.circle.fill`, 15 — the ride is done, not merely somewhere.
        case check
    }

    /// Whether this resolution puts a RING on the surface that keeps one in every
    /// non-figure state — the MINIMAL island. The structural form of "never empty":
    /// every case but `.figure` does, and `.figure` cannot reach that surface.
    var drawsRing: Bool {
        if case .figure = self { return false }
        return true
    }

    /// **MYR-412 — whether the two BARE surfaces draw the ring.**
    ///
    /// The compact trailing half-pill and the expanded `.trailing` region render the
    /// arrival glyph INSTEAD of the ring rather than inside it, so `.glyph` answers
    /// `false` here where it answers `true` to `drawsRing`. The client's board is
    /// explicit about both halves — a bare wave and a bare check at the two stops, and
    /// a bare loading ring where there is neither a glyph nor a figure — and his
    /// question was *"why is there a circle around the hand thats not needed"*.
    ///
    /// It is a second accessor rather than a redefinition of the first because the
    /// two surfaces genuinely differ: minimal keeps the mark in the middle of the
    /// ring, and one boolean answering for both is the shape that makes a surface
    /// borrow another's rendering.
    var drawsBareRing: Bool {
        switch self {
        case .figure, .glyph: return false
        case .ringDeterminate, .ringIndeterminate, .ringTrackOnly: return true
        }
    }

    /// The arrival glyph this resolution renders on its own, if any.
    var bareGlyph: Glyph? {
        if case .glyph(let glyph) = self { return glyph }
        return nil
    }
}

/// The whole card, resolved.
struct RideActivityCard: Equatable {

    /// The status the card is describing, carried so accessibility and any future
    /// slot come off the SAME resolution every visible element did.
    var status: LiveActivityRideStatus

    var leg: RideActivityLeg?

    /// Row 2.
    var headline: RideActivityHeadline

    /// Row 3 — a PLACE or an IDENTIFICATION, never a status.
    ///
    /// `nil` only when the fact it would name is genuinely absent (an `enroute`
    /// frame whose `destination` is the empty string). The ROW is still 17pt tall in
    /// that case: the footprint is fixed in every state, so an absent subline costs
    /// the card nothing and moves nothing.
    var subline: String?

    /// Row 4. Never optional — see `RideActivityRailState`.
    var rail: RideActivityRailState

    /// The compact island's trailing content — the whole §0 D ladder.
    var compact: RideActivityTrailingSlot

    /// The EXPANDED island's `.trailing` region, and the MINIMAL island.
    ///
    /// The same ladder minus the ETA. It is resolved HERE rather than derived in the
    /// view from `compact`, because "the expanded slot is the compact one unless it
    /// is a figure, in which case fall through to whatever the next rung would have
    /// been" is a rule, and a rule that lives in a view is a rule no test reads.
    var expandedTrailing: RideActivityTrailingSlot

    /// The RESOLVED staleness verdict — ActivityKit's `context.isStale` OR the
    /// server's own `asOf` having fallen behind the three-minute horizon (see
    /// `RideActivityFreshness`). v3 uses it for exactly two things — the headline
    /// drops its figure, and the subline becomes `Last updated {t}` — and for
    /// NOTHING visual: no dimming, no desaturation, no badge.
    var isStale: Bool

    /// Resolve the card from everything the widget process is handed.
    ///
    /// `vehicle` is the STATIC attribute (see `RideActivityVehicle`); `state` is the
    /// pushed content state; `isStale` is `ActivityViewContext.isStale`.
    ///
    /// `now` IS THE FRAME'S OWN MOMENT — the instant this content state was
    /// composed, which for a pushed update is the instant it landed. It is a
    /// parameter for two reasons. It makes the whole card a deterministic function
    /// of its inputs, so the fourteen-row table can be asserted against literal
    /// figures. And it is where the client's "no local countdown" ruling is
    /// enforced: the figure is derived HERE, once, and every surface is handed the
    /// composed string rather than the instant, so no view is able to re-derive it a
    /// second later.
    ///
    /// `time` formats the two wall-clock strings. Injected for the one reason those
    /// are unlike every other string on this surface: they need a LOCALE, and the
    /// system's answer is not ours to hard-code — see `RideActivityClock`.
    static func resolve(
        state: RideActivityAttributes.ContentState,
        vehicle: RideActivityVehicle?,
        isStale: Bool,
        now: Date = Date(),
        time: (Date) -> String = RideActivityClock.shortTime
    ) -> RideActivityCard {
        let leg = RideActivityLeg.of(state.status)

        // **TWO WAYS A CARD GOES STALE, AND ACTIVITYKIT ONLY KNOWS ONE.**
        //
        // `context.isStale` fires when no push has arrived inside the window the
        // last one armed. The OTHER way is the one contracts 0.28.0 added `asOf`
        // for: the ETA ticker keeps pushing, so `aps.stale-date` keeps being
        // re-armed and ActivityKit never fires — while the server has not LEARNED
        // anything for ten minutes and the track is frozen. Folding both into one
        // verdict here is what keeps the rest of this type reading a single fact.
        let stale = isStale || RideActivityFreshness.hasGoneQuiet(asOf: state.asOfDate, now: now)
        let rail = rail(for: state)

        return RideActivityCard(
            status: state.status,
            leg: leg,
            headline: headline(
                state: state, vehicle: vehicle, leg: leg, isStale: stale, now: now, time: time
            ),
            subline: subline(state: state, vehicle: vehicle, isStale: stale, time: time),
            rail: rail,
            compact: trailingSlot(
                state: state, leg: leg, rail: rail, allowsFigure: true, now: now, time: time
            ),
            expandedTrailing: trailingSlot(
                state: state, leg: leg, rail: rail, allowsFigure: false, now: now, time: time
            ),
            isStale: stale
        )
    }

    // MARK: - Row 2 · the headline

    private static func headline(
        state: RideActivityAttributes.ContentState,
        vehicle: RideActivityVehicle?,
        leg: RideActivityLeg?,
        isStale: Bool,
        now: Date,
        time: (Date) -> String
    ) -> RideActivityHeadline {
        switch state.status {
        case .requested:
            // MYR-417 — the ONE headline on this surface that names the car, and the
            // only one that needs the vehicle at all. See
            // `RideActivityCopy.rideRequestedFrom` for why the board's "Finding your
            // ride" is wrong for a product where the rider asked a specific car.
            return .sentence(
                RideActivityCopy.rideRequestedFrom(
                    RideActivityVehicleName.display(wire: state.vehicleName, vehicle: vehicle)
                )
            )
        case .arrived:
            return .sentence(RideActivityCopy.arrivedHeadline)
        case .completed:
            return .sentence(RideActivityCopy.completedHeadline)
        case .declined:
            return .sentence(RideActivityCopy.declinedHeadline)
        case .cancelled:
            return .sentence(RideActivityCopy.cancelledHeadline)
        case .reservationExpired:
            return .sentence(RideActivityCopy.expiredHeadline)
        case .unrecognized:
            return .sentence(RideActivityCopy.unknownHeadline)
        case .accepted, .enroute:
            break
        }

        // The two figure-bearing states. The `soon` sentence is the degrade for BOTH
        // reasons a figure can be missing — no ETA on the wire, and staleness — and
        // it is the same string in the same slot either way, which is what keeps the
        // card from moving.
        let soon = RideActivityHeadline.sentence(
            leg == .dropoff ? RideActivityCopy.dropoffSoon : RideActivityCopy.pickupSoon
        )

        // STALE OUTRANKS THE ETA. A figure the server has stopped confirming is
        // still a number a rider reads as the answer, and the point of staleness is
        // that we no longer have one. The whole headline swaps rather than the
        // figure freezing — a frozen figure looks identical to a working one.
        guard !isStale, let eta = state.etaDate else { return soon }

        switch leg {
        case .pickup:
            return .pickupCountdown(RideActivityCountdown.parts(until: eta, now: now))
        case .dropoff, .none:
            return .dropoffClock(time(eta))
        }
    }

    // MARK: - Row 3 · the subline

    /// **ALWAYS A PLACE OR AN IDENTIFICATION, NEVER A STATUS.**
    ///
    /// **MYR-417 REMOVED THE ONE EXCEPTION.** The board's Dispatch row put a PROCESS
    /// here — "Matching you with a ride" — because on a hailing product there is no
    /// car to name yet. There is one here: the rider asked a specific vehicle, and
    /// its plate, colour, year and model are already on the Activity's static
    /// attributes at `Activity.request`. So dispatch carries the SAME descriptor the
    /// rest of the pickup leg does, and the whole leg is one card whose figure and
    /// rail fill in rather than two cards that swap.
    private static func subline(
        state: RideActivityAttributes.ContentState,
        vehicle: RideActivityVehicle?,
        isStale: Bool,
        time: (Date) -> String
    ) -> String? {
        // STALENESS OWNS THIS ROW ON EVERY LIVE STATE. It is the one sentence the
        // card has room for, and putting it here rather than in a badge is the whole
        // of the board's "exceptions are sentences".
        //
        // Terminal states are excluded: a cancelled ride is not waiting for an
        // update, and "Last updated 3:31 PM" under "Ride cancelled" would suggest
        // the outcome might still change. See `staleOwnsTheSubline` for why that
        // gate is a list of statuses rather than "does this status have a leg" —
        // `completed` has one.
        if isStale, RideActivityCopy.staleOwnsTheSubline(for: state.status) {
            guard let asOf = state.asOfDate else { return RideActivityCopy.waitingForAnUpdate }
            return RideActivityCopy.lastUpdated(time(asOf))
        }

        switch state.status {
        case .requested, .accepted, .arrived:
            // The car, identified. From the STATIC attributes, never off a push —
            // see `RideActivityVehicle` for why the vehicle cannot change for the
            // life of an Activity and therefore does not belong on the wire.
            return RideActivityVehicleDescriptor.compose(vehicle)
        case .enroute:
            let place = nonEmpty(state.destination)
            return place.map(RideActivityCopy.headingTo)
        case .completed:
            // The place alone. The headline already says what happened, so
            // "Heading to" would be the wrong tense and a preposition nobody needs.
            return nonEmpty(state.destination)
        case .declined, .cancelled:
            return RideActivityCopy.nothingWasCharged
        case .reservationExpired:
            return RideActivityCopy.expiredSubline
        case .unrecognized:
            return RideActivityCopy.openTheApp
        }
    }

    // MARK: - Row 4 · the rail

    /// The board's §4 rail contract, in one function.
    ///
    /// ```
    /// Dispatch                 0    idle    route known, car isn't
    /// Enroute / Arriving       p    live    fills toward the pickup pin
    /// Enroute · no telemetry   0    idle    no fraction has been reported
    /// Arrived                  1    live    pin removed — the mark IS the marker
    /// leg flip → On trip       0    live    RESET (the view's `.id(leg)` does it)
    /// On trip                  p    live
    /// Completed                1    live
    /// Pushes stopped        hold    live    position held, and STILL GOLD
    /// Declined/Cancelled/Expired/Unknown  0  idle
    /// ```
    ///
    /// **`arrived` AND `completed` ARE FULL ON THE STATUS'S AUTHORITY, NOT ON THE
    /// FRACTION'S.** Both send exactly `1` in practice, but a frame that omitted it
    /// would still mean the leg is over — the car IS at the kerb, the rider HAS been
    /// dropped off — so falling back to the idle rail there would draw an untravelled
    /// route under "Your ride is here". Everywhere else an absent fraction is the
    /// idle rail, which is the honest no-telemetry state and one of the board's own
    /// fourteen rows.
    private static func rail(for state: RideActivityAttributes.ContentState) -> RideActivityRailState {
        switch state.status {
        case .arrived, .completed:
            return .live(state.progress ?? 1)
        case .accepted, .enroute:
            guard let progress = state.progress else { return .idle }
            return .live(progress)
        case .requested:
            return .idle
        case .declined, .cancelled, .reservationExpired, .unrecognized:
            return .idle
        }
    }

    // MARK: - The trailing slot · §0 D

    /// **THE PRIORITY LADDER, IN ONE FUNCTION, FOR THREE SURFACES.**
    ///
    /// `allowsFigure` is the ONLY difference between the compact island's slot and
    /// the expanded island's, and it is a parameter rather than two functions
    /// precisely because "the same rule minus one rung" is what the handoff says: two
    /// implementations would be two ladders one edit apart from disagreeing about a
    /// state (which is how v1's expanded island came to spell the trip line
    /// differently from the card's in the first place).
    ///
    /// **STALENESS DOES NOT CHANGE THIS SLOT**, deliberately, and it is the one place
    /// the island and the card disagree on purpose: the card has room to explain
    /// itself and swaps its headline for a sentence, the island has room for one
    /// thing, and the last figure says more to a rider at a glance than an empty
    /// pill. It is NOT dimmed either — v2 dropped it to 45%; v3 has one accent and no
    /// dimming vocabulary at all.
    private static func trailingSlot(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        rail: RideActivityRailState,
        allowsFigure: Bool,
        now: Date,
        time: (Date) -> String
    ) -> RideActivityTrailingSlot {
        // 1 · THE FIGURE, and it outranks everything. `8 min` / `1 min` / `3:42 PM`
        // resolve exactly as they did before §0 — the ring is an addition to the
        // states that had NOTHING, never a replacement for a number.
        if allowsFigure, let figure = figure(state: state, leg: leg, now: now, time: time) {
            return .figure(figure)
        }

        // 2 · THE GLYPH, at the two stops.
        //
        // The two rungs are DISJOINT in practice — `showsFigure` is false for both
        // `arrived` and `completed`, so no state can satisfy both — and the order is
        // still written down, because the handoff states one and a reader should not
        // have to prove the tie can never happen to know which way it breaks.
        if let glyph = glyph(for: state.status) { return .glyph(glyph) }

        // 3 · THE RING.
        return ring(for: state.status, rail: rail)
    }

    /// The ETA-derived figure, or `nil` where the status may not carry one.
    private static func figure(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        now: Date,
        time: (Date) -> String
    ) -> String? {
        guard RideActivityCopy.showsFigure(for: state.status), let eta = state.etaDate else {
            return nil
        }
        switch leg {
        case .pickup: return RideActivityCountdown.parts(until: eta, now: now).text
        case .dropoff, .none: return time(eta)
        }
    }

    private static func glyph(for status: LiveActivityRideStatus) -> RideActivityTrailingSlot.Glyph? {
        switch status {
        case .arrived: return .wave
        case .completed: return .check
        default: return nil
        }
    }

    /// **THE RING'S THREE STATES**, and each of them is a different thing to say.
    ///
    /// ```
    /// telemetry flowing        determinate   the rail's own p, floored at 2%
    /// route known, car quiet   indeterminate a 25% arc turning — "waiting on the car"
    /// the ride ended           track only    nothing is in progress, nothing is coming
    /// ```
    ///
    /// **THE ENDED TEST IS `RideActivityLeg.of(status) == nil`, NOT A SECOND LIST OF
    /// STATUSES.** That accessor already answers "is this ride part-way along
    /// anything", and it is the one that has to stay in step with the rail — a second
    /// list would be a second definition of "over", and the first status added to one
    /// and not the other renders a spinner beside "Ride cancelled". It also settles
    /// the `unrecognized` arm the right way: a status this build cannot interpret is
    /// not evidence a car is on its way, so it claims nothing.
    ///
    /// Dispatch is INDETERMINATE and that is the state the rotation was asked for:
    /// no car has been assigned, the rail is idle, and the ring saying "still
    /// working on it" is the difference between a waiting app and a dead one.
    static func ring(
        for status: LiveActivityRideStatus,
        rail: RideActivityRailState
    ) -> RideActivityTrailingSlot {
        guard RideActivityLeg.of(status) != nil else { return .ringTrackOnly }
        guard !rail.isIdle else { return .ringIndeterminate }
        return .ringDeterminate(max(RideActivityMetrics.ringMinimumArc, rail.progress))
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - The monotone hold

/// The client's half of "the rail never runs backwards".
///
/// THE SERVER IS THE ENFORCER (§7.21.3 clamps every pushed fraction to the highest
/// it has already DELIVERED to this Activity), and the widget honours whatever it
/// is handed — a Live Activity view holds no memory between pushes, so there is no
/// "previous" for it to compare against and inventing one would be a second,
/// divergent clamp on the surface least able to reason about it.
///
/// What this rule is for is the frames the CLIENT writes. The app is the backstop
/// (MYR-194 decision 2) and composes a local frame whenever the ride record moves,
/// carrying the last push's values forward — so this is where a lower value could
/// otherwise reach the lock screen, and where the leg is known on both sides.
///
/// UNCHANGED BY THE v3 REDESIGN. The board's "one rail per leg … the leg flip is the
/// only event allowed to send progress backward" is exactly this rule, restated.
enum RideActivityProgress {
    /// The fraction a newly-composed frame should carry.
    ///
    /// THE LEG IS THE RESET KEY, and it has to be: leg one ends at exactly `1` and
    /// leg two opens at ~`0`, so a max taken across the flip would pin the drop-off
    /// rail at full for the entire ride. A leg change therefore adopts the new leg's
    /// value verbatim, INCLUDING `nil` — "telemetry never seen this leg" is the
    /// board's own idle rail, and holding leg one's `1` over it would draw a
    /// completed journey the car has not started.
    ///
    /// Within one leg it is `max`, and `nil` on either side simply defers to the
    /// other — the same carry-forward `eta` gets, for the same reason: the last
    /// fraction the car reported does not stop being the last fraction the car
    /// reported.
    static func held(
        current: Double?,
        currentLeg: RideActivityLeg?,
        previous: Double?,
        previousLeg: RideActivityLeg?
    ) -> Double? {
        guard currentLeg == previousLeg else { return current }
        switch (current, previous) {
        case (let current?, let previous?): return max(current, previous)
        case (let current?, nil): return current
        case (nil, let previous?): return previous
        case (nil, nil): return nil
        }
    }
}
