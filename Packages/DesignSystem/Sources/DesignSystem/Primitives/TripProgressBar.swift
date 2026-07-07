import SwiftUI

// MARK: - TripProgressBar — the signature element (components.jsx)
//
// 6pt `elevated` track, gold travelled fill, 15pt glowing gold position orb.
// Progress is clamped to 0.05…0.95 so the orb never sits inside the end caps.

public struct TripProgressBar: View {
    private let progress: Double
    private let origin: String?
    private let dest: String?
    private let compact: Bool

    /// jsx width/left transition — cubic-bezier(.4,0,.2,1) .8s.
    static let progressAnimation = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.8)

    public init(
        progress: Double = 0.42,
        origin: String? = nil,
        dest: String? = nil,
        compact: Bool = false
    ) {
        self.progress = progress
        self.origin = origin
        self.dest = dest
        self.compact = compact
    }

    static func clamped(_ progress: Double) -> Double {
        min(0.95, max(0.05, progress))
    }

    public var body: some View {
        let p = Self.clamped(progress)
        VStack(alignment: .leading, spacing: compact ? 0 : 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Track — a solid, rounded pill so it reads crisp, not brittle
                    Capsule().fill(Color.mrtElevated).frame(height: 6)
                    // Travelled portion — solid gold fill with rounded caps
                    Capsule()
                        .fill(Color.mrtGold)
                        .frame(width: geo.size.width * p, height: 6)
                    // Current position — glowing gold orb, matching the map markers
                    orb.position(x: geo.size.width * p, y: geo.size.height / 2)
                }
            }
            .frame(height: 14)
            .animation(Self.progressAnimation, value: progress)

            if !compact, origin != nil || dest != nil {
                HStack {
                    Text(origin ?? "").foregroundStyle(Color.mrtTextMuted)
                    Spacer()
                    Text(dest ?? "").foregroundStyle(Color.mrtTextSec)
                }
                .font(.system(size: 12))
                .tracking(-0.1)
            }
        }
    }

    /// 15pt gold orb, 2pt white ring, layered gold glows.
    private var orb: some View {
        Circle()
            .fill(Color.mrtGold)
            .frame(width: 15, height: 15)
            // border: 2px solid `text` — outside the 15pt disc (CSS content-box)
            .overlay(Circle().inset(by: -1).stroke(Color.mrtText, lineWidth: 2))
            // 0 0 0 1px rgba(0,0,0,0.4)
            .overlay(Circle().inset(by: -2.5).stroke(Color.black.opacity(0.4), lineWidth: 1))
            // 0 0 6px goldGlow6, 0 0 14px goldGlow3
            .shadow(color: .mrtGoldGlow, radius: 3)
            .shadow(color: .mrtGoldGlowSoft, radius: 7)
    }
}
