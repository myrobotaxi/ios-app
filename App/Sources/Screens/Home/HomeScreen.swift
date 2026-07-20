import SwiftUI
import MapKit
import DesignSystem

// MARK: - HomeScreen — Owner Live Map (MYR-167,
// design/app/screens.jsx:369-437, Handoff §5.5; live telemetry MYR-201)
//
// The app's primary screen: real MapKit + route + vehicle marker, a
// peek↔half draggable bottom sheet (`MRTDetentSheet`, MYR-162) whose hero
// switches on the selected vehicle's activity, the `MapHeader` vehicle
// switcher, a `FloatingMapButton` recenter affordance, and the owner
// `BottomNav` (screens.jsx renders its own `BottomNav` inside `HomeScreen`
// rather than a shared wrapper — every owner screen does the same, see
// `PlaceholderScreen.swift`).
//
// MYR-201 makes the vehicle data live-or-simulated behind `OwnerHomeState`'s
// fleet seam. When the live fleet is still connecting (or can't be reached),
// there's no selected vehicle yet, so the screen shows a subtle connecting /
// status placeholder in place of the map+sheet; the switcher + BottomNav are
// unchanged. In simulated mode a vehicle is always selected, so this screen
// renders exactly as it did in M1.
struct HomeScreen: View {
    @Bindable var homeState: OwnerHomeState
    @Binding var ownerTab: String
    /// MYR-171 — the M1↔M2 ride-request seam; one instance is shared with the
    /// rider's `SharedViewerScreen` (see `RideRequestService`'s header comment).
    /// MYR-209 — the `any RideRequestService` seam (simulated or live). SwiftUI
    /// still tracks `.activeRequest` reads inside `body`: the property witness on
    /// the `@Observable` conformer drives the registrar through the existential,
    /// so no `@Bindable` is needed (this view never makes a `$` binding from it).
    var rideRequestService: any RideRequestService
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

    var body: some View {
        ZStack {
            if let vehicle = homeState.selectedVehicle,
               let telemetry = homeState.selectedTelemetry,
               !homeState.isConnecting {
                vehicleContent(vehicle: vehicle, telemetry: telemetry)
            } else {
                // Live fleet mid-connect or unavailable (deliverable 3) — subtle,
                // never dramatic (design minimalism).
                FleetConnectingView(
                    isConnecting: homeState.isConnecting,
                    message: homeState.statusMessage
                )
            }
        }
        .background(Color.mrtBg)
        // components.jsx:566 `position: absolute, ... bottom: 26` — pin to
        // the screen's PHYSICAL bottom edge via the shared `mrtBottomNav`
        // helper. Applied on the whole ZStack, it layers above every sheet/map
        // content declared above (matching the jsx's nav zIndex 40 vs. sheet
        // zIndex 30) and overlaps the sheet's bottom edge exactly like the
        // prototype.
        .mrtBottomNav(selection: $ownerTab, hidden: homeState.sheetDetent == .half)
        .onAppear { homeState.startTelemetry() }
        .onChange(of: homeState.selectedVehicleIndex) { _, _ in
            isFollowing = true
            // Live fleet: narrow the socket subscription to the newly selected
            // vehicle (no-op for the simulated fleet).
            homeState.setActiveVehicle()
        }
        .mrtConfigSheet(isPresented: $isEditingPlate, showsCloseButton: false) {
            if let executor = homeState.selectedCommandExecutor {
                PlateEditSheet(
                    initialPlate: executor.controls.plate,
                    onCancel: { isEditingPlate = false },
                    onSave: { newPlate in
                        Task { try? await executor.setPlate(newPlate) }
                        isEditingPlate = false
                    }
                )
            }
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

    // MARK: - Vehicle content (map + switcher + sheet)

    @ViewBuilder
    private func vehicleContent(vehicle: Vehicle, telemetry: any VehicleTelemetrySource) -> some View {
        let snapshot = telemetry.snapshot
        // screens.jsx:400 — driving always uses the 280pt peek; parked uses the
        // 'floating' style's 210pt (the only `parkedStyle` this app ships).
        let peekHeight = snapshot.status == .driving
            ? MRTMetrics.homePeekHeightDriving
            : MRTMetrics.homePeekHeightParked

        VehicleMapView(
            vehicle: vehicle,
            snapshot: snapshot,
            cameraPosition: $cameraPosition,
            isFollowing: $isFollowing,
            // Keeps MapKit's legal attribution label clear of the
            // (now physically flush) sheet below — see `VehicleMapView`'s
            // doc comment and MYR-196 punch-list #2.
            bottomContentInset: peekHeight
        )
        .id(vehicle.id) // fresh camera state per vehicle on switch
        .ignoresSafeArea()

        MapHeader(vehicles: homeState.vehicles, selectedIndex: $homeState.selectedVehicleIndex)

        // `bottom` is measured against the sheet's physical-edge peek
        // height (see `MRTDetentSheet`'s `.ignoresSafeArea(edges: .bottom)`),
        // so this button needs the same physical-edge coordinate space —
        // full-bleed geometry (CLAUDE.md "Hard rules").
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
                sheetContent(vehicle: vehicle, snapshot: snapshot)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.top, 6) // screens.jsx:542 `padding: '6px 24px 100px'`
                    .padding(.bottom, MRTMetrics.homeSheetContentBottomPadding)
            }
            // MYR-236 round 4: no more `.scrollDisabled(detent == .peek)` — the
            // PanSheet engine's scroll handoff governs instead (below max detent
            // the sheet owns the pan and pins this offset; at half the list
            // scrolls, and a downward pan from its top hands back to the sheet).
            // Removing the flip also kills the round-3 "glitch" suspect: nothing
            // hard-swaps when the detent binding commits at settle.
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
    private func sheetContent(vehicle: Vehicle, snapshot: VehicleTelemetrySnapshot) -> some View {
        // A live command executor is always present alongside a selected
        // vehicle; fall back to a throwaway simulated one only to keep the type
        // total (never rendered without a selection).
        let executor = homeState.selectedCommandExecutor
            ?? SimulatedVehicleCommandExecutor(driving: false, plate: vehicle.plate)
        switch vehicle.activity {
        case .driving(let trip):
            DrivingHeroContent(
                vehicle: vehicle,
                trip: trip,
                snapshot: snapshot,
                expanded: homeState.sheetDetent == .half,
                executor: executor,
                isEditingPlate: $isEditingPlate
            )
        case .parked(let location):
            ParkedHeroContent(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                // Live: reflect the real wire status (parked/charging/offline/
                // in_service→neutral) in the design badge. Simulated: `.parked`.
                status: homeState.selectedBadgeStatus,
                expanded: homeState.sheetDetent == .half,
                executor: executor,
                isEditingPlate: $isEditingPlate
            )
        }
    }
}

// MARK: - Fleet connecting / unavailable placeholder (MYR-201 deliverable 3)

/// Subtle stand-in shown while the live fleet is connecting or can't be
/// reached — no dramatic error UI (design minimalism). The Kit's auto-reconnect
/// handles transient drops; this only surfaces the cold connect + a quiet
/// status line (e.g. the auth-required case when no token is supplied).
private struct FleetConnectingView: View {
    let isConnecting: Bool
    let message: String?

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 12) {
                if isConnecting {
                    ProgressView()
                        .tint(Color.mrtTextMuted)
                    Text("Connecting to your vehicles…")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mrtTextSec)
                } else if let message {
                    Image(systemName: "car.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.mrtTextMuted)
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.mrtTextSec)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
