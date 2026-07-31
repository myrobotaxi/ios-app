import Foundation

// MARK: - OwnerHomePresentation (MYR-387) — which of owner Home's three screens
//
// THE CLIENT'S REPORT (TestFlight, build 202607311129, 2026-07-31 12:44 CT):
// owner Vehicle tab showing the Lunar switcher chip, a COMPLETELY BLACK map area
// and the bottom sheet stuck on skeleton placeholder rows. *"Nothing loading,
// what happened?"* His car was `in_service` and NOT streaming; `GET
// /api/vehicles` and `GET /api/vehicles/{id}/snapshot` both answered fine from
// the backend at the time, and a Share-tab screenshot from the SAME MINUTE
// proves the device had working network and a valid session.
//
// What he photographed is `OwnerHomeLoadingSkeleton` (MYR-326): the real
// `MapHeader` over `Color.mrtBg` — there is no map in that branch at all, which
// is why the whole map area is black — plus placeholder rows in the sheet.
//
// MYR-326 built an END for that state. `LiveVehicleFleet` bounds the cold read to
// `ColdSnapshotLoad.budget()` (~21s) and then publishes the honest
// "Can't reach Lunar right now", and `ColdSnapshotLoadTests` proves it does, at
// fleet level, in four different ways.
//
// **`HomeScreen` never rendered it.** Its body asked its three questions in this
// order:
//
//     if let vehicle = selectedVehicle, let telemetry = selectedTelemetry, !isConnecting { content }
//     else if isConnecting { skeleton }
//     else { FleetConnectingView(message: statusMessage) }
//
// and `isConnecting` is `false` the moment a `statusMessage` exists (that
// suppression is MYR-326's own, and it is correct). So on a cold-read timeout the
// FIRST branch matched — `selectedVehicle` is non-nil, because the fleet LIST
// succeeded and told us the car is called Lunar — and Home rendered CONTENT built
// on a snapshot that does not exist: `VehicleContractMapping.placeholderActivity`,
// i.e. "Locating…" at latitude 0, longitude 0, over a 0% battery. The honest
// branch was reachable only when the fleet list ITSELF failed, which is precisely
// the case it was NOT written for.
//
// **This is the MYR-369 lesson repeating**: a pure rule with good tests and the
// wrong consumer. Every assertion about `ColdSnapshotLoad` stayed green while the
// state it describes could not be reached from the product. Neither the compiler,
// nor the suite, nor a screenshot of `ownerConnecting` (whose fleet never times
// out) could catch it.
//
// So the render decision stops being three conditions inline in a `body` and
// becomes ONE pure function over the four facts that decide it. A screen cannot
// forget an arm of an enum the way it can forget the third leg of an
// `if`/`else if`/`else`.
enum OwnerHomePresentation: Equatable {
    /// The real map + sheet, on real data.
    case content
    /// A skeleton, because something is GENUINELY in flight behind it.
    case loading
    /// The honest end state: nothing is coming, and here is why. Carries the
    /// fleet's own quiet line (`nil` only when the fleet had nothing to say).
    case unavailable(message: String?)

    /// Resolve owner Home's screen from the four facts that decide it.
    ///
    /// Rule 1 — **an honest failure OUTRANKS a vehicle row.** Knowing a car's
    /// NAME is not knowing where it is: the list is one fast REST call and the
    /// snapshot is the one that didn't answer, so `hasVehicle` is true in exactly
    /// the situation this arm exists for. It is gated on `hasLiveSnapshot` so it
    /// can never blank a sheet full of perfectly good last-known values — a
    /// failed read must never clear what we already hold (NFR-3.12/3.13), which
    /// is the same reason `LiveVehicleFleet.armColdLoadWatchdog` only arms while
    /// `state` is nil.
    ///
    /// Rule 2 — **a skeleton requires something in flight.** MYR-326's
    /// "loading ≠ unavailable" as a precedence, not a comment: once rule 1 has
    /// taken every case with a settled failure, whatever is left under
    /// `isConnecting` really is still being fetched.
    ///
    /// Rule 3 — content needs a row AND a telemetry source. Anything else is
    /// `.unavailable`, which is where a live fleet with an empty account and a
    /// failed list already landed.
    ///
    /// The SIMULATED fleet publishes `statusMessage == nil`, `isConnecting ==
    /// false` and (by the protocol default) `hasLiveSnapshot == true`, so it
    /// resolves `.content` on every input — every drift-gate scene is
    /// byte-identical.
    static func resolve(
        hasVehicle: Bool,
        hasTelemetry: Bool,
        isConnecting: Bool,
        statusMessage: String?,
        hasLiveSnapshot: Bool
    ) -> OwnerHomePresentation {
        if statusMessage != nil, !hasLiveSnapshot {
            return .unavailable(message: statusMessage)
        }
        if isConnecting { return .loading }
        if hasVehicle, hasTelemetry { return .content }
        return .unavailable(message: statusMessage)
    }

    /// Whether this presentation offers the owner a way to ask again.
    ///
    /// **A deliberate deviation from MYR-326/MYR-343's "no retry button, a resume
    /// re-asks" rule, and it is client-directed**: the resume recovery is real and
    /// still runs, but it is invisible, and the client's whole sentence was
    /// *"Nothing loading, what happened?"* — a question the screen has to be able
    /// to answer where it is asked. Only `.unavailable` offers it; a skeleton must
    /// never carry a retry, because something IS already running behind it.
    var offersRetry: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
