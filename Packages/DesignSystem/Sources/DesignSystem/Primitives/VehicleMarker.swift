import SwiftUI

// MARK: - VehicleMarker (components.jsx) — gold core, heading arrow, pulse ring
//
// The jsx anchors everything on a 0×0 point; here the marker is a 44×44 view
// whose *center* is the vehicle position (annotation views should center it
// on the coordinate). The label chip overflows the frame to the right, like
// the prototype.

/// jsx heading arrow: `M 0 -16 L 5 -8 L 0 -10 L -5 -8 Z` in a −22…22 viewBox.
struct HeadingArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = rect.width / 44
        func map(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + x * scale, y: rect.midY + y * scale)
        }
        var path = Path()
        path.move(to: map(0, -16))
        path.addLine(to: map(5, -8))
        path.addLine(to: map(0, -10))
        path.addLine(to: map(-5, -8))
        path.closeSubpath()
        return path
    }
}

public struct VehicleMarker: View {
    private let heading: Double
    private let size: CGFloat
    private let label: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(heading: Double = 45, size: CGFloat = 22, label: String? = nil) {
        self.heading = heading
        self.size = size
        self.label = label
    }

    public var body: some View {
        ZStack {
            // Pulse ring — mrt-pulse-ring 2s ease-out infinite.
            // Reduce Motion → the jsx's static resting state (opacity 0.25).
            if reduceMotion {
                Circle()
                    .fill(Color.mrtGold)
                    .opacity(0.25)
                    .frame(width: size * 2, height: size * 2)
            } else {
                Circle()
                    .fill(Color.mrtGold)
                    .frame(width: size * 2, height: size * 2)
                    .scaleEffect(pulsing ? 2.2 : 0.6)
                    .opacity(pulsing ? 0 : 0.8)
            }
            // Heading arrow — 44×44 canvas rotated to `heading` degrees.
            HeadingArrowShape()
                .fill(Color.mrtGold)
                .opacity(0.9)
                .frame(width: 44, height: 44)
                .rotationEffect(.degrees(heading))
            // Core dot
            Circle()
                .fill(Color.mrtGold)
                .frame(width: size, height: size)
                .overlay(Circle().inset(by: -1).stroke(Color.mrtText, lineWidth: 2))
                .overlay(Circle().inset(by: -2.5).stroke(Color.black.opacity(0.4), lineWidth: 1))
                // 0 0 14px gold, 0 0 28px goldGlow6
                .shadow(color: .mrtGold, radius: 7)
                .shadow(color: .mrtGoldGlow, radius: 14)
        }
        .frame(width: 44, height: 44)
        .overlay {
            if let label {
                labelChip(label)
                    // Pin the chip's top-leading to the marker center…
                    .frame(width: 0, height: 0, alignment: .topLeading)
                    // …then place it like the jsx: left = size, top = -size*0.6.
                    .offset(x: size, y: -size * 0.6)
            }
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }

    private func labelChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.3)
            .foregroundStyle(Color.mrtGold)
            .lineLimit(1)
            .fixedSize()
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            // rgba(10,10,10,0.85); the jsx backdrop blur is dropped (flat-only)
            .background(Color.mrtBg.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
    }
}
