import Foundation
import MyRoboTaxiKit
import SwiftUI
import DesignSystem

// MARK: - Cancel, from the tracking sheet (MYR-397 item 1, second half)
//
// *"drag UP → full details from the data we hold (LOOK FOR card, itinerary, plate)
// **plus a Cancel ride option**. Cancel appears in EVERY pre-pickup phase
// (requested/accepted/waiting/heading); at pickup and beyond, same sheet grammar,
// no Cancel."*
//
// TWO separate things live here, and they are separate on purpose:
//
//  1. `RiderTrackingCancelVisibility` — WHEN the action exists, as a pure function
//     of the stage. Pure because "is this ride still cancellable?" is the sort of
//     rule that otherwise ends up expressed twice, slightly differently, in a view
//     and in whatever guards the action.
//  2. `RiderActiveRideCancel` — WHAT the tap does, which is the r14
//     `ReservationCancel` grammar applied to a LIVE ride rather than a
//     reservation. Same three rules, and the reason they transfer intact is that
//     the failure they were written for is the same failure: a `POST
//     /api/ride-requests/{id}/cancel` the server can refuse.
//
// **THE EXISTING `cancel()` IS NOT THAT PATH, AND WIRING THE BUTTON TO IT WOULD
// HAVE SHIPPED THE MYR-381 DEFECT A THIRD TIME.** `RideRequestService.cancel()`
// clears `activeRequest` synchronously and fires the POST into a detached
// `Task { _ = try? await … }` — the answer is discarded, unexamined, unlogged. On
// the pending pill that is survivable: nothing has been dispatched and the rider
// is one tap from asking again. On a DISPATCHED ride it is the worst outcome this
// app can produce — a rider who believes they have cancelled, walking away from a
// car that is still coming for them. So the tracking Cancel awaits the call,
// classifies the failure, RECONCILES it against a re-read, and only removes the
// ride when the server (or the re-read) agrees it is gone.

/// Whether the tracking sheet offers "Cancel ride".
enum RiderTrackingCancelVisibility {

    /// Pre-pickup only.
    ///
    /// The stage already folds status and progress into the four situations this
    /// sheet has (`RiderTrackingStage.stage`), so asking it — rather than
    /// re-deriving from `RideRequestStatus` — is what keeps the button and the
    /// sheet it sits in from ever disagreeing about which phase the ride is in.
    ///
    /// `.arrivedAwaitingStart` is the boundary and it is a NO: the owner has
    /// confirmed the car is at the kerb, which is what "at pickup" means. The
    /// server would refuse the cancel too, and offering a control that exists to
    /// be refused is MYR-233's dead end wearing a destructive tint.
    static func showsCancel(stage: RiderTrackingStage) -> Bool {
        switch stage {
        case .toPickup: true
        case .arrivedAwaitingStart, .inRide, .arrivingDropoff: false
        }
    }
}

/// The rider's own two sentences for a refused ride cancel.
///
/// `ReservationCancelCopy.rider` is about a RESERVATION ("that ride is still
/// booked"), which is the wrong noun for a car that is on its way; the shapes are
/// identical and only the objects differ, so this is a third value of the SAME
/// type rather than a second copy grammar.
extension ReservationCancelCopy {
    static let riderActiveRide = ReservationCancelCopy(
        refused: "That ride can\u{2019}t be cancelled right now",
        unreachable: "Couldn\u{2019}t reach the server \u{00B7} your ride is still on"
    )
}

/// Runs a live ride's cancel and reports what to say about it.
///
/// Deliberately a free function over two closures rather than a method on the
/// service: the service's own `cancel()` is the OPTIMISTIC pending-pill path and
/// must stay exactly as it is (the booking grace window depends on it), while this
/// is the awaited, reconciled one. Keeping them apart is what stops a later edit
/// to one silently changing the other.
enum RiderActiveRideCancel {

    /// - Parameters:
    ///   - rideID: the SERVER's ride id (`activeServerRideID`) — never the client
    ///     UUID a rider-submitted record carries before its create POST returns.
    ///   - cancel: performs the mutation; throws whatever the Kit threw.
    ///   - reread: re-reads the rider's open ride and answers whether this ride is
    ///     STILL HELD. A read that did not answer must report `true` — "I could
    ///     not check" is not evidence the ride is gone, and this is the one
    ///     surface where being wrong about that leaves somebody at a kerb.
    /// Does the re-read still hold a LIVE ride?
    ///
    /// `nil` is the clearest yes-it-is-gone there is: `LiveRideRequestService
    /// .integrate` maps the wire's `cancelled` to NO app status at all and clears
    /// the record, so a successful cancel's only signal is the record
    /// disappearing (MYR-172, "cancelled is an erasure, not a status").
    ///
    /// `.declined` and `.completed` are gone too — a ride that ended some other
    /// way while the tap was in flight still ends up where the rider asked it to
    /// be, and telling them the cancel failed would be true about the request and
    /// false about the thing they care about. Written as an exhaustive switch, the
    /// `RiderRouteLifetime` precedent: a status added later has to be classified.
    static func stillStands(status: RideRequestStatus?) -> Bool {
        guard let status else { return false }
        switch status {
        case .pending, .accepted, .arrived, .enroute: return true
        case .declined, .completed: return false
        }
    }

    static func perform(
        rideID: String,
        cancel: () async throws -> Void,
        reread: () async -> Bool
    ) async -> ReservationCancelOutcome {
        var failure: ReservationCancelFailure?
        do {
            try await cancel()
        } catch {
            failure = ReservationCancelFailure.classify(error)
            ReservationCancelLog.record(failure!, action: "cancel", rideID: rideID)
        }
        let stillHeld = await reread()
        return ReservationCancelOutcome.resolve(
            failure: failure,
            stillHeld: stillHeld,
            copy: .riderActiveRide
        )
    }
}

// MARK: - The slot

/// The Cancel action's slot in the tracking sheet's full-details layer.
///
/// **A SLOT, NOT AN `if` AT THE CALL SITE**, and the difference is the client's
/// own words: *"at pickup and beyond, same sheet grammar, no dead space where it
/// was."* A conditional inside the parent `VStack` is correct today and is exactly
/// the shape that grows a `Spacer` or a reserved height the next time somebody
/// tunes this layout — the MYR-360 lesson about `@ViewBuilder` slots typed as
/// `Optional`. As its own view the emptiness is MEASURABLE, and
/// `RiderTrackingSheetCompositionTests` measures it: **0pt when hidden.**
struct TrackingCancelSlot: View {
    let visible: Bool
    let isCancelling: Bool
    let action: () -> Void

    var body: some View {
        if visible {
            Button(action: action) {
                HStack(spacing: 8) {
                    if isCancelling {
                        SpinnerRing(diameter: 15, lineWidth: 2, trackColor: .mrtBorder, color: .mrtDanger)
                    }
                    Text(isCancelling ? "Cancelling\u{2026}" : "Cancel ride")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.mrtDanger)
                }
                .frame(maxWidth: .infinity)
                .frame(height: MRTMetrics.minTapTarget)
                .contentShape(Rectangle())
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.mrtDanger.opacity(0.35), lineWidth: MRTMetrics.hairline)
                )
            }
            .buttonStyle(.plain)
            .disabled(isCancelling)
            .accessibilityIdentifier("mrt.tracking.cancelRide")
            .accessibilityLabel("Cancel ride")
            .padding(.top, MRTMetrics.trackingCancelTopGap)
        }
    }
}
