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
    /// MYR-317 — the SAME incoming card with the queue badge up: two more pending
    /// requests waiting behind it ("+2 more waiting"). The simulated service has no
    /// incoming FEED (one in-process request is its whole world), so the count is
    /// seeded through its DEBUG-only `debugSeedWaitingIncoming` — the live service
    /// derives the identical number from the held incoming page. Everything else is
    /// `ownerIncoming` verbatim, so the pair is a clean before/after of exactly the
    /// chip this issue adds.
    case ownerIncomingQueued
    case ownerScheduled
    /// MYR-312/313 — the owner's SCHEDULED incoming card as the LIVE path renders
    /// it, in the client's exact reported condition: the request is for Saturday
    /// 5:30 PM and the target car is IN SERVICE right now. Two things the SIM
    /// `ownerScheduled` scene can't show, because both are live-only branches:
    ///   • the REAL requester name (`IncomingRequestDisplay.resolve`'s live arm
    ///     reads `requesterName`; the sim arm always renders the "Sam" fixture) —
    ///     MYR-312, which shipped as "Shared viewer wants a ride";
    ///   • Accept ENABLED against an in-service car — MYR-313's exemption.
    /// So this scene forces the incoming sheet's LIVE branch
    /// (`rendersLiveIncomingRequest`) and injects an in-service
    /// `DebugVehicleDetailsFleet` whose vehicle id the seeded record targets, so
    /// the real fleet join + the real `isAcceptGated` predicate both run.
    /// `ownerScheduled` itself is untouched (the sim drift-gate stays identical).
    case ownerScheduledLive
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
    /// MYR-308 — the seat section for a car whose SPEC says it has no cooled seats.
    /// Injects `DebugVehicleDetailsFleet(ventedSeatReadBacks: true,
    /// seatCoolingCapable: false)`: the snapshot carries the very cooler read-backs
    /// (`seatCoolerLeft`/`seatCoolerRight` present at `0`) that make the MYR-299
    /// presence heuristic fire, AND the contracts-0.16.0 `seatCoolingCapable:
    /// false` that authoritatively overrules it. The capture is therefore the
    /// PRECEDENCE proof: honest "SEAT HEATING", flame-only rows, and NO Heat↔Cool
    /// toggle — the schema forbids even a greyed-out cooling affordance, because it
    /// would imply hardware this car does not have. Pair with `MRT_OWNER_DETENT=half`.
    case ownerVehicleSeatsHeatOnly
    /// MYR-303 — the Media card with a REAL now-playing block off the wire
    /// (contracts 0.16.0). Injects `DebugVehicleDetailsFleet(media: .playingTrack)`:
    /// title/artist/album/source plus a real duration + sane elapsed, mapped by the
    /// production `VehicleContractMapping.nowPlaying` and reconciled by the real
    /// `LiveVehicleCommandExecutor`, so the capture shows the shipping render — the
    /// title/artist grammar of the prototype's media card, a passive progress line
    /// (no thumb: §7.9 has no seek), no invented cover art, and a live transport row
    /// whose icon is the car's own `Playing`. Pair with `MRT_OWNER_DETENT=half`.
    case ownerMediaNowPlaying
    /// MYR-314 — the Media card with NO media session: the car cleared the title to
    /// `""` (nothing playing) and reports no `mediaPlaybackStatus`. Injects
    /// `DebugVehicleDetailsFleet(media: .sessionEnded)`. The capture shows both
    /// halves of that one real situation — the honest idle line instead of the
    /// track that just ended, and the muted, non-interactive transport row with
    /// "Start media in the car first". Pair with `MRT_OWNER_DETENT=half`.
    case ownerMediaNoSession
    /// MYR-286 — the owner's Vehicle details section with a REAL owner-entered
    /// license plate. Injects `DebugVehicleDetailsFleet(licensePlate: "RBO 2046")`,
    /// so `licensePlate` rides BOTH the live-shaped snapshot and the list row and
    /// is mapped by the production `VehicleContractMapping` /
    /// `LiveVehicleCommandExecutor.reconcile` — the Plate row therefore shows the
    /// plate because the shipping path resolved it, not because a fixture said so.
    /// Before MYR-286 this row read `VIN ····3456` no matter what the owner typed.
    /// Its Save also runs the real §7.14 seam (`DebugPlateEndpoint`, normalize then
    /// validate, echo adopted). Pair with `MRT_OWNER_DETENT=half`.
    case ownerVehiclePlate
    /// MYR-286 — the rider's plate CHIP carrying the real plate instead of the
    /// `VIN ····xxxx` degrade. Same Booking sheet as `booking`, but the live
    /// vehicle is injected through the REAL `LiveFleetMemberMapping.fleetMember`
    /// from a `VehicleSummary` with `licensePlate` set (contracts 0.15.0 puts the
    /// plate in the VIEWER mask too, precisely so a rider can identify the car at
    /// pickup). A capture that shows the plate therefore proves the mapping does.
    case riderPlateChip
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
    /// MYR-315 — the owner sheet's freshness stamp, which exists only on the live
    /// path (the prototype has no such element and a simulated snapshot carries no
    /// freshness signals to be honest with). Both scenes inject
    /// `DebugFreshnessFleet` — a car OFFLINE for 7h, mapped by the production
    /// `VehicleContractMapping` — and force `HomeScreen`'s live rendering:
    ///   • `ownerFreshnessStale`  — the resting stamp, "Synced 7h ago", beneath the
    ///     parked hero. This is the honesty gap MYR-315 closes: before it, the peek
    ///     sheet showed a 7-hour-old battery figure with nothing saying so.
    ///   • `ownerFreshnessWaking` — the same sheet mid-tap, "Waking Lunar…". Seeded
    ///     as a phase rather than tapped, because headless capture tooling cannot
    ///     synthesize the touch.
    /// Both capture at PEEK by default (where the stamp matters most); pair with
    /// `MRT_OWNER_DETENT=half` to see it under the controls stack.
    case ownerFreshnessStale
    case ownerFreshnessWaking
    /// MYR-316 — the owner sheet for a car that is IN SERVICE with a known
    /// estimated completion. Injects `DebugVehicleDetailsFleet(status:
    /// .inService, serviceEstimatedEndAt: <next Sat 2 PM>)`, so the instant rides
    /// BOTH read surfaces (the live-shaped snapshot AND the list row) exactly as a
    /// real server emits it and travels the production
    /// `VehicleContractMapping.snapshot` + `badgeStatus` folds. The capture is
    /// therefore proof of the shipping resolver: the In Service badge and, muted
    /// directly beneath it, "Estimated completion · Sat ~2:00 PM". Captured at
    /// PEEK, where the line lives; pair with `MRT_OWNER_DETENT=half` to also see
    /// the Status & location card's matching In Service chip + "Expected back" row.
    case ownerServiceWindow
    /// MYR-316 — the SAME car with the "Expected back" ENTRY sheet open. The sheet
    /// is otherwise only reachable by tapping a row inside a half-detent scroll,
    /// which headless capture tooling cannot synthesize, so the scene seeds
    /// `HomeScreen`'s presentation state directly (`opensServiceWindowEditor`) —
    /// the same standing-in-for-a-tap precedent as `ownerFreshnessWaking`'s seeded
    /// `.waking` phase. Everything inside the sheet is real: the picker's range,
    /// the future-only validation, and a Save that runs the production
    /// `LiveVehicleCommandExecutor.setServiceWindow` against
    /// `DebugServiceWindowEndpoint` (validate future → apply Tesla precedence →
    /// echo back).
    case ownerServiceWindowEditor
    /// MYR-320 — the SAME in-service car, with the "Service completion date" row
    /// carrying its MANUAL sub-caption ("Set manually — Tesla hasn't provided an
    /// estimate for this visit"). That caption is only reachable AFTER a save
    /// whose echo came back matching the owner's submission, which headless
    /// capture tooling cannot perform, so the fleet seeds the provenance — but
    /// through the SHIPPING `LiveVehicleCommandExecutor.provenance` classifier, so
    /// the capture still proves the predicate rather than a hand-set string. Pair
    /// with `MRT_OWNER_DETENT=half`; the row shares `ownerServiceWindow`'s anchor.
    case ownerServiceWindowManual
    /// MYR-316 (client defect, server-verified) — the SAVE-REFLECTS capture.
    ///
    /// The same in-service car, but its snapshot carries NO window: this is the
    /// state the sheet is in when the owner opens the editor. On boot the fleet
    /// runs the production `LiveVehicleCommandExecutor.setServiceWindow` against
    /// `DebugServiceWindowEndpoint` — a real write, a real echo — and NOTHING
    /// refetches the snapshot afterwards, because `serviceEstimatedEndAt` is
    /// snapshot-only by contract and carries no WS delta.
    ///
    /// So the completion line in the hero and the "Service completion date" row
    /// can only be showing the ECHO, through the unified
    /// `VehicleServiceWindow.resolvedEndAt`. That is the whole fix: before it,
    /// both surfaces read the (still empty) snapshot and this scene rendered no
    /// line and no time — a save the server had accepted, invisible. Capture at
    /// PEEK for the hero line; pair with `MRT_OWNER_DETENT=half` for the row.
    case ownerServiceWindowSaved
    /// MYR-333 (client defect) — THE CHARGING SESSION THAT WAS INVISIBLE.
    ///
    /// Jul 29: "Service center was charging my car but I couldn't see it was
    /// charging. We should ensure that state is working and the bar should be a
    /// clean pulsing green animation when that happens." His two screenshots,
    /// a minute apart, show the battery climbing 74% → 76% under a bar that says
    /// nothing and a Charge tile that says "Port open" — the data was arriving,
    /// the STATE had nowhere to render.
    ///
    /// This scene is that exact condition, and it needs its own scene because it
    /// is a COMBINATION no other scene can reach: a car simultaneously
    /// `in_service` (so the badge cannot say "charging" — the wire `status` enum
    /// is single-valued and the server ranks in_service above charging) AND
    /// carrying `chargeState: .charging`. It injects both on ONE live-shaped
    /// `DebugVehicleDetailsFleet` snapshot and lets them travel the production
    /// `VehicleContractMapping.snapshot` + `badgeStatus` folds, so the capture
    /// proves the shipping mapping resolved the pulse — not a hand-set flag.
    ///
    /// Capture at PEEK for the hero (In Service badge on the left, "Charging"
    /// beside the percentage, pulsing green bar beneath); pair with
    /// `MRT_OWNER_DETENT=half` for the Charge tile's "Charging" sub. Because the
    /// bar BREATHES, capture it TWICE a second or so apart to show both ends of
    /// the cycle, and once more under
    /// `xcrun simctl ui <udid> reduce_motion enabled` to prove the fallback: the
    /// green stays, the breathing stops.
    case ownerCharging
    /// MYR-333 — the honest END of the same session. Identical injection except
    /// `chargeState: .complete` and a full battery: the bar is the SAME green but
    /// STATIC (the session is over, so motion would be a lie), the hero reads
    /// "Charge complete", and the tile sub reads "Complete". The pair
    /// `ownerCharging` / `ownerChargeComplete` is a clean before/after of exactly
    /// the motion, on identical geometry.
    case ownerChargeComplete
    /// MYR-301 (client defect) — the STUCK BANNER, now bounded. A real 502
    /// `command_failed` on `auto_conditioning_stop` settles the real `.rejected`
    /// notice ("The car didn't accept that"), which used to have no expiry and no
    /// clearing trigger short of another command and so stayed up indefinitely on
    /// the client's device. It now clears itself after
    /// `LiveVehicleCommandExecutor.defaultNoticeDisplayDuration`, so this is a
    /// TWO-SHOT capture — t≈2s (notice up) and t≈8s (gone) — exactly like
    /// `ownerDispatchedCompleted`'s 5s "Dropped off ✓" pair. Pair with
    /// `MRT_OWNER_DETENT=half`; the notice row sits under the quick tiles.
    case ownerNoticeRejected
    /// MYR-329 (client defect) — the SAME rejection, with the reason NAMED.
    ///
    /// Jul 28, TestFlight: "Any reason why car didn't accept climate, is it
    /// because low battery?" The car was in service mode; the battery was fine.
    /// `ownerNoticeRejected`'s generic "The car didn't accept that" was all the
    /// owner had, so a wrong guess was the only guess available to him.
    ///
    /// Same 502 `command_failed` on `auto_conditioning_stop`, same real
    /// `LiveVehicleCommandExecutor`, same real `.rejected` settle — the ONE
    /// difference is that the wire error carries the server's canonical token in
    /// `message` ("vehicle command failed: vehicle_in_service", rest-api.md
    /// §7.9), so the shipping `RestError.commandRejectionReason` parse runs and
    /// the row reads "Car is in service — commands are limited". Nothing about
    /// the notice is hand-set.
    ///
    /// It needs its own scene because `ownerNoticeRejected` must stay
    /// byte-identical (it is MYR-301's lifecycle capture), and because the state
    /// has no other capture route at all: it takes a car genuinely sitting in
    /// service mode, behind a real auth session, refusing a real command. The
    /// two scenes are a clean before/after of exactly the line.
    ///
    /// Same TWO-SHOT bounded display as its sibling — capture at t≈2s (notice
    /// up) and t≈8s (gone). Pair with `MRT_OWNER_DETENT=half`.
    case ownerNoticeRejectedInService
    /// MYR-320 — the vehicle-details section with EVERY enrichment field the
    /// client asked for populated at once, off one live-shaped snapshot:
    ///
    ///   • Model = "2026 Model Y Performance", composed from `trimLabel`. The
    ///     snapshot ALSO carries the raw `trim` badge `"p74d"` — so the capture is
    ///     the substitution proof: the display-safe label is rendered and the badge
    ///     code is not, and "2026 Model Y p74d" would be the bug made visible.
    ///   • Color = "Quicksilver", flowing through the EXISTING `VehicleState.color`
    ///     field (no mapping change) and rendered verbatim, replacing the honest
    ///     "— Unavailable" every earlier capture shows.
    ///   • FSD = "FSD (Supervised) v14.3.5", its own row directly after Software —
    ///     which stays "2026.14.3", because a firmware build and an FSD designation
    ///     are different facts that move independently.
    ///
    /// `ownerVehicleDetails` deliberately keeps the pre-#340 shape (blank color, no
    /// FSD row), so the pair is a clean before/after of exactly this enrichment.
    /// Pair with `MRT_OWNER_DETENT=half`; the scroll anchors to the bottom.
    case ownerVehicleEnriched
    /// MYR-316 — the RIDER's scheduling card, FLOORED. Injects a live-shaped
    /// `FleetMember` carrying `serviceEstimatedEndAt` through the REAL
    /// `LiveFleetMemberMapping.fleetMember(from:)` (a `VehicleSummary` with
    /// `status: .inService`), then opens the Schedule slide-up via the existing
    /// one-shot `opensScheduleOnSearch` hook. The capture shows all three halves
    /// of the floor at once: the muted caption ("Lunar is in service until ~Sat
    /// 2 PM"), the dimmed unreachable day/time chips, and a selection already
    /// pulled forward to the first bookable slot. A capture that renders the floor
    /// therefore proves `RideScheduleFloor` produced it — the same instant travels
    /// the shipping mapping, not a hand-set view flag.
    case riderScheduleFloored
    /// MYR-326 (client polish) — the LIVE PATH'S LOADING STATES, which have no
    /// other capture route: each is a state the app leaves as fast as it can,
    /// and the one the client screenshotted needs a real asleep car behind a real
    /// auth session. `DebugLoadingFleet` parks the app in one branch each and
    /// never resolves it (see that file). Every simulated scene is untouched —
    /// `SimulatedVehicleFleet.isConnecting` is `false` by construction, so no
    /// drift-gate capture can reach a skeleton at all.
    ///   • `ownerConnectingCold` — the first moments: the fleet LIST is in
    ///     flight, so nothing is known and even the switcher chip is a
    ///     placeholder.
    ///   • `ownerConnecting` — THE CLIENT'S STATE: the list landed (his car's
    ///     name is known and the real `MapHeader` renders it) and the cold
    ///     `/snapshot` has not. Before this issue both of these were one black
    ///     screen with a system spinner and "Connecting to your vehicles…".
    ///   • `ownerDrivesLoading` — the Drives tab with its first page in flight
    ///     (`initialOwnerTab` "drives"): a day heading + three `DriveRow`-shaped
    ///     placeholders where a spinner and "Loading drives…" used to be.
    ///   • `ownerSettingsLoading` — Settings ⇢ Tesla Account with the fleet list
    ///     in flight: two row-shaped placeholders instead of "Connecting…". The
    ///     scene forces the LIVE linked-vehicle branch
    ///     (`rendersLiveLinkedVehicles`), the same stand-in-for-a-live-session
    ///     precedent as `showsLiveSettings`; `ownerSettings` itself is unchanged.
    /// Capture each one twice — once normally, once with Reduce Motion on
    /// (`xcrun simctl ui <udid> reduce_motion enabled`) — to prove the static
    /// fallback: the blocks must stay, the sweep must go.
    case ownerConnectingCold
    case ownerConnecting
    case ownerDrivesLoading
    case ownerSettingsLoading

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

    /// MYR-327 capture modifier, orthogonal to the scene: `MRT_EXPAND_ROUTE=1`
    /// (env or `-MRT_EXPAND_ROUTE 1` arg) boots the surface with the EXPANDED
    /// route viewer already open. It exists because the viewer is only reachable
    /// by tapping the map (or its expand chip) and headless capture tooling
    /// cannot tap — the same stand-in-for-a-tap precedent as
    /// `opensServiceWindowEditor` / `initialRefreshPhase`.
    ///
    /// Consumed by BOTH host surfaces, so one modifier covers every state:
    ///   • `MRT_SCENE=ownerDrives MRT_OPEN_FIRST_DRIVE=1 MRT_EXPAND_ROUTE=1`
    ///     → the Drive Summary hero expanded (the client's own surface);
    ///   • `MRT_SCENE=trackingLeg1|trackingLeg2 MRT_EXPAND_ROUTE=1`
    ///     → the rider's live two-leg route expanded.
    /// Unset, every existing scene renders exactly as before (no overlay).
    static var opensExpandedRouteMap: Bool {
        if ProcessInfo.processInfo.environment["MRT_EXPAND_ROUTE"] == "1" { return true }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_EXPAND_ROUTE"), i + 1 < args.count { return args[i + 1] == "1" }
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

    /// MYR-319 — capture-tooling override for the dense sheet's resting scroll
    /// position: `MRT_OWNER_SCROLL=bottom` or `MRT_OWNER_SCROLL=0.55`. The
    /// per-scene `sheetScrollTarget` below only fires for scenes that INJECT a
    /// fleet; a LIVE-shaped capture (`MRT_SCENE=ownerHome MRT_TELEMETRY=live`) is
    /// the only way to see the controls stack fed by a real REST snapshot, and
    /// headless tooling cannot scroll it. Same shape as `MRT_OWNER_DETENT`.
    /// `nil` (unset) leaves every existing scene's anchor exactly as it was.
    static var ownerScrollOverride: DebugSheetScroll? {
        func parse(_ raw: String?) -> DebugSheetScroll? {
            guard let raw, !raw.isEmpty else { return nil }
            if raw == "bottom" { return .bottom }
            return Double(raw).map { .fraction(CGFloat($0)) }
        }
        if let value = parse(ProcessInfo.processInfo.environment["MRT_OWNER_SCROLL"]) { return value }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-MRT_OWNER_SCROLL"), i + 1 < args.count { return parse(args[i + 1]) }
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
        case .ownerDrives, .ownerDrivesLoading: return "drives"
        case .ownerSettings, .ownerSettingsLoading: return "settings"
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
    var showsLiveSettings: Bool {
        self == .ownerSettings || self == .riderSettings || self == .ownerSettingsLoading
    }

    /// MYR-326 — whether Settings' Tesla Account section should read the LIVE
    /// linked-vehicle list (and therefore its loading branch) rather than the
    /// fixture list. Same stand-in-for-a-live-session precedent as
    /// `showsLiveSettings` / `rendersLiveVehicleFreshness`: the section's
    /// `.connecting` state is live-only by construction, so a SIM capture of it
    /// is impossible without this. Scoped to the one scene, so `ownerSettings`
    /// keeps its fixture rows and stays byte-identical.
    var rendersLiveLinkedVehicles: Bool { self == .ownerSettingsLoading }

    /// MYR-312/313 — whether `HomeScreen`'s incoming-request surface should take
    /// its LIVE branch even though the simulator composed the simulated app mode.
    /// The two behaviours under test are live-only by construction (the real
    /// requester name off `requesterName`, and the accept gate over a real joined
    /// badge status), so a SIM capture of them is not possible; the same
    /// `showsLiveSettings` precedent lets a capture scene stand in for the live
    /// identity it cannot authenticate for. Scoped to this ONE scene, so every
    /// other scene — `ownerScheduled` and `ownerIncoming` included — keeps its
    /// simulated, pixel-identical rendering (CLAUDE.md drift gate).
    var rendersLiveIncomingRequest: Bool { self == .ownerScheduledLive }

    /// MYR-315 — whether owner Home should render its LIVE surfaces even though the
    /// simulator composed the simulated app mode. Same precedent as
    /// `rendersLiveIncomingRequest` / `showsLiveSettings`: the freshness stamp is
    /// live-only by construction, so a SIM capture of it is impossible without
    /// this. Scoped to the two freshness scenes, so every other scene keeps its
    /// simulated, byte-identical rendering (CLAUDE.md drift gate).
    var rendersLiveVehicleFreshness: Bool {
        self == .ownerFreshnessStale || self == .ownerFreshnessWaking
    }

    /// MYR-316 — whether `HomeScreen` should boot with the "Expected back" entry
    /// sheet already presented. The sheet opens from a row inside the half-detent
    /// controls scroll, which headless capture tooling cannot tap; seeding the
    /// presentation is the same stand-in-for-a-tap move `initialRefreshPhase`
    /// makes. Scoped to the one scene, so no other capture gains an overlay.
    var opensServiceWindowEditor: Bool { self == .ownerServiceWindowEditor }

    /// MYR-316 — the service window the owner scenes inject: the NEXT Saturday at
    /// 2:00 PM local. Computed relative to `now` rather than hardcoded so the
    /// value is always genuinely in the future (a fixed literal would drift into
    /// the past and the capture would show an expired window / a disabled Save,
    /// which is not the state under test). Saturday specifically, because the
    /// other-day branch of the display formatter ("Sat ~2:00 PM") is the one worth
    /// capturing — the same-day branch is the degenerate case.
    static func sampleServiceEnd(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: today)
        // 7 = Saturday in Calendar's Sunday-based indexing; always at least one
        // day out, so "today is Saturday" still yields a future instant.
        let delta = ((7 - currentWeekday + 7) % 7 == 0) ? 7 : (7 - currentWeekday + 7) % 7
        let saturday = calendar.date(byAdding: .day, value: delta, to: today) ?? today
        return calendar.date(bySettingHour: 14, minute: 0, second: 0, of: saturday) ?? saturday
    }

    /// MYR-315 — the refresh phase the stamp boots parked in. `.waking` is
    /// otherwise unreachable headlessly (it exists only between a tap and the
    /// server's answer, and capture tooling cannot tap). `nil` for every other
    /// scene, so no other capture's stamp state changes.
    @MainActor
    var initialRefreshPhase: VehicleRefreshPhase? {
        self == .ownerFreshnessWaking ? .waking("Lunar") : nil
    }

    private var isOwner: Bool {
        self == .ownerHome || self == .ownerDrives || self == .ownerIncoming
            || self == .ownerIncomingQueued
            || self == .ownerScheduled || self == .ownerScheduledLive || self == .ownerSettings
            || self == .ownerControlsUnavailable
            || self == .ownerVehicleDetails || self == .ownerVehicleTires || self == .ownerVehicleSeats
            || self == .ownerVehicleSeatsVented || self == .ownerVehicleSeatsHeatOnly
            || self == .ownerVehiclePlate
            || self == .ownerMediaNowPlaying || self == .ownerMediaNoSession
            || self == .ownerClimateAuto || self == .ownerClimateManual || self == .ownerClimateUnknown
            || self == .ownerNoticeCharge || self == .ownerNoticeAsleep || self == .ownerNoticeSeat
            || self == .ownerDispatched || self == .ownerDispatchedArrived
            || self == .ownerDispatchedEnroute || self == .ownerDispatchedCompleted
            || self == .ownerFreshnessStale || self == .ownerFreshnessWaking
            || self == .ownerServiceWindow || self == .ownerServiceWindowEditor
            || self == .ownerServiceWindowManual || self == .ownerServiceWindowSaved
            || self == .ownerCharging || self == .ownerChargeComplete
            || self == .ownerNoticeRejected || self == .ownerNoticeRejectedInService
            || self == .ownerVehicleEnriched
            || self == .ownerConnecting || self == .ownerConnectingCold
            || self == .ownerDrivesLoading || self == .ownerSettingsLoading
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
        case .ownerVehicleSeatsVented: return DebugVehicleDetailsFleet(ventedSeatReadBacks: true)
        // MYR-308 — the read-backs that make the heuristic fire, plus the spec field
        // that authoritatively says this car has NO cooled seats.
        case .ownerVehicleSeatsHeatOnly:
            return DebugVehicleDetailsFleet(ventedSeatReadBacks: true, seatCoolingCapable: false)
        // MYR-303/314 — the two live media states (see the scene docs).
        case .ownerMediaNowPlaying: return DebugVehicleDetailsFleet(media: .playingTrack)
        case .ownerMediaNoSession: return DebugVehicleDetailsFleet(media: .sessionEnded)
        // MYR-286 — same live-like fleet, plus the owner-entered plate on BOTH
        // read surfaces (snapshot + list row), as a real server emits it.
        case .ownerVehiclePlate: return DebugVehicleDetailsFleet(licensePlate: "RBO 2046")
        // MYR-313 — the same live-like fleet, IN SERVICE: the client's condition
        // (car in service today, reservation days out). The badge travels through
        // the real mapping, so `HomeScreen`'s `badgeStatus(forVehicleID:)` hands
        // the sheet a genuine `.inService` and the capture proves the shipping
        // `isAcceptGated` exemption, not a bypassed gate.
        case .ownerScheduledLive: return DebugVehicleDetailsFleet(status: .inService)
        case .ownerClimateAuto: return DebugClimateModeFleet(variant: .auto)
        case .ownerClimateManual: return DebugClimateModeFleet(variant: .cool)
        case .ownerClimateUnknown: return DebugClimateModeFleet(variant: .unknown)
        // MYR-301 — a REAL settled command notice (see the scene comments).
        case .ownerNoticeCharge: return DebugCommandNoticeFleet(variant: .chargeRelink)
        case .ownerNoticeAsleep: return DebugCommandNoticeFleet(variant: .asleep)
        case .ownerNoticeSeat: return DebugCommandNoticeFleet(variant: .seatRelink)
        // MYR-301 — the client's own rejection: climate OFF, refused by the car.
        case .ownerNoticeRejected: return DebugCommandNoticeFleet(variant: .climateRejected)
        // MYR-329 — the same rejection, with the server naming service mode.
        case .ownerNoticeRejectedInService:
            return DebugCommandNoticeFleet(variant: .climateRejectedInService)
        // MYR-315 — a car offline for 7h, so the stamp resolves its stale branch
        // through the real mapping (see `DebugFreshnessFleet`).
        case .ownerFreshnessStale, .ownerFreshnessWaking: return DebugFreshnessFleet()
        // MYR-316 — an IN SERVICE car with a known estimated completion, on both
        // read surfaces, exactly as a real server emits it.
        case .ownerServiceWindow, .ownerServiceWindowEditor:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd()
            )
        // MYR-320 — the same in-service car, with the provenance a matching write
        // echo would have proved, so the row shows its manual sub-caption.
        case .ownerServiceWindowManual:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd(),
                serviceWindowSource: .manual
            )
        // MYR-316 — the save-reflects proof: an EMPTY snapshot (no window on the
        // wire at all) plus a real write on boot. Everything the capture shows
        // about the window therefore came from the echo.
        case .ownerServiceWindowSaved:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: nil,
                savesServiceWindowOnBoot: DebugScene.sampleServiceEnd()
            )
        // MYR-333 — the client's exact condition: a car IN SERVICE that is also
        // CHARGING. Both facts ride one live-shaped snapshot and travel the real
        // mapping, so the pulsing bar in the capture is the shipping resolver's.
        // The 76% is his own second screenshot's reading.
        case .ownerCharging:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd(),
                chargeState: .charging,
                chargeLevel: 76
            )
        // MYR-333 — the same car at the end of the session: static green, no pulse.
        case .ownerChargeComplete:
            return DebugVehicleDetailsFleet(
                status: .inService,
                serviceEstimatedEndAt: DebugScene.sampleServiceEnd(),
                chargeState: .complete,
                chargeLevel: 100
            )
        // MYR-320 — every enrichment field at once: a real color off the wire, the
        // display-ready trim label composing the Model row (alongside the raw badge
        // it must NOT substitute), and the FSD designation in its own row.
        case .ownerVehicleEnriched:
            return DebugVehicleDetailsFleet(
                color: "Quicksilver",
                fsdVersion: "FSD (Supervised) v14.3.5"
            )
        // MYR-326 — the live path's three loading branches, each held still.
        // The Settings capture waits on the same thing the cold Home capture
        // does — the fleet LIST — so they share a variant: `SettingsScreen`'s
        // `.connecting` state is precisely "no rows AND still loading".
        case .ownerConnectingCold, .ownerSettingsLoading:
            return DebugLoadingFleet(variant: .fleetListPending)
        case .ownerConnecting: return DebugLoadingFleet(variant: .snapshotPending)
        case .ownerDrivesLoading: return DebugLoadingFleet(variant: .drivesPending)
        default: return nil
        }
    }

    /// MYR-279 — where the dense sheet scroll should rest for the vehicle-details
    /// capture scenes: the BOTTOM (the details section is the last section) for
    /// `ownerVehicleDetails`, or the TIRE section anchor for `ownerVehicleTires`.
    /// `nil` everywhere else, so no other scene's scroll position changes.
    var sheetScrollTarget: DebugSheetScroll? {
        switch self {
        case .ownerVehicleDetails, .ownerVehiclePlate, .ownerVehicleEnriched: return .bottom
        // MYR-316 — the "Expected back" row lives in the Status & location card,
        // which sits below the Media card; this anchor frames it at the half
        // detent. (The summary line the `ownerServiceWindow` capture is really
        // about is at PEEK and needs no anchor.)
        case .ownerServiceWindow, .ownerServiceWindowEditor, .ownerServiceWindowManual,
             .ownerServiceWindowSaved:
            return .fraction(0.62)
        // The Tire pressure section sits a little above the vertical middle of the
        // dense content; anchoring the content's ~55% point to the viewport brings
        // its honest state in-frame at the half detent.
        case .ownerVehicleTires: return .fraction(0.55)
        // The seat section is the tail of the Climate card, above the vertical
        // middle; anchoring the content's ~30% point frames it at the half detent.
        case .ownerVehicleSeats, .ownerVehicleSeatsVented, .ownerVehicleSeatsHeatOnly: return .fraction(0.30)
        // The Media card follows the Climate card, a little past the middle of the
        // dense content; this anchor frames the whole card (now-playing block,
        // transport row and its gated sub-copy) at the half detent.
        case .ownerMediaNowPlaying, .ownerMediaNoSession: return .fraction(0.39)
        // The Auto/Cool/Heat segment sits near the TOP of the Climate card (just
        // below the temp stepper); a small anchor keeps the quick tiles + climate
        // header + the segment together in-frame at the half detent.
        case .ownerClimateAuto, .ownerClimateManual, .ownerClimateUnknown: return .fraction(0.12)
        // MYR-301 — the notice row sits directly under the quick tiles, so the
        // same small anchor the climate scenes use frames the tile (with its
        // shortened sub) and the full-text row together; the seat notice needs
        // the Climate card's tail, like `ownerVehicleSeats`.
        case .ownerNoticeCharge, .ownerNoticeAsleep, .ownerNoticeRejected,
             .ownerNoticeRejectedInService: return .fraction(0.12)
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
        // MYR-317 — the owner's incoming-queue badge (see `ownerIncomingQueued`).
        if seededWaitingIncoming > 0 { service.debugSeedWaitingIncoming(seededWaitingIncoming) }
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

    /// MYR-286 — a live-SHAPED vehicle carrying a real owner-entered plate, for
    /// the `riderPlateChip` capture. Built through the REAL
    /// `LiveFleetMemberMapping.fleetMember(from:)` from a contracts
    /// `VehicleSummary` with `licensePlate` set, so the chip shows "RBO 2046"
    /// only if the shipping mapping resolves it. The same summary WITHOUT the
    /// plate is what still yields the `VIN ····2046` degrade — one code path,
    /// two honest outcomes.
    private static var platedFleetMember: FleetMember {
        LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
            vehicleId: "debug-plated",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: .parked,
            chargeLevel: 68,
            estimatedRange: 240,
            lastUpdated: "2026-07-27T12:00:00Z",
            role: .owner,
            hasActiveRide: false,
            licensePlate: "RBO 2046"
        ))
    }

    /// MYR-316 — a live-SHAPED in-service vehicle carrying a real service window,
    /// for the `riderScheduleFloored` capture. Built through the REAL
    /// `LiveFleetMemberMapping.fleetMember(from:)` from a contracts
    /// `VehicleSummary` with `status: .inService` + `serviceEstimatedEndAt`, so the
    /// caption and the dimmed chips appear only if the shipping mapping +
    /// `RideScheduleFloor` actually produce them. The same summary WITHOUT the
    /// window is what still yields a fully open picker — one code path, two honest
    /// outcomes.
    private static var flooredFleetMember: FleetMember {
        LiveFleetMemberMapping.fleetMember(from: VehicleSummary(
            vehicleId: "debug-service",
            name: "Lunar",
            model: "Model Y",
            year: 2026,
            color: "Quicksilver",
            vinLast4: "2046",
            status: .inService,
            chargeLevel: 61,
            estimatedRange: 166,
            lastUpdated: "2026-07-28T16:00:00Z",
            role: .owner,
            hasActiveRide: false,
            licensePlate: "RBO 2046",
            serviceEstimatedEndAt: DebugVehicleDetailsFleet.rfc3339.string(
                from: DebugScene.sampleServiceEnd()
            )
        ))
    }

    /// The `activeRequest` record to seed the service with (nil = no request).
    private var seededRecord: RideRequestRecord? {
        switch self {
        case .booking, .pending, .ownerIncoming, .ownerIncomingQueued, .riderPlateChip:
            return record(status: .pending)
        case .ownerScheduled:
            return record(status: .pending, schedule: Self.sampleSchedule)
        case .ownerScheduledLive:
            // MYR-312/313 — the client's card: a Saturday 5:30 PM reservation from
            // a NAMED requester, targeting the in-service debug vehicle by its real
            // id (so `HomeScreen`'s fleet join resolves the name + badge status the
            // live path would).
            return record(
                status: .pending,
                schedule: RideSchedule(day: "Sat", time: "5:30 PM"),
                fleetMemberID: Self.liveIncomingVehicleID,
                requesterName: Self.sampleProfile.firstName
            )
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

    /// MYR-317 — the queue depth behind the seeded incoming card (0 = no badge).
    /// Two is the smallest count that proves the plural copy AND that the chip is a
    /// count rather than a boolean "more" flag.
    private var seededWaitingIncoming: Int { self == .ownerIncomingQueued ? 2 : 0 }

    /// MYR-313 — the vehicle id `DebugVehicleDetailsFleet` publishes. A record that
    /// targets it JOINS the injected fleet in `HomeScreen`, so the incoming sheet
    /// resolves the real vehicle name + badge status instead of hiding them.
    static let liveIncomingVehicleID = "debug-mdy"

    private func record(
        status: RideRequestStatus,
        progress: Double? = nil,
        schedule: RideSchedule? = nil,
        fleetMemberID: String = RideRequestFixtures.fleet[0].id,
        requesterName: String? = nil
    ) -> RideRequestRecord {
        let input = RideRequestInput(
            pickup: DebugScene.samplePickup,
            destination: DebugScene.sampleDestination,
            fleetMemberID: fleetMemberID,
            passenger: nil,
            schedule: schedule,
            requesterName: requesterName
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
        case .riderScheduleFloored:
            // MYR-316 — the rider is on Search with a real trip drafted and the
            // Schedule card armed through the EXISTING one-shot hook MYR-233 added
            // (rather than a second, scene-only way to open the same card), so the
            // capture exercises the same entry path a Busy-CTA route takes.
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.debugFleetMemberOverride = DebugScene.flooredFleetMember
            viewer.opensScheduleOnSearch = true
            viewer.sheetPhase = .search
        case .riderPlateChip:
            // MYR-286 — identical to `.booking`, plus the injected live vehicle
            // carrying a real plate. Nothing else differs, so the capture isolates
            // exactly the chip this issue changes (plate, not `VIN ····2046`).
            viewer.draftPickup = DebugScene.samplePickup
            viewer.draftDestination = DebugScene.sampleDestination
            viewer.debugFleetMemberOverride = DebugScene.platedFleetMember
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
             .ownerHome, .ownerDrives, .ownerIncoming, .ownerIncomingQueued,
             .ownerScheduled, .ownerScheduledLive,
             .ownerControlsUnavailable,
             .ownerVehicleDetails, .ownerVehicleTires, .ownerVehicleSeats,
             .ownerVehicleSeatsVented, .ownerVehicleSeatsHeatOnly, .ownerVehiclePlate,
             .ownerMediaNowPlaying, .ownerMediaNoSession,
             .ownerClimateAuto, .ownerClimateManual, .ownerClimateUnknown,
             .ownerNoticeCharge, .ownerNoticeAsleep, .ownerNoticeSeat, .ownerNoticeRejected,
             .ownerNoticeRejectedInService,
             .ownerDispatched, .ownerDispatchedArrived, .ownerDispatchedEnroute,
             .ownerDispatchedCompleted,
             .ownerFreshnessStale, .ownerFreshnessWaking,
             .ownerServiceWindow, .ownerServiceWindowEditor, .ownerServiceWindowManual,
             .ownerServiceWindowSaved,
             .ownerCharging, .ownerChargeComplete,
             .ownerVehicleEnriched,
             .ownerConnecting, .ownerConnectingCold, .ownerDrivesLoading, .ownerSettingsLoading:
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
