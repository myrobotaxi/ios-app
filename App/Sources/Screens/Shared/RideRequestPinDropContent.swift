import SwiftUI
import DesignSystem

// MARK: - RideRequestPinDropContent (MYR-171, design/app/ride-request.jsx
// PinDropContent 719-739)
//
// Compact sheet shown while choosing pickup on the map. `RidePinDropMapOverlay`
// is the center-fixed pin drawn over the map layer itself (in
// `SharedViewerScreen`'s ZStack, not this sheet).
struct RideRequestPinDropContent: View {
    @Bindable var viewerState: SharedViewerState
    let returnTo: PinDropReturn
    var totalHeight: CGFloat?

    // Pin label + coordinate come from `SharedViewerState.pinDropLabel`/
    // `pinDropCoordinate`: the reverse-geocoded real map-center in live mode,
    // and in sim the fixture `pinSpots[0]` ("Folsom & 2nd St") — an M1 scope
    // simplification (the jsx picks a `PIN_SPOTS` entry off drag distance;
    // this app has no drag-to-move-the-pin gesture, matching the prototype
    // capture default `.shots/prototype/03_after_dest_select.png`).

    var body: some View {
        // MYR-171 fix: this phase's content is short and fixed (no list to
        // scroll) — ride-request.jsx:1119-1131 sizes it to content ('auto'),
        // not to a fraction of the screen. A `ScrollView` here (even with a
        // `.frame(maxHeight:)` cap) greedily claims the full proposed
        // height regardless of content size, which both stretched this
        // sheet to ~88% of the screen (a large empty scrollable area below
        // the actual content) and pushed its top edge up into the map pin
        // overlay's fixed position. A plain `VStack` hugs its own content
        // height instead, matching the jsx's 'auto'.
        VStack(alignment: .leading, spacing: 0) {
            RideGrabHandle()

            // MYR-216 deliverable 2: back to the search sheet (destination
            // retained, CTA state) — the rider adjusts/restarts without confirming
            // a pickup. Follows the design's existing back pattern, Review's
            // "‹ Change trip" chevron+label (ride-request.jsx ReviewContent /
            // `RideRequestReviewContent` 65-78) — reused, not a new component.
            // Distinct from Cancel below, which abandons the request to idle.
            HStack {
                Button {
                    viewerState.returnFromPinDropToSearch()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Change trip").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Color.mrtGold)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            HStack(spacing: 11) {
                Circle()
                    .fill(Color.mrtGold.opacity(0.16))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder(Color.mrtGold.opacity(Double(0x55) / 255.0), lineWidth: MRTMetrics.hairline))
                    .overlay(Image(systemName: "mappin").font(.system(size: 16)).foregroundStyle(Color.mrtGold))
                VStack(alignment: .leading, spacing: 2) {
                    RideEyebrowText(text: "Pickup location", size: 10)
                    // MYR-211: reverse-geocoded device label in live mode; the
                    // fixture "Folsom & 2nd St" in sim (`pinDropLabel`).
                    Text(viewerState.pinDropLabel)
                        .font(.system(size: 16, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 12)

            Text("Drag the map to move the pin, then confirm your pickup spot.")
                .font(.system(size: 12.5))
                .tracking(-0.1)
                .foregroundStyle(Color.mrtTextSec)
                .padding(.bottom, 16)

            MRTButton("Confirm pickup here", variant: .outlineDraw, action: confirm)
                .padding(.bottom, 10)

            // MYR-200 CLIENT RULING (Thomas, follow-up 2026-07-09, overrides
            // ride-request.jsx:736 AND the interim destructive-fill version):
            // Cancel here matches the Booking sheet's "Cancel request" —
            // plain centered red TEXT, no fill (ride-request.jsx:661 recipe:
            // `color '#FF6B6B'`, 13/500, centered). Same exact treatment as
            // `RideRequestBookingContent`'s cancel rows.
            Button("Cancel", action: cancel)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.mrtDialogRed)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(minHeight: MRTMetrics.minTapTarget - 14)
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 16)
        .rideRequestSheetChrome()
    }

    private func confirm() {
        // MYR-211/212: the confirmed pickup is the AUTHORITATIVE pin position —
        // in live mode the map's settled center (wherever the rider dragged to)
        // with its reverse-geocoded street label, and the fixture point in sim.
        // See `SharedViewerState.pinDropCoordinate`/`pinDropLabel`.
        viewerState.draftPickup = RidePlace(
            id: "pin",
            label: viewerState.pinDropLabel,
            subtitle: nil,
            miles: 0,
            minutes: 0,
            icon: "mappin.circle.fill",
            coordinate: viewerState.pinDropCoordinate
        )
        switch returnTo {
        case .search: viewerState.sheetPhase = .search
        // MYR-212 defect 5: enter Review through the estimate seam so the trip
        // miles/minutes are computed once from this just-confirmed pickup.
        case .review: viewerState.enterReview()
        }
    }

    /// MYR-216 deliverable 2: Cancel ABANDONS the whole request back to idle
    /// (`closeToIdle`, ride-request.jsx:1133) — distinct from the new back control
    /// above, which returns to search keeping the destination. (Pre-MYR-216 this
    /// went to `.search`, identical to where back now lands; splitting them makes
    /// the two controls genuinely distinct — back = adjust, Cancel = abandon.)
    private func cancel() {
        viewerState.resetDraftToIdle()
    }
}

// MARK: - Center-fixed pin (drawn over the map layer, not the sheet)

struct RidePinDropMapOverlay: View {
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.1)
                .foregroundStyle(Color.mrtText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.mrtBg.opacity(0.92), in: Capsule())
            Image(systemName: "mappin")
                .font(.system(size: 34))
                .foregroundStyle(Color.mrtGold)
                .shadow(color: .mrtGoldGlow, radius: 6)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
