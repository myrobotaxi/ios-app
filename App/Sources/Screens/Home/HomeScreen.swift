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
    /// MYR-171 — the M1↔M2 ride-request seam; `@Bindable` so SwiftUI tracks
    /// reads of `.activeRequest` reliably inside this view's body (see
    /// `RideRequestService`'s header comment for why one instance is shared
    /// with the rider's `SharedViewerScreen`).
    @Bindable var rideRequestService: SimulatedRideRequestService
    /// MYR-171 — accepting a *scheduled* request reserves it into Drives →
    /// Upcoming (`addUpcoming`) instead of dispatching now.
    @Bindable var drivesState: OwnerDrivesState

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    /// Drives the plate-edit `mrtConfigSheet` (MYR-168) — applied at this
    /// screen's root so the scrim covers the whole screen, matching every
    /// other shared overlay in this codebase (ConfirmDialog, SuccessToast).
    @State private var isEditingPlate = false
    /// MYR-171 — `RouteSentToast`'s content, `nil` when hidden. Set by
    /// `handleAccept` the moment `IncomingRequestSheet`'s local choreography
    /// finishes; cleared by the toast's own auto-dismiss timer.
    @State private var routeSentToast: RouteSentToastContent?

    /// MYR-171 — `IncomingRequestSheet` shows only while there's a request
    /// actually awaiting this owner's decision; once accepted/declined the
    /// service's `activeRequest.status` moves off `.pending` and this goes
    /// `nil`, which is also what drives the sheet's own dismiss animation.
    private var incomingRequest: RideRequestRecord? {
        rideRequestService.activeRequest?.status == .pending ? rideRequestService.activeRequest : nil
    }

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
        // MYR-171 — both applied as `.overlay`s AFTER `.mrtBottomNav` (itself
        // an `.overlay`, BottomNav.swift) so the request sheet/toast render
        // above the floating tab bar — matches the jsx's z-index ordering
        // (`IncomingRequestSheet`/`RouteSentToast` at 60/55 vs. `BottomNav`
        // at 40, ride-request.jsx:1284,1432).
        .overlay {
            IncomingRequestSheet(
                request: incomingRequest,
                onAccept: handleAccept,
                onDecline: { rideRequestService.decline() }
            )
        }
        .overlay {
            RouteSentToast(content: $routeSentToast)
        }
    }

    /// MYR-171 — fires once `IncomingRequestSheet`'s own sending/sent
    /// choreography finishes (~1.7s after the tap, ride-request.jsx:1279).
    /// Calls the service, reserves a scheduled request into Drives ⇢
    /// Upcoming (app.jsx:135-139 `handleOwnerAccept`'s scheduled branch —
    /// `OwnerDrivesState.addUpcoming`'s doc comment), and shows the
    /// `RouteSentToast` copy variant for this request's shape.
    private func handleAccept() {
        guard let request = rideRequestService.activeRequest else { return }
        rideRequestService.accept()

        let fleetMember = request.input.fleetMember
        let destination = request.input.destination

        if let schedule = request.input.schedule {
            drivesState.addUpcoming(
                UpcomingRide(
                    id: "ou-" + request.id,
                    rider: "Sam",
                    destination: .init(
                        label: destination.label,
                        subtitle: destination.subtitle ?? "",
                        miles: destination.miles,
                        mins: destination.minutes
                    ),
                    scheduleDay: schedule.day,
                    scheduleTime: schedule.time,
                    vehicleName: fleetMember.name
                )
            )
            routeSentToast = RouteSentToastContent(
                title: "Ride scheduled \u{00B7} \(schedule.day) \(schedule.time)",
                subtitle: "Sam \u{00B7} \(destination.label) \u{00B7} \(fleetMember.name) reserved",
                isScheduled: true
            )
        } else if let passenger = request.input.passenger {
            routeSentToast = RouteSentToastContent(
                title: "Destination sent to \(fleetMember.name)",
                subtitle: "\(passenger.name) got a tracking link \u{00B7} \(destination.label)",
                isScheduled: false
            )
        } else {
            routeSentToast = RouteSentToastContent(
                title: "Destination sent to \(fleetMember.name)",
                subtitle: "Heading to \(destination.label) \u{00B7} \(destination.minutes) min",
                isScheduled: false
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
    HomeScreen(
        homeState: OwnerHomeState(),
        ownerTab: .constant("home"),
        rideRequestService: SimulatedRideRequestService(),
        drivesState: OwnerDrivesState()
    )
    .mrtSurfaceLook(.flat)
    .preferredColorScheme(.dark)
}
