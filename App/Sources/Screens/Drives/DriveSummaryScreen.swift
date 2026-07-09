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
// 100% FSD celebration (screens.jsx:852-886,1030-1136): a confetti burst
// fires once the ring's fill sweep completes — 34 particles launch radially,
// fall under gravity, spin up to ±600°, and fade over ~1.5-2.1s, alongside a
// pop/glow/ring-flash on the ring itself (`DSRing`'s `celebrate` state drives
// all four together). Ported in `FSDRing` below via `KeyframeAnimator`, gated
// on `!reduceMotion`. The page also eases into a warm gold wash 2.7s after
// mount (reduce motion: 200ms) — screens.jsx `goldMode`, ported in
// `goldWash`/`heroGoldTint` below.
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
    /// screens.jsx:856 `goldMode` — fades in the page-wide warm wash once the
    /// celebration has settled (852-861: `isFull` gate, 2.7s / 200ms delay).
    @State private var goldMode = false
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

    private var isFullFSD: Bool { drive.fsdPercent >= 100 }

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
            Color.mrtBg.ignoresSafeArea()
            // screens.jsx:866-871 — the warm gold reward wash, a fixed
            // full-screen layer behind the scrollable content (zIndex 0 vs.
            // the page's zIndex 1), not part of the scrolling page flow.
            goldWash.ignoresSafeArea()

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
        .onAppear { scheduleGoldMode() }
        .task { await loadLiveRouteAndLabels() }
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

    /// screens.jsx:852-861 `goldMode` scheduling — fires once, 2.7s after
    /// mount (200ms under Reduce Motion), and only for a flawless drive.
    private func scheduleGoldMode() {
        guard isFullFSD else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 2700))
            guard !reduceMotion else {
                goldMode = true
                return
            }
            withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.4)) {
                goldMode = true
            }
        }
    }

    /// screens.jsx:866-871 — page-wide radial + linear gold wash.
    private var goldWash: some View {
        ZStack {
            EllipticalGradient(
                stops: [
                    .init(color: Color.mrtGold.opacity(0.22), location: 0),
                    .init(color: Color.mrtGold.opacity(0.08), location: 0.46),
                    .init(color: .clear, location: 0.76),
                ],
                center: UnitPoint(x: 0.5, y: 0.6),
                startRadiusFraction: 0,
                endRadiusFraction: 0.85
            )
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.32),
                    .init(color: Color.mrtGold.opacity(0.05), location: 0.55),
                    .init(color: Color.mrtGold.opacity(0.12), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .opacity(goldMode ? 1 : 0)
        .allowsHitTesting(false)
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

            // screens.jsx:885-886 — gold reward tint over the map itself
            // (soft-light blend + a soft radial highlight), same `goldMode`
            // fade as the page wash.
            LinearGradient(colors: [Color.mrtGold.opacity(0.5), Color.mrtGold.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .blendMode(.softLight)
                .opacity(goldMode ? 1 : 0)
                .allowsHitTesting(false)
            EllipticalGradient(
                stops: [
                    .init(color: Color.mrtGold.opacity(0.18), location: 0),
                    .init(color: .clear, location: 0.7),
                ],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadiusFraction: 0,
                endRadiusFraction: 0.75
            )
            .opacity(goldMode ? 1 : 0)
            .allowsHitTesting(false)

            floatingNav
        }
        .frame(height: MRTMetrics.driveSummaryHeroHeight)
        .clipped()
    }

    private var floatingNav: some View {
        HStack {
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
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
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
    func dsTileChrome(horizontal: CGFloat = 16, top: CGFloat = 14, bottom: CGFloat = 16) -> some View {
        padding(.horizontal, horizontal)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .background(dsTileGradient, in: RoundedRectangle(cornerRadius: MRTMetrics.driveSummaryTileRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.driveSummaryTileRadius, style: .continuous)
                    .strokeBorder(Color.mrtDsTileBorder, lineWidth: MRTMetrics.hairline)
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

    var body: some View {
        HStack(spacing: 18) {
            FSDRing(percent: percent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Full Self-Driving")
                    .font(.system(size: 10.5, weight: .semibold))
                    .tracking(1)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.mrtGoldLight)
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
        // shared DSMetric default.
        .dsTileChrome(horizontal: 18, top: 20, bottom: 20)
    }
}

/// screens.jsx:1050-1136 `DSRing` — two-tone gold activity ring, fills from 0
/// on appear. At 100% it celebrates once the sweep lands: a pop bounce + glow
/// halo + expanding ring flash on the ring itself, plus a 34-particle gold
/// confetti burst (ported from `ensureCelebrateStyle`'s
/// `dsConfetti`/`dsPop`/`dsGlow`/`dsRingFlash` keyframes, screens.jsx:1030-1136).
/// All four are driven by the same `celebrate` flip. Reduce Motion → no sweep
/// animation and no celebration; the ring renders its final state statically.
private struct FSDRing: View {
    let percent: Int
    var size: CGFloat = 82
    var stroke: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: Double = 0
    @State private var celebrate = false
    @State private var showBurst = false
    @State private var particles: [ConfettiParticle] = []

    private var fraction: Double { min(1, Double(percent) / 100) }
    private var isFull: Bool { percent >= 100 }

    /// cubic-bezier(0.34,1.56,0.64,1) — `dsPop`'s overshoot curve (screens.jsx:1041).
    private static let popCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.34, y: 1.56),
        endControlPoint: UnitPoint(x: 0.64, y: 1)
    )

    var body: some View {
        ZStack {
            if celebrate {
                celebrationGlow
                celebrationRingFlash
            }
            ringCore
            if showBurst {
                ForEach(particles) { particle in
                    ConfettiParticleView(particle: particle)
                }
            }
        }
        .frame(width: size, height: size)
        // The `.keyframeAnimator` *modifier* form (vs. the `KeyframeAnimator`
        // container) applies the pop scale to this already-sized view via a
        // `PlaceholderContentView` standing in for it, so it can't re-size
        // the ring off a sibling's larger frame the way the container form
        // did (it was reading `celebrationGlow`'s `size + 20` instead of
        // `size`, rendering ~20% too large).
        .keyframeAnimator(initialValue: 1.0, trigger: celebrate) { content, scale in
            content.scaleEffect(scale)
        } keyframes: { _ in
            // dsPop 0.8s: 0%→1, 24%→1.16, 48%→0.96, 70%→1.05, 100%→1.
            KeyframeTrack(\.self) {
                LinearKeyframe(1.0, duration: 0)
                LinearKeyframe(1.16, duration: 0.192, timingCurve: Self.popCurve)
                LinearKeyframe(0.96, duration: 0.192, timingCurve: Self.popCurve)
                LinearKeyframe(1.05, duration: 0.176, timingCurve: Self.popCurve)
                LinearKeyframe(1.0, duration: 0.24, timingCurve: Self.popCurve)
            }
        }
        .onAppear { scheduleAnimations() }
    }

    // MARK: Ring (screens.jsx:1111-1117,1128-1133)

    private var ringCore: some View {
        ZStack {
            // Manual remainder — full ring underneath, light shade
            // (screens.jsx:1113 `rgba(201,168,76,0.22)` — same alpha as the
            // existing outline-draw resting border, `mrtGoldBorderFaint`).
            Circle().stroke(Color.mrtGoldBorderFaint, lineWidth: stroke)
            // Autonomous portion — animated sweep (screens.jsx:1115-1116
            // `stroke-dashoffset 1.15s cubic-bezier(0.32,0.72,0,1)`).
            Circle()
                .trim(from: 0, to: sweep)
                .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: stroke, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text("\(percent)")
                    .font(.system(size: 21, weight: .semibold))
                Text("%")
                    .font(.system(size: 12, weight: .medium))
            }
            .monospacedDigit()
            .tracking(-0.5)
            .foregroundStyle(percent >= 100 ? Color.mrtGold : Color.mrtText)
        }
        .frame(width: size, height: size)
    }

    // MARK: Celebration glow + ring flash (screens.jsx:1104-1109)

    /// `dsGlow` 1s ease-out: 0%→opacity 0/scale 0.7, 30%→opacity 0.9, 100%→opacity 0/scale 1.9.
    private var celebrationGlow: some View {
        KeyframeAnimator(initialValue: CelebrationFade(), trigger: celebrate) { value in
            Circle()
                .fill(RadialGradient(colors: [.mrtGoldGlowSoft, .clear], center: .center, startRadius: 0, endRadius: size * 0.62))
                .frame(width: size + 20, height: size + 20)
                .scaleEffect(value.scale)
                .opacity(value.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0)
                LinearKeyframe(0.9, duration: 0.3, timingCurve: .easeOut)
                LinearKeyframe(0, duration: 0.7, timingCurve: .easeOut)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(0.7, duration: 0)
                LinearKeyframe(1.9, duration: 1.0, timingCurve: .easeOut)
            }
        }
        .allowsHitTesting(false)
    }

    /// `dsRingFlash` 0.85s cubic-bezier(0.22,1,0.36,1): 0%→opacity 0/scale 1,
    /// 25%→opacity 0.9, 100%→opacity 0/scale 1.45.
    private var celebrationRingFlash: some View {
        KeyframeAnimator(initialValue: CelebrationFade(scale: 1), trigger: celebrate) { value in
            Circle()
                .strokeBorder(Color.mrtGold, lineWidth: 2)
                .frame(width: size + 4, height: size + 4)
                .scaleEffect(value.scale)
                .opacity(value.opacity)
        } keyframes: { _ in
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: 0)
                LinearKeyframe(0.9, duration: 0.2125, timingCurve: Self.flashCurve)
                LinearKeyframe(0, duration: 0.6375, timingCurve: Self.flashCurve)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(1, duration: 0)
                LinearKeyframe(1.45, duration: 0.85, timingCurve: Self.flashCurve)
            }
        }
        .allowsHitTesting(false)
    }

    /// cubic-bezier(0.22,1,0.36,1) (screens.jsx:1109 `dsRingFlash` animation-timing-function).
    private static let flashCurve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.22, y: 1),
        endControlPoint: UnitPoint(x: 0.36, y: 1)
    )

    // MARK: Scheduling (screens.jsx:1060-1077)

    private func scheduleAnimations() {
        guard !reduceMotion else {
            sweep = fraction
            return
        }
        withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 1.15).delay(0.12)) {
            sweep = fraction
        }
        guard isFull else { return }
        // screens.jsx:1067 — celebrate fires 120ms (sweep start delay) +
        // 1150ms (sweep duration) after mount, i.e. right as the ring lands.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1270))
            particles = ConfettiParticle.burst()
            celebrate = true
            showBurst = true
            // screens.jsx:1075 — unmount the burst 2.5s later so its
            // off-screen particles can't extend the page's scrollable area.
            try? await Task.sleep(for: .milliseconds(2500))
            showBurst = false
        }
    }
}

/// Shared 0→opacity/scale keyframe value for the glow halo + ring flash.
private struct CelebrationFade {
    var opacity: Double = 0
    var scale: Double = 0.7
}

// MARK: - Confetti burst (screens.jsx:1078-1100,1119-1127 `particles`/`dsConfetti`)

/// One confetti particle — `mx`/`my` is the apex of the initial throw (10% of
/// the animation), `tx`/`ty` is where it lands under gravity (100%), matching
/// screens.jsx's per-particle generation verbatim (34 particles, radial launch
/// angle + random distance, gravity pulling `ty` below `my`, random spin up to
/// ±600°, alternating round/rect shapes, randomized size/delay/duration).
private struct ConfettiParticle: Identifiable {
    let id: Int
    let mx: Double
    let my: Double
    let tx: Double
    let ty: Double
    let rotation: Double
    let width: CGFloat
    let height: CGFloat
    let round: Bool
    let color: Color
    /// Seconds (screens.jsx `delay`, 0-200ms).
    let delay: Double
    /// Seconds (screens.jsx `dur`, 1500-2100ms).
    let duration: Double

    private static let colors: [Color] = [.mrtGold, .mrtGoldLight, .mrtGoldDark, .mrtText, .mrtConfettiPale]

    static func burst(count: Int = 34) -> [ConfettiParticle] {
        (0..<count).map { i in
            let angle = (2 * Double.pi / Double(count)) * Double(i) + Double.random(in: -0.3...0.3)
            let dist = 64 + Double.random(in: 0...70)
            let mx = cos(angle) * dist * 0.55
            let my = sin(angle) * dist * 0.55 - 6
            let tx = cos(angle) * dist
            let ty = sin(angle) * dist + 46 + Double.random(in: 0...60)
            let round = i % 3 == 0
            let width: CGFloat = round ? CGFloat(5 + Int.random(in: 0...2)) : CGFloat(3 + Int.random(in: 0...1))
            let height: CGFloat = round ? CGFloat(5 + Int.random(in: 0...2)) : CGFloat(8 + Int.random(in: 0...5))
            return ConfettiParticle(
                id: i,
                mx: mx, my: my, tx: tx, ty: ty,
                rotation: Double.random(in: -1...1) * 600,
                width: width, height: height, round: round,
                color: colors[i % colors.count],
                delay: Double.random(in: 0...0.2),
                duration: 1.5 + Double.random(in: 0...0.6)
            )
        }
    }
}

private struct ConfettiKeyframeValue {
    var x: Double = 0
    var y: Double = 0
    var scale: Double = 0.4
    var rotation: Double = 0
    var opacity: Double = 0
}

private struct ConfettiParticleView: View {
    let particle: ConfettiParticle
    /// One-shot burst trigger — a trigger-less `KeyframeAnimator` repeats
    /// forever; the jsx `dsConfetti` runs once (`forwards`) per celebration.
    @State private var burst = false

    /// cubic-bezier(0.2,0.7,0.3,1) (screens.jsx:1040 `dsConfetti` timing-function).
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.2, y: 0.7),
        endControlPoint: UnitPoint(x: 0.3, y: 1)
    )

    var body: some View {
        KeyframeAnimator(initialValue: ConfettiKeyframeValue(), trigger: burst) { value in
            Group {
                if particle.round {
                    Circle().fill(particle.color)
                } else {
                    RoundedRectangle(cornerRadius: 1).fill(particle.color)
                }
            }
            .frame(width: particle.width, height: particle.height)
            .rotationEffect(.degrees(value.rotation))
            .scaleEffect(value.scale)
            .offset(x: value.x, y: value.y)
            .opacity(value.opacity)
        } keyframes: { _ in
            // 0%→opacity 0; 10%→opacity 1 (arrival at mx/my); 70%→opacity 1
            // (hold); 100%→opacity 0 (fall to tx/ty). The leading zero-duration
            // hold is each particle's random stagger delay.
            KeyframeTrack(\.opacity) {
                LinearKeyframe(0, duration: particle.delay)
                LinearKeyframe(1, duration: particle.duration * 0.10, timingCurve: Self.curve)
                LinearKeyframe(1, duration: particle.duration * 0.60)
                LinearKeyframe(0, duration: particle.duration * 0.30, timingCurve: Self.curve)
            }
            KeyframeTrack(\.x) {
                LinearKeyframe(0, duration: particle.delay)
                LinearKeyframe(particle.mx, duration: particle.duration * 0.10, timingCurve: Self.curve)
                LinearKeyframe(particle.tx, duration: particle.duration * 0.90, timingCurve: Self.curve)
            }
            KeyframeTrack(\.y) {
                LinearKeyframe(0, duration: particle.delay)
                LinearKeyframe(particle.my, duration: particle.duration * 0.10, timingCurve: Self.curve)
                LinearKeyframe(particle.ty, duration: particle.duration * 0.90, timingCurve: Self.curve)
            }
            KeyframeTrack(\.scale) {
                LinearKeyframe(0.4, duration: particle.delay)
                LinearKeyframe(1.1, duration: particle.duration * 0.10, timingCurve: Self.curve)
                LinearKeyframe(0.85, duration: particle.duration * 0.90, timingCurve: Self.curve)
            }
            KeyframeTrack(\.rotation) {
                LinearKeyframe(0, duration: particle.delay)
                LinearKeyframe(particle.rotation * 0.4, duration: particle.duration * 0.10, timingCurve: Self.curve)
                LinearKeyframe(particle.rotation, duration: particle.duration * 0.90, timingCurve: Self.curve)
            }
        }
        .allowsHitTesting(false)
        .onAppear { burst = true }
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
