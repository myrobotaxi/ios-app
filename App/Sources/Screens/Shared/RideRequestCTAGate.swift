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
    var reason: FleetUnavailability? { isScheduled ? nil : unavailability }

    /// True when the instant CTA is disabled and the rider is pointed at the
    /// scheduling flow instead.
    var routesToScheduling: Bool { reason != nil }

    /// True when a submit may proceed. The view guards its `confirm()` on this
    /// as a last line of defence, so no path can POST an instant request the
    /// server would refuse with `409 vehicle_unavailable`.
    var allowsSubmit: Bool { !routesToScheduling }
}
