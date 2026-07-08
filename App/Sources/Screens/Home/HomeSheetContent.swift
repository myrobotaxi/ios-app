import SwiftUI
import DesignSystem

// MARK: - Bottom-sheet hero content (MYR-167 deliverable 3,
// design/app/screens.jsx:439-599)
//
// Two hero states, matching `HomeScreen`'s `driving ? DrivingSheetContent :
// ParkedSheetContent`. Both take `expanded` (true at the `.half` detent) and
// append a `VehicleControlsPlaceholder` there — the real tiles are MYR-168.

/// screens.jsx:439-499 `DrivingSheetContent`.
struct DrivingHeroContent: View {
    let vehicleName: String
    let trip: DrivingTrip
    let snapshot: VehicleTelemetrySnapshot
    let expanded: Bool

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
                        Text("· \(vehicleName)")
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

            if expanded {
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
                    VehicleControlsPlaceholder()
                }
                .transition(.opacity)
            }
        }
    }
}

/// screens.jsx:522-599 `ParkedSheetContent`, `style: 'floating'` branch only
/// — the app's single shipped `parkedStyle` (see `VehicleFixtures.swift`
/// header comment and Metrics.swift `homePeekHeightParked`).
struct ParkedHeroContent: View {
    let vehicleName: String
    let location: ParkedLocation
    let snapshot: VehicleTelemetrySnapshot
    let expanded: Bool

    private var parkedDuration: String {
        let seconds = max(0, Date().timeIntervalSince(location.parkedSince))
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    HStack(spacing: 10) {
                        Text(vehicleName)
                            .font(.system(size: 18, weight: .semibold))
                            .tracking(-0.3)
                            .foregroundStyle(Color.mrtText)
                        StatusBadge(.parked)
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
                BatteryBar(pct: snapshot.batteryPercent)
                HStack {
                    Text(location.label)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(parkedDuration)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextMuted)
                        .fixedSize()
                }
            }

            if expanded {
                VehicleControlsPlaceholder()
                    .transition(.opacity)
            }
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

/// The half-detent `VehicleControls` reservation MYR-168 fills in
/// (Handoff §5.5 "half reveals `VehicleControls`"). M1 ships layout only —
/// a section label and a reserved, empty tile-row-height card.
struct VehicleControlsPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().overlay(Color.mrtBorder).padding(.vertical, 8)
            Text("Controls").mrtTextStyle(.label()).foregroundStyle(Color.mrtTextMuted)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.mrtText.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .frame(height: MRTMetrics.homeControlsPlaceholderHeight)
                .overlay {
                    Text("Controls")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.mrtTextMuted)
                }
                .accessibilityLabel("Vehicle controls — coming soon")
        }
    }
}
