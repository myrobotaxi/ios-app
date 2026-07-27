#if DEBUG
import CoreLocation
import Foundation
import DesignSystem
import MyRobotaxiContracts

// MARK: - Debug scene hook (MYR-200 — permanent verification infrastructure)
//
// A `#if DEBUG`, env-gated jump table that boots the app straight into any
// ride-flow state so the drift gate (CLAUDE.md) can capture every phase
// full-frame without hand-driving the flow each time. Prior QA rounds
// (MYR-197/198/199) burned enormous effort adding then removing one-off
// scaffolding per round; this replaces that with ONE permanent, documented
// mechanism.
//
//   SIMCTL_CHILD_MRT_SCENE=<name> \
//     xcrun simctl launch --console <udid> app.myrobotaxi.ios
//
// The `SIMCTL_CHILD_` prefix is how `simctl launch` forwards an env var into
// the launched process (it strips the prefix), so the app reads it as
// `MRT_SCENE`. Release builds never compile this file, so shipping is
// unaffected: with no scene set (or in a Release build) the app boots to its
// normal Sign-In screen.
//
// `RootView` applies the scene once in `onAppear` (see its `#if DEBUG`
// block): it seeds the shared viewer state + request service BEFORE routing
// `screen`/`role`/tab to the target, so the destination screen mounts with
// its `activeRequest`/`sheetPhase` already in place — no timing race with the
// reactive `onChange` handlers in `SharedViewerScreen`.
enum DebugScene: String, CaseIterable {
    // Rider ride-request flow (SharedViewerScreen)
    case idle
    case search
    case searchFiltered
    case searchSelected    // a destination chosen, "Continue" CTA showing (MYR-215)
    case pinDrop
    /// MYR-217 real-path probe: boots to IDLE and then drives the ACTUAL
    /// in-session transition (idle → search → choose destination + Continue →
    /// pinDrop) on a timer, with live location/region updates flowing the whole
    /// time. This exists because cold-seeding `pinDrop` skips the exact
    /// interleaving (pre-entry camera motion + async fixes + the `.onChange`
    /// entry re-frame) that regressed on the client four times while cold
    /// probes passed — headless tooling can't tap, so the SEQUENCE is replayed
    /// in-process through the same `SharedViewerState` methods the taps call
    /// (`sheetPhase = .search`, `chooseDestination`, `proceedFromSearch`).
    case pinDropRealPath
    /// MYR-248 regression probe: replays the real path all the way THROUGH the
    /// pin-drop back-nav — idle → search → choose destination + Continue (no
    /// pickup) → pinDrop → "Change trip" back → search — so the headless
    /// drift-gate can capture the returned search sheet's geometry without
    /// tapping. The client bug: after this back-nav the search sheet stranded
    /// at the TOP of the screen instead of its bottom-anchored search detent.
    case pinDropBackRealPath
    case review
    case reviewPicker
    case booking
    case pending           // minimized "Request sent" pill on the idle map
    case trackingLeg1      // heading to pickup
    case trackingLeg2      // in-ride, heading to drop-off
    case trackingArriving  // arriving at drop-off
    /// MYR-270 — rider tracking sheet AFTER the owner confirmed pickup: the "Your car
    /// is here" stage with the circular pulsing "Start ride" CTA (status `.arrived`).
    case trackingArrived
    case summary
    case declined
    /// MYR-233 — the rider Review sheet with a BUSY vehicle: the muted "Busy"
    /// chip on the fleet-member row and the non-gold "Schedule with … instead"
    /// CTA (the instant CTA is gated). Injects a live-shaped `FleetMember`
    /// (`debugBusyFleetMember`) through `SharedViewerState.debugFleetMemberOverride`
    /// so the state is screenshot-able headlessly with NO live backend — the
    /// simulated fixtures can't express it (`FleetMember.unavailability` is nil
    /// for every fixture, which is what keeps every other scene pixel-identical).
    case riderBusyVehicle

    // Rider scheduled-ride sheet (RideHistoryScreen → ScheduledRideSheet)
    case scheduledDetails
    case scheduledReschedule
    case scheduledRequested
    case scheduledConfirmCancel

    // MYR-224 — the owner/rider view chooser (drift-gate capture). Runs in the
    // simulator, where the session carries no real account, so `RootView` renders
    // it with a representative fixture profile (`chooserProfile`).
    case modeChooser
    // MYR-224 — Settings with a real signed-in identity + the "Switch mode" row.
    // Those only render on the live path (`liveProfile != nil`), so these capture
    // scenes make `RootView` thread the DEBUG sample profile into Settings.
    case ownerSettings
    case riderSettings

    // Owner side (HomeScreen → IncomingRequestSheet)
    case ownerHome         // plain owner Live Map, nothing seeded (live-telemetry captures)
    case ownerDrives       // owner Drives tab, nothing seeded (live-drives captures)
    case ownerIncoming
    case ownerScheduled
    /// MYR-260 — owner Home sheet in the honest unknown / stale controls state
    /// (offline car: Lock/Trunk KNOWN-but-stale, Climate/Charge "— Unavailable").
    /// Injects `DebugUnavailableControlsFleet` so the REAL sheet renders the new
    /// copy full-frame in the simulator (no live backend). Pair with
    /// `MRT_OWNER_DETENT=half` to boot at the controls detent.
    case ownerControlsUnavailable
    /// MYR-279 — owner Home sheet showing the vehicle-details section with a
    /// live-like snapshot: make/model "2026 Model Y Performance", full VIN +
    /// software version populated, and the HONEST empty states for color
    /// ("— Unavailable") and tire pressure ("Available after your next drive").
    /// Injects `DebugVehicleDetailsFleet` (no live backend). Pair with
    /// `MRT_OWNER_DETENT=half` to boot at the controls detent; the details scene
    /// anchors the dense scroll to the bottom so the section is in-frame.
    case ownerVehicleDetails
    /// MYR-279 — same live-like fleet as `ownerVehicleDetails`, but the dense
    /// sheet is scrolled to the TIRE PRESSURE section so its honest
    /// "Available after your next drive" state is in-frame for a full-frame
    /// screenshot. Pair with `MRT_OWNER_DETENT=half`.
    case ownerVehicleTires
    /// MYR-280 — owner Home dense sheet scrolled to the SEAT CLIMATE section so the
    /// per-seat mode (flame/snowflake icon + Heating/Cooling/Off caption) and the
    /// Heat/Cool toggle are in-frame for a full-frame drift-gate screenshot. Uses
    /// the SIMULATED fleet (default vehicle 0 = Cybercab, ventilated → the toggle
    /// path); pass `MRT_OWNER_VEHICLE=1` for the parked non-vent "Daily" (heat-only
    /// "SEAT HEATING", no toggle). Pair with `MRT_OWNER_DETENT=half`.
    case ownerVehicleSeats
    /// MYR-299 — the SEAT CLIMATE section for a car whose ventilated seats are
    /// discovered from the WIRE, not from a fixture flag. Injects
    /// `DebugVehicleDetailsFleet(seatCoolingCapable: true)`: a live-like snapshot
    /// carrying `seatCoolerLeft`/`seatCoolerRight` PRESENT at `0` with
    /// `seatVentEnabled: false`, mapped through the production
    /// `VehicleContractMapping` → `SeatClimatePresentation.hasVentilatedSeats`. So
    /// the capture proves the shipping predicate: both seats OFF, neither reading
    /// `.cool`, vent flag false — and the Heat↔Cool toggle is still offered under a
    /// "SEAT CLIMATE" label. Under the old `seatVentEnabled` gate this exact car
    /// rendered heat-only with no way to reach Cool (the client's report). Pair
    /// with `MRT_OWNER_DETENT=half`.
    case ownerVehicleSeatsVented
    /// MYR-274 — owner Home dense sheet scrolled to the CLIMATE section so the
    /// Auto/Cool/Heat mode segment is in-frame for a full-frame drift-gate
    /// screenshot. Three variants inject `DebugClimateModeFleet` seeded via the
    /// real reconcile path: `ownerClimateAuto` (car reports On → Auto lit),
    /// `ownerClimateManual` (Override + AC → Cool lit, display-only), and
    /// `ownerClimateUnknown` (climate on but mode absent → nothing lit, honest
    /// unknown). Pair with `MRT_OWNER_DETENT=half`.
    case ownerClimateAuto
    case ownerClimateManual
    case ownerClimateUnknown
    /// MYR-301 — owner Home dense sheet holding a REAL command notice, so the
    /// readable-notice fix is screenshot-verifiable. Injects
    /// `DebugCommandNoticeFleet`, which drives a real command through the
    /// production `LiveVehicleCommandExecutor` against a sender that fails with
    /// the real §7.9 error, so the capture exercises the shipping
    /// `RestError` → notice mapping:
    ///   • `ownerNoticeCharge` — 403 `permission_denied` on the charge port (the
    ///     client's TestFlight bug): tile sub "Re-link" (no ellipsis) + the full
    ///     "Reconnect Tesla for charging access" row with the gold Reconnect pill.
    ///   • `ownerNoticeAsleep` — 503 `vehicle_asleep`, retry exhausted, on Lock:
    ///     tile "Asleep" + "Car is asleep — try again shortly" (no action).
    ///   • `ownerNoticeSeat`   — the same 403 on a seat command: the in-place
    ///     notice line inside the Climate card, tappable to the link flow.
    /// Pair with `MRT_OWNER_DETENT=half`.
    case ownerNoticeCharge
    case ownerNoticeAsleep
    case ownerNoticeSeat
    /// MYR-265 — owner Home AFTER accepting a ride: the ride-aware dispatch banner
    /// in its leg-1 "En route to pickup · picking up <Name>" state (seeds an
    /// accepted owner ride). `…Enroute` seeds the leg-2 "<Name> aboard · heading
    /// to <dropoff>" state.
    case ownerDispatched
    /// MYR-270 — owner Home in the `arrived` state: "Picked up · waiting for <Name> to
    /// start" status line, NO owner CTA (the rider must start). Status-only capture.
    case ownerDispatchedArrived
    case ownerDispatchedEnroute
    /// MYR-292 — owner Home holding a `completed` ride: the "Dropped off ✓"
    /// confirmation banner. Boots with the banner UP; after the 5s auto-dismiss the
    /// same launch shows plain owner Home, and the acknowledgement is recorded on
    /// `OwnerHomeState` (not view state), so it stays gone across a `HomeScreen`
    /// remount. Capture at t≈1s and t≈7s to see both halves.
    case ownerDispatchedCompleted

    /// The active scene for this launch, or `nil` for a normal boot. Read
    /// from `MRT_SCENE` (env, the documented `SIMCTL_CHILD_MRT_SCENE=` path);
    /// also accepts `-MRT_SCENE <name>` launch arguments as a fallback for
    /// tooling that can't set the child env.
    static var current: DebugScene? {
        guard let scene = DebugScene(rawValue: rawSceneName ?? "") else { return nil }
        return scene
    }

    /// Verification flag for the `ownerDrives` scene: when `MRT_OPEN_FIRST_DRIVE=1`
    /// is set (env or `-MRT_OPEN_FIRST_DRIVE 1` arg), `DrivesScreen` auto-opens the
    /// first loaded drive once its feed populates — the headless way to capture a
    /// Drive Summary full-frame (the tab has no tap automation). DEBUG-only.
    static var autoOpenFirstDrive: Bool {
        if ProcessInfo.processInfo.environment["MRT_OPEN_FIRST_DRIVE"] == "1" { return true }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_OPEN_FIRST_DRIVE"), i + 1 < args.count { return args[i + 1] == "1" }
        return false
    }

    /// Drift-gate flag for the `ownerHome` scene (MYR-236 r5.3): when
    /// `MRT_OWNER_DETENT=half` is set (env or `-MRT_OWNER_DETENT half` arg), the
    /// owner sheet boots resting at the HALF detent so the at-rest-half full-
    /// frame can be captured without a synthesized drag. DEBUG-only.
    static var initialOwnerDetentHalf: Bool {
        if ProcessInfo.processInfo.environment["MRT_OWNER_DETENT"] == "half" { return true }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_OWNER_DETENT"), i + 1 < args.count { return args[i + 1] == "half" }
        return false
    }

    /// Drift-gate selector for the `ownerHome` scene (MYR-236 r5.3): boots with
    /// the given fleet index selected (`MRT_OWNER_VEHICLE=1` → the parked
    /// "Daily", for the at-rest parked captures). `nil` = default index 0.
    /// DEBUG-only.
    static var initialOwnerVehicleIndex: Int? {
        if let env = ProcessInfo.processInfo.environment["MRT_OWNER_VEHICLE"], let i = Int(env) { return i }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_OWNER_VEHICLE"), i + 1 < args.count { return Int(args[i + 1]) }
        return nil
    }

    private static var rawSceneName: String? {
        if let env = ProcessInfo.processInfo.environment["MRT_SCENE"], !env.isEmpty { return env }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_SCENE"), i + 1 < args.count { return args[i + 1] }
        return nil
    }

    // MARK: Initial routing (consumed by RootView's @State defaults)

    static var initialScreen: AppScreen {
        switch current {
        case .modeChooser: return .modeChooser
        case .some(let scene) where scene.isOwner: return .ownerHome
        case .some: return .sharedHome
        case nil: return .signIn
        }
    }

    static var initialRole: UserRole {
        current?.isOwner == true ? .owner : (current == nil ? .owner : .shared)
    }

    static var initialSharedTab: String {
        guard let current, !current.isOwner else { return "shared" }
        if current == .riderSettings { return "sharedSettings" }
        return current.isScheduled ? "rideHistory" : "shared"
    }

    static var initialOwnerTab: String {
        switch current {
        case .ownerDrives: return "drives"
        case .ownerSettings: return "settings"
        default: return "home"
        }
    }

    /// MYR-224 — the DEBUG sample identity `RootView` threads into the chooser and
    /// the `ownerSettings`/`riderSettings` capture scenes (the sim session carries
    /// no real account). Matches the client's real name so captures are realistic.
    static var sampleProfile: UserProfile {
        UserProfile(id: "debug", name: "Thomas Nandola", email: "thomas@myrobotaxi.app")
    }

    /// Whether Settings should render with the DEBUG live identity + switch row.
    var showsLiveSettings: Bool { self == .ownerSettings || self == .riderSettings }

    private var isOwner: Bool {
        self == .ownerHome || self == .ownerDrives || self == .ownerIncoming
            || self == .ownerScheduled || self == .ownerSettings
            || self == .ownerControlsUnavailable
            || self == .ownerVehicleDetails || self == .ownerVehicleTires || self == .ownerVehicleSeats
            || self == .ownerVehicleSeatsVented
            || self == .ownerClimateAuto || self == .ownerClimateManual || self == .ownerClimateUnknown
            || self == .ownerNoticeCharge || self == .ownerNoticeAsleep || self == .ownerNoticeSeat
            || self == .ownerDispatched || self == .ownerDispatchedArrived
            || self == .ownerDispatchedEnroute || self == .ownerDispatchedCompleted
    }

    /// MYR-260 — a DEBUG fleet override for scenes that need a specific
    /// live-like fleet the simulated fixtures can't express (here: the honest
    /// unknown / stale controls state). `nil` for every other scene, so the
    /// normal owner paths use the simulated fleet unchanged.
    @MainActor
    var previewFleet: (any VehicleFleet)? {
        switch self {
        case .ownerControlsUnavailable: return DebugUnavailableControlsFleet()
        case .ownerVehicleDetails, .ownerVehicleTires: return DebugVehicleDetailsFleet()
        // MYR-299 — same live-like fleet, plus the vented-car seat read-backs.
        case .ownerVehicleSeatsVented: return DebugVehicleDetailsFleet(seatCoolingCapable: true)
        case .ownerClimateAuto: return DebugClimateModeFleet(variant: .auto)
        case .ownerClimateManual: return DebugClimateModeFleet(variant: .cool)
        case .ownerClimateUnknown: return DebugClimateModeFleet(variant: .unknown)
        // MYR-301 — a REAL settled command notice (see the scene comments).
        case .ownerNoticeCharge: return DebugCommandNoticeFleet(variant: .chargeRelink)
        case .ownerNoticeAsleep: return DebugCommandNoticeFleet(variant: .asleep)
        case .ownerNoticeSeat: return DebugCommandNoticeFleet(variant: .seatRelink)
        default: return nil
        }
    }

    /// MYR-279 — where the dense sheet scroll should rest for the vehicle-details
    /// capture scenes: the BOTTOM (the details section is the last section) for
    /// `ownerVehicleDetails`, or the TIRE section anchor for `ownerVehicleTires`.
    /// `nil` everywhere else, so no other scene's scroll position changes.
    var sheetScrollTarget: DebugSheetScroll? {
        switch self {
        case .ownerVehicleDetails: return .bottom
        // The Tire pressure section sits a little above the vertical middle of the
        // dense content; anchoring the content's ~55% point to the viewport brings
        // its honest state in-frame at the half detent.
        case .ownerVehicleTires: return .fraction(0.55)
        // The seat section is the tail of the Climate card, above the vertical
        // middle; anchoring the content's ~30% point frames it at the half detent.
        case .ownerVehicleSeats, .ownerVehicleSeatsVented: return .fraction(0.30)
        // The Auto/Cool/Heat segment sits near the TOP of the Climate card (just
        // below the temp stepper); a small anchor keeps the quick tiles + climate
        // header + the segment together in-frame at the half detent.
        case .ownerClimateAuto, .ownerClimateManual, .ownerClimateUnknown: return .fraction(0.12)
        // MYR-301 — the notice row sits directly under the quick tiles, so the
        // same small anchor the climate scenes use frames the tile (with its
        // shortened sub) and the full-text row together; the seat notice needs
        // the Climate card's tail, like `ownerVehicleSeats`.
        case .ownerNoticeCharge, .ownerNoticeAsleep: return .fraction(0.12)
        case .ownerNoticeSeat: return .fraction(0.30)
        default: return nil
        }
    }

    private var isScheduled: Bool {
        switch self {
        case .scheduledDetails, .scheduledReschedule, .scheduledRequested, .scheduledConfirmCancel: return true
        default: return false
        }
    }

    // MARK: Apply (called once from RootView.onAppear before routing)

    /// Seeds the rider's sheet phase + draft and the shared request service's
    /// `activeRequest`. Must run BEFORE `RootView` routes to the target
    /// screen so that screen mounts with state already in place.
    @MainActor
    func apply(viewer: SharedViewerState, service: SimulatedRideRequestService) {
        seed(viewer: viewer)
        if let record = seededRecord { service.debugSeed(record) }
        // MYR-177: stream the car for the leg-fit camera probe when requested.
        if DebugScene.armsTracking { service.debugArmTracking() }
    }

    /// MYR-177 streaming-fix probe flag (`MRT_ARM_TRACKING=1` env or
    /// `-MRT_ARM_TRACKING 1` arg): arm the tracking ticker so the car moves.
    static var armsTracking: Bool {
        if ProcessInfo.processInfo.environment["MRT_ARM_TRACKING"] == "1" { return true }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_ARM_TRACKING"), i + 1 < args.count { return args[i + 1] == "1" }
        return false
    }

    // MARK: Sub-mode hooks (read by the individual phase views on appear)

    /// Prefill for `RideRequestSearchContent`'s local `query` — non-nil only
    /// for `.searchFiltered` (matches "Ferry Building" in RECENT_PLACES).
    var searchQuery: String? { self == .searchFiltered ? "fer" : nil }

    /// Whether `RideRequestReviewContent` should open its fleet picker card.
    var opensFleetPicker: Bool { self == .reviewPicker }

    /// MYR-217: whether `SharedViewerScreen` should run the real-path replay
    /// driver on appear (see `.pinDropRealPath`'s comment).
    var replaysRealPinDropPath: Bool { self == .pinDropRealPath || self == .pinDropBackRealPath }

    /// MYR-248: whether the real-path replay should CONTINUE past pin-drop and
    /// drive the "Change trip" back-nav to search (the regression probe).
    var replaysPinDropBackNav: Bool { self == .pinDropBackRealPath }

    /// MYR-248: a FIXED simulated device fix for scenes that must exercise the
    /// route-preview path (`routePreviewActive` needs a resolvable pickup) in the
    /// simulator without live mode's auth gate. `nil` for every other scene so sim
    /// stays pixel-identical. Financial District — same SF region as the sim map /
    /// sample pickup, so the SF→SFO preview frames sensibly.
    var simulatedUserFix: CLLocationCoordinate2D? {
        self == .pinDropBackRealPath ? DriveFixtures.financialDistrict : nil
    }

    /// The destination the real-path replay chooses on the search sheet before
    /// tapping Continue — the same sample the seeded scenes use.
    static var realPathDestination: RidePlace { sampleDestination }

    /// The scheduled ride `RideHistoryScreen` should auto-open, if any.
    var scheduledRideID: String? {
        isScheduled ? RideHistoryFixtures.scheduledRides.first?.id : nil
    }

    // MARK: Seeding

    /// Sample destination — a meaty long trip so the itinerary/route render
    /// with real distances/times (SFO · Terminal 2, 18.4 mi / 32 min).
    private static var sampleDestination: RidePlace { RideRequestFixtures.recentPlaces[1] }

    /// Sample pickup — a dropped-pin place, matching the shape `PinDrop`
    /// writes back into the draft.
    private static var samplePickup: RidePlace {
        RidePlace(
            id: "pin",
            label: "Folsom & 2nd St",
            subtitle: nil,
            miles: 0, minutes: 0,
            icon: "mappin.circle.fill",
            coordinate: DriveFixtures.financialDistrict
        )
    }

    private static var sampleSchedule: RideSchedule { RideSchedule(day: "Tomorrow", time: "6:30 AM") }

    /// MYR-233 state selector for the `riderBusyVehicle` scene: which unavailable
    /// state to render (`MRT_BUSY_REASON=busy|inService|offline`, env or
    /// `-MRT_BUSY_REASON <value>` arg). Defaults to `busy`. One scene covers all
    /// three states rather than three near-identical scenes — the same shape as
    /// `MRT_OWNER_DETENT` / `MRT_OWNER_VEHICLE`. DEBUG-only.
    static var busyReason: FleetUnavailability {
        let raw: String?
        if let env = ProcessInfo.processInfo.environment["MRT_BUSY_REASON"], !env.isEmpty {
            raw = env
        } else {
            let args = ProcessInfo.processInfo.arguments
            let i = args.firstIndex(of: "-MRT_BUSY_REASON")
            raw = i.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        return raw.flatMap(FleetUnavailability.init(rawValue:)) ?? .busy
    }

    /// MYR-233 — a live-SHAPED busy vehicle for the `riderBusyVehicle` capture.
    /// Built through the REAL mapping (`LiveFleetMemberMapping.fleetMember(from:)`)
    /// from a contracts `VehicleSummary` with `hasActiveRide: true`, so the scene
    /// exercises the shipping predicate rather than a hand-set flag — a capture
    /// that renders Busy proves the mapping does too. Names match MYR-212's live
    /// join ("Lunar" · Model Y), not a fixture persona.
    private static var busyFleetMember: FleetMember {
        // Drive the REAL wire inputs per state, so each capture proves the
        // predicate's own branch: `busy` comes from `hasActiveRide` on an
        // otherwise-bookable parked car; the other two come from the status.
        let reason = busyReason
        let status: VehicleSummary.Status
        switch reason {
        case .busy: status = .parked
        case .inService: status = .inService
        case .offline: status = .offline
        }
        return LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
            vehicleId: "debug-busy",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: status,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-07-26T12:00:00Z",
            role: .owner,
            hasActiveRide: reason == .busy
        ))
    }

    /// The `activeRequest` record to seed the service with (nil = no request).
    private var seededRecord: RideRequestRecord? {
        switch self {
        case .booking, .pending, .ownerIncoming:
            return record(status: .pending)
        case .ownerScheduled:
            return record(status: .pending, schedule: Self.sampleSchedule)
        case .trackingLeg1:
            return record(status: .accepted, progress: 0.08)
        case .trackingLeg2:
            return record(status: .accepted, progress: 0.5)
        case .trackingArriving:
            return record(status: .accepted, progress: 0.97)
        case .trackingArrived:
            return record(status: .arrived, progress: RideRequestTiming.autoAcceptInitialProgress)
        case .summary:
            return record(status: .accepted, progress: 1.0)
        case .declined:
            return record(status: .declined)
        case .ownerDispatched:
            return record(status: .accepted, progress: 0.08)
        case .ownerDispatchedArrived:
            return record(status: .arrived, progress: RideRequestTiming.autoAcceptInitialProgress)
        case .ownerDispatchedEnroute:
            return record(status: .enroute, progress: 0.5)
        case .ownerDispatchedCompleted:
            // MYR-292 — the drop-off is done; the owner's banner reads "Dropped off ✓"
            // until its auto-dismiss acknowledges the ride on `OwnerHomeState`.
            return record(status: .completed, progress: 1.0)
        default:
            return nil
        }
    }

    private func record(status: RideRequestStatus, progress: Double? = nil, schedule: RideSchedule? = nil) -> RideRequestRecord {
        let input = RideRequestInput(
            pickup: DebugScene.samplePickup,
            destination: DebugScene.sampleDestination,
            fleetMemberID: RideRequestFixtures.fleet[0].id,
            passenger: nil,
            schedule: schedule
        )
        var rec = RideRequestRecord(input: input, status: status)
        rec.trackProgress = progress
        if status == .accepted { rec.acceptedAt = Date() }
        return rec
    }

    /// Seed the rider's `SharedViewerState` — sheet phase + draft.
    @MainActor
    private func seed(viewer: SharedViewerState) {
        // Draft mirrors the seeded request so route-fitted maps + itineraries
        // have a real pickup/destination pair in every mid-flow phase.
        viewer.draftFleetMemberID = RideRequestFixtures.fleet[0].id
        switch self {
        case .idle, .pending, .pinDropRealPath, .pinDropBackRealPath:
            // `.pinDropRealPath`/`.pinDropBackRealPath` deliberately seed NOTHING
            // beyond idle — the replay driver walks the real transitions after
            // boot (MYR-217 / MYR-248).
            viewer.sheetPhase = .idle
        case .declined:
            viewer.sheetPhase = .search
            viewer.showDeclinedNotice = true
        case .search, .searchFiltered:
            viewer.sheetPhase = .search
        case .searchSelected:
            // MYR-215 deliverable 3: a destination is chosen but the flow hasn't
            // advanced — the search sheet reflects it as filled + "Continue"
            // (RideRequestSearchContent.onAppear picks up this draft).
            // MYR-237: pickup seeded too so the Search route preview (etch +
            // glow behind the sheet; the live path resolves it from the
            // location fix) is exercisable in this scene.
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .search
        case .pinDrop:
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .pinDrop(returnTo: .review)
        case .review, .reviewPicker:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .review
        case .riderBusyVehicle:
            // MYR-233 — same Review draft as `.review`, plus the injected busy
            // live vehicle. Nothing else differs, so the capture isolates exactly
            // the availability affordances this issue changes.
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.debugFleetMemberOverride = DebugScene.busyFleetMember
            viewer.sheetPhase = .review
        case .booking:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .booking
        case .trackingLeg1, .trackingLeg2, .trackingArriving, .trackingArrived:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .tracking
        case .summary:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .summary
        case .modeChooser, .ownerSettings, .riderSettings,
             .scheduledDetails, .scheduledReschedule, .scheduledRequested, .scheduledConfirmCancel,
             .ownerHome, .ownerDrives, .ownerIncoming, .ownerScheduled, .ownerControlsUnavailable,
             .ownerVehicleDetails, .ownerVehicleTires, .ownerVehicleSeats,
             .ownerVehicleSeatsVented,
             .ownerClimateAuto, .ownerClimateManual, .ownerClimateUnknown,
             .ownerNoticeCharge, .ownerNoticeAsleep, .ownerNoticeSeat,
             .ownerDispatched, .ownerDispatchedArrived, .ownerDispatchedEnroute,
             .ownerDispatchedCompleted:
            break // chooser / settings / rider live-map / owner scenes don't drive the viewer sheet
        }
    }
}

// MARK: - Dense-sheet scroll target (MYR-279 drift-gate)

/// Where a capture scene rests the owner sheet's dense scroll so a specific
/// section is in-frame for a full-frame screenshot. DEBUG-only.
enum DebugSheetScroll: Equatable {
    /// Anchor the scroll to the bottom (the vehicle-details section is last).
    case bottom
    /// Anchor the given VERTICAL fraction of the content to the viewport, e.g.
    /// 0.55 to bring a mid-stack section (Tire pressure) in-frame.
    case fraction(CGFloat)
}
#endif
