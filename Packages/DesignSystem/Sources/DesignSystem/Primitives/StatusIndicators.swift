import SwiftUI

// MARK: - Vehicle status (components.jsx STATUS map)

public enum MRTVehicleStatus: String, CaseIterable, Identifiable, Sendable {
    case driving, parked, charging, offline

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .driving: "Driving"
        case .parked: "Parked"
        case .charging: "Charging"
        case .offline: "Offline"
        }
    }

    public var color: Color {
        switch self {
        case .driving: .mrtDriving
        case .parked: .mrtParked
        case .charging: .mrtCharging
        case .offline: .mrtOffline
        }
    }
}

/// 6pt status dot + label, no background fill.
public struct StatusBadge: View {
    private let status: MRTVehicleStatus
    private let size: CGFloat

    public init(_ status: MRTVehicleStatus, size: CGFloat = 12) {
        self.status = status
        self.size = size
    }

    public var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
                // 0 0 6px {color}55
                .shadow(color: status.color.opacity(85.0 / 255.0), radius: 3)
            Text(status.label)
                .font(.system(size: size, weight: .medium))
                .tracking(0.2)
                .foregroundStyle(Color.mrtTextSec)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Pulsing live dot ("Driving now" banners, viewers online, …).
/// `mrt-pulse-ring`: scale 0.6→2.2, opacity 0.8→0, 2s ease-out loop.
/// Reduce Motion → static dot.
public struct PulseDot: View {
    private let color: Color
    private let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    public init(color: Color = .mrtDriving, size: CGFloat = 8) {
        self.color = color
        self.size = size
    }

    public var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color)
                    .scaleEffect(pulsing ? 2.2 : 0.6)
                    .opacity(pulsing ? 0 : 0.8)
            }
            Circle().fill(color)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}
