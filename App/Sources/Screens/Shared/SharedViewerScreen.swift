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
                        bottom: MRTMetrics.trackingRecenterButtonBottom,
                        hidden: isFollowing
                    ) {
                        isFollowing = true
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .background(Color.mrtBg)
        .overlay(alignment: .bottom) {
            if isSearch, viewerState.showDeclinedNotice {
                DeclinedNoticeCard(
                    requesterName: declinedRequesterName,
                    onDismiss: { viewerState.resetDraftToIdle() },
                    onRebook: { viewerState.showDeclinedNotice = false }
                )
                .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.2) : .timingCurve(0.32, 0.72, 0, 1, duration: 0.3), // ride-request.jsx:1053 `mrt-sched-up`
            value: viewerState.showDeclinedNotice
        )
        .mrtBottomNav(selection: $sharedTab, tabs: MRTTab.sharedTabs, hidden: hideBottomNav)
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
                }
            }
            #endif
        }
        .onChange(of: isPinDrop) { _, entering in
            // MYR-212 defect 2: force a fresh device fix + re-seed the pin when
            // the pin-drop phase mounts (no-op in sim).
            if entering { viewerState.enterPinDrop() }
        }
        .onChange(of: rideRequestService.activeRequest?.status) { _, newStatus in
            handleStatusChange(newStatus)
        }
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
        case .tracking:
            RideRequestTrackingContent(viewerState: viewerState, rideRequestService: rideRequestService, totalHeight: totalHeight)
        case .summary:
            RideRequestSummaryContent(viewerState: viewerState, rideRequestService: rideRequestService, historyStore: historyStore, riderName: riderName, liveProfile: liveProfile)
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
    private var draftRouteEndpointsKnown: Bool {
        searchPreviewPickup != nil
            && (rideRequestService.activeRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate) != nil
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
        rideRequestService.activeRequest?.input.pickup.coordinate
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
                vehicle: viewerState.vehicle,
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
                bottomContentInset: mapBottomInset,
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
                bottomInset: mapBottomInset,
                cameraPosition: $cameraPosition,
                isFollowing: $isFollowing,
                controller: viewerState.trackingCamera,
                showsUserLocation: viewerState.userLocation.showsUserLocationDot
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
    static func mapBottomInset(phase: RiderSheetPhase, isPendingPill: Bool) -> CGFloat {
        switch phase {
        case .idle:
            return isPendingPill ? MRTMetrics.sharedPendingPillSheetHeight : MRTMetrics.sharedIdleSheetHeight
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
        Self.mapBottomInset(phase: viewerState.sheetPhase, isPendingPill: isPendingPill)
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

    /// Pickup → destination pair for the route-fitted phases — from the
    /// submitted `activeRequest` once it exists, else the still-in-progress
    /// draft (Review is reached before `submit(_:)` is ever called).
    private var requestRoute: [CLLocationCoordinate2D] {
        let pickup = searchPreviewPickup
        let destination = rideRequestService.activeRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
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
        let destination = rideRequestService.activeRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
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
        let destination = rideRequestService.activeRequest?.input.destination.coordinate ?? viewerState.draftDestination?.coordinate
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
        TrackingLeg.forProgress(rideRequestService.activeRequest?.trackProgress ?? 0,
                                pickupCut: rideRequestService.activeRequest?.pickupCut ?? 0.2)
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

    private func handleStatusChange(_ status: RideRequestStatus?) {
        guard let status, let request = rideRequestService.activeRequest else { return }
        // A decline raises the small notice overlay in addition to moving to
        // `.search` (the phase decision itself lives in the pure mapping below, so
        // the reactive `.onChange` and the MYR-230 mount reconciliation stay in
        // lockstep).
        if status == .declined { viewerState.showDeclinedNotice = true }
        if let phase = Self.reconciledPhase(status: status, hasSchedule: request.input.schedule != nil, current: viewerState.sheetPhase) {
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
    ///   "now" acceptance (`!hasSchedule`; a scheduled acceptance is a reservation,
    ///   not a live trip — `SimulatedRideRequestService.accept()` never seeds
    ///   `trackProgress` for these and ride-request.jsx's scheduled path never
    ///   shows `TrackingContent`) and only FROM `.booking`/`.idle` (already
    ///   tracking / summary / mid-request-flow → leave it, so a remount over an
    ///   accepted ride does not thrash the phase).
    /// - `.declined`: drop back to `.search` (the `DeclinedNotice` overlays there).
    /// - `.pending`: no phase change — the idle sheet shows the pending pill.
    static func reconciledPhase(status: RideRequestStatus, hasSchedule: Bool, current: RiderSheetPhase) -> RiderSheetPhase? {
        switch status {
        case .accepted:
            guard !hasSchedule, current == .booking || current == .idle else { return nil }
            return .tracking
        case .declined:
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

    /// `backgroundColor:'#0A0A0A'` + `radial-gradient(130% 62% at 50% -14%,
    /// rgba(201,168,76,0.14) 0%, rgba(10,10,10,0) 58%)` (ride-request.jsx:1176-1177).
    ///
    /// MYR-226 — the `EllipticalGradient` resolves its radius from the
    /// container's width (`endRadiusFraction` × size); on a real device's FIRST
    /// layout pass — which now happens at launch, because MYR-224 can route a
    /// stored-rider session straight to this sheet before geometry settles —
    /// that width is momentarily indeterminate, yielding a NaN radius and a hard
    /// `CALayerInvalidGeometry` crash ("CALayer bounds contains NaN [nan 286]").
    /// Gate the gradient on a finite, positive size so only the solid `mrtBg`
    /// paints during the (single, invisible) unresolved frame. Never reproduced
    /// in the simulator/tests: the sheet there only laid out after navigation,
    /// once the width was already known.
    private var idleSheetBackground: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color.mrtBg
                if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
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
            }
        }
        .allowsHitTesting(false)
    }

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
            viewerState.sheetPhase = .search
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
            viewerState.selectDestination(place)
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

    /// MYR-228 — the search bar's rotating placeholder items. LIVE: only the
    /// static "Where to?" (the fixture ETA is dropped — no real watched-vehicle
    /// ETA yet; a single-item `RotatingPlaceholder` never rotates). SIM: both
    /// strings, unchanged.
    private var searchPlaceholders: [String] {
        viewerState.isLiveLocation
            ? ["Where to?"]
            : ["Where to?", "A ride is \(SharedViewerScreen.watchedVehicleETAMinutes) min away"]
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
