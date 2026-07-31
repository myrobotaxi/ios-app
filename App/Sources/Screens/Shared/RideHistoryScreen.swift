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
// MYR-171 — `completedRides` now reads from `RideHistoryStore` (lifted at
// `RootView`, not screen-local) instead of the static fixture directly, so a
// ride the rider just finished on Live Map (`RideRequestService
// .completeAndReset()`) shows up here even if this screen wasn't the one on
// screen when it completed. Scheduled-ride mutations stay screen-local, per
// this file's own header comment above.
// MYR-197 — a tapped `RequestedRideRow` sets `historyStore.openRideID`
// (app.jsx:127 `onOpenRide`); `RootView` reads it the same way it already
// reads `OwnerDrivesState.openDriveID` for `DrivesScreen`, pushing
// `DriveSummaryScreen` on top of this screen. Fixes a bug where tapping a
// completed ride row did nothing — MYR-191 shipped the row without a tap
// handler (see `RequestedRideRow`'s previous header comment, now stale).
struct RideHistoryScreen: View {
    @Binding var sharedTab: String
    @Bindable var historyStore: RideHistoryStore
    /// MYR-228 — LIVE seeds the SCREEN-LOCAL scheduled list empty; SIM keeps the
    /// fixtures so every simulated/DEBUG scene (scheduledDetails/Reschedule/…)
    /// stays pixel-identical.
    var isLive: Bool = false

    /// MYR-377 — the LIVE Scheduled tab, or `nil` in SIM / static-token dev.
    ///
    /// The live branch used to be the literal `[]`, under a comment claiming there
    /// was no scheduled-ride backend. There has been one since MYR-174, so the
    /// client's accepted reservation for the next day rendered as "0 scheduled · 0
    /// confirmed / No scheduled rides" while it sat in the database, confirmed.
    var scheduledStore: RiderScheduledRidesStore?

    private enum Tab: String { case completed, scheduled }

    @State private var tab: Tab = .completed
    /// The SIMULATED list. Screen-local and mutable exactly as the jsx's own
    /// `ssS(SCHEDULED_RIDES)` is — see this file's header. The live list is the
    /// store's and is never written here.
    @State private var scheduled: [ScheduledRide]
    @State private var activeRideID: String?

    init(
        sharedTab: Binding<String>,
        historyStore: RideHistoryStore,
        isLive: Bool = false,
        scheduledStore: RiderScheduledRidesStore? = nil
    ) {
        _sharedTab = sharedTab
        self.historyStore = historyStore
        self.isLive = isLive
        self.scheduledStore = scheduledStore
        _scheduled = State(initialValue: isLive ? [] : RideHistoryFixtures.scheduledRides)
    }

    private var completedRides: [RequestedRide] { historyStore.completedRides }
    private var completedCount: Int { completedRides.count }
    private var totalMiles: Double { completedRides.reduce(0) { $0 + $1.miles } }
    /// The ONE list this screen renders: the server's when there is a store, the
    /// screen-local fixture array otherwise. Every count, the segment badge, the
    /// rows and the sheet all read through here, so the header can never disagree
    /// with what is under it — which is precisely what "0 scheduled" over a real
    /// reservation was.
    private var scheduledRides: [ScheduledRide] { scheduledStore?.rides ?? scheduled }
    private var scheduledCount: Int { scheduledRides.count }
    private var confirmedCount: Int { scheduledRides.filter { $0.status == .confirmed }.count }
    private var activeRide: ScheduledRide? { scheduledRides.first { $0.id == activeRideID } }

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
                    screenHeight: geo.size.height,
                    // MYR-377 — MYR-192's reschedule endpoints do not exist in the
                    // Kit, so the live sheet disables the button and says why rather
                    // than opening a picker whose "Move to…" resolves to nothing.
                    rescheduleAvailable: scheduledStore == nil
                )
            }
            // MYR-377 — read the rider's own reservations. A no-op in SIM (no store
            // is composed there), so every simulated and DEBUG capture is unchanged.
            .task { await scheduledStore?.load() }
            // A refused cancel says so, in the app's quiet-toast grammar, and the
            // row stays where it is.
            //
            // MYR-381 — in the FAILURE look. It shipped as `mrtSuccessToast`'s
            // default, which put a gold ✓ over "Couldn't cancel that ride" in the
            // client's own screenshot: the glyph said the opposite of the sentence
            // it was next to.
            .mrtFailureToast(
                isPresented: Binding(
                    get: { scheduledStore?.failureNotice != nil },
                    set: { if !$0 { scheduledStore?.failureNotice = nil } }
                ),
                message: scheduledStore?.failureNotice ?? ""
            )
            #if DEBUG
            .onAppear { // MYR-200 scheduled* scenes: auto-open the sheet
                if activeRideID == nil, let id = DebugScene.current?.scheduledRideID { activeRideID = id }
                // MYR-377 — and land on the SCHEDULED segment for the one scene whose
                // subject is that list. Headless tooling cannot tap a segmented
                // control; every other scene keeps the `.completed` default.
                if DebugScene.current?.opensScheduledTab == true { tab = .scheduled }
            }
            #endif
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
                    RequestedRideRow(ride: ride) { historyStore.openRideID = ride.id }
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
        if scheduledRides.isEmpty {
            // MYR-326's rule: a list still in flight is NOT "you have none". The
            // honest empty state waits for an answer rather than asserting one.
            if scheduledStore?.isLoading == true {
                Color.clear.frame(height: MRTMetrics.rideMapPreviewHeight)
            } else {
                emptyScheduledState
            }
        } else {
            ForEach(scheduledRides) { ride in
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

    /// MYR-377 — RESCHEDULE IS SIMULATED-ONLY, AND THE UI SAYS SO ON LIVE.
    ///
    /// The wire has the shape for it (`RideRequest.rescheduleProposedFor` /
    /// `rescheduleStatus`), but the Kit's `RestClient` exposes NO reschedule call —
    /// grepped, and there is none: the endpoints are MYR-192 and are not built. The
    /// prototype's picker is also a hard-coded June-2026 day/date table
    /// (`ScheduledRideSheet.schedDates`), so wiring it against nothing would offer
    /// a rider a set of days from last June and then silently do nothing with the
    /// one they chose. The affordance stays where the prototype puts it and is
    /// DISABLED on the live path with an honest caption — see
    /// `ScheduledRideSheet.rescheduleAvailable`.
    private func reschedule(id: String, day: String, time: String, date: String) {
        guard let index = scheduled.firstIndex(where: { $0.id == id }) else { return }
        scheduled[index].day = day
        scheduled[index].time = time
        scheduled[index].date = date
        scheduled[index].status = .pending
    }

    /// MYR-377 — the live cancel is the REAL `POST /{id}/cancel`, surfaced honestly
    /// and followed by a re-read. Never an optimistic removal: a rider who believes
    /// a ride is cancelled when it is not simply will not be there when the car
    /// arrives. The simulated path keeps the prototype's local removal exactly.
    private func cancel(id: String) {
        if let scheduledStore {
            Task {
                await scheduledStore.cancel(id: id)
                if scheduledStore.rides.contains(where: { $0.id == id }) == false { activeRideID = nil }
            }
            return
        }
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
/// owner's `DriveRow`/the rider's own `ScheduledRideRow`). MYR-197 — tapping
/// it opens the ride's summary via `DriveSummaryScreen` (shared-screens.jsx
/// `onClick={() => onOpenRide && onOpenRide(r)}`, app.jsx:127-129 routes that
/// into the SAME `DriveSummaryScreen` the owner's `DrivesScreen` pushes for a
/// `DRIVES` row — see `RequestedRide.asDrive`); `RootView` reads
/// `RideHistoryStore.openRideID` to decide whether to push it, mirroring
/// `OwnerDrivesState.openDriveID`'s pattern for `DrivesScreen`.
struct RequestedRideRow: View {
    let ride: RequestedRide
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
                    // MYR-382 — the same possessive sweep as the cancel dialog's.
                    // A completed row is fixture-fed today, so this renders
                    // byte-identically; it is guarded because the composition is
                    // the one that produced "with 's Lunar" and a second unguarded
                    // copy is how that comes back on the next surface to go live.
                    (Text(ride.driver.isEmpty ? "" : "\(ride.driver)\u{2019}s ").foregroundStyle(Color.mrtText).fontWeight(.medium)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    // MYR-377 — a LIVE reservation names no owner (the wire carries
                    // none anywhere), so the avatar falls back to a car glyph and
                    // the line to the vehicle alone. Every fixture row has a driver,
                    // so the simulated render is byte-identical.
                    Circle().fill(Color.mrtElevated).frame(width: 26, height: 26)
                        .overlay {
                            if let initial = ScheduledRideDisplay.avatarInitial(ride) {
                                Text(initial).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mrtText)
                            } else {
                                Image(systemName: "car.fill").font(.system(size: 10)).foregroundStyle(Color.mrtTextSec)
                            }
                        }
                    Group {
                        if ride.driver.isEmpty {
                            Text(ride.vehicle).foregroundStyle(Color.mrtText).fontWeight(.medium)
                        } else {
                            Text("\(ride.driver)\u{2019}s ").foregroundStyle(Color.mrtText).fontWeight(.medium)
                                + Text(ride.vehicle).foregroundStyle(Color.mrtTextSec)
                        }
                    }
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
    RideHistoryScreen(sharedTab: .constant("rideHistory"), historyStore: RideHistoryStore())
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
