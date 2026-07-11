import SwiftUI
import MapKit
import CoreLocation
import DesignSystem

// MARK: - IncomingRequestSheet (MYR-171, design/app/ride-request.jsx
// IncomingRequestSheet 1266-1421, Handoff §5.11)
//
// Owner-side modal presented at `HomeScreen`'s root whenever
// `rideRequestService.activeRequest?.status == .pending`. Hand-rolled sheet
// chrome per `ScheduledRideSheet`'s pattern — `MRTMetrics.modalRadius`'s own
// doc comment names this screen as its second consumer — rather than
// `.mrtConfigSheet`.
//
// Presentational: takes `request` + two callbacks, same shape as
// `ScheduledRideSheet(ride:onClose:onReschedule:onCancel:)`. It owns its own
// accept CHOREOGRAPHY (the `sending`/`sent` local state + `Task.sleep`,
// mirroring the jsx's `setTimeout` calls at ride-request.jsx:1276-1280) but
// not the accept's actual EFFECTS — `onAccept` fires exactly once, ~1.7s
// after the tap, and `HomeScreen` is the one that calls
// `RideRequestService.accept()`, seeds `OwnerDrivesState` for scheduled
// requests, and shows `RouteSentToast` in response (see those types' doc
// comments). `onDecline` fires immediately on tap, no choreography
// (ride-request.jsx:1276 `onReject` has none either).
struct IncomingRequestSheet: View {
    /// `nil` hides the sheet — mirrors `ScheduledRideSheet`'s `ride: ScheduledRide?`.
    let request: RideRequestRecord?
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var sending = false
    @State private var sent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            if let request {
                Color.mrtScrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .accessibilityHidden(true)
                sheet(for: request)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.34), // mrt-sched-up
            value: request != nil
        )
        .onChange(of: request?.id) { _, _ in
            // A fresh request (new id) always starts clean — also covers the
            // "reset after accept" requirement, since `request` itself goes
            // nil the instant `onAccept`'s caller flips status away from
            // `.pending` (see `HomeScreen`'s `incomingRequest` computed var).
            sending = false
            sent = false
        }
    }

    // MARK: Sheet body

    private func sheet(for request: RideRequestRecord) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            grabHandle
            kicker(request)
                .padding(.bottom, 18)
            header(request)
                .padding(.bottom, request.input.passenger != nil ? 16 : 18)
            if let passenger = request.input.passenger {
                passengerChip(passenger)
                    .padding(.bottom, 16)
            }
            mapCard(request)
                .padding(.bottom, 14)
            statusRow(request)
                .padding(.bottom, 18)
            ctaArea(request)
            if !sending, !sent {
                helperText(request)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.modalRadius, topTrailingRadius: MRTMetrics.modalRadius, style: .continuous)
                .fill(Color.mrtRideSheetFill)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.modalRadius, topTrailingRadius: MRTMetrics.modalRadius, style: .continuous)
                        .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .accessibilityAddTraits(.isModal)
    }

    /// 36×4 rounded handle (ride-request.jsx:1299) — same recipe as
    /// `ScheduledRideSheet`'s private copy (DesignSystem's own grab handle
    /// is internal to that module).
    private var grabHandle: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color.mrtElevated)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .padding(.bottom, 16)
    }

    // MARK: Kicker + header (ride-request.jsx:1300-1315)

    private func kicker(_ request: RideRequestRecord) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.mrtGold).frame(width: 7, height: 7)
                .shadow(color: .mrtGoldGlow, radius: 4)
            Text((isScheduled(request) ? "Scheduled ride request" : "Incoming ride request").uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.mrtGold)
        }
    }

    private func header(_ request: RideRequestRecord) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.mrtRequesterAvatarStart, .mrtRequesterAvatarEnd],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay(
                    Text(request.requesterDisplayName.prefix(1))
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle(request))
                    .font(.system(size: 16, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                Text(headerSubtitle(request))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
    }

    /// MYR-229: `request.requesterDisplayName` is the real requester on the
    /// live path (contracts v0.11.0's `requesterName`, "Rider" fallback if
    /// the wire omits it) and the fixture "Sam" in SIM/DEBUG scenes — see
    /// that property's doc comment.
    private func headerTitle(_ request: RideRequestRecord) -> String {
        request.input.passenger != nil
            ? "\(request.requesterDisplayName) requested a ride"
            : "\(request.requesterDisplayName) wants a ride"
    }

    private func headerSubtitle(_ request: RideRequestRecord) -> String {
        if let schedule = request.input.schedule {
            return "Scheduled \u{00B7} \(schedule.day) \(schedule.time)"
        }
        return "Shared viewer \u{00B7} just now"
    }

    // MARK: Passenger chip (ride-request.jsx:1316-1328, "for someone else")

    private func passengerChip(_ passenger: RidePassenger) -> some View {
        HStack(spacing: 11) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.mrtGold, .mrtRiderAvatarGradientEnd],
                        center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 20
                    )
                )
                .frame(width: 34, height: 34)
                .overlay(
                    Text(passenger.initials)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.mrtGoldButtonLabel)
                )
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(passenger.name)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                    Text("PASSENGER")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                        .foregroundStyle(Color.mrtGold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.mrtGoldBadgeFill, in: Capsule())
                }
                if !passenger.phone.isEmpty {
                    Text(passenger.phone)
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(Color.mrtTextSec)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "person.fill")
                .font(.system(size: 15))
                .foregroundStyle(Color.mrtTextMuted)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(Color.mrtGold.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.mrtGold.opacity(0.2), lineWidth: MRTMetrics.hairline)
        )
    }

    // MARK: Map + stats card (ride-request.jsx:1329-1359)
    //
    // One card, not two like `ScheduledRideSheet`'s (separate map preview +
    // route block) — the jsx wraps the map AND the stats row in a single
    // `borderRadius:16` container (ride-request.jsx:1329).

    private func mapCard(_ request: RideRequestRecord) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                IncomingRequestRouteMap(
                    pickup: request.input.pickup.coordinate,
                    destination: request.input.destination.coordinate
                )
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.3), .init(color: .mrtRideMapScrim, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .allowsHitTesting(false)
                HStack(spacing: 8) {
                    Circle().fill(Color.mrtGold).frame(width: 7, height: 7)
                        .shadow(color: .mrtGoldGlow, radius: 3)
                    Text(request.input.destination.label)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
            .frame(height: MRTMetrics.incomingRequestMapHeight)
            statsRow(request)
        }
        .background(Color.mrtSurface)
        .clipShape(RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.cardRadius, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
    }

    /// `Math.max(10, battery - Math.round(miles * 0.7))` (ride-request.jsx:1356)
    /// — matches the ground-truth captures exactly (68% at 0.6mi off a 68%
    /// battery; 55% at 18.4mi off the same 68%), so this ports the real
    /// formula rather than the spec's optional "just use battery directly"
    /// simplification.
    private func statsRow(_ request: RideRequestRecord) -> some View {
        let fleetMember = request.input.fleetMember
        let dest = request.input.destination
        let batteryAfter = max(10, fleetMember.battery - Int((dest.miles * 0.7).rounded()))
        return HStack(spacing: 16) {
            statCell(label: "DISTANCE", value: "\(String(format: "%.1f", dest.miles)) mi")
            Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline, height: 22)
            statCell(label: "DRIVE TIME", value: "~\(dest.minutes) min")
            Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline, height: 22)
            statCell(label: "BATTERY AFTER", value: "\(batteryAfter)%")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Color.mrtTextMuted)
            Text(value)
                .font(.system(size: 14, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.mrtText)
        }
    }

    // MARK: Status row (ride-request.jsx:1360-1378)

    private func statusRow(_ request: RideRequestRecord) -> some View {
        let scheduled = isScheduled(request)
        let fleetMember = request.input.fleetMember
        return HStack(spacing: 8) {
            if let schedule = request.input.schedule {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                Text(fleetMember.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mrtText)
                Text("reserved for \(schedule.day) \(schedule.time)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
            } else {
                Circle().fill(Color.mrtParked).frame(width: 6, height: 6)
                Text(fleetMember.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mrtText)
                Text("is parked \u{00B7} ready to dispatch")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            (scheduled ? Color.mrtGold.opacity(0.08) : Color.mrtDriving.opacity(0.06)),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(scheduled ? Color.mrtGold.opacity(0.25) : Color.mrtDriving.opacity(0.20), lineWidth: MRTMetrics.hairline)
        )
    }

    // MARK: CTA area (ride-request.jsx:1379-1408)

    @ViewBuilder
    private func ctaArea(_ request: RideRequestRecord) -> some View {
        if sent {
            sentPill(request)
        } else if sending {
            sendingPill(request)
        } else {
            HStack(spacing: 10) {
                declineButton
                MRTButton(isScheduled(request) ? "Accept ride" : "Accept & send", variant: .outlineDraw, fullWidth: true) {
                    handleAccept(request)
                }
            }
        }
    }

    /// Custom destructive fill — `outline-draw` is reserved for the accept
    /// CTA only (CLAUDE.md), so Decline mirrors `ScheduledRideSheet
    /// .cancelButton`'s exact recipe rather than any of the 6 shared
    /// `MRTButtonVariant`s.
    private var declineButton: some View {
        Button(action: onDecline) {
            Text("Decline")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.mrtDialogRed)
                .frame(maxWidth: .infinity)
                .frame(height: MRTButtonSize.md.height)
                .background(Color.mrtDangerFillSoft, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                        .strokeBorder(Color.mrtRideCancelButtonBorder, lineWidth: MRTMetrics.hairline)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(MRTPressScaleButtonStyle())
    }

    private func sendingPill(_ request: RideRequestRecord) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Color.mrtGoldButtonLabel)
            Text(isScheduled(request) ? "Confirming\u{2026}" : "Sending to \(request.input.fleetMember.name)\u{2026}")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mrtGoldButtonLabel)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(Color.mrtGold, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
    }

    private func sentPill(_ request: RideRequestRecord) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mrtDriving)
            Text(sentLabel(request))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.mrtDriving)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 50)
        .background(Color.mrtDriving.opacity(0.14), in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.mrtDriving.opacity(0.35), lineWidth: MRTMetrics.hairline)
        )
    }

    private func sentLabel(_ request: RideRequestRecord) -> String {
        if let schedule = request.input.schedule {
            return "Reserved for \(schedule.day) \(schedule.time)"
        }
        return "Destination sent to \(request.input.fleetMember.name)"
    }

    // MARK: Helper line (ride-request.jsx:1409-1417)

    private func helperText(_ request: RideRequestRecord) -> some View {
        Text(helperCopy(request))
            .font(.system(size: 11))
            .foregroundStyle(Color.mrtTextMuted)
            .tracking(0.2)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func helperCopy(_ request: RideRequestRecord) -> String {
        let fleetMember = request.input.fleetMember
        if let passenger = request.input.passenger, !passenger.phone.isEmpty {
            let routeSuffix = isScheduled(request) ? "" : " and routes \(fleetMember.name)"
            return "Accepting texts \(passenger.firstName) a live tracking link\(routeSuffix)."
        }
        if let schedule = request.input.schedule {
            return "\(fleetMember.name) will be reserved for \(schedule.day) \(schedule.time)."
        }
        return "Accepting will route \(fleetMember.name) to \(request.input.destination.label)."
    }

    // MARK: Choreography (ride-request.jsx:1276-1280)

    private func isScheduled(_ request: RideRequestRecord) -> Bool {
        request.input.schedule != nil
    }

    private func handleAccept(_ request: RideRequestRecord) {
        sending = true
        Task {
            try? await Task.sleep(nanoseconds: UInt64(RideRequestTiming.ownerSendingDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            sent = true
            try? await Task.sleep(nanoseconds: UInt64(RideRequestTiming.ownerSentHoldDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onAccept()
        }
    }
}

// MARK: - Static route preview map
//
// Non-interactive two-point route between the request's pickup/destination —
// same technique as `ScheduledRideSheet`'s private `RideRouteMap` (which is
// file-private to a file this issue doesn't own), sized for
// `MRTMetrics.incomingRequestMapHeight` instead of that screen's
// `rideMapPreviewHeight`. No real street routing (per this issue's spec —
// M1 has no routing API), a straight two-point polyline is enough.
private struct IncomingRequestRouteMap: View {
    let pickup: CLLocationCoordinate2D
    let destination: CLLocationCoordinate2D

    private var route: [CLLocationCoordinate2D] { [pickup, destination] }

    var body: some View {
        Map(initialPosition: .region(VehicleRoute.fittedRegion(for: route, paddingFactor: 1.8)), interactionModes: []) {
            mapContent.annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        MapPolyline(coordinates: route)
            .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
        MapPolyline(coordinates: route)
            .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
        Annotation("Pickup", coordinate: pickup) { MRTEndpointDot(color: .mrtDriving, size: 11) }
        Annotation("Destination", coordinate: destination) { MRTEndpointDot(color: .mrtGold, size: 13) }
    }
}

#Preview("Now") {
    ZStack {
        Color.mrtBg.ignoresSafeArea()
        IncomingRequestSheet(
            request: RideRequestRecord(
                input: RideRequestInput(
                    pickup: RideRequestFixtures.savedPlaces[0],
                    destination: RideRequestFixtures.recentPlaces[2],
                    fleetMemberID: RideRequestFixtures.fleet[0].id
                ),
                status: .pending
            ),
            onAccept: {},
            onDecline: {}
        )
    }
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}

#Preview("Scheduled") {
    ZStack {
        Color.mrtBg.ignoresSafeArea()
        IncomingRequestSheet(
            request: RideRequestRecord(
                input: RideRequestInput(
                    pickup: RideRequestFixtures.savedPlaces[0],
                    destination: RideRequestFixtures.recentPlaces[1],
                    fleetMemberID: RideRequestFixtures.fleet[0].id,
                    schedule: RideSchedule(day: "Fri", time: "5:30 PM")
                ),
                status: .pending
            ),
            onAccept: {},
            onDecline: {}
        )
    }
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
