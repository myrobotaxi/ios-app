import SwiftUI
import DesignSystem

// MARK: - RideRequestOutcomeContent (MYR-197, design/app/ride-request.jsx
// OutcomeContent 670-717)
//
// The moment right after the owner responds — accepted (green check, "Your
// ride's on the way" / "{First}'s ride is on the way", the SMS-tracking-link
// confirmation when the ride is for someone else, "Track ride") or declined
// (gray X, "Request declined", Close/Try again).
//
// `OutcomeContent` is defined in the design source but was never actually
// reachable there: `ExpandingRequestSheet`'s own phase-reaction effect
// (ride-request.jsx:1098-1117) jumps `.accepted` straight to `'tracking'`
// and `.declined` straight to `'search'` (+ the separate small
// `DeclinedNotice` overlay, ride-request.jsx:1254-1258) — confirmed live via
// the MYR-197 prototype walk (owner-accept and the solo-rider auto-accept
// fallback both skip straight into the tracking sheet with "no intermediate
// accepted banner", ride-request.jsx:1109-1111's own comment). Thomas's QA
// flagged the missing outcome moment as a real product gap regardless, so
// this view resurrects `OutcomeContent`'s content as new, intentional UX:
// `SharedViewerScreen.handleStatusChange` now routes both accept and decline
// through `.outcome` first, and it replaces the old `DeclinedNoticeCard`
// overlay entirely (one canonical declined surface — CLAUDE.md "reuse,
// don't fork", see that struct's header comment).
//
// The accepted branch also closes a real, independently-confirmed gap: prior
// to MYR-197 there was no rider-side confirmation that a "for someone else"
// passenger's tracking-link SMS actually went out (only the *owner's*
// `RouteSentToast` had that copy) — the chip below is that confirmation.
struct RideRequestOutcomeContent: View {
    @Bindable var viewerState: SharedViewerState
    var rideRequestService: SimulatedRideRequestService
    let accepted: Bool

    private var request: RideRequestRecord? { rideRequestService.activeRequest }
    private var fleetMember: FleetMember { request?.input.fleetMember ?? RideRequestFixtures.fleet[0] }
    private var passenger: RidePassenger? { request?.input.passenger }
    private var forSomeone: Bool { passenger.map { !$0.name.isEmpty } ?? false }

    /// "{model} {name}" — the same "your ride" naming Booking/Tracking use
    /// (not the jsx's separate, idle-map-only `vehicleName` prop, which
    /// tracks a fixed demo vehicle unrelated to the fleet member actually
    /// chosen in Review — see `RideRequestTrackingContent`'s equivalent).
    private var vehicleLabel: String { "\(fleetMember.model) \(fleetMember.name)" }

    var body: some View {
        VStack(spacing: 0) {
            RideGrabHandle()
            Group {
                if accepted { acceptedBody } else { declinedBody }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.bottom, 30)
        }
        .rideRequestSheetChrome()
        .overlay(alignment: .topTrailing) {
            // Minimize, not cancel — an accepted ride is real and still
            // live; a dismissed declined card just drops back to the
            // resting idle sheet (mirrors `RideRequestBookingContent`'s own
            // X, the closest sibling phase — `OutcomeContent`'s own X
            // handler was never exercised live, see this file's header
            // comment, so this is a considered choice, not a literal port).
            RideSheetCloseButton { viewerState.sheetPhase = .idle }
                .padding(.top, 14)
                .padding(.trailing, 14)
        }
    }

    // MARK: Accepted (ride-request.jsx:673-696)

    private var acceptedBody: some View {
        VStack(spacing: 0) {
            iconCircle(
                background: AnyShapeStyle(
                    RadialGradient(colors: [Color.mrtDriving, Color.mrtDrivingDeep], center: UnitPoint(x: 0.3, y: 0.3), startRadius: 0, endRadius: 30)
                ),
                glow: Color.mrtDriving.opacity(0.27) // `${T.driving}44`
            ) {
                Image(systemName: "checkmark").font(.system(size: 26, weight: .bold)).foregroundStyle(.white)
            }
            .padding(.bottom, 14)

            Text(forSomeone ? "\((passenger?.firstName ?? ""))\u{2019}s ride is on the way" : "Your ride\u{2019}s on the way")
                .font(.system(size: 18, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .multilineTextAlignment(.center)
                .padding(.bottom, 6)

            (Text("\(fleetMember.owner) sent the destination to ") + Text(vehicleLabel).foregroundColor(Color.mrtText).fontWeight(.medium) + Text("."))
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 280)
                .padding(.bottom, forSomeone && !(passenger?.phone.isEmpty ?? true) ? 14 : 16)

            if forSomeone, let passenger, !passenger.phone.isEmpty {
                smsChip(phone: passenger.phone).padding(.bottom, 16)
            }

            MRTButton("Track ride", variant: .gold, size: .sm) {
                viewerState.sheetPhase = .tracking
            }
        }
    }

    private func smsChip(phone: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "paperplane.fill").font(.system(size: 13)).foregroundStyle(Color.mrtDriving)
            (Text("Tracking link texted to ") + Text(phone).foregroundColor(Color.mrtText).fontWeight(.semibold).monospacedDigit())
                .font(.system(size: 12))
                .foregroundStyle(Color.mrtTextSec)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(maxWidth: 300)
        .background(Color.mrtDriving.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.mrtDriving.opacity(0.28), lineWidth: MRTMetrics.hairline))
    }

    // MARK: Declined (ride-request.jsx:699-716)

    private var declinedBody: some View {
        VStack(spacing: 0) {
            iconCircle(background: AnyShapeStyle(Color.mrtText.opacity(0.04)), border: Color.mrtBorder) {
                Image(systemName: "xmark").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.mrtTextSec)
            }
            .padding(.bottom, 14)

            Text("Request declined")
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.mrtText)
                .padding(.bottom, 6)

            Text("\(fleetMember.owner) can\u{2019}t accept right now.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.mrtTextSec)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 260)
                .padding(.bottom, 16)

            HStack(spacing: 8) {
                MRTButton("Close", variant: .outlineMuted, size: .sm, action: close)
                MRTButton("Try again", variant: .gold, size: .sm, action: tryAgain)
            }
        }
    }

    // MARK: Shared icon circle (ride-request.jsx:676-683,700-704 — 60pt circle)

    private func iconCircle(background: AnyShapeStyle, glow: Color? = nil, border: Color? = nil, @ViewBuilder icon: () -> some View) -> some View {
        Circle()
            .fill(background)
            .frame(width: 60, height: 60)
            .overlay(border.map { Circle().strokeBorder($0, lineWidth: MRTMetrics.hairline) })
            .shadow(color: glow ?? .clear, radius: glow == nil ? 0 : 18)
            .overlay(icon())
    }

    // MARK: Actions (ride-request.jsx's `onClose`/`onAgain` — never wired
    // live, see this file's header comment; these mirror `DeclinedNoticeCard`
    // /`PendingContent`'s "Cancel request" precedent for the same effect).

    private func close() {
        rideRequestService.cancel()
        viewerState.resetDraftToIdle()
    }

    /// Keeps the draft trip (destination/passenger/schedule/fleet pick) and
    /// just clears the declined record — ride-request.jsx's `onRebook` only
    /// resets `requestState`, not the draft (`{setRequestState('idle');
    /// setPhase('search');}`), so the rider can resubmit the same trip
    /// without re-entering everything.
    private func tryAgain() {
        rideRequestService.cancel()
        viewerState.sheetPhase = .search
    }
}
