import CoreLocation
import Foundation
import MyRoboTaxiKit
import MyRobotaxiContracts
import Observation

// MARK: - The rider's Scheduled tab, for real (MYR-377)
//
// THE DEFECT. The client booked a ride for the next day and the owner (himself)
// accepted it. Ride History → Scheduled read **"0 scheduled · 0 confirmed"** over
// "No scheduled rides", while the reservation sat in `go_ride_requests`, accepted,
// with a pickup time. It was not a data problem: `RideHistoryScreen`'s live branch
// was the literal `[]`, under a comment saying there was no scheduled-ride
// backend. There has been one since MYR-174 — `GET /api/ride-requests` returns
// the authenticated rider's own rows, `scheduledFor` and all — and the comment
// simply outlived the gap it described.
//
// WHAT LIVES HERE. The wire→row mapping (pure, so the timezone rule is asserted
// rather than eyeballed) and the small store the screen reads. The store does
// three things and no more: read the list, cancel one row for real, and say so
// when the server refuses.
//
// NOT A MYR-228 CONCERN IN EITHER DIRECTION. These rows are the rider's own data,
// so nothing here is a fixture — and the SIM path never composes this at all, so
// `RideHistoryFixtures.scheduledRides` still stands behind every simulated and
// DEBUG capture, pixel for pixel.

/// The seam the Scheduled tab reads and cancels through.
///
/// Narrow for the same reason `UpcomingReservationSource` is: one read and one
/// write, implementable in a handful of lines by a test, and carrying none of
/// `RideRequestService`'s two role-scoped pipelines (MYR-325), which have nothing
/// to do with a list of reservations nobody is riding yet.
protocol RiderScheduledRideSource: Sendable {
    /// The rider's own SCHEDULED rides that are still open — `requested` (nobody
    /// has answered) or `accepted` (confirmed, dormant until dispatch) — soonest
    /// first.
    func scheduledRides(now: Date) async throws -> [ScheduledRide]
    /// `POST /api/ride-requests/{id}/cancel` — the rider withdrawing their own
    /// reservation.
    func cancel(rideID: String) async throws
}

/// The live implementation: `GET /api/ride-requests`, mapped by the SHIPPING
/// contract mapping.
struct LiveRiderScheduledRides: RiderScheduledRideSource {
    let api: any RideRequestAPI
    /// How the car is NAMED on a row. The rider's own fleet list, joined on
    /// `vehicleId` — the same join the owner's incoming card does, and the reason a
    /// live row can carry a real car without inventing one.
    let vehicleNames: @MainActor @Sendable (String) -> RiderScheduledRideVehicle?

    static let pageLimit = 20
    /// Bounded for the same reason `LiveUpcomingReservations.maxPages` is: an
    /// unbounded client loop over a server-supplied cursor is a hang waiting for a
    /// server bug, and a rider with 100 open reservations does not exist.
    static let maxPages = 3

    func scheduledRides(now: Date) async throws -> [ScheduledRide] {
        var wire: [MyRobotaxiContracts.RideRequest] = []
        var cursor: String?
        for _ in 0..<Self.maxPages {
            let page = try await api.rideRequests(cursor: cursor, limit: Self.pageLimit)
            wire.append(contentsOf: page.items)
            guard page.hasMore, let next = page.nextCursor, !next.isEmpty else { break }
            cursor = next
        }
        let names = await MainActor.run { [vehicleNames] in
            Dictionary(uniqueKeysWithValues: Set(wire.map(\.vehicleId)).compactMap { id in
                vehicleNames(id).map { (id, $0) }
            })
        }
        return RiderScheduledRideMapping.rides(from: wire, vehicles: names, now: now)
    }

    func cancel(rideID: String) async throws {
        _ = try await api.cancelRideRequest(id: rideID)
    }
}

/// What the client knows about the car a reservation is against. Both fields are
/// the rider's own fleet row, never a persona.
struct RiderScheduledRideVehicle: Equatable, Sendable {
    /// The car's own nickname — "Lunar". What every other live rider surface
    /// titles on ("Request from Lunar"), so the Scheduled row agrees with the
    /// booking flow that produced it.
    let name: String
    /// "Your Tesla" / the share relationship. Displayed as-is.
    let relationship: String
}

// MARK: - Wire → ScheduledRide

enum RiderScheduledRideMapping {

    /// Every OPEN reservation on the page, soonest first.
    ///
    /// STRICTLY FUTURE is deliberately NOT the filter. A reservation whose moment
    /// has passed but which has not dispatched is exactly the state a rider most
    /// needs to see — it is the 30-minute window in which the server will expire it
    /// — and hiding it would reproduce MYR-360's defect from the rider's side.
    ///
    /// MYR-381 — DEDUPED BY ID, and that is a rendering guarantee rather than
    /// tidiness. `ForEach` over an `Identifiable` collection renders ONE view per
    /// id, so a list carrying the same ride twice — which a cursor page boundary
    /// can produce (`LiveRiderScheduledRides` follows up to three pages and a row
    /// created between two reads shifts the window) — draws fewer rows than it
    /// counts, and the screen's "N scheduled · M confirmed" header, which counts
    /// the array, then states a number the rider cannot see. Deduping HERE is what
    /// makes the header derive from the rendered rows structurally: there is one
    /// array, and every id in it renders.
    static func rides(
        from wire: [MyRobotaxiContracts.RideRequest],
        vehicles: [String: RiderScheduledRideVehicle],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ScheduledRide] {
        var seen: Set<String> = []
        return wire
            .compactMap { ride(from: $0, vehicle: vehicles[$0.vehicleId], now: now, calendar: calendar) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.scheduledFor ?? .distantFuture < $1.scheduledFor ?? .distantFuture }
    }

    /// ONE wire row → ONE Scheduled row, or `nil` when it does not belong on this
    /// tab at all.
    ///
    /// Refused, in order:
    ///  • anything with no `scheduledFor` — an instant ride is not a reservation;
    ///  • anything past `accepted` (`arrived`/`enroute`/`completed`) — the ride is
    ///    happening or has happened, and belongs to the tracking sheet and the
    ///    Completed tab respectively. This is `RideReservation`'s dormancy model
    ///    read from the rider's side: the Scheduled tab is the DORMANT list;
    ///  • `declined`/`cancelled`, which the contract mapping already refuses.
    ///
    /// A DISPATCHED-but-still-`accepted` reservation is also refused: it is a live
    /// ride now, the rider's map is tracking it, and a duplicate of it sitting in a
    /// list of things that have not happened yet is precisely the "0 scheduled"
    /// defect's mirror image.
    static func ride(
        from wire: MyRobotaxiContracts.RideRequest,
        vehicle: RiderScheduledRideVehicle?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledRide? {
        guard let scheduledFor = wire.scheduledFor.flatMap(RideRequestContractMapping.parseISO),
              let record = RideRequestContractMapping.record(from: wire),
              RideReservation.isDormant(record)
        else { return nil }
        return row(for: record, scheduledFor: scheduledFor, vehicle: vehicle, now: now, calendar: calendar)
    }

    /// MYR-378 — the COMPOSITION, split from the rider's dormancy GUARD above so
    /// the owner's Drives → Upcoming can build the identical row.
    ///
    /// The guard and the composition were one function, and they answer different
    /// questions: "does this belong on the rider's Scheduled tab" (dormant, still
    /// open, not dispatched) versus "what does this reservation look like". The
    /// owner's list has already applied its OWN predicate
    /// (`RideReservation.isUpcomingReservation`) by the time it gets here, and
    /// running the rider's on top of it would be a second, differently-worded
    /// filter on a row that is already in a list — the shape by which two surfaces
    /// come to disagree about one ride.
    ///
    /// Everything a reservation SAYS is decided here, once, so the two roles cannot
    /// print a different pickup, distance, day or time for the same ride.
    static func row(
        for record: RideRequestRecord,
        scheduledFor: Date,
        vehicle: RiderScheduledRideVehicle?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ScheduledRide {
        // The DAY and TIME are rendered in the READER's calendar, from a UTC
        // instant. `scheduledFor` travels the wire as RFC 3339 UTC and is written
        // by whichever device booked it; printing it in anything but the rider's
        // own zone would put a different clock on the row than the one on the chip
        // they tapped.
        let day = RideScheduleDays.label(for: scheduledFor, now: now, calendar: calendar)
        let time = RideScheduleDays.timeLabel(for: scheduledFor, calendar: calendar)

        return ScheduledRide(
            id: record.id,
            day: day,
            // The sheet's secondary date line. `day` already carries the date for
            // everything past tomorrow, so this is only ever ADDING information for
            // "Today"/"Tomorrow" — which is exactly the case the prototype's own
            // `SCHED_DATES` table existed to cover.
            date: RideScheduleDays.shortDate(for: scheduledFor, calendar: calendar),
            time: time,
            from: record.input.pickup.label,
            to: record.input.destination.label,
            // NO DRIVER NAME. The wire carries the RIDER's display name
            // (`requesterName`) and nothing about the owner; §7.0 catalog rows
            // carry no owner name either (see CLAUDE.md's "{Owner}'s {Vehicle}"
            // note). An empty string is the honest input and `ScheduledRideDisplay`
            // renders the car alone for it — inventing "Alex" here would be MYR-184's
            // `InviteHostFixture` leak on a new surface.
            driver: "",
            relationship: vehicle?.relationship ?? "",
            vehicle: vehicle?.name ?? "",
            miles: record.input.destination.miles,
            // `requested` → the prototype's "Pending"; `accepted` → "Confirmed".
            // Exactly the two words shared-screens.jsx:16 defines, now meaning what
            // they say.
            status: record.status == .accepted ? .confirmed : .pending,
            passenger: record.input.passenger,
            // The two ENDPOINTS, not a route. `RideRouteMap` draws a line only for a
            // real (>2 point) polyline — MYR-293's `RideRoutePolyline.isReal` — so
            // the sheet's preview shows the two pins and no fabricated straight
            // line between them.
            route: [record.input.pickup.coordinate, record.input.destination.coordinate],
            scheduledFor: scheduledFor
        )
    }
}

// MARK: - Rendering a row whose owner has no name (MYR-377)

/// The two strings the Scheduled row and its sheet print about the CAR.
///
/// The prototype's fixture rides are titled "{driver}'s {vehicle}" — "Mom's Model
/// Y" — because its `SCHEDULED_RIDES` carry a person. A live reservation carries
/// no owner name anywhere: not on the ride (`requesterName` is the RIDER), not on
/// the §7.0 vehicle row, not in telemetry. MYR-184's lesson is that the tempting
/// answer here — reach for a fixture persona, or synthesise one from the nickname
/// — is the leak with no grep signature, and CLAUDE.md's "{Owner}'s {Vehicle}"
/// note records what happens when a nickname is treated as a person: "Alex's
/// Alex's Model 3", shipped and photographed.
///
/// So the driver is honestly EMPTY on a live row and these two functions render
/// the car alone for that case. Every fixture row has a driver, so every simulated
/// and DEBUG capture is byte-identical.
enum ScheduledRideDisplay {
    /// "Mom's Model Y" — or just "Lunar" when nobody is named.
    ///
    /// MYR-382 — composed by `SharedVehicleTitle.compose`, the app's ONE
    /// owner-possessive rule, rather than a second `\(name)'s \(thing)` of its own.
    /// TestFlight r14 found the cost of having two: the cancel dialog spelled its
    /// own and rendered **"with 's Lunar"** for a reservation whose owner has no
    /// name (which, per MYR-377, is EVERY live reservation — the wire carries no
    /// owner name anywhere). Absence must drop the possessive whole, never leave
    /// the apostrophe behind, and now exactly one function decides that. The
    /// non-empty result is byte-identical, so every fixture row renders as before.
    static func vehicleTitle(_ ride: ScheduledRide) -> String {
        SharedVehicleTitle.compose(owner: ride.driver, vehicle: ride.vehicle)
    }

    /// "with Mom's Model Y" / "with Lunar" — the fragment the cancel dialog's
    /// sentence embeds. Named here so the sentence cannot re-spell the possessive.
    static func withVehiclePhrase(_ ride: ScheduledRide) -> String {
        "with \(vehicleTitle(ride))"
    }

    /// "Mom will be asked to re-confirm the new time." — or the ownerless form.
    static func rescheduleNote(_ ride: ScheduledRide) -> String {
        guard !ride.driver.isEmpty else { return "The owner will be asked to re-confirm the new time." }
        return "\(ride.driver) will be asked to re-confirm the new time."
    }

    /// "Waiting for Mom to confirm the new pickup time."
    static func awaitingConfirmationNote(_ ride: ScheduledRide) -> String {
        guard !ride.driver.isEmpty else { return "Waiting for the owner to confirm the new pickup time." }
        return "Waiting for \(ride.driver) to confirm the new pickup time."
    }

    /// The reschedule-requested footer, with or without a passenger.
    static func rescheduleFooterNote(_ ride: ScheduledRide) -> String {
        let responder = ride.driver.isEmpty ? "the owner" : ride.driver
        if let passenger = ride.passenger {
            return "You and \(passenger.firstName) get the updated time once \(responder) responds."
        }
        return "You\u{2019}ll be notified once \(responder) responds."
    }

    /// The avatar glyph. A named owner keeps the prototype's initial; a nameless
    /// one gets a car, which says the same thing without claiming a person.
    static func avatarInitial(_ ride: ScheduledRide) -> String? {
        ride.driver.isEmpty ? nil : String(ride.driver.prefix(1))
    }

    /// "Family · Shared with you" — or the relationship alone when there is no
    /// person for "shared with you" to be about.
    static func relationshipLine(_ ride: ScheduledRide) -> String {
        guard !ride.driver.isEmpty else { return ride.relationship }
        return "\(ride.relationship) \u{00B7} Shared with you"
    }

    /// The sheet's footnote under the Cancel/Reschedule pair.
    static func changeNote(_ ride: ScheduledRide) -> String {
        guard !ride.driver.isEmpty else { return "Changes notify the owner to re-confirm." }
        return "Changes notify \(ride.driver) to re-confirm."
    }

    /// MYR-377 — may the sheet's map preview draw a LINE between the two pins?
    ///
    /// "No straight lines ever" (MYR-237 / MYR-293) is a rule about the LIVE path:
    /// a two-point segment across a city, drawn in the route's own gold, is a
    /// fabricated road. A wire-built reservation carries exactly that — its pickup
    /// and its destination and no geometry between them — so it draws pins only.
    ///
    /// The PROTOTYPE's own fixture rides are the other case, and they keep their
    /// line. `shared-screens.jsx`'s scheduled sheet draws an illustrated route, the
    /// drift gate compares this sheet against it, and a fixture rendering in the
    /// simulator is an illustration by definition (MYR-228) rather than a claim
    /// about a road. `scheduledFor` is the discriminator because it is the one
    /// field only a wire row has — and it is a FACT about provenance rather than a
    /// flag someone has to remember to set.
    static func drawsRouteLine(_ ride: ScheduledRide) -> Bool {
        if RideRoutePolyline.isReal(ride.route) { return true }
        return ride.scheduledFor == nil
    }
}

// MARK: - The store the screen reads

/// The Scheduled tab's live state. `nil` source ⇒ the screen keeps its fixtures
/// and this is never constructed.
@Observable
@MainActor
final class RiderScheduledRidesStore {
    private(set) var rides: [ScheduledRide] = []
    /// True only while the FIRST read for this session is in flight, so a refresh
    /// behind an already-populated list does not blank it.
    private(set) var isLoading = false
    /// The last server refusal, as one honest sentence for the screen's toast.
    var failureNotice: String?
    private(set) var cancellingID: String?

    @ObservationIgnored private let source: any RiderScheduledRideSource

    init(source: any RiderScheduledRideSource) {
        self.source = source
    }

    /// - Returns: whether the server ANSWERED. MYR-381 — the cancel path needs to
    ///   tell "the ride is gone from the list" apart from "the list did not
    ///   answer", and those are the same `rides` array from the outside.
    @discardableResult
    func load() async -> Bool {
        isLoading = rides.isEmpty
        defer { isLoading = false }
        // A read that did not answer is NOT "you have no reservations" (MYR-326):
        // hold whatever is on screen and let the next appearance ask again.
        guard let rows = try? await source.scheduledRides(now: Date()) else { return false }
        rides = rows
        return true
    }

    /// Cancel for real, then re-read. Never an optimistic removal — the whole
    /// lesson of the owner's silent X (MYR-376) applies identically here, and a
    /// rider who believes a ride is cancelled when it is not will simply not be
    /// there when the car arrives.
    ///
    /// MYR-381 — the failure is CLASSIFIED, RECONCILED and RECORDED rather than
    /// collapsed into one sentence (see `ReservationCancel.swift`'s header): the
    /// re-read decides whether a refusal is worth saying out loud, and the reason
    /// the server gave goes to os_log either way.
    func cancel(id: String) async {
        cancellingID = id
        defer { cancellingID = nil }
        var failure: ReservationCancelFailure?
        do {
            try await source.cancel(rideID: id)
        } catch {
            failure = ReservationCancelFailure.classify(error)
            ReservationCancelLog.record(failure!, action: "cancel", rideID: id)
        }
        let reread = await load()
        // A read that did not answer holds whatever was on screen, so the row is
        // still "held" — never report a cancel we could not confirm.
        let stillHeld = !reread || rides.contains { $0.id == id }
        switch ReservationCancelOutcome.resolve(failure: failure, stillHeld: stillHeld, copy: .rider) {
        case .cancelled: failureNotice = nil
        case .refused(let notice): failureNotice = notice
        }
    }

    /// MYR-377's original sentence, kept as the name every existing consumer
    /// reads. MYR-381 replaced its two USES with the classified pair above; it
    /// survives as the generic fallback a future caller with nothing more specific
    /// to say can still reach for.
    static let cancelFailureMessage = "Couldn\u{2019}t cancel that ride"
}
