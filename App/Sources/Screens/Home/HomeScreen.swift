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
    /// MYR-360 — the reservation seam behind the ride-share pause warning. `nil`
    /// off the live path and in every MYR-342 capture scene, where the flow falls
    /// back to committing the pause exactly as it did before this issue (there is
    /// no rider, no reservation and no server to strand one on). `RootView` is the
    /// only composer.
    var upcomingReservations: (any UpcomingReservationSource)? = nil

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    /// Drives the plate-edit `mrtConfigSheet` (MYR-168) — applied at this
    /// screen's root so the scrim covers the whole screen, matching every
    /// other shared overlay in this codebase (ConfirmDialog, SuccessToast).
    @State private var isEditingPlate = false
    /// MYR-316 — drives the "Expected back" `mrtConfigSheet`. Applied at this
    /// screen's root for the same reason `isEditingPlate` is: the scrim must cover
    /// the whole screen, matching every other shared overlay in this codebase.
    @State private var isEditingServiceWindow = Self.initialServiceWindowEditorPresented
    /// MYR-171 — `RouteSentToast`'s content, `nil` when hidden. Set by
    /// `handleAccept` the moment `IncomingRequestSheet`'s local choreography
    /// finishes; cleared by the toast's own auto-dismiss timer.
    @State private var routeSentToast: RouteSentToastContent?
    /// MYR-270 — double-tap guard for the owner dispatch CTA ("Picked up"/"Dropped
    /// off"). Reset on every status change so a re-shown button is tappable again
    /// (MYR-265 review: never leave the CTA permanently greyed after one advance).
    @State private var dispatchInFlight = false
    /// MYR-360 — the ride-share pause interaction (the reservation read, the
    /// decision, the presented warning and its three answers). A small object
    /// rather than three `@State` flags here, so every assertion about it is about
    /// the WIRE and needs no view to run.
    @State private var pauseFlow = RideSharePauseFlow()

    /// MYR-171 — `IncomingRequestSheet` shows only while there's a request
    /// actually awaiting this owner's decision; once accepted/declined the
    /// owner pipeline's status moves off `.pending` and this goes `nil`, which is
    /// also what drives the sheet's own dismiss animation.
    ///
    /// MYR-325 — the gate now lives on the service, as the OWNER pipeline's own
    /// `incomingRequest` projection, rather than being re-derived here from the
    /// shared `activeRequest`. Same expression, correct pipeline: a request can
    /// reach this owner while this device's RIDER half is mid-ride, sitting on a
    /// declined notice, or reading a ride summary — the state that made the client's
    /// owner side go permanently silent.
    private var incomingRequest: RideRequestRecord? { rideRequestService.incomingRequest }

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

    // MARK: - MYR-293 — real road routes on the two owner surfaces
    //
    // Both surfaces read the ONE `RideRouteStore` on `OwnerHomeState` (see its
    // declaration for why it lives there). Neither reconcile has any camera
    // effect: the routes are map CONTENT, and the polyline arriving late changes
    // what is drawn on the frame, never the frame — the MYR-237 overlay pattern.
    // `VehicleMapView`'s camera writers are untouched by this issue.

    /// The DISPATCHED vehicle's current coordinate — the origin leg 1 is fetched
    /// from. Reuses `carPosition(for:)`, so it joins the ride to the fleet by id
    /// and honours the same "0,0 = no fix" sentinel: a car with no fix has no
    /// route to fetch, and the map shows the pickup marker alone.
    private var dispatchedCarPosition: CLLocationCoordinate2D? {
        dispatchedRide.flatMap { carPosition(for: $0) }
    }

    /// A ~11m-resolution key for the dispatched car's position. The simulated trip
    /// ticks at 30Hz and a live device streams ~1Hz, so reconciling on the raw
    /// coordinate would ask the store on every frame; the store's own guards would
    /// absorb it, but the `.onChange` would not. Quantizing here keeps the ask at
    /// human cadence — the store then decides whether the car has actually
    /// DEVIATED enough to be worth a new MKDirections call.
    private var dispatchedCarPositionKey: String? {
        dispatchedCarPosition.map { String(format: "%.4f,%.4f", $0.latitude, $0.longitude) }
    }

    /// The resolved car → pickup road polyline for the dispatched leg, or empty.
    /// Keyed on the CURRENT pickup, so a route cached for a previous ride can
    /// never render under this one.
    private var dispatchedLeg1Route: [CLLocationCoordinate2D] {
        guard let pickup = leg1PickupCoordinate else { return [] }
        return homeState.rideRouteStore.leg1Route(pickup: pickup) ?? []
    }

    /// The resolved pickup → destination road polyline for the card currently
    /// awaiting a decision, or empty while it is in flight / after a failure.
    private var incomingRequestRoute: [CLLocationCoordinate2D] {
        guard let request = incomingRequest else { return [] }
        return homeState.rideRouteStore.leg2Route(
            pickup: request.input.pickup.coordinate,
            destination: request.input.destination.coordinate
        ) ?? []
    }

    /// Ask the store for whichever of the two routes this screen currently needs.
    /// Cheap to call on every trigger — both `ensure` methods are no-ops once the
    /// pair is cached with real geometry, and both retry a 2-point fallback only
    /// after their shared cooldown.
    private func reconcileOwnerRoutes() {
        if let pickup = leg1PickupCoordinate, let car = dispatchedCarPosition {
            homeState.rideRouteStore.ensureLeg1(carPosition: car, pickup: pickup)
        }
        if let request = incomingRequest {
            homeState.rideRouteStore.ensureLeg2(
                pickup: request.input.pickup.coordinate,
                destination: request.input.destination.coordinate
            )
        }
    }

    /// MYR-265 — the active DISPATCHED ride this owner is tracking (accepted →
    /// enroute → completed), or `nil` when there is none / it is still pending
    /// (the incoming sheet handles pending). The owner observes the live status
    /// through the OWNER pipeline's `ownerDispatch` (MYR-325 — it used to be the
    /// shared `activeRequest`), folded from each `ride_status_changed` WS unicast by
    /// `LiveRideRequestService.integrate`.
    ///
    /// MYR-292 — the visibility rule (including "Dropped off ✓ shows until
    /// acknowledged, then never again for that ride") is the PURE
    /// `OwnerRideStatusLine.dispatchCardVisible` resolver, and the acknowledgement it
    /// reads lives on `OwnerHomeState`, which survives the owner tab switch. It used
    /// to be `HomeScreen` `@State`, which `RootView`'s `switch ownerTab` destroys —
    /// so the banner reappeared every time the owner came back to Home.
    private var dispatchedRide: RideRequestRecord? {
        guard let request = rideRequestService.ownerDispatch,
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

    /// MYR-316 — DEBUG capture hook: the `ownerServiceWindowEditor` scene boots
    /// with the entry sheet already up, because it opens from a row inside the
    /// half-detent controls scroll and headless capture tooling cannot tap. Release
    /// builds compile a plain `false`, so the sheet is only ever owner-opened.
    private static var initialServiceWindowEditorPresented: Bool {
        #if DEBUG
        DebugScene.current?.opensServiceWindowEditor == true
        #else
        false
        #endif
    }

    var body: some View {
        ZStack {
            if let vehicle = homeState.selectedVehicle,
               let telemetry = homeState.selectedTelemetry,
               !homeState.isConnecting {
                vehicleContent(vehicle: vehicle, telemetry: telemetry)
            } else if homeState.isConnecting {
                // MYR-326 — GENUINELY LOADING: the fleet list or the selected
                // car's cold snapshot is in flight. A skeleton of the screen it
                // is about to become, not a spinner in a void (the client's
                // "This looks bad"). The switcher is REAL as soon as the list
                // lands, so only what is actually unknown is a placeholder.
                OwnerHomeLoadingSkeleton(
                    vehicles: homeState.vehicles,
                    selectedIndex: $homeState.selectedVehicleIndex
                )
            } else {
                // Live fleet unavailable (deliverable 3) — subtle, never
                // dramatic (design minimalism). NOT a skeleton: this branch is
                // an honest end state (auth required, empty account,
                // unreachable, or the MYR-326 cold-read timeout), and a
                // shimmering placeholder over it would promise data that isn't
                // coming.
                FleetConnectingView(message: homeState.statusMessage)
            }
        }
        .background(Color.mrtBg)
        // components.jsx:566 `position: absolute, ... bottom: 26` — pin to
        // the screen's PHYSICAL bottom edge via the shared `mrtBottomNav`
        // helper. Applied on the whole ZStack, it layers above every sheet/map
        // content declared above (matching the jsx's nav zIndex 40 vs. sheet
        // zIndex 30) and overlaps the sheet's bottom edge exactly like the
        // prototype.
        .mrtBottomNav(selection: $ownerTab, hidden: sheetCoversMap)
        .onAppear {
            homeState.startTelemetry()
            reconcileOwnerRoutes()
        }
        // MYR-293 — the three inputs either owner route depends on. A new incoming
        // card is one fetch; the dispatched leg re-asks as the car moves (the store
        // answers only on a material deviation) and drops its cache outright when
        // the pickup changes.
        .onChange(of: incomingRequest?.id) { _, _ in reconcileOwnerRoutes() }
        .onChange(of: dispatchedCarPositionKey) { _, _ in reconcileOwnerRoutes() }
        .onChange(of: leg1PickupCoordinate.map { "\($0.latitude),\($0.longitude)" }) { _, _ in reconcileOwnerRoutes() }
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
        .mrtConfigSheet(isPresented: $isEditingServiceWindow, showsCloseButton: false) {
            if let executor = homeState.selectedCommandExecutor, let vehicle = homeState.selectedVehicle {
                ServiceWindowEditSheet(
                    // The RESOLVED window (server-side precedence already applied),
                    // so the picker opens on whatever is actually in force —
                    // Tesla's estimate or the owner's own — rather than on a
                    // remembered local draft that may have been outranked.
                    //
                    // Resolved through the SAME rule the two read surfaces use, so
                    // re-opening the editor prefills exactly what the sheet is
                    // showing — including a value that has only ever arrived on a
                    // snapshot and was never committed here.
                    initialValue: VehicleServiceWindow.resolvedEndAt(
                        executor: executor,
                        snapshot: homeState.selectedTelemetry?.snapshot
                            ?? LiveVehicleTelemetrySource.placeholder
                    ),
                    vehicleName: vehicle.name,
                    onCancel: { isEditingServiceWindow = false },
                    onSave: { expectedEndAt in
                        Task { try? await executor.setServiceWindow(expectedEndAt) }
                        isEditingServiceWindow = false
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
                // MYR-317 — how many pending requests are queued behind this card.
                // The service owns the queue; the sheet only renders the count, and
                // the NEXT request re-presents through this very same path when the
                // current one resolves (no new sheet type, no list surface in v1).
                waitingCount: rideRequestService.waitingIncomingCount,
                // MYR-293 — the card's real pickup → destination road geometry;
                // empty until MKDirections answers, and the map then draws its two
                // pins with no line rather than a fabricated straight one.
                route: incomingRequestRoute,
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
        // MYR-360 — the ride-share pause warning, at the screen ROOT so the scrim
        // covers the whole screen (the same placement every other shared overlay in
        // this codebase takes). Presented only when the flow is holding a warning,
        // which is only reachable on the live path with a real reservation on the
        // wire — so every simulated and DEBUG capture renders this as nothing at
        // all, exactly as before.
        .mrtConfirmDialog(isPresented: isShowingPauseWarning, config: pauseWarningConfig) {
            // MYR-360 — the reservations as ROWS in the dialog's content slot, not
            // as prose in the message. A list flattened into a centred sentence
            // stops being a list (the client, on the first build: "list in plain
            // text is not helpful").
            RideSharePauseReservationList(reservations: pauseFlow.warning?.reservations ?? [])
        }
        .task { await flipRideShareForCaptureSceneIfRequested() }
    }

    /// MYR-360 (DEBUG capture only) — perform the ride-share pause flip on boot for
    /// the two `ownerRideSharePauseWarning` scenes.
    ///
    /// It stands in for exactly ONE tap on a switch that lives inside a half-detent
    /// scroll, which headless capture tooling can neither reach nor synthesize — the
    /// same precedent as `ownerFreshnessWaking`'s seeded phase and
    /// `ownerServiceWindowEditor`'s seeded presentation. Everything downstream is
    /// the shipping path: the real `setRideShareEnabled`, the real reservation
    /// fetch, the real contract fold and the real dialog copy.
    ///
    /// Release builds compile this to an empty async function, and in DEBUG it
    /// returns on the first line for every scene but those two — so no other
    /// capture writes anything, and no scene changes by a pixel.
    private func flipRideShareForCaptureSceneIfRequested() async {
        #if DEBUG
        guard DebugScene.current?.flipsRideShareOnBoot == true else { return }
        // The injected fleet resolves its one car within a frame or two; wait for
        // the selection rather than racing it, and give up rather than spin.
        for _ in 0..<40 {
            if homeState.selectedCommandExecutor != nil, homeState.selectedVehicle != nil { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        setRideShareEnabled(false)
        #endif
    }

    /// Auto-dismiss the owner's "Dropped off ✓" confirmation after a beat so Home
    /// doesn't stay stuck on it. Owner-local — it acknowledges on `OwnerHomeState`
    /// and reads only the OWNER pipeline, so the rider's summary is unaffected
    /// (MYR-267; MYR-325 makes that structural rather than careful).
    ///
    /// MYR-292: the acknowledgement is written to `OwnerHomeState`, NOT to view
    /// `@State`. This task outlives the view — the owner can switch to Drives inside
    /// the 5s window — and the object it writes to must outlive it too, or the write
    /// lands in torn-down storage and the banner returns on the next visit to Home.
    /// Capturing the two references (rather than `self`) makes that explicit. Writing
    /// the same id twice is a no-op, so a duplicate timer armed by a remount inside
    /// the window is harmless.
    private func scheduleDroppedOffDismiss(for status: RideRequestStatus?) {
        guard status == .completed, let id = rideRequestService.ownerDispatch?.id,
              homeState.acknowledgedCompletedRideID != id else { return }
        let service = rideRequestService
        let state = homeState
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard service.ownerDispatch?.id == id, service.ownerDispatch?.status == .completed else { return }
            state.acknowledgedCompletedRideID = id
        }
    }

    // MARK: - Vehicle content (map + switcher + sheet)

    @ViewBuilder
    private func vehicleContent(vehicle: Vehicle, telemetry: any VehicleTelemetrySource) -> some View {
        let snapshot = telemetry.snapshot
        // screens.jsx:400 — driving always uses the 280pt peek; parked uses the
        // 'floating' style's 210pt (the only `parkedStyle` this app ships).
        //
        // MYR-294 — a car driving with NO active navigation renders a hero the
        // prototype has no band for (no destination headline, no arrival pair, no
        // trip bar), so it takes its own measured base. Every fixture trip is
        // navigating, so the simulated path never reaches it.
        let peekHeight = MRTMetrics.homePeekHeight(
            base: Self.peekBase(vehicle: vehicle, snapshot: snapshot),
            qualifiers: peekQualifiers(snapshot: snapshot)
        )

        VehicleMapView(
            vehicle: vehicle,
            snapshot: snapshot,
            cameraPosition: $cameraPosition,
            isFollowing: $isFollowing,
            // Keeps MapKit's legal attribution label clear of the
            // (now physically flush) sheet below — see `VehicleMapView`'s
            // doc comment and MYR-196 punch-list #2.
            bottomContentInset: mapBottomInset(peekHeight: peekHeight),
            // MYR-277 B — mark the dispatched ride's pickup while the owner's
            // active ride is heading to it (accepted/arrived).
            pickupCoordinate: leg1PickupCoordinate,
            // MYR-293 — and draw the REAL road route to it. Empty (in flight, or
            // only a straight fallback resolved) leaves the marker without a line.
            pickupRoute: dispatchedLeg1Route
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
            hidden: isFollowing || sheetCoversMap
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
            // MYR-332 (client ask) — the owner sheet stops at half today and the
            // rest of the controls stack is reachable only by scrolling INSIDE
            // it; the third detent lets the sheet itself be pulled up to the
            // grammar's tallest surface (`MRTMetrics.sheetTallTopClearance`).
            // Peek and half are untouched: same heights, same crossfade endpoints,
            // same MYR-315 peek-band rule.
            allowsTallDetent: true,
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

    /// The map's bottom content inset — the value MapKit fits the written camera
    /// region into (`VehicleMapView`'s `.safeAreaPadding(.bottom:)`), so it is
    /// the camera's geometry, not just the attribution's.
    ///
    /// MYR-338 (client, on the day-old tall detent): *"The map moves up with the
    /// bottom sheet. Map should stay fixed."* MYR-332 had let this FOLLOW the
    /// sheet to tall so MapKit's legal attribution wouldn't be stranded behind
    /// it — but at tall the unobstructed band is ~200pt, and re-fitting the
    /// region into 200pt lifts the framed centre until the vehicle pin and its
    /// callout sit behind the `MapHeader` chip. That is the whole of the client's
    /// screenshot.
    ///
    /// So the inset is now resolved for `cameraDetent(for:)` — capped at HALF.
    /// Past half the sheet just COVERS the map (the Apple Maps model, and
    /// exactly what MYR-250 settled for the rider sheet). The attribution ends
    /// up behind the sheet at tall, which is the same trade half has always
    /// made and the strictly better one: a legal label the sheet hides for as
    /// long as the sheet is up, versus the car moving out from under the user
    /// every time they reach for a control.
    private func mapBottomInset(peekHeight: CGFloat) -> CGFloat {
        Self.vehicleMapBottomInset(detent: homeState.sheetDetent, peekHeight: peekHeight)
    }

    /// The detent the CAMERA is framed for, which is not always the detent the
    /// sheet is resting at: everything above half resolves to half. Pure and
    /// separate from the inset below so the cap itself is the thing under test
    /// (`OwnerMapCameraInsetTests`), independent of what half happens to resolve
    /// to today.
    static func cameraDetent(for detent: MRTSheetDetent) -> MRTSheetDetent {
        detent == .tall ? .half : detent
    }

    /// The camera-affecting inset for a sheet detent. Peek and half both resolve
    /// the peek band — the number this screen has always passed, and what every
    /// `MRT_OWNER_DETENT=half` drift-gate capture was taken against — and tall
    /// resolves half's, by the cap above.
    ///
    /// It takes NO sheet geometry on purpose. MYR-332 fed the sheet's resolved
    /// heights in here; removing that parameter is what makes the re-frame
    /// structurally impossible rather than merely clamped — there is no longer a
    /// path by which a sheet height can reach the camera at all.
    static func vehicleMapBottomInset(detent: MRTSheetDetent, peekHeight: CGFloat) -> CGFloat {
        switch cameraDetent(for: detent) {
        // `.tall` is unreachable — the cap above rewrites it to `.half` — but
        // the switch stays exhaustive so a fourth detent has to declare what
        // the camera does about it rather than inheriting a default.
        case .peek, .half, .tall: return peekHeight
        }
    }

    /// MYR-332 — the detents at which the owner sheet covers the map: the
    /// floating nav and the recenter button both stand down, exactly as they
    /// already did at half.
    private var sheetCoversMap: Bool {
        homeState.sheetDetent == .half || homeState.sheetDetent == .tall
    }

    /// MYR-315 — how much taller the peek band must be than the prototype's
    /// number, because this port's peek hero carries LIVE-ONLY lines the prototype
    /// has none of.
    ///
    /// THE CLIENT'S REPORT: the "Synced …" stamp renders too close to the floating
    /// menu. Measured on the isolated sim at peek (`ownerFreshnessStale`), the
    /// stamp's ink ends 102pt from the physical bottom edge and its ≥44pt tap
    /// region reaches 84pt — past the `BottomNav`'s own top edge at 86pt (60pt
    /// tall, `padding(.bottom, 26)`) and 16pt inside the 100pt band the design
    /// reserves for exactly this (`components.jsx:542`, ported as
    /// `homeSheetContentBottomPadding`). On the client's car it is worse than the
    /// capture shows: an IN-SERVICE vehicle also renders the MYR-319/320 completion
    /// line, one 24pt line higher up, which pushes the stamp's ink itself to ~86pt
    /// — flush against the menu.
    ///
    /// The fix is not to move the stamp (10pt below the line above it IS the
    /// design's trailing-qualifier rhythm, `components.jsx:559`) but to stop the
    /// band from being one line too short for what it now holds: the peek band is
    /// content-sized in the prototype too (150 / 210 / 280 by `parkedStyle`), so
    /// growing it per live-only line is the port's own grammar, not an invention.
    ///
    /// Both inputs are nil on the simulated path — the stamp is live-only by two
    /// gates (`freshnessStamp`) and nothing simulated is ever in service — so this
    /// returns an EMPTY list there and the drift-gate scenes keep the prototype's
    /// exact bands.
    ///
    /// MYR-345 (client defect) — the lines are now reported BY IDENTITY, not
    /// counted. MYR-315 counted them and multiplied by one flat 24, which
    /// over-reserved for the completion line by ~8pt; because the hero is
    /// top-aligned, every point of surplus lands in the gap above the floating nav
    /// and nowhere else — *"Weird gap between menu and synced just now"*. Each
    /// qualifier now brings exactly its own measured room
    /// (`MRTHomePeekQualifier.reservedHeight`), so the clearance under the hero is
    /// the prototype's in every variant. `OwnerPeekBandTests` measures the real
    /// views against that rule.
    /// MYR-294 — the band for the hero this vehicle actually renders.
    ///
    /// Three heroes now, not two: parked (210), driving-a-TRIP (280), and the
    /// honest driving hero, which is shorter than either because it has no
    /// destination line, no arrival pair and no trip progress bar.
    ///
    /// It switches on the SAME `DrivingHeroElement.location` the hero itself
    /// gates that line on — "the hero has nothing to say but a speed" — rather
    /// than on the navigation case. That is what keeps this to two driving bands:
    /// a `.resolvingDestination` whose ETA and progress have landed renders the
    /// full trip hero and takes 280, and one that has landed nothing yet renders
    /// the same shape `.none` does and takes the short band with it. Deriving the
    /// band from the navigation case instead would put a 40pt hole under the
    /// second (measured), which is precisely the MYR-345 defect.
    ///
    /// Pure + static so `OwnerPeekBandTests` can measure the real views against it.
    static func peekBase(vehicle: Vehicle, snapshot: VehicleTelemetrySnapshot) -> CGFloat {
        guard snapshot.status == .driving else { return MRTMetrics.homePeekHeightParked }
        guard case .driving(let trip) = vehicle.activity else { return MRTMetrics.homePeekHeightDriving }
        let elements = DrivingHeroElement.resolve(
            navigation: trip.navigation,
            etaMinutes: snapshot.etaMinutes,
            progress: snapshot.progress
        )
        return elements.contains(.location)
            ? MRTMetrics.homePeekHeightDrivingNoNavigation
            : MRTMetrics.homePeekHeightDriving
    }

    private func peekQualifiers(snapshot: VehicleTelemetrySnapshot) -> [MRTHomePeekQualifier] {
        var qualifiers: [MRTHomePeekQualifier] = []
        // Rendered by the PARKED hero only (`ParkedSummary.serviceCompletion`);
        // a driving car is never `in_service`, but the gate is stated rather than
        // assumed so the band can never grow for a line that isn't drawn. Listed
        // first because it renders first — it is the header's own second line.
        if snapshot.status != .driving, serviceCompletionLine(snapshot: snapshot) != nil {
            qualifiers.append(.serviceCompletion)
        }
        // Rendered by BOTH heroes (`mrtFreshnessStamp`), at the foot.
        if freshnessStamp(snapshot: snapshot) != nil { qualifiers.append(.freshnessStamp) }
        return qualifiers
    }

    /// The expanded-layer scroll view. Normally a plain `ScrollView`; the
    /// MYR-279 `ownerVehicleDetails` capture scene anchors it to the BOTTOM so
    /// the vehicle-details section is in-frame for one full-frame screenshot.
    /// Release builds compile the plain `ScrollView` — the sheet is untouched.
    @ViewBuilder
    private func debugAnchoredScroll<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        #if DEBUG
        // MYR-319 — the env override wins so a LIVE-shaped capture can frame any
        // section; unset, this is exactly the per-scene anchor as before.
        switch DebugScene.ownerScrollOverride ?? DebugScene.current?.sheetScrollTarget {
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
        guard let request = rideRequestService.incomingRequest else { return }
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

    /// MYR-315 — the freshness stamp model, or `nil` to render no stamp.
    ///
    /// LIVE ONLY, by two independent gates. The prototype has no recency stamp
    /// anywhere in the owner sheet (its single freshness element is the controls
    /// footer, `vehicle-controls.jsx:428`), so rendering one in SIM would be a
    /// visual invention AND would break every drift-gate scene's byte-identity
    /// (CLAUDE.md). It is also simply not honest there: the simulated snapshot
    /// carries no `isStreaming`/`lastUpdated`, so `VehicleFreshnessStamp.recency`
    /// returns nil for it regardless — the `isLive` check just makes the intent
    /// explicit at the seam where every other fixture gate lives (MYR-228).
    ///
    /// Reading `homeState.refreshTick` here is deliberate: the label is derived
    /// from `Date()`, which `@Observable` has no reason to re-evaluate for a car
    /// that isn't streaming, so the tick is what re-renders the stamp on a tap.
    private func freshnessStamp(snapshot: VehicleTelemetrySnapshot) -> VehicleFreshnessStampModel? {
        guard isLive else { return nil }
        _ = homeState.refreshTick
        guard let recency = VehicleFreshnessStamp.recency(
            isStreaming: snapshot.isStreaming,
            lastUpdated: snapshot.lastUpdated,
            now: Date()
        ) else { return nil }
        return VehicleFreshnessStampModel(
            recency: recency,
            phase: homeState.refreshPhase,
            action: { homeState.refreshSelectedVehicle() }
        )
    }

    /// MYR-316 — the "Estimated completion \u{00B7} …" line, or `nil` to render
    /// nothing.
    ///
    /// Gated on BOTH halves of the contract's own rule: the badge must say In
    /// Service AND the server must have resolved a window. Either alone renders
    /// nothing — an in-service car with no Tesla appointment record (the common
    /// case) simply has no line, and a value left in memory after the car came
    /// back cannot outlive the badge change.
    ///
    /// Nothing gates this on `isLive` explicitly, and nothing needs to: the
    /// simulated fleet has no in-service vehicle and its snapshots carry no
    /// window, so `completionLine` returns nil there by construction and every
    /// drift-gate scene stays byte-identical.
    private func serviceCompletionLine(snapshot: VehicleTelemetrySnapshot) -> String? {
        VehicleServiceWindow.completionLine(
            for: resolvedServiceWindow(snapshot: snapshot),
            isInService: homeState.selectedBadgeStatus == .inService
        )
    }

    /// The ONE resolution of the service window for this sheet — the hero line
    /// above and the "Service completion date" row inside `VehicleControls` are
    /// both built from this single call.
    ///
    /// It used to be resolved twice, independently, and BOTH times from
    /// `snapshot.serviceEstimatedEndAt` — a value that cannot move until the next
    /// cold `/snapshot` read, because the field carries no WS delta. A save wrote
    /// its echo to the executor, which neither surface read, so a save the server
    /// accepted changed nothing on screen (the client's report). See
    /// `VehicleServiceWindow.resolvedEndAt(committed:isCommitted:snapshot:)` for
    /// why the executor is the source and why `nil` had to be committable.
    ///
    /// Falls back to the snapshot when there is no executor at all — a state the
    /// selection invariant does not actually produce, but resolving to the older
    /// of the two values is the safe direction if it ever did.
    private func resolvedServiceWindow(snapshot: VehicleTelemetrySnapshot) -> Date? {
        guard let executor = homeState.selectedCommandExecutor else {
            return snapshot.serviceEstimatedEndAt
        }
        return VehicleServiceWindow.resolvedEndAt(executor: executor, snapshot: snapshot)
    }

    /// MYR-342 — the ONE resolution of the ride-share position for this sheet, and
    /// the LIVE gate on the whole row in a single place.
    ///
    /// `nil` means "do not render the row at all", and it is returned for exactly
    /// two situations, both of which are "this switch could not reach a server":
    /// the simulated path (`!isLive` — which is why every drift-gate scene is
    /// byte-identical), and the theoretical no-executor case the selection invariant
    /// does not actually produce. A switch that cannot be committed is worse than a
    /// missing one: flipping it would appear to withdraw the owner's car from
    /// ride-hailing and would do nothing at all.
    ///
    /// Resolved through `VehicleRideShare` rather than read off the snapshot,
    /// because the field carries no WS delta (rest-api.md §7.18 — the edit fires no
    /// push): the snapshot cannot hold the value the owner just committed, and a
    /// surface reading it directly would snap the switch back under their finger.
    /// This is the MYR-316 stale-window defect, avoided in advance on the sibling
    /// field with the same delivery property.
    private func resolvedRideShare(snapshot: VehicleTelemetrySnapshot) -> Bool? {
        guard isLive, let executor = homeState.selectedCommandExecutor else { return nil }
        return VehicleRideShare.resolvedEnabled(executor: executor, snapshot: snapshot)
    }

    /// MYR-342 — commit a ride-share flip through the executor seam. Fire-and-forget
    /// on purpose: the executor owns the optimistic flip, the echo adoption, the
    /// rollback and the notice, so there is nothing for the view to await and
    /// nothing for it to do with a failure that the row is not already showing.
    ///
    /// MYR-360 — the OFF direction now goes through `RideSharePauseFlow` first,
    /// which reads the car's upcoming reservations and either pauses immediately
    /// (nothing booked — the common case, unchanged) or raises the warning. The ON
    /// direction is untouched: resuming can strand nobody, so it never reads and
    /// never asks.
    private func setRideShareEnabled(_ enabled: Bool) {
        guard let executor = homeState.selectedCommandExecutor,
              let vehicleID = homeState.selectedVehicle?.id else { return }
        pauseFlow.source = upcomingReservations
        Task { await pauseFlow.setEnabled(enabled, vehicleID: vehicleID, executor: executor) }
    }

    /// MYR-360 — the pause warning's presentation binding. `mrtConfirmDialog` takes
    /// a `Bool`; the flow owns the model, so setting it false IS "Keep sharing" —
    /// which is also the path the confirm and secondary buttons take on their way
    /// out, after their own action has already run.
    private var isShowingPauseWarning: Binding<Bool> {
        Binding(
            get: { pauseFlow.warning != nil },
            set: { if !$0 { pauseFlow.keepSharing() } }
        )
    }

    /// The dialog itself. Built from the reservations the flow is holding, so the
    /// rows name exactly the rides the confirm button will decline.
    private var pauseWarningConfig: MRTConfirmDialogConfig {
        RideSharePauseDialog.warning(
            count: pauseFlow.warning?.reservations.count ?? 0,
            onDeclineAndPause: { Task { await pauseFlow.confirmDeclineAndPause() } },
            onPauseAnyway: { Task { await pauseFlow.pauseAnyway() } }
        )
    }

    /// The LOW crossfade layer — the summary hero only (peek). Identical pixels
    /// to the top of `sheetDense` so the crossfade reads as a stationary summary.
    @ViewBuilder
    private func sheetSummary(vehicle: Vehicle, snapshot: VehicleTelemetrySnapshot) -> some View {
        switch vehicle.activity {
        case .driving(let trip):
            DrivingSummary(
                vehicle: vehicle,
                trip: trip,
                snapshot: snapshot,
                freshness: freshnessStamp(snapshot: snapshot),
                // MYR-294 — where the car is, for the no-navigation hero. Same
                // value the Route section's origin leg carries, so the peek and
                // the dense layer can never name two different places.
                currentLocation: trip.originLabel
            )
        case .parked(let location):
            ParkedSummary(
                vehicle: vehicle,
                location: location,
                snapshot: snapshot,
                // Live: reflect the real wire status (parked/charging/offline/
                // in_service→neutral) in the design badge. Simulated: `.parked`.
                status: homeState.selectedBadgeStatus,
                freshness: freshnessStamp(snapshot: snapshot),
                serviceCompletion: serviceCompletionLine(snapshot: snapshot)
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
                isLive: isLive,
                // The SAME model the peek layer gets — the crossfade dissolves the
                // two summaries into each other, so they must match line for line.
                freshness: freshnessStamp(snapshot: snapshot),
                currentLocation: trip.originLabel
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
                isLive: isLive,
                freshness: freshnessStamp(snapshot: snapshot),
                // The SAME line the peek layer gets — the crossfade dissolves the
                // two summaries into each other, so they must match line for line.
                serviceCompletion: serviceCompletionLine(snapshot: snapshot),
                onEditServiceWindow: { isEditingServiceWindow = true },
                // The SAME resolution the line above was built from, so the hero
                // and the details row can never disagree about what is saved.
                serviceEstimatedEndAt: resolvedServiceWindow(snapshot: snapshot),
                // MYR-342 — the owner's ride-sharing switch. `nil` off the live
                // path, which is the whole gate: the Status & location card grows
                // its one new row only where the toggle can actually reach §7.18.
                rideShareEnabled: resolvedRideShare(snapshot: snapshot),
                onSetRideShareEnabled: setRideShareEnabled
            )
        }
    }
}

// MARK: - Fleet unavailable notice (MYR-201 deliverable 3)

/// Subtle stand-in shown when the live fleet can't be shown — no dramatic error
/// UI (design minimalism). The Kit's auto-reconnect handles transient drops;
/// this only surfaces the quiet honest line (auth required, no vehicles on the
/// account, unreachable, or the MYR-326 cold-read timeout).
///
/// MYR-326 removed this view's CONNECTING branch — the spinner + "Connecting to
/// your vehicles…" the client screenshotted. That state is not an end state, so
/// it now renders `OwnerHomeLoadingSkeleton`; what is left here is only the
/// honest "and it isn't coming" case, which keeps its calm one-liner.
private struct FleetConnectingView: View {
    let message: String?

    var body: some View {
        ZStack {
            Color.mrtBg.ignoresSafeArea()
            VStack(spacing: 12) {
                if let message {
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
