import SwiftUI
import MapKit
import Foundation
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
// `ShareLink` (backs onto `UIActivityViewController`) sharing a plain-text
// summary.
//
// Scope note: screens.jsx's `DriveSummaryScreen` also has a "100% FSD"
// celebration (a confetti burst + a warm gold page-wide wash that fades in
// after the ring sweep completes, screens.jsx:852-886,1030-1136). Handoff
// §5.6 doesn't list it among this screen's deliverables (only hero map / stat
// grid / sparkline / FSD stat / share), so it's deliberately out of scope
// here — the FSD ring itself still renders correctly at 100% (d8, an
// Embarcadero→Mission drive, hits exactly 100%), just without the bonus
// animation. Documented in the PR body's drift-gate section.
struct DriveSummaryScreen: View {
    let drive: Drive
    let onBack: () -> Void

    private let dateLabel: String
    private let heroRegion: MKCoordinateRegion
    private let speeds: [Double]
    private let avgSpeedMPH: Int
    private let maxSpeedMPH: Int
    private let startBatteryPercent: Int
    private let endBatteryPercent: Int

    init(drive: Drive, onBack: @escaping () -> Void) {
        self.drive = drive
        self.onBack = onBack
        self.dateLabel = Drive.groupLabel(for: drive.dateGroup)
        self.heroRegion = VehicleRoute.fittedRegion(for: drive.route)

        // screens.jsx:836-849 `seedN`/`speeds`/`startPct`/`endPct` — ported
        // verbatim (same char-code-sum seed, same LCG, same formulas) so
        // each drive's numbers are stable across renders and match the
        // prototype's own derivation for the same fixture id.
        let seedN = drive.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let computedSpeeds = Self.speedTrace(seed: seedN + 7)
        self.speeds = computedSpeeds
        self.maxSpeedMPH = Int((computedSpeeds.max() ?? 0).rounded())
        self.avgSpeedMPH = Int((computedSpeeds.reduce(0, +) / Double(computedSpeeds.count) + 6).rounded())
        let startPct = min(97, 76 + seedN % 18)
        self.startBatteryPercent = startPct
        self.endBatteryPercent = max(6, startPct + drive.batteryDeltaPercent)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                headerSection
                recapGrid
                Spacer().frame(height: 14)
            }
        }
        .background(Color.mrtBg.ignoresSafeArea())
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Hero map (screens.jsx:873-897)

    private var heroSection: some View {
        ZStack {
            DriveHeroMap(route: drive.route, region: heroRegion)

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

            ShareLink(item: shareSummary) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.mrtGold)
                    .frame(width: MRTMetrics.driveSummaryFloatingButtonSize, height: MRTMetrics.driveSummaryFloatingButtonSize)
                    .background(Color.mrtDsFloatingNavFill, in: Circle())
                    .overlay(Circle().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
                    .contentShape(Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.driveSummaryFloatingButtonSize) / 2))
            }
            .accessibilityLabel("Share this drive")
        }
        .padding(.horizontal, 16)
        .padding(.top, 52)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// screens.jsx's share button has no `onClick` wired (dead affordance in
    /// the prototype) — Handoff §5.6 explicitly calls for a real
    /// `UIActivityViewController` share here, backing a plain-text summary.
    private var shareSummary: String {
        """
        \(drive.from) → \(drive.to)
        \(dateLabel) · \(drive.start) – \(drive.end)
        \(String(format: "%.1f", drive.miles)) mi · \(drive.mins) min · \(drive.fsdPercent)% FSD
        """
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
                Text(drive.from).foregroundStyle(Color.mrtText)
                Text("→").foregroundStyle(Color.mrtGold).fontWeight(.regular)
                Text(drive.to).foregroundStyle(Color.mrtText)
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

            SpeedSparklineTile(speeds: speeds)

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

// MARK: - DS_TILE shared chrome (screens.jsx:992-997)

private var dsTileGradient: LinearGradient {
    LinearGradient(colors: [.mrtDsTileTintStart, .mrtDsTileTintEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
}

private extension View {
    func dsTileChrome() -> some View {
        padding(.horizontal, 16)
            .padding(.vertical, 14)
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
        .dsTileChrome()
    }
}

/// screens.jsx:1050-1136 `DSRing` — two-tone gold activity ring, fills from 0
/// on appear. The 100%-FSD confetti celebration is out of scope here (see
/// this file's header comment); the ring itself still sweeps to a full
/// circle and the center label turns gold at 100%.
private struct FSDRing: View {
    let percent: Int
    var size: CGFloat = 82
    var stroke: CGFloat = 9

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep: Double = 0

    private var fraction: Double { min(1, Double(percent) / 100) }

    var body: some View {
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
        .onAppear {
            if reduceMotion {
                sweep = fraction
            } else {
                withAnimation(.timingCurve(0.32, 0.72, 0, 1, duration: 1.15).delay(0.12)) {
                    sweep = fraction
                }
            }
        }
    }
}

// MARK: - Battery tile (screens.jsx:929-950)

private struct BatteryTile: View {
    let usedPercent: Int
    let startPercent: Int
    let endPercent: Int

    private var endColor: Color { .mrtBatteryColor(Double(endPercent)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Battery")
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                Spacer()
                Text("\(usedPercent)% used")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
            }
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                percentLabel(startPercent, color: .mrtText)
                Text("→").font(.system(size: 16)).foregroundStyle(Color.mrtTextMuted)
                percentLabel(endPercent, color: endColor)
            }
            GeometryReader { geo in
                let startWidth = geo.size.width * CGFloat(startPercent) / 100
                let endWidth = geo.size.width * CGFloat(endPercent) / 100
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.mrtElevated)
                        .overlay(Capsule().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                    Capsule().fill(Color.mrtText.opacity(0.11)).frame(width: startWidth)
                    Capsule()
                        .fill(LinearGradient(colors: [endColor.opacity(0.73), endColor], startPoint: .leading, endPoint: .trailing))
                        .frame(width: endWidth)
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
            .frame(height: 10)
            .padding(.top, 4)
        }
        .dsTileChrome()
    }

    private func percentLabel(_ value: Int, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 28, weight: .medium))
                .monospacedDigit()
                .tracking(-1)
            Text("%")
                .font(.system(size: 16, weight: .medium))
        }
        .foregroundStyle(color)
        .fixedSize()
    }
}

// MARK: - Speed sparkline tile (MYR-169 addition — see file header; geometry
// ported from screens.jsx `DSSparkline`, 1168-1183)

private struct SpeedSparklineTile: View {
    let speeds: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Speed")
                .mrtTextStyle(.label())
                .foregroundStyle(Color.mrtTextMuted)
            MRTSparkline(values: speeds)
                .frame(height: 52)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsTileChrome()
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
