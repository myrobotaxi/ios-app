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
    /// MYR-264 — the ONE resolved live/sim flag (threaded from `HomeScreen`).
    /// SIM renders the fixture persona/vehicle; LIVE renders the real rider name +
    /// a real fleet-join vehicle (or neutral/hidden), never fixture data.
    var isLive: Bool = false
    /// MYR-264 — the owner's real fleet vehicle this request targets, joined by
    /// `vehicleId` in `HomeScreen`. `nil` in SIM (unused) and for a live request
    /// whose vehicle isn't in the loaded fleet (→ vehicle name hidden).
    var resolvedVehicle: Vehicle? = nil
    /// MYR-277 A2 — the TARGET vehicle's live position (joined by id in
    /// `HomeScreen`), used to estimate the car→pickup leg (leg 1 of dispatch v2).
    /// `nil` in SIM (fixture ride ids don't join the live fleet) and when the
    /// vehicle isn't loaded / has no GPS fix → the pickup leg is omitted and the
    /// card falls back to the single-leg stats row (pixel-identical to M1).
    var carPosition: CLLocationCoordinate2D? = nil
    /// MYR-277 C — the TARGET vehicle's live badge status. When `.inService` or
    /// `.offline` the car can't take a dispatch, so Accept is disabled with an
    /// honest reason line. `nil` in SIM / when the vehicle isn't loaded (Accept
    /// stays enabled, unchanged).
    var vehicleStatus: MRTVehicleStatus? = nil
    let onAccept: () -> Void
    let onDecline: () -> Void

    @State private var sending = false
    @State private var sent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// MYR-264 — what each gated surface renders for `request`: the fixture persona
    /// / vehicle in SIM, the real rider name + real fleet-join vehicle in LIVE (see
    /// `IncomingRequestDisplay`). Resolved once per request from the ONE `isLive`.
    private func display(for request: RideRequestRecord) -> IncomingRequestDisplay {
        IncomingRequestDisplay.resolve(request: request, isLive: isLive, liveVehicle: resolvedVehicle)
    }

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
            // MYR-264 — hide the vehicle status row entirely on the live path when
            // the request's vehicle isn't in the loaded fleet (no name to show and
            // nothing to honestly assert); the scheduled reservation line still
            // renders because its day/time come from the real wire schedule.
            if showsStatusRow(for: request) {
                statusRow(request)
                    .padding(.bottom, 18)
            }
            ctaArea(request)
            if !sending, !sent {
                // MYR-277 C — an honest reason replaces the helper line when the
                // target vehicle can't take the dispatch (in_service/offline).
                if let reason = Self.unavailableReason(
                    status: vehicleStatus,
                    vehicleName: display(for: request).vehicleName,
                    isScheduled: isScheduled(request)
                ) {
                    unavailableLine(reason)
                        .padding(.top, 12)
                } else {
                    helperText(request)
                        .padding(.top, 12)
                }
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
        let display = display(for: request)
        return HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.mrtRequesterAvatarStart, .mrtRequesterAvatarEnd],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .frame(width: 48, height: 48)
                .overlay(
                    // MYR-264 — the real/fixture name's initial when known, else a
                    // NEUTRAL person glyph (never a fabricated "S" on live).
                    Group {
                        if let initial = display.avatarInitial {
                            Text(initial)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: "person.fill")
                                .font(.system(size: 19))
                                .foregroundStyle(.white)
                        }
                    }
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(display.title(hasPassenger: request.input.passenger != nil))
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

    private func headerSubtitle(_ request: RideRequestRecord) -> String {
        if let schedule = request.input.schedule {
            return "Scheduled \u{00B7} \(schedule.day) \(schedule.time)"
        }
        // MYR-264 — SIM keeps the fixture literal (pixel-identical); LIVE derives an
        // honest relative time from the request's real `requestedAt` (no hardcoded
        // "just now").
        let when = isLive ? relativeRequestedTime(request.requestedAt) : "just now"
        return "\(IncomingRequestDisplay.neutralRole) \u{00B7} \(when)"
    }

    /// An honest coarse "when" for the live header — the request's real age.
    private func relativeRequestedTime(_ date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        let days = hours / 24
        return "\(days) day\(days == 1 ? "" : "s") ago"
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
            // MYR-277 A2 — when the car→pickup leg is known (live path with the
            // target vehicle's real position + a valid fix), show BOTH legs; else
            // fall back to the single ride-leg stats row (pixel-identical to M1 /
            // the `ownerIncoming` drift-gate scene, where `carPosition` is nil).
            if let pickupLeg = Self.pickupLegEstimate(carPosition: carPosition, pickup: request.input.pickup.coordinate) {
                legsRow(request, pickupLeg: pickupLeg)
            } else {
                statsRow(request)
            }
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
        let dest = request.input.destination
        // MYR-264 — the wire carries no per-request battery, so the BATTERY AFTER
        // cell (and its divider) is dropped on live rather than asserting a fixture
        // battery; DISTANCE/DRIVE TIME are real (filled by `TripEstimate`, MYR-219).
        let batteryAfter = display(for: request).batteryAfter
        return HStack(spacing: 16) {
            statCell(label: "DISTANCE", value: "\(String(format: "%.1f", dest.miles)) mi")
            statDivider
            statCell(label: "DRIVE TIME", value: "~\(dest.minutes) min")
            if let batteryAfter {
                statDivider
                statCell(label: "BATTERY AFTER", value: "\(batteryAfter)%")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var statDivider: some View {
        Rectangle().fill(Color.mrtBorder).frame(width: MRTMetrics.hairline, height: 22)
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

    // MARK: Two-leg itinerary (MYR-277 A2 — dispatch v2)
    //
    // Accepting routes the car to the PICKUP first, then the pickup→drop-off ride.
    // The card shows both legs honestly: the car→pickup ETA/distance (estimated
    // client-side from the target vehicle's live position, MYR-228 real-data-only)
    // and the pickup→drop-off ride leg (already carried on the destination).

    /// The car→pickup leg estimate, or `nil` when there's no usable car position
    /// (SIM, unloaded vehicle, or the "0,0 = no fix" convention). Pure + static so
    /// it's unit-testable without SwiftUI.
    static func pickupLegEstimate(carPosition: CLLocationCoordinate2D?, pickup: CLLocationCoordinate2D) -> (miles: Double, minutes: Int)? {
        guard let carPosition, !(carPosition.latitude == 0 && carPosition.longitude == 0) else { return nil }
        return TripEstimate.estimate(from: carPosition, to: pickup)
    }

    private func legsRow(_ request: RideRequestRecord, pickupLeg: (miles: Double, minutes: Int)) -> some View {
        let dest = request.input.destination
        return VStack(alignment: .leading, spacing: 10) {
            legLine(
                dotColor: .mrtDriving,
                name: "PICKUP",
                place: request.input.pickup.label,
                metric: "\(String(format: "%.1f", pickupLeg.miles)) mi \u{00B7} ~\(pickupLeg.minutes) min away"
            )
            Rectangle().fill(Color.mrtBorder).frame(height: MRTMetrics.hairline)
            legLine(
                dotColor: .mrtGold,
                name: "DROP-OFF",
                place: dest.label,
                metric: "\(String(format: "%.1f", dest.miles)) mi \u{00B7} ~\(dest.minutes) min"
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func legLine(dotColor: Color, name: String, place: String, metric: String) -> some View {
        HStack(alignment: .center, spacing: 9) {
            Circle().fill(dotColor).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.mrtTextMuted)
                Text(place)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(metric)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.mrtTextSec)
                .fixedSize()
        }
    }

    // MARK: Status row (ride-request.jsx:1360-1378)

    /// Whether the status row has anything honest to show: a scheduled request
    /// always shows its real reservation line; a live-now request shows only when
    /// its vehicle resolved from the loaded fleet (MYR-264).
    private func showsStatusRow(for request: RideRequestRecord) -> Bool {
        isScheduled(request) || display(for: request).vehicleName != nil
    }

    private func statusRow(_ request: RideRequestRecord) -> some View {
        let scheduled = isScheduled(request)
        let display = display(for: request)
        return HStack(spacing: 8) {
            if let schedule = request.input.schedule {
                Image(systemName: "calendar").font(.system(size: 13)).foregroundStyle(Color.mrtGold)
                if let name = display.vehicleName {
                    Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mrtText)
                    Text("reserved for \(schedule.day) \(schedule.time)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                } else {
                    // Live, no fleet join — the reservation is real, the vehicle name isn't known.
                    Text("Reserved for \(schedule.day) \(schedule.time)")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                }
            } else if let name = display.vehicleName {
                // MYR-264 — assert "parked · ready" only when the status is actually
                // known (sim fixtures); live shows the real vehicle name with a
                // neutral dot and NO unverified readiness claim.
                Circle().fill(display.showsReadyStatus ? Color.mrtParked : Color.mrtTextMuted).frame(width: 6, height: 6)
                Text(name).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mrtText)
                if display.showsReadyStatus {
                    Text("is parked \u{00B7} ready to dispatch")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mrtTextSec)
                }
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
                // MYR-277 C — Decline stays enabled; Accept is disabled (honest,
                // non-interactive) when the target vehicle is in_service/offline.
                // MYR-313 — …unless the request is SCHEDULED, which the gate must
                // not touch (see `isAcceptGated`).
                if Self.isAcceptGated(status: vehicleStatus, isScheduled: isScheduled(request)) {
                    disabledAcceptButton(request)
                } else {
                    MRTButton(isScheduled(request) ? "Accept ride" : "Accept & send", variant: .outlineDraw, fullWidth: true) {
                        handleAccept(request)
                    }
                }
            }
        }
    }

    /// A muted, non-interactive Accept for the in_service/offline gate (MYR-277 C).
    /// Mirrors the accept CTA's footprint (44pt tap-height, control radius) but
    /// carries no `outline-draw` trace so it never invites a tap.
    private func disabledAcceptButton(_ request: RideRequestRecord) -> some View {
        Text(isScheduled(request) ? "Accept ride" : "Accept & send")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.mrtTextMuted)
            .frame(maxWidth: .infinity)
            .frame(height: MRTButtonSize.md.height)
            .background(Color.mrtSurface, in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .accessibilityLabel("Accept unavailable")
    }

    /// The honest reason line under the CTAs when Accept is gated (MYR-277 C).
    private func unavailableLine(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.mrtTextSec)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    /// Whether the target vehicle can't take a dispatch RIGHT NOW (MYR-277 C).
    /// Pure + static so the gate is unit-testable without SwiftUI.
    static func isVehicleUnavailable(_ status: MRTVehicleStatus?) -> Bool {
        status == .inService || status == .offline
    }

    /// Whether Accept must be muted for this request (MYR-277 C, narrowed by
    /// MYR-313). The MYR-277 gate answers "can this car be dispatched NOW?", which
    /// is the right question for an INSTANT request and the wrong one for a
    /// reservation: the client's car was in service today while the request was for
    /// Saturday 5:30 PM, and the card refused the accept with "Lunar is in service
    /// — unavailable". Availability at the reservation instant is the scheduled-ride
    /// machinery's problem (MYR-179), not accept-time's — exactly as the per-rider
    /// `ride_active` guard, the per-vehicle one-active-ride index (MYR-266) and
    /// MYR-233's rider CTA gate all already exempt `scheduled_for IS NOT NULL`.
    /// So: SCHEDULED requests are never gated on current vehicle status.
    static func isAcceptGated(status: MRTVehicleStatus?, isScheduled: Bool) -> Bool {
        !isScheduled && isVehicleUnavailable(status)
    }

    /// The reason line text for a gated Accept, or `nil` when Accept is live
    /// (MYR-277 C; `nil` for every scheduled request per MYR-313, which then shows
    /// the normal helper text). Neutral "This vehicle" when the name isn't known.
    static func unavailableReason(status: MRTVehicleStatus?, vehicleName: String?, isScheduled: Bool) -> String? {
        guard isAcceptGated(status: status, isScheduled: isScheduled) else { return nil }
        let name = vehicleName ?? "This vehicle"
        let phrase = status == .offline ? "offline" : "in service"
        return "\(name) is \(phrase) \u{2014} unavailable"
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
            Text(sendingLabel(request))
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

    private func sendingLabel(_ request: RideRequestRecord) -> String {
        if isScheduled(request) { return "Confirming\u{2026}" }
        // MYR-264 — name the real joined vehicle when known, else a neutral verb.
        if let name = display(for: request).vehicleName { return "Sending to \(name)\u{2026}" }
        return "Sending\u{2026}"
    }

    private func sentLabel(_ request: RideRequestRecord) -> String {
        if let schedule = request.input.schedule {
            return "Reserved for \(schedule.day) \(schedule.time)"
        }
        if let name = display(for: request).vehicleName { return "Destination sent to \(name)" }
        return "Destination sent"
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
        // MYR-264 — reference the real joined vehicle name when known; on live with
        // no fleet join, drop the name rather than assert the fixture "Model Y".
        let vehicleName = display(for: request).vehicleName
        let destination = request.input.destination.label
        if let passenger = request.input.passenger, !passenger.phone.isEmpty {
            return Self.passengerCopy(isLive: isLive, isScheduled: isScheduled(request), vehicleName: vehicleName, passengerFirstName: passenger.firstName)
        }
        if let schedule = request.input.schedule {
            if let name = vehicleName { return "\(name) will be reserved for \(schedule.day) \(schedule.time)." }
            return "Reserved for \(schedule.day) \(schedule.time)."
        }
        return Self.nowRideCopy(isLive: isLive, vehicleName: vehicleName, destination: destination)
    }

    /// MYR-277 A2 — accept copy for a now-ride. LIVE (dispatch v2) says the car is
    /// routed to the PICKUP first, then on to the drop-off; SIM keeps the M1
    /// prototype copy verbatim so the `ownerIncoming` drift-gate scene is
    /// pixel-identical. Pure + static so it's unit-testable.
    static func nowRideCopy(isLive: Bool, vehicleName: String?, destination: String) -> String {
        if isLive {
            if let name = vehicleName { return "Accepting routes \(name) to the pickup, then to \(destination)." }
            return "Accepting dispatches to the pickup, then to \(destination)."
        }
        if let name = vehicleName { return "Accepting will route \(name) to \(destination)." }
        return "Accepting will dispatch to \(destination)."
    }

    /// MYR-277 A2 — accept copy for a for-someone-else ride with a phone. LIVE adds
    /// the v2 "routes … to the pickup" note; SIM keeps the M1 " and routes {name}".
    static func passengerCopy(isLive: Bool, isScheduled: Bool, vehicleName: String?, passengerFirstName: String) -> String {
        let routeSuffix: String
        if isScheduled || vehicleName == nil {
            routeSuffix = ""
        } else if isLive {
            routeSuffix = " and routes \(vehicleName!) to the pickup"
        } else {
            routeSuffix = " and routes \(vehicleName!)"
        }
        return "Accepting texts \(passengerFirstName) a live tracking link\(routeSuffix)."
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
