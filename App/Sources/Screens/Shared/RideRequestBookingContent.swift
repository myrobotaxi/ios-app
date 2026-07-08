import SwiftUI
import DesignSystem

// MARK: - RideRequestBookingContent (MYR-171, design/app/ride-request.jsx
// PendingContent 505-665)
//
// Rendering is driven purely by elapsed wall-clock time since
// `RideRequestRecord.requestedAt` (not a locally-owned countdown timer) —
// this makes the 10s "sending" fill naturally resumable across remounts
// (idle-pending-pill → tap → reopen Booking mid-fill) without extra state on
// `SharedViewerState`, and doubles as the "already settled, show the quiet
// waiting card" check the story spec calls for. Only the auto-minimize's
// one-shot scheduling needs real `Task` state (`.task(id:)` below), guarded
// so a stale reopen (well past the fill+hold window) never re-triggers it.
struct RideRequestBookingContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: SimulatedRideRequestService
    var totalHeight: CGFloat?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Tap-anywhere-on-the-CTA fast-forward (ride-request.jsx:548 `goSent`).
    @State private var tapForceSent = false

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var owner: String { fleetMember.owner }
    private var passenger: RidePassenger? { request?.input.passenger }

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 1 : 1.0 / 30.0)) { context in
            let elapsed = request.map { max(0, context.date.timeIntervalSince($0.requestedAt)) } ?? 0
            let isSent = tapForceSent || reduceMotion || elapsed >= RideRequestTiming.sendFillDuration
            let fillFraction = isSent ? 1.0 : elapsed / RideRequestTiming.sendFillDuration
            let secondsRemaining = max(1, Int((RideRequestTiming.sendFillDuration - elapsed).rounded(.up)))

            // MYR-171 fix: no `ScrollView` — see `RideRequestPinDropContent`'s
            // identical fix comment (this phase also sizes to content).
            VStack(alignment: .leading, spacing: 0) {
                // MYR-199 fix: drag-down-to-dismiss — ride-request.jsx:1151
                // `d > 36 && (phase === 'tracking' || phase === 'pending')`
                // → `setPhase('idle')` (minimize to the map's pending-pill
                // state; no draft reset — the request keeps running).
                RideGrabHandle(onDragDismiss: { viewerState.sheetPhase = .idle })
                    titleBlock(isSent: isSent, elapsed: elapsed)
                        .padding(.bottom, 12)

                    if let passenger, !passenger.name.isEmpty {
                        forChip(passenger).padding(.bottom, 14)
                    }

                    itinerary.padding(.bottom, 10)
                    vehicleRow.padding(.bottom, 14)

                    if isSent {
                        Button("Cancel request", action: cancel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.mrtDialogRed)
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: MRTMetrics.minTapTarget - 14)
                    } else {
                        sendingCTA(fillFraction: fillFraction, secondsRemaining: secondsRemaining)
                            .padding(.bottom, 8)
                        VStack(spacing: 2) {
                            Text("Tap to send now")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.mrtTextMuted)
                            Button("Cancel request", action: cancel)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.mrtDialogRed)
                                .buttonStyle(.plain)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .rideRequestSheetChrome()
        .overlay(alignment: .topTrailing) {
            RideSheetCloseButton { viewerState.sheetPhase = .idle }
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
        .task(id: request?.id) {
            await scheduleAutoMinimizeIfFresh()
        }
    }

    // MARK: Title

    @ViewBuilder
    private func titleBlock(isSent: Bool, elapsed: TimeInterval) -> some View {
        if isSent {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request sent")
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                (Text("Waiting for ") + Text(owner).foregroundColor(Color.mrtText).fontWeight(.medium) + Text(" \u{00B7} sent \(agoText(elapsed)) ago"))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mrtTextSec)
                if let passenger, !passenger.phone.isEmpty {
                    let first = passenger.name.split(separator: " ").first.map(String.init) ?? passenger.name
                    Text("\(first) gets a tracking link the moment \(owner) accepts.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.mrtTextMuted)
                        .padding(.top, 4)
                }
            }
        } else {
            (Text("Booking ride with ") + Text(owner).foregroundColor(Color.mrtGold))
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
        }
    }

    private func agoText(_ elapsed: TimeInterval) -> String {
        let secs = Int(elapsed)
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }

    private func forChip(_ passenger: RidePassenger) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "person.fill").font(.system(size: 11)).foregroundStyle(Color.mrtGold)
            Text("For \(passenger.name)").font(.system(size: 12)).foregroundStyle(Color.mrtText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.mrtGoldTileFaint, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtGold.opacity(Double(0x3A) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    // MARK: Itinerary (ride-request.jsx:551-587)

    private var itinerary: some View {
        let pickupEtaMinutes = fleetMember.etaMin
        let tripMinutes = request?.input.destination.minutes ?? 28
        let tripMiles = request?.input.destination.miles ?? 14
        let pickupLabel = request?.input.pickup.label ?? "Current location"
        let destinationLabel = request?.input.destination.label ?? "Destination"
        let destinationSub = request?.input.destination.subtitle

        // MYR-197 fix: the pickup connector used to be a `flex:1`
        // `Rectangle().frame(maxHeight: .infinity)` HStack sibling — with no
        // fixed-height frame between this itinerary and the screen-height
        // `GeometryReader`/`ZStack` in `SharedViewerScreen`, that request
        // propagated all the way up and stretched the whole Booking sheet
        // full-screen (client QA, MYR-197). Fix: paint the dot/line rail as
        // a `.background` behind the pickup content column instead — see
        // `RideRequestSearchContent.routeCard`'s identical fix for the full
        // explanation.
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    RideEyebrowText(text: "Pickup", color: .mrtGold, size: 10)
                    Spacer(minLength: 8)
                    Text(RideRequestClock.fromNow(minutes: pickupEtaMinutes))
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(pickupLabel).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(pickupEtaMinutes) min away").font(.system(size: 12)).foregroundStyle(Color.mrtTextMuted).lineLimit(1)
                }
            }
            .padding(.leading, 25) // 12pt dot + 13pt gap
            .background(alignment: .topLeading) {
                VStack(spacing: 4) {
                    Circle().fill(Color.mrtGoldTrace).frame(width: 12, height: 12)
                    Rectangle().fill(Color.mrtBorder).frame(width: 2).frame(maxHeight: .infinity)
                }
                .padding(.top, 3)
            }
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 13) {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Color.mrtGold, lineWidth: 2).frame(width: 12, height: 12).padding(.top, 3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        RideEyebrowText(text: "Drop-off", color: .mrtGold, size: 10)
                        Spacer(minLength: 8)
                        Text(RideRequestClock.fromNow(minutes: pickupEtaMinutes + tripMinutes))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.mrtTextSec)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text(destinationLabel).font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.mrtText).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(String(format: "%.1f", tripMiles)) mi \u{00B7} \(tripMinutes) min")
                            .font(.system(size: 12)).foregroundStyle(Color.mrtTextMuted).lineLimit(1)
                    }
                    if let destinationSub {
                        Text(destinationSub).font(.system(size: 12.5)).foregroundStyle(Color.mrtTextSec).lineLimit(1)
                    }
                }
            }
        }
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    // MARK: Vehicle row (ride-request.jsx:589-599)

    /// MYR-199 fix: headline was `"{model} {name}"` (e.g. "2025 Tesla Model
    /// Y") with no subline — the jsx's `VehicleRow` (ride-request.jsx:
    /// 602-611) headlines on the paint-color nickname + model name
    /// (`{vColor} {vName}`, e.g. "Quicksilver Model Y") and sublines on the
    /// year/make alone (`vYearMake`). Same split as
    /// `RideRequestTrackingContent.rideRow`'s identical fix.
    private var vehicleRow: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                RideEyebrowText(text: "Your ride", color: Color.mrtGold.opacity(0.6), size: 9.5)
                Text("\(fleetMember.colorName) \(fleetMember.name)")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundStyle(Color.mrtText)
                Text(fleetMember.model + (passenger?.name.isEmpty == false ? " \u{00B7} for \(passenger!.name)" : ""))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
            RidePlateChip(plate: fleetMember.plate)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x24) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    // MARK: Sending CTA (ride-request.jsx:600-620 `mrt-draw-btn` + `mrt-send-fill`)

    private func sendingCTA(fillFraction: Double, secondsRemaining: Int) -> some View {
        Button {
            tapForceSent = true
        } label: {
            ZStack {
                GeometryReader { geo in
                    Color.mrtSendFillTrack
                        .frame(width: geo.size.width * fillFraction)
                        .frame(maxHeight: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Text("Sending request")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mrtText)
                    Text("\(secondsRemaining)s")
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtText.opacity(0.85))
                }
            }
            .frame(height: 54)
            .frame(maxWidth: .infinity)
            .background(Color.mrtGoldFillFaint)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(MRTTraceBorder(shape: RoundedRectangle(cornerRadius: 14, style: .continuous)))
        }
        .buttonStyle(.plain)
    }

    // MARK: Actions

    private func cancel() {
        rideRequestService.cancel()
        viewerState.resetDraftToIdle()
    }

    /// Schedules the "hold on 'Request sent', then minimize to idle" step —
    /// but only for a booking that hasn't already settled (a stale reopen,
    /// well past `sendFillDuration + sentHoldDuration`, just shows the quiet
    /// waiting card forever, per the story spec's idle-pending-pill note).
    private func scheduleAutoMinimizeIfFresh() async {
        guard let requestedAt = request?.requestedAt else { return }
        let elapsedAtStart = Date().timeIntervalSince(requestedAt)
        guard elapsedAtStart < RideRequestTiming.sendFillDuration + RideRequestTiming.sentHoldDuration else { return }

        if reduceMotion {
            try? await Task.sleep(for: .seconds(RideRequestTiming.sentHoldDuration))
        } else {
            while !tapForceSent {
                if Date().timeIntervalSince(requestedAt) >= RideRequestTiming.sendFillDuration { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(0.1))
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(RideRequestTiming.sentHoldDuration))
        }
        guard !Task.isCancelled else { return }
        if viewerState.sheetPhase == .booking {
            viewerState.sheetPhase = .idle
        }
    }
}
