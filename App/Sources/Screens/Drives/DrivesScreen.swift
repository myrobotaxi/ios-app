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
    /// MYR-287 — the ONE resolved live/sim flag (threaded from `RootView`, the
    /// same value `HomeScreen` receives). Gates the header's lifetime-odometer
    /// figure: the prototype's fixture "42,184 mi" is simulated-only; live reads
    /// the car's real odometer. See `headerSubtitle`.
    var isLive: Bool = false

    private enum Tab: String { case history, upcoming }
    private enum SortKey: String, CaseIterable { case date, distance, duration }

    @State private var tab: Tab = .history
    @State private var sort: SortKey = .date
    @State private var confirmCancel: UpcomingRide?

    private var vehicle: Vehicle? { homeState.selectedVehicle }

    // MYR-203 — the drive-history source behind the fleet seam: `DriveFixtures`
    // for the simulated fleet, the live cursor-paginated feed for the live fleet.
    // The screen reads it identically for both.
    private var feed: any DrivesFeed { homeState.selectedDrivesFeed }

    #if DEBUG
    /// Verification hook — see the `.onChange`/`.onAppear` call sites.
    private func autoOpenFirstDriveIfRequested() {
        guard DebugScene.autoOpenFirstDrive,
              drivesState.openDriveID == nil,
              let first = feed.drives.first else { return }
        drivesState.openDriveID = first.id
    }
    #endif

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
            // screens.jsx:631 `padding: '74px 24px 16px'` is measured from
            // the physical screen edge (full-bleed canvas); ignore the top
            // safe area so `header`'s `drivesHeaderTop` padding measures
            // from the true top edge instead of stacking under it.
            .ignoresSafeArea(.container, edges: .top)
        }
        // Live fleet: ensure the fleet list is loading (idempotent — normally
        // HomeScreen started it, but the Drives tab can be entered/booted first),
        // then fetch page 1. Reloading when the selected vehicle resolves covers
        // the boot-straight-to-Drives path, where the fleet list arrives AFTER
        // this screen appears (the feed is a detached empty one until then). All
        // idempotent no-ops for the simulated fixture feed.
        .onAppear {
            homeState.startTelemetry()
            feed.loadInitial()
            #if DEBUG
            autoOpenFirstDriveIfRequested()
            #endif
        }
        .onChange(of: homeState.selectedVehicleIndex) { _, _ in feed.loadInitial() }
        .onChange(of: homeState.selectedVehicle?.id) { _, _ in feed.loadInitial() }
        #if DEBUG
        // Verification-only (MRT_OPEN_FIRST_DRIVE=1): open the first loaded drive
        // so a Drive Summary can be captured full-frame headlessly (the Drives
        // tab has no tap automation). The count change covers the live path
        // (0 → N after the async fetch); the onAppear call covers the sim path
        // (fixtures are present immediately, so count never changes). Never fires
        // without the launch flag, so normal runs / Release are unaffected.
        .onChange(of: feed.drives.count) { _, _ in autoOpenFirstDriveIfRequested() }
        #endif
        // Full-bleed geometry (CLAUDE.md "Hard rules"): pin `BottomNav` 26pt
        // from the PHYSICAL bottom edge via the shared `mrtBottomNav` helper
        // (MYR-196 punch-list #3 — was floating ~34pt too high, stacked on
        // top of the home-indicator safe-area inset).
        .mrtBottomNav(selection: $ownerTab)
        .mrtConfirmDialog(
            isPresented: Binding(
                get: { confirmCancel != nil },
                set: { if !$0 { confirmCancel = nil } }
            ),
            config: cancelDialogConfig
        )
    }

    // MARK: Header (screens.jsx:631-634)

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drives")
                .mrtTextStyle(.screenTitle)
                .foregroundStyle(Color.mrtText)
            // screens.jsx:633 `${VEHICLES[0].name} · 42,184 mi total`.
            Text(Self.headerSubtitle(
                isLive: isLive,
                vehicleName: vehicle?.name,
                odometerMiles: homeState.selectedTelemetry?.snapshot.odometerMiles
            ))
                .font(.system(size: 13))
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MRTMetrics.pageGutter)
        .padding(.top, MRTMetrics.drivesHeaderTop)
        .padding(.bottom, 16)
    }

    /// The prototype's lifetime-odometer literal (screens.jsx:633). Fixture data
    /// — simulated / DEBUG-scene renders ONLY (MYR-228).
    static let simulatedLifetimeOdometerText = "42,184"

    /// MYR-287 — the header line under "Drives" (screens.jsx:633
    /// `${VEHICLES[0].name} · 42,184 mi total`).
    ///
    /// The defect: the whole line was ported verbatim, so a LIVE owner whose car
    /// reads ~6,347 mi saw the prototype's 42,184 — the vehicle name was real and
    /// the number beside it was a fixture, which is the most convincing kind of
    /// lie (CLAUDE.md "No fixtures on the live path" / MYR-228).
    ///
    /// LIVE takes the real lifetime odometer from the selected vehicle's telemetry
    /// snapshot (`VehicleTelemetrySnapshot.odometerMiles` ← `VehicleState.odometerMiles`
    /// via `VehicleContractMapping`) — the SAME single source the owner sheet's
    /// Lifetime → Odometer row reads (`LifetimeSection`), so the two surfaces can
    /// never disagree. Deliberately NOT summed from the drives feed: that feed is
    /// cursor-paginated (rest-api.md §7.2), so a sum over the loaded pages is a
    /// partial-page total wearing a lifetime label.
    ///
    /// Honest-unknown: before the first snapshot streams the odometer in (or when
    /// the car isn't streaming it at all), the "· X mi total" suffix is OMITTED
    /// entirely, leaving just the vehicle name. A header suffix has nowhere to put
    /// the `MRTUnavailableValue` "— Syncing" treatment the detail ROWS use (that
    /// primitive is sized to stand where a value would, inside a labeled `KV`
    /// row); dropping the clause is the same honest-omission choice the other
    /// headers make for absent values.
    ///
    /// SIM keeps the literal verbatim so the `ownerDrives` drift-gate scene stays
    /// pixel-identical — including the prototype's own quirk that the figure is
    /// `VEHICLES[0]`'s regardless of which vehicle is selected.
    ///
    /// Pure + static so the live/nil/simulated matrix is unit-testable without a
    /// SwiftUI host.
    static func headerSubtitle(isLive: Bool, vehicleName: String?, odometerMiles: Int?) -> String {
        // The live fleet has no selection until the list loads; "Fleet" is a
        // generic stand-in, not fixture data, so it holds on both paths.
        let name = vehicleName ?? "Fleet"
        guard isLive else { return "\(name) · \(simulatedLifetimeOdometerText) mi total" }
        guard let odometerMiles else { return name }
        return "\(name) · \(MRTNumber.grouped(odometerMiles)) mi total"
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
        if case .driving(let trip)? = vehicle?.activity,
           let telemetry = homeState.selectedTelemetry {
            LiveTripBanner(trip: trip, snapshot: telemetry.snapshot) {
                ownerTab = "home"
            }
            .padding(.horizontal, MRTMetrics.pageGutter)
            .padding(.bottom, 16)
        }

        if feed.drives.isEmpty {
            emptyHistoryContent
        } else {
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

            // Cursor pagination (rest-api.md §7.2): while more pages exist, a
            // footer requests the next one as it scrolls into view. `hasMore` is
            // always false for the fixture feed, so this never shows in sim.
            if feed.hasMore {
                pagingFooter
            }
        }
    }

    /// The empty-history branch: a calm loading pass, then either the quiet
    /// status line (auth/unreachable) or the designed "no drives yet" state.
    ///
    /// MYR-326 — the loading pass is now a SKELETON of the list it is fetching
    /// (a day heading + three row placeholders) rather than a spinner beside
    /// "Loading drives…". The two branches beneath it are honest end states and
    /// are unchanged: a skeleton must never stand in for "there is nothing here"
    /// or "we couldn't reach the server".
    @ViewBuilder
    private var emptyHistoryContent: some View {
        if feed.isLoading {
            DrivesListSkeleton()
        } else if let message = feed.statusMessage {
            statusRow(message)
        } else {
            emptyHistoryState
        }
    }

    /// Designed empty state for a vehicle with no completed drives — mirrors the
    /// Upcoming empty state's composition (icon tile · title · subtitle).
    private var emptyHistoryState: some View {
        VStack(spacing: 0) {
            Image(systemName: "car.side")
                .font(.system(size: 22))
                .foregroundStyle(Color.mrtTextMuted)
                .frame(width: 52, height: 52)
                .background(Color.mrtDrivesEmptyIconFill, in: Circle())
                .padding(.bottom, 14)
            Text("No drives yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 4)
            Text("Completed drives for this vehicle will appear here.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 48)
    }

    private func statusRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13))
            .foregroundStyle(Color.mrtTextMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 44)
    }

    /// Bottom-of-list paging trigger: fetches the next page as it appears.
    ///
    /// MYR-326 — one row-shaped placeholder rather than a spinner, so the list
    /// continues into what is arriving instead of ending in a loading indicator.
    /// The `.onAppear` fetch trigger is unchanged; the footer's presence is
    /// still governed by `hasMore` (always false for the fixture feed, so the
    /// simulated path never renders it).
    private var pagingFooter: some View {
        DriveRowSkeleton(index: 0)
            .padding(.top, 4)
            .mrtSkeletonAccessibility("Loading more drives")
            .onAppear { feed.loadMore() }
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
        let source = feed.drives
        switch sort {
        case .date:
            var order: [String] = []
            var buckets: [String: [Drive]] = [:]
            for drive in source {
                if buckets[drive.dateGroup] == nil { order.append(drive.dateGroup) }
                buckets[drive.dateGroup, default: []].append(drive)
            }
            return order.map { (Drive.groupLabel(for: $0), buckets[$0] ?? []) }
        case .distance:
            return [("All drives", source.sorted { $0.miles > $1.miles })]
        case .duration:
            return [("All drives", source.sorted { $0.mins > $1.mins })]
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
    //
    // The prototype's flow is confirm dialog → row removal, no toast.
    // Handoff §7's toast list only covers revoke/resend/invite-sent.

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

    /// MYR-294 — the same two gates `DrivingSummary.showsArrival` applies, for the
    /// same reason: this row is the sheet hero's statement in miniature, and both
    /// of its figures (minutes remaining, miles remaining) are measured off a
    /// navigation route. With no navigation there is no route — `trip.route` is
    /// the car's own single position — so "0 min remaining · 0.0 mi" is what it
    /// used to print.
    private var showsTripFigures: Bool { trip.navigation.isActive && snapshot.etaMinutes > 0 }

    /// "→ {city}" only when there is a destination to point at.
    private var destinationFragment: Text {
        guard let city = trip.destinationCity, !city.isEmpty else { return Text("") }
        return Text(" → ").foregroundStyle(Color.mrtDriving).fontWeight(.regular)
            + Text(city).foregroundStyle(Color.mrtDrivingRowText)
    }

    /// The badge. "EN ROUTE" is a claim about going somewhere; a car with no
    /// navigation is simply driving.
    private var badgeLabel: String { trip.navigation.isActive ? "EN ROUTE" : "DRIVING" }

    /// The second line. Byte-identical to the pre-MYR-294 string whenever the
    /// figures exist (which is every simulated render); the live speed stands in
    /// when they do not, matching the hero's own promotion of speed.
    private var detailLine: Text {
        if showsTripFigures {
            return Text("\(snapshot.etaMinutes) min ").foregroundStyle(Color.mrtDriving).fontWeight(.semibold)
                + Text("remaining · \(String(format: "%.1f", remainingMiles)) mi").foregroundStyle(Color.mrtTextSec)
        }
        return Text("\(snapshot.speedMPH) mph").foregroundStyle(Color.mrtTextSec)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PulseDot(color: .mrtDriving)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .lastTextBaseline, spacing: 10) {
                        // MYR-294 — the "→ {city}" half renders only when there IS
                        // a destination. `destinationCity` is derived from the
                        // snapshot-only `destinationAddress`, so this row used to
                        // print a bare arrow pointing at an empty string on every
                        // live trip, and an arrow to nowhere on a car with no
                        // navigation at all.
                        (Text(trip.originLabel).foregroundStyle(Color.mrtDrivingRowText)
                            + destinationFragment)
                            .font(.system(size: 15, weight: .semibold))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(badgeLabel)
                            .font(.system(size: 10, weight: .bold))
                            .tracking(1)
                            .foregroundStyle(Color.mrtDriving)
                            .fixedSize()
                    }
                    detailLine
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
