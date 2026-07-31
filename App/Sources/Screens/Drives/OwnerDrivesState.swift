import DesignSystem
import Foundation
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
//
// MYR-376 — ON THE LIVE PATH THE UPCOMING LIST IS THE SERVER'S NOW.
//
// It used to be a purely LOCAL array: empty at launch on live (MYR-228 — there
// was no reservation read), appended to by `addUpcoming` when the owner accepted
// a scheduled request this session, and removed from by a cancel that made no
// network call at all. Every one of the client's Drives complaints falls out of
// that one design:
//
//  • His `arrived` ride was still listed as "upcoming". A local row inserted at
//    accept time has no way to learn that the ride has since dispatched, been
//    picked up, or completed — nothing ever revisits it.
//  • His X-cancel removed the row and left the reservation standing. There was no
//    decline call to fail; the row simply disappeared, which is the most
//    convincing possible way to not cancel something.
//  • A reservation accepted on another device, or in an earlier session, never
//    appeared at all.
//
// The list is now READ from `GET /api/ride-requests/incoming?upcomingForVehicle=`
// through the production `LiveUpcomingReservations`, filtered by
// `RideReservation.isUpcomingReservation` (accepted, scheduled, NOT dispatched),
// and the X performs the real `POST /{id}/decline` and re-syncs. SIM is untouched
// — no source is composed there, so the fixture array and its local mutations are
// byte-for-byte what they were.
@Observable
@MainActor
public final class OwnerDrivesState {
    /// app.jsx `ownerUpcoming` — the fixture reservations in SIM; the server's
    /// answer on live.
    public var upcoming: [UpcomingRide]
    /// app.jsx `drivingDriveId`/`screen==='driveSummary'` — which drive (if
    /// any) is pushed on top of the list (screens.jsx `onOpenDrive`).
    public var openDriveID: String?

    /// MYR-376 — the last cancel that the SERVER refused, as one honest sentence
    /// for the screen's toast. `nil` whenever there is nothing to say.
    public var cancelFailureNotice: String?
    /// MYR-376 — a decline is in flight for this ride id, so the row's X cannot be
    /// tapped twice into two declines.
    public private(set) var cancellingID: String?
    /// True while the live list is being read for the first time on this vehicle.
    public private(set) var isLoadingUpcoming = false

    /// MYR-376 — the live reservation seam, or `nil` in SIM / static-token dev,
    /// where the fixture list stands and the local mutations are the whole story.
    @ObservationIgnored private let reservations: (any UpcomingReservationSource)?
    /// The vehicle the currently-held list was read for, so a fleet switch re-reads
    /// rather than showing another car's reservations.
    @ObservationIgnored private var loadedVehicleID: String?

    /// MYR-228 — `live` seeds an EMPTY reservation list rather than the fixtures.
    /// MYR-376 makes that emptiness temporary: with a `reservations` source the
    /// live list is filled from the server on appear instead of staying empty until
    /// the owner happens to accept something.
    init(live: Bool = false, reservations: (any UpcomingReservationSource)? = nil) {
        upcoming = live ? [] : DriveFixtures.upcomingRides
        self.reservations = reservations
    }

    /// Whether this state reads its reservations from the server. Drives the
    /// screen's choice between the honest live cancel and the prototype's local
    /// one, so the two can never both run.
    public var readsLiveReservations: Bool { reservations != nil }

    /// screens.jsx:726 `onCancelUpcoming={(id) => setOwnerUpcoming((u) => u.filter((x) => x.id !== id))}`.
    /// The SIMULATED path only — see `cancelReservation` for the live one.
    public func cancelUpcoming(id: String) {
        upcoming.removeAll { $0.id == id }
    }

    /// MYR-171 — `IncomingRequestSheet` accepting a *scheduled* ride request
    /// reserves it into Drives → Upcoming instead of dispatching now
    /// (app.jsx:135-139 `handleOwnerAccept`'s scheduled branch: `setOwnerUpcoming
    /// ((u) => [{id:'ou'+Date.now(), rider, dest, schedule, vehicle}, ...u])`).
    ///
    /// MYR-376 — on the live path this is now an OPTIMISTIC head insert followed by
    /// a real read: the accept's own row appears instantly (the prototype's timing,
    /// which the accept toast is choreographed against) and is then replaced by the
    /// server's, id and all.
    public func addUpcoming(_ ride: UpcomingRide) {
        upcoming.insert(ride, at: 0)
    }

    // MARK: MYR-376 — the live read

    /// Read this vehicle's upcoming reservations. Idempotent per vehicle unless
    /// `force` is set (the pull a cancel does afterwards).
    /// - Returns: whether the server ANSWERED (MYR-381 — the cancel path has to
    ///   tell "the reservation left the list" apart from "the list did not
    ///   answer"; from `upcoming` alone they are the same array).
    @discardableResult
    public func loadUpcoming(vehicleID: String?, force: Bool = false) async -> Bool {
        guard let reservations, let vehicleID else { return false }
        if !force, loadedVehicleID == vehicleID { return true }
        if loadedVehicleID != vehicleID { upcoming = [] }
        isLoadingUpcoming = upcoming.isEmpty
        defer { isLoadingUpcoming = false }
        guard let rows = try? await reservations.upcomingReservations(vehicleID: vehicleID) else {
            // A read that did not answer is NOT evidence that nothing is booked
            // (MYR-326's rule). Leave whatever is held and try again on the next
            // appearance rather than emptying the list.
            return false
        }
        loadedVehicleID = vehicleID
        // MYR-381 — deduped by id for the same rendering reason
        // `RiderScheduledRideMapping.rides` is: `ForEach` draws one row per id, so
        // a duplicate across a cursor page boundary would be counted and not drawn.
        var seen: Set<String> = []
        upcoming = rows.compactMap(UpcomingReservationRow.row(for:)).filter { seen.insert($0.id).inserted }
        return true
    }

    /// MYR-376 — the HONEST cancel: decline on the server FIRST, then re-read.
    ///
    /// Never an optimistic removal. The server refuses a decline once the ride has
    /// left the declinable set — which for the client meant the row vanished from a
    /// list while the reservation it named carried on existing, the single most
    /// dangerous shape a failed write can take. A refusal keeps the row exactly
    /// where it is and says so.
    ///
    /// MYR-381 — and the refusal is now CLASSIFIED, RECONCILED and RECORDED
    /// (`ReservationCancel.swift`). The re-read this method already performed is
    /// what decides whether a refusal is worth a toast at all: a `409` on a
    /// reservation that has since dispatched or been ended elsewhere comes back
    /// with the row GONE, and a list that agrees with the tap is not a failure to
    /// announce.
    public func cancelReservation(id: String, vehicleID: String?) async {
        guard let reservations else { return }
        cancellingID = id
        defer { cancellingID = nil }
        var failure: ReservationCancelFailure?
        do {
            try await reservations.decline(reservationID: id)
        } catch {
            failure = ReservationCancelFailure.classify(error)
            ReservationCancelLog.record(failure!, action: "decline", rideID: id)
        }
        // Re-read either way: a `409` usually means the ride has moved on, and the
        // list saying so is more use than the list pretending otherwise.
        let answered = await loadUpcoming(vehicleID: vehicleID, force: true)
        let stillHeld = !answered || upcoming.contains { $0.id == id }
        switch ReservationCancelOutcome.resolve(failure: failure, stillHeld: stillHeld, copy: .owner) {
        case .cancelled: cancelFailureNotice = nil
        case .refused(let notice): cancelFailureNotice = notice
        }
    }

    /// MYR-376's original sentence. MYR-381 replaced its two USES with the
    /// classified pair in `ReservationCancelCopy.owner`; it survives as the name a
    /// caller with nothing more specific to say can still reach for.
    public static let cancelFailureMessage = "Couldn\u{2019}t cancel that reservation"
}

// MARK: - Reservation → Upcoming row (MYR-376)

/// The ONE wire→row rule for Drives → Upcoming.
///
/// Pure and static so it can be asserted directly: every string on the row is
/// either the server's (the destination, the day/time, the rider's resolved first
/// name) or the client's own trip estimate, and nothing is a fixture — a live
/// Drives list rendering "Mira · SFO · Terminal 2" would be MYR-228's exact
/// failure mode on a surface the owner acts from.
public enum UpcomingReservationRow {
    /// `nil` for a reservation carrying no mapped record. Unreachable from the live
    /// read (`LiveUpcomingReservations` always attaches one), and refusing rather
    /// than substituting is the honest answer: a row with no destination and no
    /// time is not a reservation the owner can act on.
    static func row(for reservation: UpcomingReservation) -> UpcomingRide? {
        guard let record = reservation.record else { return nil }
        let destination = record.input.destination
        return UpcomingRide(
            // The SERVER's ride id, because it is what the X declines. The local
            // accept-time row used `"ou-" + id`; a decline against that string is a
            // 404 with a plausible-looking prefix.
            id: reservation.id,
            // The SAME name rule the pause dialog states this reservation with, so
            // one ride cannot be "Thomas" on one owner surface and "A rider" on the
            // other.
            rider: RideSharePauseDialog.rowRider(for: reservation),
            destination: .init(
                label: destination.label,
                subtitle: destination.subtitle ?? "",
                miles: destination.miles,
                mins: destination.minutes
            ),
            scheduleDay: record.input.schedule?.day ?? "",
            scheduleTime: record.input.schedule?.time ?? "",
            // The car is named by the screen, which is already scoped to ONE
            // vehicle and holds its real name; this mapping sees a wire row and a
            // vehicle id, and inventing a name from an id is how a fixture leaks.
            vehicleName: "",
            scheduledFor: reservation.scheduledFor
        )
    }
}
