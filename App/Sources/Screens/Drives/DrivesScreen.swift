import SwiftUI
import DesignSystem

// MARK: - DrivesScreen (MYR-169, design/app/screens.jsx:604-797, Handoff §5.6)
//
// Owner Drives tab: segmented History ↔ Upcoming, a live-trip banner while
// the selected vehicle is driving, grouped drive rows (Today/Yesterday/…),
// and upcoming reserved rides with a destructive cancel confirmation. Renders
// its own `BottomNav` like every other owner screen (see `HomeScreen`'s
// header comment) — replaces the MYR-167 `PlaceholderScreen` for the
// "drives" tab.
struct DrivesScreen: View {
    @Bindable var homeState: OwnerHomeState
    @Bindable var drivesState: OwnerDrivesState
    @Binding var ownerTab: String

    private enum Tab: String { case history, upcoming }
    private enum SortKey: String, CaseIterable { case date, distance, duration }

    @State private var tab: Tab = .history
    @State private var sort: SortKey = .date
    @State private var confirmCancel: UpcomingRide?
    @State private var showCancelledToast = false

    private var vehicle: Vehicle { homeState.selectedVehicle }

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        segmentedControl
                        switch tab {
                        case .history: historyContent
                        case .upcoming: upcomingContent
                        }
                    }
                    .padding(.bottom, MRTMetrics.drivesContentBottomPadding)
                }
            }

            BottomNav(selection: $ownerTab, tabs: MRTTab.ownerTabs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .mrtConfirmDialog(
            isPresented: Binding(
                get: { confirmCancel != nil },
                set: { if !$0 { confirmCancel = nil } }
            ),
            config: cancelDialogConfig
        )
        .mrtSuccessToast(isPresented: $showCancelledToast, message: "Reservation cancelled")
    }

    // MARK: Header (screens.jsx:631-634)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drives")
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            // screens.jsx:633 `${VEHICLES[0].name} · 42,184 mi total` —
            // odometer figure is fixture-only, ported verbatim.
            Text("\(vehicle.name) · 42,184 mi total")
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.drivesHeaderTop)
        .padding(.bottom, 16)
    }

    // MARK: Segmented control (screens.jsx:637-646)

    private var segmentedControl: some View {
        HStack(spacing: 3) {
            segmentItem(.history, label: "History")
            segmentItem(
                .upcoming,
                label: drivesState.upcoming.isEmpty ? "Upcoming" : "Upcoming · \(drivesState.upcoming.count)"
            )
        }
        .padding(3)
        .background(Color.mrtDrivesSegmentTrack, in: RoundedRectangle(cornerRadius: MRTMetrics.drivesSegmentRadius, style: .continuous))
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 18)
    }

    private func segmentItem(_ key: Tab, label: String) -> some View {
        let active = tab == key
        return Button {
            tab = key
        } label: {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(active ? Color.mrtGoldButtonLabel : Color.mrtTextSec)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .frame(minHeight: MRTMetrics.minTapTarget - 6) // 3pt track padding × 2 tops it up to 44pt
                .background(
                    active ? Color.mrtGold : Color.clear,
                    in: RoundedRectangle(cornerRadius: MRTMetrics.drivesSegmentItemRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: active) // background/color .18s
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: History (screens.jsx:648-695)

    @ViewBuilder
    private var historyContent: some View {
        // screens.jsx:650 `{driving && …}` — this app gives each vehicle a
        // fixed activity rather than an app-wide toggle (see
        // `VehicleFixtures.swift` header comment), so "driving" here means
        // "the selected vehicle's fixed activity is driving".
        if case .driving(let trip) = vehicle.activity {
            LiveTripBanner(trip: trip, snapshot: homeState.selectedTelemetry.snapshot) {
                ownerTab = "home"
            }
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.bottom, 16)
        }

        sortMenu

        ForEach(groupedDrives, id: \.key) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group.key)
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.bottom, 10)
                ForEach(group.drives) { drive in
                    DriveRow(drive: drive) { drivesState.openDriveID = drive.id }
                }
            }
            .padding(.bottom, 16)
        }
    }

    private var sortMenu: some View {
        HStack(spacing: 8) {
            Text("Sort by")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.mrtTextMuted)
            HStack(spacing: 6) {
                ForEach(SortKey.allCases, id: \.self) { key in
                    sortChip(key)
                }
            }
        }
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 14)
    }

    private func sortChip(_ key: SortKey) -> some View {
        let active = sort == key
        return Button {
            sort = key
        } label: {
            Text(key.rawValue.capitalized)
                .font(.system(size: 12, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(active ? Color.mrtGold : Color.mrtTextSec)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .frame(minHeight: MRTMetrics.minTapTarget - 14)
                .background(active ? Color.mrtDrivesSortChipActive : Color.clear, in: Capsule())
                .overlay(active ? nil : Capsule().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    /// screens.jsx:615-626 `sortedDrives`/`grouped` — sort by date (grouped
    /// by day) or flatten into a single "All drives" group sorted by
    /// distance/duration descending.
    private var groupedDrives: [(key: String, drives: [Drive])] {
        switch sort {
        case .date:
            var order: [String] = []
            var buckets: [String: [Drive]] = [:]
            for drive in DriveFixtures.drives {
                if buckets[drive.dateGroup] == nil { order.append(drive.dateGroup) }
                buckets[drive.dateGroup, default: []].append(drive)
            }
            return order.map { (Drive.groupLabel(for: $0), buckets[$0] ?? []) }
        case .distance:
            return [("All drives", DriveFixtures.drives.sorted { $0.miles > $1.miles })]
        case .duration:
            return [("All drives", DriveFixtures.drives.sorted { $0.mins > $1.mins })]
        }
    }

    // MARK: Upcoming (screens.jsx:696-710)

    @ViewBuilder
    private var upcomingContent: some View {
        if sortedUpcoming.isEmpty {
            emptyUpcomingState
        } else {
            ForEach(sortedUpcoming) { ride in
                UpcomingRow(ride: ride) { confirmCancel = ride }
            }
        }
    }

    private var emptyUpcomingState: some View {
        VStack(spacing: 0) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(Color.mrtTextMuted)
                .frame(width: 52, height: 52)
                .background(Color.mrtDrivesEmptyIconFill, in: Circle())
                .padding(.bottom, 14)
            Text("No upcoming rides")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 4)
            Text("Scheduled rides you accept will appear here.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }

    /// screens.jsx:609-614 `DAY_ORDER` + `toMin` — Today/Tomorrow/weekday
    /// order, then time-of-day within a day.
    private static let dayOrder = ["Today", "Tomorrow", "Thu", "Fri", "Sat", "Sun", "Mon"]

    private static func minutesOfDay(_ time: String) -> Int {
        let parts = time.split(separator: " ")
        guard parts.count == 2 else { return 0 }
        let clock = parts[0].split(separator: ":")
        guard clock.count == 2, var hour = Int(clock[0]), let minute = Int(clock[1]) else { return 0 }
        hour %= 12
        if parts[1].uppercased() == "PM" { hour += 12 }
        return hour * 60 + minute
    }

    private var sortedUpcoming: [UpcomingRide] {
        drivesState.upcoming.sorted { a, b in
            let dayA = Self.dayOrder.firstIndex(of: a.scheduleDay) ?? Self.dayOrder.count
            let dayB = Self.dayOrder.firstIndex(of: b.scheduleDay) ?? Self.dayOrder.count
            if dayA != dayB { return dayA < dayB }
            return Self.minutesOfDay(a.scheduleTime) < Self.minutesOfDay(b.scheduleTime)
        }
    }

    // MARK: Cancel-reservation dialog (screens.jsx:713-739)

    private var cancelDialogConfig: MRTConfirmDialogConfig {
        let ride = confirmCancel
        return MRTConfirmDialogConfig(
            kind: .destructive,
            icon: "calendar",
            title: "Cancel this reservation?",
            message: ride.map {
                "This cancels \($0.destination.label) on \($0.scheduleDay) \($0.scheduleTime) for \($0.rider)."
            } ?? "",
            actionLabel: "Cancel reservation",
            dismissLabel: "Keep it"
        ) {
            guard let ride else { return }
            drivesState.cancelUpcoming(id: ride.id)
            showCancelledToast = true
        }
    }
}

// MARK: - Live-trip banner (screens.jsx:650-673)

private struct LiveTripBanner: View {
    let trip: DrivingTrip
    let snapshot: VehicleTelemetrySnapshot
    let onTap: () -> Void

    /// screens.jsx:668 "28.4 mi" is a static demo figure — derived here from
    /// the real route length so it tracks the live `progress` instead
    /// (VehicleRoute.swift `totalDistanceMiles`).
    private var remainingMiles: Double {
        VehicleRoute.totalDistanceMiles(along: trip.route) * (1 - snapshot.progress)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PulseDot(color: .mrtDriving)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        (Text("\(trip.originLabel) ")
                            .foregroundStyle(Color.mrtDrivingRowText)
                            + Text("→ ").foregroundStyle(Color.mrtDriving).fontWeight(.regular)
                            + Text(trip.destinationCity).foregroundStyle(Color.mrtDrivingRowText))
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text("EN ROUTE")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Color.mrtDriving)
                            .fixedSize()
                    }
                    (Text("\(snapshot.etaMinutes) min ").foregroundStyle(Color.mrtDriving).fontWeight(.semibold)
                        + Text("remaining · \(String(format: "%.1f", remainingMiles)) mi").foregroundStyle(Color.mrtTextSec))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mrtDrivingRowChevron)
            }
            .padding(15)
            .background(
                LinearGradient(
                    stops: [
                        .init(color: .mrtDrivingRowTintStart, location: 0),
                        .init(color: .mrtDrivingRowTintMid, location: 0.42),
                        .init(color: .mrtRowTintFaint, location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.mrtDrivingRowBorder, lineWidth: MRTMetrics.hairline)
            )
            .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - DriveRow (screens.jsx:772-797)

private struct DriveRow: View {
    let drive: Drive
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .lastTextBaseline) {
                        (Text("\(drive.from) ").foregroundStyle(Color.mrtGoldRowText)
                            + Text("→ ").foregroundStyle(Color.mrtGold).fontWeight(.regular)
                            + Text(drive.to).foregroundStyle(Color.mrtGoldRowText))
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 10)
                        Text(drive.start)
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtGoldTimeLabel)
                            .fixedSize()
                    }
                    (Text("\(String(format: "%.1f", drive.miles)) mi · \(drive.mins) min · ")
                        .foregroundStyle(Color.mrtTextSec)
                        + Text("\(drive.fsdPercent)% FSD").foregroundStyle(Color.mrtGold).fontWeight(.semibold))
                        .font(.system(size: 12.5))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.mrtGoldRowChevron)
            }
            .padding(15)
            .background(goldRowGradient, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.mrtGoldRowBorder, lineWidth: MRTMetrics.hairline)
            )
            .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 11)
    }
}

// MARK: - UpcomingRow (screens.jsx:746-770)

private struct UpcomingRow: View {
    let ride: UpcomingRide
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: "calendar")
                .font(.system(size: 16))
                .foregroundStyle(Color.mrtGold)
                .frame(width: MRTMetrics.upcomingIconTileSize, height: MRTMetrics.upcomingIconTileSize)
                .background(Color.mrtUpcomingIconFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.mrtUpcomingIconBorder, lineWidth: MRTMetrics.hairline)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(ride.destination.label)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtGoldRowText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                (Text("\(ride.scheduleDay) \(ride.scheduleTime) ").foregroundStyle(Color.mrtGold).fontWeight(.semibold)
                    + Text("· For \(ride.rider)").foregroundStyle(Color.mrtTextSec))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(width: MRTMetrics.upcomingCancelButtonSize, height: MRTMetrics.upcomingCancelButtonSize)
                    .background(Color.mrtDrivesCancelButtonFill, in: Circle())
                    // 44pt hit target on a 28pt visual circle.
                    .contentShape(Circle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.upcomingCancelButtonSize) / 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reserved ride")
        }
        .padding(14)
        .background(goldRowGradient, in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.mrtGoldRowBorder, lineWidth: MRTMetrics.hairline)
        )
        .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 11)
    }
}

/// Shared 122°-ish gold gradient used by both `DriveRow` and `UpcomingRow`
/// (screens.jsx:750,778 — byte-identical stop colors, only the mid-stop
/// location differs, which SwiftUI's `LinearGradient` doesn't need since
/// both rows use the same 0/34%/100% split here).
private var goldRowGradient: LinearGradient {
    LinearGradient(
        stops: [
            .init(color: .mrtGoldRowTintStart, location: 0),
            .init(color: .mrtGoldRowTintMid, location: 0.34),
            .init(color: .mrtRowTintFaint, location: 1),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

#Preview {
    let homeState = OwnerHomeState()
    return DrivesScreen(homeState: homeState, drivesState: OwnerDrivesState(), ownerTab: .constant("drives"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
        .onAppear { homeState.startTelemetry() }
}
