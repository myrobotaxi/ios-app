import SwiftUI
import DesignSystem

// MARK: - Owner ride-aware dispatch status + actions (MYR-270 — owner-driven
// dispatch v2)
//
// The owner's Live Map tracks the ride they accepted and its LIVE state: the
// shared `RideRequestService.activeRequest.status` is folded from every
// `ride_status_changed` WS unicast the owner receives (see
// `LiveRideRequestService.integrate`), so as the owner reaches the curb
// (`accepted → arrived`), the rider starts (`arrived → enroute`) and the owner
// drops off (`→ completed`), this surface updates in place. The owner drives two
// of those transitions directly from here: "Arrived at pickup" during `accepted`,
// and "Dropped off" during `enroute`.
//
// MYR-411 — **THE ARRIVED STATE MEANS THE CURB, NOT BOARDING**, and until this
// issue the button that reaches it said the opposite. It read "Picked up", so
// owners tapped it once the rider was in the car — which is a whole boarding
// later than the moment `arrived` stands for, and the rider's LA v3 wave glyph
// ("Your ride is here") is pushed off that status, so it fired late every time.
// The relabel is COPY ONLY: the button still calls `RideRequestService.pickedUp()`
// and the same §7.8 `/picked-up` write still moves `accepted → arrived`
// (`RideDispatchStatusTests` + `LiveRideRequestServiceTests` pin the pair — the
// LABEL and the TRANSITION are asserted together so a future copy pass cannot
// quietly take the wire with it). The rider's circular "Start ride" remains the
// one and only `arrived → enroute` trigger; there is deliberately NO second owner
// button for boarding.
//
// `OwnerRideStatusLine` is a PURE resolver (no SwiftUI) so the status lines are
// unit-testable, and `OwnerDispatchCard` renders them tokens-only. Both take REAL
// data only (MYR-228): the rider name resolves through the SAME gated
// `IncomingRequestDisplay` the incoming sheet/accept toast use (real wire name on
// live, fixture "Sam" in sim), and every field falls back to a NEUTRAL phrasing
// when absent — never a fabricated persona.

enum OwnerRideStatusLine {
    /// The single status line for the owner's active dispatched ride, or `nil` for
    /// a non-active status (`pending` shows the incoming sheet; `declined` shows
    /// nothing). Neutral fallbacks when the rider name / drop-off label is absent.
    ///  • `accepted` (leg 1) → "En route to pickup · <Name>"
    ///  • `arrived`          → "At pickup · waiting for <Name> to start"
    ///  • `enroute`  (leg 2) → "<Name> aboard · heading to <dropoff>"
    ///  • `enroute` + ETA≤2  → "Arriving at <dropoff>"
    ///  • `completed`        → "Dropped off ✓"
    static func text(status: RideRequestStatus, riderName: String?, dropoffLabel: String?, arriving: Bool = false) -> String? {
        let name = cleaned(riderName)
        let drop = cleaned(dropoffLabel)
        switch status {
        case .accepted:
            return name.map { "En route to pickup \u{00B7} \($0)" } ?? "En route to pickup"
        case .arrived:
            // MYR-411 — the car is AT THE CURB and nobody is aboard yet, so this
            // line no longer opens with "Picked up". It states where the car is and
            // names the RIDER's move out of the state (their circular "Start ride"),
            // keeping the existing "<state> · waiting for <Name> to <verb>" grammar
            // and its neutral fallback.
            return name.map { "At pickup \u{00B7} waiting for \($0) to start" } ?? "At pickup \u{00B7} waiting to start"
        case .enroute:
            if arriving {
                return drop.map { "Arriving at \($0)" } ?? "Arriving"
            }
            switch (name, drop) {
            case let (name?, drop?): return "\(name) aboard \u{00B7} heading to \(drop)"
            case let (name?, nil): return "\(name) aboard"
            case let (nil, drop?): return "Heading to \(drop)"
            case (nil, nil): return "Rider aboard"
            }
        case .completed:
            return "Dropped off \u{2713}"
        case .pending, .declined:
            return nil
        }
    }

    /// Whether the owner's in-ride line should read "Arriving" — pure + testable
    /// (MYR-270 review). ONLY during `enroute`, when the car is actively DRIVING
    /// with a real ETA of 1…2 min. `snapshot.etaMinutes` is a non-optional Int
    /// that collapses an ABSENT ETA to 0 (VehicleContractMapping), so `0` means
    /// "no ETA yet / stationary", NEVER "arriving" — otherwise the owner flashes
    /// "Arriving" the instant leg 2 starts (car still parked at pickup, dropoff
    /// ETA not yet streamed), matching the rider path's honest nil-handling.
    static func arriving(status: RideRequestStatus, isDriving: Bool, etaMinutes: Int) -> Bool {
        status == .enroute && isDriving && etaMinutes > 0 && etaMinutes <= 2
    }

    /// The owner's action CTA title for the current dispatched state, or `nil` when
    /// there is nothing for the owner to do (`arrived` — awaiting the rider's Start;
    /// and `completed`). Pure so the accepted→"Arrived at pickup" /
    /// enroute→"Dropped off" gating is unit-testable.
    ///
    /// MYR-411 — the accepted title is the CURB, not boarding: it is tapped on
    /// reaching the pickup, and it drives the identical `accepted → arrived`
    /// transition "Picked up" drove. `arrived` stays `nil` — the state's only exit
    /// is the rider's own "Start ride", and a second owner button here would be a
    /// way to take the ride enroute with nobody in the car.
    static func actionTitle(for status: RideRequestStatus) -> String? {
        switch status {
        case .accepted: return "Arrived at pickup"
        case .enroute: return "Dropped off"
        case .arrived, .completed, .pending, .declined: return nil
        }
    }

    /// MYR-292 — whether the owner's top-of-map dispatch card should be on screen for
    /// the CURRENT active request. Pure (no SwiftUI, no view state) so the whole
    /// "Dropped off ✓" acknowledgement rule is unit-testable and cannot drift between
    /// the card, the status line and the CTA — the same reasoning as the rider's
    /// `SharedViewerScreen.reconciledPhase`.
    ///
    /// `acknowledgedID` is the id of the `completed` ride whose confirmation the owner
    /// has already seen. It is stored on `OwnerHomeState`
    /// (`acknowledgedCompletedRideID`) — the owner-scoped observable that OUTLIVES
    /// this screen — rather than in `HomeScreen` `@State`, which `RootView`'s
    /// `switch ownerTab` destroys on every trip to Drives/Share/Settings. Because the
    /// input is a plain id, this resolver is idempotent across remounts: a fresh
    /// `HomeScreen` reading the same `OwnerHomeState` resolves to the same answer.
    ///
    ///  • `accepted` / `arrived` / `enroute` → always visible (a live dispatch).
    ///  • `completed` → visible until acknowledged, then hidden for that ride — on
    ///    this mount and every later one, including a cold launch straight into an
    ///    already-completed ride once its auto-dismiss has run.
    ///  • `pending` (the incoming sheet owns that state) / `declined` / no ride → hidden.
    static func dispatchCardVisible(status: RideRequestStatus?, rideID: String?, acknowledgedID: String?) -> Bool {
        // `status` and `rideID` co-vary (both read off the one active record), so a
        // missing either means "no active ride" — nothing to show.
        guard let status, let rideID else { return false }
        switch status {
        case .accepted, .arrived, .enroute: return true
        case .completed: return rideID != acknowledgedID
        case .pending, .declined: return false
        }
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The owner's action for the current dispatched state — a title + handler the
/// card renders as a gold CTA. `nil` when there is nothing to do.
struct OwnerDispatchAction {
    let title: String
    let handler: () -> Void
}

/// The top-of-map dispatch card for an active dispatched ride: a status pill (same
/// capsule recipe as the `MapHeader` vehicle chip — fill + hairline + shadow,
/// tokens-only) plus, when the owner can act, a gold CTA button beneath it
/// ("Arrived at pickup" during accepted, "Dropped off" during enroute). Shown ONLY while a
/// ride is dispatched, so the plain owner Home (`ownerHome` drift-gate scene, no
/// active ride) is unaffected.
struct OwnerDispatchCard: View {
    let line: String
    let isComplete: Bool
    /// The owner's CTA for this state, or `nil` (arrived / completed → status only).
    var action: OwnerDispatchAction?
    /// Disables the CTA for the frame it is tapped (double-tap guard) — cleared by
    /// the caller on the next status change (MYR-265 review: reset the in-flight
    /// latch on status change so a re-shown button is tappable again).
    var actionDisabled: Bool = false

    /// The identifiers `OwnerDispatchSheetOverlapUITests` reads the two elements'
    /// frames by. A UI test cannot ask "does this overlap the sheet" of a view it
    /// cannot address, and matching on the CTA's TITLE would tie the guard to
    /// MYR-411's copy.
    static let pillAccessibilityIdentifier = "ownerDispatchPill"
    static let ctaAccessibilityIdentifier = "ownerDispatchCTA"

    var body: some View {
        VStack(spacing: 10) {
            statusPill
            if let action {
                MRTButton(action.title, variant: .gold, size: .sm, fullWidth: true, action: action.handler)
                    .disabled(actionDisabled)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier(Self.ctaAccessibilityIdentifier)
            }
        }
        .padding(.horizontal, 24)
        // MYR-419 — the card's own height, which is what the sheet reserves room
        // for. A `background` probe rather than a fixed constant because the CTA
        // is present in two of the four dispatch states and absent in the others.
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: OwnerDispatchCardHeightKey.self, value: proxy.size.height)
            }
        )
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isComplete ? Color.mrtTextSec : Color.mrtGold)
                .frame(width: 7, height: 7)
                .shadow(color: isComplete ? .clear : .mrtGoldGlow, radius: 4)
            Text(line)
                .font(.system(size: 13.5, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(Color.mrtText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: MRTMetrics.minTapTarget)
        .background(Color.mrtMapChipFill, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.mrtMapChipBorder, lineWidth: MRTMetrics.hairline))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line)
        .accessibilityIdentifier(Self.pillAccessibilityIdentifier)
    }
}
