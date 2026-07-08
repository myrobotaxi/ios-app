import SwiftUI
import MapKit
import DesignSystem

// MARK: - SharedViewerScreen (MYR-191, design/app/screens.jsx
// SharedViewerScreen 1855-2242 idle path + ride-request.jsx
// ExpandingRequestSheet 1071-1261 idle path, Handoff §5.10 intro)
//
// The rider's live map: reuses MYR-167's MapKit stack (`VehicleMapView`) +
// simulated telemetry (`SimulatedVehicleTelemetrySource`) to show the one
// shared vehicle the rider is watching, under a resting "idle" sheet — a
// time-of-day greeting with a premium glow reveal, plus the search bar /
// quick-place "ready" affordances (visually present, not yet wired — see
// `RiderSheetPhase`). The request→booking→tracking→summary phases are
// MYR-171's scope; `viewerState.sheetPhase` is the seam that story extends.
struct SharedViewerScreen: View {
    @Bindable var viewerState: SharedViewerState
    @Binding var sharedTab: String
    var riderName: String = "Sam" // screens.jsx:1857 `riderName = 'Sam'`; M1 has no tweaks panel.

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true

    var body: some View {
        ZStack {
            VehicleMapView(
                vehicle: viewerState.vehicle,
                snapshot: viewerState.snapshot,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing,
                bottomContentInset: MRTMetrics.sharedIdleSheetHeight
            )
            .ignoresSafeArea()

            idleSheet
        }
        .background(Color.mrtBg)
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs)
        .onAppear { viewerState.startTelemetry() }
    }

    // MARK: Idle sheet (screens.jsx:2064-2207, ride-request.jsx:1165-1218)
    //
    // Fixed height, no drag handle — the jsx only shows a grab handle on the
    // interactive sheet phases ("not the static idle / tracking pages",
    // ride-request.jsx:1190); dragging up from idle to open Search is
    // MYR-171 scope.

    private var idleSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch viewerState.sheetPhase {
            case .idle:
                GreetingHero(riderName: riderName)
                    .padding(.bottom, 16)
                searchBar
                quickPlaces
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 98)
        .frame(height: MRTMetrics.sharedIdleSheetHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(idleSheetBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.sheetRadius, topTrailingRadius: MRTMetrics.sheetRadius, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: -8) // '0 -16px 40px rgba(0,0,0,0.5)' (ride-request.jsx:1182)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea(edges: .bottom)
    }

    /// `backgroundColor:'#0A0A0A'` + `radial-gradient(130% 62% at 50% -14%,
    /// rgba(201,168,76,0.14) 0%, rgba(10,10,10,0) 58%)` (ride-request.jsx:1176-1177).
    private var idleSheetBackground: some View {
        ZStack {
            Color.mrtBg
            EllipticalGradient(
                stops: [
                    .init(color: Color.mrtGold.opacity(0.14), location: 0),
                    .init(color: .clear, location: 0.58),
                ],
                center: UnitPoint(x: 0.5, y: -0.14),
                startRadiusFraction: 0,
                endRadiusFraction: 1.3
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: "Ready" affordances (screens.jsx:2174-2205) — visually present,
    // not wired: tapping either opens Search (MYR-171's `.search` phase),
    // which doesn't exist yet on `RiderSheetPhase`.

    private var searchBar: some View {
        Button {
            // MYR-171 sets `viewerState.sheetPhase = .search` here.
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Color.mrtGold)
                RotatingPlaceholder(items: ["Where to?", "A ride is \(SharedViewerScreen.watchedVehicleETAMinutes) min away"])
                    .font(.system(size: 16))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtTextSec)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            // rgba(255,255,255,0.025) (screens.jsx:2180) — a one-off alpha
            // distinct from `mrtRequestedRowTintStart`'s 0.05, so composed
            // inline rather than as a new named token.
            .background(Color.mrtText.opacity(0.025), in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
            .overlay(MRTTraceBorder(shape: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)))
            .shadow(color: .mrtSearchGlow, radius: 8) // `.mrt-search-glow` (components.jsx:676)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
        .padding(.bottom, 14)
        .accessibilityLabel("Where to?")
    }

    private var quickPlaces: some View {
        HStack(spacing: 8) {
            quickPlaceButton(label: "Home", icon: "house.fill")
            quickPlaceButton(label: "Work", icon: "briefcase.fill")
        }
    }

    private func quickPlaceButton(label: String, icon: String) -> some View {
        Button {
            // MYR-171 sets pickup + `viewerState.sheetPhase = .pinDrop` here
            // (screens.jsx:2195 `setPinReturn('review'); setPhase('pinDrop')`).
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.mrtGold)
                Text(label)
                    .font(.system(size: 14.5, weight: .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Color.mrtText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(Color.mrtRideChipFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    /// screens.jsx:15-19 `FLEET[0].etaMin` (Alex's shared Model Y) — the
    /// rotating placeholder's second string. Decorative-only in M1 (no
    /// request flow yet); MYR-171 replaces this with the real selected
    /// vehicle's live ETA.
    private static let watchedVehicleETAMinutes = 3
}

// MARK: - Greeting hero (screens.jsx:1972-1976,2085-2090; `mrt-greet-in`/
// `mrt-greet-glow`, Handoff §8)

/// Time-of-day greeting with a premium glow reveal: the whole line fades +
/// unblurs + settles its letter-spacing in over 0.85s
/// (`cubic-bezier(.22,1,.36,1)`, `mrt-greet-in`), while the rider's name
/// glows hot gold then settles over a separate 1.4s ease-out
/// (`mrt-greet-glow`, 0.12s delay). Reduce Motion → both render at their
/// final resting state immediately, no animation.
private struct GreetingHero: View {
    let riderName: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Both `mrt-greet-in` (opacity/offsetY/blur/tracking, 0.85s) and
    /// `mrt-greet-glow` (glowRadius/glowIntensity, 1.4s, 0.12s delay) driven
    /// from one animator — the two CSS animations run concurrently on the
    /// same element in the jsx, so their keyframe tracks just have different
    /// total durations here (the animator runs until the longest finishes).
    private struct RevealValue {
        var opacity = 0.0
        var offsetY = 8.0
        var blur = 8.0
        var tracking = 0.6
        var glowRadius = 0.0
        /// 0 = resting rgba(gold,0.45), 1 = hot rgba(240,210,122,0.9)
        /// (mrt-greet-glow's 40% keyframe stop).
        var glowIntensity = 0.0
    }

    /// cubic-bezier(.22,1,.36,1) — `mrt-greet-in`'s curve (components.jsx:747).
    private static let curve = UnitCurve.bezier(
        startControlPoint: UnitPoint(x: 0.22, y: 1),
        endControlPoint: UnitPoint(x: 0.36, y: 1)
    )

    private static let restingReveal = RevealValue(opacity: 1, offsetY: 0, blur: 0, tracking: -0.4, glowRadius: 13, glowIntensity: 0)

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case ..<12: "Good morning"
        case ..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        if reduceMotion {
            line(Self.restingReveal)
        } else {
            KeyframeAnimator(initialValue: RevealValue()) { value in
                line(value)
            } keyframes: { _ in
                KeyframeTrack(\.opacity) {
                    LinearKeyframe(0, duration: 0)
                    LinearKeyframe(1, duration: 0.4675, timingCurve: Self.curve)
                    LinearKeyframe(1, duration: 0.3825)
                }
                KeyframeTrack(\.offsetY) {
                    LinearKeyframe(8, duration: 0)
                    LinearKeyframe(0, duration: 0.85, timingCurve: Self.curve)
                }
                KeyframeTrack(\.blur) {
                    LinearKeyframe(8, duration: 0)
                    LinearKeyframe(0, duration: 0.4675, timingCurve: Self.curve)
                    LinearKeyframe(0, duration: 0.3825)
                }
                KeyframeTrack(\.tracking) {
                    LinearKeyframe(0.6, duration: 0)
                    LinearKeyframe(-0.4, duration: 0.85, timingCurve: Self.curve)
                }
                KeyframeTrack(\.glowRadius) {
                    LinearKeyframe(0, duration: 0.12) // mrt-greet-glow's start delay
                    LinearKeyframe(24, duration: 0.56, timingCurve: .easeOut)
                    LinearKeyframe(13, duration: 0.72, timingCurve: .easeOut)
                }
                KeyframeTrack(\.glowIntensity) {
                    LinearKeyframe(0, duration: 0.12)
                    LinearKeyframe(1, duration: 0.56, timingCurve: .easeOut)
                    LinearKeyframe(0, duration: 0.72, timingCurve: .easeOut)
                }
            }
        }
    }

    private func line(_ value: RevealValue) -> some View {
        HStack(spacing: 4) {
            Text("\(greeting),")
                .foregroundStyle(Color.mrtText)
            Text(riderName)
                .foregroundStyle(Color.mrtGold)
                .fontWeight(.semibold)
                .shadow(color: glowColor(value.glowIntensity), radius: value.glowRadius)
        }
        .font(.system(size: 21, weight: .medium))
        .tracking(value.tracking)
        .blur(radius: value.blur)
        .opacity(value.opacity)
        .offset(y: value.offsetY)
    }

    /// Blends resting rgba(gold,0.45) toward the hot `mrtGoldPulse` stop
    /// rgba(240,210,122,0.9) as intensity → 1.
    private func glowColor(_ intensity: Double) -> Color {
        intensity <= 0 ? Color.mrtGold.opacity(0.45) : Color.mrtGoldPulse.opacity(0.45 + (0.9 - 0.45) * intensity)
    }
}

// MARK: - RotatingText (screens.jsx:1838-1850 `RotatingText`)

/// Alternates between `items` on a timer with a soft slide-up + blur-clear
/// transition (`mrt-ph-rotate`). Reduce Motion → the transition becomes a
/// plain cross-fade; the text still rotates (this is a content change, not a
/// decorative loop).
private struct RotatingPlaceholder: View {
    let items: [String]
    var interval: TimeInterval = 2.8

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(items[index])
            .id(index)
            .transition(
                reduceMotion
                    ? AnyTransition.opacity
                    : AnyTransition.opacity.combined(with: .move(edge: .bottom))
            )
            .task {
                guard items.count > 1 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) {
                        index = (index + 1) % items.count
                    }
                }
            }
    }
}

#Preview {
    SharedViewerScreen(viewerState: SharedViewerState(), sharedTab: .constant("shared"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
