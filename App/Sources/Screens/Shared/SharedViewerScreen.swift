import SwiftUI
import MapKit
import CoreLocation
import DesignSystem

// MARK: - SharedViewerScreen (MYR-191, design/app/screens.jsx
// SharedViewerScreen 1855-2242 idle path + ride-request.jsx
// ExpandingRequestSheet 1071-1261, Handoff §5.10 intro; extended MYR-171)
//
// The rider's live map: reuses MYR-167's MapKit stack (`VehicleMapView`) +
// simulated telemetry (`SimulatedVehicleTelemetrySource`) to show the one
// shared vehicle the rider is watching, under an expanding request sheet
// that switches content per `viewerState.sheetPhase` (`RiderSheetPhase`).
// MYR-171 fills in every phase past `.idle`: Search/PinDrop/Review/Booking/
// Tracking/Summary each live in their own file (see the phase content
// structs below), and this file is the seam that (1) picks which phase
// content + background map to render, (2) reacts to `rideRequestService
// .activeRequest`'s status/progress changing "out from under" the rider
// (owner accept/decline, the tracking progress ticker) per ride-request.jsx:
// 1098-1117, and (3) shows/hides the floating bottom nav per phase (every
// "task" sheet past idle/tracking covers it, ride-request.jsx z-index
// comment at 1166).
struct SharedViewerScreen: View {
    @Bindable var viewerState: SharedViewerState
    @Binding var sharedTab: String
    var rideRequestService: SimulatedRideRequestService
    var historyStore: RideHistoryStore
    var riderName: String = "Sam" // screens.jsx:1857 `riderName = 'Sam'`; M1 has no tweaks panel.

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backgroundMap
                    .ignoresSafeArea()

                sheetContent(totalHeight: geo.size.height)
                    .animation(
                        reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42), // ride-request.jsx:1185
                        value: viewerState.sheetPhase
                    )

                if isPinDrop {
                    RidePinDropMapOverlay(label: RideRequestPinDropContent.pinAddress)
                        .position(x: geo.size.width / 2, y: geo.size.height * 0.36)
                }
            }
        }
        .background(Color.mrtBg)
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs, hidden: hideBottomNav)
        .onAppear { viewerState.startTelemetry() }
        .onChange(of: rideRequestService.activeRequest?.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        .onChange(of: rideRequestService.activeRequest?.trackProgress) { _, progress in
            handleProgressChange(progress)
        }
    }

    // MARK: Phase content (MYR-171)

    @ViewBuilder
    private func sheetContent(totalHeight: CGFloat) -> some View {
        switch viewerState.sheetPhase {
        case .idle:
            idleSheet
        case .search:
            RideRequestSearchContent(viewerState: viewerState)
        case .pinDrop(let returnTo):
            RideRequestPinDropContent(viewerState: viewerState, returnTo: returnTo, totalHeight: totalHeight)
        case .review:
            RideRequestReviewContent(viewerState: viewerState, rideRequestService: rideRequestService, totalHeight: totalHeight)
        case .booking:
            RideRequestBookingContent(viewerState: viewerState, rideRequestService: rideRequestService, totalHeight: totalHeight)
        case .outcome(let accepted):
            RideRequestOutcomeContent(viewerState: viewerState, rideRequestService: rideRequestService, accepted: accepted)
        case .tracking:
            RideRequestTrackingContent(viewerState: viewerState, rideRequestService: rideRequestService, totalHeight: totalHeight)
        case .summary:
            RideRequestSummaryContent(viewerState: viewerState, rideRequestService: rideRequestService, historyStore: historyStore, riderName: riderName)
        }
    }

    private var isPinDrop: Bool {
        if case .pinDrop = viewerState.sheetPhase { return true }
        return false
    }

    /// Every "task" sheet past idle/tracking covers the floating tab bar
    /// entirely (ride-request.jsx:1166's z-index split: idle/tracking sit
    /// under other chrome, every other phase sits above it).
    private var hideBottomNav: Bool {
        switch viewerState.sheetPhase {
        case .idle, .tracking: false
        default: true
        }
    }

    // MARK: Background map (MYR-171)
    //
    // `.idle`/`.search`/`.pinDrop` keep showing the rider's live map
    // (`VehicleMapView`, MYR-167) — the same vehicle they're watching stays
    // visible while they search. Once a trip exists (`.review` onward), the
    // background switches to a route-fitted map between the actual pickup/
    // destination pair (`RideRequestRouteMap`) — `VehicleMapView` has no
    // content-injection seam and is scoped to a different vehicle/telemetry
    // pairing (see that file's own header comment).

    @ViewBuilder
    private var backgroundMap: some View {
        switch viewerState.sheetPhase {
        case .idle, .search, .pinDrop:
            VehicleMapView(
                vehicle: viewerState.vehicle,
                snapshot: viewerState.snapshot,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing,
                showRoute: false, // MYR-197: no route/trip line on the rider's idle map before a ride is booked — see VehicleMapView.showRoute's header comment
                bottomContentInset: mapBottomInset
            )
        case .review, .booking, .outcome:
            RideRequestRouteMap(route: requestRoute)
        case .tracking:
            RideRequestRouteMap(route: requestRoute, progress: rideRequestService.activeRequest?.trackProgress ?? 0, showVehicle: true)
        case .summary:
            RideRequestRouteMap(route: requestRoute)
        }
    }

    private var mapBottomInset: CGFloat {
        switch viewerState.sheetPhase {
        case .search: MRTMetrics.rideRequestSearchSheetHeight
        case .pinDrop: MRTMetrics.rideRequestPinDropMapInset
        default: MRTMetrics.sharedIdleSheetHeight
        }
    }

    /// Pickup → destination pair for the route-fitted phases — from the
    /// submitted `activeRequest` once it exists, else the still-in-progress
    /// draft (Review is reached before `submit(_:)` is ever called).
    private var requestRoute: [CLLocationCoordinate2D] {
        let pickup = rideRequestService.activeRequest?.input.pickup.coordinate ?? viewerState.draftPickup?.coordinate
        let destination = rideRequestService.activeRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
        guard let pickup, let destination else {
            return [DriveFixtures.financialDistrict, DriveFixtures.embarcaderoCenter]
        }
        return [pickup, destination]
    }

    // MARK: Reactive sync (ride-request.jsx:1098-1117, extended MYR-197)
    //
    // `RideRequestService`'s `activeRequest` can change out from under the
    // rider — the owner accepting/declining, or (M1's solo-rider fallback)
    // `SimulatedRideRequestService`'s own auto-accept timer. This is where
    // the rider's `sheetPhase` reacts, not inside the service itself (see
    // `RideRequestService`'s header comment: it only ever exposes the
    // snapshot).

    private func handleStatusChange(_ status: RideRequestStatus?) {
        guard let status, let request = rideRequestService.activeRequest else { return }
        let onTaskSheet = viewerState.sheetPhase == .booking || viewerState.sheetPhase == .idle
        switch status {
        case .accepted:
            // Scheduled acceptances are reservations for later, not a live
            // trip to narrate right now — `SimulatedRideRequestService
            // .accept()` never seeds `trackProgress` for these, and
            // ride-request.jsx's own scheduled path never shows
            // `OutcomeContent`/`TrackingContent` either (`ReviewContent
            // .onConfirm` calls `onSchedule()` and returns straight to idle,
            // ported at `RideRequestReviewContent.confirm()`). Only a "now"
            // acceptance gets the "on the way" outcome card.
            if request.input.schedule == nil, onTaskSheet {
                viewerState.sheetPhase = .outcome(accepted: true)
            }
        case .declined:
            if onTaskSheet {
                viewerState.sheetPhase = .outcome(accepted: false)
            }
        case .pending:
            break
        }
    }

    private func handleProgressChange(_ progress: Double?) {
        guard let progress, progress >= 0.999, viewerState.sheetPhase == .tracking else { return }
        viewerState.sheetPhase = .summary
    }

    // MARK: Idle sheet (screens.jsx:2064-2207, ride-request.jsx:1165-1218)
    //
    // Fixed height, no drag handle — the jsx only shows a grab handle on the
    // interactive sheet phases ("not the static idle / tracking pages",
    // ride-request.jsx:1190); dragging up from idle to open Search is out of
    // M1's scope (tap-to-open only). While a request is pending, the
    // greeting/search/quick-places give way to a status pill
    // (ride-request.jsx's minimized-map "booked" state,
    // `.shots/prototype/07_idle_pending_pill.png`).

    private var idleSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let active = rideRequestService.activeRequest, active.status == .pending {
                pendingPill(active)
            } else {
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

    // MARK: Pending pill (ride-request.jsx's minimized "booked" state)

    private func pendingPill(_ request: RideRequestRecord) -> some View {
        Button {
            viewerState.sheetPhase = .booking
        } label: {
            HStack(spacing: 12) {
                Circle().fill(Color.mrtGold).frame(width: 9, height: 9).shadow(color: .mrtGoldGlow, radius: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request sent")
                        .font(.system(size: 15, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.mrtText)
                    Text("Waiting for \(request.input.fleetMember.owner) \u{00B7} \(request.input.destination.label)")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.mrtTextSec)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Color.mrtTextMuted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.mrtGoldTileFaint, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x40) / 255.0), lineWidth: MRTMetrics.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: MRTMetrics.minTapTarget)
    }

    // MARK: "Ready" affordances (screens.jsx:2174-2205) — MYR-171 wires both.

    private var searchBar: some View {
        Button {
            viewerState.sheetPhase = .search
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
            quickPlaceButton(label: "Home", icon: "house.fill", place: RideRequestFixtures.savedPlaces[0])
            quickPlaceButton(label: "Work", icon: "briefcase.fill", place: RideRequestFixtures.savedPlaces[1])
        }
    }

    /// Destination-first shortcut (screens.jsx:2195 `setPinReturn('review');
    /// setPhase('pinDrop')`) — surprising at first read (why does tapping
    /// "Home" open the *pickup* pin drop?) but intentional: Home/Work are
    /// quick *destinations*, and since the rider hasn't set a pickup yet,
    /// the flow routes through PinDrop to capture one before landing on
    /// Review, exactly like picking Home/Work from Search's destination list
    /// with no pickup set (`RideRequestSearchContent.selectDestination`).
    private func quickPlaceButton(label: String, icon: String, place: RidePlace) -> some View {
        Button {
            viewerState.draftDestination = place
            viewerState.pinReturn = .review
            viewerState.sheetPhase = .pinDrop(returnTo: .review)
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
    /// rotating placeholder's second string.
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
    /// One-shot reveal trigger. A trigger-less `KeyframeAnimator` repeats
    /// forever — the greeting flashed in a loop and its subtree churn also
    /// swallowed sheet taps. The jsx runs `mrt-greet-in` once (fill `both`),
    /// so: animate once on appear, rest at the final keyframe values.
    @State private var revealed = false

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
            KeyframeAnimator(initialValue: RevealValue(), trigger: revealed) { value in
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
            .onAppear { revealed = true }
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
    SharedViewerScreen(
        viewerState: SharedViewerState(),
        sharedTab: .constant("shared"),
        rideRequestService: SimulatedRideRequestService(),
        historyStore: RideHistoryStore()
    )
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
