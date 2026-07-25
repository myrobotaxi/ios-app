import SwiftUI
import DesignSystem

// MARK: - RiderTrackingSheet (MYR-271)
//
// Hosts the rider's live tracking card on the SHARED `PanSheet` UIKit engine — the
// same MYR-236 foundation the owner `MRTDetentSheet` and the rider idle↔search sheet
// use — so the tracking sheet DRAGS with the same fluid, 1:1, velocity-projected feel
// and chrome as the rest of the app, instead of the old fixed `rideRequestSheetChrome`
// card. Deliberately NOT `.presentationDetents` (keeps the MYR-236 engine).
//
// The two-leg map + camera behind the sheet are UNCHANGED — they live in
// `SharedViewerScreen.backgroundMap` and only read the ride status/route, which this
// sheet doesn't touch. What this adds is the draggable surface: the card lays out once
// at its full height (+ overshoot pad) top-aligned under a grab handle, and the engine
// translates it between a shorter PEEK detent (hero band visible, more map revealed)
// and the FULL card. The settled visible height is reported back through
// `settledHeight` so `SharedViewerScreen` can re-anchor the recenter button + the map
// camera inset ABOVE the sheet's settled top in every detent (MYR-271 recenter fix).
struct RiderTrackingSheet<Content: View>: View {
    /// The sheet's current settled visible height (points from the physical bottom
    /// edge) — the recenter button + map camera inset anchor above this.
    @Binding var settledHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The full card's measured natural height (grab handle + content) — the top
    /// detent. Starts at the tracking sheet's representative cover height until the
    /// first measurement.
    @State private var measuredHeight: CGFloat = MRTMetrics.trackingMapBottomInset
    /// Detent index: 0 = peek (hero band), 1 = full card. Rests at full.
    @State private var selection = 1

    /// Peek shows the hero band + a hint of the itinerary; dragging down to it reveals
    /// more of the two-leg map. Full is the whole card.
    private var peekHeight: CGFloat { MRTMetrics.trackingSheetPeekHeight }

    private var detents: [CGFloat] {
        let full = measuredHeight.isFinite && measuredHeight > peekHeight ? measuredHeight : peekHeight + 1
        return [peekHeight, full]
    }

    var body: some View {
        PanSheet(
            detentHeights: detents,
            selection: $selection,
            reduceMotion: reduceMotion,
            accessibilityIdentifier: "mrt.trackingSheet",
            accessibilityLabel: "Ride tracking sheet",
            onSettle: { index in
                settledHeight = detents[min(max(index, 0), detents.count - 1)]
            }
        ) {
            surface
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: detents) { _, new in
            // Keep the reported settled height in sync when the measured full detent
            // lands (the recenter button + map inset re-anchor off it).
            let clamped = min(max(selection, 0), new.count - 1)
            settledHeight = new[clamped]
        }
    }

    /// The hosted surface: a decorative grab handle over the tracking card, on the
    /// ride-request sheet wash filling the whole envelope (incl. the overshoot band,
    /// so an upward rubber-band never leaks the map beneath the lifted sheet).
    private var surface: some View {
        VStack(spacing: 0) {
            RideGrabHandle() // decorative — the engine's pan owns the drag
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TrackingSheetHeightKey.self, value: proxy.size.height)
                    }
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(RideRequestSheetBackground())
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.sheetRadius, topTrailingRadius: MRTMetrics.sheetRadius, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: -8)
        .onPreferenceChange(TrackingSheetHeightKey.self) { height in
            // Full detent = grab handle + measured content height.
            let full = height + MRTMetrics.sheetGrabHandleHeight
            if full > 0, abs(full - measuredHeight) > 0.5 { measuredHeight = full }
        }
    }
}

/// Measures the tracking card's natural height so the engine can adopt it as the
/// full detent.
private struct TrackingSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
