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
    /// MYR-301 — where a vehicle-command re-link notice sends the owner (the
    /// existing Settings → Tesla link flow; `RootView` owns the navigation).
    /// `nil` in previews — the notice then renders without a tappable fix.
    var onRelinkTesla: (() -> Void)? = nil
    /// MYR-264 — the ONE resolved live/sim flag (threaded from `RootView`). Gates
    /// every fixture surface below the owner Home: the incoming-request sheet's
    /// rider/vehicle identity and the vehicle-controls media block. `false` in SIM
    /// / DEBUG scenes keeps them pixel-identical (CLAUDE.md "No fixtures on the
    /// live path").
    var isLive: Bool = false

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
    /// MYR-270 — double-tap guard for the owner dispatch CTA ("Picked up"/"Dropped
    /// off"). Reset on every status change so a re-shown button is tappable again
    /// (MYR-265 review: never leave the CTA permanently greyed after one advance).
    @State private var dispatchInFlight = false

    /// MYR-171 — `IncomingRequestSheet` shows only while there's a request
    /// actually awaiting this owner's decision; once accepted/declined the
    /// service's `activeRequest.status` moves off `.pending` and this goes
    /// `nil`, which is also what drives the sheet's own dismiss animation.
    private var incomingRequest: RideRequestRecord? {
        rideRequestService.activeRequest?.status == .pending ? rideRequestService.activeRequest : nil
    }

    /// MYR-264 — join a request's real `vehicleId` to the owner's loaded fleet for
    /// the true vehicle name/status. `nil` in SIM (a fixture `fleetMemberID` is not
    /// a live vehicle id — the sheet falls back to the fixture fleet member there)
    /// and for a live request whose vehicle isn't in the loaded fleet.
    private func incomingVehicle(for request: RideRequestRecord) -> Vehicle? {
        homeState.vehicles.first { $0.id == request.input.fleetMemberID }
    }

    private func incomingDisplay(for request: RideRequestRecord) -> IncomingRequestDisplay {
        IncomingRequestDisplay.resolve(request: request, isLive: isLive, liveVehicle: incomingVehicle(for: request))
    }

    /// MYR-277 A2 — the TARGET vehicle's live position, used by the incoming sheet
    /// to estimate the car→pickup leg. `nil` when the vehicle isn't in the loaded
    /// fleet (SIM fixture ride ids, or a live ride whose vehicle isn't loaded) or
    /// when its coordinate is the "0,0 = no fix" sentinel — the sheet then omits the
    /// pickup leg and falls back to the single ride-leg stats row.
    private func carPosition(for request: RideRequestRecord) -> CLLocationCoordinate2D? {
        guard let vehicle = incomingVehicle(for: request) else { return nil }
        let coordinate: CLLocationCoordinate2D
        switch vehicle.activity {
        case .parked(let location):
            coordinate = location.coordinate
        case .driving(let trip):
            let progress = homeState.telemetry(forVehicleID: vehicle.id)?.snapshot.progress ?? 0
            coordinate = VehicleRoute.position(along: trip.route, progress: progress).coordinate
        }
        return (coordinate.latitude == 0 && coordinate.longitude == 0) ? nil : coordinate
    }

    /// MYR-277 B — the dispatched ride's pickup coordinate while the owner's active
    /// ride is heading to the pickup (leg 1: `.accepted`/`.arrived`); `nil`
    /// otherwise so the owner map only draws the car→pickup route during leg 1.
    private var leg1PickupCoordinate: CLLocationCoordinate2D? {
        guard let ride = dispatchedRide, ride.status == .accepted || ride.status == .arrived,
              // Only draw the pickup route when the vehicle ON SCREEN is the one
              // actually dispatched — otherwise switching the map to another car
              // mid-dispatch would draw a spurious route from the wrong vehicle
              // (MYR-277 review).
              ride.input.fleetMemberID == homeState.selectedVehicle?.id
        else { return nil }
        return ride.input.pickup.coordinate
    }

    /// MYR-265 — the active DISPATCHED ride this owner is tracking (accepted →
    /// enroute → completed), or `nil` when there is none / it is still pending
    /// (the incoming sheet handles pending). The owner observes the live status
    /// through the SAME shared `rideRequestService.activeRequest`, folded from each
    /// `ride_status_changed` WS unicast by `LiveRideRequestService.integrate`.
    ///
    /// MYR-292 — the visibility rule (including "Dropped off ✓ shows until
    /// acknowledged, then never again for that ride") is the PURE
    /// `OwnerRideStatusLine.dispatchCardVisible` resolver, and the acknowledgement it
    /// reads lives on `OwnerHomeState`, which survives the owner tab switch. It used
    /// to be `HomeScreen` `@State`, which `RootView`'s `switch ownerTab` destroys —
    /// so the banner reappeared every time the owner came back to Home.
    private var dispatchedRide: RideRequestRecord? {
        guard let request = rideRequestService.activeRequest,
              OwnerRideStatusLine.dispatchCardVisible(
                  status: request.status,
                  rideID: request.id,
                  acknowledgedID: homeState.acknowledgedCompletedRideID)
        else { return nil }
        return request
    }

    /// The owner's ride-aware status line for the dispatched ride — real rider name
    /// (via the gated `IncomingRequestDisplay`) + real drop-off label, neutral when
    /// absent (MYR-228). `nil` when there is no dispatched ride.
    private var dispatchStatusLine: String? {
        guard let request = dispatchedRide else { return nil }
        return OwnerRideStatusLine.text(
            status: request.status,
            riderName: incomingDisplay(for: request).riderName,
            dropoffLabel: request.input.destination.label,
            arriving: ownerArriving
        )
    }

    /// MYR-270 — "Arriving at <dropoff>" derives from the streamed nav ETA
    /// (`etaMinutes` 1…2) of the selected vehicle DURING the in-ride leg, never a
    /// timer. Honest — no fabricated ETA (MYR-228): `snapshot.etaMinutes` is a
    /// non-optional Int that collapses an ABSENT ETA to 0 (VehicleContractMapping),
    /// so an absent ETA and a stationary car both read 0. We must NOT treat 0 as
    /// "arriving" — otherwise the owner flashes "Arriving" the instant leg 2 starts
    /// (car still parked at pickup, dropoff ETA not yet streamed). Require the car
    /// to be actively DRIVING with a real ETA of 1…2 min — matching the rider path
    /// (which uses an Int? and returns false on nil).
    private var ownerArriving: Bool {
        guard let status = dispatchedRide?.status,
              let snapshot = homeState.selectedTelemetry?.snapshot else { return false }
        return OwnerRideStatusLine.arriving(
            status: status, isDriving: snapshot.status == .driving, etaMinutes: snapshot.etaMinutes)
    }

    /// The owner's dispatch CTA for the current state — "Picked up" (accepted →
    /// arrived) / "Dropped off" (enroute → completed); `nil` for arrived (awaiting
    /// the rider's Start) and completed. Optimistic + 409-reconcile happen inside the
    /// service; `dispatchInFlight` only guards a double-tap within one frame.
    private var dispatchAction: OwnerDispatchAction? {
        guard let status = dispatchedRide?.status,
              let title = OwnerRideStatusLine.actionTitle(for: status) else { return nil }
        return OwnerDispatchAction(title: title) {
            guard !dispatchInFlight else { return }
            dispatchInFlight = true
            switch status {
            case .accepted: rideRequestService.pickedUp()
            case .enroute: rideRequestService.droppedOff()
            default: break
            }
        }
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
                isLive: isLive,
                resolvedVehicle: incomingRequest.flatMap { incomingVehicle(for: $0) },
                carPosition: incomingRequest.flatMap { carPosition(for: $0) },
                vehicleStatus: incomingRequest.flatMap { homeState.badgeStatus(forVehicleID: $0.input.fleetMemberID) },
                onAccept: handleAccept,
                onDecline: { rideRequestService.decline() }
            )
        }
        .overlay {
            RouteSentToast(content: $routeSentToast)
        }
        // MYR-265 — the ride-aware dispatch status pill, pinned just below the
        // MapHeader switcher. Shown ONLY while a ride is dispatched, so the plain
        // owner Home (no active ride, the `ownerHome` drift-gate scene) is
        // pixel-identical. Full-bleed placement mirrors `MapHeader` (physical top).
        .overlay(alignment: .top) {
            if let line = dispatchStatusLine {
                OwnerDispatchCard(
                    line: line,
                    isComplete: dispatchedRide?.status == .completed,
                    action: dispatchAction,
                    actionDisabled: dispatchInFlight
                )
                .padding(.top, MRTMetrics.mapHeaderTop + MRTMetrics.mapChipHeight + 12)
                .frame(maxWidth: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.28), value: dispatchStatusLine)
        // MYR-270: reset the CTA double-tap latch whenever the dispatched status
        // changes (optimistic advance or WS reconcile), so the next state's button
        // ("Picked up" → later "Dropped off") is immediately tappable.
        .onChange(of: dispatchedRide?.status) { _, status in
            dispatchInFlight = false
            scheduleDroppedOffDismiss(for: status)
        }
        // Also on appear: `.onChange` skips the initial value, so a ride that is
        // ALREADY `.completed` when Home first renders (e.g. app relaunched right
        // after drop-off) would otherwise never schedule the dismiss and the
        // "Dropped off ✓" banner would stay stuck (MYR-267 review). Safe to run on
        // EVERY mount (MYR-292): the acknowledgement now lives on `OwnerHomeState`,
        // so a remount over an already-acknowledged ride reads `dispatchedRide == nil`
        // and this no-ops instead of re-arming the confirmation.
        .onAppear { scheduleDroppedOffDismiss(for: dispatchedRide?.status) }
    }

    /// Auto-dismiss the owner's "Dropped off ✓" confirmation after a beat so Home
    /// doesn't stay stuck on it. Owner-local — never touches the shared
    /// `activeRequest`, so the rider's summary is unaffected (MYR-267).
    ///
    /// MYR-292: the acknowledgement is written to `OwnerHomeState`, NOT to view
    /// `@State`. This task outlives the view — the owner can switch to Drives inside
    /// the 5s window — and the object it writes to must outlive it too, or the write
    /// lands in torn-down storage and the banner returns on the next visit to Home.
    /// Capturing the two references (rather than `self`) makes that explicit. Writing
    /// the same id twice is a no-op, so a duplicate timer armed by a remount inside
    /// the window is harmless.
    private func scheduleDroppedOffDismiss(for status: RideRequestStatus?) {
        guard status == .completed, let id = rideRequestService.activeRequest?.id,
              homeState.acknowledgedCompletedRideID != id else { return }
        let service = rideRequestService
        let state = homeState
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard service.activeRequest?.id == id, service.activeRequest?.status == .completed else { return }
            state.acknowledgedCompletedRideID = id
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
            bottomContentInset: peekHeight,
            // MYR-277 B — draw the dispatched car→pickup route (leg 1) while the
            // owner's active ride is heading to the pickup (accepted/arrived).
            pickupCoordinate: leg1PickupCoordinate
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

        // MYR-236 round 5.3 — the CROSSFADE model (no reserve band). The peek
        // layer is the summary hero ONLY; the expanded layer is the full dense
        // scrollable content (summary + route/controls…). The engine hosts both
        // and cross-dissolves them by drag progress, so the controls fade in
        // beneath a stationary summary from the first pixel of drag — no reserve
        // fold, no mid-drag gap that snaps shut at settle, and nothing poking
        // below the summary at rest peek (client TestFlight bugs, Jul 23).
        MRTDetentSheet(
            detent: $homeState.sheetDetent,
            peekHeight: peekHeight,
            halfHeightFraction: MRTMetrics.homeHalfHeightFraction,
            peek: {
                // LOW layer — summary hero only, at the same top position and
                // gutter as the expanded layer's summary so the crossfade reads
                // as a stationary summary.
                sheetSummary(vehicle: vehicle, snapshot: snapshot)
                    .padding(.horizontal, MRTMetrics.pageGutter)
                    .padding(.top, 6) // screens.jsx:542 `padding: '6px 24px …'`
            },
            expanded: {
                // HIGH layer — the full dense content, scrollable exactly as
                // before. Its ScrollView is the one the engine's scroll handoff
                // discovers (base + peek layer have none).
                debugAnchoredScroll {
                    sheetDense(vehicle: vehicle, snapshot: snapshot)
                        .padding(.horizontal, MRTMetrics.pageGutter)
                        .padding(.top, 6) // screens.jsx:542 `padding: '6px 24px 100px'`
                        .padding(.bottom, MRTMetrics.homeSheetContentBottomPadding)
                }
            }
        )
    }

    /// The expanded-layer scroll view. Normally a plain `ScrollView`; the
    /// MYR-279 `ownerVehicleDetails` capture scene anchors it to the BOTTOM so
    /// the vehicle-details section is in-frame for one full-frame screenshot.
    /// Release builds compile the plain `ScrollView` — the sheet is untouched.
    @ViewBuilder
    private func debugAnchoredScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if DEBUG
        switch DebugScene.current?.sheetScrollTarget {
        case .bottom:
            ScrollView { content() }.defaultScrollAnchor(.bottom)
        case .fraction(let y):
            ScrollView { content() }.defaultScrollAnchor(UnitPoint(x: 0.5, y: y))
        case nil:
            ScrollView { content() }
        }
        #else
        ScrollView { content() }
        #endif
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

        // MYR-264 — the accept toast + reserved Upcoming ride resolve through the
        // SAME gated display the sheet uses: real rider name + real joined vehicle
        // on live (neutral / hidden when absent), fixture "Sam"/"Model Y" in SIM.
        // Previously this read `request.input.fleetMember` (→ fixture `fleet[0]` on
        // live) and a hardcoded "Sam", leaking both onto the live route toast.
        let display = incomingDisplay(for: request)
        let destination = request.input.destination
        let vehicleName = display.vehicleName
        let riderLabel = display.riderLabel

        if let schedule = request.input.schedule {
            drivesState.addUpcoming(
                UpcomingRide(
                    id: "ou-" + request.id,
                    rider: riderLabel,
                    destination: .init(
                        label: destination.label,
                        subtitle: destination.subtitle ?? "",
                        miles: destination.miles,
                        mins: destination.minutes
                    ),
                    scheduleDay: schedule.day,
                    scheduleTime: schedule.time,
                    vehicleName: vehicleName ?? ""
                )
            )
            let reserved = vehicleName.map { "\(riderLabel) \u{00B7} \(destination.label) \u{00B7} \($0) reserved" }
                ?? "\(riderLabel) \u{00B7} \(destination.label) reserved"
            routeSentToast = RouteSentToastContent(
                title: "Ride scheduled \u{00B7} \(schedule.day) \(schedule.time)",
                subtitle: reserved,
                isScheduled: true
            )
        } else if let passenger = request.input.passenger {
            routeSentToast = RouteSentToastContent(
                title: vehicleName.map { "Destination sent to \($0)" } ?? "Destination sent",
                subtitle: "\(passenger.name) got a tracking link \u{00B7} \(destination.label)",
                isScheduled: false
            )
        } else {
            routeSentToast = RouteSentToastContent(
                title: vehicleName.map { "Destination sent to \($0)" } ?? "Destination sent",
                subtitle: "Heading to \(destination.label) \u{00B7} \(destination.minutes) min",
                isScheduled: false
            )
        }
    }

    /// The LOW crossfade layer — the summary hero only (peek). Identical pixels
    /// to the top of `sheetDense` so the crossfade reads as a stationary summary.
    @ViewBuilder
    private func sheetSummary(vehicle: Vehicle, snapshot: VehicleTelemetrySnapshot) -> some View {
        switch vehicle.activity {
        case .driving(let trip):
            DrivingSummary(vehicle: vehicle, trip: trip, snapshot: snapshot)
        case .parked(let location):
            ParkedSummary(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                // Live: reflect the real wire status (parked/charging/offline/
                // in_service→neutral) in the design badge. Simulated: `.parked`.
                status: homeState.selectedBadgeStatus
            )
        }
    }

    /// The HIGH crossfade layer — the full dense content (summary + route/
    /// controls…), one scrollable block, no reserve band (MYR-236 round 5.3).
    @ViewBuilder
    private func sheetDense(vehicle: Vehicle, snapshot: VehicleTelemetrySnapshot) -> some View {
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
                executor: executor,
                isEditingPlate: $isEditingPlate,
                onRelinkTesla: onRelinkTesla,
                isLive: isLive
            )
        case .parked(let location):
            ParkedHeroContent(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                status: homeState.selectedBadgeStatus,
                executor: executor,
                isEditingPlate: $isEditingPlate,
                onRelinkTesla: onRelinkTesla,
                isLive: isLive
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
