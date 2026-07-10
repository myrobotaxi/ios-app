#if DEBUG
import Foundation
import DesignSystem

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
    case review
    case reviewPicker
    case booking
    case pending           // minimized "Request sent" pill on the idle map
    case trackingLeg1      // heading to pickup
    case trackingLeg2      // in-ride, heading to drop-off
    case trackingArriving  // arriving at drop-off
    case summary
    case declined

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
    }

    // MARK: Sub-mode hooks (read by the individual phase views on appear)

    /// Prefill for `RideRequestSearchContent`'s local `query` — non-nil only
    /// for `.searchFiltered` (matches "Ferry Building" in RECENT_PLACES).
    var searchQuery: String? { self == .searchFiltered ? "fer" : nil }

    /// Whether `RideRequestReviewContent` should open its fleet picker card.
    var opensFleetPicker: Bool { self == .reviewPicker }

    /// MYR-217: whether `SharedViewerScreen` should run the real-path replay
    /// driver on appear (see `.pinDropRealPath`'s comment).
    var replaysRealPinDropPath: Bool { self == .pinDropRealPath }

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
        case .summary:
            return record(status: .accepted, progress: 1.0)
        case .declined:
            return record(status: .declined)
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
        case .idle, .pending, .pinDropRealPath:
            // `.pinDropRealPath` deliberately seeds NOTHING beyond idle — the
            // replay driver walks the real transitions after boot (MYR-217).
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
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .search
        case .pinDrop:
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .pinDrop(returnTo: .review)
        case .review, .reviewPicker:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .review
        case .booking:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .booking
        case .trackingLeg1, .trackingLeg2, .trackingArriving:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .tracking
        case .summary:
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.sheetPhase = .summary
        case .modeChooser, .ownerSettings, .riderSettings,
             .scheduledDetails, .scheduledReschedule, .scheduledRequested, .scheduledConfirmCancel,
             .ownerHome, .ownerDrives, .ownerIncoming, .ownerScheduled:
            break // chooser / settings / rider live-map / owner scenes don't drive the viewer sheet
        }
    }
}
#endif
