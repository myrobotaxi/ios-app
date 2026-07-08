import DesignSystem
import Observation

// MARK: - Owner drives state (MYR-169)
//
// Mirrors `OwnerHomeState`'s reasoning (see that file's header comment):
// app.jsx keeps `ownerUpcoming` and the open-drive-summary navigation as
// App-level state (aS('...') at the top of `App()`), not local to
// `DrivesScreen` — so a cancelled reservation stays cancelled, and (unlike a
// screen-local `@State`) doesn't get re-seeded from the fixture array if the
// owner taps away to another tab and back. Lifted above the owner tab switch
// in `RootView` for the same reason `OwnerHomeState` is.
@Observable
@MainActor
public final class OwnerDrivesState {
    /// app.jsx `ownerUpcoming` — mutated by "Cancel reservation" (screens.jsx:726).
    public var upcoming: [UpcomingRide]
    /// app.jsx `drivingDriveId`/`screen==='driveSummary'` — which drive (if
    /// any) is pushed on top of the list (screens.jsx `onOpenDrive`).
    public var openDriveID: String?

    public init() {
        upcoming = DriveFixtures.upcomingRides
    }

    /// screens.jsx:726 `onCancelUpcoming={(id) => setOwnerUpcoming((u) => u.filter((x) => x.id !== id))}`.
    public func cancelUpcoming(id: String) {
        upcoming.removeAll { $0.id == id }
    }

    /// MYR-171 — `IncomingRequestSheet` accepting a *scheduled* ride request
    /// reserves it into Drives → Upcoming instead of dispatching now
    /// (app.jsx:135-139 `handleOwnerAccept`'s scheduled branch: `setOwnerUpcoming
    /// ((u) => [{id:'ou'+Date.now(), rider, dest, schedule, vehicle}, ...u])`).
    public func addUpcoming(_ ride: UpcomingRide) {
        upcoming.insert(ride, at: 0)
    }
}
