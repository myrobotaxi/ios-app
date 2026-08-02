import SwiftUI
import DesignSystem

// MARK: - MYR-419 — the map's TOP CHROME STACK, and the band the sheet leaves for it
//
// THE CLIENT'S REPORT (r18, build 202608020103): with a live dispatch and the
// owner sheet pulled up, the status pill and the gold "Dropped off" CTA sit ON
// TOP of the sheet's own hero row.
//
// **THE OVERLAY WAS NEVER WRONG; THE SHEET'S STOP WAS MEASURED FOR DIFFERENT
// CHROME.** `MRTMetrics.sheetTallTopClearance` (140) is the sheet grammar's own
// number and its stated justification is that it "clears the `MapHeader` vehicle
// switcher whole (top 60 + 40pt chip ⇒ its bottom edge at 100)". That is true of
// a screen whose top chrome IS the chip. While a ride is dispatched this screen
// stacks two more elements under it — a 44pt status pill and, in the two states
// that have one, a 38pt CTA — so the real chrome runs to ~204pt from the physical
// edge and a sheet stopping at 140 goes straight through it. Measured on iPhone
// 17 Pro, `ownerDispatchedEnroute` at tall: the CTA's ink lands over the hero's
// "Driving · Cybercab / 185 mi" row.
//
// **WHY THE SHEET RESERVES THE ROOM RATHER THAN THE CHROME MOVING** (candidate (a),
// the MYR-397 `SheetEdgeAnchor` follower, was tried on paper first and is
// GEOMETRICALLY VACUOUS HERE). An edge follower moves chrome UP as the sheet
// rises, and this chrome has nowhere up to go: its designed position already
// begins 12pt under the `MapHeader` chip, so the travel cap MYR-338's camera cap
// would suggest — "never above the chip" — is the position it is already in. The
// rider's recenter/expand controls follow the edge because they live BELOW the
// map, above a sheet that rests tall; this card is a top banner over a sheet that
// rests at peek. Making it follow would mean re-homing it to hover above the
// sheet edge at every detent, i.e. a gold CTA floating mid-map at peek, next to
// the recenter button — a redesign of a frame nobody has complained about, to fix
// a collision at one stop.
//
// **AND WHY NOT FADE IT PAST A THRESHOLD** (candidate (c)). It is this screen's
// existing grammar for map chrome — `sheetCoversMap` already stands the recenter
// button and the floating nav down at half — but those are map CONTROLS. The
// dispatch pill is the owner's only on-screen evidence that a ride is live and
// the CTA is the only control that ends it, and taking both away at a detent is
// MYR-396's complaint (*"the owner loses the UI of the current ride in progress"*)
// re-entered by a smaller door.
//
// So the rule is MYR-345's, applied at the sheet's TOP edge instead of its peek
// band: **a live-only element brings exactly its own room.** The clearance is
// derived from the card that is actually on screen — which is why the card is
// MEASURED rather than assumed: `arrived` and `completed` render the pill with no
// CTA, and reserving a CTA's 38pt for a state that has none is the flat-24
// over-reserve MYR-345 was about, pointed the other way.
enum OwnerMapTopChrome {
    /// The `MapHeader` chip's bottom edge from the PHYSICAL top (screens.jsx:302
    /// `top: 60` + :306 `height: 40`).
    static var mapHeaderBottom: CGFloat { MRTMetrics.mapHeaderTop + MRTMetrics.mapChipHeight }

    /// The dispatch card's own top edge — the switcher chip's bottom plus the
    /// gap MYR-265 set it at. `HomeScreen` places the overlay with this, so the
    /// placement and the reserve derived from it are ONE fact: a tune that moved
    /// the card down without moving the reserve would re-open this defect.
    static let dispatchCardTop: CGFloat = 112

    /// Clear space between the dispatch card's last ink and the sheet's top edge
    /// at its tallest stop.
    ///
    /// **DERIVED, NOT CHOSEN**: it is exactly the band the grammar's own stop
    /// leaves below the `MapHeader` chip (140 − 100 = 40). Two things fall out of
    /// making it the same number rather than a comfortable-looking one.
    ///
    /// 1. The reserved stop reads like the unreserved stop — the sheet sits the
    ///    same distance under the chrome above it either way.
    /// 2. **IT ABSORBS THE RUBBER BAND, WHICH A GUTTER-SIZED GAP WOULD NOT.** A
    ///    finger can pull the sheet ABOVE its tallest detent; `SheetPhysics
    ///    .rubberBand`'s resistance saturates at its `dimension` (30), so the
    ///    highest edge ever reachable is the stop less 30. A 24pt page gutter
    ///    would leave 6pt of the gold CTA under a maximal pull — a real overlap
    ///    at a real height, invisible to any test that samples a SETTLED frame.
    ///    At 40 the whole band is inside the clear space, and the overshoot
    ///    behaves exactly as it always has above the chip.
    static let dispatchCardSheetGap: CGFloat = MRTMetrics.sheetTallTopClearance - mapHeaderBottom

    /// The band above the owner sheet that no detent may rise into.
    ///
    /// `nil` / a non-positive height means no dispatch card is on screen, and the
    /// answer is the grammar's own ``MRTMetrics/sheetTallTopClearance`` unchanged
    /// — which is what keeps every owner capture without a live ride
    /// byte-identical. Never smaller than that number: a dispatch card may raise
    /// the sheet's stop and may not lower it.
    static func sheetTopClearance(dispatchCardHeight: CGFloat?) -> CGFloat {
        guard let height = dispatchCardHeight, height.isFinite, height > 0 else {
            return MRTMetrics.sheetTallTopClearance
        }
        return max(MRTMetrics.sheetTallTopClearance, dispatchCardTop + height + dispatchCardSheetGap)
    }
}

/// Reports ``OwnerDispatchCard``'s natural height so the sheet can reserve
/// exactly that much room above itself.
///
/// **Measuring THIS view is safe and measuring its container would not be**
/// (MYR-352's trap, which cost that issue a round): the card is content-sized —
/// a capsule over an optional 38pt button, no greedy `Spacer` — and its height is
/// a pure function of its own copy and the screen width, with no edge back to the
/// sheet whose detents it feeds. A measurement that could be influenced by the
/// value it produces is a layout loop, and this one cannot be.
struct OwnerDispatchCardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
