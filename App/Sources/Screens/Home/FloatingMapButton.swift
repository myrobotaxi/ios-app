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
//
// MYR-327 generalizes the glyph + label (defaulted to the recenter-on-vehicle
// pair above), so the expanded route viewer's "fit the whole route" control is
// the SAME button rather than a look-alike fork. Every pre-existing call site
// omits both parameters and is byte-identical.
struct FloatingMapButton: View {
    let bottom: CGFloat
    let hidden: Bool
    var systemImage: String = "location.fill"
    var accessibilityLabel: String = "Recenter map on vehicle"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.mrtGold)
                .frame(width: 44, height: 44)
                .background(Color.mrtFloatButtonFill, in: Circle())
                .overlay(Circle().strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline))
                // 0 4px 16px rgba(0,0,0,0.4) (design.jsx:98 flat floatBtn)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
        // MYR-327: the label belongs to the BUTTON, not to the full-screen
        // positioning container below it. Attached to the container (where it
        // used to sit) the accessibility element's frame was the whole screen —
        // so assistive tech announced the map itself as "Recenter map on
        // vehicle", and an automated activation landed at screen centre instead
        // of on the control. Pixels are unchanged; only the a11y frame is.
        .accessibilityLabel(accessibilityLabel)
        .opacity(hidden ? 0 : 1)
        .scaleEffect(hidden ? 0.9 : 1)
        .allowsHitTesting(!hidden)
        .animation(.easeInOut(duration: 0.22), value: hidden) // screens.jsx:363 `.22s ease`
        .padding(.bottom, bottom)
        .padding(.trailing, 16) // screens.jsx:353 `right = 16`
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}
