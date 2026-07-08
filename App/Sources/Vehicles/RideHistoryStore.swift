import Observation

// MARK: - Ride history store (MYR-171)
//
// `RideHistoryScreen` (MYR-191) originally read `RideHistoryFixtures
// .requestedRides` directly — a static, immutable array. MYR-171's Ride
// Summary needs to append a newly-completed ride to that list at the moment
// the rider taps "See you soon" (`RideRequestService.completeAndReset()`),
// and the ride can finish while the rider isn't even looking at Ride History
// (they're on Live Map watching the trip). That needs the same
// lifted-above-tab-switch treatment `SharedViewerState`/`OwnerHomeState`
// already use (see their header comments) rather than `RideHistoryScreen`'s
// own screen-local `@State` — reschedule/cancel on a *scheduled* ride stay
// screen-local by design (that file's header comment), but a newly *completed*
// ride is a different, app-level concern.
@Observable
@MainActor
public final class RideHistoryStore {
    public var completedRides: [RequestedRide]

    public init(seed: [RequestedRide] = RideHistoryFixtures.requestedRides) {
        completedRides = seed
    }

    /// Prepends a freshly-completed ride — newest first, matching
    /// `RideHistoryScreen`'s day-grouped display order (`"Today"` always
    /// sorts to the top since it's the first group encountered).
    public func record(_ ride: RequestedRide) {
        completedRides.insert(ride, at: 0)
    }
}
