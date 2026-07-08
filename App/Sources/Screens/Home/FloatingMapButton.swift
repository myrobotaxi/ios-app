import SwiftUI
import DesignSystem

// MARK: - FloatingMapButton (MYR-167 deliverable 5,
// design/app/screens.jsx:353-367)
//
// Recenters the map on the vehicle. The jsx's own `onClick={() => {}}` is a
// stub (never wired to real map state, since the prototype has no real
// camera) — this port makes it functional: `VehicleMapView` flips
// `isFollowing` false on a user pan/pinch, which is what makes this button
// appear; tapping it sets `isFollowing` back to true and `VehicleMapView`
// animates the camera back onto the vehicle.
struct FloatingMapButton: View {
    let bottom: CGFloat
    let hidden: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.mrtGold)
                .frame(width: 44, height: 44)
                .background(Color.mrtFloatButtonFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                // 0 4px 16px rgba(0,0,0,0.4) (design.jsx:98 flat floatBtn)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        .opacity(hidden ? 0 : 1)
        .scaleEffect(hidden ? 0.9 : 1)
        .allowsHitTesting(!hidden)
        .animation(.easeInOut(duration: 0.22), value: hidden) // screens.jsx:363 `.22s ease`
        .padding(.bottom, bottom)
        .padding(.trailing, 16) // screens.jsx:353 `right = 16`
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .accessibilityLabel("Recenter map on vehicle")
    }
}
