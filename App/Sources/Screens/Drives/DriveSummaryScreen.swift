import SwiftUI
import MapKit
import Foundation
import UIKit
import DesignSystem

// MARK: - DriveSummaryScreen (MYR-169, design/app/screens.jsx:831-962,
// Handoff §5.6: "hero map, stat grid, speed sparkline, FSD stat, share via
// UIActivityViewController")
//
// Full-screen takeover pushed from `DrivesScreen` — no `BottomNav` (matches
// the jsx, which never calls one here). Hero MapKit route snapshot (reuses
// `MRTEndpointDot`/`VehicleRoute` from MYR-167 — static, non-interactive
// camera fitted to the drive's route, unlike the Live Map's live-following
// camera), a stat grid (distance/duration/FSD/battery/speed), and a real
// `UIActivityViewController` share (via `ActivityShareSheet`, per Handoff
// §5.6) of the rendered `DriveShareCard` image alongside a plain-text summary.
//
// 100% FSD celebration — **MYR-346, a deliberate, client-directed deviation
// from the prototype.** screens.jsx:852-886,1030-1136 celebrates with a
// full-surface gold wash (page + hero map), a hero highlight, a pop/glow/
// ring-flash and a 34-particle confetti burst. All of it is GONE. On the fixed
// (MYR-339) build the client said *"it literally looks like someone puked on the
// screen and it's hard to read… something cleaner, crisper, and more
// rewarding"*, and client outranks prototype.
//
// The map, the header and every non-FSD tile on a 100% drive are now **byte-
// identical to a 97% drive's**. The celebration lives entirely inside the FSD
// stat block, as an entry MOMENT (`MRTDriveCelebration.momentDuration`, 1.72s):
// the ring draws itself behind a bright `goldTraceBright` head — the ride-CTA
// trace / route-etch grammar — and glints once at 12 o'clock, then settles to a
// slightly richer static ring. The "100%" numeral, the kicker and one fine gold
// hairline on the tile are permanent but local. Reduce Motion boots straight to
// the settled state. Every number lives in `MRTDriveCelebration`.
//
// The Speed sparkline (`DSSparkline`) is deliberately NOT ported: it's
// defined in screens.jsx but never called from `DriveSummaryScreen`'s render
// (dead code in the prototype). The `speeds` trace is still computed
// (screens.jsx:836-844) because Avg/Max speed derive from it, just never
// rendered as a chart.
struct DriveSummaryScreen: View {
    let drive: Drive
    /// Live-only (MYR-204): lazily fetches the drive's GPS polyline for the hero
    /// on summary open. Nil for sim / rider-history drives (their route, if any,
    /// is already baked into `Drive.route`), so those paths render unchanged.
    var routeProvider: ((String) async -> [CLLocationCoordinate2D])?
    /// Live-only (MYR-204): resolves friendly endpoint labels for the header.
    /// Nil for sim / rider-history drives → the header keeps `Drive.from`/`to`.
    var placeLabeler: PlaceLabeler?
    let onBack: () -> Void

    private let dateLabel: String
    private let avgSpeedMPH: Int
    private let maxSpeedMPH: Int
    private let startBatteryPercent: Int
    private let endBatteryPercent: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shareItems: [Any] = []
    @State private var isPreparingShare = false
    @State private var showShareSheet = false
    /// MYR-204 — the lazily-fetched live route polyline (empty until it lands /
    /// for a routeless drive). Sim drives never populate this; they render
    /// `drive.route` directly, so the simulated hero is unchanged.
    @State private var liveRoute: [CLLocationCoordinate2D] = []
    @State private var didRequestRoute = false
    /// MYR-204 — resolved header labels (saved-place / POI / locality). Nil until
    /// resolved, and always nil for sim drives, so the header shows `drive.from`/
    /// `drive.to` verbatim.
    @State private var startLabel: String?
    @State private var endLabel: String?
    /// MYR-327 — the expanded, user-driven route viewer. The client's ask lands
    /// on THIS screen (their TestFlight screenshot is this hero): the hero map is
    /// `interactionModes: []`, so the route they wanted to look at could not be
    /// zoomed or panned at all. Opened by tapping the hero or its expand chip;
    /// only ever offered when a REAL polyline exists (`hasRoute`) — the routeless
    /// placeholder hero stays inert rather than expanding to nothing.
    @State private var showsExpandedRoute = false

    init(
        drive: Drive,
        routeProvider: ((String) async -> [CLLocationCoordinate2D])? = nil,
        placeLabeler: PlaceLabeler? = nil,
        onBack: @escaping () -> Void
    ) {
        self.drive = drive
        self.routeProvider = routeProvider
        self.placeLabeler = placeLabeler
        self.onBack = onBack
        self.dateLabel = Drive.groupLabel(for: drive.dateGroup)

        // screens.jsx:836-849 `seedN`/`speeds`/`startPct`/`endPct` — ported
        // verbatim (same char-code-sum seed, same LCG, same formulas) so
        // each drive's numbers are stable across renders and match the
        // prototype's own derivation for the same fixture id.
        let seedN = drive.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let computedSpeeds = Self.speedTrace(seed: seedN + 7)
        // MYR-203 — a live drive carries real avg/max speed + start/end charge
        // (mapped from the DriveSummary/Drive contract); prefer them. The M1
        // fixtures leave these nil, so the simulated Summary keeps its exact
        // seeded derivation.
        self.maxSpeedMPH = drive.maxSpeedMPH ?? Int((computedSpeeds.max() ?? 0).rounded())
        self.avgSpeedMPH = drive.avgSpeedMPH ?? Int((computedSpeeds.reduce(0, +) / Double(computedSpeeds.count) + 6).rounded())
        let startPct = drive.startChargePercent ?? min(97, 76 + seedN % 18)
        self.startBatteryPercent = startPct
        self.endBatteryPercent = drive.endChargePercent ?? max(6, startPct + drive.batteryDeltaPercent)
    }

    /// The route actually rendered: a sim drive's baked `drive.route`, or the
    /// lazily-fetched live polyline (§7.4). Sim keeps `drive.route` verbatim; a
    /// live drive starts empty and fills in when `routeProvider` returns.
    private var effectiveRoute: [CLLocationCoordinate2D] {
        drive.route.isEmpty ? liveRoute : drive.route
    }

    /// A hero map renders once we hold a real polyline; until then (and for a
    /// genuinely routeless `[]` drive) the calm routeless panel holds — no
    /// spinner. M1 fixtures always route.
    private var hasRoute: Bool { effectiveRoute.count > 1 }

    /// Static hero camera fitted to whatever route is in hand.
    private var heroRegion: MKCoordinateRegion {
        VehicleRoute.fittedRegion(for: effectiveRoute)
    }

    /// Header endpoint labels: the resolved place label when present, else the
    /// backend/fixture address (`Drive.from`/`to`).
    private var fromLabel: String { startLabel ?? drive.from }
    private var toLabel: String { endLabel ?? drive.to }

    var body: some View {
        ZStack {
            // MYR-346 — screens.jsx:866-871's full-screen gold wash used to sit
            // here, behind the scrolling page. It is deleted: a 100% drive's
            // page ground is `mrtBg`, exactly like a 97% drive's.
            Color.mrtBg.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    heroSection
                    headerSection
                    recapGrid
                    Spacer().frame(height: 14)
                }
            }
            // The jsx hero is a full-bleed `position:absolute inset:0` canvas
            // that renders under the status bar (screens.jsx:864,873); ignore
            // the top safe area so the hero starts at the physical top edge.
            .ignoresSafeArea(.container, edges: .top)
            .scrollBounceBehavior(.basedOnSize)
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(activityItems: shareItems)
        }
        // MYR-327 — the expanded route viewer, hosted as a full-bleed overlay
        // rather than a `fullScreenCover` so the open/close carries the app's own
        // motion grammar (Handoff §8 sheet snap; plain cross-fade under Reduce
        // Motion) instead of the system's modal slide.
        //
        // MYR-334: the animation is scoped to the OVERLAY, not hung off the
        // whole screen. Attached outside, a `.animation(_:value:)` re-times
        // every animatable difference the same transaction produces anywhere in
        // this subtree — it used to catch the 1.4s gold-wash fade whenever the
        // map was tapped between t=2.7s and t=4.1s. That wash is gone (MYR-346),
        // but the ring's own entry moment is in the same class of hazard, so the
        // cross-fade keeps owning exactly the layer it belongs to.
        .overlay {
            ZStack {
                if showsExpandedRoute {
                    expandedRouteViewer
                        .transition(.mrtRouteExpand(reduceMotion: reduceMotion))
                }
            }
            .animation(.mrtRouteExpand(reduceMotion: reduceMotion), value: showsExpandedRoute)
        }
        .onAppear {
            #if DEBUG
            // Drift-gate capture hook: headless tooling cannot tap the hero.
            if DebugScene.opensExpandedRouteMap, hasRoute { showsExpandedRoute = true }
            #endif
        }
        .task { await loadLiveRouteAndLabels() }
    }

    // MARK: MYR-327 — expanded route viewer

    private var expandedRouteViewer: some View {
        ExpandedRouteMap(
            title: "\(fromLabel) → \(toLabel)",
            subtitle: "\(dateLabel) · \(drive.start) – \(drive.end)",
            fitCoordinates: effectiveRoute,
            onClose: { showsExpandedRoute = false }
        ) {
            // The SAME builder the hero draws — one route recipe, two cameras.
            driveRouteMapContent(route: effectiveRoute)
        }
    }

    // MARK: Live route + header labels (MYR-204)

    /// Lazily fetch the live route on summary open, then resolve the header
    /// place labels from its endpoints. Runs ONLY for a live drive (an empty
    /// baked `drive.route`) with a provider; sim / rider drives no-op, so their
    /// summary is byte-for-byte unchanged. No spinner — the routeless
    /// placeholder holds until the polyline lands.
    @MainActor
    private func loadLiveRouteAndLabels() async {
        guard drive.route.isEmpty, let routeProvider, !didRequestRoute else { return }
        didRequestRoute = true
        let coordinates = await routeProvider(drive.id)
        guard !coordinates.isEmpty else { return }
        liveRoute = coordinates
        await resolvePlaceLabels(start: coordinates.first, end: coordinates.last)
    }

    /// Resolve the "A → B" endpoints through the labeling ladder (saved place →
    /// POI/neighborhood → city-only-when-cities-differ → address). Resolved as
    /// a PAIR (MYR-208): the city renders only when it distinguishes the two
    /// endpoints, so an intra-city drive never shows "Dallas → Dallas". Each
    /// side degrades to the existing address on a geocode timeout, so the
    /// header never blocks.
    @MainActor
    private func resolvePlaceLabels(start: CLLocationCoordinate2D?, end: CLLocationCoordinate2D?) async {
        guard let placeLabeler, let start, let end else { return }
        let labels = await placeLabeler.labels(
            start: start,
            end: end,
            fallbacks: (drive.from, drive.to),
            driveID: drive.id
        )
        startLabel = labels.start
        endLabel = labels.end
    }

    // MARK: Hero map (screens.jsx:873-897)

    private var heroSection: some View {
        ZStack {
            if hasRoute {
                DriveHeroMap(route: effectiveRoute, region: heroRegion)
            } else {
                DriveHeroPlaceholder()
            }

            // Top/bottom legibility scrims (screens.jsx:882-883).
            VStack(spacing: 0) {
                LinearGradient(colors: [.mrtDsScrimTop, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 100)
                Spacer()
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .mrtDsScrimBottomMid, location: 0.55),
                        .init(color: .mrtBg, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
            }
            .allowsHitTesting(false)

            // MYR-346 — screens.jsx:885-886's gold reward tint and radial
            // highlight used to sit HERE, directly above the hosted `MKMapView`.
            // Both are deleted. MYR-339 had already resolved the first one's
            // `mix-blend-mode: soft-light` down to normal compositing at α
            // 0.07→0.09 (a still cannot catch that defect — a screenshot
            // flattens the tree into one buffer where the blend resolves, which
            // is why the client had to photograph his phone). The client then
            // rejected the treatment itself, so the hero now renders exactly as
            // a 97% drive's does: no celebration layer of any kind touches the
            // map, at any opacity, in any blend mode.

            // MYR-327 — "click into the map": the whole hero is the tap target
            // for the expanded viewer. Placed UNDER `floatingNav` in the stack so
            // the back / share / expand buttons keep their own taps, and only
            // when a real polyline exists (a routeless hero expands to nothing,
            // which would be a fabricated affordance).
            if hasRoute {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { showsExpandedRoute = true }
                    .accessibilityHidden(true)
            }

            floatingNav
        }
        .frame(height: MRTMetrics.driveSummaryHeroHeight)
        .clipped()
    }

    private var floatingNav: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 21))
                    .foregroundStyle(Color.mrtText)
                    .frame(width: MRTMetrics.driveSummaryFloatingButtonSize, height: MRTMetrics.driveSummaryFloatingButtonSize)
                    .background(Color.mrtDsFloatingNavFill, in: Circle())
                    .overlay(Circle().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
                    .contentShape(Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.driveSummaryFloatingButtonSize) / 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Drives")

            Spacer()

            // MYR-327 — the discoverable half of "click into the map". The hero
            // is tappable everywhere, but nothing on the old screen said so; this
            // chip is the visible cue, in the floating nav's existing language and
            // geometry. Shown only alongside a real route, like the tap target.
            if hasRoute {
                ExpandRouteButton { showsExpandedRoute = true }
            }

            Button {
                Task { await prepareAndPresentShare() }
            } label: {
                ZStack {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18))
                        .opacity(isPreparingShare ? 0 : 1)
                    if isPreparingShare {
                        ProgressView().tint(Color.mrtGold)
                    }
                }
                .foregroundStyle(Color.mrtGold)
                .frame(width: MRTMetrics.driveSummaryFloatingButtonSize, height: MRTMetrics.driveSummaryFloatingButtonSize)
                .background(Color.mrtDsFloatingNavFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
                .contentShape(Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.driveSummaryFloatingButtonSize) / 2))
            }
            .buttonStyle(.plain)
            .disabled(isPreparingShare)
            .accessibilityLabel("Share this drive")
        }
        .padding(.horizontal, 16)
        .padding(.top, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// screens.jsx's share button has no `onClick` wired (dead affordance in
    /// the prototype) — Handoff §5.6 calls for a real `UIActivityViewController`
    /// share here, sharing the rendered `DSShareCard` (screens.jsx:1192)
    /// image alongside this plain-text summary, not text alone.
    private var shareSummary: String {
        """
        \(drive.from) → \(drive.to)
        \(dateLabel) · \(drive.start) – \(drive.end)
        \(String(format: "%.1f", drive.miles)) mi · \(drive.mins) min · \(drive.fsdPercent)% FSD
        """
    }

    /// Snapshots the drive's route into a `UIImage` (`DriveRouteSnapshot`,
    /// async — must finish before `ImageRenderer` runs so the map tiles are
    /// actually baked in), composes `DriveShareCard` against it, and rasters
    /// the card via `ImageRenderer`. The share sheet only opens once both the
    /// image and text are ready, matching the button's brief progress spinner.
    @MainActor
    private func prepareAndPresentShare() async {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        defer { isPreparingShare = false }

        let mapImage = await DriveRouteSnapshot.render(
            region: heroRegion,
            route: effectiveRoute,
            size: CGSize(width: MRTMetrics.shareCardWidth, height: MRTMetrics.shareCardMapHeight)
        )
        let card = DriveShareCard(drive: drive, dateLabel: dateLabel, mapImage: mapImage)
            .frame(width: MRTMetrics.shareCardWidth)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3

        var items: [Any] = []
        if let cardImage = renderer.uiImage { items.append(cardImage) }
        items.append(shareSummary)
        shareItems = items
        showShareSheet = true
    }

    // MARK: Celebratory header (screens.jsx:900-906)

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(dateLabel)
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.mrtGold)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(fromLabel).foregroundStyle(Color.mrtText)
                Text("→").foregroundStyle(Color.mrtGold).fontWeight(.regular)
                Text(toLabel).foregroundStyle(Color.mrtText)
            }
            .font(.system(size: 22, weight: .semibold))
            .tracking(-0.5)
            Text("\(drive.start) – \(drive.end)")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    // MARK: Recap grid (screens.jsx:909-957)

    private var recapGrid: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                DriveStatTile(label: "Distance", value: String(format: "%.1f", drive.miles), unit: "mi")
                DriveStatTile(label: "Duration", value: "\(drive.mins)", unit: "min")
            }

            FSDTile(percent: drive.fsdPercent, fsdMiles: drive.fsdMiles)

            BatteryTile(
                usedPercent: -drive.batteryDeltaPercent,
                startPercent: startBatteryPercent,
                endPercent: endBatteryPercent
            )

            HStack(spacing: 14) {
                DriveStatTile(label: "Avg speed", value: "\(avgSpeedMPH)", unit: "mph")
                DriveStatTile(label: "Max speed", value: "\(maxSpeedMPH)", unit: "mph", color: .mrtGold)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    // MARK: Deterministic speed trace (screens.jsx:836-844 `speeds`)

    /// Reuses `SeededMapRandom` (the prototype's shared `seedRand` LCG,
    /// already ported for `MapBackground`) rather than reimplementing it.
    static func speedTrace(seed: Int) -> [Double] {
        var rng = SeededMapRandom(seed: seed)
        return (0..<60).map { i in
            let t = Double(i) / 59.0
            let ramp = min(1, t * 5) * min(1, (1 - t) * 5)
            return 6 + ramp * (50 + 22 * sin(t * 3.0 + 0.3) + 9 * sin(t * 9.5) + rng.next() * 8)
        }
    }
}

// MARK: - Hero map (static, non-interactive — screens.jsx:874-879)

private struct DriveHeroMap: View {
    let route: [CLLocationCoordinate2D]
    let region: MKCoordinateRegion

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            driveRouteMapContent(route: route)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
    }
}

/// The drive's route + endpoints as map content — ONE recipe consumed by the
/// static hero above AND by the MYR-327 expanded viewer, so tapping into the
/// map cannot show a different route treatment than the hero it came from.
@MapContentBuilder
func driveRouteMapContent(route: [CLLocationCoordinate2D]) -> some MapContent {
    if route.count > 1 {
        // Glow underlay + bright line (RouteLine.swift doc) — no dim
        // full-path layer: `progress={1}` in the jsx means the whole
        // route already reads as "travelled", so a separate dim
        // layer would sit fully hidden underneath.
        MapPolyline(coordinates: route)
            .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
        MapPolyline(coordinates: route)
            .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
    }
    if let origin = route.first {
        Annotation("Origin", coordinate: origin) {
            MRTEndpointDot(color: .mrtDriving, size: 13)
        }
    }
    if let destination = route.last {
        Annotation("Destination", coordinate: destination) {
            MRTEndpointDot(color: .mrtGold, size: 13)
        }
    }
}

// MARK: - Routeless hero (MYR-203)
//
// The Drive Summary hero for a live drive with no route polyline (contracts
// v0.6.0 has no coordinates — see `hasRoute`). A calm muted panel keyed to the
// same tokens as the map's dark ground, so the header/stats below still read as
// a finished, intentional screen rather than a broken/empty map.
private struct DriveHeroPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.mrtElevated, .mrtBg],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "map")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(Color.mrtTextMuted.opacity(0.55))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - DS_TILE shared chrome (screens.jsx:992-997)

private var dsTileGradient: LinearGradient {
    LinearGradient(colors: [.mrtDsTileTintStart, .mrtDsTileTintEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private extension View {
    /// jsx's `DS_TILE` base style carries no padding of its own — every call
    /// site pads independently (screens.jsx:912,917,929 `DSMetric`/FSD tile/
    /// Battery tile all use different top/bottom insets). Defaults match
    /// `DSMetric`'s `'14px 16px 16px'`; FSD/Battery override below.
    ///
    /// MYR-346 — `border` is the one thing a celebrated tile changes about this
    /// chrome: the FSD tile on a 100% drive swaps the neutral `mrtDsTileBorder`
    /// for `MRTDriveCelebration.celebratedCardBorder` (gold at 0.18). Fill,
    /// radius and padding are untouched, so every other tile — and the FSD tile
    /// on a 97% drive — is byte-identical.
    func dsTileChrome(
        horizontal: CGFloat = 16,
        top: CGFloat = 14,
        bottom: CGFloat = 16,
        border: Color = .mrtDsTileBorder
    ) -> some View {
        padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background(dsTileGradient, in: RoundedRectangle(cornerRadius: MRTMetrics.driveSummaryTileRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.driveSummaryTileRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: MRTMetrics.hairline)
            )
    }
}

// MARK: - DSMetric (screens.jsx:999-1008)

private struct DriveStatTile: View {
    let label: String
    let value: String
    let unit: String
    var color: Color = .mrtText

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 29, weight: .medium))
                    .monospacedDigit()
                    .tracking(-1)
                    .foregroundStyle(color)
                Text(unit)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtTextMuted)
            }
            .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsTileChrome()
    }
}

// MARK: - Full Self-Driving tile (screens.jsx:916-926, DSRing:1050-1136)

private struct FSDTile: View {
    let percent: Int
    let fsdMiles: Double

    /// MYR-346 — the ONE predicate (DesignSystem), shared with the ring, so the
    /// hairline, the kicker and the ring can never disagree.
    private var celebrates: Bool { MRTDriveCelebration.celebrates(fsdPercent: percent) }

    var body: some View {
        HStack(spacing: 18) {
            FSDRing(percent: percent)
            VStack(alignment: .leading, spacing: 6) {
                // MYR-346 — the kicker takes the celebratory gold on a flawless
                // drive; a 97% drive keeps flat `mrtGoldLight` exactly as before.
                Text("Full Self-Driving")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .celebratedGold(celebrates, fallback: .mrtGoldLight)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(String(format: "%.1f", fsdMiles))
                        .font(.system(size: 30, weight: .medium))
                        .monospacedDigit()
                        .tracking(-1.2)
                        .foregroundStyle(Color.mrtText)
                    Text("mi")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                .fixedSize()
                Text("Driven autonomously")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
        // screens.jsx:917 `padding: '20px 18px'`, more generous than the
        // shared DSMetric default. MYR-346 — plus the one fine gold hairline.
        .dsTileChrome(
            horizontal: 18,
            top: 20,
            bottom: 20,
            border: celebrates ? MRTDriveCelebration.celebratedCardBorder : .mrtDsTileBorder
        )
    }
}

/// MYR-346 — the celebrated gold treatment for text, applied conditionally so
/// the uncelebrated branch is the EXACT `foregroundStyle(Color)` it always was
/// (a gradient with the same endpoints is not the same rasterization).
private extension View {
    @ViewBuilder
    func celebratedGold(_ celebrates: Bool, fallback: Color) -> some View {
        if celebrates {
            foregroundStyle(MRTDriveCelebration.celebratedTextGradient)
        } else {
            foregroundStyle(fallback)
        }
    }
}

/// screens.jsx:1050-1136 `DSRing` — two-tone gold activity ring, drawing from 0
/// on appear.
///
/// **MYR-346 rewrote what 100% looks like here** (the reasoning, and every
/// number, live in `MRTDriveCelebration`). The prototype celebrates a flawless
/// drive with a pop bounce, a glow halo, an expanding ring flash and a
/// 34-particle confetti burst, on top of a page-wide gold wash; the client
/// called the whole thing *"someone puked on the screen"*. All of it is gone.
///
/// What replaces it is ONE moment, 1.72s long: the ring draws itself behind a
/// bright `goldTraceBright` head — the ride-CTA `MRTTraceBorder` / route-etch
/// grammar, the app's own established "something is being drawn" language — the
/// head glints once as it lands at 12 o'clock, and the ring settles slightly
/// richer than the 97% variant and then holds perfectly still.
///
/// **The 97% variant is untouched**: same faint track, same flat-gold arc, same
/// `mrtText` numeral, same curve, same duration, same delay. It constructs no
/// head, no glint and no halo — those branches are `celebrates`-gated, not
/// opacity-zeroed.
///
/// Reduce Motion boots straight to the settled state: `drawProgress` starts at
/// its terminal and the glint starts spent, so nothing animates and nothing
/// bright is ever drawn.
private struct FSDRing: View {
    let percent: Int
    var size: CGFloat = 82
    var stroke: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The drawn fraction of the ring — animated exactly once, on appear.
    @State private var drawProgress: Double = 0
    /// 0 while the head rides the draw, 1 once the glint has burned out.
    @State private var glintPhase: Double = 0
    /// Arms the view-ATTACHED animations. Attached `.animation(_:value:)` is
    /// applied at render and survives being armed inside another transition's
    /// transaction — the MYR-237 "only renders after a hardware press" fix — and
    /// this view mounts inside the Drives → Summary push, which is exactly that
    /// situation. Nothing here uses `withAnimation`. Each flag is false until
    /// its pass is armed, so no reset can animate.
    @State private var drawArmed = false
    @State private var glintArmed = false

    private var fraction: Double { min(1, Double(percent) / 100) }

    /// The ONE celebration predicate (DesignSystem), shared with `FSDTile`.
    private var celebrates: Bool { MRTDriveCelebration.celebrates(fsdPercent: percent) }

    var body: some View {
        ZStack {
            ringTrack
            ringHalo
            ringArc
            ringHead
            numeral
        }
        .frame(width: size, height: size)
        .onAppear(perform: arm)
    }

    // MARK: The moment

    private func arm() {
        guard !reduceMotion else {
            // Straight to settled: no draw, no glint. A spent `glintPhase` is
            // what keeps the head's opacity at 0 even before its branch is read.
            drawProgress = fraction
            glintPhase = 1
            return
        }
        drawArmed = true
        drawProgress = fraction
        guard celebrates else { return }
        Task { @MainActor in
            try? await Task.sleep(for: MRTDriveCelebration.glintOnset)
            glintArmed = true
            glintPhase = 1
        }
    }

    private var drawAnimation: Animation? {
        drawArmed ? MRTDriveCelebration.ringDrawAnimation(reduceMotion: reduceMotion) : nil
    }

    // MARK: Layers (screens.jsx:1111-1117,1128-1133)

    /// Manual remainder — the full ring underneath, light shade
    /// (screens.jsx:1113 `rgba(201,168,76,0.22)`, the same alpha as the
    /// outline-draw resting border, `mrtGoldBorderFaint`).
    private var ringTrack: some View {
        Circle().stroke(Color.mrtGoldBorderFaint, lineWidth: stroke)
    }

    /// MYR-346 — the settled ring's faint static halo, celebrated drives only:
    /// the glint's residue, and all that survives of the prototype's glow +
    /// ring-flash. Trimmed with the draw so it arrives WITH the ring rather than
    /// sitting there waiting for it.
    @ViewBuilder
    private var ringHalo: some View {
        if celebrates {
            Circle()
                .trim(from: 0, to: drawProgress)
                .stroke(
                    MRTDriveCelebration.celebratedRingHalo,
                    style: StrokeStyle(lineWidth: stroke, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
                .blur(radius: MRTDriveCelebration.celebratedRingHaloBlur)
                .animation(drawAnimation, value: drawProgress)
                .allowsHitTesting(false)
        }
    }

    /// The autonomous portion (screens.jsx:1115-1116 `stroke-dashoffset 1.15s
    /// cubic-bezier(0.32,0.72,0,1)`). Flat `mrtGold` on a 97% drive — byte for
    /// byte what it always was — and the slightly richer angular gradient on a
    /// celebrated one. The −90° rotation puts both the trim's origin and the
    /// gradient's stop 0 at 12 o'clock.
    private var ringArc: some View {
        Circle()
            .trim(from: 0, to: drawProgress)
            .stroke(arcStyle, style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
            .rotationEffect(.degrees(-90))
            .animation(drawAnimation, value: drawProgress)
    }

    private var arcStyle: AnyShapeStyle {
        celebrates
            ? AnyShapeStyle(MRTDriveCelebration.celebratedRingGradient)
            : AnyShapeStyle(Color.mrtGold)
    }

    /// The trace head: the ride-CTA outline-draw's own hot spot
    /// (`goldTraceBright`), riding the leading edge of the draw and flaring once
    /// as it lands at 12 o'clock. Its three layers are `RouteEtchTrace`'s
    /// verbatim — wide soft bloom → tight glow → hot core — because this is the
    /// same gesture that etches the ride route, at ring scale.
    ///
    /// Celebrated drives only. Under Reduce Motion `glintPhase` boots spent, so
    /// `headOpacity` is 0 on the first and every frame.
    @ViewBuilder
    private var ringHead: some View {
        if celebrates {
            let angle = Angle.degrees(-90 + drawProgress * 360)
            headCore
                // The glint: the head SWELLS as it burns out, so the moment ends
                // on a brightening rather than on a fade.
                .scaleEffect(MRTDriveCelebration.glintScale(glintPhase: glintPhase))
                .opacity(MRTDriveCelebration.headOpacity(drawProgress: drawProgress, glintPhase: glintPhase))
                .animation(
                    glintArmed ? MRTDriveCelebration.ringGlintAnimation(reduceMotion: reduceMotion) : nil,
                    value: glintPhase
                )
                // …carried around the ring by the draw itself.
                .offset(
                    x: (size / 2) * cos(angle.radians),
                    y: (size / 2) * sin(angle.radians)
                )
                .animation(drawAnimation, value: drawProgress)
                // MYR-339's invariant, stated at the one glow this screen has
                // left. It is a stored constant rather than a literal because a
                // blend mode written inline in a view body is precisely what
                // flooded the hero map — and this layer, unlike that one, is
                // 82pt wide and nowhere near the hosted `MKMapView`.
                .blendMode(MRTDriveCelebration.celebrationBlendMode)
                .allowsHitTesting(false)
        }
    }

    private var headCore: some View {
        ZStack {
            Circle()
                .fill(Color.mrtGold.opacity(0.35))
                .frame(width: 30, height: 30)
                .blur(radius: 9)
            Circle()
                .fill(Color.mrtGoldTrace.opacity(0.7))
                .frame(width: 13, height: 13)
                .blur(radius: 4)
            Circle()
                .fill(Color.mrtGoldTraceBright)
                .frame(width: 6, height: 6)
                .shadow(color: .mrtGoldTraceBright.opacity(0.9), radius: 3)
        }
    }

    /// screens.jsx:1128-1133. MYR-346 — on a celebrated drive the numeral takes
    /// the struck-metal gold gradient; a 97% drive keeps flat `mrtText`.
    private var numeral: some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(percent)")
                .font(.system(size: 21, weight: .semibold))
            Text("%")
                .font(.system(size: 12, weight: .medium))
        }
        .monospacedDigit()
        .tracking(-0.5)
        .celebratedGold(celebrates, fallback: .mrtText)
    }
}

// MARK: - Battery tile (screens.jsx:929-950)

private struct BatteryTile: View {
    let usedPercent: Int
    let startPercent: Int
    let endPercent: Int

    private var endColor: Color { .mrtBatteryColor(Double(endPercent)) }

    /// MYR-204/MYR-207 — guards the start & "used" figures against a live
    /// drive's bogus `startChargeLevel = 0` (renders them "—" instead of
    /// "0% → 75% / -75% used"). Sim readings are always trustworthy → unchanged.
    private var readout: BatteryReadout {
        BatteryReadout(usedPercent: usedPercent, startPercent: startPercent, endPercent: endPercent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery")
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                Spacer()
                Text(readout.usedText)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
            }
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                percentLabel(readout.startText, showsPercent: readout.isStartKnown, color: .mrtText)
                Text("→").font(.system(size: 16)).foregroundStyle(Color.mrtTextMuted)
                percentLabel(readout.endText, showsPercent: true, color: endColor)
            }
            GeometryReader { geo in
                let startWidth = geo.size.width * CGFloat(readout.startFraction)
                let endWidth = geo.size.width * CGFloat(readout.endFraction)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.mrtElevated)
                        .overlay(Capsule().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                    // Start fill + START marker only when the start reading is
                    // trustworthy (MYR-207 guard) — a bogus 0% start draws neither.
                    if readout.isStartKnown {
                        Capsule().fill(Color.mrtText.opacity(0.11)).frame(width: startWidth)
                    }
                    Capsule()
                        .fill(LinearGradient(colors: [endColor.opacity(0.73), endColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: endWidth)
                    if readout.isStartKnown {
                        Rectangle()
                            .fill(Color.mrtGold)
                            .frame(width: 2)
                            .shadow(color: .mrtGoldGlow, radius: 3)
                            .offset(x: startWidth - 1)
                        Text("START")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(Color.mrtGoldLight)
                            .fixedSize()
                            .offset(x: min(max(0, startWidth - 16), geo.size.width - 34), y: -16)
                    }
                }
            }
            .frame(height: 10)
            .padding(.top, 4)
        }
        // screens.jsx:929 `padding: '17px 18px 18px'`.
        .dsTileChrome(horizontal: 18, top: 17, bottom: 18)
    }

    private func percentLabel(_ text: String, showsPercent: Bool, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(text)
                .font(.system(size: 28, weight: .medium))
                .monospacedDigit()
                .tracking(-1)
            if showsPercent {
                Text("%")
                    .font(.system(size: 16, weight: .medium))
            }
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

#Preview {
    DriveSummaryScreen(drive: DriveFixtures.drives[0], onBack: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}

#Preview("100% FSD") {
    DriveSummaryScreen(drive: DriveFixtures.drive(id: "d8")!, onBack: {})
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
