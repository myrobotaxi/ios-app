import SwiftUI
import DesignSystem

// MARK: - RideRequestTrackingContent (MYR-171 base, reworked MYR-270 dispatch v2)
//
// The rider's live tracking sheet. Two legs (car → pickup, then pickup → drop-off).
// MYR-270 drives the STAGE off the server status on the live path — the owner-driven
// dispatch v2 lifecycle (accepted → arrived → enroute → completed) — while the SIM /
// DEBUG tracking scenes (status `.accepted`, `trackProgress`-ticker-driven) keep
// deriving the leg from progress vs `pickupCut`, so `trackingLeg1/leg2/arriving`
// render exactly as before (drift gate). See `RiderTrackingStage.stage(...)`.
//
// The rider affordance out of `arrived` is the CIRCULAR PULSING "Start ride" CTA
// (`PulseStartButton`, DesignSystem), gated to EXACTLY `status == .arrived`: never
// during `accepted` (the owner has not confirmed pickup yet — the server would 409 a
// start). Tapping it calls `start()`, which flips `arrived → enroute` and makes the
// backend push the drop-off nav.
/// MYR-397 — which layer of the tracking sheet this content is rendering.
///
/// ONE struct renders both, deliberately: the peek's status line, its ETA and the
/// full card's are the SAME derivations (`toPickupMinutes`, `pickupRemainMiles`,
/// the ladder), and two views computing them independently is how a peek comes to
/// say "4 min" under a full card that has stopped claiming one. The compositions
/// differ; the numbers behind them cannot.
enum TrackingSheetLayer: Equatable {
    /// The brief summary the sheet drags DOWN to — status line + ETA.
    case peek
    /// The full details the sheet drags UP to — LOOK FOR, itinerary, plate,
    /// Cancel.
    case full
}

struct RideRequestTrackingContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: any RideRequestService
    var totalHeight: CGFloat?
    /// MYR-397 — peek or full. Defaults to `full`, so every existing call site
    /// (previews, the standalone fallback card) renders exactly what it did.
    var layer: TrackingSheetLayer = .full
    /// MYR-271: when hosted inside the `PanSheet` engine (`RiderTrackingSheet`), the
    /// engine's surface provides the sheet wash/corners/hairline, so the content
    /// drops its own `rideRequestSheetChrome()` (mirrors the search sheet's `hosted`
    /// path). `false` keeps the standalone bottom-pinned card for previews/fallback.
    var hosted: Bool = false
    /// MYR-270: the streamed nav ETA (minutes) of the ride's car during the in-ride
    /// leg, or `nil` when no live ETA stream is available yet (v1 rider gap — the
    /// arriving takeover then never fires on live, never a fabricated ETA, MYR-228).
    /// Drives the `enroute` "Arriving" takeover off the REAL wire ETA (≤ 2), not a timer.
    var navMinutesToArrival: Int? = nil
    /// MYR-393 — the honest motion ladder's verdict for this frame: the status
    /// line, and whether a countdown to pickup may be claimed at all. Resolved by
    /// `SharedViewerScreen` (which holds the live motion latch) so the peek layer,
    /// the full layer and the map are all reading ONE decision.
    var ladder: RiderTrackingLadderState
    /// MYR-393 — the muted "Position from N min ago" qualifier, or `nil` when the
    /// freshest position we hold is current (and always `nil` in SIM).
    var freshnessNote: String? = nil
    /// MYR-472 — what the LIVE path knows about this ride's clock: the anchored
    /// pickup instant and the remainder MEASURED from the car's fix against the
    /// leg's route. `nil` on the simulated path (and for every preview / fallback
    /// call site), where every derivation below stays exactly what it was — see
    /// `RiderTrackingTruth` for why this is an absence rather than an `isLive`
    /// branch.
    var truth: RiderTrackingTruth? = nil
    /// MYR-397 — is "Cancel ride" in this phase? Resolved through
    /// `RiderTrackingCancelVisibility` at the call site so the rule is pure.
    var showsCancel: Bool = false
    /// A cancel is in flight — the row spins and refuses a second tap.
    var isCancelling: Bool = false
    var onCancel: (() -> Void)? = nil

    /// MYR-270 — disables the "Start ride" CTA for the frame it is tapped. `start()`
    /// flips the status to `.enroute` synchronously (the button then vanishes), so
    /// this only guards a double-tap landing in the same frame. Reset on every status
    /// change so a re-shown button (a failed/reverted advance) is tappable again.
    @State private var starting = false

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { viewerState.liveFleetMember ?? request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var isLiveVehicle: Bool { viewerState.liveFleetMember != nil }
    private var passenger: RidePassenger? { request?.input.passenger }
    private var destination: RidePlace { request?.input.destination ?? RideRequestFixtures.recentPlaces[0] }
    private var pickupLabel: String { request?.input.pickup.label ?? "Current location" }

    private var progress: Double { request?.trackProgress ?? 0 }
    private var pickupCut: Double { request?.pickupCut ?? 0.2 }
    private var atPickupByProgress: Bool { progress >= pickupCut }

    private var pickupLegMinutes: Double { RideRequestTiming.pickupLegMinutes }
    private var tripMinutes: Int { destination.minutes }
    private var totalMinutes: Double { pickupLegMinutes + Double(tripMinutes) }

    // MARK: MYR-472 — the ticker's derivations, and the measurement that outranks them
    //
    // Everything in this block used to be `(1 - trackProgress) × <a duration fixed
    // at booking>`. On the live path `trackProgress` is seeded once and never
    // advances, so all four numbers were constants re-rendered for the whole ride
    // — the "10 min · 4.1 mi away" that never moved. They survive UNCHANGED as the
    // simulated model (where the ticker really does drive a car) and are now the
    // FALLBACK arm: whenever `truth` carries a measurement, that wins.

    private var tickerRemainMinutes: Int { max(0, Int(((1 - progress) * totalMinutes).rounded())) }
    private var tickerToPickupMinutes: Int {
        max(0, Int(((pickupCut - progress) / pickupCut * pickupLegMinutes).rounded()))
    }

    /// ride-request.jsx:565 `pickupMilesTotal = 2.2`.
    private static let pickupLegMiles = 2.2

    private var tickerPickupRemainMiles: Double {
        max(0.1, (1 - min(progress, pickupCut) / pickupCut) * Self.pickupLegMiles)
    }

    private var rideProgress: Double { max(0, (progress - pickupCut) / max(0.0001, 1 - pickupCut)) }
    private var tickerDropRemainMiles: Double { max(0.1, (1 - rideProgress) * destination.miles) }

    /// Minutes until DROP-OFF — the number the drop-off row's clock is set from,
    /// and the hero's once the rider is aboard.
    ///
    /// The measurement covers the ACTIVE leg only, so pre-pickup it has to be
    /// completed by the trip's own estimate: leg 2 has not begun, nothing about it
    /// is observable yet, and `destination.minutes` is the honest estimate the
    /// rider booked against. Reading the leg-1 remainder alone here would put the
    /// drop-off clock a whole trip too early — this issue's defect with the sign
    /// reversed.
    private var remainMinutes: Int {
        guard let measured = truth?.remaining?.minutes else { return tickerRemainMinutes }
        return atPickup ? measured : measured + tripMinutes
    }

    /// Minutes until the car reaches the PICKUP — the leg-1 measurement on its own.
    private var toPickupMinutes: Int { measuredOnLegOne?.minutes ?? tickerToPickupMinutes }
    private var pickupRemainMiles: Double { measuredOnLegOne?.miles ?? tickerPickupRemainMiles }
    private var dropRemainMiles: Double { measuredOnLegTwo?.miles ?? tickerDropRemainMiles }

    /// The measurement, and WHICH leg it describes. `truth.remaining` is always
    /// the leg the rider is currently on, so each reader has to name the leg it
    /// wants rather than take whatever is there — a leg-1 remainder read as a
    /// drop-off distance is a wrong number that would look perfectly plausible.
    private var measuredOnLegOne: RiderLegRemaining? { atPickup ? nil : truth?.remaining }
    private var measuredOnLegTwo: RiderLegRemaining? { atPickup ? truth?.remaining : nil }

    /// The pickup stop's clock.
    ///
    /// Two different kinds of statement wear one row. **Before pickup it is a
    /// FORECAST** and moving with the clock is correct — `now + <what is left of
    /// leg 1>`, which on live is now a measured remainder rather than a ticker's.
    /// **After pickup it is a FACT about the past**, and MYR-472's second defect
    /// was rendering it as `fromNow(0)`: the wall clock, re-stamped every frame,
    /// onto a boarding that happened once. It is the anchored instant now, and a
    /// ride this process did not observe start has no anchor and says so with the
    /// same calm dash an unknown ETA uses rather than inventing one.
    private var pickupClock: String {
        RiderTrackingTruth.pickupClockText(truth, atPickup: atPickup, minutesToPickup: toPickupMinutes)
    }

    private var arriveClock: String { RideRequestClock.fromNow(minutes: remainMinutes) }

    // MARK: MYR-270 — status-driven stage (live) / progress-derived (sim)

    /// Whether the drop-off "Arriving" takeover fires. On the live in-ride leg it is
    /// the REAL streamed nav ETA (≤ 2) — never a timer, never fabricated; on the
    /// sim/`.accepted` progress path it is the existing progress-derived `remain ≤ 2`
    /// so the `trackingArriving` sim scene is unchanged.
    private var arriving: Bool {
        RiderTrackingStage.arrivingDropoff(request: request, navMinutesToArrival: navMinutesToArrival)
    }

    private var stage: RiderTrackingStage {
        RiderTrackingStage.stage(request: request, navMinutesToArrival: navMinutesToArrival)
    }

    /// Whether the sheet renders the IN-RIDE leg framing (hero/itinerary/"Your ride"
    /// row). `arrivedAwaitingStart` renders its own card, so it reads as leg 1 here.
    private var atPickup: Bool {
        switch stage {
        case .inRide, .arrivingDropoff: return true
        case .toPickup, .arrivedAwaitingStart: return false
        }
    }

    var arrivingPickup: Bool {
        !atPickup && RiderTrackingStage.arrivingPickup(request: request, navMinutesToArrival: navMinutesToArrival)
    }

    /// MYR-393 — the status line is the LADDER's now, not a `!atPickup` ternary.
    ///
    /// The sentence it replaced ("Heading your way" for every non-terminal status)
    /// was derived from the DISPATCH, so it fired on the accept and kept saying so
    /// about a car parked at a service centre. `ladder.line.text` is a decision
    /// about the CAR, and the one place either layer reads it from.
    private var statusWord: String { ladder.line.text }

    var body: some View {
        Group {
            switch layer {
            case .peek: peekLayer
            case .full: fullLayer
            }
        }
        .modifier(TrackingChrome(hosted: hosted))
        .onChange(of: request?.status) {
            // The advance resolved — either it moved on (button gone) or a
            // failed/reverted advance came back (button re-shown). Clear the latch
            // so a re-shown "Start ride" is tappable again (MYR-265 review bug).
            starting = false
        }
    }

    // MARK: MYR-397 — the two layers

    /// The full-details layer: everything this sheet has always rendered, plus the
    /// Cancel action in every pre-pickup phase.
    private var fullLayer: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch stage {
            case .arrivingDropoff:
                arrivalHeader
            case .arrivedAwaitingStart:
                arrivedContent
            case .toPickup, .inRide:
                liveHeader
                if !atPickup {
                    rideRow(emphasize: true).padding(.bottom, 12)
                }
                itineraryStops.padding(.bottom, 12)
                if atPickup {
                    rideRow(emphasize: false)
                }
            }
            // MYR-397 — its own slot rather than an inline `if`, so "no dead space
            // where it was" is measurable rather than asserted in a comment. See
            // `TrackingCancelSlot`.
            TrackingCancelSlot(visible: showsCancel, isCancelling: isCancelling) {
                onCancel?()
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 30)
    }

    /// The brief-summary peek. Built from THIS struct's own derivations (see
    /// `TrackingSheetLayer`), so it can never disagree with the card above it.
    private var peekLayer: some View {
        RiderTrackingPeekContent(
            ladder: ladder,
            // MYR-395 — the peek's hero is the FULL card's hero, unit included:
            // it takes the same `(value, unit)` pair rather than a number plus an
            // assumption, so a 43-hour leg cannot read "2623" over a small "min"
            // on one layer and "43 hr 43 min" on the other.
            duration: peekShowsHero ? heroDuration : nil,
            milesText: peekShowsHero ? heroMilesText : nil,
            contextPrefix: atPickup ? "Dropping you off at " : "Picking you up at ",
            contextPlace: atPickup ? destination.label : pickupLabel,
            freshnessNote: freshnessNote
        )
    }

    /// The peek's hero pair. Past pickup the numbers are the drop-off's and are
    /// always honest; before it they are the ladder's to allow — a pre-motion peek
    /// carries the waiting line and NO number, exactly as the full card does.
    private var peekShowsHero: Bool { showsHeroPair }

    // MARK: Live header (ride-request.jsx:820-838)

    private var liveHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                    RideEyebrowText(text: statusWord, color: .mrtGold, size: 11)
                }
                (Text(atPickup ? "Dropping you off at " : "Picking you up at ")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtTextSec)
                 + Text(atPickup ? destination.label : pickupLabel)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.mrtText))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                // MYR-393 — the position-freshness qualifier, when the freshest
                // fix we hold is old. Brings exactly its own room (MYR-345).
                if let freshnessNote {
                    Text(freshnessNote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                        .lineLimit(1)
                        .accessibilityIdentifier("mrt.tracking.freshnessNote")
                }
            }
            Spacer(minLength: 8)
            // MYR-393 — **no countdown before motion.** The 34pt hero was the "4
            // min" the client photographed beside a parked car; it is computed
            // from `trackProgress`, a ticker the ACCEPT starts. Pre-motion the
            // whole pair is withheld rather than replaced: nothing is being
            // fetched and no arrival is estimable, so there is no in-flight state
            // to render and a placeholder would be the MYR-294 shimmer again.
            // MYR-395 — when it IS claimed, the number and its unit come from the
            // ONE duration grammar (`heroDuration`), so a withheld countdown stays
            // withheld and a long one reads "43 hr 43" / "min".
            if showsHeroPair {
                VStack(alignment: .trailing, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(heroDuration.value)
                            .font(.system(size: 34, weight: .bold))
                            .monospacedDigit()
                            .tracking(-1)
                            .foregroundStyle(Color.mrtText)
                        Text(heroDuration.unit)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.mrtGold.opacity(0.8))
                    }
                    Text(heroMilesText)
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtGold.opacity(0.6))
                }
            }
        }
        .padding(.bottom, 16)
    }

    /// The hero minutes/miles pair. In-ride numbers describe a trip the rider is
    /// on and are always shown; pre-pickup ones are a claim about a car they
    /// cannot see, and the ladder decides whether it is one we can make.
    ///
    /// MYR-472 adds the second condition, and it points the same way as the
    /// first: in-ride the ladder allows a hero unconditionally (the rider is IN
    /// the car — there is no question about whether it is moving), but on the live
    /// path an unmeasurable remainder has nothing behind it, and a number with
    /// nothing behind it is the whole of this issue. `RiderTrackingTruth.showsHero`
    /// leaves the simulated answer alone.
    private var showsHeroPair: Bool {
        RiderTrackingTruth.showsHero(truth, otherwise: atPickup || ladder.showsPickupCountdown)
    }

    /// MYR-395 — the hero's number and its unit, from the ONE duration grammar.
    ///
    /// The unit is no longer a hardcoded `Text("min")` beside the number, because
    /// on a long leg the number is not a count of minutes: an ETA of 2,623 sets
    /// "43 hr 43" against a small "min", the same shape a 12-minute leg gets. The
    /// sub-minute floor is untouched and still wins outright — "<1 min" is a
    /// statement about arriving, not a duration to reformat.
    private var heroDuration: (value: String, unit: String) {
        let minutes = atPickup ? remainMinutes : toPickupMinutes
        return minutes < 1 ? ("<1", "min") : RideDuration.heroParts(minutes: minutes)
    }

    private var heroMilesText: String {
        let miles = atPickup ? dropRemainMiles : pickupRemainMiles
        return "\(String(format: "%.1f", miles)) mi away"
    }

    // MARK: Itinerary stops (ride-request.jsx:793-816 `Stop`)

    private var itineraryStops: some View {
        VStack(alignment: .leading, spacing: 0) {
            // MYR-393 — the pickup row's clock and its "N mi · N min" note are the
            // same accept-seeded ticker the hero was, so they are withheld on the
            // same rule. `unknownClock` is the calm dash `RidePickupETADisplay`
            // already renders for an ETA that is genuinely unknown — one grammar
            // for "we do not know when", rather than a second one invented here.
            stopRow(
                isDropoff: false,
                place: pickupLabel,
                clock: showsHeroPair ? pickupClock : RidePickupETADisplay.unknownClock,
                filled: atPickup,
                note: pickupStopNote,
                last: false
            )
            // The drop-off clock is the whole-trip `remainMinutes` from now, which
            // is the pickup leg's ticker plus the trip — so pre-motion it is
            // exactly as unfounded and goes with it. Its NOTE is different and
            // stays: "N mi trip" is a fact about the route, true whether or not
            // the car has set off.
            stopRow(
                isDropoff: true,
                place: destination.label,
                clock: showsHeroPair ? arriveClock : RidePickupETADisplay.unknownClock,
                filled: false,
                note: dropoffStopNote,
                last: true
            )
        }
        .padding(15)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    /// The pickup stop's trailing note. "Picked up" once we are past it; the
    /// remaining-distance pair while the car is demonstrably approaching; and —
    /// pre-motion — the honest waiting sentence in place of a distance that is
    /// interpolated from a ticker rather than measured from the car.
    ///
    /// MYR-395 — when the pair IS rendered its duration goes through the shared
    /// `RideDuration` grammar, exactly as it did before this row moved into a
    /// helper: withholding decides WHETHER there is a number, the grammar decides
    /// how it reads.
    private var pickupStopNote: String {
        if atPickup { return "Picked up" }
        // MYR-393's own arm, unchanged: the car has not demonstrably set off, so
        // there is no approach to describe.
        guard ladder.showsPickupCountdown else { return "Not started yet" }
        // MYR-472 — the ladder says the car IS approaching and we cannot measure
        // how far off it is (no fix, or no real leg-1 route yet). "Not started
        // yet" would contradict the status line directly above it, and the ticker
        // pair is the frozen "2.2 mi · 6 min" this issue is about.
        guard showsHeroPair else { return RidePickupETADisplay.unknownNote }
        return "\(String(format: "%.1f", pickupRemainMiles)) mi \u{00B7} \(RideDuration.text(minutes: toPickupMinutes))"
    }

    /// The drop-off stop's trailing note. Pre-pickup it is a fact about the ROUTE
    /// ("N mi trip") and is true whether or not the car has set off, so it stays
    /// unconditional. In-ride it is the remaining pair, and MYR-472 withholds it
    /// on exactly the same evidence the hero is withheld on — the two describe one
    /// remainder and must never disagree about whether it is known.
    private var dropoffStopNote: String {
        guard atPickup else { return "\(String(format: "%.1f", destination.miles)) mi trip" }
        guard showsHeroPair else { return RidePickupETADisplay.unknownNote }
        return "\(String(format: "%.1f", dropRemainMiles)) mi \u{00B7} \(RideDuration.text(minutes: remainMinutes))"
    }

    private func stopRow(isDropoff: Bool, place: String, clock: String, filled: Bool, note: String, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                RideEyebrowText(text: isDropoff ? "Drop-off" : "Pickup", color: .mrtGold, size: 10)
                Spacer(minLength: 8)
                Text(clock).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Color.mrtTextSec)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(place).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(note).font(.system(size: 12)).foregroundStyle(Color.mrtTextMuted).lineLimit(1)
            }
        }
        .padding(.leading, 25) // 12pt dot + 13pt gap
        .padding(.bottom, last ? 0 : 16)
        .background(alignment: .topLeading) {
            VStack(spacing: 4) {
                Group {
                    if isDropoff {
                        RoundedRectangle(cornerRadius: 3).strokeBorder(Color.mrtGold, lineWidth: 2)
                    } else {
                        Circle()
                            .strokeBorder(Color.mrtGoldTrace, lineWidth: 2)
                            .background(Circle().fill(filled ? Color.mrtGoldTrace : Color.clear))
                    }
                }
                .frame(width: 12, height: 12)
                if !last {
                    connector
                }
            }
            .padding(.top, 3)
        }
    }

    @ViewBuilder
    private var connector: some View {
        if atPickup {
            Rectangle().fill(Color.mrtGold).frame(width: 2).frame(maxHeight: .infinity)
        } else {
            RideConnectorDash()
                .stroke(Color.mrtBorder, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: Ride row — "Look for" (spotting) vs "Your ride" (quiet reference)

    private func rideRow(emphasize: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                RideEyebrowText(text: emphasize ? "Look for" : "Your ride", color: emphasize ? .mrtGold : Color.mrtGold.opacity(0.6), size: 9.5)
                Text("\(fleetMember.colorName) \(fleetMember.name)")
                    .font(.system(size: emphasize ? 17 : 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                Text(fleetMember.model + (passenger?.name.isEmpty == false ? " \u{00B7} for \(passenger!.name)" : ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !fleetMember.plate.isEmpty {
                if emphasize && !isLiveVehicle {
                    emphasizedPlateChip
                } else {
                    RidePlateChip(plate: fleetMember.plate)
                }
            }
        }
        .padding(.horizontal, emphasize ? 14 : 13)
        .padding(.vertical, emphasize ? 13 : 11)
        .background(emphasize ? Color.mrtGold.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(emphasize ? Double(0x66) / 255.0 : Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
        )
    }

    private var emphasizedPlateChip: some View {
        Text(fleetMember.plate)
            .font(.system(size: 18, weight: .bold))
            .monospacedDigit()
            .tracking(1.5)
            .foregroundStyle(Color.mrtGoldButtonLabel)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(MRTShimmerBand())
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .mrtGoldGlow, radius: 10)
    }

    // MARK: MYR-270 — arrived: "Your car is here" + circular pulsing Start CTA
    //
    // Gated to EXACTLY `status == .arrived` (owner has confirmed pickup). During
    // `accepted` the CTA never shows — the server would 409 a start before pickup is
    // confirmed. The button flips `arrived → enroute` (server pushes the dropoff nav)
    // the instant it is tapped, so it then disappears (leg 2).

    private var arrivedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Color.mrtGold).frame(width: 6, height: 6).shadow(color: .mrtGoldGlow, radius: 4)
                // MYR-393 — the ladder's own `.carIsHere`, so this sheet has ONE
                // status line and not a literal that happens to agree with it.
                RideEyebrowText(text: statusWord, color: .mrtGold, size: 11)
            }
            .padding(.bottom, 10)
            // Reuse the "Look for" spotting chip so the rider can identify the car.
            rideRow(emphasize: true)
                .padding(.bottom, 22)
            if request?.status == .arrived {
                HStack {
                    Spacer(minLength: 0)
                    PulseStartButton {
                        guard !starting else { return }
                        starting = true
                        rideRequestService.startRide()
                    }
                    .disabled(starting)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
            }
        }
    }

    // MARK: Arrival takeover (ride-request.jsx:756-774)

    private var arrivalHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Arriving")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.6)
                    .mrtTextShimmer(duration: 2.6)
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    Text(remainMinutes < 1 ? "< 1 min" : RideDuration.text(minutes: remainMinutes))
                        .font(.system(size: 17, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtText)
                    Text("\(String(format: "%.1f", dropRemainMiles)) mi")
                        .font(.system(size: 17))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            .padding(.bottom, 8)

            HStack(spacing: 4) {
                Text("at").font(.system(size: 15)).foregroundStyle(Color.mrtTextSec)
                Text(destination.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText)
            }
            .padding(.bottom, 14)

            HStack(spacing: 8) {
                Image(systemName: "bag").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text("Grab all your belongings")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.mrtGold.opacity(0.9))
            }
            .padding(.top, 13)
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtGold.opacity(Double(0x24) / 255.0)).frame(height: MRTMetrics.hairline)
            }
            .padding(.bottom, 14)

            rideRow(emphasize: false)
        }
    }
}

// MARK: - Rider tracking stage (MYR-270, pure + testable)

/// The rider tracking sheet's stage. On the LIVE path it follows the server status
/// (owner-driven dispatch v2); on the SIM/`.accepted` progress path it derives from
/// the `trackProgress` ticker so the existing tracking drift-gate scenes render
/// unchanged.
enum RiderTrackingStage: Equatable {
    /// Leg 1 — car heading to the pickup ("Heading your way").
    case toPickup
    /// The car has arrived and the rider was picked up; awaiting the rider's Start
    /// ("Your car is here" + the pulsing Start CTA). LIVE-only (`status == .arrived`).
    case arrivedAwaitingStart
    /// Leg 2 — the ride has started, heading to the drop-off.
    case inRide
    /// The drop-off "Arriving" takeover (last stretch).
    case arrivingDropoff

    /// Pure decision, unit-testable without mounting the view.
    ///  • `.arrived` → `arrivedAwaitingStart` (the Start CTA state);
    ///  • `.enroute`/`.completed` → `arrivingDropoff` when the wire ETA says so, else `inRide`;
    ///  • otherwise (`.accepted` live leg 1, or the sim progress ticker) → progress-derived:
    ///    before `pickupCut` → `toPickup`; past it → `arrivingDropoff` (ETA≤2) or `inRide`.
    static func stage(status: RideRequestStatus?, atPickupByProgress: Bool, arriving: Bool) -> RiderTrackingStage {
        switch status {
        case .arrived:
            return .arrivedAwaitingStart
        case .enroute, .completed:
            return arriving ? .arrivingDropoff : .inRide
        default:
            if atPickupByProgress { return arriving ? .arrivingDropoff : .inRide }
            return .toPickup
        }
    }

    // MARK: MYR-393/397 — the same derivation, reachable from OUTSIDE the sheet
    //
    // Two things now have to know which stage a ride is in and neither of them is
    // the sheet: the motion ladder (whose answer the sheet, the peek layer and the
    // map all read) and `RiderTrackingCancelVisibility`. Before this the stage was
    // assembled from six private computed properties inside
    // `RideRequestTrackingContent`, so a second caller had to re-derive it — and a
    // Cancel button that thought the ride was pre-pickup while the card above it
    // had moved on is precisely the kind of disagreement that ships.
    //
    // These are the SAME expressions, moved rather than paraphrased; the view now
    // calls them too, so there is one derivation and it is testable without
    // mounting anything.

    /// Whole-trip minutes remaining, from the record's own progress ticker.
    static func remainMinutes(request: RideRequestRecord?) -> Int {
        let progress = request?.trackProgress ?? 0
        let destinationMinutes = request?.input.destination.minutes ?? RideRequestFixtures.recentPlaces[0].minutes
        let total = RideRequestTiming.pickupLegMinutes + Double(destinationMinutes)
        return max(0, Int(((1 - progress) * total).rounded()))
    }

    /// Minutes to the pickup, from that same ticker.
    static func toPickupMinutes(request: RideRequestRecord?) -> Int {
        let progress = request?.trackProgress ?? 0
        let cut = request?.pickupCut ?? 0.2
        guard cut > 0 else { return 0 }
        return max(0, Int(((cut - progress) / cut * RideRequestTiming.pickupLegMinutes).rounded()))
    }

    static func atPickupByProgress(request: RideRequestRecord?) -> Bool {
        (request?.trackProgress ?? 0) >= (request?.pickupCut ?? 0.2)
    }

    /// Whether the drop-off "Arriving" takeover fires (see the sheet's own note:
    /// the live in-ride leg uses the REAL streamed nav ETA, never a timer).
    static func arrivingDropoff(request: RideRequestRecord?, navMinutesToArrival: Int?) -> Bool {
        switch request?.status {
        case .enroute, .completed:
            if let eta = navMinutesToArrival { return eta <= 2 }
            return false
        default:
            return atPickupByProgress(request: request) && remainMinutes(request: request) <= 2
        }
    }

    /// Whether the car is on the last stretch to the PICKUP ("Your ride is
    /// arriving"). Only meaningful on `.toPickup`; the ladder gates it on motion
    /// evidence exactly as it gates "Heading your way", since both are claims
    /// about a car approaching.
    static func arrivingPickup(request: RideRequestRecord?, navMinutesToArrival: Int?) -> Bool {
        guard stage(request: request, navMinutesToArrival: navMinutesToArrival) == .toPickup else { return false }
        return toPickupMinutes(request: request) <= 1
    }

    /// The stage for a record.
    static func stage(request: RideRequestRecord?, navMinutesToArrival: Int?) -> RiderTrackingStage {
        stage(
            status: request?.status,
            atPickupByProgress: atPickupByProgress(request: request),
            arriving: arrivingDropoff(request: request, navMinutesToArrival: navMinutesToArrival)
        )
    }
}

/// Applies the ride-request sheet chrome UNLESS the content is hosted inside the
/// `PanSheet` engine (MYR-271), where the engine surface provides the wash.
private struct TrackingChrome: ViewModifier {
    let hosted: Bool
    func body(content: Content) -> some View {
        if hosted {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.rideRequestSheetChrome()
        }
    }
}

/// A plain vertical line filling its proposed rect — stroked dashed by
/// `RideRequestTrackingContent.connector` for the pre-pickup itinerary segment.
private struct RideConnectorDash: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        return path
    }
}
