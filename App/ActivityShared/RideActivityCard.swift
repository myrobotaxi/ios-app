import Foundation
import MyRobotaxiContracts

// MARK: - What the Live Activity card SAYS and DRAWS (MYR-398)
//
// PURE, and for the same reason `RideActivityStateMachine` is: the presentations
// themselves cannot be instantiated in a unit test (an `ActivityViewContext` needs
// a real Activity in a real host process), so everything worth asserting about
// WHICH headline, WHICH second line and WHETHER there is a track lives here as a
// function of (content state, static attributes, staleness). The SwiftUI in
// `Widgets/Sources/RideActivityPresentation.swift` reads this and lays it out; it
// makes no decisions of its own.
//
// It is compiled into BOTH targets (`App/ActivityShared`), so the app's test bundle
// can reach it even though the widget process is the only thing that renders it.
//
// ─────────────────────────────────────────────────────────────────────────────
// THE HONESTY RULES THIS TYPE EXISTS TO KEEP (rest-api.md §7.21.3)
//
//   1. `progress` ABSENT → NO TRACK. Not an empty rail, not a track at zero. `0`
//      is the claim "the car has covered none of the distance"; absence is the
//      admission "we cannot say". The card composes cleanly without one, which is
//      the only reason the server is free to omit it.
//   2. `eta` ABSENT → NO COUNTDOWN. The headline degrades to a status sentence.
//      The client NEVER computes an ETA — the contract's ETA is the CAR'S OWN
//      carried navigation ETA and nothing on the phone is that.
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

/// The card's top line.
enum RideActivityHeadline: Equatable {
    /// "Pick up in" / "Arriving in" followed by a LIVE countdown to `until`.
    ///
    /// The instant travels rather than a rendered number, because the whole reason
    /// §7.21.3 sends an absolute `eta` is that the phone counts down between the
    /// 60–90s pushes. The view spends it on `Text(timerInterval:)`.
    case countdown(prefix: String, until: Date)

    /// A sentence with no number in it. Every arm the contract leaves without an
    /// `eta`, plus every terminal state, plus staleness.
    case sentence(String)
}

/// The whole card, resolved.
struct RideActivityCard: Equatable {

    /// MYR-172's trip line, carried forward unchanged: the vehicle, a muted arrow
    /// and the DESTINATION in gold (surfaces.jsx:268-270).
    struct TripLine: Equatable {
        var vehicle: String
        var destination: String
    }

    /// The status the card is describing, carried so the chip word and the compact
    /// island's fallback text come off the SAME resolution the headline did. Two
    /// slots re-reading the content state independently is two slots that can name
    /// two different situations on one card.
    var status: LiveActivityRideStatus

    var leg: RideActivityLeg?
    var headline: RideActivityHeadline

    /// "Meet at {pickup}" — LEG ONE ONLY, and only when the ride carries a label.
    ///
    /// It comes off the Activity's STATIC attributes, never off a push: §7.21.3's
    /// "Why the 'Meet at {pickup}' line is NOT on the wire" is explicit that a
    /// pickup cannot change for the life of a ride and that the app already holds
    /// it. A client that waited for the server to send it would render no meet-at
    /// line at all, forever, against a server that is behaving correctly.
    var meetAt: String?

    /// The leg-two second line. `nil` on leg one (the meet-at line has the slot)
    /// and on every terminal state, where MYR-172's own reasoning stands:
    /// "Cancelled" over "Blue Whale → Home" reads as a ride still in progress.
    var trip: TripLine?

    /// The fraction the track draws, or `nil` for NO TRACK AT ALL.
    var track: Double?

    /// ActivityKit's own staleness verdict, passed through so the view can replace
    /// the countdown with what it actually knows (MYR-194: "never a confident stale
    /// ETA").
    var isStale: Bool

    /// The instant the stale notice dates itself from — the last thing the server
    /// actually told us, which is the ETA when there was one. `nil` leaves the
    /// notice claiming nothing rather than inventing a duration.
    var staleReference: Date?

    /// Resolve the card from everything the widget process is handed.
    ///
    /// `pickupLabel` is the STATIC attribute; `state` is the pushed content state;
    /// `isStale` is `ActivityViewContext.isStale`.
    static func resolve(
        state: RideActivityAttributes.ContentState,
        pickupLabel: String?,
        isStale: Bool
    ) -> RideActivityCard {
        let leg = RideActivityLeg.of(state.status)
        let car = RideActivityCopy.vehicleDisplayName(state.vehicleName)
        let destination = state.destination.trimmingCharacters(in: .whitespacesAndNewlines)

        return RideActivityCard(
            status: state.status,
            leg: leg,
            headline: headline(state: state, leg: leg, isStale: isStale),
            meetAt: leg == .pickup ? RideActivityCopy.meetAt(pickupLabel) : nil,
            trip: leg == .dropoff && !destination.isEmpty
                && RideActivityCopy.showsCountdown(for: state.status)
                ? TripLine(vehicle: car, destination: destination)
                : nil,
            track: track(for: state),
            isStale: isStale,
            staleReference: state.etaDate
        )
    }

    // MARK: - Headline

    private static func headline(
        state: RideActivityAttributes.ContentState,
        leg: RideActivityLeg?,
        isStale: Bool
    ) -> RideActivityHeadline {
        let sentence = RideActivityHeadline.sentence(
            RideActivityCopy.statusHeadline(
                for: state.status,
                vehicleName: state.vehicleName,
                destination: state.destination
            )
        )

        // A terminal ride has no future arrival, so a stale `eta` still sitting in
        // the content state must not be counted down (MYR-194's rule applied to the
        // STATE rather than to the clock).
        guard RideActivityCopy.showsCountdown(for: state.status) else { return sentence }

        // STALE OUTRANKS THE ETA. A greyed-out "4:12" is still a number a rider
        // reads as the answer, and the point of staleness is that we no longer have
        // one. The view puts the "as of" notice where the countdown was.
        guard !isStale else { return sentence }

        // NO ETA, NO COUNTDOWN — and no locally computed stand-in. `eta` is
        // optional on the wire TODAY (a car with no active nav route yields no key
        // at all, and there is no server-side route solver), so this arm is an
        // ordinary state rather than an error, and it is what makes a future
        // server-side ETA freshness gate (MYR-401) shippable without a client
        // release: omitting the key will land on a card that already knows what to
        // say.
        guard let eta = state.etaDate, let leg else { return sentence }

        return .countdown(prefix: RideActivityCopy.headlinePrefix(for: leg), until: eta)
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
