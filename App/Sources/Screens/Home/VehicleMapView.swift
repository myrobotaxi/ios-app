import SwiftUI
import MapKit
import DesignSystem
#if DEBUG
import os

// MYR-222 — standing camera-write probe: every programmatic camera write and
// every settle classification is logged (DEBUG only) so the streaming-fix
// probe (CLAUDE.md "Streaming-fix camera probe") can capture feedback loops
// that static-fix screenshots can never show. Filter with:
//   log stream --predicate 'subsystem == "app.myrobotaxi.ios" AND category == "camera"'
let mrtCameraLog = Logger(subsystem: "app.myrobotaxi.ios", category: "camera")
#endif

@inline(__always)
func mrtCameraTrace(_ message: @autoclosure () -> String) {
    #if DEBUG
    let text = message()
    mrtCameraLog.info("\(text, privacy: .public)")
    #endif
}

// MARK: - VehicleMapView (MYR-167 deliverable 2)
//
// Real MapKit (SwiftUI `Map`, DEVIATIONS "Mapbox GL → MapKit … Native
// MKMapView for vehicle annotation + route overlay. Accept minor fidelity
// loss on building extrusions" — the SwiftUI `Map` API wraps `MKMapView`).
// Dark styling comes for free from the app's forced-dark interface style
// (project.yml `INFOPLIST_KEY_UIUserInterfaceStyle: Dark`); POIs/traffic are
// excluded to keep the chrome as close to the prototype's minimal stylized
// map as MapKit allows.
struct VehicleMapView: View {
    let vehicle: Vehicle
    let snapshot: VehicleTelemetrySnapshot
    @Binding var cameraPosition: MapCameraPosition
    @Binding var isFollowing: Bool
    /// MYR-197 fix: `SharedViewerScreen`'s rider idle/search/pinDrop map
    /// reuses this same view (MYR-191) — but client QA found it was also
    /// drawing the owner's current-trip route polyline + origin/destination
    /// dots on the rider's idle map before any ride is booked, because
    /// `VEHICLES[0]`'s default fixture activity is `.driving` (matches the
    /// owner Home screen's own default tweaks, `VehicleTelemetry.swift`'s
    /// `SimulatedVehicleTelemetrySource.init` comment). The prototype's rider
    /// live map never shows a route pre-booking (confirmed via the MYR-197
    /// prototype walk) — a route only belongs once an actual request exists,
    /// which is already correctly handled by `RideRequestRouteMap` for
    /// `.review`/`.booking`/`.tracking` (`SharedViewerScreen
    /// .backgroundMap`). Defaults `true` (unchanged behavior for
    /// `HomeScreen`'s owner map, which legitimately shows its own vehicle's
    /// live trip) — the rider call site below opts out.
    var showRoute: Bool = true
    /// MYR-198 client ruling (overrides the design jsx's idle vehicle
    /// marker): the rider's idle/search/pinDrop/review map — including the
    /// "request sent, not yet accepted" pending state, which still renders
    /// this same `.idle`-phase call site — shows NO vehicle location at all,
    /// no marker and no label, until a ride is actually accepted (tracking).
    /// Client QA round 3 screenshots are the spec (privacy: don't broadcast
    /// a fleet vehicle's live position to a rider who hasn't been matched to
    /// it yet). Defaults `true` (unchanged for `HomeScreen`'s owner map,
    /// which legitimately shows its own vehicle) — the rider call site in
    /// `SharedViewerScreen.backgroundMap` opts out, mirroring `showRoute`'s
    /// identical default/opt-out shape immediately above.
    var showVehicle: Bool = true
    /// MYR-199 fix (client QA round 4): the rider's idle/search/pinDrop map
    /// was centering the camera — and RE-centering it every progress tick
    /// (`.onChange(of: progressBucket)` below) — on the watched vehicle's
    /// live simulated-driving position, even though `showVehicle`/`showRoute`
    /// are both `false` at that call site (MYR-197/198 privacy rulings), so
    /// nothing was ever drawn to explain why the map kept visibly panning
    /// down the vehicle's route. Client QA: "why is the map moving around
    /// when there's no ride booked… map should be set to the user's current
    /// location." Fix: an optional static override coordinate — when set,
    /// the camera centers there once (`onAppear`) and never re-centers on
    /// vehicle telemetry; when `nil` (the owner's `HomeScreen` call site,
    /// unchanged), legacy vehicle-follow behavior.
    var centerOverride: CLLocationCoordinate2D?
    /// MYR-211: draw the standard MapKit user-location dot (the rider's live
    /// map in live mode, when location is authorized). The prototype defines no
    /// bespoke user marker (`grep` "current location" in `design/` is only the
    /// pickup-label fallback), so the standard blue dot is the accepted
    /// deviation. Defaults `false` — the owner `HomeScreen` map is unaffected.
    var showsUserLocation: Bool = false
    /// Reserved height along the bottom edge the sheet now physically
    /// covers (MYR-196 punch-list #2, `MRTDetentSheet`'s
    /// `.ignoresSafeArea(edges: .bottom)`). `MKMapView` reads its own
    /// `safeAreaInsets` to keep the legally-required attribution/legal
    /// label (and compass) clear of obstructed regions — `.safeAreaPadding`
    /// grows that inset without shrinking the map's own edge-to-edge
    /// render, so the label settles just above the sheet's peek edge
    /// instead of being hidden underneath it.
    let bottomContentInset: CGFloat
    /// MYR-213: pin-drop mode. When set, this view (1) draws the fixed pin glyph
    /// over the map AND (2) on every camera settle converts the glyph's ACTUAL
    /// rendered screen point to a coordinate via `MapProxy`, reporting it through
    /// `onCoordinate` as the authoritative pickup. Glyph and coordinate share one
    /// screen point (`Self.pinGlyphPoint`) in one coordinate space, so they can
    /// never desync. `nil` at every non-pin-drop call site.
    var pinDrop: PinDropOverlay? = nil
    /// MYR-217: the SINGLE camera owner for the pin-drop phase (see
    /// `PinDropCameraController`'s header for the four-round recurrence it
    /// closes). Non-nil wherever `pinDrop` can ever become non-nil (the rider
    /// call site passes it unconditionally so exit is observable when `pinDrop`
    /// drops back to nil); `nil` on the owner Home map, which has no pin-drop.
    /// While `pinDrop != nil`, EVERY programmatic camera write flows through
    /// this controller — the legacy writers below are gated off by
    /// `cameraWritePermitted` — and each write it emits carries the street
    /// span, so no interleaving can re-assert a wide span at entry again.
    var pinDropCamera: PinDropCameraController? = nil
    /// The map camera's region span (degrees, lat+lon) used when (re)centering.
    /// Defaults to the neighborhood overview (`mapRegionSpanDelta`, ~6.6km) for
    /// the owner Home map + the rider idle/search map; the LIVE pin-drop passes a
    /// street-level span (`pinDropStreetSpanDelta`) so it opens a few blocks wide,
    /// not miles wide (MYR-213). Only affects programmatic recenters — user
    /// zoom/pan afterwards is never overridden.
    var regionSpanDelta: Double = MRTMetrics.mapRegionSpanDelta
    /// MYR-277 B — the dispatched ride's PICKUP, drawn with a gold pickup marker
    /// on the OWNER map. A dispatched in-service car maps to `.parked`, so
    /// `mapContent`'s `.driving` route branch never fires for it; this makes the
    /// owner's map show where the car is headed. Non-nil only while the owner's
    /// active ride is heading to the pickup (`.accepted`/`.arrived`, gated at the
    /// call site); `nil` otherwise and on the rider map, so every other call site
    /// is unchanged.
    var pickupCoordinate: CLLocationCoordinate2D? = nil
    /// MYR-293 — the REAL car → pickup road polyline for the leg above, resolved
    /// by the caller from `RideRouteStore.leg1Route(pickup:)`.
    ///
    /// MYR-277 B drew `[vehiclePosition, pickup]` — a literal two-point segment,
    /// which its own doc comment called a "straight car→pickup route". That is
    /// exactly the fabricated line the client ruled out twice (MYR-237: "no
    /// straight lines"), so the line now comes from MKDirections and this view
    /// draws NOTHING when only the provider's 2-point fallback has resolved
    /// (`RideRoutePolyline`): the gold pickup marker still says where the car is
    /// going, and the store's cooldown retries until real geometry lands. Empty at
    /// every other call site.
    var pickupRoute: [CLLocationCoordinate2D] = []
    /// MYR-387 — the last position this device observed this car at, off
    /// `LastKnownVehiclePositionStore`. Used ONLY when the vehicle has no fix
    /// (§2.3's `(0, 0)` sentinel), so the map opens somewhere real instead of on
    /// Null Island. `nil` everywhere but the owner Home map, and `nil` there too
    /// until the car has been seen once — in which case `OwnerMapCamera` writes
    /// no region at all rather than inventing a city.
    var lastKnownCenter: CLLocationCoordinate2D? = nil

    /// MYR-456/MYR-457 — the polyline this map should DRAW for a driving car,
    /// resolved by `OwnerDrivingRoute` (Tesla's own route → the app's MKDirections
    /// road route → the route this journey last really had → nothing).
    ///
    /// `nil` means "no caller opinion, use the trip's own geometry", which is what
    /// every preview and the rider's opted-out call site pass. The owner's Home
    /// screen always supplies one, because the decision needs the fetched route
    /// and the hold, and neither of those is a fact a map view should own.
    var drivingLine: [CLLocationCoordinate2D]? = nil

    // MYR-222 — token accounting for the legacy (non-pin-drop) writers,
    // replacing the wall-clock `programmaticCameraUntil` window. The window
    // was only sound when programmatic writes were RARE: with a live device
    // streaming a fix every second (MYR-221), the follow recenter re-stamped
    // the 1.2s deadline faster than it could lapse, so EVERY settle —
    // including the user's own drags — was classified programmatic,
    // `isFollowing` could never turn off, and the camera snapped back on
    // every gesture (client evidence #1). The ledger classifies by matching
    // each settle against the writes we actually issued — no clock, immune to
    // fix rate. See `CameraSettleLedger`'s header.
    @State private var settleLedger = CameraSettleLedger()
    // MYR-222 — the camera's LIVE region, tracked continuously into a plain
    // reference box (mutating a class var doesn't invalidate the view, so the
    // 60Hz stream costs nothing). Exists for exactly one moment: when a user
    // gesture begins while a programmatic camera animation is still gliding
    // (with a 1Hz follow stream one nearly always is), the gesture handler
    // pins the camera at its current visual region — cancelling the glide —
    // so the last pre-gesture write can never "finish" over the user's drag.
    @State private var liveCameraRegion = LiveCameraRegionBox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // MYR-222 — scene lifecycle is handled BY DESIGN (the pre-fix behavior
    // "backgrounding heals the glitch" was the wall-clock loop starving, not
    // a feature): suspend drops in-flight write expectations; resume re-arms
    // one clean re-seat if (and only if) seating was interrupted.
    @Environment(\.scenePhase) private var scenePhase

    /// The line this map draws for a driving car — the caller's resolution when it
    /// has one, else the trip's own wire geometry.
    private func drivingRoute(_ trip: DrivingTrip) -> [CLLocationCoordinate2D] {
        drivingLine ?? trip.route
    }

    private var vehiclePosition: VehicleRoute.Position {
        switch vehicle.activity {
        case .driving(let trip):
            let line = drivingRoute(trip)
            // MYR-457 — interpolate along the drawn route when there IS one, and
            // otherwise use the car's own fix.
            //
            // Before this the fix reached here only by being smuggled in as
            // `route[0]` of an invented `[currentPosition, destination]` pair, so
            // removing that pair (the straight-line defect) would have taken the
            // marker with it. `position(along:)` answers `(0, 0)` for empty
            // geometry, which `drawsVehicleMarker` reads as the contract's §2.3
            // no-fix sentinel — the car would simply have vanished from the
            // owner's own map on exactly the frames this issue is about.
            if line.count > 1 {
                return VehicleRoute.position(along: line, progress: snapshot.progress)
            }
            return VehicleRoute.Position(
                coordinate: trip.carCoordinate ?? VehicleRoute.position(along: line, progress: 0).coordinate,
                headingDegrees: 0
            )
        case .parked(let loc):
            return VehicleRoute.Position(coordinate: loc.coordinate, headingDegrees: 0)
        }
    }

    /// Rounds the 30Hz simulated progress to whole percent so the follow
    /// camera re-centers roughly once a second instead of on every tick.
    private var progressBucket: Double { (snapshot.progress * 100).rounded() }

    /// MYR-211: a change key for `centerOverride` so the camera re-centers when
    /// the live location fix arrives / moves (the first fix commonly lands after
    /// `onAppear`). `nil` for the owner map (no override) — never fires.
    private var centerOverrideKey: String? {
        centerOverride.map { "\($0.latitude),\($0.longitude)" }
    }

    /// MYR-387 — whether the gold vehicle pin may be drawn this frame.
    ///
    /// Deliberately NOT the same question as "where does the camera point": a
    /// last-known camera is honest context, a pin is a claim that the car is
    /// THERE right now. With no fix there is no such claim, and the pin is
    /// withheld rather than planted in the Gulf of Guinea. Every fixture vehicle
    /// carries a real coordinate, so every simulated capture is byte-identical.
    private var drawsVehicleMarker: Bool {
        OwnerMapCamera.drawsVehicleMarker(vehicle: vehiclePosition.coordinate)
    }

    /// Whether pin-drop mode is on (MYR-215): the trigger for the entry re-frame
    /// below. Kept as a plain `Bool` so it's `Equatable` for `.onChange`
    /// (`PinDropOverlay` carries a closure and isn't).
    private var isPinDropActive: Bool { pinDrop != nil }

    var body: some View {
        // MYR-213: a `MapReader` exposes the `MapProxy` so a screen point can be
        // converted to the coordinate MapKit actually renders there. The pin-drop
        // glyph is drawn by `SharedViewerScreen` (kept in its original safe-area
        // geometry so the sim scene stays pixel-identical); it passes down the
        // glyph's GLOBAL screen point (`pinDrop.glyphGlobalPoint`), derived from the
        // SAME `pinGlyphPoint` it positions the glyph with, so glyph and coordinate
        // can never desync. Converting from `.global` (not `.local`) lets the two
        // live in different views yet reference the one on-screen point.
        MapReader { proxy in
            Map(position: $cameraPosition) {
                mapContent
                    // Suppress MapKit's own auto-drawn title labels for every
                    // `Annotation` below — `VehicleMarker`'s `label` chip is the
                    // only vehicle-name label the design wants
                    // (components.jsx:443); leaving titles on doubled it up next
                    // to the marker (review finding #3). The `Origin`/
                    // `Destination`/vehicle-name strings passed to `Annotation`
                    // are accessibility labels only.
                    .annotationTitles(.hidden)
            }
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .safeAreaPadding(.bottom, bottomContentInset)
            // Force dark so MKMapView doesn't fall back to a light palette
            // independent of the app's own forced-dark Info.plist trait
            // (review finding #4). This measurably darkens urban/street
            // contexts (deep navy water, muted gray streets) but — verified in
            // the Simulator — does NOT reach near-black for natural
            // landcover/terrain (forests, coastal scrub): MapKit's `.standard`
            // style keeps a saturated teal-green there regardless of
            // `emphasis`. See the PR body for the documented limitation and
            // side-by-side evidence; there is no more aggressive terrain color
            // knob on the public SwiftUI `Map` style API.
            .preferredColorScheme(.dark)
            // MYR-222: live camera tracking for gesture-time animation cancel —
            // see `liveCameraRegion`'s declaration comment.
            .onMapCameraChange(frequency: .continuous) { context in
                liveCameraRegion.region = context.region
            }
            .onMapCameraChange(frequency: .onEnd) { context in
                // MYR-213: ground-truth pickup — no assumed screen fraction or
                // region-center model. Convert the pin GLYPH's actual rendered
                // screen point to the coordinate MapKit renders there: whatever is
                // under the glyph IS the confirmed pickup, on every settle. `proxy
                // .convert` returns nil only before the map has laid out (the glyph
                // point is always in-bounds) — the raw region center is the
                // documented transient fallback, corrected by the next settle.
                //
                // MYR-217: while pin-drop is up, the settle is fed to the ONE
                // camera owner, which decides everything (refine the seating /
                // done / user took over). The MYR-216 in-place one-shot correction
                // — whose `span: context.region.span` write re-asserted a stale
                // wide span when a pre-entry settle hijacked it (the four-round
                // recurrence) — is deleted in its favor. The coordinate is NOT
                // reported while seating is still converging (`.refine`) so the
                // label pipeline never geocodes a transient framing.
                if let pinDrop {
                    let glyphCoord = proxy.convert(pinDrop.glyphGlobalPoint, from: .global) ?? context.region.center
                    guard let camera = pinDropCamera else {
                        pinDrop.onCoordinate(glyphCoord) // defensive: no owner composed
                        return
                    }
                    let outcome = camera.cameraSettled(
                        glyphCoordinate: glyphCoord,
                        cameraCenter: context.region.center,
                        cameraLatitudeDelta: context.region.span.latitudeDelta
                    )
                    mrtCameraTrace("settle pinDrop center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) outcome=\(String(describing: outcome)) phase=\(String(describing: camera.phase))")
                    switch outcome {
                    case .refine(let write):
                        applyOwnerWrite(write)
                    case .seated, .report:
                        pinDrop.onCoordinate(glyphCoord)
                    case .userTookOver:
                        // The user's drag/zoom wins — the owner stands down for
                        // this entry, and follow mode is off (same affordance
                        // semantics as the non-pin-drop branch below).
                        isFollowing = false
                        pinDrop.onCoordinate(glyphCoord)
                    }
                    return
                }
                // MYR-222: token classification — a settle is ours only if it
                // matches a write we actually issued; everything else is the
                // user's gesture, which permanently disengages follow for this
                // screen visit (no wall-clock window to starve — see
                // `settleLedger`'s declaration comment).
                guard !settleLedger.classifySettle(center: context.region.center, latitudeDelta: context.region.span.latitudeDelta) else {
                    mrtCameraTrace("settle idle center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) classified=programmatic (token)")
                    return
                }
                // A real drag/pinch settled — the prototype's FloatingMapButton
                // recenter affordance is meant for exactly this (Handoff §5.5;
                // "appears when user has panned away").
                mrtCameraTrace("settle idle center=\(context.region.center.latitude),\(context.region.center.longitude) latDelta=\(context.region.span.latitudeDelta) classified=user → follow off")
                isFollowing = false
                settleLedger.clear()
            }
            // MYR-222: DIRECT user-gesture detection — the primary "user wins"
            // signal, ahead of settle classification. `simultaneousGesture`
            // observes the map's own pan/pinch without stealing it: any drag or
            // magnification is the user's hand, so follow disengages (idle) or
            // the pin-drop owner stands down (`userGestureBegan`) IMMEDIATELY —
            // no waiting for the gesture's settle, no inference at all.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in handleUserGesture() })
            .simultaneousGesture(MagnifyGesture(minimumScaleDelta: 0.02).onChanged { _ in handleUserGesture() })
            .onAppear {
                // MYR-217: a COLD pin-drop mount (`pinDrop` scene launch) enters
                // through the same single owner as the warm in-session transition
                // below — one code path, closing the cold-probe-passes /
                // real-path-fails verification gap that MYR-213/215/216 fell into.
                //
                // MYR-222: the mount's initial layout settle can land at a
                // position we didn't write (the `.automatic` camera) — it is
                // not a gesture; let one unmatched settle through.
                settleLedger.grantFreePass()
                if isPinDropActive {
                    enterPinDropCamera(animated: false)
                } else {
                    recenter(animated: false)
                }
            }
            // MYR-222: a sheet-inset change re-fits the camera and re-fires a
            // settle at geometry we didn't write — a layout event, not a
            // gesture. One free pass so it can't disengage follow.
            .onChange(of: bottomContentInset) { _, _ in
                settleLedger.grantFreePass()
            }
            // MYR-222: scene lifecycle BY DESIGN (the states must survive a
            // background round-trip; pre-fix, backgrounding was accidentally
            // HEALING the feedback loop — see `PinDropCameraController`'s
            // header). Suspend drops in-flight expectations; resume re-arms
            // one clean re-seat only if seating was interrupted mid-pass.
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .background:
                    pinDropCamera?.sceneWillBackground() // no-op unless mid-seat
                case .active:
                    if isPinDropActive, let write = pinDropCamera?.sceneDidForeground() {
                        mrtCameraTrace("scene foreground mid-seat → single re-seat")
                        applyOwnerWrite(write)
                    } else {
                        // The resume re-layout can re-fire a settle — not a gesture.
                        settleLedger.grantFreePass()
                    }
                default:
                    break
                }
            }
            .onChange(of: progressBucket) { _, _ in
                // MYR-199 fix: a static `centerOverride` never re-centers on the
                // ticking vehicle telemetry — see that property's header comment.
                guard centerOverride == nil else { return }
                if isFollowing { recenter(animated: true) }
            }
            .onChange(of: isFollowing) { _, following in
                if following { recenter(animated: true) }
            }
            // MYR-211: re-center when the live location override changes (first fix
            // / device movement) — but never fight a user who has panned away.
            // MYR-217/MYR-222: during pin-drop the fix goes to the camera OWNER,
            // which seats ONCE per entry — a mid-seat fix re-aims the in-flight
            // (budget-bounded) pass, a late FIRST fix completes it, and every fix
            // after that moves the blue-dot annotation only (zero camera writes,
            // zero pin movement, at any fix rate — the MYR-222 streaming-GPS
            // loop was this handler re-arming a full re-seat on every 1Hz fix).
            // `recenter` is hard-gated off during pin-drop either way
            // (`cameraWritePermitted`).
            .onChange(of: centerOverrideKey) { _, _ in
                guard centerOverride != nil else { return }
                if isPinDropActive {
                    if let camera = pinDropCamera, let fix = pinDrop?.entryFix {
                        mrtCameraTrace("fixChanged pinDrop fix=\(fix.latitude),\(fix.longitude) phase=\(String(describing: camera.phase))")
                        if let write = camera.fixChanged(fix) {
                            applyOwnerWrite(write)
                        }
                    }
                    return
                }
                guard isFollowing else { return }
                recenter(animated: true)
            }
            // MYR-217 (supersedes the MYR-215 defect-2 re-frame + MYR-216 d3
            // re-arm): the in-session idle/search → pinDrop transition hands the
            // camera to the single owner, which frames street-span with the fix
            // under the glyph in ONE write; leaving pin-drop releases it.
            .onChange(of: isPinDropActive) { _, active in
                if active {
                    isFollowing = true
                    enterPinDropCamera(animated: true)
                } else {
                    pinDropCamera?.exit()
                }
            }
        }
    }

    // MARK: - MYR-217 single-owner camera plumbing

    /// Every programmatic camera write goes through this permission gate: while
    /// pin-drop is up, ONLY the owner may write; outside it, only the legacy
    /// recenter writers. Pure + static so the invariant is pinned by
    /// `PinDropCameraOwnershipTests` — the regression this table exists to
    /// prevent is a legacy writer (follow tick, fix recenter, appear framing)
    /// mutating the camera mid-pin-drop again.
    enum CameraWriteSource {
        case pinDropOwner
        case legacyRecenter
    }

    static func cameraWritePermitted(source: CameraWriteSource, isPinDropActive: Bool) -> Bool {
        switch source {
        case .pinDropOwner: isPinDropActive
        case .legacyRecenter: !isPinDropActive
        }
    }

    /// MYR-222 — the user's hand on the map, reported by the gesture
    /// recognizers (not inferred from settles): the user wins immediately and
    /// permanently for this screen visit / pin-drop entry. Runs its takeover
    /// exactly once per engagement (the guards below), so the camera pin
    /// can't fight the ongoing drag.
    private func handleUserGesture() {
        if isPinDropActive {
            guard let camera = pinDropCamera,
                  camera.phase == .seating || camera.phase == .settled else { return }
            mrtCameraTrace("gesture user pan/zoom during pinDrop → userControlled")
            camera.userGestureBegan()
            isFollowing = false
            cancelInFlightCameraAnimation()
        } else {
            guard isFollowing else { return }
            mrtCameraTrace("gesture user pan/zoom → follow off")
            isFollowing = false
            settleLedger.clear()
            cancelInFlightCameraAnimation()
        }
    }

    /// With a streaming fix a programmatic camera animation is nearly always
    /// in flight when the user grabs the map; SwiftUI keeps driving it to its
    /// target even after the writers stand down, so the map would glide back
    /// over the user's drag ONE more time. Pin the camera at its current
    /// visual region (no animation) — a no-op visually, but it retargets the
    /// transaction and kills the glide. On behalf of the USER, deliberately
    /// not routed through the programmatic writers or their ledgers: its
    /// settle (wherever the user's gesture ends) must classify as the user's.
    private func cancelInFlightCameraAnimation() {
        guard let current = liveCameraRegion.region else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            cameraPosition = .region(current)
        }
    }

    /// Route a pin-drop entry through the single owner (cold `onAppear` and the
    /// warm in-session transition share this one path).
    private func enterPinDropCamera(animated: Bool) {
        guard let pinDrop, let camera = pinDropCamera else { return }
        let write = camera.enter(
            fix: pinDrop.entryFix,
            fallbackCenter: centerOverride ?? vehiclePosition.coordinate,
            viewportSize: pinDrop.viewportSize,
            animated: animated
        )
        applyOwnerWrite(write)
    }

    /// Apply an owner-issued camera write — the ONLY site that mutates the
    /// camera during pin-drop. The owner has already registered the write's
    /// expected settle in its own ledger (MYR-222) — nothing here to stamp.
    private func applyOwnerWrite(_ write: PinDropCameraController.Write) {
        guard Self.cameraWritePermitted(source: .pinDropOwner, isPinDropActive: isPinDropActive) else { return }
        mrtCameraTrace("WRITE owner center=\(write.region.center.latitude),\(write.region.center.longitude) span=\(write.region.span.latitudeDelta) animated=\(write.animated)")
        if write.animated, !reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) {
                cameraPosition = .region(write.region)
            }
        } else {
            cameraPosition = .region(write.region)
        }
    }

    /// The pin glyph's LOCAL screen point in a full-frame of `size` — the single
    /// source both the glyph's `.position` and (via its global projection) the
    /// `MapProxy.convert` readout derive from (MYR-213). Pure so it's unit-testable;
    /// horizontally centered, `ridePinDropGlyphScreenFraction` down from the top
    /// (the resting position tuned in MYR-212, kept so the sim scene is pixel-identical).
    static func pinGlyphPoint(in size: CGSize) -> CGPoint {
        CGPoint(x: size.width / 2, y: size.height * MRTMetrics.ridePinDropGlyphScreenFraction)
    }

    @MapContentBuilder
    private var mapContent: some MapContent {
        if showsUserLocation {
            UserAnnotation()
        }
        // MYR-277 B / MYR-293 — the dispatched leg-1 route: the REAL car→pickup
        // road polyline (MKDirections, via the owner's `RideRouteStore`) plus a
        // gold pickup marker. Drawn before the activity switch so it renders
        // whether the (dispatched, in-service → parked) car is parked or driving.
        //
        // The MARKER is unconditional and the LINE is not: a pickup we know is a
        // fact, a route we haven't fetched is not. `drawable` returns empty for
        // the provider's straight 2-point fallback, so a throttled or failed fetch
        // degrades to honest pins rather than to a fabricated line.
        if let pickup = pickupCoordinate {
            let leg = RideRoutePolyline.drawable(pickupRoute)
            if leg.count > 1 {
                MapPolyline(coordinates: leg)
                    .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
                MapPolyline(coordinates: leg)
                    .stroke(Color.mrtGold.opacity(0.95), style: StrokeStyle(lineWidth: 3.5, lineCap: .round, lineJoin: .round))
            }
            Annotation("Pickup", coordinate: pickup) { MRTEndpointDot(color: .mrtGold, size: 12) }
        }
        switch vehicle.activity {
        case .driving(let trip):
            if showRoute {
                // MYR-457 — the LINE is whatever `OwnerDrivingRoute` resolved, and
                // it is drawn only when it is a line. The `count > 1` here is a
                // shape check, not the predicate: realness was decided by
                // `RideRoutePolyline.isReal` on the way in, which is what retired
                // the invented `[currentPosition, destination]` segment this map
                // used to stroke across blocks, a park and a highway.
                let line = drivingRoute(trip)
                if line.count > 1 {
                    let travelled = VehicleRoute.travelledCoordinates(along: line, progress: snapshot.progress)
                    // MYR-293 (client: "Route poly line feels hard to see") — the
                    // full path is stroked at the LIVE route alpha, not `RouteLine`'s
                    // illustration 0.30. At trip start progress ≈ 0, so before this
                    // the entire route on the owner's own map was the dim wash while
                    // the rider watching the same car saw it at 0.85.
                    MapPolyline(coordinates: line)
                        .stroke(Color.mrtGold.opacity(MRTRouteStroke.aheadOpacity), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    // Glow underlay beneath the travelled segment (RouteLine.swift
                    // doc: "draw a third, wider underlay polyline").
                    MapPolyline(coordinates: travelled)
                        .stroke(Color.mrtGoldGlowSoft, style: StrokeStyle(lineWidth: 10, lineCap: .round, lineJoin: .round))
                    // Travelled portion, bright (RouteLine.swift: alpha 0.95).
                    MapPolyline(coordinates: travelled)
                        .stroke(Color.mrtGold.opacity(MRTRouteStroke.travelledOpacity), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

                    // The ORIGIN dot describes the drawn path, so it exists only
                    // when a path does.
                    if let origin = line.first {
                        Annotation("Origin", coordinate: origin) {
                            MRTEndpointDot(color: .mrtDriving, size: 10)
                        }
                    }
                }
                // MYR-293/MYR-395's rule, which this surface was breaking in both
                // directions: **pins unconditionally, the line only from
                // `isReal`.** The destination comes off the navigation group — a
                // place the car told us it is going, and a fact whether or not we
                // can draw the way there. Read off `route.last` (as it was), with
                // no real route it was planted at the end of the invented segment,
                // and with the 1-point degenerate arm it sat ON the car.
                if let destination = trip.destinationCoordinate ?? drivingRoute(trip).last {
                    Annotation("Destination", coordinate: destination) {
                        MRTEndpointDot(color: .mrtGold, size: 11)
                    }
                }
            }
            if showVehicle, drawsVehicleMarker {
                Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                    VehicleMarker(heading: vehiclePosition.headingDegrees, label: vehicle.name)
                }
            }
        case .parked:
            if showVehicle, drawsVehicleMarker {
                Annotation(vehicle.name, coordinate: vehiclePosition.coordinate) {
                    VehicleMarker(heading: 0, label: vehicle.name)
                }
            }
        }
    }

    private func recenter(animated: Bool) {
        // MYR-217: legacy recenters are subordinated during pin-drop — the ONE
        // owner (`PinDropCameraController`) holds the camera. This gate is the
        // runtime enforcement of the ownership invariant, so an `.onChange`
        // writer firing mid-pin-drop (fix stream, follow re-engage, progress
        // tick) can never mutate the camera underneath the owner again.
        guard Self.cameraWritePermitted(source: .legacyRecenter, isPinDropActive: isPinDropActive) else { return }
        // MYR-387 — THE CAMERA MAY NEVER OPEN ON NULL ISLAND. This used to be a
        // bare `centerOverride ?? vehiclePosition.coordinate`, and on the live
        // path before a snapshot exists that coordinate is `(0, 0)` — §2.3's
        // "no fix" sentinel, rendered as a uniform near-black Gulf of Guinea.
        // See `OwnerMapCamera` for the whole rule and its precedence.
        let target = OwnerMapCamera.resolve(
            vehicle: vehiclePosition.coordinate,
            override: centerOverride,
            lastKnown: lastKnownCenter,
            spanDelta: regionSpanDelta
        )
        guard let region = OwnerMapCamera.region(for: target) else {
            // Nothing true to say about where the car is. Leave MapKit's own wide
            // framing up rather than writing a fabricated centre — and register
            // NO expected settle, since we issued no write.
            mrtCameraTrace("WRITE recenter SKIPPED — no fix and no last-known position (unpositioned)")
            return
        }
        // MYR-222: register the expected settle (token classification — the
        // wall-clock window misclassified every gesture under a 1Hz fix stream).
        settleLedger.expect(center: region.center, spanDelta: target.spanDelta)
        mrtCameraTrace("WRITE recenter center=\(region.center.latitude),\(region.center.longitude) span=\(target.spanDelta) source=\(String(describing: target.source)) animated=\(animated)")
        if animated, !reduceMotion {
            // screens.jsx:417 vehicle-marker transition — `left .8s linear, top .8s linear`.
            withAnimation(.linear(duration: 0.8)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }
}

// MARK: - Live camera region box (MYR-222)

/// Plain reference holder for the continuously-tracked camera region — a
/// class so 60Hz writes during animations/gestures never invalidate the view.
/// See `VehicleMapView.liveCameraRegion`.
@MainActor
final class LiveCameraRegionBox {
    var region: MKCoordinateRegion?
}

// MARK: - Pin-drop overlay config (MYR-213)
//
// Passed to `VehicleMapView` to turn on pin-drop mode. Round 3 replaces the
// round-2 `PinDropProjection` assumed-fraction math (deleted) with a direct
// `MapProxy.convert` of the glyph's real rendered screen point — see the
// `onMapCameraChange` seam above. The GLYPH itself is drawn by `SharedViewerScreen`
// (kept in its original safe-area geometry for pixel-identity); it passes the
// glyph's GLOBAL screen point here, derived from the same `pinGlyphPoint` it draws
// the glyph at. `onCoordinate` fires on every settle with the coordinate under the
// glyph; the caller debounce-reverse-geocodes it to the pickup label.
struct PinDropOverlay {
    /// The glyph's point in the GLOBAL coordinate space — the exact on-screen spot
    /// the glyph is drawn at, converted to a coordinate on every camera settle.
    var glyphGlobalPoint: CGPoint
    /// The coordinate under the glyph, reported on every camera settle (once the
    /// owner's seating has converged — never for a transient mid-seat framing).
    var onCoordinate: (CLLocationCoordinate2D) -> Void
    /// MYR-216 deliverable 3: the user's device fix (blue-dot coordinate) to seat
    /// exactly under the glyph on entry. `nil` when there's no dot to align to
    /// (sim, or unauthorized/no-fix live) — the owner then frames the fallback
    /// center and settles on the first settle (no seating target).
    var entryFix: CLLocationCoordinate2D? = nil
    /// MYR-217: the screen size the glyph geometry lives in — feeds the owner's
    /// aspect-aware analytic entry framing (verified against MapProxy ground
    /// truth on settle, so it only needs to be approximately right).
    var viewportSize: CGSize = .zero
}
