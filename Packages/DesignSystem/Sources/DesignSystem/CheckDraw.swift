import SwiftUI

// MARK: - The design's DRAWN checkmark (MYR-366)
//
// `mrtCheckDraw` (onboarding.jsx:225,337) is the design kit's one check-draw
// motion: an SVG path with `stroke-dasharray: 24; stroke-dashoffset: 24`
// animated to 0, i.e. a stroke that draws itself from its own start point. In
// SwiftUI that is `Shape.trim(from: 0, to: progress)` over this path.
//
// It lived as a `private struct CheckDrawShape` inside `AddTeslaFlow` because it
// had exactly one consumer (the "Tesla account linked" beat). MYR-366's
// offboarding stepper is the second, and a second hand-transcribed copy of a
// path from a jsx file is a second place for it to be transcribed wrongly — so
// it is promoted here, unchanged, and both consumers read it. The geometry is
// identical: the same three points, normalised in the same 24-unit box.
public struct MRTCheckDrawShape: Shape {
    public init() {}

    /// jsx check path `M5 12.5l4.5 4.5L19 6.5` in a 24×24 viewBox, mapped onto
    /// whatever rect it is handed.
    public func path(in rect: CGRect) -> Path {
        var path = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x / 24 * rect.width, y: rect.minY + y / 24 * rect.height)
        }
        path.move(to: point(5, 12.5))
        path.addLine(to: point(9.5, 17))
        path.addLine(to: point(19, 6.5))
        return path
    }

    /// The design's own stroke weight for this path, expressed in the 24-unit
    /// viewBox (`strokeWidth="2.6"`, onboarding.jsx:336). Callers scale it to the
    /// size they draw at — `MRTCheckDrawShape.lineWidth(at: 46)` is the linked
    /// badge's, and the stepper's is the same ratio at its own diameter.
    public static let strokeWidthInViewBox: CGFloat = 2.6

    /// The stroke width to draw this path with at `size` points.
    public static func lineWidth(at size: CGFloat) -> CGFloat {
        strokeWidthInViewBox * size / 24
    }
}
