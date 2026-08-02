import CoreLocation
import SwiftUI
import DesignSystem

// MARK: - RideRequestSummaryContent (MYR-171, design/app/ride-request.jsx
// RideSummaryContent 909-1005)
//
// Takes over the full screen (`RideRequestSheetChrome(isSummary: true)`) —
// "the ride's done, a full page feels like a destination" per the jsx's own
// comment (ride-request.jsx:1119).
struct RideRequestSummaryContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: any RideRequestService
    var historyStore: RideHistoryStore
    var riderName: String
    /// MYR-224 — the real signed-in rider on the LIVE path, else nil (SIM keeps
    /// the fixture "Sam"). The "Have a wonderful {part of day}, {first}" sign-off
    /// personalizes to the rider who took the ride.
    var liveProfile: UserProfile? = nil
    /// MYR-414/MYR-422 — the hero's road geometry AND its length, or `nil`.
    ///
    /// Resolved by `SharedViewerScreen` through `RideSummaryRoute`'s ladder (the
    /// car's own driven track → the MKDirections road route → nothing), so a value
    /// here is real road geometry by construction — `RideRoutePolyline.isReal` has
    /// already refused every straight `[from, to]` pair — and its `miles` is a real
    /// trip distance. `nil` in SIM and whenever both rungs came up empty.
    var heroRoute: RideSummaryHeroRoute? = nil
    /// MYR-414 — the ONE resolved `AppMode` for this screen
    /// (`SharedViewerState.resolvesLiveRideSummary`), threaded by the call site
    /// like every other live gate in this flow. SIM keeps the prototype's stat
    /// strip, its tip section and its placeholder hero line verbatim.
    var isLive: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tip: String?

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    /// MYR-264 — the "You rode in" card must name the LIVE vehicle in live mode
    /// (same source MYR-212 threads through Review/Booking/Tracking:
    /// `viewerState.liveFleetMember`), not the fixture fleet. On live, the record's
    /// `fleetMemberID` is a real vehicle id that matches no fixture, so
    /// `input.fleetMember` would fall back to `fleet[0]` ("Quicksilver Model Y" /
    /// "RBO-2046") — a fixture leak. `nil` in sim → the fixture member, unchanged.
    private var fleetMember: FleetMember { viewerState.liveFleetMember ?? request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var destination: RidePlace { request?.input.destination ?? RideRequestFixtures.recentPlaces[0] }
    private var pickup: RidePlace? { request?.input.pickup }
    private var passenger: RidePassenger? { request?.input.passenger }

    private var partOfDay: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case ..<12: "morning"
        case ..<18: "afternoon"
        default: "evening"
        }
    }

    /// The rider first name for the sign-off, or `nil` for a name-less live
    /// account (→ a generic sign-off with no name). SIM keeps the fixture-derived
    /// behavior (`riderName` "Sam", or the ride's passenger).
    private var greetingFirstName: String? {
        // LIVE (MYR-224): the real signed-in rider — or nil (generic greeting) when
        // that account has no name. Never the fixture "Sam".
        if let profile = liveProfile { return profile.firstName }
        // SIM: the fixture rider name (or the ride's passenger). MYR-264 — dropped
        // the hardcoded "Sam" fallback so no fixture persona literal can reach the
        // live path; the sim `riderName` is non-empty ("Sam"), so this is unchanged.
        if !riderName.isEmpty { return riderName.split(separator: " ").first.map(String.init) ?? riderName }
        if let name = passenger?.name, !name.isEmpty { return name.split(separator: " ").first.map(String.init) ?? name }
        return nil
    }

    /// "Have a wonderful {part of day}, {first}." — or, with no name, the same
    /// warm line without a trailing name (never "…, ." — MYR-224).
    private var summaryGreeting: String {
        if let first = greetingFirstName { return "Have a wonderful \(partOfDay),\n\(first)." }
        return "Have a wonderful \(partOfDay)."
    }

    // MARK: MYR-414 — one resolution for every claim this screen makes

    /// The whole honesty decision, resolved once. See `RideSummaryPresentation`
    /// for why each live arm is gated on its own datum.
    private var presentation: RideSummaryPresentation {
        RideSummaryPresentation.resolve(
            isLive: isLive,
            // The SIM arm's inputs: the destination's QUOTED estimate, which is
            // what this screen used to render on both paths.
            estimateMinutes: destination.minutes,
            estimateMiles: destination.miles,
            tripMinutes: RideTripSpan.minutes(
                enrouteObservedAt: request?.enrouteObservedAt,
                completedAt: request?.completedAt
            ),
            // MYR-422 — the length travels WITH the polyline (`RideSummaryHeroRoute`)
            // rather than being re-derived here: a Tesla-driven track is decimated
            // for drawing and must be measured before that, and one optional feeding
            // both keeps MYR-414's "the line and the tile are refused together"
            // invariant structural.
            roadRouteMiles: heroRoute?.miles,
            completedAt: request?.completedAt
        )
    }

    /// "Arrived · 3:42 PM" from the ride's own completion instant — or a bare
    /// "Arrived" when there is none.
    ///
    /// MYR-414: this line used to stamp `Date()`, i.e. the moment the VIEW was
    /// composed, on every path. That reads correctly the instant the summary
    /// appears and becomes a small lie the moment the rider leaves it up, and it
    /// is a fabrication outright on a summary re-entered later. SIM keeps `Date()`
    /// (`presentation.arrivedAt` is `now` there), so the drift-gate scene is
    /// unchanged.
    private var arrivedEyebrow: String {
        guard let arrivedAt = presentation.arrivedAt else { return "Arrived" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return "Arrived \u{00B7} \(f.string(from: arrivedAt))"
    }

    private static let tipQuips: [String: String] = [
        "$3": "Your robotaxi beeped happily, then remembered it runs on electrons, not gratitude.",
        "$5": "The steering wheel would thank you \u{2014} if it had one.",
        "$8": "$8?! It\u{2019}s blushing in binary: 01110100 01111000.",
        "Custom": "There\u{2019}s no driver back there. Just vibes and 4,000 TOPS of compute.",
    ]

    // MYR-197 fix: the jsx wraps this whole screen in `display:flex,
    // flexDirection:'column', flex:1, minHeight:'100%'` with the map card
    // itself `flex:1, minHeight:150` (ride-request.jsx:945,956) — the map
    // grows to absorb whatever vertical space the rest of the content
    // doesn't need, so the page always reaches the true bottom edge exactly
    // once, no scrolling. The Swift port previously used a `ScrollView` +
    // a fixed `mapCard.frame(height: 220)`, which left a dead gap below
    // "See you soon" on any device taller than the fixed content (client
    // QA, MYR-197: "not filling the page — visible gap at the bottom").
    // `GeometryReader` here reports the true full-bleed height (this phase
    // ignores the bottom safe area via `rideRequestSheetChrome(isSummary:
    // true)`, and `ScrollView`'s absence is intentional — same as the jsx,
    // this never needs to scroll because the map absorbs the remainder);
    // `mapCard`'s own `.frame(minHeight:150, maxHeight:.infinity)` (see
    // below) is what actually grows, matching the jsx's `flex:1` 1:1.
    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                RideEyebrowText(text: arrivedEyebrow, color: Color.mrtGold.opacity(0.6), size: 10)
                    .padding(.bottom, 12)

                Text(summaryGreeting)
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.5)
                    .lineSpacing(4)
                    .mrtTextShimmer(duration: 3.6)
                    .padding(.bottom, 24)

                mapCard
                    .padding(.bottom, 20)

                // MYR-414 — a strip with no true stat in it renders NOTHING, and
                // spends none of its 18pt either. An empty band under the hero
                // would be the stacked-chrome-for-no-content shape MYR-347 was
                // about; the map (`flex:1`) simply takes the room back.
                if !presentation.tiles.isEmpty {
                    RideSummaryStatsStrip(tiles: presentation.tiles)
                        .padding(.bottom, 18)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        RideEyebrowText(text: "You rode in", size: 9.5)
                        // MYR-199 fix: jsx (ride-request.jsx:989) headlines
                        // on the paint-color nickname + model name alone —
                        // `{carColor} {carName}` (e.g. "Quicksilver Model
                        // Y"), no year/make subline here (unlike Booking/
                        // Tracking's rows) — this was rendering "{model}
                        // {name}" instead.
                        Text("\(fleetMember.colorName) \(fleetMember.name)")
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                    }
                    Spacer(minLength: 0)
                    // MYR-264/218 — live telemetry has no license plate (only a VIN
                    // last-4, hidden when empty); a fixture plate is always present,
                    // so sim always shows the chip.
                    if !fleetMember.plate.isEmpty {
                        RidePlateChip(plate: fleetMember.plate)
                    }
                }
                .padding(.top, 16)
                .overlay(alignment: .top) {
                    Rectangle().fill(Color.mrtGold.opacity(Double(0x1F) / 255.0)).frame(height: MRTMetrics.hairline)
                }
                .padding(.bottom, 22)

                // MYR-414 — "Tip your driver" is SIM-only now. It goes nowhere (no
                // tipping backend exists), and it says "driver" on a product whose
                // whole premise is that there isn't one. MYR-288/MYR-344's
                // no-dead-affordances precedent; the prototype's joke card stays in
                // SIM, where it is a joke rather than an offer.
                if presentation.offersTip {
                    tipSection
                        .padding(.bottom, 22)
                }

                MRTButton("See you soon", variant: .outlineDraw, action: finish)
            }
            .padding(.horizontal, 22)
            .padding(.top, 76)
            .padding(.bottom, 30)
            .frame(minHeight: geo.size.height, alignment: .top)
        }
        .rideRequestSheetChrome(isSummary: true)
        .overlay {
            if let tip {
                tipSlideUpCard(tip)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: tip)
    }

    // MARK: Map card (ride-request.jsx:950-963)

    /// The hero's polyline: the ride's REAL road geometry when the ladder found any
    /// (the car's driven track, else MKDirections), else the two endpoints — which
    /// are drawn as PINS ONLY (`drawsLine: false`), never as the straight line
    /// between them.
    ///
    /// MYR-414/MYR-293. The endpoint pair is still handed over when there is no
    /// route because the pickup and the drop-off are facts: they are what the
    /// camera frames and what the two dots sit on. Only the LINE is withheld.
    private var mapPolyline: [CLLocationCoordinate2D] {
        heroRoute?.polyline ?? [pickup?.coordinate ?? DriveFixtures.financialDistrict, destination.coordinate]
    }

    /// "from Sansome & Clay" — plus the trip's MEASURED distance when the ladder
    /// found real geometry.
    ///
    /// MYR-422: the distance was MYR-414's second stat tile and cannot stay one now
    /// that the client's two placeholders are back — a four-tile row measures 363.3pt
    /// against a 331/349pt band (`RideSummaryStripLayoutTests`). This is where it
    /// goes instead: a suffix on a line that already exists, inside the card whose
    /// polyline it is the length of, so the number and the line it measures are read
    /// together. It appears on exactly the same fact the line does
    /// (`heroDistanceMiles`), and `nil` in SIM leaves the prototype's caption
    /// byte-identical.
    private var heroFromLine: String {
        let from = "from \(pickup?.label ?? "Current location")"
        guard let miles = presentation.heroDistanceMiles else { return from }
        return "\(from) \u{00B7} \(String(format: "%.1f", miles)) mi"
    }

    private var mapCard: some View {
        ZStack(alignment: .bottomLeading) {
            RideRequestRouteMap(
                route: mapPolyline,
                progress: 1,
                drawsLine: presentation.drawsRouteLine
            )
            LinearGradient(
                stops: [.init(color: .clear, location: 0.32), .init(color: Color.mrtBg.opacity(0.94), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 4) {
                RideEyebrowText(text: "You arrived at", color: Color.mrtGold.opacity(0.67), size: 9.5)
                Text(destination.label)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(Color.mrtGold)
                    .lineLimit(1)
                Text(heroFromLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtText.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 15)
        }
        // `flex:1, minHeight:150` (ride-request.jsx:956) — grows to fill
        // whatever space the rest of the (now non-scrolling) column doesn't
        // need; safe to be greedy here since this is the ONLY flexible
        // element in the column and the ancestor chain up to `body`'s
        // `GeometryReader` is height-bounded (unlike the connector-rail bug
        // this file's sibling phases fixed — see their header comments).
        .frame(minHeight: 150, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadiusFlat, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
        )
    }

    // MARK: Tip (ride-request.jsx:981-1004)

    private var tipSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RideEyebrowText(text: "Tip your driver", size: 10)
            HStack(spacing: 8) {
                ForEach(["$3", "$5", "$8", "Custom"], id: \.self) { amount in
                    let on = tip == amount
                    Button { tip = amount } label: {
                        Text(amount)
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(on ? Color.mrtGold : Color.mrtText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(on ? Color.mrtGoldTileFaint : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.mrtGold.opacity(on ? Double(0x88) / 255.0 : Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: MRTMetrics.minTapTarget)
                }
            }
        }
    }

    private func tipSlideUpCard(_ amount: String) -> some View {
        RideSlideUpCard(onDismiss: { tip = nil }) {
            VStack(spacing: 0) {
                Circle()
                    .fill(RadialGradient(colors: [Color.mrtGold, Color.mrtRiderAvatarGradientEnd], center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 23))
                    .frame(width: 46, height: 46)
                    .overlay(Image(systemName: "face.smiling").font(.system(size: 22)).foregroundStyle(Color.mrtGoldButtonLabel))
                    .shadow(color: .mrtGoldGlow, radius: 14)
                    .padding(.bottom, 16)
                Text("Haha, no need!")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtGold)
                    .padding(.bottom, 8)
                Text(Self.tipQuips[amount] ?? "")
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 280)
                    .padding(.bottom, 22)
                MRTButton("Of course", variant: .outlineDraw) { tip = nil }
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Finish (ride-request.jsx:1000 `onDone` → `closeToIdle`)

    private func finish() {
        if let ride = rideRequestService.completeAndReset() {
            historyStore.record(ride)
        }
        viewerState.resetDraftToIdle()
    }
}

// MARK: - RideSummaryStatsStrip (ride-request.jsx:966-978)

/// The summary's stat row: the resolved tiles, in order, with the prototype's
/// divider BETWEEN them (never leading, never trailing).
///
/// **The row is left-packed by construction**: no tile takes `maxWidth: .infinity`
/// and the `HStack` holds no `Spacer`, so it sizes to its content and the enclosing
/// `VStack(alignment: .leading)` seats it at the gutter. Dropping a tile therefore
/// SHORTENS the row rather than stretching the gaps, which is why the 18pt divider
/// padding needed no per-count tuning in MYR-414 — and, from MYR-422, why ADDING
/// the fourth tile a drive-backed live summary carries (trip · distance · — · —)
/// needs none either. That is a claim about a LAYOUT, so it is MEASURED rather than
/// reasoned about: `RideSummaryStripLayoutTests` puts this exact view through a
/// `UIHostingController` at every supported width (the `OwnerPeekBandTests`
/// precedent), because this row has no ellipsis grammar and nothing in it would
/// report an overflow.
///
/// Extracted from `RideRequestSummaryContent` for that measurement — it was a
/// private computed property, and a promise about geometry that no test can read is
/// a promise about a comment.
struct RideSummaryStatsStrip: View {
    let tiles: [RideSummaryPresentation.Tile]

    /// MYR-422 — the placeholder glyph, and it is deliberately `BatteryReadout`'s
    /// own (MYR-204): this app already had a grammar for "the unit and the label are
    /// true, the number is unknowable", and a summary tile inventing a second one
    /// ("--", "N/A", a greyed zero) would be two dialects for one idea.
    static let placeholderValue = BatteryReadout.dash

    /// The page gutter this row lives inside, so a measurement can ask the question
    /// the page asks ("does it fit?") without re-deriving the number.
    static let pageHorizontalPadding: CGFloat = 22

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                if index > 0 { divider }
                statTile(for: tile)
            }
        }
    }

    @ViewBuilder
    private func statTile(for tile: RideSummaryPresentation.Tile) -> some View {
        switch tile {
        case let .trip(minutes):
            // MYR-395's one duration grammar (`"32" / "min"`, `"1 hr 37" / "min"`).
            let parts = RideDuration.heroParts(minutes: minutes)
            statTile(value: parts.value, unit: parts.unit, label: "Trip", gold: false)
        case let .fsdMiles(miles):
            // MYR-422 — `nil` is the dash. The tile keeps its GOLD value colour with
            // a real number (the prototype's celebrated stat, SIM) and goes neutral
            // for the placeholder: gold is the sacred accent, and a dash is the
            // absence of the very thing it is there to celebrate.
            statTile(
                value: miles.map { String(format: "%.1f", $0) } ?? Self.placeholderValue,
                unit: "mi",
                label: "FSD miles",
                gold: miles != nil
            )
        case let .autonomous(percent):
            statTile(
                value: percent.map(String.init) ?? Self.placeholderValue,
                unit: "%",
                label: "Autonomous",
                gold: false
            )
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.mrtGold.opacity(Double(0x24) / 255.0)).frame(width: 1, height: 30).padding(.horizontal, 18)
    }

    private func statTile(value: String, unit: String, label: String, gold: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 21, weight: .bold))
                    .monospacedDigit()
                    .tracking(-0.5)
                    .foregroundStyle(gold ? Color.mrtGold : Color.mrtText)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(gold ? Color.mrtGold.opacity(0.67) : Color.mrtTextMuted)
            }
            RideEyebrowText(text: label, size: 9.5)
        }
    }
}
