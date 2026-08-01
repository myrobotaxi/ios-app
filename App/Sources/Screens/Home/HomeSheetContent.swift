import SwiftUI
import DesignSystem

// MARK: - Bottom-sheet hero content (MYR-167 deliverable 3, MYR-168,
// design/app/screens.jsx:439-599)
//
// Two hero states, matching `HomeScreen`'s `driving ? DrivingSheetContent :
// ParkedSheetContent`. Both append the real `VehicleControls` tile stack
// (MYR-168).
//
// MYR-236 round 5.3 — CROSSFADE MODEL, NO RESERVE BAND. Rounds 4/5 shipped a
// "peek-fold reserve" (`peekRevealHeight`/`collapseReserve`) that anchored the
// controls at a fold and collapsed the band only at the half settle-commit.
// That produced the two client bugs this round fixes: (a) a mid-drag gap that
// snapped closed at settle ("weird gap as soon as I drag… then correct
// immediately after"), and (b) fold-math letting the controls poke above the
// physical bottom at peek ("widgets of the lock, trunk… poking up right below
// the floating menu").
//
// The reserve model is GONE. The sheet now rides the shared `PanSheet`
// crossfade engine exactly like the rider idle↔search sheet
// (`RiderIdleSearchSheet`): two layers are hosted simultaneously and the engine
// crossfades their alphas from the drag PROGRESS at the UIKit layer.
//   • LOW layer (peek): the summary hero ONLY (`DrivingSummary`/`ParkedSummary`)
//     — laid out at the top, nothing beneath it. At rest-peek the high layer is
//     at alpha 0, so nothing pokes below the summary (bug (a) fixed).
//   • HIGH layer (half): the FULL dense content (summary + divider/route +
//     controls…), ONE scrollable block, no reserved band anywhere (bug about
//     the awkward half gap fixed).
// The summary renders at the SAME position in both layers (identical pixels,
// identical padding), so the crossfade reads as "controls fade in beneath a
// stationary summary," not a content swap — and because the alphas ride the
// drag from the first pixel, the controls fade in continuously with no gap that
// snaps shut at settle (bug (b) fixed). See `MRTDetentSheet`'s crossfade
// initializer and `HomeScreen`'s peek/expanded builders.

// MARK: - What the driving hero may render (MYR-294 — CLIENT-DIRECTED)
//
// The client, watching the first build of this issue on a simulator: *"why are
// you skeleton loading when no route that looks so weird and useless"*, and then
// the rule itself: *"if no route then no need to show a route, if a route is
// about to arrive then sure thats fine bc we're loading something"*.
//
// The first cut rendered an `MRTSkeletonBar` in the destination slot whenever
// navigation was on without a name, on the reasoning that Tesla usually sends
// `DestinationName` within ~60s. He is right and that reasoning was wrong: **a
// skeleton is a promise that something is arriving, and the client is not
// fetching anything.** `DestinationName` is a value Tesla either pushes or does
// not; there is no request in flight, no deadline, and nothing to time out — so
// the shimmer had no honest end state and would sit there indefinitely on a car
// whose name never came.
//
// THE RULE, as he stated it: the test is *"is a fetch actually running"*, not
// "might we have a route someday".
//   • Route/nav data ABSENT → render NO route UI at all. No progress bar, no leg
//     rows, no placeholder lines, nothing that implies a route exists. Facts we
//     genuinely hold (the speed, the car's own street) stay, as plain text.
//   • A fetch GENUINELY IN FLIGHT may shimmer — and must still resolve or time
//     out to an honest state.
//
// Nothing in this hero is in the second category, so **this type has no
// placeholder case at all** and `DrivingHeroElementTests` asserts that it never
// grows one. (The MYR-293 route fetch on the owner MAP is the second category and
// is already bounded — `AppleRideRouteProvider.deadline` is 8s and the honest end
// state is pins with no line. It draws no shimmer either, because "absent" and
// "in flight" look the same from the map's side and the stricter rule is safe.)

/// One element of the driving hero. The set is a pure function of the wire, so
/// what the hero shows can be asserted without rendering it — and every element
/// is a REAL statement about the car, with no stand-in for a missing one.
enum DrivingHeroElement: CaseIterable, Sendable {
    /// The destination's name, at hero size. Only when the wire actually named it.
    case destinationTitle
    /// The live speed. Always present; it is the headline when nothing else is.
    case speed
    /// "Arriving in N min" + "ETA h:mm".
    case arrival
    /// The car's own current street — the honest answer to "where is it" when
    /// there is no journey to describe.
    case location
    /// The trip progress bar.
    case progressBar
    /// The dense layer's Route section (label + both legs).
    case routeSection

    /// The whole rule, in one place.
    ///
    /// - `destinationTitle` / `routeSection`: need a NAMED destination. The Route
    ///   section is a two-ended statement and an unnameable second end leaves
    ///   nothing to list, so the section goes rather than showing a dot with a
    ///   placeholder beside it.
    /// - `arrival`: needs active navigation AND a real `etaMinutes`. The
    ///   snapshot's ETA is a non-optional `Int` collapsing an absent wire value to
    ///   0 (`VehicleContractMapping`), which used to render as "Arriving in 0 min"
    ///   beside an "ETA" of `Date() + 0` — i.e. now. 0 is reachable even with
    ///   navigation genuinely on, because `etaMinutes` may arrive apart from its
    ///   nav siblings inside the server's 500ms accumulation window.
    /// - `progressBar`: needs active navigation AND a real progress fraction.
    ///   `TripProgressBar` CLAMPS to 0.05, so a 0 progress draws its orb 5% along
    ///   a journey — a fabricated position, and on a car with no navigation a
    ///   fabricated journey as well.
    /// - `location`: exactly when the hero would otherwise have nothing but a
    ///   speed — no destination to name AND no arrival to state. It is the
    ///   fallback subject, not an extra line: with a live trip the hero's subject
    ///   IS the trip, and the car's own street is the Route section's origin leg.
    ///   Stating it as "there is nothing else to say" rather than "navigation is
    ///   off" is what keeps this to TWO peek bands — see
    ///   ``HomeScreen/peekBase(vehicle:snapshot:)``, which switches on this very
    ///   element.
    static func resolve(navigation: DrivingNavigation, etaMinutes: Int, progress: Double) -> Set<DrivingHeroElement> {
        var elements: Set<DrivingHeroElement> = [.speed]
        if navigation.destinationName != nil {
            elements.insert(.destinationTitle)
            elements.insert(.routeSection)
        }
        if navigation.isActive, etaMinutes > 0 { elements.insert(.arrival) }
        if navigation.isActive, progress > 0 { elements.insert(.progressBar) }
        if !elements.contains(.destinationTitle), !elements.contains(.arrival) {
            elements.insert(.location)
        }
        return elements
    }
}

// MARK: - Summary heroes (the LOW crossfade layer / peek)

/// screens.jsx:439-499 `DrivingSheetContent` summary — the status row +
/// destination/speed/ETA + progress bar. This is the peek hero AND the top of
/// the dense half layout (same pixels in both).
struct DrivingSummary: View {
    let vehicle: Vehicle
    let trip: DrivingTrip
    let snapshot: VehicleTelemetrySnapshot
    /// MYR-315 — the tappable recency stamp, appended beneath the hero. `nil` on
    /// the simulated path (and in previews), where the hero is unchanged.
    var freshness: VehicleFreshnessStampModel? = nil

    /// MYR-294 — the car's current place, shown INSTEAD of a destination when
    /// there is no navigation. `nil` in the simulated hero (which always has a
    /// destination) and whenever the wire gave us no location name.
    var currentLocation: String? = nil

    private var rangeMi: Int { Int(((snapshot.batteryPercent / 100) * 272).rounded()) }

    private var arrivalTime: String {
        let date = Date().addingTimeInterval(Double(snapshot.etaMinutes) * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private var elements: Set<DrivingHeroElement> {
        DrivingHeroElement.resolve(
            navigation: trip.navigation,
            etaMinutes: snapshot.etaMinutes,
            progress: snapshot.progress
        )
    }

    var body: some View {
        // Every row below is present IFF `DrivingHeroElement.resolve` says the
        // wire supports it. Nothing here has a placeholder arm: see that type's
        // header for the client's rule.
        let elements = elements
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                statusRow
                VStack(spacing: 10) {
                    headlineRow(elements)
                    if elements.contains(.arrival) { arrivalRow }
                    if elements.contains(.location), let currentLocation { locationRow(currentLocation) }
                }
            }

            if elements.contains(.progressBar) {
                TripProgressBar(progress: snapshot.progress, compact: true)
            }
        }
        .mrtFreshnessStamp(freshness)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Unchanged in every navigation state — "● Driving · {name}" plus range. It
    /// is the one line that is true whatever the car is or isn't navigating to,
    /// which is why the honest hero is built around it rather than replacing it.
    private var statusRow: some View {
        HStack {
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.mrtDriving)
                    .frame(width: 7, height: 7)
                    .shadow(color: .mrtDriving.opacity(2.0 / 3.0), radius: 3.5)
                Text("Driving")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mrtText)
                Text("· \(vehicle.name)")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            Spacer()
            HStack(spacing: 6) {
                MiniBattery(pct: snapshot.batteryPercent)
                (Text("\(rangeMi)")
                    .foregroundStyle(Color.mrtTextSec)
                    + Text(" mi").foregroundStyle(Color.mrtTextMuted))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
        }
    }

    /// The hero line: the destination when there IS one, otherwise the speed
    /// promoted into the slot the design gives to the trip's most important fact.
    /// The speed keeps its own 27/12 treatment either way — it is moved, never
    /// restyled — and there is no third, placeholder rendering.
    @ViewBuilder
    private func headlineRow(_ elements: Set<DrivingHeroElement>) -> some View {
        HStack(alignment: .lastTextBaseline) {
            if elements.contains(.destinationTitle), let name = trip.destinationName {
                Text(name)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.8)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                speedReadout
            } else {
                speedReadout
                Spacer(minLength: 12)
            }
        }
    }

    private var speedReadout: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(snapshot.speedMPH)")
                .font(.system(size: 27, weight: .semibold))
                .tracking(-0.8)
                .monospacedDigit()
                .foregroundStyle(Color.mrtText)
            Text("mph")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .fixedSize()
    }

    private var arrivalRow: some View {
        HStack(alignment: .firstTextBaseline) {
            (Text("Arriving in ")
                .foregroundStyle(Color.mrtTextSec)
                + Text(RideDuration.text(minutes: snapshot.etaMinutes))
                .foregroundStyle(Color.mrtText)
                .fontWeight(.semibold))
                .font(.system(size: 15))
            Spacer()
            Text("ETA \(arrivalTime)")
                .font(.system(size: 14))
                .monospacedDigit()
                .foregroundStyle(Color.mrtTextMuted)
        }
    }

    /// Where the car is right now — the PARKED hero's own location line
    /// (`ParkedSummary`, 12pt `mrtText`), reused rather than restyled, because it
    /// is the same kind of statement about the same kind of fact.
    private func locationRow(_ label: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color.mrtText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
    }
}

/// screens.jsx:522-599 `ParkedSheetContent` summary — name/badge/battery/
/// address. The peek hero AND the top of the dense half layout.
struct ParkedSummary: View {
    let vehicle: Vehicle
    let location: ParkedLocation
    let snapshot: VehicleTelemetrySnapshot
    /// The design badge state for the status row. Defaults to `.parked` so the
    /// simulated M1 hero is unchanged; the live path (MYR-201) passes the real
    /// wire status so a charging/offline vehicle shows the matching badge.
    var status: MRTVehicleStatus = .parked
    /// MYR-315 — see `DrivingSummary.freshness`.
    var freshness: VehicleFreshnessStampModel? = nil
    /// MYR-316 — "Estimated completion \u{00B7} Sat ~2:00 PM", or `nil` to render
    /// NOTHING. Non-nil only when the badge above it says In Service AND the
    /// server resolved a window (`VehicleServiceWindow.completionLine`), which is
    /// the whole gate: an in-service car with no known estimate — the COMMON case,
    /// since Tesla has no appointment record for most visits — renders exactly as
    /// it did before this issue, with no "unknown" and no placeholder.
    ///
    /// Always nil on the simulated path (nothing there is in service and the
    /// simulated snapshot carries no window), so every drift-gate scene is
    /// byte-identical.
    var serviceCompletion: String? = nil

    /// MYR-333 — the hero's charge caption, or `nil` to render NOTHING.
    ///
    /// Only the two states the owner can act on the meaning of get words. Every
    /// other wire value (`Disconnected`, `Stopped`, `NoPower`, `Starting`,
    /// `Unknown`, an unrecognized value, and `null`) collapses to `.idle`
    /// upstream and renders exactly as the hero did before this issue — no
    /// "Not charging", no placeholder, no em dash. A parked car saying nothing
    /// about charging is the correct and quiet default; only a live session, or
    /// a session that just finished, is worth a word.
    ///
    /// Kept SHORT on purpose. This sits inline with the percentage in a row that
    /// also carries the vehicle name and its status badge, so a long phrase
    /// would eat the name. "Charging" is one word; "Charge complete" is the
    /// shortest honest way to say a session ENDED rather than is running.
    private var chargeCaption: String? {
        switch snapshot.chargingState {
        case .charging: return "Charging"
        case .complete: return "Charge complete"
        case .idle: return nil
        }
    }

    /// MYR-333 — the bar treatment, derived from the same one field. Split out
    /// so the mapping from wire state to DesignSystem treatment lives beside the
    /// caption it must agree with: a bar that pulses while the caption says
    /// "Charge complete" would be the exact kind of half-true state this issue
    /// exists to remove.
    private var batteryCharge: MRTBatteryCharge {
        switch snapshot.chargingState {
        case .charging: return .charging
        case .complete: return .complete
        case .idle: return .none
        }
    }

    /// The elapsed-since-parked label, or `nil` when the park-start is unknown
    /// (live path — no contracted park-start; MYR-268) so the view omits it
    /// rather than showing a fabricated "0m" that reads like "0 meters".
    private var parkedDuration: String? {
        guard let parkedSince = location.parkedSince else { return nil }
        let seconds = max(0, Date().timeIntervalSince(parkedSince))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // MYR-316/318 — the HERO HEADER: the vehicle name, its status badge,
            // the charge figure, and (when there is one) the estimated completion.
            //
            // MYR-319 — the completion line is part of THIS block, not a sibling of
            // the battery bar below it. It used to sit in the summary's flat 8pt
            // stack, which put it an equal distance from the header above and the
            // bar below — visually unattached, reading as a caption on the charge
            // rather than on the In Service badge that gives it its meaning, and
            // the client's "estimated completion should be at the TOP of the owner
            // bottom sheet". Grouped at 2pt it is unambiguously the header's own
            // second line, the first thing in the sheet, and still visible at peek.
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    HStack(spacing: 10) {
                        Text(vehicle.name)
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                            // MYR-333 — the name is the ONE elastic element in
                            // this row now that a charge caption can sit on the
                            // right. Everything else is fixedSize, so a long
                            // name truncates instead of squeezing the badge or
                            // wrapping the row. "Lunar" and every other fixture
                            // name is far short of the limit, so the simulated
                            // scenes are pixel-identical.
                            .lineLimit(1)
                            .truncationMode(.tail)
                        StatusBadge(status)
                    }
                    Spacer(minLength: 8)
                    // MYR-333 — the charge caption sits IMMEDIATELY BEFORE the
                    // percentage, so the hero reads left-to-right as
                    // "Charging · 76 %" (the issue's own wording) with no new
                    // line and no new vertical space. That placement is the
                    // point: the client's complaint was that the number kept
                    // climbing with nothing to explain WHY, and the explanation
                    // belongs next to the number it explains rather than as a
                    // detached caption elsewhere in the sheet.
                    //
                    // It is a SEPARATE signal from the status badge on the left,
                    // deliberately: a car charging at a service centre is
                    // `in_service` on the wire — `status` cannot say "charging"
                    // and "in service" at once — so the badge keeps saying
                    // In Service while this says Charging, and both are true.
                    if let chargeCaption {
                        Text(chargeCaption)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.mrtBatHigh)
                            .lineLimit(1)
                            .fixedSize()
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(Int(snapshot.batteryPercent.rounded()))")
                            .font(.system(size: 18))
                            .monospacedDigit()
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                        Text("%")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mrtTextMuted)
                    }
                    .fixedSize()
                }
                // Gated on BOTH the In Service badge and a resolved window
                // upstream (`VehicleServiceWindow.completionLine`), so honest
                // absence is unchanged: an in-service car with no known estimate
                // — the COMMON case, since Tesla holds no appointment record for
                // most visits — renders this block exactly as it did before, with
                // no placeholder and no "unknown".
                if let serviceCompletion {
                    Text(serviceCompletion)
                        // 12pt muted — the SAME treatment as this hero's location
                        // line below, because it is the same kind of thing: a quiet
                        // qualifier on the headline. Deliberately NOT the design's
                        // `.label()` eyebrow style, which uppercases at 1.2
                        // tracking: that vocabulary belongs to SECTION HEADINGS,
                        // and using it here made a footnote about one car read as a
                        // heading for everything under it.
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextMuted)
                        .lineLimit(1)
                }
            }
            // MYR-333 — the client's own words: "the bar should be a clean
            // pulsing green animation when that happens". `charge` is the ONLY
            // thing added here; `.none` (every pre-existing path, simulated and
            // live) resolves to the exact bar this line drew before.
            BatteryBar(pct: snapshot.batteryPercent, charge: batteryCharge)
            HStack {
                Text(location.label)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if let parkedDuration {
                    Text(parkedDuration)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextMuted)
                        .fixedSize()
                }
            }
        }
        .mrtFreshnessStamp(freshness)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dense heroes (the HIGH crossfade layer / half)

/// screens.jsx:439-499 `DrivingSheetContent` — the summary followed by the
/// route + `VehicleControls`, one dense scrollable block (no reserve band).
struct DrivingHeroContent: View {
    let vehicle: Vehicle
    let trip: DrivingTrip
    let snapshot: VehicleTelemetrySnapshot
    let executor: any VehicleCommandExecutor
    @Binding var isEditingPlate: Bool
    /// MYR-301 — routes a command re-link notice to the Tesla link flow (see
    /// `VehicleControls.onRelinkTesla`).
    var onRelinkTesla: (() -> Void)? = nil
    /// MYR-264 — gates `VehicleControls`' fixture media block (now-playing
    /// title/artist/cover are not on the wire → honest-hidden on live). `false` in
    /// SIM keeps the media section pixel-identical.
    var isLive: Bool = false
    /// MYR-315 — the SAME stamp model the peek layer gets. It must be passed here
    /// too: the crossfade hosts both layers at once and dissolves between them, so
    /// a summary that differed by one line between the layers would visibly tear
    /// mid-drag (MYR-236 round 5.3).
    var freshness: VehicleFreshnessStampModel? = nil

    /// MYR-294 — see `DrivingSummary.currentLocation`.
    var currentLocation: String? = nil

    var body: some View {
        // Outer gap 22 (screens.jsx:449 `gap: 22`) between the summary block and
        // the route/controls reveal block; the reveal block itself is gap 0 with
        // the `Divider pad={8}` supplying the inner spacing (screens.jsx:490-497).
        VStack(alignment: .leading, spacing: 22) {
            // Summary — rendered identically to the peek `DrivingSummary` so the
            // crossfade reads as a stationary summary with controls fading in
            // beneath it (MYR-236 round 5.3).
            DrivingSummary(
                vehicle: vehicle,
                trip: trip,
                snapshot: snapshot,
                freshness: freshness,
                currentLocation: currentLocation
            )

            VStack(alignment: .leading, spacing: 0) {
                // MYR-294 (CLIENT-DIRECTED) — the ROUTE section is a statement
                // about a journey with two ends, so it renders only when the wire
                // NAMED the far one (`DrivingHeroElement.routeSection`). No
                // navigation, or navigation whose destination has no name, and the
                // whole block goes: the "Route" label and both legs.
                //
                // It emphatically does NOT degrade to a dot with a placeholder
                // beside it. That is what the first cut did and what the client
                // rejected on sight — *"if no route then no need to show a
                // route"* — and it was also the stacked-chrome-for-no-content
                // shape MYR-347 was about.
                //
                // The DIVIDER is outside the condition: it is the section break
                // between the summary and the controls (the parked hero has one
                // too), not part of the route block.
                Divider().overlay(Color.mrtBorder).padding(.vertical, 8)
                if let destinationTitle = DrivingRouteLegTitle.compose(
                    city: trip.destinationCity, name: trip.destinationName
                ) {
                    Text("Route").mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted).padding(.bottom, 8)
                    RouteLeg(title: trip.originLabel, subtitle: trip.originAddress, color: .mrtDriving, isFirst: true, isLast: false)
                    RouteLeg(
                        // MYR-294 — joined from the parts that EXIST. It was
                        // `"\(city) · \(name)"` unconditionally, and `city` is
                        // derived from `destinationAddress`, which is snapshot-only
                        // and never live-broadcast — so on a real trip this row
                        // read "· Local Creamery", a separator with nothing on its
                        // left. The client: *"I don't like the dot next to the
                        // destination."*
                        title: destinationTitle,
                        subtitle: trip.destinationAddress,
                        color: .mrtGold,
                        isFirst: false,
                        isLast: true
                    )
                }
                VehicleControls(
                    vehicle: vehicle,
                    driving: true,
                    batteryPercent: snapshot.batteryPercent,
                    parkedLocation: nil,
                    executor: executor,
                    isEditingPlate: $isEditingPlate,
                    cabinTemp: snapshot.interiorTempF,
                    extTemp: snapshot.exteriorTempF,
                    odometerMiles: snapshot.odometerMiles,
                    fsdMilesSinceReset: snapshot.fsdMilesSinceReset,
                    lastUpdated: snapshot.lastUpdated,
                    isStreaming: snapshot.isStreaming,
                    onRelinkTesla: onRelinkTesla,
                    isLive: isLive,
                    // MYR-303 — the live now-playing block (nil in SIM).
                    nowPlaying: snapshot.nowPlaying
                )
            }
        }
    }
}

/// screens.jsx:522-599 `ParkedSheetContent`, `style: 'floating'` branch only
/// — the app's single shipped `parkedStyle` (see `VehicleFixtures.swift`
/// header comment and Metrics.swift `homePeekHeightParked`). Summary followed
/// by `VehicleControls`, one dense block (no reserve band).
struct ParkedHeroContent: View {
    let vehicle: Vehicle
    let location: ParkedLocation
    let snapshot: VehicleTelemetrySnapshot
    /// The design badge state for the status row. Defaults to `.parked` so the
    /// simulated M1 hero is unchanged; the live path (MYR-201) passes the real
    /// wire status so a charging/offline vehicle shows the matching badge.
    var status: MRTVehicleStatus = .parked
    let executor: any VehicleCommandExecutor
    @Binding var isEditingPlate: Bool
    /// MYR-301 — see `DrivingHeroContent.onRelinkTesla`.
    var onRelinkTesla: (() -> Void)? = nil
    /// MYR-264 — see `DrivingHeroContent.isLive`.
    var isLive: Bool = false
    /// MYR-315 — see `DrivingHeroContent.freshness`.
    var freshness: VehicleFreshnessStampModel? = nil
    /// MYR-316 — the SAME line the peek layer gets, for the same crossfade reason
    /// `freshness` is threaded here: both layers are hosted at once and dissolved
    /// into each other, so a summary differing by one line between them would
    /// visibly tear mid-drag (MYR-236 round 5.3).
    var serviceCompletion: String? = nil
    /// MYR-316 — opens the "Expected back" entry sheet. `nil` in previews.
    var onEditServiceWindow: (() -> Void)? = nil
    /// MYR-316 — the RESOLVED service window, threaded from `HomeScreen`'s single
    /// `resolvedServiceWindow(snapshot:)` call rather than re-read from the
    /// snapshot here. Reading `snapshot.serviceEstimatedEndAt` at this call site is
    /// precisely the defect that shipped: the snapshot is snapshot-only by contract
    /// and does not carry a just-saved value, so the row (and the hero line, which
    /// had the same bug) kept showing the pre-save state.
    var serviceEstimatedEndAt: Date? = nil
    // MYR-369 — the ride-share position and its write no longer travel through
    // here: the switch moved to the Share tab, which reads §7.18's field straight
    // off the vehicle list it already fetches and needs nothing threaded through
    // the owner sheet.

    var body: some View {
        // Outer gap 14 (screens.jsx:585 `gap: 14`) between the summary and the
        // controls reveal.
        VStack(alignment: .leading, spacing: 14) {
            // Summary — rendered identically to the peek `ParkedSummary` so the
            // crossfade reads as a stationary summary with controls fading in
            // beneath it (MYR-236 round 5.3).
            ParkedSummary(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                status: status,
                freshness: freshness,
                serviceCompletion: serviceCompletion
            )

            VehicleControls(
                vehicle: vehicle,
                driving: false,
                batteryPercent: snapshot.batteryPercent,
                parkedLocation: location,
                executor: executor,
                isEditingPlate: $isEditingPlate,
                cabinTemp: snapshot.interiorTempF,
                extTemp: snapshot.exteriorTempF,
                odometerMiles: snapshot.odometerMiles,
                fsdMilesSinceReset: snapshot.fsdMilesSinceReset,
                lastUpdated: snapshot.lastUpdated,
                isStreaming: snapshot.isStreaming,
                onRelinkTesla: onRelinkTesla,
                isLive: isLive,
                // MYR-303 — the live now-playing block (nil in SIM).
                nowPlaying: snapshot.nowPlaying,
                // MYR-316 — the real badge (so the Status chip can say In Service)
                // and the expected-back entry route. Both default to their
                // pre-MYR-316 values on the simulated path.
                badgeStatus: status,
                onEditServiceWindow: onEditServiceWindow,
                serviceEstimatedEndAt: serviceEstimatedEndAt,
                // MYR-333 — read off the SAME snapshot the hero's bar and caption
                // use, so the tile sub can never disagree with the bar above it.
                chargingState: snapshot.chargingState,
            )
        }
    }
}

/// MYR-294 — the destination leg's title, composed from the parts that exist.
///
/// The prototype interpolates `"{city} · {name}"` with two literals, so it never
/// meets an absent half. The wire does, constantly: `destinationAddress` (which
/// `city` is parsed out of) is snapshot-only — the telemetry writer persists it
/// but does not put it on the navigation group's live broadcast — so on a
/// WS-driven trip the name is present and the city is not, and the row rendered
/// a leading separator over nothing.
///
/// Pure and public-to-tests so the join is asserted rather than eyeballed: a
/// separator may exist only BETWEEN two present parts.
enum DrivingRouteLegTitle {
    static func compose(city: String?, name: String?) -> String? {
        let parts = [city, name]
            .compactMap { $0 }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// screens.jsx:501-520 `RouteLeg` — a connected-dot timeline row.
private struct RouteLeg: View {
    /// Always a real label. A leg with nothing to name is not rendered at all —
    /// its whole SECTION is dropped (MYR-294, client-directed), so this row has no
    /// placeholder arm to reach.
    let title: String
    /// `nil`/blank — no second line at all. It used to render unconditionally, so
    /// a live leg with no address carried an empty 12pt line: a gap that looks
    /// like a layout bug and reads as missing content (MYR-294).
    let subtitle: String?
    let color: Color
    let isFirst: Bool
    let isLast: Bool

    private var resolvedSubtitle: String? {
        guard let subtitle, !subtitle.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return subtitle
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                if !isFirst {
                    Rectangle().fill(Color.mrtBorder).frame(width: 1, height: 6)
                }
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
                    .shadow(color: color.opacity(0.4), radius: 4)
                if !isLast {
                    Rectangle().fill(Color.mrtBorder).frame(width: 1).frame(minHeight: 14)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                if let resolvedSubtitle {
                    Text(resolvedSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 6)
    }
}
