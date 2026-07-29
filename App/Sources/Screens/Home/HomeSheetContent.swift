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

    private var rangeMi: Int { Int(((snapshot.batteryPercent / 100) * 272).rounded()) }

    private var arrivalTime: String {
        let date = Date().addingTimeInterval(Double(snapshot.etaMinutes) * 60)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
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

                VStack(spacing: 10) {
                    HStack(alignment: .lastTextBaseline) {
                        Text(trip.destinationName)
                            .font(.system(size: 28, weight: .semibold))
                            .tracking(-0.8)
                            .foregroundStyle(Color.mrtText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 12)
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
                    HStack(alignment: .firstTextBaseline) {
                        (Text("Arriving in ")
                            .foregroundStyle(Color.mrtTextSec)
                            + Text("\(snapshot.etaMinutes) min")
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
            }

            TripProgressBar(progress: snapshot.progress, compact: true)
        }
        .mrtFreshnessStamp(freshness)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        StatusBadge(status)
                    }
                    Spacer()
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
            BatteryBar(pct: snapshot.batteryPercent)
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

    var body: some View {
        // Outer gap 22 (screens.jsx:449 `gap: 22`) between the summary block and
        // the route/controls reveal block; the reveal block itself is gap 0 with
        // the `Divider pad={8}` supplying the inner spacing (screens.jsx:490-497).
        VStack(alignment: .leading, spacing: 22) {
            // Summary — rendered identically to the peek `DrivingSummary` so the
            // crossfade reads as a stationary summary with controls fading in
            // beneath it (MYR-236 round 5.3).
            DrivingSummary(vehicle: vehicle, trip: trip, snapshot: snapshot, freshness: freshness)

            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(Color.mrtBorder).padding(.vertical, 8)
                Text("Route").mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted).padding(.bottom, 8)
                RouteLeg(title: trip.originLabel, subtitle: trip.originAddress, color: .mrtDriving, isFirst: true, isLast: false)
                RouteLeg(
                    title: "\(trip.destinationCity) · \(trip.destinationName)",
                    subtitle: trip.destinationAddress,
                    color: .mrtGold,
                    isFirst: false,
                    isLast: true
                )
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
                serviceEstimatedEndAt: serviceEstimatedEndAt
            )
        }
    }
}

/// screens.jsx:501-520 `RouteLeg` — a connected-dot timeline row.
private struct RouteLeg: View {
    let title: String
    let subtitle: String
    let color: Color
    let isFirst: Bool
    let isLast: Bool

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
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
            }
            .padding(.bottom, 6)
        }
        .padding(.vertical, 6)
    }
}
