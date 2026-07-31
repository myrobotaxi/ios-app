import Foundation
import MyRoboTaxiKit
import Observation
import os

// MARK: - RideBookedWindowsStore (MYR-385)
//
// The fetch half of the schedule picker's conflict awareness. The pure rules live
// in `RideBookedWindows.swift`; this is the seam, the cache and the fail-open
// policy.
//
// **THE POLICY IS THE FEATURE, so it is written down before the code.**
//
//  • **LIVE PATH ONLY, BY CONSTRUCTION.** The provider is `nil` on the simulated
//    path — `PlaceSearchComposition.Seams.simulated` has nothing to put there —
//    so a simulated picker does not "skip" the fetch, it has no way to make one.
//    That is what keeps every drift-gate capture byte-identical: SIM has no
//    bookings, and inventing fixture windows for it would be a MYR-228 leak with
//    the added indignity of being a leak about somebody's calendar.
//  • **FAIL OPEN, ALWAYS.** A failed or slow read leaves `windows` empty, which
//    dims nothing, which is precisely how the picker behaved before this issue.
//    There is deliberately **no `isLoading`, no error state and no retry** on this
//    type: a spinner over a picker would gate the flow on an ADVISORY read, and
//    the create-time `409 time_conflict` is the authority that makes degrading
//    safe. An honest empty state (MYR-326's rule) is not wanted here either —
//    "we could not check" is not a thing the rider can act on, and the server
//    still refuses the collision.
//  • **THE CACHE IS KEYED BY VEHICLE, and reading it requires naming the vehicle.**
//    `windows(for:)` answers `[]` for any id but the one covered, so windows
//    fetched for the car the draft used to point at can never dim the picker for
//    the car it points at now. A bare `windows` property would make that leak
//    available at every call site and visible at none — the MYR-184 "fixture
//    default with no grep signature" shape, pointed at a different kind of stale.
//  • **TWO ENTRY POINTS, and the difference is deliberate.** `refresh` is
//    unconditional and is what the picker OPENING calls: a window can vanish or
//    appear between two openings, and the active-instant arm slides with the
//    clock, so re-asking is the whole point. `ensureCovered` fetches only when the
//    requested range falls outside what is already held, and is what a DAY-CHIP
//    change calls — the seven-day range fetched on open already covers every chip,
//    so in practice it is a no-op, and it exists so a picker whose horizon later
//    grows past one request keeps working without a second policy.

/// "Which windows is this vehicle spoken for in?", narrowed to one method so the
/// store can be driven by a stub with no network — the same seam style as
/// `RidePinLabeling` / `PlaceSearching`.
///
/// Returns the app's parsed ``RideBookedWindow`` rather than the wire envelope, so
/// the §7.22 instants are parsed in exactly one place
/// (`RideBookedWindowMapping`) whichever provider answered.
protocol RideBookedWindowsProviding: Sendable {
    func windows(vehicleID: String, from: Date, to: Date) async throws -> [RideBookedWindow]
}

/// The production provider: `GET /api/vehicles/{id}/booked-windows` through the
/// Kit, folded by the shipping mapping.
///
/// Holds the ENDPOINT protocol rather than a concrete `RestClient` so a DEBUG
/// capture scene can inject a wire stub and still run this exact code — the
/// "real code path, injected wire" precedent of `DebugServiceWindowEndpoint` /
/// `DebugShareEndpoint`.
struct LiveRideBookedWindows: RideBookedWindowsProviding {
    let endpoint: any VehicleBookedWindowsEndpoint

    func windows(vehicleID: String, from: Date, to: Date) async throws -> [RideBookedWindow] {
        RideBookedWindowMapping.windows(
            from: try await endpoint.bookedWindows(vehicleID: vehicleID, from: from, to: to)
        )
    }
}

/// What one held response covers. A read that names a different vehicle, or a
/// range reaching outside this one, is not covered by it.
struct RideBookedWindowsCoverage: Equatable, Sendable {
    let vehicleID: String
    let from: Date
    let to: Date

    func covers(vehicleID: String, from: Date, to: Date) -> Bool {
        self.vehicleID == vehicleID && self.from <= from && self.to >= to
    }
}

@Observable
@MainActor
final class RideBookedWindowsStore {

    /// `nil` on the simulated path — see the header. Nothing here fetches without
    /// one, so "the simulated picker never constructs the fetch" is a property of
    /// the type rather than a rule a call site has to remember.
    @ObservationIgnored private let provider: (any RideBookedWindowsProviding)?

    /// True when a fetch is even possible. Read by tests and by the picker's own
    /// "is this feature on at all" branch; deliberately NOT a loading flag.
    var isEnabled: Bool { provider != nil }

    private(set) var coverage: RideBookedWindowsCoverage?
    private var held: [RideBookedWindow] = []

    @ObservationIgnored private var task: Task<Void, Never>?

    private static let log = Logger(subsystem: "app.myrobotaxi.ios", category: "bookedWindows")

    init(provider: (any RideBookedWindowsProviding)? = nil) {
        self.provider = provider
    }

    /// The windows held FOR `vehicleID`, or `[]` for any other id (and for a
    /// vehicle nothing has been read for yet).
    ///
    /// `[]` is the fail-open answer and the common-case answer at once, which is
    /// what makes every degradation here land on "the picker behaves exactly as it
    /// did before MYR-385" without a branch anywhere saying so.
    func windows(for vehicleID: String) -> [RideBookedWindow] {
        guard coverage?.vehicleID == vehicleID else { return [] }
        return held
    }

    /// Re-read unconditionally. Called when the schedule picker OPENS, and after a
    /// create is refused `409 time_conflict` — the two moments where the previous
    /// answer is known to be either stale or demonstrably wrong.
    func refresh(vehicleID: String, from: Date, to: Date) {
        fetch(vehicleID: vehicleID, from: from, to: to)
    }

    /// Read only if `[from, to]` is not already inside what is held for this
    /// vehicle. Called on a day-chip change.
    func ensureCovered(vehicleID: String, from: Date, to: Date) {
        guard coverage?.covers(vehicleID: vehicleID, from: from, to: to) != true else { return }
        fetch(vehicleID: vehicleID, from: from, to: to)
    }

    /// Drop everything held. The picker returns to its pre-MYR-385 behaviour until
    /// the next read lands — which is the correct resting state for "we no longer
    /// know", never a reason to block anything.
    func invalidate() {
        task?.cancel()
        task = nil
        coverage = nil
        held = []
    }

    private func fetch(vehicleID: String, from: Date, to: Date) {
        guard let provider, !vehicleID.isEmpty, to > from else { return }
        // One read at a time. A second open landing on top of an in-flight one
        // supersedes it rather than racing it into the same two properties.
        task?.cancel()
        task = Task { [weak self] in
            defer { self?.task = nil }
            do {
                let windows = try await provider.windows(vehicleID: vehicleID, from: from, to: to)
                guard !Task.isCancelled else { return }
                self?.adopt(windows, coverage: RideBookedWindowsCoverage(vehicleID: vehicleID, from: from, to: to))
            } catch {
                guard !Task.isCancelled else { return }
                // LOG AND DEGRADE. Nothing is published, nothing is retried and the
                // picker is not told: what it already holds (usually nothing) stays,
                // and the server gate backstops. The one thing that must NOT happen
                // is a partial or empty result being adopted as COVERAGE — that
                // would say "checked, all clear" about a range nobody checked.
                Self.log.info("booked-windows read failed; picker degrades to unrestricted: \(String(describing: error))")
            }
        }
    }

    private func adopt(_ windows: [RideBookedWindow], coverage: RideBookedWindowsCoverage) {
        held = windows
        self.coverage = coverage
    }
}

// MARK: - The picker's range

/// The one place the picker's request range is derived, so the range FETCHED and
/// the chips RENDERED are the same seven days.
enum RideBookedWindowsRange {

    /// `[now, end of the last day chip]`.
    ///
    /// Starts at `now` rather than at the start of today deliberately: an
    /// ACTIVE-INSTANT window straddles the present moment, and a range beginning
    /// later today would still catch it (§7.22 returns anything OVERLAPPING the
    /// range) while a range beginning tomorrow would not. Earlier-today slots need
    /// no window to dim them — MYR-370's day-identity rule already has them.
    ///
    /// Ends one day past the last chip's start, so the last chip's evening slots
    /// are inside the range. That is ~8 days, comfortably under §7.22's 14-day cap
    /// (`BookedWindowsRange.maximum`) — which is a REFUSAL, not a clamp, so a
    /// picker horizon that ever grew past it would start getting `400`s and
    /// degrading to an unrestricted picker rather than silently under-dimming.
    static func range(
        days: [RideScheduleDay],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (from: Date, to: Date)? {
        guard let last = days.map(\.date).max(),
              let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)),
              end > now
        else { return nil }
        return (now, end)
    }
}
