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

/// The compact Dynamic Island's trailing slot — **a figure or nothing**.
///
/// Uber's rule, and the board's: `8 min` / `1 min` / `3:42 PM`, the mark alone where
/// there is no figure, and a glyph at the two stops. Every status WORD v2 rendered
/// here is deleted, along with the width ladder they needed.
enum RideActivityCompact: Equatable {
    /// 15/600 tabular, white. The pickup countdown's `{n} {unit}` or the trip leg's
    /// clock time — already composed, for the same no-clock-in-the-widget reason.
    case figure(String)

    /// A real SF Symbol, white — `hand.wave.fill` at the kerb, `checkmark.circle.fill`
    /// when the ride is done. Not artwork: Apple's optical weights, the same shapes
    /// the board drew with Material Symbols.
    case glyph(Glyph)

    /// The mark alone. Dispatch, both no-ETA degrades, and every ending.
    case markOnly

    enum Glyph: Equatable {
        /// `hand.wave.fill`, 17 — the car greeting you.
        case wave
        /// `checkmark.circle.fill`, 15 — the ride is done, not merely somewhere.
        case check
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

    /// The compact island's trailing content.
    var compact: RideActivityCompact

    /// ActivityKit's own staleness verdict, passed through. v3 uses it for exactly
    /// two things — the headline drops its figure, and the subline becomes
    /// `Last updated {t}` — and for NOTHING visual: no dimming, no desaturation, no
    /// badge.
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

        return RideActivityCard(
            status: state.status,
            leg: leg,
            headline: headline(state: state, leg: leg, isStale: isStale, now: now, time: time),
            subline: subline(state: state, vehicle: vehicle, isStale: isStale, time: time),
            rail: rail(for: state),
            compact: compact(state: state, leg: leg, now: now, time: time),
            isStale: isStale
        )
    }

    // MARK: - Row 2 · the headline

    private static func headline(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        isStale: Bool,
        now: Date,
        time: (Date) -> String
    ) -> RideActivityHeadline {
        switch state.status {
        case .requested:
            return .sentence(RideActivityCopy.dispatchHeadline)
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
    /// The one exception in the board's own table is Dispatch, where there is no car
    /// to name and no leg to be part-way along — and even there the line describes
    /// what is happening TO the rider's request rather than restating the headline.
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
        case .requested:
            return RideActivityCopy.dispatchSubline
        case .accepted, .arrived:
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

    // MARK: - The compact island

    /// A figure, a glyph, or the mark alone.
    ///
    /// **STALENESS DOES NOT CHANGE THIS SLOT**, deliberately, and it is the one place
    /// the island and the card disagree on purpose: the card has room to explain
    /// itself and swaps its headline for a sentence, the island has room for one
    /// thing, and the last figure says more to a rider at a glance than an empty
    /// pill. It is NOT dimmed either — v2 dropped it to 45%; v3 has one accent and no
    /// dimming vocabulary at all.
    private static func compact(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        now: Date,
        time: (Date) -> String
    ) -> RideActivityCompact {
        switch state.status {
        case .arrived: return .glyph(.wave)
        case .completed: return .glyph(.check)
        default: break
        }

        guard RideActivityCopy.showsFigure(for: state.status), let eta = state.etaDate else {
            return .markOnly
        }

        switch leg {
        case .pickup:
            return .figure(RideActivityCountdown.parts(until: eta, now: now).text)
        case .dropoff, .none:
            return .figure(time(eta))
        }
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
