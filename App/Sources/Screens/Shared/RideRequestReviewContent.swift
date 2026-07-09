import SwiftUI
import DesignSystem

// MARK: - RideRequestReviewContent (MYR-171, design/app/ride-request.jsx
// ReviewContent 347-500)
struct RideRequestReviewContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: any RideRequestService
    var totalHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fleetPickerOpen = false

    private var destination: RidePlace? { viewerState.draftDestination }
    private var fleetMember: FleetMember {
        RideRequestFixtures.fleet.first { $0.id == viewerState.draftFleetMemberID } ?? RideRequestFixtures.fleet[0]
    }
    private var schedule: RideSchedule? { viewerState.draftSchedule }
    private var passenger: RidePassenger? { viewerState.draftPassenger }

    private var tripMinutes: Int { destination?.minutes ?? 28 }
    private var tripMiles: Double { destination?.miles ?? 14 }
    private var pickupMinutes: Int { fleetMember.etaMin }

    private var pickupAt: String {
        if let schedule { return schedule.time }
        return RideRequestClock.fromNow(minutes: pickupMinutes)
    }

    private var arriveAt: String {
        if let schedule { return RideRequestClock.adding(tripMinutes, to: schedule.time) }
        return RideRequestClock.fromNow(minutes: pickupMinutes + tripMinutes)
    }

    private var pickupSub: String {
        schedule.map(\.day) ?? "\(pickupMinutes) min away"
    }

    private var arriveSub: String {
        "\(tripMinutes) min \u{00B7} \(String(format: "%.1f", tripMiles)) mi trip"
    }

    var body: some View {
        // MYR-171 fix: no `ScrollView` — this phase sizes to content
        // ('auto' in ride-request.jsx:1119-1131, no inner scroll container
        // in the source either). A `ScrollView` here greedily claims the
        // full proposed height regardless of content size, stretching the
        // sheet to ~88% of the screen with a large empty area below the
        // actual content. See `RideRequestPinDropContent`'s identical fix.
        VStack(alignment: .leading, spacing: 0) {
            RideGrabHandle()

                HStack {
                    Button {
                        viewerState.sheetPhase = .search
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                            Text("Change trip").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundStyle(Color.mrtGold)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                    RideSheetCloseButton { viewerState.resetDraftToIdle() }
                }
                .padding(.bottom, 10)

                if let schedule {
                    scheduledBadge(schedule).padding(.bottom, 12)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text(destination?.label ?? "Destination")
                        .font(.system(size: 28, weight: .semibold))
                        .tracking(-0.7)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    if let subtitle = destination?.subtitle {
                        Text(subtitle)
                            .font(.system(size: 14.5))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 20)

                statsRow
                    .padding(.bottom, 22)

                if let passenger {
                    passengerCard(passenger).padding(.bottom, 14)
                }

                vehicleRow.padding(.bottom, 16)

                MRTButton(schedule != nil ? "Schedule with \(fleetMember.owner)" : "Request from \(fleetMember.owner)", variant: .outlineDraw, action: confirm)

                Text(helperText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextMuted)
                    .tracking(-0.1)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 13)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        .rideRequestSheetChrome()
        .overlay {
            if fleetPickerOpen { fleetSlideUpCard }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: fleetPickerOpen)
        #if DEBUG
        .onAppear { if DebugScene.current?.opensFleetPicker == true { fleetPickerOpen = true } } // MYR-200 reviewPicker scene
        #endif
    }

    private func scheduledBadge(_ schedule: RideSchedule) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.system(size: 12)).foregroundStyle(Color.mrtGold)
            Text("Scheduled \u{00B7} \(schedule.day) \(schedule.time)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.mrtGold)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Color.mrtGoldTileFaint, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtGold.opacity(Double(0x40) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    /// MYR-197 fix: the divider used to be a bare `Rectangle()` (no height
    /// modifier at all) as a third HStack sibling — a `Shape` with no frame
    /// fills whatever height it's proposed by default, which, with no
    /// fixed-height frame between this row and the screen-height
    /// `GeometryReader`/`ZStack` in `SharedViewerScreen`, meant the whole
    /// screen's height. That stretched the entire Review sheet full-screen
    /// with a giant gap around the divider (client QA, MYR-197). Fix: paint
    /// the divider as a `.background` behind the Pick-up column instead of
    /// an HStack sibling — see `RideRequestSearchContent.routeCard`'s
    /// identical fix for the full explanation; `alignment: .trailing` + the
    /// 20pt trailing padding below lands it in the same gap the jsx's
    /// `margin: '2px 20px'` describes (ride-request.jsx:404).
    private var statsRow: some View {
        HStack(alignment: .top, spacing: 0) {
            statPair(label: "Pick-up", value: pickupAt, sub: pickupSub)
                .padding(.trailing, 20)
                .background(alignment: .trailing) {
                    Rectangle().fill(Color.mrtBorder).frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 2)
                }
            statPair(label: "Arrive", value: arriveAt, sub: arriveSub)
                .padding(.leading, 20)
        }
    }

    private func statPair(label: String, value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.mrtGold)
            Text(value)
                .font(.system(size: 27, weight: .medium))
                .monospacedDigit()
                .tracking(-0.6)
                .foregroundStyle(Color.mrtText)
            Text(sub)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextSec)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passengerCard(_ passenger: RidePassenger) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.mrtGold, Color.mrtRiderAvatarGradientEnd],
                        center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 20
                    )
                )
                .frame(width: 36, height: 36)
                .overlay(Text(passenger.initials).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Color.mrtGoldButtonLabel))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(passenger.name)
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    Text("PASSENGER")
                        .font(.system(size: 9.5, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color.mrtGold)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.mrtGoldBadgeFill, in: Capsule())
                }
                if passenger.phone.isEmpty {
                    Text("Add a mobile number to send the tracking link")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtDialogRed)
                } else {
                    Text(passenger.phone)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            Spacer(minLength: 0)
            Button {
                viewerState.sheetPhase = .search
            } label: {
                HStack(spacing: 5) {
                    if !passenger.phone.isEmpty {
                        Image(systemName: "pencil").font(.system(size: 11))
                    }
                    Text(passenger.phone.isEmpty ? "Add number" : "Edit")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.mrtGold)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(Color.mrtGold.opacity(Double(0x18) / 255.0), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.mrtGold.opacity(Double(0x40) / 255.0), lineWidth: MRTMetrics.hairline))
            }
            .buttonStyle(.plain)
        }
        .padding(11)
        .mrtSurface(.control, fill: .mrtElevated, radius: 13)
    }

    private var vehicleRow: some View {
        Button {
            if RideRequestFixtures.fleet.count > 1 { fleetPickerOpen = true }
        } label: {
            HStack(spacing: 11) {
                Circle().fill(Color.mrtGoldTileFaint).frame(width: 36, height: 36)
                    .overlay(Text(String(fleetMember.owner.prefix(1))).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mrtGold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(fleetMember.owner)\u{2019}s \(fleetMember.name)")
                        .font(.system(size: 14.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    HStack(spacing: 6) {
                        Circle().fill(Color.mrtParked).frame(width: 6, height: 6).shadow(color: .mrtParked.opacity(0.6), radius: 3)
                        Text("Available\(schedule == nil ? " now" : "") \u{00B7} \(fleetMember.battery)%")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mrtTextSec)
                    }
                }
                Spacer(minLength: 0)
                if RideRequestFixtures.fleet.count > 1 {
                    HStack(spacing: 3) {
                        Text("Change").font(.system(size: 12, weight: .semibold))
                        Image(systemName: "chevron.down").font(.system(size: 11))
                    }
                    .foregroundStyle(Color.mrtGold)
                } else {
                    Image(systemName: "car.fill").font(.system(size: 15)).foregroundStyle(Color.mrtTextMuted)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline))
        .disabled(RideRequestFixtures.fleet.count <= 1)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    private var helperText: String {
        if let passenger, !passenger.phone.isEmpty {
            let first = passenger.name.split(separator: " ").first.map(String.init) ?? passenger.name
            return "\(fleetMember.owner) must accept \u{2014} then we\u{2019}ll text \(first) the tracking link"
        }
        return "\(fleetMember.owner) must accept before the ride is confirmed"
    }

    private func confirm() {
        guard let pickup = viewerState.draftPickup, let destination = viewerState.draftDestination else { return }
        let input = RideRequestInput(
            // MYR-211: re-resolve a "Current location" pickup to the freshest
            // device fix at request time so the created ride carries the real
            // coordinate (a pin/saved pickup passes through unchanged).
            pickup: viewerState.resolvedPickup(pickup),
            destination: destination,
            fleetMemberID: fleetMember.id,
            passenger: viewerState.draftPassenger,
            schedule: viewerState.draftSchedule
        )
        rideRequestService.submit(input)
        if viewerState.draftSchedule != nil {
            // M1 scope: scheduled requests never start a live trip sim
            // (mirrors `SimulatedRideRequestService.accept()`'s own
            // `schedule != nil` branch, which never seeds `trackProgress`) —
            // go straight back to idle rather than into Booking/Tracking.
            viewerState.sheetPhase = .idle
        } else {
            viewerState.sheetPhase = .booking
        }
    }

    // MARK: Fleet picker (ride-request.jsx:426-467)

    private var fleetSlideUpCard: some View {
        RideSlideUpCard(onDismiss: { fleetPickerOpen = false }) {
            RideSlideUpCardTitle(title: "Available rides") { fleetPickerOpen = false }
            VStack(spacing: 8) {
                ForEach(RideRequestFixtures.fleet) { member in
                    let active = member.id == viewerState.draftFleetMemberID
                    Button {
                        viewerState.draftFleetMemberID = member.id
                        fleetPickerOpen = false
                    } label: {
                        HStack(spacing: 12) {
                            Circle().fill(Color.mrtGoldTileFaint).frame(width: 38, height: 38)
                                .overlay(Text(String(member.owner.prefix(1))).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtGold))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(member.owner)\u{2019}s \(member.name)")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .tracking(-0.2)
                                    .foregroundStyle(Color.mrtText)
                                Text("\(member.relationship) \u{00B7} \(member.battery)% \u{00B7} \(member.etaMin) min away")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.mrtTextSec)
                            }
                            Spacer(minLength: 0)
                            if active {
                                Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Color.mrtGold)
                            } else {
                                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Color.mrtTextMuted)
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(active ? Color.mrtGoldTileFaint : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(active ? Color.mrtGold.opacity(Double(0x66) / 255.0) : Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
