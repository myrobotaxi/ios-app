import Foundation
import MyRobotaxiContracts

// MARK: - What the Live Activity card SAYS and DRAWS (MYR-398, r16 redesign v2)
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
// WHAT v2 ADDED TO THIS TYPE, AND WHY IT IS HERE RATHER THAN IN THE VIEWS
//
// v1 resolved the headline, the second line and the track here, and then let the
// views ask `RideActivityCopy` directly for the status word — twice, in two slots,
// with two different fallbacks. That is how the compact island came to render the
// chip's long word: nothing was wrong with either call, and no test could see the
// disagreement because neither call was the card.
//
// So v2 resolves the WHOLE row: the chip's word, its TONE, whether that tone dot
// pulses, the second line's one place, and the compact island's text. The views
// switch on values; they never switch on `status`. `RideActivityCardTests` then
// walks `la-data.jsx`'s twelve rows against this one function, which is the only
// way the design's own table can be an executable assertion.
// ─────────────────────────────────────────────────────────────────────────────
//
// ─────────────────────────────────────────────────────────────────────────────
// THE HONESTY RULES THIS TYPE EXISTS TO KEEP (rest-api.md §7.21.3) — UNCHANGED
//
//   1. `progress` ABSENT → NO TRACK. Not an empty rail, not a track at zero. `0`
//      is the claim "the car has covered none of the distance"; absence is the
//      admission "we cannot say". The card composes cleanly without one, which is
//      the only reason the server is free to omit it.
//   2. `eta` ABSENT → NO COUNTDOWN. The headline degrades to the state's own
//      sentence. The client NEVER computes an ETA — the contract's ETA is the
//      CAR'S OWN carried navigation ETA and nothing on the phone is that.
//   3. RENDER BOTH AS GIVEN. `progress` is clamped server-side and `eta` is
//      deliberately not, so "most of the way there and arriving later than it said"
//      is a coherent pair. Reconciling them here would hide the true one.
// ─────────────────────────────────────────────────────────────────────────────

/// Which half of the ride the card is describing.
///
/// The LEG IS NOT ON THE WIRE and must never be asked for: §7.21.3 keeps it off
/// the payload precisely because `status` already carries it, and "one fact on the
/// wire twice is two things that can disagree". This is the client's single
/// reading of it — the headline, the second line and the track's reset key all
/// come through here rather than each switching on `status` themselves.
enum RideActivityLeg: String, Hashable, CaseIterable {
    /// Leg one — the car driving to the RIDER. The card counts down to the pickup
    /// and names where to stand.
    case pickup

    /// Leg two — the car driving the rider ONWARD. The card counts down to the
    /// drop-off and names it.
    case dropoff

    /// `nil` for a ride that has no leg in progress at all, which is not the same
    /// as "leg unknown": a declined, cancelled or lapsed ride is not part-way
    /// along anything, and neither is a status this build has never heard of.
    static func of(_ status: LiveActivityRideStatus) -> RideActivityLeg? {
        switch status {
        case .requested, .accepted, .arrived:
            // `arrived` is the END of leg one, not the start of leg two: the car is
            // at the kerb and the rider has not boarded. The server sends exactly
            // `1` here on the ride record's authority, so the pickup track renders
            // FULL — which is the picture the rider wants at that moment.
            return .pickup
        case .enroute:
            return .dropoff
        case .completed:
            // The leg it ENDED on. `completed` lingers ~15 minutes carrying a
            // `progress` of exactly `1`, so the drop-off track renders full for the
            // whole linger rather than disappearing at the moment of arrival.
            return .dropoff
        case .declined, .cancelled, .reservationExpired, .unrecognized:
            return nil
        }
    }
}

/// The chip's 5pt dot, which is the ONLY place a state's colour appears.
///
/// Handoff §1 change 4: twelve states × coloured text is a dozen colours competing
/// with gold, so the colour collapses into the dot and the chip's label is always
/// 82% white. §4's table maps each of these onto an EXISTING DesignSystem token —
/// there are no new status colours in this redesign.
enum RideActivityTone: String, Hashable, CaseIterable {
    /// `goldDeepSoft` — a claim in flight. `requested` only.
    case pending
    /// `gold` — the car is ours and it is moving toward the rider.
    case active
    /// `driving` — the rider is in the car.
    case riding
    /// `parked` — dropped off. The one ending that went right.
    case complete
    /// `offline` — every other ending, and staleness.
    case terminal
}

/// The card's top line.
enum RideActivityHeadline: Equatable {
    /// "Pick up in" + the ETA figure, `{n} min` / `{n} s`.
    ///
    /// **THE FIGURE TRAVELS, NOT THE INSTANT — CLIENT DECISION, 2026-07-31.** It is
    /// derived ONCE here, when the content state is resolved, and then HELD until
    /// the next push. *"We are pulling live data from Tesla ETA telemetry; counting
    /// down is inaccurate."* See `RideActivityCountdown` for the full reasoning: the
    /// wire's `eta` is the car's own live navigation estimate, and a phone
    /// decrementing it locally shows an extrapolation of the car's last answer while
    /// looking exactly like the car's current one.
    ///
    /// Carrying `Parts` rather than a `Date` is what makes that structural. A view
    /// handed an instant can always re-derive; a view handed a figure cannot.
    case countdown(prefix: String, figure: RideActivityCountdown.Parts)

    /// A sentence with no number in it. Every arm the contract leaves without an
    /// `eta`, plus every terminal state, plus staleness.
    case sentence(String)
}

/// The card's ONE second-line place (handoff §1 change 10, §2 part 2).
///
/// **NEVER A PAIR.** v1 rendered "Meet at {pickup}" on leg one and
/// "{Vehicle} → {Destination}" on leg two; the board dropped the preposition, the
/// vehicle and the arrow. The headline already says which leg you are on and the
/// rail already shows the span, so naming both ends was the busiest row on the
/// card.
enum RideActivitySecondLine: Equatable {
    /// Leg one — where to stand, at 62% white. The bare label, no "Meet at ".
    case pickup(String)
    /// Leg two — where you are going, IN GOLD. The bare label, no vehicle, no
    /// arrow.
    case destination(String)
}

/// What the compact Dynamic Island's trailing slot shows.
enum RideActivityCompact: Equatable {
    /// The ETA figure — 15/600 tabular. Resolved once and held, exactly as the
    /// headline's is.
    ///
    /// `isStale` rides ALONG with it rather than replacing it (handoff §1 change 7):
    /// the compact island keeps the last known figure at 45% instead of dropping to
    /// a word, because a rider glancing at the island wants the number and the
    /// opacity is the whole admission.
    case figure(RideActivityCountdown.Parts, isStale: Bool)

    /// The short status word — 14.5/500, and never `monospacedDigit`.
    case word(String)
}

/// The whole card, resolved.
struct RideActivityCard: Equatable {

    /// The status the card is describing, carried so accessibility and any future
    /// slot come off the SAME resolution every visible element did.
    var status: LiveActivityRideStatus

    var leg: RideActivityLeg?

    var headline: RideActivityHeadline

    /// The one second-line place, or `nil` — leg one with no pickup label, and
    /// every TERMINAL state, where MYR-172's own reasoning stands: "Cancelled" over
    /// a destination reads as a ride still in progress.
    var secondLine: RideActivitySecondLine?

    /// The fraction the track draws, or `nil` for NO TRACK AT ALL.
    var track: Double?

    /// The chip's word — "Not updating" when stale, the status's own word otherwise.
    var chipWord: String

    /// The chip's 5pt dot colour, as a token-free tone.
    var tone: RideActivityTone

    /// Whether that dot PULSES — `arrived`, and only `arrived`.
    ///
    /// The single animation on this card besides the rail's offset (handoff §7,
    /// "everything else is static — Live Activities are budget-limited"). It is on
    /// the one state where something is waiting for the rider rather than the other
    /// way round. A stale `arrived` does not pulse: motion is a claim to be live.
    var pulsesToneDot: Bool

    /// The compact island's trailing content.
    var compact: RideActivityCompact

    /// ActivityKit's own staleness verdict, passed through so the views can dim the
    /// rail and raise the notice.
    var isStale: Bool

    /// The instant the stale notice dates itself from.
    ///
    /// **ALWAYS `nil` TODAY.** See `RideActivityCopy.staleNotice(lastUpdate:…)` —
    /// nothing the widget process holds is an update instant, and the `eta` (v1's
    /// choice) is a FUTURE instant that would overstate freshness on the one card
    /// that exists to admit it has none. The field is kept so the arm has a way in
    /// the day the wire grows one.
    var staleLastUpdate: Date?

    /// Resolve the card from everything the widget process is handed.
    ///
    /// `pickupLabel` is the STATIC attribute; `state` is the pushed content state;
    /// `isStale` is `ActivityViewContext.isStale`.
    ///
    /// `now` IS THE FRAME'S OWN MOMENT — the instant this content state was
    /// composed, which for a pushed update is the instant it landed. It exists as a
    /// parameter for two reasons. It makes the whole card a deterministic function
    /// of its inputs, so the twelve-row table can be asserted against literal
    /// figures. And it is where the client's "no local countdown" ruling is
    /// enforced: the ETA figure is derived HERE, once, and every surface is handed
    /// the figure rather than the instant, so no view is able to re-derive it a
    /// second later.
    static func resolve(
        state: RideActivityAttributes.ContentState,
        pickupLabel: String?,
        isStale: Bool,
        now: Date = Date()
    ) -> RideActivityCard {
        let leg = RideActivityLeg.of(state.status)

        return RideActivityCard(
            status: state.status,
            leg: leg,
            headline: headline(state: state, leg: leg, isStale: isStale, now: now),
            secondLine: secondLine(state: state, leg: leg, pickupLabel: pickupLabel),
            track: track(for: state),
            chipWord: isStale
                ? RideActivityCopy.staleChipWord
                : RideActivityCopy.chipWord(for: state.status),
            tone: isStale ? .terminal : tone(for: state.status),
            pulsesToneDot: state.status == .arrived && !isStale,
            compact: compact(state: state, isStale: isStale, now: now),
            isStale: isStale,
            // The `{t}` arm has no source on this wire. Stated once, here, rather
            // than being quietly absent at a call site.
            staleLastUpdate: nil
        )
    }

    // MARK: - Headline

    private static func headline(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        isStale: Bool,
        now: Date
    ) -> RideActivityHeadline {
        let sentence = RideActivityHeadline.sentence(
            RideActivityCopy.sentence(
                for: state.status,
                vehicleName: state.vehicleName,
                destination: state.destination
            )
        )

        // A terminal ride has no future arrival, so a stale `eta` still sitting in
        // the content state must not be counted down (MYR-194's rule applied to the
        // STATE rather than to the clock).
        guard RideActivityCopy.showsCountdown(for: state.status) else { return sentence }

        // STALE OUTRANKS THE ETA. A dimmed "4 min" is still a number a rider reads
        // as the answer, and the point of staleness is that we no longer have one.
        // The whole headline swaps to the sentence rather than the timer freezing —
        // the handoff's SwiftUI note 1 is explicit about that, because a frozen
        // `TimelineView` looks identical to a working one that has stopped ticking.
        guard !isStale else { return sentence }

        // NO ETA, NO COUNTDOWN — and no locally computed stand-in. `eta` is
        // optional on the wire TODAY (a car with no active nav route yields no key
        // at all, and there is no server-side route solver), so this arm is an
        // ordinary state rather than an error, and it is what makes a future
        // server-side ETA freshness gate (MYR-401) shippable without a client
        // release: omitting the key will land on a card that already knows what to
        // say.
        guard let eta = state.etaDate, let leg else { return sentence }

        return .countdown(
            prefix: RideActivityCopy.headlinePrefix(for: leg),
            figure: RideActivityCountdown.parts(until: eta, now: now)
        )
    }

    // MARK: - The second line

    /// One place, never a pair.
    ///
    /// Present for exactly the four LIVE states and absent on every ending, which
    /// falls out of `showsCountdown` rather than being a second list of statuses to
    /// keep in step — `completed` has a leg (`dropoff`, the one it ended on, which
    /// the full rail needs) and must still show no place.
    ///
    /// STALE CHANGES NOTHING HERE. The handoff's state table says "unchanged": a
    /// pickup and a destination are facts about the ride, not readings off the car,
    /// so they do not rot while the pushes are away.
    private static func secondLine(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        pickupLabel: String?
    ) -> RideActivitySecondLine? {
        guard let leg, RideActivityCopy.showsCountdown(for: state.status) else { return nil }

        switch leg {
        case .pickup:
            // From the STATIC attributes, never off a push. §7.21.3's "Why the
            // 'Meet at {pickup}' line is NOT on the wire" is explicit that a pickup
            // cannot change for the life of a ride and that the app already holds
            // it, so a client that waited for the server to send it would render no
            // second line at all, forever, against a correct server.
            let trimmed = (pickupLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .pickup(trimmed)
        case .dropoff:
            let trimmed = state.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : .destination(trimmed)
        }
    }

    // MARK: - The chip's tone

    private static func tone(for status: LiveActivityRideStatus) -> RideActivityTone {
        switch status {
        case .requested: return .pending
        case .accepted, .arrived: return .active
        case .enroute: return .riding
        case .completed: return .complete
        case .declined, .cancelled, .reservationExpired, .unrecognized: return .terminal
        }
    }

    // MARK: - The compact island

    /// The figure wins whenever there IS one, including when the card is stale.
    ///
    /// Gated on the same two facts the headline's countdown is — an instant on the
    /// wire and a status that may count down — but deliberately NOT on `isStale`,
    /// which is the one place the compact island and the lock card disagree on
    /// purpose (handoff §1 change 7). The card has room to explain itself; the
    /// island has room for one thing, and the last figure at 45% says more than
    /// "Driving" at full strength.
    private static func compact(
        state: RideActivityAttributes.ContentState,
        isStale: Bool,
        now: Date
    ) -> RideActivityCompact {
        if let eta = state.etaDate, RideActivityCopy.showsCountdown(for: state.status) {
            return .figure(RideActivityCountdown.parts(until: eta, now: now), isStale: isStale)
        }
        return .word(RideActivityCopy.compactWord(for: state.status))
    }

    // MARK: - Track

    /// The fraction to draw, or `nil` for no track.
    ///
    /// Clamped to `0...1` and NOTHING ELSE. In particular it does not clamp AWAY
    /// from the ends the way `TripProgressBar.clamped` does (0.05…0.95, so a zero
    /// draws its orb 5% along): that floor is right for an illustrated bar and
    /// wrong for a claim about a car, since `arrived` and `completed` send exactly
    /// `1` on the ride record's authority and a track that stopped at 95% would
    /// quietly contradict it.
    private static func track(for state: RideActivityAttributes.ContentState) -> Double? {
        guard let progress = state.progress else { return nil }
        return min(1, max(0, progress))
    }
}

// MARK: - The monotone hold

/// The client's half of "the track never runs backwards".
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
/// UNCHANGED BY THE v2 REDESIGN. The handoff's "Monotone clamp upstream unchanged"
/// is this.
enum RideActivityProgress {
    /// The fraction a newly-composed frame should carry.
    ///
    /// THE LEG IS THE RESET KEY, and it has to be: leg one ends at exactly `1` and
    /// leg two opens at ~`0`, so a max taken across the flip would pin the drop-off
    /// track at full for the entire ride. A leg change therefore adopts the new
    /// leg's value verbatim, INCLUDING `nil` — "telemetry never seen this leg" is
    /// an honest no-track, and holding leg one's `1` over it would draw a completed
    /// journey the car has not started.
    ///
    /// Within one leg it is `max`, and `nil` on either side simply defers to the
    /// other — which is the same carry-forward `eta` gets, for the same reason: the
    /// last fraction the car reported does not stop being the last fraction the car
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
