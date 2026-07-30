// MARK: - RideRequestCTAGate (MYR-233 acceptance criterion 2)
//
// The rider Review CTA's gate, extracted as a PURE value so the decision is
// unit-testable without mounting SwiftUI (the same reasoning
// `RideRequestSearchContent.scrollRegionHeight` was extracted for).
//
// The rule, in one place:
//
//  • The vehicle can't take an INSTANT request (`FleetUnavailability` non-nil)
//    → the gold outline-draw "Request from …" CTA is REPLACED by a muted one
//    that routes to the scheduling flow. Not a dimmed dead button: a dead-end
//    is exactly what criterion 2 forbids.
//  • The draft ALREADY carries a schedule → nothing is gated. Scheduled rides
//    are explicitly EXEMPT from the busy rule (contracts `hasActiveRide`: "a
//    request with scheduledFor set … is outside the index and outside this flag
//    no matter its status"), and an in_service / offline car may well be back
//    by the requested time. Gating it would refuse a request the server accepts.
//  • Everything else is untouched, so the fixture / simulated flow — where
//    `unavailability` is always nil — is pixel-identical.
struct RideRequestCTAGate: Equatable {
    /// Why the vehicle can't take an instant request, or `nil` when it can.
    let unavailability: FleetUnavailability?
    /// Whether the draft is a SCHEDULED request (exempt — see above).
    let isScheduled: Bool

    init(unavailability: FleetUnavailability?, isScheduled: Bool) {
        self.unavailability = unavailability
        self.isScheduled = isScheduled
    }

    /// The gating reason actually in force for this draft — `nil` when the
    /// normal CTA shows (available vehicle, or an exempt scheduled request).
    ///
    /// MYR-342 — the scheduled exemption is now PER REASON rather than blanket.
    /// It still applies to `busy` / `inService` / `offline`, on the contract's own
    /// guidance that a reservation sits outside the availability index. It does NOT
    /// apply to an owner's `paused`, because rest-api.md §7.18 says so in as many
    /// words — "the pause does NOT inherit that exemption, on any layer" — and
    /// explains why: MYR-313's argument is that a service visit ENDS, so refusing a
    /// reservation days out would strand the owner over a condition that will have
    /// cleared. A pause is open-ended, so exempting reservations would let a rider
    /// book a car withdrawn indefinitely.
    var reason: FleetUnavailability? {
        guard let unavailability else { return nil }
        if isScheduled, unavailability.exemptWhenScheduled { return nil }
        return unavailability
    }

    /// True when the instant CTA is gated for ANY reason — the rider cannot submit
    /// from here as things stand. The view uses this to tell "show the helper line
    /// alone" from "show the normal CTA", independently of whether a scheduling
    /// route exists.
    var isGated: Bool { reason != nil }

    /// True when the gated CTA is REPLACED by a muted button routing to the
    /// scheduling flow.
    ///
    /// MYR-233's rule — never a dead end — survives for every reason that ends on
    /// its own. MYR-342 carves out the one that does not: for a paused car the
    /// server refuses scheduled rides too, on all three enforcement layers, so the
    /// CTA area shows the helper text ALONE. That is a deliberate deviation, and
    /// the honest one: a scheduling button here would not be an escape from the
    /// dead end, it would be a longer walk to the same `409` — after the rider had
    /// picked a day, a time and a passenger.
    var routesToScheduling: Bool { reason?.offersScheduling == true }

    /// True when a submit may proceed. The view guards its `confirm()` on this
    /// as a last line of defence, so no path can POST an instant request the
    /// server would refuse with `409 vehicle_unavailable`.
    ///
    /// MYR-342 — derived from `isGated`, NOT from `routesToScheduling`. Those were
    /// the same predicate until a reason existed that gates without offering
    /// scheduling; leaving them tied would have let a paused car through the last
    /// line of defence the moment the scheduling route was removed.
    var allowsSubmit: Bool { !isGated }
}
