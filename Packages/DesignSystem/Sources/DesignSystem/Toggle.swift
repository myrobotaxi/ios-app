import SwiftUI

// MARK: - MRTToggle — gold-track toggle (components.jsx `Toggle`, 254-272;
// Handoff §5.8/§5.9 Notifications rows)
//
// Flat-only (product decision, 2026-07-06): the jsx's liquid-mode gradient +
// glow track (design.jsx `toggleTrack`, liquid branch) is out of scope; the
// flat branch is a plain fill — on → `T.gold`, off → `T.elevated`. Track
// 51×31, radius 16; a white 27×27 thumb slides between `left: 2` (off) and
// `left: 22` (on) with a `.22s cubic-bezier(.3,.7,.4,1)` transition and a
// `0 2px 4px rgba(0,0,0,0.3)` shadow.
//
// No `label`/`disabled` params — like the jsx, every call site wraps this in
// its own row layout with a separate label `Text`.
public struct MRTToggle: View {
    @Binding private var isOn: Bool

    public init(isOn: Binding<Bool>) {
        _isOn = isOn
    }

    public var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: MRTMetrics.toggleTrackRadius, style: .continuous)
                    .fill(isOn ? Color.mrtGold : Color.mrtElevated)
                Circle()
                    .fill(Color.white)
                    .frame(width: MRTMetrics.toggleThumbSize, height: MRTMetrics.toggleThumbSize)
                    .shadow(color: .mrtToggleThumbShadow, radius: 2, x: 0, y: 2)
                    .padding(.horizontal, MRTMetrics.toggleThumbInset)
            }
            .frame(width: MRTMetrics.toggleTrackWidth, height: MRTMetrics.toggleTrackHeight)
            // 44pt hit target around the 31pt-tall visual track.
            .contentShape(Rectangle().inset(by: -(MRTMetrics.minTapTarget - MRTMetrics.toggleTrackHeight) / 2))
        }
        .buttonStyle(.plain)
        .animation(.timingCurve(0.3, 0.7, 0.4, 1, duration: 0.22), value: isOn) // components.jsx:263 thumb transition
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
