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
    /// Drives the plate-edit `mrtConfigSheet` (MYR-168) — applied at this
    /// screen's root so the scrim covers the whole screen, matching every
    /// other shared overlay in this codebase (ConfirmDialog, SuccessToast).
    @State private var isEditingPlate = false

    private var vehicle: Vehicle { homeState.selectedVehicle }
    private var snapshot: VehicleTelemetrySnapshot { homeState.selectedTelemetry.snapshot }
    private var commandExecutor: any VehicleCommandExecutor { homeState.selectedCommandExecutor }

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
                isFollowing: $isFollowing,
                // Keeps MapKit's legal attribution label clear of the
                // (now physically flush) sheet below — see
                // `VehicleMapView`'s doc comment and MYR-196 punch-list #2.
                bottomContentInset: peekHeight
            )
            .id(vehicle.id) // fresh camera state per vehicle on switch
            .ignoresSafeArea()

            MapHeader(vehicles: VehicleFixtures.vehicles, selectedIndex: $homeState.selectedVehicleIndex)

            // `bottom` is measured against the sheet's physical-edge peek
            // height (see `MRTDetentSheet`'s `.ignoresSafeArea(edges:
            // .bottom)`), so this button needs the same physical-edge
            // coordinate space — full-bleed geometry (CLAUDE.md "Hard
            // rules").
            FloatingMapButton(
                bottom: peekHeight + MRTMetrics.mapButtonBottomGap,
                hidden: isFollowing || homeState.sheetDetent == .half
            ) {
                isFollowing = true
            }
            .ignoresSafeArea(edges: .bottom)

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
        }
        .background(Color.mrtBg)
        // components.jsx:566 `position: absolute, ... bottom: 26` — pin to
        // the screen's PHYSICAL bottom edge via the shared `mrtBottomNav`
        // helper (review finding #1 + MYR-196 punch-list #2/#3: was
        // floating mid-screen, then floating ~60pt off the physical bottom
        // once safe-area insets were accounted for). Applied as a modifier
        // on the whole ZStack, it layers above every sheet/map content
        // declared above (matching the jsx's nav zIndex 40 vs. sheet
        // zIndex 30) and overlaps the sheet's bottom edge exactly like the
        // prototype (`BottomSheet` is called with `navHeight={0}` at
        // screens.jsx:429 — the sheet itself already runs flush to the
        // physical bottom, see `MRTDetentSheet`'s own
        // `.ignoresSafeArea(edges: .bottom)` — while its content reserves
        // `MRTMetrics.homeSheetContentBottomPadding` (100pt) of bottom
        // padding above so the floating nav capsule never obscures it).
        .mrtBottomNav(selection: $ownerTab, hidden: homeState.sheetDetent == .half)
        .onAppear { homeState.startTelemetry() }
        .onChange(of: homeState.selectedVehicleIndex) { _, _ in
            isFollowing = true
        }
        .mrtConfigSheet(isPresented: $isEditingPlate, showsCloseButton: false) {
            PlateEditSheet(
                initialPlate: commandExecutor.controls.plate,
                onCancel: { isEditingPlate = false },
                onSave: { newPlate in
                    let executor = commandExecutor
                    Task { try? await executor.setPlate(newPlate) }
                    isEditingPlate = false
                }
            )
        }
    }

    @ViewBuilder
    private var sheetContent: some View {
        switch vehicle.activity {
        case .driving(let trip):
            DrivingHeroContent(
                vehicle: vehicle,
                trip: trip,
                snapshot: snapshot,
                expanded: homeState.sheetDetent == .half,
                executor: commandExecutor,
                isEditingPlate: $isEditingPlate
            )
        case .parked(let location):
            ParkedHeroContent(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                expanded: homeState.sheetDetent == .half,
                executor: commandExecutor,
                isEditingPlate: $isEditingPlate
            )
        }
    }
}

#Preview {
    HomeScreen(homeState: OwnerHomeState(), ownerTab: .constant("home"))
        .mrtSurfaceLook(.flat)
        .preferredColorScheme(.dark)
}
