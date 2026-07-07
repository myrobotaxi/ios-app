import SwiftUI

// MARK: - Layout metrics
//
// Ported from the design project (Handoff §1, §7). Radii that differ between
// the Flat and Liquid Glass looks are resolved through `MRTSurfaceLook` — use
// `look.cardRadius` / `look.sheetRadius` instead of the raw constants when a
// look is in scope.

public enum MRTMetrics {
    /// Horizontal page padding.
    public static let pageGutter: CGFloat = 24
    /// Vertical gap between stacked cards.
    public static let cardGap: CGFloat = 12
    /// Card corner radius in the Liquid Glass look (default).
    public static let cardRadius: CGFloat = 16
    /// Card corner radius in the Flat look.
    public static let cardRadiusFlat: CGFloat = 14
    /// Inputs and buttons.
    public static let controlRadius: CGFloat = 12
    /// Bottom sheet top corners in the Flat look (default).
    public static let sheetRadius: CGFloat = 24
    /// Bottom sheet top corners in the Liquid Glass look.
    public static let sheetRadiusLiquid: CGFloat = 30
    /// Minimum hit target for any interactive element.
    public static let minTapTarget: CGFloat = 44
    /// Hairline border width used by the Flat look.
    public static let hairline: CGFloat = 0.5

    // MARK: Overlays (Handoff §7)

    /// Confirm-dialog card corner radius.
    public static let dialogRadius: CGFloat = 22
    /// Confirm-dialog card max width.
    public static let dialogMaxWidth: CGFloat = 300
    /// Confirm-dialog tinted icon-circle diameter.
    public static let dialogIconSize: CGFloat = 46
    /// Config bottom-sheet top-corner radius (§7 — 26, distinct from the
    /// home detent sheet's look-resolved 24/30).
    public static let configSheetRadius: CGFloat = 26
    /// Success-toast default bottom offset — clears the floating tab bar.
    public static let toastBottomOffset: CGFloat = 116
    /// Home detent-sheet peek height (components.jsx `BottomSheet` peekH).
    public static let sheetPeekHeight: CGFloat = 260
}
