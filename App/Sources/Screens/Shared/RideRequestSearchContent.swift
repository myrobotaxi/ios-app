import SwiftUI
import DesignSystem

// MARK: - RideRequestSearchContent (MYR-171, design/app/ride-request.jsx
// SearchContent 150-346 + PassengerPicker 94-143)
//
// Search phase: Now/Schedule + Me/Someone else chips, the pickup/destination
// route card, and Saved/Recent/Nearby (or filtered Results) below. Schedule
// picking opens a slide-up card (`RideSlideUpCard`) — the same recipe
// `ScheduledRideSheet`'s reschedule mode uses for its day/time chips, reused
// here rather than forked.
struct RideRequestSearchContent: View {
    @Bindable var viewerState: SharedViewerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var query = ""
    @State private var forSomeoneElse = false
    @State private var scheduleSheetOpen = false
    @State private var schedDay = "Today"
    @State private var schedTime = "5:30 PM"

    /// The fleet owner the search phase is provisionally requesting from —
    /// not yet chosen by the rider (that's Review's fleet picker), so this
    /// mirrors the jsx's `requesterName` default: the first shared Tesla
    /// (ride-request.jsx:150 `requesterName = 'Alex'`).
    private var requesterName: String {
        RideRequestFixtures.fleet.first { $0.id == viewerState.draftFleetMemberID }?.owner
            ?? RideRequestFixtures.fleet[0].owner
    }

    private var filteredResults: [RidePlace]? {
        guard !query.isEmpty else { return nil }
        let q = query.lowercased()
        return RideRequestFixtures.recentPlaces.filter {
            $0.label.lowercased().contains(q) || ($0.subtitle?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RideGrabHandle()
            chipRow
                .padding(.bottom, viewerState.draftSchedule != nil ? 8 : 12)
            if let schedule = viewerState.draftSchedule {
                scheduleRow(schedule)
                    .padding(.bottom, 12)
            }
            if forSomeoneElse {
                passengerPicker
                    .padding(.bottom, 12)
            }
            routeCard
                .padding(.bottom, 10)
            ScrollView {
                resultsList
                    .padding(.bottom, 16)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
        .padding(.bottom, MRTMetrics.homeSheetContentBottomPadding)
        .frame(height: MRTMetrics.rideRequestSearchSheetHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .rideRequestSheetChrome()
        .overlay {
            if scheduleSheetOpen {
                scheduleSlideUpCard
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), value: scheduleSheetOpen)
        .onAppear {
            forSomeoneElse = viewerState.draftPassenger != nil
            if let schedule = viewerState.draftSchedule {
                schedDay = schedule.day
                schedTime = schedule.time
            }
        }
    }

    // MARK: Chips

    private var chipRow: some View {
        HStack(spacing: 7) {
            RideChip(title: "Now", selected: viewerState.draftSchedule == nil) {
                viewerState.draftSchedule = nil
            }
            RideChip(title: "Schedule", selected: viewerState.draftSchedule != nil) {
                if let schedule = viewerState.draftSchedule {
                    schedDay = schedule.day
                    schedTime = schedule.time
                }
                scheduleSheetOpen = true
            }
            Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline, height: 16)
                .padding(.horizontal, 3)
            RideChip(title: "Me", selected: !forSomeoneElse) {
                forSomeoneElse = false
                viewerState.draftPassenger = nil
            }
            RideChip(title: "Someone else", selected: forSomeoneElse) {
                forSomeoneElse = true
            }
            Spacer(minLength: 0)
        }
    }

    private func scheduleRow(_ schedule: RideSchedule) -> some View {
        Button {
            schedDay = schedule.day
            schedTime = schedule.time
            scheduleSheetOpen = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                (Text("Pickup ") + Text("\(schedule.day) \u{00B7} \(schedule.time)").foregroundColor(Color.mrtText).fontWeight(.semibold))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
                Text("Edit")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.mrtGold)
            }
        }
        .buttonStyle(.plain)
        .frame(minHeight: 30)
    }

    // MARK: Passenger picker (ride-request.jsx:94-143)

    private var passengerName: String { viewerState.draftPassenger?.name ?? "" }
    private var passengerPhone: String { viewerState.draftPassenger?.phone ?? "" }

    private var passengerNameBinding: Binding<String> {
        Binding(
            get: { passengerName },
            set: { newValue in setPassenger(name: newValue, phone: passengerPhone) }
        )
    }

    private var passengerPhoneBinding: Binding<String> {
        Binding(
            get: { passengerPhone },
            set: { newValue in setPassenger(name: passengerName, phone: newValue) }
        )
    }

    private func setPassenger(name: String, phone: String) {
        viewerState.draftPassenger = (name.isEmpty && phone.isEmpty) ? nil : RidePassenger(name: name, phone: phone)
    }

    private var passengerPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                RideEyebrowText(text: "Passenger")
                Spacer(minLength: 0)
                if !passengerName.isEmpty {
                    Button("Clear") { viewerState.draftPassenger = nil }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.mrtGold)
                        .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 10)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RideRequestFixtures.recentPassengers) { contact in
                        let active = passengerPhone == contact.phone
                        Button {
                            setPassenger(name: contact.name, phone: contact.phone)
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Color.mrtElevated).frame(width: 24, height: 24)
                                    .overlay(Text(initials(contact.name)).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color.mrtText))
                                Text(contact.name)
                                    .font(.system(size: 13, weight: .semibold))
                                    .tracking(-0.1)
                                    .foregroundStyle(active ? Color.mrtGold : Color.mrtText)
                            }
                            .padding(.leading, 6)
                            .padding(.trailing, 12)
                            .padding(.vertical, 6)
                            .background(active ? Color.mrtGoldTileFaint : Color.mrtRideChipFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(active ? Color.mrtGold.opacity(Double(0x66) / 255.0) : Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 2)
            }
            .padding(.bottom, 11)

            VStack(spacing: 8) {
                TextField("Passenger name", text: passengerNameBinding)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.mrtRequestCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                TextField("Mobile number", text: passengerPhoneBinding)
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .keyboardType(.phonePad)
                    .foregroundStyle(Color.mrtText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.mrtRequestCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "paperplane.fill").font(.system(size: 12)).foregroundStyle(Color.mrtGold)
                notifyNote
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
                    .lineSpacing(2)
            }
            .padding(.top, 11)
        }
        .padding(14)
        .mrtSurface(.control, fill: .mrtElevated, radius: 16)
    }

    private var notifyNote: Text {
        let first = passengerName.split(separator: " ").first.map(String.init) ?? "them"
        return Text("We\u{2019}ll text ")
            + Text(passengerName.isEmpty ? "them" : first).foregroundColor(Color.mrtText).fontWeight(.semibold)
            + Text(" a live tracking link as soon as \(requesterName) accepts.")
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    // MARK: Route card (pickup / destination)
    //
    // MYR-197 fix: the pickup→destination connector used to be a `flex:1`
    // `Rectangle().frame(maxHeight: .infinity)` sitting as an HStack sibling
    // next to the content column. With no fixed-height frame between this
    // card and the screen-height `GeometryReader`/`ZStack` in
    // `SharedViewerScreen`, that "give me infinity" request propagated all
    // the way up — this card (and the whole Search sheet's internal layout)
    // rendered with a huge dead gap instead of hugging its content (client
    // QA, MYR-197). Fix: paint the dot/line rail as a `.background` behind
    // the content column instead of a flexible HStack sibling — a
    // `.background` is always proposed a size equal to the *already
    // resolved* size of the view it's attached to, so the connector's own
    // `maxHeight: .infinity` correctly fills exactly the content column's
    // natural height (pickup row top → destination row bottom) and nothing
    // more, matching the jsx's CSS `align-items: stretch` behavior. Ported
    // to `RideRequestBookingContent`/`RideRequestTrackingContent`'s
    // itinerary rails identically.
    private var routeCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RideEyebrowText(text: "Pickup")
                    Text(viewerState.draftPickup?.label ?? "Current location")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button {
                    viewerState.pinReturn = .search
                    viewerState.sheetPhase = .pinDrop(returnTo: .search)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mappin").font(.system(size: 11))
                        Text(viewerState.draftPickup != nil ? "On map" : "Set on map")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(Color.mrtGold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(viewerState.draftPickup != nil ? Color.mrtGold.opacity(0.16) : Color.clear, in: Capsule())
                    .overlay(Capsule().strokeBorder(viewerState.draftPickup != nil ? Color.mrtGold.opacity(Double(0x66) / 255.0) : Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 11)

            Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RideEyebrowText(text: "Destination")
                    TextField("Where to?", text: $query)
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 13)).foregroundStyle(Color.mrtTextMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 11)
        }
        .padding(.leading, 22) // room for the dot/line rail painted behind
        .background(alignment: .topLeading) { routeRail }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .mrtSurface(.control, fill: .mrtElevated, radius: 16)
    }

    /// The pickup (driving-green dot) → destination (gold square) connector
    /// — see this file's `routeCard` header comment for why it's a
    /// `.background` rather than an HStack sibling.
    private var routeRail: some View {
        VStack(spacing: 4) {
            Circle().fill(Color.mrtDriving).frame(width: 9, height: 9).shadow(color: .mrtDriving.opacity(0.67), radius: 4)
            Rectangle().fill(Color.mrtBorder).frame(width: 2).frame(maxHeight: .infinity)
            RoundedRectangle(cornerRadius: 2.5).fill(Color.mrtGold).frame(width: 9, height: 9).shadow(color: .mrtGoldGlow, radius: 4)
        }
        .padding(.vertical, 19)
    }

    // MARK: Results

    @ViewBuilder
    private var resultsList: some View {
        if let filteredResults {
            if filteredResults.isEmpty {
                Text("No results for \u{201C}\(query)\u{201D}")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel("Results").padding(.top, 6)
                    ForEach(filteredResults) { destRow($0) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                sectionLabel("Saved").padding(.top, 6)
                ForEach(RideRequestFixtures.savedPlaces) { destRow($0) }

                sectionLabel("Recent").padding(.top, 18)
                ForEach(RideRequestFixtures.recentPlaces.prefix(4)) { destRow($0) }

                sectionLabel("Nearby").padding(.top, 18).padding(.bottom, 8)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RideRequestFixtures.nearbyPlaces) { nearbyCard($0) }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Color.mrtTextMuted)
    }

    private func destRow(_ place: RidePlace) -> some View {
        Button {
            selectDestination(place)
        } label: {
            HStack(spacing: 14) {
                Circle()
                    .fill(Color.mrtGoldTileFaint)
                    .frame(width: 38, height: 38)
                    .overlay(Image(systemName: place.icon).font(.system(size: 15)).foregroundStyle(Color.mrtGold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    if let subtitle = place.subtitle {
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f mi", place.miles))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtText)
                    Text("\(place.minutes) min")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextMuted)
                }
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    private func nearbyCard(_ place: RidePlace) -> some View {
        Button {
            selectDestination(place)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: place.icon).font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text(place.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
                Text("\(String(format: "%.1f", place.miles)) mi \u{00B7} \(place.minutes) min")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color.mrtTextSec)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: 132, alignment: .leading)
        }
        .buttonStyle(.plain)
        .mrtSurface(.control, fill: .mrtElevated, radius: 14)
    }

    private func selectDestination(_ place: RidePlace) {
        viewerState.draftDestination = place
        if viewerState.draftPickup == nil {
            viewerState.pinReturn = .review
            viewerState.sheetPhase = .pinDrop(returnTo: .review)
        } else {
            viewerState.sheetPhase = .review
        }
    }

    // MARK: Schedule slide-up card (ride-request.jsx:296-346)

    private var scheduleSlideUpCard: some View {
        RideSlideUpCard(onDismiss: { scheduleSheetOpen = false }) {
            RideSlideUpCardTitle(title: "Schedule pickup") { scheduleSheetOpen = false }

            RideEyebrowText(text: "Day", size: 10.5).padding(.bottom, 9)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RideRequestFixtures.scheduleDays, id: \.self) { day in
                        RideChip(title: day, selected: schedDay == day) { schedDay = day }
                    }
                }
            }
            .padding(.bottom, 18)

            RideEyebrowText(text: "Time", size: 10.5).padding(.bottom, 9)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(RideRequestFixtures.scheduleTimes, id: \.self) { time in
                        RideChip(title: time, selected: schedTime == time, monospaced: true) { schedTime = time }
                    }
                }
            }
            .padding(.bottom, 20)

            MRTButton("Set pickup \u{00B7} \(schedDay) \(schedTime)", variant: .gold) {
                viewerState.draftSchedule = RideSchedule(day: schedDay, time: schedTime)
                scheduleSheetOpen = false
            }
        }
    }
}
