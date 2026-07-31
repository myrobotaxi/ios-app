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
    var rideRequestService: any RideRequestService
    var historyStore: RideHistoryStore
    var riderName: String = "Sam" // screens.jsx:1857 `riderName = 'Sam'`; M1 has no tweaks panel.
    /// MYR-224 — the real signed-in rider on the LIVE path, else nil. When nil
    /// (SIM), the greeting + summary keep the fixture `riderName` ("Sam") so the
    /// sim scenes stay pixel-identical; when set, they render the real first
    /// name (or a calm generic if the account has no name).
    var liveProfile: UserProfile? = nil
    /// MYR-186 — forwarded to `RideRequestReviewContent`; see its declaration.
    var onRideRequestSubmitted: (() -> Void)? = nil

    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var isFollowing = true
    /// MYR-217: the ONE camera owner for the pin-drop phase — every programmatic
    /// camera write while the pin is up flows through it (see
    /// `PinDropCameraController`'s header for the MYR-213/215/216 recurrence it
    /// closes). Owned here (not in `VehicleMapView`, a per-render struct) so the
    /// state machine survives view updates, and passed unconditionally so the
    /// map can release it when the phase exits.
    @State private var pinDropCamera = PinDropCameraController()
    /// MYR-220: a calm session/connection-failure notice — shown when a live
    /// create POST's auth died mid-send (401 / auth-shaped 403), NOT an owner
    /// decline. Reuses the shared bottom pill (`mrtSuccessToast`) with a muted
    /// tone; the rider is already returned to a retryable state with the draft
    /// intact by `handleSessionFailure()`.
    @State private var showSessionErrorToast = false
    /// MYR-233: a calm "car is busy" notice — shown when a live create/accept was
    /// refused `409 vehicle_unavailable`. Not a decline (nobody refused the
    /// rider) and not a session failure; the rider is already returned to Review
    /// with the draft intact by `handleVehicleUnavailable()`, where the CTA now
    /// routes to scheduling.
    @State private var showVehicleUnavailableToast = false
    /// MYR-316 — a scheduled request was refused because the pickup precedes the
    /// vehicle's estimated return from service. Raised by
    /// `handleScheduleWindowFailure()`, which lands the rider back on Search with
    /// the schedule picker OPEN and re-floored, so the correction is the very next
    /// thing they touch.
    @State private var showScheduleWindowToast = false
    /// MYR-271 — the tracking sheet's settled visible height, reported by
    /// `RiderTrackingSheet` on every settle. The recenter button + the tracking map
    /// camera inset re-anchor ABOVE this so both clear the card in every detent.
    @State private var trackingSettledHeight: CGFloat = MRTMetrics.trackingMapBottomInset
    /// MYR-327 — the expanded, user-driven route viewer over the live tracking
    /// map. The tracking map is pannable in place, but the sheet covers ~312pt of
    /// it; this is where the rider can actually "zoom in and out to look at" the
    /// whole trip. Only reachable from the tracking phase.
    @State private var showsExpandedRoute = false
    /// MYR-352 — the availability banner's own measured height, reported by
    /// `RiderIdleAvailabilityBannerView` through `RiderIdleBannerHeightKey`. `0`
    /// whenever no banner is up, which is every simulated boot and every
    /// pre-existing DEBUG scene. The same precedent as `trackingSettledHeight`
    /// directly above: a live-only element that reports what it measures so the
    /// chrome around it can reserve exactly that much.
    @State private var idleBannerHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            // MYR-213: ONE source of truth for the pin-drop glyph's screen point.
            // `glyphLocal` positions the glyph (in this safe-area GeometryReader,
            // unchanged from the original so the sim scene is pixel-identical);
            // `glyphGlobal` is the SAME point projected into the global space and
            // handed to `VehicleMapView`, which converts it to the coordinate MapKit
            // renders there. Deriving both from `glyphLocal` means the drawn glyph
            // and the confirmed pickup can never desync.
            let glyphLocal = VehicleMapView.pinGlyphPoint(in: geo.size)
            let glyphGlobal = CGPoint(
                x: geo.frame(in: .global).minX + glyphLocal.x,
                y: geo.frame(in: .global).minY + glyphLocal.y
            )
            ZStack {
                backgroundMap(glyphGlobalPoint: glyphGlobal, viewportSize: geo.size)
                    .ignoresSafeArea()

                sheetContent(totalHeight: geo.size.height)
                    .animation(
                        reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.42), // ride-request.jsx:1185
                        value: viewerState.sheetPhase
                    )

                if isPinDrop {
                    // MYR-211: live pin label is the reverse-geocoded device
                    // location; sim keeps the fixture "Folsom & 2nd St". Drawn at
                    // `glyphLocal` — the exact original position — and `VehicleMapView`
                    // reads the coordinate under this same point (via `glyphGlobal`).
                    RidePinDropMapOverlay(label: viewerState.pinDropLabel)
                        .position(glyphLocal)
                }

                // MYR-223 deliverable 3 — rider recenter (client-approved design
                // addition). REUSES the owner map's `FloatingMapButton` + styling
                // verbatim (HomeScreen.swift:144-150). Hidden while following;
                // appears once follow-mode stops — i.e. after the rider's first
                // pan/pinch, which `VehicleMapView.handleUserGesture` reports by
                // flipping `isFollowing` false (MYR-222). Only on the resting IDLE
                // map — never during pin-drop, which owns its camera through
                // `PinDropCameraController` (recenter there is out of scope).
                if isIdle {
                    FloatingMapButton(
                        // Mirror the owner placement metric `peekH + 80`
                        // (screens.jsx:424, `MRTMetrics.mapButtonBottomGap`): float
                        // the button one gap above the phase's bottom chrome (the
                        // idle greeting sheet, or the shorter pending pill).
                        bottom: mapBottomInset + MRTMetrics.mapButtonBottomGap,
                        hidden: isFollowing
                    ) {
                        // Recenter on the current fix + resume follow. Setting
                        // `isFollowing = true` drives `VehicleMapView`'s
                        // `.onChange(of: isFollowing)` recenter, which registers
                        // its OWN settle expectation in the `CameraSettleLedger`
                        // (MYR-222) — so this programmatic recenter is classified
                        // as ours, never misread as a gesture, and it re-engages
                        // follow cleanly (subsequent fixes recenter until the
                        // rider pans again, which stands follow down once more).
                        isFollowing = true
                    }
                    .ignoresSafeArea(edges: .bottom)
                }

                // MYR-177: the SAME recenter affordance on the live tracking map —
                // appears once the rider pans/pinches away (follow off) and
                // re-engages the leg-fit camera (`TrackingMapView`'s
                // `.onChange(of: isFollowing)` → `TrackingCameraController.recenter`).
                if isTrackingPhase {
                    FloatingMapButton(
                        // MYR-271: re-anchor above the sheet's SETTLED top (recomputed
                        // from the settled detent height) so it clears the card in
                        // every detent — no longer a fixed offset that overlapped it.
                        bottom: trackingSettledHeight + MRTMetrics.trackingRecenterSheetGap,
                        hidden: isFollowing
                    ) {
                        isFollowing = true
                    }
                    .ignoresSafeArea(edges: .bottom)

                    // MYR-327 — the visible half of "click into the map". The map
                    // tap works anywhere, but nothing said so; this chip sits one
                    // button-stack above the recenter control (which is itself
                    // conditional), always available while tracking.
                    ExpandRouteButton { showsExpandedRoute = true }
                        .padding(.trailing, 16)
                        .padding(.bottom, trackingSettledHeight + MRTMetrics.trackingRecenterSheetGap + MRTMetrics.trackingExpandButtonStackGap)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(Color.mrtBg)
        .overlay(alignment: .bottom) {
            if isSearch, viewerState.showDeclinedNotice {
                DeclinedNoticeCard(
                    requesterName: declinedRequesterName,
                    // MYR-381 — both answers ACKNOWLEDGE the ride, not just the
                    // card. Before this, Dismiss reset the draft (which the
                    // declined RECORD does not live in) and Rebook lowered a flag,
                    // so the very next reconcile put the card back — the client's
                    // *"I already dismissed the declined ride"*.
                    onDismiss: {
                        viewerState.acknowledgeDeclined(rideID: rideRequestService.activeRequest?.id)
                        viewerState.resetDraftToIdle()
                    },
                    onRebook: {
                        viewerState.acknowledgeDeclined(rideID: rideRequestService.activeRequest?.id)
                    }
                )
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.3), // ride-request.jsx:1053 `mrt-sched-up`
            value: viewerState.showDeclinedNotice
        )
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs, hidden: hideBottomNav)
        // MYR-327 — the expanded route viewer, above every rider chrome layer
        // (nav included). A plain overlay rather than a `fullScreenCover` so the
        // open/close carries the app's own motion grammar (Handoff §8 sheet snap;
        // cross-fade under Reduce Motion) instead of the system modal slide.
        //
        // MYR-334: the animation is scoped to the OVERLAY, not hung off the
        // whole rider screen. Attached outside, a `.animation(_:value:)` re-times
        // every animatable difference the same transaction produces anywhere in
        // this subtree — the detent sheet, the bottom nav, the declined notice —
        // whenever the map is expanded. Inside, the cross-fade owns exactly the
        // layer it belongs to.
        .overlay {
            ZStack {
                if showsExpandedRoute, isTrackingPhase {
                    expandedTrackingRouteViewer
                        .transition(.mrtRouteExpand(reduceMotion: reduceMotion))
                }
            }
            .animation(.mrtRouteExpand(reduceMotion: reduceMotion), value: showsExpandedRoute)
        }
        .onChange(of: isTrackingPhase) { _, tracking in
            // Leaving tracking (drop-off → summary, a decline, …) closes the
            // viewer: its content is the live ride, so it must not outlive it.
            if !tracking { showsExpandedRoute = false }
        }
        .onAppear {
            viewerState.startTelemetry()
            // MYR-230 deliverable 1: reconcile the CURRENT active ride into the
            // sheet phase on mount. The `.onChange` handlers below only fire for
            // transitions that happen WHILE this screen is mounted, so an owner
            // accept/decline (the client-reported bug: request → switch to Owner →
            // accept → switch back to Rider, landing on the idle greeting instead
            // of tracking) or a cold-launch adoption (deliverable 2) is otherwise
            // never reflected. Fold the current status + progress through the same
            // mapping, idempotently and without animating the first layout.
            reconcileMountedPhase()
            // MYR-177: if we mounted straight into tracking (cold scene / adopted
            // ride), prime the route cache so the leg-fit map has real geometry.
            if isTrackingPhase { isFollowing = true; reconcileTrackingRoutes() }
            #if DEBUG
            // MYR-327 drift-gate capture hook: headless tooling cannot tap the map.
            if isTrackingPhase, DebugScene.opensExpandedRouteMap { showsExpandedRoute = true }
            #endif
            // MYR-237: mounted into Review/Booking (DEBUG scene / retryable
            // session-failure return) — prime the real Apple route to draw/etch.
            reconcileReviewRoute()
            #if DEBUG
            // MYR-217 real-path probe: replay the ACTUAL idle → search →
            // choose+Continue → pinDrop sequence (with live updates flowing)
            // through the same state methods the taps call — the entry
            // interleaving the cold `pinDrop` scene can never exercise.
            if DebugScene.current?.replaysRealPinDropPath == true {
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    viewerState.sheetPhase = .search
                    try? await Task.sleep(for: .seconds(3))
                    viewerState.chooseDestination(DebugScene.realPathDestination)
                    viewerState.proceedFromSearch()
                    // MYR-248: continue the real path through the pin-drop
                    // back-nav ("Change trip" → search) so the returned search
                    // sheet's geometry can be captured headless.
                    if DebugScene.current?.replaysPinDropBackNav == true {
                        try? await Task.sleep(for: .seconds(3))
                        viewerState.returnFromPinDropToSearch()
                    }
                }
            }
            #endif
        }
        .onChange(of: isPinDrop) { _, entering in
            // MYR-212 defect 2: force a fresh device fix + re-seed the pin when
            // the pin-drop phase mounts (no-op in sim).
            if entering { viewerState.enterPinDrop() }
        }
        // MYR-341: re-seat the pickup-ETA anchors on this screen's appearance
        // and whenever either RAW endpoint changes. The anchors themselves only
        // move on a material (>250m) step, so a ~1Hz device fix writes nothing
        // and the placeholder's number holds still across its 2800ms rotation.
        .onChange(of: viewerState.pickupETAFixKey, initial: true) { _, _ in
            viewerState.refreshPickupETAAnchors()
        }
        .onChange(of: rideRequestService.activeRequest?.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
        // MYR-381 — THE SLOT RELEASING IS ALSO A TERMINAL TRANSITION, and it is the
        // one with no status to observe: `LiveRideRequestService.integrate` maps
        // the wire's `cancelled` to NO app status and sets `activeRequest` to nil,
        // so "cancelled" reaches this screen only as the record DISAPPEARING (the
        // same erasure MYR-172's Live Activity had to be written around). A
        // status-only observer sees `nil == nil` and never fires, which is how the
        // client's cancelled reservation left its 1,000-mile etch on the map.
        .onChange(of: rideRequestService.activeRequest?.id, releaseRouteIfSlotEmpty)
        .onChange(of: rideRequestService.activeRequest?.trackProgress) { _, progress in
            handleProgressChange(progress)
            // MYR-177: as the ride advances, keep the route cache reconciled
            // (leg flip fetches leg 1 / draws leg 2 solid). The store no-ops
            // unless the pair/car-origin actually changed — no per-fix network.
            reconcileTrackingRoutes()
        }
        .onChange(of: viewerState.sheetPhase) { oldPhase, newPhase in
            // MYR-177: manage the tracking leg-fit camera + route cache lifecycle
            // around the phase. Entering tracking: reset follow so the leg fit
            // engages cleanly and prime the routes. Leaving: release the single
            // owner + drop the cache so the next ride starts fresh.
            if newPhase == .tracking {
                isFollowing = true
                reconcileTrackingRoutes()
            } else if oldPhase == .tracking {
                viewerState.trackingCamera.exit()
                viewerState.rideRouteStore.reset()
            }
            // MYR-237: entering Review/Booking — fetch the real Apple route so it
            // draws (and, on Review, etches) instead of the straight placeholder.
            if newPhase == .review || newPhase == .booking {
                reconcileReviewRoute()
            }
        }
        .task(id: routePreviewActive) {
            // MYR-237: while the route preview is up without a REAL road route
            // (MKDirections throttled/failed — the client hit a locked straight
            // line), keep re-asking on the store's cooldown until one lands.
            // The store no-ops these once a real route is cached.
            while !Task.isCancelled, routePreviewActive {
                if let draft = viewerState.draftDestination, RidePlaceMapper.isUnresolved(draft),
                   rideRequestService.activeRequest == nil {
                    // The destination's REAL coordinate is still missing — that
                    // resolution is the thing to retry (the route fetch stays
                    // gated until it lands).
                    viewerState.retryDestinationResolutionIfNeeded()
                } else if (reviewRealRoute?.count ?? 0) <= 2 {
                    reconcileReviewRoute(prefetch: true)
                }
                try? await Task.sleep(for: .seconds(6))
            }
        }
        .onChange(of: viewerState.rideRouteStore.leg2.count) { _, n in
            #if DEBUG
            print("ETCH \(Date().timeIntervalSince1970) leg2-arrived points=\(n) phase=\(viewerState.sheetPhase)")
            #endif
        }
        .onChange(of: viewerState.draftDestination) { _, destination in
            #if DEBUG
            print("ETCH \(Date().timeIntervalSince1970) draftDestination-changed resolved=\(destination.map { !RidePlaceMapper.isUnresolved($0) } ?? false)")
            #endif

            // MYR-237: PREFETCH the real route the moment a destination is
            // chosen in Search (before "Continue"), so the etch usually starts
            // the instant Review opens instead of after a visible MKDirections
            // wait (client: "the animation starts after a few seconds"). The
            // leg-2 cache is keyed per pickup/destination pair, so this is a
            // no-op if Review re-requests the same pair.
            if destination != nil {
                reconcileReviewRoute(prefetch: true)
            }
        }
        .onChange(of: rideRequestService.sessionFailure) { _, failure in
            // MYR-220: an auth/session failure of the create POST is NOT an owner
            // decline — never let it drive `DeclinedNotice`. Return the rider to a
            // retryable state (draft intact) and raise the calm retry notice.
            if failure != nil { handleSessionFailure() }
        }
        .onChange(of: rideRequestService.vehicleUnavailableFailure) { _, failure in
            // MYR-233: `409 vehicle_unavailable` is NOT an owner decline — never
            // let it drive `DeclinedNotice`. Return the rider to Review (draft
            // intact) where the CTA now routes to scheduling, and raise the calm
            // notice. No retry is attempted anywhere on this path.
            if failure != nil { handleVehicleUnavailable() }
        }
        .onChange(of: rideRequestService.scheduleWindowFailure) { _, failure in
            // MYR-316: a `400 invalid_request` on a SCHEDULED ride is NOT an owner
            // decline — never let it drive `DeclinedNotice`. Send the rider back to
            // the schedule picker (draft intact), which re-derives its floor from
            // the fleet row and will now dim the slot they picked.
            if failure != nil { handleScheduleWindowFailure() }
        }
        // MYR-233 own-ride exception (criterion 4): mirror "this rider holds an
        // open ride" onto the viewer state, which folds it into `liveFleetMember`
        // so the rider carrying the ride never sees their own car as Busy. Seeded
        // on appear and kept in sync as the ride's status advances.
        .onAppear { syncRiderOwnsActiveRide() }
        .onChange(of: rideRequestService.activeRequest?.status) { _, _ in
            syncRiderOwnsActiveRide()
        }
        .mrtSuccessToast(
            isPresented: $showVehicleUnavailableToast,
            // Honest and specific: name the real reason (the car, not the owner)
            // and the way forward. Muted tone — this is not an error the rider
            // caused, and not a refusal.
            message: "That car just became unavailable. Your trip’s saved — try scheduling it.",
            systemImage: "calendar",
            tint: .mrtTextMuted
        )
        .mrtSuccessToast(
            isPresented: $showScheduleWindowToast,
            // Honest and specific about WHAT is wrong (the time, not the rider,
            // not the owner) without quoting the server's sentence — the picker
            // itself now shows which slots are reachable, which is more useful
            // than a number in a toast. Muted: nothing failed, a time moved.
            message: "That pickup is before the car is back from service. Pick a later time.",
            systemImage: "calendar",
            tint: .mrtTextMuted
        )
        .mrtSuccessToast(
            isPresented: $showSessionErrorToast,
            // Calm, non-alarming copy (design minimalism — cf. the "can't reach"
            // fleet placeholder): the trip is preserved and retryable once the
            // session is back. No "declined", no vehicle/owner name.
            message: "Couldn’t reach your session. Your trip’s saved — try again.",
            systemImage: "arrow.clockwise",
            tint: .mrtTextMuted
        )
    }

    // MARK: Phase content (MYR-171)

    /// MYR-236 round 4: the greeting card + search sheet ride the ONE `PanSheet`
    /// engine (continuous idle↔search drag). The pending pill (an active request,
    /// not a search starting point) keeps the old fixed idle sheet.
    private var usesIdleSearchEngine: Bool {
        switch viewerState.sheetPhase {
        case .search: return true
        case .idle: return !isPendingPill
        default: return false
        }
    }

    /// MYR-352 — the idle card's height: the prototype's `sharedIdleSheetHeight`
    /// PLUS exactly what the availability banner measures, and the constant itself
    /// whenever there is no banner.
    ///
    /// It stays a FIXED frame rather than becoming a `minHeight` floor, and that is
    /// load-bearing rather than stylistic: the card ends in a greedy `Spacer`, so a
    /// floor lets it absorb whatever the engine proposes — which stretched the
    /// sheet's own gradient wash and drifted `riderWatchOnly`, a scene that had
    /// been byte-stable across runs, by ~913k pixels. A fixed height computed from
    /// the banner's measurement keeps every bannerless state at exactly 286 and
    /// therefore byte-identical.
    ///
    /// The three consumers — the card's frame, the engine's idle detent, and
    /// MapKit's attribution inset — all read THIS, so the card, the sheet the
    /// engine draws and the band the map keeps clear can never disagree.
    private var resolvedIdleSheetHeight: CGFloat {
        guard idleBannerHeight > 0 else { return MRTMetrics.sharedIdleSheetHeight }
        return MRTMetrics.sharedIdleSheetHeight + idleBannerHeight + MRTMetrics.riderIdleBannerGap
    }

    private var riderIdleSearchSheet: some View {
        RiderIdleSearchSheet(
            viewerState: viewerState,
            // MYR-352 — the detent follows the banner's own reserve, so the
            // engine draws the sheet at exactly the height the card is. The
            // constant verbatim whenever no banner is up.
            idleHeight: resolvedIdleSheetHeight,
            idleContent: { idleGreetingCardHosted },
            searchContent: { RideRequestSearchContent(viewerState: viewerState, hosted: true) }
        )
    }

    @ViewBuilder
    private func sheetContent(totalHeight: CGFloat) -> some View {
        if usesIdleSearchEngine {
            // ONE persistent engine identity across the idle↔search drag so the
            // surface/gesture aren't torn down mid-transition.
            riderIdleSearchSheet
        } else {
            switch viewerState.sheetPhase {
            case .idle:
                idleSheet // pending pill only — greeting rides the engine above
            case .search:
                EmptyView() // unreachable: search always rides the engine
            case .pinDrop(let returnTo):
                RideRequestPinDropContent(viewerState: viewerState, returnTo: returnTo, totalHeight: totalHeight)
            case .review:
                // MYR-312 — the real identity travels into the submitted draft as
                // its `requesterName`, so the owner's incoming card names the
                // requester from the first frame (scheduled requests return
                // straight to idle, so the owner tab is reachable before the
                // deferred create POST + WS refetch could supply it).
                RideRequestReviewContent(
                    viewerState: viewerState,
                    rideRequestService: rideRequestService,
                    totalHeight: totalHeight,
                    liveProfile: liveProfile,
                    onRideRequestSubmitted: onRideRequestSubmitted
                )
            case .booking:
                RideRequestBookingContent(viewerState: viewerState, rideRequestService: rideRequestService, totalHeight: totalHeight)
            case .tracking:
                // MYR-271: the tracking card rides the shared PanSheet engine (drag +
                // fluid chrome), reporting its settled height back for the recenter /
                // map-inset re-anchor. The two-leg map/camera behind it are unchanged.
                RiderTrackingSheet(settledHeight: $trackingSettledHeight) {
                    RideRequestTrackingContent(
                        viewerState: viewerState,
                        rideRequestService: rideRequestService,
                        totalHeight: totalHeight,
                        hosted: true,
                        navMinutesToArrival: viewerState.riderNavMinutesToArrival
                    )
                }
            case .summary:
                RideRequestSummaryContent(viewerState: viewerState, rideRequestService: rideRequestService, historyStore: historyStore, riderName: riderName, liveProfile: liveProfile)
            }
        }
    }

    private var isPinDrop: Bool {
        if case .pinDrop = viewerState.sheetPhase { return true }
        return false
    }

    private var isSearch: Bool {
        if case .search = viewerState.sheetPhase { return true }
        return false
    }

    /// MYR-223 d3 — the resting idle map (greeting or pending pill). The only
    /// phase the rider recenter button shows on (the map is visible + pannable;
    /// the search/pin-drop/route sheets cover it, and pin-drop owns its camera).
    private var isIdle: Bool {
        viewerState.sheetPhase == .idle
    }

    /// MYR-198 client ruling (overrides screens.jsx:2239's idle/tracking
    /// z-index split — the design jsx keeps `BottomNav` visible under both
    /// `.idle` and `.tracking`): within the rider flow `BottomNav` shows on
    /// **idle only**. Client QA round 3 screenshots showed the nav painting
    /// OVER tracking-sheet content (including the "arriving" takeover) —
    /// the design's own two-phase visibility wasn't reliably clearing the
    /// sheet's content underneath, so the ruling collapses it to a single
    /// rule: hidden everywhere except idle. See the MYR-198 PR body for the
    /// before/after evidence.
    private var hideBottomNav: Bool {
        viewerState.sheetPhase != .idle
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

    /// MYR-237 (client): the route preview renders on SEARCH too, the moment
    /// both endpoints are known — "when I put in the route it should
    /// automatically display the route polyline in the same way the following
    /// page would". Hoisted ABOVE the phase switch so search-preview → Review →
    /// Booking is ONE view identity: the etch plays once (at destination
    /// selection), then persists as the breathing glow through "Continue"
    /// instead of replaying per phase.
    private var routePreviewActive: Bool {
        switch viewerState.sheetPhase {
        case .review, .booking: return true
        case .search: return draftRouteEndpointsKnown
        default: return false
        }
    }

    /// Both preview endpoints resolvable while still on Search (a destination
    /// has been chosen). "Current location" pickup has NO draft — it resolves
    /// from the live fix, so the fix coordinate is the pickup fallback here
    /// (same coordinate the request would materialize at Continue).
    ///
    /// MYR-381 — through `liveRouteRequest`, so a TERMINAL record cannot supply the
    /// destination that raises this preview. That is the whole of the stale-etch
    /// defect: the draft was cleared and the declined ride answered in its place.
    ///
    /// MYR-389 — and through `previewRouteRequest`, so on SEARCH no record supplies
    /// it at all, live or not. Both narrowings are about the same sentence read one
    /// clause further: a route belongs to a ride that is happening AND to the
    /// surface that ride is on.
    private var draftRouteEndpointsKnown: Bool {
        searchPreviewPickup != nil
            && (previewRouteRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate) != nil
    }

    /// The route preview map's `loading` input: true while the real road route
    /// (or the destination's real coordinate) is still being resolved.
    private var reviewPreviewLoading: Bool {
        if let draft = viewerState.draftDestination, RidePlaceMapper.isUnresolved(draft),
           rideRequestService.activeRequest == nil {
            return true
        }
        return reviewRouteLoading
    }

    /// The preview's pickup coordinate: explicit request/draft pickup, else
    /// the live "Current location" fix.
    private var searchPreviewPickup: CLLocationCoordinate2D? {
        previewRouteRequest?.input.pickup.coordinate
            ?? viewerState.draftPickup?.coordinate
            // The ANCHOR, never the live fix: GPS jitter must not re-key the
            // route (MYR-237 device trace — the collapse/refetch loop).
            ?? viewerState.previewPickupAnchor
    }

    @ViewBuilder
    private func backgroundMap(glyphGlobalPoint: CGPoint, viewportSize: CGSize) -> some View {
        if routePreviewActive {
            // MYR-216 d4 / MYR-223 d2 / MYR-237 — see the .review case notes
            // below (this is that same map, now also serving Search's preview).
            RideRequestRouteMap(
                route: reviewRoute,
                // Search's own inset is the EXPANDED 712pt search sheet
                // (SHEET_HEIGHTS.search) — the destination-selected state that
                // hosts this preview renders the compact sheet (~review-sized),
                // so the preview fits with the REVIEW inset in both phases
                // (also keeps the framing continuous through "Continue").
                bottomInset: viewerState.sheetPhase == .search
                    ? Self.mapBottomInset(phase: .review, isPendingPill: false)
                    : mapBottomInset,
                etch: viewerState.sheetPhase != .booking,
                loading: viewerState.sheetPhase != .booking && reviewPreviewLoading,
                replayKey: String(describing: viewerState.sheetPhase)
            )
        } else {
            backgroundMapByPhase(glyphGlobalPoint: glyphGlobalPoint, viewportSize: viewportSize)
        }
    }

    @ViewBuilder
    private func backgroundMapByPhase(glyphGlobalPoint: CGPoint, viewportSize: CGSize) -> some View {
        switch viewerState.sheetPhase {
        case .idle, .search, .pinDrop:
            VehicleMapView(
                // MYR-184 — the REAL shared vehicle on the live path (adopted from
                // the first `role: viewer` row) and the fixture in sim. `mapVehicle`
                // degrades to a CONTENTLESS placeholder, never a fixture car, for the
                // window in which the shell has not yet swapped to its empty state.
                vehicle: viewerState.mapVehicle,
                snapshot: viewerState.snapshot,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing,
                showRoute: false, // MYR-197: no route/trip line on the rider's idle map before a ride is booked — see VehicleMapView.showRoute's header comment
                showVehicle: false, // MYR-198 client ruling: no vehicle marker/label pre-acceptance — see VehicleMapView.showVehicle's header comment
                // MYR-199/211: pin the camera on the rider's region — the live
                // device location first, live-vehicle region as fallback,
                // fixture `DriveFixtures.home` only in sim (see
                // `SharedViewerState.mapRegionCenter`). Not the watched
                // vehicle's simulated driving route — see
                // VehicleMapView.centerOverride's header comment.
                centerOverride: viewerState.mapRegionCenter,
                // MYR-211 addendum: standard user-location dot in live mode
                // (authorized only); off in sim so screenshots stay identical.
                showsUserLocation: viewerState.userLocation.showsUserLocationDot,
                bottomContentInset: vehicleMapBottomInset,
                // MYR-213: during pin-drop, adopt the coordinate UNDER THE GLYPH
                // (ground-truthed via `MapProxy.convert` of the glyph's real global
                // screen point) as the authoritative pickup — only then (no geocoding
                // churn on the idle/search map, and a no-op in sim). The glyph itself
                // is drawn in `body` at the local twin of this point.
                pinDrop: isPinDrop
                    ? PinDropOverlay(
                        glyphGlobalPoint: glyphGlobalPoint,
                        onCoordinate: { viewerState.pinDropCameraSettled(at: $0) },
                        // MYR-216 d3: the blue-dot fix to seat under the glyph on
                        // entry — the live device coordinate (nil in sim / no fix).
                        entryFix: viewerState.userLocation.coordinate,
                        // MYR-217: feeds the owner's analytic entry framing.
                        viewportSize: viewportSize
                    )
                    : nil,
                // MYR-217: the single pin-drop camera owner (passed even outside
                // pin-drop so the map can release it on phase exit). During
                // pin-drop it writes the street span (~440m) with the fix under
                // the glyph — the MYR-213/215 client-approved street-level entry,
                // now issued by exactly one writer in both live and sim.
                pinDropCamera: pinDropCamera,
                // Non-pin-drop framing span (idle/search overview). During
                // pin-drop the legacy recenter is gated off entirely, so the
                // street-vs-overview choice (`mapSpanDelta`, MYR-215) is kept
                // only as the documented product constant pair.
                regionSpanDelta: pinDropRegionSpanDelta
            )
        case .review, .booking:
            // Unreachable: `routePreviewActive` intercepts Review/Booking (and
            // Search once endpoints are known) above, so the route-preview map
            // keeps ONE identity across those phases (MYR-237 — the etch plays
            // once and the glow persists through "Continue").
            EmptyView()
        case .tracking:
            // MYR-177: the LIVE leg-fit tracking map (replaces the old static
            // straight-line preview). Frames car→pickup (leg 1) / pickup→
            // destination (leg 2) with real routes + an Uber-style heading marker,
            // all through the single camera owner.
            TrackingMapView(
                leg: trackingLeg,
                leg1Route: trackingLeg1Route,
                leg2Route: trackingLeg2Route,
                carCoordinate: trackingCarPosition.coordinate,
                carHeading: trackingCarPosition.headingDegrees,
                legProgress: trackingLegProgress,
                // MYR-271: track the sheet's settled detent height so the leg-fit
                // camera fills the true visible band above the (now draggable) card.
                bottomInset: trackingSettledHeight,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing,
                controller: viewerState.trackingCamera,
                showsUserLocation: viewerState.userLocation.showsUserLocationDot,
                // MYR-327 — tap anywhere on the map to open the expanded viewer.
                onExpand: { showsExpandedRoute = true }
            )
        case .summary:
            // Summary is a full-screen takeover (its own hero-map layout), not a
            // peek above a bottom sheet — no inset (MYR-216 d4).
            RideRequestRouteMap(route: requestRoute)
        }
    }

    // MARK: MYR-223 deliverable 2 — per-phase map bottom inset (ONE source of truth)
    //
    // The map's bottom inset feeds `.safeAreaPadding(.bottom:)`, which keeps
    // MapKit's legally-required attribution/legal label clear of the bottom
    // chrome (MYR-196 #2). The pre-MYR-223 `mapBottomInset` collapsed every
    // non-search/pin-drop phase to the FIXED tall greeting-sheet height (286) —
    // so when the idle sheet shrank to the short "Request sent" pending pill, the
    // attribution stayed insetted 286pt up and floated at mid-page (the client's
    // on-device screenshot). The fix: the inset tracks the ACTUAL bottom chrome
    // height PER PHASE, from one pure table used by BOTH the idle/search/pin-drop
    // `VehicleMapView` (its `bottomContentInset`) and the route-fitted phases'
    // `RideRequestRouteMap` (its attribution inset) — so the attribution sits
    // just above the real chrome on every phase.

    /// The phase→bottom-chrome-inset table (pure + static so it's unit-testable
    /// without mounting the view — `PerPhaseMapInsetTests`). `isPendingPill`
    /// distinguishes the two idle states (tall greeting sheet vs. short pending
    /// pill). Summary is a full-screen takeover with no bottom sheet → 0.
    ///
    /// MYR-352 — `idleSheetHeight` is the engine's RESOLVED idle detent, which
    /// equals `sharedIdleSheetHeight` in every state that carries no availability
    /// banner (i.e. every simulated boot and every pre-existing DEBUG scene, which
    /// is why it defaults to exactly that and no existing caller or test changes).
    /// A banner makes the card taller, and MapKit's legally-required attribution
    /// has to clear the card that is actually on screen rather than the constant
    /// one — the MYR-223 rule, unchanged: the inset tracks the ACTUAL bottom
    /// chrome height per phase.
    static func mapBottomInset(
        phase: RiderSheetPhase,
        isPendingPill: Bool,
        idleSheetHeight: CGFloat = MRTMetrics.sharedIdleSheetHeight
    ) -> CGFloat {
        switch phase {
        case .idle:
            return isPendingPill ? MRTMetrics.sharedPendingPillSheetHeight : idleSheetHeight
        case .search:
            return MRTMetrics.rideRequestSearchSheetHeight
        case .pinDrop:
            return MRTMetrics.rideRequestPinDropMapInset
        case .review, .booking:
            return MRTMetrics.rideRequestRouteMapBottomInset
        case .tracking:
            // MYR-177: the tracking sheet is shorter than Review/Booking — its
            // own real cover height so the leg-fit map fills the visible band.
            return MRTMetrics.trackingMapBottomInset
        case .summary:
            return 0
        }
    }

    private var mapBottomInset: CGFloat {
        Self.mapBottomInset(
            phase: viewerState.sheetPhase,
            isPendingPill: isPendingPill,
            idleSheetHeight: resolvedIdleSheetHeight // MYR-352
        )
    }

    /// MYR-250 item 1 — the `VehicleMapView` (idle/search/pin-drop) camera inset.
    /// SEARCH shares the IDLE inset so opening the search sheet slides OVER a
    /// STATIONARY map (the Apple Maps model the client asked for) instead of
    /// recentering the camera up: `mapBottomInset` reports the full 712pt search
    /// sheet height for search, and MapKit's `.safeAreaPadding(.bottom:)` shifts
    /// the framed center up by that jump the instant idle→search commits — the
    /// map "moving up with the sheet". Keeping the idle inset leaves the camera
    /// exactly where it was; the taller sheet simply covers more of the same map,
    /// and the location dot gets covered just as Apple Maps' does. Pin-drop keeps
    /// its own inset (a legitimate street-level refit — MYR-213/215). Once a
    /// destination is chosen the map switches to the route-preview
    /// (`routePreviewActive`, above), which intentionally refits to show the
    /// route, so this only governs the empty idle↔search framing.
    private var vehicleMapBottomInset: CGFloat {
        Self.vehicleMapBottomInset(
            phase: viewerState.sheetPhase,
            isPendingPill: isPendingPill,
            idleSheetHeight: resolvedIdleSheetHeight // MYR-352
        )
    }

    /// Pure (testable) — the idle/search/pin-drop `VehicleMapView` camera inset.
    /// SEARCH returns the IDLE inset so idle→search never recenters the camera
    /// (item 1); every other phase keeps its own `mapBottomInset`. Extracted
    /// static so the "search shares idle framing" invariant is unit-testable
    /// without mounting the view (`PerPhaseMapInsetTests`).
    static func vehicleMapBottomInset(
        phase: RiderSheetPhase,
        isPendingPill: Bool,
        idleSheetHeight: CGFloat = MRTMetrics.sharedIdleSheetHeight
    ) -> CGFloat {
        if case .search = phase {
            return mapBottomInset(phase: .idle, isPendingPill: false, idleSheetHeight: idleSheetHeight)
        }
        return mapBottomInset(phase: phase, isPendingPill: isPendingPill, idleSheetHeight: idleSheetHeight)
    }

    /// The map camera span for the shared idle/search/pin-drop map: pin-drop
    /// opens street-level (a few blocks) so the rider confirms an exact spot;
    /// every other phase keeps the neighborhood overview.
    ///
    /// MYR-215 CLIENT-APPROVED DEVIATION (waives the sim pixel-identity gate for
    /// pin-drop zoom ONLY): pin-drop is now street-level in BOTH live and sim.
    /// MYR-213 had gated the street span on `isLiveLocation` to keep the sim
    /// scene pixel-identical to the prototype's miles-wide pin-drop; the client
    /// overrode that — "if the prototype is showing it zoomed out, who cares; we
    /// should be doing what's best for the end user." A rider confirming an exact
    /// pickup needs a few-blocks view in every mode. The sim pin-drop scene's
    /// ZOOM legitimately changes as a result (fixture region center, street span);
    /// its pin, label, and sheet content are otherwise identical, and every other
    /// sim scene stays pixel-identical. See the MYR-215 PR body for the sanctioned
    /// before/after.
    private var pinDropRegionSpanDelta: Double {
        Self.mapSpanDelta(isPinDrop: isPinDrop)
    }

    /// Pure span selection (MYR-215) — extracted so the both-modes rule is
    /// unit-testable without mounting the view. Deliberately takes NO
    /// `isLiveLocation` parameter: the pin-drop street span now applies in every
    /// mode (client-approved deviation), so mode simply can't influence it.
    static func mapSpanDelta(isPinDrop: Bool) -> Double {
        isPinDrop ? MRTMetrics.pinDropStreetSpanDelta : MRTMetrics.mapRegionSpanDelta
    }

    // MARK: MYR-381 — NO ROUTE WITHOUT A LIVE RIDE OWNING IT
    //
    // THE DEFECT. After the client's double-booked reservation was declined, his
    // rider Live Map kept the dead ride's leg etched across four states — a
    // 1,000-mile Illinois → Dallas polyline behind the idle sheet, and again
    // behind the search sheet under the declined card. *"Why is there some old
    // route rendering in the background? It's creating a glitching experience."*
    //
    // THE CAUSE is one line of reach: every endpoint below took
    // `rideRequestService.activeRequest` WITHOUT asking whether that ride is still
    // happening. A `.declined` record stays in the rider's slot on purpose (the
    // notice is built from it), so `routePreviewActive`'s
    // `draftRouteEndpointsKnown` kept resolving a destination from a ride nobody
    // was taking — the draft had been cleared and it made no difference, because
    // the RECORD was answering. `resetDraftToIdle()` could not have fixed it;
    // there was nothing left in the draft to reset.
    //
    // THE RULE, and it is structural rather than a cleanup: a route may only be
    // drawn from a ride that is LIVE. `liveRouteRequest` is the ONE accessor every
    // route-endpoint site reads, and it is `nil` for both terminal statuses, so a
    // new surface cannot reach past it to a dead ride. The store is reset on the
    // transition itself (`handleStatusChange`) so the cached geometry goes with
    // it — the overlay and the cache can never disagree about whether a ride
    // exists.
    private var liveRouteRequest: RideRequestRecord? {
        guard let request = rideRequestService.activeRequest else { return nil }
        return RiderRouteLifetime.bearsRoute(status: request.status) ? request : nil
    }

    // MARK: MYR-389 — AND A SEARCH IS NOT ABOUT ANY RIDE BUT THE ONE BEING TYPED
    //
    // MYR-381 asked "is this ride still happening?" and stopped there, which is the
    // right question for Review/Booking/Tracking: on those phases the submitted
    // record IS the trip on screen. On SEARCH it is the wrong question entirely —
    // the rider is choosing a destination, and the only trip that exists is the
    // draft they are building.
    //
    // The client's r15 clip has both halves of this. Clearing the draft on entry
    // (see `SharedViewerState.enterSearchFromIdle`) empties the field and the
    // schedule row, but a rider who has just booked a reservation still HOLDS a
    // live record — pending or accepted, both `bearsRoute` — and
    // `draftRouteEndpointsKnown` would keep resolving ITS pickup and destination.
    // The sheet would be clean and the map behind it would still be etching the
    // trip they thought they had left: "no route" only half-delivered, and the
    // more convincing half left in place.
    //
    // MYR-381's rule is untouched — a route may only be drawn from a LIVE ride —
    // and the cache is deliberately NOT dropped here, because that reservation's
    // geometry is still legitimately its own (and Tracking will want it). This
    // narrows WHICH SURFACE may read it, which is the smaller claim of the two.
    private var previewRouteRequest: RideRequestRecord? {
        Self.previewRouteRequest(phase: viewerState.sheetPhase, liveRequest: liveRouteRequest)
    }

    /// Pure, so the one phase that differs is assertable without mounting the
    /// screen (`RiderDraftLifetimeTests`) — the same reason `reconciledPhase` and
    /// `mapBottomInset` are static.
    static func previewRouteRequest(
        phase: RiderSheetPhase,
        liveRequest: RideRequestRecord?
    ) -> RideRequestRecord? {
        if case .search = phase { return nil }
        return liveRequest
    }

    /// Pickup → destination pair for the route-fitted phases — from the
    /// submitted `activeRequest` once it exists, else the still-in-progress
    /// draft (Review is reached before `submit(_:)` is ever called).
    private var requestRoute: [CLLocationCoordinate2D] {
        let pickup = searchPreviewPickup
        let destination = previewRouteRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
        guard let pickup, let destination else {
            return [DriveFixtures.financialDistrict, DriveFixtures.embarcaderoCenter]
        }
        return [pickup, destination]
    }

    // MARK: MYR-237 — real Apple Maps route for Review/Booking
    //
    // Reuses MYR-177's route service verbatim: `viewerState.rideRouteStore`
    // (`AppleRideRouteProvider` → MKDirections) already fetches the pickup →
    // destination polyline exactly once per pair via `ensureLeg2`, so Review
    // primes leg 2 early and Tracking inherits the warm cache (no extra fetch).

    /// The route drawn on Review/Booking: the REAL leg-2 road polyline once it has
    /// resolved FOR THE CURRENT pickup/destination pair, else the straight
    /// `[pickup, destination]` — the honest loading placeholder while MKDirections
    /// is in flight and the permanent fallback if it fails. The endpoint-match
    /// guard prevents a stale route (a prior trip's leg 2, still cached because the
    /// store only resets on Tracking exit) from flashing under a new trip's
    /// pickup/destination after "Change trip".
    private var reviewRoute: [CLLocationCoordinate2D] {
        if let real = reviewRealRoute { return real }
        // Destination still resolving: hand the map ONLY the pickup, so the
        // loading state frames the pickup street instead of fitting a
        // placeholder pair (device QA: a metro-wide wrong fit) and no 2-point
        // line can ever render from the placeholder.
        if let draft = viewerState.draftDestination, RidePlaceMapper.isUnresolved(draft),
           rideRequestService.activeRequest == nil,
           let pickup = searchPreviewPickup {
            return [pickup]
        }
        return requestRoute
    }

    /// The MKDirections route for the current review pickup/destination pair, or
    /// `nil` while it is still being fetched (leg 2 empty for this pair) — the
    /// skeleton-loading signal. A resolved-but-failed fetch yields the 2-point
    /// straight fallback (non-nil), so a permanent failure shows the honest static
    /// straight line, never an endless loading pulse.
    private var reviewRealRoute: [CLLocationCoordinate2D]? {
        // An UNRESOLVED destination's coordinate is a placeholder (the rider's
        // own location) — never route against it (MYR-237 device QA: it drew a
        // "random route around my pickup"). nil = the loading breathing head.
        if let draft = viewerState.draftDestination, RidePlaceMapper.isUnresolved(draft),
           rideRequestService.activeRequest == nil {
            return nil
        }
        let pickup = searchPreviewPickup
        let destination = previewRouteRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
        guard let pickup, let destination else { return nil }
        return viewerState.rideRouteStore.leg2Route(pickup: pickup, destination: destination)
    }

    /// True while the real route for the current pair has not resolved yet — drives
    /// the review map's skeleton loader so the wait feels intentional.
    private var reviewRouteLoading: Bool { reviewRealRoute == nil }

    /// Prime the pickup → destination route while on Review/Booking (no-op once the
    /// pair is cached — cheap to call on every entry). MKDirections runs in the
    /// Simulator too (the store uses `AppleRideRouteProvider` in every mode,
    /// MYR-177), so the etch draws a real road route in sim and on device alike.
    private func reconcileReviewRoute(prefetch: Bool = false) {
        guard prefetch || viewerState.sheetPhase == .review || viewerState.sheetPhase == .booking
            || viewerState.sheetPhase == .search else { return }
        // Never spend a (throttle-budgeted) MKDirections call on an unresolved
        // destination's placeholder coordinate — the resolution swap re-fires
        // this via the draftDestination onChange (MYR-237 device QA).
        if let draft = viewerState.draftDestination, RidePlaceMapper.isUnresolved(draft),
           rideRequestService.activeRequest == nil {
            return
        }
        let pickup = searchPreviewPickup
        // MYR-389 — through `previewRouteRequest` like every other endpoint site.
        // This one had never been narrowed at all (MYR-381 left it on the raw
        // record), so on SEARCH it would spend a throttle-budgeted MKDirections
        // call priming the route for a trip the rider is not looking at.
        let destination = previewRouteRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
        guard let pickup, let destination else { return }
        viewerState.rideRouteStore.ensureLeg2(pickup: pickup, destination: destination)
    }

    // MARK: MYR-177 — live tracking geometry
    //
    // The active ride's pickup/destination and the derived leg + car position.
    // Until MYR-231's two-leg dispatch statuses land, the leg is derived from
    // `trackProgress` vs the record's `pickupCut` (see `TrackingLeg`), and the
    // car position is interpolated along the active leg's real route by the
    // per-leg progress. When a rider-side live vehicle stream lands, the car
    // coordinate/heading are overridden with telemetry — the map view already
    // takes them as plain inputs, so nothing above changes.

    private var trackingPickup: CLLocationCoordinate2D { requestRoute[0] }
    private var trackingDestination: CLLocationCoordinate2D { requestRoute[1] }

    /// The origin the car started its approach from (leg 1). Live: the car's
    /// last-known coordinate (cold snapshot via the locator). Sim / no-fix: a
    /// short hop from pickup so leg 1 has a real approach to frame (~0.8 mi).
    private var trackingCarOrigin: CLLocationCoordinate2D {
        if viewerState.isLiveLocation, let live = viewerState.liveVehicleLocator?.coordinate { return live }
        return CLLocationCoordinate2D(latitude: trackingPickup.latitude + 0.0075, longitude: trackingPickup.longitude - 0.011)
    }

    private var trackingLeg: TrackingLeg {
        // MYR-265: on the LIVE path the leg follows the REAL server status — an
        // `enroute`/`completed` ride is the in-ride leg regardless of the seeded
        // anchor. Otherwise (the sim ticker, and the leg-1 `accepted` case) it
        // derives from `trackProgress` vs `pickupCut`, so the simulated
        // trackingLeg1/leg2 drift-gate scenes (status `.accepted`, progress-driven)
        // render exactly as before.
        switch rideRequestService.activeRequest?.status {
        case .enroute, .completed:
            return .inRide
        case .arrived:
            // MYR-270: the car has reached the pickup (rider picked up, awaiting the
            // Start CTA) — still the leg-1 (car→pickup) framing, at the pickup.
            return .toPickup
        default:
            return TrackingLeg.forProgress(rideRequestService.activeRequest?.trackProgress ?? 0,
                                           pickupCut: rideRequestService.activeRequest?.pickupCut ?? 0.2)
        }
    }

    /// The two leg polylines, falling back to a straight segment until the
    /// provider resolves (so the map always has geometry to draw + fit).
    private var trackingLeg1Route: [CLLocationCoordinate2D] {
        viewerState.rideRouteStore.leg1.count > 1 ? viewerState.rideRouteStore.leg1 : [trackingCarOrigin, trackingPickup]
    }
    private var trackingLeg2Route: [CLLocationCoordinate2D] {
        viewerState.rideRouteStore.leg2.count > 1 ? viewerState.rideRouteStore.leg2 : [trackingPickup, trackingDestination]
    }

    /// Progress WITHIN the current leg (0…1) from the whole-trip `trackProgress`.
    private var trackingLegProgress: Double {
        let progress = rideRequestService.activeRequest?.trackProgress ?? 0
        let cut = rideRequestService.activeRequest?.pickupCut ?? 0.2
        switch trackingLeg {
        case .toPickup: return cut > 0 ? min(1, max(0, progress / cut)) : 0
        case .inRide: return (1 - cut) > 0 ? min(1, max(0, (progress - cut) / (1 - cut))) : 0
        }
    }

    /// The car's current coordinate + heading, interpolated along the active
    /// leg's route by the per-leg progress (route tangent for heading).
    private var trackingCarPosition: VehicleRoute.Position {
        let route = trackingLeg == .toPickup ? trackingLeg1Route : trackingLeg2Route
        return VehicleRoute.position(along: route, progress: trackingLegProgress)
    }

    private var isTrackingPhase: Bool { viewerState.sheetPhase == .tracking }

    // MARK: MYR-327 — expanded route viewer (tracking)

    /// The whole trip, full-bleed and user-driven, over the SAME map content the
    /// inline tracking map draws (`TrackingRouteMapContent`) — both legs with
    /// their active/inactive treatment, both pins, and the live heading marker.
    /// The camera is the rider's: one initial fit, then nothing until they tap
    /// recenter (see `ExpandedRouteCamera`).
    private var expandedTrackingRouteViewer: some View {
        ExpandedRouteMap(
            title: expandedRouteTitle,
            subtitle: trackingLeg == .toPickup ? "Heading to pickup" : "In ride",
            // Fit the WHOLE trip (both legs), not just the active one: the point
            // of expanding is to see the trip, and the leg fit is what the inline
            // map already gives.
            fitCoordinates: trackingLeg1Route + trackingLeg2Route,
            // Honest: while a leg is still the straight 2-point endpoint fallback,
            // MKDirections has not produced road geometry yet — say so instead of
            // letting the placeholder read as the route.
            routeIsResolving: trackingRouteIsResolving,
            onClose: { showsExpandedRoute = false }
        ) {
            TrackingRouteMapContent.content(
                leg: trackingLeg,
                leg1Route: trackingLeg1Route,
                leg2Route: trackingLeg2Route,
                pickupCoordinate: TrackingRouteMapContent.pickup(
                    leg1Route: trackingLeg1Route,
                    leg2Route: trackingLeg2Route,
                    carCoordinate: trackingCarPosition.coordinate
                ),
                destinationCoordinate: TrackingRouteMapContent.destination(leg2Route: trackingLeg2Route),
                carCoordinate: trackingCarPosition.coordinate,
                carHeading: trackingCarPosition.headingDegrees,
                legProgress: trackingLegProgress,
                showsUserLocation: viewerState.userLocation.showsUserLocationDot
            )
            .annotationTitles(.hidden)
        }
    }

    /// "{pickup} → {destination}" from the ride's own record — never a fixture
    /// persona or a fabricated place (MYR-228).
    private var expandedRouteTitle: String {
        let pickup = rideRequestService.activeRequest?.input.pickup.label
            ?? viewerState.draftPickup?.label
            ?? "Current location"
        let destination = rideRequestService.activeRequest?.input.destination.label
            ?? viewerState.draftDestination?.label
        guard let destination else { return pickup }
        return "\(pickup) → \(destination)"
    }

    /// Whether either leg is still the straight `[from, to]` fallback — i.e. the
    /// real road polyline has not landed for it yet.
    private var trackingRouteIsResolving: Bool {
        viewerState.rideRouteStore.leg1.count <= 2 || viewerState.rideRouteStore.leg2.count <= 2
    }

    /// Reconcile the route cache for the active ride — leg 2 always (drawn dimmed
    /// in leg 1, solid in leg 2), leg 1 only while heading to pickup. Cheap: the
    /// store issues network work only when the pair/car-origin actually changed.
    private func reconcileTrackingRoutes() {
        guard isTrackingPhase else { return }
        viewerState.rideRouteStore.ensureLeg2(pickup: trackingPickup, destination: trackingDestination)
        if trackingLeg == .toPickup {
            viewerState.rideRouteStore.ensureLeg1(carPosition: trackingCarOrigin, pickup: trackingPickup)
        }
    }

    // MARK: Reactive sync (ride-request.jsx:1098-1117)
    //
    // `RideRequestService`'s `activeRequest` can change out from under the
    // rider — the owner accepting/declining, or (M1's solo-rider fallback)
    // `SimulatedRideRequestService`'s own auto-accept timer. This is where
    // the rider's `sheetPhase` reacts, not inside the service itself (see
    // `RideRequestService`'s header comment: it only ever exposes the
    // snapshot). Mirrors ride-request.jsx's own reactive effect: accept
    // jumps straight into the to-pickup tracking sheet — "no intermediate
    // accepted banner" is the jsx's own comment (ride-request.jsx:1109-1111)
    // — and decline drops back to `.search` with the small `DeclinedNotice`
    // overlay (ride-request.jsx:1254-1258). `OutcomeContent`
    // (ride-request.jsx:670-717) is defined in the design source but never
    // mounted anywhere in it (`grep -c "<OutcomeContent"` is 0) — it does not
    // belong in either transition.

    // MARK: MYR-230 deliverable 1 — mount-time phase reconciliation
    //
    // `handleStatusChange` / `handleProgressChange` fire only via `.onChange`
    // while this screen is mounted, so a status transition that happened while it
    // was UNMOUNTED — the client bug: request a ride, switch to Owner mode, accept
    // it there, switch back to Rider and land on the idle greeting instead of the
    // tracking sheet — or a cold-launch adoption (deliverable 2 / a 409 adopt) is
    // never folded into `sheetPhase`. On appear, run the CURRENT active request's
    // status + progress through the SAME mapping, idempotently: a ride+status
    // already reflected is a no-op because each transition guards on its source
    // phase (an already-`.tracking` accepted ride does not re-enter tracking; a
    // `.pending` ride leaves `sheetPhase` on `.idle`, where the pending pill shows).
    //
    // Applied WITHOUT animation during the first layout (MYR-227 postmortem: never
    // let a mount-time adoption animate the sheet mid-first-layout) by disabling
    // animations for this transaction — this also suppresses the `.animation(_:,
    // value: sheetPhase)` sheet transition for the adopted change.
    private func reconcileMountedPhase() {
        guard let request = rideRequestService.activeRequest else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            handleStatusChange(request.status)
            handleProgressChange(request.trackProgress)
        }
    }

    /// MYR-381 — the rider's active slot went empty, so whatever route was cached
    /// for it is about a ride that no longer exists. See the call site's note: this
    /// is the ONLY signal a cancelled ride gives this screen.
    private func releaseRouteIfSlotEmpty(_ previousID: String?, _ id: String?) {
        guard id == nil else { return }
        viewerState.rideRouteStore.reset()
    }

    private func handleStatusChange(_ status: RideRequestStatus?) {
        guard let status, let request = rideRequestService.activeRequest else { return }
        // A decline raises the small notice overlay in addition to moving to
        // `.search` (the phase decision itself lives in the pure mapping below, so
        // the reactive `.onChange` and the MYR-230 mount reconciliation stay in
        // lockstep).
        //
        // MYR-381 — unless the rider has already dismissed THIS ride's card. This
        // method is the re-surfacing path the client hit: it runs on every mount
        // reconciliation and on every status fold, and the declined record it
        // reads is still in the slot, so before the acknowledgement each of those
        // put the card back up.
        if RiderDeclinedNotice.shouldRaise(
            status: status,
            rideID: request.id,
            acknowledgedID: viewerState.acknowledgedDeclinedRideID
        ) {
            viewerState.showDeclinedNotice = true
        }
        // MYR-381 — A ROUTE DIES WITH ITS RIDE. Clearing the store ON THE
        // TRANSITION is the other half of `liveRouteRequest`: the accessor stops
        // new geometry being drawn for a dead ride, and this drops the geometry
        // already fetched, so the overlay and the cache cannot disagree about
        // whether the ride exists. (`.completed` keeps its route until the summary
        // is dismissed — that map is ABOUT the ride that just happened — so only
        // the refusal clears here; the slot-release path below covers the rest.)
        if status == .declined { viewerState.rideRouteStore.reset() }
        if let phase = Self.reconciledPhase(
            status: status,
            isDormantReservation: RideReservation.isDormant(request),
            current: viewerState.sheetPhase,
            isAcknowledgedDecline: request.id == viewerState.acknowledgedDeclinedRideID
        ) {
            viewerState.sheetPhase = phase
        }
    }

    /// Pure status→phase decision shared by the reactive `.onChange` path and the
    /// MYR-230 mount reconciliation. Returns the phase the sheet should move to, or
    /// `nil` to leave it unchanged (IDEMPOTENCE: a ride+status already reflected in
    /// `current` is a no-op). Extracted static so it is unit-testable without
    /// mounting the view and so both entry points can never drift.
    ///
    /// - `.accepted`: jump straight into the live tracking sheet — but only for a
    ///   LIVE ride (`!isDormantReservation`) and only FROM `.booking`/`.idle`
    ///   (already tracking / summary / mid-request-flow → leave it, so a remount
    ///   over an accepted ride does not thrash the phase).
    /// - `.declined`: drop back to `.search` (the `DeclinedNotice` overlays there).
    /// - `.pending`: no phase change — the idle sheet shows the pending pill.
    ///
    /// MYR-377 — the parameter was `hasSchedule`, which conflated "this ride is
    /// booked for later" with "this ride is not happening". Those are the same
    /// thing right up until the reservation sweeper dispatches, and then they are
    /// opposites: the client's ride reached `arrived` — a car at his kerb — and
    /// this gate still refused to leave the idle sheet, so there was no tracking
    /// card and, fatally, no "Start ride" button, which is the ONLY control that
    /// moves `arrived → enroute`. The flow could not be completed at all.
    ///
    /// MYR-381 — `isAcknowledgedDecline` is the second half of the dismissal. The
    /// notice and the PHASE are two consequences of one record, so an
    /// acknowledgement that lowered only the card would leave every reconcile
    /// still yanking the rider from the idle sheet to `.search` for a ride they
    /// have finished with — a card-less version of the same defect.
    static func reconciledPhase(
        status: RideRequestStatus,
        isDormantReservation: Bool,
        current: RiderSheetPhase,
        isAcknowledgedDecline: Bool = false
    ) -> RiderSheetPhase? {
        switch status {
        case .accepted:
            guard !isDormantReservation, current == .booking || current == .idle else { return nil }
            return .tracking
        case .arrived, .enroute:
            // MYR-270 — the owner confirmed pickup (arrived) or the rider started
            // (enroute). From booking/idle (a cold-adopt of an in-progress ride) enter
            // tracking; already tracking → stay (the stage/leg flips within the
            // tracking sheet off the status itself).
            guard !isDormantReservation, current == .booking || current == .idle else { return nil }
            return .tracking
        case .completed:
            // MYR-265 — dropped off: advance the live tracking sheet to the summary.
            return current == .tracking ? .summary : nil
        case .declined:
            // MYR-381 — an acknowledged decline moves nothing. The rider dismissed
            // it; the record is simply history now.
            guard !isAcknowledgedDecline else { return nil }
            return current == .search ? nil : .search
        case .pending:
            return nil
        }
    }

    private func handleProgressChange(_ progress: Double?) {
        guard let progress, progress >= 0.999, viewerState.sheetPhase == .tracking else { return }
        viewerState.sheetPhase = .summary
    }

    // MARK: MYR-220 — session/connection failure is NOT a decline
    //
    // The live create POST's auth died mid-send (token expired → 401 / auth-
    // shaped 403). Backend confirmed no ride was created, so this must NOT render
    // as an owner decline ("Alex can't take this ride right now"). Return the
    // rider to a RETRYABLE state with the draft intact — Review when a full draft
    // exists (retry the exact same trip in one tap), else the collapsed search
    // sheet — and raise the calm retry notice. The draft lives in
    // `SharedViewerState` (untouched by the failed submit), so nothing to restore.
    private func handleSessionFailure() {
        // Never leave the declined affordance up for a session failure.
        viewerState.showDeclinedNotice = false
        if viewerState.draftPickup != nil, viewerState.draftDestination != nil {
            viewerState.sheetPhase = .review
        } else {
            viewerState.sheetPhase = .search
        }
        showSessionErrorToast = true
    }

    // MARK: MYR-233 — `409 vehicle_unavailable` is NOT a decline
    //
    // The server refused the create/accept because the CAR can't take the ride
    // (it already carries an open instant ride, or it went in service / offline
    // between the list fetch and the send). No ride was created, and nobody
    // refused the rider — so this must not render as an owner decline, and must
    // not leave a "Waiting…" pending card up. Return to Review with the draft
    // intact: the vehicle row now shows the muted Busy chip and the CTA routes to
    // scheduling, so the honest next step is one tap away. If the draft is
    // incomplete, fall back to the search sheet (same shape as MYR-220's).
    private func handleVehicleUnavailable() {
        viewerState.showDeclinedNotice = false
        if viewerState.draftPickup != nil, viewerState.draftDestination != nil {
            viewerState.sheetPhase = .review
        } else {
            viewerState.sheetPhase = .search
        }
        showVehicleUnavailableToast = true
    }

    // MARK: MYR-316 — `400 invalid_request` on a scheduled ride is NOT a decline
    //
    // The server refused because the requested pickup precedes the vehicle's
    // estimated return from service. No ride was created and nobody refused the
    // rider — they simply picked a time the car cannot make. Return to Search
    // with the draft intact AND arm the schedule card (the same one-shot
    // `opensScheduleOnSearch` hook MYR-233 uses), so the picker — re-floored from
    // the fleet row — is the next thing on screen rather than something the rider
    // has to go find.
    private func handleScheduleWindowFailure() {
        viewerState.showDeclinedNotice = false
        viewerState.opensScheduleOnSearch = true
        viewerState.sheetPhase = .search
        showScheduleWindowToast = true
    }

    /// MYR-233 criterion 4 — mirror the rider's own open ride onto the viewer
    /// state. A ride is "owned and open" while a record exists in a non-terminal
    /// status; `declined`/`completed` are terminal, so the exception lifts and a
    /// genuinely busy car reads Busy again on the next list fetch.
    private func syncRiderOwnsActiveRide() {
        guard let status = rideRequestService.activeRequest?.status else {
            viewerState.riderOwnsActiveRide = false
            return
        }
        switch status {
        case .pending, .accepted, .arrived, .enroute:
            viewerState.riderOwnsActiveRide = true
        case .completed, .declined:
            viewerState.riderOwnsActiveRide = false
        }
    }

    /// The actor named in the declined card. MYR-220 deliverable 2: in LIVE mode
    /// the rider knows the VEHICLE, not a fixture owner — its nickname ("Lunar")
    /// stands in as `liveFleetMember.owner` (MYR-212's naming, mirrored by the
    /// Booking/Tracking "Waiting for {name}" cards). Sim keeps the fixture owner
    /// ("Alex") so the simulated declined scene is content-identical.
    private var declinedRequesterName: String {
        if let live = viewerState.liveFleetMember { return live.owner }
        return RideRequestFixtures.fleet.first { $0.id == viewerState.draftFleetMemberID }?.owner
            ?? RideRequestFixtures.fleet[0].owner
    }

    /// MYR-224 — the name shown in the greeting. LIVE: the real first name, or
    /// `nil` when the account has no name (→ a calm generic "Good morning" with
    /// no trailing name). SIM (`liveProfile` nil): the fixture "Sam", unchanged.
    private var greetingFirstName: String? {
        if let profile = liveProfile { return profile.firstName }
        return riderName
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
    //
    // MYR-199 fix (client QA round 4): this sheet used a FIXED height
    // (`sharedIdleSheetHeight`, 286 — sized for the greeting + search bar +
    // quick places content) unconditionally, including for the much shorter
    // pending-pill content. That left the pill sitting in an oversized card
    // with a dead gap of empty sheet surface between it and the floating
    // nav. The jsx itself shortens `idleHeight` when a request is active
    // (screens.jsx:2078 `reqActive ? 246 : 286`) — but that 246 is sized for
    // ITS content (greeting kept + pill), not this app's simplified
    // pill-only card (MYR-191 deliberately swaps the greeting out for the
    // pill rather than stacking both — see this section's header comment),
    // so porting 246 verbatim would still leave a mismatched gap. Instead:
    // drop the fixed height for the pending case and let the sheet hug its
    // (much shorter) pill content — the same content-sizing recipe
    // Review/Booking/Tracking already use for their 'auto'-height phases.
    // Top/bottom padding stay the same 14/98 either way — 98 is the nav
    // clearance amount validated against the greeting sheet (nav floats
    // within the sheet's own bottom padding, not past its content), so
    // keeping it means the pill card still clears the floating nav
    // correctly even though the sheet is now much shorter overall.

    private var isPendingPill: Bool {
        rideRequestService.activeRequest?.status == .pending
    }

    private var idleSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let active = rideRequestService.activeRequest, active.status == .pending {
                pendingPill(active)
            } else {
                GreetingHero(firstName: greetingFirstName)
                    .padding(.bottom, 16)
                searchBar
                // MYR-228 — the Home/Work quick chips render fixture saved places
                // (`RideRequestFixtures.savedPlaces`). There is no saved-places
                // backend yet (real ones arrive with MYR-225), so in live mode the
                // idle sheet must NOT surface them — hide the chips entirely (an
                // honest empty affordance: the rider searches instead). SIM keeps
                // them so the greeting sheet stays pixel-identical.
                if !viewerState.isLiveLocation {
                    quickPlaces
                }
                // MYR-199 fix: this `Spacer` is what actually enforces the
                // fixed `sharedIdleSheetHeight` (286) below — it's the
                // flexible child a VStack needs to consume the "extra"
                // proposed height rather than just hugging content.
                // Scoping it to this (greeting) branch only was the missing
                // piece: with the pill branch above ALSO having a trailing
                // `Spacer`, `.frame(height: nil)` alone didn't stop it from
                // greedily expanding — the outer bottom-pinning wrapper
                // (`.frame(maxWidth:.infinity, maxHeight:.infinity,
                // alignment:.bottom)` a few modifiers down) still proposes
                // this VStack nearly the full screen height, and a `Spacer`
                // anywhere inside happily consumes all of it regardless of
                // the `nil` height frame. Without a flexible child at all,
                // the pill branch's VStack now reports its own hugged
                // (small) ideal size no matter what's proposed, and that
                // wrapper's `alignment: .bottom` positions the
                // already-compact card at the sheet's bottom — the same
                // "hug content, get bottom-pinned by the outer frame" recipe
                // Booking/Tracking's content-sized phases already rely on.
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 98)
        .frame(height: isPendingPill ? nil : MRTMetrics.sharedIdleSheetHeight)
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

    // MARK: MYR-236 round 4 — engine-hosted greeting card (rider idle↔search)
    //
    // The greeting card, rendered for the `PanSheet` engine: identical visuals
    // (wash + top corners + hairline + shadow) but NO bottom-pin / safe-area
    // handling and NO fixed outer frame — it hugs its natural
    // `sharedIdleSheetHeight`, which the engine adopts as the idle detent. The
    // pending pill keeps the old fixed-height, bottom-pinned `idleSheet` (it is
    // NOT part of the idle↔search drag — an active request isn't a place to
    // start a new search from).
    private var idleGreetingCardHosted: some View {
        VStack(alignment: .leading, spacing: 0) {
            GreetingHero(firstName: greetingFirstName)
                .padding(.bottom, 16)
            // MYR-184 §7.5.0 — the ride-request affordance needs the TOP
            // (`rides`) tier. Below it the server will 403 the create, so the
            // client must not offer it: a rider on `live`/`live_history` can
            // watch the car and sees a quiet line saying exactly that, instead of
            // a "Where to?" that dead-ends. Every simulated path keeps the CTA
            // (`canRequestRides` is true when no tier applies), so the drift-gate
            // scenes are byte-identical.
            if viewerState.canRequestRides {
                // MYR-352 — the client's "sleek banner above the search bar". It
                // sits ABOVE, not in place of, the search bar on purpose: the
                // rider can still search, and — for every reason except an owner's
                // pause — still schedule (MYR-313). This is the WHY behind the
                // MYR-341 ETA placeholder's deliberate silence in exactly these
                // states, so the two can never contradict each other: the same
                // `FleetUnavailability` non-nil that suppresses "A ride is N min
                // away" is what raises this banner. `nil` on every simulated boot
                // (no live fleet member ⇒ no vehicle set), so the idle sheet is
                // byte-identical everywhere it was before.
                if let availability = viewerState.idleAvailabilityBanner {
                    RiderIdleAvailabilityBannerView(availability: availability)
                        .padding(.bottom, MRTMetrics.riderIdleBannerGap)
                }
                searchBar
                if !viewerState.isLiveLocation {
                    quickPlaces
                }
            } else {
                watchOnlyNotice
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 98)
        // MYR-352 — still a FIXED height, now `sharedIdleSheetHeight` plus the
        // banner's own measured room. The prototype's 286 was sized for greeting +
        // search bar + chips (≈259, the rest absorbed by the trailing `Spacer`);
        // the banner is the first element that can exceed that band, because its
        // headline wraps to two lines for the longer reasons even at 393pt. Left
        // at a flat 286 it pushed the Home/Work chips under the floating nav.
        //
        // MYR-345's rule — a live-only line brings exactly its own room — applied
        // by MEASUREMENT rather than a constant, since this line's height depends
        // on the reason, the vehicle's name and the device width. Bannerless
        // states resolve to exactly 286 and are byte-identical.
        .frame(height: resolvedIdleSheetHeight)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Read the banner's height back out of the hosted subtree. Attached OUTSIDE
        // the frame it feeds, so it observes the banner rather than the card.
        .onPreferenceChange(RiderIdleBannerHeightKey.self) { height in
            guard abs(height - idleBannerHeight) > 0.5 else { return }
            idleBannerHeight = height
        }
        .background(idleSheetBackground)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: MRTMetrics.sheetRadius, topTrailingRadius: MRTMetrics.sheetRadius, style: .continuous))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.mrtGoldSheetHairline).frame(height: MRTMetrics.hairline)
        }
        .shadow(color: .black.opacity(0.5), radius: 20, y: -8)
    }

    /// The idle sheet's surface — see `RiderIdleSheetBackground`, which MYR-343's
    /// loading skeleton shares so the sheet a rider is looking at while their
    /// vehicle set resolves is the same surface the loaded sheet lands on.
    private var idleSheetBackground: some View { RiderIdleSheetBackground() }

    // MARK: Pending pill (ride-request.jsx's minimized "booked" state)

    // MYR-200 fix (client QA finding #3): the minimized "Request sent" pill
    // was a single reopen button with a plain 9pt gold dot + a chevron. The
    // prototype's pill (screens.jsx:2093-2128, `reqMeta.pending`) is richer
    // and split: a 30pt PULSING gold ring around an 18pt gold circle bearing a
    // dark paperplane, `Request sent` / `Waiting for {owner} · {dest}` (14/12),
    // and — for the pending state specifically — a RED circular ✕ that CANCELS
    // the request (not a chevron; the chevron is only the accepted/declined
    // affordance). Container: gold@10% fill, gold@33% hairline, radius 14,
    // 13×11 padding. Tapping the label region still reopens the booking sheet.
    private func pendingPill(_ request: RideRequestRecord) -> some View {
        HStack(spacing: 8) {
            Button {
                viewerState.sheetPhase = .booking
            } label: {
                HStack(spacing: 12) {
                    PendingPulseIcon()
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Request sent")
                            .font(.system(size: 14, weight: .semibold))
                            .tracking(-0.2)
                            .foregroundStyle(Color.mrtText)
                        Text("Waiting for \(viewerState.liveFleetMember?.owner ?? request.input.fleetMember.owner) \u{00B7} \(request.input.destination.label)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mrtTextSec)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                rideRequestService.cancel()
                viewerState.resetDraftToIdle()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.mrtDialogRed)
                    .frame(width: 28, height: 28)
                    .background(Color.mrtDialogRed.opacity(0.14), in: Circle())
                    .contentShape(Circle().inset(by: -6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel request")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(Color.mrtGold.opacity(Double(0x1A) / 255.0), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.mrtGold.opacity(Double(0x55) / 255.0), lineWidth: MRTMetrics.hairline))
    }

    // MARK: "Ready" affordances (screens.jsx:2174-2205) — MYR-171 wires both.

    private var searchBar: some View {
        Button {
            // MYR-389 — never a bare `sheetPhase = .search`: that adopts whatever
            // draft the last flow left behind, which is exactly what the client
            // tapped into. See `SharedViewerState.enterSearchFromIdle`.
            viewerState.enterSearchFromIdle()
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(Color.mrtGold)
                // MYR-228 — the "A ride is 3 min away" placeholder is a HARDCODED
                // fixture ETA (`watchedVehicleETAMinutes`, `FLEET[0].etaMin`), not a
                // real signal. In live mode drop it and rotate nothing — just the
                // static "Where to?" — until a real watched-vehicle ETA exists. SIM
                // keeps both strings rotating (pixel-identical).
                RotatingPlaceholder(items: searchPlaceholders)
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

    /// MYR-184 — what stands where "Where to?" would be for a viewer whose tier is
    /// below `rides`. Same 16pt row rhythm as the search bar it replaces, muted
    /// rather than gold: this is not a disabled CTA (there is nothing to enable),
    /// it is the honest description of what this grant is.
    private var watchOnlyNotice: some View {
        HStack(spacing: 11) {
            Image(systemName: "eye")
                .font(.system(size: 15))
                .foregroundStyle(Color.mrtTextMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(watchOnlyTitle)
                    .font(.system(size: 14, weight: .medium))
                    .tracking(-0.1)
                    .foregroundStyle(Color.mrtText)
                Text("The owner hasn\u{2019}t enabled ride requests for you.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.mrtTextSec)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(Color.mrtText.opacity(0.025), in: RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: MRTMetrics.controlRadius, style: .continuous)
                .strokeBorder(Color.mrtBorder, lineWidth: MRTMetrics.hairline)
        )
        .padding(.bottom, 14)
    }

    private var watchOnlyTitle: String {
        let name = viewerState.sharedVehicle?.name ?? ""
        return name.isEmpty ? "You can watch this Tesla" : "You can watch \(name)"
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
    /// with no pickup set (`SharedViewerState.selectDestination`).
    private func quickPlaceButton(label: String, icon: String, place: RidePlace) -> some View {
        Button {
            // MYR-211 defect B: route through pin-drop to capture the pickup
            // (same shortcut as Search's destination list) — never bypass it.
            // MYR-389: from IDLE, so the previous draft is discarded first — a
            // stale schedule or passenger must not ride along into a new trip.
            viewerState.selectDestinationFromIdle(place)
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

    /// The search bar's rotating placeholder items (screens.jsx:1977-1980).
    ///
    /// SIM: both strings on the fixture ETA, byte-identical to every prior
    /// build — the drift-gate scenes depend on this line reading "A ride is 3
    /// min away", and it is returned before any live machinery is consulted.
    ///
    /// LIVE (MYR-341): the same two strings, on a REAL estimate. MYR-228 had
    /// suppressed the second item here "until a real watched-vehicle ETA
    /// exists"; `RiderPickupETA` is that ETA. The gates live in
    /// `RiderIdlePlaceholder.items` — no fix, no vehicle coordinate, an
    /// unavailable car, or a request already in flight all fall back to the
    /// static "Where to?" a single-item `RotatingPlaceholder` never rotates.
    private var searchPlaceholders: [String] {
        RiderIdlePlaceholder.items(
            resolvesLiveETA: viewerState.resolvesPickupETA,
            pickupETAMinutes: viewerState.pickupETAMinutes,
            unavailability: viewerState.liveFleetMember?.unavailability,
            // ride-request.jsx `reqActive` (screens.jsx:1964, gating the whole
            // greeting + search block at 2173) — any record at all, not just a
            // pending one.
            hasActiveRequest: rideRequestService.activeRequest != nil
        )
    }
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
    /// The rider's first name, or `nil` for a name-less account — then the line
    /// is the greeting ALONE ("Good morning"), never "Good morning, " + empty
    /// (MYR-224). Apple only returns a name on first sign-in; a row created
    /// before native sign-in may carry none.
    let firstName: String?
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
                    LinearKeyframe(1, duration: 0.4675, timingCurve: Self.curve)
                    LinearKeyframe(1, duration: 0.3825)
                }
                KeyframeTrack(\.offsetY) {
                    LinearKeyframe(0, duration: 0.85, timingCurve: Self.curve)
                }
                KeyframeTrack(\.blur) {
                    LinearKeyframe(0, duration: 0.4675, timingCurve: Self.curve)
                    LinearKeyframe(0, duration: 0.3825)
                }
                KeyframeTrack(\.tracking) {
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
        // MYR-227 — the KeyframeAnimator's interpolation produced a transient
        // non-finite sample on device (zero-duration keyframes divide by zero),
        // sending `tracking` infinite: the greeting Text then reported an
        // INFINITE ideal width, which cascaded NaN through the sheet's layout
        // and crashed ("view origin is invalid … (inf, 860)"). The poisonous
        // keyframes are gone (initialValue pins the start values), and this
        // clamp is the hard guarantee: no animated sample reaches text layout
        // (tracking), CALayer geometry (blur/glow radius), or placement
        // (offset) unless it is finite.
        let sanitized = RevealValue(
            opacity: value.opacity.isFinite ? value.opacity : 1,
            offsetY: value.offsetY.isFinite ? value.offsetY : 0,
            blur: value.blur.isFinite ? value.blur : 0,
            tracking: value.tracking.isFinite ? value.tracking : Self.restingReveal.tracking,
            glowRadius: value.glowRadius.isFinite ? value.glowRadius : Self.restingReveal.glowRadius,
            glowIntensity: value.glowIntensity.isFinite ? value.glowIntensity : 0
        )
        return line(sanitized: sanitized)
    }

    private func line(sanitized value: RevealValue) -> some View {
        HStack(spacing: 4) {
            if let firstName {
                Text("\(greeting),")
                    .foregroundStyle(Color.mrtText)
                Text(firstName)
                    .foregroundStyle(Color.mrtGold)
                    .fontWeight(.semibold)
                    .shadow(color: glowColor(value.glowIntensity), radius: value.glowRadius)
            } else {
                // No name → the greeting stands alone, no trailing comma/name.
                Text(greeting)
                    .foregroundStyle(Color.mrtText)
            }
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

// MARK: - Pending pill pulse icon (screens.jsx:2104-2109 + `mrt-ready-dot`)
//
// 30pt gold ring around an 18pt gold circle with a dark paperplane. The ring
// carries `mrt-ready-dot`'s pulse (components.jsx:722-729): a gold glow that
// spreads out and fades over 2s, ease-out, forever. Reduce Motion → the ring
// rests with a static gold glow instead (the jsx's own reduced fallback,
// `box-shadow: 0 0 8px rgba(gold,0.6)`).
private struct PendingPulseIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animating = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .stroke(Color.mrtGold.opacity(0.55), lineWidth: 1.5)
                    .frame(width: 30, height: 30)
                    .scaleEffect(animating ? 1.5 : 1)
                    .opacity(animating ? 0 : 0.55)
            }
            Circle()
                .stroke(Color.mrtGold, lineWidth: 1.5)
                .frame(width: 30, height: 30)
                .shadow(color: reduceMotion ? Color.mrtGold.opacity(0.6) : .clear, radius: reduceMotion ? 4 : 0)
            Circle()
                .fill(Color.mrtGold)
                .frame(width: 18, height: 18)
                .overlay(
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.mrtGoldButtonLabel)
                )
        }
        .frame(width: 30, height: 30)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 2).repeatForever(autoreverses: false)) { animating = true }
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
