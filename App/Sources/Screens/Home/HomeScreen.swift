import SwiftUI
import MapKit
import DesignSystem

// MARK: - HomeScreen — Owner Live Map (MYR-167,
// design/app/screens.jsx:369-437, Handoff §5.5)
//
// The app's primary screen: real MapKit + route + vehicle marker, a
// peek↔half draggable bottom sheet (`MRTDetentSheet`, MYR-162) whose hero
// switches on the selected vehicle's fixed M1 activity, the `MapHeader`
// vehicle switcher, a `FloatingMapButton` recenter affordance, and the owner
// `BottomNav` (screens.jsx renders its own `BottomNav` inside `HomeScreen`
// rather than a shared wrapper — every owner screen does the same, see
// `PlaceholderScreen.swift`).
struct HomeScreen: View {
    @Bindable var homeState: OwnerHomeState
    @Binding var ownerTab: String

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true

    private var vehicle: Vehicle { homeState.selectedVehicle }
    private var snapshot: VehicleTelemetrySnapshot { homeState.selectedTelemetry.snapshot }

    /// screens.jsx:400 — driving always uses the 280pt peek; parked uses the
    /// 'floating' style's 210pt (the only `parkedStyle` this app ships).
    private var peekHeight: CGFloat {
        snapshot.status == .driving ? MRTMetrics.homePeekHeightDriving : MRTMetrics.homePeekHeightParked
    }

    var body: some View {
        ZStack {
            VehicleMapView(
                vehicle: vehicle,
                snapshot: snapshot,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing
            )
            .id(vehicle.id) // fresh camera state per vehicle on switch
            .ignoresSafeArea()

            MapHeader(vehicles: VehicleFixtures.vehicles, selectedIndex: $homeState.selectedVehicleIndex)

            FloatingMapButton(
                bottom: peekHeight + MRTMetrics.mapButtonBottomGap,
                hidden: isFollowing || homeState.sheetDetent == .half
            ) {
                isFollowing = true
            }

            MRTDetentSheet(
                detent: $homeState.sheetDetent,
                peekHeight: peekHeight,
                halfHeightFraction: MRTMetrics.homeHalfHeightFraction
            ) {
                ScrollView {
                    sheetContent
                        .padding(.horizontal, MRTMetrics.pageGutter)
                        .padding(.top, 6) // screens.jsx:542 `padding: '6px 24px 100px'`
                        .padding(.bottom, MRTMetrics.homeSheetContentBottomPadding)
                }
                .scrollDisabled(homeState.sheetDetent == .peek)
                // No extra `.animation` here: `detent` only ever changes via
                // `MRTDetentSheet`'s own drag gesture, which already wraps
                // the mutation in `.spring(response:0.42, dampingFraction:
                // 0.86)` (Handoff §8 sheet snap) — since it writes through
                // this same `homeState.sheetDetent` binding, the Route/
                // Controls reveal below inherits that transaction for free.
            }

            BottomNav(selection: $ownerTab, tabs: MRTTab.ownerTabs, hidden: homeState.sheetDetent == .half)
        }
        .background(Color.mrtBg)
        .onAppear { homeState.startTelemetry() }
        .onChange(of: homeState.selectedVehicleIndex) { _, _ in
            isFollowing = true
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch vehicle.activity {
        case .driving(let trip):
            DrivingHeroContent(
                vehicleName: vehicle.name,
                trip: trip,
                snapshot: snapshot,
                expanded: homeState.sheetDetent == .half
            )
        case .parked(let location):
            ParkedHeroContent(
                vehicleName: vehicle.name,
                location: location,
                snapshot: snapshot,
                expanded: homeState.sheetDetent == .half
            )
        }
    }
}

#Preview {
    HomeScreen(homeState: OwnerHomeState(), ownerTab: .constant("home"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
