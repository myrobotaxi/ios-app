import Foundation

// MARK: - MYR-414 — what the rider's post-ride summary is ALLOWED to claim
//
// r17, the client: *"this screen at the end is not connected to real data."* The
// post-ride takeover rendered "35 min TRIP", "14.2 mi FSD MILES" and "100%
// AUTONOMOUS" over a live ride, plus a straight two-point hero line.
//
// Every one of those numbers was the prototype's illustration read literally:
//
//  • **Trip time** was `destination.minutes` — the ESTIMATE the search sheet
//    quoted before the car moved, re-labelled after the fact as what the ride
//    took. On a fixture destination it is a baked constant.
//  • **FSD miles** was `destination.miles` — the same estimate again, this time
//    wearing a claim about WHO DROVE, on a product whose cars are driven by a
//    human/FSD-supervised owner. The app holds no drive record for the ride, so
//    the honest count of FSD miles is not "the trip's distance", it is UNKNOWN.
//  • **100% autonomous** was a literal. It was never derived from anything.
//  • The **hero line** was `[pickup, destination]`, the two-point placeholder
//    MYR-237/MYR-293 named as the one shape that is never a route. (MYR-327
//    excluded this card from the expanded-route viewer FOR that reason; the
//    honest fix is to make the line real, not to keep hiding it at small size.)
//
// So the rule this file states is the MYR-228 no-fixtures rule pointed at a
// screen full of numbers: **a stat tile renders IFF the datum behind it exists**,
// and the SIMULATED path keeps the prototype's illustration verbatim, because
// that is what it is for.
//
// Written as ONE pure resolution over the facts rather than four `if isLive`
// branches in the view, for MYR-387's reason: a screen cannot forget an arm of a
// returned value the way it can forget the third leg of an `if`/`else if`.

/// The trip's own span, from the two instants a client can honestly hold.
///
/// **THE WIRE HAS NO TRIP START, AND THAT IS THE WHOLE DIFFICULTY.**
/// `RideRequest` (contracts) carries `createdAt`, `updatedAt`, `acceptedAt`,
/// `dispatchedAt` and `completedAt` — and the status history the trip span would
/// come from does not exist on it. Of those five:
///
///  • `createdAt` is when the rider ASKED, which includes waiting for an owner to
///    accept — on a scheduled ride, potentially days.
///  • `acceptedAt` / `dispatchedAt` are when the car was SENT, which includes the
///    whole leg-1 approach and however long it then waited at the kerb. MYR-411
///    is precisely about how long that wait can be.
///  • `updatedAt` is the last mutation of any kind and describes nothing.
///
/// A span built from any of them is a real instant subtracted from a real instant
/// and still not the trip — labelling "accepted → completed" as TRIP is the same
/// defect this issue is fixing, with better provenance. **The trip is
/// `enroute → completed`**: `enroute` is the moment the rider's own "Start ride"
/// tap takes the car off the kerb (MYR-411 is emphatic that this is the boarding
/// boundary), and there is no server instant for it.
///
/// So the START is **this device's own observation** of the transition and the END
/// is the **server's `completedAt`**. The asymmetry is deliberate: one of the two
/// exists on the wire and one does not, and inventing a client-side completion
/// instant would let a delayed poll inflate the trip.
///
/// **AN OBSERVATION THIS PROCESS DID NOT MAKE IS NOT AVAILABLE**, which is the
/// honest half. A ride adopted mid-flight after a force-quit (MYR-396/MYR-402's
/// world) arrives already `enroute`, and this device cannot know when it started;
/// the tile is then omitted rather than measured from the moment we found out. The
/// proper home for a server-side trip span is MYR-178 (ride summary generation +
/// persistence), which is Backlog — see the PR's follow-up note.
enum RideTripSpan {
    /// The enroute instant to CARRY, given a status fold.
    ///
    /// - Parameters:
    ///   - previous: the status this device held BEFORE the fold (`nil` = this
    ///     process had no record, i.e. a first sighting / cold adoption).
    ///   - next: the status the fold lands on.
    ///   - held: the instant already carried, if any.
    ///
    /// Three rules, in order:
    ///  1. **An instant already held is never restamped.** A refetch, a re-delivered
    ///     `ride_status_changed` frame and a foreground reconcile all fold the same
    ///     `enroute` onto an `enroute` record; restamping on each would walk the
    ///     start forward and shrink the trip toward zero.
    ///  2. **Only a TRANSITION stamps**, and a transition needs BOTH sides. A
    ///     `previous` of `nil` is a first sighting — this process held no record —
    ///     so it is not a transition however the ride arrives, and neither is
    ///     `enroute → enroute`. Spelling this as `previous != .enroute` alone reads
    ///     correct and quietly stamps every cold adoption with the moment the app
    ///     launched, which is the inflated-trip lie this whole rule exists to avoid.
    ///  3. Everything else carries `held` through unchanged, including a fold to a
    ///     terminal status: the ride's start does not stop being known because the
    ///     ride ended.
    static func observing(
        previous: RideRequestStatus?,
        next: RideRequestStatus,
        held: Date?,
        now: Date = Date()
    ) -> Date? {
        if let held { return held }
        guard let previous, next == .enroute, previous != .enroute else { return held }
        return now
    }

    /// The trip's length in whole minutes, or `nil` when it is not derivable.
    ///
    /// `nil` for a missing instant at either end, for a completion that precedes
    /// the start (clock skew, or a `completedAt` belonging to an earlier attempt),
    /// and for a span that rounds to **zero** minutes — MYR-395's 0-sentinel rule
    /// says an unmeasurable duration renders no line at all rather than "0 min".
    static func minutes(enrouteObservedAt: Date?, completedAt: Date?) -> Int? {
        guard let start = enrouteObservedAt, let end = completedAt else { return nil }
        let seconds = end.timeIntervalSince(start)
        guard seconds > 0 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 1 else { return nil }
        return minutes
    }
}

/// Everything the summary takeover renders that could be a fabrication, resolved
/// once from the facts in hand.
struct RideSummaryPresentation: Equatable {
    /// A stat tile is a VALUE OR A DASH, never a fabrication.
    ///
    /// **MYR-422 — THE CLIENT'S DECISION, SUPERSEDING MYR-414's OMISSION.** That
    /// issue dropped the FSD MILES and AUTONOMOUS tiles on live, because the app
    /// holds no drive record for a ride and a number it cannot derive is a number it
    /// must not print. The client's answer: *"should just have some place holder
    /// instead of being omitted"* — the row is the page's spine, and a page that
    /// shows one tile after a ride reads as broken rather than as honest.
    ///
    /// So the two tiles come back carrying **`nil`**, and `nil` renders as the em
    /// dash `BatteryReadout` established for exactly this ("the start & used figures
    /// are unknowable, so they degrade to '—'", MYR-204): value "—", unit and label
    /// unchanged, no styling of its own. **A dash is the ONLY non-real thing this
    /// enum can render** — there is still no live arm anywhere that produces a
    /// number for either of them, which is the MYR-414 guarantee restated as an
    /// associated value rather than as an absence.
    enum Tile: Equatable {
        /// The measured trip span (`RideTripSpan`) on live; the destination's
        /// quoted estimate in SIM.
        case trip(minutes: Int)
        /// FSD miles. **`nil` on every live resolution today**, and there is no
        /// input that could make it otherwise: a ride carries no autonomy record.
        ///
        /// THE SEAM: the day a window-scoped FSD figure exists, it arrives here and
        /// the dash becomes a number with no other change to this file. The obvious
        /// candidate is NOT sufficient on its own — MYR-422's drive join
        /// (`RideSummaryDriveRouteStore`) already identifies the drive this ride was,
        /// and `DriveSummary.fsdMiles` is right there — but that figure describes the
        /// WHOLE DRIVE, which routinely includes the owner's approach to the pickup,
        /// and unlike the polyline it cannot be trimmed to the trip's window (§7.4's
        /// points carry no autonomy state). Quoting it would be MYR-414's defect with
        /// better provenance. What closes it is a server-side ride→drive join
        /// (MYR-178) or per-point autonomy on §7.4.
        case fsdMiles(Double?)
        /// The autonomous share, as a whole percent. `nil` on live for the same
        /// reason `fsdMiles` is; the prototype's `100` literal is the SIM arm's.
        case autonomous(percent: Int?)
    }

    /// Left-packed, in order.
    ///
    /// MYR-422: on live this now always holds at least the two PLACEHOLDER tiles, so
    /// the strip is never empty and the row never collapses — the client's "keep the
    /// layout stable". The empty case survives as an unreachable-on-live floor
    /// (`RideRequestSummaryContent` still spends none of the strip's 18pt for it),
    /// because a strip is a container and a container with nothing in it should not
    /// reserve room (MYR-347).
    var tiles: [Tile]
    /// Whether the hero map draws a LINE at all. MYR-293's law: pins are a fact,
    /// a route we do not hold is not.
    var drawsRouteLine: Bool
    /// **MYR-422 — the measured trip distance, which is no longer a TILE.**
    ///
    /// MYR-414 put the road route's own length in the strip's second slot. With the
    /// client's two placeholders back, a fourth tile does not fit the page: measured
    /// through a `UIHostingController`, `trip · distance · — · —` is **363.3pt**
    /// against a content band of **331pt** at 375 and **349pt** at 393 — it would run
    /// straight out of the gutter on the client's own device, and the row's grammar
    /// has no ellipsis to say so (`RideSummaryStripLayoutTests`). Compressing the
    /// dividers does not save it either: the worst legal row ("1 hr 37", a
    /// three-digit distance) is 306.3pt of TILES alone.
    ///
    /// So the strip is the prototype's three slots, and the number rides the hero
    /// caption instead — "from {pickup} · 12.8 mi", one short suffix on a line that
    /// already exists, directly under the route it measures. That keeps MYR-414's
    /// datum on the page AND its invariant intact: this is `nil` exactly when
    /// `drawsRouteLine` is false, so the page still cannot measure a line it will not
    /// draw. `nil` in SIM, which is what keeps the drift-gate capture unchanged.
    var heroDistanceMiles: Double?
    /// The "Tip your driver" section. **Off on live** — it goes nowhere (there is
    /// no tipping backend and the buttons open a joke card), and it says "driver"
    /// on a driverless product. MYR-288/MYR-344's no-dead-affordances precedent.
    /// SIM keeps it: it is the prototype's own gag and the drift gate photographs
    /// it.
    var offersTip: Bool
    /// The instant behind the "Arrived · {clock}" eyebrow. `nil` renders the
    /// eyebrow with **no clock** rather than stamping the moment the view happened
    /// to be composed, which is what the pre-MYR-414 screen did on every path.
    var arrivedAt: Date?

    /// The prototype's celebrated literal (ride-request.jsx:975). Named so the SIM
    /// arm's `100` is visibly the illustration's own number and not a claim this
    /// resolver derives from anything.
    static let prototypeAutonomousPercent = 100

    /// - Parameters:
    ///   - isLive: the ONE resolved `AppMode` (`SharedViewerState.isLiveLocation`),
    ///     plus the single DEBUG capture branch. Never a new env var (MYR-228).
    ///   - estimateMinutes/estimateMiles: the destination's QUOTED estimate. The
    ///     SIM arm's only input, and deliberately unreachable from the live arm.
    ///   - tripMinutes: `RideTripSpan.minutes(…)`.
    ///   - roadRouteMiles: the length of the leg-2 road polyline, IFF one is held
    ///     for this ride's exact pickup/destination pair and it is real road
    ///     geometry (`RideRoutePolyline.isReal`). `nil` otherwise.
    ///   - completedAt: the server's own completion instant.
    static func resolve(
        isLive: Bool,
        estimateMinutes: Int,
        estimateMiles: Double,
        tripMinutes: Int?,
        roadRouteMiles: Double?,
        completedAt: Date?,
        now: Date = Date()
    ) -> RideSummaryPresentation {
        guard isLive else {
            // The prototype's own illustration, byte for byte. Every drift-gate
            // scene lands here, which is what keeps them unchanged.
            return RideSummaryPresentation(
                tiles: [
                    .trip(minutes: estimateMinutes),
                    .fsdMiles(estimateMiles),
                    .autonomous(percent: Self.prototypeAutonomousPercent)
                ],
                drawsRouteLine: true,
                // The prototype's hero caption is "from {pickup}" and nothing else.
                heroDistanceMiles: nil,
                offersTip: true,
                arrivedAt: now
            )
        }
        var tiles: [Tile] = []
        if let tripMinutes { tiles.append(.trip(minutes: tripMinutes)) }
        // MYR-422 — the two placeholders, ALWAYS, and always carrying `nil`. They
        // are appended unconditionally rather than gated on a datum precisely
        // because there is no datum: their whole job is to hold the row's shape
        // while saying nothing (see `Tile.fsdMiles`' seam note for what would fill
        // them).
        tiles.append(.fsdMiles(nil))
        tiles.append(.autonomous(percent: nil))
        return RideSummaryPresentation(
            tiles: tiles,
            // The presence of a real road route is the SAME fact that carries the
            // measured distance, so the line and the number can never disagree about
            // whether this ride's geometry is known.
            drawsRouteLine: roadRouteMiles != nil,
            heroDistanceMiles: roadRouteMiles,
            offersTip: false,
            arrivedAt: completedAt
        )
    }
}
