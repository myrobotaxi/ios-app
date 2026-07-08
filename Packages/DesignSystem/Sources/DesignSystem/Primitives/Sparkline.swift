import SwiftUI

// MARK: - MRTSparkline (screens.jsx `DSSparkline`, screens.jsx:1168-1183)
//
// A gold-filled area sparkline with a glowing stroke and a marker dot at the
// peak value — Drive Summary's speed trace (MYR-169, Handoff §5.6 "speed
// sparkline"). `screens.jsx`'s `DriveSummaryScreen` computes a `speeds` array
// and this exact `DSSparkline` component but doesn't call it in the render
// (dead code in the current source) — ported anyway per the Handoff spec,
// which explicitly lists the speed sparkline as a `DriveSummaryScreen`
// deliverable. Geometry (normalization, path, peak marker) is a 1:1 port of
// `DSSparkline`.
public struct MRTSparkline: View {
    private let values: [Double]

    public init(values: [Double]) {
        self.values = values
    }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let points = Self.normalizedPoints(values: values, width: width, height: height)
            let peakIndex = Self.peakIndex(values: values)

            ZStack {
                if let fillPath = Self.fillPath(points: points, width: width, height: height) {
                    fillPath
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color.mrtGold.opacity(0.32), location: 0),
                                    .init(color: Color.mrtGold.opacity(0), location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
                Self.linePath(points: points)
                    .stroke(Color.mrtGold, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: .mrtGoldGlow, radius: 2)
                if let peak = points[safe: peakIndex] {
                    Circle()
                        .fill(Color.mrtGold)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color.mrtBg, lineWidth: 1.5))
                        .position(peak)
                }
            }
        }
        .accessibilityHidden(true)
    }

    // MARK: Geometry (screens.jsx:1169-1173)

    /// `norm(v) = height - ((v - min) / (max - min || 1)) * (height - 14) - 8`.
    static func normalizedPoints(values: [Double], width: CGFloat, height: CGFloat) -> [CGPoint] {
        guard values.count > 1, let minV = values.min(), let maxV = values.max() else {
            return values.map { _ in CGPoint(x: 0, y: height) }
        }
        let range = maxV - minV
        return values.enumerated().map { index, value in
            let x = (CGFloat(index) / CGFloat(values.count - 1)) * width
            let normalized = range == 0 ? 0 : (value - minV) / range
            let y = height - CGFloat(normalized) * (height - 14) - 8
            return CGPoint(x: x, y: y)
        }
    }

    static func peakIndex(values: [Double]) -> Int {
        var peak = 0
        for (index, value) in values.enumerated() where value > values[peak] { peak = index }
        return peak
    }

    static func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }

    /// `line + 'L width height L 0 height Z'` — closes the line down to the
    /// baseline to form the fill area.
    static func fillPath(points: [CGPoint], width: CGFloat, height: CGFloat) -> Path? {
        guard !points.isEmpty else { return nil }
        var path = linePath(points: points)
        path.addLine(to: CGPoint(x: width, y: height))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.closeSubpath()
        return path
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
