import SwiftUI
import DesignSystem

// MARK: - RideHistoryScreen (MYR-191, design/app/shared-screens.jsx
// RideHistoryScreen 34-122, Handoff §5.10 intro)
//
// Rider Ride History tab: segmented Completed ↔ Scheduled, grouped-by-day
// completed rides (`RequestedRideRow`), scheduled reservations
// (`ScheduledRideRow`) that open `ScheduledRideSheet` on tap, header trip
// count + total miles / confirmed count. Renders its own `BottomNav` like
// every other tab screen (see `HomeScreen`'s header comment). Mutations
// (reschedule/cancel) are real local `@State` — mirrors the jsx's own
// `ssS(SCHEDULED_RIDES)` (screen-local, not app-level like `ownerUpcoming`),
// so — like the jsx — they reset if the rider navigates away from this tab
// and back (`RootView`'s `sharedTab` switch remounts this screen the same
// way app.jsx's `screen` routing remounts `RideHistoryScreen`).
struct RideHistoryScreen: View {
    @Binding var sharedTab: String

    private enum Tab: String { case completed, scheduled }

    @State private var tab: Tab = .completed
    @State private var scheduled: [ScheduledRide] = RideHistoryFixtures.scheduledRides
    @State private var activeRideID: String?

    private var completedRides: [RequestedRide] { RideHistoryFixtures.requestedRides }
    private var completedCount: Int { completedRides.count }
    private var totalMiles: Double { completedRides.reduce(0) { $0 + $1.miles } }
    private var scheduledCount: Int { scheduled.count }
    private var confirmedCount: Int { scheduled.filter { $0.status == .confirmed }.count }
    private var activeRide: ScheduledRide? { scheduled.first { $0.id == activeRideID } }

    /// shared-screens.jsx:40-44 `grouped` — day → rides, first-seen order.
    private var groupedCompleted: [(day: String, rides: [RequestedRide])] {
        var order: [String] = []
        var buckets: [String: [RequestedRide]] = [:]
        for ride in completedRides {
            if buckets[ride.day] == nil { order.append(ride.day) }
            buckets[ride.day, default: []].append(ride)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.mrtBg.ignoresSafeArea()

                VStack(spacing: 0) {
                    header
                    ScrollView {
                        VStack(spacing: 0) {
                            segmentedControl
                            switch tab {
                            case .completed: completedContent
                            case .scheduled: scheduledContent
                            }
                        }
                        .padding(.bottom, MRTMetrics.shareContentBottomPadding)
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
            }
            .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
            .overlay {
                ScheduledRideSheet(
                    ride: activeRide,
                    onClose: { activeRideID = nil },
                    onReschedule: reschedule,
                    onCancel: cancel,
                    screenHeight: geo.size.height
                )
            }
        }
    }

    // MARK: Header (shared-screens.jsx:62-69)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your rides")
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            Group {
                if tab == .completed {
                    (Text("\(completedCount) trips \u{00B7} ")
                        + Text("\(totalMiles.formatted(.number.precision(.fractionLength(1)))) mi")
                        .foregroundStyle(Color.mrtGold).fontWeight(.medium))
                } else {
                    (Text("\(scheduledCount) scheduled \u{00B7} ")
                        + Text("\(confirmedCount) confirmed")
                        .foregroundStyle(Color.mrtGold).fontWeight(.medium))
                }
            }
            .font(.system(size: 13))
            .monospacedDigit()
            .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.shareHeaderTop)
        .padding(.bottom, 16)
    }

    // MARK: Segmented control (shared-screens.jsx:73-82, byte-identical to
    // DrivesScreen's — screens.jsx:637-646)

    private var segmentedControl: some View {
        HStack(spacing: 3) {
            segmentItem(.completed, label: completedCount > 0 ? "Completed \u{00B7} \(completedCount)" : "Completed")
            segmentItem(.scheduled, label: scheduledCount > 0 ? "Scheduled \u{00B7} \(scheduledCount)" : "Scheduled")
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
                .frame(minHeight: MRTMetrics.minTapTarget - 6)
                .background(
                    active ? Color.mrtGold : Color.clear,
                    in: RoundedRectangle(cornerRadius: MRTMetrics.drivesSegmentItemRadius, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.18), value: active)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    // MARK: Completed (shared-screens.jsx:84-94)

    @ViewBuilder
    private var completedContent: some View {
        ForEach(groupedCompleted, id: \.day) { group in
            VStack(alignment: .leading, spacing: 0) {
                Text(group.day)
                    .mrtTextStyle(.label())
                    .foregroundStyle(Color.mrtTextMuted)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.bottom, 10)
                ForEach(group.rides) { ride in
                    RequestedRideRow(ride: ride)
                }
            }
            .padding(.bottom, 16)
        }
        Text("Rides you\u{2019}ve requested from shared vehicles")
            .font(.system(size: 11))
            .foregroundStyle(Color.mrtTextMuted)
            .tracking(0.2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    // MARK: Scheduled (shared-screens.jsx:97-112)

    @ViewBuilder
    private var scheduledContent: some View {
        if scheduled.isEmpty {
            emptyScheduledState
        } else {
            ForEach(scheduled) { ride in
                ScheduledRideRow(ride: ride) { activeRideID = ride.id }
            }
            Text("Tap a ride to view details or make changes")
                .font(.system(size: 11))
                .foregroundStyle(Color.mrtTextMuted)
                .tracking(0.2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    private var emptyScheduledState: some View {
        VStack(spacing: 0) {
            Image(systemName: "calendar")
                .font(.system(size: 22))
                .foregroundStyle(Color.mrtTextMuted)
                .frame(width: 52, height: 52)
                .background(Color.mrtDrivesEmptyIconFill, in: Circle())
                .padding(.bottom, 14)
            Text("No scheduled rides")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 4)
            Text("Rides you book for later will appear here.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }

    // MARK: Mutations (shared-screens.jsx:50-57)

    private func reschedule(id: String, day: String, time: String, date: String) {
        guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
        scheduled[index].day = day
        scheduled[index].time = time
        scheduled[index].date = date
        scheduled[index].status = .pending
    }

    private func cancel(id: String) {
        scheduled.removeAll { $0.id == id }
        if activeRideID == id { activeRideID = nil }
    }
}

// MARK: - RideForTag (shared-screens.jsx:24-32)

/// "For {name}" pill — marks a ride booked on behalf of someone else.
struct RideForTag: View {
    let passenger: RidePassenger

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "person.fill").font(.system(size: 9))
            Text("For \(passenger.firstName)")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.mrtGold)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.mrtRideForTagFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtGoldRowBorder, lineWidth: MRTMetrics.hairline))
        .fixedSize()
    }
}

// MARK: - RequestedRideRow (shared-screens.jsx:125-153)

/// Completed ride — elevated neutral card (not gold-tinted, unlike the
/// owner's `DriveRow`/the rider's own `ScheduledRideRow`). No tap
/// destination in M1 — MYR-191's deliverables don't include a ride-detail
/// screen for completed rides (unlike `DrivesScreen`, which already had
/// `DriveSummaryScreen` from MYR-169 to push into).
struct RequestedRideRow: View {
    let ride: RequestedRide

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .lastTextBaseline, spacing: 10) {
                (Text("\(ride.from) ").foregroundStyle(Color.mrtRequestedRowText)
                    + Text("\u{2192} ").foregroundStyle(Color.mrtTextMuted).fontWeight(.regular)
                    + Text(ride.to).foregroundStyle(Color.mrtRequestedRowText))
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 10)
                Text(ride.start)
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextMuted)
                    .fixedSize()
            }
            HStack(spacing: 10) {
                Circle().fill(Color.mrtElevated).frame(width: 26, height: 26)
                    .overlay(Text(ride.driver.prefix(1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mrtText))
                (Text("\(ride.driver)\u{2019}s ").foregroundStyle(Color.mrtText).fontWeight(.medium)
                    + Text(ride.vehicle).foregroundStyle(Color.mrtTextSec))
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // shared-screens.jsx:145 `flex:1, minWidth:0` — this run
                    // is the one flexible element that shrinks/truncates;
                    // the passenger pill + trailing stats keep their
                    // intrinsic size (jsx `flexShrink:0` on both).
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let passenger = ride.passenger {
                    RideForTag(passenger: passenger)
                }
                Text("\(String(format: "%.1f", ride.miles)) mi \u{00B7} \(ride.mins) min")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextMuted)
                    .fixedSize()
            }
        }
        .padding(15)
        .background(
            LinearGradient(
                stops: [
                    .init(color: .mrtRequestedRowTintStart, location: 0),
                    .init(color: .mrtRequestedRowTintMid, location: 0.38),
                    .init(color: .mrtRequestedRowTintEnd, location: 1),
                ],
                startPoint: .topLeading, endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.mrtRequestedRowBorder, lineWidth: MRTMetrics.hairline)
        )
        .shadow(color: .black.opacity(0.28), radius: 10, y: 6)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.bottom, 11)
    }
}

// MARK: - ScheduledRideRow (shared-screens.jsx:156-200)

/// Scheduled ride — gold-tinted reservation card mirroring `DriveRow`/
/// `UpcomingRow`'s recipe (MYR-169) verbatim; see `Tokens.swift`'s MYR-191
/// section header comment.
struct ScheduledRideRow: View {
    let ride: ScheduledRide
    let onTap: () -> Void

    private var confirmed: Bool { ride.status == .confirmed }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.mrtGold)
                        .frame(width: 38, height: 38)
                        .background(Color.mrtUpcomingIconFill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.mrtUpcomingIconBorder, lineWidth: MRTMetrics.hairline)
                        )
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("\(ride.from) ").foregroundStyle(Color.mrtGoldRowText)
                            + Text("\u{2192} ").foregroundStyle(Color.mrtGold).fontWeight(.regular)
                            + Text(ride.to).foregroundStyle(Color.mrtGoldRowText))
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        (Text("\(ride.day) \(ride.time) ").foregroundStyle(Color.mrtGold).fontWeight(.semibold)
                            + Text("\u{00B7} \(String(format: "%.1f", ride.miles)) mi").foregroundStyle(Color.mrtTextSec))
                            .font(.system(size: 12.5))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.mrtGoldRowChevron)
                }
                HStack(spacing: 10) {
                    Circle().fill(Color.mrtElevated).frame(width: 26, height: 26)
                        .overlay(Text(ride.driver.prefix(1)).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mrtText))
                    (Text("\(ride.driver)\u{2019}s ").foregroundStyle(Color.mrtText).fontWeight(.medium)
                        + Text(ride.vehicle).foregroundStyle(Color.mrtTextSec))
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // shared-screens.jsx:185 `flex:1, minWidth:0` — see
                        // `RequestedRideRow`'s identical comment.
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let passenger = ride.passenger {
                        RideForTag(passenger: passenger)
                    }
                    statusChip
                }
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

    private var statusChip: some View {
        HStack(spacing: 5) {
            Circle().fill(confirmed ? Color.mrtDriving : Color.mrtTextMuted).frame(width: 5, height: 5)
            Text(confirmed ? "Confirmed" : "Pending")
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(confirmed ? Color.mrtDriving : Color.mrtTextSec)
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(confirmed ? Color.mrtRideConfirmedChipFill : Color.mrtRidePendingChipFill, in: Capsule())
    }

    /// Byte-identical to `DriveRow`/`UpcomingRow`'s gradient (MYR-169) —
    /// see `Tokens.swift`'s MYR-191 section header comment.
    private var goldRowGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .mrtGoldRowTintStart, location: 0),
                .init(color: .mrtGoldRowTintMid, location: 0.34),
                .init(color: .mrtRowTintFaint, location: 1),
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

#Preview {
    RideHistoryScreen(sharedTab: .constant("rideHistory"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
