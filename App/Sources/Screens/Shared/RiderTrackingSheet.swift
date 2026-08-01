import SwiftUI
import DesignSystem

// MARK: - RiderTrackingSheet (MYR-271, redesigned MYR-397)
//
// Hosts the rider's live tracking card on the SHARED `PanSheet` UIKit engine — the
// same MYR-236 foundation the owner `MRTDetentSheet` and the rider idle↔search
// sheet use — so the tracking sheet DRAGS with the same fluid, 1:1,
// velocity-projected feel and chrome as the rest of the app.
//
// **MYR-397 REPLACES THE ONE-LAYER MODEL WITH THE CROSSFADE ONE.** MYR-271 hosted a
// single card and let the peek detent be that card translated down until 150pt of
// it showed — so dragging down guillotined the itinerary mid-row, which is
// MYR-296's own defect on MYR-296's own surface, reintroduced by the change that
// made the sheet draggable. The client filmed it: *"Why can I drag this bottom
// sheet down… achieve a clean peak state."*
//
// The two detents are now two COMPOSITIONS, hosted simultaneously and
// cross-dissolved by the engine at the UIKit layer (`PanSheetCrossfade`, the exact
// mechanism `RiderIdleSearchSheet` uses):
//
//   • PEEK — `RiderTrackingPeekContent`: the status line, its one-line context and
//     the ETA. A complete composition at its OWN measured height, so nothing is
//     cropped because nothing is hidden. `SHEET_HEIGHTS`' rule for every phase past
//     search is "size to content" (ride-request.jsx:47), which is why the height is
//     measured rather than the pinned 150 the old peek used.
//   • FULL — the whole card: LOOK FOR, itinerary, plate, and (pre-pickup) Cancel.
//
// Both are built by ONE `RideRequestTrackingContent` (see `TrackingSheetLayer`), so
// the peek's ETA is by construction the number the card above it is showing.
//
// **THE CHROME RIDES THE EDGE.** `settledHeight` is still reported for anything
// that legitimately wants a resting number, but the recenter + expand controls no
// longer position off it — they are laid out at the peek detent and translated by
// the engine per drag frame and through the settle (`SheetEdgeAnchor`). That is
// MYR-397 item 3: before, they stood still through the whole drag and jumped once
// at settle, which is what the client's three screenshots caught.
struct RiderTrackingSheet<Peek: View, Full: View>: View {
    /// The sheet's current settled visible height (points from the physical bottom
    /// edge).
    @Binding var settledHeight: CGFloat
    /// The PEEK detent's resolved height, published so the host can lay its
    /// edge-following chrome out against it (the anchor's base).
    @Binding var peekHeight: CGFloat
    /// MYR-397 — the chrome that rides this sheet's top edge.
    let edgeAnchor: SheetEdgeAnchor
    @ViewBuilder var peekContent: () -> Peek
    @ViewBuilder var fullContent: () -> Full
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The full card's measured natural height (grab handle + content) — the top
    /// detent. Starts at the tracking sheet's representative cover height until the
    /// first measurement.
    @State private var measuredFullHeight: CGFloat = MRTMetrics.trackingMapBottomInset
    /// The peek composition's measured natural height (grab handle + content).
    /// MYR-397 — measured, not pinned: the peek grows by exactly one line when
    /// MYR-393's position-freshness qualifier is up and shrinks back when it is
    /// not, which is MYR-345's per-line reserve rule on this surface.
    @State private var measuredPeekHeight: CGFloat = MRTMetrics.trackingSheetPeekHeight
    /// Detent index: 0 = peek (brief summary), 1 = full details. Rests at FULL —
    /// the ride's details are what the rider opened this surface for, and the peek
    /// is where dragging DOWN takes them (which is the direction the client's report
    /// is about).
    @State private var selection = Self.initialSelection

    /// MYR-397 — headless tooling cannot drag a sheet, so the peek detent has no
    /// capture route without a hook. `MRT_TRACKING_DETENT=peek` (and the
    /// `trackingPeek` scene) boots at index 0; unset, every existing tracking
    /// capture rests at full exactly as it did.
    private static var initialSelection: Int {
        #if DEBUG
        return DebugScene.tracksAtPeekDetent ? 0 : 1
        #else
        return 1
        #endif
    }

    /// Ascending detents: [peek, full]. Sanitised so a measurement that has not
    /// landed (or a peek that momentarily measures taller than the card) can never
    /// hand the engine an unsorted pair.
    private var detents: [CGFloat] {
        let peek = measuredPeekHeight.isFinite && measuredPeekHeight > 0
            ? measuredPeekHeight
            : MRTMetrics.trackingSheetPeekHeight
        let full = measuredFullHeight.isFinite && measuredFullHeight > peek ? measuredFullHeight : peek + 1
        return [peek, full]
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
            },
            // MYR-397 — the two compositions, dissolved by the drag progress at the
            // UIKit layer. At rest the alphas are EXACTLY 0/1 (`crossfadeRamp`), so
            // a settled capture is pixel-clean rather than half-faded.
            crossfade: PanSheetCrossfade(
                low: { peekLayer },
                high: { fullLayer }
            ),
            edgeAnchor: edgeAnchor
        ) {
            // Base layer — an ALWAYS-opaque sheet wash spanning the full envelope
            // (incl. the overshoot band), so an upward rubber-band or a
            // mid-crossfade frame never leaks the map beneath the lifted sheet.
            envelopeWash
        }
        .ignoresSafeArea(edges: .bottom)
        .onChange(of: detents) { _, new in
            let clamped = min(max(selection, 0), new.count - 1)
            settledHeight = new[clamped]
            // The anchor's base is the PEEK detent: the chrome is laid out there
            // and translated up by however much taller the sheet currently is.
            peekHeight = new[0]
            edgeAnchor.setBaseHeight(new[0])
        }
        .onAppear {
            peekHeight = detents[0]
            edgeAnchor.setBaseHeight(detents[0])
            settledHeight = detents[min(max(selection, 0), detents.count - 1)]
        }
    }

    /// The persistent sheet-wash base filling the surface envelope. Never faded —
    /// it is what keeps the overshoot band and every mid-crossfade frame opaque,
    /// and it carries the corners, hairline and shadow both layers sit inside.
    private var envelopeWash: some View {
        RideRequestSheetBackground()
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.sheetRadius, topTrailingRadius: MRTMetrics.sheetRadius, style: .continuous))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .shadow(color: .black.opacity(0.5), radius: 20, y: -8)
            .allowsHitTesting(false)
    }

    private var peekLayer: some View {
        layer(peekContent(), key: TrackingPeekHeightKey.self)
            .onPreferenceChange(TrackingPeekHeightKey.self) { height in
                let total = height + MRTMetrics.sheetGrabHandleHeight
                if total > 0, abs(total - measuredPeekHeight) > 0.5 { measuredPeekHeight = total }
            }
    }

    private var fullLayer: some View {
        layer(fullContent(), key: TrackingFullHeightKey.self)
            .onPreferenceChange(TrackingFullHeightKey.self) { height in
                let total = height + MRTMetrics.sheetGrabHandleHeight
                if total > 0, abs(total - measuredFullHeight) > 0.5 { measuredFullHeight = total }
            }
    }

    /// One layer: the decorative grab handle over the composition, top-aligned in
    /// the envelope, carrying its own height probe.
    ///
    /// **The probe measures the COMPOSITION, never the envelope.** Measuring a view
    /// that fills the proposed space feeds the engine back whatever it proposed and
    /// the detent ratchets upward every pass — MYR-352 paid a round for exactly
    /// that. Both compositions here are content-sized (no greedy `Spacer`), which
    /// is what makes them safe to ask.
    private func layer<Content: View, Key: PreferenceKey>(
        _ content: Content,
        key: Key.Type
    ) -> some View where Key.Value == CGFloat {
        VStack(spacing: 0) {
            RideGrabHandle() // decorative — the engine's pan owns the drag
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: key, value: proxy.size.height)
                    }
                )
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Measures the PEEK composition's natural height so the engine can adopt it as
/// the lower detent.
private struct TrackingPeekHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Measures the FULL card's natural height (the upper detent).
private struct TrackingFullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
