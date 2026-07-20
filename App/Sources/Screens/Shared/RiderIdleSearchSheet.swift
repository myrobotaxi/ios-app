import SwiftUI
import DesignSystem

// MARK: - RiderIdleSearchSheet (MYR-236 round 4)
//
// Makes the rider's idle greeting card and the search sheet feel like ONE
// continuous draggable sheet, on the shared `PanSheet` UIKit engine (the same
// foundation the owner `MRTDetentSheet` now uses).
//
// The client's round-3 report: the idle↔search transition "doesn't even show
// dragging up and down — it just re-renders to the good-morning card when
// dragging down, or the search when dragging up, without any fluid smooth
// motion." Accurate — before this, idle→search was a tap-only phase swap and
// search→idle was a >36px drag-DOWN threshold on the handle (a discrete
// dismiss, no continuous follow). Now:
//
//   • From idle, dragging UP moves the greeting card surface 1:1 with the
//     finger; a velocity-projected release past the midpoint settles at the
//     search height and THEN commits `sheetPhase = .search`. Below it, springs
//     back to idle.
//   • From search, dragging DOWN (from the handle, or from the results scroll
//     when it is at its top — the engine's scroll handoff) moves the sheet 1:1;
//     release either settles back at search or collapses to idle, committing
//     `resetDraftToIdle()` (ride-request.jsx `closeToIdle`) at settle.
//   • The current phase's content RIDES the surface during the drag; the swap
//     happens at the settle commit exactly as the existing phase transition did
//     (never mid-drag — that "just re-renders" was the complaint).
//
// The search detent tracks the search content's NATURAL height (measured), so
// the MYR-200 no-dead-zone sizing and the MYR-216 post-selection collapse are
// preserved rather than pinned to a fixed 712. The idle detent is the fixed
// greeting-card height.
struct RiderIdleSearchSheet<Idle: View, Search: View>: View {
    @Bindable var viewerState: SharedViewerState
    /// The idle greeting card's fixed height (`sharedIdleSheetHeight`).
    let idleHeight: CGFloat
    @ViewBuilder var idleContent: () -> Idle
    @ViewBuilder var searchContent: () -> Search
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The search content's measured natural height — the search detent. Starts
    /// at the canonical 712 (`SHEET_HEIGHTS.search`) until the first measurement.
    @State private var measuredSearchHeight: CGFloat = MRTMetrics.rideRequestSearchSheetHeight

    private var isSearch: Bool { viewerState.sheetPhase == .search }

    /// Ascending detents: [idle card height, search sheet height].
    private var detents: [CGFloat] {
        let fallback = MRTMetrics.rideRequestSearchSheetHeight
        let search = measuredSearchHeight.isFinite && measuredSearchHeight > 0 ? measuredSearchHeight : fallback
        return [idleHeight, max(search, idleHeight + 1)]
    }

    /// idle ↔ 0, search ↔ 1. The engine commits the settled index through
    /// `onSettle` (below); this binding only mirrors the current phase so a
    /// tap-to-open (the greeting search bar sets `.search`) animates the surface
    /// up via the same spring instead of a hard cut.
    private var selection: Binding<Int> {
        Binding(get: { isSearch ? 1 : 0 }, set: { _ in })
    }

    var body: some View {
        PanSheet(
            detentHeights: detents,
            selection: selection,
            reduceMotion: reduceMotion,
            accessibilityIdentifier: "mrt.riderSheet",
            accessibilityLabel: "Ride request sheet",
            onSettle: commitSettle,
            // MYR-236 round 5 — the greeting card and the search content are
            // hosted SIMULTANEOUSLY as two crossfade layers; the engine drives
            // their alphas from the drag progress at the UIKit layer (greeting
            // 1→0, search 0→1), so the content transitions WITH the surface
            // instead of popping at the settle commit. The phase machine still
            // commits at settle (`commitSettle`); this is purely visual.
            crossfade: PanSheetCrossfade(
                low: { idleLayer },
                high: { searchLayer }
            )
        ) {
            // Base layer — an ALWAYS-opaque sheet wash spanning the full
            // envelope (incl. the overshoot band), so an upward rubber-band or a
            // mid-crossfade frame never leaks the map beneath the lifted sheet.
            // Non-interactive; the crossfade layers above carry all controls.
            envelopeWash
        }
        // Full-bleed geometry (CLAUDE.md): the sheet runs flush to the PHYSICAL
        // bottom edge — the engine's container must span the whole screen, not
        // the safe-area-inset region (mirrors `MRTDetentSheet`).
        .ignoresSafeArea(edges: .bottom)
    }

    /// The persistent sheet-wash base filling the surface envelope (rounded top
    /// to match both crossfade layers' own top corners). Never faded — it is
    /// what keeps the overshoot band and every mid-crossfade frame opaque.
    private var envelopeWash: some View {
        RideRequestSheetBackground()
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.sheetRadius, topTrailingRadius: MRTMetrics.sheetRadius, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    /// Crossfade layer visible at the idle detent (alpha 1→0 as the drag rises)
    /// — the greeting card, self-contained (its own wash/corners/hairline).
    private var idleLayer: some View {
        idleContent()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Crossfade layer visible at the search detent (alpha 0→1). Carries the
    /// height probe that feeds the search detent (preserving MYR-200 no-dead-
    /// zone / MYR-216 collapse), measured from the search content's own natural
    /// height regardless of the current phase.
    private var searchLayer: some View {
        searchContent()
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: RiderSheetHeightKey.self, value: proxy.size.height)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onPreferenceChange(RiderSheetHeightKey.self) { height in
                if height > 0, abs(height - measuredSearchHeight) > 0.5 {
                    measuredSearchHeight = height
                }
            }
    }

    /// Commit the settled detent to the phase machine — AFTER settle, never
    /// mid-drag (the engine guarantees this).
    private func commitSettle(_ index: Int) {
        if index == 1 {
            // Settled at search — open Search from idle (a re-settle at search
            // no-ops). Focus is left to the field tap, which happens post-settle.
            if viewerState.sheetPhase == .idle { viewerState.sheetPhase = .search }
        } else {
            // Settled at idle — collapse Search to the greeting card with a full
            // draft reset (ride-request.jsx `closeToIdle`), the same commit the
            // old >36px drag-down-dismiss made, now velocity-projected by the
            // engine.
            if viewerState.sheetPhase == .search { viewerState.resetDraftToIdle() }
        }
    }
}

/// Measures the hosted phase content's natural height so the engine can adopt
/// it as the search detent (preserving MYR-200 no-dead-zone / MYR-216 collapse).
private struct RiderSheetHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
