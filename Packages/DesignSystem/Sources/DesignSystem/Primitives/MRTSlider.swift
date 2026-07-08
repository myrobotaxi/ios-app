import SwiftUI

// MARK: - MRTSlider — gold range slider (MYR-168)
//
// Port of the prototype's `Slider` (design/app/vehicle-controls.jsx:8-21) and
// its chrome (design/app/components.jsx MRT_STYLES:768-770 `input.mrt-range`):
// a gold-filled track up to a white 22pt thumb, with the unfilled remainder
// in `T.elevated`. Used by the media scrubber and volume control
// (vehicle-controls.jsx:358,379) — both pass `height: 4`, overriding this
// view's 6pt default (the jsx `Slider`'s own default).
//
// Drag anywhere on the track to jump the thumb there and keep dragging,
// matching a native `<input type="range">`'s click-to-seek behavior.
public struct MRTSlider: View {
    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let tint: Color
    private let trackHeight: CGFloat

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...100,
        tint: Color = .mrtGold,
        trackHeight: CGFloat = 6
    ) {
        _value = value
        self.range = range
        self.tint = tint
        self.trackHeight = trackHeight
    }

    private var percent: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return ((value - range.lowerBound) / span).clamped(to: 0...1)
    }

    private var controlHeight: CGFloat { max(MRTMetrics.sliderThumbSize, trackHeight) }

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumbX = percent * width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.mrtElevated)
                    .frame(height: trackHeight)
                Capsule()
                    .fill(tint)
                    .frame(width: max(trackHeight, thumbX), height: trackHeight)
                Circle()
                    .fill(Color.mrtText)
                    .frame(width: MRTMetrics.sliderThumbSize, height: MRTMetrics.sliderThumbSize)
                    .shadow(color: .mrtSliderThumbShadow, radius: 5, y: 1)
                    .offset(x: thumbX - MRTMetrics.sliderThumbSize / 2)
            }
            .frame(height: geo.size.height)
            // 44pt minimum hit target around a visually thin track — expand
            // the tappable shape, not the layout (mirrors MRTButtonChrome's
            // small-size technique, Buttons.swift:159).
            .contentShape(Rectangle().inset(by: min(0, (controlHeight - MRTMetrics.minTapTarget) / 2)))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard width > 0 else { return }
                        let clampedX = min(max(0, drag.location.x), width)
                        value = range.lowerBound + (clampedX / width) * (range.upperBound - range.lowerBound)
                    }
            )
        }
        .frame(height: controlHeight)
        .accessibilityRepresentation {
            Slider(value: $value, in: range)
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
